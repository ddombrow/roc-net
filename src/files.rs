//! Hosted file and environment functions (`File`, `Env`).
//!
//! File system calls block, and a slow disk or network file system can
//! block for a long time, so each call runs on a helper thread
//! (`sched::blocking`) while the task waits. A cancelled task stops
//! waiting; the call finishes in the background.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::mem::ManuallyDrop;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use crate::net::{FromNetErr, NetErr};
use crate::roc_host;
use crate::roc_platform_abi::{
    FoundOrMissingOrNotUtf8, FoundOrMissingOrNotUtf8Payload, FoundOrMissingOrNotUtf8Tag, HostFileDeleteResult,
    HostFileDeleteResultPayload, HostFileDeleteResultTag, HostFileExistsResult, HostFileExistsResultPayload,
    HostFileExistsResultTag, HostFileReadResult, HostFileReadResultPayload, HostFileReadResultTag, RocListWith,
    RocStr,
};

/// Run `f` on a helper thread and wait for it (or fail with `Cancelled`).
fn off_thread<T: Send + 'static>(f: impl FnOnce() -> io::Result<T> + Send + 'static) -> io::Result<T> {
    crate::sched::blocking(None, f)?.expect("no deadline")
}

/// A Roc string argument as an owned path, releasing the string.
fn take_path(text: RocStr) -> PathBuf {
    let path = PathBuf::from(text.as_str());
    unsafe { text.decref(roc_host()) };
    path
}

fn unit_result(value: io::Result<()>) -> HostFileDeleteResult {
    match value {
        Ok(()) => HostFileDeleteResult { payload: HostFileDeleteResultPayload { ok: [] }, tag: HostFileDeleteResultTag::Ok },
        Err(err) => HostFileDeleteResult {
            payload: HostFileDeleteResultPayload { err: ManuallyDrop::new(FromNetErr::from_net_err(NetErr::Io(err))) },
            tag: HostFileDeleteResultTag::Err,
        },
    }
}

/// Hosted function: Host.file_read!
#[no_mangle]
pub extern "C" fn roc_file_read(path: RocStr) -> HostFileReadResult {
    let path = take_path(path);
    match off_thread(move || fs::read(path)) {
        Ok(bytes) => HostFileReadResult {
            payload: HostFileReadResultPayload {
                ok: ManuallyDrop::new(unsafe { RocListWith::<u8, false>::from_slice(&bytes, roc_host()) }),
            },
            tag: HostFileReadResultTag::Ok,
        },
        Err(err) => HostFileReadResult {
            payload: HostFileReadResultPayload { err: ManuallyDrop::new(FromNetErr::from_net_err(NetErr::Io(err))) },
            tag: HostFileReadResultTag::Err,
        },
    }
}

/// Hosted function: Host.file_write!. `how`: 0 create or replace, 1 append
/// (creating), 2 create only if absent, 3 replace atomically.
#[no_mangle]
pub extern "C" fn roc_file_write(path: RocStr, bytes: RocListWith<u8, false>, how: u8, mode: u32) -> HostFileDeleteResult {
    let path = take_path(path);
    let data = bytes.as_slice().to_vec();
    unsafe { bytes.decref(roc_host()) };
    unit_result(off_thread(move || match how {
        2 => write_new(&path, &data, mode),
        3 => write_atomic(&path, &data, mode),
        _ => {
            let mut options = OpenOptions::new();
            options.write(true).mode(mode);
            match how {
                0 => options.create(true).truncate(true),
                _ => options.create(true).append(true),
            };
            options.open(&path)?.write_all(&data)
        }
    }))
}

/// The directory `path` is in, and its file name.
fn split(path: &Path) -> io::Result<(&Path, &std::ffi::OsStr)> {
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "not a file path"))?;
    let dir = match path.parent() {
        Some(dir) if !dir.as_os_str().is_empty() => dir,
        _ => Path::new("."),
    };
    Ok((dir, name))
}

/// Write `data` to a new temporary file beside `path` with permissions
/// `mode`, flushed to disk, and return its path. The name has a random part,
/// so one left behind by a program that stopped partway (perhaps with the
/// same process id, as a container's first process always has) can't get in
/// the way; a collision anyway just tries another name.
fn write_temp(path: &Path, data: &[u8], mode: u32) -> io::Result<PathBuf> {
    let (dir, name) = split(path)?;
    let mut attempt = 0;
    loop {
        let mut random = [0u8; 8];
        aws_lc_rs::rand::fill(&mut random).map_err(|_| io::Error::other("the secure random generator failed"))?;
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let temp = dir.join(format!(".{}.{suffix}.tmp", name.to_string_lossy()));
        let mut file = match OpenOptions::new().write(true).create_new(true).mode(mode).open(&temp) {
            Ok(file) => file,
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists && attempt < 8 => {
                attempt += 1;
                continue;
            }
            Err(err) => return Err(err),
        };
        let written = file.write_all(data).and_then(|()| file.sync_all());
        if let Err(err) = written {
            let _ = fs::remove_file(&temp);
            return Err(err);
        }
        return Ok(temp);
    }
}

/// Flush `path`'s directory, so a new name in it lasts too. Not every file
/// system can; the file is in place either way.
fn sync_dir(path: &Path) {
    if let Ok((dir, _)) = split(path) {
        if let Ok(dir) = fs::File::open(dir) {
            let _ = dir.sync_all();
        }
    }
}

/// Replace `path` with `data`: a temporary file, flushed, renamed over it.
fn write_atomic(path: &Path, data: &[u8], mode: u32) -> io::Result<()> {
    let temp = write_temp(path, data, mode)?;
    if let Err(err) = fs::rename(&temp, path) {
        let _ = fs::remove_file(&temp);
        return Err(err);
    }
    sync_dir(path);
    Ok(())
}

/// Create `path` with `data` only if nothing is there: a temporary file,
/// flushed, then hard-linked to `path` (which fails with `AlreadyExists` if
/// something is), so `path` never appears empty or cut short.
///
/// On a file system without hard links (FAT, exFAT, some network shares),
/// it creates `path` directly instead, removing it again if writing fails;
/// there, a crash partway can leave it incomplete.
fn write_new(path: &Path, data: &[u8], mode: u32) -> io::Result<()> {
    let temp = write_temp(path, data, mode)?;
    let linked = fs::hard_link(&temp, path);
    let _ = fs::remove_file(&temp);
    match linked {
        Ok(()) => {}
        Err(err) if no_hard_links(&err) => {
            let mut file = OpenOptions::new().write(true).create_new(true).mode(mode).open(path)?;
            if let Err(err) = file.write_all(data).and_then(|()| file.sync_all()) {
                let _ = fs::remove_file(path);
                return Err(err);
            }
        }
        Err(err) => return Err(err),
    }
    sync_dir(path);
    Ok(())
}

/// Whether `link` failed because the file system has no hard links.
fn no_hard_links(err: &io::Error) -> bool {
    err.kind() == io::ErrorKind::Unsupported
        || matches!(err.raw_os_error(), Some(code) if code == libc::EPERM || code == libc::ENOTSUP || code == libc::EOPNOTSUPP || code == libc::ENOSYS)
}

/// Hosted function: Host.file_rename!
#[no_mangle]
pub extern "C" fn roc_file_rename(from: RocStr, to: RocStr) -> HostFileDeleteResult {
    let (from, to) = (take_path(from), take_path(to));
    unit_result(off_thread(move || fs::rename(from, to)))
}

/// Hosted function: Host.file_delete!
#[no_mangle]
pub extern "C" fn roc_file_delete(path: RocStr) -> HostFileDeleteResult {
    let path = take_path(path);
    unit_result(off_thread(move || fs::remove_file(path)))
}

/// Hosted function: Host.file_exists!
#[no_mangle]
pub extern "C" fn roc_file_exists(path: RocStr) -> HostFileExistsResult {
    let path = take_path(path);
    // Like `Path::try_exists`, but without following a final symlink, so a
    // dangling link counts as something being there (`write_new!` would fail).
    let found = off_thread(move || match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(err) => Err(err),
    });
    match found {
        Ok(found) => HostFileExistsResult {
            payload: HostFileExistsResultPayload { ok: ManuallyDrop::new(found) },
            tag: HostFileExistsResultTag::Ok,
        },
        Err(err) => HostFileExistsResult {
            payload: HostFileExistsResultPayload { err: ManuallyDrop::new(FromNetErr::from_net_err(NetErr::Io(err))) },
            tag: HostFileExistsResultTag::Err,
        },
    }
}

/// Hosted function: Host.env_var!
#[no_mangle]
pub extern "C" fn roc_env_var(name: RocStr) -> FoundOrMissingOrNotUtf8 {
    use FoundOrMissingOrNotUtf8Payload as P;
    use FoundOrMissingOrNotUtf8Tag as T;
    let key = name.as_str().to_owned();
    unsafe { name.decref(roc_host()) };
    // Names the OS can't hold can't be set either.
    let value = if key.is_empty() || key.contains(['=', '\0']) { None } else { std::env::var_os(&key) };
    match value.map(|value| value.into_string()) {
        Some(Ok(text)) => FoundOrMissingOrNotUtf8 {
            payload: P { found: ManuallyDrop::new(RocStr::from_str(&text, roc_host())) },
            tag: T::Found,
        },
        Some(Err(_)) => FoundOrMissingOrNotUtf8 { payload: P { not_utf8: [] }, tag: T::NotUtf8 },
        None => FoundOrMissingOrNotUtf8 { payload: P { missing: [] }, tag: T::Missing },
    }
}
