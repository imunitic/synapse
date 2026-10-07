#!/bin/bash
# Builds the Linux release binaries of the Ada crate so that they need no more
# than glibc 2.28, the floor of the Zig release.
#
# The Alire toolchain and `alr` itself need a newer glibc than 2.28, so the
# build cannot run on an old system. It runs on a recent one, and compiles and
# links against a sysroot taken from an AlmaLinux 8 image instead of its own C
# library (`SYNAPSE_USE_SYSROOT`, see `synapse_platform.gpr`). The toolchain's
# own unwinder asks glibc for `_dl_find_object`, which only 2.35 has, so the
# sysroot also carries the older unwinder of the image's compiler.
#
#   ci/ada-linux-release.sh
#
# Needs podman or docker. Leaves `$OUT_DIR/{synapse,synapse-hook,synapse-fake}`
# (`ada/bin` unless OUT_DIR says otherwise) and checks the highest glibc
# version they ask for.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"

out_dir="${OUT_DIR:-$root/ada/bin}"
floor="${GLIBC_FLOOR:-2.28}"
alire_version="${ALIRE_VERSION:-2.1.1}"
gnat_version="${GNAT_VERSION:-16.1.0}"

runtime="$(command -v podman || command -v docker || true)"
[ -n "$runtime" ] || { echo "neither podman nor docker is on PATH" >&2; exit 1; }

case "$(uname -m)" in
    x86_64) alire_arch=x86_64 ;;
    aarch64|arm64) alire_arch=aarch64 ;;
    *) echo "no Linux build for $(uname -m)" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "sysroot from almalinux:8"
"$runtime" run --rm -v "$work:/out" almalinux:8 sh -ec '
    dnf -y -q install glibc-devel kernel-headers gcc tar gzip
    mkdir -p /usr/lib64/eh
    cp /usr/lib/gcc/*-redhat-linux/8/libgcc_eh.a /usr/lib64/eh/
    tar -C / -cf /out/sysroot.tar usr/include usr/lib64 lib64
    # The C library names its loader as /lib/ld-linux-aarch64.so.1 there. The
    # link goes into the archive from a directory of its own: /lib is a link
    # here, and one made through it would break this system.
    if [ -e /usr/lib64/ld-linux-aarch64.so.1 ]; then
        mkdir -p /extra/lib
        ln -s ../usr/lib64/ld-linux-aarch64.so.1 /extra/lib/ld-linux-aarch64.so.1
        tar -C /extra -rf /out/sysroot.tar lib
    fi
    gzip /out/sysroot.tar
    mv /out/sysroot.tar.gz /out/sysroot.tgz'

echo "build on ubuntu:24.04"
"$runtime" run --rm -v "$root/ada:/src/ada:ro" -v "$work:/out" \
    -e ALIRE_ARCH="$alire_arch" -e ALIRE_VERSION="$alire_version" -e GNAT_VERSION="$gnat_version" \
    ubuntu:24.04 bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl unzip ca-certificates build-essential binutils >/dev/null
    curl -fsSL -o /tmp/alr.zip "https://github.com/alire-project/alire/releases/download/v${ALIRE_VERSION}/alr-${ALIRE_VERSION}-bin-${ALIRE_ARCH}-linux.zip"
    (cd /tmp && unzip -q alr.zip && install -m755 bin/alr /usr/local/bin/alr)
    mkdir -p /sysroot && tar -xzf /out/sysroot.tgz -C /sysroot
    mkdir -p /work && cd /src/ada && tar --exclude=obj --exclude=bin --exclude=alire --exclude=ucd --exclude=testdata -cf - . | tar -xf - -C /work
    cd /work
    alr -n toolchain --select "gnat_native=${GNAT_VERSION}" gprbuild
    SYNAPSE_USE_SYSROOT=yes SYNAPSE_SYSROOT=/sysroot alr -n build --release
    cp bin/synapse bin/synapse-hook bin/synapse-fake /out/'

mkdir -p "$out_dir"
cp "$work/synapse" "$work/synapse-hook" "$work/synapse-fake" "$out_dir/"

# The floor, as a property of the binaries and not a hope.
"$runtime" run --rm -v "$out_dir:/b:ro" -e FLOOR="$floor" ubuntu:24.04 bash -euo pipefail -c '
    apt-get update -qq && apt-get install -y -qq binutils >/dev/null
    for b in synapse synapse-hook synapse-fake; do
        top="$(objdump -T "/b/$b" | grep -o "GLIBC_[0-9.]*" | sed "s/GLIBC_//" | sort -Vu | tail -1)"
        echo "  $b needs glibc $top"
        [ "$(printf "%s\n%s\n" "$top" "$FLOOR" | sort -V | tail -1)" = "$FLOOR" ] \
            || { echo "FAIL: $b needs glibc $top, above $FLOOR" >&2; exit 1; }
    done'
echo "ada-linux-release ok (glibc <= $floor)"
