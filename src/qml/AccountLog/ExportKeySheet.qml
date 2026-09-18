import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Hand the account's own secret back, so it can be taken somewhere else. The
// key opens the account wherever it lands, which is the whole warning.
Sheet {
    property var store: null

    id: root
    objectName: "exportKeySheet"
    title: qsTr("Export this account's key")
    confirmText: qsTr("Show the key")
    confirmEnabled: !root.store.isProtected || password.text.length > 0
    backend: root.store.backend

    function reset() {
        password.text = ""
        if (root.store.isProtected)
            password.field.forceActiveFocus()
    }

    onConfirmed: {
        root.send("exportAccount")
        store.backend.exportAccount(root.store.address,
                                    root.store.isProtected ? password.text : "")
        password.text = ""
    }
    onLanded: root.close()
    onCancelled: {
        password.text = ""
        root.close()
    }

    LogosText {
        Layout.fillWidth: true
        text: qsTr("Hands back the 32-byte secret this account signs with. Whoever holds it is this account, and two modules holding one key can split its log.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    Field {
        id: password
        Layout.fillWidth: true
        visible: root.store.isProtected
        label: qsTr("Account password")
        echoMode: TextInput.Password
        help: qsTr("The password that seals this key. It opens it for this export only.")
        onAccepted: root.submit()
        onTextChanged: root.problem = ""
    }
}
