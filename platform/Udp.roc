import Host
import IOErr

## UDP sockets: send and receive individual datagrams.
##
## Datagrams may be lost, duplicated, or arrive out of order, and each is
## delivered whole or not at all. Use `set_read_timeout!` when waiting for a
## reply, since a lost packet otherwise means waiting forever.
##
## Addresses given as host names (`"example.com:53"`) are looked up with the
## system resolver on every call, with no timeout beyond the resolver's own.
## For a name, look it up once with `Dns.resolve_timeout!` and use the IP
## address.
##
## Sockets close automatically once nothing refers to them any more. Every
## operation fails with `UdpErr(IOErr)`.
Udp := [].{

	## A UDP socket bound to a local address.
	Socket :: Host.Socket.{

		## Send `bytes` as one datagram to `address`, such as `"127.0.0.1:5353"`.
		send_to! : Socket, List(U8), Str => Try({}, [UdpErr(IOErr)])
		send_to! = |Socket.(socket), bytes, address| udp_err(Host.udp_send_to!(socket, bytes, address))

		## Wait for the next datagram and return its bytes and the sender's
		## address. A datagram longer than `max` bytes is cut short, and
		## `truncated` is `True`: the rest of it is lost, so don't parse it as
		## if it were whole.
		recv_from! : Socket, U64 => Try({ bytes : List(U8), from : Str, truncated : Bool }, [UdpErr(IOErr)])
		recv_from! = |Socket.(socket), max| udp_err(Host.udp_recv_from!(socket, max))

		## Fix this socket's peer: `send!` then sends to `address`, and `recv!`
		## only receives datagrams from it. On most systems a connected socket
		## also reports `ConnectionRefused` when the peer's port is closed.
		connect! : Socket, Str => Try({}, [UdpErr(IOErr)])
		connect! = |Socket.(socket), address| udp_err(Host.udp_connect!(socket, address))

		## Send `bytes` as one datagram to the connected peer.
		send! : Socket, List(U8) => Try({}, [UdpErr(IOErr)])
		send! = |Socket.(socket), bytes| udp_err(Host.socket_write!(socket, bytes))

		## Wait for the next datagram from the connected peer. A datagram longer
		## than `max` bytes is cut short, and `truncated` is `True`.
		recv! : Socket, U64 => Try({ bytes : List(U8), truncated : Bool }, [UdpErr(IOErr)])
		recv! = |Socket.(socket), max| udp_err(Host.udp_recv!(socket, max))

		## Make receives fail with `TimedOut` if no datagram arrives in time.
		set_read_timeout! : Socket, [NoTimeout, Millis(U64)] => Try({}, [UdpErr(IOErr)])
		set_read_timeout! = |Socket.(socket), timeout| udp_err(Host.socket_set_timeout!(socket, 0, timeout_ms(timeout)))

		## Make sends fail with `TimedOut` if they cannot complete in time.
		set_write_timeout! : Socket, [NoTimeout, Millis(U64)] => Try({}, [UdpErr(IOErr)])
		set_write_timeout! = |Socket.(socket), timeout| udp_err(Host.socket_set_timeout!(socket, 1, timeout_ms(timeout)))

		## Allow sending to broadcast addresses such as `"255.255.255.255:9"`.
		set_broadcast! : Socket, Bool => Try({}, [UdpErr(IOErr)])
		set_broadcast! = |Socket.(socket), enabled| udp_err(Host.udp_set_broadcast!(socket, enabled))

		## Start receiving datagrams sent to the multicast group `group`, such
		## as `"239.1.2.3"` or `"ff02::1234"`, on the default interface.
		join_multicast! : Socket, Str => Try({}, [UdpErr(IOErr)])
		join_multicast! = |Socket.(socket), group| udp_err(Host.udp_join_multicast!(socket, group))

		## Stop receiving datagrams sent to the multicast group `group`.
		leave_multicast! : Socket, Str => Try({}, [UdpErr(IOErr)])
		leave_multicast! = |Socket.(socket), group| udp_err(Host.udp_leave_multicast!(socket, group))

		## The address this socket is bound to. After binding port 0, this tells
		## you which port the OS chose.
		local_addr! : Socket => Try(Str, [UdpErr(IOErr)])
		local_addr! = |Socket.(socket)| udp_err(Host.socket_local_addr!(socket))

		## The connected peer's address; fails with `NotConnected` if
		## `connect!` hasn't been called.
		peer_addr! : Socket => Try(Str, [UdpErr(IOErr)])
		peer_addr! = |Socket.(socket)| udp_err(Host.socket_peer_addr!(socket))

		## Ask for a receive buffer of `bytes`: how much the operating system
		## holds for this socket before the sender has to wait (or, for UDP,
		## before datagrams are dropped). It may adjust the size (Linux doubles
		## it, for its own bookkeeping); `recv_buffer_size!` says what it chose.
		set_recv_buffer_size! : Socket, U64 => Try({}, [UdpErr(IOErr)])
		set_recv_buffer_size! = |Socket.(handle), bytes| udp_err(Host.socket_set_buffer_size!(handle, 0, bytes))

		## Ask for a send buffer of `bytes` (see `set_recv_buffer_size!`).
		set_send_buffer_size! : Socket, U64 => Try({}, [UdpErr(IOErr)])
		set_send_buffer_size! = |Socket.(handle), bytes| udp_err(Host.socket_set_buffer_size!(handle, 1, bytes))

		recv_buffer_size! : Socket => Try(U64, [UdpErr(IOErr)])
		recv_buffer_size! = |Socket.(handle)| udp_err(Host.socket_buffer_size!(handle, 0))

		send_buffer_size! : Socket => Try(U64, [UdpErr(IOErr)])
		send_buffer_size! = |Socket.(handle)| udp_err(Host.socket_buffer_size!(handle, 1))
	}

	## How `bind_with!` binds. Start from `bind_config` and adjust.
	BindConfig :: { reuse : Bool }.{

		## Let several sockets bind the same address and port (`SO_REUSEADDR`
		## and `SO_REUSEPORT`), each binding with this set: for several
		## programs receiving one multicast group (as mDNS responders do), or
		## to spread datagrams to one port over several sockets.
		with_reuse_port : BindConfig, Bool -> BindConfig
		with_reuse_port = |BindConfig.(config), reuse| BindConfig.({ ..config, reuse })
	}

	## No address reuse.
	bind_config : BindConfig
	bind_config = BindConfig.({ reuse: False })

	## Bind a socket to `address`, such as `"0.0.0.0:5353"`. Use port 0 to let
	## the OS choose a free port, which suits a client.
	bind! : Str => Try(Socket, [UdpErr(IOErr)])
	bind! = |address| bind_with!(address, bind_config)

	## Bind with the options in `config`.
	bind_with! : Str, BindConfig => Try(Socket, [UdpErr(IOErr)])
	bind_with! = |address, BindConfig.(config)|
		match Host.udp_bind!(address, config.reuse) {
			Ok(socket) => Ok(Socket.(socket))
			Err(err) => Err(UdpErr(err))
		}

	udp_err : Try(ok, IOErr) -> Try(ok, [UdpErr(IOErr)])
	udp_err = |result|
		match result {
			Ok(value) => Ok(value)
			Err(err) => Err(UdpErr(err))
		}

	timeout_ms : [NoTimeout, Millis(U64)] -> U64
	timeout_ms = |timeout|
		match timeout {
			NoTimeout => 0
			# 0 would mean "no timeout" to the host, so round up.
			Millis(ms) => if ms == 0 1 else ms
		}
}
