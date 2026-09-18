import QtQuick

import Logos.Theme
import Logos.Controls

// A small pill carrying one fact: a count, a state, a warning. Four tones, and
// nothing else in this app uses colour to say something a word does not.
Rectangle {
    // "neutral" | "pending" | "success" | "error"
    property string tone: "neutral"
    property alias text: label.text

    readonly property color accent: tone === "pending" ? Theme.palette.primary
                                  : tone === "success" ? Theme.palette.success
                                  : tone === "error" ? Theme.palette.error
                                  : Theme.palette.textSecondary

    readonly property int labelInset: 8

    id: root
    implicitWidth: label.implicitWidth + root.labelInset * 2
    implicitHeight: 20
    radius: Theme.spacing.radiusSmall
    color: tone === "neutral" ? Theme.palette.backgroundMuted : "transparent"
    border.width: 1
    border.color: tone === "neutral" ? Theme.palette.borderSubtle : root.accent

    LogosText {
        id: label
        anchors.centerIn: parent
        // The pill hugs this label, so it is only ever narrower where a caller
        // gave the pill less room than it asked for, and then the label yields.
        width: Math.min(implicitWidth, root.width - root.labelInset * 2)
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.pixelSize: Theme.typography.secondaryText
        font.weight: Theme.typography.weightMedium
        color: root.accent
    }
}
