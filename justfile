# Run `just` to list recipes.

# Pass recipe arguments through as "$@" so quoted arguments keep their spaces.
set positional-arguments

# Use the project-local compiler installed by `just setup`.
export PATH := justfile_directory() / ".tools" + ":" + env("PATH")

# The Roc nightly pinned in the platform header.
nightly := `sed -n 's/.*roc: "\(nightly-[^"]*\)".*/\1/p' platform/main.roc`
nightly_suffix := trim_start_match(nightly, "nightly-")
nightly_os := if os() == "macos" {
    if arch() == "aarch64" { "macos_apple_silicon" } else { "macos_x86_64" }
} else {
    if arch() == "aarch64" { "linux_arm64" } else { "linux_x86_64" }
}
glue := ".tools/roc_nightly-source-" + nightly_suffix + "/src/glue/src/RustGlue.roc"
bin_dir := "target/examples"

default:
    @just --list

# Download the pinned Roc nightly (and its source, for glue) into .tools/
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .tools && cd .tools
    if [ -x roc ] && roc version | grep -q "{{nightly}}"; then
        echo "roc {{nightly}} already installed"
        exit 0
    fi
    gh release download "{{nightly}}" -R roc-lang/nightlies --clobber \
        -p "roc_nightly-{{nightly_os}}-{{nightly_suffix}}.tar.gz" \
        -p "roc_nightly-source-{{nightly_suffix}}.tar.gz"
    tar xzf "roc_nightly-{{nightly_os}}-{{nightly_suffix}}.tar.gz"
    tar xzf "roc_nightly-source-{{nightly_suffix}}.tar.gz"
    ln -sf "roc_nightly-{{nightly_os}}-{{nightly_suffix}}/roc" roc
    roc version

# Build the Rust host for the native target
build:
    ./build.sh

# Build the Rust host for every supported target
build-all:
    ./build.sh --all

# Regenerate src/roc_platform_abi.rs after changing hosted or provided functions
glue:
    roc glue {{glue}} ./src/ platform/main.roc

# List the examples
examples:
    @ls examples

# Type-check every example (or just one)
check example="":
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    for dir in examples/{{ if example == "" { "*" } else { example } }}/; do
        if roc check "$dir/main.roc" >/dev/null 2>&1; then
            echo "ok    $dir"
        else
            echo "FAIL  $dir"
            roc check "$dir/main.roc"
            status=1
        fi
    done
    exit $status

# Build the host, then run an example: just run tcp_client 127.0.0.1:8080 hi
run example *args: build
    shift && roc examples/{{example}}/main.roc -- "$@"

# Build an example to target/examples/<name>
build-example example: build
    @mkdir -p {{bin_dir}}
    roc build examples/{{example}}/main.roc --output={{bin_dir}}/{{example}}

# Build every example to target/examples/ (catches link errors that `check` can't)
build-examples: build
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p {{bin_dir}}
    status=0
    for dir in examples/*/; do
        name=$(basename "$dir")
        out=$(roc build "$dir/main.roc" --output={{bin_dir}}/$name 2>&1)
        # roc exits 2 when the build succeeded with warnings.
        case $? in
            0) echo "ok    $name" ;;
            2) echo "warn  $name" ;;
            *) echo "FAIL  $name"; echo "$out" | tail -15; status=1 ;;
        esac
    done
    exit $status

# Start the concurrent echo server and check that a client gets its message back
smoke: build (build-example "tcp_echo_concurrent") (build-example "tcp_client")
    #!/usr/bin/env bash
    set -euo pipefail
    {{bin_dir}}/tcp_echo_concurrent 127.0.0.1:9471 >/dev/null &
    server=$!
    trap 'kill $server 2>/dev/null' EXIT
    sleep 0.5
    reply=$({{bin_dir}}/tcp_client 127.0.0.1:9471 "smoke test")
    echo "$reply"
    [ "$reply" = "Received: smoke test" ]

# Run the network tests, every example's `expect`s, then the smoke test
test: (build-example "net_tests") smoke
    {{bin_dir}}/net_tests
    for f in $(grep -lE '^expect' examples/*/*.roc | xargs -n1 dirname | sort -u); do roc test "$f/main.roc" || exit 1; done

linux_programs := "examples/net_tests examples/tcp_echo_concurrent examples/udp_echo_server examples/line_server examples/chat_server tests/e2e"
compose := "docker compose -f tests/e2e/compose.yaml"
roc_linux := ".tools/linux-arm64/roc_nightly-linux_arm64-" + nightly_suffix + "/roc"

# Build the test programs for Linux into target/linux/<target>: arm64musl, x64musl (static), arm64glibc, x64glibc
build-linux target="arm64musl":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p target/linux/{{target}}
    case "{{target}}" in
    *glibc)
        # Roc only links glibc programs on Linux: use its Linux build in a
        # Rocky 8 container, against Rocky 8's glibc (2.28).
        [ -f platform/targets/{{target}}/libc.so.6 ] || scripts/fetch_glibc_inputs.sh {{target}}
        if [ ! -x "{{roc_linux}}" ]; then
            mkdir -p .tools/linux-arm64
            gh release download "{{nightly}}" -R roc-lang/nightlies -D .tools/linux-arm64 --clobber \
                -p "roc_nightly-linux_arm64-{{nightly_suffix}}.tar.gz"
            tar xzf .tools/linux-arm64/roc_nightly-linux_arm64-{{nightly_suffix}}.tar.gz -C .tools/linux-arm64
        fi
        ./build.sh --target {{target}}
        docker run --rm --platform linux/arm64 -v "$PWD:/work" -w /work rockylinux/rockylinux:8-minimal sh -euc '
            for program in {{linux_programs}}; do
                {{roc_linux}} build --target={{target}} "$program/main.roc" --output="target/linux/{{target}}/$(basename "$program")" >/dev/null
                echo "built target/linux/{{target}}/$(basename "$program")"
            done' ;;
    *)
        ./build.sh --target {{target}}
        for program in {{linux_programs}}; do
            roc build --target={{target}} "$program/main.roc" --output="target/linux/{{target}}/$(basename "$program")" >/dev/null
            echo "built target/linux/{{target}}/$(basename "$program")"
        done ;;
    esac

# Run the suite and cross-container e2e checks for every Linux build: musl on Alpine, glibc on Rocky 8 and 9 (needs docker)
linux-test: (build-linux "arm64musl") (build-linux "arm64glibc") (build-linux "x64musl") (build-linux "x64glibc")
    #!/usr/bin/env bash
    set -uo pipefail
    status=0
    platform_of() { case "$1" in x64*) echo linux/amd64 ;; *) echo linux/arm64 ;; esac; }
    suite() {
        echo "== test suite: $1 on $2"
        # A stage that hangs fails after 10 minutes instead of blocking the run.
        # -T and </dev/null: timeout runs compose in the background, where
        # reading from the terminal would stop it (SIGTTIN) instead of timing out.
        ROC_TARGET=$1 ROC_IMAGE=$2 ROC_PLATFORM=$(platform_of "$1") timeout 600 {{compose}} run --rm -T net-tests </dev/null | tail -1
        [ "${PIPESTATUS[0]}" = 0 ] || { status=1; echo "FAILED (exit ${PIPESTATUS[0]}; 124 means it timed out)"; }
        {{compose}} down -t 1 >/dev/null 2>&1
    }
    e2e() {
        echo "== e2e: $1 on $2"
        # Fresh containers every run, so none keep running an older binary.
        {{compose}} down -t 1 >/dev/null 2>&1
        ROC_TARGET=$1 ROC_IMAGE=$2 ROC_PLATFORM=$(platform_of "$1") timeout 600 {{compose}} up --force-recreate --exit-code-from e2e echo udp lines chat e2e </dev/null 2>/dev/null \
            | sed -n 's/^e2e-1 *| //p' | tail -1
        [ "${PIPESTATUS[0]}" = 0 ] || { status=1; echo "FAILED (exit ${PIPESTATUS[0]}; 124 means it timed out)"; }
        {{compose}} down -t 1 >/dev/null 2>&1
    }
    for arch in arm64 x64; do
        suite ${arch}musl alpine:3
        suite ${arch}glibc rockylinux/rockylinux:8-minimal
        suite ${arch}glibc rockylinux/rockylinux:9-minimal
        e2e ${arch}musl alpine:3
        e2e ${arch}glibc rockylinux/rockylinux:9-minimal
    done
    exit $status

# Benchmark against Rust baselines and record results: just bench --label "what changed"
bench *args:
    python3 bench/run.py "$@"

# Show roc-net's recorded benchmark results over time
bench-history *metrics:
    python3 bench/run.py history "$@"

# Generate API docs from the platform's doc comments into target/docs/
docs:
    roc docs platform/main.roc --output=target/docs --no-cache
    @echo "Open target/docs/index.html"

# Remove build output (keeps .tools/)
clean:
    cargo clean
    rm -rf platform/targets/*/libhost.a
