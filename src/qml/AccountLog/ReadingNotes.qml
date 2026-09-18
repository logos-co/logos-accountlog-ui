import QtQuick
import QtQuick.Layouts

import Logos.Theme

// Three sentences, each saying something no badge on this screen can: what
// makes a key live, where a change goes before it is published, and what
// publishing will ask of this particular account.
ColumnLayout {
    property var store: null

    id: root
    spacing: Theme.spacing.small

    Eyebrow { label: qsTr("Reading this screen") }

    HelpText {
        Layout.fillWidth: true
        lead: qsTr("An installation is live ")
        body: qsTr("while no removal in the log points at its entry. A removed key stays in the log, dimmed, and can be added again as a new entry.")
    }

    HelpText {
        Layout.fillWidth: true
        lead: qsTr("Changes are staged ")
        body: qsTr("as pending entries at the end of the log, and published together as one update.")
    }

    HelpText {
        Layout.fillWidth: true
        lead: qsTr("Publishing ")
        body: root.store.isProtected
              ? qsTr("signs the whole log and sends it to the store. This account is password protected, so it asks for the password first.")
              : qsTr("signs the whole log and sends it to the store. This account has no password, so it publishes straight away.")
    }
}
