import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Endorse an installation's public key. The key is pasted from the screen of
// the installation that holds it: nothing here asks that installation anything.
Sheet {
    property var store: null

    id: root
    objectName: "addInstallationSheet"
    title: qsTr("Add installation")
    confirmText: qsTr("Add installation")
    confirmEnabled: root.valid && !root.live && root.stagedAs < 0 && root.problem === ""
    backend: root.store.backend

    readonly property string key: Fmt.hex(field.text)
    readonly property bool valid: /^[0-9a-f]{64}$/.test(root.key)
    readonly property bool live: {
        for (var i = 0; i < store.installations.length; ++i)
            if (store.installations[i].key === root.key)
                return true
        return false
    }
    // The pending entry that already endorses this key, or -1.
    readonly property int stagedAs: {
        for (var i = 0; i < store.pending.length; ++i)
            if (store.pending[i].kind === "installation" && store.pending[i].value === root.key)
                return store.pending[i].index
        return -1
    }

    function reset() {
        field.text = ""
        field.field.forceActiveFocus()
    }

    onConfirmed: {
        root.send("stageAddInstallation")
        store.backend.stageAddInstallation(root.key)
    }
    onLanded: root.close()
    onCancelled: root.close()

    LogosText {
        Layout.fillWidth: true
        text: qsTr("Paste the public key the installation shows. The account endorses it by appending an entry to its log.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    Field {
        id: field
        objectName: "installationKeyField"
        Layout.fillWidth: true
        label: qsTr("Public key")
        placeholderText: qsTr("64 hex characters")
        mono: true
        problem: {
            if (!root.valid)
                return Fmt.hexProblem(field.text, qsTr("An installation key"))
            if (root.live)
                return qsTr("Already in this account: the key is live as entry %1.")
                            .arg(Fmt.index(root.entryOf(root.key)))
            if (root.stagedAs >= 0)
                return qsTr("Already staged as entry %1.").arg(Fmt.index(root.stagedAs))
            return ""
        }
        onAccepted: root.submit()
        onTextChanged: root.problem = ""
        // Not a price for a key the core has just refused.
        help: root.problem !== "" ? ""
            : qsTr("Endorsed under chat.signer. Appends one %1-byte entry, leaving %2 bytes in the log's lifetime budget.")
                  .arg(root.store.costs.installation)
                  .arg(Fmt.count(root.store.maxBytes - root.store.logBytes
                                 - root.store.pendingBytes - root.store.costs.installation))
    }

    function entryOf(key) {
        for (var i = 0; i < store.installations.length; ++i)
            if (store.installations[i].key === key)
                return store.installations[i].index
        return -1
    }
}
