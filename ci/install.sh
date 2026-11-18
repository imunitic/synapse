#!/bin/sh
# Installs Synapse Desktop on a Mac with Apple Silicon into ~/Applications:
#
#   curl -fsSL https://github.com/imunitic/synapse/releases/latest/download/install.sh | sh
#
# The release workflow fills in the two values below with the release's own
# version and download folder, so this script installs the version of the
# release it is attached to. It downloads that version's tarball and the
# release's SHA256SUMS, installs only when the tarball's hash is the listed one,
# and replaces ~/Applications/Synapse Desktop.app.
#
# A file downloaded with curl carries no com.apple.quarantine attribute, so
# Gatekeeper does not assess the app, and its ad-hoc signature is enough for it
# to start. The attribute is removed from the installed app anyway, so a
# tarball downloaded in a browser installs the same way.
set -eu

VERSION="@VERSION@"
BASE_URL="@BASE_URL@"

die() {
  echo "install.sh: $*" >&2
  exit 1
}

case "$VERSION" in @*) die "this copy has not been made for a release" ;; esac
[ "$(uname -s)" = Darwin ] || die "this installs the macOS app"
[ "$(uname -m)" = arm64 ] || die "the macOS app is built for Apple Silicon only"

name="synapse-desktop_${VERSION}_macos-arm64.tar.gz"
dest="$HOME/Applications"
mkdir -p "$dest"

# Inside the destination, so that the final move is a rename on one volume.
work=$(mktemp -d "$dest/.synapse-desktop.XXXXXX")
trap 'rm -rf "$work"' EXIT

curl -fsSL "$BASE_URL/$name" -o "$work/$name" || die "could not download $BASE_URL/$name"
curl -fsSL "$BASE_URL/SHA256SUMS" -o "$work/SHA256SUMS" ||
  die "could not download $BASE_URL/SHA256SUMS; it appears a few minutes after the release, try again shortly"

want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$work/SHA256SUMS")
[ -n "$want" ] || die "$name is not listed in SHA256SUMS"
got=$(shasum -a 256 "$work/$name" | awk '{ print $1 }')
[ "$got" = "$want" ] || die "the checksum of $name is $got, not the listed $want"

mkdir "$work/app"
tar -xzf "$work/$name" -C "$work/app"
[ -d "$work/app/Synapse Desktop.app" ] || die "$name has no Synapse Desktop.app"
xattr -dr com.apple.quarantine "$work/app/Synapse Desktop.app" 2>/dev/null || true

rm -rf "$dest/Synapse Desktop.app"
mv "$work/app/Synapse Desktop.app" "$dest/Synapse Desktop.app"
echo "Installed Synapse Desktop $VERSION in $dest/Synapse Desktop.app"
