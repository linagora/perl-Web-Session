package Web::Session;

our $VERSION = '1.0.0';

print STDERR "Use a sub module of Web::Session such as Web::Session::File";

1;
__END__

=head1 NAME

Web::Session - Add index and search methods to Apache::Session

=head1 DESCRIPTION

Web::Session provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

It has been written to increase performances of LemonLDAP::NG. Read the
chosen module documentation carefully to set the indexes.

=head1 BATCH SIZE

get_key_from_all_sessions() reads sessions by batches. The number of sessions
read per query is set by the
C<$Web::Session::_common::BatchSize> package variable (1000 by
default). A value that is not an integer between 1 and 1,000,000 is ignored
and falls back to the default.

=head1 PERSISTENT DATABASE CONNECTIONS

SQL backends keep their database connection open between sessions: a process
opens one connection (per DataSource, user and connection attributes) the
first time a session is tied, and uses it again for the next ones. With TLS
or a remote database, opening a connection costs more than the session access
itself.

This applies to all DBI backends (PgJSON, Patroni, MySQLJSON, MariaDBJSON,
SQLite and Cassandra, and the Postgres, MySQL and MariaDB aliases). The
handle is cached by DBI C<connect_cached()>, which checks it with C<ping()>
and reconnects if the connection was lost. It is opened with the attributes
that these backends always used (C<AutoCommit> in particular) and gets the
same flags (C<pg_enable_utf8>, C<mysql_enable_utf8>, C<sqlite_unicode>).

To get the previous behaviour, one connection opened when a session is tied
and closed at untie, set the C<noreuse> argument to a true value. Example
with Lemonldap::NG, to disable the reuse in C<globalStorageOptions>:

  globalStorage        => 'Web::Session::Postgres',
  globalStorageOptions => {
      DataSource => 'dbi:Pg:dbname=sessions;host=db.example.com;sslmode=require',
      UserName   => 'lemonldap',
      Password   => 'secret',
      TableName  => 'sessions',
      Commit     => 1,
      noreuse    => 1,
  },

A C<Handle> argument has precedence over the connection cache.
L<Web::Session::Redis> has its own C<reuse> option, which is
unrelated.

Things to know:

=over

=item *

Each process (Apache or FastCGI worker...) keeps its connection(s) open: size
the maximum number of connections of the database server for the number of
processes, or use C<noreuse>.

=item *

These connections are fork safe: a child created by C<fork()> (a pre-fork
server starting its workers, for example) opens its own connection, and
neither uses nor closes the connections of its parent. This also applies to a
session tied before the fork and used or untied in the child: the child
writes it through its own connection, and doesn't commit nor roll back the
parent's transaction. It doesn't apply to connections the store doesn't
share, with C<noreuse> or a C<Handle> argument: as with
Apache::Session::Browseable, a session tied before the fork must then not be
used in the child, and the child must not destroy it (it would close or
commit the parent's connection).

=item *

Backends that use transactions (C<AutoCommit> off: PgJSON, Patroni and
SQLite) end the transaction
each time a session is untied, even after a failure: it is committed if
C<Commit> is set, rolled back otherwise. So set C<Commit =E<gt> 1> with these
backends (SQLite and Patroni set it by default). No transaction, and so no
row lock taken by a write, stays open on the connection.

=item *

Sessions tied at the same time in a process share the connection, and so the
transaction: untying one of them also commits (or rolls back) the changes
already done in the others. Use C<noreuse> if you need to keep several
sessions tied at once with independent transactions.

=item *

Search methods (searchOn(), get_key_from_all_sessions(),
deleteIfLowerThan()...) already use a persistent connection, with
C<AutoCommit> on. MySQLJSON and MariaDBJSON sessions use the same
attributes and share it; with the other backends, a process that also calls
search methods keeps two connections.

=back

PostgreSQL backends (PgJSON and its Postgres alias) also provide a pool of
connections lent to one session at a time, with timeouts and error handling:
see the C<KeepConnections> option in L<Web::Session::PgJSON>.

=head1 AVAILABLE MODULES

=head2 SQL databases

=head3 PostgreSQL

=over

=item L<Web::Session::PgJSON>: uses a "json/jsonb" field

=item L<Web::Session::Postgres>: alias of PgJSON

=item L<Web::Session::Patroni>: uses a "json/jsonb" field and
manages connections using the Patroni API to find the primary node of a
PostgreSQL cluster

=back

=head3 MySQL or MariaDB

=over

=item L<Web::Session::MySQLJSON>: for MySQL, uses a "json"
field

=item L<Web::Session::MySQL>: alias of MySQLJSON

=item L<Web::Session::MariaDBJSON>: for MariaDB, uses a
"json" field and generated columns

=item L<Web::Session::MariaDB>: alias of MariaDBJSON

=back

=head3 Other

=over

=item L<Web::Session::SQLite>

=back

=head2 NoSQL

=over

=item L<Web::Session::Redis>

=item L<Web::Session::Cassandra>

=back

=head2 Other

=over

=item L<Web::Session::File>

=item L<Web::Session::LDAP>

=back

=head1 ADDING A COLUMN TO Index ON AN EXISTING TABLE

With the backends that store indexed fields in dedicated columns (SQLite,
Cassandra), the index columns are filled only when a
session is inserted or updated. If you add a column to C<Index> on a table that
already contains sessions, this column stays C<NULL> for every existing session
until it is written again. Such sessions are considered as "field absent":
C<searchOn()> and C<searchOnExpr()> do not find them, and the C<not> clause of
C<deleteIfLowerThan()> (which matches C<NULL> columns) can delete them. For
example, Lemonldap::NG purges with
C<< not =E<gt> { _session_kind =E<gt> 'Persistent' } >>: it would delete
persistent sessions whose C<_session_kind> column was never filled.
Conversely, a column that was never filled never matches the C<or>/C<and>
thresholds of C<deleteIfLowerThan()> (a C<NULL> column is never lower than a
value): these sessions are not purged through that field (an C<or> rule can
still purge them through its other fields).

So, before relying on a new column, you must backfill it. Which method to use
depends on the backend. The examples below backfill a column named
C<_session_kind> (a field of Lemonldap::NG sessions): replace it by your field.

=head2 Backends that need no backfill

L<Web::Session::PgJSON>, L<Web::Session::Patroni>,
L<Web::Session::MySQLJSON> and
L<Web::Session::MariaDBJSON> (and their aliases) use an
expression index or a generated column computed from the serialized data:
creating the index (or the generated column) computes it for every existing
row.

=head2 Backfilling in SQL (SQLite)

If the serializer is C<Web::Session::Serialize::JSON> (the default), SQLite
can extract a field from the JSON text. Rows that are not valid JSON (sessions
written by old versions with Storable, corrupted rows) are skipped:

  UPDATE sessions SET _session_kind = json_extract(a_session, '$._session_kind')
    WHERE _session_kind IS NULL AND json_valid(a_session);

Rows skipped by this statement must be handled with the generic method.

=head2 Backends where SQL cannot be used

Cassandra, Redis and LDAP: the index is maintained by the module only when a
session is written. Use the generic method for these backends.

=head2 Generic method: re-save every session from Perl

This works with every backend (including the ones above and non-JSON rows): read
each session and write it again, so that the store rewrites its index columns.
Set C<$class> and C<$args> as you do in your application:

  my $class = 'Web::Session::SQLite';   # your backend
  my $ids   = $class->get_key_from_all_sessions( $args, sub { 1 } );
  foreach my $id ( keys %$ids ) {
      tie my %s, $class, $id, $args;
      $s{_session_kind} = $s{_session_kind};   # marks the session as modified
      untie %s;
  }

Notes:

=over

=item *

Run it when the activity is low: a session updated by another process between
C<tie> and C<untie> loses that update.

=item *

The session data is written back unchanged: no timestamp stored in the
session is updated, so sessions do not get a longer life.

=item *

Sessions that cannot be unserialized are reported on C<STDERR> and skipped.

=back

=head2 Do not just wait for sessions to be rewritten

Short-lived sessions expire and sessions rewritten regularly get their column
filled over time, but a session that is never rewritten keeps a C<NULL> column
forever. With Lemonldap::NG, persistent sessions never expire and are rewritten
only when the user logs in: they are exactly the ones its purge rule could
delete. Backfill before relying on the column.

=head1 TABLE AND COLUMN NAMES

With PostgreSQL, MySQL, MariaDB and SQLite, the table name (C<TableName>) and
the columns of the fields listed in C<Index> (column backends) are quoted in SQL queries
(C<quote_identifier()> of DBI), so an indexed field may be named after a
reserved word (C<order>, C<user>...). A C<schema.table> name is quoted part by
part, and a name that already contains quotes is used as is.

PostgreSQL folds unquoted names to lower case: tables and columns created
without quotes have lower case names. These names are therefore lowercased
before being quoted, so C<TableName =E<gt> 'Sessions'> and the
C<_whatToTrace> column keep working; tables and columns created with quoted
mixed-case names are not supported.

Other drivers get the names unchanged.

=head1 SEE ALSO

L<Apache::Session>, L<http://lemonldap-ng.org>,
L<https://lemonldap-ng.org/documentation/2.0/performances#performance_test>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

Copyright (C):

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
