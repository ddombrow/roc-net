app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Log
import pf.Stderr
import pf.Stdout
import pf.Task
import pf.Time

# Writes known log lines for scripts/run_log_tests.sh to check, which runs it
# in these modes:
#
#   log lines        every field kind, escaping, renamed keys, levels, tasks
#   log long         a string past 16 KiB, and a line past 64 KiB
#   log fail [COUNT] a line (or COUNT long ones, enough to fill a pipe), then
#                    main! failing
#   log mixed        long lines from Log and Stderr.line! at once, from four
#                    tasks of each, which mustn't tear each other
#   log stall COUNT  COUNT lines as fast as possible, then reports on stdout
#                    how long that took, and waits 3 seconds (for the script
#                    to drain stderr, which it holds stalled meanwhile)

main! : List(Str) => Try({}, _)
main! = |args|
	match args {
		[_, "lines"] => lines!()
		[_, "long"] => long!()
		[_, "mixed"] => mixed!()
		[_, "fail"] => {
			Log.info!("before failing", [])
			Err(Boom)
		}
		[_, "fail", count] => {
			for i in U64.until(0, U64.from_str(count)?) {
				Log.info!("filling", [U64("i", i), Str("padding", Str.repeat(".", 200))])
			}
			Err(Boom)
		}
		[_, "stall", count] => stall!(U64.from_str(count)?)
		_ => Err(Exit(2))
	}

lines! = || {
	Log.info!("plain message", [])
	Log.info!("fields", [Str("peer", "1.2.3.4:5"), U64("up", 120), I64("delta", -5), F64("ratio", 0.5), Bool("ok", True)])
	Log.info!("quoting", [Str("path", "a b"), Str("empty", ""), Str("q", "say \"hi\""), Str("eq", "a=b"), Str("back", "c:\\d")])
	Log.info!("two\nlines", [])
	Log.info!("reserved", [Str("msg", "x"), U64("task", 9), Str("ts", "y")])
	Log.info!("bad key", [Str("bad key", "v")])
	Log.info!("floats", [F64("big", 1e300), F64("small", 1e-300), F64("third", 1.0 / 3.0), F64("two", 2.0)])
	Log.info!("control", [Str("ctl", "a\u(01)b")])
	# Interpolated data that looks like fields mustn't pass for them.
	Log.info!("connection from 1.2.3.4 admin=true", [Str("user", "bob")])
	Log.debug!("hidden unless debug", [])
	Log.warn!("a warning", [])
	Log.error!("an error", [])
	# Which task logged it: another task has an id of its own.
	other = Task.spawn!(|| {
		Log.info!("from another task", [])
		Ok({})
	})?
	other.join!()?
	Stdout.line!("debug enabled: ${Str.inspect(Log.enabled!(Debug))}")?
	Ok({})
}

mixed! = || {
	plain_padding = Str.repeat("x", 2000)
	padding = Str.repeat("y", 2000)
	var $tasks = []
	for _ in U64.until(0, 4) {
		plain = Task.spawn!(|| {
			for i in U64.until(0, 500) {
				Stderr.line!("plain ${i.to_str()} ${plain_padding}")?
			}
			Ok({})
		})?
		logging = Task.spawn!(|| {
			for i in U64.until(0, 500) {
				Log.info!("mixed", [U64("i", i), Str("padding", padding)])
				# Let the plain task on this thread have a turn.
				Task.yield!({})
			}
			Ok({})
		})?
		$tasks = List.concat($tasks, [plain, logging])
	}
	for task in $tasks {
		task.join!()?
	}
	Ok({})
}

long! = || {
	Log.info!("long string", [Str("big", Str.repeat("x", 20000))])
	var $fields = []
	for i in U64.until(0, 10) {
		$fields = List.append($fields, Str("f${i.to_str()}", Str.repeat("y", 10000)))
	}
	Log.info!("many fields", $fields)
	Ok({})
}

stall! = |count| {
	start = Time.now!()
	for i in U64.until(0, count) {
		Log.info!("stall line", [U64("i", i), Str("padding", "................................................................................................................................................................")])
	}
	Stdout.line!("logged ${count.to_str()} lines in ${start.elapsed!().to_millis().to_str()} ms")?
	Time.sleep!(Time.seconds(3))?
	Ok({})
}
