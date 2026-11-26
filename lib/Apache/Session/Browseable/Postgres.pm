package Apache::Session::Browseable::Postgres;

use strict;
use Apache::Session::Browseable::PgJSON;

our $VERSION = '1.4.0';
our @ISA     = qw(Apache::Session::Browseable::PgJSON);

# populate() is also called as a function
*populate = \&Apache::Session::Browseable::PgJSON::populate;

1;
__END__

=head1 NAME

Apache::Session::Browseable::Postgres - Alias of
L<Apache::Session::Browseable::PgJSON>

=head1 SYNOPSIS

  use Apache::Session::Browseable::Postgres;

  my $args = {
       DataSource => 'dbi:Pg:sessions',
       UserName   => $db_user,
       Password   => $db_pass,
       Commit     => 1,
  };

  tie %session, 'Apache::Session::Browseable::Postgres', $id, $args;

=head1 DESCRIPTION

This module is an alias of L<Apache::Session::Browseable::PgJSON>: sessions
are stored as JSON in a C<json> or C<jsonb> column, and indexes are expression
indexes on this column. See L<Apache::Session::Browseable::PgJSON> for the
table, the indexes and the available options.

Previous versions stored each indexed field in its own column. A table created
for them is not compatible: create a new table as described in
L<Apache::Session::Browseable::PgJSON>, then copy the sessions, for example:

  INSERT INTO new_sessions (id, a_session)
    SELECT id, a_session::jsonb FROM sessions
    WHERE a_session IS JSON;

(C<IS JSON> needs PostgreSQL 16 or later.)

=head1 SEE ALSO

L<Apache::Session::Browseable::PgJSON>, L<Apache::Session::Browseable>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

=over

=item 2009-2025 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2025 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
