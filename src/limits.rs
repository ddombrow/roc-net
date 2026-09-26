//! Resource limits, configurable through environment variables at startup.

use std::sync::OnceLock;

/// `ROC_NET_MAX_TASKS`: how many tasks may run at once. Each task is an OS
/// thread, so the OS limit may be lower (6144 threads per process on macOS).
pub fn max_tasks() -> usize {
    static VALUE: OnceLock<usize> = OnceLock::new();
    *VALUE.get_or_init(|| from_env("ROC_NET_MAX_TASKS", 10_000, 1, usize::MAX))
}

/// `ROC_NET_MAX_SOCKETS`: how many sockets (listeners and streams) may be open.
pub fn max_sockets() -> usize {
    static VALUE: OnceLock<usize> = OnceLock::new();
    // Slot indexes use 16 bits of the handle token.
    *VALUE.get_or_init(|| from_env("ROC_NET_MAX_SOCKETS", 16_384, 1, 65_535))
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
