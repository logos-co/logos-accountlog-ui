import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The two ways a writer gets an account, side by side: make a key, or take
// custody of one made elsewhere.
Item {
    property bool canCancel: false

    signal createRequested()
    signal importRequested()
    signal cancelled()

    id: root

    Panel {
        anchors.centerIn: parent
        width: Math.min(720, parent.width - 48)
        padding: Theme.spacing.xxlarge
        horizontalPadding: Theme.spacing.xxlarge
        spacing: Theme.spacing.medium

        LogosText {
            Layout.fillWidth: true
            text: qsTr("Add an account")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.titleText
            font.weight: Theme.typography.weightBold
        }

        LogosText {
            Layout.fillWidth: true
            text: qsTr("This app writes accounts, so every account it holds needs its key. It can make a new one, or take one that was made somewhere else.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: Theme.typography.subtitleText
            color: Theme.palette.textSecondary
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.medium
            spacing: Theme.spacing.large

            // The two bodies differ in length, so the titles share a baseline
            // and the buttons another only while the cards share a height.
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
