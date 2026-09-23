pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The profile namespace: what the account publishes about itself. A name is
// current because it is the newest live one, not because the others were
// removed, so the names before it are listed as the aliases they are.
Panel {
    property var store: null

    signal renameRequested()

    id: root
    padding: 14
    horizontalPadding: 18
    spacing: Theme.spacing.small

    // Why the account has no name on screen, which for an observed account is
    // usually a fact about the read rather than about the account.
    readonly property string noName: {
        if (root.store.reading === "unread")
            return qsTr("Not read yet")
        if (root.store.reading === "unverified")
            return qsTr("Not shown: the log did not verify")
        if (root.store.reading === "forked")
            return qsTr("Not shown: the store serves a second history")
        if (root.store.reading === "unanswered")
            return qsTr("Not read: the store did not answer")
        if (!root.store.published)
            return qsTr("Nothing published under this address")
        return qsTr("Not set")
    }

    // A staged rename leaves the published name in the log, so it joins the
    // earlier ones instead of disappearing.
    readonly property bool retiring: root.store.renaming && root.store.publishedName !== ""
    readonly property int aliases: root.store.previousNames.length + (root.retiring ? 1 : 0)

    component Alias: ColumnLayout {
        property int entryIndex: -1
        property string name: ""
        property bool current: false
        property bool last: false

        id: aliasRow
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            spacing: 10

            LogosText {
                text: Fmt.index(aliasRow.entryIndex)
                textFormat: Text.PlainText
                font.family: Theme.typography.mono
                font.pixelSize: 11
                color: Theme.palette.textTertiary
            }
            LogosText {
                Layout.fillWidth: true
                text: aliasRow.name
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.pixelSize: Theme.typography.secondaryText
                color: Theme.palette.textSecondary
            }
            Badge {
                visible: aliasRow.current
                text: qsTr("Current until published")
            }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            visible: !aliasRow.last
            color: Theme.palette.borderTertiaryMuted
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        LogosText {
            text: qsTr("Profile")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
        }
        ContextChip { text: "profile" }
        Item { Layout.fillWidth: true }
        CompactButton {
            objectName: "displayNameButton"
            visible: root.store.managed
            text: root.store.displayName !== "" ? qsTr("Change name") : qsTr("Set a name")
            enabled: !root.store.busy
            onClicked: root.renameRequested()
        }
    }

    HelpText {
        Layout.fillWidth: true
        body: root.store.managed
              ? qsTr("What the account publishes about itself, for anything that displays it.")
              : qsTr("What the account publishes about itself, for anything that displays it, as the store last served it.")
    }

    Subsection {
        Layout.fillWidth: true
        Layout.topMargin: 2
        label: qsTr("Display name")
        context: "profile.displayname"
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.minimumHeight: 28
        spacing: 10

        LogosText {
            readonly property bool named: root.store.displayName !== ""

            Layout.fillWidth: true
            Layout.maximumWidth: Math.ceil(implicitWidth)
            text: named ? root.store.displayName : root.noName
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.pixelSize: named ? Theme.typography.subtitleText : Theme.typography.primaryText
            font.weight: named ? Theme.typography.weightMedium : Theme.typography.weightRegular
            color: root.store.renaming ? Theme.palette.primary
                 : named ? Theme.palette.text
                 : Theme.palette.textTertiary
        }
        Badge {
            visible: root.store.renaming
            tone: "pending"
            text: qsTr("Pending")
        }
        LogosText {
            visible: !root.store.renaming && root.store.nameIndex >= 0
            text: qsTr("entry %1").arg(Fmt.index(root.store.nameIndex))
            textFormat: Text.PlainText
            font.family: Theme.typography.mono
            font.pixelSize: 11
            color: Theme.palette.textTertiary
        }
        Item { Layout.fillWidth: true }
    }

    Subsection {
        Layout.fillWidth: true
        Layout.topMargin: 2
        visible: root.aliases > 0
        label: qsTr("Previous names · %1").arg(root.aliases)
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: root.aliases > 0
        spacing: 0

        Alias {
            Layout.fillWidth: true
            visible: root.retiring
            entryIndex: root.store.nameIndex
            name: root.store.publishedName
            current: true
            last: root.store.previousNames.length === 0
        }
        Repeater {
            model: root.store.previousNames

            delegate: Alias {
                required property var modelData
                required property int index

                Layout.fillWidth: true
                entryIndex: modelData.index
                name: modelData.value
                last: index === root.store.previousNames.length - 1
            }
        }
    }

    HelpText {
        Layout.fillWidth: true
        body: root.retiring
              ? qsTr("Appended as a new entry when published. %1 stays in the log and becomes a previous alias.")
                    .arg(Fmt.index(root.store.nameIndex))
              : root.store.renaming && root.store.resolved
              ? qsTr("The account's first name, when published.")
              : root.store.renaming
              ? qsTr("Takes effect when published.")
              : root.store.resolved
              ? qsTr("The newest entry under this context is the name. The ones before it stay live and readable, which is what an account's earlier aliases are.")
              : qsTr("A name comes out of the log, and there is no log here to read one from.")
    }
}
