//! Tasks as coroutines on a few worker threads.
//!
//! Every task, `main!` included, runs on its own small stack (a corosensei
//! coroutine). Each worker thread runs many of them: when a task would block
//! (a socket that isn't ready, a sleep, an empty channel), the hosted function
//! suspends it and the worker runs another. Sockets are non-blocking; a
//! worker waits for readiness with one `mio::Poll` (epoll or kqueue) for all
//! of its tasks, so an idle connection costs a suspended stack, not a thread.
//!
//! Roc code doesn't change: a hosted function still returns only when its
//! operation is done. Suspending happens inside it, on the task's stack.
//!
//! - A task stays on the worker it started on, so thread-local state (such
//!   as the read scratch buffer) is safe to use between waits, never across
//!   one. Nothing may hold a `std::sync::Mutex` across a wait either: another
//!   task on the same worker taking it would block the whole thread. Code
//!   that must wait while holding a lock uses [`Lock`].
//! - New tasks are spread round-robin across workers, started on first use
//!   (`ROC_NET_WORKERS`, default one per CPU). `main!` runs on the main
//!   thread, which is worker 0.
//! - Scheduling is cooperative. A task yields when it waits, and also after
//!   [`BUDGET`] socket operations that didn't have to wait, so a task
//!   streaming data can't starve the others on its worker. Pure computation
//!   in Roc has no yield points.
//! - Wake-ups carry the id of the wait they're for, so a stale one (for a
//!   wait that already ended by timing out, say) is ignored.
//! - The same functions work outside a task (on a plain thread), by blocking
//!   that thread instead.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, VecDeque};
use std::io;
use std::os::fd::RawFd;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
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

/// Finished tasks' stacks kept for reuse, so spawning doesn't map a new one
/// each time.
const MAX_POOLED_STACKS: usize = 256;

const WAKER_TOKEN: Token = Token(usize::MAX);

const MAX_POLL_WAIT: Duration = Duration::from_secs(3600);

/// How often a worker updates its load measurement.
const LOAD_WINDOW: Duration = Duration::from_millis(5);

/// A worker running at least this much of the time hands new tasks to less
/// busy workers.
const BUSY_PERCENT: u32 = 50;

/// How many more tasks than an even share a worker keeps before handing new
/// ones to others, even when it isn't busy. Keeping tasks local avoids waking
/// another thread (the main cost of a hand-off); the cap keeps a burst of
/// connections, which arrives before the load measurement notices, from
/// landing on one worker for good (tasks don't move once started).
const LOCAL_SLACK: usize = 8;

pub type Job = Box<dyn FnOnce() + Send>;

/// Why a task suspended.
enum Wait {
    /// Until `fd` is readable (or writable), or the deadline.
    Io { fd: RawFd, writable: bool, deadline: Option<Instant> },
    Sleep(Instant),
    /// Until a [`TaskWaker`] wakes it, or the deadline.
    Park(Option<Instant>),
    /// Let other tasks run, then continue.
    Yield,
}

/// Why a task resumed.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Woke {
    Ready,
    TimedOut,
}

type Co = Coroutine<Woke, Wait, (), DefaultStack>;

thread_local! {
    /// This thread's worker, if it is one.
    static WORKER: Cell<*const Worker> = const { Cell::new(std::ptr::null()) };
    /// The running task's yielder; null when no task is running.
    static YIELDER: Cell<*const Yielder<Woke, Wait>> = const { Cell::new(std::ptr::null()) };
    static OPS_LEFT: Cell<u32> = const { Cell::new(0) };
}

// --- Workers ---

enum Msg {
    Spawn(Job, SendStack),
    Wake { task: usize, wait: u64 },
}

/// The part of a worker other threads use to reach it.
pub struct Shared {
    inbox: Mutex<Vec<Msg>>,
    waker: Waker,
    /// Set while the worker is (about to be) blocked in `poll`, so senders
    /// know to wake it; skipping that syscall otherwise matters for
    /// ping-pong traffic.
    sleeping: AtomicBool,
    /// Percentage of recent time spent running (not waiting in `poll`),
    /// measured over windows of [`LOAD_WINDOW`], for choosing where new
    /// tasks go.
    load: AtomicU32,
    /// Tasks on this worker, started or not.
    tasks: AtomicUsize,
}

impl Shared {
    fn new(waker: Waker) -> Arc<Shared> {
        Arc::new(Shared {
            inbox: Mutex::new(Vec::new()),
            waker,
            sleeping: AtomicBool::new(false),
            load: AtomicU32::new(0),
            tasks: AtomicUsize::new(0),
        })
    }

    /// Too busy to take new tasks when others could: running most of the
    /// time. A worker asleep in `poll` isn't busy, whatever its last
    /// measurement said.
    fn busy(&self) -> bool {
        self.load.load(Ordering::Relaxed) >= BUSY_PERCENT && !self.sleeping.load(Ordering::Relaxed)
    }

    fn send(&self, msg: Msg) {
        lock(&self.inbox).push(msg);
        if self.sleeping.swap(false, Ordering::SeqCst) {
            let _ = self.waker.wake();
        }
    }
}

struct TaskEntry {
    /// Taken out while the task runs.
    co: Option<Co>,
    /// The id of the wait the task is suspended in; 0 when it isn't waiting.
    wait: u64,
    /// The id a [`TaskWaker`] was handed out for, for the next park.
    next_park: u64,
    /// The descriptor it waits on, and its timer, so waking removes both.
    fd: Option<RawFd>,
    timer: Option<(Instant, u64)>,
}

struct IoWaiter {
    task: usize,
    wait: u64,
    writable: bool,
}

struct Worker {
    index: usize,
    shared: Arc<Shared>,
    poll: RefCell<Poll>,
    registry: Registry,
    tasks: RefCell<Slab<TaskEntry>>,
    ready: RefCell<VecDeque<(usize, Woke)>>,
    /// Tasks waiting on each file descriptor, indexed by descriptor.
    io_waiters: RefCell<Vec<Vec<IoWaiter>>>,
    timers: RefCell<BTreeMap<(Instant, u64), usize>>,
    next_wait: Cell<u64>,
    current: Cell<Option<usize>>,
    woken: RefCell<Vec<(usize, u64)>>,
}

static WORKERS: OnceLock<Vec<OnceLock<Arc<Shared>>>> = OnceLock::new();
static NEXT_WORKER: AtomicUsize = AtomicUsize::new(0);

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn new_poll() -> (Poll, Waker) {
    let poll = Poll::new().unwrap_or_else(|err| fatal(&format!("can't create an event queue: {err}")));
    let waker = Waker::new(poll.registry(), WAKER_TOKEN)
        .unwrap_or_else(|err| fatal(&format!("can't create an event queue waker: {err}")));
    (poll, waker)
}

fn fatal(message: &str) -> ! {
    eprintln!("roc-net: {message}");
    std::process::exit(1);
}

/// The worker at `index`, starting its thread if it hasn't started yet;
/// `None` if the OS won't start another thread.
fn worker_shared(index: usize) -> Option<&'static Arc<Shared>> {
    static STARTING: Mutex<()> = Mutex::new(());
    let workers = WORKERS.get()?;
    if let Some(shared) = workers[index].get() {
        return Some(shared);
    }
    let _starting = lock(&STARTING);
    if let Some(shared) = workers[index].get() {
        return Some(shared);
    }
    // Out of file descriptors, say.
    let queue = Poll::new().and_then(|poll| {
        let waker = Waker::new(poll.registry(), WAKER_TOKEN)?;
        let registry = poll.registry().try_clone()?;
        Ok((poll, waker, registry))
    });
    let (poll, waker, registry) = match queue {
        Ok(queue) => queue,
        Err(err) => {
            warn_worker_start(index, &err);
            return None;
        }
    };
    let shared = Shared::new(waker);
    let for_thread = shared.clone();
    let started = std::thread::Builder::new().name(format!("roc-net-worker-{index}")).spawn(move || {
        let worker = Worker::install(index, for_thread, poll, registry);
        worker.run(|| false);
    });
    if let Err(err) = started {
        warn_worker_start(index, &err);
        return None;
    }
    let _ = workers[index].set(shared);
    workers[index].get()
}

/// Warn once that a worker thread couldn't start; tasks go to the workers
/// already running instead.
fn warn_worker_start(index: usize, err: &io::Error) {
    static WARNED: AtomicBool = AtomicBool::new(false);
    if !WARNED.swap(true, Ordering::Relaxed) {
        eprintln!("roc-net: can't start worker thread {index} ({err}); running tasks on the workers already started");
    }
}

impl Worker {
    /// Create this thread's worker. It's leaked: it lives as long as the
    /// process, and a suspended coroutine must never be dropped (that
    /// unwinds its stack, which `panic = "abort"` turns into an abort).
    fn install(index: usize, shared: Arc<Shared>, poll: Poll, registry: Registry) -> &'static Worker {
        let worker: &'static Worker = Box::leak(Box::new(Worker {
            index,
            shared,
            poll: RefCell::new(poll),
            registry,
            tasks: RefCell::new(Slab::new()),
            ready: RefCell::new(VecDeque::new()),
            io_waiters: RefCell::new(Vec::new()),
            timers: RefCell::new(BTreeMap::new()),
            next_wait: Cell::new(1),
            current: Cell::new(None),
            woken: RefCell::new(Vec::new()),
        }));
        WORKER.set(worker);
        worker
    }

    fn add_task(&self, co: Co) {
        self.shared.tasks.fetch_add(1, Ordering::Relaxed);
        let id = self.tasks.borrow_mut().insert(TaskEntry { co: Some(co), wait: 0, next_park: 0, fd: None, timer: None });
        self.ready.borrow_mut().push_back((id, Woke::Ready));
    }

    fn new_wait_id(&self) -> u64 {
        let id = self.next_wait.get();
        self.next_wait.set(id + 1);
        id
    }

    /// Run tasks until `done()` says to stop (checked after each round).
    fn run(&self, done: impl Fn() -> bool) {
        let mut events = Events::with_capacity(1024);
        let mut window_start = Instant::now();
        let mut busy = Duration::ZERO;
        let mut awake_since = window_start;
        loop {
            self.drain_inbox();
            let round = self.ready.borrow().len();
            for _ in 0..round {
                let Some((id, woke)) = self.ready.borrow_mut().pop_front() else { break };
                self.resume(id, woke);
            }
            if done() {
                return;
            }

            let mut timeout = if !self.ready.borrow().is_empty() {
                Some(Duration::ZERO)
            } else {
                let now = Instant::now();
                // Capped: kqueue rejects very long timeouts (EINVAL), and
                // waking once an hour to re-check costs nothing.
                self.timers
                    .borrow()
                    .first_key_value()
                    .map(|((at, _), _)| at.saturating_duration_since(now).min(MAX_POLL_WAIT))
            };
            let sleeping = timeout != Some(Duration::ZERO);
            if sleeping {
                self.shared.sleeping.store(true, Ordering::SeqCst);
                if !lock(&self.shared.inbox).is_empty() {
                    timeout = Some(Duration::ZERO);
                }
            }
            let before_poll = Instant::now();
            busy += before_poll - awake_since;
            let elapsed = before_poll - window_start;
            if elapsed >= LOAD_WINDOW {
                let percent = (busy.as_nanos() * 100 / elapsed.as_nanos().max(1)) as u32;
                self.shared.load.store(percent, Ordering::Relaxed);
                window_start = before_poll;
                busy = Duration::ZERO;
            }
            let polled = self.poll.borrow_mut().poll(&mut events, timeout);
            awake_since = Instant::now();
            if sleeping {
                self.shared.sleeping.store(false, Ordering::SeqCst);
            }
            match polled {
                Ok(()) => {}
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(err) => fatal(&format!("waiting for socket events failed: {err}")),
            }
            for event in events.iter() {
                if event.token() == WAKER_TOKEN {
                    continue;
                }
                let readable = event.is_readable() || event.is_read_closed() || event.is_error();
                let writable = event.is_writable() || event.is_write_closed() || event.is_error();
                self.io_ready(event.token().0 as RawFd, readable, writable);
            }
            self.fire_timers();
        }
    }

    fn drain_inbox(&self) {
        let messages = std::mem::take(&mut *lock(&self.shared.inbox));
        for msg in messages {
            match msg {
                Msg::Spawn(job, stack) => self.add_task(new_task(job, stack.0)),
                Msg::Wake { task, wait } => self.wake(task, wait, Woke::Ready),
            }
        }
    }

    fn resume(&self, id: usize, woke: Woke) {
        let Some(mut co) = self.tasks.borrow_mut().get_mut(id).and_then(|task| task.co.take()) else { return };
        self.current.set(Some(id));
        OPS_LEFT.set(BUDGET);
        // Roc runs here, and may call back into this worker through `WORKER`;
        // no RefCell borrow is held across it.
        let result = co.resume(woke);
        YIELDER.set(std::ptr::null());
        self.current.set(None);
        match result {
            CoroutineResult::Yield(wait) => {
                self.tasks.borrow_mut()[id].co = Some(co);
                self.suspended(id, wait);
            }
            CoroutineResult::Return(()) => {
                self.tasks.borrow_mut().remove(id);
                self.shared.tasks.fetch_sub(1, Ordering::Relaxed);
                recycle_stack(co.into_stack());
            }
        }
    }

    /// Record what a task that just suspended is waiting for.
    fn suspended(&self, id: usize, wait: Wait) {
        let mut tasks = self.tasks.borrow_mut();
        let task = &mut tasks[id];
        let wait_id = match wait {
            Wait::Park(_) if task.next_park != 0 => task.next_park,
            _ => self.new_wait_id(),
        };
        task.wait = wait_id;
        let deadline = match wait {
            Wait::Io { fd, writable, deadline } => {
                let mut waiters = self.io_waiters.borrow_mut();
                let index = fd as usize;
                if waiters.len() <= index {
                    waiters.resize_with(index + 1, Vec::new);
                }
                waiters[index].push(IoWaiter { task: id, wait: wait_id, writable });
                task.fd = Some(fd);
                deadline
            }
            Wait::Sleep(at) => Some(at),
            Wait::Park(deadline) => deadline,
            Wait::Yield => {
                task.wait = 0;
                self.ready.borrow_mut().push_back((id, Woke::Ready));
                None
            }
        };
        if let Some(at) = deadline {
            self.timers.borrow_mut().insert((at, wait_id), id);
            task.timer = Some((at, wait_id));
        }
    }

    /// End a task's wait, if it's still in the wait `wait_id`.
    fn wake(&self, id: usize, wait_id: u64, woke: Woke) {
        let mut tasks = self.tasks.borrow_mut();
        let Some(task) = tasks.get_mut(id) else { return };
        if task.wait == 0 || task.wait != wait_id {
            return;
        }
        task.wait = 0;
        task.next_park = 0;
        if let Some(key) = task.timer.take() {
            self.timers.borrow_mut().remove(&key);
        }
        if let Some(fd) = task.fd.take() {
            if let Some(list) = self.io_waiters.borrow_mut().get_mut(fd as usize) {
                list.retain(|waiter| waiter.wait != wait_id);
            }
        }
        self.ready.borrow_mut().push_back((id, woke));
    }

    fn io_ready(&self, fd: RawFd, readable: bool, writable: bool) {
        let mut woken = std::mem::take(&mut *self.woken.borrow_mut());
        if let Some(list) = self.io_waiters.borrow_mut().get_mut(fd as usize) {
            list.retain(|waiter| {
                let hit = if waiter.writable { writable } else { readable };
                if hit {
                    woken.push((waiter.task, waiter.wait));
                }
                !hit
            });
        }
        for (task, wait) in woken.drain(..) {
            self.wake(task, wait, Woke::Ready);
        }
        *self.woken.borrow_mut() = woken;
    }

    fn fire_timers(&self) {
        let now = Instant::now();
        loop {
            let due = {
                let mut timers = self.timers.borrow_mut();
                match timers.first_key_value() {
                    Some((&(at, wait), &task)) if at <= now => {
                        timers.remove(&(at, wait));
                        Some((task, wait))
                    }
                    _ => None,
                }
            };
            let Some((task, wait)) = due else { return };
            self.wake(task, wait, Woke::TimedOut);
        }
    }
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

// --- Starting ---

/// Run `main` as the first task, with this thread as worker 0, until it
/// returns. Tasks still running then are abandoned (the process exits).
pub fn run_main(main: impl FnOnce() -> i32 + 'static) -> i32 {
    let workers = crate::limits::workers();
    let _ = WORKERS.set((0..workers).map(|_| OnceLock::new()).collect());
    let (poll, waker) = new_poll();
    let shared = Shared::new(waker);
    let _ = WORKERS.get().expect("just set")[0].set(shared.clone());
    let registry = poll.registry().try_clone().unwrap_or_else(|err| fatal(&format!("can't create an event queue: {err}")));
    let worker = Worker::install(0, shared, poll, registry);

    // The main thread's usual stack size, since main! used to run on it.
    let stack = DefaultStack::new(8 * 1024 * 1024).unwrap_or_else(|err| fatal(&format!("can't allocate main!'s stack: {err}")));
    let result = Rc::new(Cell::new(None));
    let set_result = result.clone();
    worker.add_task(Coroutine::with_stack(stack, move |yielder, _: Woke| {
        YIELDER.set(yielder);
        set_result.set(Some(main()));
    }));
    worker.run(|| result.get().is_some());
    result.get().unwrap_or(1)
}

/// Start `job` as a new task. Fails, returning the job, if no stack can be
/// allocated for it.
///
/// It runs on the current worker unless that one is busy or has more than
/// its share of tasks (see [`LOCAL_SLACK`]); then on the worker best placed
/// to take it: not busy, already awake (so no thread needs waking), with the
/// fewest tasks. A worker that hasn't started yet counts as asleep and empty.
pub fn spawn(job: Job) -> Result<(), (Job, io::Error)> {
    let stack = match take_stack() {
        Ok(stack) => stack,
        Err(err) => return Err((job, err)),
    };
    let Some(workers) = WORKERS.get() else {
        return Err((job, io::Error::other("the scheduler isn't running")));
    };
    let local = current_worker();
    let total: usize = workers.iter().filter_map(OnceLock::get).map(|w| w.tasks.load(Ordering::Relaxed)).sum();
    if let Some(worker) = local {
        let share = total / workers.len() + LOCAL_SLACK;
        if !worker.shared.busy() && worker.shared.tasks.load(Ordering::Relaxed) <= share {
            worker.add_task(new_task(job, stack));
            return Ok(());
        }
    }
    let score = |index: usize| match workers[index].get() {
        Some(w) => (w.busy(), w.sleeping.load(Ordering::Relaxed), w.tasks.load(Ordering::Relaxed)),
        None => (false, true, 0),
    };
    // Start the scan at a rotating point so ties don't all go to worker 0.
    let start = NEXT_WORKER.fetch_add(1, Ordering::Relaxed);
    let target = (0..workers.len())
        .map(|i| (start + i) % workers.len())
        .filter(|&i| local.is_none_or(|w| w.index != i))
        .min_by_key(|&i| score(i))
        .unwrap_or(0);
    let msg = Msg::Spawn(job, SendStack(stack));
    match worker_shared(target) {
        Some(shared) => shared.send(msg),
        // That worker's thread wouldn't start: this one, or else worker 0,
        // which is always running (it's the main thread).
        None => match local {
            Some(worker) => worker.shared.send(msg),
            None => workers[0].get().expect("worker 0 runs main!").send(msg),
        },
    }
    Ok(())
}

fn new_task(job: Job, stack: DefaultStack) -> Co {
    Coroutine::with_stack(stack, move |yielder, _: Woke| {
        YIELDER.set(yielder);
        job();
    })
}

// --- Waiting, from inside a task ---

fn current_worker() -> Option<&'static Worker> {
    if YIELDER.get().is_null() {
        return None;
    }
    let worker = WORKER.get();
    (!worker.is_null()).then(|| unsafe { &*worker })
}

fn suspend(wait: Wait) -> Woke {
    let yielder = YIELDER.get();
    let woke = unsafe { (*yielder).suspend(wait) };
    YIELDER.set(yielder);
    woke
}

pub fn timed_out() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "timed out")
}

/// Which workers' event queues a socket is registered with, one bit per
/// worker. Each socket has one; registration lasts until the socket closes.
#[derive(Default)]
pub struct IoReg(AtomicU64);

/// Wait until `fd` is readable (or writable) or `deadline` passes. Call it
/// after an operation fails with `WouldBlock`, then retry the operation.
/// Wake-ups can be spurious; the retry sorts that out.
pub fn wait_io(fd: RawFd, reg: &IoReg, writable: bool, deadline: Option<Instant>) -> io::Result<()> {
    if deadline.is_some_and(|at| Instant::now() >= at) {
        return Err(timed_out());
    }
    let Some(worker) = current_worker() else {
        return wait_io_blocking(fd, writable, deadline);
    };
    let bit = 1u64 << worker.index;
    if reg.0.load(Ordering::Acquire) & bit == 0 {
        let interest = Interest::READABLE | Interest::WRITABLE;
        let token = Token(fd as usize);
        match worker.registry.register(&mut SourceFd(&fd), token, interest) {
            Ok(()) => {}
            // Registered under a descriptor that was closed while a duplicate
            // stayed open; take the registration over.
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {
                worker.registry.reregister(&mut SourceFd(&fd), token, interest)?
            }
            Err(err) => return Err(err),
        }
        reg.0.fetch_or(bit, Ordering::AcqRel);
    }
    match suspend(Wait::Io { fd, writable, deadline }) {
        Woke::Ready => Ok(()),
        Woke::TimedOut => Err(timed_out()),
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
    let left = OPS_LEFT.get();
    if left <= 1 {
        suspend(Wait::Yield);
    } else {
        OPS_LEFT.set(left - 1);
    }
}

pub fn sleep(duration: Duration) {
    if current_worker().is_none() {
        std::thread::sleep(duration);
        return;
    }
    match Instant::now().checked_add(duration) {
        Some(at) => suspend(Wait::Sleep(at)),
        // Too far off to represent: that's forever.
        None => suspend(Wait::Park(None)),
    };
}

/// Wakes one particular wait of a task (or a plain thread).
pub enum TaskWaker {
    Task { worker: Arc<Shared>, task: usize, wait: u64 },
    Thread(std::thread::Thread),
}

impl TaskWaker {
    pub fn wake(self) {
        match self {
            TaskWaker::Task { worker, task, wait } => worker.send(Msg::Wake { task, wait }),
            TaskWaker::Thread(thread) => thread.unpark(),
        }
    }
}

/// A waker for the current task's next [`park`].
pub fn waker() -> TaskWaker {
    let Some(worker) = current_worker() else {
        return TaskWaker::Thread(std::thread::current());
    };
    let task = worker.current.get().expect("a task is running");
    let wait = worker.new_wait_id();
    worker.tasks.borrow_mut()[task].next_park = wait;
    TaskWaker::Task { worker: worker.shared.clone(), task, wait }
}

/// Wait until woken by the waker from [`waker`] or until `deadline`. May also
/// return early for no reason, so callers check their condition in a loop.
pub fn park(deadline: Option<Instant>) {
    if current_worker().is_some() {
        suspend(Wait::Park(deadline));
        return;
    }
    match deadline {
        None => std::thread::park(),
        Some(at) => std::thread::park_timeout(at.saturating_duration_since(Instant::now())),
    }
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

    pub fn add(&mut self) -> u64 {
        self.next += 1;
        self.list.push_back((self.next, waker()));
        self.next
    }

    pub fn remove(&mut self, id: u64) {
        self.list.retain(|(waiter, _)| *waiter != id);
    }

    pub fn wake_one(&mut self) {
        if let Some((_, waker)) = self.list.pop_front() {
            waker.wake();
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
            let id = state.1.add();
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

/// Wait for a helper-thread slot until `deadline`.
fn claim_blocking_slot(deadline: Option<Instant>) -> Option<BlockingSlot> {
    let mut state = lock(&BLOCKING);
    loop {
        if state.0 < MAX_BLOCKING_THREADS {
            state.0 += 1;
            return Some(BlockingSlot);
        }
        if deadline.is_some_and(|at| Instant::now() >= at) {
            return None;
        }
        let id = state.1.add();
        drop(state);
        park(deadline);
        state = lock(&BLOCKING);
        state.1.remove(id);
    }
}

/// Run `f` on a helper thread, which can block as long as it likes, and
/// wait for its result until `deadline`: `None` if it isn't done by then
/// (it finishes in the background, and its result is dropped). At most
/// [`MAX_BLOCKING_THREADS`] run at once; past that, callers wait for one to
/// finish, until their deadline. Outside a task, with no deadline, it just
/// runs `f`.
pub fn blocking<R: Send + 'static>(
    deadline: Option<Instant>,
    f: impl FnOnce() -> R + Send + 'static,
) -> io::Result<Option<R>> {
    if deadline.is_none() && current_worker().is_none() {
        return Ok(Some(f()));
    }
    let Some(slot) = claim_blocking_slot(deadline) else {
        return Ok(None);
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
        park(deadline);
        state = lock(&result);
        state.1.remove(id);
    }
}
