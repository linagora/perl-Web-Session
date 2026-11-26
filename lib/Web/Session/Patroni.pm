package Web::Session::Patroni;

use strict;
use Apache::Session::Lock::Null;
use Web::Session::PgJSON;
use Web::Session::Store::Patroni;
use Web::Session::Generate::SHA256;
use Web::Session::Serialize::JSON;

our @ISA     = qw(Web::Session::PgJSON);
our $VERSION = '1.0.0';

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Web::Session::Store::Patroni $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Web::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Web::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Web::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Web::Session::Serialize::JSON::unserialize;

    return $self;
}

1;
__END__

=head1 NAME

Web::Session::Patroni - PostgreSQL/Patroni cluster support
for L<Web::Session::PgJSON>

=head1 SYNOPSIS

Create table and indexes as for L<Web::Session::PgJSON> (see
its documentation for the recommended indexes and their exact expressions):

  CREATE UNLOGGED TABLE sessions (
      id varchar(64) not null primary key,
      a_session jsonb
  );

Use it with Perl:

  use Web::Session::Patroni;

  my $args = {
       DataSource => 'dbi:Pg:dbname=sessions',
       UserName   => $db_user,
       Password   => $db_pass,
       Commit     => 1,

       # List Patroni API endpoints (comma or space separated)
       # Put preferred (local) endpoints first
       PatroniUrl => 'http://1.2.3.4:8008/cluster, http://2.3.4.5:8008/cluster',

       # Optional parameters with defaults:
       # PatroniTimeout             => 3,   # API request timeout in seconds
       # PatroniCacheTTL            => 60,  # Leader cache TTL in seconds
       # PatroniCircuitBreakerDelay => 30,  # Delay before retrying failed API

       # Use a GIN index for searchOn(), see
       # Web::Session::PgJSON for its trade-offs:
       # GinIndex                   => 1,

       # SSL options (verification enabled by default):
       # PatroniVerifySSL           => 1,   # Verify SSL certificates (default: 1)
       # PatroniSSLCAFile           => '/path/to/ca.pem',  # Custom CA file
       # PatroniSSLCAPath           => '/path/to/certs/',  # Custom CA directory
  };

  # Use it like L<Web::Session::PgJSON>

=head1 DESCRIPTION

Web::Session provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

Web::Session::Patroni implements it for PostgreSQL databases
using "json" or "jsonb" type to be able to browse sessions and is able to dial
directly with Patroni API to find the master node of PostgreSQL cluster in
case of error.

searchLt() and searchGt() work as in L<Web::Session::PgJSON>.

=head2 Resilience features

=over 4

=item * B<Circuit breaker>: Avoids hammering the Patroni API when it's failing.
After a failure, the API won't be queried again for C<PatroniCircuitBreakerDelay>
seconds (default: 30).

=item * B<Leader caching>: The discovered leader is cached for
C<PatroniCacheTTL> seconds (default: 60). This cache is used as fallback when
the API is unavailable.

=item * B<Split-brain detection>: Refuses to use a cluster that reports
multiple leaders.

=item * B<Leader health check>: Verifies that the leader is in "running" state
before using it.

=item * B<Multi-source support>: Each DataSource maintains its own independent
cache, allowing multiple Patroni clusters to be used simultaneously.

=back

=head2 SSL/TLS Configuration

By default, SSL certificate verification is B<enabled> when connecting to
HTTPS Patroni endpoints. This protects against man-in-the-middle attacks.

Available SSL options:

=over 4

=item * C<PatroniVerifySSL> (default: 1)

Set to 0 to disable SSL certificate verification. B<Warning>: This makes
HTTPS connections vulnerable to MITM attacks. Only use in development or
when you have other network-level protections.

  PatroniVerifySSL => 0,  # INSECURE - disable SSL verification

=item * C<PatroniSSLCAFile>

Path to a custom CA certificate file (PEM format) for verifying the Patroni
API server certificate.

  PatroniSSLCAFile => '/etc/ssl/certs/patroni-ca.pem',

=item * C<PatroniSSLCAPath>

Path to a directory containing CA certificates for verification.

  PatroniSSLCAPath => '/etc/ssl/certs/',

=back

=head2 Persistent connection

The database connection is kept open between sessions. Set
C<noreuse =E<gt> 1> to open and close one for each session, see
L<Web::Session/"PERSISTENT DATABASE CONNECTIONS">.

=head1 SEE ALSO

L<http://lemonldap-ng.org>, L<Web::Session::PgJSON>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

=over

=item 2009-2026 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2026 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
