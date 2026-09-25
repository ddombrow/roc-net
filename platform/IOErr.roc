## An error from a network or I/O operation.
##
## Most tags mirror the operating system's error codes. Timeouts from
## `set_read_timeout!` and `set_write_timeout!` are reported as `TimedOut`.
IOErr := [
	AddrInUse,
	AddrNotAvailable,
	BrokenPipe,
	ConnectionAborted,
	ConnectionRefused,
	ConnectionReset,
	Interrupted,
	InvalidInput,
	NotConnected,
	NotFound,
	PermissionDenied,
	TimedOut,
	## The platform's limit on open sockets was reached.
	TooManySockets,
	UnexpectedEof,
	Unsupported,
	## Any other error, with the operating system's description.
	Other(Str),
]
