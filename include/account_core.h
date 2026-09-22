// logos-account-core: the account write path, as a linkable library.
//
// Link against liblogos_account_core.a. The library is the whole of what this
// app decides about an account: it holds the keys, stages edits to a log, signs
// them and publishes them, and reads the logs of accounts whose key is
// elsewhere. Nothing below is a Logos module call, so no key and no password
// crosses a process boundary.
//
// Ownership: every char * returned here belongs to the caller and must be
// released with logos_account_core_string_free, which clears it first. The
// one const char *, the default store URL, is static and never freed.
//
// Replies: every call returns JSON with an `ok` field. A failure is
// {"ok":false,"error":"..."} rather than a null return, so a caller that only
// ever parses JSON stays correct on every path.
//
// Threads: the handle is internally synchronised, so calls may be made from
// any thread. They are not cancellable, and the two that reach the network
// (refresh, publish) block for as long as the store takes.
//
// No function unwinds, and every one tolerates a NULL handle or NULL string.
// A string that is not UTF-8 is refused, never read as absent.

#ifndef LOGOS_ACCOUNT_CORE_H
#define LOGOS_ACCOUNT_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LogosAccountCore LogosAccountCore;

// The store this app points at when nothing else says otherwise. Static: do
// not free it.
const char *logos_account_core_default_store_url(void);

// Open the vault directory at `vault_dir`, creating it on first write, and
// point the app at `store_url`. The literal "memory" selects an in-process
// store, which is what a harness with no network gets.
//
// Returns NULL only if an argument is absent or not UTF-8.
LogosAccountCore *logos_account_core_new(const char *vault_dir, const char *store_url);

// Safe on NULL.
void logos_account_core_free(LogosAccountCore *core);

// Clear and release any char * returned by this library. Safe on NULL.
void logos_account_core_string_free(char *text);

// {"ok":true,"store":"…","accounts":[{address,managed,protected,locked,
//                                     resolved,displayName,pending,problem}]}
//
// Reads no store. Every account this app has, the ones it holds a key for
// first and the ones it only observes after, which is the order a switcher
// lists them in. `managed` is false for an observed account, which has no key
// here, nothing to protect and nothing to publish. `locked` is true for a
// sealed account this handle has not unlocked. `resolved` says the store
// has answered for the account this session; `displayName` is null until it
// has, and when the log names none. `problem` is null unless the last read did
// not land: one of "unverified", "forked", "unanswered".
char *logos_account_core_accounts(LogosAccountCore *core);

// Generate an account and take it into the vault. A NULL `password` means the
// account chooses none, and its key is then stored in the clear. A sealed one
// starts unlocked, as logos_account_core_unlock leaves it.
// {"ok":true,"address":"<64 hex>"}
char *logos_account_core_create_account(LogosAccountCore *core, const char *password);

// Take an account made elsewhere, from the 32-byte secret its holder exported
// as 64 hex characters. {"ok":true,"address":"<64 hex>","alreadyHeld":b}: an
// account the vault already holds is found rather than refused, and kept as it
// is, password and all. A sealed one taken in starts unlocked.
char *logos_account_core_import_account(LogosAccountCore *core,
                                        const char *secret_hex,
                                        const char *password);

// {"ok":true,"key":"<64 hex>"}: the account's own secret. Whoever holds those
// bytes is the account, so a copy the caller makes of the reply is worth
// clearing too.
char *logos_account_core_export_account(LogosAccountCore *core,
                                        const char *address,
                                        const char *password);

// Open a sealed account's key and hold it until the handle is freed, so a
// publish asks for no password. An export still asks for it. Refused for a
// wrong password, and for an account that has none.
char *logos_account_core_unlock(LogosAccountCore *core,
                                const char *address,
                                const char *password);

// Drop the account and its key from the vault. Nothing here can recover it,
// and the log it signed can never be extended again.
char *logos_account_core_forget_account(LogosAccountCore *core, const char *address);

// Start reading the log published under this address, whose key is somewhere
// else. {"ok":true,"alreadyObserved":b}: an address already observed is found
// rather than refused. An address the vault holds is refused, since this app
// manages that account rather than observing it.
//
// Nothing is read here: the address is taken on, and
// logos_account_core_refresh fetches it.
char *logos_account_core_observe_account(LogosAccountCore *core, const char *address);

// Stop reading the log under this address, dropping what was read with it.
// Refused for an address this app does not observe. Nothing is lost that the
// store does not still hold.
char *logos_account_core_stop_observing(LogosAccountCore *core, const char *address);

// {"ok":true,"dropped":n}: read the store for this account, adopting the log
// only where it extends what is already held, and drop the staged edits that
// log already holds. n counts them since the last answer, so a publish that
// failed after its own read leaves its count to this one.
char *logos_account_core_refresh(LogosAccountCore *core, const char *address);

// {"ok":true,"state":{…}}: everything the Manage pane draws for one account,
// from what is already held. Reads no store.
//
// state = { address, managed, protected, locked, resolved, readAtMs, problem,
//           published, logBytes, maxBytes,
//           displayName, displayNameIndex,
//           previousNames:[{index,value}], installations:[{index,key}],
//           entries:[{index,kind,context,value,live,target,bytes,
//                     supersededBy}],
//           otherEntries:[…], unreadable, pending:[…],
//           costs:{installation,remove,displayName} }
//
// `entries` is every entry the account ever wrote, in order, each carrying the
// index a revocation targets and what it costs the log's 128 KiB lifetime
// budget. `kind` is one of installation, displayName, key, text, revocation,
// other. `pending` holds the entries the next publish will append, in the same
// shape and numbered as they will be once it lands. `costs` is what one more
// entry of each kind would cost, for a dialog that names the price before the
// edit exists; a display name costs `displayName` plus its own UTF-8 bytes.
// `resolved` says the store has answered for this account since the handle
// was opened, so a false `published` beside it means nothing was published
// rather than that the store could not be asked. `readAtMs` is when it
// answered, in milliseconds since the epoch, and null until it has. `problem`
// is why the last read did not land, null where it did: "unverified" for a log
// whose signature does not check against the address, "forked" for one that
// does not extend the log already read, "unanswered" for a store that did not
// answer with a log at all. Set beside a resolved account, it says the copy on
// screen is not the store's last word.
//
// Several display names can be live at once. The highest-indexed is the one
// in force, `displayName` at `displayNameIndex`, and each earlier one carries
// that index as `supersededBy`; `previousNames` lists the earlier ones newest
// first. `installations` is newest first too. `otherEntries` holds the live
// entries, in the shape of `entries`, under a namespace other than the two
// this app writes, profile and chat.
//
// `managed` is false for an observed account: the whole of what this app can
// do with it is on this reply, and every call below is refused for it.
// `locked` is true for a sealed account this handle has not unlocked, which
// can stage but not publish.
//
// Every stage call below is refused while `unreadable` is set, and for an edit
// that would take the log last read past its budget. A publish measures again
// against the log it reads.
char *logos_account_core_state(LogosAccountCore *core, const char *address);

// Stage an endorsement of an installation's public key, as 64 hex characters.
// Refused for a key already live in the log, under any context.
char *logos_account_core_stage_add_installation(LogosAccountCore *core,
                                                const char *address,
                                                const char *key_hex);

// Stage the display name, one entry appended after the names already live.
// Replaces any name already staged. The name in force drops a staged rename,
// and is refused when none is staged; refused too is a name that shows nothing
// or holds line breaks, control characters or text-direction overrides.
char *logos_account_core_stage_set_display_name(LogosAccountCore *core,
                                                const char *address,
                                                const char *name);

// Stage a revocation of the entry at `index`, which must be live now.
char *logos_account_core_stage_revoke(LogosAccountCore *core,
                                      const char *address,
                                      uint32_t index);

// Throw away everything staged for this account. Nothing was written, so
// nothing is undone.
char *logos_account_core_discard_pending(LogosAccountCore *core, const char *address);

// Read the store, then sign and publish every staged edit it does not already
// hold as one update. All or nothing: one rejected entry writes none of them.
// {"ok":true,"firstNewIndex":n,"dropped":d}: the index of the first entry
// written, null when the store already held every staged edit, and the staged
// edits it held, counted as refresh counts them. Refused while the account is
// locked, before the store is read.
char *logos_account_core_publish(LogosAccountCore *core, const char *address);

#ifdef __cplusplus
}
#endif

#endif // LOGOS_ACCOUNT_CORE_H
