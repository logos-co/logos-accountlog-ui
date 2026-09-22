# logos-accountlog-ui

A Logos app for the thing an account actually is: a log of entries, signed as a
whole by one key, published under the address that key derives.

The app holds the key. It lists the accounts this module has one for, replays
each account's log into the live set that log describes, stages edits as
pending entries, and sends them to chat-storage as a single update: every entry
is applied, or none is.

It also reads accounts it holds no key for. An **observed** account is an
address and nothing else: whatever the store serves under it, verified against
it, on the same screen with every control that needs a key taken out. Both
kinds are in one switcher, the managed ones first.

What the current pane does, in full:

- endorse an installation's public key under `chat.signer`, and revoke one;
- set the account's display name under `profile.displayname`, which appends
  the new name and leaves the earlier ones readable as previous aliases;
- list the live entries under any other namespace, read only;
- publish the staged entries, signing the whole log;
- create an account, import one made elsewhere, unlock it, export its key,
  forget it;
- observe an account by address, read its log, and stop.

A password is per account, not per module: an account can be sealed with one,
or stored unsealed, and the screen says which at every point where it matters.
A sealed account is unlocked once per session, by making or importing it or by
its password after a restart, and its key stays open until the app closes, so
publishing asks for nothing. Exporting the key asks for the password every time.

## Layout

| Path | What it is |
|---|---|
| `rust-core/` | Everything the app decides. Vault, observed accounts, store client, staging rules, and the C ABI. Builds as a static archive. |
| `include/account_core.h` | That library's C header, and the reference for the JSON it answers with. |
| `src/accountlog_ui.rep` | The QtRO contract between the backend and the view. |
| `src/AccountLogBackend.{h,cpp}` | The backend: marshals view calls onto a worker thread and publishes the results as properties. |
| `src/qml/AccountLogView.qml` | The view's entry point, named by `metadata.json`. |
| `src/qml/AccountLog/` | The view's own QML module: `Store.qml` is the only file that talks to the host. |

The account log format itself, the signing and the resolver come from
[logos-chat](https://github.com/logos-messaging/logos-chat); this repo adds no
crypto of its own.

### Two rules the contract keeps

Every slot returns void. A slot with a return value reaches QML as a
`QRemoteObjectPendingReply`, and two of the calls behind these slots reach the
network; so a slot is a request, and the answer arrives as a property change or
a signal.

The tables cross as JSON text. The backend holds nothing the library does not
already hold, so a remoted model would be a second copy of the log with its own
staleness. The format caps a log at 128 KiB, so the whole of it fits in one
property.

## Where things are kept

The vault is one directory holding one file per account, sealed (an
eth-keystore v3 document) or in the clear, by that account's own choice. It
lives under `GenericDataLocation/logos/accountlog-ui/vault`, which
`LOGOS_ACCOUNTLOG_VAULT_DIR` overrides.

The observed accounts are one file in that same directory, `observed.json`: a
list of addresses and nothing else, since an account with no key here has
nothing to seal. One directory is this app's data, whether or not a given
account in it has a key.

By default the app publishes to chat-store on devnet,
`https://devnet.chat-kc.logos.co`. `LOGOS_ACCOUNTLOG_STORE_URL` points it at
another store. The literal `memory` selects an in-process store, for a run with
no network.

## Documentation

The tutorial is executable. `doctests/accountlog-ui.test.yaml` builds the app,
launches it headless in `logos-standalone-app` and drives the real QML surface:
make a key, name the account, endorse an installation, publish, then give a
second account's key up and read its log from the outside. Every figure it
shows was measured by the app's own library during that run.

```sh
nix run github:logos-co/logos-doctest -- run doctests/accountlog-ui.test.yaml --verbose
nix run github:logos-co/logos-doctest -- generate doctests/accountlog-ui.test.yaml -o /tmp/accountlog-ui.md
```

The driving is `nix run .#walkthrough`, a standalone test that checks the app's
own state at every step and fails the run if any of them is missed. Every
figure in the tutorial is a screenshot it took on the way through, published
beside the report by the CI job that ran it.
[`doctests/walkthrough`](doctests/walkthrough/README.md) explains how it works
and how to run it by hand.

CI runs it on every push and publishes the two-column report, the tutorial
beside the commands that actually ran, to
<https://logos-co.github.io/logos-accountlog-ui/>.

It runs against the in-process store, so it needs nothing on the network and
leaves nothing on devnet, where a published log cannot be deleted. The
in-process store enforces the rule chat-store's `/v1/account` route does: a log
is accepted only where it extends the one held.

## Building

```sh
nix build .#default
```

The Rust library is built by this flake and handed to the module builder as an
external library, so the library and the plugin that links it are versioned by
one commit.

## Checks

The library:

```sh
cd rust-core
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

The view, which needs the design system's source on the import path:

```sh
ds=$(nix eval --impure --raw --expr \
  '(builtins.getFlake (toString ./.)).inputs.logos-module-builder.inputs.logos-design-system.outPath')/src/qml

qmllint --max-warnings 0 --unqualified info \
  -I src/qml -I "$ds" $(find src/qml -name '*.qml' | sort)
```

`logos` is a context property the ui-host installs, so qmllint cannot know it
and reports every use of it: that is what `--unqualified info` is for. Anything
else it reports is a finding.
