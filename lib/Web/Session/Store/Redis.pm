package Web::Session::Store::Redis;

use strict;
use JSON;

our $VERSION = '1.0.0';

# Key of the session object holding the result of update(), see "DESCRIPTION"
use constant STATUS => 'web_session_redis_update';

# Key of the session object holding the version read, see _writeMerged()
use constant READ => 'web_session_redis_read';

# Writes tried before a session updated concurrently is overwritten
our $MAX_TRIES = 5;

our $redis;
our %reused_connections;

BEGIN {
    $redis = 'Redis::Fast';
    eval 'use Redis::Fast';
    if ($@) {
        require Redis;
        $redis = 'Redis';
    }
}

# Redis clients croak on characters above U+00FF: key names built from a field
# name or a value are sent as Latin-1 bytes (existing index sets keep their
# name) or, if they hold such characters, as UTF-8 bytes
sub keyName {
    my $name = shift;
    $name = "$name";
    utf8::encode($name) unless ( utf8::downgrade( $name, 1 ) );
    return $name;
}

our $HASH_INDEX_PREFIX = 'hidx:';

# Index set of value $value of field $field
sub indexName {
    my ( $field, $value ) = @_;
    return keyName("${field}_$value");
}

# Index hash of value $value of field $field, used with utimeOffset
sub hashIndexName {
    my ( $field, $value ) = @_;
    return keyName("$HASH_INDEX_PREFIX${field}_$value");
}

# '00' is truthy: the numeric test disables it
sub hashIndex {
    my ($args) = @_;
    return ( $args->{utimeOffset} and $args->{utimeOffset} > 0 );
}

sub new {
    my ( $class, $session ) = @_;
    my $self;

    my $offset = $session->{args}->{utimeOffset};
    die "utimeOffset must be a number of seconds\n"
      if ( defined $offset
        and length $offset
        and $offset !~ /^[0-9]{1,10}\z/ );

    my $args = $session->{args};
    $self->{cache} = $class->_getRedis($args);
    _checkHexpire( $self->{cache}, $args )
      if ( hashIndex($args)
        and ( ref( $args->{Index} ) ? @{ $args->{Index} } : $args->{Index} ) );

    bless $self, $class;
}

# Result of the HEXPIRE probe per server: 1 if supported, otherwise
# [ time of the next probe (undef: never), error to raise ]
our %hexpire;

# Seconds before probing again a read-only replica
our $READONLY_RETRY = 60;

# Fail at tie time: Apache::Session updates the session at untie, where an
# error is only a warning
sub _checkHexpire {
    my ( $redisObj, $args ) = @_;
    my $server = join ' ',
      map { ref($_) ? @$_ : $_ // '' } @$args{qw(server sock service sentinels)};
    if ( my $known = $hexpire{$server} ) {
        return unless ( ref $known );
        my ( $retry, $die ) = @$known;
        if ( !defined $retry or time < $retry ) {
            die $die if ($die);
            return;
        }
    }

    # No index hash has this name. Errors other than a missing command (ACL,
    # read-only replica...) are left to the commands that will fail. So that
    # each tie doesn't pay a failed round trip, a missing command and NOPERM
    # are remembered until the process ends, READONLY for $READONLY_RETRY
    # seconds only (a Sentinel failover may promote the replica). Other errors
    # may be transient
    unless (
        eval {
            $redisObj->hexpire( $HASH_INDEX_PREFIX, 1, 'FIELDS', 1, 'x' );
            1;
        }
      )
    {
        ( my $err = $@ ) =~ s/\n.*//s;
        if ( $err =~ /unknown command/i ) {
            my $die = "utimeOffset needs Redis >= 7.4 or Valkey >= 9: $err\n";
            $hexpire{$server} = [ undef, $die ];
            die $die;
        }
        if ( $err =~ /\bNOPERM\b/ ) {
            $hexpire{$server} = [undef];
        }
        elsif ( $err =~ /\bREADONLY\b/ ) {
            $hexpire{$server} = [ time + $READONLY_RETRY ];
        }
        else {
            delete $hexpire{$server};
        }
        return;
    }
    $hexpire{$server} = 1;
}

# Expiration of a session in seconds, see "OPTIONS"
sub _ttl {
    my ($session) = @_;
    my $args = $session->{args};
    my $data = $session->{data};

    # Persistent sessions keep the _utime of their creation and never expire
    if (    hashIndex($args)
        and defined $data->{_utime}
        and $data->{_utime} =~ /^[0-9]+(?:\.[0-9]+)?\z/
        and ( $data->{_session_kind} // '' ) ne 'Persistent' )
    {
        my $ttl = int( $data->{_utime} + $args->{utimeOffset} - time );

        # An expired session is still written: it may be read again before
        # the end of the request
        return $ttl > 0 ? $ttl : 1;
    }
    return $args->{TTL};
}

sub _set {
    my ( $self, $session, @opts ) = @_;
    my $ttl = _ttl($session);
    return $self->{cache}->set(
        $session->{data}->{_session_id},
        $session->{serialized}, ( $ttl ? ( 'EX', $ttl ) : () ), @opts
    );
}

# XX: another process may have deleted the session (logout, revocation,
# purge) or Redis may have expired it since it was read; a plain SET would
# write it back
sub _overwrite {
    my ( $self, $session ) = @_;
    return 1 if ( defined $self->_set( $session, 'XX' ) );
    _warnDeleted( $session->{data}->{_session_id} );
    return 0;
}

sub _warnDeleted {
    warn "Session '$_[0]' was deleted or expired, not stored again\n";
}

# With utimeOffset, the session and its index entries are written in one
# transaction. The entries of a session that expires are fields of an index
# hash that expire with it (HEXPIRE: Redis >= 7.4, Valkey >= 9; otherwise
# Redis refuses the whole transaction); the others stay in index sets. $xx:
# overwrite an existing session only. Returns false if it doesn't exist,
# undef if EXEC was aborted by a WATCH of the caller
sub _writeHashIndex {
    my ( $self, $session, $index, $old, $xx ) = @_;
    my $r   = $self->{cache};
    my $ttl = _ttl($session);
    my ( @cmds, $queueErr, $reply, $execErr );

    # $fatal: an error of this command fails the write, like outside a
    # transaction. Other errors are ignored (key of another type)
    my $queue = sub {
        my ( $cmd, $fatal, @args ) = @_;
        push @cmds, [ $cmd, $fatal, @args ];
        $r->$cmd( @args,
            sub { $queueErr //= "[$cmd] $_[1]" if ( defined $_[1] ) } );
    };
    my $sent = eval {
        $r->multi(
            sub { $queueErr //= "[multi] $_[1]" if ( defined $_[1] ) } );
        $self->_queueHashIndex( $queue, $session, $index, $old, $ttl, $xx );
        $r->exec( sub { ( $reply, $execErr ) = @_ } );
        $r->wait_all_responses;
        1;
    };

    # A connection left in a transaction would queue the next commands
    unless ($sent) {
        my $err = $@;
        eval { $r->wait_all_responses };
        eval { $r->discard };
        die $err;
    }
    if ( my $err = $queueErr // $execErr ) {
        die "utimeOffset needs Redis >= 7.4 or Valkey >= 9: $err\n"
          if ( $err =~ /unknown command/i );
        die "$err\n";
    }
    return undef unless ( defined $reply );
    die "[exec] unexpected reply\n"
      unless ( ref($reply) eq 'ARRAY'
        and @$reply == @cmds
        and !grep { ref($_) ne 'ARRAY' } @$reply );
    foreach ( 0 .. $#cmds ) {
        my $err = $reply->[$_]->[1];
        die "[$cmds[$_]->[0]] $err\n" if ( defined $err and $cmds[$_]->[1] );
    }
    return 1 if ( defined $reply->[0]->[0] );

    # SET XX refused: the entries added in the transaction are orphans
    foreach ( grep { $_->[0] =~ /^(?:hset|sadd)\z/ } @cmds ) {
        my ( $cmd, undef, $name, $id ) = @$_;
        eval {
            $cmd eq 'hset' ? $r->hdel( $name, $id ) : $r->srem( $name, $id );
        };
    }
    return 0;
}

sub _queueHashIndex {
    my ( $self, $queue, $session, $index, $old, $ttl, $xx ) = @_;
    my $data = $session->{data};
    my $id   = $data->{_session_id};
    $queue->(
        'set', 1, $id, $session->{serialized},
        ( $ttl ? ( 'EX', $ttl ) : () ),
        ( $xx  ? 'XX'           : () )
    );
    foreach my $i (@$index) {
        my $old_val = $old ? $old->{$i} : undef;
        my $new_val = $data->{$i};
        my $add     = ( defined($new_val) and length($new_val) > 0 );
        if (    defined($old_val)
            and length($old_val) > 0
            and ( !$add or $old_val ne $new_val ) )
        {
            $queue->( 'srem', 0, indexName( $i, $old_val ), $id );
            $queue->( 'hdel', 0, hashIndexName( $i, $old_val ), $id );
        }
        next unless ($add);
        my $set  = indexName( $i, $new_val );
        my $hash = hashIndexName( $i, $new_val );
        if ($ttl) {

            # The set holds the sessions stored before utimeOffset was set
            $queue->( 'srem',    0, $set,  $id );
            $queue->( 'hset',    1, $hash, $id, 1 );
            $queue->( 'hexpire', 1, $hash, $ttl, 'FIELDS', 1, $id );
        }
        else {
            $queue->( 'hdel', 0, $hash, $id );
            $queue->( 'sadd', 1, $set,  $id );
        }
    }
}

sub insert {
    my ( $self, $session ) = @_;
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    if ( @$index and hashIndex( $session->{args} ) ) {
        $self->_writeHashIndex( $session, $index )
          // die "[exec] unexpected reply\n";
    }
    else {
        my $id = $session->{data}->{_session_id};
        $self->_set($session);
        foreach my $i (@$index) {
            my $t = $session->{data}->{$i};
            next unless ( defined($t) and ( length($t) > 0 ) );
            $self->{cache}->sadd( keyName("${i}_$t"), $id );
        }
    }
    $session->{ +READ }   = $session->{serialized};
    $session->{ +STATUS } = 'written';
    return 1;
}

# True if the session was stored
sub update {
    my ( $self, $session ) = @_;
    delete $session->{ +STATUS };
    $session->{ +STATUS } = $self->_update($session);
    return $session->{ +STATUS } eq 'deleted' ? 0 : 1;
}

# Returns the status of the update, see "DESCRIPTION"
sub _update {
    my ( $self, $session ) = @_;
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    return $self->_updateHashIndex( $session, $index )
      if ( @$index and hashIndex( $session->{args} ) );

    my $id = $session->{data}->{_session_id};
    my $old_data;

    my $status = 'overwritten';
    if ( defined $session->{ +READ } ) {
        ( $status, my $old_raw ) = $self->_writeMerged( $session, $id );
        return $status if ( $status eq 'deleted' or !@$index );
        $old_data = _decodeOld( $session, $old_raw );
    }
    else {

        # The version read is unknown (unserialize isn't the one installed by
        # Web::Session::Redis): overwrite. Nothing to clean up without index
        unless (@$index) {
            return $self->_overwrite($session) ? $status : 'deleted';
        }

        # Read old data to clean up stale index entries
        my $old_raw = eval { $self->{cache}->get($id) };
        if ($@) {
            warn "Failed to read previous session '$id' from Redis: $@";
        }
        $old_data = _decodeOld( $session, $old_raw );

        return 'deleted' unless ( $self->_overwrite($session) );
    }

    foreach my $i (@$index) {
        my $old_val = defined($old_data) ? $old_data->{$i} : undef;
        my $new_val = $session->{data}->{$i};

        # Remove old index entry if value changed
        if ( defined($old_val) && length($old_val) > 0 ) {
            if ( !defined($new_val)
                || length($new_val) == 0
                || $old_val ne $new_val )
            {
                eval { $self->{cache}->srem( keyName("${i}_$old_val"), $id ) };
            }
        }

        # Add new index entry
        if ( defined($new_val) && length($new_val) > 0 ) {
            $self->{cache}->sadd( keyName("${i}_$new_val"), $id );
        }
    }
    return $status;
}

# Decoded like the session itself: Redis returns Latin-1, not UTF-8
sub _decode {
    my ( $session, $raw ) = @_;
    my $tmp = { serialized => $raw };
    $session->{unserialize}->($tmp);
    return $tmp->{data};
}

# Previous version, whose index entries are replaced
sub _decodeOld {
    my ( $session, $raw ) = @_;
    return undef unless ( defined $raw and length $raw );
    my $data = eval { _decode( $session, $raw ) };
    if ($@) {
        my $id = $session->{data}->{_session_id};
        warn "Failed to decode previous session '$id': $@";
    }
    return $data;
}

# Sessions aren't locked (see "DESCRIPTION"): a write is accepted only if Redis
# still holds the version this process read, otherwise the caller's changes are
# merged into the stored version and the write is tried again. Returns the
# status of the update and the version replaced
sub _writeMerged {
    my ( $self, $session, $id ) = @_;
    my $expected = $session->{ +READ };
    my $merge    = _merger( $session, $id );
    my ( $merged, $failed );
    for ( 1 .. $MAX_TRIES ) {
        my ( $res, $cur ) =
          @{ $self->_compareAndSet( $id, $expected, $session->{serialized},
                _ttl($session) ) };
        if ( $res eq 'written' ) {
            $session->{ +READ } = $session->{serialized};
            return ( $merged ? 'merged' : 'written', $expected );
        }
        if ( $res eq 'deleted' ) {
            _warnDeleted($id);
            return ('deleted');
        }
        next if ( $res eq 'aborted' );
        if ( $res eq 'refused' ) {
            _warnUnchecked($cur);
            $failed = 1;
            last;
        }
        $expected = $cur;
        unless ( $merge->($expected) ) {
            $failed = 1;
            last;
        }
        $merged = 1;
    }
    _warnOverwrite($id) unless ($failed);
    return ('deleted') unless ( $self->_overwrite($session) );
    $session->{ +READ } = $session->{serialized};
    return ( 'overwritten', $expected );
}

# Same as _writeMerged() with index hashes: the version check is part of the
# transaction of _writeHashIndex(), so that the index entries replaced are
# those of the version replaced. WATCH aborts EXEC if the session changes after
# GET; if WATCH is refused, the transaction is run without it. Without the
# version read, the session is overwritten. Returns the status of the update
sub _updateHashIndex {
    my ( $self, $session, $index ) = @_;
    my $r        = $self->{cache};
    my $id       = $session->{data}->{_session_id};
    my $expected = $session->{ +READ };
    my $status   = defined($expected) ? 'written' : 'overwritten';
    my $merge    = _merger( $session, $id );
    my ( $cur, $done, $failed );
    eval {
        for ( 1 .. $MAX_TRIES ) {
            unless ( eval { $r->watch($id); 1 } ) {
                my $err = $@;
                die $err unless ( _refused($err) );
                _warnUnchecked($err);
                $failed = 1;
                $cur    = $r->get($id);
                $done   = 0 unless ( defined $cur );
                last;
            }
            $cur = $r->get($id);
            unless ( defined $cur ) {
                $r->unwatch;
                $done = 0;
                last;
            }
            if ( defined $expected and $cur ne $expected ) {
                $r->unwatch;
                $expected = $cur;
                $status   = 'merged';
                next if ( $merge->($cur) );
                $failed = 1;
                last;
            }

            # undef: the session changed after GET, read it again
            $done = $self->_writeHashIndex( $session, $index,
                _decodeOld( $session, $cur ), 1 );
            last if ( defined $done );
        }
        1;
    } or do {
        my $err = $@;
        eval { $r->unwatch };
        die $err;
    };

    # Not watched: the index entries replaced are those of the last version
    # read
    unless ( defined $done ) {
        _warnOverwrite($id) unless ($failed);
        $status = 'overwritten';
        $done   = $self->_writeHashIndex( $session, $index,
            _decodeOld( $session, $cur ), 1 )
          // die "[exec] unexpected reply\n";
    }
    unless ($done) {
        _warnDeleted($id);
        return 'deleted';
    }
    $session->{ +READ } = $session->{serialized};
    return $status;
}

# Refusals that a retry won't change: ACL, command renamed or not supported by
# a proxy. Connection errors are not
sub _refused {
    return $_[0] =~ /\bNOPERM\b|unknown command|not (?:allowed|supported)/i
      || $_[0] =~ /unsupported|forbid/i;
}

our $unchecked_warned;

sub _warnUnchecked {
    return if ($unchecked_warned);
    $unchecked_warned = 1;

    # First line only: Redis::Fast adds a backtrace holding the arguments
    my ($err) = split /\n/, $_[0];
    warn "Redis refused WATCH/MULTI, concurrent updates of sessions are not "
      . "merged: $err\n";
}

sub _warnOverwrite {
    warn "Session '$_[0]' was updated concurrently too often, overwriting it\n";
}

# Returns a function that applies to the version stored, its argument, what
# the caller changed since the version it read, and serializes the result in
# $session. It returns false, with a warning, if they can't be merged
sub _merger {
    my ( $session, $id ) = @_;
    my ( $orig, $new );
    return sub {
        my ($cur) = @_;
        my $merged = eval {
            $orig //= _decode( $session, $session->{ +READ } );
            $new  //= $session->{data};
            _merge( $orig, _decode( $session, $cur ), $new, $id );
        };
        unless ( ref($merged) eq 'HASH' ) {
            warn "Unable to merge session '$id' with a concurrent update, "
              . "overwriting it: "
              . ( $@ || "not a session\n" );
            return 0;
        }
        $session->{data} = $merged;
        $session->{serialize}->($session);
        return 1;
    };
}

# Three-way merge of top-level keys: what the caller changed or deleted since
# $orig is applied to $cur
sub _merge {
    my ( $orig, $cur, $new, $id ) = @_;
    my %res = %$cur;
    foreach my $k ( keys %$orig ) {
        delete $res{$k} unless ( exists $new->{$k} );
    }
    foreach my $k ( keys %$new ) {
        $res{$k} = $new->{$k}
          unless ( exists $orig->{$k} and _same( $orig->{$k}, $new->{$k} ) );
    }
    $res{_session_id} = $id;
    return \%res;
}

my $cmpJson = JSON->new->canonical->allow_nonref;

# A number used as a string is still the same value: scalars are compared
# with eq, references by their canonical JSON
sub _same {
    my ( $x, $y ) = @_;
    return !defined($y) unless ( defined $x );
    return 0            unless ( defined $y );
    return $x eq $y unless ( ref($x) or ref($y) );
    return 0        unless ( ref($x) and ref($y) );
    return eval { $cmpJson->encode($x) eq $cmpJson->encode($y) } ? 1 : 0;
}

# KEYS[1]: session, ARGV: version read, new version, TTL or ''
our $CAS = q{local cur = redis.call('get', KEYS[1])
if not cur then return {'deleted'} end
if cur ~= ARGV[1] then return {'conflict', cur} end
if ARGV[3] == '' then redis.call('set', KEYS[1], ARGV[2], 'XX')
else redis.call('set', KEYS[1], ARGV[2], 'EX', ARGV[3], 'XX') end
return {'written'}};

our $lua_warned;

# Write $serialized if $id still holds $expected. Returns ['written'],
# ['deleted'], ['conflict', current version], ['aborted'] or ['refused', error].
# Without Lua (EVAL forbidden by ACL, proxy...), WATCH the session so that a
# concurrent write aborts EXEC
sub _compareAndSet {
    my ( $self, $id, $expected, $serialized, $ttl ) = @_;
    my $redisObj = $self->{cache};
    my $res      = eval {
        $redisObj->eval( $CAS, 1, $id, $expected, $serialized,
            ( $ttl ? $ttl : '' ) );
    };
    return $res if ( ref($res) eq 'ARRAY' and !$@ );
    unless ($lua_warned) {
        $lua_warned = 1;

        # First line only: Redis::Fast adds a backtrace holding the arguments,
        # that is the session id and data
        my ($err) = split /\n/, ( $@ || 'unexpected reply' );
        print STDERR "Redis EVAL failed, sessions are updated without Lua: "
          . "$err\n";
    }
    eval {
        $redisObj->watch($id);
        my $cur = $redisObj->get($id);
        if ( !defined $cur or $cur ne $expected ) {
            $redisObj->unwatch;
            $res = defined($cur) ? [ 'conflict', $cur ] : ['deleted'];
            return 1;
        }
        $redisObj->multi;
        $ttl
          ? $redisObj->set( $id, $serialized, 'EX', $ttl, 'XX' )
          : $redisObj->set( $id, $serialized, 'XX' );
        my $done = $redisObj->exec;

        # undef: the session changed after GET
        $res =
            !$done             ? ['aborted']
          : defined( $done->[0] ) ? ['written']
          :                         ['deleted'];
        1;
    } or do {
        my $err = $@;
        eval { $redisObj->discard };
        eval { $redisObj->unwatch };
        return [ 'refused', $err ] if ( _refused($err) );
        die $err;
    };
    return $res;
}

sub materialize {
    my ( $self, $session ) = @_;
    $session->{serialized} =
      $self->{cache}->get( $session->{data}->{_session_id} )
      or die 'Object does not exist in data store.';
}

sub remove {
    my ( $self, $session ) = @_;
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    my $id   = $session->{data}->{_session_id};
    my $hash = hashIndex( $session->{args} );
    foreach my $i (@$index) {
        my $t;
        next unless ( $t = $session->{data}->{$i} );
        eval { $self->{cache}->srem( indexName( $i, $t ), $id ); };
        eval { $self->{cache}->hdel( hashIndexName( $i, $t ), $id ); }
          if ($hash);
    }
    $self->{cache}->del($id);
}

sub _getRedis {
    my $class = shift;
    my $args  = shift;
    my $redisObj;

    # Manage undef encoding
    $args->{encoding} = undef
      if (  $args->{encoding}
        and $args->{encoding} eq "undef" );

    # If sentinels is not given as an array ref, try to parse
    # a comma delimited list instead
    if ( $args->{sentinels}
        and ref $args->{sentinels} ne 'ARRAY' )
    {
        $args->{sentinels} =
          [ split /[,\s]+/, $args->{sentinels} ];
    }

    if (    $args->{reuse}
        and $reused_connections{ $args->{reuse} } )
    {
        $redisObj = $reused_connections{ $args->{reuse} };
    }
    else {
        $redisObj = $redis->new( %{$args} );
        if ( $args->{reuse} ) {
            $reused_connections{ $args->{reuse} } = $redisObj;
        }
    }

    # Manage database
    $redisObj->select( $args->{database} )
      if defined $args->{database};
    return $redisObj;
}

1;
__END__

=pod

=encoding utf8

=head1 NAME

Web::Session::Store::Redis - An implementation of
Apache::Session::Store

=head1 SYNOPSIS

 use Web::Session::Redis;
 
 tie %hash, 'Web::Session::Redis', $id, {
    # optional: default to localhost
    server => '127.0.0.1:6379',

    # optional: set a Redis TTL (in seconds) on session keys
    TTL => 86400,

    # optional: expire sessions at _utime + utimeOffset (Lemonldap::NG)
    utimeOffset => 79200,
 };

=head1 DESCRIPTION

This module is an implementation of Web::Session. It uses the
Redis storage system.

Sessions are not locked: a lock would not protect Lemonldap::NG, whose local
cache reads a cached session without taking it. Instead, an update is written
only if Redis still holds the version read when the session was tied: it
sends that version along with the new one, to a Lua script (C<EVAL>), or uses
C<WATCH>/C<MULTI>/C<EXEC> when C<EVAL> is refused (ACL, proxy). With
C<utimeOffset> and C<Index>, the check is part of the C<MULTI> transaction
that writes the session and its index entries (C<WATCH> and C<GET> of the
session, then C<MULTI>/C<EXEC>, aborted if it changes meanwhile), without
Lua: the index entries replaced are those of the version replaced. Each
update thus transfers the session about twice: the version read is sent with
the new one, or read back with C<GET>.

If another process updated the session meanwhile, the changes made since the
read are applied, key by key, to the stored version, and the write is tried
again:

=over

=item * concurrent changes of different keys are all kept;

=item * a key deleted by one process stays deleted, unless the other one
writes it too: the last write wins;

=item * a key changed by both: the last write wins.

=back

The expiration given by C<utimeOffset> is computed from the merged session.
After 5 tries, the session is overwritten with the last merge and a warning
is printed. A session deleted (logout, revocation, purge) or expired since it
was tied is not written back nor indexed again; a warning is printed instead.

If neither C<EVAL> nor C<WATCH>/C<MULTI> is allowed (C<NOPERM>, command
unknown or not supported by a proxy), a warning is printed once per process
and the session is overwritten if it still exists (C<SET ... XX>): concurrent
updates are not merged and the last write wins, but a deleted session is
still not written back. With C<utimeOffset> and C<Index>, if C<WATCH> is
refused, the transaction runs without it, with the same consequences;
C<MULTI> is required. Other errors, such as a lost connection, are raised.

The version read is known only when the session was read with the
C<unserialize> of L<Web::Session::Redis>; otherwise the update overwrites the
session if it still exists (C<SET ... XX>).

C<update()> returns true if the session was stored, false otherwise, and
records the outcome in C<< $session->{web_session_redis_update} >>:

=over

=item * C<written>: the session was stored, no other process had updated it
since it was read;

=item * C<merged>: the session was stored after merging concurrent updates;

=item * C<overwritten>: the session was stored without this check (version
read unknown, check refused by Redis, too many concurrent updates or merge
impossible): a concurrent update may have been lost;

=item * C<deleted>: the session was deleted or expired, it was not stored.

=back

C<< $session->{serialized} >> then holds the version stored, merged if
needed.

A wrapper that caches the session before calling C<update()>, such as the
local cache of Lemonldap::NG, keeps in its cache, until the cache entry
expires, a session deleted meanwhile (not stored again, but still served by
this node from its cache) or the version before the merge. To avoid it, a
wrapper should cache C<< $session->{serialized} >> after C<update()>, and
only if it returned true.

=head1 OPTIONS

=over

=item B<TTL>

Optional. If set, session keys will be stored with a Redis TTL (in seconds)
using C<SET key value EX ttl>. The TTL is refreshed on every update. This
acts as a safety net: sessions are automatically removed by Redis if the
application fails to delete them. Index sets are not expired by Redis, but
orphan index entries will be cleaned up by C<searchOn>, C<searchOnExpr>,
C<searchLt>, C<searchGt> or manual maintenance.

Without this option or C<utimeOffset>, session keys have no expiration and
must be explicitly deleted or purged.

=item B<utimeOffset>

Optional, in seconds. With C<Index>, it requires Redis 7.4 or Valkey 9
(C<HEXPIRE>), checked when the session is tied, and the C<WATCH>, C<MULTI>
and C<HEXPIRE> commands must be allowed (ACL, proxy). A session with a numeric
C<_utime> expires at C<_utime + utimeOffset>, and so do its index entries.
Its Redis TTL is computed when it is written, and isn't moved by an update
that keeps C<_utime>. A session already expired is kept 1 second. Sessions
without such a C<_utime> get C<TTL>, if set. C<0> disables this option.

All the nodes sharing the sessions must use the same C<utimeOffset>,
C<Index> and C<TTL>. A node without C<utimeOffset> rewrites a session
without this expiration (only C<TTL>, if set), and indexes it in the index
sets while its entries stay in the index hashes until they expire.

Lemonldap::NG considers that a session expires at C<_utime + timeout> (it
shifts C<_utime> of the sessions that have their own lifetime, such as OpenID
Connect offline sessions), so C<utimeOffset> must be at least its C<timeout>.
Add a margin: the TTL of stored sessions isn't changed when C<timeout> is
increased. With the default C<timeout> (72000 seconds),
C<utimeOffset =E<gt> 79200> keeps a margin of 2 hours.

Persistent sessions (C<_session_kind> is C<Persistent>) are excluded: their
C<_utime> is their creation time and they must not expire. They get C<TTL>,
if set.

B<Index>: Redis can't expire the members of a set, so the index entries of a
session that expires are the fields of an index hash, C<hidx:field_value>,
that expire with the session. The entries of sessions that don't expire stay
in the index set C<field_value>. The session and its index entries are
written in one transaction (C<MULTI>). Searches read both. The C<hidx:>
prefix is reserved: no indexed field name may start with it.

Index sets written before C<utimeOffset> was set are still read: a session
leaves them when it is written again, deleted or purged.

Without C<utimeOffset>, index hashes are not read anymore. To remove it,
re-save the sessions with the new arguments, or the ones indexed in hashes
won't be found by searches until they expire:

  my $all = Web::Session::Redis->get_key_from_all_sessions( $args, sub { 1 } );
  foreach my $id ( keys %$all ) {
      tie my %s, 'Web::Session::Redis', $id, $args;
      $s{_session_id} = $s{_session_id};
      untie %s;
  }

=back

=head1 SEE ALSO

L<Web::Session>, L<Apache::Session::NoSQL>, L<Apache::Session>

=head1 COPYRIGHT AND LICENSE

=over

=item 2009-2026 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2026 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
