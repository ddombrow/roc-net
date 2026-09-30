//! `Log`: structured log lines, written to stderr by a thread of their own,
//! so that logging never blocks a task.
//!
//! A task writing to stderr itself (`Stderr.line!`) waits whenever whatever
//! reads stderr falls behind (a full pipe, a slow log shipper, a paused
//! terminal), and so does every other task on its worker. Here a call formats
//! its line, appends it to a queue and returns; one writer thread, not a task
//! worker, does the (blocking) writes.
//!
//! - Memory is capped (`ROC_NET_LOG_BUFFER_KIB`): lines queued plus the
//!   batch being written stay within it (give or take one line). When a new
//!   line doesn't fit, the oldest queued ones are dropped, and counted: the
//!   writer reports the count in a line of its own before what's left.
//!   Dropping, not waiting, is the point. The writer takes at most a
//!   sixteenth of the cap per batch, so a batch stuck on a stalled stderr
//!   can't hold much of it. Strings longer than 16 KiB, and lines longer
//!   than 64 KiB, are cut short (and marked), so one huge field can't
//!   either.
//! - Lines are formatted whole before they're queued and written one at a
//!   time, so lines from different tasks never interleave.
//! - Timestamps are the wall clock (UTC) when the line was logged, not when
//!   it's written.
//! - When `main!` returns, [`flush`] gives the writer a moment to finish; a
//!   crash loses what's queued.

use std::collections::VecDeque;
use std::io::Write;
use std::sync::{Condvar, Mutex, MutexGuard, Once};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::roc_host;
use crate::roc_platform_abi::{
    decref_list_of_anon_struct_be833d82c728025b as decref_log_fields, BoolOrF64OrI64OrStrOrU64Tag as Tag,
    HostLogWriteArg2 as RocLogField, RocList, RocStr,
};

/// A value in a line's fields.
pub enum Value<'a> {
    Str(&'a str),
    U64(u64),
    I64(i64),
    F64(f64),
    Bool(bool),
}

/// Levels, least severe first (as `ROC_NET_LOG` numbers them).
const LEVELS: [&str; 4] = ["debug", "info", "warn", "error"];
pub const WARN: u8 = 2;

/// How long the writer waits after a batch for more lines to gather.
const GATHER: Duration = Duration::from_millis(1);
pub const ERROR: u8 = 3;

struct Queue {
    lines: VecDeque<Vec<u8>>,
    /// The bytes of `lines`.
    queued: usize,
    /// The bytes the writer has taken and not finished writing.
    in_flight: usize,
    /// Lines dropped since the writer last reported it.
    dropped: u64,
    /// The writer has taken lines and not finished writing them.
    writing: bool,
    /// The writer is waiting for lines, so a new one must wake it. (Waking it
    /// only then, not for every line, saves a system call per line while
    /// it's busy.)
    sleeping: bool,
}

struct Sink {
    queue: Mutex<Queue>,
    /// Lines (or a drop to report) are waiting.
    ready: Condvar,
    /// The writer has written everything and is waiting (for [`flush`]).
    idle: Condvar,
}

static SINK: Sink = Sink {
    queue: Mutex::new(Queue { lines: VecDeque::new(), queued: 0, in_flight: 0, dropped: 0, writing: false, sleeping: false }),
    ready: Condvar::new(),
    idle: Condvar::new(),
};

// Held only to append or take lines, never across a write, so a task never
// waits on stderr through it.
fn lock() -> MutexGuard<'static, Queue> {
    SINK.queue.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Whether a line at `level` would be written.
pub fn enabled(level: u8) -> bool {
    level >= crate::limits::log_level()
}

/// Log `message` with `fields` at `level`, if it's enabled. Never waits.
pub fn log(level: u8, message: &str, fields: &[(&str, Value)]) {
    if !enabled(level) {
        return;
    }
    let line = format_line(
        crate::limits::log_json(),
        now_millis(),
        level,
        message,
        fields,
        crate::sched::current_task_id(),
    );
    push(line);
}

fn push(line: Vec<u8>) {
    static WRITER: Once = Once::new();
    WRITER.call_once(|| {
        // If it can't start, lines pile up and the oldest are dropped: the
        // program carries on without its logs rather than stopping.
        let _ = std::thread::Builder::new().name("roc-net-log".into()).spawn(writer);
    });
    let cap = crate::limits::log_buffer_bytes();
    let mut queue = lock();
    queue.queued += line.len();
    queue.lines.push_back(line);
    // Keep at least the newest line (lines are at most MAX_LINE long).
    while queue.queued + queue.in_flight > cap && queue.lines.len() > 1 {
        if let Some(oldest) = queue.lines.pop_front() {
            queue.queued -= oldest.len();
            queue.dropped += 1;
        }
    }
    let wake = std::mem::take(&mut queue.sleeping);
    drop(queue);
    if wake {
        SINK.ready.notify_one();
    }
}

/// The writer thread: take everything queued, write it, repeat.
fn writer() {
    // A write to a pipe whose reader is gone raises SIGPIPE, which by default
    // ends the program; blocked on this thread, the write fails with EPIPE
    // instead (and the line is lost, as it would be anyway).
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGPIPE);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
    }
    let batch_max = (crate::limits::log_buffer_bytes() / 16).max(4096);
    loop {
        let (lines, dropped) = {
            let mut queue = lock();
            queue.in_flight = 0;
            while queue.lines.is_empty() && queue.dropped == 0 {
                queue.writing = false;
                queue.sleeping = true;
                SINK.idle.notify_all();
                queue = SINK.ready.wait(queue).unwrap_or_else(|poisoned| poisoned.into_inner());
            }
            queue.sleeping = false;
            queue.writing = true;
            // The oldest lines, up to `batch_max` (at least one); the rest
            // stay queued, where newer lines can still push them out.
            let mut taken = Vec::new();
            let mut bytes = 0;
            while let Some(line) = queue.lines.front() {
                if !taken.is_empty() && bytes + line.len() > batch_max {
                    break;
                }
                bytes += line.len();
                taken.push(queue.lines.pop_front().expect("just looked"));
            }
            queue.queued -= bytes;
            queue.in_flight = bytes;
            (taken, std::mem::take(&mut queue.dropped))
        };
        // One write per batch rather than per line.
        let mut batch = Vec::with_capacity(lines.iter().map(Vec::len).sum::<usize>() + 128);
        if dropped > 0 {
            batch.extend(format_line(
                crate::limits::log_json(),
                now_millis(),
                WARN,
                "log lines dropped",
                &[("count", Value::U64(dropped))],
                None,
            ));
        }
        for line in &lines {
            batch.extend_from_slice(line);
        }
        // Under Rust's stderr lock, which `Stderr.line!` holds while it writes
        // a line: without it, a batch (or a write of it the pipe splits) could
        // land in the middle of one of its lines. Batches are small enough
        // that waiting behind one is brief.
        let _ = std::io::stderr().lock().write_all(&batch);
        // Let lines gather before the next batch: waking for every line (the
        // writer is usually that quick) costs a system call and a context
        // switch per line. Lines come out up to this much later; their
        // timestamps are from when they were logged.
        std::thread::sleep(GATHER);
    }
}

/// Wait until everything logged so far has been written, or `timeout`
/// passes (a stalled stderr mustn't keep the program from exiting).
pub fn flush(timeout: Duration) {
    let deadline = Instant::now() + timeout;
    let mut queue = lock();
    while !queue.lines.is_empty() || queue.dropped > 0 || queue.writing {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        queue = SINK.idle.wait_timeout(queue, left).unwrap_or_else(|poisoned| poisoned.into_inner()).0;
    }
}

/// Hosted function: Host.log_enabled!
#[no_mangle]
pub extern "C" fn roc_log_enabled(level: u8) -> bool {
    enabled(level)
}

/// Hosted function: Host.log_write!
#[no_mangle]
pub extern "C" fn roc_log_write(level: u8, message: RocStr, fields: RocList<RocLogField>) {
    {
        let fields: Vec<(&str, Value)> = fields
            .as_slice()
            .iter()
            .map(|field| {
                // Each accessor is only valid for its own tag.
                let value = unsafe {
                    match field.value.tag {
                        Tag::Str => Value::Str(field.value.borrow_payload_str_unchecked().as_str()),
                        Tag::U64 => Value::U64(*field.value.borrow_payload_u64_unchecked()),
                        Tag::I64 => Value::I64(*field.value.borrow_payload_i64_unchecked()),
                        Tag::F64 => Value::F64(*field.value.borrow_payload_f64_unchecked()),
                        Tag::Bool => Value::Bool(*field.value.borrow_payload_bool_unchecked()),
                    }
                };
                (field.key.as_str(), value)
            })
            .collect();
        log(level, message.as_str(), &fields);
    }
    unsafe {
        message.decref(roc_host());
        decref_log_fields(fields, roc_host());
    }
}

// --- Time ---

/// Milliseconds since the Unix epoch, on the wall clock (negative before it).
fn now_millis() -> i64 {
    now_nanos().div_euclid(1_000_000)
}

/// Nanoseconds since the Unix epoch, on the wall clock (negative before it;
/// an `I64` covers 1677 to 2262).
pub fn now_nanos() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(since) => i64::try_from(since.as_nanos()).unwrap_or(i64::MAX),
        Err(before) => i64::try_from(before.duration().as_nanos()).map_or(i64::MIN, |n| -n),
    }
}

/// Hosted function: Host.time_utc_now_ns!
#[no_mangle]
pub extern "C" fn roc_time_utc_now_ns() -> i64 {
    now_nanos()
}

/// `ms` since the Unix epoch as RFC 3339 in UTC, to the millisecond:
/// `2026-09-30T12:34:56.789Z`. (The same as `Time.Utc.to_rfc3339` in Roc.)
pub fn rfc3339_millis(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    let of_day = ms.rem_euclid(86_400_000);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        of_day / 3_600_000,
        of_day / 60_000 % 60,
        of_day / 1000 % 60,
        of_day % 1000
    )
}

/// The (proleptic Gregorian) date `days` after 1970-01-01, by Howard
/// Hinnant's `civil_from_days`.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}

// --- Formatting ---

/// Names the platform writes itself; a field using one is renamed `field.x`.
const RESERVED: [&str; 4] = ["ts", "level", "msg", "task"];

/// The longest a message or string field is written; past it, it's cut
/// short (at a character boundary) and ends in `TRUNCATED`.
const MAX_STR: usize = 16 * 1024;
/// Past this many bytes, a line's remaining fields are left out, and it ends
/// with a `truncated` field saying so.
const MAX_LINE: usize = 64 * 1024;
const TRUNCATED: &str = "...(truncated)";

/// `s`, cut short to `MAX_STR` bytes if it's longer.
fn capped(s: &str) -> std::borrow::Cow<'_, str> {
    if s.len() <= MAX_STR {
        return s.into();
    }
    let mut end = MAX_STR;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{TRUNCATED}", &s[..end]).into()
}

/// Floats in their shortest exact form: `0.5`, `2.0`, `1e300`, `1e-300`
/// (Rust's `Display` would write 300 digits), which JSON also reads.
fn float(x: f64) -> String {
    format!("{x:?}")
}

/// One line, newline included: text (`ts LEVEL message key=value ...
/// task=n`) or a JSON object.
fn format_line(json: bool, ms: i64, level: u8, message: &str, fields: &[(&str, Value)], task: Option<u64>) -> Vec<u8> {
    let level = LEVELS.get(level as usize).copied().unwrap_or("error");
    let mut out = String::with_capacity(64 + message.len() + fields.len() * 24);
    let ts = rfc3339_millis(ms);
    if json {
        out.push_str("{\"ts\":\"");
        out.push_str(&ts);
        out.push_str("\",\"level\":\"");
        out.push_str(level);
        out.push_str("\",\"msg\":");
        json_string(&mut out, &capped(message));
        if let Some(task) = task {
            out.push_str(&format!(",\"task\":{task}"));
        }
        for (key, value) in fields {
            if out.len() > MAX_LINE {
                out.push_str(",\"truncated\":true");
                break;
            }
            out.push(',');
            json_string(&mut out, &capped(&field_key(key)));
            out.push(':');
            match value {
                Value::Str(s) => json_string(&mut out, &capped(s)),
                Value::U64(n) => out.push_str(&n.to_string()),
                Value::I64(n) => out.push_str(&n.to_string()),
                // JSON has no NaN or infinity.
                Value::F64(x) if x.is_finite() => out.push_str(&float(*x)),
                Value::F64(_) => out.push_str("null"),
                Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            }
        }
        out.push('}');
    } else {
        out.push_str(&ts);
        out.push(' ');
        out.push_str(&level.to_ascii_uppercase());
        out.push(' ');
        let message = capped(message);
        // Quoted if it could pass for fields (`... from 1.2.3.4 admin=true`,
        // with the address interpolated), else as it is.
        if message.contains(['=', '"']) {
            quote(&mut out, &message);
        } else {
            escape_controls(&mut out, &message);
        }
        for (key, value) in fields {
            if out.len() > MAX_LINE {
                out.push_str(" truncated=true");
                break;
            }
            out.push(' ');
            text_key(&mut out, &capped(&field_key(key)));
            out.push('=');
            match value {
                Value::Str(s) => text_value(&mut out, &capped(s)),
                Value::U64(n) => out.push_str(&n.to_string()),
                Value::I64(n) => out.push_str(&n.to_string()),
                Value::F64(x) => out.push_str(&float(*x)),
                Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            }
        }
        if let Some(task) = task {
            out.push_str(&format!(" task={task}"));
        }
    }
    out.push('\n');
    out.into_bytes()
}

fn field_key(key: &str) -> std::borrow::Cow<'_, str> {
    if RESERVED.contains(&key) {
        format!("field.{key}").into()
    } else {
        key.into()
    }
}

fn json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A message in text: as it is, but with control characters (a newline
/// above all, which would split the line) escaped.
fn escape_controls(out: &mut String, s: &str) {
    for c in s.chars() {
        match c {
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => out.push_str(&format!("\\x{:02x}", c as u32)),
            c => out.push(c),
        }
    }
}

/// A key in text: spaces, `=` and quotes would make the line ambiguous, so
/// they become `_`.
fn text_key(out: &mut String, key: &str) {
    if key.is_empty() {
        out.push('_');
    }
    for c in key.chars() {
        out.push(if c.is_whitespace() || c.is_control() || c == '=' || c == '"' { '_' } else { c });
    }
}

/// A string value in text: bare if that's unambiguous, else in quotes with
/// `"` and `\` escaped (and control characters, as in messages).
fn text_value(out: &mut String, s: &str) {
    let bare = !s.is_empty() && !s.chars().any(|c| c.is_whitespace() || c.is_control() || c == '"' || c == '=' || c == '\\');
    if bare {
        out.push_str(s);
    } else {
        quote(out, s);
    }
}

/// `s` in quotes, with `"` and `\` escaped (and control characters, as in
/// messages).
fn quote(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c => escape_controls(out, c.encode_utf8(&mut [0; 4])),
        }
    }
    out.push('"');
}
