import QtQuick
import QtQuick.Layouts

import Logos.Theme

// Drop the account and its key. The log it published stays in the store and
// stays readable; what goes is the only thing that can extend it.
Sheet {
    property var store: null

    id: root
    objectName: "forgetAccountSheet"
    title: root.store.displayName !== ""
           ? qsTr("Forget %1?").arg(root.store.displayName)
           : qsTr("Forget this account?")
    confirmText: qsTr("Forget account")
    destructive: true
    backend: root.store.backend

    onConfirmed: {
        root.send("forgetAccount")
        store.backend.forgetAccount(root.store.address)
    }
    onLanded: root.close()
    onCancelled: root.close()

    NoticeBar {
        Layout.fillWidth: true
        dismissable: false
        tone: "error"
        title: qsTr("An account key cannot be recovered")
        body: qsTr("The key is kept only in this vault. Without it no entry can be signed for this address again, by anyone, ever.")
    }

    ValueBox {
        Layout.fillWidth: true
        text: root.store.address
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.pending.length > 0
        body: qsTr("%1 not yet published will be lost with it.")
                  .arg(Fmt.plural(root.store.pending.length, qsTr("pending entry"),
                                  qsTr("pending entries")))
        color: Theme.palette.error
    }

    HelpText {
        Layout.fillWidth: true
        body: root.store.resolved && !root.store.published
              ? qsTr("This account has published nothing, so nothing of it remains anywhere once the key is gone. Export the key first if the account is to live somewhere else.")
              : qsTr("Whatever this account published stays in the store and stays readable. Export the key first if the account is to live somewhere else.")
    }
}
