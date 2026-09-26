#!/bin/sh
# Copy the glibc link inputs for a glibc target (arm64glibc or x64glibc) out
# of a Rocky Linux 8 container into platform/targets/<target>. Linking against
# Rocky 8's glibc (2.28) makes the binaries run on Rocky/RHEL 8 and newer.
#
#   scripts/fetch_glibc_inputs.sh [arm64glibc|x64glibc]
#
# Needs docker. The files are extracted, not committed (they're gitignored).
set -eu
target="${1:-arm64glibc}"
case "$target" in
    arm64glibc) platform=linux/arm64; loader=ld-linux-aarch64.so.1 ;;
    x64glibc) platform=linux/amd64; loader=ld-linux-x86-64.so.2 ;;
    *) echo "unknown glibc target: $target" >&2; exit 1 ;;
esac
out="$(cd "$(dirname "$0")/.." && pwd)/platform/targets/$target"
mkdir -p "$out"

# The copy itself, run on a Rocky 8 system with glibc-devel installed.
copy='
    # Startup files and the parts of libc that are always linked statically.
    cp /usr/lib64/Scrt1.o /usr/lib64/crti.o /usr/lib64/crtn.o /usr/lib64/libc_nonshared.a "$out/"
    # Shared libraries, by the exact names programs will ask for at run time.
    # Before glibc 2.34, threads, dlopen, math, and clocks lived outside libc.
    for lib in libc.so.6 libpthread.so.0 libdl.so.2 libm.so.6 librt.so.1 libgcc_s.so.1 "$loader"; do
        cp -L "/lib64/$lib" "$out/"
    done
    rpm -q glibc | sed "s/^/extracted from /"
'

case "$(uname -m)" in
    aarch64 | arm64) this_platform=linux/arm64 ;;
    x86_64) this_platform=linux/amd64 ;;
    *) this_platform=other ;;
esac
if grep -qs 'release 8' /etc/rocky-release && [ "$this_platform" = "$platform" ]; then
    # Already on Rocky 8 with the right CPU (as in CI): copy from here.
    rpm -q glibc-devel >/dev/null || dnf install -y -q glibc-devel >/dev/null
    out="$out" loader="$loader" sh -euc "$copy"
else
    docker run --rm --platform "$platform" -v "$out:/out" -e out=/out -e loader="$loader" \
        rockylinux/rockylinux:8 sh -euc "dnf install -y -q glibc-devel >/dev/null; $copy"
fi
ls "$out"
