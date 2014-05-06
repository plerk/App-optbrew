package My::ModuleBuild;

use strict;
use warnings;
use base qw( Module::Build );

sub new
{
  my($class, %args) = @_;
  
  $args{requires}->{'Alien::MSYS'} = '0.04' if $^O eq 'MSWin32';
  
  my $self = $class->SUPER::new(%args);
  
  $self;
}

1;
