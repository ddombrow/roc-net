import IOErr

## Internal hosted-effect boundary used by the platform wrappers.
##
## Applications should import `Stdout`, `Stderr`, `Stdin`, and `Tcp` instead.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdin_line! : {} => Try(Str, [StdinErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])

	## Host-owned sockets. The host closes one when Roc releases its last
	## reference. Platform code must never `Box.unbox` or re-box these.
	TcpListener :: Box(U64)
	TcpStream :: Box(U64)

	tcp_listen! : Str => Try(TcpListener, IOErr)
	tcp_accept! : TcpListener => Try(TcpStream, IOErr)
	tcp_listener_local_addr! : TcpListener => Try(Str, IOErr)
	## Connect, giving up after `timeout_ms` milliseconds.
	tcp_connect! : Str, U64 => Try(TcpStream, IOErr)
	## Read up to `max` bytes. An empty list means the peer closed the stream.
	tcp_read! : TcpStream, U64 => Try(List(U8), IOErr)
	## Write all bytes.
	tcp_write! : TcpStream, List(U8) => Try({}, IOErr)
	## Shut down reading (0), writing (1), or both (2).
	tcp_shutdown! : TcpStream, U8 => Try({}, IOErr)
	## Set the read (0) or write (1) timeout in milliseconds; 0 means none.
	tcp_set_timeout! : TcpStream, U8, U64 => Try({}, IOErr)
	tcp_set_nodelay! : TcpStream, Bool => Try({}, IOErr)
	tcp_local_addr! : TcpStream => Try(Str, IOErr)
	tcp_peer_addr! : TcpStream => Try(Str, IOErr)

	## Start running a task on a new thread. Returns False at the task limit.
	task_spawn! : Box(() => {}) => Bool
}
