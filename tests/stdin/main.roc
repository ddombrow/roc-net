app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

# Checks for reading stdin through `Select` and `Stdin`, run by
# scripts/run_net_tests.sh with this input: "first", then (once this
# program creates the file named by STDIN_TEST_MARKER) a line of exactly
# 1 MiB, one a byte longer, "second" and "third", then the end. Waiting for the marker, not a fixed time, keeps it
# reliable on a slow machine.

import pf.Env
import pf.File
import pf.Select
import pf.Stdin
import pf.Stdout
import pf.Task
import pf.Time

main! : List(Str) => Try({}, _)
main! = |_| {
	results = [
		check!("stdin: a Select arm gets a line", || {
			got = select_line!(Time.seconds(5))?
			expect_eq(got, "first")
		}),
		check!("stdin: a Select times out while no line comes", || {
			got = select_line!(Time.millis(50))?
			# Now the feeder may send the rest.
			marker = Env.var!("STDIN_TEST_MARKER")?
			File.write_utf8!(marker, "")?
			expect_eq(got, "timed out")
		}),
		check!("stdin: a line of exactly 1 MiB is read", || {
			got = Stdin.read_line!({})?
			length =
				match got {
					Line(text) => Str.count_utf8_bytes(text)
					End => 0
				}
			expect_eq(length, 1048576)
		}),
		check!("stdin: a longer line fails with LineTooLong, and is skipped", || {
			got =
				match Stdin.read_line!({}) {
					Err(LineTooLong) => "too long"
					Ok(_) => "read"
					Err(StdinErr(message)) => message
				}
			expect_eq(got, "too long")
		}),
		check!("stdin: a line asked for by an arm that lost goes to the next reader", || {
			# The arm above asked for a line; give it time to arrive while
			# nobody waits (if it's slower, read_line! waits for it, and gets
			# it all the same).
			Time.sleep!(Time.millis(500))?
			got = Stdin.read_line!({})?
			expect_eq(got, Line("second"))
		}),
		check!("stdin: other tasks run while one waits on stdin", || {
			waiter = Task.spawn!(|| Stdin.read_line!({}))?
			# This task gets on with its own work meanwhile.
			Time.sleep!(Time.millis(10))?
			got = waiter.join!()?
			expect_eq(got, Line("third"))
		}),
		check!("stdin: the end reaches every kind of read", || {
			arm = select_line!(Time.seconds(5))?
			read = Stdin.read_line!({})?
			line = Stdin.line!({})?
			expect_eq((arm, read, line), ("end", End, ""))
		}),
	]
	failed = List.count_if(results, |passed| !passed)
	if failed == 0 {
		Stdout.line!("All stdin checks passed")
	} else {
		Stdout.line!("${failed.to_str()} stdin checks failed")?
		Err(Exit(1))
	}
}

select_line! = |timeout| {
	got =
		Select.new({})
			.on_stdin_line(|result| Read(result))
			.on_timeout(timeout, || TimedOut)
			.wait!()?
	match got {
		Read(Ok(Line(text))) => Ok(text)
		Read(Ok(End)) => Ok("end")
		Read(Err(LineTooLong)) => Ok("too long")
		Read(Err(StdinErr(message))) => Err(StdinFailed(message))
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
