// logos-account-core: the account write path, as a linkable library.
//
// Link against liblogos_account_core.a. The library is the whole of what this
// app decides about an account: it holds the keys, stages edits to a log, signs
// them and publishes them. Nothing below is a Logos module call, so no key and
// no password crosses a process boundary.
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

// {"ok":true,"store":"…","accounts":[{address,protected,resolved,displayName,pending}]}
//
// Reads the vault only. `resolved` says the store has answered for the account
// this session; `displayName` is null until it has, and when the log names
// none.
char *logos_account_core_accounts(LogosAccountCore *core);

// Generate an account and take it into the vault. A NULL `password` means the
// account chooses none, and its key is then stored in the clear.
// {"ok":true,"address":"<64 hex>"}
char *logos_account_core_create_account(LogosAccountCore *core, const char *password);

// Take an account made elsewhere, from the 32-byte secret its holder exported
// as 64 hex characters. {"ok":true,"address":"<64 hex>","alreadyHeld":b}: an
// account the vault already holds is found rather than refused, and kept as it
// is, password and all.
char *logos_account_core_import_account(LogosAccountCore *core,
                                        const char *secret_hex,
                                        const char *password);

// {"ok":true,"key":"<64 hex>"}: the account's own secret. Whoever holds those
// bytes is the account, so a copy the caller makes of the reply is worth
// clearing too.
char *logos_account_core_export_account(LogosAccountCore *core,
                                        const char *address,
                                        const char *password);

// Drop the account and its key from the vault. Nothing here can recover it,
// and the log it signed can never be extended again.
char *logos_account_core_forget_account(LogosAccountCore *core, const char *address);

// {"ok":true,"dropped":n}: read the store for this account, adopting the log
// only where it extends what is already held, and drop the staged edits that
// log already holds. n counts them since the last answer, so a publish that
// failed after its own read leaves its count to this one.
char *logos_account_core_refresh(LogosAccountCore *core, const char *address);

// {"ok":true,"state":{…}}: everything the Manage pane draws for one account,
// from what is already held. Reads no store.
//
// state = { address, protected, resolved, published, logBytes, maxBytes,
//           domainBytes, displayName, installations:[{index,key}],
//           entries:[{index,kind,context,value,live,target,bytes}],
//           unreadable, pending:[…],
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
// rather than that the store could not be asked.
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

// Stage the display name. Replaces any name already staged: two of them in one
// update would revoke the live name twice, which the log refuses. The live
// name drops a staged rename, and is refused when none is staged; refused too
// is a name that shows nothing or holds line breaks, control characters or
// text-direction overrides.
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
// edits it held, counted as refresh counts them.
char *logos_account_core_publish(LogosAccountCore *core,
                                 const char *address,
                                 const char *password);

#ifdef __cplusplus
}
#endif

#endif // LOGOS_ACCOUNT_CORE_H
