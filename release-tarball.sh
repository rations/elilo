#!/bin/sh
# release-tarball.sh — build a release tarball for Devuan/Debian
#
# Usage:  ./release-tarball.sh <version>
# Example: ./release-tarball.sh 3.17
#
# Creates: elilo-<version>-devuan.tar.gz in the current directory.

set -e

VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release-tarball.sh <version>" >&2
    echo "  Example: ./release-tarball.sh 3.17" >&2
    exit 1
fi

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
cd "$SCRIPT_DIR"

DIRNAME="elilo-$VERSION-devuan"
TARBALL="$DIRNAME.tar.gz"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/$DIRNAME/scripts"
mkdir -p "$TMPDIR/$DIRNAME/hooks/postinst.d"
mkdir -p "$TMPDIR/$DIRNAME/hooks/postrm.d"

cp elilo.efi                                    "$TMPDIR/$DIRNAME/"
cp install-elilo.sh                             "$TMPDIR/$DIRNAME/"
cp README.md                                    "$TMPDIR/$DIRNAME/"
cp scripts/update-elilo                         "$TMPDIR/$DIRNAME/scripts/"
cp scripts/elilo-update.conf                    "$TMPDIR/$DIRNAME/scripts/"
cp hooks/postinst.d/zz-update-elilo             "$TMPDIR/$DIRNAME/hooks/postinst.d/"
cp hooks/postrm.d/zz-update-elilo               "$TMPDIR/$DIRNAME/hooks/postrm.d/"

chmod 755 "$TMPDIR/$DIRNAME/install-elilo.sh"
chmod 755 "$TMPDIR/$DIRNAME/scripts/update-elilo"
chmod 755 "$TMPDIR/$DIRNAME/hooks/postinst.d/zz-update-elilo"
chmod 755 "$TMPDIR/$DIRNAME/hooks/postrm.d/zz-update-elilo"
chmod 644 "$TMPDIR/$DIRNAME/elilo.efi"
chmod 644 "$TMPDIR/$DIRNAME/README.md"
chmod 644 "$TMPDIR/$DIRNAME/scripts/elilo-update.conf"

tar -czf "$TARBALL" -C "$TMPDIR" "$DIRNAME"

echo "Created: $TARBALL"
echo ""
tar -tzf "$TARBALL"
