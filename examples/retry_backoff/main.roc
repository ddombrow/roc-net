app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Framing
import pf.Random
import pf.Stdout
import pf.Tcp
import pf.Time

# Demonstrates: retrying an operation that can fail for a while (a server
# starting up or restarting) with exponential backoff and jitter.
#
# Usage: retry_backoff ADDRESS [MESSAGE]
#
# Connects to a line server (such as `line_server`), sends `ECHO MESSAGE`,
# and prints the reply, retrying the connection until it works or the
# attempts run out. Start it before the server to watch it back off:
#
#   retry_backoff 127.0.0.1:8080 hello     # then, within a few seconds:
#   line_server 127.0.0.1:8080
#
# Each wait doubles, up to a cap, and is a random time up to that ("full
# jitter"), so many clients retrying at once don't come back at the same
# moment. Only errors that can clear up are retried; any other ends it at
# once. This is example code, not part of the platform: retry policies
# differ too much between protocols to fix one.

main! : List(Str) => Try({}, _)
main! = |args| {
	(address, message) =
		match args {
			[_, a] => (a, "hello")
			[_, a, m] => (a, m)
			_ => {
				Stdout.line!("Usage: retry_backoff ADDRESS [MESSAGE]")?
				return Err(Exit(2))
			}
		}
	policy = { attempts: 8, first_delay_ms: 100, max_delay_ms: 5000 }
	stream = retry!(policy, || Tcp.connect_timeout!(address, Millis(2000)))?
	stream.set_read_timeout!(Millis(5000))?
	stream.write_str!("ECHO ${message}\n")?
	(reply, _) = Framing.reader(stream).read_line!()?
	Stdout.line!("Reply: ${reply}")
}

## Run `attempt!` until it succeeds, it fails in a way that won't clear up,
## or `policy.attempts` have failed, waiting with backoff in between.
retry! = |policy, attempt!| {
	var $delay = policy.first_delay_ms
	var $tries : U64
	var $tries = 1
	while True {
		match attempt!() {
			Ok(value) => return Ok(value)
			Err(err) if $tries < policy.attempts and retryable(err) => {
				wait = Random.between!(0, $delay)
				Stdout.line!("Attempt ${$tries.to_str()} failed (${Str.inspect(err)}); retrying in ${wait.to_str()} ms")?
				Time.sleep!(Time.millis(wait))?
				doubled = $delay * 2
				$delay = if doubled > policy.max_delay_ms policy.max_delay_ms else doubled
				$tries = $tries + 1
			}
			Err(err) => return Err(GaveUp({ attempts: $tries, last: Str.inspect(err) }))
		}
	}
	crash "unreachable: the loop only exits by returning"
}

## Errors that can clear up on their own: nothing listening yet, a
## connection dropped or refused, a timeout. A bad address or a permission
## problem won't, so retrying would only waste time.
retryable = |err|
	match err {
		TcpErr(ConnectionRefused) | TcpErr(ConnectionReset) | TcpErr(ConnectionAborted) | TcpErr(TimedOut) | TcpErr(NotConnected) => True
		_ => False
	}
