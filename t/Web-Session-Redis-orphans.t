use strict;
use warnings;
use Test::More;

my $class = 'Web::Session::Redis';

plan skip_all => 'Redis module is needed' unless eval "require $class";

# Orphan removal without Lua
{

    package FakeRedis;
    our @log;
    our $lua    = 0;
    our $exists = 0;
    sub new { bless {}, shift }

    sub eval {
        die "ERR unknown command 'eval'\n" unless $lua;
        push @log, $_[1] =~ /hdel/ ? 'eval hdel' : 'eval';
        1;
    }
    sub watch   { push @log, 'watch' }
    sub unwatch { push @log, 'unwatch' }
    sub exists  { push @log, 'exists'; $exists }
    sub multi   { push @log, 'multi' }
    sub srem    { shift; push @log, join ' ', 'srem', @_ }
    sub hdel    { shift; push @log, join ' ', 'hdel', @_ }
    sub exec    { push @log, 'exec' }
    sub discard { push @log, 'discard' }
}
{
    my $err = '';
    local *STDERR;
    open STDERR, '>', \$err;
    my $r = FakeRedis->new;
    $class->_removeOrphan( $r, 'uid_x', 'k' );
    is_deeply(
        \@FakeRedis::log,
        [ 'watch', 'exists', 'multi', 'srem uid_x k', 'exec' ],
        'fallback: WATCH/MULTI/EXEC'
    );
    like( $err, qr/^Redis EVAL failed/, 'fallback: error printed' );
    @FakeRedis::log    = ();
    $err               = '';
    $FakeRedis::exists = 1;
    $class->_removeOrphan( $r, 'uid_x', 'k' );
    is_deeply(
        \@FakeRedis::log,
        [ 'watch', 'exists', 'unwatch' ],
        'fallback: existing session is kept'
    );
    is( $err, '', 'fallback: error printed once' );
    @FakeRedis::log = ();
    $FakeRedis::lua = 1;
    $class->_removeOrphan( $r, 'uid_x', 'k' );
    is_deeply( \@FakeRedis::log, ['eval'], 'Lua used when available' );

    # Index hashes
    @FakeRedis::log = ();
    $class->_removeOrphan( $r, 'hidx:uid_x', 'k', 1 );
    is_deeply( \@FakeRedis::log, ['eval hdel'], 'index hash: Lua HDEL' );
    @FakeRedis::log    = ();
    $FakeRedis::lua    = 0;
    $FakeRedis::exists = 0;
    $class->_removeOrphan( $r, 'hidx:uid_x', 'k', 1 );
    is_deeply(
        \@FakeRedis::log,
        [ 'watch', 'exists', 'multi', 'hdel hidx:uid_x k', 'exec' ],
        'index hash: fallback with HDEL'
    );
}

# SCAN patterns of index sets and hashes
{
    my $re = $class->can('_globRe');
    ok( 'uid_dwho' =~ $re->('uid_dw*'),   '_globRe: wildcard' );
    ok( 'uid_dw' =~ $re->('uid_dw*'),     '_globRe: empty wildcard' );
    ok( 'xuid_dwho' !~ $re->('uid_dw*'),  '_globRe: anchored' );
    ok( 'a*b_c' =~ $re->('a\\*b_*'),      '_globRe: escaped star' );
    ok( 'axb_c' !~ $re->('a\\*b_*'),      '_globRe: escaped star is literal' );
    ok( 'a?b_' =~ $re->('a\\?b_*'),       '_globRe: escaped question mark' );
    ok( 'a.b_' !~ $re->('a\\?b_*'),       '_globRe: no other wildcard' );
}
{

    package FakeScan;
    our @log;
    my @keys = qw(uid_dwho hidx:uid_dwho _session_uid_dwho
      hidx:_session_uid_dwho xuid_dwho hidx:xuid_dwho);
    sub new { bless {}, shift }

    sub scan {
        my ( $self, $cursor, %opts ) = @_;
        push @log, "scan $cursor $opts{MATCH}";
        return $cursor
          ? ( 0, [ @keys[ 3 .. $#keys ] ] )
          : ( 7, [ @keys[ 0 .. 2 ] ] );
    }
}
{
    my $scan = $class->can('_scanIndexes');
    my ( @sets, @hashes );
    my $cb = sub {
        my ( $names, $hash ) = @_;
        push @{ $hash ? \@hashes : \@sets }, @$names;
    };
    $scan->( FakeScan->new, { utimeOffset => 60 }, 'uid_dw*', $cb );
    is_deeply( \@FakeScan::log, [ 'scan 0 *uid_dw*', 'scan 7 *uid_dw*' ],
        'utimeOffset: one walk for sets and hashes' );
    is_deeply( \@sets,   ['uid_dwho'],      'utimeOffset: index sets' );
    is_deeply( \@hashes, ['hidx:uid_dwho'], 'utimeOffset: index hashes' );

    ( @FakeScan::log, @sets, @hashes ) = ();
    $scan->( FakeScan->new, {}, 'uid_dw*', $cb );
    is_deeply( \@FakeScan::log, [ 'scan 0 uid_dw*', 'scan 7 uid_dw*' ],
        'without utimeOffset: same pattern as before' );
    is( scalar(@hashes), 0, 'without utimeOffset: no index hash' );
}

done_testing();
