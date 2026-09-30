#!/bin/sh
# Check `Log` from outside, on the test program in tests/log: the exact lines
# in both formats, level filtering, settings, and above all that logging
# doesn't wait while nothing reads stderr. POSIX sh and grep only, since the
# Linux test images have no Python.
#
# Usage: scripts/run_log_tests.sh path/to/log
set -u
bin=$1
work=$(mktemp -d)
reader=
cleanup() {
    [ -n "$reader" ] && kill "$reader" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
failed=0
fail() {
    echo "FAIL  log: $1"
    failed=$((failed + 1))
}
ok() {
    echo "ok    log: $1"
}
# Whether two files hold the same text (`cmp` isn't in minimal images).
same() {
    [ "$(cat "$1")" = "$(cat "$2")" ]
}

ts='[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9]Z'

# --- Text lines, default level (info) ---
"$bin" lines > "$work/out" 2> "$work/err"
if [ "$(grep -c "^$ts " "$work/err")" = "$(wc -l < "$work/err" | tr -d ' ')" ]; then
    ok "every text line starts with an RFC 3339 timestamp"
else
    fail "a text line without a timestamp:"; cat "$work/err"
fi
sed "s/^$ts /TS /" "$work/err" > "$work/text"
cat > "$work/want" <<'EOF'
TS INFO plain message task=1
TS INFO fields peer=1.2.3.4:5 up=120 delta=-5 ratio=0.5 ok=true task=1
TS INFO quoting path="a b" empty="" q="say \"hi\"" eq="a=b" back="c:\\d" task=1
TS INFO two\nlines task=1
TS INFO reserved field.msg=x field.task=9 field.ts=y task=1
TS INFO bad key bad_key=v task=1
TS INFO floats big=1e300 small=1e-300 third=0.3333333333333333 two=2.0 task=1
TS INFO control ctl="a\x01b" task=1
TS INFO "connection from 1.2.3.4 admin=true" user=bob task=1
TS WARN a warning task=1
TS ERROR an error task=1
TS INFO from another task task=2
EOF
if same "$work/text" "$work/want"; then
    ok "text lines: fields, floats, quoting, escaping, a message that looks like fields, renamed keys, levels, task ids"
else
    fail "text lines differ (want, then got):"; cat "$work/want" "$work/text"
fi
if grep -q '^debug enabled: False$' "$work/out"; then ok "Log.enabled!(Debug) is False by default"; else fail "Log.enabled!: $(cat "$work/out")"; fi

# --- JSON lines, debug level ---
ROC_NET_LOG=debug ROC_NET_LOG_FORMAT=json "$bin" lines > "$work/out" 2> "$work/err"
sed "s/^{\"ts\":\"$ts\"/{\"ts\":\"TS\"/" "$work/err" > "$work/json"
cat > "$work/want" <<'EOF'
{"ts":"TS","level":"info","msg":"plain message","task":1}
{"ts":"TS","level":"info","msg":"fields","task":1,"peer":"1.2.3.4:5","up":120,"delta":-5,"ratio":0.5,"ok":true}
{"ts":"TS","level":"info","msg":"quoting","task":1,"path":"a b","empty":"","q":"say \"hi\"","eq":"a=b","back":"c:\\d"}
{"ts":"TS","level":"info","msg":"two\nlines","task":1}
{"ts":"TS","level":"info","msg":"reserved","task":1,"field.msg":"x","field.task":9,"field.ts":"y"}
{"ts":"TS","level":"info","msg":"bad key","task":1,"bad key":"v"}
{"ts":"TS","level":"info","msg":"floats","task":1,"big":1e300,"small":1e-300,"third":0.3333333333333333,"two":2.0}
{"ts":"TS","level":"info","msg":"control","task":1,"ctl":"a\u0001b"}
{"ts":"TS","level":"info","msg":"connection from 1.2.3.4 admin=true","task":1,"user":"bob"}
{"ts":"TS","level":"debug","msg":"hidden unless debug","task":1}
{"ts":"TS","level":"warn","msg":"a warning","task":1}
{"ts":"TS","level":"error","msg":"an error","task":1}
{"ts":"TS","level":"info","msg":"from another task","task":2}
EOF
if same "$work/json" "$work/want"; then
    ok "json lines, and ROC_NET_LOG=debug"
else
    fail "json lines differ (want, then got):"; cat "$work/want" "$work/json"
fi
if grep -q '^debug enabled: True$' "$work/out"; then ok "Log.enabled!(Debug) follows ROC_NET_LOG"; else fail "Log.enabled! at debug: $(cat "$work/out")"; fi

# --- Long strings and lines ---
"$bin" long > /dev/null 2> "$work/err"
first=$(sed -n 1p "$work/err")
second=$(sed -n 2p "$work/err")
xs=$(printf '%s' "$first" | tr -cd 'x' | wc -c | tr -d ' ')
if [ "$xs" = 16384 ] && printf '%s' "$first" | grep -q 'x\.\.\.(truncated) task=1$'; then
    ok "a string past 16 KiB is cut short, and marked"
else
    fail "a long string: $xs x's, ending $(printf '%s' "$first" | tail -c 40)"
fi
if printf '%s' "$second" | grep -q ' truncated=true task=1$' && [ "$(printf '%s' "$second" | wc -c)" -lt 90000 ]; then
    ok "a line past 64 KiB leaves out its remaining fields, and says so"
else
    fail "a long line: $(printf '%s' "$second" | wc -c) bytes, ending $(printf '%s' "$second" | tail -c 40)"
fi

# --- main! failing ---
"$bin" fail > /dev/null 2> "$work/err"
code=$?
sed "s/^$ts /TS /" "$work/err" > "$work/text"
printf 'TS INFO before failing task=1\nTS ERROR main! failed error=Boom task=1\n' > "$work/want"
if [ $code != 0 ] && same "$work/text" "$work/want"; then
    ok "main! failing is logged as an error, after what came before, and exits non-zero"
else
    fail "main! failing (exit $code):"; cat "$work/text"
fi

# ... and with stderr stalled, it still exits: its error goes through the
# log writer, which gets at most a second before the program ends.
mkfifo "$work/fail-fifo"
sleep 60 < "$work/fail-fifo" &
reader=$!
# 2,000 lines of 250 bytes: more than a pipe holds, so the writer is stuck.
"$bin" fail 2000 2> "$work/fail-fifo" > /dev/null &
app=$!
waited=0
while kill -0 $app 2>/dev/null && [ $waited -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if kill -0 $app 2>/dev/null; then
    fail "main! failing with stderr stalled: still running after 5 s"
    kill $app 2>/dev/null
else
    ok "main! failing with stderr stalled still exits (after $((waited * 100)) ms; the flush waits up to 1 s)"
fi
kill "$reader" 2>/dev/null
wait "$reader" 2>/dev/null
reader=

# --- Log and Stderr.line! at once ---
# Tasks write 2 KB lines, four with Log and four with Stderr.line!: each
# line must come out whole, to a file and to a pipe read late (which splits
# large writes). Order between the two may differ; tearing mustn't happen.
# Whole lines only: every one of the 2,000 plain lines, and every log line
# (or a count of dropped ones), and nothing else. (`{250}` eight times, since
# grep allows at most 255 repetitions; a pattern it rejects matches nothing,
# so the counts would come out short and the check fail.)
ts_ere=$(printf '%s' "$ts" | sed 's/\\//g')
plain_line='^plain [0-9]+ (x{250}){8}$'
log_line="^$ts_ere INFO mixed i=[0-9]+ padding=(y{250}){8} task=[0-9]+$"
notice_line="^$ts_ere WARN log lines dropped count=[0-9]+$"
mixed_ok() {
    whole_plain=$(grep -c -E "$plain_line" "$1")
    whole_log=$(grep -c -E "$log_line" "$1")
    notices=$(grep -c -E "$notice_line" "$1")
    lost=0
    for n in $(grep -E "$notice_line" "$1" | sed 's/.*count=//'); do
        lost=$((lost + n))
    done
    other=$(($(wc -l < "$1" | tr -d ' ') - whole_plain - whole_log - notices))
    report="$whole_plain of 2000 plain lines whole, $whole_log log lines whole and $lost dropped, $other other lines"
    [ "$whole_plain" = 2000 ] && [ $((whole_log + lost)) = 2000 ] && [ "$other" = 0 ]
}
"$bin" mixed > /dev/null 2> "$work/mixed-file"
mkfifo "$work/mixed-fifo"
( sleep 0.3; cat "$work/mixed-fifo" > "$work/mixed-pipe" ) &
late=$!
"$bin" mixed > /dev/null 2> "$work/mixed-fifo"
wait $late
if mixed_ok "$work/mixed-file"; then
    ok "Log and Stderr.line! at once never tear each other's lines, to a file ($report)"
else
    fail "torn lines to a file: $report"
    grep -v -E "$plain_line" "$work/mixed-file" | grep -v -E "$log_line" | head -3 | cut -c1-120
fi
if mixed_ok "$work/mixed-pipe"; then
    ok "... or to a pipe read late ($report)"
else
    fail "torn lines to a pipe: $report"
    grep -v -E "$plain_line" "$work/mixed-pipe" | grep -v -E "$log_line" | head -3 | cut -c1-120
fi

# --- Settings ---
ROC_NET_LOG=off "$bin" lines > /dev/null 2> "$work/err"
if [ ! -s "$work/err" ]; then ok "ROC_NET_LOG=off writes nothing"; else fail "ROC_NET_LOG=off wrote:"; cat "$work/err"; fi
ROC_NET_LOG=error "$bin" lines > /dev/null 2> "$work/err"
if [ "$(wc -l < "$work/err" | tr -d ' ')" = 1 ] && grep -q ' ERROR an error ' "$work/err"; then
    ok "ROC_NET_LOG=error writes only errors"
else
    fail "ROC_NET_LOG=error wrote:"; cat "$work/err"
fi
ROC_NET_LOG=loud "$bin" lines > /dev/null 2> "$work/err"
if grep -q 'ignoring ROC_NET_LOG="loud"' "$work/err" && grep -q ' INFO plain message ' "$work/err"; then
    ok "a bad ROC_NET_LOG is reported, and info used"
else
    fail "a bad ROC_NET_LOG:"; cat "$work/err"
fi

# --- A stalled stderr ---
# stderr is a pipe that stays open but is never read, so the log writer's
# writes stop once the pipe is full. Logging must carry on regardless (it
# would hang here if it waited), dropping the oldest lines past the 64 KiB
# buffer; once the pipe is drained, a count of the dropped lines comes out,
# then the newest lines.
count=20000
mkfifo "$work/fifo"
sleep 60 < "$work/fifo" &
reader=$!
ROC_NET_LOG_BUFFER_KIB=64 "$bin" stall $count 2> "$work/fifo" > "$work/out" &
app=$!
waited=0
while ! grep -q '^logged' "$work/out" && [ $waited -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if grep -q '^logged' "$work/out"; then
    ok "logging doesn't wait while stderr isn't read ($(cat "$work/out"))"
else
    fail "logging stalled with stderr: nothing on stdout after 10 s"
fi
# Drain it, then let the program finish (it waits 3 seconds for this).
cat "$work/fifo" > "$work/err" &
drain=$!
wait $app
code=$?
wait $drain
kill "$reader" 2>/dev/null
wait "$reader" 2>/dev/null
reader=
# The writer reports drops each time it catches up, so there may be several.
notices=$(grep -c ' WARN log lines dropped count=' "$work/err")
dropped=0
for n in $(grep ' WARN log lines dropped count=' "$work/err" | sed 's/.*count=\([0-9]*\).*/\1/'); do
    dropped=$((dropped + n))
done
if [ $code = 0 ] && [ "$dropped" -gt 0 ]; then
    ok "the dropped lines are counted ($dropped of $count)"
else
    fail "no count of dropped lines (exit $code):"; head -3 "$work/err"; tail -3 "$work/err"
fi
if tail -1 "$work/err" | grep -q " i=$((count - 1)) "; then
    ok "the oldest lines are the ones dropped: the newest is kept"
else
    fail "the last line isn't the newest: $(tail -1 "$work/err" | cut -c1-100)"
fi
lines=$(wc -l < "$work/err" | tr -d ' ')
if [ $((lines - notices + dropped)) = $count ]; then
    ok "every line is written or counted as dropped"
else
    fail "$lines lines written ($notices of them drop counts) and $dropped dropped, of $count"
fi

if [ $failed = 0 ]; then
    echo "All log checks passed"
else
    echo "$failed log checks failed"
    exit 1
fi
