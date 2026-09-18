pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Exactly one thing on this screen names the account, and it is this bar:
// choosing an account changes the whole screen, not just the panel beneath it.
// Nothing below repeats the name.
Item {
    property var store: null
    signal addAccountRequested()

    id: root
    implicitHeight: 56

    // The popup is the one place that knows whether it is up, since the close
    // policy can take it down without asking anything here.
    readonly property bool open: popover.visible

    Rectangle {
        id: bar
        anchors.fill: parent
        color: Theme.palette.backgroundSecondary
        border.width: 1
        border.color: root.open ? Theme.palette.overlayOrange : Theme.palette.border
        radius: Theme.spacing.radiusLarge

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: popover.visible ? popover.close() : popover.open()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 16
            spacing: Theme.spacing.medium

            // Fills only as far as the name reaches, and gives way first: the
            // count and caret beside it are the bar's own controls. Rounded up,
            // since the layout rounds a width down and a name a fraction of a
            // pixel short of its own width elides.
            LogosText {
                text: root.store.loading ? qsTr("Loading")
                    : root.store.displayName !== "" ? root.store.displayName
                    : root.store.resolved ? qsTr("Unnamed account")
                    : qsTr("Not read yet")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.maximumWidth: Math.ceil(implicitWidth)
                font.pixelSize: root.store.displayName !== ""
                                ? Theme.typography.panelTitleText
                                : Theme.typography.subtitleText
                font.weight: root.store.displayName !== ""
                             ? Theme.typography.weightBold
                             : Theme.typography.weightRegular
                color: root.store.displayName !== "" ? Theme.palette.text
                                                     : Theme.palette.textTertiary
            }

            Badge {
                visible: root.store.renaming
                tone: "pending"
                text: qsTr("Pending")
            }

            Item { Layout.fillWidth: true }

            LogosText {
                text: Fmt.plural(root.store.accounts.length, qsTr("account"), qsTr("accounts"))
                textFormat: Text.PlainText
                font.pixelSize: Theme.typography.secondaryText
                color: Theme.palette.textTertiary
            }

            // A caret, drawn: the icon set carries no chevron.
            Canvas {
                implicitWidth: 10
                implicitHeight: 6
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.fillStyle = Theme.palette.textSecondary
                    ctx.beginPath()
                    ctx.moveTo(0, 0)
                    ctx.lineTo(width, 0)
                    ctx.lineTo(width / 2, height)
                    ctx.closePath()
                    ctx.fill()
                }
            }
        }
    }

    Popup {
        id: popover
        y: bar.height + Theme.spacing.small
        width: root.width
        padding: 6
        // OutsideParent, not Outside: the bar is this popup's parent, so a
        // click on it is left to the toggle above rather than closing here and
        // reopening there.
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        background: Rectangle {
            color: Theme.palette.backgroundSecondary
            border.width: 1
            border.color: Theme.palette.border
            radius: Theme.spacing.radiusLarge
        }

        contentItem: ColumnLayout {
            id: list
            spacing: 2

            Eyebrow {
                Layout.leftMargin: 10
                Layout.topMargin: Theme.spacing.tiny
                label: qsTr("Accounts on this module")
            }

            Repeater {
                model: root.store.accounts

                delegate: Rectangle {
                    required property var modelData

                    id: option

                    Layout.fillWidth: true
                    implicitHeight: 48
                    radius: Theme.spacing.radiusMedium
                    color: option.modelData.address === root.store.address
                           ? Qt.rgba(Theme.palette.primary.r, Theme.palette.primary.g,
                                     Theme.palette.primary.b, 0.18)
                           : "transparent"

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            popover.close()
                            root.store.backend.selectAccount(option.modelData.address)
                        }
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
                                // A name is only known to be missing once the
                                // store has answered for the account.
                                text: option.modelData.displayName ? option.modelData.displayName
                                    : option.modelData.resolved ? qsTr("Unnamed account")
                                    : qsTr("Not read yet")
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                font.pixelSize: Theme.typography.primaryText
                                color: option.modelData.displayName ? Theme.palette.text
                                                             : Theme.palette.textTertiary
                            }
                            LogosText {
                                text: Fmt.mid(option.modelData.address, 10)
                                textFormat: Text.PlainText
                                font.family: Theme.typography.mono
                                font.pixelSize: 11
                                color: Theme.palette.textTertiary
                            }
                        }

                        Badge {
                            visible: !option.modelData.protected
                            text: qsTr("No password")
                        }
                        Badge {
                            visible: option.modelData.pending > 0
                            tone: "pending"
                            text: qsTr("%1 pending").arg(option.modelData.pending)
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                implicitHeight: 1
                color: Theme.palette.borderSubtle
            }

            LogosButton {
                Layout.margins: Theme.spacing.tiny
                text: qsTr("Add an account")
                onClicked: {
                    popover.close()
                    root.addAccountRequested()
                }
            }
        }
    }
}
