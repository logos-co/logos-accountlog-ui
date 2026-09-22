pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The live entries under namespaces this module has no editor for, listed as
// they come out of the log and left alone: whatever owns a namespace is what
// writes it.
Panel {
    property var store: null

    id: root
    padding: 14
    horizontalPadding: 18
    spacing: Theme.spacing.small

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        LogosText {
            text: qsTr("Other contexts")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
        }
        Badge { text: qsTr("Read only") }
        Item { Layout.fillWidth: true }
    }

    HelpText {
        Layout.fillWidth: true
        body: qsTr("Entries under namespaces this module has no editor for. They are shown so that nothing in the log is invisible here, and left alone: whatever owns the namespace is what writes it.")
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Repeater {
            model: root.store.otherEntries

            delegate: ColumnLayout {
                required property var modelData
                required property int index

                id: entry
                Layout.fillWidth: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    spacing: 10

                    LogosText {
                        text: Fmt.index(entry.modelData.index)
                        textFormat: Text.PlainText
                        font.family: Theme.typography.mono
                        font.pixelSize: 11
                        color: Theme.palette.textTertiary
                    }
                    ContextChip {
                        Layout.maximumWidth: 180
                        text: entry.modelData.context
                    }
                    // A key is recognised by both ends; text is read whole.
                    LogosText {
                        Layout.fillWidth: true
                        text: entry.modelData.kind === "key"
                              ? Fmt.mid(entry.modelData.value, 10) : entry.modelData.value
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.secondaryText
                        color: Theme.palette.textSecondary
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    visible: entry.index < root.store.otherEntries.length - 1
                    color: Theme.palette.borderTertiaryMuted
                }
            }
        }
    }
}
