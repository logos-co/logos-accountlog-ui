import QtQuick

import Logos.Theme
import Logos.Controls

// A context, verbatim and in monospace. Contexts are byte-compared by the log,
// so they are shown exactly as written and never prettified.
Rectangle {
    property alias text: label.text

    readonly property int labelInset: 6

    id: root
    implicitWidth: label.implicitWidth + root.labelInset * 2
    implicitHeight: 20
    radius: Theme.spacing.radiusSmall
    color: Theme.palette.backgroundMuted
    border.width: 1
    border.color: Theme.palette.borderSubtle

    LogosText {
        id: label
        anchors.centerIn: parent
        // The chip hugs this label, so it is only ever narrower where a caller
        // gave the chip less room than it asked for, and then the label yields.
        width: Math.min(implicitWidth, root.width - root.labelInset * 2)
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.family: Theme.typography.mono
        font.pixelSize: 11
        color: Theme.palette.textSecondary
    }
}
