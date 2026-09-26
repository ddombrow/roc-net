#!/bin/bash
set -eo pipefail

# Get rust triple for a target name
get_rust_triple() {
    case "$1" in
        x64mac)    echo "x86_64-apple-darwin" ;;
        arm64mac)  echo "aarch64-apple-darwin" ;;
        x64musl)   echo "x86_64-unknown-linux-musl" ;;
        arm64musl) echo "aarch64-unknown-linux-musl" ;;
        arm64glibc) echo "aarch64-unknown-linux-gnu" ;;
        x64glibc) echo "x86_64-unknown-linux-gnu" ;;
        *) echo "Unknown target: $1" >&2; exit 1 ;;
    esac
}

# All supported targets
ALL_TARGETS="x64mac arm64mac x64musl arm64musl"

# Detect native target based on current platform
detect_native_target() {
    local arch=$(uname -m)
    local os=$(uname -s)

    if [ "$os" = "Darwin" ]; then
        if [ "$arch" = "arm64" ]; then
            echo "arm64mac"
        else
            echo "x64mac"
        fi
    elif [ "$os" = "Linux" ]; then
        if [ "$arch" = "aarch64" ]; then
            echo "arm64musl"
        else
            echo "x64musl"
        fi
    else
        echo "Unsupported OS: $os" >&2
        exit 1
    fi
}

# The host's C dependencies (AWS-LC, via rustls) need a C compiler for the
# target. For Linux musl targets, use Zig as the cross-compiler.
with_cross_c_compiler() {
    local target_name=$1; shift
    local rust_triple=$(get_rust_triple "$target_name")
    local env_triple=$(echo "$rust_triple" | tr '-' '_')
    case "$target_name" in
        x64musl) zig_target="x86_64-linux-musl" ;;
        arm64musl) zig_target="aarch64-linux-musl" ;;
        # Rocky/RHEL 8's glibc, the oldest the glibc build supports.
        arm64glibc) zig_target="aarch64-linux-gnu.2.28" ;;
        x64glibc) zig_target="x86_64-linux-gnu.2.28" ;;
        *) "$@"; return ;;
    esac
    if ! command -v zig >/dev/null; then
        echo "Building for $target_name needs zig as a C cross-compiler (https://ziglang.org)" >&2
        exit 1
    fi
    local scripts="$(cd "$(dirname "$0")" && pwd)/scripts"
    env "CC_${env_triple}=${scripts}/zig-cc" "AR_${env_triple}=${scripts}/zig-ar" ZIG_CC_TARGET="$zig_target" "$@"
}

# Build for a specific target (cross-compile)
build_target_cross() {
    local target_name=$1
    local rust_triple=$(get_rust_triple "$target_name")

    echo "Building for $target_name ($rust_triple)..."
    with_cross_c_compiler "$target_name" cargo build --release --locked --lib --target "$rust_triple"

    mkdir -p "platform/targets/$target_name"
    cp "target/$rust_triple/release/libhost.a" "platform/targets/$target_name/"
    echo "  -> platform/targets/$target_name/libhost.a"
}

# Build for native target
# On macOS: no --target needed (native is fine)
# On Linux: must use --target for musl, since default is glibc
build_target_native() {
    local target_name=$1
    local rust_triple=$(get_rust_triple "$target_name")

    echo "Building for $target_name (native)..."

    # On macOS, native build is fine
    # On Linux, we must explicitly target musl (default is glibc)
    if [[ "$target_name" == *"musl"* ]]; then
        # Linux: need explicit musl target
        rustup target add "$rust_triple" 2>/dev/null || true
        cargo build --release --locked --lib --target "$rust_triple"
        mkdir -p "platform/targets/$target_name"
        cp "target/$rust_triple/release/libhost.a" "platform/targets/$target_name/"
    else
        # macOS: native is fine
        cargo build --release --locked --lib
        mkdir -p "platform/targets/$target_name"
        cp "target/release/libhost.a" "platform/targets/$target_name/"
    fi

    echo "  -> platform/targets/$target_name/libhost.a"
}

# Download and verify the independently released linker inputs before building hosts.
# An unpublished archive is accepted only with this explicit development flag.
BUILD_ALL=0
CROSS_TARGET=""
RUNTIME_CANDIDATE_PATH=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --all) BUILD_ALL=1; shift ;;
        --target)
            test "$#" -ge 2 || { echo "--target requires a target name ($ALL_TARGETS)" >&2; exit 1; }
            get_rust_triple "$2" >/dev/null
            CROSS_TARGET=$2; shift 2 ;;
        --runtime-candidate)
            test "$#" -ge 2 || { echo "--runtime-candidate requires an archive" >&2; exit 1; }
            RUNTIME_CANDIDATE_PATH=$2; shift 2 ;;
        *) echo "Unknown build argument: $1" >&2; exit 1 ;;
    esac
done

# Linux musl targets link against a verified C runtime (crt1.o, libc.a, ...).
fetch_runtime() {
    if [ -n "$RUNTIME_CANDIDATE_PATH" ]; then
        python3 ci/runtime.py install-candidate "$RUNTIME_CANDIDATE_PATH"
    else
        python3 scripts/fetch_linux_runtime.py "$@"
    fi
}
if [ "$BUILD_ALL" = 1 ]; then
    fetch_runtime x64musl arm64musl
elif [[ "$CROSS_TARGET" == *musl ]]; then
    fetch_runtime "$CROSS_TARGET"
elif [ -z "$CROSS_TARGET" ] && [[ "$(detect_native_target)" == *musl ]]; then
    fetch_runtime "$(detect_native_target)"
fi

# Main logic
if [ -n "$CROSS_TARGET" ]; then
    rustup target add "$(get_rust_triple "$CROSS_TARGET")" 2>/dev/null || true
    build_target_cross "$CROSS_TARGET"
elif [ "$BUILD_ALL" = 1 ]; then
    echo "Building for all targets..."
    echo ""

    # Ensure all rust targets are installed
    echo "Installing Rust targets..."
    for target_name in $ALL_TARGETS; do
        rust_triple=$(get_rust_triple "$target_name")
        rustup target add "$rust_triple" 2>/dev/null || true
    done
    echo ""

    # Build each target (cross-compile)
    for target_name in $ALL_TARGETS; do
        build_target_cross "$target_name"
        echo ""
    done

    echo "All targets built successfully!"
else
    # Build for native target only (no cross-compile)
    TARGET=$(detect_native_target)
    echo "Building for native target: $TARGET"
    echo ""

    build_target_native "$TARGET"

    echo ""
    echo "Build complete!"
fi
