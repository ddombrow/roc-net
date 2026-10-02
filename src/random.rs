//! Random bytes from the TLS crypto provider's secure random generator
//! (AWS-LC's CSPRNG, which the OS seeds via getentropy/getrandom).

use std::ffi::c_void;
use std::mem::{size_of, ManuallyDrop};
use std::sync::OnceLock;

use crate::roc_host;
use crate::roc_platform_abi::{BytesOrOutOfMemory, BytesOrOutOfMemoryPayload, BytesOrOutOfMemoryTag, RocHost, RocListWith};

const WORD: usize = size_of::<usize>();

/// Hosted function: Host.random_bytes!. `Random.bytes!` keeps `count` to
/// 16 MiB; even so, memory can run out, which is reported, not an abort.
#[no_mangle]
pub extern "C" fn roc_random_bytes(count: u64) -> BytesOrOutOfMemory {
    check_layout();
    let count = count as usize;
    let Some(list) = try_alloc_bytes(count) else {
        return BytesOrOutOfMemory { payload: BytesOrOutOfMemoryPayload { out_of_memory: [] }, tag: BytesOrOutOfMemoryTag::OutOfMemory };
    };
    if count > 0 {
        let bytes = unsafe { std::slice::from_raw_parts_mut(list.elements, count) };
        let provider = rustls::crypto::aws_lc_rs::default_provider();
        if provider.secure_random.fill(bytes).is_err() {
            // Without a secure source nothing random can be trusted, and making
            // every call fallible just pushes that dead end onto apps.
            eprintln!("roc-net: the system's secure random generator failed");
            std::process::exit(1);
        }
    }
    BytesOrOutOfMemory { payload: BytesOrOutOfMemoryPayload { bytes: ManuallyDrop::new(list) }, tag: BytesOrOutOfMemoryTag::Bytes }
}

/// A Roc list of `count` bytes (left for the caller to fill), or `None` if
/// the memory can't be had. The glue's `RocListWith::allocate` would end the
/// program instead; this lays the list out as it does (checked by
/// [`check_layout`]): one word of reference count (1) before the elements,
/// and the capacity field shifted left one bit, in memory from the host's
/// own allocator, which Roc frees as usual.
fn try_alloc_bytes(count: usize) -> Option<RocListWith<u8, false>> {
    if count == 0 {
        return Some(RocListWith::empty());
    }
    let base = crate::alloc::try_alloc(count.checked_add(WORD)?, WORD) as *mut u8;
    if base.is_null() {
        return None;
    }
    unsafe {
        let elements = base.add(WORD);
        *(elements as *mut isize).sub(1) = 1;
        Some(RocListWith { elements, length: count, capacity_or_alloc_ptr: count.checked_shl(1)? })
    }
}

/// Have the glue lay out a one-byte list in a buffer, through a `RocHost`
/// whose allocator hands out that buffer (nothing is allocated), and check
/// it matches [`try_alloc_bytes`]. A mismatch means the glue changed and this
/// file must follow it: a platform bug, which the test suite would show.
fn check_layout() {
    static CHECKED: OnceLock<()> = OnceLock::new();
    CHECKED.get_or_init(|| {
        // The buffer, then what the glue asked the allocator for.
        let mut probe = [0usize; 8];
        extern "C" fn probe_alloc(host: *mut RocHost, length: usize, alignment: usize) -> *mut c_void {
            unsafe {
                let probe = (*host).env as *mut usize;
                *probe.add(6) = length;
                *probe.add(7) = alignment;
                probe as *mut c_void
            }
        }
        let host = roc_host();
        let mut probe_host = RocHost {
            env: probe.as_mut_ptr() as *mut c_void,
            roc_alloc: probe_alloc,
            roc_dealloc: host.roc_dealloc,
            roc_realloc: host.roc_realloc,
            roc_dbg: host.roc_dbg,
            roc_expect_failed: host.roc_expect_failed,
            roc_crashed: host.roc_crashed,
        };
        let list = unsafe { RocListWith::<u8, false>::allocate(1, &mut probe_host) };
        let base = probe.as_ptr() as *const u8;
        let matches = probe[6] == 1 + WORD
            && probe[7] == WORD
            && list.elements as *const u8 == base.wrapping_add(WORD)
            && probe[0] == 1
            && list.length == 1
            && list.capacity_or_alloc_ptr == 1 << 1;
        // The list lives in `probe`: never freed through Roc.
        if !matches {
            eprintln!("roc-net bug: the generated glue lays lists out differently from src/random.rs");
            std::process::exit(1);
        }
    });
}
