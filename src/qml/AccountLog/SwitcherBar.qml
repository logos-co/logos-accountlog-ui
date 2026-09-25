pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The account's name, and the list of every other: choosing an account changes
// the whole screen, every section and the log.
//
// Both kinds of account are in the one list, under a heading each that says
// what the word means: two words picked out of a list cannot teach a reader
// the difference between holding an account's key and not holding it, and this
// is the one place every reader passes through.
Item {
    objectName: "switcherBar"

    property var store: null
    signal addAccountRequested()
    signal observeAccountRequested()

    id: root
    implicitWidth: Math.max(260, root.naturalWidth)
    implicitHeight: 48

    // The width the name and the caret need, which the bar pads out to 260.
    readonly property real naturalWidth: content.implicitWidth + 26

    // The popup is the one place that knows whether it is up, since the close
    // policy can take it down without asking anything here.
    readonly property bool open: popover.visible

    Rectangle {
        id: bar
        anchors.fill: parent
        color: Theme.palette.backgroundMuted
        border.width: 1
        border.color: root.open ? Theme.palette.overlayOrange : Theme.palette.borderSubtle
        radius: Theme.spacing.radiusLarge

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: popover.visible ? popover.close() : popover.open()
        }

        RowLayout {
            id: content
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 12
            spacing: Theme.spacing.medium

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                // Gives way first: the caret beside it is the bar's own
                // control. Rounded up, since the layout rounds a width down and
                // a name a fraction of a pixel short of its own width elides.
                LogosText {
                    readonly property bool named: root.store.displayName !== ""

                    // An account with no name is its address: a bar saying
                    // "Unnamed account" names nothing at all, and the address
                    // is what the account actually is.
                    text: root.store.loading ? qsTr("Loading")
                        : named ? root.store.displayName
                        : Fmt.mid(root.store.address, 8)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    Layout.maximumWidth: Math.ceil(implicitWidth)
                    font.family: named ? Theme.typography.publicSans : Theme.typography.mono
                    font.pixelSize: named ? Theme.typography.subtitleText
                                          : Theme.typography.primaryText
                    font.weight: named ? Theme.typography.weightBold
                                       : Theme.typography.weightRegular
                    color: named ? Theme.palette.text : Theme.palette.textSecondary
                }

                LogosText {
                    text: Fmt.plural(root.store.accounts.length, qsTr("account"), qsTr("accounts"))
                    textFormat: Text.PlainText
                    font.pixelSize: 11
                    color: Theme.palette.textTertiary
                }
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
        width: 420
        padding: 6
        // OutsideParent, not Outside: the bar is this popup's parent, so a
        // click on it is left to the toggle above rather than closing here and
        // reopening there.
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        // Escape reaches a popup only while it holds the focus.
        focus: true

        background: Rectangle {
            color: Theme.palette.backgroundSecondary
            border.width: 1
            border.color: Theme.palette.border
            radius: Theme.spacing.radiusLarge
        }

        contentItem: ColumnLayout {
            id: list
            spacing: 2

            // A module with many accounts scrolls rather than growing a
            // popover past the window it is drawn in.
            LogosScrollView {
                id: roster
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(rosterColumn.implicitHeight, 420)

                ColumnLayout {
                    id: rosterColumn
                    width: roster.availableWidth
                    spacing: 2

                    // An empty group draws nothing at all: a heading over no
                    // rows teaches the word without showing the thing.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: root.store.managedAccounts.length > 0
                        spacing: 2

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.topMargin: Theme.spacing.tiny
                            spacing: Theme.spacing.small

                            Eyebrow {
                                label: qsTr("Managed · %1").arg(root.store.managedAccounts.length)
                            }
                            LogosText {
                                Layout.fillWidth: true
                                text: qsTr("this module holds the key")
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.pixelSize: Theme.typography.secondaryText
                                color: Theme.palette.textTertiary
                            }
                        }

                        Repeater {
                            model: root.store.managedAccounts

                            delegate: SwitcherRow {
                                required property var modelData

                                Layout.fillWidth: true
                                account: modelData
                                current: modelData.address === root.store.address
                                onChosen: {
                                    popover.close()
                                    root.store.backend.selectAccount(modelData.address)
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: root.store.observedAccounts.length > 0
                        spacing: 2

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 10
                            Layout.topMargin: Theme.spacing.tiny
                            spacing: Theme.spacing.small

                            Eyebrow {
                                label: qsTr("Observed · %1").arg(root.store.observedAccounts.length)
                            }
                            LogosText {
                                Layout.fillWidth: true
                                text: qsTr("read only, no key here")
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.pixelSize: Theme.typography.secondaryText
                                color: Theme.palette.textTertiary
                            }
                        }

                        Repeater {
                            model: root.store.observedAccounts

                            delegate: SwitcherRow {
                                required property var modelData

                                Layout.fillWidth: true
                                account: modelData
                                current: modelData.address === root.store.address
                                onChosen: {
                                    popover.close()
                                    root.store.backend.selectAccount(modelData.address)
                                }
                            }
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

            RowLayout {
                Layout.margins: Theme.spacing.tiny
                spacing: Theme.spacing.small

                LogosButton {
                    objectName: "addAccountButton"
                    text: qsTr("Add an account")
                    onClicked: {
                        popover.close()
                        root.addAccountRequested()
                    }
                }
                LogosButton {
                    objectName: "observeAccountButton"
                    text: qsTr("Observe an account")
                    onClicked: {
                        popover.close()
                        root.observeAccountRequested()
                    }
                }
                Item { Layout.fillWidth: true }
            }
        }
    }
}
