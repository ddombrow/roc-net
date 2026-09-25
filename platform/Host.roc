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

	tcp_listen! : Str => Try(TcpListener, [TcpErr(Str)])
	tcp_accept! : TcpListener => Try(TcpStream, [TcpErr(Str)])
	tcp_connect! : Str => Try(TcpStream, [TcpErr(Str)])
	## Read up to `max` bytes. An empty list means the peer closed the stream.
	tcp_read! : TcpStream, U64 => Try(List(U8), [TcpErr(Str)])
	## Write all bytes.
	tcp_write! : TcpStream, List(U8) => Try({}, [TcpErr(Str)])
	## Shut down both directions now, waking any task blocked on the stream.
	tcp_shutdown! : TcpStream => {}

	## Start running a task on a new thread. Returns False at the task limit.
	task_spawn! : Box(() => {}) => Bool
}
