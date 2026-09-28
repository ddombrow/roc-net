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
    if echo "$out" | grep -q '^task failed'; then
        echo "FAILED: a task failed unexpectedly (see above)"
        return 1
    fi
    return $code
}

run "$bin" || exit 1
echo "== again, moving tasks between threads at every backlog"
run env ROC_NET_SHARE_AFTER_US=0 "$bin" || exit 1
echo "== again, on one worker thread (anything that blocks the thread hangs)"
run env ROC_NET_WORKERS=1 "$bin"
