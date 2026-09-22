//! No call that handles an account key frees a buffer still holding it.
//!
//! A test binary of its own, since its allocator watches every buffer freed
//! while it runs.

use std::alloc::{GlobalAlloc, Layout, System};
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};

use logos_account_core::ffi::*;

/// Frees through the system allocator, first counting each buffer that holds
/// the needle: the key's first 16 bytes, raw or as hex.
struct Watching;

static ARMED: AtomicBool = AtomicBool::new(false);
static RAW: [AtomicU8; 16] = [const { AtomicU8::new(0) }; 16];
static HEX: [AtomicU8; 32] = [const { AtomicU8::new(0) }; 32];
static FOUND: AtomicUsize = AtomicUsize::new(0);

fn holds(buffer: &[u8], needle: &[AtomicU8]) -> bool {
    buffer.windows(needle.len()).any(|window| {
        window
            .iter()
            .zip(needle)
            .all(|(byte, want)| *byte == want.load(Ordering::Relaxed))
    })
}

unsafe impl GlobalAlloc for Watching {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if ARMED.load(Ordering::Relaxed) {
            let buffer = unsafe { std::slice::from_raw_parts(ptr, layout.size()) };
            if holds(buffer, &RAW) || holds(buffer, &HEX) {
                FOUND.fetch_add(1, Ordering::Relaxed);
            }
        }
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Watching = Watching;

fn call(reply: *mut c_char) -> serde_json::Value {
    let value = serde_json::from_str(unsafe { CStr::from_ptr(reply) }.to_str().unwrap()).unwrap();
    logos_account_core_string_free(reply);
    value
}

#[test]
fn importing_and_exporting_a_key_leaves_no_copy_behind() {
    let vault = tempfile::tempdir().unwrap();
    let dir = CString::new(vault.path().to_str().unwrap()).unwrap();
    let core = logos_account_core_new(dir.as_ptr(), c"memory".as_ptr());

    let secret: [u8; 32] = std::array::from_fn(|i| 0x40 + i as u8);
    let secret_hex = CString::new(hex::encode(secret)).unwrap();
    for (i, byte) in secret.iter().take(16).enumerate() {
        RAW[i].store(*byte, Ordering::Relaxed);
    }
    for (i, byte) in secret_hex.as_bytes().iter().take(32).enumerate() {
        HEX[i].store(*byte, Ordering::Relaxed);
    }

    // A sealed import is held unlocked until the forget, and both publishes
    // sign.
    for (password, name) in [(None, c"Saro"), (Some(c"a long quiet sentence"), c"Raya")] {
        let password = password.map_or(std::ptr::null(), CStr::as_ptr);
        ARMED.store(true, Ordering::Relaxed);
        let imported = call(logos_account_core_import_account(
            core,
            secret_hex.as_ptr(),
            password,
        ));
        let address = CString::new(imported["address"].as_str().unwrap()).unwrap();
        let exported = logos_account_core_export_account(core, address.as_ptr(), password);
        logos_account_core_string_free(exported);
        call(logos_account_core_stage_set_display_name(
            core,
            address.as_ptr(),
            name.as_ptr(),
        ));
        assert_eq!(
            call(logos_account_core_publish(core, address.as_ptr()))["ok"],
            true
        );
        call(logos_account_core_forget_account(core, address.as_ptr()));
        ARMED.store(false, Ordering::Relaxed);
    }

    // The table of unlocked keys is replaced as it grows, and keeps the slot a
    // forget emptied until the handle goes: a key held in it rather than boxed
    // would be left in both.
    ARMED.store(true, Ordering::Relaxed);
    let imported = call(logos_account_core_import_account(
        core,
        secret_hex.as_ptr(),
        c"a long quiet sentence".as_ptr(),
    ));
    for _ in 0..4 {
        call(logos_account_core_create_account(
            core,
            c"another quiet sentence".as_ptr(),
        ));
    }
    let address = CString::new(imported["address"].as_str().unwrap()).unwrap();
    call(logos_account_core_forget_account(core, address.as_ptr()));
    logos_account_core_free(core);
    ARMED.store(false, Ordering::Relaxed);
    let core = logos_account_core_new(dir.as_ptr(), c"memory".as_ptr());

    // A key file that fails to parse after its key.
    let imported = call(logos_account_core_import_account(
        core,
        secret_hex.as_ptr(),
        std::ptr::null(),
    ));
    let address = imported["address"].as_str().unwrap().to_owned();
    {
        let path = vault.path().join(format!("{address}.open.json"));
        let text = std::fs::read_to_string(&path).unwrap();
        let open = text.trim_end().strip_suffix('}').unwrap();
        std::fs::write(&path, format!("{open},}}")).unwrap();
    }
    let address = CString::new(address).unwrap();
    ARMED.store(true, Ordering::Relaxed);
    let refused = call(logos_account_core_export_account(
        core,
        address.as_ptr(),
        std::ptr::null(),
    ));
    ARMED.store(false, Ordering::Relaxed);
    assert_eq!(refused["ok"], false);
    logos_account_core_free(core);

    // A key still unlocked when the handle goes.
    let vault = tempfile::tempdir().unwrap();
    let dir = CString::new(vault.path().to_str().unwrap()).unwrap();
    let core = logos_account_core_new(dir.as_ptr(), c"memory".as_ptr());
    ARMED.store(true, Ordering::Relaxed);
    call(logos_account_core_import_account(
        core,
        secret_hex.as_ptr(),
        c"a long quiet sentence".as_ptr(),
    ));
    logos_account_core_free(core);
    ARMED.store(false, Ordering::Relaxed);

    assert_eq!(FOUND.load(Ordering::Relaxed), 0);
}
