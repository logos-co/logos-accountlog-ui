import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The three ways an account gets onto this screen, side by side: make a key,
// take custody of one made elsewhere, or take an address and only read it.
Item {
    property bool canCancel: false

    signal createRequested()
    signal importRequested()
    signal observeRequested()
    signal cancelled()

    id: root

    Panel {
        anchors.centerIn: parent
        width: Math.min(1040, parent.width - 48)
        padding: Theme.spacing.xxlarge
        horizontalPadding: Theme.spacing.xxlarge
        spacing: Theme.spacing.medium

        LogosText {
            Layout.fillWidth: true
            text: root.canCancel ? qsTr("Add an account") : qsTr("Add your first account")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.titleText
            font.weight: Theme.typography.weightBold
        }

        LogosText {
            Layout.fillWidth: true
            text: qsTr("An account whose key this module holds is managed: it can be written, and every change is signed here. An account this module has only the address of is observed: its log is read from the store and verified, and that is all. Both appear in the same switcher.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: Theme.typography.subtitleText
            color: Theme.palette.textSecondary
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.medium
            spacing: Theme.spacing.large

            // The three bodies differ in length, so the titles share a
            // baseline and the buttons another only while the cards share a
            // height.
            Door {
                objectName: "createAccountDoor"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                primary: true
                title: qsTr("Create an account")
                body: qsTr("Makes a signing key on this computer. Its public half becomes the address, and every change to the account is signed with it.")
                action: qsTr("Create an account")
                onTriggered: root.createRequested()
            }

            Door {
                objectName: "importAccountDoor"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                title: qsTr("Import an account")
                body: qsTr("Paste the 32-byte secret key of an account made elsewhere. Two modules holding one key can split its log, so hand an account over rather than sharing it.")
                action: qsTr("Import an account")
                onTriggered: root.importRequested()
            }

            Door {
                objectName: "observeAccountDoor"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                title: qsTr("Observe an account")
                body: qsTr("Paste an address. The log served under it is fetched, verified against that address, and shown read only. Takes no key, and sends none.")
                action: qsTr("Observe an account")
                onTriggered: root.observeRequested()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.canCancel

            Item { Layout.fillWidth: true }
            LogosButton {
                text: qsTr("Back")
                onClicked: root.cancelled()
            }
        }
    }
}
