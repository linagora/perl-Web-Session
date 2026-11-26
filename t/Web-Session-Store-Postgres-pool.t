use strict;
use warnings;
no warnings 'once';
use Test::More;

# KeepConnections of Web::Session::Store::Postgres, without database: DBI
# connections are mocked
plan skip_all => 'DBI and Apache::Session are needed for this test'
  unless eval { require DBI; require Apache::Session::Store::Postgres; 1 };

{

    package FakeDbh;
    our ( @connects, @sql, $disconnects, $pings );

    sub new {
        my ( $class, %attr ) = @_;
        return bless {
            Active => 1,
            Driver => { Name => 'Pg' },
            Type   => 'db',
            alive  => 1,
            %attr,
        }, $class;
    }

    sub ping {
        $pings++;
        return $_[0]->{alive};
    }

    sub disconnect {
        $_[0]->{Active} = 0;
        $disconnects++;
        return 1;
    }

    sub quote_identifier {
        my ( $self, $name ) = @_;
        $name =~ s/"/""/g;
        return qq{"$name"};
    }

    # Statement handles inherit HandleError, as with DBI
    sub prepare_cached {
        my ( $self, $sql ) = @_;
        return bless {
            sql         => $sql,
            Type        => 'st',
            Database    => $self,
            HandleError => $self->{HandleError},
        }, 'FakeSth';
    }
    *prepare = \&prepare_cached;
    sub commit   { 1 }
    sub rollback { 1 }

    package FakeSth;
    sub bind_param { 1 }

    # A statement fails if its connection has "fail" set
    sub execute {
        my ($self) = @_;
        push @FakeDbh::sql, $self->{sql};
        if ( $self->{Database}->{fail} ) {
            my $err = 'cannot execute UPDATE in a read-only transaction';
            $self->{HandleError}->( $err, $self, undef )
              if ( $self->{HandleError} );
            die "$err\n";
        }
        return 1;
    }
    sub fetchrow_arrayref { ['{}'] }
    sub finish            { 1 }
}

my $class = 'Web::Session::Store::Postgres';
use_ok($class);

no warnings 'redefine';
local *DBI::connect = sub {
    my ( undef, $ds, $user, $pass, $attr ) = @_;
    my $dbh = FakeDbh->new(%$attr);
    push @FakeDbh::connects, [ $ds, $attr, $dbh ];
    return $dbh;
};
local *DBI::connect_cached = sub {
    my ( undef, $ds, $user, $pass, $attr ) = @_;
    my $dbh = FakeDbh->new(%$attr);
    push @FakeDbh::connects, [ $ds, $attr, $dbh, 'cached' ];
    return $dbh;
};
use warnings 'redefine';

my %base = (
    DataSource      => 'dbi:Pg:dbname=sessions',
    UserName        => 'u',
    Commit          => 1,
    KeepConnections => 1,
);
my $key = "$base{DataSource}\0u";
my $n   = 0;

sub session {
    my %args = ( %base, @_ );
    return {
        args       => \%args,
        data       => { _session_id => 'id' . ++$n, uid => 'dwho' },
        serialized => '{}',
    };
}

sub reset_pool {
    %Web::Session::Store::Postgres::IDLE = ();
    @FakeDbh::connects                    = ();
    @FakeDbh::sql                         = ();
    $FakeDbh::disconnects                 = 0;
    $FakeDbh::pings                       = 0;
}

sub pool { $Web::Session::Store::Postgres::IDLE{$key} || [] }
sub idle { scalar @{ pool() } }

# Connection attributes
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
    my $attr = $FakeDbh::connects[0]->[1];
    ok( $attr->{AutoCommit},          'Pooled connection: AutoCommit on' );
    ok( $attr->{AutoInactiveDestroy}, 'Pooled connection: AutoInactiveDestroy' );
    ok( $attr->{RaiseError},          'Pooled connection: RaiseError' );
    is( ref( $attr->{HandleError} ), 'CODE', 'Pooled connection: HandleError' );
}
is( idle(),                1, 'Connection given back to the pool' );
is( $FakeDbh::disconnects, 0, 'Connection not closed' );

# Reused by the next store
{
    my $store = $class->new;
    $store->connection( session() );
    is( scalar @FakeDbh::connects, 1, 'Idle connection reused' );
    is( idle(),                    0, 'Lent: no longer idle' );
}

# A session is written at once, as without the pool
reset_pool();
{
    my $store = $class->new;
    my $s     = session();
    $store->insert($s);
    is( scalar @FakeDbh::sql, 1, 'insert() writes at once' );
    like( $FakeDbh::sql[0], qr/^INSERT INTO/, 'It is an INSERT' );
    $store->update($s);
    like( $FakeDbh::sql[1], qr/^UPDATE/, 'update() updates' );
}

# Two stores at once never share a connection
reset_pool();
{
    my ( $s1, $s2 ) = ( $class->new, $class->new );
    $s1->connection( session() );
    $s2->connection( session() );
    isnt( $s1->{dbh}, $s2->{dbh}, 'Two stores tied at once: two connections' );
}
is( idle(), 2, 'Both given back' );

# MaxIdle
reset_pool();
{
    my @stores = map { $class->new } 1 .. 3;
    $_->connection( session( MaxIdle => 1 ) ) foreach (@stores);
}
is( idle(),                1, 'MaxIdle: one connection kept' );
is( $FakeDbh::disconnects, 2, 'MaxIdle: the others closed' );

# A connection whose statement failed is closed: HandleError, inherited by
# the statement handle, flags it
reset_pool();
{
    my $store = $class->new;
    my $s     = session();
    $store->connection($s);
    $store->{dbh}->{fail} = 1;
    ok( !eval { $store->insert($s); 1 }, 'Failed statement dies' );
    ok( $store->{dbh}->{private_ws_error}, 'Its connection is flagged' );
}
is( idle(),                0, 'Error: connection not kept' );
is( $FakeDbh::disconnects, 1, 'Error: connection closed' );

# The error flag is reset when a connection is lent
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
    $store->{dbh}->{private_ws_error} = 1;
    push @{ pool() }, [ $store->{dbh}, time ];
    delete $store->{pool_key};
    delete $store->{dbh};
}
{
    my $store = $class->new;
    $store->connection( session() );
    ok( !$store->{dbh}->{private_ws_error}, 'Error flag reset when lent' );
}

# A connection given back lately is lent without ping if its socket has
# nothing to read, pinged otherwise
reset_pool();
pipe( my $r, my $w ) or die $!;
{
    my $store = $class->new;
    $store->connection( session() );
    $store->{dbh}->{pg_socket} = fileno($r);
}
{
    my $store = $class->new;
    $store->connection( session() );
    is( $FakeDbh::pings, 0, 'Recent connection, empty socket: no ping' );
}
syswrite( $w, 'x' );
{
    my $store = $class->new;
    $store->connection( session() );
    is( $FakeDbh::pings, 1, 'Readable socket: pinged' );
}
pool()->[0]->[1] -= 60;
sysread( $r, my $buf, 1 );
{
    my $store = $class->new;
    $store->connection( session() );
    is( $FakeDbh::pings, 2, 'Connection idle for a while: pinged' );
}

# Dead connection replaced
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
}
pool()->[0]->[0]->{alive} = 0;
pool()->[0]->[1] -= 60;
{
    my $store = $class->new;
    $store->connection( session() );
    is( scalar @FakeDbh::connects, 2, 'Dead connection replaced' );
    is( $FakeDbh::disconnects,     1, 'Dead connection closed' );
}

# IdleTimeout: closed without ping
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
}
pool()->[0]->[1] -= 200;
{
    my $store = $class->new;
    $store->connection( session( IdleTimeout => 100 ) );
    is( scalar @FakeDbh::connects, 2, 'IdleTimeout: new connection' );
    is( $FakeDbh::pings,           0, 'IdleTimeout: old one not pinged' );
    is( $FakeDbh::disconnects,     1, 'IdleTimeout: old one closed' );
}

# Expired idle connections are closed when a connection is given back, even
# if they were never reached
reset_pool();
{
    my @stores = map { $class->new } 1 .. 2;
    $_->connection( session() ) foreach (@stores);
}
is( idle(), 2, 'Two idle connections' );
pool()->[0]->[1] -= 200;
{
    my $store = $class->new;
    $store->connection( session( IdleTimeout => 100 ) );
}
is( idle(),                1, 'Expired idle connection reaped at give back' );
is( $FakeDbh::disconnects, 1, 'Expired idle connection closed' );

# MaxLifetime
reset_pool();
{
    my $store = $class->new;
    $store->connection( session( MaxLifetime => 100 ) );
    $store->{dbh}->{private_ws_born} -= 200;
}
is( idle(),                0, 'MaxLifetime: old connection not kept' );
is( $FakeDbh::disconnects, 1, 'MaxLifetime: old connection closed' );

# Inherited from a parent process (idle when it forked): neither used nor
# closed
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
}
pool()->[0]->[0]->{private_ws_pid} = -1;
{
    my $store = $class->new;
    $store->connection( session() );
    is( scalar @FakeDbh::connects, 2, 'Fork: parent connection not used' );
    is( $FakeDbh::disconnects,     0, 'Fork: parent connection not closed' );
}

# Lent when the process forked: neither given back nor closed by the child
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
    $store->{dbh}->{private_ws_pid} = -1;
}
is( idle(),                0, 'Fork: lent connection not given back' );
is( $FakeDbh::disconnects, 0, 'Fork: lent connection not closed' );

# Without KeepConnections, or without Commit, or with noreuse or a Handle:
# no pool
foreach (
    [ 'Without KeepConnections', KeepConnections => 0 ],
    [ 'Without Commit',          Commit          => 0 ],
  )
{
    my ( $label, @args ) = @$_;
    reset_pool();
    {
        my $store = $class->new;
        $store->insert( session(@args) );
        ok( !$FakeDbh::connects[0]->[1]->{AutoCommit},
            "$label: AutoCommit off" );
        is( $FakeDbh::connects[0]->[3],
            'cached', "$label: connection reuse of the other stores" );
    }
    is( idle(), 0, "$label: nothing in the pool" );
}
reset_pool();
{
    my $store = $class->new;
    $store->insert( session( noreuse => 1 ) );
    ok( !$FakeDbh::connects[0]->[3], 'noreuse: own connection' );
}
is( idle(), 0, 'noreuse: nothing in the pool' );
reset_pool();
{
    my $dbh   = FakeDbh->new( AutoCommit => 0 );
    my $store = $class->new;
    $store->insert( session( Handle => $dbh ) );
    is( $store->{dbh},             $dbh, 'Handle: used as is' );
    is( scalar @FakeDbh::connects, 0,    'Handle: no connection opened' );
}
is( idle(), 0, 'Handle: nothing in the pool' );

done_testing();
