import QtQuick
import QtQuick.Layouts

import Logos.Theme

// Sentences that each say something no badge on this screen can: what a
// section above is, and where a change goes before it is published.
//
// For an account this module only reads, three about the reading instead: what
// the signature covers, whose draft this is not, and what observing costs the
// account being observed.
ColumnLayout {
    property var store: null

    id: root
    spacing: Theme.spacing.small

    Eyebrow { label: qsTr("Reading this screen") }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.managed
        lead: qsTr("A section is a namespace ")
        body: qsTr("in the account's log. The account above owns all of them; each section writes only its own contexts.")
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.managed
        lead: qsTr("Changes are staged ")
        body: qsTr("as pending entries at the end of the log, and published together as one update.")
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.observing
        lead: qsTr("The whole log is verified ")
        body: qsTr("under the address above: one signature covers every entry, so a log that does not verify is refused entire rather than in part.")
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.observing
        lead: qsTr("This is what the store serves, ")
        body: qsTr("not what any holder has drafted. A holder that has not published yet looks exactly like one that has nothing to say.")
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.observing
        lead: qsTr("Observing takes no key ")
        body: qsTr("and sends none. This module can stop at any time, and the account never learns either way.")
    }
}
