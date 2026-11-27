#!/usr/bin/perl
# Usage: check-version.pl <tag>
# Checks that the release tag (vX.Y.Z) matches the version declared in
# Build.PL, in every module, in Changes and in the RPM spec file.

use strict;
use warnings;
use File::Find;

my $tag = shift // die "Usage: $0 <tag>\n";
my ($version) = $tag =~ /^v(\d+\.\d+\.\d+)\z/
  or die "Tag '$tag' is not of the form vX.Y.Z\n";

my @errors;
my $check = sub {
    my ( $where, $found ) = @_;
    push @errors, "$where: " . ( $found // 'no version found' )
      unless ( defined $found and $found eq $version );
};

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "Can't read $file: $!\n";
    local $/;
    return <$fh>;
}

$check->( 'Build.PL dist_version',
    ( slurp('Build.PL') =~ /dist_version\s*=>\s*'([^']+)'/ )[0] );

find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless /\.pm\z/;
            $check->( $_,
                ( slurp($_) =~ /^\s*(?:our\s+)?\$VERSION\s*=\s*'([^']+)'/m )
                  [0] );
        },
    },
    'lib'
);

$check->( 'Changes (first entry)', ( slurp('Changes') =~ /^(\d[^\s(]*)/m )[0] );

foreach my $spec ( glob 'rpm/*.spec' ) {
    $check->( $spec,
        ( slurp($spec) =~ /^%define\s+real_version\s+(\S+)/m )[0] );
}

if (@errors) {
    print STDERR "Tag $tag (version $version) doesn't match:\n";
    print STDERR "  $_\n" foreach (@errors);
    exit 1;
}
print "Version $version is consistent\n";
