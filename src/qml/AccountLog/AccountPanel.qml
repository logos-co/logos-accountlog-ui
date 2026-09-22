import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What can be done to the account the switcher names: rename it, copy its
// address, hand it over. The name itself belongs to the switcher, so it is not
// repeated here.
//
// An account this module only observes gets the same panel with everything
// that needs a key taken out of it: values where the controls were, and the
// one thing that can be done to it, which is to stop.
Panel {
    property var store: null

    signal renameRequested()
    signal exportRequested()
    signal forgetRequested()

    id: root
    spacing: Theme.spacing.medium

    // Why the account has no name on screen, which for an observed account is
    // usually a fact about the read rather than about the account.
    readonly property string noName: {
        if (root.store.reading === "unread")
            return qsTr("Not read yet")
        if (root.store.reading === "unverified")
            return qsTr("Not shown: the log did not verify")
        if (root.store.reading === "forked")
            return qsTr("Not shown: the store serves a second history")
        if (root.store.reading === "unanswered")
            return qsTr("Not read: the store did not answer")
        if (!root.store.published)
            return qsTr("Nothing published under this address")
        return qsTr("Not set")
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.small

        Eyebrow { label: qsTr("Account") }
        Item { Layout.fillWidth: true }
        Badge {
            visible: root.store.managed && !root.store.isProtected
            text: qsTr("No password")
        }
        LogosButton {
            objectName: "stopObservingButton"
            visible: root.store.observing
            text: qsTr("Stop observing")
            enabled: !root.store.busy
            onClicked: root.store.backend.stopObserving(root.store.address)
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
                visible: root.store.managed
                text: root.store.displayName !== "" ? qsTr("Change name") : qsTr("Set a name")
                enabled: !root.store.busy
                onClicked: root.renameRequested()
            }
        }

        // The name itself, for an account that cannot be renamed here: the
        // switcher shows it, and this says where it came from.
        LogosText {
            Layout.fillWidth: true
            visible: root.store.observing
            text: root.store.displayName !== "" ? root.store.displayName : root.noName
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: Theme.typography.subtitleText
            color: root.store.displayName !== "" ? Theme.palette.text
                                                 : Theme.palette.textTertiary
        }

        HelpText {
            Layout.fillWidth: true
            visible: root.store.observing
            body: root.store.resolved
                  ? qsTr("Whatever the account last published. It is not verified and not unique: only the address identifies the account.")
                  : qsTr("A name comes out of the log, and there is no log here to read one from.")
        }

        HelpText {
            Layout.fillWidth: true
            visible: root.store.managed && !root.store.renaming
            body: qsTr("A display name is public and not verified: only the address identifies the account. Every name the account has used stays readable in its log.")
        }

        HelpText {
            Layout.fillWidth: true
            visible: root.store.managed && root.store.renaming
            body: root.store.publishedName !== ""
                  ? qsTr("Appended as a new entry when published. %1 stays in the log and becomes a previous alias.")
                        .arg(Fmt.index(root.store.nameIndex))
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
        body: root.store.managed
              ? qsTr("This module holds this account's key, so it can write this log. The address is that key's public half.")
              : qsTr("This module holds no key for this address, so it can read this log and never write it. Its entries are signed by whoever does.")
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        visible: root.store.managed
        spacing: Theme.spacing.small

        LogosButton {
            objectName: "exportKeyButton"
            text: qsTr("Export key")
            enabled: !root.store.busy
            onClicked: root.exportRequested()
        }
        LogosButton {
            objectName: "forgetAccountButton"
            text: qsTr("Forget account")
            enabled: !root.store.busy
            onClicked: root.forgetRequested()
        }
        Item { Layout.fillWidth: true }
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.managed
        body: qsTr("Handing an account over is an export here and an import there, then forgetting it here. Two modules holding one key can split its log.")
    }
}
