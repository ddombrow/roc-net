//! `Task.spawn!`: one OS thread per task, up to a limit.
//!
//! At the limit, spawning fails (`TaskLimitReached` in Roc) rather than
//! waiting or queueing. With a thread per task, waiting can deadlock tasks
//! that depend on each other: a proxy's connection task spawns the task for
//! the other direction, and if every slot is held by a task waiting to spawn,
//! none ever finishes. Refusing lets the caller shed that one piece of work.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

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

/// A task waiting to run: its closure, and its slot in the task limit.
struct Job {
    task: SendCallable,
    slot: Slot,
}

impl Job {
    fn run(self) {
        let Job { task, slot } = self;
        // roc_run_task takes ownership of the closure.
        unsafe { roc_run_task(task.0) };
        drop(slot);
    }
}

/// Threads that finished a task wait here briefly for the next one, so a
/// server handling many short connections reuses threads instead of creating
/// and tearing one down per connection (which dominated that workload).
struct Pool {
    queue: VecDeque<Job>,
    /// Threads waiting for a job that no job has been handed to yet.
    idle: usize,
}

static POOL: Mutex<Pool> = Mutex::new(Pool { queue: VecDeque::new(), idle: 0 });
static JOB_READY: Condvar = Condvar::new();

/// At most this many threads wait for work at once. Idle threads count
/// against the OS's thread limit, so the pool mustn't crowd out tasks.
const MAX_IDLE_THREADS: usize = 64;
/// An idle thread exits after this long without work, so the pool shrinks
/// after a burst.
const IDLE_THREAD_LIFETIME: Duration = Duration::from_secs(10);

fn pool() -> MutexGuard<'static, Pool> {
    POOL.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Run `first`, then keep taking jobs until none comes for a while.
fn worker(first: Job) {
    let mut job = first;
    loop {
        job.run();
        let mut pool = pool();
        if pool.idle >= MAX_IDLE_THREADS {
            return;
        }
        pool.idle += 1;
        let deadline = Instant::now() + IDLE_THREAD_LIFETIME;
        job = loop {
            // Jobs are only queued after claiming an idle thread (see
            // `roc_task_spawn`), so a queued job always has a waiter.
            if let Some(next) = pool.queue.pop_front() {
                break next;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                pool.idle -= 1;
                return;
            }
            pool = JOB_READY
                .wait_timeout(pool, left)
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .0;
        };
    }
}

/// Hosted function: Host.task_spawn!
#[no_mangle]
pub extern "C" fn roc_task_spawn(callable: RocErasedCallable) -> bool {
    let Some(slot) = try_claim_slot() else {
        unsafe { decref_erased_callable(callable, crate::roc_host()) };
        return false;
    };
    let job = Job { task: SendCallable(callable), slot };

    // Hand it to a waiting thread if there is one.
    {
        let mut pool = pool();
        if pool.idle > 0 {
            pool.idle -= 1;
            pool.queue.push_back(job);
            drop(pool);
            JOB_READY.notify_one();
            return true;
        }
    }

    // Otherwise start a thread. It's shared so the closure can be recovered
    // and released if the thread never starts (`spawn` drops what it was
    // given on failure).
    let job = Arc::new(Mutex::new(Some(job)));
    let for_thread = job.clone();
    let spawned = std::thread::Builder::new().spawn(move || {
        let first = for_thread.lock().unwrap().take();
        if let Some(first) = first {
            worker(first);
        }
    });

    match spawned {
        Ok(_) => true,
        Err(err) => {
            warn_thread_limit(&err);
            if let Some(job) = job.lock().unwrap().take() {
                unsafe { decref_erased_callable(job.task.0, crate::roc_host()) };
            }
            false
        }
    }
}
