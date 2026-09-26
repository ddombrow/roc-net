import Host
import IOErr

## UDP sockets: send and receive individual datagrams.
##
## Datagrams may be lost, duplicated, or arrive out of order, and each is
## delivered whole or not at all. Use `set_read_timeout!` when waiting for a
## reply, since a lost packet otherwise means waiting forever.
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
		## address. A datagram longer than `max` bytes is cut short.
		recv_from! : Socket, U64 => Try({ bytes : List(U8), from : Str }, [UdpErr(IOErr)])
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
		## than `max` bytes is cut short.
		recv! : Socket, U64 => Try(List(U8), [UdpErr(IOErr)])
		recv! = |Socket.(socket), max| udp_err(Host.socket_read!(socket, max))

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
	}

	## Bind a socket to `address`, such as `"0.0.0.0:5353"`. Use port 0 to let
	## the OS choose a free port, which suits a client.
	bind! : Str => Try(Socket, [UdpErr(IOErr)])
	bind! = |address|
		match Host.udp_bind!(address) {
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
