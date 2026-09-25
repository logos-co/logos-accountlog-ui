import QtQuick
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
    // Why the last read failed. The tooltip on the status beside it.
    property string problem: ""
    // A call is in flight, the read a retry asks for among them.
    property bool busy: false
    // When the log on screen was read, in milliseconds since the epoch, or 0.
    // Once one has landed, how old the copy is is what this strip says: the
    // backend's own line is what it was doing, and that is the answer only
    // while it is doing it.
    property real readAtMs: 0

    signal retryRequested()

    id: root
    implicitHeight: 40
    color: Theme.palette.backgroundMuted
    border.width: 1
    border.color: Theme.palette.borderSubtle
    radius: Theme.spacing.radiusLarge

    // The clock this strip's freshness is measured against. No property
    // changes as time passes, so one is ticked here.
    property real now: 0
    readonly property string freshness:
        root.readAtMs > 0 ? qsTr("Read %1").arg(Fmt.since(root.readAtMs, root.now)) : ""

    Timer {
        running: root.visible && root.readAtMs > 0
        interval: 30000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

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
            // The backend's own line wins wherever there is something wrong
            // to say: how old the copy is is only the answer while the last
            // read is still the store's last word.
            text: root.busy || root.problem !== "" || root.freshness === ""
                  ? root.say : root.freshness
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.secondaryText
            color: Theme.palette.textSecondary

            HoverHandler { id: sayHover }
            LogosToolTip {
                text: root.problem
                visible: sayHover.hovered && root.problem !== ""
            }
        }

        // Always here: reading the store back is the whole of what can be done
        // to an account whose key is elsewhere, and it is how an account this
        // module holds is checked against what the store actually serves.
        LogosButton {
            objectName: "storeRetryButton"
            enabled: !root.busy
            text: root.readAtMs > 0 ? qsTr("Read again") : qsTr("Read")
            // Seated in a 40-high strip, as the notice's Dismiss is.
            implicitHeight: 24
            topPadding: 2
            bottomPadding: 2
            onClicked: root.retryRequested()
        }
    }
}
