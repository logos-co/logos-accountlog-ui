import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A modal panel over the screen, built here rather than taken from the design
// system: everything this app draws that a dialog would give it is one column
// of content and two buttons, and a hand-built one has no API surface to be
// wrong about.
//
// The scrim covers the plugin area only, and swallows every click behind it.
//
// A sheet that makes a backend call stays up until the call lands, and says
// beside its buttons why it did not: the person can fix what they typed rather
// than find the failure somewhere else once the sheet has gone.
Item {
    property string title: ""
    property string confirmText: qsTr("Confirm")
    property bool confirmEnabled: true
    // False where there is nothing to decide: a sheet that only shows a result
    // has one way out, and it is not a cancellation.
    property bool cancellable: true
    property real sheetWidth: 560
    default property alias content: body.data

    // The backend whose `succeeded` and `failed` answer `send`.
    property var backend: null
    // The call this sheet is waiting on, or empty.
    property string awaiting: ""
    // Why the last call failed, in the backend's words.
    property string problem: ""
    // Said while a call has run a while: Cancel is disabled until it lands.
    property string awaitingText: qsTr("Waiting for an answer. A call once made cannot be cancelled.")
    // Where focus was as the sheet opened. A hidden button keeps focus, and
    // Space or Return would press it again, so it goes back as the sheet closes.
    property Item returnFocus: null

    signal confirmed()
    signal cancelled()
    // The call named in `send` succeeded.
    signal landed()

    id: root
    anchors.fill: parent
    visible: false

    function open() {
        problem = ""
        awaiting = ""
        returnFocus = root.Window.activeFocusItem
        visible = true
        panel.forceActiveFocus()
    }

    function close() {
        awaiting = ""
        visible = false
        if (returnFocus && returnFocus.visible && returnFocus.enabled)
            returnFocus.forceActiveFocus()
        else
            root.parent.forceActiveFocus()
        returnFocus = null
    }

    // Say which backend call the confirm just made, before making it.
    function send(what) {
        problem = ""
        awaiting = what
    }

    // Confirm from the keyboard, under the same conditions as the button.
    function submit() {
        if (visible && confirmEnabled && awaiting === "")
            confirmed()
    }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true

        function onSucceeded(what) {
            if (what !== root.awaiting)
                return
            root.awaiting = ""
            root.landed()
        }

        function onFailed(what, message) {
            if (what !== root.awaiting)
                return
            root.awaiting = ""
            root.problem = message
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.palette.scrim

        MouseArea {
            anchors.fill: parent
            // Nothing behind a sheet is clickable while it is up, and a sheet
            // with nothing to cancel is not closed by a click that missed it.
            onClicked: if (root.cancellable && root.awaiting === "") root.cancelled()
        }
    }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(root.sheetWidth, root.width - 48)
        implicitHeight: column.implicitHeight + 32
        color: Theme.palette.backgroundSecondary
        border.width: 1
        border.color: Theme.palette.border
        radius: Theme.spacing.radiusLarge

        // Clicks on the sheet itself must not reach the scrim behind it.
        MouseArea { anchors.fill: parent }

        // A call once made runs to its end, so nothing closes the sheet while
        // it does: its outcome would land with nothing left to show it.
        Keys.onEscapePressed: if (root.awaiting === "") root.cancelled()
        // A field takes Return first, so this is a sheet with nothing focused
        // that would.
        Keys.onReturnPressed: root.submit()
        Keys.onEnterPressed: root.submit()

        ColumnLayout {
            id: column
            anchors.fill: parent
            anchors.margins: 16
            spacing: Theme.spacing.medium

            LogosText {
                Layout.fillWidth: true
                text: root.title
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                color: Theme.palette.text
            }

            ColumnLayout {
                id: body
                Layout.fillWidth: true
                spacing: Theme.spacing.medium
            }

            HelpText {
                objectName: root.objectName + "Problem"
                Layout.fillWidth: true
                visible: root.problem !== ""
                body: root.problem
                color: Theme.palette.error
            }

            // Most calls answer at once, and a line that flashed for those
            // would read as something going wrong.
            Timer {
                id: slow
                interval: 400
                running: root.awaiting !== ""
            }
            HelpText {
                Layout.fillWidth: true
                visible: root.awaiting !== "" && !slow.running
                body: root.awaitingText
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                spacing: Theme.spacing.small

                LogosButton {
                    objectName: root.objectName + "Cancel"
                    visible: root.cancellable
                    enabled: root.awaiting === ""
                    text: qsTr("Cancel")
                    onClicked: root.cancelled()
                }
                Item { Layout.fillWidth: true }
                LogosButton {
                    // Every sheet is instantiated at once and only one is
                    // visible, so a driver looking for a confirm button finds
                    // six. Each is named after the sheet that owns it.
                    objectName: root.objectName + "Confirm"
                    text: root.awaiting !== "" ? qsTr("Working") : root.confirmText
                    enabled: root.confirmEnabled && root.awaiting === ""
                    onClicked: root.submit()
                }
            }
        }
    }
}
