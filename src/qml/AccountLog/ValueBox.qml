import QtQuick
import QtQuick.Layouts

import Logos.Theme

// A value shown in full and selectable: an address, an exported key. Wrapped
// rather than elided, because the whole of it is the identifier and a column
// narrower than 64 hex characters is the ordinary case.
Rectangle {
    property alias text: value.text

    id: root
    implicitWidth: row.implicitWidth + 20
    implicitHeight: Math.max(36, value.implicitHeight + 16)
    color: Theme.palette.backgroundMuted
    border.width: 1
    border.color: Theme.palette.borderSubtle
    radius: Theme.spacing.radiusSmall

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        spacing: Theme.spacing.small

        TextEdit {
            id: value
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            readOnly: true
            selectByMouse: true
            wrapMode: Text.WrapAnywhere
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textTertiary
        }

        CompactButton {
            Layout.alignment: Qt.AlignVCenter
            text: qsTr("Copy")
            onClicked: {
                value.selectAll()
                value.copy()
                value.deselect()
            }
        }
    }
}
