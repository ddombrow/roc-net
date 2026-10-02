app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

# Stress for a lost wake-up: sockets closing while others open, so
# descriptor numbers are reused constantly. Unix sockets, so the stress
# isn't limited by TCP ports waiting to be reused. Each of 64 tasks repeatedly
# connects to an echo server, sends a byte and waits (2 s at most) for it
# back. An exchange that times out means a connection's wake-up was lost.
#
# Usage: fd_reuse [SECONDS]  (default 10)

import pf.Bytes
import pf.Random
import pf.Stdout
import pf.Task
import pf.Time
import pf.Unix

main! : List(Str) => Try({}, _)
main! = |args| {
	seconds =
		match args {
			[_, s] => U64.from_str(s) ?? 10
			_ => 10
		}
	address = "/tmp/roc-net-fd-reuse-${Bytes.to_hex(Bytes.u64_be(Random.u64!()))}.sock"
	listener = Unix.listen!(address)?
	_ = Task.spawn!(|| {
		while True {
			stream = listener.accept!()?
			_ = Task.spawn!(|| {
				stream.set_read_timeout!(Millis(2000))?
				bytes = stream.read!(1)?
				stream.write!(bytes)?
				Ok({})
			})
		}
		Ok({})
	})?
	started = Time.now!()
	until = seconds * 1000
	results =
		Task.scope!(|scope| {
			var $handles = []
			var $i = 0
			while $i < 64 {
				$i = $i + 1
				handle = scope.spawn!(|| client!(address, started, until))?
				$handles = List.append($handles, handle)
			}
			var $all = []
			for handle in $handles {
				$all = List.append($all, handle.join!()?)
			}
			Ok($all)
		})?
	exchanges = List.fold(results, 0, |sum, r| sum + r.exchanges)
	timeouts = List.fold(results, 0, |sum, r| sum + r.timeouts)
	Stdout.line!("${exchanges.to_str()} exchanges, ${timeouts.to_str()} timed out")?
	if timeouts > 0 Err(Exit(1)) else Ok({})
}

client! = |address, started, until_ms| {
	var $exchanges : U64
	var $exchanges = 0
	var $timeouts : U64
	var $timeouts = 0
	while started.elapsed!().to_millis() < until_ms {
		stream = Unix.connect!(address)?
		stream.set_read_timeout!(Millis(2000))?
		stream.write!([7])?
		match stream.read!(1) {
			Ok(_) => {
				$exchanges = $exchanges + 1
			}
			Err(UnixErr(TimedOut)) => {
				$timeouts = $timeouts + 1
			}
			Err(err) => return Err(err)
		}
		stream.close!()
	}
	Ok({ exchanges: $exchanges, timeouts: $timeouts })
}
