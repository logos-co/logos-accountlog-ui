import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// One account in the switcher, and one address is one row. It says what the
// account is called, its address, and a badge only where something is not the
// default. How many entries it has and how long ago it was read are on the
// screen the row opens, and repeating them here only makes the list harder to
// scan.
Rectangle {
    property var account: null
    property bool current: false

    signal chosen()

    id: root
    implicitHeight: 48
    radius: Theme.spacing.radiusMedium
    color: root.current
           ? Qt.rgba(Theme.palette.primary.r, Theme.palette.primary.g,
                     Theme.palette.primary.b, 0.18)
           : "transparent"

    readonly property bool managed: root.account.managed !== false
    readonly property string name: root.account.displayName || ""
    // A name is only known to be missing once the store has answered, and an
    // account this module can name itself is missing a different thing from
    // one it can only read.
    readonly property string unnamed: !root.account.resolved ? qsTr("Not read yet")
                                    : root.managed ? qsTr("No display name set")
                                    : qsTr("No display name published")
    // Why the last read of an observed account did not land. A managed
    // account's badges are about publishing, which is what its row is for.
    readonly property string failure: {
        if (root.managed || !root.account.problem)
            return ""
        if (root.account.problem === "unverified")
            return qsTr("Not verified")
        if (root.account.problem === "forked")
            return qsTr("Forked log")
        return qsTr("Could not be read")
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.chosen()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        spacing: Theme.spacing.medium

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            LogosText {
                text: root.name !== "" ? root.name : Fmt.mid(root.account.address, 10)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                Layout.fillWidth: true
                font.family: root.name !== "" ? Theme.typography.publicSans
                                              : Theme.typography.mono
                font.pixelSize: Theme.typography.primaryText
                color: root.name !== "" ? Theme.palette.text : Theme.palette.textSecondary
            }
            LogosText {
                text: root.name !== "" ? Fmt.mid(root.account.address, 10) : root.unnamed
                textFormat: Text.PlainText
                elide: Text.ElideRight
                Layout.fillWidth: true
                font.family: root.name !== "" ? Theme.typography.mono
                                              : Theme.typography.publicSans
                font.pixelSize: 11
                color: Theme.palette.textTertiary
            }
        }

        Badge {
            visible: root.managed && !root.account.protected
            text: qsTr("No password")
        }
        Badge {
            visible: root.managed && root.account.pending > 0
            tone: "pending"
            text: qsTr("%1 pending").arg(root.account.pending)
        }
        Badge {
            visible: root.failure !== ""
            tone: "error"
            text: root.failure
        }
    }
}
