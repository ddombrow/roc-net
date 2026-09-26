//! Random bytes from the OS's secure random source, read from `/dev/urandom`
//! with the standard library only.

use std::fs::File;
use std::io::Read;
use std::sync::OnceLock;

use crate::roc_host;
use crate::roc_platform_abi::RocListWith;

/// The random source, opened once and shared: reading through `&File` is safe
/// from several threads at once.
fn source() -> &'static File {
    static SOURCE: OnceLock<File> = OnceLock::new();
    SOURCE.get_or_init(|| {
        File::open("/dev/urandom").unwrap_or_else(|err| {
            // Without a secure source nothing random can be trusted, and
            // making every call fallible just pushes that dead end onto apps.
            eprintln!("roc-net: cannot open /dev/urandom for random numbers: {err}");
            std::process::exit(1)
        })
    })
}

/// Hosted function: Host.random_bytes!
#[no_mangle]
pub extern "C" fn roc_random_bytes(count: u64) -> RocListWith<u8, false> {
    let mut buf = vec![0u8; count as usize];
    if let Err(err) = (&mut source()).read_exact(&mut buf) {
        eprintln!("roc-net: cannot read /dev/urandom: {err}");
        std::process::exit(1);
    }
    unsafe { RocListWith::<u8, false>::from_slice(&buf, roc_host()) }
}
