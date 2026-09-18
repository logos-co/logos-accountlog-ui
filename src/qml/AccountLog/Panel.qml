import QtQuick
import QtQuick.Layouts

import Logos.Theme

// The surface every block on this screen sits on.
Rectangle {
    default property alias content: body.data
    property alias spacing: body.spacing
    property real padding: Theme.spacing.large
    property real horizontalPadding: 20

    id: root
    color: Theme.palette.backgroundSecondary
    border.width: 1
    border.color: Theme.palette.border
    radius: Theme.spacing.radiusLarge
    implicitHeight: body.implicitHeight + root.padding * 2

    ColumnLayout {
        id: body
        anchors.fill: parent
        anchors.topMargin: root.padding
        anchors.bottomMargin: root.padding
        anchors.leftMargin: root.horizontalPadding
        anchors.rightMargin: root.horizontalPadding
        spacing: Theme.spacing.small
    }
}
