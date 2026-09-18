import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What the next publish will send, and the two things that can be done with
// it. One update, so one button.
RowLayout {
    property var store: null

    signal publishRequested()

    id: root
    spacing: Theme.spacing.medium

    readonly property int count: store.pending.length

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2

        LogosText {
            text: root.count === 0
                  ? qsTr("No pending entries")
                  : qsTr("%1 · +%2 B")
                        .arg(Fmt.plural(root.count, qsTr("pending entry"), qsTr("pending entries")))
                        .arg(root.store.pendingBytes)
            textFormat: Text.PlainText
            font.weight: Theme.typography.weightMedium
            color: root.count === 0 ? Theme.palette.textTertiary : Theme.palette.text
        }

        HelpText {
            Layout.fillWidth: true
            body: root.count === 0
                  ? qsTr("Changes collect here as entries, and are published together.")
                  : qsTr("Published as one update: every entry is applied, or none is.")
        }
    }

    LogosButton {
        objectName: "discardButton"
        text: qsTr("Discard")
        enabled: root.count > 0 && !root.store.busy
        onClicked: root.store.backend.discardPending()
    }

    LogosButton {
        // Named apart from the publish sheet's own confirm button, which
        // carries the same word.
        objectName: "publishButton"
        text: qsTr("Publish")
        variant: root.count > 0 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
        enabled: root.count > 0 && !root.store.busy
        onClicked: root.publishRequested()
    }
}
