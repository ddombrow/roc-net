//! Resource limits, configurable through environment variables at startup.

use std::sync::OnceLock;

/// `ROC_NET_MAX_TASKS`: how many tasks may run at once. Each task has its
/// own stack (see `task_stack_bytes`); on Linux each stack is two memory
/// mappings, and the default `vm.max_map_count` (65,530) caps a process at
/// roughly 30,000 tasks unless it's raised.
pub fn max_tasks() -> usize {
    static VALUE: OnceLock<usize> = OnceLock::new();
    *VALUE.get_or_init(|| from_env("ROC_NET_MAX_TASKS", 100_000, 1, usize::MAX))
}

/// `ROC_NET_WORKERS`: how many threads run tasks. Defaults to one per CPU.
pub fn workers() -> usize {
    static VALUE: OnceLock<usize> = OnceLock::new();
    *VALUE.get_or_init(|| {
        let cpus = std::thread::available_parallelism().map_or(1, |n| n.get()).min(64);
        // At most 64: sockets track which workers watch them in a 64-bit mask.
        from_env("ROC_NET_WORKERS", cpus, 1, 64)
    })
}

/// `ROC_NET_TASK_STACK_KIB`: each task's stack size. Memory is only used as
/// the stack grows into it; this is the most a task can use (deep recursion
/// past it crashes the program). `main!` gets 8 MiB, like a main thread.
pub fn task_stack_bytes() -> usize {
    static VALUE: OnceLock<usize> = OnceLock::new();
    *VALUE.get_or_init(|| from_env("ROC_NET_TASK_STACK_KIB", 256, 64, 1024 * 1024) * 1024)
}

/// `ROC_NET_MAX_SOCKETS`: how many sockets (listeners and streams) may be open.
pub fn max_sockets() -> usize {
    static VALUE: OnceLock<usize> = OnceLock::new();
    // Slot indexes use 16 bits of the handle token.
    *VALUE.get_or_init(|| from_env("ROC_NET_MAX_SOCKETS", 16_384, 1, 65_535))
}

/// `ROC_NET_MAX_CHANNELS`: how many channels may exist at once.
pub fn max_channels() -> usize {
    static VALUE: OnceLock<usize> = OnceLock::new();
    // Each channel uses two handle slots (sender, receiver), and slot indexes
    // use 16 bits of the handle token.
    *VALUE.get_or_init(|| from_env("ROC_NET_MAX_CHANNELS", 8_192, 1, 32_767))
}

fn from_env(name: &str, default: usize, min: usize, max: usize) -> usize {
    let Ok(raw) = std::env::var(name) else {
        return default;
    };
    match raw.trim().parse::<usize>() {
        Ok(value) if (min..=max).contains(&value) => value,
        _ => {
            let range = if max == usize::MAX {
                format!("a number of at least {min}")
            } else {
                format!("a number from {min} to {max}")
            };
            eprintln!("roc-net: ignoring {name}={raw:?}; expected {range}. Using {default}.");
            default
        }
    }
}
