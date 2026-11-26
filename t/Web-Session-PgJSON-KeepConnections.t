use strict;
use lib 't/lib';
use SQLBackendTests;

# The PgJSON tests with the connection pool of Web::Session::Store::Postgres
run_tests(
    class  => 'Web::Session::PgJSON',
    driver => 'Pg',
    env    => 'PG',
    table  => 'asb_test_pgjson_keep',
    create => [
'CREATE TABLE __TABLE__ (id varchar(64) not null primary key, a_session jsonb)',
    ],
    args      => { KeepConnections => 1, MaxIdle => 2 },
    null      => 1,
    json      => 1,
    weird     => [ "weird'field", 'a"b\\c', 'a?b', 'x\\' ],
    scs       => 1,
    tableCase => 1,
    todo      => {},
);
