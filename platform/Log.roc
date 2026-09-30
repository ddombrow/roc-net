import Host

## Structured log lines, for servers: a message and typed fields, with a
## timestamp, a level, and the task that logged it.
##
## ```roc
## Log.info!("session ended", [Str("peer", peer), U64("up", copied.a_to_b), U64("down", copied.b_to_a)])
## ```
##
## writes (to stderr)
##
## ```
## 2026-09-30T12:34:56.789Z INFO session ended peer=203.0.113.9:51234 up=120 down=48213 task=17
## ```
##
## **Logging never waits.** A call formats its line and queues it; a thread
## of its own writes the queue to stderr. So when whatever reads stderr falls
## behind (a full pipe, a slow log shipper, a paused terminal), tasks carry
## on; `Stderr.line!`, by contrast, waits, and so does every task sharing its
## thread. Lines come out a millisecond or so after they're logged (the
## writer gathers them into batches); their timestamps are from when they
## were logged.
##
## **Memory is capped**: lines waiting to be written take at most about 1 MiB
## (`ROC_NET_LOG_BUFFER_KIB`). If stderr takes lines more slowly than they're
## logged for long enough to fill that, the oldest are dropped, and a
## `log lines dropped` warning says how many. A server that logs in bursts
## (thousands of lines at once, say, while stderr is also busy) can hit that
## even when stderr is a fast file: if the warnings show up, raise
## `ROC_NET_LOG_BUFFER_KIB` to hold a whole burst, at the cost of that much
## memory while one is waiting. A string (the message, or a
## field) longer than 16 KiB is cut short, ending in `...(truncated)`, and
## once a line passes 64 KiB its remaining fields are left out and a
## `truncated` field says so.
##
## When `main!` returns, what's queued gets up to a second to be written (a
## stalled stderr can't hold up the exit longer); a crash loses it.
##
## Settings (environment variables, read at startup):
##
## - `ROC_NET_LOG`: the least severe level written: `debug`, `info` (the
##   default), `warn`, `error`, or `off`.
## - `ROC_NET_LOG_FORMAT`: `text` (the default, as above) or `json` (one
##   object per line: `{"ts":"...","level":"info","msg":"session ended","task":17,"peer":"...","up":120,...}`).
##
## Timestamps are the wall clock in UTC, to the millisecond, taken when the
## line is logged. `task` is the task that logged it (`main!`'s is 1), so a
## connection's lines can be told apart. Fields keep their order; one named
## `ts`, `level`, `msg` or `task` is written as `field.ts` and so on. Two
## fields with the same name are both written, which JSON parsers handle
## differently (most keep the last), so keep names distinct.
##
## Keep variable data in fields rather than in the message: fields are
## typed and easy to search. A text message containing `=` or `"` is
## written in quotes, so that interpolated data (`"connection from ${peer}"`)
## can't pass for fields.
##
## The platform's own messages come out here too: a detached task failing,
## `main!` returning an error (`main! failed`, at error level), and warnings
## such as running out of file descriptors. So `ROC_NET_LOG=off` silences
## those as well; `main!` failing still sets the exit code.
##
## Mixing `Log` and `Stderr.line!` works, but their lines may come out in a
## different order than they were written.
Log := [].{

	## How severe a line is. Lines below `ROC_NET_LOG`'s level aren't
	## written.
	Level : [Debug, Info, Warn, Error]

	## A named value in a line. Keys are best kept to letters, digits, `_`
	## and `.`: in text lines, spaces, `=` and quotes become `_`.
	Field : [Str(Str, Str), U64(Str, U64), I64(Str, I64), F64(Str, F64), Bool(Str, Bool)]

	debug! : Str, List(Field) => {}
	debug! = |message, fields| log!(Debug, message, fields)

	info! : Str, List(Field) => {}
	info! = |message, fields| log!(Info, message, fields)

	warn! : Str, List(Field) => {}
	warn! = |message, fields| log!(Warn, message, fields)

	error! : Str, List(Field) => {}
	error! = |message, fields| log!(Error, message, fields)

	## Log `message` with `fields` at `level`. Never waits and never fails.
	log! : Level, Str, List(Field) => {}
	log! = |level, message, fields| {
		code = level_code(level)
		# Skip building the host's fields for a line that won't be written.
		if Host.log_enabled!(code) {
			Host.log_write!(code, message, List.map(fields, to_host))
		}
	}

	## Whether a line at `level` would be written, to skip building costly
	## fields for one that wouldn't:
	##
	## ```roc
	## if Log.enabled!(Debug) {
	##     Log.debug!("frame", [Str("bytes", hex_dump(frame))])
	## }
	## ```
	enabled! : Level => Bool
	enabled! = |level| Host.log_enabled!(level_code(level))

	level_code : Level -> U8
	level_code = |level|
		match level {
			Debug => 0
			Info => 1
			Warn => 2
			Error => 3
		}

	to_host : Field -> Host.LogField
	to_host = |field|
		match field {
			Str(key, value) => { key, value: Str(value) }
			U64(key, value) => { key, value: U64(value) }
			I64(key, value) => { key, value: I64(value) }
			F64(key, value) => { key, value: F64(value) }
			Bool(key, value) => { key, value: Bool(value) }
		}
}
