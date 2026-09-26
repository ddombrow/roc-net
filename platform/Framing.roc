import Bytes

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
Framing := [].{

	Reader(s) :: { stream : s, buffered : List(U8), max_len : U64 }.{

		## Read up to (not including) the next `\n`, dropping a `\r` before it.
		##
		## Fails with `EndOfStream` if the stream ended cleanly with nothing
		## buffered, `UnexpectedEof` if it ended partway through a line,
		## `TooLong` if no `\n` arrives within the reader's maximum length, and
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
		## delimiter.
		read_until! = |Reader.(r), delimiter| {
			var $buffered = r.buffered
			var $searched = 0
			while True {
				match List.find_first_index(List.drop_first($buffered, $searched), |byte| byte == delimiter) {
					Ok(offset) => {
						end = $searched + offset
						record = List.take_first($buffered, end)
						rest = List.drop_first($buffered, end + 1)
						return Ok((record, Reader.({ ..r, buffered: rest })))
					}
					Err(NotFound) => {
						if List.len($buffered) >= r.max_len {
							return Err(TooLong)
						}
						$searched = List.len($buffered)
						chunk = r.stream.read!(4096)?
						if List.is_empty(chunk) {
							return if List.is_empty($buffered) Err(EndOfStream) else Err(UnexpectedEof)
						}
						$buffered = List.concat($buffered, chunk)
					}
				}
			}
			Err(EndOfStream)
		}

		## Read exactly `count` bytes, or fail with `UnexpectedEof` (or
		## `EndOfStream` if the stream ended before any of them).
		read_exactly! = |Reader.(r), count| {
			var $buffered = r.buffered
			while List.len($buffered) < count {
				chunk = r.stream.read!(4096)?
				if List.is_empty(chunk) {
					return if List.is_empty($buffered) Err(EndOfStream) else Err(UnexpectedEof)
				}
				$buffered = List.concat($buffered, chunk)
			}
			bytes = List.take_first($buffered, count)
			Ok((bytes, Reader.({ ..r, buffered: List.drop_first($buffered, count) })))
		}

		## Read one frame written by `write_frame!`: a 4-byte big-endian length,
		## then that many bytes. Fails with `TooLong` if the length exceeds the
		## reader's maximum.
		read_frame! = |reader| {
			(header, after_header) = reader.read_exactly!(4)?
			(len, _) =
				match Bytes.take_u32_be(header) {
					Ok(decoded) => decoded
					Err(TooShort) => return Err(UnexpectedEof)
				}
			if len.to_u64() > after_header.max_len() {
				return Err(TooLong)
			}
			after_header.read_exactly!(len.to_u64())
		}

		## Call `handle!` with each line until the stream ends or `handle!`
		## returns `Ok(Stop)`. A stream that ends cleanly between lines is a
		## normal finish, not an error.
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

	## Wrap `stream` in a reader that accepts lines, records, and frames of up
	## to 1 MiB.
	reader = |stream| reader_with_max(stream, 1048576)

	## Wrap `stream` in a reader that accepts lines, records, and frames of up
	## to `max_len` bytes.
	reader_with_max = |stream, max_len| Reader.({ stream, buffered: [], max_len })

	## Write `bytes` as one frame for `read_frame!`: a 4-byte big-endian length,
	## then the bytes.
	write_frame! = |stream, bytes| stream.write!(List.concat(Bytes.u32_be(List.len(bytes).to_u32_wrap()), bytes))
}
