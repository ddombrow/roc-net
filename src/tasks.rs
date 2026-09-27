//! `Task.spawn!`: a coroutine per task (see `sched.rs`), up to a limit.
//!
//! At the limit, spawning fails (`TaskLimitReached` in Roc) rather than
//! waiting or queueing, so a server sheds the one connection instead of
//! stalling its accept loop, and tasks that spawn each other (a proxy's
//! connection task spawning the other direction) can't deadlock waiting for
//! slots only they would free.

use std::sync::atomic::{AtomicUsize, Ordering};

use crate::roc_platform_abi::{decref_erased_callable, roc_run_task, RocErasedCallable};

static LIVE_TASKS: AtomicUsize = AtomicUsize::new(0);

/// Releases the task's slot even if the task never runs.
struct Slot;

impl Drop for Slot {
    fn drop(&mut self) {
        LIVE_TASKS.fetch_sub(1, Ordering::AcqRel);
    }
}

fn try_claim_slot() -> Option<Slot> {
    let limit = crate::limits::max_tasks();
    LIVE_TASKS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |live| (live < limit).then_some(live + 1))
        .ok()
        .map(|_| Slot)
}

/// The Roc closure a task runs. Dropping it without running it releases the
/// closure (and so whatever it captured, such as a connection).
struct Pending(Option<RocErasedCallable>);

// Roc refcounts and its allocator are thread-safe, and the closure has
// exactly one owner, so it can move to the worker that runs it.
unsafe impl Send for Pending {}

impl Pending {
    fn run(mut self) {
        if let Some(task) = self.0.take() {
            // roc_run_task takes ownership of the closure.
            unsafe { roc_run_task(task) };
        }
    }
}

impl Drop for Pending {
    fn drop(&mut self) {
        if let Some(task) = self.0.take() {
            unsafe { decref_erased_callable(task, crate::roc_host()) };
        }
    }
}

/// Warn once per process that task stacks can't be allocated.
fn warn_no_stack(err: &std::io::Error) {
    use std::sync::atomic::AtomicBool;
    static WARNED: AtomicBool = AtomicBool::new(false);
    if !WARNED.swap(true, Ordering::Relaxed) {
        eprintln!(
            "roc-net: can't allocate a task stack ({err}) with {} tasks running; \
             spawns fail with TaskLimitReached until some finish",
            LIVE_TASKS.load(Ordering::Relaxed)
        );
    }
}

/// Hosted function: Host.task_spawn!
#[no_mangle]
pub extern "C" fn roc_task_spawn(callable: RocErasedCallable) -> bool {
    let pending = Pending(Some(callable));
    let Some(slot) = try_claim_slot() else {
        return false;
    };
    let job = Box::new(move || {
        pending.run();
        drop(slot);
    });
    match crate::sched::spawn(job) {
        Ok(()) => true,
        Err((job, err)) => {
            warn_no_stack(&err);
            // Releases the closure and the slot.
            drop(job);
            false
        }
    }
}
