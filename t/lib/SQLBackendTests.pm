package SQLBackendTests;

# Common tests for SQL backends, run only if <env>_DSN is set (credentials
# are read from <env>_USER and <env>_PASSWORD). Parameters:
#  - class:   Apache::Session::Browseable class to test
#  - driver:  DBD driver name (Pg, mysql, MariaDB, Oracle); if not set, it
#             is read from <env>_DSN
#  - env:     environment variables prefix (PG, MYSQL, MARIADB, ORACLE)
#  - table:   table name (dropped before and after tests)
#  - create:  SQL statements to create table (__TABLE__ is replaced)
#  - index:   indexed fields (DBI based backends, one column per field)
#  - corrupt: a_session value that can't be unserialized
#  - null:    1 if a field can be stored as JSON null (JSON backends)
#  - json:    1 if any field can be queried (JSON/Hstore backends)
#  - weird:   field names that need quoting (JSON/Hstore backends)
#  - scs:     1 to also test with standard_conforming_strings=off (PostgreSQL)
#  - reserved: an indexed field named after a reserved word (quoted column)
#  - tableCase: 1 to also use the table with its name in upper case
#               (PostgreSQL folds unquoted names to lower case)
#  - todo:    known bugs of this backend: { test group => reason }. Tests of
#             these groups are run as TODO tests and may die without
#             breaking the rest of the suite
#  - utf8:    1 to test non-ASCII field names and values (JSON backends)
#  - utf8_todo: reason why get_key_from_all_sessions() without fields doesn't
#               return non-ASCII values yet (marks this test as TODO)
#  - exact:   1 to check that searches are case and accent sensitive
#  - explain: sub( $class, $dbh, $args ) returning a list of
#             [ description, WHERE clause, index or array ref of indexes,
#               statement ]:
#             the plan of each WHERE clause must use all these indexes.
#             Statement defaults to "SELECT id" (use "DELETE" to explain a
#             deletion)
#  - explain_key:  1 to check that MySQL/MariaDB chooses these indexes, not
#                  only lists them in possible_keys
#  - explain_fill: number of sessions to add to a new table before explaining
#                  queries, so that the optimizer choices don't depend on a
#                  tiny table
#
# ASB_TEST_TABLE_PREFIX environment variable replaces the "asb_test_" prefix
# of table names.

use strict;
use warnings;
use Test::More;
use Exporter 'import';

our @EXPORT = qw(run_tests);
our $TODO;

# Diagnostics may contain non-ASCII values
binmode( Test::More->builder->$_, ':encoding(UTF-8)' )
  foreach (qw(output failure_output todo_output));

sub run_tests {
    my %o = @_;
    my ( $class, $table ) = @o{qw(class table)};
    my $dsn = $ENV{"$o{env}_DSN"};
    $table =~ s/^asb_test_/$ENV{ASB_TEST_TABLE_PREFIX}/
      if $ENV{ASB_TEST_TABLE_PREFIX};

    $o{driver} ||= ( ( $dsn // '' ) =~ /^dbi:(\w+):/i )[0];
    plan skip_all => "Set $o{env}_DSN to run this test" unless $o{driver};
    plan skip_all => "DBD::$o{driver} is needed for this test"
      unless eval "require DBI; require DBD::$o{driver}; 1";
    plan skip_all => "Set $o{env}_DSN to run this test" unless $dsn;

    my $dbh = DBI->connect(
        $dsn, $ENV{"$o{env}_USER"},
        $ENV{"$o{env}_PASSWORD"},
        { RaiseError => 1, PrintError => 0, PrintWarn => 0, AutoCommit => 1 }
    );

    # Oracle < 23 has no DROP TABLE IF EXISTS
    my $drop = sub {
        if ( $o{driver} eq 'Oracle' ) {
            eval { $dbh->do("DROP TABLE $table") };
        }
        else {
            $dbh->do("DROP TABLE IF EXISTS $table");
        }
    };
    my $create = sub {
        $drop->();
        foreach ( @{ $o{create} } ) {
            ( my $sql = $_ ) =~ s/__TABLE__/$table/g;
            $dbh->do($sql);
        }
    };
    $create->();

    use_ok($class);

    my $args = {
        DataSource => $dsn,
        UserName   => $ENV{"$o{env}_USER"},
        Password   => $ENV{"$o{env}_PASSWORD"},
        TableName  => $table,
        Commit     => 1,
        ( $o{index} ? ( Index => $o{index} ) : () ),
    };
    my %todo  = %{ $o{todo}  || {} };
    my @weird = @{ $o{weird} || [] };

    my $newSession = sub {
        my %data = @_;
        my %session;
        tie %session, $class, undef, $args;
        $session{$_} = $data{$_} foreach ( keys %data );
        my $id = $session{_session_id};
        untie %session;
        return $id;
    };

    my %data = (
        dwho => {
            uid           => 'dwho',
            _whatToTrace  => 'dwho',
            _session_kind => 'SSO',
            _utime        => 100,
            _lastSeen     => 100,
            _oidcRtUpdate => 150,
            counter       => 1,
            mail          => 'dwho@badwolf.org',
            ( map { ( $_ => 'w1' ) } @weird ),
        },
        rtyler => {
            uid           => 'rtyler',
            _whatToTrace  => 'rtyler',
            _session_kind => 'Persistent',
            _utime        => 100,
            _lastSeen     => 300,
            _oidcRtUpdate => 250,
            counter       => 3,
            mail          => 'rtyler@badwolf.org',
            ( map { ( $_ => 'w2' ) } @weird ),
        },
        obrien => {
            uid           => "O'Brien",
            _whatToTrace  => "O'Brien",
            _session_kind => 'SSO',
            _utime        => 300,
            _lastSeen     => 100,
            counter       => 2,
            mail          => 'obrien@badwolf.org',
        },
        nokind => {
            uid           => 'nokind',
            _whatToTrace  => 'nokind',
            _utime        => 100,
            _lastSeen     => 100,
            _oidcRtUpdate => 200,
            mail          => 'nokind@badwolf.org',
        },
    );

    my $ids;
    my $reset = sub {
        $dbh->do("DELETE FROM $table");
        $ids = { map { ( $_ => $newSession->( %{ $data{$_} } ) ) } keys %data };
    };
    my $name = sub {
        my %rev = reverse %{ $ids || {} };
        return join ',', sort map { $rev{$_} // $_ } keys %{ $_[0] || {} };
    };
    my $remaining = sub {
        return $name->( $class->get_key_from_all_sessions($args) );
    };
    my $quiet = sub {
        my ($code) = @_;
        local *STDERR;
        my $err = '';
        open STDERR, '>', \$err;
        return $code->();
    };

    # Run a group of tests. If the group is a known bug of this backend, run
    # it as TODO: STDERR is silenced and a die is reported as a failure
    my $group = sub {
        my ( $key, $code ) = @_;
        return $code->() unless $todo{$key};
      TODO: {
            local $TODO = $todo{$key};
            local *STDERR;
            my $err = '';
            open STDERR, '>', \$err;
            eval { $code->(); 1 } or fail("$key died: $@");
        }
    };

    # Store / retrieve
    $group->(
        store => sub {
            my $id = $newSession->( %{ $data{dwho} }, list => [ 1, 2 ] );
            ok( $id, 'Session created' );
            my %session;
            ok( tie( %session, $class, $id, $args ), 'Session retrieved' );
            is( $session{$_}, $data{dwho}->{$_}, "Field $_ retrieved" )
              foreach ( sort keys %{ $data{dwho} } );
            is_deeply( $session{list}, [ 1, 2 ], 'Array retrieved' );
            untie %session;
        }
    );

    # Non-ASCII values, in Latin-1 range and beyond
    foreach my $v ( "\x{c9}lodie", "\x{c9}lodie \x{3a9}" ) {
        ( my $l = $v ) =~ s/[^ -~]/?/g;
        my $u8 = $newSession->( uid => 'u8', cn => $v, list => [$v] );
        my %session;
        my $check = sub {
            my ($step) = @_;
            tie %session, $class, $u8, $args;
            is( $session{cn}, $v, "Value $l$step retrieved" );
            is_deeply( $session{list}, [$v], "Array with $l$step retrieved" );
            untie %session;
            my $r = $class->get_key_from_all_sessions($args);
            is( $r->{$u8}->{cn}, $v, "get_key_from_all_sessions returns $l$step" );
            $r = $class->get_key_from_all_sessions( $args, sub { $_[0]->{cn} } );
            is( $r->{$u8}, $v, "get_key_from_all_sessions with a code ref: $l$step" );
            $group->(
                gkfasArray => sub {
                    my $r = $class->get_key_from_all_sessions( $args, ['cn'] );
                    is( $r->{$u8}->{cn}, $v,
                        "get_key_from_all_sessions with fields: $l$step" );
                }
            );
            $group->(
                searchOnData => sub {
                    my $r = $class->searchOn( $args, 'uid', 'u8' );
                    is( $r->{$u8}->{cn}, $v,
                        "searchOn without fields returns $l$step" );
                }
            );
            $r = $class->searchOn( $args, 'uid', 'u8', 'cn' );
            is( $r->{$u8}->{cn}, $v, "searchOn with fields returns $l$step" );
        };
        $check->('');

        # Update the session: the store rewrites the non-ASCII values
        tie %session, $class, $u8, $args;
        $session{x} = 1;
        untie %session;
        $check->(' after update');
        $dbh->do( "DELETE FROM $table WHERE id=?", undef, $u8 );
    }

    $reset->();

    # searchOn / searchOnExpr
    $group->(
        searchOn => sub {
            my $res = $class->searchOn( $args, 'uid', 'dwho' );
            is( $name->($res), 'dwho', 'searchOn without fields' );

            $res = $class->searchOn( $args, '_whatToTrace', "O'Brien", 'uid' );
            is_deeply(
                $res,
                {
                    $ids->{obrien} => { id => $ids->{obrien}, uid => "O'Brien" }
                },
                'searchOn on a value containing a quote'
            );

            $res = $class->searchOn( $args, '_session_kind', 'SSO', '_utime' );
            is( $name->($res), 'dwho,obrien', 'searchOn on _session_kind' );

            $res = $class->searchOnExpr( $args, '_whatToTrace', '*t*' );
            is( $name->($res), 'rtyler', 'searchOnExpr without fields' );
        }
    );
    $group->(
        searchOnData => sub {
            my $res = $class->searchOn( $args, 'uid', 'dwho' );
            is( $res->{ $ids->{dwho} }->{mail},
                'dwho@badwolf.org',
                'searchOn without fields returns session data' );
            $res = $class->searchOnExpr( $args, 'uid', 'dw*' );
            is( $res->{ $ids->{dwho} }->{mail},
                'dwho@badwolf.org',
                'searchOnExpr without fields returns session data' );
        }
    );
    $group->(
        searchOnFields => sub {
            my $res =
              $class->searchOn( $args, 'uid', 'dwho', '_whatToTrace', 'uid' );
            is_deeply(
                $res,
                {
                    $ids->{dwho} => {
                        id           => $ids->{dwho},
                        _whatToTrace => 'dwho',
                        uid          => 'dwho'
                    }
                },
                'searchOn with fields keeps field name case'
            );
            $res =
              $class->searchOnExpr( $args, '_whatToTrace', '*t*',
                '_whatToTrace' );
            is_deeply(
                $res,
                {
                    $ids->{rtyler} =>
                      { id => $ids->{rtyler}, _whatToTrace => 'rtyler' }
                },
                'searchOnExpr with fields keeps field name case'
            );
        }
    );
    $group->(
        searchOnExprQuote => sub {
            my $res = $class->searchOnExpr( $args, 'uid', "O'Br*" );
            is( $name->($res), 'obrien',
                'searchOnExpr on a value containing a quote' );
        }
    );

    # searchLt / searchGt: sessions without the field are never returned.
    # "counter" is never indexed (Perl comparison with column backends)
    $group->(
        searchLt => sub {
            foreach (
                [ searchLt => _oidcRtUpdate => 200,     'dwho' ],
                [ searchGt => _oidcRtUpdate => 200,     'rtyler' ],
                [ searchLt => _oidcRtUpdate => 1000,    'dwho,nokind,rtyler' ],
                [ searchGt => _oidcRtUpdate => -1,      'dwho,nokind,rtyler' ],
                [ searchLt => _oidcRtUpdate => '200.5', 'dwho,nokind' ],
                [ searchGt => _oidcRtUpdate => '199.5', 'nokind,rtyler' ],
                [ searchLt => _utime        => 300,     'dwho,nokind,rtyler' ],
                [ searchGt => _utime        => 100,     'obrien' ],
                [ searchLt => counter       => 3,       'dwho,obrien' ],
                [ searchGt => counter       => 1,       'obrien,rtyler' ],
                [ searchGt => counter       => 0,       'dwho,obrien,rtyler' ],
                [ searchLt => unknown       => 1000,    '' ],
                [ searchGt => _oidcRtUpdate => ' 200 ', 'rtyler' ],
                [ searchGt => counter       => ' 2 ',   'rtyler' ],
              )
            {
                my ( $m, $f, $v, $expected ) = @$_;
                my $res = $class->$m( $args, $f, $v );
                is( $name->($res), $expected, "$m $f $v" );
            }
            $group->(
                searchOnData => sub {
                    my $res = $class->searchLt( $args, '_oidcRtUpdate', 200 );
                    is( $res->{ $ids->{dwho} }->{mail},
                        'dwho@badwolf.org',
                        'searchLt without fields returns session data' );
                    is( $res->{ $ids->{dwho} }->{_oidcRtUpdate},
                        150, 'searchLt without fields returns field value' );
                }
            );
            my $noId = sub {
                my ($h) = @_;
                return {
                    map { $_ eq 'id' ? () : ( $_ => $h->{$_} ) }
                      keys %$h
                };
            };
            foreach (
                [
                    'searchLt', '_oidcRtUpdate',
                    200,        'dwho',
                    [qw(uid _oidcRtUpdate)]
                ],
                [
                    'searchGt', '_utime',
                    100,        'obrien',
                    [qw(_whatToTrace _utime)]
                ],
                [ 'searchGt', 'counter', 2, 'rtyler', [qw(mail counter)] ],
              )
            {
                my ( $m, $f, $v, $s, $fields ) = @$_;
                my $res = $class->$m( $args, $f, $v, @$fields );
                is( $name->($res), $s, "$m $f $v with fields" );
                is_deeply(
                    $noId->( $res->{ $ids->{$s} } || {} ),
                    { map { ( $_ => $data{$s}->{$_} ) } @$fields },
                    "$m $f $v with fields returns these fields"
                );
            }
            foreach
              my $bad ( '200 OR 1=1', '1e3', '', ' ', undef, "\x{0661}", '2 0' )
            {
                ( my $label = $bad // 'undef' ) =~ s/[^ -~]/?/g;
                foreach my $m (qw(searchLt searchGt)) {
                    my $res =
                      $quiet->( sub { $class->$m( $args, '_utime', $bad ) } );
                    is_deeply( $res, {},
                        "$m with value '$label' returns nothing" );
                }
            }
        }
    );

    # Case and accent sensitive searches, on indexed and non indexed fields
    if ( $o{exact} ) {
        # Character string: DBD::mysql sends other strings in Latin-1, which
        # an utf8mb4 column rejects
        my $elodie = "\x{c9}lodie";
        utf8::upgrade($elodie);
        my $uid = $newSession->(
            %{ $data{dwho} },
            uid          => $elodie,
            _whatToTrace => $elodie,
        );
        foreach my $f (qw(_whatToTrace uid)) {
            my $res = $class->searchOn( $args, $f, 'DWHO' );
            is_deeply( $res, {}, "searchOn on $f is case sensitive" );
            $res = $class->searchOnExpr( $args, $f, 'DW*' );
            is_deeply( $res, {}, "searchOnExpr on $f is case sensitive" );
            foreach my $v (qw(elodie ELODIE)) {
                $res = $class->searchOn( $args, $f, $v );
                is_deeply( $res, {}, "searchOn on $f: $v doesn't match" );
                $res = $class->searchOnExpr( $args, $f, "$v*" );
                is_deeply( $res, {}, "searchOnExpr on $f: $v* doesn't match" );
            }

            $res = $class->searchOn( $args, $f, $elodie );
            is( $name->($res), $uid, "searchOn on $f: exact value found" );
        }
        $dbh->do( "DELETE FROM $table WHERE id=?", undef, $uid );
    }

    # get_key_from_all_sessions
    $group->(
        gkfas => sub {
            my $res = $class->get_key_from_all_sessions($args);
            is( $name->($res), 'dwho,nokind,obrien,rtyler',
                'get_key_from_all_sessions without argument' );
            is( $res->{ $ids->{rtyler} }->{mail},
                'rtyler@badwolf.org',
                'get_key_from_all_sessions returns session data' );

            $res = $class->get_key_from_all_sessions( $args,
                sub { $_[0]->{uid} eq 'dwho' ? $_[0]->{mail} : undef } );
            is_deeply(
                $res,
                { $ids->{dwho} => 'dwho@badwolf.org' },
                'get_key_from_all_sessions with a code ref'
            );
        }
    );
    $group->(
        gkfasArray => sub {
            my $fields = [ 'uid', '_utime' ];
            my $res    = $class->get_key_from_all_sessions( $args, $fields );
            is( $name->($res), 'dwho,nokind,obrien,rtyler',
                'get_key_from_all_sessions with an array ref' );
            is( $res->{ $ids->{obrien} }->{uid},
                "O'Brien",
                'get_key_from_all_sessions with an array ref returns data' );
            is_deeply(
                $fields,
                [ 'uid', '_utime' ],
                'Array ref is not modified'
            );
        }
    );
    $group->(
        gkfasField => sub {
            my $res =
              $class->get_key_from_all_sessions( $args, '_whatToTrace' );
            is_deeply(
                $res->{ $ids->{rtyler} },
                { id => $ids->{rtyler}, _whatToTrace => 'rtyler' },
                'get_key_from_all_sessions with a field name'
            );
        }
    );

    $group->(
        callerArray => sub {
            my $fields = [ 'uid', "x'y" ];
            {
                local *STDERR;
                my $err = '';
                open STDERR, '>', \$err;
                eval { $class->get_key_from_all_sessions( $args, $fields ) };
            }
            is_deeply(
                $fields,
                [ 'uid', "x'y" ],
                'Array ref with a quote is not modified'
            );
        }
    );
    # Mixed-case field with a false value
    my $zero = $newSession->( %{ $data{dwho} }, _whatToTrace => '0' );
    $group->(
        searchOnFields => sub {
            my $res = $class->searchOn( $args, 'uid', 'dwho', '_whatToTrace' );
            is( $res->{$zero}->{_whatToTrace},
                '0',
                'searchOn with fields keeps false value under original case' );
        }
    );
    $group->(
        gkfasArray => sub {
            my $res =
              $class->get_key_from_all_sessions( $args, ['_whatToTrace'] );
            is( $res->{$zero}->{_whatToTrace},
                '0',
                'get_key_from_all_sessions with array ref and false value' );
        }
    );
    $group->(
        gkfasField => sub {
            my $res =
              $class->get_key_from_all_sessions( $args, '_whatToTrace' );
            is( $res->{$zero}->{_whatToTrace},
                '0',
                'get_key_from_all_sessions with a field name and false value' );
        }
    );
    $dbh->do( "DELETE FROM $table WHERE id=?", undef, $zero );
    # Fields needing quotes
    foreach my $w (@weird) {
        $group->(
            weird => sub {
                my $res = $class->searchOn( $args, $w, 'w1', $w, 'uid' );
                is_deeply(
                    $res,
                    {
                        $ids->{dwho} =>
                          { id => $ids->{dwho}, $w => 'w1', uid => 'dwho' }
                    },
                    "searchOn on field [$w]"
                );
                $res = $class->searchOnExpr( $args, $w, 'w*', 'uid' );
                is( $name->($res), 'dwho,rtyler',
                    "searchOnExpr on field [$w]" );
            }
        );
        $group->(
            gkfasArray => sub {
                my $res =
                  $class->get_key_from_all_sessions( $args, [ $w, 'uid' ] );
                is( $res->{ $ids->{rtyler} }->{$w},
                    'w2', "get_key_from_all_sessions with field [$w]" );
            }
        );
    }
    if ( $o{json} ) {
        foreach my $w ( "x' OR '1'='1", 'x" OR "1"="1', "x`y" ) {
            $group->(
                fieldInjection => sub {
                    my $res = eval { $class->searchOn( $args, $w, 'w1', $w ) };
                    is_deeply( $res, {},
                        "searchOn on field [$w]: no injection" )
                      or diag $@;
                    $res = eval { $class->searchLt( $args, $w, 1000 ) };
                    is_deeply( $res, {},
                        "searchLt on field [$w]: no injection" )
                      or diag $@;
                }
            );
            $group->(
                gkfasArray => sub {
                    my $res =
                      eval { $class->get_key_from_all_sessions( $args, [$w] ); };
                    is( scalar( keys %{ $res || {} } ),
                        4, "get_key_from_all_sessions with field [$w]" )
                      or diag $@;
                }
            );
        }

        # Field names are case sensitive (MySQL/MariaDB column names aren't)
        $group->(
            fieldCase => sub {
                my $res = $class->searchOn( $args, '_WhatToTrace', 'dwho' );
                is_deeply( $res, {},
                    'searchOn: field names are case sensitive' );
                $res = $class->searchOnExpr( $args, '_WhatToTrace', 'dw*' );
                is_deeply( $res, {},
                    'searchOnExpr: field names are case sensitive' );
            }
        );
        $group->(
            gkfasArray => sub {
                my $res =
                  $class->get_key_from_all_sessions( $args, ['_WhatToTrace'] );
                is_deeply(
                    $res->{ $ids->{dwho} },
                    { id => $ids->{dwho}, _WhatToTrace => undef },
                    'get_key_from_all_sessions: field names are case sensitive'
                );
            }
        );
    }

    # Non-ASCII field names and values
    if ( $o{utf8} ) {
        my $uid = $newSession->(
            %{ $data{dwho} },
            uid          => "\x{c9}lodie",
            _whatToTrace => "\x{c9}lodie",
            cn           => "Zo\x{eb} \x{20ac}",
            "cl\x{e9}"   => 'v',
        );
        $group->(
            utf8 => sub {
                my $res =
                  $class->searchOn( $args, '_whatToTrace', "\x{c9}lodie",
                    'cn' );
                is_deeply(
                    $res,
                    { $uid => { id => $uid, cn => "Zo\x{eb} \x{20ac}" } },
                    'searchOn with non-ASCII value'
                );
                $res = $class->searchOn( $args, 'cn', "Zo\x{eb} \x{20ac}",
                    '_whatToTrace', "cl\x{e9}" );
                is_deeply(
                    $res,
                    {
                        $uid => {
                            id           => $uid,
                            _whatToTrace => "\x{c9}lodie",
                            "cl\x{e9}"   => 'v'
                        }
                    },
                    'searchOn with non-ASCII field name and value'
                );
            }
        );
        $group->(
            gkfasArray => sub {
                my $res = $class->get_key_from_all_sessions( $args,
                    [ 'cn', "cl\x{e9}" ] );
                is_deeply(
                    $res->{$uid},
                    {
                        id         => $uid,
                        cn         => "Zo\x{eb} \x{20ac}",
                        "cl\x{e9}" => 'v'
                    },
                    'get_key_from_all_sessions with non-ASCII field name'
                );
            }
        );
        $group->(
            utf8Read => sub {
                my $res = $class->get_key_from_all_sessions($args);
                is(
                    $res->{$uid}->{cn},
                    "Zo\x{eb} \x{20ac}",
                    'get_key_from_all_sessions returns non-ASCII value'
                );
            }
        );
        foreach (
            [ value => { _whatToTrace => "\x{c9}lodie" }, 'utf8' ],
            [
                'value (UTF-8 bytes)' => { _whatToTrace => "\xc3\x89lodie" },
                'utf8'
            ],
            [ 'field name' => { "cl\x{e9}" => 'v' }, 'deleteNot' ]
          )
        {
            my ( $l, $not, $key ) = @$_;

            # Other sessions don't have the field name: they must be deleted
            $group->(
                $key => sub {
                    my @r = $class->deleteIfLowerThan( $args,
                        { or => { _utime => 200 }, not => $not } );
                    is_deeply(
                        \@r,
                        [ 1, 3 ],
                        "deleteIfLowerThan \"not\" non-ASCII $l"
                    );
                    is(
                        $remaining->(),
                        join( ',', sort 'obrien', $uid ),
"deleteIfLowerThan \"not\" non-ASCII $l: right sessions kept"
                    );
                }
            );
            $reset->();
            $uid = $newSession->(
                %{ $data{dwho} },
                _whatToTrace => "\x{c9}lodie",
                "cl\x{e9}"   => 'v',
            );
        }
        $reset->();
    }

    # get_key_from_all_sessions reads sessions by batches
    {
        local $Apache::Session::Browseable::_common::BatchSize = 2;
        my $queries = 0;
        my $cdbh    = $class->_classDbh($args);
        local $cdbh->{Callbacks} =
          { ChildCallbacks => { execute => sub { $queries++; return } } };
        foreach my $n ( 4, 5 ) {
            $newSession->( uid => 'extra' ) if ( $n == 5 );
            $queries = 0;
            my $calls = 0;
            my $res   = $class->get_key_from_all_sessions( $args,
                sub { $calls++; $_[1] } );
            is( $calls, $n,
                "$n sessions by batches: callback called for each" );
            is( scalar( keys %$res ),
                $n, "$n sessions by batches: all returned" );
            is( $queries, 3, "$n sessions by batches: 3 queries" );
        }
        my $res = $class->get_key_from_all_sessions($args);
        is( scalar( keys %$res ), 5, 'Sessions by batches without callback' );
        $reset->();
    }

    # deleteIfLowerThan
    $group->(
        delete => sub {
            $reset->();
            my @r =
              $class->deleteIfLowerThan( $args, { or => { _utime => 200 } } );
            is_deeply(
                \@r,
                [ 1, 3 ],
                'deleteIfLowerThan "or": 3 sessions deleted'
            );
            is( $remaining->(), 'obrien',
                'deleteIfLowerThan "or": 1 session kept' );

            $reset->();
            @r = $class->deleteIfLowerThan( $args,
                { or => { _utime => 200, _lastSeen => 200 } } );
            is_deeply( \@r, [ 1, 4 ], 'deleteIfLowerThan "or" with 2 fields' );
        }
    );
    $group->(
        deleteAnd => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan( $args,
                { and => { _utime => 200, _lastSeen => 200 } } );
            is_deeply(
                \@r,
                [ 1, 2 ],
                'deleteIfLowerThan "and": 2 sessions deleted'
            );
            is( $remaining->(), 'obrien,rtyler',
                'deleteIfLowerThan "and": 2 kept' );
        }
    );
    $group->(
        deleteNot => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan(
                $args,
                {
                    or  => { _utime        => 200 },
                    not => { _session_kind => 'Persistent' }
                }
            );
            is_deeply(
                \@r,
                [ 1, 2 ],
                'deleteIfLowerThan "not": 2 sessions deleted'
            );
            is( $remaining->(), 'obrien,rtyler',
                'deleteIfLowerThan "not": session without field deleted' );
        }
    );
    $group->(
        deleteAndNot => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan(
                $args,
                {
                    and => { _utime        => 200, _lastSeen => 400 },
                    not => { _session_kind => 'Persistent' }
                }
            );
            is_deeply( \@r, [ 1, 2 ], 'deleteIfLowerThan "and" with "not"' );
            is( $remaining->(), 'obrien,rtyler',
                'deleteIfLowerThan "and" with "not": right sessions kept' );
        }
    );
    $group->(
        deleteNotQuote => sub {
            $reset->();
            my @r = $class->deleteIfLowerThan( $args,
                { or => { _utime => 400 }, not => { uid => "O'Brien" } } );
            is_deeply( \@r, [ 1, 3 ], 'deleteIfLowerThan "not" with a quote' );
            is( $remaining->(), 'obrien',
                'deleteIfLowerThan "not" with a quote' );

            $reset->();
            @r = $class->deleteIfLowerThan( $args,
                { or => { _utime => 200 }, not => { uid => "x' OR '1'='1" } } );
            is_deeply( \@r, [ 1, 3 ], 'deleteIfLowerThan "not": no injection' );
        }
    );
    $group->(
        ruleNotModified => sub {
            $reset->();
            my $rule =
              { or => { _utime => 400 }, not => { uid => "O'Brien" } };
            {
                # Some backends die here, only the rule matters
                local *STDERR;
                my $err = '';
                open STDERR, '>', \$err;
                eval { $class->deleteIfLowerThan( $args, $rule ) };
            }
            is( $rule->{not}->{uid}, "O'Brien", 'Rule is not modified' );
        }
    );

    # Corrupted session must not break listing
    if ( $o{corrupt} ) {
        $group->(
            corrupt => sub {
                $reset->();
                $dbh->do(
                    "INSERT INTO $table (id,a_session) VALUES ('corrupt',?)",
                    undef, $o{corrupt} );
                my $res;
                {
                    local *STDERR;
                    my $err = '';
                    open STDERR, '>', \$err;
                    $res = $class->get_key_from_all_sessions($args);
                }
                is( $name->($res), 'dwho,nokind,obrien,rtyler',
                    'get_key_from_all_sessions skips corrupted session' );
            }
        );
    }
    # Rules that can't be turned into SQL are rejected without exception;
    # an empty "not" is ignored
    $group->(
        deleteInvalid => sub {
            $reset->();
            my @r = eval {
                $class->deleteIfLowerThan( $args,
                    { not => { uid => 'dwho' } } );
            };
            is_deeply(
                \@r,
                [ 0, 0 ],
                'deleteIfLowerThan with only "not" returns 0'
            ) or diag $@;
            is( $remaining->(), 'dwho,nokind,obrien,rtyler',
                'Nothing deleted' );

            @r = $class->deleteIfLowerThan( $args,
                { or => { _utime => 200 }, not => {} } );
            is_deeply( \@r, [ 1, 3 ], 'deleteIfLowerThan with an empty "not"' );

            foreach my $bad ( 'x', [ _utime => 200 ], \'x' ) {
                my $label = ref($bad) || $bad;
                @r = $quiet->(
                    sub {
                        eval {
                            $class->deleteIfLowerThan( $args,
                                { or => { _utime => 200 }, not => $bad } );
                        };
                    }
                );
                is_deeply(
                    \@r,
                    [ 0, 0 ],
                    "\"not\" is not a hash ref ($label): returns 0"
                );
                @r = $quiet->(
                    sub {
                        eval { $class->deleteIfLowerThan( $args, $bad ) }
                    }
                );
                is_deeply(
                    \@r,
                    [ 0, 0 ],
                    "rule is not a hash ref ($label): returns 0"
                );
            }
            is( $remaining->(), 'obrien',
                'Invalid rule: only empty "not" deleted' );
        }
    );
    # A field stored as JSON null does not protect a session
    if ( $o{null} ) {
        $group->(
            deleteNull => sub {
                $reset->();
                my $nullId =
                  $newSession->( %{ $data{dwho} }, _session_kind => undef );
                my $json =
                  $dbh->selectrow_array(
                    "SELECT a_session FROM $table WHERE id=?",
                    undef, $nullId );
                like(
                    $json,
                    qr/"_session_kind"\s*:\s*null/,
                    'Session with a JSON null field created'
                );
                my @r = $class->deleteIfLowerThan(
                    $args,
                    {
                        or  => { _utime        => 200 },
                        not => { _session_kind => 'SSO' }
                    }
                );
                is_deeply(
                    \@r,
                    [ 1, 3 ],
                    'deleteIfLowerThan "not": JSON null deleted'
                );
                is( $remaining->(), 'dwho,obrien',
                    'deleteIfLowerThan "not": right sessions kept' );
            }
        );
    }

    # Thresholds are inserted into the query: they must be numbers
    $group->(
        deleteThresholds => sub {
            $reset->();
            foreach my $type (qw(or and)) {
                foreach my $bad ( '200 OR 1=1', '1e3', '', "\x{0661}" ) {
                    ( my $label = $bad ) =~ s/[^ -~]/?/g;
                    my @r = $quiet->(
                        sub {
                            eval {
                                $class->deleteIfLowerThan(
                                    $args,
                                    {
                                        $type =>
                                          { _utime => 400, _lastSeen => $bad }
                                    }
                                );
                            };
                        }
                    );
                    is_deeply(
                        \@r,
                        [ 0, 0 ],
                        "\"$type\" with threshold '$label' returns 0"
                    );
                }
            }
            is( $remaining->(), 'dwho,nokind,obrien,rtyler',
                'Nothing deleted' );

            my @r =
              $class->deleteIfLowerThan( $args,
                { or => { _utime => '100.5' } } );
            is_deeply(
                \@r,
                [ 1, 3 ],
                'deleteIfLowerThan with a decimal threshold'
            );
        }
    );

    # "not" on fields needing quotes. Sessions without the field must be
    # deleted too
    foreach my $w (@weird) {
        $group->(
            deleteNot => sub {
                $reset->();
                my @r = $class->deleteIfLowerThan( $args,
                    { or => { _utime => 400 }, not => { $w => 'w1' } } );
                is_deeply(
                    \@r,
                    [ 1, 3 ],
                    "deleteIfLowerThan \"not\" on field [$w]"
                );
                is( $remaining->(), 'dwho',
                    "deleteIfLowerThan \"not\" on field [$w]" );
            }
        );
    }

    # PostgreSQL with standard_conforming_strings=off: backslashes are escape
    # characters in plain string literals
    if ( $o{scs} ) {
        my $mdbh = $class->_classDbh($args);
        $mdbh->do('SET standard_conforming_strings = off');
        is( $mdbh->selectrow_array('SHOW standard_conforming_strings'),
            'off', 'standard_conforming_strings is off for the module' );
        my %isWeird = map { $_ => 1 } @weird;
        my @names = ( @weird, grep { !$isWeird{$_} } "x\\' OR '1'='1", 'x\\' );
        foreach my $w (@names) {
            my $found = $isWeird{$w};
            my $l     = "field [$w] (scs off)";
            $reset->();
            $group->(
                weird => sub {
                    my $res =
                      eval { $class->searchOn( $args, $w, 'w1', 'uid' ) };
                    diag $@ if $@;
                    is( $name->($res), $found ? 'dwho' : '', "searchOn on $l" );
                    $res =
                      eval { $class->searchOnExpr( $args, $w, 'w*', 'uid' ) };
                    diag $@ if $@;
                    is(
                        $name->($res),
                        $found ? 'dwho,rtyler' : '',
                        "searchOnExpr on $l"
                    );
                }
            );
            $group->(
                gkfasArray => sub {
                    my $res =
                      eval { $class->get_key_from_all_sessions( $args, [$w] ) };
                    diag $@ if $@;
                    is( scalar( keys %{ $res || {} } ),
                        4, "get_key_from_all_sessions on $l" );
                    is( $res->{ $ids->{rtyler} }->{$w},
                        'w2', "get_key_from_all_sessions value on $l" )
                      if ($found);
                }
            );
            $group->(
                deleteNot => sub {
                    my @r = eval {
                        $class->deleteIfLowerThan( $args,
                            { or => { _utime => 200 }, not => { $w => 'w1' } }
                        );
                    };
                    diag $@ if $@;
                    is_deeply(
                        \@r,
                        [ 1, $found ? 2 : 3 ],
                        "deleteIfLowerThan \"not\" on $l"
                    );
                    is(
                        $remaining->(),
                        $found ? 'dwho,obrien' : 'obrien',
                        "deleteIfLowerThan \"not\" on $l: right sessions kept"
                    );
                }
            );
        }
        $mdbh->do('SET standard_conforming_strings = on');
        is( $mdbh->selectrow_array('SHOW standard_conforming_strings'),
            'on', 'standard_conforming_strings is back on' );
    }

    # Identifiers are quoted: an indexed column named after a reserved word
    if ( my $w = $o{reserved} ) {
        $group->(
            reserved => sub {
                $reset->();
                my $id  = $newSession->( %{ $data{dwho} }, $w => 'r1' );
                my $res = $class->searchOn( $args, $w, 'r1', $w );
                is_deeply(
                    $res,
                    { $id => { id => $id, $w => 'r1' } },
                    "searchOn on column [$w]"
                );
                $res = $class->searchOnExpr( $args, $w, 'r*' );
                is( join( ',', keys %$res ),
                    $id, "searchOnExpr on column [$w]" );
                $res = $class->get_key_from_all_sessions( $args, [$w] );
                is( $res->{$id}->{$w},
                    'r1', "get_key_from_all_sessions with column [$w]" );
                $group->(
                    deleteNot => sub {
                        my @r = $class->deleteIfLowerThan( $args,
                            { or => { _utime => 200 }, not => { $w => 'r1' } }
                        );
                        is_deeply(
                            \@r,
                            [ 1, 3 ],
                            "deleteIfLowerThan with column [$w]"
                        );
                        is(
                            $remaining->(),
                            join( ',', sort 'obrien', $id ),
"deleteIfLowerThan with column [$w]: right sessions kept"
                        );
                    }
                );
            }
        );
    }

    # Table name in upper case: it must reach the table created without quotes
    if ( $o{tableCase} ) {
        $group->(
            tableCase => sub {
                $reset->();
                my $uargs = { %$args, TableName => uc($table) };
                my %session;
                tie %session, $class, undef, $uargs;
                $session{uid}    = 'upper';
                $session{_utime} = 100;
                my $id = $session{_session_id};
                untie %session;
                tie %session, $class, $id, $uargs;
                is( $session{uid}, 'upper', 'Upper case table: session read' );
                $session{mail} = 'upper@badwolf.org';
                untie %session;
                my $res = $class->searchOn( $uargs, 'uid', 'upper', 'uid' );
                is_deeply(
                    $res,
                    { $id => { id => $id, uid => 'upper' } },
                    'Upper case table: searchOn'
                );
                $res = $class->get_key_from_all_sessions($uargs);
                is( $res->{$id}->{mail},
                    'upper@badwolf.org',
                    'Upper case table: get_key_from_all_sessions' );
                my @r = $class->deleteIfLowerThan( $uargs,
                    { or => { _utime => 200 } } );
                is_deeply(
                    \@r,
                    [ 1, 4 ],
                    'Upper case table: deleteIfLowerThan'
                );
                is( $remaining->(), 'obrien',
                    'Upper case table: right sessions kept' );
            }
        );
    }

    # Queries must be able to use indexes
    if ( $o{explain} ) {

        # New table: rows deleted by previous tests may still be in indexes
        # and distort the optimizer estimates
        $create->() if ( $o{explain_fill} );
        $reset->();
        if ( $o{explain_fill} ) {
            $newSession->(
                uid           => "filler$_",
                _whatToTrace  => "filler$_",
                _session_kind => 'SSO',
                _utime        => 1000 + $_,
                _lastSeen     => 1000 + $_,
            ) foreach ( 1 .. $o{explain_fill} );
            $dbh->selectall_arrayref(
                ( $o{driver} eq 'Pg' ? 'ANALYZE' : 'ANALYZE TABLE' )
                . " $table" );
        }
        $dbh->do('SET enable_seqscan = off') if ( $o{driver} eq 'Pg' );

        # MySQL >= 8.3: JSON and TREE formats have no possible_keys column
        eval { $dbh->do('SET SESSION explain_format=TRADITIONAL') }
          if ( $o{driver} eq 'mysql' );
        foreach ( $o{explain}->( $class, $dbh, $args ) ) {
            my ( $desc, $where, $indexes, $statement ) = @$_;
            my @indexes =
              map { ( my $i = $_ ) =~ s/__TABLE__/$table/g; $i }
              ref($indexes) ? @$indexes : ($indexes);
            my $index = join ',', @indexes;
            $statement ||= 'SELECT id';
            my $sth =
              $dbh->prepare("EXPLAIN $statement FROM $table WHERE $where");
            $sth->execute;
            if ( $o{driver} eq 'Pg' ) {
                my $plan = join "\n",
                  map { $_->[0] } @{ $sth->fetchall_arrayref };
                my @missing = grep { $plan !~ /\b\Q$_\E\b/ } @indexes;
                ok( !@missing && $plan =~ /Index Cond/,
                    "$desc uses index $index" )
                  or diag "$where:\n$plan";
            }
            else {
                my $row     = $sth->fetchrow_hashref('NAME_lc');
                my $keys    = $row->{possible_keys} // '';
                my %keys    = map  { $_ => 1 } split /,/, $keys;
                my @missing = grep { !$keys{$_} } @indexes;
                ok( !@missing, "$desc can use index $index" )
                  or diag "$where: possible_keys=$keys";
                if ( $o{explain_key} ) {

                    # The optimizer may combine indexes (index_merge), so the
                    # expected ones must be included in key, not equal it
                    my %used    = map  { $_ => 1 } split /,/, $row->{key} // '';
                    my @missing = grep { !$used{$_} } @indexes;
                    ok( !@missing && ( $row->{type} // '' ) ne 'ALL',
                        "$desc uses index $index" )
                      or diag "$where: key="
                      . ( $row->{key} // '' )
                      . " type="
                      . ( $row->{type} // '' );
                }
                $sth->finish;
            }
        }
        $dbh->do('RESET enable_seqscan') if ( $o{driver} eq 'Pg' );
    }

    $drop->();
    $dbh->disconnect;
    done_testing();
}

1;
