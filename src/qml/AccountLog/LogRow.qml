import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// One entry of the log, published or staged. The six columns are the table's,
// so the widths arrive from above rather than being agreed twice.
Rectangle {
    property var row: null
    property var widths: null
    // Staged: numbered as it will be, and written by the next publish.
    property bool pending: false
    // The entry this one already retired, when a removal points at it.
    property int removedBy: -1
    // The pending entry that will retire this one, or -1: it is live now and
    // will not be once the update lands.
    property int leavingBy: -1
    // Part of what the last publish wrote.
    property bool fresh: false
    property bool current: false

    signal clicked()

    id: root
    readonly property bool isRemoval: row.kind === "revocation"
    readonly property bool tombstoned: removedBy >= 0
    // A live name a later one took over from: live in the log, and not the
    // account's name.
    readonly property bool superseded: !pending && row.supersededBy !== null
                                       && row.supersededBy !== undefined

    implicitHeight: 34
    color: root.current ? Qt.rgba(Theme.palette.primary.r, Theme.palette.primary.g,
                                  Theme.palette.primary.b, 0.12)
                        : "transparent"
    opacity: root.tombstoned && !root.current ? 0.55 : 1

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: root.widths.rowMargin
        anchors.rightMargin: root.widths.rowMargin
        spacing: Theme.spacing.small

        LogosText {
            Layout.preferredWidth: root.widths.index
            text: Fmt.index(root.row.index)
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textTertiary
        }

        Item {
            Layout.preferredWidth: root.widths.op
            implicitHeight: 20
            Badge {
                anchors.verticalCenter: parent.verticalCenter
                tone: root.isRemoval ? "error" : "neutral"
                text: root.isRemoval ? qsTr("Remove") : qsTr("Add")
            }
        }

        Item {
            id: contextCell
            Layout.preferredWidth: root.widths.context
            implicitHeight: 20
            ContextChip {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, contextCell.width)
                visible: root.row.context !== null && root.row.context !== undefined
                text: root.row.context ? root.row.context : ""
            }
        }

        LogosText {
            Layout.fillWidth: true
            Layout.preferredWidth: root.widths.dataFloor
            Layout.minimumWidth: root.widths.dataFloor
            // A key is recognised by both ends; a name is read whole.
            text: root.row.kind === "installation" || root.row.kind === "key"
                  ? Fmt.mid(root.row.value, 8)
                  : root.isRemoval ? Fmt.index(root.row.target)
                  : root.row.value
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: root.row.kind === "displayName" || root.row.kind === "text"
                         ? Theme.typography.publicSans
                         : Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.text
        }

        Item {
            id: stateCell
            Layout.fillWidth: true
            Layout.preferredWidth: root.widths.state
            Layout.maximumWidth: root.widths.state
            Layout.minimumWidth: root.widths.stateFloor
            implicitHeight: 20

            Badge {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, stateCell.width)
                visible: root.pending
                tone: "pending"
                text: qsTr("Pending")
            }
            Badge {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, stateCell.width)
                visible: !root.pending && root.tombstoned
                text: qsTr("Removed by %1").arg(Fmt.index(root.removedBy))
            }
            LogosText {
                anchors.verticalCenter: parent.verticalCenter
                width: stateCell.width
                visible: !root.pending && !root.tombstoned && root.leavingBy >= 0
                text: qsTr("Removed by %1 on publish").arg(Fmt.index(root.leavingBy))
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.pixelSize: Theme.typography.secondaryText
                color: Theme.palette.primary
            }
            Badge {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, stateCell.width)
                visible: !root.tombstoned && root.leavingBy < 0 && root.superseded
                text: qsTr("Superseded by %1").arg(Fmt.index(root.row.supersededBy))
            }
            Badge {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, stateCell.width)
                visible: !root.pending && !root.tombstoned && root.leavingBy < 0 && !root.superseded
                         && root.fresh
                tone: "success"
                text: qsTr("Just published")
            }
        }

        LogosText {
            Layout.preferredWidth: root.widths.bytes
            horizontalAlignment: Text.AlignRight
            text: (root.pending ? "+" : "") + root.row.bytes
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.secondaryText
            color: root.pending ? Theme.palette.primary : Theme.palette.textTertiary
        }
    }
}
