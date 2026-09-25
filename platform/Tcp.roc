import Host

## Blocking TCP sockets.
##
## Sockets close automatically once nothing refers to them any more, including
## when a task ends early because of an error.
Tcp := [].{

	## A socket bound to a local address, waiting for connections.
	Listener :: Host.TcpListener.{

		## Block until a client connects.
		accept! : Listener => Try(Stream, [TcpErr(Str)])
		accept! = |Listener.(listener)|
			match Host.tcp_accept!(listener) {
				Ok(stream) => Ok(Stream.(stream))
				Err(TcpErr(err)) => Err(TcpErr(err))
			}
	}

	## A connected TCP stream.
	Stream :: Host.TcpStream.{

		## Read up to `max` bytes. Returns an empty list once the peer has closed
		## its side of the connection.
		read! : Stream, U64 => Try(List(U8), [TcpErr(Str)])
		read! = |Stream.(stream), max|
			match Host.tcp_read!(stream, max) {
				Ok(bytes) => Ok(bytes)
				Err(TcpErr(err)) => Err(TcpErr(err))
			}

		## Write all of `bytes` to the stream.
		write! : Stream, List(U8) => Try({}, [TcpErr(Str)])
		write! = |Stream.(stream), bytes|
			match Host.tcp_write!(stream, bytes) {
				Ok({}) => Ok({})
				Err(TcpErr(err)) => Err(TcpErr(err))
			}

		## Write `text` encoded as UTF-8.
		write_str! : Stream, Str => Try({}, [TcpErr(Str)])
		write_str! = |stream, text| stream.write!(Str.to_utf8(text))

		## Close the connection now instead of waiting for the stream to be
		## dropped. Any task blocked reading this stream wakes up and sees the
		## end of the stream, and later reads and writes fail.
		close! : Stream => {}
		close! = |Stream.(stream)| Host.tcp_shutdown!(stream)
	}

	## Listen on `address`, such as `"127.0.0.1:8080"`.
	listen! : Str => Try(Listener, [TcpErr(Str)])
	listen! = |address|
		match Host.tcp_listen!(address) {
			Ok(listener) => Ok(Listener.(listener))
			Err(TcpErr(err)) => Err(TcpErr(err))
		}

	## Connect to `address`, such as `"example.com:80"`.
	connect! : Str => Try(Stream, [TcpErr(Str)])
	connect! = |address|
		match Host.tcp_connect!(address) {
			Ok(stream) => Ok(Stream.(stream))
			Err(TcpErr(err)) => Err(TcpErr(err))
		}
}
