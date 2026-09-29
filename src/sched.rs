//! Tasks as coroutines on a few worker threads, with work stealing.
//!
//! Every task, `main!` included, runs on its own small stack (a corosensei
//! coroutine). Each worker thread runs many of them: when a task would block
//! (a socket that isn't ready, a sleep, an empty channel), the hosted function
//! suspends it and the worker runs another. Sockets are non-blocking, and
//! each worker waits for readiness with its own `mio::Poll` (epoll or
//! kqueue), so an idle connection costs a suspended stack, not a thread.
//!
//! Roc code doesn't change: a hosted function still returns only when its
//! operation is done. Suspending happens inside it, on the task's stack.
//!
//! - **Run queues.** Each worker has a queue of tasks ready to run. A new
//!   task, or one being woken, goes on the queue of the worker doing the
//!   spawning or waking (a plain thread uses a shared queue instead), which
//!   keeps request-response traffic on one thread. When a worker is
//!   saturated (busy without a break for `ROC_NET_SHARE_AFTER_US`, default
//!   500 µs) and has a backlog,
//!   it wakes a sleeping worker (at most one at a time, see `SEARCHING`),
//!   which steals half of some queue. Only woken workers steal: stealing
//!   whenever a worker ran dry kept moving connections between workers that
//!   were keeping up. Workers past the first start only when needed, up to
//!   `ROC_NET_WORKERS` (default one per CPU), so a small tool stays on one
//!   thread.
//! - **Tasks move between threads.** A task may resume on a different thread
//!   than it suspended on. So nothing may hold thread-local state across a
//!   wait, nor a `std::sync::Mutex` (another task on that thread taking it
//!   would block the whole worker): code that must wait while holding a lock
//!   uses [`Lock`]. And because the compiler may keep a thread-local
//!   variable's address across a call, thread-locals are only reached
//!   through functions that are never inlined, which look the address up
//!   again each time (see `with_scratch` in `sockets.rs` too).
//! - **Sockets.** A task waiting on a socket is recorded with the socket
//!   ([`IoReg`]), not the worker, so an event wakes it wherever it runs. Each
//!   socket is watched by one worker's event queue, at first the one it was
//!   first waited on from; when a task that was stolen waits on it (and
//!   nobody else is waiting on it), it moves to the thief's queue, so stealing
//!   rebalances load lastingly rather than for one request.
//! - **Waking.** Each wait has an id, and a wake-up only counts if it names
//!   the task's current wait, so a stale one (for a wait that already ended
//!   by timing out, say) is ignored. A wake-up can arrive before the task has
//!   finished suspending; the task's state flags make the worker put it back
//!   on a queue once it has.
//! - **Fairness.** Cooperative: a task yields when it waits, and after
//!   [`BUDGET`] socket operations that didn't have to wait, so a task
//!   streaming data can't starve the others on its worker. Pure computation
//!   in Roc has no yield points.
//! - The same functions work outside a task (on a plain thread), by blocking
//!   that thread instead.

use std::any::Any;
use std::cell::{Cell, RefCell, UnsafeCell};
use std::collections::{BTreeMap, VecDeque};
use std::io;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use corosensei::stack::DefaultStack;
use corosensei::{Coroutine, CoroutineResult, Yielder};
use mio::unix::SourceFd;
use mio::{Events, Interest, Poll, Registry, Token, Waker};
use slab::Slab;

/// Socket operations a task may complete without waiting before it yields to
/// the others on its worker.
const BUDGET: u32 = 128;

/// A busy worker checks for socket events and the shared queue after running
/// this many tasks, so a long queue can't hide them.
const EVENT_INTERVAL: u32 = 61;

/// Finished tasks' stacks kept for reuse, so spawning doesn't map a new one
/// each time.
const MAX_POOLED_STACKS: usize = 256;

const WAKER_TOKEN: Token = Token(usize::MAX);

/// Longest a worker sleeps in `poll` at a time: kqueue rejects very long
/// timeouts (EINVAL), and waking once an hour to re-check costs nothing.
const MAX_POLL_WAIT: Duration = Duration::from_secs(3600);

pub type Job = Box<dyn FnOnce() + Send>;

/// Why a task handed control back to its worker.
enum Suspend {
    /// Waiting: its wakers, and timer if any, are registered.
    Wait,
    /// Out of budget: run again after the others in the queue.
    Yield,
}

/// How a wait ended.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Woke {
    Ready = 0,
    TimedOut = 1,
    /// The task was cancelled (see [`TaskRef::cancel`]).
    Cancelled = 2,
}

impl Woke {
    fn from_u8(value: u8) -> Woke {
        match value {
            1 => Woke::TimedOut,
            2 => Woke::Cancelled,
            _ => Woke::Ready,
        }
    }
}

type Co = Coroutine<(), Suspend, (), DefaultStack>;

// --- Tasks ---

/// Task state bits. `RUNNING`: a worker is running it. `NOTIFIED`: it's on a
/// queue, or (with `RUNNING`) must go back on one when it suspends.
const RUNNING: u8 = 1;
const NOTIFIED: u8 = 2;
const DONE: u8 = 4;

struct Task {
    /// Resumed only by the worker that set `RUNNING`.
    co: UnsafeCell<Option<Co>>,
    state: AtomicU8,
    /// The id of the wait the task is in (or about to suspend for); 0 once a
    /// wake-up has claimed it.
    wait: AtomicU64,
    /// How the last wait ended.
    woke: AtomicU8,
    /// The task's own timer: (worker, key). Touched only by the task itself.
    timer: UnsafeCell<Option<(usize, (Instant, u64))>>,
    /// The first task, `main!`: when it returns, the program exits.
    main: bool,
    /// Cancelled (see [`TaskRef::cancel`]): cancellable waits end at once.
    cancelled: AtomicBool,
    /// Whether the current wait may be ended by cancelling (locks can't be).
    cancellable: AtomicBool,
    /// Finished, and who's waiting for that (`TaskRef::wait_done`); the flag
    /// changes under the same lock as the list, so no waiter misses it.
    finished: Mutex<(bool, Waiters)>,
    /// The task's result, stored by the task itself before it returns (the
    /// host's Roc glue decides what's in it).
    result: Mutex<Option<Box<dyn Any + Send>>>,
    /// Roc handles to the task (`TaskRef::add_handle`): when none are left,
    /// nobody can wait for its result.
    handles: AtomicUsize,
}

// `co` and `timer` are only touched by whoever holds `RUNNING` (the queue
// handoff orders those accesses); everything else is atomic.
unsafe impl Send for Task {}
unsafe impl Sync for Task {}

static NEXT_WAIT: AtomicU64 = AtomicU64::new(1);

fn new_wait_id() -> u64 {
    NEXT_WAIT.fetch_add(1, Ordering::Relaxed)
}

/// End `task`'s wait `wait`, if that's still the wait it's in, and queue it.
/// Returns whether it did (false: that wait already ended, say by timing out
/// or being cancelled).
fn wake(task: &Arc<Task>, wait: u64, woke: Woke) -> bool {
    if task.wait.compare_exchange(wait, 0, Ordering::AcqRel, Ordering::Acquire).is_ok() {
        task.woke.store(woke as u8, Ordering::Release);
        schedule(task.clone());
        true
    } else {
        false
    }
}

/// Put a woken task on a queue, unless it's queued already. If it's still
/// running (it was woken before it finished suspending), mark it, and its
/// worker queues it once it has.
fn schedule(task: Arc<Task>) {
    let mut state = task.state.load(Ordering::Acquire);
    loop {
        if state & (NOTIFIED | DONE) != 0 {
            return;
        }
        let next = state | NOTIFIED;
        match task.state.compare_exchange_weak(state, next, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) if state & RUNNING != 0 => return,
            Ok(_) => break,
            Err(actual) => state = actual,
        }
    }
    push(task);
}

/// Queue a ready task: on this worker's queue, or from a plain thread on the
/// shared one.
fn push(task: Arc<Task>) {
    match this_worker() {
        Some(worker) => {
            let backlog = worker.shared.push(task);
            if backlog > 1 && worker.saturated() {
                notify_idle();
            }
        }
        None => {
            {
                // The count changes with the queue, under its lock, so a
                // worker draining the queue can't be overtaken by a stale
                // increment (a count stuck above zero keeps idle workers
                // polling without sleeping).
                let mut inject = lock(&INJECT);
                inject.push_back(task);
                INJECT_LEN.store(inject.len(), Ordering::Release);
            }
            notify_idle();
        }
    }
}

// --- Workers ---

/// The part of a worker other threads use: its run queue, timers, and event
/// queue registry, and how to wake it.
struct Shared {
    index: usize,
    queue: Mutex<VecDeque<Arc<Task>>>,
    /// `queue`'s length, readable without the lock.
    queue_len: AtomicUsize,
    timers: Mutex<BTreeMap<(Instant, u64), (Arc<Task>, u64)>>,
    registry: Registry,
    waker: Waker,
    /// Set by `notify_idle` when it wakes this worker to look for work; the
    /// worker then counts as searching until it has looked.
    notified: AtomicBool,
}

impl Shared {
    /// Add to the back of the run queue; returns its new length.
    fn push(&self, task: Arc<Task>) -> usize {
        let mut queue = lock(&self.queue);
        queue.push_back(task);
        let len = queue.len();
        self.queue_len.store(len, Ordering::Release);
        len
    }

    fn pop(&self) -> Option<Arc<Task>> {
        if self.queue_len.load(Ordering::Acquire) == 0 {
            return None;
        }
        let mut queue = lock(&self.queue);
        let task = queue.pop_front();
        self.queue_len.store(queue.len(), Ordering::Release);
        task
    }
}

/// Workers, by index; started when first needed.
static WORKERS: OnceLock<Vec<OnceLock<Arc<Shared>>>> = OnceLock::new();
/// Tasks queued by threads that aren't workers.
static INJECT: Mutex<VecDeque<Arc<Task>>> = Mutex::new(VecDeque::new());
/// `INJECT`'s length, readable without the lock; only written while holding it.
static INJECT_LEN: AtomicUsize = AtomicUsize::new(0);
/// Workers blocked in `poll`, one bit each.
static SLEEPING: AtomicU64 = AtomicU64::new(0);
/// Workers woken to look for work that haven't looked yet. While there are
/// any, more backlog doesn't wake more workers: one thief at a time, rather
/// than a stampede for one extra task.
static SEARCHING: AtomicUsize = AtomicUsize::new(0);
/// `main!`'s exit code once it has returned.
static MAIN_RESULT: Mutex<Option<i32>> = Mutex::new(None);
static MAIN_DONE: AtomicBool = AtomicBool::new(false);

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn fatal(message: &str) -> ! {
    eprintln!("roc-net: {message}");
    std::process::exit(1);
}

fn workers() -> &'static [OnceLock<Arc<Shared>>] {
    WORKERS.get().map_or(&[], Vec::as_slice)
}

/// Wake a sleeping worker to steal work, or start another worker if none is
/// asleep. Does nothing while another woken worker is still looking.
fn notify_idle() {
    if SEARCHING.load(Ordering::SeqCst) > 0 {
        return;
    }
    let sleeping = SLEEPING.load(Ordering::SeqCst);
    if sleeping != 0 {
        let index = sleeping.trailing_zeros() as usize;
        let bit = 1u64 << index;
        if SLEEPING.fetch_and(!bit, Ordering::SeqCst) & bit != 0 {
            if let Some(shared) = workers().get(index).and_then(OnceLock::get) {
                SEARCHING.fetch_add(1, Ordering::SeqCst);
                shared.notified.store(true, Ordering::SeqCst);
                let _ = shared.waker.wake();
            }
        }
        return;
    }
    // Everyone's awake: start another worker, if there are any left.
    if let Some(index) = workers().iter().position(|w| w.get().is_none()) {
        start_worker(index);
    }
}

/// Start worker `index`'s thread; it begins by looking for work to steal.
fn start_worker(index: usize) {
    static STARTING: Mutex<()> = Mutex::new(());
    let _starting = lock(&STARTING);
    let Some(slot) = workers().get(index) else { return };
    if slot.get().is_some() {
        return;
    }
    let (shared, poll) = match new_shared(index) {
        Ok(created) => created,
        Err(err) => return warn_worker_start(index, &err),
    };
    shared.notified.store(true, Ordering::SeqCst);
    SEARCHING.fetch_add(1, Ordering::SeqCst);
    let for_thread = shared.clone();
    let started = std::thread::Builder::new().name(format!("roc-net-worker-{index}")).spawn(move || {
        let worker = Worker::install(for_thread, poll);
        worker.run();
    });
    match started {
        Ok(_) => {
            let _ = slot.set(shared);
        }
        Err(err) => {
            SEARCHING.fetch_sub(1, Ordering::SeqCst);
            warn_worker_start(index, &err);
        }
    }
}

fn new_shared(index: usize) -> io::Result<(Arc<Shared>, Poll)> {
    // Fails when out of file descriptors, say.
    let poll = Poll::new()?;
    let waker = Waker::new(poll.registry(), WAKER_TOKEN)?;
    let registry = poll.registry().try_clone()?;
    let shared = Arc::new(Shared {
        index,
        queue: Mutex::new(VecDeque::new()),
        queue_len: AtomicUsize::new(0),
        timers: Mutex::new(BTreeMap::new()),
        registry,
        waker,
        notified: AtomicBool::new(false),
    });
    Ok((shared, poll))
}

/// Warn once that a worker thread couldn't start; the ones already running
/// carry on.
fn warn_worker_start(index: usize, err: &io::Error) {
    static WARNED: AtomicBool = AtomicBool::new(false);
    if !WARNED.swap(true, Ordering::Relaxed) {
        eprintln!("roc-net: can't start worker thread {index} ({err}); running tasks on the workers already started");
    }
}

/// The part of a worker only its own thread uses.
struct Worker {
    shared: Arc<Shared>,
    poll: RefCell<Poll>,
    events: RefCell<Events>,
    /// When the worker last woke from sleeping in `poll`: how long it has
    /// been busy without a break.
    busy_since: Cell<Instant>,
}

impl Worker {
    /// Create this thread's worker. It's leaked: it lives as long as the
    /// process.
    fn install(shared: Arc<Shared>, poll: Poll) -> &'static Worker {
        let worker: &'static Worker = Box::leak(Box::new(Worker {
            shared,
            poll: RefCell::new(poll),
            events: RefCell::new(Events::with_capacity(1024)),
            busy_since: Cell::new(Instant::now()),
        }));
        set_worker(worker);
        worker
    }

    /// Busy long enough without a break that its backlog is more than a
    /// passing batch of events, so it's worth waking another worker to share
    /// it. Sharing sooner woke thieves for backlogs the owner would have
    /// cleared by itself in microseconds, and moved connections back and
    /// forth between workers.
    fn saturated(&self) -> bool {
        self.busy_since.get().elapsed() >= crate::limits::share_after()
    }

    fn index(&self) -> usize {
        self.shared.index
    }

    /// Run tasks until `main!` has returned (only worker 0 ever stops).
    fn run(&self) {
        // A new worker starts because some worker needed help.
        self.answer_notification();
        let mut ticks = 0u32;
        loop {
            if self.index() == 0 && MAIN_DONE.load(Ordering::Acquire) {
                return;
            }
            if let Some(task) = self.shared.pop() {
                self.run_task(task);
                ticks = ticks.wrapping_add(1);
                if ticks % EVENT_INTERVAL == 0 {
                    self.poll_events(Some(Duration::ZERO));
                    self.fire_timers();
                    self.take_injected();
                }
                continue;
            }
            if self.take_injected() || self.answer_notification() {
                continue;
            }
            self.park();
        }
    }

    /// Sleep in `poll` until a socket event, a timer, or a wake-up.
    fn park(&self) {
        let bit = 1u64 << self.index();
        SLEEPING.fetch_or(bit, Ordering::SeqCst);
        // Re-check after announcing sleep: work queued for any worker before
        // `notify_idle` could see the bit would otherwise wait for the next
        // socket event. (A backlog on another worker isn't checked: its owner
        // is working through it, and the next push there wakes a thief.
        // Checking kept idle workers spinning on backlogs that cleared before
        // they could steal from them.)
        let work_waiting = INJECT_LEN.load(Ordering::SeqCst) > 0 || (self.index() == 0 && MAIN_DONE.load(Ordering::SeqCst));
        let timeout = if work_waiting {
            Some(Duration::ZERO)
        } else {
            let now = Instant::now();
            lock(&self.shared.timers)
                .first_key_value()
                .map(|((at, _), _)| at.saturating_duration_since(now).min(MAX_POLL_WAIT))
        };
        self.poll_events(timeout);
        self.busy_since.set(Instant::now());
        SLEEPING.fetch_and(!bit, Ordering::SeqCst);
        self.fire_timers();
        self.answer_notification();
    }

    /// If `notify_idle` woke this worker to share a backlog, steal now, even
    /// if it also has work of its own: until it has looked, it counts as
    /// searching, and no other worker is woken. (Looking only once idle let
    /// a busy worker hold that off indefinitely, so load stopped spreading.)
    ///
    /// Only woken workers steal: stealing whenever a worker ran dry kept
    /// moving connections, and their event registrations, between workers
    /// whose owners were keeping up fine.
    fn answer_notification(&self) -> bool {
        if !self.shared.notified.swap(false, Ordering::SeqCst) {
            return false;
        }
        let found = self.steal();
        SEARCHING.fetch_sub(1, Ordering::SeqCst);
        found
    }

    fn run_task(&self, task: Arc<Task>) {
        // Popped from a queue, so it's NOTIFIED; now it's running.
        task.state.store(RUNNING, Ordering::Release);
        set_current_task(Arc::as_ptr(&task));
        set_ops_left(BUDGET);
        let co = unsafe { (*task.co.get()).as_mut().expect("a task that isn't done has a coroutine") };
        let result = co.resume(());
        set_yielder(std::ptr::null());
        set_current_task(std::ptr::null());
        match result {
            CoroutineResult::Yield(Suspend::Yield) => {
                task.state.store(NOTIFIED, Ordering::Release);
                self.shared.push(task);
            }
            CoroutineResult::Yield(Suspend::Wait) => {
                // Woken while suspending? Then queue it now.
                if task.state.compare_exchange(RUNNING, 0, Ordering::AcqRel, Ordering::Acquire).is_err() {
                    task.state.store(NOTIFIED, Ordering::Release);
                    self.shared.push(task);
                }
            }
            CoroutineResult::Return(()) => {
                task.state.store(DONE, Ordering::Release);
                let co = unsafe { (*task.co.get()).take() }.expect("just ran");
                recycle_stack(co.into_stack());
                {
                    let mut finished = lock(&task.finished);
                    finished.0 = true;
                    finished.1.wake_all();
                }
                if task.main {
                    MAIN_DONE.store(true, Ordering::Release);
                    if let Some(main) = workers().first().and_then(OnceLock::get) {
                        let _ = main.waker.wake();
                    }
                }
            }
        }
    }

    fn poll_events(&self, timeout: Option<Duration>) {
        let mut events = self.events.borrow_mut();
        match self.poll.borrow_mut().poll(&mut events, timeout) {
            Ok(()) => {}
            Err(err) if err.kind() == io::ErrorKind::Interrupted => return,
            Err(err) => fatal(&format!("waiting for socket events failed: {err}")),
        }
        if events.is_empty() {
            return;
        }
        // Look every socket up at once, so the table's lock is taken once.
        let ready: Vec<(Arc<IoState>, bool, bool)> = {
            let table = lock(&IO_TABLE);
            events
                .iter()
                .filter(|event| event.token() != WAKER_TOKEN)
                .filter_map(|event| {
                    let token = event.token().0;
                    let state = table.get(token & KEY_MASK)?;
                    (state.token == token).then(|| {
                        let readable = event.is_readable() || event.is_read_closed() || event.is_error();
                        let writable = event.is_writable() || event.is_write_closed() || event.is_error();
                        (state.clone(), readable, writable)
                    })
                })
                .collect()
        };
        drop(events);
        for (state, readable, writable) in ready {
            let woken: Vec<(Arc<Task>, u64)> = {
                let mut waiters = lock(&state.waiters);
                let mut woken = Vec::new();
                waiters.retain(|waiter| {
                    let hit = if waiter.writable { writable } else { readable };
                    if hit {
                        woken.push((waiter.task.clone(), waiter.wait));
                    }
                    !hit
                });
                woken
            };
            for (task, wait) in woken {
                wake(&task, wait, Woke::Ready);
            }
        }
    }

    fn fire_timers(&self) {
        let now = Instant::now();
        let due: Vec<(Arc<Task>, u64)> = {
            let mut timers = lock(&self.shared.timers);
            let mut due = Vec::new();
            while let Some(entry) = timers.first_entry() {
                if entry.key().0 > now {
                    break;
                }
                due.push(entry.remove());
            }
            due
        };
        for (task, wait) in due {
            wake(&task, wait, Woke::TimedOut);
        }
    }

    fn take_injected(&self) -> bool {
        if INJECT_LEN.load(Ordering::Acquire) == 0 {
            return false;
        }
        let mut inject = lock(&INJECT);
        let task = inject.pop_front();
        INJECT_LEN.store(inject.len(), Ordering::Release);
        drop(inject);
        let Some(task) = task else { return false };
        self.shared.push(task);
        true
    }

    /// Take half of the longest-looking other queue (at least one task).
    fn steal(&self) -> bool {
        let all = workers();
        let start = self.index() + 1;
        for offset in 0..all.len() {
            let Some(victim) = all[(start + offset) % all.len()].get() else { continue };
            if victim.index == self.index() || victim.queue_len.load(Ordering::Acquire) == 0 {
                continue;
            }
            let stolen: Vec<Arc<Task>> = {
                let mut queue = lock(&victim.queue);
                let take = queue.len().div_ceil(2);
                let stolen = queue.drain(..take).collect();
                victim.queue_len.store(queue.len(), Ordering::Release);
                stolen
            };
            if stolen.is_empty() {
                continue;
            }
            let mut queue = lock(&self.shared.queue);
            queue.extend(stolen);
            self.shared.queue_len.store(queue.len(), Ordering::Release);
            return true;
        }
        false
    }
}

// --- Thread-local access ---
//
// Never inlined: a task may resume on another thread, and code that looked a
// thread-local's address up before a call must not reuse it after (the
// compiler assumes a function stays on one thread). A fresh call looks it up
// again.

thread_local! {
    static WORKER: Cell<*const Worker> = const { Cell::new(std::ptr::null()) };
    /// The running task's yielder; null when no task is running.
    static YIELDER: Cell<*const Yielder<(), Suspend>> = const { Cell::new(std::ptr::null()) };
    static CURRENT_TASK: Cell<*const Task> = const { Cell::new(std::ptr::null()) };
    static OPS_LEFT: Cell<u32> = const { Cell::new(0) };
}

#[inline(never)]
fn set_worker(worker: *const Worker) {
    WORKER.set(worker);
}

#[inline(never)]
fn yielder() -> *const Yielder<(), Suspend> {
    YIELDER.get()
}

#[inline(never)]
fn set_yielder(yielder: *const Yielder<(), Suspend>) {
    YIELDER.set(yielder);
}

#[inline(never)]
fn set_current_task(task: *const Task) {
    CURRENT_TASK.set(task);
}

#[inline(never)]
fn set_ops_left(ops: u32) {
    OPS_LEFT.set(ops);
}

#[inline(never)]
fn take_op() -> bool {
    let left = OPS_LEFT.get();
    if left <= 1 {
        return false;
    }
    OPS_LEFT.set(left - 1);
    true
}

/// This thread's worker, if it is one (whether or not a task is running).
#[inline(never)]
fn this_worker() -> Option<&'static Worker> {
    let worker = WORKER.get();
    (!worker.is_null()).then(|| unsafe { &*worker })
}

/// This thread's worker, if a task is running on it.
#[inline(never)]
fn current_worker() -> Option<&'static Worker> {
    if YIELDER.get().is_null() {
        return None;
    }
    let worker = WORKER.get();
    (!worker.is_null()).then(|| unsafe { &*worker })
}

/// The running task, if any.
#[inline(never)]
fn current_task() -> Option<Arc<Task>> {
    if YIELDER.get().is_null() {
        return None;
    }
    let task = CURRENT_TASK.get();
    if task.is_null() {
        return None;
    }
    // A new reference to the task the worker holds while running it.
    unsafe {
        Arc::increment_strong_count(task);
        Some(Arc::from_raw(task))
    }
}

/// Hand control back to the worker; returns when the task is resumed,
/// possibly on another thread.
#[inline(never)]
fn suspend(why: Suspend) {
    let yielder = yielder();
    unsafe { (*yielder).suspend(why) };
    // Now on whichever thread resumed the task.
    set_yielder(yielder);
}

// --- Stacks ---

/// A stack not in use by any coroutine, so it can move between threads.
struct SendStack(DefaultStack);
unsafe impl Send for SendStack {}

static STACKS: Mutex<Vec<SendStack>> = Mutex::new(Vec::new());

fn take_stack() -> io::Result<DefaultStack> {
    if let Some(stack) = lock(&STACKS).pop() {
        return Ok(stack.0);
    }
    DefaultStack::new(crate::limits::task_stack_bytes())
}

fn recycle_stack(stack: DefaultStack) {
    let mut pool = lock(&STACKS);
    if pool.len() < MAX_POOLED_STACKS {
        pool.push(SendStack(stack));
    }
}

fn new_task(job: impl FnOnce() + Send + 'static, stack: DefaultStack, main: bool, handles: usize) -> Arc<Task> {
    let co = Coroutine::with_stack(stack, move |yielder, ()| {
        set_yielder(yielder);
        job();
    });
    Arc::new(Task {
        co: UnsafeCell::new(Some(co)),
        state: AtomicU8::new(NOTIFIED),
        wait: AtomicU64::new(0),
        woke: AtomicU8::new(Woke::Ready as u8),
        timer: UnsafeCell::new(None),
        main,
        cancelled: AtomicBool::new(false),
        cancellable: AtomicBool::new(false),
        finished: Mutex::new((false, Waiters::new())),
        result: Mutex::new(None),
        handles: AtomicUsize::new(handles),
    })
}

// --- Starting ---

/// Run `main` as the first task, with this thread as worker 0, until it
/// returns. Tasks still running then are abandoned (the process exits).
pub fn run_main(main: impl FnOnce() -> i32 + Send + 'static) -> i32 {
    let count = crate::limits::workers();
    let _ = WORKERS.set((0..count).map(|_| OnceLock::new()).collect());
    let (shared, poll) = new_shared(0).unwrap_or_else(|err| fatal(&format!("can't create an event queue: {err}")));
    let _ = workers()[0].set(shared.clone());
    let worker = Worker::install(shared, poll);

    // The main thread's usual stack size, since main! used to run on it.
    let stack = DefaultStack::new(8 * 1024 * 1024).unwrap_or_else(|err| fatal(&format!("can't allocate main!'s stack: {err}")));
    let task = new_task(move || *lock(&MAIN_RESULT) = Some(main()), stack, true, 0);
    worker.shared.push(task);
    worker.run();
    lock(&MAIN_RESULT).unwrap_or(1)
}

/// Start `job` as a new task, on this worker's queue (other workers steal it
/// if this one is busy). Fails, returning the job, if no stack can be
/// allocated for it. The task starts with one handle (see
/// [`TaskRef::add_handle`]), counted before it can finish.
pub fn spawn(job: Job) -> Result<TaskRef, (Job, io::Error)> {
    if WORKERS.get().is_none() {
        return Err((job, io::Error::other("the scheduler isn't running")));
    }
    let stack = match take_stack() {
        Ok(stack) => stack,
        Err(err) => return Err((job, err)),
    };
    let task = new_task(job, stack, false, 1);
    push(task.clone());
    Ok(TaskRef(task))
}

/// A task, for cancelling it or waiting for it to finish.
#[derive(Clone)]
pub struct TaskRef(Arc<Task>);

impl TaskRef {
    /// Ask the task to stop: its current wait, if cancellable, ends now, and
    /// every cancellable wait it starts from now on ends at once, with
    /// [`Woke::Cancelled`]. Cooperative: the task decides what to do about
    /// it (Roc code usually propagates the error, which unwinds the task).
    pub fn cancel(&self) {
        let task = &self.0;
        task.cancelled.store(true, Ordering::SeqCst);
        let wait = task.wait.load(Ordering::SeqCst);
        // A wait that starts after this sees `cancelled` (see `begin_wait`).
        if wait != 0 && task.cancellable.load(Ordering::SeqCst) {
            wake(task, wait, Woke::Cancelled);
        }
    }

    pub fn is_finished(&self) -> bool {
        lock(&self.0.finished).0
    }

    /// The running task.
    pub fn current() -> Option<TaskRef> {
        current_task().map(TaskRef)
    }

    pub fn drop_handle(&self) {
        self.0.handles.fetch_sub(1, Ordering::AcqRel);
    }

    pub fn has_handles(&self) -> bool {
        self.0.handles.load(Ordering::Acquire) > 0
    }

    pub fn set_result(&self, result: Box<dyn Any + Send>) {
        *lock(&self.0.result) = Some(result);
    }

    pub fn with_result<R>(&self, f: impl FnOnce(Option<&(dyn Any + Send)>) -> R) -> R {
        f(lock(&self.0.result).as_deref())
    }

    /// For `Select`: `None` if the task has finished; otherwise register
    /// `waker` for when it does, under the id returned (remove it with
    /// [`unwatch_finished`](Self::unwatch_finished)).
    pub fn watch_finished(&self, waker: &TaskWaker) -> Option<u64> {
        let mut finished = lock(&self.0.finished);
        if finished.0 {
            None
        } else {
            Some(finished.1.add_waker(waker.clone()))
        }
    }

    pub fn unwatch_finished(&self, id: u64) {
        lock(&self.0.finished).1.remove(id);
    }

    /// Wait for the task to finish. `cancellable: false` for waits that
    /// must complete even if the waiting task is cancelled (a scope waiting
    /// for its children).
    pub fn wait_finished(&self, cancellable: bool) -> Woke {
        let mut finished = lock(&self.0.finished);
        loop {
            if finished.0 {
                return Woke::Ready;
            }
            let id = if cancellable { finished.1.add() } else { finished.1.add_uncancellable() };
            drop(finished);
            let end = park(None);
            finished = lock(&self.0.finished);
            finished.1.remove(id);
            if end == Woke::Cancelled {
                return Woke::Cancelled;
            }
        }
    }
}

/// Whether the running task has been cancelled.
pub fn is_cancelled() -> bool {
    current_task().is_some_and(|task| task.cancelled.load(Ordering::SeqCst))
}

/// Let other tasks on this worker run, then continue.
pub fn yield_now() {
    if current_worker().is_some() {
        suspend(Suspend::Yield);
    }
}

// --- Waiting, from inside a task ---

pub fn timed_out() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "timed out")
}

/// Suspend the current task until woken (its wait id is already set) or
/// `deadline`.
fn wait_suspended(task: &Arc<Task>, wait: u64, deadline: Option<Instant>) -> Woke {
    let worker = current_worker().expect("a task is running");
    if let Some(at) = deadline {
        let key = (at, wait);
        lock(&worker.shared.timers).insert(key, (task.clone(), wait));
        unsafe { *task.timer.get() = Some((worker.index(), key)) };
    }
    suspend(Suspend::Wait);
    // Remove the timer if it didn't fire, from whichever worker holds it.
    if let Some((index, key)) = unsafe { (*task.timer.get()).take() } {
        if let Some(shared) = workers().get(index).and_then(OnceLock::get) {
            lock(&shared.timers).remove(&key);
        }
    }
    Woke::from_u8(task.woke.load(Ordering::Acquire))
}

/// Start a wait: give the current task a new wait id. A cancellable wait
/// of a task that's already cancelled ends at once (the wake-up is queued
/// before the task even suspends).
fn begin_wait(task: &Arc<Task>, cancellable: bool) -> u64 {
    let wait = new_wait_id();
    task.woke.store(Woke::Ready as u8, Ordering::Relaxed);
    task.cancellable.store(cancellable, Ordering::SeqCst);
    task.wait.store(wait, Ordering::SeqCst);
    // Pairs with `TaskRef::cancel`, which sets the flag before reading `wait`.
    if cancellable && task.cancelled.load(Ordering::SeqCst) {
        wake(task, wait, Woke::Cancelled);
    }
    wait
}

/// The error a cancelled I/O wait surfaces as.
#[derive(Debug)]
pub struct Cancelled;

impl std::fmt::Display for Cancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the task was cancelled")
    }
}

impl std::error::Error for Cancelled {}

pub fn cancelled() -> io::Error {
    io::Error::other(Cancelled)
}

pub fn is_cancelled_error(err: &io::Error) -> bool {
    err.get_ref().is_some_and(|inner| inner.is::<Cancelled>())
}

// --- Sockets ---

/// Sockets being waited on, by token. A token is the socket's key here plus a
/// generation, so an event that was already collected when its socket closed
/// can't be mistaken for a newer socket's.
static IO_TABLE: Mutex<Slab<Arc<IoState>>> = Mutex::new(Slab::new());
static IO_GENERATION: AtomicU64 = AtomicU64::new(1);
const KEY_BITS: u32 = 32;
const KEY_MASK: usize = (1 << KEY_BITS) - 1;

struct IoState {
    token: usize,
    fd: RawFd,
    /// The worker whose event queue watches this socket, plus one; 0: none.
    owner: AtomicUsize,
    waiters: Mutex<Vec<IoWaiter>>,
}

struct IoWaiter {
    task: Arc<Task>,
    wait: u64,
    writable: bool,
}

/// A socket's scheduling state: the tasks waiting on it, and which worker's
/// event queue watches it. Each socket has one. It must be dropped before the
/// socket closes, so the socket leaves the event queue first (closing a
/// descriptor that has a duplicate, as STARTTLS makes, wouldn't remove it).
#[derive(Default)]
pub struct IoReg(OnceLock<Arc<IoState>>);

impl IoReg {
    fn state(&self, fd: RawFd) -> &Arc<IoState> {
        self.0.get_or_init(|| {
            let mut table = lock(&IO_TABLE);
            let entry = table.vacant_entry();
            let generation = IO_GENERATION.fetch_add(1, Ordering::Relaxed) as usize;
            let token = entry.key() | (generation << KEY_BITS);
            let state = Arc::new(IoState { token, fd, owner: AtomicUsize::new(0), waiters: Mutex::new(Vec::new()) });
            entry.insert(state.clone());
            state
        })
    }
}

impl Drop for IoReg {
    fn drop(&mut self) {
        let Some(state) = self.0.get() else { return };
        let owner = state.owner.load(Ordering::Acquire);
        if let Some(shared) = owner.checked_sub(1).and_then(|index| workers().get(index)).and_then(OnceLock::get) {
            let _ = shared.registry.deregister(&mut SourceFd(&state.fd));
        }
        let mut table = lock(&IO_TABLE);
        let key = state.token & KEY_MASK;
        if table.get(key).is_some_and(|entry| entry.token == state.token) {
            table.remove(key);
        }
    }
}

/// Wait until `fd` is readable (or writable) or `deadline` passes. Call it
/// after an operation fails with `WouldBlock`, then retry the operation.
/// Wake-ups can be spurious; the retry sorts that out.
pub fn wait_io(fd: RawFd, reg: &IoReg, writable: bool, deadline: Option<Instant>) -> io::Result<()> {
    if deadline.is_some_and(|at| Instant::now() >= at) {
        return Err(timed_out());
    }
    let (Some(worker), Some(task)) = (current_worker(), current_task()) else {
        return wait_io_blocking(fd, writable, deadline);
    };
    let state = reg.state(fd).clone();
    let wait = begin_wait(&task, true);
    watch_io(worker, &state, &task, wait, writable)?;
    let woke = wait_suspended(&task, wait, deadline);
    // Gone already if an event woke it; still there if it didn't.
    lock(&state.waiters).retain(|waiter| waiter.wait != wait);
    match woke {
        Woke::Ready => Ok(()),
        Woke::TimedOut => Err(timed_out()),
        Woke::Cancelled => Err(cancelled()),
    }
}

/// Add the task's wait `wait` to the socket's waiters, and make sure an
/// event will come if the socket is (or becomes) ready: watch it from this
/// worker's event queue, unless another worker's queue watches it for
/// another waiting task, in which case re-arm it there. (Registering or
/// re-arming a socket reports readiness that's already there, so an event
/// that another worker handled just before this waiter was added isn't
/// lost.)
fn watch_io(worker: &Worker, state: &Arc<IoState>, task: &Arc<Task>, wait: u64, writable: bool) -> io::Result<()> {
    let fd = state.fd;
    let token = Token(state.token);
    let interest = Interest::READABLE | Interest::WRITABLE;
    let mut waiters = lock(&state.waiters);
    let owner = state.owner.load(Ordering::Acquire);
    let mine = worker.index() + 1;
    let other = owner.checked_sub(1).and_then(|index| workers().get(index)).and_then(OnceLock::get);
    waiters.push(IoWaiter { task: task.clone(), wait, writable });
    if owner == mine {
        // Events for it are handled by this thread, which can't handle any
        // until this task suspends.
        return Ok(());
    }
    if owner != 0 && waiters.len() > 1 {
        if let Some(other) = other {
            return other.registry.reregister(&mut SourceFd(&fd), token, interest);
        }
    }
    if let Some(old) = other {
        let _ = old.registry.deregister(&mut SourceFd(&fd));
    }
    let registered = match worker.shared.registry.register(&mut SourceFd(&fd), token, interest) {
        Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {
            worker.shared.registry.reregister(&mut SourceFd(&fd), token, interest)
        }
        result => result,
    };
    match registered {
        Ok(()) => {
            state.owner.store(mine, Ordering::Release);
            Ok(())
        }
        Err(err) => {
            state.owner.store(0, Ordering::Release);
            waiters.retain(|waiter| waiter.wait != wait);
            Err(err)
        }
    }
}

/// One wait on several sources at once (`Select`): the first to fire wins,
/// since a wake-up only counts for the wait it names and the wait id is
/// shared. Sockets are added with [`add_io`](MultiWait::add_io); other
/// sources (channels) register [`waker`](MultiWait::waker) themselves.
pub struct MultiWait {
    task: Arc<Task>,
    wait: u64,
    io: Vec<Arc<IoState>>,
}

/// Start a cancellable wait on several sources; `None` outside a task.
pub fn begin_multi_wait() -> Option<MultiWait> {
    current_worker()?;
    let task = current_task()?;
    let wait = begin_wait(&task, true);
    Some(MultiWait { task, wait, io: Vec::new() })
}

impl MultiWait {
    pub fn waker(&self) -> TaskWaker {
        TaskWaker(WakerKind::Task { task: self.task.clone(), wait: self.wait })
    }

    /// Also wake when `fd` becomes readable (or writable).
    pub fn add_io(&mut self, fd: RawFd, reg: &IoReg, writable: bool) -> io::Result<()> {
        let worker = current_worker().expect("a task is running");
        let state = reg.state(fd).clone();
        watch_io(worker, &state, &self.task, self.wait, writable)?;
        self.io.push(state);
        Ok(())
    }

    /// Suspend until a source fires, `deadline`, or cancellation.
    pub fn wait(self, deadline: Option<Instant>) -> Woke {
        let woke = wait_suspended(&self.task, self.wait, deadline);
        self.forget_io();
        woke
    }

    /// Give up the wait without suspending (a source was ready already):
    /// later wake-ups for it are ignored.
    pub fn abandon(self) {
        let _ = self.task.wait.compare_exchange(self.wait, 0, Ordering::AcqRel, Ordering::Acquire);
        self.forget_io();
    }

    fn forget_io(&self) {
        for state in &self.io {
            lock(&state.waiters).retain(|waiter| waiter.wait != self.wait);
        }
    }
}

/// `wait_io` for a plain thread: a throwaway event queue for this one wait.
fn wait_io_blocking(fd: RawFd, writable: bool, deadline: Option<Instant>) -> io::Result<()> {
    let mut poll = Poll::new()?;
    let interest = if writable { Interest::WRITABLE } else { Interest::READABLE };
    poll.registry().register(&mut SourceFd(&fd), Token(0), interest)?;
    let mut events = Events::with_capacity(4);
    loop {
        let timeout = deadline.map(|at| at.saturating_duration_since(Instant::now()).min(MAX_POLL_WAIT));
        match poll.poll(&mut events, timeout) {
            Ok(()) => {}
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
        if !events.is_empty() {
            return Ok(());
        }
        if deadline.is_some_and(|at| Instant::now() >= at) {
            return Err(timed_out());
        }
    }
}

/// Count an operation that completed without waiting, yielding to the
/// worker's other tasks once the task has done [`BUDGET`] of them in a row.
pub fn consume_budget() {
    if current_worker().is_none() {
        return;
    }
    if !take_op() {
        suspend(Suspend::Yield);
    }
}

/// Sleep for `duration`; `false` if the task was cancelled first.
pub fn sleep(duration: Duration) -> bool {
    let Some(task) = current_task() else {
        std::thread::sleep(duration);
        return true;
    };
    // Too far off to represent: that's forever.
    let deadline = Instant::now().checked_add(duration);
    // A task can be resumed early (a wake-up for an earlier wait arriving
    // late), so sleep until the deadline has really passed.
    loop {
        let wait = begin_wait(&task, true);
        match wait_suspended(&task, wait, deadline) {
            Woke::TimedOut => return true,
            Woke::Cancelled => return false,
            Woke::Ready => {}
        }
    }
}

/// Wakes one particular wait of a task (or a plain thread).
#[derive(Clone)]
pub struct TaskWaker(WakerKind);

#[derive(Clone)]
enum WakerKind {
    Task { task: Arc<Task>, wait: u64 },
    Thread(std::thread::Thread),
}

impl TaskWaker {
    /// Wake the wait this waker is for. Returns false if that wait had
    /// already ended, so the wake-up reached nobody.
    pub fn wake(self) -> bool {
        match self.0 {
            WakerKind::Task { task, wait } => wake(&task, wait, Woke::Ready),
            WakerKind::Thread(thread) => {
                thread.unpark();
                true
            }
        }
    }
}

/// A waker for the current task's next [`park`]. Starts the wait, so the
/// task must park next. The wait ends early if the task is cancelled.
pub fn waker() -> TaskWaker {
    new_waker(true)
}

/// Like [`waker`], for a wait cancelling mustn't end (such as for a lock the
/// task needs to make progress).
pub fn waker_uncancellable() -> TaskWaker {
    new_waker(false)
}

fn new_waker(cancellable: bool) -> TaskWaker {
    match current_task() {
        Some(task) => {
            let wait = begin_wait(&task, cancellable);
            TaskWaker(WakerKind::Task { task, wait })
        }
        None => TaskWaker(WakerKind::Thread(std::thread::current())),
    }
}

/// Wait until woken by the waker from [`waker`], until `deadline`, or until
/// the task is cancelled (if the wait is cancellable). May also return early
/// for no reason, so callers check their condition in a loop.
pub fn park(deadline: Option<Instant>) -> Woke {
    let Some(task) = current_task() else {
        match deadline {
            None => std::thread::park(),
            Some(at) => std::thread::park_timeout(at.saturating_duration_since(Instant::now())),
        }
        return Woke::Ready;
    };
    let wait = task.wait.load(Ordering::Acquire);
    if wait == 0 {
        // Already woken: say how.
        return Woke::from_u8(task.woke.load(Ordering::Acquire));
    }
    wait_suspended(&task, wait, deadline)
}

/// Tasks waiting for some condition, kept inside the state that condition is
/// about (under the same mutex), like a condition variable's queue:
///
/// ```ignore
/// loop {
///     if condition(&state) { break }
///     let id = state.waiters.add();
///     drop(state);
///     sched::park(deadline);
///     state = lock();
///     state.waiters.remove(id);
/// }
/// ```
///
/// A waiter woken by `wake_one` is no longer in the list, so it is the one
/// that must act on the notification; removing yourself after waking (found
/// or not) keeps the list to tasks that are really waiting, so `wake_one`
/// never spends a notification on one that has left.
#[derive(Default)]
pub struct Waiters {
    list: VecDeque<(u64, TaskWaker)>,
    next: u64,
}

impl Waiters {
    pub const fn new() -> Self {
        Waiters { list: VecDeque::new(), next: 0 }
    }

    /// Add the current task, starting a (cancellable) wait.
    pub fn add(&mut self) -> u64 {
        self.add_waker(waker())
    }

    /// Add the current task for a wait cancelling doesn't end.
    pub fn add_uncancellable(&mut self) -> u64 {
        self.add_waker(waker_uncancellable())
    }

    /// Add a waker for a wait already started, such as one of several
    /// sources a task waits on at once ([`MultiWait`]).
    pub fn add_waker(&mut self, waker: TaskWaker) -> u64 {
        self.next += 1;
        self.list.push_back((self.next, waker));
        self.next
    }

    pub fn remove(&mut self, id: u64) {
        self.list.retain(|(waiter, _)| *waiter != id);
    }

    /// Wake the first task that's still waiting. Entries whose wait already
    /// ended (a waiter cancelled or timed out, and not yet back to remove
    /// itself) are dropped on the way: spending the notification on one would
    /// leave a real waiter asleep.
    pub fn wake_one(&mut self) {
        while let Some((_, waker)) = self.list.pop_front() {
            if waker.wake() {
                return;
            }
        }
    }

    pub fn wake_all(&mut self) {
        for (_, waker) in self.list.drain(..) {
            waker.wake();
        }
    }
}

/// A mutual-exclusion lock that can be held across waits: a task waiting for
/// it suspends instead of blocking its worker's thread.
pub struct Lock {
    state: Mutex<(bool, Waiters)>,
}

pub struct LockGuard<'a>(&'a Lock);

impl Lock {
    pub const fn new() -> Self {
        Lock { state: Mutex::new((false, Waiters::new())) }
    }

    /// Whether some task holds the lock right now.
    pub fn is_locked(&self) -> bool {
        lock(&self.state).0
    }

    /// Take the lock if it's free, without waiting.
    pub fn try_lock(&self) -> Option<LockGuard<'_>> {
        let mut state = lock(&self.state);
        if state.0 {
            return None;
        }
        state.0 = true;
        Some(LockGuard(self))
    }

    pub fn lock(&self) -> LockGuard<'_> {
        let mut state = lock(&self.state);
        loop {
            if !state.0 {
                state.0 = true;
                return LockGuard(self);
            }
            // A task holding up others by being cancelled mid-lock would be
            // worse than finishing: lock waits aren't cancellable.
            let id = state.1.add_uncancellable();
            drop(state);
            park(None);
            state = lock(&self.state);
            state.1.remove(id);
        }
    }
}

impl Drop for LockGuard<'_> {
    fn drop(&mut self) {
        let mut state = lock(&self.0.state);
        state.0 = false;
        state.1.wake_one();
    }
}

/// At most this many helper threads (see [`blocking`]) at once, counting
/// ones still finishing work their caller stopped waiting for. It bounds
/// what slow name lookups (say, for hostnames an attacker supplies) can pile
/// up.
const MAX_BLOCKING_THREADS: usize = 64;

/// Helper threads in use, and tasks waiting for one.
static BLOCKING: Mutex<(usize, Waiters)> = Mutex::new((0, Waiters::new()));

/// A claimed helper-thread slot, given back when dropped.
struct BlockingSlot;

impl Drop for BlockingSlot {
    fn drop(&mut self) {
        let mut state = lock(&BLOCKING);
        state.0 -= 1;
        state.1.wake_one();
    }
}

/// Wait for a helper-thread slot until `deadline` (`Err(TimedOut)`) or the
/// task is cancelled (`Err(Cancelled)`).
fn claim_blocking_slot(deadline: Option<Instant>) -> Result<BlockingSlot, Woke> {
    let mut state = lock(&BLOCKING);
    loop {
        if state.0 < MAX_BLOCKING_THREADS {
            state.0 += 1;
            return Ok(BlockingSlot);
        }
        if deadline.is_some_and(|at| Instant::now() >= at) {
            return Err(Woke::TimedOut);
        }
        let id = state.1.add();
        drop(state);
        let end = park(deadline);
        state = lock(&BLOCKING);
        state.1.remove(id);
        if end == Woke::Cancelled {
            return Err(Woke::Cancelled);
        }
    }
}

/// Run `f` on a helper thread, which can block as long as it likes, and
/// wait for its result until `deadline`: `None` if it isn't done by then
/// (it finishes in the background, and its result is dropped). At most
/// [`MAX_BLOCKING_THREADS`] run at once; past that, callers wait for one to
/// finish, until their deadline. A cancelled task stops waiting with a
/// [`cancelled`] error. Outside a task, with no deadline, it just runs `f`.
pub fn blocking<R: Send + 'static>(
    deadline: Option<Instant>,
    f: impl FnOnce() -> R + Send + 'static,
) -> io::Result<Option<R>> {
    if deadline.is_none() && current_worker().is_none() {
        return Ok(Some(f()));
    }
    let slot = match claim_blocking_slot(deadline) {
        Ok(slot) => slot,
        Err(Woke::Cancelled) => return Err(cancelled()),
        Err(_) => return Ok(None),
    };
    let result: Arc<Mutex<(Option<R>, Waiters)>> = Arc::new(Mutex::new((None, Waiters::new())));
    let for_thread = result.clone();
    std::thread::Builder::new().name("roc-net-blocking".into()).spawn(move || {
        let _slot = slot;
        let value = f();
        let mut result = lock(&for_thread);
        result.0 = Some(value);
        result.1.wake_all();
    })?;
    let mut state = lock(&result);
    loop {
        if let Some(value) = state.0.take() {
            return Ok(Some(value));
        }
        if deadline.is_some_and(|at| Instant::now() >= at) {
            return Ok(None);
        }
        let id = state.1.add();
        drop(state);
        let end = park(deadline);
        state = lock(&result);
        state.1.remove(id);
        if end == Woke::Cancelled {
            return Err(cancelled());
        }
    }
}
