import Host

## Blocking TCP sockets.
##
## Listeners and streams are host resources: call `close!` when you are done
## with one, or it stays open until the program exits.
Tcp := [].{

	## A socket bound to a local address, waiting for connections.
	Listener :: U64.{

		## Block until a client connects.
		accept! : Listener => Try(Stream, [TcpErr(Str)])
		accept! = |Listener.(id)|
			match Host.tcp_accept!(id) {
				Ok(stream_id) => Ok(Stream.(stream_id))
				Err(TcpErr(err)) => Err(TcpErr(err))
			}

		## Stop listening.
		close! : Listener => {}
		close! = |Listener.(id)| Host.tcp_close!(id)
	}

	## A connected TCP stream.
	Stream :: U64.{

		## Read up to `max` bytes. Returns an empty list once the peer has closed
		## its side of the connection.
		read! : Stream, U64 => Try(List(U8), [TcpErr(Str)])
		read! = |Stream.(id), max|
			match Host.tcp_read!(id, max) {
				Ok(bytes) => Ok(bytes)
				Err(TcpErr(err)) => Err(TcpErr(err))
			}

		## Write all of `bytes` to the stream.
		write! : Stream, List(U8) => Try({}, [TcpErr(Str)])
		write! = |Stream.(id), bytes|
			match Host.tcp_write!(id, bytes) {
				Ok({}) => Ok({})
				Err(TcpErr(err)) => Err(TcpErr(err))
			}

		## Write `text` encoded as UTF-8.
		write_str! : Stream, Str => Try({}, [TcpErr(Str)])
		write_str! = |stream, text| stream.write!(Str.to_utf8(text))

		## Close the connection.
		close! : Stream => {}
		close! = |Stream.(id)| Host.tcp_close!(id)
	}

	## Listen on `address`, such as `"127.0.0.1:8080"`.
	listen! : Str => Try(Listener, [TcpErr(Str)])
	listen! = |address|
		match Host.tcp_listen!(address) {
			Ok(id) => Ok(Listener.(id))
			Err(TcpErr(err)) => Err(TcpErr(err))
		}

	## Connect to `address`, such as `"example.com:80"`.
	connect! : Str => Try(Stream, [TcpErr(Str)])
	connect! = |address|
		match Host.tcp_connect!(address) {
			Ok(id) => Ok(Stream.(id))
			Err(TcpErr(err)) => Err(TcpErr(err))
		}
}
