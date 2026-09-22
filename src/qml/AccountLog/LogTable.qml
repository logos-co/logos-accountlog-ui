pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The log itself: the domain it opens with, every entry in order, and the
// entries the next publish will append. Nothing is ever taken out, so a
// removal is a row like any other and what it removed stays above it.
ColumnLayout {
    property var store: null
    property int selectedIndex: -1
    // The first index the last publish wrote, or -1.
    property int firstNewIndex: -1

    signal selected(int index)

    id: root
    spacing: 0

    // One place agrees what the columns are, so a header and a row cannot
    // drift apart. `index`, `op`, `context` and `bytes` are the width of the
    // widest token each holds, measured: an index, a context and an op name are
    // each the whole content of their cell, so none of them may be cut. `state`
    // asks for its longest sentence and falls to the width of a `Superseded
    // by #NN` badge, which loses only that sentence's tail. `data` carries the
    // value, the one thing the rest of the row does not say, so it keeps its
    // floor and takes every spare pixel.
    readonly property var widths: ({
        index: 30, op: 62, bytes: 34, context: 140,
        state: 172, stateFloor: 124,
        dataFloor: 140,
        rowMargin: 12
    })

    // What the columns need before one of them starts cutting content, so the
    // panel can ask the window for that much before the left column takes it.
    readonly property int minimumWidth:
        widths.index + widths.op + widths.context + widths.dataFloor
        + widths.stateFloor + widths.bytes
        + Theme.spacing.small * 5 + widths.rowMargin * 2

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: root.widths.rowMargin
        Layout.rightMargin: root.widths.rowMargin
        Layout.bottomMargin: Theme.spacing.tiny
        spacing: Theme.spacing.small

        Eyebrow { Layout.preferredWidth: root.widths.index; label: "#" }
        Eyebrow { Layout.preferredWidth: root.widths.op; label: qsTr("Op") }
        Eyebrow { Layout.preferredWidth: root.widths.context; label: qsTr("Context") }
        Eyebrow {
            Layout.fillWidth: true
            Layout.preferredWidth: root.widths.dataFloor
            Layout.minimumWidth: root.widths.dataFloor
            label: qsTr("Data")
        }
        Eyebrow {
            Layout.fillWidth: true
            Layout.preferredWidth: root.widths.state
            Layout.maximumWidth: root.widths.state
            Layout.minimumWidth: root.widths.stateFloor
            label: qsTr("State")
        }
        Eyebrow {
            Layout.preferredWidth: root.widths.bytes
            horizontalAlignment: Text.AlignRight
            label: qsTr("Bytes")
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.palette.borderSubtle
    }

    // The domain is not an entry and has no index, but it is bytes the
    // signature covers, so it is shown where those bytes are counted.
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: root.widths.rowMargin
        Layout.rightMargin: root.widths.rowMargin
        Layout.topMargin: Theme.spacing.tiny
        Layout.bottomMargin: Theme.spacing.tiny
        spacing: Theme.spacing.small

        Item { Layout.preferredWidth: root.widths.index }

        LogosText {
            text: "logos:accounts:1"
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textSecondary
        }

        HelpText {
            Layout.fillWidth: true
            body: qsTr("domain, covered by the one signature over the whole log")
        }

        LogosText {
            Layout.preferredWidth: root.widths.bytes
            horizontalAlignment: Text.AlignRight
            text: root.store.domainBytes
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textTertiary
        }
    }

    Repeater {
        model: root.store.entries

        delegate: LogRow {
            required property var modelData

            Layout.fillWidth: true
            row: modelData
            widths: root.widths
            removedBy: root.store.removedBy(modelData.index)
            leavingBy: root.store.willBeRevokedBy(modelData.index)
            fresh: root.firstNewIndex >= 0 && modelData.index >= root.firstNewIndex
            current: root.selectedIndex === modelData.index
            onClicked: root.selected(modelData.index)
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.tiny
        visible: root.store.pending.length > 0
        implicitHeight: 1
        color: Theme.palette.primary
        opacity: 0.4
    }

    Repeater {
        model: root.store.pending

        delegate: LogRow {
            required property var modelData

            Layout.fillWidth: true
            row: modelData
            widths: root.widths
            pending: true
        }
    }
}
