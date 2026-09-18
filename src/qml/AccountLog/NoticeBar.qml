import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What just happened, said once and dismissible. A publish raises one, and so
// do the two edits made from a button on the log; everything else that fails
// says so in the sheet or screen that made the call.
Rectangle {
    // "success" | "error" | "info" | "warning"
    property string tone: "info"
    property string title: ""
    property string body: ""
    // A notice that states a rule rather than reporting an event stays put.
    property bool dismissable: true
    signal dismissed()

    readonly property color accent: tone === "success" ? Theme.palette.success
                                  : tone === "error" ? Theme.palette.error
                                  : tone === "warning" ? Theme.palette.warning
                                  : Theme.palette.primary

    id: root
    implicitHeight: layout.implicitHeight + 24
    color: Theme.palette.backgroundMuted
    border.width: 1
    border.color: root.accent
    radius: Theme.spacing.radiusLarge

    RowLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: 12
        spacing: Theme.spacing.medium

        Rectangle {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 4
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            color: root.accent
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            LogosText {
                Layout.fillWidth: true
                text: root.title
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.weight: Theme.typography.weightMedium
                color: Theme.palette.text
            }
            HelpText {
                Layout.fillWidth: true
                visible: root.body !== ""
                body: root.body
            }
        }

        LogosButton {
            visible: root.dismissable
            text: qsTr("Dismiss")
            // A Control seats its label inside the padding box, and this
            // button pads 12 above and below against a floor of 44. A strip
            // this short needs the padding down with the height: left at 12
            // the box is nothing high and the label draws under it.
            implicitHeight: 24
            topPadding: 2
            bottomPadding: 2
            onClicked: root.dismissed()
        }
    }
}
