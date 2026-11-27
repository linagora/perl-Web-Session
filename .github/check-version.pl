#!/usr/bin/perl
# Usage: check-version.pl [<tag>]
# Checks that the version declared in Build.PL, in every module, in Changes
# and in the RPM spec file are the same, and match the release tag (vX.Y.Z)
# when one is given.

use strict;
use warnings;
use File::Find;

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "Can't read $file: $!\n";
    local $/;
    return <$fh>;
}

my ($buildVersion) = slurp('Build.PL') =~ /dist_version\s*=>\s*(['"])(.+?)\1/
  ? ($2)
  : ();
die "No dist_version found in Build.PL\n" unless defined $buildVersion;

my $tag = shift;
my $version;
if ( defined $tag ) {
    ($version) = $tag =~ /^v(\d+\.\d+\.\d+)\z/
      or die "Tag '$tag' is not of the form vX.Y.Z\n";
}
else {
    $version = $buildVersion;
}

my @errors;
my $check = sub {
    my ( $where, $found ) = @_;
    push @errors, "$where: " . ( $found // 'no version found' )
      unless ( defined $found and $found eq $version );
};

$check->( 'Build.PL dist_version', $buildVersion );

find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless /\.pm\z/;
            $check->(
                $_,
                slurp($_) =~ /^\s*(?:our\s+)?\$VERSION\s*=\s*(['"])(.+?)\1/m
                ? $2
                : undef
            );
        },
    },
    'lib'
);

$check->(
    'Changes (first entry)',
    slurp('Changes') =~ /^(\d+\.\d+(?:\.\d+)?)\b/m ? $1 : undef
);

my @specs = glob 'rpm/*.spec';
push @errors, 'rpm/: no spec file found' unless @specs;
foreach my $spec (@specs) {
    $check->( $spec,
        slurp($spec) =~ /^%define\s+real_version\s+(\S+)/m ? $1 : undef );
}

if (@errors) {
    print STDERR ( defined $tag ? "Tag $tag" : 'Build.PL' ),
      " (version $version) doesn't match:\n";
    print STDERR "  $_\n" foreach (@errors);
    exit 1;
}
print "Version $version is consistent\n";
