//! Host resources owned by Roc reference counting.
//!
//! Adapted from basic-webserver's `host_resource.rs` (UPL-1.0).
//!
//! Each resource lives in a fixed slot whose first two words have the layout of
//! a Roc `Box(U64)`: an atomic refcount followed by the `U64` payload. The host
//! hands Roc a pointer to that payload, and Roc refcounts it like any other box.
//! When Roc releases the last reference it deallocates the box's base address,
//! which is the slot itself; `roc_dealloc` routes that address here via
//! [`ResourceHeap::release`], and the resource is dropped (closing the socket).
//!
//! The payload is a token of (generation, slot index). Every lookup checks it,
//! so a handle whose slot has since been reused is rejected rather than
//! silently resolving to someone else's socket.

use core::cell::UnsafeCell;
use core::ffi::c_void;
use core::mem::{offset_of, MaybeUninit};
use core::sync::atomic::{AtomicIsize, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard};

const INDEX_BITS: u32 = 16;
const INDEX_MASK: u64 = (1 << INDEX_BITS) - 1;

#[repr(C)]
struct Slot<T> {
    refcount: AtomicIsize,
    token: UnsafeCell<u64>,
    resource: UnsafeCell<MaybeUninit<T>>,
}

struct State {
    free: Vec<usize>,
    generations: Vec<u64>,
    live: Vec<bool>,
}

pub struct ResourceHeap<T> {
    slots: Box<[Slot<T>]>,
    state: Mutex<State>,
    /// Signalled whenever a slot returns to the free list.
    slot_freed: Condvar,
}

// Slot state is guarded by `state`. A live resource is only reached through a
// handle whose Roc reference the caller owns, which keeps the slot from being
// released during the access; `T` provides its own synchronization.
unsafe impl<T: Send> Send for ResourceHeap<T> {}
unsafe impl<T: Send + Sync> Sync for ResourceHeap<T> {}

#[derive(Debug)]
pub struct Full;

#[derive(Debug)]
pub struct Invalid;

impl<T> ResourceHeap<T> {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0 && capacity as u64 <= INDEX_MASK);
        assert_eq!(offset_of!(Slot<T>, token), core::mem::size_of::<isize>());

        let slots = (0..capacity)
            .map(|_| Slot {
                refcount: AtomicIsize::new(0),
                token: UnsafeCell::new(0),
                resource: UnsafeCell::new(MaybeUninit::uninit()),
            })
            .collect();
        Self {
            slots,
            state: Mutex::new(State {
                free: (0..capacity).rev().collect(),
                generations: vec![0; capacity],
                live: vec![false; capacity],
            }),
            slot_freed: Condvar::new(),
        }
    }

    /// Claim a free slot, or fail if there is none.
    pub fn try_reserve(&self) -> Result<Reservation<'_, T>, Full> {
        let index = self.lock().free.pop().ok_or(Full)?;
        Ok(Reservation { heap: self, index: Some(index) })
    }

    /// Claim a free slot, waiting for one to be released if the heap is full.
    pub fn reserve(&self) -> Reservation<'_, T> {
        let mut state = self.lock();
        loop {
            if let Some(index) = state.free.pop() {
                return Reservation { heap: self, index: Some(index) };
            }
            state = self
                .slot_freed
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }

    fn free_slot(&self, index: usize) {
        self.lock().free.push(index);
        self.slot_freed.notify_one();
    }

    /// Borrow the resource behind a handle.
    ///
    /// # Safety
    /// The caller must own a live Roc reference to `handle` for as long as it
    /// uses the returned reference.
    pub unsafe fn get(&self, handle: *mut u64) -> Result<&T, Invalid> {
        let index = self.payload_index(handle).ok_or(Invalid)?;
        let token = unsafe { *self.slots[index].token.get() };
        let state = self.lock();
        let valid = state.live[index]
            && token & INDEX_MASK == index as u64
            && token >> INDEX_BITS == state.generations[index];
        drop(state);
        if !valid {
            return Err(Invalid);
        }
        Ok(unsafe { (*self.slots[index].resource.get()).assume_init_ref() })
    }

    /// Called from `roc_dealloc` for every freed allocation. Returns false if
    /// `ptr` is not one of this heap's slots, so ordinary memory can be freed
    /// normally.
    pub fn release(&self, ptr: *mut c_void) -> bool {
        let Some(index) = self.base_index(ptr as usize) else {
            if self.contains(ptr as usize) {
                // Inside the heap but not a slot base: never ours to free normally.
                eprintln!(
                    "roc-net: freed pointer {ptr:?} is inside the resource heap but not a slot"
                );
                return true;
            }
            return false;
        };
        let mut state = self.lock();
        if !state.live[index] {
            eprintln!("roc-net: resource slot {index} released twice");
            return true;
        }
        state.live[index] = false;
        let resource = unsafe { (*self.slots[index].resource.get()).assume_init_read() };
        drop(state);

        // Closing may block, so do it outside the lock and only then make the
        // slot available again.
        drop(resource);
        self.free_slot(index);
        true
    }

    fn contains(&self, address: usize) -> bool {
        let start = self.slots.as_ptr() as usize;
        (start..start + core::mem::size_of_val(&*self.slots)).contains(&address)
    }

    fn payload_index(&self, handle: *mut u64) -> Option<usize> {
        let base = (handle as usize).checked_sub(offset_of!(Slot<T>, token))?;
        self.base_index(base)
    }

    fn base_index(&self, address: usize) -> Option<usize> {
        let start = self.slots.as_ptr() as usize;
        let offset = address.checked_sub(start)?;
        let stride = core::mem::size_of::<Slot<T>>();
        let index = offset / stride;
        (offset % stride == 0 && index < self.slots.len()).then_some(index)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// A slot claimed for a resource that is not created yet. Dropping it without
/// calling `insert` returns the slot to the heap.
pub struct Reservation<'a, T> {
    heap: &'a ResourceHeap<T>,
    index: Option<usize>,
}

impl<T> Reservation<'_, T> {
    /// Store `resource` in the slot and return the payload pointer Roc will own,
    /// with one reference.
    pub fn insert(mut self, resource: T) -> *mut u64 {
        let index = self.index.take().expect("reservation used once");
        let heap = self.heap;
        let mut state = heap.lock();
        let generation = state.generations[index] + 1;
        state.generations[index] = generation;
        state.live[index] = true;
        drop(state);

        let slot = &heap.slots[index];
        unsafe {
            (*slot.resource.get()).write(resource);
            *slot.token.get() = (generation << INDEX_BITS) | index as u64;
        }
        slot.refcount.store(1, Ordering::Release);
        slot.token.get()
    }
}

impl<T> Drop for Reservation<'_, T> {
    fn drop(&mut self) {
        if let Some(index) = self.index.take() {
            self.heap.free_slot(index);
        }
    }
}
