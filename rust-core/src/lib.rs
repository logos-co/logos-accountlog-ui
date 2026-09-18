//! The account write path as a linkable library.
//!
//! This crate is the whole of what logos-accountlog-ui does with an account:
//! it holds the keys, stages edits to a log, signs them and publishes them.
//! The C++ half above it renders and takes input, and makes no decision about
//! an account that is not made here.

mod json;
pub mod manager;
pub mod store;
pub mod vault;

pub use manager::{AccountCore, AccountState, AccountSummary, CoreError, MAX_DISPLAY_NAME_BYTES};
pub use store::{Store, StoreError, DEFAULT_STORE_URL};
pub use vault::{StoredAccount, Vault, VaultError};
