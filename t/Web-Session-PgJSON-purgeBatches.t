use strict;
use Test::More;
use Web::Session::PgJSON;
use Web::Session::Patroni;

# deleteIfLowerThan() with a mocked handle: no database needed. Checks the
# statements, the bound values and the return contract.

package MockDbh;

sub new { my ( $c, @counts ) = @_; bless { counts => [@counts], log => [] }, $c }

sub do {
    my ( $self, $sql, $attr, @bind ) = @_;
    push @{ $self->{log} }, [ $sql, @bind ];
    my $n = shift @{ $self->{counts} };
    die "mock failure\n" if ( defined $n and $n eq 'die' );
    return $n;
}

package main;

my $dbh;
{
    no warnings 'redefine';
    *Web::Session::PgJSON::_classDbh   = sub { $dbh };
    *Web::Session::_common::_tableName = sub { 'sessions' };
}

my $rule =
  { or => { _utime => 200 }, not => { _session_kind => 'Persistent' } };

sub run {
    my ( $counts, $batch, $class ) = @_;
    $dbh = MockDbh->new(@$counts);
    local $Web::Session::_common::BatchSize = $batch;
    return ( $class || 'Web::Session::PgJSON' )
      ->deleteIfLowerThan( {}, $rule );
}

my @r = run( [ 2, 2, 1 ], 2 );
is_deeply( \@r, [ 1, 5 ], 'List context: total of all batches' );
is( scalar @{ $dbh->{log} }, 3, '3 statements: stops on a short batch' );
like(
    $dbh->{log}->[0]->[0],
qr/^DELETE FROM sessions WHERE id IN \(SELECT id FROM sessions WHERE .* LIMIT 2\)\z/s,
    'Batch statement'
);
is_deeply(
    [ map { [ @$_[ 1 .. $#$_ ] ] } @{ $dbh->{log} } ],
    [ ['Persistent'], ['Persistent'], ['Persistent'] ],
    'Bound values given to each batch'
);

@r = run( [ 2, 2, 0 ], 2 );
is_deeply( \@r, [ 1, 4 ], 'A last empty batch ends the loop' );
is( scalar @{ $dbh->{log} }, 3, '3 statements' );

@r = run( ['0E0'], 1000 );
is_deeply( \@r, [ 1, 0 ], 'Nothing to delete' );
is( scalar @{ $dbh->{log} }, 1, '1 statement' );
like( $dbh->{log}->[0]->[0], qr/LIMIT 1000\)/, 'Default size' );

@r = run( [1], 'bad' );
like( $dbh->{log}->[0]->[0], qr/LIMIT 1000\)/, 'Invalid size: default' );

@r = run( [-1], 5 );
is_deeply( \@r, [ 1, 0 ], 'Unknown count (-1) ends the loop' );

my $s = do {
    $dbh = MockDbh->new(1);
    Web::Session::PgJSON->deleteIfLowerThan( {}, $rule );
};
is( $s, 1, 'Scalar context' );

{
    local *STDERR;
    my $err = '';
    open STDERR, '>', \$err;
    @r = run( [ 2, 'die' ], 2 );
    is_deeply( \@r, [ 0, 0 ], 'Error in a batch: (0,0)' );
    like( $err, qr/^deleteIfLowerThan: mock failure/, 'Error on STDERR' );
    $dbh = MockDbh->new('die');
    $s   = Web::Session::PgJSON->deleteIfLowerThan( {}, $rule );
    is( $s, 0, 'Error in scalar context: 0' );
}

@r = run( [1], 2, 'Web::Session::Patroni' );
is_deeply( \@r, [ 1, 1 ], 'Patroni inherits batches' );

done_testing;
