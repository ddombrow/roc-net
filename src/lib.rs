//! Roc platform host implementation for Roc's symbol-based host ABI.
//!
//! This host provides memory management and I/O effects for Roc programs.

use std::ffi::c_void;
use std::io::{self, BufRead, Write};
use std::mem::ManuallyDrop;

mod limits;
mod resource;
mod roc_platform_abi;
mod sockets;
mod tasks;
mod time;
mod net;

use crate::roc_platform_abi::{
    make_roc_host, roc_main, DefaultAllocators, DefaultHandlers, HostStderrLineResult,
    HostStderrLineResultPayload, HostStderrLineResultTag, HostStdinLineResult,
    HostStdinLineResultPayload, HostStdinLineResultTag, HostStdoutLineResult,
    HostStdoutLineResultPayload, HostStdoutLineResultTag, RocHost, RocList, RocStr,
};

/// Flush generated instructions from the AArch64 caches.
///
/// TODO: Remove this compatibility symbol once Roc ships the upstream fix.
/// Tracking: https://github.com/lukewilliamboswell/roc-platform-template-rust/issues/11
/// Upstream: https://github.com/roc-lang/roc/issues/11161
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
#[no_mangle]
pub unsafe extern "C" fn __clear_cache(begin: *mut c_void, end: *mut c_void) {
    use core::arch::asm;

    let begin = begin as usize;
    let end = end as usize;
    let cache_type: usize;

    asm!(
        "mrs {cache_type}, ctr_el0",
        cache_type = out(reg) cache_type,
        options(nomem, nostack, preserves_flags),
    );

    // IDC means instruction-to-data cache coherency does not require explicit
    // data-cache cleaning to the point of unification.
    if cache_type & (1 << 28) == 0 {
        let data_cache_line_size = 4 << ((cache_type >> 16) & 0xf);
        let mut address = begin & !(data_cache_line_size - 1);

        while address < end {
            asm!(
                "dc cvau, {address}",
                address = in(reg) address,
                options(nostack, preserves_flags),
            );
            address += data_cache_line_size;
        }
    }

    asm!("dsb ish", options(nostack, preserves_flags));

    // DIC means data-to-instruction cache coherency does not require explicit
    // instruction-cache invalidation to the point of unification.
    if cache_type & (1 << 29) == 0 {
        let instruction_cache_line_size = 4 << (cache_type & 0xf);
        let mut address = begin & !(instruction_cache_line_size - 1);

        while address < end {
            asm!(
                "ic ivau, {address}",
                address = in(reg) address,
                options(nostack, preserves_flags),
            );
            address += instruction_cache_line_size;
        }
    }

    asm!("dsb ish", "isb", options(nostack, preserves_flags));
}

static mut ROC_HOST: *mut RocHost = core::ptr::null_mut();

fn set_roc_host(roc_host: *mut RocHost) {
    unsafe {
        ROC_HOST = roc_host;
    }
}

fn roc_host_ptr() -> *mut RocHost {
    unsafe {
        if ROC_HOST.is_null() {
            eprintln!("roc host error: RocHost not initialized");
            std::process::exit(1);
        }
        ROC_HOST
    }
}

pub(crate) fn roc_host() -> &'static RocHost {
    unsafe { &*roc_host_ptr() }
}

fn unit_ok_payload() -> [u8; 0] {
    []
}

fn err_str(err: impl std::fmt::Display) -> ManuallyDrop<RocStr> {
    ManuallyDrop::new(RocStr::from_str(&err.to_string(), roc_host()))
}

/// Hosted function: Host.stderr_line!
#[no_mangle]
pub extern "C" fn roc_stderr_line(message: RocStr) -> HostStderrLineResult {
    let result = writeln!(io::stderr(), "{}", message.as_str());
    unsafe { message.decref(roc_host()) };

    match result {
        Ok(()) => HostStderrLineResult {
            payload: HostStderrLineResultPayload {
                ok: unit_ok_payload(),
            },
            tag: HostStderrLineResultTag::Ok,
        },
        Err(err) => HostStderrLineResult {
            payload: HostStderrLineResultPayload { err: err_str(err) },
            tag: HostStderrLineResultTag::Err,
        },
    }
}

/// Hosted function: Host.stdin_line!
#[no_mangle]
pub extern "C" fn roc_stdin_line() -> HostStdinLineResult {
    let stdin = io::stdin();
    let mut line = String::new();

    match stdin.lock().read_line(&mut line) {
        Ok(_) => {
            let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
            HostStdinLineResult {
                payload: HostStdinLineResultPayload {
                    ok: ManuallyDrop::new(RocStr::from_str(trimmed, roc_host())),
                },
                tag: HostStdinLineResultTag::Ok,
            }
        }
        Err(err) => HostStdinLineResult {
            payload: HostStdinLineResultPayload { err: err_str(err) },
            tag: HostStdinLineResultTag::Err,
        },
    }
}

/// Hosted function: Host.stdout_line!
#[no_mangle]
pub extern "C" fn roc_stdout_line(message: RocStr) -> HostStdoutLineResult {
    let result = writeln!(io::stdout(), "{}", message.as_str());
    unsafe { message.decref(roc_host()) };

    match result {
        Ok(()) => HostStdoutLineResult {
            payload: HostStdoutLineResultPayload {
                ok: unit_ok_payload(),
            },
            tag: HostStdoutLineResultTag::Ok,
        },
        Err(err) => HostStdoutLineResult {
            payload: HostStdoutLineResultPayload { err: err_str(err) },
            tag: HostStdoutLineResultTag::Err,
        },
    }
}

#[no_mangle]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> *mut c_void {
    DefaultAllocators::roc_alloc(roc_host_ptr(), length, alignment)
}

#[no_mangle]
pub extern "C" fn roc_dealloc(ptr: *mut c_void, alignment: usize) {
    host_dealloc(roc_host_ptr(), ptr, alignment);
}

/// Every Roc deallocation, from compiled Roc code (via `roc_dealloc`) or from
/// glue helpers (via `RocHost`), comes through here. Socket handles are routed
/// to the socket heap, which closes them; everything else is ordinary memory.
extern "C" fn host_dealloc(roc_host: *mut RocHost, ptr: *mut c_void, alignment: usize) {
    if !sockets::release(ptr) {
        DefaultAllocators::roc_dealloc(roc_host, ptr, alignment);
    }
}

#[no_mangle]
pub extern "C" fn roc_realloc(
    ptr: *mut c_void,
    new_length: usize,
    alignment: usize,
) -> *mut c_void {
    DefaultAllocators::roc_realloc(roc_host_ptr(), ptr, new_length, alignment)
}

#[no_mangle]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    DefaultHandlers::roc_dbg(roc_host_ptr(), bytes, len);
}

#[no_mangle]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    DefaultHandlers::roc_expect_failed(roc_host_ptr(), bytes, len);
}

#[no_mangle]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    DefaultHandlers::roc_crashed(roc_host_ptr(), bytes, len);
}

/// Build a RocList<RocStr> from command-line arguments.
fn build_args_list(roc_host: &RocHost) -> RocList<RocStr> {
    let args: Vec<String> = std::env::args().collect();

    if args.is_empty() {
        return RocList::empty();
    }

    let list = unsafe { RocList::<RocStr>::allocate(args.len(), roc_host) };
    let elements = list.elements;
    for (i, arg) in args.iter().enumerate() {
        let roc_str = RocStr::from_str(arg, roc_host);
        unsafe {
            elements.add(i).write(roc_str);
        }
    }
    list
}

/// C-compatible main entry point for the Roc program.
/// This is exported so the linker can find it.
#[no_mangle]
pub extern "C" fn main(_argc: i32, _argv: *const *const i8) -> i32 {
    rust_main()
}

/// Main entry point for the Roc program.
pub fn rust_main() -> i32 {
    time::init();
    // Read the limits now so a bad setting is reported at startup.
    limits::max_tasks();
    limits::max_sockets();

    // Leaked so it stays valid for tasks that are still running when `main!` returns.
    let roc_host: &'static mut RocHost = Box::leak(Box::new(RocHost {
        roc_dealloc: host_dealloc,
        ..make_roc_host(core::ptr::null_mut())
    }));
    set_roc_host(roc_host);

    let args_list = build_args_list(roc_host);

    unsafe { roc_main(args_list) }
}
