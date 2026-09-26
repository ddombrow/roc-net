import IOErr

## Internal hosted-effect boundary used by the platform wrappers.
##
## Applications should import the public modules (`Tcp`, `Udp`, `Unix`, ...) instead.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdin_line! : {} => Try(Str, [StdinErr(Str)])
	stdout_line! : Str => Try({}, [StdoutErr(Str)])

	## A host-owned socket of any kind (TCP or Unix listener or stream, UDP
	## socket); the public modules wrap it in distinct types. The host closes it
	## when Roc releases the last reference. Platform code must never
	## `Box.unbox` or re-box one.
	Socket :: Box(U64)

	tcp_listen! : Str => Try(Socket, IOErr)
	## Connect, giving up after `timeout_ms` milliseconds (0 means no timeout).
	tcp_connect! : Str, U64 => Try(Socket, IOErr)
	unix_listen! : Str => Try(Socket, IOErr)
	unix_connect! : Str => Try(Socket, IOErr)
	udp_bind! : Str => Try(Socket, IOErr)

	## Accept a connection on a TCP or Unix listener.
	socket_accept! : Socket => Try(Socket, IOErr)
	## Read up to `max` bytes from a stream (an empty list means the peer closed
	## it), or receive one datagram on a connected UDP socket.
	socket_read! : Socket, U64 => Try(List(U8), IOErr)
	## Write all bytes to a stream, or send one datagram on a connected UDP socket.
	socket_write! : Socket, List(U8) => Try({}, IOErr)
	## Shut down reading (0), writing (1), or both (2) on a stream.
	socket_shutdown! : Socket, U8 => Try({}, IOErr)
	## Set the read (0) or write (1) timeout in milliseconds; 0 means none.
	socket_set_timeout! : Socket, U8, U64 => Try({}, IOErr)
	socket_local_addr! : Socket => Try(Str, IOErr)
	socket_peer_addr! : Socket => Try(Str, IOErr)
	tcp_set_nodelay! : Socket, Bool => Try({}, IOErr)

	## Set the default destination for `socket_write!` and filter what
	## `socket_read!` receives to datagrams from that address.
	udp_connect! : Socket, Str => Try({}, IOErr)
	udp_send_to! : Socket, List(U8), Str => Try({}, IOErr)
	udp_recv_from! : Socket, U64 => Try({ bytes : List(U8), from : Str }, IOErr)
	udp_set_broadcast! : Socket, Bool => Try({}, IOErr)
	udp_join_multicast! : Socket, Str => Try({}, IOErr)
	udp_leave_multicast! : Socket, Str => Try({}, IOErr)

	## Nanoseconds on a monotonic clock, counted from when the program started.
	time_now_ns! : {} => U64
	## Pause the calling task (thread) for `ns` nanoseconds.
	time_sleep_ns! : U64 => {}
	## Resolve a host name to IP addresses with the OS resolver.
	dns_resolve! : Str => Try(List(Str), IOErr)

	## `count` bytes from the OS's secure random source.
	random_bytes! : U64 => List(U8)

	## Start running a task on a new thread. Returns False at the task limit.
	task_spawn! : Box(() => {}) => Bool
}
