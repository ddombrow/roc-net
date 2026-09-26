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
##
## Sockets close automatically once nothing refers to them. Every operation
## fails with `TlsErr(IOErr)`.
Tls := [].{

	## A TCP listener whose connections speak TLS.
	Listener :: Host.Socket.{

		## Block until a client connects. The TLS handshake happens on the
		## stream's first read or write, in whichever task uses it, so a slow
		## client can't hold up the accept loop.
		accept! : Listener => Try(Stream, [TlsErr(IOErr)])
		accept! = |Listener.(listener)|
			match Host.socket_accept!(listener) {
				Ok(stream) => Ok(Stream.(stream))
				Err(err) => Err(TlsErr(err))
			}

		## The address this listener is bound to.
		local_addr! : Listener => Try(Str, [TlsErr(IOErr)])
		local_addr! = |Listener.(listener)| tls_err(Host.socket_local_addr!(listener))
	}

	## An encrypted stream.
	Stream :: Host.Socket.{

		## Read up to `max` decrypted bytes. Returns an empty list once the
		## peer has ended the session properly; fails with `UnexpectedEof` if
		## the connection just dropped, since that could mean the data was cut
		## short by an attacker.
		read! : Stream, U64 => Try(List(U8), [TlsErr(IOErr)])
		read! = |Stream.(stream), max| tls_err(Host.socket_read!(stream, max))

		## Encrypt and send all of `bytes`.
		write! : Stream, List(U8) => Try({}, [TlsErr(IOErr)])
		write! = |Stream.(stream), bytes| tls_err(Host.socket_write!(stream, bytes))

		## Encrypt and send `text` as UTF-8.
		write_str! : Stream, Str => Try({}, [TlsErr(IOErr)])
		write_str! = |stream, text| stream.write!(Str.to_utf8(text))

		## Shut down one or both directions. Shutting down `Write` (or `Both`)
		## first tells the peer the session is ending on purpose.
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

		## End the session and close the connection now.
		close! : Stream => {}
		close! = |Stream.(stream)| {
			_ = Host.socket_shutdown!(stream, 2)
			{}
		}

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
	ClientConfig :: { ca_file : Str, server_name : Str, timeout_ms : U64 }.{

		## Trust only the CA certificate(s) in this PEM file instead of
		## Mozilla's roots: for servers with certificates from your own CA.
		with_ca_file : ClientConfig, Str -> ClientConfig
		with_ca_file = |ClientConfig.(config), path| ClientConfig.({ ..config, ca_file: path })

		## Check the certificate against this name instead of the address's
		## host, e.g. when connecting by IP address. Also sent to the server
		## so it can pick the right certificate (SNI).
		with_server_name : ClientConfig, Str -> ClientConfig
		with_server_name = |ClientConfig.(config), name| ClientConfig.({ ..config, server_name: name })

		## Give up if connecting and the handshake take longer than this.
		with_timeout : ClientConfig, [Millis(U64)] -> ClientConfig
		with_timeout = |ClientConfig.(config), Millis(ms)| ClientConfig.({ ..config, timeout_ms: ms })
	}

	## Mozilla's root certificates, the address's host as the server name, and
	## a 30-second timeout.
	client_config : ClientConfig
	client_config = ClientConfig.({ ca_file: "", server_name: "", timeout_ms: 30000 })

	## Connect to `address`, such as `"example.com:443"`, with `client_config`.
	connect! : Str => Try(Stream, [TlsErr(IOErr)])
	connect! = |address| connect_with!(address, client_config)

	## Connect to `address` using `config`.
	connect_with! : Str, ClientConfig => Try(Stream, [TlsErr(IOErr)])
	connect_with! = |address, ClientConfig.(config)|
		match Host.tls_connect!(address, config.server_name, config.ca_file, config.timeout_ms) {
			Ok(stream) => Ok(Stream.(stream))
			Err(err) => Err(TlsErr(err))
		}

	## The certificate chain and private key a server presents, as PEM files.
	ServerConfig : { cert_file : Str, key_file : Str }

	## Listen for TLS connections on `address`.
	listen! : Str, ServerConfig => Try(Listener, [TlsErr(IOErr)])
	listen! = |address, config|
		match Host.tls_listen!(address, config.cert_file, config.key_file) {
			Ok(listener) => Ok(Listener.(listener))
			Err(err) => Err(TlsErr(err))
		}

	## Switch a plain TCP connection to TLS as the client, as protocols with a
	## STARTTLS command (SMTP, IMAP, ...) do partway through. Uses `config`'s
	## server name, which is required here since there's no address to take
	## it from. Don't use `stream` afterwards: raw bytes in the middle of the
	## TLS session would break it.
	wrap_client! : Tcp.Stream, ClientConfig => Try(Stream, [TlsErr(IOErr)])
	wrap_client! = |stream, ClientConfig.(config)|
		match Host.tls_wrap_client!(Tcp.to_socket(stream), config.server_name, config.ca_file) {
			Ok(tls) => Ok(Stream.(tls))
			Err(err) => Err(TlsErr(err))
		}

	## Switch a plain TCP connection to TLS as the server; see `wrap_client!`.
	wrap_server! : Tcp.Stream, ServerConfig => Try(Stream, [TlsErr(IOErr)])
	wrap_server! = |stream, config|
		match Host.tls_wrap_server!(Tcp.to_socket(stream), config.cert_file, config.key_file) {
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
