package Web::Session::PgJSON;

use strict;

use Apache::Session;
use Apache::Session::Lock::Null;
use Web::Session::Store::Postgres;
use Web::Session::_common;
use Web::Session::Generate::SHA256;
use Web::Session::Serialize::JSON;
use JSON qw(to_json);

our $VERSION = '1.0.0';
our @ISA     = qw(Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} =
      new Web::Session::Store::Postgres $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Web::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Web::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Web::Session::Serialize::JSON::serialize;
    $self->{unserialize}  = \&Web::Session::Serialize::JSON::unserialize;

    return $self;
}

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    my $dbh = $class->_classDbh($args);
    if ( $args->{GinIndex} and !$class->_jsonbColumn( $args, $dbh ) ) {
        $args = { %$args };
        delete $args->{GinIndex};
    }
    return $class->_queryDbh( $dbh, $args,
        $class->_searchOnQuery( $args, $selectField, $value ), @fields );
}

# With GinIndex, add jsonb containment conditions that can use a GIN index
# on a_session. "->>" also returns the text of numbers and booleans, so a
# value that looks like one of them is searched in both forms. The "->>"
# comparison is kept: results are exactly the same as without GinIndex.
sub _searchOnQuery {
    my ( $class, $args, $field, $value ) = @_;
    my $f = $class->_sqlField($field);

    # "->>" returns arrays and objects as JSON text; jsonb rejects NUL
    return { query => "$f =?", values => [$value] }
      unless ( $args->{GinIndex}
        and defined($value)
        and $value !~ /^[\[{]/
        and "$field$value" !~ /\0/ );

    # A caller may pass the UTF-8 bytes of a non-ASCII field or value without
    # the UTF-8 flag: to_json() would then read them as Latin-1 and the JSON
    # document wouldn't match the stored data. Decode copies, used only to
    # build the documents: the "->>" recheck keeps the arguments as given,
    # like the query used without GinIndex.
    my ( $dfield, $dvalue ) = ( $field, $value );
    for ( $dfield, $dvalue ) {
        if ( !utf8::is_utf8($_) and /[\x80-\xff]/ ) {
            my $decoded = $_;
            $_ = $decoded if ( utf8::decode($decoded) );
        }
    }

    # Numbers beyond PostgreSQL numeric limits can't be stored in jsonb
    my $literal = $value =~ /^(?:true|false)\z/
      || (  $value =~ /^-?(0|[1-9][0-9]*)(?:\.([0-9]+))?\z/
        and length($1) <= 131072
        and length( $2 // '' ) <= 16383 );
    my @docs = ( to_json( { $dfield => "$dvalue" } ) );
    push @docs, '{' . to_json( "$dfield", { allow_nonref => 1 } ) . ":$value}"
      if ($literal);

    # JSON::PP doesn't flag its result as UTF-8 when it holds only Latin-1
    # characters: DBD::Pg would then send Latin-1 bytes
    utf8::upgrade($_) foreach (@docs);
    return {
        query => '('
          . join( ' OR ', ('a_session @> ?::jsonb') x @docs )
          . ") AND $f =?",
        values => [ @docs, $value ],
    };
}

# The "a_session @> ..." conditions need a jsonb column: with a json column
# every searchOn() would fail. Look the type up once per handle and table,
# warn and fall back to the plain query when it is not jsonb. An unknown type
# (table not created yet) isn't cached.
sub _jsonbColumn {
    my ( $class, $args, $dbh ) = @_;

    $dbh ||= $class->_classDbh($args);
    my $table = $args->{TableName} || $Apache::Session::Store::DBI::TableName;
    my $cache = $dbh->{private_asb_pgjson_type} ||= {};
    unless ( defined $cache->{$table} ) {
        ( $cache->{$table} ) = $dbh->selectrow_array(
            q{SELECT t.typname FROM pg_attribute a
                JOIN pg_type t ON t.oid = a.atttypid
               WHERE a.attrelid = to_regclass(?) AND a.attname = 'a_session'
                 AND NOT a.attisdropped},
            undef, $table
        );
        warn "GinIndex ignored: $table.a_session is not jsonb\n"
          unless ( $cache->{$table} || '' ) eq 'jsonb';
    }
    return ( $cache->{$table} || '' ) eq 'jsonb';
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    $value =~ s/\*/%/g;
    my $query = {
        query  => $class->_sqlField($selectField) . ' like ?',
        values => [$value]
    };
    return $class->_query( $args, $query, @fields );
}

sub searchLt {
    my $class = shift;
    return $class->_searchCompare( '<', @_ );
}

sub searchGt {
    my $class = shift;
    return $class->_searchCompare( '>', @_ );
}

# $value is checked, then inserted like deleteIfLowerThan() thresholds: bound,
# it would be typed bigint and decimal values would fail
sub _searchCompare {
    my ( $class, $op, $args, $selectField, $value, @fields ) = @_;
    $value =
      Web::Session::_common->_checkSearchValue( $op, $value );
    return {} unless ( defined $value );
    my $query = {
        query  => $class->_buildCompareExpression( $selectField, $op, $value ),
        values => []
    };
    return Web::Session::_common->_searchQuery( $op,
        sub { $class->_query( $args, $query, @fields ) } );
}

sub _query {
    my ( $class, $args, $query, @fields ) = @_;
    return $class->_queryDbh( $class->_classDbh($args), $args, $query,
        @fields );
}

# Same as _query() with an already connected handle
sub _queryDbh {
    my ( $class, $dbh, $args, $query, @fields ) = @_;
    my %res = ();

    my $dbh = $class->_classDbh($args);
    my $table_name =
      Web::Session::_common->_tableName( $dbh, $args );

    my $sth;
    my $fields =
      @fields
      ? join( ',',
        'id',
        map { $class->_sqlField($_) . ' AS ' . $class->_sqlAlias($_) } @fields )
      : '*';
    $sth =
      $dbh->prepare("SELECT $fields from $table_name where $query->{query}");
    $sth->execute( @{ $query->{values} } );

    my $res = $sth->fetchall_hashref('id') or return {};
    unless (@fields) {
        my $sub = Web::Session::_common::_unserializer($class);
        foreach my $s ( keys %$res ) {
            eval {
                my $tmp = &$sub( { serialized => $res->{$s}->{a_session} } );
                $res->{$s} = $tmp;
            };
            if ($@) {
                print STDERR "Error in session $s: $@\n";
                delete $res->{$s};
            }
        }
    }
    return $res;
}

sub deleteIfLowerThan {
    my ( $class, $args, $rule ) = @_;
    return wantarray ? ( 0, 0 ) : 0
      unless ( Web::Session::_common->_checkRule($rule)
        and Web::Session::_common->_checkThresholds($rule) );
    my ( $query, @bind );
    if ( $rule->{or} ) {
        $query = join ' OR ', map {
            $class->_buildLowerThanExpression( $_, $rule->{or}->{$_} )
          }
          keys %{ $rule->{or} };
    }
    elsif ( $rule->{and} ) {
        $query = join ' AND ', map {
            $class->_buildLowerThanExpression( $_, $rule->{and}->{$_} )
          }
          keys %{ $rule->{and} };
    }
    return wantarray ? ( 0, 0 ) : 0 unless ($query);
    if ( $rule->{not} and keys %{ $rule->{not} } ) {
        $query = "($query) AND " . join(
            ' AND ',
            map {
                push @bind, $rule->{not}->{$_};
                my $f = $class->_sqlField($_);
                "($f IS NULL OR $f <> ?)"
              }
              keys %{ $rule->{not} }
        );
    }
    my $rows = eval {
        my $dbh = $class->_classDbh($args);
        my $table_name =
          Web::Session::_common->_tableName( $dbh, $args );
        $dbh->do( "DELETE FROM $table_name WHERE $query", undef, @bind );
    };
    if ($@) {
        print STDERR "deleteIfLowerThan: $@\n";
        return wantarray ? ( 0, 0 ) : 0;
    }
    return wantarray ? ( 0, 0 ) : 0 unless defined $rows;

    if (wantarray) {
        $rows = 0 if $rows == -1;
        return ( 1, $rows );
    }
    else {
        return 1;
    }
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;

    my $dbh = $class->_classDbh($args);
    my $table_name =
      Web::Session::_common->_tableName( $dbh, $args );
    my $sth;

    # Special case if all wanted fields are indexed
    if ( $data and ref($data) ne 'CODE' ) {
        $data = [$data] unless ( ref($data) );
        my $fields = join ',', 'id',
          map { $class->_sqlField($_) . ' AS ' . $class->_sqlAlias($_) } @$data;
        $sth = $dbh->prepare("SELECT $fields from $table_name");
        $sth->execute;
        return $sth->fetchall_hashref('id');
    }
    my %res;
    my $sub = Web::Session::_common::_unserializer($class);
    Web::Session::_common->_forEachSession(
        $dbh,
        $table_name,
        sub {
            my @row = @_;
            eval {
                my $tmp = &$sub( { serialized => $row[1] } );
                if ( ref($data) eq 'CODE' ) {
                    $tmp = &$data( $tmp, $row[0] );
                    $res{ $row[0] } = $tmp if ( defined($tmp) );
                }
                elsif ($data) {
                    $data = [$data] unless ( ref($data) );
                    $res{ $row[0] }->{$_} = $tmp->{$_} foreach (@$data);
                }
                else {
                    $res{ $row[0] } = $tmp;
                }
            };
            if ($@) {
                print STDERR "Error in session $row[0]: $@\n";
                delete $res{ $row[0] };
            }
        }
    );
    return \%res;
}

sub _buildLowerThanExpression {
    my ( $class, $field, $value ) = @_;
    return $class->_buildCompareExpression( $field, '<', $value );
}

# Must match the documented expression indexes (_utime, _lastSeen). $op is
# "<" or ">", $value a number checked by the caller
sub _buildCompareExpression {
    my ( $class, $field, $op, $value ) = @_;
    Web::Session::_common->_checkOp($op);
    my $f = $class->_sqlField($field);
    return "cast($f as bigint) $op $value";
}

# Build SQL expression to get a field from a_session
sub _sqlField {
    my ( $class, $field ) = @_;

    # With standard_conforming_strings=off, backslashes are escape characters
    # in plain literals: use an escape string literal in this case
    if ( $field =~ /\\/ ) {
        $field =~ s/(['\\])/$1$1/g;
        return "a_session ->> E'$field'";
    }
    $field =~ s/'/''/g;
    return "a_session ->> '$field'";
}

# Build a column alias that preserves field name case
sub _sqlAlias {
    my ( $class, $field ) = @_;
    $field =~ s/"/""/g;
    return qq{"$field"};
}

sub _classDbh {
    my ( $class, $args ) = @_;

    my $datasource = $args->{DataSource} or die "No datasource given !";
    my $username   = $args->{UserName};
    my $password   = $args->{Password};
    my $dbh =
      DBI->connect_cached( $datasource, $username, $password,
        { RaiseError => 1, AutoCommit => 1 } )
      || die $DBI::errstr;
    $dbh->{pg_enable_utf8} = 1;
    return $dbh;
}

1;
__END__

=head1 NAME

Web::Session::PgJSON - Add index and search methods to
Apache::Session for PostgreSQL, using a JSON column

=head1 SYNOPSIS

Create table:

  CREATE UNLOGGED TABLE sessions (
      id varchar(64) not null primary key,
      a_session jsonb
  );

Optionally, add indexes on some fields. Example for Lemonldap::NG:

  CREATE INDEX uid1 ON sessions USING BTREE
    ( (a_session ->> '_whatToTrace') text_pattern_ops );
  CREATE INDEX  s1  ON sessions ( (a_session ->> '_session_kind') );
  CREATE INDEX  u1  ON sessions ( ( cast(a_session ->> '_utime' AS bigint) ) );
  CREATE INDEX ls1  ON sessions
    ( ( cast(a_session ->> '_lastSeen' AS bigint) ) );
  CREATE INDEX rt1  ON sessions
    ( ( cast(a_session ->> '_oidcRtUpdate' AS bigint) ) );
  CREATE INDEX ip1  ON sessions USING BTREE
    ( (a_session ->> 'ipAddr') text_pattern_ops );

searchOnExpr() uses C<LIKE 'prefix%'> queries: unless the database uses the
"C" collation, PostgreSQL can't use a plain btree index for them. The
C<text_pattern_ops> operator class lets the same index serve both C<=> and
prefix C<LIKE> searches. Note that a search starting with a C<*> wildcard can
never use a btree index.

deleteIfLowerThan() can use C<u1> and C<ls1> indexes only if they are declared
exactly as above. C<ls1> is needed when Lemonldap::NG "timeoutActivity" is
used: sessions purge then deletes sessions whose C<_utime> B<or> C<_lastSeen>
is too old, and an C<OR> with a non indexed side forces a full table scan.

C<rt1> is useful when OpenID Connect relying parties have a refresh token
activity timeout: sessions purge then calls searchLt() on C<_oidcRtUpdate>,
which can use this index only if it is declared exactly as above.

Avoid a global C<GIN (a_session jsonb_path_ops)> index: queries of this module
don't use the C<@E<gt>> operator, so it is never used. Measured on 300,000
realistic Lemonldap::NG sessions, it took 167 MB (versus 15 MB for the C<uid1>,
C<s1>, C<u1> and C<ip1> btree indexes above) and made updates about 3 times
slower.

A single GIN index can replace the btree indexes used only for equality
searches (like C<s1>), but it is much bigger and slows down updates: see
L</GIN INDEX>.

Don't set C<Index>: any field can be searched. Use it like the other backends
of L<Web::Session>. L<Web::Session::Postgres> is
an alias of this module.

=head1 DESCRIPTION

Web::Session provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

Web::Session::PgJSON implements it for PosqtgreSQL databases
using "json" or "jsonb" type to be able to browse sessions. The C<GinIndex>
option requires "jsonb".

=head1 GIN INDEX

Instead of one btree index per searched field, one GIN index can serve
searchOn() on B<any> field:

  CREATE INDEX gin1 ON sessions USING GIN (a_session jsonb_path_ops);

It is used only if C<GinIndex> is set in the arguments (for Lemonldap::NG, in
sessions storage options):

  GinIndex => 1,

searchOn() then adds a C<a_session @E<gt> '{"field":"value"}'> condition, the
only kind of query this index can serve. The C<@E<gt>> operator and the
C<jsonb_path_ops> operator class exist only for "jsonb": with a "json"
column, the index can't be created: C<GinIndex> is then ignored, with a
warning, and searchOn() falls back to the query used without the option. The
warning is emitted once per database handle (so once per process and
connection) and table. To use the index, convert the column first:

  ALTER TABLE sessions ALTER COLUMN a_session TYPE jsonb
    USING a_session::jsonb;

This rewrites the whole table under an C<ACCESS EXCLUSIVE> lock: sessions are
blocked during the conversion. It fails if a session contains C<\u0000>
(accepted by "json", refused by "jsonb"). The column type is cached per
database handle and table: processes already connected must be restarted (or
reconnect) after the conversion, else they keep ignoring C<GinIndex>.

Results are the same as without C<GinIndex>:

=over

=item * Containment is type sensitive while the C<-E<gt>E<gt>> operator used
without C<GinIndex> is not: searching C<123> finds both the string C<"123">
and the number C<123> (like C<_utime>). So a value that looks like a JSON
number or boolean is searched in both forms, with two index scans combined by
a C<BitmapOr>.

=item * The C<-E<gt>E<gt>> comparison is kept to filter the rows found by the
index: for example, C<{"k":1.50}> contains C<{"k":1.5}> but searching C<1.5>
must not find C<1.50>.

=item * Numbers beyond PostgreSQL numeric limits (more than 131072 digits
before the decimal point or 16383 after) can't be stored in "jsonb": such
values are searched as strings only.

=item * Values starting with C<[> or C<{> (possible text of JSON arrays and
objects) and values or field names containing a NUL character are searched
without the GIN index.

=back

Measured on PostgreSQL 17 with 300,000 realistic Lemonldap::NG sessions
(391 MB table):

=over

=item * the GIN index takes 167 MB, versus 15 MB for the C<uid1>, C<s1>,
C<u1> and C<ip1> btree indexes above;

=item * searchOn() lookups through the GIN index or through a btree index are
comparable, well under 1 ms. The gain is on fields without btree index:
0.04 ms instead of a 30 ms full table scan;

=item * updating 30,000 sessions takes 6.3 s with the GIN index, versus 1.9 s
without it (about 3 times slower). The 4 btree indexes above were present in
both runs.

=back

Sessions are updated often (C<_utime>, C<_lastSeen>), so this write cost
usually outweighs the lookup gain. The GIN index is interesting when searchOn()
is used on many fields that have no btree index. Enabling C<GinIndex> without
the index only adds useless conditions.

The GIN index doesn't help searchOnExpr() (C<LIKE>), deleteIfLowerThan()
(C<E<lt>> comparisons, and C<not> rules that must also match sessions without
the field) nor get_key_from_all_sessions(). Keep the C<uid1>, C<u1>, C<ls1>
and C<ip1> btree indexes above alongside it; C<s1> is not needed anymore.
PostgreSQL may still prefer a btree index on the searched field, or a full
scan for a frequent value like C<_session_kind = 'SSO'>.

=head2 searchLt() and searchGt()

  # Sessions whose _utime is lower than $time
  my $hash = Web::Session::PgJSON->searchLt( $args,
      '_utime', $time, 'uid' );

searchLt() and searchGt() take the same arguments and return the same data as
searchOn(): sessions whose field is lower (or greater) than the given value,
which is excluded. The value must be a number (C<12>, C<-12> or C<12.5>):
otherwise nothing is returned and an error is printed on STDERR. Spaces
around the value are ignored.

Fields are compared in SQL as deleteIfLowerThan() does
(C<cast(a_session -E<gt>E<gt> 'field' AS bigint)>): an expression index
declared exactly as C<u1> or C<rt1> above is used with an integer value. As
for deleteIfLowerThan(), the query fails if it reads a session where this
field is not an integer: searchLt() and searchGt() then return nothing and
print the error on STDERR.

Sessions without the field are never returned. This differs from the Perl
fallback of Lemonldap::NG, where a missing field is compared as 0: searchLt()
would then return nearly all sessions. Lemonldap::NG doesn't need them: its
sessions purge ignores sessions without C<_oidcRtUpdate>.

=head2 Persistent connection

The database connection is kept open between sessions. Set
C<noreuse =E<gt> 1> to open and close one for each session, see
L<Web::Session/"PERSISTENT DATABASE CONNECTIONS">.

=head2 Connection pool (KeepConnections)

With C<KeepConnections =E<gt> 1> (and C<Commit =E<gt> 1>), sessions use a pool
of connections instead: each process keeps up to C<MaxIdle> idle connections
per data source (C<DataSource> and C<UserName>), and lends each one to a
single tied session at a time. So two sessions tied together (for example a
Lemonldap::NG session and its persistent session) never share a connection
nor a transaction. Options:

=over

=item KeepConnections

Enables the pool. Ignored without C<Commit>, with C<noreuse> or with a
C<Handle>.

=item MaxIdle

Idle connections kept per process and data source, 4 by default. C<0> closes
each connection at untie.

=item IdleTimeout

Seconds: a connection idle for longer is closed instead of being lent
(without a C<ping()>, which could wait for a TCP timeout on a connection
dropped by a NAT or a load balancer), 120 by default. Adding
C<keepalives_idle> to the DSN also helps detect dead connections.

=item MaxLifetime

Seconds: an older connection is closed when it is given back, 3600 by
default.

=back

On these connections each statement is its own transaction (C<AutoCommit>
on): no session is locked, so a transaction around a tie protected nothing.
A connection that met an error (for example a write on the former primary
after a failover) is closed, never lent again. Expired idle connections are
closed when another connection is given back. A connection given back
recently is lent without a round trip; an older one is checked with
C<ping()>. Connections are opened with C<AutoInactiveDestroy>: a child
created by C<fork()> neither uses nor closes the connections of its parent,
even one that was lent when it forked.

Example with Lemonldap::NG:

  globalStorage        => 'Web::Session::PgJSON',
  globalStorageOptions => {
      DataSource      => 'dbi:Pg:dbname=sessions;host=db;keepalives_idle=30',
      UserName        => 'lemonldap',
      Password        => 'secret',
      TableName       => 'sessions',
      Commit          => 1,
      KeepConnections => 1,
  },

L<Web::Session::Patroni> has its own connection management and doesn't use
this pool.

=head1 SEE ALSO

L<http://lemonldap-ng.org>, L<Apache::Session::Postgres>

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
