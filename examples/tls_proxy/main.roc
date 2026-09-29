app [main!] { roc: "nightly-2026-09-24-f45bfbe", pf: platform "../../platform/main.roc" }

import pf.Select
import pf.Stderr
import pf.Stdout
import pf.Stream
import pf.Task
import pf.Tcp
import pf.Tls

# Demonstrates: terminating TLS and routing by the host name the client asks
# for (SNI), `Stream.copy_both!`, and plain and TLS listeners served by the
# same code.
#
# Usage: tls_proxy PLAIN_ADDRESS TLS_ADDRESS CERT_FILE KEY_FILE BACKEND [NAME=BACKEND ...]
#
# Plain connections, and TLS clients asking for a name with no route, go to
# BACKEND. With the test certificates, which are for "localhost":
#
#   just run tls_proxy 127.0.0.1:9080 127.0.0.1:9443 \
#       examples/net_tests/certs/server.pem examples/net_tests/certs/server-key.pem \
#       127.0.0.1:8080 localhost=127.0.0.1:8081

usage = "Usage: tls_proxy PLAIN_ADDRESS TLS_ADDRESS CERT_FILE KEY_FILE BACKEND [NAME=BACKEND ...]"

Listener : [Plain(Tcp.Listener), Secure(Tls.Listener)]

Route : { name : Str, backend : Str }

main! : List(Str) => Try({}, _)
main! = |args| {
	(plain_address, tls_address, cert_file, key_file, default_backend, route_args) =
		match args {
			[_, plain, secure, cert, key, backend, .. as rest] => (plain, secure, cert, key, backend, rest)
			_ => {
				_ = Stderr.line!(usage)
				return Err(Exit(2))
			}
		}
	routes = parse_routes(route_args)?

	plain = Tcp.listen!(plain_address)?
	secure = Tls.listen!(tls_address, Tls.server_config({ cert_file, key_file }))?
	listeners : List(Listener)
	listeners = [Plain(plain), Secure(secure)]
	Stdout.line!("Proxying ${plain_address} (plain) and ${tls_address} (TLS) -> ${default_backend}")?

	# An accept loop per listener. They only end on an error (such as running
	# out of file descriptors), so when either ends, stop: returning an error
	# from the scope's body cancels the other.
	Task.scope!(|scope| {
		var $first = Select.new({})
		for listener in listeners {
			task = scope.spawn!(|| serve!(listener, routes, default_backend))?
			$first = $first.on_join(task, |result| result)
		}
		match $first.wait!()? {
			Ok({}) => Err(ListenerStopped)
			Err(err) => Err(err)
		}
	})
}

## Accept connections forever, proxying each on its own task.
serve! : Listener, List(Route), Str => Try({}, _)
serve! = |listener, routes, default_backend|
	match listener {
		Plain(l) => accept_loop!(l, |_client| Ok(default_backend))
		Secure(l) =>
			accept_loop!(l, |client| {
				# Finish the handshake first, so a client that fails it is
				# dropped before a backend connection is made, and so the name
				# it asked for is known.
				client.handshake!()?
				# Most TLS clients close without close_notify, and the backend
				# only sees a plain close either way.
				client.ignore_unexpected_eof!(True)?
				# Clients connecting by IP address send no name.
				match client.server_name!()? {
					Name(name) => Ok(backend_for(routes, name, default_backend))
					NoName => Ok(default_backend)
				}
			})
	}

## Accept connections on any kind of listener; `route!` picks each one's
## backend.
accept_loop! = |listener, route!| {
	while True {
		client = listener.accept!()?
		# At the task limit this fails and drops the connection; the proxy keeps going.
		_ = Task.spawn!(|| {
			proxy!(client, route!)
			Ok({})
		})
	}
	Ok({})
}

## Copy between `client` and its backend until both are done, and log how
## it went.
proxy! = |client, route!| {
	peer = client.peer_addr!() ?? "unknown peer"
	match route!(client) {
		Err(err) => {
			_ = Stderr.line!("${peer}: ${Str.inspect(err)}")
		}
		Ok(backend_address) =>
			match Tcp.connect!(backend_address) {
				Err(err) => {
					_ = Stderr.line!("${peer} -> ${backend_address}: ${Str.inspect(err)}")
				}
				Ok(backend) =>
					match Stream.copy_both!(client, backend) {
						Ok(copied) => {
							_ = Stdout.line!("${peer} -> ${backend_address}: ${copied.a_to_b.to_str()} bytes up, ${copied.b_to_a.to_str()} down")
						}
						# On an error, `copy_both!` has aborted both streams, so the
						# client can't mistake a cut-off response for a complete one.
						Err(CopyErr({ failed, a_to_b, b_to_a })) => {
							_ = Stderr.line!("${peer} -> ${backend_address}: ${Str.inspect(failed)} after ${a_to_b.to_str()} bytes up, ${b_to_a.to_str()} down")
						}
						Err(err) => {
							_ = Stderr.line!("${peer} -> ${backend_address}: ${Str.inspect(err)}")
						}
					}
			}
	}
}

backend_for : List(Route), Str, Str -> Str
backend_for = |routes, name, default_backend| {
	var $backend = default_backend
	for route in routes {
		if route.name == name {
			$backend = route.backend
		}
	}
	$backend
}

parse_routes : List(Str) -> Try(List(Route), [Exit(I32)])
parse_routes = |route_args| {
	var $routes = []
	for arg in route_args {
		match Str.split_on(arg, "=") {
			[name, backend] => {
				$routes = List.append($routes, { name, backend })
			}
			_ => return Err(Exit(2))
		}
	}
	Ok($routes)
}
