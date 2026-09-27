#!/usr/bin/env bash
# Check a platform bundle the way an app would use it: serve it over HTTP,
# build programs whose header points at its URL (not ../../platform), and run
# them. `just test-bundle` builds the bundle and runs this.
#
#   ci/test_bundle.sh <bundle.tar.zst>
#
# Builds the test suite and the echo server and client from the bundle, runs
# the suite (from the repository, which has its TLS test certificates) and
# the echo round trip. With Docker, it also builds the suite for arm64 and x64
# musl from the bundle and runs each in an Alpine container.
set -euo pipefail

bundle=${1:?Usage: ci/test_bundle.sh <bundle-file>}
test -f "$bundle"
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
server_pid=
cleanup() {
    # `|| true`: under `set -e`, a failing command here would become the
    # script's exit status (the killed server's wait returns 143).
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

mkdir "$work/www"
cp "$bundle" "$work/www/"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/www" > "$work/http.log" 2>&1 < /dev/null &
server_pid=$!
url="http://127.0.0.1:$port/$(basename "$bundle")"
for _ in $(seq 1 20); do
    curl --noproxy '*' --max-time 2 -fsI "$url" > /dev/null && break
    sleep 0.5
done
echo "Serving the bundle at $url"

for example in net_tests tcp_echo_concurrent tcp_client; do
    mkdir -p "$work/$example"
    sed "s|platform \"../../platform/main.roc\"|platform \"$url\"|" \
        "$root/examples/$example/main.roc" > "$work/$example/main.roc"
    grep -q "$url" "$work/$example/main.roc" || { echo "$example: couldn't point it at the bundle" >&2; exit 1; }
    # --no-cache: download the bundle, rather than reuse a cached copy.
    roc build --no-cache "$work/$example/main.roc" --output="$work/$example/app" > "$work/$example/build.log" 2>&1 \
        || { cat "$work/$example/build.log" >&2; exit 1; }
    echo "Built $example from the bundle"
done

(cd "$root" && scripts/run_net_tests.sh "$work/net_tests/app")

"$work/tcp_echo_concurrent/app" 127.0.0.1:9472 > /dev/null &
echo_pid=$!
sleep 0.5
reply=$("$work/tcp_client/app" 127.0.0.1:9472 "bundle test")
kill "$echo_pid"
wait "$echo_pid" 2>/dev/null || true
[ "$reply" = "Received: bundle test" ] || { echo "echo round trip failed: $reply" >&2; exit 1; }
echo "Echo round trip through the bundle's programs: ok"

if ! command -v docker > /dev/null || ! docker info > /dev/null 2>&1; then
    echo "Docker isn't available: skipping the Linux programs"
    exit 0
fi
for target in arm64musl x64musl; do
    case $target in arm64*) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac
    roc build --target=$target "$work/net_tests/main.roc" --output="$root/target/bundle-test-$target" > "$work/$target.log" 2>&1 \
        || { cat "$work/$target.log" >&2; exit 1; }
    echo "== $target, built from the bundle"
    docker run --rm --platform $platform -v "$root:/work" -w /work alpine:3 \
        scripts/run_net_tests.sh "target/bundle-test-$target" < /dev/null
    rm -f "$root/target/bundle-test-$target"
done
