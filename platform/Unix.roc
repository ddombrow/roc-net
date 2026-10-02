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

		## For `Select`: a waiting connection, without waiting for one
		## (`Ok(NotReady)` if there's none yet).
		try_accept! : Listener => Try([Accepted(Stream), NotReady], [UnixErr(IOErr)])
		try_accept! = |Listener.(listener)|
			match Host.socket_try_accept!(listener) {
				Accepted(stream) => Ok(Accepted(Stream.(stream)))
				NotReady => Ok(NotReady)
				Failed(err) => Err(UnixErr(err))
			}

		## The host socket, for `Select` to wait on.
		socket : Listener -> Host.Socket
		socket = |Listener.(listener)| listener

		## The path this listener is bound to.
		local_addr! : Listener => Try(Str, [UnixErr(IOErr)])
		local_addr! = |Listener.(listener)| unix_err(Host.socket_local_addr!(listener))

		## Stop listening now: new connections are refused, and `accept!` (or a
		## `Select`'s `on_accept` arm), including one already waiting, fails
		## with `UnixErr(NotConnected)`. Connections already accepted carry on.
		## For a server shutting down, which shouldn't take connections it won't
		## serve; otherwise a listener closes once nothing refers to it.
		close! : Listener => Try({}, [UnixErr(IOErr)])
		close! = |Listener.(listener)| unix_err(Host.listener_close!(listener))
	}

	## A connected Unix domain stream.
	Stream :: Host.Socket.{

		## Read up to `max` bytes. Returns an empty list once the peer has closed
		## its side of the connection.
		read! : Stream, U64 => Try(List(U8), [UnixErr(IOErr)])
		read! = |Stream.(stream), max| unix_err(Host.socket_read!(stream, max))

		## Like `read!`, but reuse `buffer`'s memory for the result: its old
		## contents are replaced by the (up to `max`) bytes that arrived, and an
		## empty result means the peer closed the stream. In a loop, pass back
		## what it returned, and there's no new allocation per read:
		##
		## ```roc
		## var $buf = List.with_capacity(4096)
		## while True {
		## 	$buf = stream.read_into!($buf, 4096)?
		## 	if List.is_empty($buf) {
		## 		break
		## 	}
		## 	stream.write!($buf)?
		## }
		## ```
		##
		## The memory is reused only while nothing else refers to `buffer`; if
		## something does (say, you kept an earlier result), you get a new list
		## instead and the old one is left as it was. Either way it's correct;
		## reuse only makes it faster.
		read_into! : Stream, List(U8), U64 => Try(List(U8), [UnixErr(IOErr)])
		read_into! = |Stream.(stream), buffer, max| unix_err(Host.socket_read_into!(stream, buffer, max))

		## Like `read_into!`, but add the bytes that arrived to the end of
		## `buffer` instead of replacing its contents. If the length didn't
		## change, the peer closed the stream. `Framing` reads this way.
		read_append! : Stream, List(U8), U64 => Try(List(U8), [UnixErr(IOErr)])
		read_append! = |Stream.(stream), buffer, max| unix_err(Host.socket_read_append!(stream, buffer, max))

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

		## For `Select`: what has arrived, without waiting (`Ok(NotReady)` if
		## nothing has yet).
		try_read! : Stream, U64 => Try([Data(List(U8)), NotReady], [UnixErr(IOErr)])
		try_read! = |Stream.(stream), max|
			match Host.socket_try_read!(stream, max) {
				Data(bytes) => Ok(Data(bytes))
				NotReady => Ok(NotReady)
				Failed(err) => Err(UnixErr(err))
			}

		## The host socket, for `Select` to wait on.
		socket : Stream -> Host.Socket
		socket = |Stream.(stream)| stream

		## What a read reports when the stream's read timeout passes, for
		## `Select` to report it the same way.
		timeout_error : Stream -> [UnixErr(IOErr)]
		timeout_error = |_| UnixErr(TimedOut)

		## Close the connection now instead of waiting for the stream to be
		## dropped. Any task blocked reading this stream wakes up and sees the
		## end of the stream, and later reads and writes fail.
		close! : Stream => {}
		close! = |Stream.(stream)| {
			_ = Host.socket_shutdown!(stream, 2)
			{}
		}

		## Give up on the connection partway through (see
		## `Tcp.Stream.abort!`). Unix sockets have no reset, so the peer sees
		## the end of the stream, as with `close!`; it's here so code over
		## any kind of stream can call it.
		abort! : Stream => {}
		abort! = |Stream.(stream)| Host.socket_abort!(stream)

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

		## Who is at the other end, as the operating system recorded it when
		## they connected: their user and group ids, and their process id
		## (`Unknown` where the system doesn't say, as macOS doesn't once the
		## peer has disconnected). The peer can't forge these, so a local
		## service can use them to decide what a client may do.
		peer_credentials! : Stream => Try({ uid : U32, gid : U32, pid : [Pid(I32), Unknown] }, [UnixErr(IOErr)])
		peer_credentials! = |Stream.(stream)|
			match Host.unix_peer_credentials!(stream) {
				Ok({ uid, gid, pid }) => Ok({ uid, gid, pid: if pid < 0 Unknown else Pid(pid) })
				Err(err) => Err(UnixErr(err))
			}

		## Ask for a receive buffer of `bytes`: how much the operating system
		## holds for this socket before the sender has to wait (or, for UDP,
		## before datagrams are dropped). It may adjust the size (Linux doubles
		## it, for its own bookkeeping); `recv_buffer_size!` says what it chose.
		set_recv_buffer_size! : Stream, U64 => Try({}, [UnixErr(IOErr)])
		set_recv_buffer_size! = |Stream.(handle), bytes| unix_err(Host.socket_set_buffer_size!(handle, 0, bytes))

		## Ask for a send buffer of `bytes` (see `set_recv_buffer_size!`).
		set_send_buffer_size! : Stream, U64 => Try({}, [UnixErr(IOErr)])
		set_send_buffer_size! = |Stream.(handle), bytes| unix_err(Host.socket_set_buffer_size!(handle, 1, bytes))

		recv_buffer_size! : Stream => Try(U64, [UnixErr(IOErr)])
		recv_buffer_size! = |Stream.(handle)| unix_err(Host.socket_buffer_size!(handle, 0))

		send_buffer_size! : Stream => Try(U64, [UnixErr(IOErr)])
		send_buffer_size! = |Stream.(handle)| unix_err(Host.socket_buffer_size!(handle, 1))
	}

	## Timeouts for the streams a listener accepts, so a client that goes
	## quiet or stops reading can't hold a server task forever. Start from
	## `listen_config` and adjust:
	##
	## ```roc
	## # Chat users can sit idle for a while.
	## config = Unix.listen_config.with_idle_timeout(Millis(1800000))
	## listener = Unix.listen_with!("/tmp/chat.sock", config)?
	## ```
	##
	## Each accepted stream starts with these; its `set_read_timeout!` and
	## `set_write_timeout!` change them for that stream.
	ListenConfig :: { idle_ms : U64, write_ms : U64 }.{

		## How long a read on an accepted stream waits for data before failing
		## with `TimedOut`: a client that stays silent this long is dropped.
		## This bounds each read, not a whole message; `Framing` readers also
		## bound each line or frame (see `Framing.Reader.with_message_timeout`).
		with_idle_timeout : ListenConfig, [NoTimeout, Millis(U64)] -> ListenConfig
		with_idle_timeout = |ListenConfig.(config), timeout| ListenConfig.({ ..config, idle_ms: timeout_ms(timeout) })

		## How long a write can wait for the client to accept data (when it has
		## stopped reading and the connection's buffers are full) before failing
		## with `TimedOut`.
		with_write_timeout : ListenConfig, [NoTimeout, Millis(U64)] -> ListenConfig
		with_write_timeout = |ListenConfig.(config), timeout| ListenConfig.({ ..config, write_ms: timeout_ms(timeout) })
	}

	## Idle and write timeouts of 60 seconds.
	listen_config : ListenConfig
	listen_config = ListenConfig.({ idle_ms: 60000, write_ms: 60000 })

	## Listen on the socket file at `path`. If a socket file is already there
	## but nothing is listening on it (left over from a program that crashed),
	## it is replaced; if something is listening, this fails with `AddrInUse`.
	## Accepted streams use `listen_config`: 60-second idle and write
	## timeouts.
	listen! : Str => Try(Listener, [UnixErr(IOErr)])
	listen! = |path| listen_with!(path, listen_config)

	## Listen on the socket file at `path` with the given timeouts for
	## accepted streams.
	listen_with! : Str, ListenConfig => Try(Listener, [UnixErr(IOErr)])
	listen_with! = |path, ListenConfig.(config)|
		match Host.unix_listen!(path, config.idle_ms, config.write_ms) {
			Ok(listener) => Ok(Listener.(listener))
			Err(err) => Err(UnixErr(err))
		}

	## Connect to the socket file at `path`, giving up after 30 seconds; see
	## `connect_timeout!`.
	connect! : Str => Try(Stream, [UnixErr(IOErr)])
	connect! = |path| connect_timeout!(path, Millis(30000))

	## Connect to the socket file at `path`, giving up with `TimedOut` after
	## `timeout`. Connecting normally succeeds or fails at once; it waits only
	## while the listener's queue of unaccepted connections is full.
	connect_timeout! : Str, [Millis(U64)] => Try(Stream, [UnixErr(IOErr)])
	connect_timeout! = |path, Millis(ms)|
		match Host.unix_connect!(path, timeout_ms(Millis(ms))) {
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
