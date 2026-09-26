import Host
import Stderr

## Concurrent tasks.
##
## Each task runs a closure to completion, possibly in parallel with other
## tasks and with `main!`. When `main!` returns, the program exits and any
## tasks still running are stopped.
Task := [].{

	## Run `task!` concurrently. If it returns an error, the error is printed to
	## stderr and only that task ends.
	##
	## Returns `Err(TaskLimitReached)` without running `task!` when too many
	## tasks are already running: `ROC_NET_MAX_TASKS` (default 10,000), or fewer
	## if the OS won't start more threads. Anything `task!` captured is released,
	## so a connection it captured is closed. In a server's accept loop, ignore
	## the error to shed that one connection rather than stopping the server:
	##
	## ```roc
	## stream = listener.accept!()?
	## _ = Task.spawn!(|| handle!(stream))
	## ```
	spawn! : (() => Try({}, _err)) => Try({}, [TaskLimitReached])
	spawn! = |task!| {
		run! = || {
			match task!() {
				Ok({}) => {}
				Err(err) => {
					_ = Stderr.line!("task failed: ${Str.inspect(err)}")
				}
			}
		}
		if Host.task_spawn!(Box.box(run!)) {
			Ok({})
		} else {
			Err(TaskLimitReached)
		}
	}
}
