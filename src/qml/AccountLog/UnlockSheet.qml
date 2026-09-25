import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The password prompt that opens a sealed key for the session: once this
// lands, publishing asks for nothing until the app closes.
Sheet {
    property var store: null

    id: root
    objectName: "unlockSheet"
    title: root.store.publishedName !== ""
           ? qsTr("Unlock %1").arg(root.store.publishedName)
           : qsTr("Unlock this account")
    confirmText: qsTr("Unlock")
    confirmEnabled: password.text.length > 0
    backend: root.store.backend
    input: password.field

    function reset() {
        password.text = ""
    }

    // The password is cleared once it is sent: a refusal asks for it again.
    onConfirmed: {
        root.send("unlock")
        store.backend.unlock(root.store.address, password.text)
        password.text = ""
    }
    onLanded: root.close()
    onCancelled: {
        password.text = ""
        root.close()
    }

    LogosText {
        Layout.fillWidth: true
        text: qsTr("This account's key is sealed with a password. Opening it here opens it for as long as the app runs: publishing signs with it and asks for nothing.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    Field {
        id: password
        objectName: "unlockPasswordField"
        Layout.fillWidth: true
        label: qsTr("Account password")
        echoMode: TextInput.Password
        help: qsTr("The log can be read without it. Only signing needs the key.")
        onAccepted: root.submit()
        onTextChanged: root.problem = ""
    }
}
