//! Random bytes from the TLS crypto provider's secure random generator
//! (AWS-LC's CSPRNG, which the OS seeds via getentropy/getrandom).

use std::mem::ManuallyDrop;

use crate::roc_host;
use crate::roc_platform_abi::{BytesOrOutOfMemory, BytesOrOutOfMemoryPayload, BytesOrOutOfMemoryTag, RocListWith};

/// Hosted function: Host.random_bytes!. `Random.bytes!` keeps `count` to
/// 16 MiB; even so, memory can run out, which is reported, not an abort.
#[no_mangle]
pub extern "C" fn roc_random_bytes(count: u64) -> BytesOrOutOfMemory {
    let mut buf = Vec::new();
    if buf.try_reserve_exact(count as usize).is_err() {
        return BytesOrOutOfMemory { payload: BytesOrOutOfMemoryPayload { out_of_memory: [] }, tag: BytesOrOutOfMemoryTag::OutOfMemory };
    }
    buf.resize(count as usize, 0u8);
    let provider = rustls::crypto::aws_lc_rs::default_provider();
    if provider.secure_random.fill(&mut buf).is_err() {
        // Without a secure source nothing random can be trusted, and making
        // every call fallible just pushes that dead end onto apps.
        eprintln!("roc-net: the system's secure random generator failed");
        std::process::exit(1);
    }
    let bytes = unsafe { RocListWith::<u8, false>::from_slice(&buf, roc_host()) };
    BytesOrOutOfMemory { payload: BytesOrOutOfMemoryPayload { bytes: ManuallyDrop::new(bytes) }, tag: BytesOrOutOfMemoryTag::Bytes }
}
