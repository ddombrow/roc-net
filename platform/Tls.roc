import Host
import IOErr
import Tcp

## TLS (encrypted, authenticated) streams over TCP.
##
## ```roc
## stream = Tls.connect!("example.com:443")?
## stream.write_str!("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")?
## ```
##
## `Tls.Stream` has the same methods as `Tcp.Stream`, so code written against
## those methods (like `Framing`) works with either. One task can read while
## another writes, as with plain streams.
##
## Clients check the server's certificate against Mozilla's root
## certificates (or a CA file you choose) and its name against the address.
## Certificate and protocol failures come back as `TlsErr(Other(message))`,
## with rustls's description, such as `"invalid peer certificate: UnknownIssuer"`.
## So do certificate and key files that can't be used, with the path and the
## reason, such as `"server.pem: No such file or directory (os error 2)"`.
##
## Sockets close automatically once nothing refers to them. Every operation
## fails with `TlsErr(IOErr)`.
Tls := [].{

	## A TCP listener whose connections speak TLS.
	Listener :: Host.Socket.{

		## Block until a client connects. The TLS handshake happens on the
		## stream's first read or write (or `handshake!`), in whichever task
		## uses it, so a slow client can't hold up the accept loop.
		accept! : Listener => Try(Stream, [TlsErr(IOErr)])
		accept! = |Listener.(listener)|
			match Host.socket_accept!(listener) {
				Ok(stream) => Ok(Stream.(stream))
				Err(err) => Err(TlsErr(err))
			}

		## For `Select`: a waiting connection, without waiting for one
		## (`Ok(NotReady)` if there's none yet).
		try_accept! : Listener => Try([Accepted(Stream), NotReady], [TlsErr(IOErr)])
		try_accept! = |Listener.(listener)|
			match Host.socket_try_accept!(listener) {
				Accepted(stream) => Ok(Accepted(Stream.(stream)))
				NotReady => Ok(NotReady)
				Failed(err) => Err(TlsErr(err))
			}

		## The host socket, for `Select` to wait on.
		socket : Listener -> Host.Socket
		socket = |Listener.(listener)| listener

		## The address this listener is bound to.
		local_addr! : Listener => Try(Str, [TlsErr(IOErr)])
		local_addr! = |Listener.(listener)| tls_err(Host.socket_local_addr!(listener))
	}

	## An encrypted stream.
	Stream :: Host.Socket.{

		## Complete the TLS handshake now, if it hasn't happened yet. A stream
		## from `Listener.accept!` or `wrap_server!` otherwise does it on its
		## first read or write; streams from `connect!` and `wrap_client!` have
		## already done it, so this returns at once.
		##
		## Call it before sharing a stream between tasks (a proxy copying in
		## both directions, say), so a failed handshake (a bad client, the
		## handshake timeout) is reported here rather than by whichever task
		## happened to go first:
		##
		## ```roc
		## client = listener.accept!()?
		## client.handshake!()?
		## ```
		handshake! : Stream => Try({}, [TlsErr(IOErr)])
		handshake! = |Stream.(stream)| tls_err(Host.tls_handshake!(stream))

		## On a server stream, the name the client asked for (SNI), such as
		## `Name("api.example.com")`, for routing by host name. It's
		## lower-cased and has no trailing dot, as when choosing a certificate
		## (`with_cert_for`). `NoName` if the client sent none (clients
		## connecting by IP address don't), and on a client stream. Completes
		## the handshake first, like `handshake!`.
		server_name! : Stream => Try([Name(Str), NoName], [TlsErr(IOErr)])
		server_name! = |Stream.(stream)|
			match Host.tls_server_name!(stream) {
				Ok("") => Ok(NoName)
				Ok(name) => Ok(Name(name))
				Err(err) => Err(TlsErr(err))
			}

		## The application protocol agreed with ALPN (see
		## `ServerConfig.with_alpn` and `ClientConfig.with_alpn`), such as
		## `"h2"`, or `""` if none was. Completes the handshake first, like
		## `handshake!`.
		alpn_protocol! : Stream => Try(Str, [TlsErr(IOErr)])
		alpn_protocol! = |Stream.(stream)| tls_err(Host.tls_alpn_protocol!(stream))

		## Read up to `max` decrypted bytes. Returns an empty list once the
		## peer has ended the session properly; fails with `UnexpectedEof` if
		## the connection just dropped, since that could mean the data was cut
		## short by an attacker.
		read! : Stream, U64 => Try(List(U8), [TlsErr(IOErr)])
		read! = |Stream.(stream), max| tls_err(Host.socket_read!(stream, max))

		## Like `read!`, but reuse `buffer`'s memory for the result: its old
		## contents are replaced by the (up to `max`) bytes that arrived, and an
		## empty result means the peer closed the stream. In a loop, pass back
		## what it returned, and there's no new allocation per read:
		##
		## ```roc
		## var $buf = List.with_capacity(4096)
		## while True {
		## 	$buf = stream.read_into!($buf, 4096)?
		## 	if List.is_empty($buf) {
		## 		break
		## 	}
		## 	stream.write!($buf)?
		## }
		## ```
		##
		## The memory is reused only while nothing else refers to `buffer`; if
		## something does (say, you kept an earlier result), you get a new list
		## instead and the old one is left as it was. Either way it's correct;
		## reuse only makes it faster.
		read_into! : Stream, List(U8), U64 => Try(List(U8), [TlsErr(IOErr)])
		read_into! = |Stream.(stream), buffer, max| tls_err(Host.socket_read_into!(stream, buffer, max))

		## Like `read_into!`, but add the bytes that arrived to the end of
		## `buffer` instead of replacing its contents. If the length didn't
		## change, the peer closed the stream. `Framing` reads this way.
		read_append! : Stream, List(U8), U64 => Try(List(U8), [TlsErr(IOErr)])
		read_append! = |Stream.(stream), buffer, max| tls_err(Host.socket_read_append!(stream, buffer, max))

		## Encrypt and send all of `bytes`.
		write! : Stream, List(U8) => Try({}, [TlsErr(IOErr)])
		write! = |Stream.(stream), bytes| tls_err(Host.socket_write!(stream, bytes))

		## Encrypt and send `text` as UTF-8.
		write_str! : Stream, Str => Try({}, [TlsErr(IOErr)])
		write_str! = |stream, text| stream.write!(Str.to_utf8(text))

		## Shut down one or both directions. Shutting down `Write` (or `Both`)
		## first tells the peer the session is ending on purpose. Succeeds if
		## the peer has already closed the connection.
		shutdown! : Stream, [Read, Write, Both] => Try({}, [TlsErr(IOErr)])
		shutdown! = |Stream.(stream), how| {
			code =
				match how {
					Read => 0
					Write => 1
					Both => 2
				}
			tls_err(Host.socket_shutdown!(stream, code))
		}

		## For `Select`: what has arrived, without waiting (`Ok(NotReady)` if
		## nothing has yet).
		try_read! : Stream, U64 => Try([Data(List(U8)), NotReady], [TlsErr(IOErr)])
		try_read! = |Stream.(stream), max|
			match Host.socket_try_read!(stream, max) {
				Data(bytes) => Ok(Data(bytes))
				NotReady => Ok(NotReady)
				Failed(err) => Err(TlsErr(err))
			}

		## The host socket, for `Select` to wait on.
		socket : Stream -> Host.Socket
		socket = |Stream.(stream)| stream

		## What a read reports when the stream's read timeout passes, for
		## `Select` to report it the same way.
		timeout_error : Stream -> [TlsErr(IOErr)]
		timeout_error = |_| TlsErr(TimedOut)

		## End the session and close the connection now. The peer sees a
		## deliberate end (close_notify), which says it got everything sent;
		## to give up partway through instead, use `abort!`.
		close! : Stream => {}
		close! = |Stream.(stream)| {
			_ = Host.socket_shutdown!(stream, 2)
			{}
		}

		## Give up on the connection partway through: end it with a reset, so
		## the peer sees an error rather than a clean end of stream. No
		## close_notify is sent, then or when the stream is released. Use it
		## on error paths, where a clean end (`close!`) would pass off
		## whatever the peer received as complete, such as a proxy whose
		## backend failed mid-response. Later reads and writes fail, and tasks
		## waiting on the stream wake.
		abort! : Stream => {}
		abort! = |Stream.(stream)| Host.socket_abort!(stream)

		## Make reads fail with `TimedOut` if no data arrives in time.
		set_read_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [TlsErr(IOErr)])
		set_read_timeout! = |Stream.(stream), timeout| tls_err(Host.socket_set_timeout!(stream, 0, timeout_ms(timeout)))

		## Make writes fail with `TimedOut` if the peer stops accepting data.
		set_write_timeout! : Stream, [NoTimeout, Millis(U64)] => Try({}, [TlsErr(IOErr)])
		set_write_timeout! = |Stream.(stream), timeout| tls_err(Host.socket_set_timeout!(stream, 1, timeout_ms(timeout)))

		## Treat a connection that closes without ending the TLS session
		## (no close_notify) as a normal end of stream instead of failing with
		## `UnexpectedEof`.
		##
		## Many servers close this way. Without the proper ending, a reader
		## can't tell complete data from data an attacker cut short, so only
		## turn this on when the protocol itself marks where the data ends,
		## such as an HTTP response with `Content-Length`, or when a
		## truncated result is acceptable.
		##
		## A proxy that terminates TLS and forwards plain TCP can usually turn
		## it on for its client side: many TLS clients close without
		## close_notify, and the backend only sees a plain close either way,
		## so failing wouldn't tell it anything more.
		ignore_unexpected_eof! : Stream, Bool => Try({}, [TlsErr(IOErr)])
		ignore_unexpected_eof! = |Stream.(stream), ignore| tls_err(Host.tls_ignore_unexpected_eof!(stream, ignore))

		## Send small writes immediately; see `Tcp.Stream.set_nodelay!`.
		set_nodelay! : Stream, Bool => Try({}, [TlsErr(IOErr)])
		set_nodelay! = |Stream.(stream), enabled| tls_err(Host.tcp_set_nodelay!(stream, enabled))

		local_addr! : Stream => Try(Str, [TlsErr(IOErr)])
		local_addr! = |Stream.(stream)| tls_err(Host.socket_local_addr!(stream))

		peer_addr! : Stream => Try(Str, [TlsErr(IOErr)])
		peer_addr! = |Stream.(stream)| tls_err(Host.socket_peer_addr!(stream))
	}

	## How a client checks the server. Start from `client_config` and adjust:
	##
	## ```roc
	## config = Tls.client_config.with_ca_file("certs/dev-ca.pem")
	## stream = Tls.connect_with!("127.0.0.1:8443", config.with_server_name("localhost"))?
	## ```
	ClientConfig :: { ca_file : Str, server_name : Str, alpn : List(Str), timeout_ms : U64 }.{

		## Trust only the CA certificate(s) in this PEM file instead of
		## Mozilla's roots: for servers with certificates from your own CA.
		with_ca_file : ClientConfig, Str -> ClientConfig
		with_ca_file = |ClientConfig.(config), path| ClientConfig.({ ..config, ca_file: path })

		## Check the certificate against this name instead of the address's
		## host, e.g. when connecting by IP address. Also sent to the server
		## so it can pick the right certificate (SNI).
		with_server_name : ClientConfig, Str -> ClientConfig
		with_server_name = |ClientConfig.(config), name| ClientConfig.({ ..config, server_name: name })

		## Offer these application protocols (ALPN), most preferred first,
		## such as `["h2", "http/1.1"]`. After connecting, the stream's
		## `alpn_protocol!` says which one the server picked ("" if it didn't
		## take part).
		with_alpn : ClientConfig, List(Str) -> ClientConfig
		with_alpn = |ClientConfig.(config), protocols| ClientConfig.({ ..config, alpn: protocols })

		## Give up with `TimedOut` if looking up the name, connecting, and the
		## handshake together (or, for `wrap_client!`, the handshake) take
		## longer than this; see `Tcp.connect_timeout!`. It bounds
		## the whole handshake, so a peer that trickles bytes to keep each read
		## alive still times out.
		with_timeout : ClientConfig, [Millis(U64)] -> ClientConfig
		with_timeout = |ClientConfig.(config), Millis(ms)| ClientConfig.({ ..config, timeout_ms: ms })
	}

	## Mozilla's root certificates, the address's host as the server name, no
	## ALPN, and a 30-second timeout.
	client_config : ClientConfig
	client_config = ClientConfig.({ ca_file: "", server_name: "", alpn: [], timeout_ms: 30000 })

	## Connect to `address`, such as `"example.com:443"`, with `client_config`.
	connect! : Str => Try(Stream, [TlsErr(IOErr)])
	connect! = |address| connect_with!(address, client_config)

	## Connect to `address` using `config`.
	connect_with! : Str, ClientConfig => Try(Stream, [TlsErr(IOErr)])
	connect_with! = |address, ClientConfig.(config)|
		match Host.tls_connect!(address, config.server_name, config.ca_file, config.alpn, config.timeout_ms) {
			Ok(stream) => Ok(Stream.(stream))
			Err(err) => Err(TlsErr(err))
		}

	## What a server presents and how long clients get to set up a session.
	## Start from `server_config` and adjust:
	##
	## ```roc
	## config = Tls.server_config({ cert_file: "server.pem", key_file: "server-key.pem" })
	## listener = Tls.listen!("0.0.0.0:8443", config.with_handshake_timeout(Millis(3000)))?
	## ```
	##
	## To serve several host names from one listener, give each its own
	## certificate with `with_cert_for`; the one from `server_config` is for
	## every other name:
	##
	## ```roc
	## config =
	## 	Tls.server_config({ cert_file: "default.pem", key_file: "default-key.pem" })
	## 		.with_cert_for("api.example.com", { cert_file: "api.pem", key_file: "api-key.pem" })
	## 		.with_cert_for("*.example.com", { cert_file: "wild.pem", key_file: "wild-key.pem" })
	## ```
	ServerConfig :: { certs : List(Host.TlsCert), alpn : List(Str), handshake_timeout_ms : U64, idle_ms : U64, write_ms : U64 }.{

		## Present this certificate chain and private key to clients that ask
		## for `name` (SNI), such as `"api.example.com"`. A name starting with
		## `*.` covers one more label: `"*.example.com"` covers
		## `"api.example.com"`, but not `"example.com"` or
		## `"a.b.example.com"`. An exact name wins over a wildcard, and a later
		## certificate for the same name replaces an earlier one.
		##
		## Clients that ask for no name (such as ones connecting by IP address)
		## or a name with no certificate here get the one from
		## `server_config`. The stream's `server_name!` tells the server which
		## name the client asked for.
		with_cert_for : ServerConfig, Str, { cert_file : Str, key_file : Str } -> ServerConfig
		with_cert_for = |ServerConfig.(config), name, files|
			ServerConfig.({ ..config, certs: List.append(config.certs, { name, cert_file: files.cert_file, key_file: files.key_file }) })

		## Accept these application protocols (ALPN), most preferred first,
		## such as `["h2", "http/1.1"]`. A client that offers some protocols but
		## none of these fails the handshake (as the ALPN standard requires); a
		## client that offers none is served without one. The stream's
		## `alpn_protocol!` says which one was agreed.
		with_alpn : ServerConfig, List(Str) -> ServerConfig
		with_alpn = |ServerConfig.(config), protocols| ServerConfig.({ ..config, alpn: protocols })

		## After the handshake, how long a read waits for data before failing
		## with `TimedOut`; see `Tcp.ListenConfig.with_idle_timeout`.
		with_idle_timeout : ServerConfig, [NoTimeout, Millis(U64)] -> ServerConfig
		with_idle_timeout = |ServerConfig.(config), timeout| ServerConfig.({ ..config, idle_ms: timeout_ms(timeout) })

		## How long a write can wait for a client that has stopped reading; see
		## `Tcp.ListenConfig.with_write_timeout`.
		with_write_timeout : ServerConfig, [NoTimeout, Millis(U64)] -> ServerConfig
		with_write_timeout = |ServerConfig.(config), timeout| ServerConfig.({ ..config, write_ms: timeout_ms(timeout) })


		## How long each client has, from when its connection is accepted, to
		## complete the TLS handshake; `NoTimeout` means no limit. Past it, the
		## stream's first read or write fails with `TimedOut`.
		##
		## This is a deadline for the whole handshake, so a client that sends a
		## byte at a time to keep each read alive (a slowloris attack) can't
		## hold the connection and its task open. It covers only the handshake:
		## to bound idle clients after it, use the stream's
		## `set_read_timeout!`.
		with_handshake_timeout : ServerConfig, [NoTimeout, Millis(U64)] -> ServerConfig
		with_handshake_timeout = |ServerConfig.(config), timeout| {
			ms =
				match timeout {
					NoTimeout => 0
					# 0 would mean "no timeout" to the host, so round up.
					Millis(n) => if n == 0 1 else n
				}
			ServerConfig.({ ..config, handshake_timeout_ms: ms })
		}
	}

	## A server presenting the certificate chain and private key in these PEM
	## files (to every client, unless `with_cert_for` adds others). Clients
	## get 10 seconds to complete the handshake, then 60-second idle and write
	## timeouts, as with `Tcp.listen!`. The files are read when listening
	## starts (or at `wrap_server!`).
	server_config : { cert_file : Str, key_file : Str } -> ServerConfig
	server_config = |files|
		ServerConfig.({
			certs: [{ name: "", cert_file: files.cert_file, key_file: files.key_file }],
			alpn: [],
			handshake_timeout_ms: 10000,
			idle_ms: 60000,
			write_ms: 60000,
		})

	## Listen for TLS connections on `address`.
	listen! : Str, ServerConfig => Try(Listener, [TlsErr(IOErr)])
	listen! = |address, ServerConfig.(config)|
		match Host.tls_listen!(address, config.certs, config.alpn, config.handshake_timeout_ms, config.idle_ms, config.write_ms) {
			Ok(listener) => Ok(Listener.(listener))
			Err(err) => Err(TlsErr(err))
		}

	## Switch a plain TCP connection to TLS as the client, as protocols with a
	## STARTTLS command (SMTP, IMAP, ...) do partway through. Uses `config`'s
	## server name, which is required here since there's no address to take
	## it from. The handshake is bounded by `config`'s timeout (30 seconds
	## unless changed with `with_timeout`). Read and write timeouts set on
	## `stream` carry over to the TLS stream. Don't use `stream` afterwards:
	## raw bytes in the middle of the TLS session would break it.
	wrap_client! : Tcp.Stream, ClientConfig => Try(Stream, [TlsErr(IOErr)])
	wrap_client! = |stream, ClientConfig.(config)|
		match Host.tls_wrap_client!(Tcp.to_socket(stream), config.server_name, config.ca_file, config.alpn, config.timeout_ms) {
			Ok(tls) => Ok(Stream.(tls))
			Err(err) => Err(TlsErr(err))
		}

	## Switch a plain TCP connection to TLS as the server; see `wrap_client!`.
	## The handshake timeout counts from this call.
	wrap_server! : Tcp.Stream, ServerConfig => Try(Stream, [TlsErr(IOErr)])
	wrap_server! = |stream, ServerConfig.(config)|
		match Host.tls_wrap_server!(Tcp.to_socket(stream), config.certs, config.alpn, config.handshake_timeout_ms) {
			Ok(tls) => Ok(Stream.(tls))
			Err(err) => Err(TlsErr(err))
		}

	tls_err : Try(ok, IOErr) -> Try(ok, [TlsErr(IOErr)])
	tls_err = |result|
		match result {
			Ok(value) => Ok(value)
			Err(err) => Err(TlsErr(err))
		}

	timeout_ms : [NoTimeout, Millis(U64)] -> U64
	timeout_ms = |timeout|
		match timeout {
			NoTimeout => 0
			# 0 would mean "no timeout" to the host, so round up.
			Millis(ms) => if ms == 0 1 else ms
		}
}
