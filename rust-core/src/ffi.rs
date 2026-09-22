//! The C ABI the Qt backend calls. See `include/account_core.h` for the
//! declarations and the ownership rules.
//!
//! Three properties every function here keeps, because the caller is C++ and
//! has no way to recover from a broken one:
//!
//! 1. Nothing unwinds. A panic is caught and returned as a failed reply.
//! 2. Every reply is JSON with an `ok` field, so a caller that only ever parses
//!    JSON stays correct on every path.
//! 3. A null handle or a null string is answered, not dereferenced.
//!
//! The handle is behind a mutex: the backend calls from a worker thread so the
//! view is not blocked on the network, and the same handle is read from the
//! thread that answers the replica.

// Every function below takes pointers the C caller must keep valid for the
// duration of the call, so marking only the two that happen to dereference one
// today would draw a distinction a C caller cannot see and cannot act on. The
// safety contract is the file header, and it is the same for all of them.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{c_char, CStr, CString};
use std::panic::{self, AssertUnwindSafe};
use std::sync::{LazyLock, Mutex};

use serde_json::{json, Value};
use zeroize::{Zeroize, Zeroizing};

use crate::json;
use crate::manager::{parse_address, AccountCore, CoreError};
use crate::store::{Store, DEFAULT_STORE_URL};
use crate::vault::VaultError;

/// The opaque handle C holds.
pub struct LogosAccountCore(Mutex<AccountCore>);

/// One NUL-terminated copy of [`DEFAULT_STORE_URL`], so the pointer handed to C
/// outlives the call and the URL itself has one definition.
static DEFAULT_STORE_URL_C: LazyLock<CString> =
    LazyLock::new(|| CString::new(DEFAULT_STORE_URL).expect("the default store url has no NUL"));

/// The store this app points at when nothing else says otherwise. Static, so
/// the caller must not free it.
#[no_mangle]
pub extern "C" fn logos_account_core_default_store_url() -> *const c_char {
    DEFAULT_STORE_URL_C.as_ptr()
}

/// Open the vault at `vault_dir` and point the app at `store_url`. The literal
/// `memory` selects this process's own store, which is what a harness with no
/// network gets. Returns null only if an argument is not valid UTF-8.
#[no_mangle]
pub extern "C" fn logos_account_core_new(
    vault_dir: *const c_char,
    store_url: *const c_char,
) -> *mut LogosAccountCore {
    let Some(vault_dir) = str_arg(vault_dir) else {
        return std::ptr::null_mut();
    };
    let Some(store_url) = str_arg(store_url) else {
        return std::ptr::null_mut();
    };
    let core = AccountCore::new(vault_dir, Store::from_url(store_url));
    Box::into_raw(Box::new(LogosAccountCore(Mutex::new(core))))
}

/// Safe on null.
#[no_mangle]
pub extern "C" fn logos_account_core_free(core: *mut LogosAccountCore) {
    if !core.is_null() {
        drop(unsafe { Box::from_raw(core) });
    }
}

/// Clear and release any string returned by this library. Safe on null.
#[no_mangle]
pub extern "C" fn logos_account_core_string_free(text: *mut c_char) {
    if !text.is_null() {
        // A CString clears only its first byte on drop, and an exported key
        // sits further in.
        let mut bytes = unsafe { CString::from_raw(text) }.into_bytes_with_nul();
        bytes.zeroize();
    }
}

/// `{"ok":true,"store":"…","accounts":[{address,managed,protected,resolved,
/// displayName,pending,problem}]}`
#[no_mangle]
pub extern "C" fn logos_account_core_accounts(core: *mut LogosAccountCore) -> *mut c_char {
    reply(core, |core| {
        Ok(json!({
            "store": core.store().describe(),
            "accounts": core.accounts()?,
        }))
    })
}

/// Generate an account. A null `password` means the account chooses none, and
/// its key is then stored in the clear.
#[no_mangle]
pub extern "C" fn logos_account_core_create_account(
    core: *mut LogosAccountCore,
    password: *const c_char,
) -> *mut c_char {
    let password = optional_arg(password);
    reply(core, move |core| {
        let password = password?;
        let address = core.create_account(password.as_deref().map(String::as_str))?;
        Ok(json!({ "address": address.to_string() }))
    })
}

/// Take an account from the 32-byte secret its holder exported, as 64 hex
/// characters.
#[no_mangle]
pub extern "C" fn logos_account_core_import_account(
    core: *mut LogosAccountCore,
    secret_hex: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    let secret = required_arg(secret_hex);
    let password = optional_arg(password);
    reply(core, move |core| {
        let (secret, password) = (secret?, password?);
        let (address, held) =
            match core.import_account(&secret, password.as_deref().map(String::as_str)) {
                Ok(address) => (address, false),
                Err(CoreError::Vault(VaultError::AccountExists(address))) => (*address, true),
                Err(e) => return Err(e),
            };
        Ok(json!({ "address": address.to_string(), "alreadyHeld": held }))
    })
}

/// `{"ok":true,"key":"<64 hex>"}`. Whoever holds those bytes is the account.
#[no_mangle]
pub extern "C" fn logos_account_core_export_account(
    core: *mut LogosAccountCore,
    address: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    let password = optional_arg(password);
    reply(core, move |core| {
        let (addr, password) = (parse_address(&address?)?, password?);
        let key = core.export_account(&addr, password.as_deref().map(String::as_str))?;
        Ok(json!({ "key": key.as_str() }))
    })
}

/// Drop the account and its key. Nothing here can recover it.
#[no_mangle]
pub extern "C" fn logos_account_core_forget_account(
    core: *mut LogosAccountCore,
    address: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    reply(core, move |core| {
        core.forget_account(&parse_address(&address?)?)?;
        Ok(json!({}))
    })
}

/// Start reading the log under this address, whose key is somewhere else.
/// `{"ok":true,"alreadyObserved":false}` for an address not observed before.
#[no_mangle]
pub extern "C" fn logos_account_core_observe_account(
    core: *mut LogosAccountCore,
    address: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    reply(core, move |core| {
        let added = core.observe(&parse_address(&address?)?)?;
        Ok(json!({ "alreadyObserved": !added }))
    })
}

/// Stop reading the log under this address. Drops what was read, and nothing
/// the store does not still hold.
#[no_mangle]
pub extern "C" fn logos_account_core_stop_observing(
    core: *mut LogosAccountCore,
    address: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    reply(core, move |core| {
        core.stop_observing(&parse_address(&address?)?)?;
        Ok(json!({}))
    })
}

/// Read the store for this account, and drop the staged edits it already holds.
#[no_mangle]
pub extern "C" fn logos_account_core_refresh(
    core: *mut LogosAccountCore,
    address: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    reply(core, move |core| {
        let dropped = core.refresh(&parse_address(&address?)?)?;
        Ok(json!({ "dropped": dropped }))
    })
}

/// `{"ok":true,"state":{…}}`: everything the Manage pane draws for one
/// account, from what is already held. Reads no store.
#[no_mangle]
pub extern "C" fn logos_account_core_state(
    core: *mut LogosAccountCore,
    address: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    reply(core, move |core| {
        Ok(json!({ "state": core.state(&parse_address(&address?)?)? }))
    })
}

/// Stage an endorsement of an installation's public key, as 64 hex characters.
#[no_mangle]
pub extern "C" fn logos_account_core_stage_add_installation(
    core: *mut LogosAccountCore,
    address: *const c_char,
    key_hex: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    let key = required_arg(key_hex);
    reply(core, move |core| {
        core.stage_add_installation(&parse_address(&address?)?, &key?)?;
        Ok(json!({}))
    })
}

/// Stage the display name. Replaces any name already staged.
#[no_mangle]
pub extern "C" fn logos_account_core_stage_set_display_name(
    core: *mut LogosAccountCore,
    address: *const c_char,
    name: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    let name = required_arg(name);
    reply(core, move |core| {
        core.stage_set_display_name(&parse_address(&address?)?, &name?)?;
        Ok(json!({}))
    })
}

/// Stage a revocation of the entry at `index`, which must be live now.
#[no_mangle]
pub extern "C" fn logos_account_core_stage_revoke(
    core: *mut LogosAccountCore,
    address: *const c_char,
    index: u32,
) -> *mut c_char {
    let address = required_arg(address);
    reply(core, move |core| {
        core.stage_revoke(&parse_address(&address?)?, index)?;
        Ok(json!({}))
    })
}

/// Throw away everything staged for this account. Nothing was written.
#[no_mangle]
pub extern "C" fn logos_account_core_discard_pending(
    core: *mut LogosAccountCore,
    address: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    reply(core, move |core| {
        core.discard_pending(&parse_address(&address?)?)?;
        Ok(json!({}))
    })
}

/// Read the store, then sign and publish every staged edit it does not already
/// hold as one update. All or nothing: one rejected entry writes none of them.
#[no_mangle]
pub extern "C" fn logos_account_core_publish(
    core: *mut LogosAccountCore,
    address: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    let address = required_arg(address);
    let password = optional_arg(password);
    reply(core, move |core| {
        let (addr, password) = (parse_address(&address?)?, password?);
        let published = core.publish(&addr, password.as_deref().map(String::as_str))?;
        Ok(json!({
            "firstNewIndex": published.first_new_index,
            "dropped": published.dropped,
        }))
    })
}

/// Run `call` against the handle and render whatever it says as a reply. The
/// three properties at the top of this file all live here.
fn reply(
    core: *mut LogosAccountCore,
    call: impl FnOnce(&mut AccountCore) -> Result<Value, CoreError>,
) -> *mut c_char {
    let Some(handle) = (unsafe { core.as_ref() }) else {
        return failed("no account core");
    };
    let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
        let mut core = handle
            .0
            .lock()
            .map_err(|_| "the account core is poisoned")?;
        call(&mut core).map_err(|e| e.to_string())
    }));
    match outcome {
        Ok(Ok(mut value)) => {
            let object = value.as_object_mut().expect("replies are JSON objects");
            object.insert("ok".into(), Value::Bool(true));
            render(value)
        }
        Ok(Err(error)) => failed(&error),
        Err(_) => failed("the account core panicked"),
    }
}

fn failed(error: &str) -> *mut c_char {
    render(json!({ "ok": false, "error": error }))
}

fn render(mut value: Value) -> *mut c_char {
    let mut bytes = json::to_vec_sized(&value, 1);
    bytes.push(0);
    scrub(&mut value);
    // Every value here is serde_json's own output, so the only way to hold an
    // interior NUL would be for a caller-supplied string to carry one, and a
    // CStr cannot.
    CString::from_vec_with_nul(bytes)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// Clear every string a reply held, an exported key among them.
fn scrub(value: &mut Value) {
    match value {
        Value::String(text) => text.zeroize(),
        Value::Array(items) => items.iter_mut().for_each(scrub),
        Value::Object(fields) => fields.values_mut().for_each(scrub),
        _ => {}
    }
}

fn str_arg<'a>(text: *const c_char) -> Option<&'a str> {
    if text.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(text) }.to_str().ok()
}

/// A missing or non-UTF-8 argument, deferred so it is reported as a reply
/// rather than swallowed. Copied into memory that is cleared on drop, since
/// some arguments are secrets.
fn required_arg(text: *const c_char) -> Result<Zeroizing<String>, CoreError> {
    str_arg(text)
        .map(|text| Zeroizing::new(text.to_owned()))
        .ok_or(CoreError::Argument)
}

/// An argument whose absence is meaningful: no password, rather than a bad
/// one. A present one that is not UTF-8 is still refused, not read as absent.
fn optional_arg(text: *const c_char) -> Result<Option<Zeroizing<String>>, CoreError> {
    if text.is_null() {
        return Ok(None);
    }
    required_arg(text).map(Some)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn call(reply: *mut c_char) -> Value {
        let text = unsafe { CStr::from_ptr(reply) }
            .to_str()
            .unwrap()
            .to_owned();
        logos_account_core_string_free(reply);
        serde_json::from_str(&text).unwrap()
    }

    fn c(text: &str) -> CString {
        CString::new(text).unwrap()
    }

    fn core(dir: &std::path::Path) -> *mut LogosAccountCore {
        logos_account_core_new(c(dir.to_str().unwrap()).as_ptr(), c("memory").as_ptr())
    }

    /// The three properties at the top of this file, on the path that is
    /// easiest to get wrong: a caller that passes nothing at all.
    #[test]
    fn a_null_handle_is_answered_rather_than_dereferenced() {
        let reply = call(logos_account_core_accounts(std::ptr::null_mut()));
        assert_eq!(reply["ok"], false);
        assert!(reply["error"].is_string());
    }

    #[test]
    fn a_null_argument_is_answered() {
        let tmp = tempfile::tempdir().unwrap();
        let core = core(tmp.path());
        let reply = call(logos_account_core_state(core, std::ptr::null()));
        assert_eq!(reply["ok"], false);
        logos_account_core_free(core);
    }

    /// Read as absent, such a password would store the key in the clear.
    #[test]
    fn a_password_that_is_not_utf8_is_refused_rather_than_dropped() {
        let tmp = tempfile::tempdir().unwrap();
        let core = core(tmp.path());
        let password = c"\xff\xfepw";

        let created = call(logos_account_core_create_account(core, password.as_ptr()));
        assert_eq!(created["ok"], false);
        assert!(call(logos_account_core_accounts(core))["accounts"]
            .as_array()
            .unwrap()
            .is_empty());
        logos_account_core_free(core);
    }

    #[test]
    fn a_created_account_is_listed_and_can_be_exported() {
        let tmp = tempfile::tempdir().unwrap();
        let core = core(tmp.path());

        let created = call(logos_account_core_create_account(core, c("pw").as_ptr()));
        assert_eq!(created["ok"], true);
        let address = created["address"].as_str().unwrap().to_owned();

        let listed = call(logos_account_core_accounts(core));
        assert_eq!(listed["store"], "memory");
        assert_eq!(listed["accounts"][0]["address"], address.as_str());
        assert_eq!(listed["accounts"][0]["protected"], true);

        let exported = call(logos_account_core_export_account(
            core,
            c(&address).as_ptr(),
            c("pw").as_ptr(),
        ));
        assert_eq!(exported["key"].as_str().unwrap().len(), 64);

        logos_account_core_free(core);
    }

    /// Kept as it is, whatever password came with it this time.
    #[test]
    fn importing_an_account_already_held_finds_it() {
        let tmp = tempfile::tempdir().unwrap();
        let core = core(tmp.path());
        let created = call(logos_account_core_create_account(core, std::ptr::null()));
        let address = c(created["address"].as_str().unwrap());
        let key = call(logos_account_core_export_account(
            core,
            address.as_ptr(),
            std::ptr::null(),
        ));

        let imported = call(logos_account_core_import_account(
            core,
            c(key["key"].as_str().unwrap()).as_ptr(),
            c("pw").as_ptr(),
        ));
        assert_eq!(imported["ok"], true);
        assert_eq!(imported["address"], created["address"]);
        assert_eq!(imported["alreadyHeld"], true);
        assert_eq!(
            call(logos_account_core_accounts(core))["accounts"][0]["protected"],
            false
        );
        logos_account_core_free(core);
    }

    /// One trip through the whole surface, in the order the Manage pane makes
    /// the calls.
    #[test]
    fn staging_and_publishing_round_trips_through_the_abi() {
        let tmp = tempfile::tempdir().unwrap();
        let core = core(tmp.path());
        let address = call(logos_account_core_create_account(core, std::ptr::null()))["address"]
            .as_str()
            .unwrap()
            .to_owned();
        let addr = c(&address);
        let installation = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";

        assert_eq!(
            call(logos_account_core_stage_add_installation(
                core,
                addr.as_ptr(),
                c(installation).as_ptr()
            ))["ok"],
            true
        );
        assert_eq!(
            call(logos_account_core_stage_set_display_name(
                core,
                addr.as_ptr(),
                c("Saro").as_ptr()
            ))["ok"],
            true
        );

        let staged = call(logos_account_core_state(core, addr.as_ptr()));
        assert_eq!(staged["state"]["pending"].as_array().unwrap().len(), 2);
        assert_eq!(staged["state"]["published"], false);

        assert_eq!(
            call(logos_account_core_publish(
                core,
                addr.as_ptr(),
                std::ptr::null()
            ))["ok"],
            true
        );

        let published = call(logos_account_core_state(core, addr.as_ptr()))["state"].clone();
        assert_eq!(published["published"], true);
        assert_eq!(published["displayName"], "Saro");
        assert_eq!(published["installations"][0]["key"], installation);
        assert!(published["pending"].as_array().unwrap().is_empty());
        assert!(published["logBytes"].as_u64().unwrap() > 0);

        logos_account_core_free(core);
    }

    /// The observe route through the ABI, on the one account a hermetic test
    /// can have a store already holding: this app's own, published and then
    /// forgotten, which leaves the log where the store keeps it.
    #[test]
    fn an_observed_account_round_trips_through_the_abi() {
        let tmp = tempfile::tempdir().unwrap();
        let core = core(tmp.path());
        let address = call(logos_account_core_create_account(core, std::ptr::null()))["address"]
            .as_str()
            .unwrap()
            .to_owned();
        let addr = c(&address);
        call(logos_account_core_stage_set_display_name(
            core,
            addr.as_ptr(),
            c("Raya").as_ptr(),
        ));
        call(logos_account_core_publish(
            core,
            addr.as_ptr(),
            std::ptr::null(),
        ));
        call(logos_account_core_forget_account(core, addr.as_ptr()));

        let observed = call(logos_account_core_observe_account(core, addr.as_ptr()));
        assert_eq!(observed["ok"], true);
        assert_eq!(observed["alreadyObserved"], false);
        assert_eq!(
            call(logos_account_core_observe_account(core, addr.as_ptr()))["alreadyObserved"],
            true
        );

        let listed = call(logos_account_core_accounts(core))["accounts"][0].clone();
        assert_eq!(listed["address"], address.as_str());
        assert_eq!(listed["managed"], false);
        assert_eq!(listed["protected"], false);

        assert_eq!(
            call(logos_account_core_refresh(core, addr.as_ptr()))["ok"],
            true
        );
        let state = call(logos_account_core_state(core, addr.as_ptr()))["state"].clone();
        assert_eq!(state["managed"], false);
        assert_eq!(state["displayName"], "Raya");
        assert!(state["readAtMs"].as_u64().unwrap() > 0);
        assert_eq!(state["problem"], serde_json::Value::Null);

        let refused = call(logos_account_core_stage_set_display_name(
            core,
            addr.as_ptr(),
            c("Saro").as_ptr(),
        ));
        assert_eq!(refused["ok"], false);

        assert_eq!(
            call(logos_account_core_stop_observing(core, addr.as_ptr()))["ok"],
            true
        );
        assert!(call(logos_account_core_accounts(core))["accounts"]
            .as_array()
            .unwrap()
            .is_empty());

        logos_account_core_free(core);
    }
}
