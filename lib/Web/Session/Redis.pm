package Web::Session::Redis;

use strict;

use Apache::Session;
use Web::Session::Store::Redis;
use Web::Session::Generate::SHA256;
use Apache::Session::Lock::Null;
use Web::Session::Serialize::JSON;
use Web::Session::_common;

our $VERSION = '1.0.0';
our @ISA     = qw(Apache::Session);

sub populate {
    my $self = shift;

    $self->{object_store} = new Web::Session::Store::Redis $self;
    $self->{lock_manager} = new Apache::Session::Lock::Null $self;
    $self->{generate}     = \&Web::Session::Generate::SHA256::generate;
    $self->{validate}     = \&Web::Session::Generate::SHA256::validate;
    $self->{serialize}    = \&Web::Session::Serialize::JSON::serializeLatin1;
    $self->{unserialize} =
      \&Web::Session::Serialize::JSON::unserializeLatin1;

    return $self;
}

# Key name sent to Redis, see Store::Redis::keyName()
sub _keyName {
    return Web::Session::Store::Redis::keyName(@_);
}

# Index sets, plus index hashes with utimeOffset: [ name, is a hash ]. The
# prefix is ASCII, so the name of a hash keeps the Latin-1 or UTF-8 encoding
# of the name of the set
sub _indexNames {
    my ( $args, $name ) = @_;
    return (
        [ $name, 0 ],
        (
            Web::Session::Store::Redis::hashIndex($args)
            ? [ $Web::Session::Store::Redis::HASH_INDEX_PREFIX . $name, 1 ]
            : ()
        )
    );
}

# SCAN patterns for searchOnExpr(). The name of a set is Latin-1 unless it
# holds characters above U+00FF, so a wildcard may stand for such characters
# while the literal part is not ASCII: the UTF-8 form is then scanned too
sub _exprPatterns {
    my ( $field, $value ) = @_;
    my $pattern = _exprPattern( $field, $value );
    my @res     = ( _keyName($pattern) );
    if ( $value =~ /\*/ ) {
        my $p = $pattern;
        utf8::encode($p);
        push @res, $p unless ( $p eq $res[0] );
    }
    return @res;
}

sub unserialize {
    my $session = shift;
    my $tmp     = { serialized => $session };
    Web::Session::Serialize::JSON::unserializeLatin1($tmp);
    return $tmp->{data};
}

# Keys per SCAN call (a hint for Redis)
our $SCAN_COUNT = 1000;

# Keys per MGET: a huge index set must not block Redis with one big command
our $MGET_BATCH = 500;

# Like $redisObj->mget(@keys), in batches. MGET returns undef for missing
# keys and keys that aren't strings
sub _mget {
    my ( $redisObj, @keys ) = @_;
    my @res;
    while (@keys) {
        push @res, $redisObj->mget( splice( @keys, 0, $MGET_BATCH ) );
    }
    return @res;
}

# Members of index sets @$sets (index hashes if $hash), read in one pipeline:
# { set => [ keys ] }. A key of another type is ignored; other Redis errors
# are raised
sub _smembers {
    my ( $redisObj, $sets, $hash ) = @_;
    return _indexMembers( $redisObj, [ map { [ $_, $hash ] } @$sets ] );
}

# Same as _smembers() for index sets and hashes @$names: [ name, is a hash ]
sub _indexMembers {
    my ( $redisObj, $names ) = @_;
    my ( %res, $fatal );
    foreach my $name (@$names) {
        my ( $set, $hash ) = @$name;
        my $cmd = $hash ? 'hkeys' : 'smembers';
        $redisObj->$cmd(
            $set,
            sub {
                my ( $reply, $err ) = @_;
                if ($err) {
                    $fatal //= $err unless ( $err =~ /WRONGTYPE/ );
                }
                else {
                    $res{$set} = $reply;
                }
            }
        );
    }
    $redisObj->wait_all_responses;
    die $fatal if ($fatal);
    return \%res;
}

# Remove session KEYS[2] from index KEYS[1] only if it doesn't exist, in one
# step: a concurrent writer may be recreating it
our $SREM_ORPHAN = q{if redis.call('exists',KEYS[2])==0 then }
  . q{return redis.call('srem',KEYS[1],KEYS[2]) end return 0};
our $HDEL_ORPHAN = q{if redis.call('exists',KEYS[2])==0 then }
  . q{return redis.call('hdel',KEYS[1],KEYS[2]) end return 0};

our $lua_warned;

# Remove orphan session $k from index set $set (index hash if $hash). Without
# Lua (EVAL forbidden by ACL, proxy...), WATCH the session so that a
# concurrent writer aborts the removal. $k must have been checked with
# isLlngKey()
sub _removeOrphan {
    my ( $class, $redisObj, $set, $k, $hash ) = @_;
    return
      if (
        eval {
            $redisObj->eval( ( $hash ? $HDEL_ORPHAN : $SREM_ORPHAN ),
                2, $set, $k );
            1;
        }
      );
    unless ($lua_warned) {
        $lua_warned = 1;
        print STDERR "Redis EVAL failed, orphan index members are removed "
          . "without Lua: $@\n";
    }
    my $err;
    eval {
        $redisObj->watch($k);
        if ( $redisObj->exists($k) ) {
            $redisObj->unwatch;
        }
        else {
            $redisObj->multi;
            $hash ? $redisObj->hdel( $set, $k ) : $redisObj->srem( $set, $k );
            $redisObj->exec;
        }
    };
    if ($@) {
        $err = $@;
        eval { $redisObj->discard };
        eval { $redisObj->unwatch };
        print STDERR "Unable to remove '$k' from index $set: $err\n";
    }
}

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = @_;

    my %res = ();
    if ( $class->isIndexed( $args, $selectField ) ) {

        my $redisObj = $class->_getRedis($args);
        my ( @keys, %index, %seen );
        my @names   = _indexNames( $args, _keyName("${selectField}_$value") );
        my $members = _indexMembers( $redisObj, \@names );
        foreach my $name (@names) {

            # Members of another application are neither read nor removed
            foreach ( @{ $members->{ $name->[0] } || [] } ) {
                next unless ( $_ and $class->isLlngKey( $args, $_ ) );
                push @{ $index{$_} }, $name;
                push @keys, $_ unless ( $seen{$_}++ );
            }
        }
        my %values;
        @values{@keys} = _mget( $redisObj, @keys );
        foreach my $k (@keys) {
            my $tmp = $values{$k};
            unless ($tmp) {
                # Lazy cleanup: remove orphan from index
                $class->_removeOrphan( $redisObj, $_->[0], $k, $_->[1] )
                  foreach ( @{ $index{$k} } );
                next;
            }
            eval {
                $tmp = unserialize($tmp);

                # The index may be stale or shared with another field
                # ("a_b" + "c" and "a" + "b_c" give the same set name)
                return
                  unless ( defined $tmp->{$selectField}
                    and $tmp->{$selectField} eq $value );
                if (@fields) {
                    $res{$k}->{$_} = $tmp->{$_} foreach (@fields);
                }
                else {
                    $res{$k} = $tmp;
                }
            };
            if ($@) {
                print STDERR "Error in session $k: $@\n";
                delete $res{$k};
            }
        }
    }
    else {
        $class->get_key_from_all_sessions(
            $args,
            sub {
                my $entry = shift;
                my $id    = shift;
                return undef
                  unless ( defined $entry->{$selectField}
                    and $entry->{$selectField} eq $value );
                if (@fields) {
                    $res{$id}->{$_} = $entry->{$_} foreach (@fields);
                }
                else {
                    $res{$id} = $entry;
                }
                undef;
            }
        );
    }
    return \%res;
}

# Regexp of the names matched by the SCAN pattern $glob: '*' is its only
# wildcard, a backslash escapes the next character
sub _globRe {
    my ($glob) = @_;
    my $re = join '',
      map { $_ eq '*' ? '.*' : quotemeta( substr( $_, -1 ) ) }
      $glob =~ /(\\.|.)/gs;
    return qr/^$re\z/s;
}

# Call $cb->( \@sets, $hash ) for each SCAN page of the index sets matching
# $pattern and, with utimeOffset, of the index hashes: "*$pattern" matches
# both, so that the keyspace is walked once. @opts are given to SCAN
sub _scanIndexes {
    my ( $redisObj, $args, $pattern, $cb, @opts ) = @_;
    my $hash = Web::Session::Store::Redis::hashIndex($args);
    my ( $setRe, $hashRe );
    if ($hash) {
        $setRe  = _globRe($pattern);
        $hashRe = _globRe(
            _globEscape($Web::Session::Store::Redis::HASH_INDEX_PREFIX)
              . $pattern );
    }
    my $cursor = 0;
    do {
        my ( $new_cursor, $keys ) = $redisObj->scan( $cursor,
            MATCH => ( $hash ? "*$pattern" : $pattern ),
            @opts );
        if ($hash) {
            $cb->( [ grep { $_ =~ $setRe } @$keys ], 0 );
            $cb->( [ grep { $_ =~ $hashRe } @$keys ], 1 );
        }
        else {
            $cb->( $keys, 0 );
        }
        $cursor = $new_cursor;
    } while ( $cursor != 0 );
}

# searchOnExpr() patterns: '*' is a wildcard
sub _exprRe {
    my ($value) = @_;
    $value = quotemeta($value);
    $value =~ s/\\\*/\.\*/g;
    return qr/^$value$/;
}

# Redis glob escape: MATCH patterns of SCAN must find names literally
sub _globEscape {
    my ($s) = @_;
    $s =~ s/([*?\[\]\\])/\\$1/g;
    return $s;
}

# SCAN pattern of the index sets for searchOnExpr(): '*' is the only
# wildcard of the value. The sessions are checked afterwards with _exprRe()
sub _exprPattern {
    my ( $field, $value ) = @_;
    $value =~ s/([?\[\]\\])/\\$1/g;
    return _globEscape($field) . "_$value";
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = @_;
    my %res;
    my $re = _exprRe($value);
    if ( $class->isIndexed( $args, $selectField ) ) {
        my $redisObj = $class->_getRedis($args);
        foreach my $pattern ( _exprPatterns( $selectField, $value ) ) {
            _scanIndexes(
                $redisObj, $args, $pattern,
                sub {
                    my ( $sets, $hash ) = @_;

                    # The sets of a SCAN page are read together: a few round
                    # trips instead of two per set. Members of another
                    # application are neither read nor removed
                    my $members = _smembers( $redisObj, $sets, $hash );
                    foreach my $set ( keys %$members ) {
                        $members->{$set} =
                          [ grep { $_ and $class->isLlngKey( $args, $_ ) }
                              @{ $members->{$set} } ];
                    }
                    my %seen;
                    my @keys =
                      grep { !$seen{$_}++ } map { @$_ } values %$members;
                    my %values;
                    @values{@keys} = _mget( $redisObj, @keys );
                    foreach my $set ( keys %$members ) {
                        foreach my $k ( @{ $members->{$set} } ) {
                            my $v = $values{$k};
                            unless ($v) {
                                # Lazy cleanup: remove orphan from index
                                $class->_removeOrphan( $redisObj, $set, $k,
                                    $hash );
                                next;
                            }
                            my $tmp = eval { unserialize($v) };
                            if ( $@ or ref($tmp) ne 'HASH' ) {
                                print STDERR "Error in session $k: "
                                  . ( $@ || "not a session\n" );
                                next;
                            }

                            # The pattern may match sets of another field
                            unless ( defined $tmp->{$selectField}
                                and $tmp->{$selectField} =~ $re )
                            {
                                next;
                            }
                            $res{$k} =
                              $class->extractFields( $tmp, @fields );
                        }
                    }
                },
                COUNT => $SCAN_COUNT
            );
        }
    }
    else {
        $class->get_key_from_all_sessions(
            $args,
            sub {
                my ( $entry, $id ) = @_;
                return undef unless ( $entry->{$selectField} =~ $re );
                $res{$id} = $class->extractFields( $entry, @fields );
                undef;
            }
        );
    }
    return \%res;
}

sub searchLt {
    my $class = shift;
    return $class->_searchCompare( '<', @_ );
}

sub searchGt {
    my $class = shift;
    return $class->_searchCompare( '>', @_ );
}

# Trimmed number, or undef
sub _number {
    my ($v) = @_;
    return undef unless ( defined($v) and !ref($v) );
    $v =~ s/^\s+|\s+$//g;
    return $v =~ /^-?[0-9]+(?:\.[0-9]+)?\z/ ? $v : undef;
}

# Sessions where $selectField isn't a number (see _number()) are skipped.
# Indexed field: SCAN walks the keyspace server-side and returns only the
# index sets of $selectField; only sets holding a matching value are read.
# Used by purges: Redis errors are reported and the sets ignored
sub _searchCompare {
    my ( $class, $op, $args, $selectField, $value, @fields ) = @_;

    # LLNG CLI keeps spaces around the value ("--where 'f < 123 '")
    $value = _number($value);
    unless ( defined $value ) {
        print STDERR 'search'
          . ( $op eq '<' ? 'Lt' : 'Gt' )
          . ": value must be a number\n";
        return {};
    }
    my $test = sub {
        my $v = _number(shift);
        return 0 unless ( defined $v );
        return $op eq '<' ? $v < $value : $v > $value;
    };
    my %res;
    unless ( $class->isIndexed( $args, $selectField ) ) {
        $class->get_key_from_all_sessions(
            $args,
            sub {
                my ( $entry, $id ) = @_;
                $res{$id} = $class->extractFields( $entry, @fields )
                  if ( $test->( $entry->{$selectField} ) );
                undef;
            }
        );
        return \%res;
    }

    my $redisObj = $class->_getRedis($args);
    my $prefix   = "${selectField}_";
    ( my $pattern = $prefix ) =~ s/([*?\[\]\\])/\\$1/g;
    _scanIndexes(
        $redisObj, $args,
        "$pattern*",
        sub {
            my ( $sets, $hash ) = @_;
            my $cmd  = $hash ? 'hkeys' : 'smembers';
            my $skip = length($prefix) + (
                $hash
                ? length($Web::Session::Store::Redis::HASH_INDEX_PREFIX)
                : 0
            );

            # Sets of other fields ("${selectField}_x_1") aren't numbers
            foreach my $set ( grep { $test->( substr( $_, $skip ) ) } @$sets )
            {
                my @keys = eval { $redisObj->$cmd($set) };
                if ($@) {
                    print STDERR "Error when reading index $set: $@\n"
                      unless ( $@ =~ /WRONGTYPE/ );
                    next;
                }
                foreach my $k (@keys) {

                    # Members of another application are neither read nor
                    # removed
                    next
                      unless ( $k
                        and !exists $res{$k}
                        and $class->isLlngKey( $args, $k ) );
                    my $v = eval { $redisObj->get($k) };
                    if ($@) {
                        print STDERR "Error when reading $k: $@\n"
                          unless ( $@ =~ /WRONGTYPE/ );
                        next;
                    }
                    unless ($v) {

                        # Lazy cleanup: remove orphan from index
                        $class->_removeOrphan( $redisObj, $set, $k, $hash );
                        next;
                    }
                    my $tmp = eval { unserialize($v) };
                    if ( $@ or ref($tmp) ne 'HASH' ) {
                        print STDERR "Error in session $k: "
                          . ( $@ || "not a session\n" );
                        next;
                    }

                    # The index may be stale: check the session itself
                    $res{$k} = $class->extractFields( $tmp, @fields )
                      if ( $test->( $tmp->{$selectField} ) );
                }
            }
        }
    );
    return \%res;
}

# Decide if a session must be purged. Like Lemonldap::NG's generic purge,
# only a missing _utime means "expired": any other missing field is not lower
# than the threshold (so a session without _lastSeen is not purged by it).
sub _isDominated {
    my ( $class, $v, $rule ) = @_;

    # Empty or data-less sessions should be purged
    return 1 if ( !$v || !%$v || !exists $v->{_session_id} );
    if ( $rule->{or} ) {
        foreach ( keys %{ $rule->{or} } ) {
            if ( !defined( $v->{$_} ) ) {

                # Session without _utime: treat as expired
                return 1 if $_ eq '_utime';
                next;
            }
            return 1 if $v->{$_} < $rule->{or}->{$_};
        }
    }
    elsif ( $rule->{and} ) {
        foreach ( keys %{ $rule->{and} } ) {
            if ( !defined( $v->{$_} ) ) {

                # Only a missing _utime counts as lower
                return 0 unless $_ eq '_utime';
                next;
            }
            return 0 unless $v->{$_} < $rule->{and}->{$_};
        }
        return 1;
    }
    return 0;
}

sub deleteIfLowerThan {
    my ( $class, $args, $rule ) = @_;

    # Same contract as the SQL backends: an invalid rule deletes nothing
    return wantarray ? ( 0, 0 ) : 0
      unless ( Web::Session::_common->_checkRule($rule)
        and Web::Session::_common->_checkThresholds($rule) );
    my $deleted  = 0;
    my $redisObj = $class->_getRedis($args);
    my $index =
      ref( $args->{Index} )
      ? $args->{Index}
      : [ split /\s+/, $args->{Index} ];

    $class->get_key_from_all_sessions(
        $args,
        sub {
            my ( $v, $k ) = @_;
            if ( $rule->{not} ) {
                foreach ( keys %{ $rule->{not} } ) {
                    if (defined( $v->{$_} ) and $v->{$_} eq $rule->{not}->{$_}) {
                        return ();
                    }
                }
            }
            my $dominated = $class->_isDominated( $v, $rule );
            if ($dominated) {
                # Clean up index entries before deleting the session
                my $index_ok = 1;
                foreach my $i (@$index) {
                    my $t = $v->{$i};
                    next unless ( defined($t) and length($t) > 0 );
                    foreach ( _indexNames( $args, _keyName("${i}_$t") ) ) {
                        my ( $name, $hash ) = @$_;
                        eval {
                            $hash
                              ? $redisObj->hdel( $name, $k )
                              : $redisObj->srem( $name, $k );
                        };
                        if ($@) {
                            warn "Failed to remove '$k' from index '$name': $@";
                            $index_ok = 0;
                        }
                    }
                }
                if ($index_ok) {
                    $redisObj->del($k);
                    $deleted++;
                }
                else {
                    warn "Skipping deletion of session '$k' due to index cleanup failure";
                }
            }
            return ();
        },
    );
    return ( 1, $deleted );
}

sub extractFields {
    my ( $class, $entry, @fields ) = @_;
    my $res;
    if (@fields) {
        $res->{$_} = $entry->{$_} foreach (@fields);
    }
    else {
        $res = $entry;
    }
    return $res;
}

sub isIndexed {
    my ( $class, $args, $field ) = @_;
    my $indexes =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    return grep { $_ eq $field } @$indexes;
}

my %keysRe_re;
sub isLlngKey {
    my ( $class, $args, $name ) = @_;
    my $expr = $args->{keysRe} || '^[0-9a-f]{32,}$';

    # Compile per expression: a process may use several keysRe
    $keysRe_re{$expr} = qr/$expr/ unless ( exists $keysRe_re{$expr} );
    return ( $name =~ $keysRe_re{$expr} );
}

sub get_key_from_all_sessions {
    my ( $class, $args, $data ) = @_;
    my %res;

    my $redisObj = $class->_getRedis($args);
    my $cursor   = 0;
    do {
        my ( $new_cursor, $keys ) = $redisObj->scan($cursor);
        foreach my $k (@$keys) {

            # Keep only our keys
            next unless $class->isLlngKey( $args, $k );

            # Don't scan sets,...
            next unless $redisObj->type($k) eq 'string';
            eval {
                my $v = $redisObj->get($k);
                next unless $v;
                my $tmp = unserialize($v);
                if ( ref($data) eq 'CODE' ) {
                    $tmp = &$data( $tmp, $k );
                    $res{$k} = $tmp if ( defined($tmp) );
                }
                elsif ($data) {
                    $data = [$data] unless ( ref($data) );
                    $res{$k}->{$_} = $tmp->{$_} foreach (@$data);
                }
                else {
                    $res{$k} = $tmp;
                }
            };
            if ($@) {
                print STDERR "Error in session $k: $@\n";

                # Don't delete, it may own to another app
                #delete $res{$k};
            }
        }
        $cursor = $new_cursor;
    } while ( $cursor != 0 );
    return \%res;
}

sub _getRedis {
    my ( $class, $args ) = @_;
    return Web::Session::Store::Redis->_getRedis($args);
}

1;
__END__

=encoding utf8

=head1 NAME

Web::Session::Redis - Add index and search methods to
Apache::Session::Redis

=head1 SYNOPSIS

  use Web::Session::Redis;

  my $args = {
       server => '127.0.0.1:6379',

       # Select database (optional)
       #database => 0,

       # Use a persistent connection to the Redis server
       # (value is the connection cache key)
       # You'll probably also want to set
       # read_timeout, write_timeout, reconnect and every
       reuse => "myserver",

       # Choose your browseable fields
       Index          => 'uid mail',

       # Optional: set a Redis TTL on session keys (in seconds)
       # TTL => 86400,

       # Optional: expire sessions at _utime + utimeOffset, see
       # Web::Session::Store::Redis
       # utimeOffset => 79200,
  };
  
  # Use it like Apache::Session
  my %session;
  tie %session, 'Web::Session::Redis', $id, $args;
  $session{uid} = 'me';
  $session{mail} = 'me@me.com';
  $session{unindexedField} = 'zz';
  untie %session;
  
  # Web::Session add some global class methods
  #
  # 1) search on a field (indexed or not)
  my $hash = Web::Session::Redis->searchOn( $args, 'uid', 'me' );
  foreach my $id (keys %$hash) {
    print $id . ":" . $hash->{$id}->{mail} . "\n";
  }

  # 2) Parse all sessions
  # a. get all sessions
  my $hash = Web::Session::Redis->get_key_from_all_sessions($args);

  # b. get some fields from all sessions
  my $hash = Web::Session::Redis->get_key_from_all_sessions($args, 'uid', 'mail')

  # c. execute something with datas from each session :
  #    Example : get uid and mail if mail domain is
  my $hash = Web::Session::Redis->get_key_from_all_sessions(
              $args,
              sub {
                 my ( $session, $id ) = @_;
                 if ( $session->{mail} =~ /mydomain.com$/ ) {
                     return { $session->{uid}, $session->{mail} };
                 }
              }
  );
  foreach my $id (keys %$hash) {
    print $id . ":" . $hash->{$id}->{uid} . "=>" . $hash->{$id}->{mail} . "\n";
  }

=head1 DESCRIPTION

Web::Session provides some class methods to manipulate all
sessions and add the capability to index some fields to make research faster.

This module use either L<Redis::Fast> or L<Redis>.

Untying a session never recreates it if it was deleted or expired since it
was tied (see L<Web::Session::Store::Redis>).

=head1 searchLt() AND searchGt()

  # Sessions where _oidcRtUpdate < $time (or > $time)
  my $hash = Web::Session::Redis->searchLt(
      $args, '_oidcRtUpdate', $time );
  $hash = Web::Session::Redis->searchGt(
      $args, '_oidcRtUpdate', $time, 'uid', 'client_id' );

They return sessions whose field is strictly lower (or greater) than the
given value, like L<searchOn()|/SYNOPSIS>: C<{ id =E<gt> session }>, or only
the requested fields. The comparison is numeric.

Leading and trailing spaces of the value are removed, then it must match
C</^-?[0-9]+(?:\.[0-9]+)?\z/>. Otherwise, an error is
printed on STDERR and an empty hash is returned.

Sessions where the field is missing, empty or not a number (same check as the
value, so C<Inf> or C<1e3> are skipped) are never returned. This differs from
the SQL backends, which compare a non-numeric value as 0 (and cast its numeric
prefix: C<250x> is 250), so C<searchLt($args, 'f', 10)> returns a session
where C<f> is C<abc> with them, but not with Redis. Numbers must be written
in plain decimal form to be found. Likewise, the Perl fallback of
Lemonldap::NG, used with backends that don't provide these methods, compares
a missing field as 0.

If the field isn't listed in C<Index>, all sessions are read and decoded. If
it is, Redis still walks the whole keyspace (C<SCAN ... MATCH field_*>, or
C<*field_*> to find the index hashes too with C<utimeOffset>), but
server-side: only the index sets of this field (C<field_value> keys) are
returned, and only the sessions of sets holding a matching value are read.
Orphan entries of these sets are removed; keys that don't match C<keysRe>
are ignored.

For the Lemonldap::NG purge of OpenID Connect refresh tokens, add
C<_oidcRtUpdate> to C<Index>. Sessions stored before a field is added to
C<Index> are not in its index until they are saved again, and refresh tokens
are saved only when used: inactive ones won't be found by C<searchLt()> and
will only be purged when C<_utime> expires. To index them at once, re-save
them:

  my $rt = Web::Session::Redis->get_key_from_all_sessions(
      $args, sub { $_[0]->{_oidcRtUpdate} } );
  foreach my $id ( keys %$rt ) {
      tie my %s, 'Web::Session::Redis', $id, $args;
      $s{_oidcRtUpdate} = $s{_oidcRtUpdate};
      untie %s;
  }

This also refreshes their C<TTL> or, with C<utimeOffset>, recomputes their
expiration from C<_utime>.

=head1 CHARACTERS ABOVE U+00FF

Redis clients refuse characters above U+00FF. Sessions are stored as JSON
where such characters (and only them) are written as C<\uXXXX> escapes, so
they are supported: the stored value is the same as before for a session
holding only Latin-1 characters. Index set names (C<field_value>) are sent as
Latin-1 bytes when they can be, so existing sets keep working, and as UTF-8
bytes otherwise. The name of a value above U+00FF may then be the same as the
Latin-1 name of another value (C<uid_\x{3a9}> and C<uid_\x{ce}\x{a9}>).

Index sets are updated after the session is written, without a transaction.
If the same session is updated concurrently by two processes, a stale member
can remain in the index set of a previous value. C<searchOn> only removes
members whose session no longer exists and doesn't check the indexed value
again, so such a session may be returned for a value it no longer has. With
C<utimeOffset>, the index entries are written in the same transaction as the
session, but the previous value is read before: the same can happen. The
stale entry then expires with the session, unless the session doesn't expire.

=head1 SEE ALSO

L<Apache::Session>

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
