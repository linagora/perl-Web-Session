package Web::Session::Store::Postgres;

use strict;

use DBI;
use Web::Session::Store::DBI;
use Apache::Session::Store::Postgres;

our @ISA =
  qw(Web::Session::Store::DBI Apache::Session::Store::Postgres);
our $VERSION = '1.0.0';

# A pool of connections, per process and per data source (DataSource +
# UserName), lent to one store at a time: two sessions tied together (a
# session and its persistent session) never share a connection, so never a
# transaction. With the connection reuse of the other stores
# (connect_cached(), see _connection() in Store/DBI.pm), they share the
# handle and its transaction: untying one commits or rolls back what the
# other has done so far.
#
# So the pool is the default connection reuse of this store when writes are
# committed (see _commit()), noreuse isn't set and no Handle is given.
# KeepConnections => 0 gives back the connect_cached() handle of the other
# stores. With Commit => 0, writes must not be committed (AutoCommit off,
# rolled back at untie), which the pool, where each statement commits
# itself, can't do: connect_cached() is kept.
#
# In the pool, each statement of this store is its own transaction
# (AutoCommit): it reads without a lock (Apache::Session::Store::DBI's
# materialize, no FOR UPDATE; the lock manager is Null), so a transaction
# around a tie protected nothing and cost a BEGIN and a COMMIT round trip
# each. The Patroni store, whose materialize() locks the row, opens a
# transaction per tie on its pooled connection; _giveBack() never keeps a
# connection inside a transaction.
#
# With the same arguments, the class methods of Web::Session::PgJSON borrow
# a connection of this pool for the duration of each call (see _lend()), so
# that a process using both sessions and class methods doesn't keep one more
# connection for the latter.
# Times the idle connections of a data source were dropped by _dropIdle():
# a connection lent before the last drop is closed when given back
our %DROPS;    # "datasource\0user" => count
our %IDLE;   # "datasource\0user" => [ [ $dbh, $since ], ... ]

# Defaults of the MaxIdle, IdleTimeout and MaxLifetime arguments
our $MAX_IDLE     = 4;       # idle connections kept per data source
our $IDLE_TIMEOUT = 120;     # seconds: an idle connection older is closed
our $MAX_LIFETIME = 3600;    # seconds: an older connection isn't kept

# An idle connection given back less than $PING_AFTER seconds ago is lent
# without a round trip if its socket has nothing to read (see _usable())
our $PING_AFTER = 30;

# Integer argument $name of $args, or $default
sub _intArg {
    my ( $args, $name, $default ) = @_;
    my $v = $args->{$name};
    return ( defined($v) and $v =~ /^\s*([0-9]+)\s*\z/ ) ? $1 : $default;
}

# Whether an idle handle can be lent without a round trip: one given back
# lately, its statements done, whose socket has nothing to read, is alive (a
# server that goes away closes it, which makes it readable). One idle for
# longer, or whose socket is readable or unknown, is pinged.
sub _usable {
    my ( $handle, $since ) = @_;
    return 0 unless $handle->{Active};
    my $fd = eval { $handle->{pg_socket} };
    if ( time - $since < $PING_AFTER and defined $fd and $fd >= 0 ) {
        my $rin = '';
        vec( $rin, $fd, 1 ) = 1;

        # The descriptor number only: no Perl handle opened, none closed
        my $ready = select( my $rout = $rin, undef, undef, 0 );
        return 1 if ( defined $ready and $ready == 0 );
    }
    return eval { $handle->ping } ? 1 : 0;
}

# Whether an idle connection given back at $since is expired
sub _expired {
    my ( $handle, $since, $now, $idleTimeout, $maxLifetime ) = @_;
    return ( $now - $since > $idleTimeout
          or $now - $handle->{private_ws_born} > $maxLifetime );
}

# HandleError of pooled connections (inherited by their statement handles):
# a connection that met an error is closed when given back, never lent again.
# For example, after a failover behind a virtual IP, a connection to the
# former primary still answers ping() but every write fails. Returns false:
# RaiseError still applies.
sub _flagError {
    my ( $msg, $h ) = @_;
    my $dbh = ( $h->{Type} // '' ) eq 'st' ? $h->{Database} : $h;
    $dbh->{private_ws_error} = 1 if ($dbh);
    return 0;
}

# Commit policy of a session. Without a Handle, writes are committed unless
# Commit is explicitly false: a missing or empty Commit keeps the default (as
# the Patroni store does), else a session written without it would be rolled
# back at untie. With a Handle, the caller owns the transaction: Commit is
# used as given, as in Apache::Session::Store::Postgres
sub _commit {
    my ($args) = @_;
    return $args->{Commit} if ( exists $args->{Handle} );
    my $commit = $args->{Commit};
    return ( defined $commit and $commit ne '' ) ? $commit : 1;
}

# Whether the pool applies to these arguments: KeepConnections not disabled,
# writes committed, no noreuse, no Handle. $commit is the commit policy of
# the store, _commit($args) by default (the Patroni store has its own, see
# Store/Patroni.pm). Shared by connection(), by the Patroni store and by the
# class methods of Web::Session::PgJSON (see _lend()), so that they stay
# consistent
sub _poolApplies {
    my ( $args, $commit ) = @_;
    $commit = _commit($args) if ( @_ < 2 );

    # KeepConnections is on unless explicitly disabled: a missing or empty
    # value (configuration interfaces may store an empty option as '') keeps
    # the default
    my $keep = $args->{KeepConnections};
    $keep = 1 unless ( defined $keep and $keep ne '' );
    return (  $keep
          and $commit
          and !$args->{noreuse}
          and !exists $args->{Handle} ) ? 1 : 0;
}

# Key of the idle connections of a data source in %IDLE
sub _poolKey {
    my ( $datasource, $username ) = @_;
    return join "\0", $datasource // '', $username // '';
}

# Takes a connection to $datasource as $username of the pool, an idle one if
# possible, a new one otherwise. Without $datasource, connects to the data
# source of $args; $args also gives the MaxIdle, IdleTimeout and MaxLifetime
# options. Lent means removed from the idle ones: a connection is never lent
# twice at once. Returns the handle and what _giveBack() needs:
# { dbh, pool_key, pool_maxidle, pool_idle, pool_maxlife }
sub _borrow {
    my ( $args, $datasource, $username, $password ) = @_;
    if ( @_ < 2 ) {
        $datasource = $args->{DataSource}
          || $Apache::Session::Store::Postgres::DataSource;
        $username = $args->{UserName}
          || $Apache::Session::Store::Postgres::UserName;
        $password = $args->{Password}
          || $Apache::Session::Store::Postgres::Password;
    }
    my $key         = _poolKey( $datasource, $username );
    my $idleTimeout = _intArg( $args, 'IdleTimeout', $IDLE_TIMEOUT );
    my $maxLifetime = _intArg( $args, 'MaxLifetime', $MAX_LIFETIME );
    my $now         = time;
    my $dbh;
    while ( my $idle = pop @{ $IDLE{$key} ||= [] } ) {
        my ( $handle, $since ) = @$idle;

        # Inherited from the parent before a fork: its socket is the parent's.
        # AutoInactiveDestroy keeps this process from closing it
        next if ( $handle->{private_ws_pid} != $$ );

        # Idle for too long, a NAT or load balancer may have dropped it: a
        # ping could then wait for the TCP timeout. Closed without a ping
        if ( _expired( $handle, $since, $now, $idleTimeout, $maxLifetime )
            or !_usable( $handle, $since ) )
        {
            eval { $handle->disconnect };
            next;
        }
        $dbh = $handle;
        last;
    }
    unless ($dbh) {
        $dbh = DBI->connect(
            $datasource,
            $username,
            $password,
            {
                RaiseError          => 1,
                AutoCommit          => 1,
                AutoInactiveDestroy => 1,
                HandleError         => \&_flagError,
            }
        ) || die $DBI::errstr;
        $dbh->{private_ws_born} = time;
        $dbh->{private_ws_pid}  = $$;
        $dbh->{pg_enable_utf8}  = 1;
    }
    $dbh->{private_ws_error} = 0;
    return {
        dbh          => $dbh,
        pool_key     => $key,
        pool_drops   => $DROPS{$key} // 0,
        pool_maxidle => _intArg( $args, 'MaxIdle', $MAX_IDLE ),
        pool_idle    => $idleTimeout,
        pool_maxlife => $maxLifetime,
    };
}

# Lends to the store $self a connection to $datasource as $username (see
# _borrow()), given back by _giveBack() from DESTROY. The Patroni store calls
# it (as a fully qualified method, it doesn't inherit from this class) with
# the DSN of the primary it found.
sub _pooledConnection {
    my ( $self, $datasource, $username, $password, $args ) = @_;
    my $loan = _borrow( $args, $datasource, $username, $password );
    $self->{$_} = $loan->{$_} foreach ( keys %$loan );
    $self->{disconnect} = 0;
}

# Closes the idle connections of this process to the data source of key $key
# (see _poolKey()); those lent at this time are closed when given back. The
# Patroni store drops those to a former primary
sub _dropIdle {
    my ($key) = @_;
    $DROPS{$key}++;
    my $idle = delete $IDLE{$key} or return;
    local $@;
    foreach (@$idle) {
        my $h = $_->[0];

        # Inherited from a parent process: left to it (AutoInactiveDestroy)
        eval { $h->disconnect }
          if ( $h->{Active} and $h->{private_ws_pid} == $$ );
    }
}

# Gives back the connection $loan->{dbh} taken by _borrow(). $loan is a store
# or a Web::Session::Store::Postgres::Loan (a plain function: the Patroni
# store calls it as a fully qualified method)
sub _giveBack {
    my ($loan) = @_;
    my $key = $loan->{pool_key};
    my $dbh = delete $loan->{dbh} or return;
    local $@;    # disconnect() below must not clear the caller's $@

    # End of the program: the handles may already be freed, DBI closes them
    return if ( ${^GLOBAL_PHASE} eq 'DESTRUCT' );

    # Lent when the process forked: the connection belongs to the parent.
    # Neither given back nor closed here (AutoInactiveDestroy)
    return if ( $dbh->{private_ws_pid} != $$ );

    # The connection goes back to the idle ones with AutoCommit on (no
    # transaction left open, see the Patroni store), unless it met an error,
    # is too old or was lent before its data source was dropped (a former
    # Patroni primary). Expired idle
    # connections (at the bottom of the stack, never reached when the pool
    # stays busy) are closed now
    my $now  = time;
    my $idle = $IDLE{$key} ||= [];
    @$idle = grep {
        my ( $h, $since ) = @$_;
        if ( $h->{private_ws_pid} != $$ ) { 0 }
        elsif (
            _expired(
                $h, $since, $now, $loan->{pool_idle}, $loan->{pool_maxlife}
            )
          )
        {
            eval { $h->disconnect };
            0;
        }
        else { 1 }
    } @$idle;
    if (    !$dbh->{private_ws_error}
        and $dbh->{Active}
        and $dbh->{AutoCommit}
        and ( $DROPS{$key} // 0 ) == ( $loan->{pool_drops} // 0 )
        and $now - $dbh->{private_ws_born} <= $loan->{pool_maxlife}
        and @$idle < $loan->{pool_maxidle} )
    {
        push @$idle, [ $dbh, $now ];
        return;
    }
    eval { $dbh->disconnect };
}

# A connection of the pool lent outside of a store, for the duration of a
# class method of Web::Session::PgJSON (callers check _poolApplies() first).
# Returns a Web::Session::Store::Postgres::Loan object holding the handle in
# $loan->{dbh}, given back when the object is freed: when the method returns,
# and also when a query or a callback dies, so a connection never leaks.
sub _lend {
    my ( $class, $args ) = @_;
    return bless _borrow($args), 'Web::Session::Store::Postgres::Loan';
}

sub connection {
    my ( $self, $session ) = @_;
    $self->_forgetInheritedHandle;
    return if defined $self->{dbh};
    my $args = $session->{args};
    unless ( _poolApplies($args) ) {

        # AutoCommit off: see "Why AutoCommit differs" in Store/DBI.pm
        $self->_connection( $session, 'Apache::Session::Store::Postgres',
            { RaiseError => 1, AutoCommit => 0 } );
        $self->{dbh}->{pg_enable_utf8} = 1;
        $self->{commit} = _commit($args);
        return;
    }
    $self->{table_name} =
      $args->{TableName} || $Apache::Session::Store::DBI::TableName;
    my $loan = _borrow($args);
    $self->{$_}         = $loan->{$_} foreach ( keys %$loan );
    $self->{commit}     = 1;
    $self->{disconnect} = 0;
}

sub DESTROY {
    my $self = shift;
    return if ( $self->_forgetInheritedHandle );
    return $self->SUPER::DESTROY(@_) unless defined $self->{pool_key};
    _giveBack($self);
}

package Web::Session::Store::Postgres::Loan;

sub DESTROY {
    Web::Session::Store::Postgres::_giveBack( $_[0] );
}

1;
