#!/bin/sh
# Run the network test suite (examples/net_tests) the way every environment
# should: `just test` on macOS, `just linux-test` (via tests/e2e/compose.yaml)
# and GitLab CI all call this, so they can't drift apart.
#
#   scripts/run_net_tests.sh path/to/net_tests
#
# - Raises the file-descriptor limit if allowed: the Unix backlog test fills a
#   listener's queue, which Linux lets grow to 4,096 connections.
# - Runs the suite three times: as configured; with ROC_NET_SHARE_AFTER_US=0,
#   which makes tasks move between worker threads as often as possible; and
#   with ROC_NET_WORKERS=1, where anything that blocks the thread (rather than
#   suspending the task) hangs every task instead of hiding behind others.
# - Fails if a task failed unexpectedly: that's only logged ("task failed:
#   ..."), so the suite itself would still pass.
set -u
bin=$1

limit=$(ulimit -n)
if [ "$limit" != unlimited ] && [ "$limit" -lt 10000 ]; then
    ulimit -n 10000 2>/dev/null || echo "note: couldn't raise the descriptor limit from $limit; the Unix backlog test needs more than 4,096 on Linux"
fi

run() {
    out=$("$@" 2>&1)
    code=$?
    echo "$out" | grep -v '^ok'
    if echo "$out" | grep -q ' ERROR task failed'; then
        echo "FAILED: a task failed unexpectedly (see above)"
        return 1
    fi
    return $code
}

run "$bin" || exit 1
echo "== again, moving tasks between threads at every backlog"
run env ROC_NET_SHARE_AFTER_US=0 "$bin" || exit 1
echo "== again, on one worker thread (anything that blocks the thread hangs)"
run env ROC_NET_WORKERS=1 "$bin" || exit 1
# The `Log` checks, when their program (tests/log) was built alongside.
log_bin="$(dirname "$bin")/log"
if [ -x "$log_bin" ]; then
    echo "== log"
    "$(dirname "$0")/run_log_tests.sh" "$log_bin"
else
    # Loudly: a job that forgot to build it must not look like it passed.
    echo "SKIPPED: the Log checks ($log_bin, from tests/log, wasn't built)"
fi
# The Noise test vectors (tests/noise), likewise.
noise_bin="$(dirname "$bin")/noise"
if [ -x "$noise_bin" ]; then
    echo "== noise vectors"
    "$noise_bin" || exit 1
else
    echo "SKIPPED: the Noise test vectors ($noise_bin, from tests/noise, wasn't built)"
fi
# The stdin checks (tests/stdin), fed input with a pause in it.
stdin_bin="$(dirname "$bin")/stdin"
if [ -x "$stdin_bin" ]; then
    echo "== stdin"
    marker=$(mktemp -u "${TMPDIR:-/tmp}/roc-net-stdin.XXXXXX")
    # The rest only once the program says (by creating $marker) it has seen
    # no line arrive; at most 30 seconds, so a failed check can't hang this.
    {
        printf 'first\n'
        tries=0
        while [ ! -e "$marker" ] && [ $tries -lt 600 ]; do sleep 0.05; tries=$((tries + 1)); done
        # A line of exactly 1 MiB (accepted), then one a byte longer (refused).
        head -c 1048576 /dev/zero | tr '\0' x; printf '\n'
        head -c 1048577 /dev/zero | tr '\0' x; printf '\n'
        printf 'second\nthird\n'
    } | STDIN_TEST_MARKER="$marker" "$stdin_bin"
    code=$?
    rm -f "$marker"
    [ $code = 0 ] || exit 1
else
    echo "SKIPPED: the stdin checks ($stdin_bin, from tests/stdin, wasn't built)"
fi
# Two Selects on one idle stream (tests/select_idle) must sleep, not wake
# each other in a loop: about 4 seconds of waiting, well under half a second
# of CPU.
idle_bin="$(dirname "$bin")/select_idle"
if [ -x "$idle_bin" ]; then
    echo "== select_idle"
    if [ -x /usr/bin/time ]; then
        times=$( { /usr/bin/time -p "$idle_bin" >/dev/null; } 2>&1 ) || { echo "$times"; echo "FAILED: select_idle"; exit 1; }
        cpu=$(echo "$times" | awk '$1 == "user" || $1 == "sys" { total += $2 } END { print total + 0 }')
        if awk -v cpu="$cpu" 'BEGIN { exit !(cpu < 0.5) }'; then
            echo "Idle Selects used ${cpu}s of CPU over 4s"
        else
            echo "$times"
            echo "FAILED: idle Selects used ${cpu}s of CPU over 4s (they're waking each other)"
            exit 1
        fi
    else
        "$idle_bin" || exit 1
        echo "SKIPPED: select_idle's CPU check (no /usr/bin/time here)"
    fi
else
    echo "SKIPPED: the idle Select check ($idle_bin, from tests/select_idle, wasn't built)"
fi
