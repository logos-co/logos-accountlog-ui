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
                ContextChip { text: "logos:accounts:1" }
                // A count of nothing is not the same claim as no count: an
                // account whose log was never read has neither.
                Badge {
                    visible: root.store.resolved
                    text: Fmt.entries(root.store.entries.length)
                }
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
                Badge {
                    visible: root.store.observing
                    text: qsTr("Read only")
                }
            }

            HelpText {
                Layout.fillWidth: true
                body: root.store.managed
                      ? qsTr("Every entry in order. Nothing is deleted: a removal is an entry too.")
                      : qsTr("Every entry in order, exactly as the store serves it.")
            }
        }

        Meter {
            Layout.preferredWidth: 220
            // Not a size until the account's state has landed, and not one at
            // all where no log was read: an unread account is not an empty one.
            opacity: root.store.loading || !root.store.resolved ? 0 : 1
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
                  : root.store.reading === "unverified"
                  ? qsTr("Nothing is shown: the log the store served does not verify under this address.")
                  : root.store.reading === "forked"
                  ? qsTr("Nothing is shown: the store serves a log that does not extend the one already read.")
                  : root.store.reading === "unanswered"
                  ? qsTr("The store could not be read, so whether this account published anything is not known yet: %1")
                        .arg(root.store.storeProblem)
                  : root.store.reading === "unread"
                  ? qsTr("This account's log has not been read from the store yet.")
                  : !root.store.published && root.store.observing
                  ? qsTr("The store has nothing under this address.")
                  : !root.store.published
                  ? qsTr("Nothing published yet. This account has claimed no address in the store.")
                  : root.store.observing
                  ? qsTr("The store holds this address with an empty log.")
                  : qsTr("No entries yet. Every change appends one here, and nothing is ever taken out.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.palette.textTertiary
        }
        HelpText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            visible: root.store.reading === "unverified"
                     || (root.store.resolved && !root.store.loading)
            body: root.store.reading === "unverified"
                  ? qsTr("One signature covers the whole log, so none of it can be trusted in part.")
                  : root.store.published && root.store.observing
                  ? qsTr("The account was claimed by publishing, and has said nothing since.")
                  : root.store.published
                  ? qsTr("Publishing an empty log is still a publish: it claims the address.")
                  : root.store.observing
                  ? qsTr("Either the account has never published, or it publishes to a different store.")
                  : qsTr("The address is claimed by the first publish, and there is nothing to publish yet.")
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
        readAtMs: root.store.readAtMs
        onRetryRequested: root.store.backend.refresh()
    }

    PendingBar {
        Layout.fillWidth: true
        visible: root.store.managed
        store: root.store
        onPublishRequested: root.publishRequested()
    }

    // The foot of the log says what the next update will send. For an account
    // held elsewhere there is no next update, and saying so is what keeps the
    // panel from reading as one whose Publish button failed to draw.
    ColumnLayout {
        Layout.fillWidth: true
        visible: root.store.observing
        spacing: 2

        LogosText {
            text: qsTr("Nothing to publish here")
            textFormat: Text.PlainText
            font.weight: Theme.typography.weightMedium
            color: Theme.palette.textTertiary
        }
        HelpText {
            Layout.fillWidth: true
            body: qsTr("Writing this log needs this account's key, which is held somewhere else.")
        }
    }
}
