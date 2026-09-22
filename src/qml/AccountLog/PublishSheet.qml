import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Send the staged entries as one update. Nothing is asked for: a sealed key
// was opened when the account was unlocked, and an unsealed one needs no
// opening. The sheet says which.
Sheet {
    property var store: null

    id: root
    objectName: "publishSheet"
    title: root.nothingLeft ? qsTr("Nothing left to publish")
                            : qsTr("Publish %1").arg(Fmt.entries(root.store.pending.length))
    confirmText: root.nothingLeft ? qsTr("Close") : qsTr("Publish")
    // Not before the read made as the sheet opened lands: the preview is what
    // the store holds only once it has.
    confirmEnabled: root.nothingLeft
                    || (root.store.pending.length > 0 && !root.store.busy
                        && root.store.storeProblem === "")
    cancellable: !root.nothingLeft
    awaitingText: qsTr("Publishing. A publish cannot be stopped once sent, and the store has up to 15 seconds to answer.")
    backend: root.store.backend

    readonly property bool nothingLeft: root.store.hasAccount && root.store.pending.length === 0
                                        && !root.store.busy
    // How many entries this device had read as the sheet opened, or -1 when it
    // had not read the store yet and so has nothing to compare against.
    property int entriesBefore: -1
    // What another device published meanwhile, which the preview now builds on.
    readonly property int arrived: root.entriesBefore < 0 || root.store.busy
                                   ? 0 : root.store.entries.length - root.entriesBefore

    function reset() {
        root.entriesBefore = root.store.resolved ? root.store.entries.length : -1
    }

    onConfirmed: {
        if (root.nothingLeft) {
            root.close()
            return
        }
        root.send("publish")
        store.backend.publish()
    }
    onLanded: root.close()
    onCancelled: root.close()

    LogosText {
        Layout.fillWidth: true
        visible: root.store.busy && root.awaiting === ""
        text: qsTr("Reading the store, so that what is published extends what it holds now.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    // A publish reads the store first, so one the sheet's own read could not
    // reach would fail the same way.
    RowLayout {
        Layout.fillWidth: true
        visible: root.store.storeProblem !== "" && !root.store.busy
        spacing: Theme.spacing.medium

        HelpText {
            Layout.fillWidth: true
            body: qsTr("The store could not be read, so publishing would fail: %1")
                      .arg(root.store.storeProblem)
            color: Theme.palette.error
        }
        LogosButton {
            objectName: "publishRetryButton"
            text: qsTr("Read again")
            onClicked: {
                root.problem = ""
                root.store.backend.refresh()
            }
        }
    }

    LogosText {
        Layout.fillWidth: true
        visible: root.arrived > 0 && !root.nothingLeft && root.awaiting === ""
        text: qsTr("Another device published %1 since this one last read the store, so what is below is planned on top of it.")
                  .arg(Fmt.entries(root.arrived))
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.warning
    }

    // The sheet's read raises this and nothing else while the sheet is up.
    LogosText {
        Layout.fillWidth: true
        visible: root.store.backend.noticeKind === "info" && !root.nothingLeft
                 && root.awaiting === ""
        text: root.store.backend.noticeBody
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    // The read made as the sheet opened can find everything already written.
    LogosText {
        Layout.fillWidth: true
        visible: root.nothingLeft
        text: qsTr("The store already holds everything that was pending, so there is nothing left to publish.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    LogosText {
        Layout.fillWidth: true
        visible: root.store.pending.length > 0
        text: qsTr("Signs the whole log with this account's key and sends it to the store: %1 appending %2 bytes, leaving %3 bytes in the log's lifetime budget.")
                  .arg(Fmt.entries(root.store.pending.length))
                  .arg(root.store.pendingBytes)
                  .arg(Fmt.count(root.store.maxBytes - root.store.logBytes - root.store.pendingBytes))
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    NoticeBar {
        Layout.fillWidth: true
        visible: root.store.isProtected && !root.nothingLeft
        dismissable: false
        tone: "info"
        title: qsTr("This account is unlocked")
        body: qsTr("Its key was opened with its password this session and stays open until the app closes, so publishing asks for nothing.")
    }

    NoticeBar {
        Layout.fillWidth: true
        visible: !root.store.isProtected && !root.nothingLeft
        dismissable: false
        tone: "info"
        title: qsTr("This account has no password")
        body: qsTr("Its key is stored unsealed on this computer, so publishing asks for nothing. Giving it one means exporting the key and taking the account in again with a password.")
    }
}
