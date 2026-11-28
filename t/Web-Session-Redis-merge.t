use strict;
use warnings;
use Test::More;
use POSIX ();

# Two ties of the same session updated concurrently: the changes of both are
# kept, with Lua, with the WATCH/MULTI fallback and with index hashes

plan skip_all => 'REDIS_URL is not set' unless ( $ENV{REDIS_URL} );

my $package = 'Web::Session::Redis';
plan skip_all => 'Redis module is needed' unless eval "require $package";

my $base = {
    server   => $ENV{REDIS_URL},
    # Not the databases of the other Redis tests, to run them in parallel
    database => ( ( $ENV{REDIS_DBNUM} || 15 ) + 9 ) % 16,
    Index    => 'uid',
};
my $r = eval { $package->_getRedis($base) };
plan skip_all => "Redis error: $@" unless ($r);
$r->flushdb;

my @warnings;
$SIG{__WARN__} = sub { push @warnings, @_ };

sub newSession {
    my ( $args, %data ) = @_;
    my %s;
    tie %s, $package, undef, $args;
    $s{$_} = $data{$_} foreach ( keys %data );
    my $id = $s{_session_id};
    untie %s;
    return $id;
}

sub stored {
    my ($id) = @_;
    my $v = $r->get($id);
    return defined $v ? Web::Session::Redis::unserialize($v) : undef;
}

# Index set, or index hash with utimeOffset: 1 if $id is indexed with $value
sub indexed {
    my ( $value, $id ) = @_;
    return ( $r->sismember( "uid_$value", $id )
          or $r->hexists( "hidx:uid_$value", $id ) ) ? 1 : 0;
}

sub commandCalls {
    my ($cmd) = @_;
    my $info = $r->info('commandstats');
    return ref($info)
      ? ( ( $info->{"cmdstat_$cmd"} // '' ) =~ /calls=(\d+)/ )[0] // 0
      : 0;
}

sub cases {
    my ( $name, $args ) = @_;

    # Different keys changed, one deleted
    my $id = newSession( $args, uid => 'dwho', z => 1, _utime => time );
    my ( %a, %b );
    tie %a, $package, $id, $args;
    tie %b, $package, $id, $args;
    $b{x} = 'bx';
    untie %b;
    $a{y} = 'ay';
    delete $a{z};
    @warnings = ();
    untie %a;
    my $s = stored($id);
    is( $s->{x}, 'bx', "$name: key set by B kept" );
    is( $s->{y}, 'ay', "$name: key set by A kept" );
    ok( !exists $s->{z}, "$name: key deleted by A stays deleted" );
    is( $s->{_session_id}, $id, "$name: _session_id kept" );
    is( indexed( 'dwho', $id ), 1, "$name: index kept" );
    is_deeply( \@warnings, [], "$name: no warning" );
    if ( $args->{TTL} or $args->{utimeOffset} ) {
        cmp_ok( $r->ttl($id), '>', 0, "$name: TTL kept" );
    }
    else {
        is( $r->ttl($id), -1, "$name: no TTL" );
    }

    # Key deleted by B, A changes another one
    tie %a, $package, $id, $args;
    tie %b, $package, $id, $args;
    delete $b{x};
    untie %b;
    $a{y} = 'ay2';
    untie %a;
    $s = stored($id);
    ok( !exists $s->{x}, "$name: key deleted by B stays deleted" );
    is( $s->{y}, 'ay2', "$name: A's change kept" );

    # Same key changed by both: the last write wins
    tie %a, $package, $id, $args;
    tie %b, $package, $id, $args;
    $a{color} = 'blue';
    $b{color} = 'red';
    untie %b;
    untie %a;
    is( stored($id)->{color}, 'blue', "$name: same key, last write wins" );

    # Indexed field changed by B, A changes another key
    tie %a, $package, $id, $args;
    tie %b, $package, $id, $args;
    $b{uid} = 'rtyler';
    untie %b;
    $a{other} = 1;
    untie %a;
    $s = stored($id);
    is( $s->{uid},   'rtyler', "$name: indexed value changed by B kept" );
    is( $s->{other}, 1,        "$name: A's change kept with B's uid" );
    is( indexed( 'rtyler', $id ), 1, "$name: new uid indexed" );
    is( indexed( 'dwho',   $id ), 0, "$name: old uid removed" );
    is_deeply( [ keys %{ $package->searchOn( $args, 'uid', 'rtyler' ) } ],
        [$id], "$name: searchOn finds the new uid" );

    # Indexed field changed by A, B changes another key
    tie %a, $package, $id, $args;
    tie %b, $package, $id, $args;
    $a{uid} = 'dwho';
    $b{b} = 'bb';
    untie %b;
    untie %a;
    $s = stored($id);
    is( $s->{uid}, 'dwho', "$name: indexed value changed by A" );
    is( $s->{b},   'bb',   "$name: B's change kept with A's uid" );
    is( indexed( 'dwho',   $id ), 1, "$name: A's uid indexed" );
    is( indexed( 'rtyler', $id ), 0, "$name: B's uid removed" );

    # Three ties: two merges
    my %c;
    tie %a, $package, $id, $args;
    tie %b, $package, $id, $args;
    tie %c, $package, $id, $args;
    $a{n1} = 1;
    $b{n2} = 2;
    $c{n3} = 3;
    untie %c;
    untie %b;
    untie %a;
    $s = stored($id);
    is_deeply( [ @$s{qw(n1 n2 n3)} ], [ 1, 2, 3 ], "$name: three updates" );

    # Saved twice in the same tie, with a concurrent update in between
    tie %a, $package, $id, $args;
    $a{s1} = 1;
    tied(%a)->save;
    tie %b, $package, $id, $args;
    $b{s2} = 2;
    untie %b;
    $a{s3} = 3;
    untie %a;
    $s = stored($id);
    is_deeply( [ @$s{qw(s1 s2 s3)} ], [ 1, 2, 3 ], "$name: second save" );

    # New session changed in the tie that created it
    my %n;
    tie %n, $package, undef, $args;
    $n{uid} = 'new';
    my $nid = $n{_session_id};
    untie %n;
    is( stored($nid)->{uid}, 'new', "$name: new session written" );
    is( indexed( 'new', $nid ), 1, "$name: new session indexed" );

    # Deleted by B: not written back by A
    tie %a, $package, $id, $args;
    tie %b, $package, $id, $args;
    $a{color} = 'green';
    tied(%b)->delete;
    untie %b;
    @warnings = ();
    untie %a;
    ok( !$r->exists($id), "$name: deleted session not written back" );
    is( indexed( 'dwho', $id ), 0, "$name: not indexed again" );
    is( scalar( grep { /\Q$id\E/ } @warnings ), 1, "$name: warning" );

    # Deleted by B after a conflict with C
    $id = newSession( $args, uid => 'dwho' );
    tie %a, $package, $id, $args;
    tie %c, $package, $id, $args;
    $c{x} = 1;
    untie %c;
    $a{y} = 1;
    $r->del($id);
    untie %a;
    ok( !$r->exists($id), "$name: expired session not written back" );

    $r->flushdb;
}

foreach my $ttl ( undef, 100 ) {
    my $args = { %$base, ( $ttl ? ( TTL => $ttl ) : () ) };
    my $name = $ttl ? 'Lua, TTL' : 'Lua';
    my $evals = commandCalls('eval');
    cases( $name, $args );
  SKIP: {
        skip 'INFO commandstats unavailable', 1 unless ( commandCalls('get') );
        cmp_ok( commandCalls('eval'), '>', $evals, "$name: EVAL used" );
    }
}

# EVAL refused (ACL, proxy): WATCH/MULTI/EXEC
foreach my $ttl ( undef, 100 ) {
    my $args = { %$base, ( $ttl ? ( TTL => $ttl ) : () ) };
    my $name   = $ttl ? 'Without Lua, TTL' : 'Without Lua';
    my $client = do { no warnings "once"; $Web::Session::Store::Redis::redis };
    my $refused = 0;
    my $execs   = commandCalls('exec');
    my $stderr;
    {
        no strict 'refs';
        no warnings 'redefine';
        local *{"${client}::eval"} = sub { $refused++; die "NOPERM test\n" };
        open my $fh, '>', \$stderr;
        local *STDERR = $fh;
        cases( $name, $args );
    }
    ok( $refused, "$name: EVAL refused" );
    like( $stderr // '', qr/EVAL failed/, "$name: reported" )
      unless ($ttl);
  SKIP: {
        skip 'INFO commandstats unavailable', 1 unless ( commandCalls('get') );
        cmp_ok( commandCalls('exec'), '>', $execs, "$name: EXEC used" );
    }
}

# utimeOffset with Index: the check is part of the MULTI transaction
SKIP: {
    skip 'utimeOffset needs Redis >= 7.4 or Valkey >= 9', 1
      unless eval {
        $r->hset( 'h', 'f', 1 );
        $r->hexpire( 'h', 10, 'FIELDS', 1, 'f' );
        $r->del('h');
        1;
      };
    my $hargs = { %$base, utimeOffset => 3600 };
    foreach my $ttl ( undef, 100 ) {
        my $args = { %$hargs, ( $ttl ? ( TTL => $ttl ) : () ) };
        my $name = $ttl ? 'Index hashes, TTL' : 'Index hashes';
        my $execs = commandCalls('exec');
        my $cas   = 0;
        {
            no warnings 'redefine';
            my $orig = \&Web::Session::Store::Redis::_compareAndSet;
            local *Web::Session::Store::Redis::_compareAndSet =
              sub { $cas++; goto &$orig };
            cases( $name, $args );
        }
        is( $cas, 0, "$name: no Lua nor separate check" );
      SKIP: {
            skip 'INFO commandstats unavailable', 1
              unless ( commandCalls('get') );
            cmp_ok( commandCalls('exec'), '>', $execs, "$name: EXEC used" );
        }
    }

    # time() may change during the test
    my $near = sub { ok( abs( $_[0] - $_[1] ) <= 2, $_[2] ) };
    my $now  = time;
    my $id   = newSession( $hargs, uid => 'dwho', _utime => $now );
    my ( %a, %b );
    tie %a, $package, $id, $hargs;
    tie %b, $package, $id, $hargs;
    $b{uid}    = 'rtyler';
    $b{_utime} = $now + 1000;
    untie %b;
    $a{x} = 1;
    @warnings = ();
    untie %a;
    my $s = stored($id);
    is_deeply( [ @$s{qw(uid _utime x)} ], [ 'rtyler', $now + 1000, 1 ],
        'Index hashes: disjoint changes kept' );
    is( $r->hexists( 'hidx:uid_rtyler', $id ), 1, 'Index hashes: new uid' );
    is( $r->hexists( 'hidx:uid_dwho', $id ),
        0, 'Index hashes: old uid removed' );
    ok( !$r->exists('uid_rtyler') && !$r->exists('uid_dwho'),
        'Index hashes: no index set' );
    $near->( $r->ttl($id), 4600, 'Index hashes: TTL of the merge' );
    $near->(
        ( $r->httl( 'hidx:uid_rtyler', 'FIELDS', 1, $id ) )[0],
        4600, 'Index hashes: index entry expires with the session'
    );
    is_deeply( \@warnings, [], 'Index hashes: no warning' );

    # uid changed by A, _utime by B
    tie %a, $package, $id, $hargs;
    tie %b, $package, $id, $hargs;
    $a{uid}    = 'dwho';
    $b{_utime} = $now + 2000;
    untie %b;
    untie %a;
    $s = stored($id);
    is_deeply( [ @$s{qw(uid _utime)} ], [ 'dwho', $now + 2000 ],
        "Index hashes: A's uid, B's _utime" );
    is( $r->hexists( 'hidx:uid_dwho', $id ), 1, "Index hashes: A's uid" );
    is( $r->hexists( 'hidx:uid_rtyler', $id ),
        0, "Index hashes: B's uid removed" );
    $near->( $r->ttl($id), 5600, "Index hashes: TTL of B's _utime" );
    $near->(
        ( $r->httl( 'hidx:uid_dwho', 'FIELDS', 1, $id ) )[0],
        5600, "Index hashes: index entry TTL of B's _utime"
    );

    # Updated by B between the GET and the EXEC of A: EXEC aborted by WATCH
    {
        my $client =
          do { no warnings "once"; $Web::Session::Store::Redis::redis };
        my $get = $client->can('get');
        my $nid    = newSession( $hargs, uid => 'dwho', _utime => $now );
        tie %a, $package, $nid, $hargs;
        $a{x} = 'a';
        my ( $updated, $aborted ) = ( 0, 0 );
        {
            no strict 'refs';
            no warnings 'redefine';
            my $write = \&Web::Session::Store::Redis::_writeHashIndex;
            local *Web::Session::Store::Redis::_writeHashIndex = sub {
                my $res = $write->(@_);
                $aborted++ unless ( defined $res );
                return $res;
            };
            local *{"${client}::get"} = sub {
                my @res = $get->(@_);
                if ( $_[1] eq $nid and !$updated++ ) {
                    tie %b, $package, $nid, $hargs;
                    $b{uid} = 'rtyler';
                    untie %b;
                }
                return wantarray ? @res : $res[0];
            };
            untie %a;
        }
        is( $aborted, 1, 'Index hashes, EXEC aborted once' );
        $s = stored($nid);
        is_deeply( [ @$s{qw(uid x)} ], [ 'rtyler', 'a' ],
            'Index hashes, EXEC aborted: both changes kept' );
        is( $r->hexists( 'hidx:uid_rtyler', $nid ),
            1, 'Index hashes, EXEC aborted: new uid' );
        is( $r->hexists( 'hidx:uid_dwho', $nid ),
            0, 'Index hashes, EXEC aborted: old uid removed' );
        tie %a, $package, $nid, $hargs;
        tied(%a)->delete;
    }

    # Deleted by B: neither recreated nor indexed
    tie %a, $package, $id, $hargs;
    tie %b, $package, $id, $hargs;
    $a{color} = 'green';
    tied(%b)->delete;
    untie %b;
    @warnings = ();
    untie %a;
    ok( !$r->exists($id), 'Index hashes: deleted session not written back' );
    ok( !$r->exists('hidx:uid_dwho'), 'Index hashes: no index entry' );
    is( scalar( grep { /\Q$id\E/ } @warnings ), 1, 'Index hashes: warning' );
    $r->flushdb;
}

# Lemonldap::NG's local cache provides an older version instead of materialize
{
    my $id     = newSession( $base, uid => 'dwho', a => 1 );
    my $cached = $r->get($id);
    my ( %a, %b );
    tie %b, $package, $id, $base;
    $b{b} = 2;
    untie %b;
    {
        no warnings qw(once redefine);
        local *Web::Session::Store::Redis::materialize =
          sub { $_[1]->{serialized} = $cached };
        tie %a, $package, $id, $base;
    }
    $a{c} = 3;
    tied(%a)->save;
    is( tied(%a)->{web_session_redis_update}, 'merged', 'Cache: merged' );
    is( tied(%a)->{serialized}, $r->get($id), 'Cache: version stored' );
    untie %a;
    my $s = stored($id);
    is_deeply( [ @$s{qw(a b c)} ], [ 1, 2, 3 ], 'Cache: both changes kept' );
    $r->flushdb;
}

# Two processes: B writes while A holds the session tied
{
    my $id = newSession( $base, uid => 'dwho' );
    pipe( my $tiedR, my $tiedW ) or die $!;
    pipe( my $goR,   my $goW )   or die $!;
    my $pid = fork;
    die "fork: $!" unless ( defined $pid );
    unless ($pid) {
        close $tiedR;
        close $goW;
        my $ok = eval {
            my %a;
            tie %a, $package, $id, $base;
            syswrite $tiedW, "1";
            sysread $goR, my $buf, 1;
            $a{fromChild} = 'a';
            untie %a;
            1;
        };
        POSIX::_exit( $ok ? 0 : 1 );
    }
    close $tiedW;
    close $goR;
    sysread $tiedR, my $buf, 1;
    my %b;
    tie %b, $package, $id, $base;
    $b{fromParent} = 'b';
    $b{uid}        = 'rtyler';
    untie %b;
    syswrite $goW, "1";
    waitpid( $pid, 0 );
    is( $?, 0, 'Fork: child updated the session' );
    my $s = stored($id);
    is( $s->{fromChild},  'a',      'Fork: child change kept' );
    is( $s->{fromParent}, 'b',      'Fork: parent change kept' );
    is( $s->{uid},        'rtyler', 'Fork: indexed value kept' );
    is( indexed( 'rtyler', $id ), 1, 'Fork: new uid indexed' );
    is( indexed( 'dwho',   $id ), 0, 'Fork: old uid removed' );
    $r->flushdb;
}

done_testing();
