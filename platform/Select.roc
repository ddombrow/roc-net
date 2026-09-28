import Host
import Time

## Wait for whichever of several things happens first: data on a stream, a
## connection on a listener, a value on a channel, room in a channel, or a
## timeout.
##
## Build a `Select` from arms, each saying what to wait for and how to turn
## what happened into a value of your own type, then `wait!`:
##
## ```roc
## next = Select.new({})
##     .on_read(stream, 4096, |result| FromPeer(result))
##     .on_receive(outbox, |result| ToSend(result))
##     .on_timeout(Time.seconds(30), || Idle)
##     .wait!()?
##
## match next {
##     FromPeer(Ok(bytes)) => ...
##     FromPeer(Err(err)) => ...
##     ToSend(Ok(message)) => ...
##     ToSend(Err(ChannelClosed)) => ...
##     Idle => ...
## }
## ```
##
## - Exactly one arm happens per `wait!`, and only that arm consumes anything:
##   a value stays in a channel, and data on a stream, unless its arm won.
## - Each arm's result includes its errors (`Try`), so a closed stream is an
##   outcome to handle, not a failed `wait!`.
## - When several arms are ready at once, which one wins rotates, so an arm
##   that's always ready can't starve the others.
## - `wait!` fails only if the task is cancelled (see `Task`).
## - A stream's own timeouts still apply: an `on_read` (or `on_line`,
##   `on_frame`) arm reports `TimedOut` once the stream's read timeout passes
##   with nothing arriving (and a TLS stream, its handshake deadline), as a
##   blocking read would. To wait longer, raise or remove the read timeout
##   (`set_read_timeout!`, or a listener's `with_idle_timeout`).
## - Arms work with any stream type: `Tcp`, `Unix` and `Tls` streams and
##   listeners, `Framing` readers over them, and `Channel` ends.
Select := [].{

	## An arm: how to check it without waiting, what to wait on, and for a
	## stream, what it reports when the stream's own timeout passes.
	Arm(out) : { poll! : {} => [Got(out), NotReady], source : Host.WaitSource, on_stream_timeout : [NoDeadline, Report(() -> out)] }

	## Arms waiting to be `wait!`ed on, each producing an `out`.
	Arms(out) :: { arms : List(Arm(out)), timeout : [NoTimeout, After(U64, () -> out)] }.{

		## Up to `max` bytes arriving on `stream`; an empty list means the peer
		## closed its side. `to_out` gets what `stream.read!` would return.
		on_read = |Arms.({ arms, timeout }), stream, max, to_out| {
			poll! = |{}|
				match stream.try_read!(max) {
					Ok(Data(bytes)) => Got(to_out(Ok(bytes)))
					Ok(NotReady) => NotReady
					Err(err) => Got(to_out(Err(err)))
				}
			on_stream_timeout = Report(|| to_out(Err(stream.timeout_error())))
			Arms.({ arms: List.append(arms, { poll!: poll!, source: Readable(stream.socket()), on_stream_timeout }), timeout })
		}

		## A connection arriving on `listener`. `to_out` gets what
		## `listener.accept!` would return.
		on_accept = |Arms.({ arms, timeout }), listener, to_out| {
			poll! = |{}|
				match listener.try_accept!() {
					Ok(Accepted(stream)) => Got(to_out(Ok(stream)))
					Ok(NotReady) => NotReady
					Err(err) => Got(to_out(Err(err)))
				}
			Arms.({ arms: List.append(arms, { poll!: poll!, source: Readable(listener.socket()), on_stream_timeout: NoDeadline }), timeout })
		}

		## A line on a `Framing` reader. `to_out` gets what `reader.read_line!`
		## would return, including the reader to continue with. A line that
		## starts arriving is read to its end (under the reader's message
		## timeout), so once this arm has begun, it wins.
		on_line = |Arms.({ arms, timeout }), reader, to_out| {
			poll! = |{}|
				match reader.try_read_line!() {
					NotReady => NotReady
					Ready(result) => Got(to_out(result))
				}
			on_stream_timeout = Report(|| to_out(Err(reader.timeout_error())))
			Arms.({ arms: List.append(arms, { poll!: poll!, source: Readable(reader.socket()), on_stream_timeout }), timeout })
		}

		## A frame on a `Framing` reader (see `on_line`).
		on_frame = |Arms.({ arms, timeout }), reader, to_out| {
			poll! = |{}|
				match reader.try_read_frame!() {
					NotReady => NotReady
					Ready(result) => Got(to_out(result))
				}
			on_stream_timeout = Report(|| to_out(Err(reader.timeout_error())))
			Arms.({ arms: List.append(arms, { poll!: poll!, source: Readable(reader.socket()), on_stream_timeout }), timeout })
		}

		## A value arriving on a channel's `receiver`, or the channel closing
		## (`Err(ChannelClosed)`).
		on_receive = |Arms.({ arms, timeout }), receiver, to_out| {
			poll! = |{}|
				match receiver.try_receive!() {
					Ok(value) => Got(to_out(Ok(value)))
					Err(ChannelEmpty) => NotReady
					Err(ChannelClosed) => Got(to_out(Err(ChannelClosed)))
				}
			Arms.({ arms: List.append(arms, { poll!: poll!, source: Receivable(receiver.channel_end()), on_stream_timeout: NoDeadline }), timeout })
		}

		## Room for `value` on a channel's `sender`: if this arm wins, `value`
		## has been sent. `Err(ChannelClosed)` if nobody will receive it.
		on_send = |Arms.({ arms, timeout }), sender, value, to_out| {
			poll! = |{}|
				match sender.try_send!(value) {
					Ok({}) => Got(to_out(Ok({})))
					Err(ChannelFull) => NotReady
					Err(ChannelClosed) => Got(to_out(Err(ChannelClosed)))
				}
			Arms.({ arms: List.append(arms, { poll!: poll!, source: Sendable(sender.channel_end()), on_stream_timeout: NoDeadline }), timeout })
		}

		## Nothing else happening within `duration` of `wait!` starting. With
		## several timeouts, the shortest applies.
		on_timeout : Arms(out), Time.Duration, (() -> out) -> Arms(out)
		on_timeout = |Arms.({ arms, timeout }), duration, to_out| {
			ns = duration.to_nanos()
			shortest =
				match timeout {
					After(existing, _) if existing <= ns => timeout
					_ => After(ns, to_out)
				}
			Arms.({ arms, timeout: shortest })
		}

		## Wait for the first arm to happen and return its value. Fails only
		## with `Cancelled`, if the task is cancelled while waiting.
		wait! : Arms(out) => Try(out, [Cancelled])
		wait! = |Arms.({ arms, timeout })| {
			started = Host.time_now_ns!({})
			deadline =
				match timeout {
					NoTimeout => U64.highest
					After(ns, _) => started.plus_saturated(ns)
				}
			count = List.len(arms)
			# Start at a different arm each time, so one that's always ready
			# can't starve the others.
			first = if count == 0 0 else started % count
			sources = List.map(arms, |arm| arm.source)
			while True {
				for offset in U64.until(0, count) {
					match List.get(arms, (first + offset) % count) {
						Ok(arm) =>
							match (arm.poll!)({}) {
								Got(value) => return Ok(value)
								NotReady => {}
							}
						Err(OutOfBounds) => {}
					}
				}
				now = Host.time_now_ns!({})
				if now >= deadline {
					match timeout {
						After(_, to_out) => return Ok(to_out())
						NoTimeout => {}
					}
				}
				remaining = if deadline == U64.highest U64.highest else deadline - now
				match Host.select_wait!(sources, remaining) {
					Cancelled => return Err(Cancelled)
					Ready | TimedOut => {}
					# That arm's stream reached its own timeout, for this wait.
					SourceTimedOut(index) =>
						match List.get(arms, index) {
							Ok({ on_stream_timeout: Report(report), .. }) => return Ok(report())
							_ => {}
						}
				}
			}
			crash "unreachable: the loop above only exits by returning"
		}
	}

	## A `Select` with no arms yet.
	new : {} -> Arms(out)
	new = |{}| Arms.({ arms: [], timeout: NoTimeout })
}
