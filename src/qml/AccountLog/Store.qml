import QtQuick

// The whole of this view's contact with the host, so every other component is
// a plain QML type that can be instantiated on its own.
//
// Readiness is a signal, not a property: `logos.isViewModuleReady()` is a
// function call, and a binding containing one is evaluated once at creation,
// when the ui-host has not finished handing over. It would latch false forever
// and the view would sit on "Connecting…" with a backend that works.
QtObject {
    id: store

    // Every host call names the module it is about, so the name is spelled
    // once here rather than at each call site.
    readonly property string moduleName: "accountlog_ui"

    readonly property var backend:
        (typeof logos !== "undefined" && logos) ? logos.module(store.moduleName) : null

    property bool ready: false

    // Once ready, stays set: `ready` dropping after that is a backend that
    // stopped, not one still starting.
    property bool wasReady: false
    onReadyChanged: if (ready) wasReady = true

    // The selected account, already parsed. Every screen reads this rather than
    // the JSON, so the parse happens once per change.
    readonly property var state: {
        if (!ready || !backend)
            return ({})
        try {
            var parsed = JSON.parse(backend.stateJson)
            // Until the new account's state lands, the one held is another
            // account's, and nothing on screen may act on it.
            return parsed.address === backend.selectedAddress ? parsed : ({})
        } catch (e) {
            return ({})
        }
    }

    readonly property var accounts: {
        if (!ready || !backend)
            return []
        try {
            return JSON.parse(backend.accountsJson)
        } catch (e) {
            return []
        }
    }

    readonly property string address: ready && backend ? backend.selectedAddress : ""
    // The selected account's state has landed.
    readonly property bool hasAccount: (state.address || "") !== ""
    // An account is selected and its state is still on its way.
    readonly property bool loading: address !== "" && !hasAccount
    // The selected account's line in the vault listing, which lands before its
    // state does.
    readonly property var held: {
        for (var i = 0; i < accounts.length; ++i)
            if (accounts[i].address === address)
                return accounts[i]
        return null
    }
    readonly property bool isProtected: held !== null && held.protected === true
    readonly property bool busy: (ready && backend ? backend.busy : false) || loading
    readonly property var entries: state.entries || []
    readonly property var installations: state.installations || []
    readonly property var pending: state.pending || []
    readonly property int logBytes: state.logBytes || 0
    readonly property int maxBytes: state.maxBytes || Fmt.maxBytes
    readonly property int domainBytes: state.domainBytes || 0
    readonly property bool published: state.published === true
    // The store has answered for this account, so `published` is its answer
    // rather than a default.
    readonly property bool resolved: state.resolved === true
    readonly property string storeProblem: ready && backend ? backend.storeProblem : ""
    readonly property string vaultProblem: ready && backend ? backend.vaultProblem : ""
    readonly property string unreadable: state.unreadable || ""

    // What a further entry of each kind would cost the budget, for the dialogs
    // that name the price before the edit exists.
    readonly property var costs: state.costs || ({ installation: 0, remove: 0, displayName: 0 })

    // What the pending entries add to the log, which is what the update sends.
    readonly property int pendingBytes: {
        var total = 0
        for (var i = 0; i < pending.length; ++i)
            total += pending[i].bytes
        return total
    }

    // The name that will be in force after the next publish: a staged rename
    // is what the switcher shows, because that is what the person just asked
    // for and what Publish will write.
    readonly property string publishedName: state.displayName || ""
    readonly property string stagedName: {
        for (var i = 0; i < pending.length; ++i)
            if (pending[i].kind === "displayName")
                return pending[i].value
        return ""
    }
    readonly property string displayName: stagedName !== "" ? stagedName : publishedName
    readonly property bool renaming: stagedName !== ""

    // Indices a staged revocation points at, so the installation list and the
    // log table can mark the same entries without each deriving it.
    readonly property var revoking: {
        var out = []
        for (var i = 0; i < pending.length; ++i)
            if (pending[i].target !== null && pending[i].target !== undefined)
                out.push(pending[i].target)
        return out
    }

    function willBeRevoked(index) {
        return revoking.indexOf(index) !== -1
    }

    // The pending entry that will retire this one, or -1: the same pairing the
    // published log shows, one update early.
    function willBeRevokedBy(index) {
        for (var i = 0; i < pending.length; ++i)
            if (pending[i].target === index)
                return pending[i].index
        return -1
    }

    // Which entry the rename staged for this account replaces, for the panel
    // that says so in words.
    function replacedNameIndex() {
        for (var i = 0; i < pending.length; ++i)
            if (pending[i].kind === "revocation" && entryKind(pending[i].target) === "displayName")
                return pending[i].target
        return -1
    }

    // The revocation that already retired this entry, or -1. The log carries
    // the pair as an entry and its target, so the reverse lookup is here.
    function removedBy(index) {
        for (var i = 0; i < entries.length; ++i)
            if (entries[i].kind === "revocation" && entries[i].target === index)
                return entries[i].index
        return -1
    }

    function entryKind(index) {
        for (var i = 0; i < entries.length; ++i)
            if (entries[i].index === index)
                return entries[i].kind
        return ""
    }

    function entryValue(index) {
        for (var i = 0; i < entries.length; ++i)
            if (entries[i].index === index)
                return entries[i].value
        return ""
    }
}
