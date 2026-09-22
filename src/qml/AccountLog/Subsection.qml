import QtQuick
import QtQuick.Layouts

import Logos.Theme

// One context of the several a namespace's section may hold. The rule above it
// is what says it is a part of the section rather than a sibling of it.
// Anything declared inside follows the label and the context on its row.
ColumnLayout {
    property string label: ""
    property string context: ""
    default property alias content: row.data

    id: root
    spacing: Theme.spacing.medium

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.palette.borderSubtle
    }

    RowLayout {
        id: row
        Layout.fillWidth: true
        spacing: 10

        Eyebrow { label: root.label }
        ContextChip {
            visible: root.context !== ""
            text: root.context
        }
    }
}
