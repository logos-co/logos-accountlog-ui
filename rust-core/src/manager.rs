//! What the app does with an account: hold its key, stage edits to its log,
//! and publish them.
//!
//! Edits are staged here rather than applied as they are made, because the log
//! is published all or nothing: one rejected entry writes none of them. The
//! staged list is this app's, not the log's, and it survives only as long as
//! the process does.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use account::{Account, AccountError, AccountProvider, AccountPublisher, AccountResolver};
use account_log::{
    AccountAddr, AccountEntry, AccountLog, AccountLogDraft, AccountLogError, AccountRecord,
    Context, Ed25519SigningKey, Ed25519VerifyingKey, EntryData, SignedAccountLog,
    ACCOUNT_LOG_DOMAIN, MAX_PAYLOAD_BYTES, SIGNER_CONTEXT,
};
use serde::Serialize;
use thiserror::Error;
use zeroize::Zeroizing;

use crate::observed::{ObservedAccounts, ObservedError};
use crate::store::{Store, StoreError};
use crate::vault::{Vault, VaultError};

/// The display name, under the profile specification's namespace.
pub static DISPLAY_NAME_CONTEXT: LazyLock<Context> =
    LazyLock::new(|| Context::new("profile.displayname").expect("valid context"));

/// The account log format caps the payload, not the entry. A name long enough
/// to matter spends the budget a revocation will need later, so this app caps
/// it where a name stops being a name.
pub const MAX_DISPLAY_NAME_BYTES: usize = 64;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error(transparent)]
    Vault(#[from] VaultError),
    #[error(transparent)]
    Account(#[from] AccountError),
    #[error(transparent)]
    Log(#[from] AccountLogError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Observed(#[from] ObservedError),
    #[error("not an account address: 64 lowercase hex characters, unprefixed")]
    Address,
    #[error("this app neither holds nor observes that account")]
    Unknown,
    #[error("this app holds no key for that account, so it cannot write its log")]
    NotManaged,
    #[error("this app holds that account's key, so it is managed rather than observed")]
    AlreadyManaged,
    /// A caller reached the C ABI without one of the strings it names.
    #[error("missing or malformed argument")]
    Argument,
    #[error("not an installation key: {0}")]
    Key(String),
    #[error("a display name needs at least one visible character")]
    EmptyDisplayName,
    #[error(
        "a display name cannot hold line breaks, control characters or text-direction overrides"
    )]
    DisplayNameCharacters,
    #[error("a display name is limited to 64 bytes of UTF-8, and this one is {0}")]
    DisplayNameTooLong(usize),
    #[error("that is already the account's display name")]
    NameUnchanged,
    #[error("that key is already live in this account's log")]
    InstallationLive,
    #[error("that edit is already waiting to be published")]
    AlreadyStaged,
    #[error("that would take the log past its lifetime budget of {} KiB", MAX_PAYLOAD_BYTES / 1024)]
    OverBudget,
    #[error("entry {0} is not a live entry this account can revoke")]
    NotRevocable(u32),
    #[error("there is nothing waiting to be published")]
    NothingStaged,
    #[error("this account's log holds an entry this build cannot read, so it cannot be extended")]
    Unreadable,
}

/// An edit waiting for the next publish.
#[derive(Debug, Clone, PartialEq, Eq)]
enum StagedEdit {
    AddInstallation(Ed25519VerifyingKey),
    /// Appended as one more name. The profile rules make the highest-indexed
    /// live one current, and the ones before it stay as previous aliases.
    SetDisplayName(String),
    Revoke(u32),
}

/// The domain prefix every payload carries before its first entry, and so the
/// size of a log that has published nothing.
pub const DOMAIN_BYTES: usize = ACCOUNT_LOG_DOMAIN.len();

/// Why the last read of the store did not land. The view words each of these,
/// so what crosses is the kind and not the message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReadProblem {
    /// The store served a log whose signature does not check against the
    /// address it was asked about, or one this build cannot decode at all.
    Unverified,
    /// The store served a log that does not extend the one held: the account
    /// has shown two histories, and the one already verified stands.
    Forked,
    /// The store did not answer, or answered something that is not a log.
    Unanswered,
}

impl ReadProblem {
    /// A read's failure as the screen has to tell them apart. The message
    /// itself still reaches the view, and says which store and why.
    fn of(error: &AccountError) -> Self {
        match error {
            AccountError::Log(_) => Self::Unverified,
            AccountError::Forked => Self::Forked,
            AccountError::Provider(_) => Self::Unanswered,
        }
    }
}

/// What the last read of the store left behind for one account: when it last
/// answered with a log, and what went wrong since, if anything.
#[derive(Debug, Clone, Copy, Default)]
struct LastRead {
    at: Option<SystemTime>,
    problem: Option<ReadProblem>,
}

/// One account, as the vault and the store together know it.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountSummary {
    pub address: String,
    /// Whether this app holds the key. False for an account it only observes,
    /// whose log it reads and can never extend.
    pub managed: bool,
    /// Whether opening the key takes a password. False for an observed
    /// account, which has no key here to open.
    pub protected: bool,
    /// Whether the store has answered for this account since the app started,
    /// so a missing name is known to be missing.
    pub resolved: bool,
    /// The name in force in the published log, if the store has been read.
    pub display_name: Option<String>,
    pub pending: usize,
    /// Why the last read of this account did not land, for the one badge a
    /// row carries when something is not as it should be.
    pub problem: Option<ReadProblem>,
}

/// Everything the Manage pane draws for one account.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountState {
    pub address: String,
    /// Whether this app holds the key, and so whether anything on the screen
    /// this draws can write.
    pub managed: bool,
    pub protected: bool,
    /// Whether the store has answered for this account since the app started.
    /// Distinguishes "nothing published" from "could not ask".
    pub resolved: bool,
    /// When the log on screen was read, in milliseconds since the epoch, so
    /// the view can say how old the copy it is drawing is. None until one has
    /// been read.
    pub read_at_ms: Option<u64>,
    /// Why the last read did not land. Set beside a log where an earlier read
    /// answered and a later one did not, which is how the screen knows the
    /// copy it draws is not the store's last word.
    pub problem: Option<ReadProblem>,
    pub published: bool,
    pub log_bytes: usize,
    pub max_bytes: usize,
    /// The bytes the payload spends before its first entry, which the table
    /// shows because the signature covers them too.
    pub domain_bytes: usize,
    pub display_name: Option<String>,
    pub display_name_index: Option<u32>,
    pub installations: Vec<Installation>,
    pub entries: Vec<EntryRow>,
    /// Set when the published log carries an entry this build cannot read. The
    /// log is then shown by context only, and cannot be extended at all.
    pub unreadable: Option<String>,
    /// The entries the next publish will append, already numbered as they will
    /// be once it lands.
    pub pending: Vec<EntryRow>,
    pub costs: EntryCosts,
}

/// What the next entry of each kind will cost the budget, so a dialog can name
/// the price before the edit is staged.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryCosts {
    /// One endorsed installation key.
    pub installation: usize,
    /// One removal, whatever it points at.
    pub remove: usize,
    /// A display name of no bytes; each UTF-8 byte of the name adds one.
    pub display_name: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Installation {
    pub index: u32,
    pub key: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Name {
    pub index: u32,
    pub value: String,
}

/// One row of the log table: every entry the account ever wrote, in order,
/// carrying the index a revocation targets. Also the shape of a pending entry,
/// because a pending entry is an entry.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryRow {
    pub index: u32,
    pub kind: &'static str,
    pub context: Option<String>,
    pub value: String,
    /// False for an entry a revocation has tombstoned, and for the revocations
    /// themselves.
    pub live: bool,
    /// The entry a revocation tombstones.
    pub target: Option<u32>,
    /// What this entry costs the log's lifetime budget. Zero for an entry this
    /// build cannot author, which appears only in a log shown by context.
    pub bytes: usize,
    /// For a live display name a later live one supersedes, the index of the
    /// name in force.
    pub superseded_by: Option<u32>,
}

/// What a publish did.
#[derive(Debug, PartialEq, Eq)]
pub struct Published {
    /// The first entry the update wrote: the length of the log it extends,
    /// which is the only log the store takes it on top of. `None` when the
    /// store already held every staged edit, so nothing was written.
    pub first_new_index: Option<u32>,
    /// Staged edits dropped as already in the log, counted as `refresh`
    /// counts them.
    pub dropped: usize,
}

pub struct AccountCore {
    vault: Vault,
    observed: ObservedAccounts,
    store: Store,
    resolver: AccountResolver<ReadBack>,
    written: Written,
    /// What the store last said about each account it was asked about.
    read: HashMap<AccountAddr, LastRead>,
    staged: HashMap<AccountAddr, Vec<StagedEdit>>,
    /// Staged edits a read dropped that no answer has counted yet: a publish
    /// that fails after its read leaves them to the next refresh.
    dropped: HashMap<AccountAddr, usize>,
}

impl AccountCore {
    pub fn new(vault_dir: impl Into<PathBuf>, store: Store) -> Self {
        let written = Written::default();
        let vault_dir = vault_dir.into();
        Self {
            vault: Vault::new(vault_dir.clone()),
            observed: ObservedAccounts::new(vault_dir),
            resolver: AccountResolver::new(ReadBack {
                store: store.clone(),
                written: written.clone(),
            }),
            written,
            store,
            read: HashMap::new(),
            staged: HashMap::new(),
            dropped: HashMap::new(),
        }
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    /// Every account this app has, the ones it holds a key for first and the
    /// ones it only observes after. Reads no store.
    pub fn accounts(&self) -> Result<Vec<AccountSummary>, CoreError> {
        let held = self.vault.accounts()?;
        let observed = self.observed.list()?;
        Ok(held
            .iter()
            .map(|held| AccountSummary {
                managed: true,
                resolved: self.answered(&held.addr),
                display_name: self.live_name(&held.addr),
                pending: self.planned_entries(&held.addr).len(),
                address: held.addr.to_string(),
                protected: held.protected,
                problem: self.problem(&held.addr),
            })
            // An address whose key arrived while it was observed is managed
            // now, and one account is one row.
            .chain(
                observed
                    .iter()
                    .filter(|addr| !held.iter().any(|held| &held.addr == *addr))
                    .map(|addr| AccountSummary {
                        managed: false,
                        protected: false,
                        resolved: self.answered(addr),
                        display_name: self.live_name(addr),
                        pending: 0,
                        address: addr.to_string(),
                        problem: self.problem(addr),
                    }),
            )
            .collect())
    }

    /// Start reading the log under `addr`, whose key is somewhere else.
    /// Answers whether it was not already observed.
    pub fn observe(&mut self, addr: &AccountAddr) -> Result<bool, CoreError> {
        if self.manages(addr)? {
            return Err(CoreError::AlreadyManaged);
        }
        Ok(self.observed.add(addr)?)
    }

    /// Stop reading the log under `addr`. What was read goes with it, and
    /// nothing is lost that the store does not still hold.
    pub fn stop_observing(&mut self, addr: &AccountAddr) -> Result<(), CoreError> {
        if !self.observed.remove(addr)? {
            return Err(CoreError::Unknown);
        }
        self.read.remove(addr);
        self.dropped.remove(addr);
        Ok(())
    }

    /// Generate an account and take it into the vault.
    pub fn create_account(&self, password: Option<&str>) -> Result<AccountAddr, CoreError> {
        Ok(self
            .vault
            .create(&Ed25519SigningKey::generate(), password)?)
    }

    /// Take an account this app did not generate, from the 32-byte secret its
    /// holder exported.
    pub fn import_account(
        &self,
        secret_hex: &str,
        password: Option<&str>,
    ) -> Result<AccountAddr, CoreError> {
        let secret_hex = secret_hex.trim();
        let mut secret = Zeroizing::new([0u8; 32]);
        hex::decode_to_slice(secret_hex, secret.as_mut_slice()).map_err(|e| match e {
            hex::FromHexError::InvalidHexCharacter { .. } => {
                CoreError::Key("an account key holds only 0-9 and a-f".into())
            }
            _ => CoreError::Key(format!(
                "an account key is 64 hex characters, this is {}",
                secret_hex.len()
            )),
        })?;
        let addr = self
            .vault
            .create(&Ed25519SigningKey::from_bytes(&secret), password)?;
        // Its key is here now, so it is managed rather than observed: the same
        // account, the same log, the other group.
        self.observed.remove(&addr)?;
        Ok(addr)
    }

    /// The account's own secret, for its holder to write down. Whoever holds
    /// these bytes is the account.
    pub fn export_account(
        &self,
        addr: &AccountAddr,
        password: Option<&str>,
    ) -> Result<Zeroizing<String>, CoreError> {
        self.require_managed(addr)?;
        let key = self.vault.open(addr, password)?;
        Ok(Zeroizing::new(hex::encode(
            Zeroizing::new(*key.as_bytes()).as_slice(),
        )))
    }

    /// Drop the account from the vault, with everything staged for it.
    pub fn forget_account(&mut self, addr: &AccountAddr) -> Result<(), CoreError> {
        self.require_managed(addr)?;
        self.vault.forget(addr)?;
        self.staged.remove(addr);
        self.read.remove(addr);
        self.dropped.remove(addr);
        Ok(())
    }

    /// Read the store for `addr`, adopting the log only where it extends what
    /// is held, and drop the staged edits it already holds. Answers how many
    /// were dropped since the last answer: by this read, and by the read of a
    /// publish that then failed.
    pub fn refresh(&mut self, addr: &AccountAddr) -> Result<usize, CoreError> {
        self.require_known(addr)?;
        self.read_store(addr)?;
        Ok(self.take_dropped(addr))
    }

    fn read_store(&mut self, addr: &AccountAddr) -> Result<(), CoreError> {
        let outcome = self.resolver.resolve(addr).map(|_| ());
        let read = self.read.entry(addr.clone()).or_default();
        match &outcome {
            Ok(()) => {
                *read = LastRead {
                    at: Some(SystemTime::now()),
                    problem: None,
                }
            }
            Err(e) => read.problem = Some(ReadProblem::of(e)),
        }
        outcome?;
        self.settle(addr);
        Ok(())
    }

    fn take_dropped(&mut self, addr: &AccountAddr) -> usize {
        self.dropped.remove(addr).unwrap_or(0)
    }

    /// Everything the Manage pane draws. Reads no store: call
    /// [`refresh`](Self::refresh) for that.
    pub fn state(&self, addr: &AccountAddr) -> Result<AccountState, CoreError> {
        let held = self
            .vault
            .accounts()?
            .into_iter()
            .find(|held| &held.addr == addr);
        if held.is_none() && !self.observes(addr)? {
            return Err(CoreError::Unknown);
        }
        let record = self.record(addr);
        let log = record.map(AccountRecord::log);

        let (mut entries, unreadable) = match log {
            None => (Vec::new(), None),
            Some(log) => match AccountLogDraft::from_log(log) {
                Ok(draft) => (rows_from_draft(&draft), None),
                // Another build wrote an entry this one cannot read. The log
                // can still be selected by context, and cannot be extended.
                Err(e) => (rows_by_context(log), Some(e.to_string())),
            },
        };
        let names = log.map(live_display_names).unwrap_or_default();
        if let Some((current, previous)) = names.split_last() {
            for row in &mut entries {
                if previous.iter().any(|name| name.index == row.index) {
                    row.superseded_by = Some(current.index);
                }
            }
        }

        Ok(AccountState {
            address: addr.to_string(),
            managed: held.is_some(),
            protected: held.is_some_and(|held| held.protected),
            resolved: self.answered(addr),
            read_at_ms: self.read_at(addr).map(since_epoch_ms),
            problem: self.problem(addr),
            published: record.is_some(),
            log_bytes: record.map_or(DOMAIN_BYTES, |record| {
                record.signed_log().payload.as_bytes().len()
            }),
            max_bytes: MAX_PAYLOAD_BYTES,
            domain_bytes: DOMAIN_BYTES,
            display_name: names.last().map(|name| name.value.clone()),
            display_name_index: names.last().map(|name| name.index),
            installations: log.map(live_installations).unwrap_or_default(),
            pending: pending_rows(self.planned_entries(addr), entries.len() as u32),
            entries,
            unreadable,
            costs: *ENTRY_COSTS,
        })
    }

    /// Stage an endorsement of an installation's public key, pasted by the
    /// person holding it.
    pub fn stage_add_installation(
        &mut self,
        addr: &AccountAddr,
        key_hex: &str,
    ) -> Result<(), CoreError> {
        self.require_managed(addr)?;
        let key = parse_installation_key(key_hex)?;
        if self
            .extendable(addr)?
            .is_some_and(|draft| live_keys(&draft).contains(&key.to_bytes()))
        {
            return Err(CoreError::InstallationLive);
        }
        let mut staged = self.staged.get(addr).cloned().unwrap_or_default();
        if staged.contains(&StagedEdit::AddInstallation(key.clone())) {
            return Err(CoreError::AlreadyStaged);
        }
        staged.push(StagedEdit::AddInstallation(key));
        self.restage(addr, staged)
    }

    /// Stage the account's display name. Replaces any name already staged, so
    /// an update carries one. The name in force, while another is staged,
    /// drops the staged one.
    pub fn stage_set_display_name(
        &mut self,
        addr: &AccountAddr,
        name: &str,
    ) -> Result<(), CoreError> {
        self.require_managed(addr)?;
        let name = display_name(name)?;
        self.extendable(addr)?;
        let mut staged = self.staged.get(addr).cloned().unwrap_or_default();
        let before = staged.len();
        staged.retain(|edit| !matches!(edit, StagedEdit::SetDisplayName(_)));
        if self.live_name(addr).as_deref() != Some(name) {
            staged.push(StagedEdit::SetDisplayName(name.to_owned()));
        } else if staged.len() == before {
            return Err(CoreError::NameUnchanged);
        }
        self.restage(addr, staged)
    }

    /// Stage a revocation of the entry at `index`, which must be live now.
    pub fn stage_revoke(&mut self, addr: &AccountAddr, index: u32) -> Result<(), CoreError> {
        self.require_managed(addr)?;
        let is_live = self.extendable(addr)?.is_some_and(|draft| {
            draft
                .live_entries()
                .iter()
                .any(|entry| entry.index == index)
        });
        if !is_live {
            return Err(CoreError::NotRevocable(index));
        }
        let mut staged = self.staged.get(addr).cloned().unwrap_or_default();
        if staged.contains(&StagedEdit::Revoke(index)) {
            return Err(CoreError::AlreadyStaged);
        }
        staged.push(StagedEdit::Revoke(index));
        self.restage(addr, staged)
    }

    /// Make `staged` all that `addr` has waiting, once the update it plans is
    /// one the log takes: an edit past the byte budget is refused here rather
    /// than failing every publish after it.
    fn restage(&mut self, addr: &AccountAddr, staged: Vec<StagedEdit>) -> Result<(), CoreError> {
        self.fits(addr, &staged)?;
        if staged.is_empty() {
            self.staged.remove(addr);
        } else {
            self.staged.insert(addr.clone(), staged);
        }
        Ok(())
    }

    /// Throw away everything staged for `addr`. Nothing was written, so
    /// nothing is undone.
    pub fn discard_pending(&mut self, addr: &AccountAddr) -> Result<(), CoreError> {
        self.require_managed(addr)?;
        self.staged.remove(addr);
        Ok(())
    }

    /// Sign and publish every staged edit the log does not already hold, as
    /// one update.
    ///
    /// All or nothing: a single rejected entry writes none of them, and the
    /// staged list survives so the person can fix it rather than retype it.
    ///
    /// A store that already holds every staged edit is not a failure: the
    /// update is simply not needed.
    pub fn publish(
        &mut self,
        addr: &AccountAddr,
        password: Option<&str>,
    ) -> Result<Published, CoreError> {
        self.require_managed(addr)?;
        if self.staged.get(addr).is_none_or(Vec::is_empty) {
            return Err(CoreError::NothingStaged);
        }
        // Before the store is read, so a wrong password costs no request.
        let key = self.vault.open(addr, password)?;
        // Planned against what the store holds now rather than what this
        // instance last read, so the update extends the log the store holds.
        self.read_store(addr)?;
        let Some(staged) = self.staged.get(addr) else {
            return Ok(Published {
                first_new_index: None,
                dropped: self.take_dropped(addr),
            });
        };
        // The store's log may have grown since staging measured against it.
        self.fits(addr, staged)?;
        let first_new = self
            .extendable(addr)?
            .map_or(0, |draft| draft.entries().len() as u32);
        let entries = self.planned_entries(addr);

        let base = self.record(addr).map(|record| record.signed_log().clone());
        let mut account = Account::from_signing_key(
            key,
            Extending {
                base,
                store: self.store.clone(),
            },
        );
        let mut update = account.update();
        for entry in entries {
            update = update.push(entry);
        }
        let written = update.publish()?;

        self.staged.remove(addr);
        self.written.hold(addr, written);
        self.resolver.resolve(addr)?;
        Ok(Published {
            first_new_index: Some(first_new),
            dropped: self.take_dropped(addr),
        })
    }

    /// Drop the staged edits the log already holds, written first by another
    /// device or by a publish whose answer was lost. Left staged, each would
    /// fail the whole update: an entry revoked twice, a key live twice.
    fn settle(&mut self, addr: &AccountAddr) {
        let Some(log) = self.record(addr).map(AccountRecord::log) else {
            return;
        };
        let Ok(draft) = AccountLogDraft::from_log(log) else {
            return;
        };
        let live = draft.live_entries();
        let keys = live_keys(&draft);
        let name = live_display_name(log);
        let Some(staged) = self.staged.get_mut(addr) else {
            return;
        };
        let before = staged.len();
        staged.retain(|edit| match edit {
            StagedEdit::Revoke(index) => live.iter().any(|entry| entry.index == *index),
            StagedEdit::AddInstallation(key) => !keys.contains(&key.to_bytes()),
            StagedEdit::SetDisplayName(staged) => name.as_ref() != Some(staged),
        });
        let dropped = before - staged.len();
        if staged.is_empty() {
            self.staged.remove(addr);
        }
        if dropped > 0 {
            *self.dropped.entry(addr.clone()).or_default() += dropped;
        }
    }

    /// Whether the store has answered for `addr` with a log this app could
    /// use. A read that failed leaves this as it was, so the copy already on
    /// screen stays on screen.
    fn answered(&self, addr: &AccountAddr) -> bool {
        self.read_at(addr).is_some()
    }

    fn read_at(&self, addr: &AccountAddr) -> Option<&SystemTime> {
        self.read.get(addr).and_then(|read| read.at.as_ref())
    }

    fn problem(&self, addr: &AccountAddr) -> Option<ReadProblem> {
        self.read.get(addr).and_then(|read| read.problem)
    }

    /// Whether this app holds `addr`'s key.
    fn manages(&self, addr: &AccountAddr) -> Result<bool, CoreError> {
        Ok(self.vault.accounts()?.iter().any(|held| &held.addr == addr))
    }

    fn observes(&self, addr: &AccountAddr) -> Result<bool, CoreError> {
        Ok(self.observed.list()?.iter().any(|held| held == addr))
    }

    /// Refuse a write to an account whose key is elsewhere. Checked at the
    /// call and not left to the vault, because a managed and an observed
    /// account are one list and one screen, and the screen must not be the
    /// only thing keeping their calls apart.
    fn require_managed(&self, addr: &AccountAddr) -> Result<(), CoreError> {
        // Asked in this order on purpose: the vault holding the key settles it,
        // and a list of observed accounts that cannot be read then takes
        // nothing away from an account whose key is right here.
        if self.manages(addr)? {
            return Ok(());
        }
        if self.observes(addr)? {
            return Err(CoreError::NotManaged);
        }
        Err(CoreError::Unknown)
    }

    /// Refuse a read of an account this app was never asked to have, so a
    /// stale address cannot make it fetch whatever it names.
    fn require_known(&self, addr: &AccountAddr) -> Result<(), CoreError> {
        if self.manages(addr)? || self.observes(addr)? {
            return Ok(());
        }
        Err(CoreError::Unknown)
    }

    /// The log the store gave for `addr` this session. The resolver keeps it
    /// past a forget, and an account imported again starts unread.
    fn record(&self, addr: &AccountAddr) -> Option<&AccountRecord> {
        self.resolver.get(addr).filter(|_| self.answered(addr))
    }

    /// Refuse an update of `staged` that would take `addr`'s log, as last
    /// read, past its byte budget.
    fn fits(&self, addr: &AccountAddr, staged: &[StagedEdit]) -> Result<(), CoreError> {
        let mut draft = self.extendable(addr)?.unwrap_or_default();
        for entry in Self::plan(staged) {
            draft.push(entry)?;
        }
        draft.log().encode().map_err(|e| match e {
            AccountLogError::TooLarge(_) => CoreError::OverBudget,
            other => other.into(),
        })?;
        Ok(())
    }

    /// The published log as an update would extend it: `None` when nothing is
    /// published yet, refused when it holds an entry this build cannot read and
    /// so cannot sign again.
    fn extendable(&self, addr: &AccountAddr) -> Result<Option<AccountLogDraft>, CoreError> {
        self.record(addr)
            .map(|record| {
                AccountLogDraft::from_log(record.log()).map_err(|_| CoreError::Unreadable)
            })
            .transpose()
    }

    fn live_name(&self, addr: &AccountAddr) -> Option<String> {
        self.record(addr)
            .and_then(|record| live_display_name(record.log()))
    }

    /// The entries the next publish will append, in the order they are written.
    /// Revocations first: every one targets an already-published entry.
    fn planned_entries(&self, addr: &AccountAddr) -> Vec<AccountEntry> {
        Self::plan(self.staged.get(addr).map_or(&[], Vec::as_slice))
    }

    /// What an update made of `staged` would append.
    fn plan(staged: &[StagedEdit]) -> Vec<AccountEntry> {
        let mut entries: Vec<AccountEntry> = staged
            .iter()
            .filter_map(|edit| match edit {
                StagedEdit::Revoke(index) => Some(AccountEntry::Remove { index: *index }),
                _ => None,
            })
            .collect();
        for edit in staged {
            match edit {
                StagedEdit::AddInstallation(key) => entries.push(AccountEntry::add(
                    SIGNER_CONTEXT.clone(),
                    EntryData::Ed25519Key(key.to_bytes()),
                )),
                StagedEdit::SetDisplayName(name) => entries.push(AccountEntry::add(
                    DISPLAY_NAME_CONTEXT.clone(),
                    EntryData::Text(name.clone()),
                )),
                StagedEdit::Revoke(_) => {}
            }
        }
        entries
    }
}

/// What an update is written through: it serves the log the update was
/// planned against, so a store that has moved on since refuses the update
/// rather than taking a plan made for another log.
struct Extending {
    base: Option<SignedAccountLog>,
    store: Store,
}

impl AccountProvider for Extending {
    type Error = StoreError;

    fn fetch(&self, _: &AccountAddr) -> Result<Option<SignedAccountLog>, Self::Error> {
        Ok(self.base.clone())
    }
}

impl AccountPublisher for Extending {
    type Error = StoreError;

    fn publish(&mut self, addr: &AccountAddr, log: &SignedAccountLog) -> Result<(), Self::Error> {
        self.store.publish(addr, log)
    }
}

/// A log one publish just wrote, until the read after it collects it.
#[derive(Clone, Default)]
struct Written(Arc<Mutex<Option<(AccountAddr, SignedAccountLog)>>>);

impl Written {
    fn hold(&self, addr: &AccountAddr, log: SignedAccountLog) {
        *self.0.lock().expect("never held across a panic") = Some((addr.clone(), log));
    }

    fn take(&self, addr: &AccountAddr) -> Option<SignedAccountLog> {
        let mut slot = self.0.lock().expect("never held across a panic");
        slot.take_if(|(held, _)| held == addr).map(|(_, log)| log)
    }
}

/// What the resolver reads through: the store, except for the one read after
/// a publish, which gets the log that publish wrote. The store took it, so it
/// is what the store holds, and a write that landed is shown as landed whether
/// or not the store then answers a read.
struct ReadBack {
    store: Store,
    written: Written,
}

impl AccountProvider for ReadBack {
    type Error = StoreError;

    fn fetch(&self, addr: &AccountAddr) -> Result<Option<SignedAccountLog>, Self::Error> {
        match self.written.take(addr) {
            Some(log) => Ok(Some(log)),
            None => self.store.fetch(addr),
        }
    }
}

/// The planned entries as log rows, numbered from `base`: the index each will
/// carry once the update lands.
fn pending_rows(planned: Vec<AccountEntry>, base: u32) -> Vec<EntryRow> {
    planned
        .into_iter()
        .enumerate()
        .map(|(offset, entry)| {
            let live = !matches!(entry, AccountEntry::Remove { .. });
            row_from(base + offset as u32, &entry, live)
        })
        .collect()
}

fn parse_installation_key(key_hex: &str) -> Result<Ed25519VerifyingKey, CoreError> {
    let key_hex = key_hex.trim();
    let bytes = hex::decode(key_hex)
        .map_err(|_| CoreError::Key("an installation key is 64 hex characters".into()))?;
    let bytes: [u8; 32] = bytes.as_slice().try_into().map_err(|_| {
        CoreError::Key(format!(
            "an installation key is 32 bytes, this is {}",
            bytes.len()
        ))
    })?;
    Ed25519VerifyingKey::from_canonical_bytes(&bytes)
        .map_err(|_| CoreError::Key("those 32 bytes are not a valid Ed25519 public key".into()))
}

/// The name as it will be published: trimmed, and refused when it would
/// render as nothing, break a line, or turn the text around it.
fn display_name(name: &str) -> Result<&str, CoreError> {
    let name = name.trim();
    if name.chars().any(moves_text) {
        return Err(CoreError::DisplayNameCharacters);
    }
    // Invisible characters are allowed, since emoji sequences need the joiner
    // and the variation selectors, but a name made only of them shows nothing.
    if name.chars().all(|c| c.is_whitespace() || invisible(c)) {
        return Err(CoreError::EmptyDisplayName);
    }
    if name.len() > MAX_DISPLAY_NAME_BYTES {
        return Err(CoreError::DisplayNameTooLong(name.len()));
    }
    Ok(name)
}

/// A character that breaks a line or turns the text around it.
fn moves_text(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{2028}' | '\u{2029}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}'
        )
}

/// A character that draws nothing: Unicode's Default_Ignorable_Code_Point
/// set, plus the blanks outside it.
fn invisible(c: char) -> bool {
    matches!(
        c,
        '\u{00AD}'
            | '\u{034F}'
            | '\u{061C}'
            | '\u{115F}'..='\u{1160}'
            | '\u{17B4}'..='\u{17B5}'
            | '\u{180B}'..='\u{180F}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{206F}'
            | '\u{3164}'
            | '\u{FE00}'..='\u{FE0F}'
            | '\u{FEFF}'
            | '\u{FFA0}'
            | '\u{FFF0}'..='\u{FFF8}'
            | '\u{1BCA0}'..='\u{1BCA3}'
            | '\u{1D173}'..='\u{1D17A}'
            | '\u{E0000}'..='\u{E0FFF}'
            // The braille blank and the interlinear annotation marks.
            | '\u{2800}'
            | '\u{FFF9}'..='\u{FFFB}'
    )
}

/// A moment as the view counts them. Saturating: a clock set before 1970
/// makes a read look older than the app, not younger than the epoch.
fn since_epoch_ms(read: &SystemTime) -> u64 {
    read.duration_since(UNIX_EPOCH)
        .map(|since| since.as_millis() as u64)
        .unwrap_or(0)
}

pub fn parse_address(address: &str) -> Result<AccountAddr, CoreError> {
    address.trim().parse().map_err(|_| CoreError::Address)
}

/// The name in force: the highest-indexed live one, which is what the profile
/// rules make current.
fn live_display_name(log: &AccountLog) -> Option<String> {
    live_display_names(log).pop().map(|name| name.value)
}

/// Every live name, oldest first: the name in force last, and the account's
/// previous aliases before it.
fn live_display_names(log: &AccountLog) -> Vec<Name> {
    log.entries_for(&DISPLAY_NAME_CONTEXT)
        .into_iter()
        .filter_map(|entry| match entry.entry {
            AccountEntry::Add {
                data: EntryData::Text(value),
                ..
            } => Some(Name {
                index: entry.index,
                value: value.clone(),
            }),
            _ => None,
        })
        .collect()
}

/// Every key live in the log, under any context: the log refuses a key live
/// twice whatever the context, and would refuse the whole update over it.
fn live_keys(draft: &AccountLogDraft) -> Vec<[u8; 32]> {
    draft
        .live_entries()
        .iter()
        .filter_map(|entry| match entry.entry {
            AccountEntry::Add {
                data: EntryData::Ed25519Key(key),
                ..
            } => Some(*key),
            _ => None,
        })
        .collect()
}

fn live_installations(log: &AccountLog) -> Vec<Installation> {
    log.entries_for(&SIGNER_CONTEXT)
        .into_iter()
        .filter_map(|entry| match entry.entry {
            AccountEntry::Add {
                data: EntryData::Ed25519Key(key),
                ..
            } => Some(Installation {
                index: entry.index,
                key: hex::encode(key),
            }),
            _ => None,
        })
        .collect()
}

/// The whole log, in order, with every entry's index and whether it is still
/// live.
fn rows_from_draft(draft: &AccountLogDraft) -> Vec<EntryRow> {
    let live: Vec<u32> = draft
        .live_entries()
        .iter()
        .map(|entry| entry.index)
        .collect();
    draft
        .entries()
        .into_iter()
        .map(|entry| row_from(entry.index, entry.entry, live.contains(&entry.index)))
        .collect()
}

fn row_from(index: u32, entry: &AccountEntry, live: bool) -> EntryRow {
    let (kind, value) = describe(entry);
    EntryRow {
        index,
        kind,
        context: context_of(entry).map(|c| c.as_str().to_owned()),
        value,
        live,
        target: match entry {
            AccountEntry::Remove { index } => Some(*index),
            _ => None,
        },
        bytes: entry_size(entry),
        superseded_by: None,
    }
}

/// What a log with an unreadable entry can still say: the live entries this
/// app's own two contexts select. The rest of the log is there and is not
/// shown, which is why [`AccountState::unreadable`] is set alongside.
fn rows_by_context(log: &AccountLog) -> Vec<EntryRow> {
    let mut rows: Vec<EntryRow> = [&*SIGNER_CONTEXT, &*DISPLAY_NAME_CONTEXT]
        .into_iter()
        .flat_map(|context| log.entries_for(context))
        .map(|entry| row_from(entry.index, entry.entry, true))
        .collect();
    rows.sort_by_key(|row| row.index);
    rows
}

fn context_of(entry: &AccountEntry) -> Option<&Context> {
    match entry {
        AccountEntry::Add { context, .. } => Some(context),
        _ => None,
    }
}

/// What one entry costs the log's lifetime budget, measured by encoding it on
/// its own and taking the domain prefix back off. Measured rather than
/// computed, so a size on screen is one the format charges and not a second
/// copy of its framing rules.
///
/// Zero for an entry this build cannot author: it can only have arrived in a
/// log that is already shown by context, where the log's own size is all that
/// can be said.
fn entry_size(entry: &AccountEntry) -> usize {
    match entry {
        AccountEntry::Remove { .. } => ENTRY_COSTS.remove,
        _ => encoded_size(std::slice::from_ref(entry)) - DOMAIN_BYTES,
    }
}

/// The payload a log holding exactly `entries` would sign, or the bare domain
/// when this build cannot author them.
fn encoded_size(entries: &[AccountEntry]) -> usize {
    let mut draft = AccountLogDraft::new();
    for entry in entries {
        if draft.push(entry.clone()).is_err() {
            return DOMAIN_BYTES;
        }
    }
    draft
        .log()
        .encode()
        .map_or(DOMAIN_BYTES, |payload| payload.as_bytes().len())
}

/// What the next entry of each kind will cost, for the dialogs that quote a
/// price before the edit exists. Every one of them is the same for every
/// account, and each is measured the same way a row's size is.
static ENTRY_COSTS: LazyLock<EntryCosts> = LazyLock::new(|| {
    let empty_name =
        AccountEntry::add(DISPLAY_NAME_CONTEXT.clone(), EntryData::Text(String::new()));
    let installation = AccountEntry::add(
        SIGNER_CONTEXT.clone(),
        // Any key measures the same, and a made-up one would have to be a
        // point on the curve to survive the log's own validation.
        EntryData::Ed25519Key(Ed25519SigningKey::generate().verifying_key().to_bytes()),
    );
    EntryCosts {
        installation: entry_size(&installation),
        // A removal costs the same wherever it points, so it is measured
        // behind an entry worth pointing at, which is then taken off again.
        remove: encoded_size(&[empty_name.clone(), AccountEntry::Remove { index: 0 }])
            - encoded_size(std::slice::from_ref(&empty_name)),
        display_name: entry_size(&empty_name),
    }
});

/// The kind a row is labelled with, and the text it shows.
fn describe(entry: &AccountEntry) -> (&'static str, String) {
    match entry {
        // An opcode a newer build wrote. Counted and indexed, never read.
        AccountEntry::Unknown { opcode, .. } => ("other", format!("opcode {opcode:#04x}")),
        AccountEntry::Remove { index } => ("revocation", format!("entry {index}")),
        AccountEntry::Add { context, data } => match data {
            EntryData::Ed25519Key(key) if context == &*SIGNER_CONTEXT => {
                ("installation", hex::encode(key))
            }
            EntryData::Ed25519Key(key) => ("key", hex::encode(key)),
            EntryData::Text(value) if context == &*DISPLAY_NAME_CONTEXT => {
                ("displayName", value.clone())
            }
            EntryData::Text(value) => ("text", value.clone()),
            _ => ("other", String::new()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Publish `entries` as another device holding `key` would.
    fn publish_elsewhere(key: Ed25519SigningKey, store: Store, entries: Vec<AccountEntry>) {
        let mut account = Account::from_signing_key(key, store);
        let mut update = account.update();
        for entry in entries {
            update = update.push(entry);
        }
        update.publish().unwrap();
    }

    /// A log of one display name, signed by `key` and published nowhere.
    fn signed_log(key: &Ed25519SigningKey, name: &str) -> SignedAccountLog {
        let mut draft = AccountLogDraft::new();
        draft
            .add(DISPLAY_NAME_CONTEXT.clone(), EntryData::Text(name.into()))
            .unwrap();
        let payload = draft.log().encode().unwrap();
        let signature = key.sign(payload.as_bytes());
        SignedAccountLog { payload, signature }
    }

    /// `entries` followed by notes that bring them to `size` encoded bytes.
    fn padded_to(mut entries: Vec<AccountEntry>, size: usize) -> Vec<AccountEntry> {
        let note = |text: String| {
            AccountEntry::add(
                Context::new("elsewhere.note").unwrap(),
                EntryData::Text(text),
            )
        };
        loop {
            let left = size - encoded_size(&entries);
            let framing = encoded_size(&[entries.clone(), vec![note(String::new())]].concat())
                - encoded_size(&entries);
            if left - framing <= 40_000 {
                entries.push(note("x".repeat(left - framing)));
                break;
            }
            entries.push(note("x".repeat(40_000)));
        }
        assert_eq!(encoded_size(&entries), size);
        entries
    }

    fn installation_key() -> [u8; 32] {
        Ed25519SigningKey::generate().verifying_key().to_bytes()
    }

    /// The numbers the screen quotes are the format's, not this app's: an
    /// endorsement of a key is 48 bytes, a removal 7, a display name 24 plus
    /// its own UTF-8. A format change moves these before it moves a screen.
    #[test]
    fn an_entry_costs_what_the_format_charges() {
        assert_eq!(DOMAIN_BYTES, 17);
        assert_eq!(ENTRY_COSTS.installation, 48);
        assert_eq!(ENTRY_COSTS.remove, 7);
        assert_eq!(ENTRY_COSTS.display_name, 24);

        let named = AccountEntry::add(DISPLAY_NAME_CONTEXT.clone(), EntryData::Text("Saro".into()));
        assert_eq!(entry_size(&named), ENTRY_COSTS.display_name + 4);
    }

    /// Every byte of the payload is on one row or in the domain, so the table
    /// and the meter above it cannot tell different stories.
    #[test]
    fn the_rows_account_for_the_whole_log() {
        let mut draft = AccountLogDraft::new();
        draft
            .add(DISPLAY_NAME_CONTEXT.clone(), EntryData::Text("Saro".into()))
            .expect("a name is an entry");
        draft
            .add(
                SIGNER_CONTEXT.clone(),
                EntryData::Ed25519Key(installation_key()),
            )
            .expect("a key is an entry");
        draft.revoke(0).expect("entry 0 is live");

        let rows = rows_from_draft(&draft);
        let counted: usize = rows.iter().map(|row| row.bytes).sum();
        let payload = draft.log().encode().expect("a three-entry log encodes");
        assert_eq!(DOMAIN_BYTES + counted, payload.as_bytes().len());
    }

    /// Saro's laptop last read the log before Saro's phone renamed the
    /// account, and renames it again without refreshing. Its name lands after
    /// the phone's, and every earlier name stays live behind the newest.
    #[test]
    fn a_rename_appends_and_leaves_the_earlier_names_live() {
        let store = Store::from_url("memory");
        let (phone_vault, laptop_vault) =
            (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let mut phone = AccountCore::new(phone_vault.path(), store.clone());
        let mut laptop = AccountCore::new(laptop_vault.path(), store.clone());

        let addr = phone.create_account(None).unwrap();
        let secret = phone.export_account(&addr, None).unwrap();
        laptop.import_account(&secret, None).unwrap();

        phone.stage_set_display_name(&addr, "Saro").unwrap();
        phone.publish(&addr, None).unwrap();
        laptop.refresh(&addr).unwrap();

        phone.stage_set_display_name(&addr, "Saro R").unwrap();
        phone.publish(&addr, None).unwrap();

        laptop.stage_set_display_name(&addr, "Saro P").unwrap();
        let pending = laptop.state(&addr).unwrap().pending;
        assert_eq!(
            pending.iter().map(|row| row.kind).collect::<Vec<_>>(),
            ["displayName"]
        );
        laptop.publish(&addr, None).unwrap();

        let state = laptop.state(&addr).unwrap();
        assert_eq!(state.display_name.as_deref(), Some("Saro P"));
        assert_eq!(state.display_name_index, Some(2));
        assert_eq!(
            state
                .entries
                .iter()
                .map(|row| (row.value.as_str(), row.live, row.superseded_by))
                .collect::<Vec<_>>(),
            [
                ("Saro", true, Some(2)),
                ("Saro R", true, Some(2)),
                ("Saro P", true, None)
            ]
        );
    }

    /// A previous alias is a name like any other: taking it again appends it
    /// once more, and the newest entry is the one in force.
    #[test]
    fn an_earlier_name_can_be_taken_again() {
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        let addr = core.create_account(None).unwrap();
        for name in ["Saro", "Raya", "Saro"] {
            core.stage_set_display_name(&addr, name).unwrap();
            core.publish(&addr, None).unwrap();
        }

        let state = core.state(&addr).unwrap();
        assert_eq!(state.display_name.as_deref(), Some("Saro"));
        assert_eq!(
            state
                .entries
                .iter()
                .map(|row| row.superseded_by)
                .collect::<Vec<_>>(),
            [Some(2), Some(2), None]
        );
    }

    /// What the refresh before a publish cannot close: another device's first
    /// name landing between the plan and the write. The update is written on
    /// its plan, so the store refuses it rather than taking a plan made for
    /// another log.
    #[test]
    fn an_update_the_store_has_moved_past_is_refused() {
        let store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let name = |value: &str| {
            AccountEntry::add(DISPLAY_NAME_CONTEXT.clone(), EntryData::Text(value.into()))
        };

        let mut phone =
            Account::from_signing_key(Ed25519SigningKey::from_bytes(key.as_bytes()), store.clone());
        let held = phone.update().push(name("Saro R")).publish().unwrap();

        let planned_on_nothing = Extending {
            base: None,
            store: store.clone(),
        };
        let mut laptop = Account::from_signing_key(key, planned_on_nothing);
        assert!(laptop.update().push(name("Saro P")).publish().is_err());
        assert_eq!(store.fetch(&addr).unwrap(), Some(held));
    }

    /// Saro's phone and laptop, each with its own vault, on one store.
    fn two_devices(
        store: &Store,
    ) -> (
        AccountCore,
        AccountCore,
        AccountAddr,
        [tempfile::TempDir; 2],
    ) {
        let vaults = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let phone = AccountCore::new(vaults[0].path(), store.clone());
        let laptop = AccountCore::new(vaults[1].path(), store.clone());
        let addr = phone.create_account(None).unwrap();
        let secret = phone.export_account(&addr, None).unwrap();
        laptop.import_account(&secret, None).unwrap();
        (phone, laptop, addr, vaults)
    }

    /// The laptop staged what the phone then published first. Each edit is
    /// already in the log, so publishing it again would revoke an entry twice
    /// or make a key live twice, and the log refuses the whole update.
    #[test]
    fn edits_another_device_wrote_first_are_dropped_rather_than_refused() {
        let store = Store::from_url("memory");
        let (mut phone, mut laptop, addr, _vaults) = two_devices(&store);
        let key = hex::encode(installation_key());

        phone.stage_set_display_name(&addr, "Saro").unwrap();
        phone.publish(&addr, None).unwrap();
        laptop.refresh(&addr).unwrap();

        for device in [&mut laptop, &mut phone] {
            device.stage_revoke(&addr, 0).unwrap();
            device.stage_add_installation(&addr, &key).unwrap();
        }
        laptop.stage_set_display_name(&addr, "Raya").unwrap();
        phone.publish(&addr, None).unwrap();

        assert_eq!(laptop.refresh(&addr).unwrap(), 2);
        assert_eq!(
            laptop.publish(&addr, None).unwrap().first_new_index,
            Some(3)
        );
        let state = laptop.state(&addr).unwrap();
        assert_eq!(state.display_name.as_deref(), Some("Raya"));
        assert_eq!(state.installations.len(), 1);
        assert!(state.pending.is_empty());

        phone.stage_set_display_name(&addr, "Pax").unwrap();
        laptop.stage_set_display_name(&addr, "Pax").unwrap();
        phone.publish(&addr, None).unwrap();
        assert_eq!(
            laptop.publish(&addr, None).unwrap(),
            Published {
                first_new_index: None,
                dropped: 1
            }
        );
    }

    /// The store took the write and then failed the read after it. The write
    /// is what the store holds, so it is shown as landed rather than failed.
    #[test]
    fn a_publish_is_shown_as_landed_without_reading_the_store_back() {
        use crate::store::tests::{answer, json_error, serve};
        let url = serve(vec![
            json_error("404 Not Found", "no account log for account_addr"),
            answer("204 No Content", "", ""),
            answer("503 Service Unavailable", "", ""),
        ]);
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url(&url));
        let addr = core.create_account(None).unwrap();

        core.stage_set_display_name(&addr, "Saro").unwrap();
        assert_eq!(core.publish(&addr, None).unwrap().first_new_index, Some(0));
        let state = core.state(&addr).unwrap();
        assert!(state.published);
        assert_eq!(state.display_name.as_deref(), Some("Saro"));
        assert!(state.pending.is_empty());
    }

    /// An account the store says never published has been read; one whose
    /// store could not be asked has not, and must not claim to be empty.
    #[test]
    fn resolved_means_the_store_answered() {
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        let addr = core.create_account(None).unwrap();
        assert!(!core.state(&addr).unwrap().resolved);
        assert!(!core.accounts().unwrap()[0].resolved);

        core.refresh(&addr).unwrap();
        let state = core.state(&addr).unwrap();
        assert!(state.resolved);
        assert!(!state.published);
        assert!(core.accounts().unwrap()[0].resolved);

        let mut down = AccountCore::new(vault.path(), Store::from_url("http://127.0.0.1:9"));
        assert!(down.refresh(&addr).is_err());
        assert!(!down.state(&addr).unwrap().resolved);
    }

    #[test]
    fn a_name_that_shows_nothing_or_moves_text_is_refused() {
        for name in [
            "",
            " \u{200b} ",
            "\u{2060}\u{200d}",
            "\u{3164}",
            "\u{fe0f}",
            "\u{e0053}\u{e007f}",
            "\u{2800}",
            "\u{1d173}",
        ] {
            assert!(
                matches!(display_name(name), Err(CoreError::EmptyDisplayName)),
                "{name:?}"
            );
        }
        for name in [
            "Saro\nRaya",
            "Saro\u{2028}Raya",
            "\u{202e}oraS",
            "Saro\u{2067}",
        ] {
            assert!(
                matches!(display_name(name), Err(CoreError::DisplayNameCharacters)),
                "{name:?}"
            );
        }
        assert_eq!(
            display_name(" 👩\u{200d}💻 Saro ").unwrap(),
            "👩\u{200d}💻 Saro"
        );
        assert_eq!(display_name("❤\u{fe0f}").unwrap(), "❤\u{fe0f}");
    }

    #[test]
    fn the_live_name_drops_a_staged_rename_and_is_otherwise_refused() {
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        let addr = core.create_account(None).unwrap();
        core.stage_set_display_name(&addr, "Saro").unwrap();
        core.publish(&addr, None).unwrap();

        assert!(matches!(
            core.stage_set_display_name(&addr, "  Saro "),
            Err(CoreError::NameUnchanged)
        ));
        core.stage_set_display_name(&addr, "Raya").unwrap();
        core.stage_set_display_name(&addr, "Saro").unwrap();
        assert!(core.state(&addr).unwrap().pending.is_empty());
    }

    /// A key live under a context this app does not write still makes the
    /// log refuse the same key as an installation.
    #[test]
    fn a_key_live_under_any_context_cannot_be_staged() {
        let store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store.clone());
        core.import_account(&hex::encode(key.as_bytes()), None)
            .unwrap();

        let device = installation_key();
        Account::from_signing_key(key, store)
            .update()
            .push(AccountEntry::add(
                Context::new("elsewhere.key").unwrap(),
                EntryData::Ed25519Key(device),
            ))
            .publish()
            .unwrap();
        core.refresh(&addr).unwrap();

        assert!(matches!(
            core.stage_add_installation(&addr, &hex::encode(device)),
            Err(CoreError::InstallationLive)
        ));
    }

    /// Another device made the staged key live under a context this app does
    /// not write. The log would refuse it as a key live twice, so it goes the
    /// way an edit already in the log does.
    #[test]
    fn a_staged_key_made_live_under_another_context_is_dropped() {
        let store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store.clone());
        core.import_account(&hex::encode(key.as_bytes()), None)
            .unwrap();
        let device = installation_key();
        core.stage_add_installation(&addr, &hex::encode(device))
            .unwrap();

        Account::from_signing_key(key, store)
            .update()
            .push(AccountEntry::add(
                Context::new("elsewhere.key").unwrap(),
                EntryData::Ed25519Key(device),
            ))
            .publish()
            .unwrap();

        assert_eq!(
            core.publish(&addr, None).unwrap(),
            Published {
                first_new_index: None,
                dropped: 1
            }
        );
        assert!(core.state(&addr).unwrap().pending.is_empty());
    }

    /// Twenty bytes short of the budget: a removal still fits, an endorsement
    /// does not, and is refused as it is staged rather than at every publish.
    #[test]
    fn an_edit_past_the_budget_is_refused_as_it_is_staged() {
        let store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store.clone());
        core.import_account(&hex::encode(key.as_bytes()), None)
            .unwrap();

        publish_elsewhere(key, store, padded_to(Vec::new(), MAX_PAYLOAD_BYTES - 20));
        core.refresh(&addr).unwrap();

        assert!(matches!(
            core.stage_add_installation(&addr, &hex::encode(installation_key())),
            Err(CoreError::OverBudget)
        ));
        assert!(core.state(&addr).unwrap().pending.is_empty());
        core.stage_revoke(&addr, 0).unwrap();
    }

    /// Staged before the store answered, then outgrown by another device's
    /// update: the publish measures again against the log it read, and what
    /// its read dropped is still counted once it fails.
    #[test]
    fn a_log_grown_since_staging_is_measured_again_at_publish() {
        let store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store.clone());
        core.import_account(&hex::encode(key.as_bytes()), None)
            .unwrap();
        let (first, second) = (installation_key(), installation_key());
        for device in [first, second] {
            core.stage_add_installation(&addr, &hex::encode(device))
                .unwrap();
        }

        let endorsed = AccountEntry::add(SIGNER_CONTEXT.clone(), EntryData::Ed25519Key(first));
        publish_elsewhere(
            key,
            store,
            padded_to(vec![endorsed], MAX_PAYLOAD_BYTES - 20),
        );

        assert!(matches!(
            core.publish(&addr, None),
            Err(CoreError::OverBudget)
        ));
        assert_eq!(core.state(&addr).unwrap().pending.len(), 1);
        assert_eq!(core.refresh(&addr).unwrap(), 1);
    }

    /// The resolver keeps what it read for an address the vault no longer
    /// holds.
    #[test]
    fn an_account_forgotten_and_imported_again_starts_unread() {
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        let addr = core.create_account(None).unwrap();
        core.stage_set_display_name(&addr, "Saro").unwrap();
        core.publish(&addr, None).unwrap();
        let secret = core.export_account(&addr, None).unwrap();
        core.forget_account(&addr).unwrap();
        core.import_account(&secret, None).unwrap();

        let state = core.state(&addr).unwrap();
        assert!(!state.resolved);
        assert!(!state.published);
        assert!(state.entries.is_empty());
        assert_eq!(core.accounts().unwrap()[0].display_name, None);

        core.refresh(&addr).unwrap();
        assert_eq!(
            core.state(&addr).unwrap().display_name.as_deref(),
            Some("Saro")
        );
    }

    /// A newer build wrote an entry this one cannot read. The log cannot be
    /// signed again, so nothing is staged against it.
    #[test]
    fn a_log_this_build_cannot_read_takes_no_edits() {
        let mut store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store.clone());
        core.import_account(&hex::encode(key.as_bytes()), None)
            .unwrap();

        let mut draft = AccountLogDraft::new();
        draft
            .add(DISPLAY_NAME_CONTEXT.clone(), EntryData::Text("Saro".into()))
            .unwrap();
        let mut bytes = draft.log().encode().unwrap().as_bytes().to_vec();
        // An opcode no build allocates yet, with an empty body.
        bytes.extend_from_slice(&[0x0f, 0, 0]);
        let payload = account_log::EncodedAccountLog::from_bytes(bytes).unwrap();
        let signature = key.sign(payload.as_bytes());
        store
            .publish(&addr, &SignedAccountLog { payload, signature })
            .unwrap();
        core.refresh(&addr).unwrap();

        assert!(matches!(
            core.stage_set_display_name(&addr, "Raya"),
            Err(CoreError::Unreadable)
        ));
        assert!(matches!(
            core.stage_revoke(&addr, 0),
            Err(CoreError::Unreadable)
        ));
    }

    /// One list, and the order in it is the switcher's: the accounts this app
    /// can write first, the ones it can only read after.
    #[test]
    fn the_accounts_this_app_holds_come_before_the_ones_it_only_reads() {
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        let observed = AccountAddr::from(&Ed25519SigningKey::generate().verifying_key());

        assert!(core.observe(&observed).unwrap());
        assert!(!core.observe(&observed).unwrap());
        let held = core.create_account(None).unwrap();

        let accounts = core.accounts().unwrap();
        assert_eq!(
            accounts
                .iter()
                .map(|account| (account.address.as_str(), account.managed))
                .collect::<Vec<_>>(),
            vec![
                (held.to_string().as_str(), true),
                (observed.to_string().as_str(), false)
            ]
        );
        assert!(!accounts[1].protected);
        assert_eq!(accounts[1].pending, 0);
    }

    /// The whole of observing: the log the store serves under the address,
    /// verified against it, on the screen a managed account already has.
    #[test]
    fn an_observed_account_draws_the_log_without_a_key() {
        let store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        publish_elsewhere(
            key,
            store.clone(),
            vec![
                AccountEntry::add(DISPLAY_NAME_CONTEXT.clone(), EntryData::Text("Raya".into())),
                AccountEntry::add(
                    SIGNER_CONTEXT.clone(),
                    EntryData::Ed25519Key(installation_key()),
                ),
            ],
        );
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store);
        core.observe(&addr).unwrap();

        // Observed and not read yet, which is not an account holding nothing.
        let state = core.state(&addr).unwrap();
        assert!(!state.managed);
        assert!(!state.resolved);
        assert!(!state.published);
        assert_eq!(state.read_at_ms, None);

        core.refresh(&addr).unwrap();

        let state = core.state(&addr).unwrap();
        assert!(!state.managed);
        assert!(!state.protected);
        assert!(state.resolved);
        assert!(state.published);
        assert_eq!(state.display_name.as_deref(), Some("Raya"));
        assert_eq!(state.installations.len(), 1);
        assert_eq!(state.problem, None);
        assert!(state.read_at_ms.is_some());
    }

    /// Every write needs the key, so every write is refused the same way,
    /// rather than each failing in its own words wherever it reaches for one.
    #[test]
    fn an_observed_account_takes_no_edits() {
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        let addr = AccountAddr::from(&Ed25519SigningKey::generate().verifying_key());
        core.observe(&addr).unwrap();

        assert!(matches!(
            core.stage_set_display_name(&addr, "Raya"),
            Err(CoreError::NotManaged)
        ));
        assert!(matches!(
            core.stage_add_installation(&addr, &hex::encode(installation_key())),
            Err(CoreError::NotManaged)
        ));
        assert!(matches!(
            core.stage_revoke(&addr, 0),
            Err(CoreError::NotManaged)
        ));
        assert!(matches!(
            core.discard_pending(&addr),
            Err(CoreError::NotManaged)
        ));
        assert!(matches!(
            core.publish(&addr, None),
            Err(CoreError::NotManaged)
        ));
        assert!(matches!(
            core.export_account(&addr, None),
            Err(CoreError::NotManaged)
        ));
        assert!(matches!(
            core.forget_account(&addr),
            Err(CoreError::NotManaged)
        ));
    }

    /// An address this app was never asked to have is refused before it
    /// reaches the store, so a stale one cannot make it fetch what it names.
    #[test]
    fn an_account_neither_held_nor_observed_is_not_read_at_all() {
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        let addr = AccountAddr::from(&Ed25519SigningKey::generate().verifying_key());

        assert!(matches!(core.refresh(&addr), Err(CoreError::Unknown)));
        assert!(matches!(core.state(&addr), Err(CoreError::Unknown)));
        assert!(matches!(
            core.stage_set_display_name(&addr, "Raya"),
            Err(CoreError::Unknown)
        ));
        assert!(matches!(
            core.stop_observing(&addr),
            Err(CoreError::Unknown)
        ));
    }

    /// The key of an observed account arriving makes it managed, and one
    /// account stays one row.
    #[test]
    fn importing_the_key_of_an_observed_account_makes_it_managed() {
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url("memory"));
        core.observe(&addr).unwrap();

        core.import_account(&hex::encode(key.as_bytes()), None)
            .unwrap();

        let accounts = core.accounts().unwrap();
        assert_eq!(accounts.len(), 1);
        assert!(accounts[0].managed);
        assert!(matches!(
            core.observe(&addr),
            Err(CoreError::AlreadyManaged)
        ));
        core.stage_set_display_name(&addr, "Raya").unwrap();

        // Out of the observed list, not merely hidden behind the vault: were
        // it still in there, giving the key up would bring the account back as
        // a row this app only reads.
        core.forget_account(&addr).unwrap();
        assert!(core.accounts().unwrap().is_empty());
    }

    /// Stopping leaves nothing here about the account, so observing it again
    /// starts from the store rather than from what was already on screen.
    #[test]
    fn stop_observing_drops_the_account_and_what_was_read() {
        let store = Store::from_url("memory");
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        publish_elsewhere(
            key,
            store.clone(),
            vec![AccountEntry::add(
                DISPLAY_NAME_CONTEXT.clone(),
                EntryData::Text("Raya".into()),
            )],
        );
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store);
        core.observe(&addr).unwrap();
        core.refresh(&addr).unwrap();

        core.stop_observing(&addr).unwrap();

        assert!(core.accounts().unwrap().is_empty());
        assert!(matches!(core.state(&addr), Err(CoreError::Unknown)));

        core.observe(&addr).unwrap();
        let state = core.state(&addr).unwrap();
        assert!(!state.resolved);
        assert_eq!(state.display_name, None);
    }

    /// The store answered with a real log that this address did not sign. One
    /// signature covers the whole log, so none of it is shown, and the row
    /// says which way the read failed rather than that it failed.
    #[test]
    fn a_log_the_address_did_not_sign_leaves_the_account_unread() {
        let mut store = Store::from_url("memory");
        let addr = AccountAddr::from(&Ed25519SigningKey::generate().verifying_key());
        store
            .publish(&addr, &signed_log(&Ed25519SigningKey::generate(), "Raya"))
            .unwrap();
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), store);
        core.observe(&addr).unwrap();

        assert!(core.refresh(&addr).is_err());

        let state = core.state(&addr).unwrap();
        assert!(!state.resolved);
        assert!(!state.published);
        assert!(state.entries.is_empty());
        assert_eq!(state.display_name, None);
        assert_eq!(state.problem, Some(ReadProblem::Unverified));
    }

    /// A store that stops answering leaves the copy already read where it is,
    /// and says why it is not the store's last word.
    #[test]
    fn a_read_that_fails_keeps_the_copy_already_read() {
        use crate::store::tests::{answer_bytes, serve_bytes};
        let key = Ed25519SigningKey::generate();
        let addr = AccountAddr::from(&key.verifying_key());
        let url = serve_bytes(vec![
            answer_bytes("200 OK", &signed_log(&key, "Raya").to_bytes()),
            answer_bytes("503 Service Unavailable", b""),
        ]);
        let vault = tempfile::tempdir().unwrap();
        let mut core = AccountCore::new(vault.path(), Store::from_url(&url));
        core.observe(&addr).unwrap();
        core.refresh(&addr).unwrap();

        assert!(core.refresh(&addr).is_err());

        let state = core.state(&addr).unwrap();
        assert!(state.resolved);
        assert_eq!(state.display_name.as_deref(), Some("Raya"));
        assert!(state.read_at_ms.is_some());
        assert_eq!(state.problem, Some(ReadProblem::Unanswered));
    }
}
