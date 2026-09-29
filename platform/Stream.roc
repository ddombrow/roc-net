import Host
import IOErr

## Code that works with any kind of stream: `Tcp.Stream`, `Tls.Stream` and
## `Unix.Stream` have the same methods, so a function that only calls those
## methods takes any of them.
##
## Without an annotation, Roc works out what a function needs by itself. To
## write the annotation, list the methods it calls in a `where` clause, with
## their types; the error type is a variable too, since each kind of stream
## has its own (`TcpErr(IOErr)`, `TlsErr(IOErr)`, ...):
##
## ```roc
## ## Send back what arrives until the peer hangs up.
## echo! : s => Try({}, e)
## 	where [
## 		s.read! : s, U64 => Try(List(U8), e),
## 		s.write! : s, List(U8) => Try({}, e),
## 	]
## echo! = |stream| {
## 	while True {
## 		bytes = stream.read!(4096)?
## 		if List.is_empty(bytes) {
## 			break
## 		}
## 		stream.write!(bytes)?
## 	}
## 	Ok({})
## }
## ```
##
## A list holds values of one type, so to keep listeners (or streams) of
## different kinds together, wrap them in a tag union and `match` where it
## matters. Each branch calls the same generic code with its own type:
##
## ```roc
## Listener : [Plain(Tcp.Listener), Secure(Tls.Listener)]
##
## serve! : Listener => Try({}, _)
## serve! = |listener|
## 	match listener {
## 		Plain(l) => accept_loop!(l)
## 		Secure(l) => accept_loop!(l)
## 	}
## ```
##
## `examples/tls_proxy` does both.
Stream := [].{

	## Copy between `a` and `b` in both directions at once, until both
	## directions have ended, and return how many bytes went each way. The
	## usual core of a proxy:
	##
	## ```roc
	## client = listener.accept!()?
	## backend = Tcp.connect!(backend_address)?
	## copied = Stream.copy_both!(client, backend)?
	## ```
	##
	## Works with any two streams (`Tcp`, `Tls`, `Unix`), of the same kind
	## or not. The bytes are copied by the platform, never becoming Roc
	## lists; on Linux, between two plain (`Tcp` or `Unix`) streams, they
	## don't pass through the program's memory at all (`splice`). An idle
	## session holds no buffer.
	##
	## - When one side ends its sending (a plain end of stream, or TLS
	##   close_notify), that's passed on: the other side's writing is shut
	##   down, so its peer sees the end too, and the other direction keeps
	##   going. A client can send a request, close its side, and still read
	##   the whole reply.
	## - On an error in either direction, both streams are aborted (see
	##   `abort!`), so neither peer mistakes what it got for everything: a
	##   backend that resets partway through a response reaches the client
	##   as a reset, not as a clean end. A stream whose incoming data had
	##   already ended cleanly isn't reset, since what it got is complete (a
	##   reset would make its peer discard what it hadn't read yet): a slow
	##   client still gets a finished response when the session then times
	##   out. The error says where it happened (`ReadA`, `WriteB`, and so
	##   on) and how many bytes had got through each way.
	## - A TLS client that closes without close_notify fails with
	##   `ReadA(UnexpectedEof)` unless the stream has
	##   `ignore_unexpected_eof!(True)`, which a proxy usually wants.
	## - Read timeouts count the session as idle only when neither direction
	##   moves: a long download with nothing sent the other way doesn't time
	##   out, nor does a write to a slow peer that's still going. A read
	##   timeout that passes while the other direction was busy starts over,
	##   so a session that goes quiet ends after one to two read timeouts.
	##   Write timeouts apply as usual.
	## - Cancelling the task stops both directions, aborts both streams, and
	##   returns `Err(Cancelled)`.
	##
	## It copies from the streams themselves, so bytes a `Framing` reader has
	## already buffered from one (say, after reading a header line to choose
	## the backend) aren't included: write those to the other side first.
	##
	## The second direction runs on a task of its own, so this fails with
	## `TaskLimitReached` (copying nothing) at the task limit.
	copy_both! : a, b => Try(
			{ a_to_b : U64, b_to_a : U64 },
			[
				CopyErr({ failed : [ReadA(IOErr), ReadB(IOErr), WriteA(IOErr), WriteB(IOErr)], a_to_b : U64, b_to_a : U64 }),
				Cancelled,
				TaskLimitReached,
			],
		)
		where [a.socket : a -> Host.Socket, b.socket : b -> Host.Socket]
	copy_both! = |a, b| {
		{ a_to_b, b_to_a, outcome } = Host.stream_copy_both!(a.socket(), b.socket())
		failed = |how| Err(CopyErr({ failed: how, a_to_b, b_to_a }))
		match outcome {
			Done => Ok({ a_to_b, b_to_a })
			Cancelled => Err(Cancelled)
			TaskLimitReached => Err(TaskLimitReached)
			ReadA(err) => failed(ReadA(err))
			ReadB(err) => failed(ReadB(err))
			WriteA(err) => failed(WriteA(err))
			WriteB(err) => failed(WriteB(err))
		}
	}
}
