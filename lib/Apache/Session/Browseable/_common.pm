package Apache::Session::Browseable::_common;

use strict;
use AutoLoader 'AUTOLOAD';

our $VERSION = '1.2.2';

# Number of sessions read per query by _forEachSession(). Values outside
# 1..1_000_000 fall back to the default (a huge value would break LIMIT)
our $BatchSize = 1000;

sub _tabInTab {
    my ( $class, $t1, $t2 ) = @_;

    # if no fields are required, return 0
    return 0 unless ( @$t1 and @$t2 );
    foreach my $f (@$t1) {
        unless ( grep { $_ eq $f } @$t2 ) {
            return 0;
        }
    }
    return 1;
}

sub _fieldIsIndexed {
    my ( $class, $args, $field ) = @_;
    my $index =
      ref( $args->{Index} ) ? $args->{Index} : [ split /\s+/, $args->{Index} ];
    return ( grep { $_ eq $field } @$index );
}

# Check the structure of a deleteIfLowerThan() rule
sub _checkRule {
    my ( $class, $rule ) = @_;
    unless ( ref($rule) eq 'HASH' ) {
        print STDERR "deleteIfLowerThan: rule must be a hash reference\n";
        return 0;
    }
    foreach my $type (qw(or and not)) {
        next unless defined $rule->{$type};
        unless ( ref( $rule->{$type} ) eq 'HASH' ) {
            print STDERR "deleteIfLowerThan: $type must be a hash reference\n";
            return 0;
        }
    }
    return 1;
}

# deleteIfLowerThan() thresholds are inserted into SQL queries, so they must
# be numbers
sub _checkThresholds {
    my ( $class, $rule ) = @_;
    return 1 unless ( ref($rule) eq 'HASH' );
    my $thresholds = $rule->{or} || $rule->{and};
    return 1 unless ( ref($thresholds) eq 'HASH' );
    foreach ( values %$thresholds ) {
        unless ( defined($_) and /^-?[0-9]+(?:\.[0-9]+)?\z/ ) {
            print STDERR "deleteIfLowerThan: threshold must be a number\n";
            return 0;
        }
    }
    return 1;
}

# Identifier (table or column name) inserted into an SQL query. It is quoted
# with the driver's quote_identifier() when the driver supports it the
# standard way. PostgreSQL folds unquoted names to lower case, so tables and
# columns created without quotes have lower case names: the name is
# lowercased before being quoted, which keeps the previous behaviour for
# names in mixed case (TableName => 'Sessions' still finds "sessions"). A
# "schema.table" name is quoted part by part, and a name that already
# contains quotes is left unchanged. Other drivers (Oracle, Sybase,
# Informix...) get the name as before: quoting would change its case or
# meaning there
sub _quoteIdentifier {
    my ( $class, $dbh, $name ) = @_;
    my $driver = $dbh->{Driver}->{Name};
    unless ( $driver =~ /^(?:Pg|mysql|MariaDB|SQLite)\z/ ) {
        $name =~ s/'/''/g;
        return $name;
    }
    return $name      if ( $name =~ /["`]/ );
    $name = lc($name) if ( $driver eq 'Pg' );
    return join '.', map { $dbh->quote_identifier($_) } split /\./, $name, -1;
}

# Column of an indexed field in SQL queries. Callers check Index with the
# field name, then insert the result of this method: backends that need
# another quoting override it
sub _quoteColumn {
    my ( $class, $dbh, $field ) = @_;
    return $class->_quoteIdentifier( $dbh, $field );
}

# Quoted table name, see _quoteIdentifier()
sub _tableName {
    my ( $class, $dbh, $args ) = @_;
    return $class->_quoteIdentifier( $dbh,
        $args->{TableName} || $Apache::Session::Store::DBI::TableName );
}

# Get the unserialize sub of a class (populate() may be inherited)
sub _unserializer {
    my ($class) = @_;
    my $p = $class->can('populate') or die "$class has no populate()\n";
    return $p->()->{unserialize};
}

# Call $sub->( $id, $serialized ) for each session. If the driver supports
# LIMIT, sessions are read by batches to avoid loading the whole table in
# memory. No server-side cursor here: $sub may reuse the database handle.
sub _forEachSession {
    my ( $class, $dbh, $table_name, $sub ) = @_;
    my ($limit) = ( $BatchSize // '' ) =~ /^\s*([1-9][0-9]*)\s*\z/;
    $limit = 1000 if ( !$limit or $limit > 1_000_000 );
    my $sql   = "SELECT id,a_session FROM $table_name";
    unless ( $dbh->{Driver}->{Name} =~ /^(?:Pg|mysql|MariaDB|SQLite)\z/ ) {
        my $sth = $dbh->prepare_cached($sql);
        $sth->execute;
        while ( my @row = $sth->fetchrow_array ) {
            $sub->(@row);
        }
        return;
    }

    # Not a single snapshot: rows inserted during the iteration with an id
    # lower than the current position are not visited (harmless for purge
    # and sessions explorer)
    my ( $last, $rows );
    do {
        my $sth =
          $dbh->prepare_cached( $sql
              . ( defined($last) ? ' WHERE id > ?' : '' )
              . " ORDER BY id LIMIT $limit" );
        $sth->execute( defined($last) ? ($last) : () );
        $rows = $sth->fetchall_arrayref;
        $sub->(@$_) foreach (@$rows);
        $last = $rows->[-1]->[0] if (@$rows);
    } while ( @$rows >= $limit );
    return;
}

# deleteIfLowerThan() thresholds are inserted into SQL queries, so they must
# be numbers
sub _checkThresholds {
    my ( $class, $rule ) = @_;
    return 1 unless ( ref($rule) eq 'HASH' );
    my $thresholds = $rule->{or} || $rule->{and};
    return 1 unless ( ref($thresholds) eq 'HASH' );
    foreach ( values %$thresholds ) {
        unless ( defined($_) and /^-?[0-9]+(?:\.[0-9]+)?\z/ ) {
            print STDERR "deleteIfLowerThan: threshold must be a number\n";
            return 0;
        }
    }
    return 1;
}

1;
__END__

sub searchOn {
    my ( $class, $args, $selectField, $value, @fields ) = splice @_;
    my %res = ();
    $class->get_key_from_all_sessions(
        $args,
        sub {
            my $entry = shift;
            my $id    = shift;
            return undef unless ( $entry->{$selectField} eq $value );
            if (@fields) {
                $res{$id}->{$_} = $entry->{$_} foreach (@fields);
            }
            else {
                $res{$id} = $entry;
            }
            undef;
        }
    );
    return \%res;
}

sub searchOnExpr {
    my ( $class, $args, $selectField, $value, @fields ) = splice @_;
    $value = quotemeta($value);
    $value =~ s/\\\*/\.\*/g;
    $value = qr/^$value$/;
    my %res = ();
    $class->get_key_from_all_sessions(
        $args,
        sub {
            my $entry = shift;
            my $id    = shift;
            return undef unless ( $entry->{$selectField} =~ $value );
            if (@fields) {
                $res{$id}->{$_} = $entry->{$_} foreach (@fields);
            }
            else {
                $res{$id} = $entry;
            }
            undef;
        }
    );
    return \%res;
}

1;

