//! The accounts this app reads and holds no key for, on disk.
//!
//! An observed account is an address and nothing else: whatever the store
//! serves under it, verified against it. So this is one document listing
//! addresses, rather than the vault's file per account, and it carries no
//! secret.
//!
//! It is written whole and renamed into place, so a reader sees one list or
//! the previous one and never half of either. Two instances of the app adding
//! at the same moment can lose one address, which the person adds again; the
//! vault's lock guards a key that cannot be recovered, and this is not that.

use std::fs;
use std::io;
use std::path::PathBuf;

use account_log::AccountAddr;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::vault::set_mode;

const FILE: &str = "observed.json";
/// Written beside the list and renamed over it, so a crash mid-write cannot
/// leave a truncated list under the real name.
const STAGED_FILE: &str = ".observed.json.new";
const VERSION: u32 = 1;

#[derive(Debug, Error)]
pub enum ObservedError {
    /// Present, but not a list this app wrote.
    #[error("unreadable list of observed accounts: {0}")]
    Corrupt(String),
    #[error("observed accounts i/o: {0}")]
    Io(#[from] io::Error),
}

#[derive(Serialize, Deserialize)]
struct Document {
    #[serde(default)]
    logos_account_observed: u32,
    addresses: Vec<String>,
}

/// The directory the list of observed accounts is kept in, which is the
/// vault's: one directory is this app's data, whether or not a given account
/// in it has a key here.
pub struct ObservedAccounts {
    dir: PathBuf,
}

impl ObservedAccounts {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// Every address observed, in address order. No file is no accounts, which
    /// is what a first run has.
    pub fn list(&self) -> Result<Vec<AccountAddr>, ObservedError> {
        let text = match fs::read_to_string(self.dir.join(FILE)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            text => text?,
        };
        let document: Document =
            serde_json::from_str(&text).map_err(|e| ObservedError::Corrupt(e.to_string()))?;
        if document.logos_account_observed != VERSION {
            return Err(ObservedError::Corrupt(
                "not a list this version writes".into(),
            ));
        }
        let mut addresses: Vec<AccountAddr> = document
            .addresses
            .iter()
            .map(|address| {
                address
                    .parse()
                    .map_err(|_| ObservedError::Corrupt(format!("{address} is not an address")))
            })
            .collect::<Result<_, _>>()?;
        addresses.sort_by_key(AccountAddr::to_string);
        addresses.dedup();
        Ok(addresses)
    }

    /// Start observing `addr`. Answers whether it was not already observed.
    pub fn add(&self, addr: &AccountAddr) -> Result<bool, ObservedError> {
        let mut observed = self.list()?;
        if observed.contains(addr) {
            return Ok(false);
        }
        observed.push(addr.clone());
        self.write(&observed)?;
        Ok(true)
    }

    /// Stop observing `addr`. Answers whether it was observed at all.
    pub fn remove(&self, addr: &AccountAddr) -> Result<bool, ObservedError> {
        let mut observed = self.list()?;
        let before = observed.len();
        observed.retain(|held| held != addr);
        if observed.len() == before {
            return Ok(false);
        }
        self.write(&observed)?;
        Ok(true)
    }

    fn write(&self, observed: &[AccountAddr]) -> Result<(), ObservedError> {
        let mut addresses: Vec<String> = observed.iter().map(AccountAddr::to_string).collect();
        addresses.sort();
        let document = serde_json::to_vec(&Document {
            logos_account_observed: VERSION,
            addresses,
        })
        .expect("a list of addresses serializes");

        fs::create_dir_all(&self.dir)?;
        set_mode(&self.dir, 0o700)?;
        let staged = self.dir.join(STAGED_FILE);
        fs::write(&staged, &document)?;
        set_mode(&staged, 0o600)?;
        fs::File::options().write(true).open(&staged)?.sync_all()?;
        fs::rename(&staged, self.dir.join(FILE))?;
        // Best effort: without it the rename is atomic but may not survive a
        // power cut.
        let _ = fs::File::open(&self.dir).and_then(|dir| dir.sync_all());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use account_log::Ed25519SigningKey;

    fn observed() -> (tempfile::TempDir, ObservedAccounts) {
        let tmp = tempfile::tempdir().unwrap();
        let observed = ObservedAccounts::new(tmp.path().join("vault"));
        (tmp, observed)
    }

    fn addr() -> AccountAddr {
        AccountAddr::from(&Ed25519SigningKey::generate().verifying_key())
    }

    #[test]
    fn a_first_run_observes_nothing() {
        let (_tmp, observed) = observed();
        assert_eq!(observed.list().unwrap(), Vec::new());
    }

    #[test]
    fn an_address_added_is_read_back() {
        let (_tmp, observed) = observed();
        let addr = addr();

        assert!(observed.add(&addr).unwrap());

        assert_eq!(observed.list().unwrap(), vec![addr]);
    }

    #[test]
    fn adding_twice_adds_one() {
        let (_tmp, observed) = observed();
        let addr = addr();

        assert!(observed.add(&addr).unwrap());
        assert!(!observed.add(&addr).unwrap());

        assert_eq!(observed.list().unwrap(), vec![addr]);
    }

    #[test]
    fn removing_leaves_the_others() {
        let (_tmp, observed) = observed();
        let (one, two) = (addr(), addr());
        observed.add(&one).unwrap();
        observed.add(&two).unwrap();

        assert!(observed.remove(&one).unwrap());
        assert!(!observed.remove(&one).unwrap());

        assert_eq!(observed.list().unwrap(), vec![two]);
    }

    /// The list is one order whatever order it was written in, so the switcher
    /// does not reshuffle when an account is added.
    #[test]
    fn the_list_is_in_address_order() {
        let (_tmp, observed) = observed();
        let mut added: Vec<AccountAddr> = (0..4).map(|_| addr()).collect();
        for addr in &added {
            observed.add(addr).unwrap();
        }
        added.sort_by_key(AccountAddr::to_string);

        assert_eq!(observed.list().unwrap(), added);
    }

    #[test]
    fn a_document_from_another_version_is_refused() {
        let (_tmp, observed) = observed();
        fs::create_dir_all(&observed.dir).unwrap();
        fs::write(
            observed.dir.join(FILE),
            br#"{"logos_account_observed":2,"addresses":[]}"#,
        )
        .unwrap();

        assert!(matches!(observed.list(), Err(ObservedError::Corrupt(_))));
    }

    /// The file names addresses, so a name that is not one is a file this app
    /// must not act on rather than an entry to skip.
    #[test]
    fn a_line_that_is_not_an_address_is_refused() {
        let (_tmp, observed) = observed();
        fs::create_dir_all(&observed.dir).unwrap();
        fs::write(
            observed.dir.join(FILE),
            br#"{"logos_account_observed":1,"addresses":["nonsense"]}"#,
        )
        .unwrap();

        assert!(matches!(observed.list(), Err(ObservedError::Corrupt(_))));
    }

    /// The vault reads the same directory and must not take this for an
    /// account file.
    #[test]
    fn the_list_is_not_an_account_the_vault_holds() {
        let (_tmp, observed) = observed();
        observed.add(&addr()).unwrap();

        let vault = crate::vault::Vault::new(&observed.dir);

        assert_eq!(vault.accounts().unwrap(), Vec::new());
    }
}
