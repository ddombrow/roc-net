//! Roc platform host implementation for Roc's symbol-based host ABI.
//!
//! This host provides memory management and I/O effects for Roc programs.

use std::ffi::c_void;
use std::io::{self, BufRead, Read, Write};
use std::mem::ManuallyDrop;
use std::net::{Shutdown, TcpListener, TcpStream};

mod resource;
mod roc_platform_abi;
mod sockets;
mod tasks;

use crate::roc_platform_abi::{
    decref_box_with, make_roc_host, roc_main, DefaultAllocators, DefaultHandlers,
    HostStderrLineResult, HostStderrLineResultPayload, HostStderrLineResultTag,
    HostStdinLineResult, HostStdinLineResultPayload, HostStdinLineResultTag, HostStdoutLineResult,
    HostStdoutLineResultPayload, HostStdoutLineResultTag, HostTcpAcceptResult,
    HostTcpAcceptResultPayload, HostTcpAcceptResultTag, HostTcpConnectResult,
    HostTcpConnectResultPayload, HostTcpConnectResultTag, HostTcpListenResult,
    HostTcpListenResultPayload, HostTcpListenResultTag, HostTcpReadResult,
    HostTcpReadResultPayload, HostTcpReadResultTag, HostTcpWriteResult, HostTcpWriteResultPayload,
    HostTcpWriteResultTag, RocBox, RocHost, RocList, RocListWith, RocStr,
};
use crate::sockets::Socket;

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

/// Largest single read buffer, so a huge `max` from Roc cannot force a huge allocation.
const MAX_READ_BYTES: u64 = 64 * 1024;

/// Release the Roc reference a hosted function received for a socket handle.
/// If it was the last one, this closes the socket (via `roc_dealloc`).
fn release_handle(handle: *mut u64) {
    unsafe {
        decref_box_with(
            handle as RocBox,
            core::mem::align_of::<u64>(),
            false,
            None,
            roc_host(),
        )
    };
}

macro_rules! handle_result {
    ($result:ident, $payload:ident, $tag:ident, $value:expr) => {
        match $value {
            Ok(handle) => $result {
                payload: $payload {
                    ok: ManuallyDrop::new(handle),
                },
                tag: $tag::Ok,
            },
            Err(err) => $result {
                payload: $payload { err: err_str(err) },
                tag: $tag::Err,
            },
        }
    };
}

/// Hosted function: Host.tcp_listen!
#[no_mangle]
pub extern "C" fn roc_tcp_listen(address: RocStr) -> HostTcpListenResult {
    let result = TcpListener::bind(address.as_str())
        .map_err(|err| format!("{}: {err}", address.as_str()))
        .and_then(|listener| sockets::insert(Socket::TcpListener(listener)));
    unsafe { address.decref(roc_host()) };
    handle_result!(
        HostTcpListenResult,
        HostTcpListenResultPayload,
        HostTcpListenResultTag,
        result
    )
}

/// Hosted function: Host.tcp_accept!
#[no_mangle]
pub extern "C" fn roc_tcp_accept(listener: *mut u64) -> HostTcpAcceptResult {
    let result = unsafe { sockets::listener(listener) }.and_then(|listener| {
        let (stream, _peer) = listener.accept().map_err(|err| err.to_string())?;
        sockets::insert(Socket::TcpStream(stream))
    });
    release_handle(listener);
    handle_result!(
        HostTcpAcceptResult,
        HostTcpAcceptResultPayload,
        HostTcpAcceptResultTag,
        result
    )
}

/// Hosted function: Host.tcp_connect!
#[no_mangle]
pub extern "C" fn roc_tcp_connect(address: RocStr) -> HostTcpConnectResult {
    let result = TcpStream::connect(address.as_str())
        .map_err(|err| format!("{}: {err}", address.as_str()))
        .and_then(|stream| sockets::insert(Socket::TcpStream(stream)));
    unsafe { address.decref(roc_host()) };
    handle_result!(
        HostTcpConnectResult,
        HostTcpConnectResultPayload,
        HostTcpConnectResultTag,
        result
    )
}

/// Hosted function: Host.tcp_read!
#[no_mangle]
pub extern "C" fn roc_tcp_read(stream: *mut u64, max: u64) -> HostTcpReadResult {
    let result = unsafe { sockets::stream(stream) }.and_then(|mut stream| {
        let mut buf = vec![0u8; max.min(MAX_READ_BYTES) as usize];
        let len = stream.read(&mut buf).map_err(|err| err.to_string())?;
        Ok(unsafe { RocListWith::<u8, false>::from_slice(&buf[..len], roc_host()) })
    });
    release_handle(stream);

    match result {
        Ok(bytes) => HostTcpReadResult {
            payload: HostTcpReadResultPayload {
                ok: ManuallyDrop::new(bytes),
            },
            tag: HostTcpReadResultTag::Ok,
        },
        Err(err) => HostTcpReadResult {
            payload: HostTcpReadResultPayload { err: err_str(err) },
            tag: HostTcpReadResultTag::Err,
        },
    }
}

/// Hosted function: Host.tcp_write!
#[no_mangle]
pub extern "C" fn roc_tcp_write(
    stream: *mut u64,
    bytes: RocListWith<u8, false>,
) -> HostTcpWriteResult {
    let result = unsafe { sockets::stream(stream) }.and_then(|mut stream| {
        stream
            .write_all(bytes.as_slice())
            .map_err(|err| err.to_string())
    });
    unsafe { bytes.decref(roc_host()) };
    release_handle(stream);

    match result {
        Ok(()) => HostTcpWriteResult {
            payload: HostTcpWriteResultPayload {
                ok: unit_ok_payload(),
            },
            tag: HostTcpWriteResultTag::Ok,
        },
        Err(err) => HostTcpWriteResult {
            payload: HostTcpWriteResultPayload { err: err_str(err) },
            tag: HostTcpWriteResultTag::Err,
        },
    }
}

/// Hosted function: Host.tcp_shutdown!
#[no_mangle]
pub extern "C" fn roc_tcp_shutdown(stream: *mut u64) {
    if let Ok(stream) = unsafe { sockets::stream(stream) } {
        // Fails only if the stream is already shut down or disconnected.
        let _ = stream.shutdown(Shutdown::Both);
    }
    release_handle(stream);
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

/// Ignore SIGPIPE so writing to a disconnected peer returns an error instead
/// of killing the process. Rust's own startup does this for Rust binaries, but
/// Roc links this library behind the `main` below, so that startup never runs.
fn ignore_sigpipe() {
    #[cfg(unix)]
    {
        const SIGPIPE: i32 = 13;
        const SIG_IGN: usize = 1;
        extern "C" {
            fn signal(signum: i32, handler: usize) -> usize;
        }
        unsafe {
            signal(SIGPIPE, SIG_IGN);
        }
    }
}

/// C-compatible main entry point for the Roc program.
/// This is exported so the linker can find it.
#[no_mangle]
pub extern "C" fn main(_argc: i32, _argv: *const *const i8) -> i32 {
    rust_main()
}

/// Main entry point for the Roc program.
pub fn rust_main() -> i32 {
    ignore_sigpipe();

    // Leaked so it stays valid for tasks that are still running when `main!` returns.
    let roc_host: &'static mut RocHost = Box::leak(Box::new(RocHost {
        roc_dealloc: host_dealloc,
        ..make_roc_host(core::ptr::null_mut())
    }));
    set_roc_host(roc_host);

    let args_list = build_args_list(roc_host);

    unsafe { roc_main(args_list) }
}
