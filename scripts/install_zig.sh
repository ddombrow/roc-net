#!/bin/sh
# Install Zig into .tools/zig (for CI on Linux; on macOS use `brew install zig`).
# Zig is the C cross-compiler for the host's C dependency (AWS-LC).
set -eu
cd "$(dirname "$0")/.."
version=0.16.0
case "$(uname -m)" in
    x86_64) platform=x86_64-linux; sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
    aarch64 | arm64) platform=aarch64-linux; sha256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
    *) echo "no Zig download configured for $(uname -m)" >&2; exit 1 ;;
esac
if [ -x .tools/zig/zig ] && [ "$(.tools/zig/zig version)" = "$version" ]; then
    echo "zig $version already installed"; exit 0
fi
archive=$(mktemp)
curl -fsSL --proto =https -o "$archive" "https://ziglang.org/download/$version/zig-$platform-$version.tar.xz"
echo "$sha256  $archive" | sha256sum -c - >/dev/null
rm -rf .tools/zig && mkdir -p .tools/zig
tar xJf "$archive" --strip-components=1 -C .tools/zig
rm "$archive"
.tools/zig/zig version
