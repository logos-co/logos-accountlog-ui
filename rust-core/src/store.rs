//! Where a log is published and read back.
//!
//! The account crates take their provider by value, and this app needs the
//! same store in three places at once (the resolver, each publish, and the
//! read-back that confirms it), so every provider here is a cheap handle over
//! shared state rather than the state itself.
//!
//! Over HTTP, the store is chat-store's `/v1/account/{address}`
//! (logos-messaging/chat-store#8). A log crosses it as the artifact the
//! account-log crate transmits, `signature || payload`, in both directions.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use account::{AccountProvider, AccountPublisher};
use account_log::{AccountAddr, SignedAccountLog, MAX_PAYLOAD_BYTES};
use serde::Deserialize;
use thiserror::Error;

/// The devnet service the chat team runs. Overridable, because the route this
/// client calls lands there after this app does.
pub const DEFAULT_STORE_URL: &str = "https://devnet.chat-kc.logos.co";

const FETCH_TIMEOUT: Duration = Duration::from_secs(15);

/// The largest artifact a store can answer with: the format's payload cap
/// plus the signature in front of it.
const MAX_ARTIFACT_BYTES: u64 = MAX_PAYLOAD_BYTES as u64 + 64;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("store request failed: {0}")]
    Transport(String),
    #[error("the store refused the log: it is not an extension of what it holds")]
    Diverged,
    #[error("this store has no account-log route: nothing answers /v1/account there")]
    NoRoute,
    #[error("store returned {code}{}", reason.as_deref().map(|r| format!(": {r}")).unwrap_or_default())]
    Status { code: u16, reason: Option<String> },
    #[error("store returned something that is not a signed log: {0}")]
    Malformed(String),
}

/// The body chat-store answers every failure with.
#[derive(Deserialize)]
struct ErrorBody {
    error: String,
}

/// What the store said went wrong, if it said it the way chat-store does.
fn reason(response: &mut ureq::http::Response<ureq::Body>) -> Option<String> {
    let text = response
        .body_mut()
        .with_config()
        .limit(4096)
        .read_to_string()
        .ok()?;
    serde_json::from_str::<ErrorBody>(&text)
        .ok()
        .map(|body| body.error)
}

fn transport(e: ureq::Error) -> StoreError {
    StoreError::Transport(match e {
        ureq::Error::Timeout(_) => format!("no answer within {} s", FETCH_TIMEOUT.as_secs()),
        ureq::Error::Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
            "connection refused".into()
        }
        other => other.to_string(),
    })
}

/// chat-store over HTTP.
#[derive(Clone)]
pub struct ChatStore {
    base_url: Arc<str>,
    agent: ureq::Agent,
}

impl ChatStore {
    pub fn new(base_url: &str) -> Self {
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(FETCH_TIMEOUT))
            .build();
        Self {
            base_url: base_url.trim_end_matches('/').into(),
            agent: config.into(),
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    fn url(&self, addr: &AccountAddr) -> String {
        format!("{}/v1/account/{addr}", self.base_url)
    }
}

impl AccountProvider for ChatStore {
    type Error = StoreError;

    fn fetch(&self, addr: &AccountAddr) -> Result<Option<SignedAccountLog>, Self::Error> {
        let mut response = self
            .agent
            .get(&self.url(addr))
            .config()
            .http_status_as_error(false)
            .build()
            .call()
            .map_err(transport)?;
        match response.status().as_u16() {
            200..=299 => {}
            // An account that has never published is not a failure to report,
            // and the route says so in its own words. A 404 without them is a
            // server with no such route, which must not read as an account
            // that has published nothing.
            404 => {
                return match reason(&mut response) {
                    Some(_) => Ok(None),
                    None => Err(StoreError::NoRoute),
                }
            }
            code => {
                return Err(StoreError::Status {
                    code,
                    reason: reason(&mut response),
                })
            }
        }
        let artifact = response
            .body_mut()
            .with_config()
            .limit(MAX_ARTIFACT_BYTES)
            .read_to_vec()
            .map_err(|e| match e {
                ureq::Error::BodyExceedsLimit(_) => StoreError::Malformed(e.to_string()),
                // The body stopped coming: the connection's failure, not the log's.
                other => transport(other),
            })?;
        SignedAccountLog::from_bytes(&artifact)
            .map(Some)
            .map_err(|e| StoreError::Malformed(e.to_string()))
    }
}

impl AccountPublisher for ChatStore {
    type Error = StoreError;

    fn publish(&mut self, addr: &AccountAddr, log: &SignedAccountLog) -> Result<(), Self::Error> {
        let mut response = self
            .agent
            .post(&self.url(addr))
            .config()
            // A POST redirected with 301, 302 or 303 is re-sent as a GET, whose
            // answer would pass for a publish that never happened.
            .max_redirects(0)
            .http_status_as_error(false)
            .build()
            .header("Content-Type", "application/octet-stream")
            .send(log.to_bytes())
            .map_err(transport)?;
        match response.status().as_u16() {
            200..=299 => Ok(()),
            // The store holds a log this one does not extend: a longer copy of
            // it, or another history under the same address.
            409 => Err(StoreError::Diverged),
            404 => Err(StoreError::NoRoute),
            code => Err(StoreError::Status {
                code,
                reason: reason(&mut response),
            }),
        }
    }
}

/// A store in memory, shared by every clone. What the tests publish to, and
/// what the app falls back on only when it is told to run without a store.
#[derive(Clone, Default)]
pub struct MemoryStore(Arc<Mutex<Vec<(AccountAddr, SignedAccountLog)>>>);

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn held(&self, addr: &AccountAddr) -> Option<SignedAccountLog> {
        let held = self.0.lock().expect("store lock");
        held.iter()
            .find(|(held, _)| held == addr)
            .map(|(_, log)| log.clone())
    }
}

impl AccountProvider for MemoryStore {
    type Error = StoreError;

    fn fetch(&self, addr: &AccountAddr) -> Result<Option<SignedAccountLog>, Self::Error> {
        Ok(self.held(addr))
    }
}

impl AccountPublisher for MemoryStore {
    type Error = StoreError;

    /// Enforces what the real route will: a log is accepted only where it
    /// extends the one held, so a test cannot pass against a store more
    /// permissive than the service.
    fn publish(&mut self, addr: &AccountAddr, log: &SignedAccountLog) -> Result<(), Self::Error> {
        let mut held = self.0.lock().expect("store lock");
        match held.iter_mut().find(|(held, _)| held == addr) {
            Some((_, existing)) => {
                let candidate = log.payload.as_bytes();
                if !candidate.starts_with(existing.payload.as_bytes()) {
                    return Err(StoreError::Diverged);
                }
                *existing = log.clone();
            }
            None => held.push((addr.clone(), log.clone())),
        }
        Ok(())
    }
}

/// The store this app was pointed at. One type rather than a type parameter,
/// because the choice is made once from the environment and every caller below
/// would otherwise carry it.
#[derive(Clone)]
pub enum Store {
    /// The chat team's service, over HTTP.
    Chat(ChatStore),
    /// This process's own memory. What the tests publish to, and what a harness
    /// with no network gets.
    Memory(MemoryStore),
}

impl Store {
    /// `memory` selects the in-process store; anything else is a base URL.
    pub fn from_url(url: &str) -> Self {
        match url {
            "memory" => Self::Memory(MemoryStore::new()),
            url => Self::Chat(ChatStore::new(url)),
        }
    }

    pub fn describe(&self) -> String {
        match self {
            Self::Chat(store) => store.base_url().to_owned(),
            Self::Memory(_) => "memory".to_owned(),
        }
    }
}

impl AccountProvider for Store {
    type Error = StoreError;

    fn fetch(&self, addr: &AccountAddr) -> Result<Option<SignedAccountLog>, Self::Error> {
        match self {
            Self::Chat(store) => store.fetch(addr),
            Self::Memory(store) => store.fetch(addr),
        }
    }
}

impl AccountPublisher for Store {
    type Error = StoreError;

    fn publish(&mut self, addr: &AccountAddr, log: &SignedAccountLog) -> Result<(), Self::Error> {
        match self {
            Self::Chat(store) => store.publish(addr, log),
            Self::Memory(store) => store.publish(addr, log),
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use account_log::{AccountLogDraft, Context, Ed25519SigningKey, EntryData};

    fn signed(key: &Ed25519SigningKey, values: &[&str]) -> (AccountAddr, SignedAccountLog) {
        let context = Context::new("chat.signer").unwrap();
        let mut draft = AccountLogDraft::new();
        for value in values {
            draft
                .add(context.clone(), EntryData::Text((*value).into()))
                .unwrap();
        }
        let payload = draft.log().encode().unwrap();
        let signature = key.sign(payload.as_bytes());
        (
            AccountAddr::from(&key.verifying_key()),
            SignedAccountLog { payload, signature },
        )
    }

    #[test]
    fn a_store_nothing_listens_on_is_named_plainly() {
        let addr = AccountAddr::from(&Ed25519SigningKey::generate().verifying_key());
        let error = ChatStore::new("http://127.0.0.1:9")
            .fetch(&addr)
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            "store request failed: connection refused"
        );
    }

    #[test]
    fn an_account_that_never_published_fetches_to_nothing() {
        let store = MemoryStore::new();
        let addr = AccountAddr::from(&Ed25519SigningKey::generate().verifying_key());
        assert_eq!(store.fetch(&addr).unwrap(), None);
    }

    #[test]
    fn an_extension_is_stored_and_read_back() {
        let key = Ed25519SigningKey::generate();
        let mut store = MemoryStore::new();
        let (addr, first) = signed(&key, &["saro"]);
        let (_, second) = signed(&key, &["saro", "raya"]);

        store.publish(&addr, &first).unwrap();
        store.publish(&addr, &second).unwrap();

        assert_eq!(store.fetch(&addr).unwrap(), Some(second));
    }

    /// The fake refuses what the route will refuse, so a test that passes here
    /// is not passing because the store was lenient.
    #[test]
    fn a_log_that_does_not_extend_is_refused() {
        let key = Ed25519SigningKey::generate();
        let mut store = MemoryStore::new();
        let (addr, held) = signed(&key, &["saro", "raya"]);
        let (_, forked) = signed(&key, &["pax", "raya", "saro"]);

        store.publish(&addr, &held).unwrap();

        assert!(matches!(
            store.publish(&addr, &forked),
            Err(StoreError::Diverged)
        ));
        assert_eq!(store.fetch(&addr).unwrap(), Some(held));
    }

    /// Every clone is the same store, which is what lets one live in the
    /// resolver and another in each publish.
    #[test]
    fn clones_share_one_store() {
        let key = Ed25519SigningKey::generate();
        let store = MemoryStore::new();
        let (addr, log) = signed(&key, &["saro"]);

        store.clone().publish(&addr, &log).unwrap();

        assert_eq!(store.fetch(&addr).unwrap(), Some(log));
    }

    /// Answers each connection with the next canned response, after reading
    /// the whole request so the client is never cut off mid-send.
    pub(crate) fn serve(answers: Vec<String>) -> String {
        use std::io::{BufRead, BufReader, Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for answer in answers {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut length = 0;
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap();
                    }
                    if line == "\r\n" {
                        break;
                    }
                }
                reader.read_exact(&mut vec![0; length]).unwrap();
                reader.into_inner().write_all(answer.as_bytes()).unwrap();
            }
        });
        url
    }

    /// One HTTP response, with `extra` headers and `body`.
    pub(crate) fn answer(status: &str, extra: &str, body: &str) -> String {
        format!(
            "HTTP/1.1 {status}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    pub(crate) fn json_error(status: &str, error: &str) -> String {
        answer(
            status,
            "Content-Type: application/json\r\n",
            &format!("{{\"error\":\"{error}\"}}"),
        )
    }

    fn addr() -> AccountAddr {
        AccountAddr::from(&Ed25519SigningKey::generate().verifying_key())
    }

    #[test]
    fn a_body_cut_short_is_the_connection_failing_not_the_log() {
        let store = ChatStore::new(&serve(vec![
            "HTTP/1.1 200 OK\r\nContent-Length: 200\r\nConnection: close\r\n\r\n0123456789".into(),
        ]));
        assert!(matches!(
            store.fetch(&addr()),
            Err(StoreError::Transport(_))
        ));
    }

    #[test]
    fn the_routes_own_404_is_an_account_that_never_published() {
        let store = ChatStore::new(&serve(vec![json_error(
            "404 Not Found",
            "no account log for account_addr",
        )]));
        assert_eq!(store.fetch(&addr()).unwrap(), None);
    }

    /// The default store answers every unknown path this way, so reading it as
    /// "nothing published" would hide that the route is not there at all.
    #[test]
    fn a_bare_404_is_a_store_without_the_route() {
        let store = ChatStore::new(&serve(vec![answer("404 Not Found", "", "")]));
        assert!(matches!(store.fetch(&addr()), Err(StoreError::NoRoute)));
    }

    #[test]
    fn a_redirected_publish_is_not_a_publish() {
        let mut store = ChatStore::new(&serve(vec![answer(
            "301 Moved Permanently",
            "Location: /elsewhere\r\n",
            "",
        )]));
        let (addr, log) = signed(&Ed25519SigningKey::generate(), &["saro"]);
        assert!(matches!(
            store.publish(&addr, &log),
            Err(StoreError::Status { code: 301, .. })
        ));
    }

    #[test]
    fn a_refusal_carries_the_stores_reason() {
        let mut store = ChatStore::new(&serve(vec![json_error(
            "400 Bad Request",
            "payload: not a log",
        )]));
        let (addr, log) = signed(&Ed25519SigningKey::generate(), &["saro"]);
        let error = store.publish(&addr, &log).unwrap_err().to_string();
        assert_eq!(error, "store returned 400: payload: not a log");
    }

    #[test]
    fn a_base_url_keeps_one_spelling() {
        assert_eq!(
            ChatStore::new("https://example.test/").base_url(),
            "https://example.test"
        );
    }
}
