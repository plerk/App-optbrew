package App::optbrew;

use strict;
use warnings;
use autodie;
use v5.10;
use Getopt::Args qw( dispatch arg opt subcmd );
use File::HomeDir;
use Path::Class::Dir;

# ABSTRACT: Brew for ~/opt
# VERSION

arg command => (
  isa      => 'SubCmd',
  comment  => 'sub command to run',
  required => 1,
);

opt help => (
  isa     => 'Bool',
  comment => 'print a help message and exit',
  alias   => 'h',
  ishelp  => 1,
);

subcmd cmd => 'build', comment => 'build a component';

opt name => (
  isa     => 'Str',
  comment => 'Rename component name',
);

opt suffix => (
  isa     => 'Str',
  comment => 'Suffix to attach to version number',
);

arg url => (
  isa      => 'Str',
  comment  => 'The URL',
  required => 1,
  greedy   => 1,
);

sub main
{
  my $class = shift;
  local @ARGV = @_;
  dispatch(run => 'App::optbrew');
}

sub root
{
  state $root //= Path::Class::Dir->new($ENV{OPTBREW_ROOT});
  
  unless(defined $root)
  {
    $root //= Path::Class::Dir->new(File::HomeDir->my_home, 'opt');
  }
  
  unless(-d $root)
  {
    say "does not exist: $root";
    say "create: $root";
    # TODO: permissions
    $root->mkpath(0, 0700);
  }
  
  $root;
}

package App::optbrew::build;

use strict;
use warnings;
use v5.10;
use File::Temp qw( tempdir );
use HTTP::Tiny;
use Archive::Libarchive::Any qw( :all );
use URI;
use URI::file;
use File::chdir;
use Net::FTP;
use Path::Class::Dir;
use Path::Class::File;

sub run
{
  my $opt = shift;
  
  my $url  = $opt->{url};
  my $configure_args = '';

  if($url =~ /^(.*?)\s+(.*)$/)
  {
    ($url, $configure_args) = ($1, $2);
  }

  if(-r $url || $url !~ /^(https?|ftp):/)
  {
    $url = Path::Class::File->new($url)->absolute;
  }
  else
  {
    $url = URI->new($url);
    $url = Path::Class::File->new($url->path) if $url->scheme eq 'file';
    
  }
  
  my $content;
  if($url->isa('Path::Class::File'))
  {
    $content = "$url";
  }
  elsif($url->scheme =~ /^https?$/)
  {
    say "FETCH $url";
    my $http = HTTP::Tiny->new->get($url);
  
    die "$http->{status} $http->{reason}\n"
      unless $http->{success};
    
    $content = \$http->{content};
  }
  elsif($url->scheme eq 'ftp')
  {
    say "FETCH $url";
    my $ftp = Net::FTP->new($url->host)     || die "cannot connect to " . $url->host;
    $ftp->login($url->user, $url->password) || die "cannot login ", $ftp->message;
    $ftp->binary                            || die "cannot set to binary ", $ftp->message;
    my $data = '';
    open my $fh, '>', \$data;
    binmode $fh;
    $ftp->get($url->path, $fh)              || die "get failed ", $ftp->message;
    close $fh;
    $content = \$data;
  }
  else
  {
    die "scheme not supported: " . $url->scheme;
  }
  
  local $|=1;

  if($^O eq 'MSWin32' && ref($content))
  {
    print "TMPIFYING (windows only) ";
    my $file = Path::Class::Dir->new(tempdir( CLEANUP => 1))->file('archive');
    $file->spew(iomode => '>:raw', $$content);
    $content = "$file";
    say $file;
  }

  print "NAME ";
  my($name, $version) = find_name_and_version($content);
  print " $name $version";

  $name     = $opt->{name}   if defined $opt->{name};
  $version .= $opt->{suffix} if defined $opt->{suffix};
  
  if(defined $opt->{name} || defined $opt->{suffix})
  {
    print " => $name $version";
  }
  
  print "\n";
  
  my $root = App::optbrew->root->subdir($name, $version);
  
  if(-d $root)
  {
    if(-r $root->file('.fail'))
    {
      require File::Path;
      File::Path::remove_tree($root, { verbose => 0, error => \my $err });
      die "unable to remove old $root" if @$err;
    }
    else
    {
      die "something already installed in $root";
    }
  }
  
  my $src = $root->subdir('src');
  
  say "MKDIR $src";
  # TODO: permissions
  $src->mkpath(0,0700);
  $root->file('.fail')->spew('');

  say "EXTRACT";
  do {
    local $CWD = $src;
    extract($content);
  };
  
  die "archive didn't have exactly one child" if $src->children != 1;
  ($src) = $src->children;
  
  do {
    local $CWD = $src;
    my $script = $src->parent->file($src->basename . ".sh");
    my $fh = $script->openw(">");
    say $fh "#!/bin/sh";
    my $prefix = "$root";
    $prefix =~ s{\\}{/}g;
    say $fh "sh configure --prefix=$prefix $configure_args && \\";
    say $fh "make && \\";
    say $fh "make install";
    close $fh;
    # TODO: permissions
    chmod 0700, $script;
    if($^O eq 'MSWin32')
    {
      require Alien::MSYS;
      Alien::MSYS::msys(sub {
        system 'sh', '-x', $script;
        die "build failed" if $?;
      });
    }
    else
    {
      system '/bin/sh', '-x', $script;
      die "build failed" if $?;
    }
  };
  
  $root->file('.fail')->remove;
}

sub find_name_and_version
{
  my $in = shift;
  
  my $a = archive_read_new();
  archive_read_support_filter_all($a);
  archive_read_support_format_all($a);
  if(ref $in)
  {
    archive_read_open_memory($a, $$in) == ARCHIVE_OK || die "unable to open archive: " . archive_error_string($a);
  }
  else
  {
    archive_read_open_filename($a, $in, 10240) == ARCHIVE_OK || die "unable to open archive $in: " . archive_error_string($a);
  }
  while(archive_read_next_header($a, my $e) == ARCHIVE_OK)
  {
    if(archive_entry_pathname($e) =~ m{/configure$})
    {
      my $configure = '';
      while(1)
      {
        my $size = archive_read_data($a, my $tmp, 10240);
        $size >=0 || die "error reading from archive: " . archive_error_string($a);
        last if $size == 0;
        $configure .= $tmp;
      }
      foreach my $line (split /\n/, $configure)
      {
        if($line =~ /^# Generated by GNU Autoconf [\d\.]+ for (.*?) (.*?)\.$/) {
          archive_read_close($a);
          archive_read_free($a);
          return ($1, $2);
        }
      }
    }
    else
    {
      archive_read_data_skip($a);
    }
  }
  
  archive_read_close($a);
  archive_read_free($a);
  
  die "unable to find configure script in archive";
}

sub extract
{
  my $in = shift;

  my $a = archive_read_new();
  archive_read_support_filter_all($a);
  archive_read_support_format_all($a);
  if(ref $in)
  {
    archive_read_open_memory($a, $$in) == ARCHIVE_OK || die "unable to open archive: " . archive_error_string($a);
  }
  else
  {
    archive_read_open_filename($a, $in, 10240) == ARCHIVE_OK || die "unable to open archive $in: " . archive_error_string($a);
  }

  my $d = archive_write_disk_new();
  archive_write_disk_set_options($d, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_ACL | ARCHIVE_EXTRACT_FFLAGS);
  archive_write_disk_set_standard_lookup($d);

  while(1)
  {
    my $r = archive_read_next_header($a, my $e);
    last if $r == ARCHIVE_EOF;
    if($r == ARCHIVE_WARN)
    { warn archive_error_string($a) }
    elsif($r != ARCHIVE_OK)
    { die archive_error_string($a) }
    
    $r = archive_write_header($d, $e);
    if($r == ARCHIVE_WARN)
    { warn archive_error_string($a) }
    elsif($r != ARCHIVE_OK)
    { die archive_error_string($a) }
    
    while(1)
    {
      $r = archive_read_data_block($a, my $buff, my $offset);
      last if $r == ARCHIVE_EOF;
      if($r == ARCHIVE_WARN)
      { warn archive_error_string($a) }
      elsif($r != ARCHIVE_OK)
      { die archive_error_string($a) }
      
      $r = archive_write_data_block($d, $buff, $offset);
      if($r == ARCHIVE_WARN)
      { warn archive_error_string($a) }
      elsif($r != ARCHIVE_OK)
      { die archive_error_string($a) }
    }
  }

  archive_write_close($d);
  archive_write_free($d);

  archive_read_close($a);
  archive_read_free($a) == ARCHIVE_OK || warn "unable to free archive: " . archive_error_string($a);
}

1;
