package Web::Session::Store::Postgres;

use strict;

use DBI;
use Web::Session::Store::DBI;
use Apache::Session::Store::Postgres;

our @ISA =
  qw(Web::Session::Store::DBI Apache::Session::Store::Postgres);
our $VERSION = '1.0.0';

# KeepConnections: a pool of connections, per process and per data source
# (DataSource + UserName), lent to one store at a time: two sessions tied
# together (a session and its persistent session) never share a connection,
# so never a transaction. Used only when KeepConnections and Commit are set,
# noreuse isn't and no Handle is given; otherwise connection() is the one of
# the other stores (see _connection() in Store/DBI.pm).
#
# On that path each statement is its own transaction (AutoCommit): the store
# reads without a lock (Apache::Session::Store::DBI's materialize, no FOR
# UPDATE; the lock manager is Null), so a transaction around a tie protected
# nothing and cost a BEGIN and a COMMIT round trip each.
our %IDLE;    # "datasource\0user" => [ [ $dbh, $since ], ... ]

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

sub connection {
    my ( $self, $session ) = @_;
    return if defined $self->{dbh};
    my $args = $session->{args};
    unless ( $args->{KeepConnections}
        and $args->{Commit}
        and !$args->{noreuse}
        and !exists $args->{Handle} )
    {
        # AutoCommit off: see "Why AutoCommit differs" in Store/DBI.pm
        $self->_connection( $session, 'Apache::Session::Store::Postgres',
            { RaiseError => 1, AutoCommit => 0 } );
        $self->{dbh}->{pg_enable_utf8} = 1;
        return;
    }
    $self->{table_name} =
      $args->{TableName} || $Apache::Session::Store::DBI::TableName;
    my $datasource = $args->{DataSource}
      || $Apache::Session::Store::Postgres::DataSource;
    my $username = $args->{UserName}
      || $Apache::Session::Store::Postgres::UserName;
    my $password = $args->{Password}
      || $Apache::Session::Store::Postgres::Password;
    my $key         = join "\0", $datasource // '', $username // '';
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
    $self->{dbh}          = $dbh;
    $self->{pool_key}     = $key;
    $self->{pool_maxidle} = _intArg( $args, 'MaxIdle', $MAX_IDLE );
    $self->{pool_idle}    = $idleTimeout;
    $self->{pool_maxlife} = $maxLifetime;
    $self->{commit}       = $args->{Commit};
    $self->{disconnect}   = 0;
}

sub DESTROY {
    my $self = shift;
    my $key  = $self->{pool_key};
    return $self->SUPER::DESTROY(@_) unless defined $key;
    my $dbh = delete $self->{dbh} or return;

    # End of the program: the handles may already be freed, DBI closes them
    return if ( ${^GLOBAL_PHASE} eq 'DESTRUCT' );

    # Lent when the process forked: the connection belongs to the parent.
    # Neither given back nor closed here (AutoInactiveDestroy)
    return if ( $dbh->{private_ws_pid} != $$ );

    # Each statement committed itself (AutoCommit): the connection goes back
    # to the idle ones, unless it met an error or is too old. Expired idle
    # connections (at the bottom of the stack, never reached when the pool
    # stays busy) are closed now
    my $now  = time;
    my $idle = $IDLE{$key} ||= [];
    @$idle = grep {
        my ( $h, $since ) = @$_;
        if ( $h->{private_ws_pid} != $$ ) { 0 }
        elsif (
            _expired(
                $h, $since, $now, $self->{pool_idle}, $self->{pool_maxlife}
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
        and $now - $dbh->{private_ws_born} <= $self->{pool_maxlife}
        and @$idle < $self->{pool_maxidle} )
    {
        push @$idle, [ $dbh, $now ];
        return;
    }
    local $@;
    eval { $dbh->disconnect };
}

1;
