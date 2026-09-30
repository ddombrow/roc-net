import Host

## Measure elapsed time, pause, and tell the date and time.
##
## ```roc
## start = Time.now!()
## do_work!()
## Stdout.line!("took ${start.elapsed!().to_millis().to_str()} ms")?
## Time.sleep!(Time.millis(500))?
## Stdout.line!("it's ${Time.utc_now!().to_rfc3339()}")?  # 2026-09-30T12:34:56.789Z
## ```
##
## `now!` and `Instant` are for measuring (a monotonic clock, which the
## system's date and time settings don't move); `utc_now!` and `Utc` are for
## telling the time (the wall clock, which they do).
Time := [].{

	## A moment on a monotonic clock: one that never goes backwards, even if
	## the system's date and time are changed. Use it to measure how long
	## something took, not to tell the date.
	Instant :: U64.{

		## How long after `earlier` this instant is (zero if it's before it).
		since : Instant, Instant -> Duration
		since = |Instant.(later), Instant.(earlier)| Duration.(if later > earlier later - earlier else 0)

		## How long ago this instant was.
		elapsed! : Instant => Duration
		elapsed! = |instant| now!().since(instant)
	}

	## A length of time, with nanosecond precision, up to about 584 years:
	## longer durations (`Time.seconds(U64.highest)`, or adding up to more)
	## are capped there rather than overflowing, which a timeout treats as no
	## limit.
	Duration :: U64.{

		to_nanos : Duration -> U64
		to_nanos = |Duration.(n)| n

		## Whole microseconds, rounded down.
		to_micros : Duration -> U64
		to_micros = |Duration.(n)| n // 1000

		## Whole milliseconds, rounded down.
		to_millis : Duration -> U64
		to_millis = |Duration.(n)| n // 1000000

		## This duration minus `other`, or zero if `other` is longer.
		minus : Duration, Duration -> Duration
		minus = |Duration.(a), Duration.(b)| Duration.(if a > b a - b else 0)

		plus : Duration, Duration -> Duration
		plus = |Duration.(a), Duration.(b)| Duration.(a.plus_saturated(b))

		is_lt : Duration, Duration -> Bool
		is_lt = |Duration.(a), Duration.(b)| a < b
	}

	## A moment on the wall clock, in UTC: nanoseconds since the Unix epoch
	## (1970-01-01T00:00:00Z), negative before it. Covers the years 1677 to
	## 2262. For timestamps and dates; to measure how long something took,
	## use `Instant`, which the system's clock being set can't disturb.
	Utc :: I64.{

		to_nanos_since_epoch : Utc -> I64
		to_nanos_since_epoch = |Utc.(n)| n

		## Whole milliseconds since the epoch, rounded down (towards the past).
		to_millis_since_epoch : Utc -> I64
		to_millis_since_epoch = |Utc.(n)| floor_div(n, 1000000)

		## Whole seconds since the epoch, rounded down: a Unix timestamp.
		to_seconds_since_epoch : Utc -> I64
		to_seconds_since_epoch = |Utc.(n)| floor_div(n, 1000000000)

		## RFC 3339 (and ISO 8601) in UTC, to the millisecond:
		## `"2026-09-30T12:34:56.789Z"`, the form `Log` timestamps take.
		to_rfc3339 : Utc -> Str
		to_rfc3339 = |utc| {
			ms = utc.to_millis_since_epoch()
			days = floor_div(ms, 86400000)
			of_day = ms - days * 86400000
			{ year, month, day } = civil_from_days(days)
			hours = of_day // 3600000
			minutes = (of_day // 60000) % 60
			seconds = (of_day // 1000) % 60
			millis = of_day % 1000
			"${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}T${pad(hours, 2)}:${pad(minutes, 2)}:${pad(seconds, 2)}.${pad(millis, 3)}Z"
		}

		## Whether this moment is before `other`.
		is_lt : Utc, Utc -> Bool
		is_lt = |Utc.(a), Utc.(b)| a < b
	}

	## The current moment on the wall clock.
	utc_now! : () => Utc
	utc_now! = || Utc.(Host.time_utc_now_ns!({}))

	## The moment `ns` nanoseconds after the Unix epoch.
	utc_from_nanos : I64 -> Utc
	utc_from_nanos = |ns| Utc.(ns)

	## The moment `ms` milliseconds after the Unix epoch (a JavaScript-style
	## timestamp), capped at the range `Utc` covers.
	utc_from_millis : I64 -> Utc
	utc_from_millis = |ms| Utc.(ms.times_saturated(1000000))

	## The moment `s` seconds after the Unix epoch (a Unix timestamp), capped
	## at the range `Utc` covers.
	utc_from_seconds : I64 -> Utc
	utc_from_seconds = |s| Utc.(s.times_saturated(1000000000))

	## Division rounding towards negative infinity (`//` rounds towards zero).
	floor_div : I64, I64 -> I64
	floor_div = |a, b| {
		q = a // b
		if (a % b != 0) and ((a < 0) != (b < 0)) q - 1 else q
	}

	## The (proleptic Gregorian) date `days` after 1970-01-01, by Howard
	## Hinnant's `civil_from_days`, as the host formats `Log` timestamps.
	civil_from_days : I64 -> { year : I64, month : I64, day : I64 }
	civil_from_days = |days| {
		z = days + 719468
		era = floor_div(z, 146097)
		doe = z - era * 146097
		yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
		doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
		mp = (5 * doy + 2) // 153
		day = doy - (153 * mp + 2) // 5 + 1
		month = if mp < 10 mp + 3 else mp - 9
		year = yoe + era * 400 + (if month <= 2 1 else 0)
		{ year, month, day }
	}

	## `n` in decimal, with leading zeros to make `width` digits.
	pad : I64, U64 -> Str
	pad = |n, width| {
		digits = n.to_str()
		length = Str.count_utf8_bytes(digits)
		if length >= width digits else Str.concat(Str.repeat("0", width - length), digits)
	}

	nanos : U64 -> Duration
	nanos = |n| Duration.(n)

	micros : U64 -> Duration
	micros = |n| Duration.(n.times_saturated(1000))

	millis : U64 -> Duration
	millis = |n| Duration.(n.times_saturated(1000000))

	seconds : U64 -> Duration
	seconds = |n| Duration.(n.times_saturated(1000000000))

	## The current moment on the monotonic clock.
	now! : () => Instant
	now! = || Instant.(Host.time_now_ns!({}))

	## Pause the calling task for `duration`. Other tasks keep running. Fails
	## with `Cancelled` if the task is cancelled meanwhile (see `Task`).
	sleep! : Duration => Try({}, [Cancelled])
	sleep! = |Duration.(n)| if Host.time_sleep_ns!(n) Ok({}) else Err(Cancelled)
}
