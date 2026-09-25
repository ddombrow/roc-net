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
	## Returns `Err(TaskLimitReached)` when too many tasks are already running.
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
