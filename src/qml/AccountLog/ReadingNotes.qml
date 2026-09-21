import QtQuick
import QtQuick.Layouts

import Logos.Theme

// Three sentences, each saying something no badge on this screen can: what
// makes a key live, where a change goes before it is published, and what
// publishing will ask of this particular account.
//
// For an account this module only reads, the three are about the reading
// instead: what the signature covers, whose draft this is not, and what
// observing costs the account being observed.
ColumnLayout {
    property var store: null

    id: root
    spacing: Theme.spacing.small

    Eyebrow { label: qsTr("Reading this screen") }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.managed
        lead: qsTr("An installation is live ")
        body: qsTr("while no removal in the log points at its entry. A removed key stays in the log, dimmed, and can be added again as a new entry.")
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.managed
        lead: qsTr("Changes are staged ")
        body: qsTr("as pending entries at the end of the log, and published together as one update.")
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.store.managed
        lead: qsTr("Publishing ")
        body: root.store.isProtected
              ? qsTr("signs the whole log and sends it to the store. This account is password protected, so it asks for the password first.")
              : qsTr("signs the whole log and sends it to the store. This account has no password, so it publishes straight away.")
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
