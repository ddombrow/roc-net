//! Random bytes from the TLS crypto provider's secure random generator
//! (AWS-LC's CSPRNG, which the OS seeds via getentropy/getrandom).

use crate::roc_host;
use crate::roc_platform_abi::RocListWith;

/// Hosted function: Host.random_bytes!
#[no_mangle]
pub extern "C" fn roc_random_bytes(count: u64) -> RocListWith<u8, false> {
    let mut buf = vec![0u8; count as usize];
    let provider = rustls::crypto::aws_lc_rs::default_provider();
    if provider.secure_random.fill(&mut buf).is_err() {
        // Without a secure source nothing random can be trusted, and making
        // every call fallible just pushes that dead end onto apps.
        eprintln!("roc-net: the system's secure random generator failed");
        std::process::exit(1);
    }
    unsafe { RocListWith::<u8, false>::from_slice(&buf, roc_host()) }
}
