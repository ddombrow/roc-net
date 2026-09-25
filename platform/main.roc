platform ""
	requires {
		main! : List(Str) => Try({}, [Exit(I32), ..])
	}
	exposes [Stdout, Stderr, Stdin, Task, Tcp]
	packages { roc: "nightly-2026-09-24-f45bfbe" }
	provides { "roc_main": main_for_host!, "roc_run_task": run_task_for_host! }
	hosted {
		"roc_stderr_line": Host.stderr_line!,
		"roc_stdin_line": Host.stdin_line!,
		"roc_stdout_line": Host.stdout_line!,
		"roc_task_spawn": Host.task_spawn!,
		"roc_tcp_accept": Host.tcp_accept!,
		"roc_tcp_close": Host.tcp_close!,
		"roc_tcp_connect": Host.tcp_connect!,
		"roc_tcp_listen": Host.tcp_listen!,
		"roc_tcp_read": Host.tcp_read!,
		"roc_tcp_write": Host.tcp_write!,
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
import Tcp
import Host

main_for_host! : List(Str) => I32
main_for_host! = |args| {
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
