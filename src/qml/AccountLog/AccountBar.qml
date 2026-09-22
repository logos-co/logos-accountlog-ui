import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The account itself, across the screen: which one, its address, and what can
// be done to it. Every section under it is one of its namespaces, so choosing
// another account here redraws all of them.
//
// An account this module only observes gets the same bar with everything that
// needs a key taken out: the one thing that can be done to it is to stop.
ColumnLayout {
    property var store: null

    signal addAccountRequested()
    signal observeAccountRequested()
    signal exportRequested()
    signal forgetRequested()

    id: root
    spacing: 6

    readonly property bool switcherOpen: selector.open

    Panel {
        Layout.fillWidth: true
        padding: 10
        horizontalPadding: 16

        // When the bar runs short the selector and the address give way, the
        // name eliding and the address wrapping, and every control keeps its
        // size.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.large

            SwitcherBar {
                id: selector
                Layout.fillWidth: true
                Layout.minimumWidth: Math.min(naturalWidth, 180)
                Layout.maximumWidth: Math.min(implicitWidth, 360)
                store: root.store
                onAddAccountRequested: root.addAccountRequested()
                onObserveAccountRequested: root.observeAccountRequested()
            }

            Rectangle {
                Layout.fillHeight: true
                Layout.topMargin: 2
                Layout.bottomMargin: 2
                implicitWidth: 1
                color: Theme.palette.borderSubtle
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.maximumWidth: implicitWidth
                Layout.minimumWidth: 200
                spacing: Theme.spacing.tiny

                Eyebrow { label: qsTr("Address") }
                ValueBox {
                    Layout.fillWidth: true
                    text: root.store.address
                }
            }

            Item { Layout.fillWidth: true }

            Badge {
                visible: root.store.managed && root.store.renaming
                tone: "pending"
                text: root.store.publishedName !== "" ? qsTr("Rename pending")
                                                      : qsTr("Name pending")
            }
            Badge {
                visible: root.store.observing || !root.store.isProtected
                text: root.store.observing ? qsTr("Read only") : qsTr("No password")
            }
            LogosButton {
                objectName: "exportKeyButton"
                visible: root.store.managed
                text: qsTr("Export key")
                compact: true
                enabled: !root.store.busy
                onClicked: root.exportRequested()
            }
            LogosButton {
                objectName: "forgetAccountButton"
                visible: root.store.managed
                text: qsTr("Forget account")
                compact: true
                enabled: !root.store.busy
                onClicked: root.forgetRequested()
            }
            LogosButton {
                objectName: "stopObservingButton"
                visible: root.store.observing
                text: qsTr("Stop observing")
                compact: true
                enabled: !root.store.busy
                onClicked: root.store.backend.stopObserving(root.store.address)
            }
        }
    }

    HelpText {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.spacing.tiny
        body: root.store.observing
              ? qsTr("This module holds no key for this address, so it can read this log and never write it. Its entries are signed by whoever does.")
              : root.store.isProtected
              ? qsTr("This module holds this account's key, sealed with a password. The address is that key's public half. Handing the account over is an export here and an import there, then forgetting it here.")
              : qsTr("This module holds this account's key, unsealed on this computer. The address is that key's public half. Handing the account over is an export here and an import there, then forgetting it here.")
    }
}
