package Web::Session::Store::Redis;

use strict;

our $VERSION = '1.0.0';

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

# '00' is true
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

# Servers known to support HEXPIRE
our %hexpire;

# Fail at tie time: Apache::Session updates the session at untie, where an
# error is only a warning
sub _checkHexpire {
    my ( $redisObj, $args ) = @_;
    my $server = join ' ',
      map { ref($_) ? @$_ : $_ // '' } @$args{qw(server sock service sentinels)};
    return if ( $hexpire{$server} );

    # No index hash has this name. Other errors (read-only replica, ACL...) are
    # left to the commands that will fail
    unless (
        eval {
            $redisObj->hexpire( $HASH_INDEX_PREFIX, 1, 'FIELDS', 1, 'x' );
            1;
        }
      )
    {
        ( my $err = $@ ) =~ s/\n.*//s;
        die "utimeOffset needs Redis >= 7.4 or Valkey >= 9: $err\n"
          if ( $err =~ /unknown command/i );
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
    my ( $self, $session ) = @_;
    my $ttl = _ttl($session);
    $self->{cache}->set(
        $session->{data}->{_session_id},
        $session->{serialized}, ( $ttl ? ( 'EX', $ttl ) : () )
    );
}

# With utimeOffset, the session and its index entries are written in one
# transaction. The entries of a session that expires are fields of an index
# hash that expire with it (HEXPIRE: Redis >= 7.4, Valkey >= 9; otherwise
# Redis refuses the whole transaction); the others stay in index sets
sub _writeHashIndex {
    my ( $self, $session, $index, $old ) = @_;
    my $r   = $self->{cache};
    my $ttl = _ttl($session);
    my ( @cmds, $queueErr, $reply, $execErr );

    # $fatal: an error of this command fails the write, like outside a
    # transaction. Other errors are ignored (key of another type)
    my $queue = sub {
        my ( $cmd, $fatal, @args ) = @_;
        push @cmds, [ $cmd, $fatal ];
        $r->$cmd( @args,
            sub { $queueErr //= "[$cmd] $_[1]" if ( defined $_[1] ) } );
    };
    my $sent = eval {
        $r->multi(
            sub { $queueErr //= "[multi] $_[1]" if ( defined $_[1] ) } );
        $self->_queueHashIndex( $queue, $session, $index, $old, $ttl );
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
          if ( $err =~ /hexpire/i );
        die "$err\n";
    }
    foreach ( 0 .. $#cmds ) {
        my $err = $reply->[$_]->[1];
        die "[$cmds[$_]->[0]] $err\n" if ( defined $err and $cmds[$_]->[1] );
    }
}

sub _queueHashIndex {
    my ( $self, $queue, $session, $index, $old, $ttl ) = @_;
    my $data = $session->{data};
    my $id   = $data->{_session_id};
    $queue->(
        'set', 1, $id, $session->{serialized}, ( $ttl ? ( 'EX', $ttl ) : () )
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

    return $self->_writeHashIndex( $session, $index )
      if ( hashIndex( $session->{args} ) );
    my $id = $session->{data}->{_session_id};
    $self->_set($session);
    foreach my $i (@$index) {
        my $t = $session->{data}->{$i};
        next unless ( defined($t) and ( length($t) > 0 ) );
        $self->{cache}->sadd( keyName("${i}_$t"), $id );
    }
}

sub update {
    my ( $self, $session ) = @_;
    my $index =
      ref( $session->{args}->{Index} )
      ? $session->{args}->{Index}
      : [ split /\s+/, $session->{args}->{Index} ];

    my $id = $session->{data}->{_session_id};

    # Nothing to clean up without index
    unless (@$index) {
        $self->_set($session);
        return;
    }

    # Read old data to clean up stale index entries
    my $old_raw = eval { $self->{cache}->get($id) };
    if ($@) {
        warn "Failed to read previous session '$id' from Redis: $@";
    }
    # Decode it like the session itself: Redis returns Latin-1, not UTF-8
    my $old_data;
    if ( defined $old_raw && length $old_raw ) {
        my $old = { serialized => $old_raw };
        eval { $session->{unserialize}->($old) };
        if ($@) {
            warn "Failed to decode previous session '$id': $@";
        }
        else {
            $old_data = $old->{data};
        }
    }

    return $self->_writeHashIndex( $session, $index, $old_data )
      if ( hashIndex( $session->{args} ) );

    # Store new data
    $self->_set($session);

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
(C<HEXPIRE>), checked when the session is tied, and the C<MULTI> and
C<HEXPIRE> commands must be allowed (ACL, proxy). A session with a numeric C<_utime> expires at
C<_utime + utimeOffset>, and so do its index entries. Its Redis TTL is
computed when it is written, and isn't moved by an update that keeps
C<_utime>. A session already expired is kept 1 second. Sessions without such
a C<_utime> get C<TTL>, if set. C<0> disables this option.

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
written in one transaction (C<MULTI>). Searches read both.

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
