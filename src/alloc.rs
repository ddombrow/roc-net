//! The host's memory allocator, for Roc code and for the glue's helpers.
//!
//! The same layout as the glue's `DefaultAllocators` (each allocation's
//! total size in the word just before the pointer handed out), taken over so
//! the host can also allocate in a way that can fail ([`try_alloc`]), with a
//! layout that by construction matches what [`dealloc`] frees.

use std::alloc::Layout;
use std::ffi::c_void;
use std::mem::{align_of, size_of};

use crate::roc_platform_abi::RocHost;

/// `length` bytes aligned to `alignment`, or null if memory (or the size)
/// runs out.
pub fn try_alloc(length: usize, alignment: usize) -> *mut c_void {
    let align = alignment.max(align_of::<usize>());
    let Some(total) = length.checked_add(align) else { return std::ptr::null_mut() };
    let Ok(layout) = Layout::from_size_align(total, align) else { return std::ptr::null_mut() };
    unsafe {
        let base = std::alloc::alloc(layout);
        if base.is_null() {
            return std::ptr::null_mut();
        }
        let user = base.add(align);
        *(user.sub(size_of::<usize>()) as *mut usize) = total;
        user as *mut c_void
    }
}

/// Free what [`try_alloc`] (or [`alloc`]) returned.
pub fn dealloc(ptr: *mut c_void, alignment: usize) {
    let align = alignment.max(align_of::<usize>());
    unsafe {
        let total = *((ptr as *const u8).sub(size_of::<usize>()) as *const usize);
        std::alloc::dealloc((ptr as *mut u8).sub(align), Layout::from_size_align_unchecked(total, align));
    }
}

fn out_of_memory(what: &str) -> ! {
    eprintln!("{what}: out of memory");
    std::process::exit(1)
}

/// The allocator Roc code and the glue use: [`try_alloc`], ending the
/// program if it fails (Roc has no way to go on without the memory).
pub extern "C" fn alloc(_roc_host: *mut RocHost, length: usize, alignment: usize) -> *mut c_void {
    let ptr = try_alloc(length, alignment);
    if ptr.is_null() {
        out_of_memory("roc_alloc");
    }
    ptr
}

pub extern "C" fn realloc(_roc_host: *mut RocHost, ptr: *mut c_void, new_length: usize, alignment: usize) -> *mut c_void {
    let align = alignment.max(align_of::<usize>());
    unsafe {
        let old_total = *((ptr as *const u8).sub(size_of::<usize>()) as *const usize);
        let new_total = new_length.checked_add(align).unwrap_or_else(|| out_of_memory("roc_realloc"));
        let base = std::alloc::realloc((ptr as *mut u8).sub(align), Layout::from_size_align_unchecked(old_total, align), new_total);
        if base.is_null() {
            out_of_memory("roc_realloc");
        }
        let user = base.add(align);
        *(user.sub(size_of::<usize>()) as *mut usize) = new_total;
        user as *mut c_void
    }
}
