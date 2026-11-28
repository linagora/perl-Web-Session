use strict;
use warnings;
use Test::More;

# A session deleted while another process holds it tied must not be written
# back when that process unties it

our $test_dburl = $ENV{REDIS_URL}   || 'localhost:6379';
# Not the databases of the other Redis tests, to run them in parallel
our $test_dbnum = ( ( $ENV{REDIS_DBNUM} || 15 ) + 8 ) % 16;
our $r;

plan skip_all => "Optional modules (Redis) not installed"
  unless eval { require Redis; };

plan skip_all => "Redis error : $@"
  unless eval {
    $r = Redis->new( server => $test_dburl );
    $r->select($test_dbnum);
    $r->flushdb();
  };

my $package = 'Web::Session::Redis';
use_ok($package);

my $hexpire = eval {
    $r->hset( 'h', 'f', 1 );
    $r->hexpire( 'h', 10, 'FIELDS', 1, 'f' );
    $r->del('h');
    1;
};

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

foreach my $case (
    [ 'with index',          { Index => 'uid' } ],
    [ 'with index and TTL',  { Index => 'uid', TTL => 100 } ],
    [ 'without index',       {} ],
    [ 'without index, TTL',  { TTL => 100 } ],
    [ 'with index and utimeOffset', { Index => 'uid', utimeOffset => 3600 } ],
    [ 'without index, utimeOffset', { utimeOffset => 3600 } ],
  )
{
    my ( $name, $extra ) = @$case;
    next if ( $extra->{utimeOffset} and $extra->{Index} and !$hexpire );
    my $args = { server => $test_dburl, database => $test_dbnum, %$extra };
    my $indexed = $extra->{Index};
    my $expires = ( $extra->{TTL} or $extra->{utimeOffset} );

    # Index set, or index hash with utimeOffset
    my $isIndexed = sub {
        $extra->{utimeOffset}
          ? $r->hexists( 'hidx:uid_dwho', $_[0] )
          : $r->sismember( 'uid_dwho', $_[0] );
    };

    # Deleted by another tie (logout, revocation)
    my $id = newSession( $args, uid => 'dwho', _utime => time );
    ok( $r->exists($id), "$name: session created" );
    is( $isIndexed->($id), 1, "$name: index created" )
      if $indexed;

    my ( %a, %b );
    tie %a, $package, $id, $args;
    $a{color} = 'blue';
    tie %b, $package, $id, $args;
    tied(%b)->delete;
    untie %b;
    ok( !$r->exists($id), "$name: session deleted by B" );
    @warnings = ();
    tied(%a)->save;
    is( tied(%a)->{web_session_redis_update}, 'deleted', "$name: status" );
    untie %a;
    ok( !$r->exists($id), "$name: session not written back by A" );
    is( $isIndexed->($id), 0, "$name: not indexed again" )
      if $indexed;
    is( scalar( grep { /\Q$id\E/ } @warnings ), 1, "$name: warning" );

    # Expired (or deleted directly) while tied
    $id = newSession( $args, uid => 'dwho', _utime => time );
    tie %a, $package, $id, $args;
    $a{color} = 'blue';
    $r->del($id);
    untie %a;
    ok( !$r->exists($id), "$name: expired session not written back" );

    # Its index entry, left by the expiration, is an orphan
    ok( !$package->searchOn( $args, 'uid', 'dwho' )->{$id},
        "$name: expired session not found" );

    # Purged by deleteIfLowerThan
    $id = newSession( $args, uid => 'dwho', _utime => time - 1000 );
    tie %a, $package, $id, $args;
    $a{color} = 'blue';
    my ( $ok, $deleted ) =
      $package->deleteIfLowerThan( $args, { or => { _utime => time - 10 } } );
    is_deeply( [ $ok, $deleted ], [ 1, 1 ], "$name: purge deleted it" );
    untie %a;
    ok( !$r->exists($id), "$name: purged session not written back" );
    is( $isIndexed->($id), 0, "$name: purged session not indexed" )
      if $indexed;

    # Normal update still writes, keeps the index and refreshes the TTL
    $id = newSession( $args, uid => 'dwho', _utime => time );
    $r->expire( $id, 10 ) if $expires;
    @warnings = ();
    tie %a, $package, $id, $args;
    $a{color} = 'red';
    tied(%a)->save;
    is( tied(%a)->{web_session_redis_update}, 'written', "$name: status" );
    untie %a;
    ok( $r->exists($id), "$name: updated session kept" );
    like( $r->get($id), qr/"color":"red"/, "$name: update written" );
    is( $isIndexed->($id), 1, "$name: index kept" )
      if $indexed;
    if ($expires) {
        cmp_ok( $r->ttl($id), '>', 10, "$name: TTL refreshed" );
    }
    else {
        is( $r->ttl($id), -1, "$name: no TTL" );
    }
    is_deeply( \@warnings, [], "$name: no warning on a normal update" );

    $r->flushdb();
}

done_testing();
