//! `Cryptography`'s host-backed primitives, from AWS-LC (aws-lc-rs, the same
//! build rustls uses): X25519, ChaCha20-Poly1305 and AES-256-GCM, Ed25519,
//! and a constant-time comparison. HMAC and HKDF are Roc, on the builtin
//! SHA-256 (platform/Cryptography.roc).
//!
//! Roc's key and nonce types check lengths before calling these; they check
//! again, and a wrong length is the operation's failure (`LowOrder`,
//! `Invalid`, an empty list, `False`), never a crash.

use aws_lc_rs::{aead, agreement, signature};

use crate::roc_host;
use crate::roc_platform_abi::{
    InvalidOrOpened, InvalidOrOpenedPayload, InvalidOrOpenedTag, LowOrderOrShared, LowOrderOrSharedPayload,
    LowOrderOrSharedTag, RocListWith,
};

type Bytes = RocListWith<u8, false>;

fn bytes(slice: &[u8]) -> Bytes {
    unsafe { Bytes::from_slice(slice, roc_host()) }
}

/// Run `f` on the lists' contents, then release them.
fn with_lists<const N: usize, R>(lists: [Bytes; N], f: impl FnOnce([&[u8]; N]) -> R) -> R {
    let result = f(std::array::from_fn(|i| lists[i].as_slice()));
    for list in lists {
        unsafe { list.decref(roc_host()) };
    }
    result
}

// --- X25519 ---

fn x25519_secret(secret: &[u8]) -> Option<agreement::PrivateKey> {
    agreement::PrivateKey::from_private_key(&agreement::X25519, secret).ok()
}

/// Hosted function: Host.x25519_public_key!
#[no_mangle]
pub extern "C" fn roc_x25519_public_key(secret: Bytes) -> Bytes {
    with_lists([secret], |[secret]| match x25519_secret(secret).and_then(|key| key.compute_public_key().ok()) {
        Some(public) => bytes(public.as_ref()),
        None => bytes(&[]),
    })
}

/// Hosted function: Host.x25519_shared!
#[no_mangle]
pub extern "C" fn roc_x25519_shared(secret: Bytes, public: Bytes) -> LowOrderOrShared {
    let shared = with_lists([secret, public], |[secret, public]| {
        let key = x25519_secret(secret)?;
        let peer = agreement::UnparsedPublicKey::new(&agreement::X25519, public);
        let shared = agreement::agree(&key, peer, (), |shared| Ok(shared.to_vec())).ok()?;
        // An all-zero result means a low-order public key, which RFC 7748
        // says to reject (AWS-LC does too; this doesn't rely on it).
        (shared.len() == 32 && shared.iter().any(|&b| b != 0)).then_some(shared)
    });
    match shared {
        Some(shared) => LowOrderOrShared {
            payload: LowOrderOrSharedPayload { shared: std::mem::ManuallyDrop::new(bytes(&shared)) },
            tag: LowOrderOrSharedTag::Shared,
        },
        None => LowOrderOrShared { payload: LowOrderOrSharedPayload { low_order: [] }, tag: LowOrderOrSharedTag::LowOrder },
    }
}

// --- AEADs ---

fn aead_key(alg: u8, key: &[u8]) -> Option<aead::LessSafeKey> {
    let alg = match alg {
        0 => &aead::CHACHA20_POLY1305,
        1 => &aead::AES_256_GCM,
        _ => return None,
    };
    aead::UnboundKey::new(alg, key).ok().map(aead::LessSafeKey::new)
}

fn nonce(nonce: &[u8]) -> Option<aead::Nonce> {
    aead::Nonce::try_assume_unique_for_key(nonce).ok()
}

/// Hosted function: Host.aead_seal!
#[no_mangle]
pub extern "C" fn roc_aead_seal(alg: u8, key: Bytes, nonce_bytes: Bytes, ad: Bytes, plaintext: Bytes) -> Bytes {
    with_lists([key, nonce_bytes, ad, plaintext], |[key, nonce_bytes, ad, plaintext]| {
        let (Some(key), Some(nonce)) = (aead_key(alg, key), nonce(nonce_bytes)) else {
            return bytes(&[]);
        };
        let mut sealed = plaintext.to_vec();
        match key.seal_in_place_append_tag(nonce, aead::Aad::from(ad), &mut sealed) {
            Ok(()) => bytes(&sealed),
            Err(_) => bytes(&[]),
        }
    })
}

/// Hosted function: Host.aead_open!
#[no_mangle]
pub extern "C" fn roc_aead_open(alg: u8, key: Bytes, nonce_bytes: Bytes, ad: Bytes, ciphertext: Bytes) -> InvalidOrOpened {
    let opened = with_lists([key, nonce_bytes, ad, ciphertext], |[key, nonce_bytes, ad, ciphertext]| {
        let key = aead_key(alg, key)?;
        let nonce = nonce(nonce_bytes)?;
        let mut buf = ciphertext.to_vec();
        key.open_in_place(nonce, aead::Aad::from(ad), &mut buf).ok().map(|plain| bytes(plain))
    });
    match opened {
        Some(plain) => InvalidOrOpened {
            payload: InvalidOrOpenedPayload { opened: std::mem::ManuallyDrop::new(plain) },
            tag: InvalidOrOpenedTag::Opened,
        },
        None => InvalidOrOpened { payload: InvalidOrOpenedPayload { invalid: [] }, tag: InvalidOrOpenedTag::Invalid },
    }
}

// --- Ed25519 ---

fn ed25519_key(seed: &[u8]) -> Option<signature::Ed25519KeyPair> {
    signature::Ed25519KeyPair::from_seed_unchecked(seed).ok()
}

/// Hosted function: Host.ed25519_public_key!
#[no_mangle]
pub extern "C" fn roc_ed25519_public_key(seed: Bytes) -> Bytes {
    with_lists([seed], |[seed]| match ed25519_key(seed) {
        Some(key) => bytes(signature::KeyPair::public_key(&key).as_ref()),
        None => bytes(&[]),
    })
}

/// Hosted function: Host.ed25519_sign!
#[no_mangle]
pub extern "C" fn roc_ed25519_sign(seed: Bytes, message: Bytes) -> Bytes {
    with_lists([seed, message], |[seed, message]| match ed25519_key(seed) {
        Some(key) => bytes(key.sign(message).as_ref()),
        None => bytes(&[]),
    })
}

/// Hosted function: Host.ed25519_verify!
#[no_mangle]
pub extern "C" fn roc_ed25519_verify(public: Bytes, message: Bytes, sig: Bytes) -> bool {
    with_lists([public, message, sig], |[public, message, sig]| {
        signature::UnparsedPublicKey::new(&signature::ED25519, public).verify(message, sig).is_ok()
    })
}

// --- Comparison ---

/// Hosted function: Host.constant_time_eq!
#[no_mangle]
pub extern "C" fn roc_constant_time_eq(a: Bytes, b: Bytes) -> bool {
    #[allow(deprecated)]
    with_lists([a, b], |[a, b]| aws_lc_rs::constant_time::verify_slices_are_equal(a, b).is_ok())
}
