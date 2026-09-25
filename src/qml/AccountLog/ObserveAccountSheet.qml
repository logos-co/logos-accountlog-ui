import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Take on an account whose key is elsewhere: an address, and nothing else. The
// log served under it is fetched and verified against it, which is the whole
// of what this module can do with an account it does not hold.
Sheet {
    property var store: null

    // An address this module already holds the key for: the sheet has nothing
    // to take on, and the account is opened instead.
    signal openRequested(string address)

    id: root
    objectName: "observeAccountSheet"
    title: qsTr("Observe an account")
    confirmText: root.held ? qsTr("Open it") : qsTr("Observe")
    confirmEnabled: root.valid && root.problem === ""
    backend: root.store.backend
    input: field.field

    readonly property string addr: Fmt.hex(field.text)
    readonly property bool valid: /^[0-9a-f]{64}$/.test(root.addr)
    // An account this module holds the key for is managed rather than
    // observed, and the core refuses it as such. It is said here, where it can
    // still be acted on, rather than as a failure once the call comes back.
    readonly property bool held: {
        for (var i = 0; i < store.managedAccounts.length; ++i)
            if (store.managedAccounts[i].address === root.addr)
                return true
        return false
    }

    function reset() {
        field.text = ""
    }

    onConfirmed: {
        if (root.held) {
            root.openRequested(root.addr)
            root.close()
            return
        }
        root.send("observeAccount")
        root.store.backend.observeAccount(root.addr)
    }
    onLanded: root.close()
    onCancelled: root.close()

    LogosText {
        Layout.fillWidth: true
        text: qsTr("Fetches the log the store serves under this address and verifies it against the address. No key is needed to read an account, and none is sent.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    Field {
        id: field
        objectName: "observeAddressField"
        Layout.fillWidth: true
        label: qsTr("Account address")
        placeholderText: qsTr("64 hex characters")
        mono: true
        problem: root.valid ? "" : Fmt.hexProblem(field.text, qsTr("An account address"))
        help: root.problem !== "" || root.held
              ? ""
              : qsTr("Shared out of band: a holder copies it from its own screen. Nothing here verifies that anyone runs this account.")
        onAccepted: root.submit()
        onTextChanged: root.problem = ""
    }

    NoticeBar {
        Layout.fillWidth: true
        visible: root.held
        dismissable: false
        tone: "info"
        title: qsTr("This account is already here, and this module holds its key")
        body: qsTr("It is under Managed, where it can also be written. To see what the store actually serves for it, open it and read it again: this screen always shows the log as the store answered it.")
    }
}
