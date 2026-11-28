use strict;
use Test::More;
use JSON qw(from_json);

# updateKeys() statements, then json and text columns against PostgreSQL when
# PG_DSN is set (jsonb columns are tested by Web-Session-PgJSON.t)
my $class = 'Web::Session::PgJSON';
plan skip_all => "$class can't be loaded" unless ( eval "require $class" );

package FakeDbh;

sub new {
    my ( $class, $type, $rows ) = @_;
    return bless {
        Driver  => { Name => 'Pg' },
        type    => $type,
        rows    => $rows,
        lookups => 0,
        done    => []
    }, $class;
}
sub quote_identifier { qq{"$_[1]"} }

sub selectrow_array {
    my $self = shift;
    $self->{lookups}++;
    return $self->{type};
}

sub do {
    my ( $self, $sql, $attr, @bind ) = @_;
    push @{ $self->{done} }, [ $sql, @bind ];
    return $self->{rows};
}

package main;

my $dbh;
{
    no warnings 'redefine';
    local *Web::Session::PgJSON::_borrowDbh = sub { ( $dbh, undef ) };

    my $args = { TableName => 'sessions' };
    my $set  = '((a_session::jsonb || ?::jsonb) - ?::text[])::json';

    foreach (
        [ jsonb => '(a_session || ?::jsonb) - ?::text[]' ],
        [ json  => $set ],
        [ text  => $set ],
        [ ''    => $set ],
      )
    {
        my ( $type, $value ) = @$_;
        $dbh = FakeDbh->new( $type, 1 );
        is(
            $class->updateKeys(
                { %$args, TableName => "t_$type" },
                'abc',
                {
                    uid   => 'dwho',
                    list  => [ 1, { b => 2, a => 1 } ],
                    gone  => undef,
                    agone => undef
                }
            ),
            1,
            "Column '$type': session updated"
        );
        is_deeply(
            $dbh->{done},
            [
                [
                    qq{UPDATE "t_$type" SET a_session = $value WHERE id = ?},
                    '{"list":[1,{"a":1,"b":2}],"uid":"dwho"}',
                    [ 'agone', 'gone' ],
                    'abc'
                ]
            ],
            "Column '$type': one UPDATE, canonical JSON, deleted keys"
        );
    }

    $dbh = FakeDbh->new( 'jsonb', '0E0' );
    is( $class->updateKeys( $args, 'abc', { uid => 'dwho' } ),
        0, 'No session with this id: 0' );
    $class->updateKeys( $args, 'abc', { uid => 'dwho' } );
    is( $dbh->{lookups}, 1, 'Column type looked up once per handle and table' );
    is_deeply( $dbh->{done}->[0]->[1], '{"uid":"dwho"}', 'Only set keys' );
    $class->updateKeys( $args, 'abc', { uid => undef } );
    is_deeply(
        [ @{ $dbh->{done}->[2] }[ 1, 2 ] ],
        [ '{}', ['uid'] ],
        'Only deleted keys'
    );

    $dbh = FakeDbh->new( 'jsonb', 1 );
    foreach (
        [ 'No id',       undef, { uid => 1 } ],
        [ 'Empty id',    '',    { uid => 1 } ],
        [ 'No change',   'abc', {} ],
        [ 'Not a hash',  'abc', [ uid => 1 ] ],
        [ '_session_id', 'abc', { _session_id => 'x' } ],
      )
    {
        my ( $desc, $id, $changes ) = @$_;
        ok( !eval { $class->updateKeys( $args, $id, $changes ); 1 },
            "$desc: dies" );
    }
    is( scalar @{ $dbh->{done} }, 0, 'Nothing written on a bad argument' );
}

SKIP: {
    skip 'Set PG_DSN to run the PostgreSQL tests', 1 unless ( $ENV{PG_DSN} );
    skip 'DBD::Pg is needed', 1 unless ( eval { require DBD::Pg; 1 } );
    my $pg = DBI->connect( $ENV{PG_DSN}, $ENV{PG_USER}, $ENV{PG_PASSWORD},
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
    my $prefix = $ENV{ASB_TEST_TABLE_PREFIX} // 'asb_test_';
    foreach my $type (qw(json text)) {
        my $table = "${prefix}updatekeys_$type";
        $pg->do("DROP TABLE IF EXISTS $table");
        $pg->do("CREATE TABLE $table "
              . "(id varchar(64) not null primary key, a_session $type)" );
        my $targs = {
            DataSource => $ENV{PG_DSN},
            UserName   => $ENV{PG_USER},
            Password   => $ENV{PG_PASSWORD},
            TableName  => $table,
            Commit     => 1,
        };
        my %s;
        tie %s, $class, undef, $targs;
        @s{qw(uid mail _utime)} = ( 'dwho', 'old@badwolf.org', 100 );
        my $id = $s{_session_id};
        untie %s;
        is(
            $class->updateKeys(
                $targs, $id,
                { mail => "\x{e9}\@badwolf.org", _utime => undef }
            ),
            1,
            "$type column: session updated"
        );
        tie %s, $class, $id, $targs;
        is_deeply(
            {%s},
            { _session_id => $id, uid => 'dwho', mail => "\x{e9}\@badwolf.org" },
            "$type column: keys set, deleted and kept"
        );
        untie %s;
        my ($raw) =
          $pg->selectrow_array( "SELECT a_session FROM $table WHERE id = ?",
            undef, $id );
        ok( eval { from_json($raw); 1 }, "$type column: still JSON" );
        is( $class->updateKeys( $targs, 'none', { uid => 'x' } ),
            0, "$type column: unknown session" );

        # Not JSON (Storable, written by very old versions): the caller
        # falls back to a tie, which rewrites it as JSON
        $pg->do("INSERT INTO $table VALUES ('old', 'not json')")
          if ( $type eq 'text' );
        ok( !eval { $class->updateKeys( $targs, 'old', { uid => 'x' } ); 1 },
            "$type column: a row that isn't JSON dies" )
          if ( $type eq 'text' );
        $pg->do("DROP TABLE $table");
    }
}

done_testing();
