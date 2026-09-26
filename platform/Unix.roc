import Host
import IOErr

## Unix domain stream sockets: connections between processes on the same
## machine, addressed by a file path such as `"/tmp/app.sock"`.
##
## Streams have the same methods as `Tcp.Stream` (except `set_nodelay!`), so
## code written against those methods works with either.
##
## Sockets close automatically once nothing refers to them any more. Every
## operation fails with `UnixErr(IOErr)`.
Unix := [].{

	## A socket bound to a path, waiting for connections. When it closes, it
	## deletes its socket file.
	Listener :: Host.Socket.{

		## Block until a client connects.
		accept! : Listener => Try(Stream, [UnixErr(IOErr)])
		accept! = |Listener.(listener)|
			match Host.socket_accept!(listener) {
				Ok(stream) => Ok(Stream.(stream))
				Err(err) => Err(UnixErr(err))
			}

		## The path this listener is bound to.
		local_addr! : Listener => Try(Str, [UnixErr(IOErr)])
		local_addr! = |Listener.(listener)| unix_err(Host.socket_local_addr!(listener))
	}

	## A connected Unix domain stream.
	Stream :: Host.Socket.{

		## Read up to `max` bytes. Returns an empty list once the peer has closed
		## its side of the connection.
		read! : Stream, U64 => Try(List(U8), [UnixErr(IOErr)])
		read! = |Stream.(stream), max| unix_err(Host.socket_read!(stream, max))

		## Write all of `bytes` to the stream.
		write! : Stream, List(U8) => Try({}, [UnixErr(IOErr)])
		write! = |Stream.(stream), bytes| unix_err(Host.socket_write!(stream, bytes))

		## Write `text` encoded as UTF-8.
		write_str! : Stream, Str => Try({}, [UnixErr(IOErr)])
		write_str! = |stream, text| stream.write!(Str.to_utf8(text))

		## Shut down one or both directions while keeping the stream usable in
		## the other. See `Tcp.Stream.shutdown!`.
		shutdown! : Stream, [Read, Write, Both] => Try({}, [UnixErr(IOErr)])
		shutdown! = |Stream.(stream), how| {
			code =
				match how {
					Read => 0
					Write => 1
					Both => 2
				}
			unix_err(Host.socket_shutdown!(stream, code))
		}

		## Close the connection now instead of waiting for the stream to be
		## dropped. Any task blocked reading this stream wakes up and sees the
		## end of the stream, and later reads and writes fail.
		close! : Stream => {}
		close! = |Stream.(stream)| {
			_ = Host.socket_shutdown!(stream, 2)
			{}
		}

		## Make reads fail with `TimedOut` if no data arrives in time.
		set_read_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [UnixErr(IOErr)])
		set_read_timeout! = |Stream.(stream), timeout| unix_err(Host.socket_set_timeout!(stream, 0, timeout_ms(timeout)))

		## Make writes fail with `TimedOut` if the peer stops accepting data.
		set_write_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [UnixErr(IOErr)])
		set_write_timeout! = |Stream.(stream), timeout| unix_err(Host.socket_set_timeout!(stream, 1, timeout_ms(timeout)))

		## This end's path. A connecting client usually has no path, so this is
		## often the empty string.
		local_addr! : Stream => Try(Str, [UnixErr(IOErr)])
		local_addr! = |Stream.(stream)| unix_err(Host.socket_local_addr!(stream))

		## The other end's path (empty if it has none).
		peer_addr! : Stream => Try(Str, [UnixErr(IOErr)])
		peer_addr! = |Stream.(stream)| unix_err(Host.socket_peer_addr!(stream))
	}

	## Listen on the socket file at `path`. If a socket file is already there
	## but nothing is listening on it (left over from a program that crashed),
	## it is replaced; if something is listening, this fails with `AddrInUse`.
	listen! : Str => Try(Listener, [UnixErr(IOErr)])
	listen! = |path|
		match Host.unix_listen!(path) {
			Ok(listener) => Ok(Listener.(listener))
			Err(err) => Err(UnixErr(err))
		}

	## Connect to the socket file at `path`.
	connect! : Str => Try(Stream, [UnixErr(IOErr)])
	connect! = |path|
		match Host.unix_connect!(path) {
			Ok(stream) => Ok(Stream.(stream))
			Err(err) => Err(UnixErr(err))
		}

	unix_err : Try(ok, IOErr) -> Try(ok, [UnixErr(IOErr)])
	unix_err = |result|
		match result {
			Ok(value) => Ok(value)
			Err(err) => Err(UnixErr(err))
		}

	timeout_ms : [NoTimeout, Millis(U64)] -> U64
	timeout_ms = |timeout|
		match timeout {
			NoTimeout => 0
			# 0 would mean "no timeout" to the host, so round up.
			Millis(ms) => if ms == 0 1 else ms
		}
}
