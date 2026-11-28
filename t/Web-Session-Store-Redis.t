use strict;
use warnings;
use Test::More;

# Lets the HEXPIRE probe cache be tested across time
our $fakeTime;
BEGIN { *CORE::GLOBAL::time = sub () { $main::fakeTime // CORE::time } }

# Store::Redis::update with a mock Redis object (no server needed)
package MockRedis;
sub new { my ( $class, %res ) = @_; bless { calls => [], res => \%res }, $class }

sub AUTOLOAD {
    my $self = shift;
    our $AUTOLOAD;
    ( my $m = $AUTOLOAD ) =~ s/.*:://;
    return if $m eq 'DESTROY';
    push @{ $self->{calls} }, [ $m, @_ ];
    my $res = $self->{res}->{$m};

    # A list of replies is consumed one by one, a code ref is called
    $res = shift @$res if ( ref($res) eq 'ARRAY' );
    return ref($res) eq 'CODE' ? $res->(@_) : $res;
}

package main;

plan skip_all => 'Redis module is needed'
  unless eval { require Web::Session::Store::Redis; 1 };

# %res: replies of the mock, SET replies OK unless set => undef
sub run {
    my ( $index, $extra, %res ) = @_;
    %res = ( set => 'OK', %res );
    my $store = bless { cache => MockRedis->new(%res) },
      'Web::Session::Store::Redis';
    my $unserialized = 0;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $session = {
        data        => { _session_id => 'id1', uid => 'dwho' },
        serialized  => '{}',
        args        => { Index => $index, %{ $extra || {} } },
        unserialize => sub {
            $unserialized++;
            $_[0]->{data} = { _session_id => 'id1', uid => 'rtyler' };
        },
    };
    my $ret = $store->update($session);
    return ( $store->{cache}->{calls}, $unserialized, \@warnings, $session,
        $ret );
}

my $STATUS = Web::Session::Store::Redis::STATUS();

my ( $calls, $unser, $warn, $stored, $ret ) = run('');
is_deeply( $calls, [ [ 'set', 'id1', '{}', 'XX' ] ],
    'Without index: session overwritten, no read' );
is( $ret, 1, 'Without index: update() returns true' );
is( $stored->{$STATUS}, 'overwritten',
    'Without index, version unknown: status' );
is( $unser, 0, 'Without index: old session not decoded' );
is_deeply( $warn, [], 'Without index: no warning' );

( $calls, $unser ) = run( '', { TTL => 10 } );
is_deeply( $calls, [ [ 'set', 'id1', '{}', 'EX', 10, 'XX' ] ],
    'Without index: TTL is kept' );

( $calls, $unser ) = run( [] );
is_deeply( $calls, [ [ 'set', 'id1', '{}', 'XX' ] ], 'Empty index list' );

( $calls, $unser, $warn, $stored, $ret ) = run('uid');
is( $ret, 1, 'With index: update() returns true' );
is( $stored->{$STATUS}, 'overwritten', 'With index, version unknown: status' );
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(get set sadd)],
    'With index: old session read, index updated'
);
is_deeply( $calls->[1], [ 'set', 'id1', '{}', 'XX' ],
    'With index: session overwritten' );
is_deeply( $warn, [], 'With index: no warning' );

( $calls, $unser ) = run( 'uid', { TTL => 10 }, get => '{}' );
is_deeply(
    $calls,
    [
        [ 'get', 'id1' ],
        [ 'set', 'id1', '{}', 'EX', 10, 'XX' ],
        [ 'srem', 'uid_rtyler', 'id1' ],
        [ 'sadd', 'uid_dwho',   'id1' ],
    ],
    'With index and TTL: old index entry replaced'
);

# Session deleted or expired since it was read: SET XX replies nil
foreach my $case (
    [ 'without index',          '' ],
    [ 'without index, with TTL', '', { TTL => 10 } ],
    [ 'with index',             'uid' ],
    [ 'with index and TTL', 'uid', { TTL => 10 }, get => '{}' ],
  )
{
    my ( $name, $index, $extra, %res ) = @$case;
    ( $calls, $unser, $warn, $stored, $ret ) =
      run( $index, $extra, %res, set => undef );
    is( $ret, 0, "Deleted session, $name: update() returns false" );
    is( $stored->{$STATUS}, 'deleted', "Deleted session, $name: status" );
    my @set = grep { $_->[0] eq 'set' } @$calls;
    is( scalar(@set), 1, "Deleted session, $name: one SET" );
    is( $set[0]->[-1], 'XX', "Deleted session, $name: SET XX" );
    is_deeply( [ grep { $_->[0] =~ /^s(?:add|rem)$/ } @$calls ],
        [], "Deleted session, $name: index sets untouched" );
    is( scalar(@$warn), 1, "Deleted session, $name: one warning" );
    like(
        $warn->[0] // '',
        qr/'id1' was deleted or expired/,
        "Deleted session, $name: warning names the session"
    );
}

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
    our ( %queueErr, %execErr, %croak, $execReply, @execReplies );
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
        # Commands of the transaction
        my ($multi) =
          grep { $self->{calls}->[$_]->[0] eq 'multi' }
          reverse 0 .. $#{ $self->{calls} };
        my @tx = @{ $self->{calls} }[ $multi + 1 .. $#{ $self->{calls} } - 1 ];
        push @{ $self->{cbs} }, sub {
            if ( $m eq 'exec' ) {

                # @execReplies: 'nil' for an EXEC aborted by WATCH
                if (@execReplies) {
                    my $res = shift @execReplies;
                    return $cb->( $res eq 'nil' ? undef : $res );
                }
                return $cb->($execReply) if ($execReply);
                return $cb->( undef, 'EXECABORT Transaction discarded' )
                  if ( grep { $queueErr{ $_->[0] } } @tx );
                $cb->( [ map { [ 1, $execErr{ $_->[0] } ] } @tx ] );
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
    my $session = {
        data        => { _session_id => 'id1', %$data },
        serialized  => '{}',
        args        => { Index => 'uid', utimeOffset => 60, %args },
        unserialize => sub { $_[0]->{data} = $old },
    };
    my $ret = $store->$method($session);
    my @calls =
      grep { $_->[0] !~ /^(?:get|watch)\z/ } @{ $store->{cache}->{calls} };

    # The expiration is checked apart
    my @ttl;
    foreach (@calls) {
        if ( $_->[0] eq 'set' and @$_ > 3 ) { push @ttl, splice( @$_, 4 ) }
        if ( $_->[0] eq 'hexpire' ) { push @ttl, splice( @$_, 2, 1, 'TTL' ) }
    }
    return ( \@calls, \@ttl, $session, $ret );
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
    my ( undef, undef, $inserted, $insertRet ) =
      tx( 'insert', { uid => 'dwho', _utime => $now } );
    is( $insertRet, 1, 'insert: returns true' );
    is( $inserted->{$STATUS}, 'written', 'insert: status' );

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

    my $same = { uid => 'new', _utime => $now };
    my ( $session, $ret );
    ( $calls, $ttl, $session, $ret ) = tx( 'update', $same, $same );
    is( $ttl->[1], 'XX', 'update: SET XX' );
    is( $ret, 1, 'update: returns true' );
    is( $session->{$STATUS}, 'overwritten', 'update, version unknown: status' );
    {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        local $MockTx::execReply = [ [undef], ( [1] ) x 3 ];
        ( $calls, $ttl, $session, $ret ) = tx( 'update', $same, $same );
        is( $ret, 0, 'SET XX refused: update() returns false' );
        is( $session->{$STATUS}, 'deleted', 'SET XX refused: status' );
        is_deeply(
            [ map { join ' ', grep { defined } @$_[ 0, 1 ] } @$calls ],
            [
                'multi',        'set id1',
                'srem uid_new', 'hset hidx:uid_new',
                'hexpire hidx:uid_new', 'exec',
                'hdel hidx:uid_new'
            ],
            'SET XX refused: added index entry removed'
        );
        is( scalar(@warnings), 1, 'SET XX refused: warning' );
        like( $warnings[0], qr/'id1' was deleted or expired/,
            'SET XX refused: message' );
    }

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

# Version check and merge: the session was read by Web::Session::Redis
use Web::Session::Serialize::JSON;
my $READ = Web::Session::Store::Redis::READ();
no warnings 'once';

sub ser {
    my $s = { data => shift };
    Web::Session::Serialize::JSON::serializeLatin1($s);
}

sub unser {
    my $s = { serialized => shift };
    Web::Session::Serialize::JSON::unserializeLatin1($s);
    $s->{data};
}

my $merge = \&Web::Session::Store::Redis::_merge;
my $orig  = { _session_id => 'id1', a => 1, b => 2, c => 3, l => [ 1, 2 ] };
is_deeply(
    $merge->(
        $orig,
        { %$orig, a => 10, d => 4 },
        { %$orig, b => 20, e => 5 }, 'id1'
    ),
    { %$orig, a => 10, b => 20, d => 4, e => 5 },
    'merge: changes of different keys are kept'
);
{
    my %new = %$orig;
    delete $new{c};
    is_deeply(
        $merge->( $orig, { %$orig, a => 10 }, \%new, 'id1' ),
        { _session_id => 'id1', a => 10, b => 2, l => [ 1, 2 ] },
        'merge: key deleted by the caller'
    );
    my %cur = %$orig;
    delete $cur{c};
    is_deeply( $merge->( $orig, \%cur, { %$orig, a => 10 }, 'id1' ),
        { %cur, a => 10 }, 'merge: key deleted concurrently stays deleted' );
    is_deeply( $merge->( $orig, \%cur, { %$orig, c => 30 }, 'id1' ),
        { %cur, c => 30 }, 'merge: key deleted concurrently, set by caller' );
}
is_deeply(
    $merge->( $orig, { %$orig, a => 10 }, { %$orig, a => 11 }, 'id1' ),
    { %$orig, a => 11 },
    'merge: same key, the caller wins'
);
is_deeply(
    $merge->(
        $orig,
        { %$orig, l => [ 1, 2, 3 ] },
        { %$orig, l => [ 1, 2 ] }, 'id1'
    ),
    { %$orig, l => [ 1, 2, 3 ] },
    'merge: references compared by value'
);
is_deeply(
    $merge->( $orig, { %$orig, l => [1] }, { %$orig, l => [ 1, 2, 4 ] },
        'id1' ),
    { %$orig, l => [ 1, 2, 4 ] },
    'merge: reference changed by the caller'
);
is_deeply(
    $merge->( $orig, { %$orig, a => 10 }, { %$orig, a => '1' }, 'id1' ),
    { %$orig, a => 10 },
    'merge: a number read as a string is unchanged'
);
is_deeply(
    $merge->(
        $orig,
        { %$orig, _session_id => 'other' },
        { %$orig, _session_id => 'x' }, 'id1'
    ),
    $orig,
    'merge: _session_id kept'
);
is_deeply(
    $merge->( $orig, { %$orig, u => undef }, { %$orig, u => undef }, 'id1' ),
    { %$orig, u => undef },
    'merge: undef values'
);

my $read = ser( { _session_id => 'id1', uid => 'rtyler', a => 1 } );

# %res: replies of the mock; $data: the caller's changes to the version read
sub runCas {
    my ( $index, $extra, $data, %res ) = @_;
    my $store = bless { cache => MockRedis->new(%res) },
      'Web::Session::Store::Redis';
    my $session = {
        data        => { %{ unser($read) }, %$data },
        args        => { Index => $index, %{ $extra || {} } },
        serialize   => \&Web::Session::Serialize::JSON::serializeLatin1,
        unserialize => \&Web::Session::Serialize::JSON::unserializeLatin1,
        $READ       => $read,
    };
    $session->{serialize}->($session);
    my ( @warnings, $stderr, $err, $ret );
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        local $Web::Session::Store::Redis::lua_warned;
        local $Web::Session::Store::Redis::unchecked_warned;
        open my $fh, '>', \$stderr;
        local *STDERR = $fh;
        eval { $ret = $store->update($session) };
        $err = $@;
    }
    return ( $store->{cache}->{calls}, $session, \@warnings, $stderr, $err,
        $ret );
}

my $noLua = sub { die "NOPERM this user has no permissions\n" };
my ( $session, $stderr, $err );

( $calls, $session, $warn ) =
  runCas( 'uid', undef, { uid => 'dwho' }, eval => sub { ['written'] } );
is_deeply( [ map { $_->[0] } @$calls ],
    [qw(eval srem sadd)], 'CAS: one EVAL, no GET, index updated' );
is_deeply(
    [ @{ $calls->[0] }[ 2 .. 6 ] ],
    [ 1, 'id1', $read, $session->{serialized}, '' ],
    'CAS: version read and new version sent'
);
is_deeply(
    [ @$calls[ 1, 2 ] ],
    [ [ 'srem', 'uid_rtyler', 'id1' ], [ 'sadd', 'uid_dwho', 'id1' ] ],
    'CAS: index of the version read replaced'
);
is( $session->{$READ}, $session->{serialized}, 'CAS: version written kept' );
is_deeply( $warn, [], 'CAS: no warning' );

( $calls, $session ) =
  runCas( '', { TTL => 10 }, { a => 2 }, eval => sub { ['written'] } );
is_deeply( [ map { $_->[0] } @$calls ], ['eval'], 'CAS without index' );
is( $calls->[0]->[-1], 10, 'CAS: TTL sent' );

my $cur = ser( { _session_id => 'id1', uid => 'rtyler', a => 1, x => 'y' } );
( $calls, $session, $warn ) = runCas(
    'uid', undef,
    { a => 2 },
    eval => [ sub { [ 'conflict', $cur ] }, sub { ['written'] } ]
);
is_deeply( [ map { $_->[0] } @$calls ],
    [qw(eval eval sadd)], 'Conflict: written again' );
is_deeply(
    $session->{data},
    { _session_id => 'id1', uid => 'rtyler', a => 2, x => 'y' },
    'Conflict: merged'
);
is( $calls->[1]->[4], $cur, 'Conflict: current version expected' );
is( $calls->[1]->[5], ser( $session->{data} ), 'Conflict: merge sent' );
is_deeply( $warn, [], 'Conflict: no warning' );

( $calls, $session, $warn ) =
  runCas( 'uid', undef, { uid => 'dwho' }, eval => sub { ['deleted'] } );
is_deeply( [ map { $_->[0] } @$calls ], ['eval'], 'Deleted: no write' );
is( scalar(@$warn), 1, 'Deleted: one warning' );
like( $warn->[0], qr/'id1' was deleted or expired/, 'Deleted: warning' );

( $calls, $session, $warn ) = runCas(
    'uid', undef,
    { a => 2 },
    eval => sub { [ 'conflict', ser( { _session_id => 'id1', n => rand } ) ] },
    set  => 'OK'
);
is( scalar( grep { $_->[0] eq 'eval' } @$calls ),
    $Web::Session::Store::Redis::MAX_TRIES,
    'Always changed: tries bounded' );
is_deeply(
    $calls->[-1],
    [ 'set', 'id1', $session->{serialized}, 'XX' ],
    'Always changed: last merge overwritten'
);
is_deeply( [ sort keys %{ $session->{data} } ],
    [qw(_session_id a n)], 'Always changed: merged' );
is( scalar(@$warn), 1, 'Always changed: one warning' );

# Without Lua: WATCH, GET, MULTI, SET XX, EXEC
( $calls, $session, $warn, $stderr ) = runCas(
    'uid', undef,
    { uid => 'dwho' },
    eval => $noLua,
    get  => $read,
    exec => [ undef, ['OK'] ],
);
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(eval watch get multi set exec eval watch get multi set exec srem sadd)],
    'Without Lua: EXEC aborted once, then written'
);
is_deeply(
    $calls->[4],
    [ 'set', 'id1', $session->{serialized}, 'XX' ],
    'Without Lua: SET XX'
);
like( $stderr, qr/^Redis EVAL failed.*NOPERM/, 'Without Lua: reported' );
is_deeply( $warn, [], 'Without Lua: no warning' );

( $calls, $session, $warn ) = runCas(
    '', { TTL => 10 },
    { a => 2 },
    eval => $noLua,
    get  => [ $cur, $cur ],
    exec => [ ['OK'] ],
);
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(eval watch get unwatch eval watch get multi set exec)],
    'Without Lua: conflict, merged and written'
);
is_deeply(
    $calls->[8],
    [ 'set', 'id1', $session->{serialized}, 'EX', 10, 'XX' ],
    'Without Lua: TTL'
);
is( $session->{data}->{x}, 'y', 'Without Lua: merged' );

( $calls, $session, $warn ) = runCas(
    'uid', undef,
    { uid => 'dwho' },
    eval => $noLua,
    get  => undef,
);
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(eval watch get unwatch)],
    'Without Lua: deleted session not written'
);
is( scalar(@$warn), 1, 'Without Lua: deleted, warning' );

( $calls, $session, $warn ) = runCas(
    'uid', undef,
    { uid => 'dwho' },
    eval => $noLua,
    get  => $read,
    exec => [ [undef] ],
);
is_deeply( [ map { $_->[0] } @$calls ],
    [qw(eval watch get multi set exec)], 'Without Lua: SET XX nil' );
is( scalar(@$warn), 1, 'Without Lua: SET XX nil, warning' );

( $calls, $session, $warn, $stderr, $err ) = runCas(
    'uid', undef,
    { uid => 'dwho' },
    eval => $noLua,
    get  => sub { die "connection lost\n" },
);
is( $err, "connection lost\n", 'Without Lua: Redis error raised' );
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(eval watch get discard unwatch)],
    'Without Lua: transaction cleaned up on error'
);

# Status of the update, and version stored in serialized
foreach my $case (
    [ 'written', eval => sub { ['written'] } ],
    [ 'merged', eval => [ sub { [ 'conflict', $cur ] }, sub { ['written'] } ] ],
    [ 'deleted', eval => sub { ['deleted'] } ],
    [
        'overwritten',
        eval =>
          sub { [ 'conflict', ser( { _session_id => 'id1', n => rand } ) ] },
        set => 'OK'
    ],
  )
{
    my ( $status, %res ) = @$case;
    my ( $c, $s, $w, $e, $er, $ret ) =
      runCas( 'uid', undef, { a => 2 }, %res );
    is( $s->{$STATUS}, $status, "Status $status" );
    is( $ret, ( $status eq 'deleted' ? 0 : 1 ), "Status $status: returned" );
    next if ( $status eq 'deleted' );
    my ($write) = grep { $_->[0] =~ /^(?:eval|set)\z/ } reverse @$c;
    is( ( $write->[0] eq 'eval' ? $write->[5] : $write->[2] ),
        $s->{serialized}, "Status $status: version stored in serialized" );
}

# Neither EVAL nor WATCH/MULTI: SET XX, without merge
my $noperm = sub {
    die "[$_[0]] NOPERM User app has no permissions to run this command\n";
};
( $calls, $session, $warn, $stderr, $err, $ret ) = runCas(
    'uid', undef,
    { uid => 'dwho' },
    eval  => $noLua,
    watch => sub { $noperm->('watch') },
    set   => 'OK',
);
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(eval watch discard unwatch set srem sadd)],
    'WATCH refused: overwritten, index updated'
);
is_deeply(
    $calls->[4],
    [ 'set', 'id1', $session->{serialized}, 'XX' ],
    'WATCH refused: SET XX'
);
is( $err, '', 'WATCH refused: no error' );
is( $ret, 1, 'WATCH refused: stored' );
is( $session->{$STATUS}, 'overwritten', 'WATCH refused: status' );
is( scalar(@$warn), 1, 'WATCH refused: one warning' );
like( $warn->[0], qr/refused WATCH\/MULTI.*NOPERM/, 'WATCH refused: message' );

( $calls, $session, $warn, $stderr, $err ) = runCas(
    '', undef,
    { uid => 'dwho' },
    eval  => $noLua,
    get   => $read,
    multi => sub { $noperm->('multi') },
    set   => 'OK',
);
is_deeply(
    [ map { $_->[0] } @$calls ],
    [qw(eval watch get multi discard unwatch set)],
    'MULTI refused: overwritten'
);
is( $session->{$STATUS}, 'overwritten', 'MULTI refused: status' );

( $calls, $session, $warn, $stderr, $err, $ret ) = runCas(
    'uid', undef,
    { uid => 'dwho' },
    eval  => $noLua,
    watch => sub { die "[watch] ERR unknown command 'watch'\n" },
    set   => undef,
);
is( $ret, 0, 'WATCH unknown, session deleted: not stored' );
is_deeply( [ grep { $_->[0] =~ /^s(?:add|rem)\z/ } @$calls ],
    [], 'WATCH unknown, session deleted: index untouched' );

( $calls, $session, $warn, $stderr, $err ) = runCas(
    'uid', undef,
    { uid => 'dwho' },
    eval  => $noLua,
    watch => sub { die "[watch] Error while reading from Redis server\n" },
);
like( $err, qr/Error while reading/, 'WATCH, connection error: raised' );
is( scalar( grep { $_->[0] eq 'set' } @$calls ),
    0, 'WATCH, connection error: not written' );

{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    local $Web::Session::Store::Redis::unchecked_warned;
    open my $fh, '>', \my $buf;
    local *STDERR = $fh;
    foreach ( 1, 2 ) {
        my $store = bless {
            cache => MockRedis->new(
                eval  => $noLua,
                watch => sub { $noperm->('watch') },
                set   => 'OK'
            )
          },
          'Web::Session::Store::Redis';
        my $s = {
            data        => unser($read),
            args        => { Index => '' },
            serialize   => \&Web::Session::Serialize::JSON::serializeLatin1,
            unserialize => \&Web::Session::Serialize::JSON::unserializeLatin1,
            $READ       => $read,
        };
        $s->{serialize}->($s);
        $store->update($s);
    }
    is( scalar(@warnings), 1, 'WATCH refused: warned once per process' );
}

# Lemonldap::NG's local cache: it sets serialized and Apache::Session calls
# unserialize, without materialize
{
    require Web::Session::Redis;
    my $cached = ser( { _session_id => 'id1', uid => 'dwho', a => 1 } );
    my $newer = ser( { _session_id => 'id1', uid => 'dwho', a => 1, b => 2 } );
    my $store = bless {
        cache => MockRedis->new(
            eval => [ sub { [ 'conflict', $newer ] }, sub { ['written'] } ]
        )
      },
      'Web::Session::Store::Redis';
    my $s = {
        serialized  => $cached,
        args        => { Index => '' },
        serialize   => \&Web::Session::Serialize::JSON::serializeLatin1,
        unserialize => \&Web::Session::Redis::_unserializeRead,
    };
    $s->{unserialize}->($s);
    is( $s->{$READ}, $cached, 'Cache: version read kept by unserialize' );
    $s->{data}->{c} = 3;
    $s->{serialize}->($s);
    ok( $store->update($s), 'Cache: stored' );
    my @evals = grep { $_->[0] eq 'eval' } @{ $store->{cache}->{calls} };
    is( $evals[0]->[4], $cached, 'Cache: version cached checked' );
    is( $evals[1]->[4], $newer,  'Cache: then the version stored' );
    is_deeply(
        unser( $s->{serialized} ),
        { _session_id => 'id1', uid => 'dwho', a => 1, b => 2, c => 3 },
        'Cache: merged'
    );
    is( $s->{$STATUS}, 'merged', 'Cache: status' );
}

# insert() keeps the version written for a second save in the same tie
{
    my $store = bless { cache => MockRedis->new( set => 'OK' ) },
      'Web::Session::Store::Redis';
    my $s = { data => { _session_id => 'id1' }, serialized => '{}', args => {} };
    $store->insert($s);
    is( $s->{$READ}, '{}', 'insert: version written kept' );
}

# utimeOffset with Index: WATCH and GET of the session, then the transaction.
# $gets: replies of GET (list or code ref), @exec: replies of EXEC ('nil':
# aborted by WATCH, undef: default)
my $readU = ser( { %{ unser($read) }, _utime => $now } );

sub runHash {
    my ( $data, $gets, @exec ) = @_;
    my $store = bless { cache => MockTx->new }, 'Web::Session::Store::Redis';
    my $session = {
        data        => { %{ unser($readU) }, %$data },
        args        => { Index => 'uid', utimeOffset => 60 },
        serialize   => \&Web::Session::Serialize::JSON::serializeLatin1,
        unserialize => \&Web::Session::Serialize::JSON::unserializeLatin1,
        $READ       => $readU,
    };
    $session->{serialize}->($session);
    my ( @warnings, $err, $ret );
    {
        no warnings 'redefine';
        local *MockTx::get = sub {
            push @{ $_[0]->{calls} }, ['get'];
            return ref($gets) eq 'CODE' ? $gets->() : shift @$gets;
        };
        local @MockTx::execReplies = grep { defined } @exec;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        eval { $ret = $store->update($session) };
        $err = $@;
    }
    return ( $store->{cache}->{calls}, $session, \@warnings, $err, $ret );
}

sub names { [ map { join ' ', grep { defined } @$_[ 0, 1 ] } @{ $_[0] } ] }

( $calls, $session, $warn ) = runHash( { uid => 'dwho' }, [$readU] );
is_deeply(
    names($calls),
    [
        'watch id1',              'get',
        'multi',                  'set id1',
        'srem uid_rtyler',        'hdel hidx:uid_rtyler',
        'srem uid_dwho',          'hset hidx:uid_dwho',
        'hexpire hidx:uid_dwho', 'exec'
    ],
    'Index hashes: version checked, then one transaction'
);
is( $calls->[3]->[-1], 'XX', 'Index hashes: SET XX' );
near( $calls->[3]->[-2], 60, 'Index hashes: expiration' );
is( $session->{$READ}, $session->{serialized},
    'Index hashes: version written kept' );
is_deeply( $warn, [], 'Index hashes: no warning' );
is( $session->{$STATUS}, 'written', 'Index hashes: status' );

my $curU =
  ser( { %{ unser($readU) }, uid => 'other', x => 'y', _utime => $now + 100 } );
( $calls, $session, $warn ) = runHash( { a => 2 }, [ $curU, $curU ] );
is_deeply(
    names($calls),
    [
        'watch id1',            'get',
        'unwatch',              'watch id1',
        'get',                  'multi',
        'set id1',              'srem uid_other',
        'hset hidx:uid_other', 'hexpire hidx:uid_other',
        'exec'
    ],
    'Index hashes, conflict: merged and written, index of the version replaced'
);
is_deeply(
    $session->{data},
    { %{ unser($curU) }, a => 2 },
    'Index hashes, conflict: merged'
);
is( $calls->[6]->[2], $session->{serialized}, 'Index hashes: merge written' );
near( $calls->[6]->[-2], 160, 'Index hashes, conflict: _utime of the merge' );
near( $calls->[9]->[2], 160,
    'Index hashes, conflict: index entry expires with the merge' );
is_deeply( $warn, [], 'Index hashes, conflict: no warning' );
is( $session->{$STATUS}, 'merged', 'Index hashes, conflict: status' );

( $calls, $session, $warn ) =
  runHash( { uid => 'dwho' }, [ $readU, $readU ], 'nil' );
is_deeply(
    [ map { $_->[0] } @$calls ],
    [
        qw(watch get multi set srem hdel srem hset hexpire exec),
        qw(watch get multi set srem hdel srem hset hexpire exec)
    ],
    'Index hashes, EXEC aborted: read and written again'
);
is( $session->{$READ}, $session->{serialized},
    'Index hashes, EXEC aborted: version written kept' );
is_deeply( $warn, [], 'Index hashes, EXEC aborted: no warning' );

( $calls, $session, $warn ) =
  runHash( { uid => 'dwho' }, [ $readU, $curU, $curU ], 'nil' );
is_deeply(
    [ map { $_->[0] } @$calls[ 10 .. $#$calls ] ],
    [
        qw(watch get unwatch watch get multi set),
        qw(srem hdel srem hset hexpire exec)
    ],
    'Index hashes, EXEC aborted by an update: merged'
);
is( $session->{data}->{x}, 'y', 'Index hashes, EXEC aborted: merge written' );

( $calls, $session, $warn, $err, $ret ) =
  runHash( { uid => 'dwho' }, [undef] );
is( $ret,                0,         'Index hashes, deleted: not stored' );
is( $session->{$STATUS}, 'deleted', 'Index hashes, deleted: status' );
is_deeply( names($calls), [ 'watch id1', 'get', 'unwatch' ],
    'Index hashes, deleted: no write, no index command' );
is( scalar(@$warn), 1, 'Index hashes, deleted: one warning' );
like( $warn->[0], qr/'id1' was deleted or expired/,
    'Index hashes, deleted: message' );

( $calls, $session, $warn ) = runHash(
    { a => 2 },
    sub { ser( { %{ unser($readU) }, n => rand } ) }
);
is( scalar( grep { $_->[0] eq 'watch' } @$calls ),
    $Web::Session::Store::Redis::MAX_TRIES,
    'Index hashes, always changed: tries bounded' );
is_deeply(
    [ map { $_->[0] } @$calls[ -7 .. -1 ] ],
    [qw(unwatch multi set srem hset hexpire exec)],
    'Index hashes, always changed: last merge written without WATCH'
);
is( $calls->[-5]->[2], $session->{serialized},
    'Index hashes, always changed: last merge written' );
is( scalar(@$warn), 1, 'Index hashes, always changed: one warning' );
is( $session->{$STATUS}, 'overwritten',
    'Index hashes, always changed: status' );
like( $warn->[0], qr/updated concurrently too often/,
    'Index hashes, always changed: message' );

( $calls, $session, $warn ) =
  runHash( { uid => 'dwho' }, [ ($readU) x 10 ],
    ('nil') x $Web::Session::Store::Redis::MAX_TRIES );
is( scalar( grep { $_->[0] eq 'exec' } @$calls ),
    $Web::Session::Store::Redis::MAX_TRIES + 1,
    'Index hashes, EXEC always aborted: bounded, then overwritten' );
is( $session->{$READ}, $session->{serialized},
    'Index hashes, EXEC always aborted: written' );

( $calls, $session, $warn, $err ) =
  runHash( { uid => 'dwho' }, sub { die "connection lost\n" } );
is( $err, "connection lost\n", 'Index hashes: Redis error raised' );
is_deeply( [ map { $_->[0] } @$calls ], [qw(watch get unwatch)],
    'Index hashes: WATCH cleared on error' );

{
    local $MockTx::queueErr{hset} = 'OOM command not allowed';
    ( $calls, $session, $warn, $err ) = runHash( { uid => 'dwho' }, [$readU] );
    like( $err, qr/^\[hset\] OOM/, 'Index hashes: queue error raised' );
}

# Index hashes, WATCH refused: transaction without WATCH nor merge
{
    no warnings 'redefine';
    local $Web::Session::Store::Redis::unchecked_warned;
    local *MockTx::watch = sub {
        push @{ $_[0]->{calls} }, ['watch'];
        die "[watch] NOPERM User app has no permissions to run 'watch'\n";
    };
    ( $calls, $session, $warn, $err, $ret ) =
      runHash( { uid => 'dwho' }, [$curU] );
    is_deeply(
        names($calls),
        [
            'watch',                 'get',
            'multi',                 'set id1',
            'srem uid_other',        'hdel hidx:uid_other',
            'srem uid_dwho',         'hset hidx:uid_dwho',
            'hexpire hidx:uid_dwho', 'exec'
        ],
        'Index hashes, WATCH refused: index of the version read from Redis'
    );
    is( $err, '', 'Index hashes, WATCH refused: no error' );
    is( $ret, 1,  'Index hashes, WATCH refused: stored' );
    ok( !exists $session->{data}->{x},
        'Index hashes, WATCH refused: no merge' );
    is( $session->{$STATUS}, 'overwritten',
        'Index hashes, WATCH refused: status' );
    is( scalar(@$warn), 1, 'Index hashes, WATCH refused: one warning' );

    local $MockTx::queueErr{multi} =
      "NOPERM User app has no permissions to run 'multi'";
    ( $calls, $session, $warn, $err ) = runHash( { uid => 'dwho' }, [$curU] );
    like( $err, qr/^\[multi\] NOPERM/, 'Index hashes, MULTI refused: error' );
}

# Without the version read: overwritten, index of the version replaced
{
    my $store = bless { cache => MockTx->new }, 'Web::Session::Store::Redis';
    no warnings 'redefine';
    local *MockTx::get = sub { push @{ $_[0]->{calls} }, ['get']; $curU };
    my $s = {
        data        => { %{ unser($readU) }, uid => 'dwho' },
        serialized  => '{}',
        args        => { Index => 'uid', utimeOffset => 60 },
        unserialize => \&Web::Session::Serialize::JSON::unserializeLatin1,
    };
    $store->update($s);
    is_deeply(
        [ @{ names( $store->{cache}->{calls} ) }[ 0 .. 5 ] ],
        [ 'watch id1', 'get', 'multi', 'set id1', 'srem uid_other',
            'hdel hidx:uid_other' ],
        'Index hashes, version unknown: no check, index replaced'
    );

    $store = bless { cache => MockTx->new }, 'Web::Session::Store::Redis';
    $s     = {
        data       => { _session_id => 'id1', uid => 'a', _utime => $now },
        serialized => '{}',
        args       => { Index => 'uid', utimeOffset => 60 },
    };
    $store->insert($s);
    is( $s->{$READ}, '{}', 'Index hashes, insert: version written kept' );
    is( scalar( grep { $_ eq 'XX' } @{ $store->{cache}->{calls}->[1] } ),
        0, 'Index hashes, insert: not SET XX' );
}

done_testing();
