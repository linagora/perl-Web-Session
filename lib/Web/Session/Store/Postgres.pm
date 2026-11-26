package Web::Session::Store::Postgres;

use strict;

use DBI;
use Web::Session::Store::DBI;
use Apache::Session::Store::Postgres;

our @ISA =
  qw(Web::Session::Store::DBI Apache::Session::Store::Postgres);
our $VERSION = '1.4.0';

# KeepConnections: a pool of connections, per process and per data source
# (DataSource + UserName), lent to one store at a time: two sessions tied
# together (a session and its persistent session) never share a connection,
# so never a transaction. Used only when KeepConnections and Commit are set,
# noreuse isn't and no Handle is given; otherwise connection() is the one of the other
# stores (see _connection() in Store/DBI.pm).
#
# On that path each statement is its own transaction (AutoCommit): the store
# reads without a lock (Apache::Session::Store::DBI's materialize, no FOR
# UPDATE; the lock manager is Null), and a tie writes once, so a transaction
# around it protected nothing and cost a BEGIN and a COMMIT round trip each.
# That once: Apache::Session's TIEHASH inserts a new session at once, then
# its untie updates it with its data; here the insert waits for the untie and
# writes the data then, a single INSERT.
our %IDLE;    # "datasource\0user" => [ [ $dbh, $pid, $since ], ... ]

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
        my ( $handle, $pid, $since ) = @$idle;

        # Inherited from the parent before a fork: its socket is the parent's.
        # AutoInactiveDestroy keeps this process from closing it
        next if ( $pid != $$ );

        # Idle for too long, a NAT or load balancer may have dropped it: a
        # ping could then wait for the TCP timeout. Closed without a ping
        if (   $now - $since > $idleTimeout
            or $now - $handle->{private_ws_born} > $maxLifetime
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
        $dbh->{pg_enable_utf8}  = 1;
    }
    $dbh->{private_ws_error} = 0;
    $self->{dbh}          = $dbh;
    $self->{pool_key}     = $key;
    $self->{pool_maxidle} = _intArg( $args, 'MaxIdle', $MAX_IDLE );
    $self->{pool_maxlife} = $maxLifetime;
    $self->{commit}       = $args->{Commit};
    $self->{disconnect}   = 0;
}

# A new session: its insert waits for the untie (the update that follows), so
# that it is written once, with its data
sub insert {
    my ( $self, $session ) = @_;
    $self->connection($session);
    return $self->SUPER::insert($session) unless defined $self->{pool_key};

    # What the insert needs, copied: keeping $session would be a cycle (it
    # holds this store), and neither would ever be destroyed
    $self->{pending_insert} = {
        data       => { %{ $session->{data} } },
        serialized => $session->{serialized},
        args       => $session->{args},
    };
    return 1;
}

sub update {
    my ( $self, $session ) = @_;
    return $self->SUPER::insert($session) if delete $self->{pending_insert};
    return $self->SUPER::update($session);
}

sub remove {
    my ( $self, $session ) = @_;

    # Created and removed in the same tie: nothing was written
    return 1 if delete $self->{pending_insert};
    return $self->SUPER::remove($session);
}

sub DESTROY {
    my $self = shift;
    my $key  = $self->{pool_key};
    return $self->SUPER::DESTROY(@_) unless defined $key;
    my $dbh = $self->{dbh} or return;

    # A new session untied without an update: inserted now, as it was tied
    my $ok = 1;
    if ( my $pending = delete $self->{pending_insert} ) {
        local $@;
        $ok = eval { $self->SUPER::insert($pending); 1 };
        print STDERR "Unable to store the new session: $@" unless $ok;
    }
    delete $self->{dbh};

    # Each statement committed itself (AutoCommit): the connection goes back
    # to the idle ones, unless it met an error, is too old, or the program
    # ends
    if (    $ok
        and !$dbh->{private_ws_error}
        and $dbh->{Active}
        and time - $dbh->{private_ws_born} <= $self->{pool_maxlife}
        and ${^GLOBAL_PHASE} ne 'DESTRUCT'
        and @{ $IDLE{$key} ||= [] } < $self->{pool_maxidle} )
    {
        push @{ $IDLE{$key} }, [ $dbh, $$, time ];
        return;
    }
    local $@;
    eval { $dbh->disconnect };
}

1;
