import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Set or change the name the account publishes. A rename appends one entry and
// leaves the name before it in the log, and this sheet says so before it
// stages it.
Sheet {
    property var store: null

    id: root
    objectName: "displayNameSheet"
    title: root.store.displayName !== "" ? qsTr("Change display name") : qsTr("Set display name")
    confirmText: qsTr("Save")
    confirmEnabled: root.bytes > 0 && root.bytes <= root.limit && !root.unchanged
                    && root.moving === 0
    backend: root.store.backend

    readonly property int limit: 64
    readonly property string name: field.text.trim()
    readonly property int bytes: Fmt.utf8Bytes(root.name)
    // A character the core refuses, since it could not be seen for what it is.
    readonly property int moving: Fmt.movesText(field.text)
    // The name already in force once the next publish lands: saving it again
    // would spend an entry to say nothing new.
    readonly property bool unchanged: root.name === root.store.displayName
    // The published name while another is staged: saving it drops the rename.
    readonly property bool reverting: root.store.renaming && root.name === root.store.publishedName
    readonly property int cost: root.store.costs.displayName + root.bytes

    function reset() {
        field.text = root.store.displayName
        field.field.forceActiveFocus()
    }

    onConfirmed: {
        root.send("stageSetDisplayName")
        store.backend.stageSetDisplayName(root.name)
    }
    onLanded: root.close()
    onCancelled: root.close()

    LogosText {
        Layout.fillWidth: true
        text: qsTr("Shown to others in place of the account's address. It is not unique and proves nothing; the address is the identity.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Theme.palette.textSecondary
    }

    Field {
        id: field
        objectName: "displayNameField"
        Layout.fillWidth: true
        label: qsTr("Display name")
        counter: qsTr("%1 / %2 bytes").arg(root.bytes).arg(root.limit)
        problem: root.moving > 0
                 ? qsTr("A display name cannot hold line breaks, control characters or text-direction overrides, and character %1 is one.")
                       .arg(root.moving)
                 : root.bytes > root.limit
                 ? qsTr("A display name is limited to %1 bytes of UTF-8.").arg(root.limit)
                 : field.text !== "" && root.bytes === 0
                 ? qsTr("A display name needs at least one visible character.")
                 : ""
        help: qsTr("Public and permanent: every name the account has used stays readable in its log.")
        onAccepted: root.submit()
        onTextChanged: root.problem = ""
    }

    HelpText {
        Layout.fillWidth: true
        visible: root.confirmEnabled || (root.unchanged && field.text !== root.store.displayName)
        body: root.unchanged
              ? qsTr("That is already the account's name, so there is nothing to save.")
              : root.reverting
              ? qsTr("Keeps the published name and drops the pending rename, so nothing is appended.")
              : root.store.publishedName !== ""
              ? qsTr("Appends %1 bytes. \"%2\", entry %3, stays in the log as a previous alias: the newest name is the one that counts.")
                    .arg(root.cost).arg(root.store.publishedName).arg(Fmt.index(root.store.nameIndex))
              : qsTr("Appends %1 bytes.").arg(root.cost)
    }
}
