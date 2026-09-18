import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls
import Logos.Icons

// One endorsed key: the entry that endorsed it, the key itself, and whatever
// this update is about to do to it.
Rectangle {
    property int entryIndex: 0
    property string keyHex: ""
    // Staged, so it has no entry in the published log yet.
    property bool pending: false
    // A staged revocation points at this entry.
    property bool leaving: false
    property bool current: false

    signal clicked()
    signal removeRequested()

    id: root
    implicitHeight: 44
    radius: Theme.spacing.radiusMedium
    color: root.current ? Qt.rgba(Theme.palette.primary.r, Theme.palette.primary.g,
                                  Theme.palette.primary.b, 0.14)
                        : Theme.palette.backgroundMuted
    border.width: 1
    border.color: root.pending || root.leaving ? Theme.palette.primary
                : root.current ? Theme.palette.overlayOrange
                : Theme.palette.borderSubtle
    opacity: root.leaving ? 0.7 : 1

    MouseArea {
        anchors.fill: parent
        enabled: !root.pending
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 8
        spacing: Theme.spacing.small

        LogosText {
            text: Fmt.index(root.entryIndex)
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textTertiary
        }

        LogosText {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: Fmt.mid(root.keyHex, 14)
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: root.leaving ? Theme.palette.textTertiary : Theme.palette.text
        }

        Badge {
            Layout.alignment: Qt.AlignVCenter
            visible: root.pending
            tone: "pending"
            text: qsTr("Pending")
        }
        Badge {
            Layout.alignment: Qt.AlignVCenter
            visible: root.leaving
            tone: "pending"
            text: qsTr("Pending removal")
        }
        LogosIconButton {
            Layout.alignment: Qt.AlignVCenter
            visible: !root.pending && !root.leaving
            // The key beside it is what the row is about, and a labelled
            // button here would be wider than the key.
            Accessible.name: qsTr("Remove this installation")
            ToolTip.visible: hovered
            ToolTip.text: qsTr("Remove this installation")
            iconSource: LogosIcons.trash
            iconColor: Theme.palette.textTertiary
            size: 32
            iconSize: 16
            flat: true
            // Off the button before it hides, where Space would press it again.
            onClicked: {
                root.forceActiveFocus()
                root.removeRequested()
            }
        }
    }
}
