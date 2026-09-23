import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The chat namespace: the keys this account endorses for logos-chat. An account
// is not a chat account, so the section says whose they are, and each context
// chat defines is a subsection of it.
Panel {
    property var store: null
    // The entry the log table is scrolled to, shared so a key and its entry
    // are selected together.
    property int selectedIndex: -1

    signal addRequested()
    signal selected(int index)

    id: root
    padding: 14
    horizontalPadding: 18
    spacing: Theme.spacing.small

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        LogosText {
            text: qsTr("Chat")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
        }
        ContextChip { text: "chat" }
        Item { Layout.fillWidth: true }
        CompactButton {
            objectName: "addInstallationButton"
            visible: root.store.managed
            text: qsTr("Add installation")
            variant: LogosButton.Variant.Primary
            enabled: !root.store.busy && root.store.unreadable === ""
            onClicked: root.addRequested()
        }
    }

    HelpText {
        Layout.fillWidth: true
        body: qsTr("What this account endorses for logos-chat, newest entry first. An account is not a chat account: other applications claim namespaces of their own in the same log, and this section is chat's.")
    }

    InstallationList {
        Layout.fillWidth: true
        Layout.topMargin: 2
        store: root.store
        selectedIndex: root.selectedIndex
        onSelected: (index) => root.selected(index)
    }
}
