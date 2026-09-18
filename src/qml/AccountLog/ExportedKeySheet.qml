import QtQuick
import QtQuick.Layouts

// The exported key itself, shown once. Nothing here can be undone: the value
// on screen is the account.
Sheet {
    property string address: ""
    property string key: ""

    id: root
    objectName: "exportedKeySheet"
    title: qsTr("This account's key")
    confirmText: qsTr("Done")
    cancellable: false

    // Nothing keeps the key once the sheet is down.
    onConfirmed: root.forget()
    onCancelled: root.forget()

    function forget() {
        root.key = ""
        root.address = ""
        root.close()
    }

    NoticeBar {
        Layout.fillWidth: true
        dismissable: false
        tone: "warning"
        title: qsTr("This key is the account")
        body: qsTr("Anything holding it can write this log. Move it the way a key is moved, and forget the account here once it lives somewhere else.")
    }

    Eyebrow { label: qsTr("Address") }

    ValueBox {
        Layout.fillWidth: true
        text: root.address
    }

    Eyebrow { label: qsTr("Secret key") }

    ValueBox {
        Layout.fillWidth: true
        text: root.key
    }
}
