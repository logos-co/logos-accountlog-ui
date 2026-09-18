import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A labelled field with its own help line, so every sheet asks for something
// the same way: what it is, the box, and what it will cost or why it is wrong.
ColumnLayout {
    property string label: ""
    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property alias echoMode: input.echoMode
    property alias field: input
    property bool mono: false
    property string help: ""
    // Said in the error colour, and in place of `help`.
    property string problem: ""
    // Right-aligned against the help line: a byte count, a length.
    property string counter: ""

    // Return or Enter in the box.
    signal accepted()

    id: root
    spacing: Theme.spacing.tiny

    Connections {
        target: input.textInput
        function onAccepted() { root.accepted() }
    }

    Eyebrow { label: root.label }

    LogosTextField {
        id: input
        Layout.fillWidth: true
        textInput.font.family: root.mono ? Theme.typography.mono
                                         : Theme.typography.publicSans
    }

    RowLayout {
        Layout.fillWidth: true
        visible: root.help !== "" || root.problem !== "" || root.counter !== ""
        spacing: Theme.spacing.small

        HelpText {
            Layout.fillWidth: true
            body: root.problem !== "" ? root.problem : root.help
            color: root.problem !== "" ? Theme.palette.error : Theme.palette.textSecondary
        }

        LogosText {
            visible: root.counter !== ""
            text: root.counter
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textTertiary
        }
    }
}
