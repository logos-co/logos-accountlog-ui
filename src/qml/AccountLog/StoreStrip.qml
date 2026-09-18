import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Where this log goes, and what the store last said about it. Named in full so
// the demo can be pointed at a different store without anyone having to guess
// which one is answering.
Rectangle {
    property string url: ""
    property string address: ""
    // "ok" | "wait" | "dead"
    property string tone: "ok"
    property string say: ""
    // Why the last read failed. Offers a second try, and is the tooltip on
    // the status beside it.
    property string problem: ""
    // A call is in flight, the read a retry asks for among them.
    property bool busy: false

    signal retryRequested()

    id: root
    implicitHeight: 40
    color: Theme.palette.backgroundMuted
    border.width: 1
    border.color: Theme.palette.borderSubtle
    radius: Theme.spacing.radiusLarge

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: Theme.spacing.medium

        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            color: root.tone === "dead" ? Theme.palette.error
                 : root.tone === "wait" ? Theme.palette.warning
                 : Theme.palette.success
        }

        LogosText {
            Layout.fillWidth: true
            text: root.url + "/v1/account/" + Fmt.mid(root.address, 6)
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: Theme.typography.mono
            font.pixelSize: 11
            color: Theme.palette.textTertiary
        }

        LogosText {
            text: root.say
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textSecondary

            HoverHandler { id: sayHover }
            ToolTip.visible: sayHover.hovered && root.problem !== ""
            ToolTip.text: root.problem
        }

        LogosButton {
            objectName: "storeRetryButton"
            visible: root.problem !== ""
            enabled: !root.busy
            text: qsTr("Read again")
            // Seated in a 40-high strip, as the notice's Dismiss is.
            implicitHeight: 24
            topPadding: 2
            bottomPadding: 2
            onClicked: root.retryRequested()
        }
    }
}
