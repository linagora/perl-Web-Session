use strict;
use warnings;
use Test::More;

my $class = 'Web::Session::Redis';

plan skip_all => 'Redis module is needed' unless eval "require $class";
plan skip_all => 'REDIS_URL is not set' unless $ENV{REDIS_URL};

# Not the databases of the other Redis tests, to run them in parallel
my $args = {
    server      => $ENV{REDIS_URL},
    database    => ( ( $ENV{REDIS_DBNUM} || 15 ) + 10 ) % 16,
    Index       => 'uid _utime',
    utimeOffset => 3600,
};
my %noOffset = ( %$args, utimeOffset => undef );
my $redis    = $class->_getRedis($args);
$redis->flushdb;
plan skip_all => 'utimeOffset needs Redis >= 7.4 or Valkey >= 9'
  unless eval { $redis->hset( 'h', 'f', 1 ); $redis->hexpire( 'h', 10, 'FIELDS', 1, 'f' ); 1 };
$redis->flushdb;

sub newSession {
    my ( $a, %data ) = @_;
    my %session;
    tie %session, $class, undef, $a;
    $session{$_} = $data{$_} foreach ( keys %data );
    my $id = $session{_session_id};
    untie %session;
    return $id;
}

sub fieldTtl {
    my ( $hash, $id ) = @_;
    return ( $redis->httl( $hash, 'FIELDS', 1, $id ) )[0];
}

my $now = time;

# Expiration of sessions and of their index entries
my $sso = newSession( $args, uid => 'dwho', _utime => $now );
ok( abs( $redis->ttl($sso) - 3600 ) <= 2, 'session: _utime + utimeOffset' );
ok( abs( fieldTtl( 'hidx:uid_dwho', $sso ) - 3600 ) <= 2,
    'index entry: same expiration' );
ok( !$redis->exists('uid_dwho'), 'index set not used' );

my $oidc = newSession(
    $args,
    uid           => 'dwho',
    _utime        => $now + 86400 - 3600,
    _session_kind => 'OIDCI'
);
ok( abs( $redis->ttl($oidc) - 86400 ) <= 2,
    'shifted _utime: expiration of Lemonldap::NG' );
ok( abs( fieldTtl( 'hidx:uid_dwho', $oidc ) - 86400 ) <= 2,
    'shifted _utime: index entry' );

my $ps = newSession(
    $args,
    uid           => 'dwho',
    _utime        => $now,
    _session_kind => 'Persistent'
);
is( $redis->ttl($ps), -1, 'persistent session: no expiration' );
ok( $redis->sismember( 'uid_dwho', $ps ), 'persistent session: index set' );
ok( !$redis->hexists( 'hidx:uid_dwho', $ps ),
    'persistent session: not in index hash' );

# A session stored before utimeOffset was set leaves its set when rewritten
my $legacy = newSession( \%noOffset, uid => 'dwho', _utime => $now );
ok( $redis->sismember( 'uid_dwho', $legacy ), 'legacy session: index set' );
is( keys %{ $class->searchOn( $args, 'uid', 'dwho' ) },
    4, 'searchOn: sets and hashes read' );
is( keys %{ $class->searchOnExpr( $args, 'uid', 'dw*' ) },
    4, 'searchOnExpr: sets and hashes read' );
is( keys %{ $class->searchGt( $args, '_utime', $now - 1 ) },
    4, 'searchGt: sets and hashes read' );
{
    my %s;
    tie %s, $class, $legacy, $args;
    $s{uid} = 'rtyler';
    untie %s;
}
ok( !$redis->sismember( 'uid_dwho', $legacy ), 'rewritten: old value removed' );
ok( $redis->hexists( 'hidx:uid_rtyler', $legacy ), 'rewritten: index hash' );
ok( !$redis->sismember( "_utime_$now", $legacy ),
    'rewritten: same value moved to the index hash' );
ok( $redis->hexists( "hidx:_utime_$now", $legacy ),
    'rewritten: same value in index hash' );

# Expired by Redis: no orphan left
my $short = newSession( $args, uid => 'short', _utime => time - 3600 + 4 );
ok( $redis->hexists( 'hidx:uid_short', $short ), 'short session indexed' );
sleep 6;
ok( !$redis->exists($short),           'short session expired' );
ok( !$redis->exists('hidx:uid_short'), 'its index hash expired too' );
is_deeply( $class->searchOn( $args, 'uid', 'short' ), {},
    'expired session not found' );

# Orphan index entries in hashes are removed by searches
{
    my $orphan = 'f' x 64;
    foreach my $h ( 'hidx:uid_dwho', "hidx:_utime_$now" ) {
        $redis->hset( $h, $orphan, 1 );
        $redis->hexpire( $h, 3600, 'FIELDS', 1, $orphan );
    }
    is( keys %{ $class->searchOn( $args, 'uid', 'dwho' ) },
        3, 'searchOn: orphan skipped' );
    ok( !$redis->hexists( 'hidx:uid_dwho', $orphan ), 'searchOn: orphan removed' );
    $redis->hset( 'hidx:uid_dwho', $orphan, 1 );
    is( keys %{ $class->searchOnExpr( $args, 'uid', 'dw*' ) },
        3, 'searchOnExpr: orphan skipped' );
    ok( !$redis->hexists( 'hidx:uid_dwho', $orphan ),
        'searchOnExpr: orphan removed' );
    $class->searchGt( $args, '_utime', $now - 1 );
    ok( !$redis->hexists( "hidx:_utime_$now", $orphan ),
        'searchGt: orphan removed' );
}

# A session that stops expiring moves to the index set
{
    my $id = newSession( $args, uid => 'moving', _utime => $now );
    my %s;
    tie %s, $class, $id, $args;
    delete $s{_utime};
    $s{x} = 1;
    untie %s;
    is( $redis->ttl($id), -1, 'no _utime anymore: no expiration' );
    ok( $redis->sismember( 'uid_moving', $id ), 'no _utime: index set' );
    ok( !$redis->exists('hidx:uid_moving'), 'no _utime: index hash left' );
    tie %s, $class, $id, $args;
    tied(%s)->delete;
}

# A failed command doesn't leave the connection in the transaction
{
    $redis->set( 'uid_bad', 'not a set' );
    my %s;
    tie %s, $class, undef, $args;
    @s{qw(uid _session_kind)} = ( 'bad', 'Persistent' );
    ok( !eval { tied(%s)->save; 1 }, 'WRONGTYPE: write fails' );
    like( $@, qr/^\[sadd\] WRONGTYPE/, 'WRONGTYPE: error' );
    tied(%s)->{status} = 0;
    untie %s;
    $redis->del('uid_bad');
    ok( newSession( $args, uid => 'after', _utime => $now ),
        'next write succeeds' );
    is( $redis->ping, 'PONG', 'connection not in a transaction' );
}

# Removal and purge
{
    my %s;
    tie %s, $class, $oidc, $args;
    tied(%s)->delete;
}
ok( !$redis->hexists( 'hidx:uid_dwho', $oidc ), 'delete: index entry removed' );
my @r = $class->deleteIfLowerThan( $args,
    { or => { _utime => $now + 1 }, not => { _session_kind => 'Persistent' } } );
is_deeply( \@r, [ 1, 3 ], 'purge: sessions deleted' );
ok( !$redis->exists('hidx:uid_dwho'),   'purge: index hash emptied' );
ok( !$redis->exists('hidx:uid_rtyler'), 'purge: rewritten session removed' );
is_deeply( [ $redis->smembers('uid_dwho') ], [$ps],
    'purge: persistent session kept' );

# Removing utimeOffset: sessions re-saved as documented are found again
{
    $redis->flushdb;
    my $id = newSession( $args, uid => 'dwho', _utime => $now );
    is_deeply( $class->searchOn( \%noOffset, 'uid', 'dwho' ),
        {}, 'without utimeOffset: index hashes not read' );
    my $all =
      $class->get_key_from_all_sessions( \%noOffset, sub { 1 } );
    foreach my $id ( keys %$all ) {
        tie my %s, $class, $id, \%noOffset;
        $s{_session_id} = $s{_session_id};
        untie %s;
    }
    is_deeply( [ keys %{ $class->searchOn( \%noOffset, 'uid', 'dwho' ) } ],
        [$id], 'without utimeOffset: re-saved session found' );
}

$redis->flushdb;
done_testing();
