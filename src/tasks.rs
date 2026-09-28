//! Tasks: `Task.spawn!`, handles for joining and cancelling them, and the
//! groups behind `Task.scope!`. The scheduling itself is in `sched.rs`.
//!
//! At the task limit, spawning fails (`TaskLimitReached` in Roc) rather than
//! waiting or queueing, so a server sheds the one connection instead of
//! stalling its accept loop, and tasks that spawn each other (a proxy's
//! connection task spawning the other direction) can't deadlock waiting for
//! slots only they would free.
//!
//! Handles and groups are Roc-owned resources, like sockets (see
//! `resource.rs`). A task's result is stored with the task (`task_finish!`)
//! rather than sent through a channel, so joinable tasks aren't limited by
//! the number of channels.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

use crate::resource::ResourceHeap;
use crate::roc_host;
use crate::roc_platform_abi::{
    decref_box_with, decref_erased_callable, incref_erased_callable, roc_run_task, HostGroupNewResult,
    HostGroupNewResultPayload, HostGroupNewResultTag, HostTaskJoinResult, HostTaskJoinResultPayload,
    HostTaskJoinResultTag, HostTaskSpawnResult, HostTaskSpawnResultPayload, HostTaskSpawnResultTag, RocBox,
    RocErasedCallable,
};
use crate::sched::{self, TaskRef, Woke};

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

/// One Roc reference to a closure: the task to run, or a stored result.
/// Dropping it releases the reference (and so whatever the closure captured,
/// such as a connection).
struct Closure(Option<RocErasedCallable>);

// Roc refcounts and its allocator are thread-safe, and this is the only
// reference the host holds.
unsafe impl Send for Closure {}

impl Closure {
    fn run(mut self) {
        if let Some(task) = self.0.take() {
            // roc_run_task takes ownership of the closure.
            unsafe { roc_run_task(task) };
        }
    }
}

impl Drop for Closure {
    fn drop(&mut self) {
        if let Some(callable) = self.0.take() {
            unsafe { decref_erased_callable(callable, roc_host()) };
        }
    }
}

/// A Roc-owned task handle or scope group.
enum TaskObj {
    Handle(Handle),
    Group(Mutex<Vec<TaskRef>>),
}

/// Counts as one of the task's handles while it exists.
struct Handle(TaskRef);

impl Drop for Handle {
    fn drop(&mut self) {
        self.0.drop_handle();
    }
}

static HEAP: OnceLock<ResourceHeap<TaskObj>> = OnceLock::new();

fn heap() -> &'static ResourceHeap<TaskObj> {
    // Handles of detached tasks are released right away, so this bounds
    // handles kept for joining, not running tasks. Slot indexes use 16 bits.
    HEAP.get_or_init(|| ResourceHeap::new(crate::limits::max_tasks().min(65_535)))
}

/// Called by `roc_dealloc`. Returns true if `ptr` was a handle or group,
/// which is now released and must not be freed as ordinary memory.
pub fn release(ptr: *mut std::ffi::c_void) -> bool {
    HEAP.get().is_some_and(|heap| heap.release(ptr))
}

/// Run `f` on the object behind a handle, then release the handle.
fn with_obj<T>(handle: *mut u64, f: impl FnOnce(Option<&TaskObj>) -> T) -> T {
    let result = f(unsafe { heap().get(handle) }.ok());
    unsafe { decref_box_with(handle as RocBox, core::mem::align_of::<u64>(), false, None, roc_host()) };
    result
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

fn spawn_failed() -> HostTaskSpawnResult {
    HostTaskSpawnResult { payload: HostTaskSpawnResultPayload { err: [] }, tag: HostTaskSpawnResultTag::Err }
}

/// Hosted function: Host.task_spawn!
#[no_mangle]
pub extern "C" fn roc_task_spawn(callable: RocErasedCallable) -> HostTaskSpawnResult {
    let closure = Closure(Some(callable));
    let Some(slot) = try_claim_slot() else {
        return spawn_failed();
    };
    // Claim the handle's slot first, so a task never starts without one.
    let Ok(reservation) = heap().try_reserve() else {
        return spawn_failed();
    };
    let job = Box::new(move || {
        closure.run();
        drop(slot);
    });
    match sched::spawn(job) {
        // The task was created with one handle counted: this one.
        Ok(task) => HostTaskSpawnResult {
            payload: HostTaskSpawnResultPayload {
                ok: std::mem::ManuallyDrop::new(reservation.insert(TaskObj::Handle(Handle(task)))),
            },
            tag: HostTaskSpawnResultTag::Ok,
        },
        Err((job, err)) => {
            warn_no_stack(&err);
            // Releases the closure and the task slot.
            drop(job);
            spawn_failed()
        }
    }
}

/// Hosted function: Host.task_finish!
#[no_mangle]
pub extern "C" fn roc_task_finish(result: RocErasedCallable) -> bool {
    let result = Closure(Some(result));
    match TaskRef::current() {
        Some(task) => {
            let watched = task.has_handles();
            task.set_result(Box::new(result));
            watched
        }
        None => false,
    }
}

fn join_err() -> HostTaskJoinResult {
    HostTaskJoinResult { payload: HostTaskJoinResultPayload { err: [] }, tag: HostTaskJoinResultTag::Err }
}

/// Hosted function: Host.task_join!
#[no_mangle]
pub extern "C" fn roc_task_join(handle: *mut u64) -> HostTaskJoinResult {
    with_obj(handle, |obj| {
        let Some(TaskObj::Handle(Handle(task))) = obj else { return join_err() };
        if task.wait_finished(true) == Woke::Cancelled {
            return join_err();
        }
        task.with_result(|result| match result.and_then(|result| result.downcast_ref::<Closure>()) {
            // Another reference for Roc, so the result can be joined again.
            Some(Closure(Some(callable))) => {
                unsafe { incref_erased_callable(*callable, 1) };
                HostTaskJoinResult {
                    payload: HostTaskJoinResultPayload { ok: std::mem::ManuallyDrop::new(*callable) },
                    tag: HostTaskJoinResultTag::Ok,
                }
            }
            // Every task stores its result before it returns (Task.roc), so
            // a finished task always has one.
            _ => join_err(),
        })
    })
}

/// Hosted function: Host.task_cancel!
#[no_mangle]
pub extern "C" fn roc_task_cancel(handle: *mut u64) {
    with_obj(handle, |obj| {
        if let Some(TaskObj::Handle(Handle(task))) = obj {
            task.cancel();
        }
    })
}

/// Hosted function: Host.task_is_cancelled!
#[no_mangle]
pub extern "C" fn roc_task_is_cancelled() -> bool {
    sched::is_cancelled()
}

/// Hosted function: Host.task_yield!
#[no_mangle]
pub extern "C" fn roc_task_yield() {
    sched::yield_now();
}

/// Hosted function: Host.group_new!
#[no_mangle]
pub extern "C" fn roc_group_new() -> HostGroupNewResult {
    match heap().try_reserve() {
        Ok(reservation) => HostGroupNewResult {
            payload: HostGroupNewResultPayload {
                ok: std::mem::ManuallyDrop::new(reservation.insert(TaskObj::Group(Mutex::new(Vec::new())))),
            },
            tag: HostGroupNewResultTag::Ok,
        },
        Err(_) => HostGroupNewResult { payload: HostGroupNewResultPayload { err: [] }, tag: HostGroupNewResultTag::Err },
    }
}

/// Hosted function: Host.group_add!
#[no_mangle]
pub extern "C" fn roc_group_add(group: *mut u64, handle: *mut u64) {
    let task = with_obj(handle, |obj| match obj {
        Some(TaskObj::Handle(Handle(task))) => Some(task.clone()),
        _ => None,
    });
    let Some(task) = task else { return with_obj(group, |_| ()) };
    with_obj(group, |obj| {
        if let Some(TaskObj::Group(tasks)) = obj {
            let mut tasks = tasks.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            // Forget finished tasks as we go, so a long-lived scope that
            // starts many short tasks doesn't grow without bound.
            tasks.retain(|task| !task.is_finished());
            tasks.push(task);
        }
    });
}

/// Hosted function: Host.group_close!
#[no_mangle]
pub extern "C" fn roc_group_close(group: *mut u64, cancel: bool) {
    with_obj(group, |obj| {
        let Some(TaskObj::Group(tasks)) = obj else { return };
        let tasks = std::mem::take(&mut *tasks.lock().unwrap_or_else(|poisoned| poisoned.into_inner()));
        if cancel {
            for task in &tasks {
                task.cancel();
            }
        }
        // Not cancellable: a scope must not return while its tasks run,
        // even if the task running the scope is cancelled meanwhile.
        for task in &tasks {
            task.wait_finished(false);
        }
    })
}
