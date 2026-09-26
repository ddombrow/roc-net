//! `Task.spawn!`: one OS thread per task, up to a limit.
//!
//! At the limit, spawning fails (`TaskLimitReached` in Roc) rather than
//! waiting or queueing. With a thread per task, waiting can deadlock tasks
//! that depend on each other: a proxy's connection task spawns the task for
//! the other direction, and if every slot is held by a task waiting to spawn,
//! none ever finishes. Refusing lets the caller shed that one piece of work.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use crate::roc_platform_abi::{decref_erased_callable, roc_run_task, RocErasedCallable};

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

fn try_claim_slot() -> Option<Slot> {
    let limit = crate::limits::max_tasks();
    LIVE_TASKS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |live| {
            (live < limit).then_some(live + 1)
        })
        .ok()
        .map(|_| Slot)
}

/// Warn once per process that the OS refused to create a thread.
fn warn_thread_limit(err: &std::io::Error) {
    use std::sync::atomic::AtomicBool;
    static WARNED: AtomicBool = AtomicBool::new(false);
    if !WARNED.swap(true, Ordering::Relaxed) {
        eprintln!(
            "roc-net: the OS refused to start a task thread ({err}) with {} tasks running; \
             spawns fail with TaskLimitReached until some finish",
            LIVE_TASKS.load(Ordering::Relaxed)
        );
    }
}

/// Hosted function: Host.task_spawn!
#[no_mangle]
pub extern "C" fn roc_task_spawn(callable: RocErasedCallable) -> bool {
    let Some(slot) = try_claim_slot() else {
        unsafe { decref_erased_callable(callable, crate::roc_host()) };
        return false;
    };

    // Shared so the closure can be recovered and released if the thread
    // never starts (`spawn` drops what it was given on failure).
    let task = Arc::new(Mutex::new(Some(SendCallable(callable))));
    let for_thread = task.clone();
    let spawned = std::thread::Builder::new().spawn(move || {
        let _slot = slot;
        let task = for_thread.lock().unwrap().take();
        if let Some(task) = task {
            // roc_run_task takes ownership of the closure.
            unsafe { roc_run_task(task.0) };
        }
    });

    match spawned {
        Ok(_) => true,
        Err(err) => {
            warn_thread_limit(&err);
            if let Some(task) = task.lock().unwrap().take() {
                unsafe { decref_erased_callable(task.0, crate::roc_host()) };
            }
            false
        }
    }
}
