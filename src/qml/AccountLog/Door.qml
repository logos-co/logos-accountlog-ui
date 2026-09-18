import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// One of two ways in, stated in full before it is taken: a title, what it will
// actually do, and the button that does it.
Rectangle {
    property string title: ""
    property string body: ""
    property string action: ""
    property bool primary: false

    signal triggered()

    id: root
    implicitHeight: column.implicitHeight + 40
    color: Theme.palette.backgroundMuted
    border.width: 1
    border.color: root.primary ? Theme.palette.overlayOrange : Theme.palette.borderSubtle
    radius: Theme.spacing.radiusLarge

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: 20
        spacing: Theme.spacing.small

        LogosText {
            Layout.fillWidth: true
            text: root.title
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
        }

        LogosText {
            Layout.fillWidth: true
            text: root.body
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textSecondary
            lineHeight: 1.35
        }

        Item { Layout.fillHeight: true; Layout.minimumHeight: Theme.spacing.small }

        LogosButton {
            // The title above carries the same words as this button, so a
            // driver matching on text alone cannot tell them apart.
            objectName: root.objectName + "Action"
            text: root.action
            variant: root.primary ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
            onClicked: root.triggered()
        }
    }
}
