import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What can be done to the account the switcher names: rename it, copy its
// address, hand it over. The name itself belongs to the switcher, so it is not
// repeated here.
Panel {
    property var store: null

    signal renameRequested()
    signal exportRequested()
    signal forgetRequested()

    id: root
    spacing: Theme.spacing.medium

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.small

        Eyebrow { label: qsTr("Account") }
        Item { Layout.fillWidth: true }
        Badge {
            visible: !root.store.isProtected
            text: qsTr("No password")
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.tiny

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            Eyebrow { label: qsTr("Display name") }
            Item { Layout.fillWidth: true }
            LogosButton {
                objectName: "displayNameButton"
                text: root.store.displayName !== "" ? qsTr("Change name") : qsTr("Set a name")
                enabled: !root.store.busy
                onClicked: root.renameRequested()
            }
        }

        HelpText {
            Layout.fillWidth: true
            visible: !root.store.renaming
            body: qsTr("A display name is public and not verified: only the address identifies the account. Every name the account has used stays readable in its log.")
        }

        HelpText {
            Layout.fillWidth: true
            visible: root.store.renaming
            body: root.store.replacedNameIndex() >= 0
                  ? qsTr("Replaces \"%1\", entry %2, when published.")
                        .arg(root.store.entryValue(root.store.replacedNameIndex()))
                        .arg(Fmt.index(root.store.replacedNameIndex()))
                  : root.store.resolved
                  ? qsTr("The account's first name, when published.")
                  : qsTr("Takes effect when published.")
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        Layout.bottomMargin: Theme.spacing.tiny
        implicitHeight: 1
        color: Theme.palette.borderSubtle
    }

    Eyebrow { label: qsTr("Address") }

    ValueBox {
        Layout.fillWidth: true
        text: root.store.address
    }

    HelpText {
        Layout.fillWidth: true
        body: qsTr("This module holds this account's key, so it can write this log. The address is that key's public half.")
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        spacing: Theme.spacing.small

        LogosButton {
            text: qsTr("Export key")
            enabled: !root.store.busy
            onClicked: root.exportRequested()
        }
        LogosButton {
            text: qsTr("Forget account")
            enabled: !root.store.busy
            onClicked: root.forgetRequested()
        }
        Item { Layout.fillWidth: true }
    }

    HelpText {
        Layout.fillWidth: true
        body: qsTr("Handing an account over is an export here and an import there, then forgetting it here. Two modules holding one key can split its log.")
    }
}
