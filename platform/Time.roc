import Host

## Measure elapsed time and pause.
##
## ```roc
## start = Time.now!()
## do_work!()
## Stdout.line!("took ${start.elapsed!().to_millis().to_str()} ms")?
## Time.sleep!(Time.millis(500))
## ```
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

	## A length of time, with nanosecond precision.
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
		plus = |Duration.(a), Duration.(b)| Duration.(a + b)

		is_lt : Duration, Duration -> Bool
		is_lt = |Duration.(a), Duration.(b)| a < b
	}

	nanos : U64 -> Duration
	nanos = |n| Duration.(n)

	micros : U64 -> Duration
	micros = |n| Duration.(n * 1000)

	millis : U64 -> Duration
	millis = |n| Duration.(n * 1000000)

	seconds : U64 -> Duration
	seconds = |n| Duration.(n * 1000000000)

	## The current moment on the monotonic clock.
	now! : () => Instant
	now! = || Instant.(Host.time_now_ns!({}))

	## Pause the calling task for `duration`. Other tasks keep running.
	sleep! : Duration => {}
	sleep! = |Duration.(n)| Host.time_sleep_ns!(n)
}
