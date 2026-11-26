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
    our ( @connects, @sql, $disconnects );

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
    sub ping { $_[0]->{alive} }

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

    sub prepare_cached {
        my ( $self, $sql ) = @_;
        return bless { sql => $sql, dbh => $self }, 'FakeSth';
    }
    *prepare = \&prepare_cached;
    sub commit   { 1 }
    sub rollback { 1 }

    package FakeSth;
    sub bind_param { 1 }

    sub execute {
        my ($self) = @_;
        push @FakeDbh::sql, $self->{sql};
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
my $n = 0;

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
}

sub idle {
    return scalar @{ $Web::Session::Store::Postgres::IDLE{"$base{DataSource}\0u"}
          || [] };
}

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
is( idle(), 1, 'Connection given back to the pool' );
is( $FakeDbh::disconnects, 0, 'Connection not closed' );

# Reused by the next store
{
    my $store = $class->new;
    $store->connection( session() );
    is( scalar @FakeDbh::connects, 1, 'Idle connection reused' );
    is( idle(),                    0, 'Lent: no longer idle' );
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

# A connection that met an error is closed
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );

    # An error of a statement flags its connection
    Web::Session::Store::Postgres::_flagError( 'read-only transaction',
        bless { Type => 'st', Database => $store->{dbh} }, 'FakeSth' );
}
is( idle(),                0, 'Error: connection not kept' );
is( $FakeDbh::disconnects, 1, 'Error: connection closed' );

# The error flag is reset when a connection is lent
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
}
{
    my $store = $class->new;
    $store->connection( session() );
    ok( !$store->{dbh}->{private_ws_error}, 'Error flag reset when lent' );
}
is( idle(), 1, 'Connection without error kept' );

# Dead connection replaced
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
}
$Web::Session::Store::Postgres::IDLE{"$base{DataSource}\0u"}->[0]->[0]->{alive}
  = 0;
$Web::Session::Store::Postgres::IDLE{"$base{DataSource}\0u"}->[0]->[2] -= 60;
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
{
    my $entry = $Web::Session::Store::Postgres::IDLE{"$base{DataSource}\0u"}->[0];
    $entry->[2] -= 200;
    my $pinged = 0;
    no warnings 'redefine';
    local *FakeDbh::ping = sub { $pinged++; 1 };
    my $store = $class->new;
    $store->connection( session( IdleTimeout => 100 ) );
    is( scalar @FakeDbh::connects, 2, 'IdleTimeout: new connection' );
    is( $pinged,                   0, 'IdleTimeout: old one not pinged' );
    is( $FakeDbh::disconnects,     1, 'IdleTimeout: old one closed' );
}

# MaxLifetime
reset_pool();
{
    my $store = $class->new;
    $store->connection( session( MaxLifetime => 100 ) );
    $store->{dbh}->{private_ws_born} -= 200;
}
is( idle(),                0, 'MaxLifetime: old connection not kept' );
is( $FakeDbh::disconnects, 1, 'MaxLifetime: old connection closed' );

# Inherited from a parent process: neither used nor closed
reset_pool();
{
    my $store = $class->new;
    $store->connection( session() );
}
$Web::Session::Store::Postgres::IDLE{"$base{DataSource}\0u"}->[0]->[1] = -1;
{
    my $store = $class->new;
    $store->connection( session() );
    is( scalar @FakeDbh::connects, 2, 'Fork: parent connection not used' );
    is( $FakeDbh::disconnects,     0, 'Fork: parent connection not closed' );
}

# A new session is written once, at untie
reset_pool();
{
    my $store = $class->new;
    my $s     = session();
    $store->insert($s);
    is( scalar @FakeDbh::sql, 0, 'insert() waits for the untie' );
    $store->update($s);
    is( scalar @FakeDbh::sql, 1, 'update() of a new session: one statement' );
    like( $FakeDbh::sql[0], qr/^INSERT INTO/, 'update() of a new session inserts' );
    $store->update($s);
    like( $FakeDbh::sql[1], qr/^UPDATE/, 'Next update() updates' );
}
reset_pool();
{
    my $store = $class->new;
    $store->insert( session() );
}
is( scalar @FakeDbh::sql, 1, 'New session untied without update: inserted' );
like( $FakeDbh::sql[0], qr/^INSERT INTO/, 'It is an INSERT' );
reset_pool();
{
    my $store = $class->new;
    my $s     = session();
    $store->insert($s);
    $store->remove($s);
}
is( scalar @FakeDbh::sql, 0, 'Created and removed in the same tie: no SQL' );

# Without KeepConnections, or without Commit, or with a Handle: no pool
foreach (
    [ 'Without KeepConnections', KeepConnections => 0 ],
    [ 'Without Commit',          Commit          => 0 ],
  )
{
    my ( $label, @args ) = @$_;
    reset_pool();
    {
        my $store = $class->new;
        my $s     = session(@args);
        $store->insert($s);
        is( scalar @FakeDbh::sql, 1, "$label: insert() writes at once" );
        ok( !$FakeDbh::connects[0]->[1]->{AutoCommit},
            "$label: AutoCommit off" );
        is( $FakeDbh::connects[0]->[3], 'cached',
            "$label: connection reuse of the other stores" );
    }
    is( idle(), 0, "$label: nothing in the pool" );
}
reset_pool();
{
    my $dbh   = FakeDbh->new( AutoCommit => 0 );
    my $store = $class->new;
    $store->insert( session( Handle => $dbh ) );
    is( $store->{dbh},              $dbh, 'Handle: used as is' );
    is( scalar @FakeDbh::connects, 0,    'Handle: no connection opened' );
}
is( idle(), 0, 'Handle: nothing in the pool' );

done_testing();
