pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The live set, replayed from the log: the keys this account currently
// endorses, plus the ones this update will add or retire.
Panel {
    property var store: null
    // The entry the log table is scrolled to, shared so a key and its entry
    // are selected together.
    property int selectedIndex: -1

    signal addRequested()
    signal selected(int index)

    id: root
    spacing: Theme.spacing.medium

    readonly property var arriving: {
        var out = []
        for (var i = 0; i < store.pending.length; ++i)
            if (store.pending[i].kind === "installation")
                out.push(store.pending[i])
        return out
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.small

        LogosText {
            text: qsTr("Installations")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
        }
        Badge { text: qsTr("%1 live").arg(root.store.installations.length) }
        Badge {
            visible: root.arriving.length > 0
            tone: "pending"
            text: qsTr("+%1 pending").arg(root.arriving.length)
        }
        Item { Layout.fillWidth: true }
        LogosButton {
            objectName: "addInstallationButton"
            text: qsTr("Add installation")
            variant: LogosButton.Variant.Primary
            enabled: !root.store.busy && root.store.unreadable === ""
            onClicked: root.addRequested()
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.tiny

        HelpText { body: qsTr("Keys live under") }
        ContextChip { text: "chat.signer" }
        HelpText {
            Layout.fillWidth: true
            body: qsTr("and each is one entry in the log.")
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        visible: root.store.installations.length > 0 || root.arriving.length > 0
        spacing: Theme.spacing.tiny

        Repeater {
            model: root.arriving

            delegate: InstallationRow {
                required property var modelData

                Layout.fillWidth: true
                entryIndex: modelData.index
                keyHex: modelData.value
                pending: true
            }
        }

        Repeater {
            model: root.store.installations

            delegate: InstallationRow {
                required property var modelData

                Layout.fillWidth: true
                entryIndex: modelData.index
                keyHex: modelData.key
                leaving: root.store.willBeRevoked(modelData.index)
                current: root.selectedIndex === modelData.index
                onClicked: root.selected(modelData.index)
                onRemoveRequested: root.store.backend.stageRevoke(modelData.index)
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.small
        visible: root.store.installations.length === 0 && root.arriving.length === 0
        spacing: Theme.spacing.tiny

        LogosText {
            Layout.fillWidth: true
            text: qsTr("No installations yet.")
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            color: Theme.palette.textTertiary
        }
        HelpText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            body: qsTr("Add the public key of a chat installation to endorse it.")
        }
    }
}
