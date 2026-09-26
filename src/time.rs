//! Monotonic time and sleeping.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

fn start() -> Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    *START.get_or_init(Instant::now)
}

/// Fix the clock's zero point; called once at startup.
pub fn init() {
    start();
}

/// Hosted function: Host.time_now_ns!
#[no_mangle]
pub extern "C" fn roc_time_now_ns() -> u64 {
    // u64 nanoseconds last about 584 years of uptime.
    start().elapsed().as_nanos() as u64
}

/// Hosted function: Host.time_sleep_ns!
#[no_mangle]
pub extern "C" fn roc_time_sleep_ns(ns: u64) {
    std::thread::sleep(Duration::from_nanos(ns));
}
