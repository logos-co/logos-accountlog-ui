pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The live set under chat.signer, replayed from the log: the keys this account
// currently endorses, plus the ones this update will add or retire.
ColumnLayout {
    property var store: null
    // The entry the log table is scrolled to, shared so a key and its entry
    // are selected together.
    property int selectedIndex: -1

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

    Subsection {
        Layout.fillWidth: true
        label: qsTr("Installations")
        context: "chat.signer"

        // No log read means no live set, which is not the same claim as a
        // live set with nothing in it.
        Badge {
            visible: root.store.resolved
            text: qsTr("%1 live").arg(root.store.installations.length)
        }
        Badge {
            visible: root.arriving.length > 0
            tone: "pending"
            text: qsTr("+%1 pending").arg(root.arriving.length)
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
                removable: root.store.managed
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
            // An account whose log has not been read has no installations to
            // show, which is a different thing from one that endorses none.
            text: root.store.resolved ? qsTr("No installations yet.")
                : root.store.reading === "unread" ? qsTr("Nothing read yet.")
                : qsTr("Nothing to show.")
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            color: Theme.palette.textTertiary
        }
        HelpText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            body: root.store.resolved && root.store.managed
                  ? qsTr("Add the public key of a chat installation to endorse it.")
                  : root.store.resolved
                  ? qsTr("This account endorses no installation key.")
                  : root.store.reading === "unread"
                  ? qsTr("Installations appear once this account's log has been read.")
                  : qsTr("Installations are read from the log, and there is no log here.")
        }
    }
}
