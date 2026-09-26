import Host
import IOErr

## Blocking TCP sockets.
##
## Sockets close automatically once nothing refers to them any more, including
## when a task ends early because of an error.
##
## Every operation fails with `TcpErr(IOErr)`, so an app can handle specific
## cases: `Err(TcpErr(ConnectionRefused)) => ...`.
Tcp := [].{

	## A socket bound to a local address, waiting for connections.
	Listener :: Host.Socket.{

		## Block until a client connects.
		accept! : Listener => Try(Stream, [TcpErr(IOErr)])
		accept! = |Listener.(listener)|
			match Host.socket_accept!(listener) {
				Ok(stream) => Ok(Stream.(stream))
				Err(err) => Err(TcpErr(err))
			}

		## The address this listener is bound to, such as `"127.0.0.1:8080"`.
		## After listening on port 0, this tells you which port the OS chose.
		local_addr! : Listener => Try(Str, [TcpErr(IOErr)])
		local_addr! = |Listener.(listener)| tcp_err(Host.socket_local_addr!(listener))
	}

	## A connected TCP stream.
	Stream :: Host.Socket.{

		## Read up to `max` bytes. Returns an empty list once the peer has closed
		## its side of the connection.
		read! : Stream, U64 => Try(List(U8), [TcpErr(IOErr)])
		read! = |Stream.(stream), max| tcp_err(Host.socket_read!(stream, max))

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
		read_into! : Stream, List(U8), U64 => Try(List(U8), [TcpErr(IOErr)])
		read_into! = |Stream.(stream), buffer, max| tcp_err(Host.socket_read_into!(stream, buffer, max))

		## Like `read_into!`, but add the bytes that arrived to the end of
		## `buffer` instead of replacing its contents. If the length didn't
		## change, the peer closed the stream. `Framing` reads this way.
		read_append! : Stream, List(U8), U64 => Try(List(U8), [TcpErr(IOErr)])
		read_append! = |Stream.(stream), buffer, max| tcp_err(Host.socket_read_append!(stream, buffer, max))

		## Write all of `bytes` to the stream.
		write! : Stream, List(U8) => Try({}, [TcpErr(IOErr)])
		write! = |Stream.(stream), bytes| tcp_err(Host.socket_write!(stream, bytes))

		## Write `text` encoded as UTF-8.
		write_str! : Stream, Str => Try({}, [TcpErr(IOErr)])
		write_str! = |stream, text| stream.write!(Str.to_utf8(text))

		## Shut down one or both directions while keeping the stream usable in
		## the other. `shutdown!(Write)` tells the peer you are done sending (it
		## reads the end of the stream) and still lets you read its reply.
		shutdown! : Stream, [Read, Write, Both] => Try({}, [TcpErr(IOErr)])
		shutdown! = |Stream.(stream), how| {
			code =
				match how {
					Read => 0
					Write => 1
					Both => 2
				}
			tcp_err(Host.socket_shutdown!(stream, code))
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
		set_read_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [TcpErr(IOErr)])
		set_read_timeout! = |Stream.(stream), timeout| tcp_err(Host.socket_set_timeout!(stream, 0, timeout_ms(timeout)))

		## Make writes fail with `TimedOut` if the peer stops accepting data.
		set_write_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [TcpErr(IOErr)])
		set_write_timeout! = |Stream.(stream), timeout| tcp_err(Host.socket_set_timeout!(stream, 1, timeout_ms(timeout)))

		## Send small writes immediately instead of batching them (disables
		## Nagle's algorithm). Useful for interactive protocols.
		set_nodelay! : Stream, Bool => Try({}, [TcpErr(IOErr)])
		set_nodelay! = |Stream.(stream), enabled| tcp_err(Host.tcp_set_nodelay!(stream, enabled))

		## This end's address, such as `"127.0.0.1:52814"`.
		local_addr! : Stream => Try(Str, [TcpErr(IOErr)])
		local_addr! = |Stream.(stream)| tcp_err(Host.socket_local_addr!(stream))

		## The other end's address.
		peer_addr! : Stream => Try(Str, [TcpErr(IOErr)])
		peer_addr! = |Stream.(stream)| tcp_err(Host.socket_peer_addr!(stream))
	}

	## Timeouts for the streams a listener accepts, so a client that goes
	## quiet or stops reading can't hold a server task forever. Start from
	## `listen_config` and adjust:
	##
	## ```roc
	## # Chat users can sit idle for a while.
	## config = Tcp.listen_config.with_idle_timeout(Millis(1800000))
	## listener = Tcp.listen_with!("0.0.0.0:8080", config)?
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

	## Listen on `address`, such as `"127.0.0.1:8080"`, with `listen_config`:
	## accepted streams time out after 60 seconds without data, or 60 seconds
	## blocked writing to a client that isn't reading. Use port 0 to let the OS
	## choose a free port, then ask `local_addr!` which one it chose.
	listen! : Str => Try(Listener, [TcpErr(IOErr)])
	listen! = |address| listen_with!(address, listen_config)

	## Listen on `address` with the given timeouts for accepted streams.
	listen_with! : Str, ListenConfig => Try(Listener, [TcpErr(IOErr)])
	listen_with! = |address, ListenConfig.(config)|
		match Host.tcp_listen!(address, config.idle_ms, config.write_ms) {
			Ok(listener) => Ok(Listener.(listener))
			Err(err) => Err(TcpErr(err))
		}

	## Connect to `address`, such as `"example.com:80"`, giving up after 30
	## seconds; see `connect_timeout!`.
	connect! : Str => Try(Stream, [TcpErr(IOErr)])
	connect! = |address| connect_timeout!(address, Millis(30000))

	## Connect to `address`, giving up with `TimedOut` after `timeout`.
	##
	## The timeout covers everything: looking up the name (see
	## `Dns.resolve_timeout!`) and every connection attempt. If the name has
	## several addresses, they're tried in turn, each with an equal share of
	## the time left, so an unreachable first address can't use up the whole
	## timeout. An IP address, such as `"127.0.0.1:8080"`, skips the lookup.
	connect_timeout! : Str, [Millis(U64)] => Try(Stream, [TcpErr(IOErr)])
	connect_timeout! = |address, Millis(ms)|
		match Host.tcp_connect!(address, ms) {
			Ok(stream) => Ok(Stream.(stream))
			Err(err) => Err(TcpErr(err))
		}

	## The host socket behind a stream, for `Tls.wrap_client!` and
	## `Tls.wrap_server!`. Not useful to applications.
	to_socket : Stream -> Host.Socket
	to_socket = |Stream.(stream)| stream

	tcp_err : Try(ok, IOErr) -> Try(ok, [TcpErr(IOErr)])
	tcp_err = |result|
		match result {
			Ok(value) => Ok(value)
			Err(err) => Err(TcpErr(err))
		}

	timeout_ms : [NoTimeout, Millis(U64)] -> U64
	timeout_ms = |timeout|
		match timeout {
			NoTimeout => 0
			# 0 would mean "no timeout" to the host, so round up.
			Millis(ms) => if ms == 0 1 else ms
		}
}
