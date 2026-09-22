import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

import AccountLog

// The account the bar names, one section per namespace replayed from its log,
// and the log itself. One screen serves both kinds of account: an account this
// module holds the key for is the whole of it, and one it only observes is the
// same screen with every control that needs a key taken out.
//
// One screen at a time, chosen by what this module has and what the person
// last asked for.
Item {
    id: view

    // The plugin draws its own background: the widget behind it is white, and
    // this app is dark.
    Rectangle {
        anchors.fill: parent
        color: Theme.palette.background
    }

    Store {
        id: store
    }

    // isViewModuleReady() is a call, not a property, so a binding on it would
    // be evaluated once and never again. The signal is what says it changed,
    // and it carries the answer, so nothing here has to ask again. One host can
    // hold several view modules, hence the name check.
    Connections {
        target: typeof logos !== "undefined" ? logos : null
        function onViewModuleReadyChanged(moduleName, ready) {
            if (moduleName === store.moduleName)
                store.ready = ready
        }
    }

    // The module can already be ready before this view is built, in which case
    // the signal above has been and gone.
    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.isViewModuleReady(store.moduleName))
            store.ready = true
    }

    // "manage" | "add" | "create" | "import", as last asked for. Observing
    // is a sheet rather than a screen: it asks for one address, and the
    // account it takes on is on screen as soon as it answers.
    property string screen: "manage"

    // What is actually drawn: there is nothing to show until this module has
    // an account of either kind, so a first run opens the door itself.
    readonly property string activeScreen:
        screen === "manage" && !hasAccounts ? "add" : screen

    // The entry the installation list and the log table are both pointing at.
    property int selectedIndex: -1

    readonly property bool hasAccounts: store.accounts.length > 0

    // A screen is drawn from the accounts this module has, so none is while
    // the vault cannot be read: an empty listing would read as a module that
    // has none.
    readonly property bool usable: store.ready && store.vaultProblem === ""

    Connections {
        target: store.backend
        ignoreUnknownSignals: true

        function onAccountExported(address, key) {
            exportedKeySheet.address = address
            exportedKeySheet.key = key
            exportedKeySheet.open()
        }

        function onSelectedAddressChanged() {
            view.selectedIndex = -1
            if (store.backend.selectedAddress !== "")
                view.screen = "manage"
        }

        // An account the vault already held can be the one on screen, which
        // moves no selection.
        function onSucceeded(what) {
            if (what === "importAccount")
                view.screen = "manage"
        }
    }

    // A backend that stops answers nothing it was asked, so no sheet is left
    // waiting on it over the text that says so. The exported key stays: it is
    // already here, and is being written down.
    Connections {
        target: store

        function onReadyChanged() {
            if (store.ready)
                return
            for (const sheet of [addInstallationSheet, displayNameSheet, publishSheet,
                                 exportKeySheet, forgetAccountSheet, observeAccountSheet])
                sheet.close()
        }
    }

    LogosText {
        anchors.centerIn: parent
        visible: !store.ready
        text: store.wasReady ? qsTr("The account backend stopped") : qsTr("Starting")
        textFormat: Text.PlainText
        color: Theme.palette.textTertiary
    }

    ColumnLayout {
        objectName: "vaultProblem"
        anchors.centerIn: parent
        width: Math.min(parent.width - 2 * Theme.spacing.large, 560)
        visible: store.ready && store.vaultProblem !== ""
        spacing: Theme.spacing.medium

        LogosText {
            Layout.fillWidth: true
            text: qsTr("The vault could not be read")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
            color: Theme.palette.text
        }
        LogosText {
            Layout.fillWidth: true
            text: qsTr("Nothing is shown until it can be, since the accounts it holds are what every screen is drawn from: %1")
                      .arg(store.vaultProblem)
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.palette.textSecondary
        }
        LogosButton {
            objectName: "vaultRetryButton"
            text: qsTr("Read again")
            enabled: !store.busy
            onClicked: store.backend.refresh()
        }
    }

    // Nothing to show until this module has an account, so the door is the
    // whole screen rather than an empty two-column layout.
    AddAccountScreen {
        objectName: "addAccountScreen"
        anchors.fill: parent
        visible: view.usable && view.activeScreen === "add"
        canCancel: view.hasAccounts
        onCreateRequested: {
            createScreen.reset()
            view.screen = "create"
        }
        onImportRequested: {
            importScreen.reset()
            view.screen = "import"
        }
        onObserveRequested: {
            observeAccountSheet.open()
            observeAccountSheet.reset()
        }
        onCancelled: view.screen = "manage"
    }

    CreateAccountScreen {
        id: createScreen
        objectName: "createAccountScreen"
        anchors.fill: parent
        visible: view.usable && view.activeScreen === "create"
        store: store
        onCancelled: view.screen = "add"
    }

    ImportAccountScreen {
        id: importScreen
        anchors.fill: parent
        visible: view.usable && view.activeScreen === "import"
        store: store
        onCancelled: view.screen = "add"
    }

    ColumnLayout {
        objectName: "managePane"
        anchors.fill: parent
        anchors.margins: Theme.spacing.large
        visible: view.usable && view.activeScreen === "manage" && view.hasAccounts
        spacing: Theme.spacing.medium

        // Above both columns, so the account stays put while the sections
        // under it scroll, and so it reads as what all of them belong to.
        AccountBar {
            id: accountBar
            Layout.fillWidth: true
            store: store
            onAddAccountRequested: view.screen = "add"
            onObserveAccountRequested: {
                observeAccountSheet.open()
                observeAccountSheet.reset()
            }
            onExportRequested: {
                exportKeySheet.open()
                exportKeySheet.reset()
            }
            onForgetRequested: forgetAccountSheet.open()
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.spacing.large

            LogosScrollView {
                id: leftScroller
                Layout.fillWidth: true
                // The maximum is what actually holds the column at this width:
                // it fills, and without a cap it takes the log's half of the
                // screen with it.
                //
                // The minimum is where it stops giving way to the log: below it
                // the installation list cuts the abbreviated keys it shows.
                Layout.preferredWidth: 520
                Layout.maximumWidth: 520
                Layout.minimumWidth: 320
                Layout.fillHeight: true
                // This column runs past a 768-high window, and a bar hidden at
                // rest leaves its last sentence reading as cut rather than
                // scrollable. Pinned only where there is something to scroll.
                ScrollBar.vertical.policy: leftScroller.ScrollBar.vertical.size < 1
                                           ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded

                ColumnLayout {
                    width: leftScroller.availableWidth
                    spacing: Theme.spacing.medium

                    ProfileSection {
                        Layout.fillWidth: true
                        store: store
                        onRenameRequested: {
                            displayNameSheet.open()
                            displayNameSheet.reset()
                        }
                    }

                    ChatSection {
                        Layout.fillWidth: true
                        store: store
                        selectedIndex: view.selectedIndex
                        onAddRequested: {
                            addInstallationSheet.open()
                            addInstallationSheet.reset()
                        }
                        onSelected: (index) => view.selectedIndex = index
                    }

                    OtherContexts {
                        Layout.fillWidth: true
                        visible: store.otherEntries.length > 0
                        store: store
                    }

                    ReadingNotes {
                        Layout.fillWidth: true
                        store: store
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            LogPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                store: store
                selectedIndex: view.selectedIndex
                firstNewIndex: store.backend ? store.backend.firstNewIndex : -1
                onSelected: (index) => view.selectedIndex = index
                // Read first, so the preview is of what the store holds now: an
                // edit another device already wrote drops out of it.
                onPublishRequested: {
                    // What the sheet's read finds is said again inside the
                    // sheet, so a notice from before it must not be.
                    store.backend.dismissNotice()
                    store.backend.refresh()
                    publishSheet.open()
                    publishSheet.reset()
                }
            }
        }
    }

    AddInstallationSheet {
        id: addInstallationSheet
        store: store
    }

    DisplayNameSheet {
        id: displayNameSheet
        store: store
    }

    PublishSheet {
        id: publishSheet
        store: store
    }

    ExportKeySheet {
        id: exportKeySheet
        store: store
    }

    ExportedKeySheet {
        id: exportedKeySheet
    }

    ForgetAccountSheet {
        id: forgetAccountSheet
        store: store
    }

    ObserveAccountSheet {
        id: observeAccountSheet
        store: store
        // Selecting an account already on screen changes nothing and says
        // nothing, so the screen this was opened from is left behind here.
        onOpenRequested: (address) => {
            store.backend.selectAccount(address)
            view.screen = "manage"
        }
    }
}
