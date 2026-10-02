app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

# Checks for catching signals, run by scripts/run_net_tests.sh, which sends
# them with kill(1) as this program asks: it creates the file named by
# SIGNAL_TEST_MARKER, then MARKER.2 and MARKER.3, and the script answers
# each with the signals for the next check.

import pf.Env
import pf.File
import pf.Select
import pf.Signal
import pf.Stdout
import pf.Time

main! : List(Str) => Try({}, _)
main! = |_| {
	Signal.catch!([User1, Terminate, Hangup])?
	marker = Env.var!("SIGNAL_TEST_MARKER")?
	results = [
		check!("signal: a Select times out while no signal comes", || {
			expect_eq(select_signal!(Time.millis(50))?, "timed out")
		}),
		check!("signal: a Select arm gets SIGUSR1", || {
			File.write_utf8!(marker, "")?
			expect_eq(select_signal!(Time.seconds(10))?, "User1")
		}),
		check!("signal: Signal.next! gets SIGTERM, and the program carries on", || {
			File.write_utf8!("${marker}.2", "")?
			got = Signal.next!({})?
			expect_eq(Str.inspect(got), "Terminate")
		}),
		check!("signal: a signal sent twice while still queued counts once", || {
			File.write_utf8!("${marker}.3", "")?
			# The script sends SIGHUP twice and then nothing more.
			Time.sleep!(Time.millis(500))?
			first = select_signal!(Time.seconds(10))?
			second = select_signal!(Time.millis(100))?
			expect_eq((first, second), ("Hangup", "timed out"))
		}),
	]
	failed = List.count_if(results, |passed| !passed)
	if failed == 0 {
		Stdout.line!("All signal checks passed")
	} else {
		Stdout.line!("${failed.to_str()} signal checks failed")?
		Err(Exit(1))
	}
}

select_signal! = |timeout| {
	got =
		Select.new({})
			.on_signal(|kind| Caught(kind))
			.on_timeout(timeout, || TimedOut)
			.wait!()?
	match got {
		Caught(kind) => Ok(Str.inspect(kind))
		TimedOut => Ok("timed out")
	}
}

check! = |name, test!|
	match test!() {
		Ok({}) => {
			_ = Stdout.line!("ok    ${name}")
			True
		}
		Err(err) => {
			_ = Stdout.line!("FAIL  ${name}: ${Str.inspect(err)}")
			False
		}
	}

expect_eq = |actual, expected|
	if actual == expected {
		Ok({})
	} else {
		Err(Mismatch({ expected: Str.inspect(expected), actual: Str.inspect(actual) }))
	}
