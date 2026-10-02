app [main!] { roc: "nightly-2026-09-29-7f11a82", pf: platform "../../platform/main.roc" }

import pf.Channel
import pf.Framing
import pf.Select
import pf.Signal
import pf.Stdout
import pf.Task
import pf.Tcp
import pf.Time

# Demonstrates: stopping a server cleanly on SIGTERM (or Ctrl-C), as a
# service manager, container runtime or load balancer expects: stop taking
# connections, let requests already under way finish, close idle
# connections, and give up on the rest after a grace period.
#
# Usage: graceful_server [ADDRESS] [GRACE_SECONDS]
#
# A line server: `SLOW ms` replies `DONE` after `ms` milliseconds (a long
# request), anything else is echoed back. Try it with `nc 127.0.0.1 8080`:
# send `SLOW 5000`, then stop the server with Ctrl-C or `kill PID`. The slow
# request still gets its `DONE`; an idle connection is told the server is
# shutting down and closed at once.
#
# This is example code, not part of the platform: what "finished" means,
# and how long to wait, belong to the application.

main! : List(Str) => Try({}, _)
main! = |args| {
	address = List.get(args, 1) ?? "127.0.0.1:8080"
	grace_secs = U64.from_str(List.get(args, 2) ?? "10") ?? 10
	# Before anything else: until then, these signals end the program at once.
	Signal.catch!([Terminate, Interrupt])?
	listener = Tcp.listen!(address)?
	Stdout.line!("Listening on ${address}; SIGTERM or Ctrl-C to stop.")?

	# Closing `stop` tells every connection to finish; each reports on
	# `done` when it has.
	(stop, stopping) = Channel.new!(1)?
	(done_tx, done) = Channel.new!(1024)?
	Task.scope!(|scope| {
		var $active : U64
		var $active = 0
		var $running = True
		while $running {
			next =
				Select.new({})
					.on_accept(listener, |result| Accepted(result))
					.on_receive(done, |_| Finished)
					.on_signal(|kind| Stop(kind))
					.wait!()?
			match next {
				Accepted(Ok(stream)) => {
					spawned = scope.spawn!(|| {
						result = serve!(stream, stopping)
						_ = done_tx.send!({})
						result
					})
					match spawned {
						Ok(_) => {
							$active = $active + 1
						}
						# At the task limit: shed this one connection.
						Err(TaskLimitReached) => {}
					}
				}
				Accepted(Err(err)) => Stdout.line!("accept failed: ${Str.inspect(err)}")?
				Finished => {
					$active = $active - 1
				}
				Stop(kind) => {
					Stdout.line!("${Str.inspect(kind)}: no new connections; draining ${$active.to_str()}")?
					$running = False
				}
			}
		}
		# New connections are refused from here on, rather than accepted and
		# left waiting.
		listener.close!()?
		stop.close!()
		started = Time.now!()
		while $active > 0 {
			grace_ms = grace_secs * 1000
			spent = started.elapsed!().to_millis()
			left = if spent >= grace_ms 0 else grace_ms - spent
			next =
				Select.new({})
					.on_receive(done, |_| Finished)
					.on_timeout(Time.millis(left), || OutOfTime)
					.wait!()?
			match next {
				Finished => {
					$active = $active - 1
				}
				OutOfTime => {
					Stdout.line!("Grace period over: cancelling ${$active.to_str()} connection(s)")?
					scope.cancel_all!()
					$active = 0
				}
			}
		}
		Ok({})
	})?
	Stdout.line!("Stopped.")
}

## Answer requests until the client leaves or the server is stopping. A
## request under way when the stop comes is finished first: the stop is
## only noticed between requests.
serve! = |stream, stopping| {
	var $reader = Framing.reader(stream)
	while True {
		next =
			Select.new({})
				.on_line($reader, |result| Line(result))
				.on_receive(stopping, |_| Stopping)
				.wait!()?
		match next {
			Line(Ok((line, rest))) => {
				$reader = rest
				stream.write_str!("${respond!(line)?}\n")?
			}
			Line(Err(_)) => return Ok({})
			Stopping => {
				_ = stream.write_str!("server shutting down\n")
				return Ok({})
			}
		}
	}
	Ok({})
}

respond! = |line|
	match Str.split_first(line, " ") {
		Ok({ before: "SLOW", after }) => {
			Time.sleep!(Time.millis(U64.from_str(after) ?? 1000))?
			Ok("DONE")
		}
		_ => Ok(line)
	}
