import Host

## Concurrent tasks.
##
## Each task runs a closure to completion, possibly in parallel with other
## tasks and with `main!`. When `main!` returns, the program exits and any
## tasks still running are stopped.
##
## `spawn!` returns a `Handle` for waiting for the task's result (`join!`) or
## stopping it (`cancel!`). A task whose handles are all released keeps
## running (it's detached); if it returns an error, that's printed to stderr.
## `scope!` runs tasks that can't outlive a block of code.
##
## Cancelling is cooperative: the task's waits (reading, receiving, sleeping,
## `Select`) end at once with a `Cancelled` error, which ordinary `?`-style
## code passes up, so the task unwinds and its sockets close. A task that
## ignores the error keeps running; a long computation can check
## `is_cancelled!`.
Task := [].{

	## A running (or finished) task whose result is
	## `Try(ok, [Cancelled, ..err])`: the task's own errors, which include
	## `Cancelled` when it's stopped mid-wait.
	Handle(ok, err) :: Host.TaskHandle.{

		## Wait for the task to finish and return its result. Fails with
		## `Cancelled` if the task waiting is cancelled first. Can be called
		## more than once, from any task.
		join! : Handle(ok, err) => Try(ok, [Cancelled, ..err])
		join! = |Handle.(task)|
			match Host.task_join!(task) {
				Ok(boxed) => {
					thunk = Box.unbox(boxed)
					match thunk() {
						Ok(value) => Ok(value)
						Err(err) => Err(err)
					}
				}
				Err(Cancelled) => Err(Cancelled)
			}

		## Whether the task has finished, so `join!` would return at once.
		is_finished! : Handle(ok, err) => Bool
		is_finished! = |Handle.(task)| Host.task_is_finished!(task)

		## The host task handle, for `Select` to wait on.
		task_handle : Handle(ok, err) -> Host.TaskHandle
		task_handle = |Handle.(task)| task

		## Ask the task to stop (see "Cancelling" above). Doesn't wait for it:
		## `join!` does.
		cancel! : Handle(ok, err) => {}
		cancel! = |Handle.(task)| Host.task_cancel!(task)
	}

	## Tasks started with a scope's `spawn!` can't outlive `scope!`.
	Scope :: Host.TaskGroup.{

		## Like `Task.spawn!`, for a task that belongs to this scope.
		spawn! : Scope, (() => Try(ok, [Cancelled, ..err])) => Try(Handle(ok, err), [TaskLimitReached])
		spawn! = |Scope.(group), task!| {
			Handle.(task) = start!(task!)?
			Host.group_add!(group, task)
			Ok(Handle.(task))
		}

		## Cancel the scope's tasks that are still running (see "Cancelling"
		## above), without leaving the scope: `scope!` still waits for them to
		## finish when its body returns. For helper tasks that should last only
		## as long as the body, such as a connection's writer while the body
		## reads:
		##
		## ```roc
		## Task.scope!(|scope| {
		##     _ = scope.spawn!(|| write_loop!(stream, outbox))?
		##     result = read_loop!(stream)
		##     # Otherwise the scope would wait for the writer, which may be
		##     # waiting for a message that never comes.
		##     scope.cancel_all!()
		##     result
		## })
		## ```
		cancel_all! : Scope => {}
		cancel_all! = |Scope.(group)| Host.group_cancel!(group)
	}

	## Run `task!` concurrently, returning a handle for its result.
	##
	## Returns `Err(TaskLimitReached)` without running `task!` when too many
	## tasks are already running: `ROC_NET_MAX_TASKS` (default 100,000), or
	## fewer if no more task stacks can be allocated. Anything `task!`
	## captured is released, so a connection it captured is closed. In a
	## server's accept loop, ignore the error to shed that one connection
	## rather than stopping the server:
	##
	## ```roc
	## stream = listener.accept!()?
	## _ = Task.spawn!(|| handle!(stream))
	## ```
	spawn! : (() => Try(ok, [Cancelled, ..err])) => Try(Handle(ok, err), [TaskLimitReached])
	spawn! = |task!| start!(task!)

	## Run `body!` with a scope for starting tasks, then wait for every task
	## started in it. If `body!` returns an error, the scope's unfinished tasks
	## are cancelled first. Either way, no task started in the scope is still
	## running when `scope!` returns.
	##
	## ```roc
	## Task.scope!(|scope| {
	##     a = scope.spawn!(|| fetch!("a"))?
	##     b = scope.spawn!(|| fetch!("b"))?
	##     Ok((a.join!()?, b.join!()?))
	## })
	## ```
	##
	## Only `body!`'s result decides whether the others are cancelled (or
	## `scope.cancel_all!()`, which the body can call itself). A task
	## in the scope that fails just ends: the rest keep running, and the
	## scope still waits for them. Its error goes wherever it would for any
	## task: to whoever joins its handle, or, if every handle is released
	## unjoined, to stderr.
	##
	## So with several long-running tasks (one accept loop per listener,
	## say), decide what one of them ending should mean. If the others should
	## carry on, let each handle its own errors. To stop them all instead,
	## have `body!` return an error when the first one ends. Joining handles
	## in turn won't do that, since `join!` waits for that particular task,
	## but a `Select` with an `on_join` arm per task will:
	##
	## ```roc
	## Task.scope!(|scope| {
	##     plain = scope.spawn!(|| serve!(tcp_listener))?
	##     secure = scope.spawn!(|| serve!(tls_listener))?
	##     # Whichever ends first; returning an error cancels the other.
	##     first =
	##         Select.new({})
	##             .on_join(plain, |result| result)
	##             .on_join(secure, |result| result)
	##             .wait!()?
	##     match first {
	##         Ok({}) => Err(ListenerStopped)
	##         Err(err) => Err(err)
	##     }
	## })
	## ```
	scope! : (Scope => Try(a, [TaskLimitReached, ..err])) => Try(a, [TaskLimitReached, ..err])
	scope! = |body!|
		match Host.group_new!({}) {
			Err(TaskLimitReached) => Err(TaskLimitReached)
			Ok(group) => {
				result = body!(Scope.(group))
				failed =
					match result {
						Ok(_) => False
						Err(_) => True
					}
				Host.group_close!(group, failed)
				match result {
					Ok(value) => Ok(value)
					Err(err) => Err(err)
				}
			}
		}

	## Let other tasks on this thread run before continuing. Tasks yield
	## whenever they wait; a long computation can call this to share its
	## thread.
	yield! : {} => {}
	yield! = |{}| Host.task_yield!({})

	## Whether the running task has been cancelled, for a long computation
	## that doesn't wait on anything to check.
	is_cancelled! : {} => Bool
	is_cancelled! = |{}| Host.task_is_cancelled!({})

	start! : (() => Try(ok, [Cancelled, ..err])) => Try(Handle(ok, err), [TaskLimitReached])
	start! = |task!| {
		run! = || {
			result = task!()
			watched = Host.task_finish!(Box.box(|| result))
			# Nobody can join a task whose handles are gone, so report its
			# failure rather than lose it, unless it failed because it was
			# cancelled, as asked.
			if !watched and !Host.task_is_cancelled!({}) {
				match result {
					Ok(_) => {}
					# Through the log writer, so a failing task can't stall its
					# worker on a slow stderr.
					Err(err) => Host.log_write!(3, "task failed", [{ key: "error", value: Str(Str.inspect(err)) }])
				}
			}
		}
		match Host.task_spawn!(Box.box(run!)) {
			Ok(task) => Ok(Handle.(task))
			Err(TaskLimitReached) => Err(TaskLimitReached)
		}
	}
}
