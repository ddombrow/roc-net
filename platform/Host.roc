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
	## `ca_file` means Mozilla's root certificates. `alpn`: the protocols to
	## offer, most preferred first (none: no ALPN).
	tls_connect! : Str, Str, Str, List(Str), U64 => Try(Socket, IOErr)
	## Listen for TLS connections. `certs`: certificate chains and private
	## keys in PEM files, each for the server name `name` (`*.` wildcards
	## allowed); the one with an empty name is for clients that ask for no
	## name or an unknown one. `alpn`: the protocols accepted, most preferred
	## first. Each connection must finish its handshake within
	## `handshake_timeout_ms` of being accepted (0 means no limit), then has
	## the given read (idle) and write timeouts.
	tls_listen! : Str, List(TlsCert), List(Str), U64, U64, U64 => Try(Socket, IOErr)
	## A certificate for `tls_listen!` and `tls_wrap_server!`.
	TlsCert : { name : Str, cert_file : Str, key_file : Str }
	## The server name the client asked for (SNI), lower-cased and without a
	## trailing dot, or "" if none (or on a client stream). Completes the
	## handshake first.
	tls_server_name! : Socket => Try(Str, IOErr)
	## The protocol agreed with ALPN, or "" if none. Completes the handshake
	## first.
	tls_alpn_protocol! : Socket => Try(Str, IOErr)
	## Complete a TLS stream's handshake now if it hasn't happened yet.
	tls_handshake! : Socket => Try({}, IOErr)
	## Let a TLS stream treat a connection closed without close_notify as a
	## normal end of stream.
	tls_ignore_unexpected_eof! : Socket, Bool => Try({}, IOErr)
	## Upgrade a connected TCP stream to TLS as the client (STARTTLS), giving
	## up if the handshake takes longer than `timeout_ms` (0 means no limit).
	tls_wrap_client! : Socket, Str, Str, List(Str), U64 => Try(Socket, IOErr)
	## Upgrade a connected TCP stream to TLS as the server (STARTTLS); the
	## handshake must finish within `handshake_timeout_ms` (0 means no limit).
	tls_wrap_server! : Socket, List(TlsCert), List(Str), U64 => Try(Socket, IOErr)

	## Accept a connection on a TCP or Unix listener.
	socket_accept! : Socket => Try(Socket, IOErr)
	## Read up to `max` bytes from a stream (an empty list means the peer closed
	## it), or receive one datagram on a connected UDP socket.
	socket_read! : Socket, U64 => Try(List(U8), IOErr)
	## `socket_read!` without waiting, for `Select`: `NotReady` if nothing has
	## arrived (for TLS: no decrypted data yet).
	socket_try_read! : Socket, U64 => [Data(List(U8)), NotReady, Failed(IOErr)]
	## `socket_accept!` without waiting, for `Select`.
	socket_try_accept! : Socket => [Accepted(Socket), NotReady, Failed(IOErr)]
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
	## End a stream so the peer sees an error, not a clean end: a TCP reset,
	## and for TLS no close_notify.
	socket_abort! : Socket => {}
	## Set the read (0) or write (1) timeout in milliseconds; 0 means none.
	socket_set_timeout! : Socket, U8, U64 => Try({}, IOErr)
	socket_local_addr! : Socket => Try(Str, IOErr)
	socket_peer_addr! : Socket => Try(Str, IOErr)
	tcp_set_nodelay! : Socket, Bool => Try({}, IOErr)

	## Write `prefix` to the second stream, then copy the first stream to it
	## until it ends or, with `Exactly(n)`, exactly `n` more bytes, never
	## reading past them (see `Stream.copy_to!`), all within
	## `message_timeout_ns` if it isn't 0 (`MessageTimedOut` past it).
	## `copied` counts the bytes the second stream accepted, the prefix
	## included, even when the copy failed (see `Stream.copy_to!`).
	stream_copy_to! : Socket, Socket, List(U8), [UntilEnd, Exactly(U64)], U64 => { copied : U64, outcome : [Done, Read(IOErr), Write(IOErr), MessageTimedOut, Cancelled] }

	## Copy between two streams in both directions at once until both have
	## ended (see `Stream.copy_both!`), on this task and a helper task. The
	## counts are the bytes each side accepted, even when the copy failed.
	stream_copy_both! : Socket, Socket => { a_to_b : U64, b_to_a : U64, outcome : [Done, ReadA(IOErr), ReadB(IOErr), WriteA(IOErr), WriteB(IOErr), Cancelled, TaskLimitReached] }

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
	## Nanoseconds since the Unix epoch on the wall clock (negative before it).
	time_utc_now_ns! : {} => I64

	## A `Log` field, as the host takes it.
	LogField : { key : Str, value : [Str(Str), U64(U64), I64(I64), F64(F64), Bool(Bool)] }
	## Whether a line at `level` (0 debug, 1 info, 2 warn, 3 error) would be
	## written (`ROC_NET_LOG`).
	log_enabled! : U8 => Bool
	## Format a log line and queue it for the log writer; never waits (see
	## `Log`).
	log_write! : U8, Str, List(LogField) => {}
	## Pause the calling task for `ns` nanoseconds.
	## False if the task was cancelled while sleeping.
	time_sleep_ns! : U64 => Bool
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
	channel_send! : ChannelEnd, Box(() -> a), Bool => [Sent, Full, Closed, Cancelled]
	## Take the next value, waiting up to `timeout_ns` nanoseconds: 0 means
	## don't wait, and `U64.highest` means wait as long as it takes.
	channel_receive! : ChannelEnd, U64 => Try(Box(() -> a), [Closed, TimedOut, Cancelled])
	## Stop accepting values; receivers still get the queued ones.
	channel_close! : ChannelEnd => {}

	## Something a task can wait on, for `Select`.
	WaitSource : [Readable(Socket), Writable(Socket), Receivable(ChannelEnd), Sendable(ChannelEnd), Joinable(TaskHandle)]

	## Wait until any source may be ready, or `timeout_ns` passes (U64.highest:
	## no limit). A wake-up can be spurious: callers poll their sources again.
	## `SourceTimedOut(index)`: the stream at `index` reached its own deadline
	## first (its read timeout, counted from the start of this wait, or a TLS
	## handshake deadline), as a blocking read of it would have.
	select_wait! : List(WaitSource), U64 => [Ready, TimedOut, Cancelled, SourceTimedOut(U64)]

	## A number that goes up by one per call, for `Select` to rotate which arm
	## it tries first.
	select_turn! : {} => U64

	## A task, for waiting for its result or cancelling it. The task keeps
	## running when every handle is released.
	TaskHandle :: Box(U64)

	## Start running a task.
	task_spawn! : Box(() => {}) => Try(TaskHandle, [TaskLimitReached])

	## Store the running task's result, for `task_join!`. Returns whether any
	## handle to the task still exists (if not, nobody can join it).
	task_finish! : Box(() -> a) => Bool

	## Wait for a task to finish and return (another reference to) its result.
	task_join! : TaskHandle => Try(Box(() -> a), [Cancelled])

	## Ask a task to stop: its cancellable waits end with `Cancelled`.
	task_cancel! : TaskHandle => {}

	## Whether the running task has been cancelled.
	task_is_cancelled! : {} => Bool

	## Whether a task has finished, so `task_join!` would return at once.
	task_is_finished! : TaskHandle => Bool

	## Let other tasks on this thread run.
	task_yield! : {} => {}

	## Tasks started in a `Task.scope!`.
	TaskGroup :: Box(U64)

	group_new! : {} => Try(TaskGroup, [TaskLimitReached])
	group_add! : TaskGroup, TaskHandle => {}

	## Wait for every task in the group to finish, cancelling the unfinished
	## ones first if `cancel` is True. The wait itself can't be cancelled.
	group_close! : TaskGroup, Bool => {}
}
