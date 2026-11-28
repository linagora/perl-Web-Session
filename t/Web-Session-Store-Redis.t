use strict;
use warnings;
use Test::More;

# Lets the HEXPIRE probe cache be tested across time
our $fakeTime;
BEGIN { *CORE::GLOBAL::time = sub () { $main::fakeTime // CORE::time } }

# Store::Redis::update with a mock Redis object (no server needed)
package MockRedis;
sub new { bless { calls => [] }, shift }

sub AUTOLOAD {
    my $self = shift;
    our $AUTOLOAD;
    ( my $m = $AUTOLOAD ) =~ s/.*:://;
    return if $m eq 'DESTROY';
    push @{ $self->{calls} }, [ $m, @_ ];
    return;
}

package main;

plan skip_all => 'Redis module is needed'
  unless eval { require Web::Session::Store::Redis; 1 };

sub run {
    my ( $index, %extra ) = @_;
    my $store = bless { cache => MockRedis->new },
      'Web::Session::Store::Redis';
    my $unserialized = 0;
    $store->update(
        {
            data       => { _session_id => 'id1', uid => 'dwho' },
            serialized => '{}',
            args       => { Index => $index, %extra },
            unserialize => sub { $unserialized++ },
        }
    );
    return ( $store->{cache}->{calls}, $unserialized );
}

my ( $calls, $unser ) = run('');
is_deeply( $calls, [ [ 'set', 'id1', '{}' ] ],
    'Without index: session written, no read' );
is( $unser, 0, 'Without index: old session not decoded' );

( $calls, $unser ) = run( '', TTL => 10 );
is_deeply( $calls, [ [ 'set', 'id1', '{}', 'EX', 10 ] ],
    'Without index: TTL is kept' );

( $calls, $unser ) = run( [] );
is_deeply( $calls, [ [ 'set', 'id1', '{}' ] ], 'Empty index list' );

( $calls, $unser ) = run('uid');
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(get set sadd)],
    'With index: old session read, index updated'
);

# utimeOffset: expiration computed from _utime
sub ttl {
    my ( $data, %args ) = @_;
    return Web::Session::Store::Redis::_ttl(
        { data => $data, args => \%args } );
}
my $now = time;
# time() may change during the test
sub near { ok( abs( $_[0] - $_[1] ) <= 1, $_[2] ) }
near( ttl( { _utime => $now }, utimeOffset => 3600 ),
    3600, 'utimeOffset: _utime + offset' );
near( ttl( { _utime => $now + 600 }, utimeOffset => 3600 ),
    4200, 'utimeOffset: _utime in the future (shifted by Lemonldap::NG)' );
is( ttl( { _utime => $now - 7200 }, utimeOffset => 3600 ),
    1, 'utimeOffset: expired session kept 1 second' );
near( ttl( { _utime => "$now.5" }, utimeOffset => 10 ),
    10, 'utimeOffset: decimal _utime' );
near( ttl( { _utime => $now }, utimeOffset => 3600, TTL => 10 ),
    3600, 'utimeOffset: preferred to TTL' );
is( ttl( { _utime => 'abc' }, utimeOffset => 3600, TTL => 10 ),
    10, 'utimeOffset: invalid _utime falls back to TTL' );
is( ttl( {}, utimeOffset => 3600 ), undef, 'utimeOffset: no _utime, no TTL' );
is(
    ttl(
        { _utime => $now, _session_kind => 'Persistent' },
        utimeOffset => 3600
    ),
    undef,
    'utimeOffset: persistent sessions never expire'
);
is(
    ttl(
        { _utime => $now, _session_kind => 'Persistent' },
        utimeOffset => 3600,
        TTL         => 10
    ),
    10,
    'utimeOffset: persistent sessions keep TTL'
);
is( ttl( { _utime => $now }, utimeOffset => '', TTL => 10 ),
    10, 'utimeOffset: empty value ignored' );
is( ttl( { _utime => $now }, utimeOffset => 0 ),
    undef, 'utimeOffset: 0 disables it' );
is( ttl( { _utime => $now }, utimeOffset => '00' ),
    undef, "utimeOffset: '00' disables it" );

# utimeOffset: session and index entries written in one pipelined transaction
{

    package MockTx;
    our ( %queueErr, %execErr, %croak, $execReply );
    sub new { bless { calls => [], cbs => [] }, shift }

    sub AUTOLOAD {
        my $self = shift;
        our $AUTOLOAD;
        ( my $m = $AUTOLOAD ) =~ s/.*:://;
        return if $m eq 'DESTROY';
        my $cb = ref( $_[-1] ) eq 'CODE' ? pop : undef;
        push @{ $self->{calls} }, [ $m, @_ ];
        die "[$m] Not connected\n" if ( $croak{$m} );
        return unless ($cb);
        my $n = grep { $_->[0] !~ /^(?:multi|exec)$/ } @{ $self->{calls} };
        push @{ $self->{cbs} }, sub {
            if ( $m eq 'exec' ) {
                return $cb->($execReply) if ($execReply);
                return $cb->( undef, 'EXECABORT Transaction discarded' )
                  if ( grep { $queueErr{ $_->[0] } } @{ $self->{calls} } );
                $cb->(
                    [
                        map { [ 1, $execErr{ $_->[0] } ] }
                        grep { $_->[0] !~ /^(?:get|multi|exec)$/ }
                          @{ $self->{calls} }
                    ]
                );
            }
            elsif ( $queueErr{$m} ) { $cb->( undef, $queueErr{$m} ) }
            else                     { $cb->( $m eq 'multi' ? 'OK' : 'QUEUED' ) }
        };
    }

    sub wait_all_responses {
        $_->() foreach @{ $_[0]->{cbs} };
        $_[0]->{cbs} = [];
    }
}

sub tx {
    my ( $method, $data, $old, %args ) = @_;
    my $store = bless { cache => MockTx->new }, 'Web::Session::Store::Redis';
    my $old_raw = $old ? 'old' : undef;
    no warnings qw(redefine once);
    local *MockTx::get = sub { push @{ $_[0]->{calls} }, ['get']; $old_raw };
    $store->$method(
        {
            data => { _session_id => 'id1', %$data },
            serialized  => '{}',
            args        => { Index => 'uid', utimeOffset => 60, %args },
            unserialize => sub { $_[0]->{data} = $old },
        }
    );
    my @calls = grep { $_->[0] ne 'get' } @{ $store->{cache}->{calls} };

    # The expiration is checked apart
    my @ttl;
    foreach (@calls) {
        if ( $_->[0] eq 'set' and @$_ > 3 ) { push @ttl, splice( @$_, 4 ) }
        if ( $_->[0] eq 'hexpire' ) { push @ttl, splice( @$_, 2, 1, 'TTL' ) }
    }
    return ( \@calls, \@ttl );
}

{
    my ( $calls, $ttl ) = tx( 'insert', { uid => 'dwho', _utime => $now } );
    is_deeply(
        $calls,
        [
            ['multi'],
            [ 'set',     'id1',          '{}', 'EX' ],
            [ 'srem',    'uid_dwho',     'id1' ],
            [ 'hset',    'hidx:uid_dwho', 'id1', 1 ],
            [ 'hexpire', 'hidx:uid_dwho', 'TTL', 'FIELDS', 1, 'id1' ],
            ['exec'],
        ],
        'insert: session and index hash entry in one transaction'
    );
    near( $ttl->[0], 60, 'insert: session expiration' );
    is( $ttl->[1], $ttl->[0], 'insert: index entry expires with the session' );

    ( $calls, $ttl ) = tx( 'insert',
        { uid => 'dwho', _utime => $now, _session_kind => 'Persistent' } );
    is_deeply(
        $calls,
        [
            ['multi'],
            [ 'set',  'id1',           '{}' ],
            [ 'hdel', 'hidx:uid_dwho', 'id1' ],
            [ 'sadd', 'uid_dwho',      'id1' ],
            ['exec'],
        ],
        'insert: session without expiration indexed in the set'
    );

    ( $calls, $ttl ) = tx( 'update', { uid => 'new', _utime => $now },
        { uid => 'old', _utime => $now } );
    is_deeply(
        [ map { "$_->[0] $_->[1]" } @$calls[ 1 .. 5 ] ],
        [
            'set id1', 'srem uid_old', 'hdel hidx:uid_old', 'srem uid_new',
            'hset hidx:uid_new'
        ],
        'update: old value removed from both indexes'
    );

    ( $calls, $ttl ) = tx( 'update', { _utime => $now },
        { uid => 'old', _utime => $now } );
    is_deeply(
        [ map { join ' ', grep { defined } @$_[ 0, 1 ] } @$calls ],
        [ 'multi', 'set id1', 'srem uid_old', 'hdel hidx:uid_old', 'exec' ],
        'update: removed value'
    );

    local $MockTx::queueErr{hexpire} =
      "ERR unknown command 'HEXPIRE', with args beginning with: ...";
    ok( !eval { tx( 'insert', { uid => 'dwho', _utime => $now } ); 1 },
        'Redis without HEXPIRE: write fails' );
    like( $@, qr/^utimeOffset needs Redis >= 7\.4 or Valkey >= 9: \[hexpire\]/,
        'Redis without HEXPIRE: explicit error' );

    local $MockTx::queueErr{hexpire} =
      "NOPERM User app has no permissions to run the 'hexpire' command";
    ok( !eval { tx( 'insert', { uid => 'dwho', _utime => $now } ); 1 },
        'HEXPIRE forbidden: write fails' );
    like( $@, qr/^\[hexpire\] NOPERM/, 'HEXPIRE forbidden: error of Redis' );
}
# set, srem, hset, hexpire
foreach my $bad ( [], ['OK'], [ ( [ 1, undef ] ) x 3, 'QUEUED' ], 'OK' ) {
    local $MockTx::execReply = $bad;
    ok( !eval { tx( 'insert', { uid => 'dwho', _utime => $now } ); 1 },
        'unexpected EXEC reply: write fails' );
    is( $@, "[exec] unexpected reply\n", 'unexpected EXEC reply: error' );
}
{
    my $store = bless { cache => MockRedis->new },
      'Web::Session::Store::Redis';
    $store->insert(
        {
            data       => { _session_id => 'id1', _utime => $now },
            serialized => '{}',
            args       => { Index => '', utimeOffset => 60 },
        }
    );
    my $calls = $store->{cache}->{calls};
    my $ttl   = splice( @{ $calls->[0] }, 4 );
    is_deeply( $calls, [ [ 'set', 'id1', '{}', 'EX' ] ],
        'insert without index: no transaction' );
    near( $ttl, 60, 'insert without index: expiration' );
}
{
    local $MockTx::execErr{srem} = 'WRONGTYPE Operation against a key';
    ok( eval { tx( 'insert', { uid => 'dwho', _utime => $now } ); 1 },
        'error of a removal ignored' );
    local $MockTx::execErr{hset} = 'WRONGTYPE Operation against a key';
    ok( !eval { tx( 'insert', { uid => 'dwho', _utime => $now } ); 1 },
        'error of an addition fails the write' );
    like( $@, qr/^\[hset\] WRONGTYPE/, 'error of an addition: message' );
}
{
    local $MockTx::croak{hset} = 1;
    my $store = bless { cache => MockTx->new }, 'Web::Session::Store::Redis';
    ok(
        !eval {
            $store->insert(
                {
                    data => { _session_id => 'id1', uid => 'a', _utime => $now },
                    serialized => '{}',
                    args       => { Index => 'uid', utimeOffset => 60 },
                }
            );
            1;
        },
        'client error in the transaction: write fails'
    );
    like( $@, qr/^\[hset\] Not connected/, 'client error: message' );
    is( $store->{cache}->{calls}->[-1]->[0],
        'discard', 'client error: transaction discarded' );
}
{
    my $store = bless { cache => MockRedis->new },
      'Web::Session::Store::Redis';
    $store->remove(
        {
            data => { _session_id => 'id1', uid => 'dwho' },
            args => { Index => 'uid', utimeOffset => 60 },
        }
    );
    is_deeply(
        $store->{cache}->{calls},
        [
            [ 'srem', 'uid_dwho',      'id1' ],
            [ 'hdel', 'hidx:uid_dwho', 'id1' ],
            [ 'del',  'id1' ]
        ],
        'remove: session removed from both indexes'
    );
}

# HEXPIRE support is checked once per server
{

    package FakeHexpire;
    our ( $err, $calls ) = ( undef, 0 );
    sub new { bless {}, shift }
    sub hexpire { $calls++; die $err if ($err); return [-2] }
}
{
    my $check = \&Web::Session::Store::Redis::_checkHexpire;
    no warnings 'once';
    local %Web::Session::Store::Redis::hexpire;
    my $r = FakeHexpire->new;
    local $FakeHexpire::err =
      "[hexpire] ERR unknown command 'HEXPIRE', with args beginning with: ...";
    ok( !eval { $check->( $r, { server => 'a' } ); 1 },
        'Redis without HEXPIRE: tie fails' );
    like( $@, qr/^utimeOffset needs Redis >= 7\.4 or Valkey >= 9: \[hexpire\]/,
        'Redis without HEXPIRE: explicit error' );
    $FakeHexpire::err = 'WRONGTYPE Operation against a key';
    ok( eval { $check->( $r, { server => 'b' } ); 1 }, 'WRONGTYPE: supported' );
    $FakeHexpire::calls = 0;
    ok( !eval { $check->( $r, { server => 'a' } ); 1 },
        'Redis without HEXPIRE: remembered' );
    is( $FakeHexpire::calls, 0, 'Redis without HEXPIRE: not probed again' );
    like( $@, qr/^utimeOffset needs Redis >= 7\.4/,
        'Redis without HEXPIRE: same error' );

    $FakeHexpire::err =
      "[hexpire] NOPERM User app has no permissions to run the 'hexpire' command";
    $FakeHexpire::calls = 0;
    ok( eval { $check->( $r, { server => 'n' } ) foreach ( 1 .. 3 ); 1 },
        'NOPERM left to the commands' );
    is( $FakeHexpire::calls, 1, 'NOPERM: probed once' );

    $FakeHexpire::err =
      "[hexpire] READONLY You can't write against a read only replica.";
    $FakeHexpire::calls = 0;
    local $fakeTime = CORE::time;
    ok( eval { $check->( $r, { server => 'r' } ) foreach ( 1 .. 3 ); 1 },
        'READONLY left to the commands' );
    is( $FakeHexpire::calls, 1, 'READONLY: probed once' );
    $fakeTime += $Web::Session::Store::Redis::READONLY_RETRY - 1;
    $check->( $r, { server => 'r' } );
    is( $FakeHexpire::calls, 1, 'READONLY: not probed again before the delay' );
    $fakeTime += 1;
    $FakeHexpire::err = undef;
    $check->( $r, { server => 'r' } );
    is( $FakeHexpire::calls, 2, 'READONLY: probed again after the delay' );
    $fakeTime += 3600;
    $check->( $r, { server => 'r' } );
    is( $FakeHexpire::calls, 2, 'promoted replica: support remembered' );

    $FakeHexpire::err = '[hexpire] Error while reading from Redis server';
    $FakeHexpire::calls = 0;
    $check->( $r, { server => 't' } ) foreach ( 1, 2 );
    is( $FakeHexpire::calls, 2, 'other errors: probed again' );
    $FakeHexpire::err = undef;
    $FakeHexpire::calls = 0;
    $check->( $r, { sentinels => [ 'c', 'd' ] } ) foreach ( 1, 2 );
    is( $FakeHexpire::calls, 1, 'checked once per server' );
    $check->( $r, { sentinels => [ 'c', 'e' ] } );
    is( $FakeHexpire::calls, 2, 'other server checked' );
}

foreach my $bad ( 'abc', '-1', '1.5', '1' x 11, "\x{663}" ) {
    ( my $name = $bad ) =~ s/([^\x00-\x7f])/sprintf( '\\x{%x}', ord $1 )/ge;
    ok(
        !eval {
            Web::Session::Store::Redis->new(
                { args => { utimeOffset => $bad } } );
            1;
        },
        "utimeOffset '$name' rejected"
    );
    like( $@, qr/utimeOffset/, "utimeOffset '$name': error message" );
}

done_testing();
