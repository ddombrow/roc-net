## roc-net is a platform for network programs: custom protocols, servers,
## clients, and proxies.
##
## An app provides `main!`, which receives the command-line arguments. Write
## network code as ordinary sequential steps (connect, read, write) and use
## `Task.spawn!` to handle many connections at once. Sockets close
## automatically once nothing refers to them.
##
## ```roc
## app [main!] { pf: platform "../../platform/main.roc" }
##
## import pf.Task
## import pf.Tcp
##
## main! : List(Str) => Try({}, _)
## main! = |_args| {
## 	listener = Tcp.listen!("127.0.0.1:8080")?
## 	while True {
## 		stream = listener.accept!()?
## 		Task.spawn!(|| echo!(stream))?
## 	}
## 	Ok({})
## }
##
## echo! = |stream| {
## 	while True {
## 		bytes = stream.read!(4096)?
## 		if List.is_empty(bytes) {
## 			break
## 		}
## 		stream.write!(bytes)?
## 	}
## 	Ok({})
## }
## ```
##
## Start with `Tcp` and `Task`. The `examples/` directory has complete programs.
platform ""
	requires {
		main! : List(Str) => Try({}, [Exit(I32), ..])
	}
	exposes [Bytes, Dns, Framing, IOErr, Random, Stdout, Stderr, Stdin, Task, Tcp, Time, Udp, Unix]
	packages { roc: "nightly-2026-09-24-f45bfbe" }
	provides { "roc_main": main_for_host!, "roc_run_task": run_task_for_host! }
	hosted {
		"roc_stderr_line": Host.stderr_line!,
		"roc_stdin_line": Host.stdin_line!,
		"roc_stdout_line": Host.stdout_line!,
		"roc_task_spawn": Host.task_spawn!,
		"roc_dns_resolve": Host.dns_resolve!,
		"roc_random_bytes": Host.random_bytes!,
		"roc_time_now_ns": Host.time_now_ns!,
		"roc_time_sleep_ns": Host.time_sleep_ns!,
		"roc_socket_accept": Host.socket_accept!,
		"roc_socket_local_addr": Host.socket_local_addr!,
		"roc_socket_peer_addr": Host.socket_peer_addr!,
		"roc_socket_read": Host.socket_read!,
		"roc_socket_set_timeout": Host.socket_set_timeout!,
		"roc_socket_shutdown": Host.socket_shutdown!,
		"roc_socket_write": Host.socket_write!,
		"roc_tcp_connect": Host.tcp_connect!,
		"roc_tcp_listen": Host.tcp_listen!,
		"roc_tcp_set_nodelay": Host.tcp_set_nodelay!,
		"roc_udp_bind": Host.udp_bind!,
		"roc_udp_connect": Host.udp_connect!,
		"roc_udp_join_multicast": Host.udp_join_multicast!,
		"roc_udp_leave_multicast": Host.udp_leave_multicast!,
		"roc_udp_recv_from": Host.udp_recv_from!,
		"roc_udp_send_to": Host.udp_send_to!,
		"roc_udp_set_broadcast": Host.udp_set_broadcast!,
		"roc_unix_connect": Host.unix_connect!,
		"roc_unix_listen": Host.unix_listen!,
	}
	targets: {
		inputs_dir: "targets/",
		x64mac: { inputs: ["libhost.a", app] },
		arm64mac: { inputs: ["libhost.a", app] },
		x64musl: { inputs: ["crt1.o", "libhost.a", "libunwind.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
		arm64musl: { inputs: ["crt1.o", "libhost.a", "libunwind.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Stdout
import Stderr
import Stdin
import Task
import Bytes
import Dns
import Framing
import Tcp
import Time
import Udp
import Unix
import Host
import IOErr
import Random

main_for_host! : List(Str) => I32
main_for_host! = |args| {
	# Compiler workaround (nightly-2026-09-24): if an app never calls
	# Task.spawn!, `run_task_for_host!` calls a closure of no known type, the
	# LLVM backend emits a call to `roc_boxy_init_embedded`, and the linker
	# doesn't include the runtime that defines it ("undefined symbol").
	# Mentioning one concrete task closure avoids that. `args` always holds the
	# program name, so this never runs.
	if List.is_empty(args) {
		_ = Host.task_spawn!(Box.box(|| {}))
	}
	result = main!(args)
	match result {
		Ok({}) => 0
		Err(Exit(code)) => code
		Err(other) => {
			_ = Stderr.line!("ERROR: ${Str.inspect(other)}")
			-1
		}
	}
}

run_task_for_host! : Box(() => {}) => {}
run_task_for_host! = |boxed| {
	run! = Box.unbox(boxed)
	run!()
}
