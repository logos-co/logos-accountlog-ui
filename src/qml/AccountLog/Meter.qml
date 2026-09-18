import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// How much of the log's lifetime budget has been spent. A budget rather than a
// quota: the format never reclaims the space an entry took, not even a revoked
// one, so this bar only ever moves one way.
ColumnLayout {
    property int used: 0
    property int limit: Fmt.maxBytes

    id: root
    spacing: Theme.spacing.tiny

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.small

        Eyebrow { label: qsTr("Log size") }
        Item { Layout.fillWidth: true }
        LogosText {
            text: Fmt.bytes(root.used) + qsTr(" of ") + Fmt.bytes(root.limit)
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textSecondary
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 4
        radius: 2
        color: Theme.palette.surfaceRecessed

        Rectangle {
            height: parent.height
            radius: parent.radius
            color: Theme.palette.accentOrange
            // A three-pixel floor, so a log that has only claimed its address
            // still reads as a log rather than as an empty track.
            width: Math.max(3, parent.width * Math.min(1, root.used / Math.max(1, root.limit)))
        }
    }

    HelpText { Layout.fillWidth: true; body: qsTr("A lifetime budget: space is never reclaimed.") }
}
