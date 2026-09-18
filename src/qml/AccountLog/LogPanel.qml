import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The log, whole: what the store serves plus what this module has staged on
// top of it, the budget it has spent, and the one button that sends it.
Panel {
    property var store: null
    property int selectedIndex: -1
    property int firstNewIndex: -1

    signal selected(int index)
    signal publishRequested()

    id: root
    spacing: Theme.spacing.medium

    // The table's own budget, carried up to the window: the log is the only
    // thing on this screen whose columns have a right answer, so it is the one
    // that states a width and the column beside it that gives way.
    Layout.minimumWidth: table.minimumWidth + root.horizontalPadding * 2

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.large

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            RowLayout {
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("Log")
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                }
                Badge { text: Fmt.entries(root.store.entries.length) }
                Badge {
                    visible: root.store.pending.length > 0
                    tone: "pending"
                    text: qsTr("+%1 pending").arg(root.store.pending.length)
                }
                Badge {
                    visible: root.store.unreadable !== ""
                    tone: "error"
                    text: qsTr("Partly unreadable")
                }
            }

            HelpText {
                Layout.fillWidth: true
                body: qsTr("Every entry in order. Nothing is deleted: a removal is an entry too.")
            }
        }

        Meter {
            Layout.preferredWidth: 220
            // Not a size until the account's state has landed.
            opacity: root.store.loading ? 0 : 1
            used: root.store.logBytes
            limit: root.store.maxBytes
        }
    }

    NoticeBar {
        Layout.fillWidth: true
        visible: root.store.unreadable !== ""
        dismissable: false
        tone: "warning"
        title: qsTr("This log holds an entry this build cannot read")
        body: qsTr("Only the entries this app knows are shown, and nothing can be published: re-signing a log means re-signing bytes it cannot interpret.")
    }

    // An update that stages no entry is refused by the core, so the address is
    // claimed by the log's first entry and never by an empty publish.
    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.large
        Layout.bottomMargin: Theme.spacing.large
        visible: root.store.entries.length === 0 && root.store.pending.length === 0
        spacing: Theme.spacing.tiny

        // "Nothing published" is the store's answer, so it is said only once
        // the store has given one.
        LogosText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: root.store.loading
                  ? qsTr("Reading this account.")
                  : !root.store.resolved && root.store.storeProblem !== ""
                  ? qsTr("The store could not be read, so whether this account published anything is not known yet: %1")
                        .arg(root.store.storeProblem)
                  : !root.store.resolved
                  ? qsTr("This account's log has not been read from the store yet.")
                  : root.store.published
                  ? qsTr("No entries yet. Every change appends one here, and nothing is ever taken out.")
                  : qsTr("Nothing published yet. This account has claimed no address in the store.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.palette.textTertiary
        }
        HelpText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            visible: root.store.resolved && !root.store.published
            body: qsTr("The address is claimed by the first publish, and there is nothing to publish yet.")
        }
    }

    // Holds the header at the top while there is no table to fill the panel.
    Item {
        Layout.fillHeight: true
        visible: !scroller.visible
    }

    // The log is capped at 128 KiB, not at a screenful: a log that outgrows the
    // panel scrolls, and the foot below stays where it is.
    LogosScrollView {
        id: scroller
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.store.entries.length > 0 || root.store.pending.length > 0
        // Pinned where there is something to scroll, as the left column does:
        // a bar hidden at rest hides the pending rows under the fold.
        ScrollBar.vertical.policy: scroller.ScrollBar.vertical.size < 1
                                   ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded

        LogTable {
            id: table
            width: scroller.availableWidth
            store: root.store
            selectedIndex: root.selectedIndex
            firstNewIndex: root.firstNewIndex
            onSelected: (index) => root.selected(index)
        }
    }

    NoticeBar {
        Layout.fillWidth: true
        visible: root.store.backend.noticeKind !== ""
        tone: root.store.backend.noticeKind
        title: root.store.backend.noticeTitle
        body: root.store.backend.noticeBody
        onDismissed: root.store.backend.dismissNotice()
    }

    StoreStrip {
        Layout.fillWidth: true
        url: root.store.backend.storeUrl
        address: root.store.address
        tone: root.store.storeProblem !== "" ? "dead"
            : !root.store.published ? "wait"
            : "ok"
        say: root.store.backend.statusText
        problem: root.store.storeProblem
        busy: root.store.busy
        onRetryRequested: root.store.backend.refresh()
    }

    PendingBar {
        Layout.fillWidth: true
        store: root.store
        onPublishRequested: root.publishRequested()
    }
}
