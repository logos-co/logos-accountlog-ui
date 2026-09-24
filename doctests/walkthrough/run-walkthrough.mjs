// Write a whole account log by driving an already-running logos-accounts-ui
// instance, and capture a screenshot of each step for the docs.
//
// The walkthrough is a sequence of screens, and each step is finished when the
// app says so -- a key exists, a sheet is up, an entry is staged, the store
// serves it. This driver speaks the logos-qt-mcp inspector protocol directly,
// so every step waits on the app's own state rather than on a timer, and the
// screenshot is taken once that state has been reached. Launch + teardown of
// the app is handled by run-walkthrough.sh; this script attaches to the
// inspector port it is given.
//
// Nothing here reaches past the QML the person sees: the controls are found by
// objectName and clicked, the fields are filled by writing their `text`, and
// the account library is only ever called the way a button calls it.
//
// Env:
//   APP_PORT   inspector port (default 3768)
//   OUT_DIR    screenshot output dir (default ./images)
import net from "node:net";
import fs from "node:fs";

// ── inspector client: newline-delimited JSON over TCP ────────────────────────
class Inspector {
  constructor(host, port) { this.host = host; this.port = port; this.socket = null; this.requestId = 0; this.pending = new Map(); this.buffer = ""; }
  async connect() {
    if (this.socket && !this.socket.destroyed) return;
    return new Promise((resolve, reject) => {
      const sock = net.createConnection({ host: this.host, port: this.port });
      sock.once("connect", () => { this.socket = sock; resolve(); });
      sock.once("error", (err) => reject(new Error(`connect ${this.port}: ${err.message}`)));
      sock.on("data", (c) => { this.buffer += c.toString("utf-8"); this._drain(); });
      sock.on("close", () => { this.socket = null; for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(new Error("connection closed")); } this.pending.clear(); });
      sock.on("error", () => {});
    });
  }
  _drain() { let i; while ((i = this.buffer.indexOf("\n")) !== -1) { const line = this.buffer.slice(0, i).trim(); this.buffer = this.buffer.slice(i + 1); if (!line) continue; try { const m = JSON.parse(line); const p = this.pending.get(String(m.id)); if (p) { clearTimeout(p.timer); this.pending.delete(String(m.id)); p.resolve(m); } } catch {} } }
  async send(command, params = {}) {
    await this.connect();
    const id = ++this.requestId;
    const payload = JSON.stringify({ id, command, params }) + "\n";
    return new Promise((resolve, reject) => { const timer = setTimeout(() => { this.pending.delete(String(id)); reject(new Error(`inspector timeout: ${command}`)); }, 30000); this.pending.set(String(id), { resolve, reject, timer }); this.socket.write(payload); });
  }
  disconnect() { if (this.socket) this.socket.destroy(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Evaluate a QML expression in AccountLogView's root scope, where the ids the
// view declares -- store, view, and each sheet -- are all visible.
async function evalq(insp, expr) {
  const r = await insp.send("evaluate", { expression: expr });
  if (r.error) throw new Error(`eval(${expr}): ${r.error}`);
  return r.result;
}

async function waitFor(fn, { timeout = 30000, interval = 250, what = "condition" } = {}) {
  const start = Date.now(); let last;
  while (Date.now() - start < timeout) {
    try { if (await fn()) return; } catch (e) { last = e; }
    await sleep(interval);
  }
  throw new Error(`timed out waiting for ${what}${last ? " (" + last.message + ")" : ""}`);
}

// Wait until a QML expression equals `expected`. The whole walkthrough is
// sequenced on these: a click is delivered asynchronously, so what says it
// landed is the app's own state changing, never elapsed time.
async function waitUntil(insp, expr, expected, opts = {}) {
  await waitFor(async () => (await evalq(insp, expr)) === expected,
    { what: `${expr} === ${JSON.stringify(expected)}`, ...opts });
}

// Resolve one control by objectName. Every sheet is instantiated at once and
// only one is visible, so each control this walkthrough touches is uniquely
// named and a second match means the QML changed under us.
async function findOne(insp, objectName) {
  const r = await insp.send("findByProperty", { property: "objectName", value: objectName });
  if (r.error) throw new Error(`find ${objectName}: ${r.error}`);
  const matches = r.matches || [];
  if (matches.length !== 1) throw new Error(`find ${objectName}: expected 1 match, got ${matches.length}`);
  return matches[0].id;
}

// Evaluate an expression against one object rather than the view's root, for
// reading a control's own state.
async function evalOn(insp, objectId, expr) {
  const r = await insp.send("evaluate", { expression: expr, objectId });
  if (r.error) throw new Error(`eval(${expr}) on ${objectId}: ${r.error}`);
  return r.result;
}

async function click(insp, objectName) {
  const id = await findOne(insp, objectName);
  // Every button on this walkthrough is enabled by something -- a sheet's
  // input being valid, a publish having something to send, the library not
  // being busy. A disabled one takes the press and emits nothing, so waiting
  // here says "not ready yet" instead of leaving the next wait to time out.
  await waitFor(async () => (await evalOn(insp, id, "enabled")) === true,
    { what: `${objectName} to be enabled` });
  const r = await insp.send("click", { objectId: id });
  if (r.error) throw new Error(`click ${objectName}: ${r.error}`);
  console.log(`  click ${objectName}`);
}

async function type(insp, objectName, value) {
  const r = await insp.send("setProperty", { objectId: await findOne(insp, objectName), property: "text", value });
  if (r.error) throw new Error(`type into ${objectName}: ${r.error}`);
}

async function shoot(insp, outDir, name) {
  // The scene graph renders what the bindings already hold, but a screen that
  // has just changed still owes a layout pass, so let it settle before the grab.
  await sleep(500);
  const r = await insp.send("screenshot", {});
  if (r.error || !r.image) throw new Error(`screenshot ${name}: ${r.error || "no image"}`);
  fs.writeFileSync(`${outDir}/${name}`, Buffer.from(r.image, "base64"));
  console.log(`  screenshot ${name} (${r.width}x${r.height})`);
}

// A store that cannot be read says so on storeProblem, and a refused publish on
// the notice, rather than by leaving the log short. Reading them turns a silent
// stall into the message the app itself shows.
async function expectNoError(insp, what) {
  const problem = await evalq(insp, "store.storeProblem");
  if (problem) throw new Error(`${what}: the store could not be read: "${problem}"`);
  if ((await evalq(insp, "store.backend.noticeKind")) === "error")
    throw new Error(`${what}: the app reported "${await evalq(insp, "store.backend.noticeBody")}"`);
}

// A sheet stays up until its call lands, and a refusal keeps it up with the
// library's own words in it, so either ends the wait.
async function confirm(insp, sheet) {
  await click(insp, `${sheet}Confirm`);
  let refused = "";
  await waitFor(async () => {
    refused = await evalq(insp, `${sheet}.problem`);
    return refused !== "" || (await evalq(insp, `${sheet}.visible`)) === false;
  }, { timeout: 60000, what: `${sheet} to land` });
  if (refused) throw new Error(`${sheet} was refused: ${refused}`);
}

// The roster hangs from the selector in the account bar, which is the one
// control on this screen that is not a button.
async function openSwitcher(insp) {
  await click(insp, "switcherBar");
  await waitUntil(insp, "accountBar.switcherOpen", true);
}

const PASSWORD = "a long quiet sentence";
const DISPLAY_NAME = "Saro";
// The second account, whose key this run gives up so that the first can watch
// it from the outside.
const OTHER_NAME = "Raya";
// A real Ed25519 public key: the log checks that an endorsed key is a point on
// the curve, so an invented one is refused on the way in.
const INSTALLATION_KEY = "50493a4f65e5bbb98b68c4f9608dfa860a975c31c3b6db40b61958af345a6fce";

async function main() {
  const outDir = process.env.OUT_DIR || "./images";
  fs.mkdirSync(outDir, { recursive: true });
  const app = new Inspector("127.0.0.1", parseInt(process.env.APP_PORT || "3768", 10));
  await app.connect();
  console.log("connected to the inspector");

  // Cold start: the host spawns ui-host, which loads the plugin and answers the
  // readiness handshake. Until it does, the view shows "Starting".
  console.log("waiting for the module to come ready...");
  await waitUntil(app, "store.ready", true, { timeout: 120000 });

  // There is nothing to manage until the vault holds a key, so an empty vault
  // opens the door itself.
  await waitUntil(app, "view.activeScreen", "add", { timeout: 20000 });
  console.log("empty vault: the add screen is up");
  await shoot(app, outDir, "01-add-an-account.png");

  console.log("make a key on this computer...");
  await click(app, "createAccountDoorAction");
  await waitUntil(app, "view.activeScreen", "create");
  await type(app, "createPasswordField", PASSWORD);
  await type(app, "createPasswordConfirmField", PASSWORD);
  // The screen is valid once the two halves match, so this is what says the
  // second write landed rather than that the field exists.
  await waitUntil(app, "createScreen.valid", true);
  await shoot(app, outDir, "02-create-an-account.png");

  await click(app, "createAccountSubmit");
  let refused = "";
  await waitFor(async () => {
    refused = await evalq(app, "createScreen.problem");
    return refused !== "" || (await evalq(app, "store.hasAccount")) === true;
  }, { timeout: 60000, what: "the account to be created" });
  if (refused) throw new Error(`creating the account was refused: ${refused}`);
  await waitUntil(app, "view.activeScreen", "manage");
  // The account's state lands before the store answers for it, and until then
  // "nothing published" is not the store's answer.
  await waitUntil(app, "store.resolved", true);
  await expectNoError(app, "create the account");
  const address = await evalq(app, "store.address");
  console.log(`account created: ${address}`);
  // The key exists here and the address is derived from it, but the store has
  // never heard of it: the address is claimed by the first publish.
  await waitUntil(app, "store.published", false);
  await waitUntil(app, "store.entries.length", 0);
  await shoot(app, outDir, "03-nothing-published-yet.png");

  console.log("name the account...");
  await click(app, "displayNameButton");
  await waitUntil(app, "displayNameSheet.visible", true);
  await type(app, "displayNameField", DISPLAY_NAME);
  await confirm(app, "displayNameSheet");
  await waitUntil(app, "store.pending.length", 1);
  // 28 bytes, and the app measured it: an empty display-name entry costs 24 by
  // the format's own encoder, and "Saro" adds its four UTF-8 bytes.
  const nameBytes = await evalq(app, "store.pendingBytes");
  if (nameBytes !== 28) throw new Error(`"${DISPLAY_NAME}" priced at ${nameBytes} bytes, expected 28`);
  console.log(`  staged, priced at ${nameBytes} bytes`);
  await shoot(app, outDir, "04-one-pending-entry.png");

  console.log("publish the name...");
  await publish(app);
  await waitUntil(app, "store.entries.length", 1, { timeout: 60000 });
  await waitUntil(app, "store.published", true);
  await expectNoError(app, "publish the name");
  const name = await evalq(app, "store.publishedName");
  if (name !== DISPLAY_NAME) throw new Error(`the store serves the name as ${JSON.stringify(name)}`);
  console.log(`  the store serves entry #0: ${name}`);
  await shoot(app, outDir, "05-first-entry-published.png");

  console.log("endorse an installation...");
  await click(app, "addInstallationButton");
  await waitUntil(app, "addInstallationSheet.visible", true);
  await type(app, "installationKeyField", INSTALLATION_KEY);
  await confirm(app, "addInstallationSheet");
  await waitUntil(app, "store.pending.length", 1);
  // An endorsement costs 48 bytes, whatever the key.
  const keyBytes = await evalq(app, "store.pendingBytes");
  if (keyBytes !== 48) throw new Error(`an endorsement priced at ${keyBytes} bytes, expected 48`);
  console.log(`  staged, priced at ${keyBytes} bytes`);

  await publish(app);
  await waitUntil(app, "store.entries.length", 2, { timeout: 60000 });
  await expectNoError(app, "publish the endorsement");
  // The live set is replayed from the log rather than held beside it, so this
  // is the log itself saying the endorsement took.
  await waitUntil(app, "store.installations.length", 1);
  console.log("  the log now endorses one installation");
  await shoot(app, outDir, "06-installation-endorsed.png");

  // An account this module reads and cannot write needs a log published by a
  // key held somewhere else. A hermetic run has no somewhere else, so it makes
  // one here and then gives the key up: what stays behind is a log in the
  // store that this module can never extend, which is what observing is.
  console.log("publish a second account...");
  await openSwitcher(app);
  await click(app, "addAccountButton");
  await waitUntil(app, "view.activeScreen", "add");
  await click(app, "createAccountDoorAction");
  await waitUntil(app, "view.activeScreen", "create");
  await type(app, "createPasswordField", PASSWORD);
  await type(app, "createPasswordConfirmField", PASSWORD);
  await waitUntil(app, "createScreen.valid", true);
  await click(app, "createAccountSubmit");
  await waitFor(async () => {
    const at = await evalq(app, "store.address");
    return at !== "" && at !== address;
  }, { timeout: 60000, what: "the second account to be created" });
  const observed = await evalq(app, "store.address");
  await waitUntil(app, "store.resolved", true);
  await expectNoError(app, "create the second account");
  console.log(`  second account: ${observed}`);

  await click(app, "displayNameButton");
  await waitUntil(app, "displayNameSheet.visible", true);
  await type(app, "displayNameField", OTHER_NAME);
  await confirm(app, "displayNameSheet");
  await waitUntil(app, "store.pending.length", 1);
  await publish(app);
  await waitUntil(app, "store.entries.length", 1, { timeout: 60000 });
  await expectNoError(app, "publish the second account");

  console.log("give up its key, keeping the log the store holds...");
  await click(app, "forgetAccountButton");
  await waitUntil(app, "forgetAccountSheet.visible", true);
  await confirm(app, "forgetAccountSheet");
  await waitUntil(app, "store.address", address, { timeout: 60000 });
  await waitUntil(app, "store.accounts.length", 1);

  console.log("observe it from the outside...");
  await openSwitcher(app);
  await click(app, "observeAccountButton");
  await waitUntil(app, "observeAccountSheet.visible", true);
  await type(app, "observeAddressField", observed);
  await confirm(app, "observeAccountSheet");
  await waitUntil(app, "store.address", observed, { timeout: 60000 });
  await waitUntil(app, "store.observing", true);
  // The address was taken on without reading anything, and the read that
  // follows is what puts a log on the screen.
  await waitUntil(app, "store.resolved", true, { timeout: 60000 });
  await expectNoError(app, "observe the account");
  const served = await evalq(app, "store.publishedName");
  if (served !== OTHER_NAME) throw new Error(`the store serves the observed name as ${JSON.stringify(served)}`);
  await waitUntil(app, "store.entries.length", 1);
  if (await evalq(app, "store.managed")) throw new Error("an account with no key here is shown as managed");
  console.log(`  reading ${OTHER_NAME}'s log with no key for it`);
  await shoot(app, outDir, "07-an-observed-account.png");

  // Stopping drops the account and what was read with it, and leaves the
  // account this module does hold on screen.
  console.log("stop observing...");
  await click(app, "stopObservingButton");
  await waitUntil(app, "store.address", address, { timeout: 60000 });
  await waitUntil(app, "store.accounts.length", 1);
  await waitUntil(app, "store.entries.length", 2);

  const logBytes = await evalq(app, "store.logBytes");
  console.log(`\nWALKTHROUGH COMPLETE: 2 entries, ${logBytes} bytes of signed payload; screenshots in ${outDir}`);
  app.disconnect();
}

// Sign and send the staged entries as one update. The key is sealed, and was
// unlocked by making the account, so the sheet asks for nothing.
async function publish(insp) {
  await click(insp, "publishButton");
  await waitUntil(insp, "publishSheet.visible", true);
  await confirm(insp, "publishSheet");
  await waitUntil(insp, "store.pending.length", 0);
}

main().then(() => process.exit(0)).catch((e) => { console.error("\nFAILED:", e.message); process.exit(1); });
