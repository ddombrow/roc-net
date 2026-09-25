//! `Task.spawn!`: one OS thread per task, up to a fixed limit.

use std::sync::atomic::{AtomicUsize, Ordering};

use crate::roc_platform_abi::{decref_erased_callable, roc_run_task, RocErasedCallable};

const MAX_LIVE_TASKS: usize = 1024;

/// Roc refcounts and its allocator are atomic/thread-safe, and each closure has
/// exactly one owner (the thread it moves to), so it can cross threads.
struct SendCallable(RocErasedCallable);
unsafe impl Send for SendCallable {}

static LIVE_TASKS: AtomicUsize = AtomicUsize::new(0);

/// Releases the task's slot even if the thread unwinds.
struct Slot;

impl Drop for Slot {
    fn drop(&mut self) {
        LIVE_TASKS.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Hosted function: Host.task_spawn!
#[no_mangle]
pub extern "C" fn roc_task_spawn(callable: RocErasedCallable) -> bool {
    let reserved = LIVE_TASKS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |live| {
            (live < MAX_LIVE_TASKS).then_some(live + 1)
        })
        .is_ok();
    if !reserved {
        unsafe { decref_erased_callable(callable, crate::roc_host()) };
        return false;
    }

    let slot = Slot;
    let task = SendCallable(callable);
    let spawned = std::thread::Builder::new().spawn(move || {
        let _slot = slot;
        let task = task;
        // roc_run_task takes ownership of the closure.
        unsafe { roc_run_task(task.0) };
    });

    match spawned {
        Ok(_) => true,
        // The closure moved into the failed thread's environment and was
        // dropped with it without running; its Roc allocation leaks. Thread
        // creation failing means the process is already out of resources.
        Err(err) => {
            eprintln!("roc-net: failed to start task thread: {err}");
            false
        }
    }
}
