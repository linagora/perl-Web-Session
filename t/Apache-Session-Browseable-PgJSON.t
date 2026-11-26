use strict;
use lib 't/lib';
use SQLBackendTests;

run_tests(
    class  => 'Apache::Session::Browseable::PgJSON',
    driver => 'Pg',
    env    => 'PG',
    table  => 'asb_test_pgjson',
    create => [
'CREATE TABLE __TABLE__ (id varchar(64) not null primary key, a_session jsonb)'
    ],
    null => 1,
    json  => 1,
    weird => [ "weird'field", 'a"b\\c', 'a?b', 'x\\' ],
    scs   => 1,
    todo => {
    },
);
