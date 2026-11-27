#!/bin/sh
# Usage: build-deb.sh [Web-Session-X.Y.Z.tar.gz]
# Builds libweb-session-perl_X.Y.Z-1_all.deb in the current directory with
# dh-make-perl, from the given distribution or, without argument, from a
# distribution built from the current checkout. Installs the packaging tools
# with apt-get: run it as root in a Debian container (see the deb jobs of
# .github/workflows).

set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends dh-make-perl apt-file \
    build-essential libmodule-build-perl
apt-file update

if [ $# -gt 0 ]; then
    tarball=$1
else
    perl Build.PL
    ./Build dist
    tarball=$(ls Web-Session-*.tar.gz)
fi
version=${tarball##*Web-Session-}
version=${version%.tar.gz}
deb="libweb-session-perl_${version}-1_all.deb"

export DEBFULLNAME="${DEBFULLNAME:-Web::Session release}"
export DEBEMAIL="${DEBEMAIL:-noreply@github.com}"
export DEB_BUILD_OPTIONS=nocheck

work=$(mktemp -d)
tar xzf "$tarball" -C "$work"
(
    cd "$work/Web-Session-$version"
    dh-make-perl --packagename libweb-session-perl --vcs none
    perl -0pi -e '
        s/(^Package: libweb-session-perl\n(?:.+\n)*?)(Description:)/$1Recommends: libdbi-perl,
            libredis-fast-perl | libredis-perl,
            libnet-ldap-perl,
            libio-socket-timeout-perl,
            libauthen-sasl-perl
Suggests: libdbd-pg-perl,
          libdbd-mariadb-perl | libdbd-mysql-perl,
          libdbd-sqlite3-perl,
          libdbd-cassandra-perl,
          libwww-perl
$2/m or die "No binary stanza in debian/control\n"
    ' debian/control
    dpkg-buildpackage -us -uc -b -Pnocheck
)
mv "$work/$deb" .
rm -rf "$work"

dpkg-deb --info "$deb"
for field in Depends Recommends Suggests; do
    dpkg-deb --field "$deb" "$field" | grep -q . || {
        echo "$deb has no $field field" >&2
        exit 1
    }
done
dpkg-deb --field "$deb" Recommends | grep -q libdbi-perl
dpkg-deb --field "$deb" Suggests | grep -q libdbd-pg-perl
echo "Built $deb"
