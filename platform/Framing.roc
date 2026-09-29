import Bytes
import Host
import IOErr
import Time

## Split a byte stream into messages: lines, delimited records, fixed-size
## chunks, or length-prefixed frames.
##
## A `Reader` wraps any stream (`Tcp.Stream`, `Unix.Stream`, ...) and keeps the
## bytes it has read but not yet returned. Roc values don't change in place,
## so every read returns the result together with the updated reader, which
## you use for the next read:
##
## ```roc
## (line, reader2) = reader.read_line!()?
## ```
##
## For the common case of handling every message until the peer hangs up,
## `each_line!` and `each_frame!` run that loop for you.
##
## If the stream's read timeout expires between messages (before any of the
## next one has arrived), reads fail with `Idle(reader)`, handing back the
## reader unchanged: nothing was lost, so the app can check on the peer (say,
## send it a ping) and carry on reading. A timeout partway through a message
## is still an error, since part of the message has been consumed.
##
## ```roc
## match reader.read_line!() {
## 	Ok((line, next)) => ...
## 	Err(Idle(same)) => {
## 		stream.write_str!("PING\n")?
## 		# ...and read again with `same`
## 	}
## 	Err(err) => ...
## }
## ```
Framing := [].{

	Reader(s) :: { stream : s, buffered : List(U8), max_len : U64, message_timeout_ns : U64 }.{

		## Read up to (not including) the next `\n`, dropping a `\r` before it.
		##
		## Fails with `EndOfStream` if the stream ended cleanly with nothing
		## buffered, `UnexpectedEof` if it ended partway through a line,
		## `TooLong` if the line (counting a `\r` before the `\n`) is longer
		## than the reader's maximum length, and
		## `BadUtf8` if the line isn't valid UTF-8.
		read_line! = |reader| {
			(bytes, next) = reader.read_until!(10)?
			without_cr =
				match List.last(bytes) {
					Ok(13) => List.drop_last(bytes, 1)
					_ => bytes
				}
			match Str.from_utf8(without_cr) {
				Ok(line) => Ok((line, next))
				Err(_) => Err(BadUtf8)
			}
		}

		## Read up to (not including) the next `delimiter` byte, and consume the
		## delimiter. Fails with `TooLong` if the record (the bytes before the
		## delimiter) is longer than the reader's maximum length, however the
		## bytes arrive.
		read_until! = |Reader.(r), delimiter| {
			started = Time.now!()
			# Take the reader apart so the buffer has only one owner, $buffered,
			# which lets each read add to it in place.
			{ stream, buffered, max_len, message_timeout_ns } = r
			var $buffered = buffered
			var $searched = 0
			while True {
				match List.find_first_index(List.drop_first($buffered, $searched), |byte| byte == delimiter) {
					Ok(offset) => {
						end = $searched + offset
						# Check the record found, not just what was buffered
						# before it: one read can bring a whole oversized record.
						if end > max_len {
							return Err(TooLong)
						}
						record = List.take_first($buffered, end)
						rest = List.drop_first($buffered, end + 1)
						return Ok((record, Reader.({ stream, buffered: rest, max_len, message_timeout_ns })))
					}
					Err(NotFound) => {
						# No delimiter yet, so the record is at least this long.
						# Exactly max_len is still fine if the delimiter is next.
						if List.len($buffered) > max_len {
							return Err(TooLong)
						}
						$searched = List.len($buffered)
						before = List.len($buffered)
						$buffered =
							match stream.read_append!($buffered, 4096) {
								Ok(grown) => grown
								Err(err) =>
									return if before == 0 and timed_out(err) {
										Err(Idle(Reader.({ stream, buffered: [], max_len, message_timeout_ns })))
									} else {
										Err(err)
									}
							}
						if List.len($buffered) == before {
							return if before == 0 Err(EndOfStream) else Err(UnexpectedEof)
						}
						if out_of_time!(message_timeout_ns, started) {
							return Err(MessageTimedOut)
						}
					}
				}
			}
			Err(EndOfStream)
		}

		## Read exactly `count` bytes, or fail with `UnexpectedEof` (or
		## `EndOfStream` if the stream ended before any of them). Fails with
		## `TooLong` if `count` is more than the reader's maximum length.
		read_exactly! = |Reader.(r), count| {
			if count > r.max_len {
				return Err(TooLong)
			}
			(bytes, rest) = take_exactly!(r, count, Time.now!(), True)?
			Ok((bytes, Reader.(rest)))
		}

		## Read everything until the stream ends, including anything already
		## buffered. Fails with `TooLong` past the reader's maximum length.
		read_to_end! = |Reader.(r)| {
			{ stream, buffered, max_len, message_timeout_ns } = r
			var $bytes = buffered
			while True {
				if List.len($bytes) > max_len {
					return Err(TooLong)
				}
				before = List.len($bytes)
				$bytes = stream.read_append!($bytes, 4096)?
				if List.len($bytes) == before {
					break
				}
			}
			Ok(($bytes, Reader.({ stream, buffered: [], max_len, message_timeout_ns })))
		}

		## Read one frame written by `write_frame!`: a 4-byte big-endian length,
		## then that many bytes. Fails with `TooLong` if the length exceeds the
		## reader's maximum; the 4-byte header itself doesn't count toward it.
		read_frame! = |Reader.(r)| {
			# The header is framing, not payload, so the reader's limit (which
			# is for payloads) doesn't apply to it: even a reader limited to
			# fewer than 4 bytes can read small frames.
			# Header and payload are one message, on one clock.
			started = Time.now!()
			max_len = r.max_len
			(header, after_header) = take_exactly!(r, 4, started, True)?
			(len, _) =
				match Bytes.take_u32_be(header) {
					Ok(decoded) => decoded
					Err(TooShort) => return Err(UnexpectedEof)
				}
			if len.to_u64() > max_len {
				return Err(TooLong)
			}
			# Mid-frame now: a timeout here isn't idle, even with nothing
			# buffered, since the header has been read.
			(payload, rest) = take_exactly!(after_header, len.to_u64(), started, False)?
			Ok((payload, Reader.(rest)))
		}

		## Call `handle!` with each line until the stream ends or `handle!`
		## returns `Ok(Stop)`. A stream that ends cleanly between lines is a
		## normal finish, not an error. If the stream goes idle (see the
		## module docs), this ends with `Err(Idle(reader))`; call
		## `reader.each_line!(handle!)` to carry on.
		each_line! = |reader, handle!| each!(reader, |r| r.read_line!(), handle!)

		## Call `handle!` with each frame (see `read_frame!`) until the stream
		## ends or `handle!` returns `Ok(Stop)`.
		each_frame! = |reader, handle!| each!(reader, |r| r.read_frame!(), handle!)

		## Like `each_line!`, but with state carried from one line to the next:
		## `step!` gets the state so far and a line, and returns
		## `Continue(new_state)` or `Stop(new_state)`. Returns the final state.
		fold_lines! = |reader, state, step!| fold!(reader, state, |r| r.read_line!(), step!)

		## Like `each_frame!`, but with state carried from one frame to the
		## next; see `fold_lines!`.
		fold_frames! = |reader, state, step!| fold!(reader, state, |r| r.read_frame!(), step!)

		## For `Select.on_line`: `read_line!`, if a line is available now or
		## starts arriving, else `NotReady` (consuming nothing). A line that's
		## arriving in pieces is read to its end, waiting under the reader's
		## message timeout.
		try_read_line! = |reader| try_read_with!(reader, |buffered| List.contains(buffered, 10), |r| r.read_line!())

		## For `Select.on_frame`: `read_frame!`, like `try_read_line!`.
		try_read_frame! = |reader| try_read_with!(reader, frame_complete, |r| r.read_frame!())

		## Copy the next bytes of the stream to `to`: until it ends
		## (`UntilEnd`) or exactly `n` of them (`Exactly(n)`), starting with
		## the ones this reader has already buffered. Returns how many were
		## copied and the reader to carry on with. Everything else is as for
		## `Stream.copy_to!`.
		##
		## Use this, not `Stream.copy_to!` on the underlying stream, after
		## reading from the stream with a reader: a read can bring in more
		## than was asked for (the rest of a header, a body, even the start of
		## the next message), and the stream alone no longer has those bytes.
		## With `Exactly(n)`, nothing past the `n`th byte is copied: bytes
		## after it stay buffered in the reader returned, ready for its next
		## read. And the `n` bytes are one message, so the reader's message
		## timeout (60 seconds unless changed with `with_message_timeout`)
		## bounds the whole copy, as it bounds `read_exactly!`: past it, the
		## copy fails with `MessageTimedOut`, so a peer can't keep the
		## connection busy by sending a byte at a time. (For a large body on a
		## slow link, raise it.) `UntilEnd` copies a stream, not a message,
		## so only the stream's read timeout applies.
		##
		## ```roc
		## # A header line naming the payload's length, then the payload,
		## # streamed to `sink`; then the next header, on the same connection.
		## (line, $reader) = $reader.read_line!()?
		## length = parse_length(line)?
		## (_, $reader) = $reader.copy_to!(sink, Exactly(length))?
		## (next, $reader) = $reader.read_line!()?
		## ```
		copy_to! : Reader(s), t, [UntilEnd, Exactly(U64)] => Try((U64, Reader(s)), [CopyToErr({ failed : [Read(IOErr), Write(IOErr), MessageTimedOut], copied : U64 }), Cancelled])
			where [s.socket : s -> Host.Socket, t.socket : t -> Host.Socket]
		copy_to! = |Reader.(r), to, limit| {
			(first, rest, stream_limit, timeout_ns) =
				match limit {
					UntilEnd => (r.buffered, [], UntilEnd, 0)
					Exactly(n) => {
						take = if n < List.len(r.buffered) n else List.len(r.buffered)
						(List.take_first(r.buffered, take), List.drop_first(r.buffered, take), Exactly(n - take), r.message_timeout_ns)
					}
				}
			# TODO: call `Stream.copy_to!` rather than the host, once the
			# compiler lets this module see `Stream`'s functions (on
			# nightly-2026-09-24 they "do not exist" here, even a trivial one,
			# while `Tls` can call `Tcp`'s). Until then, keep this mapping the
			# same as `Stream.copy_to!`'s.
			{ copied, outcome } = Host.stream_copy_to!(r.stream.socket(), to.socket(), first, stream_limit, timeout_ns)
			match outcome {
				Done => Ok((copied, Reader.({ ..r, buffered: rest })))
				Cancelled => Err(Cancelled)
				Read(err) => Err(CopyToErr({ failed: Read(err), copied }))
				Write(err) => Err(CopyToErr({ failed: Write(err), copied }))
				MessageTimedOut => Err(CopyToErr({ failed: MessageTimedOut, copied }))
			}
		}

		## The underlying stream's host socket, for `Select` to wait on.
		socket = |Reader.(r)| r.stream.socket()

		## What the underlying stream reports when its read timeout passes.
		timeout_error = |Reader.(r)| r.stream.timeout_error()

		## Limit how long each line, record, or frame may take to arrive; past
		## it, the read fails with `MessageTimedOut`. The default is 60
		## seconds. `NoTimeout` removes the limit.
		##
		## This stops a peer that sends a message a byte at a time to keep
		## every individual read alive (a slowloris attack), which a stream's
		## read timeout can't catch. It's checked each time data arrives, so a
		## read can overrun it by up to the stream's read timeout (60 seconds
		## by default for streams a listener accepted). `read_to_end!`
		## doesn't use it, since a large download on a slow link can
		## legitimately take a long time.
		with_message_timeout = |Reader.(r), timeout| {
			ns =
				match timeout {
					NoTimeout => 0
					Millis(ms) => if ms == 0 1 else ms.times_saturated(1000000)
				}
			Reader.({ ..r, message_timeout_ns: ns })
		}

		## The longest line, record, or frame this reader accepts.
		max_len = |Reader.(r)| r.max_len
	}

	## Call `handle!` with each line from `stream` until the stream ends or
	## `handle!` returns `Ok(Stop)`. A stream that ends cleanly between lines is
	## a normal finish, not an error. Lines may be up to 1 MiB; for another
	## limit use `reader_with_max(stream, max).each_line!(handle!)`.
	##
	## ```roc
	## Framing.each_line!(stream, |line| {
	## 	stream.write_str!("you said: ${line}\n")?
	## 	Ok(Continue)
	## })
	## ```
	each_line! = |stream, handle!| reader(stream).each_line!(handle!)

	## Call `handle!` with each frame from `stream` (see `Reader.read_frame!`)
	## until the stream ends or `handle!` returns `Ok(Stop)`.
	each_frame! = |stream, handle!| reader(stream).each_frame!(handle!)

	## Carry `state` from one line to the next, until the stream ends or
	## `step!` returns `Ok(Stop(state))`, and return the final state. A handler
	## can't update variables outside itself, so this is how it keeps count,
	## tracks a session, or collects results:
	##
	## ```roc
	## count = Framing.fold_lines!(stream, 0.U64, |n, _line| Ok(Continue(n + 1)))?
	## ```
	fold_lines! = |stream, state, step!| reader(stream).fold_lines!(state, step!)

	## Like `fold_lines!`, for frames.
	fold_frames! = |stream, state, step!| reader(stream).fold_frames!(state, step!)

	## Read messages with `read!` and pass each to `handle!`, until the stream
	## ends or `handle!` says `Stop`.
	each! = |start, read!, handle!|
		fold!(start, {}, read!, |{}, message|
			match handle!(message) {
				Ok(Continue) => Ok(Continue({}))
				Ok(Stop) => Ok(Stop({}))
				Err(err) => Err(err)
			})

	## Read messages with `read!` and fold them into `state` with `step!`,
	## passing the updated reader along, until the stream ends or `step!` says
	## `Stop`. A stream that ends cleanly between messages is a normal finish.
	fold! = |start, state, read!, step!| {
		var $reader = start
		var $state = state
		while True {
			(message, $reader) =
				match read!($reader) {
					Ok(read) => read
					Err(EndOfStream) => break
					Err(err) => return Err(err)
				}
			match step!($state, message)? {
				Continue(next) => {
					$state = next
				}
				Stop(next) => {
					$state = next
					break
				}
			}
		}
		Ok($state)
	}

	## Take exactly `count` bytes from a reader's buffer and stream, adding to
	## the buffer in place as data arrives, without the length limit: `read_exactly!` applies that first, and `read_frame!`
	## reads its fixed-size header here. It works on a `Reader`'s inner
	## record, which only this module can get at, so it gives callers no way
	## around a reader's limit.
	## `read!` on the reader if a whole message is buffered (`complete`), or
	## if data arrives on the stream now (the message then is read to its end);
	## `NotReady` otherwise, with nothing consumed.
	try_read_with! = |Reader.(r), complete, read!| {
		if complete(r.buffered) {
			Ready(read!(Reader.(r)))
		} else {
			{ stream, buffered, max_len, message_timeout_ns } = r
			match stream.try_read!(4096) {
				Ok(NotReady) => NotReady
				# Empty data is the end of the stream, which `read!` reports.
				Ok(Data(bytes)) => Ready(read!(Reader.({ stream, buffered: List.concat(buffered, bytes), max_len, message_timeout_ns })))
				Err(err) => Ready(Err(err))
			}
		}
	}

	## A whole frame is buffered: its 4-byte length and that many bytes.
	frame_complete = |buffered|
		match Bytes.u32_be_at(buffered, 0) {
			Ok(len) => List.len(buffered) >= 4 + len.to_u64()
			Err(_) => False
		}

	take_exactly! = |r, count, started, message_start| {
		{ stream, buffered, max_len, message_timeout_ns } = r
		var $buffered = buffered
		while List.len($buffered) < count {
			before = List.len($buffered)
			$buffered =
				match stream.read_append!($buffered, 4096) {
					Ok(grown) => grown
					Err(err) =>
						return if message_start and before == 0 and timed_out(err) {
							Err(Idle(Reader.({ stream, buffered: [], max_len, message_timeout_ns })))
						} else {
							Err(err)
						}
				}
			if List.len($buffered) == before {
				return if before == 0 Err(EndOfStream) else Err(UnexpectedEof)
			}
			if out_of_time!(message_timeout_ns, started) {
				return Err(MessageTimedOut)
			}
		}
		Ok((List.take_first($buffered, count), { stream, buffered: List.drop_first($buffered, count), max_len, message_timeout_ns }))
	}

	## Whether a stream error is a read timeout, whichever kind of stream.
	timed_out = |err|
		match err {
			TcpErr(TimedOut) | UnixErr(TimedOut) | TlsErr(TimedOut) => True
			_ => False
		}

	## Whether a message that started at `started` has run past a message
	## timeout of `timeout_ns` (0 means none).
	out_of_time! = |timeout_ns, started| timeout_ns > 0 and started.elapsed!().to_nanos() > timeout_ns

	## Wrap `stream` in a reader that accepts lines, records, and frames of up
	## to 1 MiB, each arriving within 60 seconds (see `with_message_timeout`).
	reader = |stream| reader_with_max(stream, 1048576)

	## Wrap `stream` in a reader that accepts lines, records, and frames of up
	## to `max_len` bytes.
	reader_with_max = |stream, max_len| Reader.({ stream, buffered: [], max_len, message_timeout_ns: 60000000000 })

	## Write `bytes` as one frame for `read_frame!`: a 4-byte big-endian length,
	## then the bytes.
	write_frame! = |stream, bytes| stream.write!(List.concat(Bytes.u32_be(List.len(bytes).to_u32_wrap()), bytes))
}
