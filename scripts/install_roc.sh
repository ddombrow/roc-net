#!/bin/sh
# Install the Roc nightly pinned in platform/main.roc into .tools/ (as
# .tools/roc), for this machine's OS and CPU. Public downloads, no login.
#
#   scripts/install_roc.sh [--with-source]   # the source has RustGlue.roc, for `just glue`
set -eu
cd "$(dirname "$0")/.."
nightly=$(sed -n 's/.*roc: "\(nightly-[^"]*\)".*/\1/p' platform/main.roc | head -1)
suffix=${nightly#nightly-}
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) os=macos_apple_silicon ;;
    Darwin-x86_64) os=macos_x86_64 ;;
    Linux-aarch64 | Linux-arm64) os=linux_arm64 ;;
    Linux-x86_64) os=linux_x86_64 ;;
    *) echo "no Roc nightly for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
base="https://github.com/roc-lang/nightlies/releases/download/$nightly"
mkdir -p .tools

fetch() {
    curl -fsSL --proto =https -o ".tools/$1" "$base/$1"
    tar xzf ".tools/$1" -C .tools
    rm ".tools/$1"
}

if [ -x .tools/roc ] && .tools/roc version 2>/dev/null | grep -q "$nightly"; then
    echo "roc $nightly already installed"
else
    fetch "roc_nightly-$os-$suffix.tar.gz"
    ln -sf "roc_nightly-$os-$suffix/roc" .tools/roc
    .tools/roc version
fi
if [ "${1:-}" = "--with-source" ] && [ ! -d ".tools/roc_nightly-source-$suffix" ]; then
    fetch "roc_nightly-source-$suffix.tar.gz"
fi
