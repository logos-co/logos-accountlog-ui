//! The account keys this app holds, on disk.
//!
//! One file per account, named after its address, so the address is known
//! without opening anything. A password is the account's own choice: with one,
//! the file is a Web3 Secret Storage v3 keystore; without one, it is a small
//! document that says in as many words that it holds the key. Both are written
//! the same way, opened through the same call, and carry the same permissions;
//! the two spellings exist so that an unprotected key cannot be mistaken on
//! sight for a sealed one.
//!
//! A key is decrypted for one call and dropped.

use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use account_log::{AccountAddr, Ed25519SigningKey};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use zeroize::Zeroizing;

use crate::json;

const LOCK_FILE: &str = ".lock";
const STAGED_FILE: &str = "vault.json";
const LOCK_WAIT: Duration = Duration::from_secs(1);

/// Marks the file of an account that chose no password.
const OPEN_SUFFIX: &str = ".open.json";
const SEALED_SUFFIX: &str = ".json";

/// Ceilings on the scrypt work a vault file may ask for: anything running as
/// this user can replace the file, and eth-keystore passes its parameters to
/// scrypt unchecked.
const MAX_SCRYPT_N: u64 = 1 << 18;
const MAX_SCRYPT_R: u64 = 16;
const MAX_SCRYPT_P: u64 = 16;
/// n * r * p at geth's standard parameters, 32 times what this vault writes:
/// the core answers no other call while it derives. It bounds memory at 256
/// MiB too.
const MAX_SCRYPT_WORK: u64 = (1 << 18) * 8;

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("the vault holds no such account")]
    NoAccount,
    /// Boxed: an address holds a decompressed curve point.
    #[error("the vault already holds this account")]
    AccountExists(Box<AccountAddr>),
    #[error("an empty string is not a password")]
    EmptyPassword,
    #[error("this account has a password")]
    PasswordRequired,
    #[error("this account has no password")]
    PasswordNotRequired,
    #[error("wrong password")]
    WrongPassword,
    /// Present, but not a vault this app can open.
    #[error("unreadable vault: {0}")]
    Corrupt(String),
    #[error("vault i/o: {0}")]
    Io(#[from] io::Error),
}

/// An account the vault holds, and whether opening it takes a password.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredAccount {
    pub addr: AccountAddr,
    pub protected: bool,
}

/// The directory this app keeps account keys in.
pub struct Vault {
    dir: PathBuf,
}

impl Vault {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// Every account held, in address order, read from the file names alone.
    pub fn accounts(&self) -> Result<Vec<StoredAccount>, VaultError> {
        let entries = match fs::read_dir(&self.dir) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            entries => entries?,
        };
        let mut held: Vec<StoredAccount> = Vec::new();
        for entry in entries {
            let name = entry?.file_name();
            let Some(name) = name.to_str() else { continue };
            let Some((stem, protected)) = name
                .strip_suffix(OPEN_SUFFIX)
                .map(|stem| (stem, false))
                .or_else(|| name.strip_suffix(SEALED_SUFFIX).map(|stem| (stem, true)))
            else {
                continue;
            };
            // Not an account's file: a copy a file manager made beside one, say.
            let Ok(addr) = stem.parse::<AccountAddr>() else {
                continue;
            };
            if held.iter().any(|held| held.addr == addr) {
                return Err(VaultError::Corrupt(format!(
                    "{addr} is held both with and without a password"
                )));
            }
            held.push(StoredAccount { addr, protected });
        }
        held.sort_by_key(|held| held.addr.to_string());
        Ok(held)
    }

    /// Take `key` into the vault, under `password` when there is one. Refused
    /// when the account is already held, so a key is never replaced.
    pub fn create(
        &self,
        key: &Ed25519SigningKey,
        password: Option<&str>,
    ) -> Result<AccountAddr, VaultError> {
        if password == Some("") {
            return Err(VaultError::EmptyPassword);
        }
        let addr = AccountAddr::from(&key.verifying_key());
        fs::create_dir_all(&self.dir)?;
        set_mode(&self.dir, 0o700)?;

        // Written before the lock is taken: scrypt is slow, and the lock only
        // has to cover the check and the rename.
        let stage = Stage::create(&self.dir.join(format!(".stage-{addr}")))?;
        match password {
            Some(password) => stage.seal(key, password)?,
            None => stage.write_open(&addr, key)?,
        }

        let _lock = self.lock()?;
        if self.accounts()?.iter().any(|held| held.addr == addr) {
            return Err(VaultError::AccountExists(Box::new(addr)));
        }
        stage.promote(&self.path_of(&addr, password.is_some()))?;
        Ok(addr)
    }

    /// The key of `addr`, for the caller to use and drop. `password` must match
    /// what the account chose: supplying one it does not have, or omitting one
    /// it does, is refused rather than guessed at.
    pub fn open(
        &self,
        addr: &AccountAddr,
        password: Option<&str>,
    ) -> Result<Ed25519SigningKey, VaultError> {
        let held = self
            .accounts()?
            .into_iter()
            .find(|held| &held.addr == addr)
            .ok_or(VaultError::NoAccount)?;
        let path = self.path_of(addr, held.protected);

        let key = match (held.protected, password) {
            (true, Some(password)) => {
                check_params(&fs::read_to_string(&path)?)?;
                let secret = Zeroizing::new(eth_keystore::decrypt_key(&path, password).map_err(
                    |e| match e {
                        eth_keystore::KeystoreError::MacMismatch => VaultError::WrongPassword,
                        other => VaultError::Corrupt(other.to_string()),
                    },
                )?);
                let bytes: &[u8; 32] = secret.as_slice().try_into().map_err(|_| {
                    VaultError::Corrupt(format!("the sealed key is {} bytes, not 32", secret.len()))
                })?;
                Ed25519SigningKey::from_bytes(bytes)
            }
            (false, None) => read_open(&path)?,
            (true, None) => return Err(VaultError::PasswordRequired),
            (false, Some(_)) => return Err(VaultError::PasswordNotRequired),
        };

        // The file name is a claim; the key is the proof.
        if &AccountAddr::from(&key.verifying_key()) != addr {
            return Err(VaultError::Corrupt(format!(
                "the file named for {addr} holds another account's key"
            )));
        }
        Ok(key)
    }

    /// Drop `addr` from the vault. The key is gone with it: nothing here can
    /// recover it, and the log it signed can never be extended again.
    pub fn forget(&self, addr: &AccountAddr) -> Result<(), VaultError> {
        let held = self
            .accounts()?
            .into_iter()
            .find(|held| &held.addr == addr)
            .ok_or(VaultError::NoAccount)?;
        let _lock = self.lock()?;
        fs::remove_file(self.path_of(addr, held.protected))?;
        Ok(())
    }

    fn path_of(&self, addr: &AccountAddr, protected: bool) -> PathBuf {
        let suffix = if protected {
            SEALED_SUFFIX
        } else {
            OPEN_SUFFIX
        };
        self.dir.join(format!("{addr}{suffix}"))
    }

    /// Held across a create's check and rename, so two processes cannot both
    /// find the account absent. Released when the file closes.
    fn lock(&self) -> Result<File, VaultError> {
        let file = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.dir.join(LOCK_FILE))?;
        let deadline = Instant::now() + LOCK_WAIT;
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(file),
                Err(fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(25))
                }
                Err(fs::TryLockError::WouldBlock) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WouldBlock,
                        "another process is writing to this vault",
                    )
                    .into());
                }
                Err(fs::TryLockError::Error(e)) => return Err(e.into()),
            }
        }
    }
}

/// What an account without a password is stored as. Every field is redundant
/// with the file name except `key`, and `key` is the whole point: a reader is
/// meant to see at a glance that this file is the account.
const OPEN_WARNING: &str =
    "This file holds the account key in the clear. Anything that can read it is this account.";

#[derive(Serialize)]
struct OpenDocument<'a> {
    logos_account_vault: u32,
    address: String,
    protection: &'a str,
    key: &'a str,
    warning: &'a str,
}

fn write_open_document(addr: &AccountAddr, key: &Ed25519SigningKey) -> Zeroizing<Vec<u8>> {
    let secret = Zeroizing::new(key.DANGER_to_bytes());
    let mut hex_key = Zeroizing::new([0u8; 64]);
    hex::encode_to_slice(secret.as_slice(), hex_key.as_mut_slice())
        .expect("32 bytes are 64 hex characters");
    Zeroizing::new(json::to_vec_sized(
        &OpenDocument {
            logos_account_vault: 1,
            address: addr.to_string(),
            protection: "none",
            key: std::str::from_utf8(hex_key.as_slice()).expect("hex is ASCII"),
            warning: OPEN_WARNING,
        },
        0,
    ))
}

/// What `read_open` takes from the document. The key is parsed out of the
/// file's text into one allocation, which is cleared on drop, a parse that
/// fails after it included.
#[derive(Deserialize)]
struct ReadOpenDocument {
    #[serde(default)]
    logos_account_vault: u32,
    key: Option<Zeroizing<String>>,
}

fn read_open(path: &Path) -> Result<Ed25519SigningKey, VaultError> {
    let corrupt = |why: &str| VaultError::Corrupt(why.into());
    let text = Zeroizing::new(fs::read_to_string(path)?);
    let document: ReadOpenDocument =
        serde_json::from_str(&text).map_err(|e| VaultError::Corrupt(e.to_string()))?;
    if document.logos_account_vault != 1 {
        return Err(corrupt("not a vault document this version writes"));
    }
    let hex_key = document
        .key
        .as_deref()
        .ok_or_else(|| corrupt("the document carries no key"))?;
    let mut secret = Zeroizing::new([0u8; 32]);
    hex::decode_to_slice(hex_key, secret.as_mut_slice()).map_err(|e| match e {
        hex::FromHexError::InvalidHexCharacter { .. } => corrupt("the key is not hex"),
        _ => VaultError::Corrupt(format!(
            "the key is {} hex characters, not 64",
            hex_key.len()
        )),
    })?;
    Ok(Ed25519SigningKey::from_bytes(&secret))
}

/// A private directory the vault file is written into and renamed out of:
/// a crash mid-write would otherwise leave a truncated file under a real name.
/// Removed on drop.
struct Stage(PathBuf);

impl Stage {
    fn create(dir: &Path) -> Result<Self, VaultError> {
        let _ = fs::remove_dir_all(dir);
        fs::create_dir(dir)?;
        let stage = Self(dir.to_owned());
        set_mode(dir, 0o700)?;
        Ok(stage)
    }

    fn seal(&self, key: &Ed25519SigningKey, password: &str) -> Result<(), VaultError> {
        let secret = Zeroizing::new(key.DANGER_to_bytes());
        eth_keystore::encrypt_key(
            &self.0,
            &mut rand::thread_rng(),
            secret.as_slice(),
            password,
            Some(STAGED_FILE),
        )
        .map_err(io::Error::other)?;
        Ok(())
    }

    fn write_open(&self, addr: &AccountAddr, key: &Ed25519SigningKey) -> Result<(), VaultError> {
        let document = write_open_document(addr, key);
        fs::write(self.0.join(STAGED_FILE), document.as_slice())?;
        Ok(())
    }

    fn promote(&self, dest: &Path) -> Result<(), VaultError> {
        let staged = self.0.join(STAGED_FILE);
        set_mode(&staged, 0o600)?;
        File::options().write(true).open(&staged)?.sync_all()?;
        fs::rename(&staged, dest)?;
        // Best effort: without it the rename is atomic but may not survive a
        // power cut.
        if let Some(parent) = dest.parent() {
            let _ = File::open(parent).and_then(|dir| dir.sync_all());
        }
        Ok(())
    }
}

impl Drop for Stage {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Refuses parameters that would make decryption panic or exhaust memory,
/// before any derivation runs.
fn check_params(json: &str) -> Result<(), VaultError> {
    let corrupt = |why: &str| Err(VaultError::Corrupt(why.into()));
    let vault: serde_json::Value =
        serde_json::from_str(json).map_err(|e| VaultError::Corrupt(e.to_string()))?;
    let crypto = &vault["crypto"];
    if crypto["kdf"] != "scrypt" {
        return corrupt("the key derivation is not scrypt");
    }
    // eth-keystore reads the parameters without the `kdf` beside them, and
    // takes them as PBKDF2's, at an iteration count the file picks, whenever
    // PBKDF2's fields are there.
    let scrypt_only = crypto["kdfparams"].as_object().is_some_and(|params| {
        params
            .keys()
            .all(|name| ["dklen", "n", "r", "p", "salt"].contains(&name.as_str()))
    });
    if !scrypt_only {
        return corrupt("the key derivation parameters are not scrypt's");
    }
    let param = |name: &str| crypto["kdfparams"][name].as_u64();
    let (Some(dklen), Some(n), Some(r), Some(p)) =
        (param("dklen"), param("n"), param("r"), param("p"))
    else {
        return corrupt("scrypt parameters are missing");
    };
    // decrypt_key slices the derived key at 32 bytes and the IV at 16.
    let iv_bytes = crypto["cipherparams"]["iv"].as_str().map_or(0, str::len) / 2;
    if dklen != 32 || iv_bytes != 16 {
        return corrupt("the derived key or IV length is wrong");
    }
    if !n.is_power_of_two()
        || n > MAX_SCRYPT_N
        || r > MAX_SCRYPT_R
        || p > MAX_SCRYPT_P
        || n * r * p > MAX_SCRYPT_WORK
    {
        return corrupt("scrypt parameters are out of range");
    }
    Ok(())
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_mode(_: &Path, _: u32) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault() -> (tempfile::TempDir, Vault) {
        let tmp = tempfile::tempdir().unwrap();
        let vault = Vault::new(tmp.path().join("keystore"));
        (tmp, vault)
    }

    fn addr_of(key: &Ed25519SigningKey) -> AccountAddr {
        AccountAddr::from(&key.verifying_key())
    }

    fn addresses(vault: &Vault) -> Vec<AccountAddr> {
        vault
            .accounts()
            .unwrap()
            .into_iter()
            .map(|held| held.addr)
            .collect()
    }

    /// Rewrites a sealed vault file's JSON in place.
    fn tamper(vault: &Vault, addr: &AccountAddr, edit: impl FnOnce(&mut serde_json::Value)) {
        let path = vault.path_of(addr, true);
        let mut json: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        edit(&mut json);
        fs::write(&path, json.to_string()).unwrap();
    }

    #[test]
    fn a_vault_that_was_never_created_holds_nothing() {
        let (_tmp, vault) = vault();
        let absent = addr_of(&Ed25519SigningKey::generate());
        assert_eq!(vault.accounts().unwrap(), vec![]);
        assert!(matches!(
            vault.open(&absent, Some("pw")),
            Err(VaultError::NoAccount)
        ));
    }

    #[test]
    fn a_created_account_opens_with_its_password() {
        let (_tmp, vault) = vault();
        let key = Ed25519SigningKey::generate();

        let addr = vault.create(&key, Some("correct horse")).unwrap();

        assert_eq!(addr, addr_of(&key));
        assert_eq!(
            vault.accounts().unwrap(),
            vec![StoredAccount {
                addr: addr.clone(),
                protected: true
            }]
        );
        let opened = vault.open(&addr, Some("correct horse")).unwrap();
        assert_eq!(opened.DANGER_to_bytes(), key.DANGER_to_bytes());
    }

    #[test]
    fn a_wrong_password_is_refused() {
        let (_tmp, vault) = vault();
        let addr = vault
            .create(&Ed25519SigningKey::generate(), Some("correct horse"))
            .unwrap();
        assert!(matches!(
            vault.open(&addr, Some("battery staple")),
            Err(VaultError::WrongPassword)
        ));
    }

    /// An empty string is the caller meaning `None` and saying it badly, so it
    /// is refused rather than sealed under a password nobody chose.
    #[test]
    fn an_empty_password_is_not_a_password() {
        let (_tmp, vault) = vault();
        assert!(matches!(
            vault.create(&Ed25519SigningKey::generate(), Some("")),
            Err(VaultError::EmptyPassword)
        ));
        assert_eq!(addresses(&vault), vec![]);
    }

    #[test]
    fn an_account_without_a_password_opens_without_one() {
        let (_tmp, vault) = vault();
        let key = Ed25519SigningKey::generate();

        let addr = vault.create(&key, None).unwrap();

        assert_eq!(
            vault.accounts().unwrap(),
            vec![StoredAccount {
                addr: addr.clone(),
                protected: false
            }]
        );
        assert_eq!(
            vault.open(&addr, None).unwrap().DANGER_to_bytes(),
            key.DANGER_to_bytes()
        );
    }

    /// The point of the second spelling: the file says what it is holding, so
    /// a copy of it cannot be mistaken for a sealed keystore.
    #[test]
    fn an_unprotected_file_shows_the_key_it_holds() {
        let (_tmp, vault) = vault();
        let key = Ed25519SigningKey::generate();
        let addr = vault.create(&key, None).unwrap();

        let text = fs::read_to_string(vault.path_of(&addr, false)).unwrap();

        assert!(text.contains(&hex::encode(key.DANGER_to_bytes())));
        assert!(text.contains(OPEN_WARNING));
    }

    /// Protection is the account's, and the caller is held to it either way: a
    /// prompt that should not have appeared is a bug worth seeing.
    #[test]
    fn the_password_must_match_what_the_account_chose() {
        let (_tmp, vault) = vault();
        let sealed = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        let open = vault.create(&Ed25519SigningKey::generate(), None).unwrap();

        assert!(matches!(
            vault.open(&sealed, None),
            Err(VaultError::PasswordRequired)
        ));
        assert!(matches!(
            vault.open(&open, Some("pw")),
            Err(VaultError::PasswordNotRequired)
        ));
    }

    /// One vault, some accounts sealed and some not.
    #[test]
    fn accounts_with_and_without_passwords_live_side_by_side() {
        let (_tmp, vault) = vault();
        let (first, second) = (Ed25519SigningKey::generate(), Ed25519SigningKey::generate());

        vault.create(&first, Some("pw")).unwrap();
        vault.create(&second, None).unwrap();

        let mut expected = vec![addr_of(&first), addr_of(&second)];
        expected.sort_by_key(AccountAddr::to_string);
        assert_eq!(addresses(&vault), expected);
        assert_eq!(
            vault
                .open(&addr_of(&first), Some("pw"))
                .unwrap()
                .DANGER_to_bytes(),
            first.DANGER_to_bytes()
        );
        assert_eq!(
            vault
                .open(&addr_of(&second), None)
                .unwrap()
                .DANGER_to_bytes(),
            second.DANGER_to_bytes()
        );
    }

    #[test]
    fn re_adding_an_account_is_refused_and_the_held_key_kept() {
        let (_tmp, vault) = vault();
        let key = Ed25519SigningKey::generate();
        let addr = vault.create(&key, Some("pw")).unwrap();

        let refused = vault.create(&key, Some("another"));

        assert!(matches!(refused, Err(VaultError::AccountExists(_))));
        assert_eq!(
            vault.open(&addr, Some("pw")).unwrap().DANGER_to_bytes(),
            key.DANGER_to_bytes()
        );
    }

    #[test]
    fn forgetting_removes_one_account_and_keeps_the_rest() {
        let (_tmp, vault) = vault();
        let (kept, dropped) = (Ed25519SigningKey::generate(), Ed25519SigningKey::generate());
        vault.create(&kept, Some("pw")).unwrap();
        vault.create(&dropped, None).unwrap();

        vault.forget(&addr_of(&dropped)).unwrap();

        assert_eq!(addresses(&vault), vec![addr_of(&kept)]);
        assert!(matches!(
            vault.forget(&addr_of(&dropped)),
            Err(VaultError::NoAccount)
        ));
    }

    #[test]
    fn a_create_leaves_only_the_vault_files_and_the_lock() {
        let (_tmp, vault) = vault();
        let sealed = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        let open = vault.create(&Ed25519SigningKey::generate(), None).unwrap();

        let mut names: Vec<_> = fs::read_dir(&vault.dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();

        let mut expected = vec![
            LOCK_FILE.to_string(),
            format!("{sealed}{SEALED_SUFFIX}"),
            format!("{open}{OPEN_SUFFIX}"),
        ];
        expected.sort();
        assert_eq!(names, expected);
    }

    #[cfg(unix)]
    #[test]
    fn every_vault_file_is_readable_by_its_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let (_tmp, vault) = vault();
        let sealed = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        let open = vault.create(&Ed25519SigningKey::generate(), None).unwrap();

        let mode = |path: PathBuf| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(vault.dir.clone()), 0o700);
        assert_eq!(mode(vault.path_of(&sealed, true)), 0o600);
        assert_eq!(mode(vault.path_of(&open, false)), 0o600);
    }

    #[test]
    fn a_file_under_another_accounts_name_is_refused() {
        let (_tmp, vault) = vault();
        let sealed = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        let open = vault.create(&Ed25519SigningKey::generate(), None).unwrap();
        let other = addr_of(&Ed25519SigningKey::generate());

        fs::rename(
            vault.path_of(&sealed, true),
            vault.dir.join(format!("{other}{SEALED_SUFFIX}")),
        )
        .unwrap();
        assert!(matches!(
            vault.open(&other, Some("pw")),
            Err(VaultError::Corrupt(_))
        ));

        let another = addr_of(&Ed25519SigningKey::generate());
        fs::rename(
            vault.path_of(&open, false),
            vault.dir.join(format!("{another}{OPEN_SUFFIX}")),
        )
        .unwrap();
        assert!(matches!(
            vault.open(&another, None),
            Err(VaultError::Corrupt(_))
        ));
    }

    /// A scrypt `n` of 2^31 would ask for about 256 GiB before the MAC check.
    #[test]
    fn oversized_scrypt_parameters_are_refused_before_derivation() {
        let (_tmp, vault) = vault();
        let addr = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        tamper(&vault, &addr, |json| {
            json["crypto"]["kdfparams"]["n"] = (1u64 << 31).into()
        });
        assert!(matches!(
            vault.open(&addr, Some("pw")),
            Err(VaultError::Corrupt(_))
        ));
    }

    /// Each within its own ceiling, and together 64 times this vault's work.
    #[test]
    fn scrypt_work_past_the_ceiling_is_refused() {
        let (_tmp, vault) = vault();
        let addr = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        tamper(&vault, &addr, |json| {
            json["crypto"]["kdfparams"]["n"] = (1u64 << 16).into();
            json["crypto"]["kdfparams"]["r"] = 16.into();
            json["crypto"]["kdfparams"]["p"] = 4.into();
        });
        assert!(matches!(
            check_params(&fs::read_to_string(vault.path_of(&addr, true)).unwrap()),
            Err(VaultError::Corrupt(_))
        ));
    }

    /// eth-keystore would take PBKDF2's fields over scrypt's and run as many
    /// iterations as the file asks for.
    #[test]
    fn pbkdf2_parameters_beside_scrypt_ones_are_refused() {
        let (_tmp, vault) = vault();
        let addr = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        tamper(&vault, &addr, |json| {
            json["crypto"]["kdfparams"]["c"] = u32::MAX.into();
            json["crypto"]["kdfparams"]["prf"] = "hmac-sha256".into();
        });
        assert!(matches!(
            vault.open(&addr, Some("pw")),
            Err(VaultError::Corrupt(_))
        ));
    }

    /// What a file manager names a copy made in place.
    #[test]
    fn a_copy_beside_a_key_file_is_not_an_account() {
        let (_tmp, vault) = vault();
        let addr = vault.create(&Ed25519SigningKey::generate(), None).unwrap();
        fs::copy(
            vault.path_of(&addr, false),
            vault.dir.join(format!("{addr} (copy){OPEN_SUFFIX}")),
        )
        .unwrap();
        assert_eq!(
            vault.accounts().unwrap(),
            vec![StoredAccount {
                addr: addr.clone(),
                protected: false
            }]
        );
        vault.open(&addr, None).unwrap();
    }

    #[test]
    fn a_short_iv_is_refused_rather_than_panicking() {
        let (_tmp, vault) = vault();
        let addr = vault
            .create(&Ed25519SigningKey::generate(), Some("pw"))
            .unwrap();
        tamper(&vault, &addr, |json| {
            json["crypto"]["cipherparams"]["iv"] = "00".into()
        });
        assert!(matches!(
            vault.open(&addr, Some("pw")),
            Err(VaultError::Corrupt(_))
        ));
    }

    #[test]
    fn an_unreadable_open_document_is_refused_rather_than_guessed_at() {
        let (_tmp, vault) = vault();
        let addr = vault.create(&Ed25519SigningKey::generate(), None).unwrap();
        fs::write(vault.path_of(&addr, false), r#"{"logos_account_vault":1}"#).unwrap();
        assert!(matches!(
            vault.open(&addr, None),
            Err(VaultError::Corrupt(_))
        ));
    }
}
