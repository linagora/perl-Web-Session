package Web::Session::Store::Postgres;

use strict;

use Web::Session::Store::DBI;
use Apache::Session::Store::Postgres;

our @ISA =
  qw(Web::Session::Store::DBI Apache::Session::Store::Postgres);
our $VERSION = '1.2.2';

sub connection {
    my ( $self, $session ) = @_;

    # AutoCommit off: see "Why AutoCommit differs" in Store/DBI.pm
    $self->_connection( $session, 'Apache::Session::Store::Postgres',
        { RaiseError => 1, AutoCommit => 0 } );
    $self->{dbh}->{pg_enable_utf8} = 1;
}

1;

