## Internal hosted-effect boundary used by the platform wrappers.
##
## Applications should import `Stdout`, `Stderr`, `Stdin`, and `Tcp` instead.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdin_line! : {} => Try(Str, [StdinErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])

	## Bind a listener; returns its host handle.
	tcp_listen! : Str => Try(U64, [TcpErr(Str)])
	## Block until a client connects; returns the stream's host handle.
	tcp_accept! : U64 => Try(U64, [TcpErr(Str)])
	## Open a connection; returns the stream's host handle.
	tcp_connect! : Str => Try(U64, [TcpErr(Str)])
	## Read up to `max` bytes. An empty list means the peer closed the stream.
	tcp_read! : U64, U64 => Try(List(U8), [TcpErr(Str)])
	## Write all bytes.
	tcp_write! : U64, List(U8) => Try({}, [TcpErr(Str)])
	## Release a listener or stream handle. Unknown handles are ignored.
	tcp_close! : U64 => {}

	## Start running a task on a new thread. Returns False at the task limit.
	task_spawn! : Box(() => {}) => Bool
}
