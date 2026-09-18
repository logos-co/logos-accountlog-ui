import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

import AccountLog

// The Manage pane: the account this module holds a key for, the live set
// replayed from its log, and the log itself.
//
// One screen at a time, chosen by what the vault holds and what the person
// last asked for. The pane tabs the mockup draws belong to a second pane that
// only reads, and there is nothing to switch to until it exists.
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

    // "manage" | "add" | "create" | "import", as last asked for.
    property string screen: "manage"

    // What is actually drawn: there is nothing to manage until the vault holds
    // an account, so an empty vault opens the door itself.
    readonly property string activeScreen:
        screen === "manage" && !hasAccounts ? "add" : screen

    // The entry the installation list and the log table are both pointing at.
    property int selectedIndex: -1

    readonly property bool hasAccounts: store.accounts.length > 0

    // A screen is drawn from what the vault holds, so none is while it cannot
    // be read: an empty listing would read as a vault that holds nothing.
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
                                 exportKeySheet, forgetSheet])
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

    // Nothing to manage until the vault holds an account, so the door is the
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

    RowLayout {
        objectName: "managePane"
        anchors.fill: parent
        anchors.margins: Theme.spacing.large
        visible: view.usable && view.activeScreen === "manage" && view.hasAccounts
        spacing: Theme.spacing.large

        ColumnLayout {
            // The maximum is what actually holds the column at this width: a
            // nested layout holding a filling child asks to expand, and without
            // a cap it takes the log's half of the screen with it.
            //
            // The minimum is where it stops giving way to the log: below it the
            // installation list cuts the abbreviated keys it shows, whereas
            // everything given up above it costs the address box another
            // wrapped line, which it already takes at 420.
            Layout.preferredWidth: 420
            Layout.maximumWidth: 420
            Layout.minimumWidth: 320
            Layout.fillHeight: true
            spacing: Theme.spacing.medium

            // Outside the scroll view below, so the bar naming the account
            // stays put while the panels under it scroll.
            SwitcherBar {
                Layout.fillWidth: true
                store: store
                onAddAccountRequested: view.screen = "add"
            }

            LogosScrollView {
                id: leftScroller
                Layout.fillWidth: true
                Layout.fillHeight: true
                // This column runs past a 768-high window, and a bar hidden at
                // rest leaves its last sentence reading as cut rather than
                // scrollable. Pinned only where there is something to scroll.
                ScrollBar.vertical.policy: leftScroller.ScrollBar.vertical.size < 1
                                           ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded

                ColumnLayout {
                    width: leftScroller.availableWidth
                    spacing: Theme.spacing.medium

                    AccountPanel {
                        Layout.fillWidth: true
                        store: store
                        onRenameRequested: {
                            displayNameSheet.open()
                            displayNameSheet.reset()
                        }
                        onExportRequested: {
                            exportKeySheet.open()
                            exportKeySheet.reset()
                        }
                        onForgetRequested: forgetSheet.open()
                    }

                    InstallationList {
                        Layout.fillWidth: true
                        store: store
                        selectedIndex: view.selectedIndex
                        onAddRequested: {
                            addInstallationSheet.open()
                            addInstallationSheet.reset()
                        }
                        onSelected: (index) => view.selectedIndex = index
                    }

                    ReadingNotes {
                        Layout.fillWidth: true
                        store: store
                    }

                    Item { Layout.fillHeight: true }
                }
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
                // What the sheet's read finds is said again inside the sheet,
                // so a notice from before it must not be.
                store.backend.dismissNotice()
                store.backend.refresh()
                publishSheet.open()
                publishSheet.reset()
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
        id: forgetSheet
        store: store
    }
}
