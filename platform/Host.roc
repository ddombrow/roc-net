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

	## Listen; every accepted stream gets these read (idle) and write timeouts
	## in milliseconds (0 means none).
	tcp_listen! : Str, U64, U64 => Try(Socket, IOErr)
	## Look up the name and connect, all within `timeout_ms` milliseconds (0
	## means no limit).
	tcp_connect! : Str, U64 => Try(Socket, IOErr)
	unix_listen! : Str, U64, U64 => Try(Socket, IOErr)
	unix_connect! : Str, U64 => Try(Socket, IOErr)
	udp_bind! : Str => Try(Socket, IOErr)
	## Look up the name, connect, and complete a TLS handshake, all within
	## `timeout_ms` (0 means no limit). An empty `server_name` means the address's host; an empty
	## `ca_file` means Mozilla's root certificates.
	tls_connect! : Str, Str, Str, U64 => Try(Socket, IOErr)
	## Listen for TLS connections using the certificate chain and private key
	## in these PEM files. Each connection must finish its handshake within
	## `handshake_timeout_ms` of being accepted (0 means no limit), then has
	## the given read (idle) and write timeouts.
	tls_listen! : Str, Str, Str, U64, U64, U64 => Try(Socket, IOErr)
	## Let a TLS stream treat a connection closed without close_notify as a
	## normal end of stream.
	tls_ignore_unexpected_eof! : Socket, Bool => Try({}, IOErr)
	## Upgrade a connected TCP stream to TLS as the client (STARTTLS), giving
	## up if the handshake takes longer than `timeout_ms` (0 means no limit).
	tls_wrap_client! : Socket, Str, Str, U64 => Try(Socket, IOErr)
	## Upgrade a connected TCP stream to TLS as the server (STARTTLS); the
	## handshake must finish within `handshake_timeout_ms` (0 means no limit).
	tls_wrap_server! : Socket, Str, Str, U64 => Try(Socket, IOErr)

	## Accept a connection on a TCP or Unix listener.
	socket_accept! : Socket => Try(Socket, IOErr)
	## Read up to `max` bytes from a stream (an empty list means the peer closed
	## it), or receive one datagram on a connected UDP socket.
	socket_read! : Socket, U64 => Try(List(U8), IOErr)
	## Read up to `max` bytes from a stream and return them in `list`, whose
	## old contents are replaced; its allocation is reused when possible. An
	## empty result means the peer closed the stream.
	socket_read_into! : Socket, List(U8), U64 => Try(List(U8), IOErr)
	## Like `socket_read_into!`, but add what arrived to the end of `list`.
	## An unchanged length means the peer closed the stream.
	socket_read_append! : Socket, List(U8), U64 => Try(List(U8), IOErr)
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
	## Pause the calling task for `ns` nanoseconds.
	time_sleep_ns! : U64 => {}
	## Resolve a host name to IP addresses with the OS resolver, giving up
	## after `timeout_ms` (0 means no limit).
	dns_resolve! : Str, U64 => Try(List(Str), IOErr)

	## `count` bytes from the OS's secure random source.
	random_bytes! : U64 => List(U8)

	## One end of a channel (sender or receiver), closed when Roc releases it.
	ChannelEnd :: Box(U64)

	## A channel holding up to `capacity` values.
	channel_new! : U64 => Try({ sender : ChannelEnd, receiver : ChannelEnd }, [TooManyChannels])
	## Queue a value, wrapped as a thunk so the host can hold it without knowing
	## its type. With `wait` false, return `Full` instead of waiting for room.
	channel_send! : ChannelEnd, Box(() -> a), Bool => [Sent, Full, Closed]
	## Take the next value, waiting up to `timeout_ns` nanoseconds: 0 means
	## don't wait, and `U64.highest` means wait as long as it takes.
	channel_receive! : ChannelEnd, U64 => Try(Box(() -> a), [Closed, TimedOut])
	## Stop accepting values; receivers still get the queued ones.
	channel_close! : ChannelEnd => {}

	## Start running a task. Returns False at the task limit.
	task_spawn! : Box(() => {}) => Bool
}
