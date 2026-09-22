import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Make a key on this computer. The password is optional per account, and the
// warning changes with it, because the two choices carry different risks and
// only one of them can be undone.
Item {
    property var store: null

    signal cancelled()

    id: root

    // A click makes the checkbox write its own `checked`, so the box is where
    // this choice lives and the screen reads it from there.
    readonly property bool withPassword: passwordBox.checked

    readonly property bool valid: !withPassword
                                  || (password.text.length > 0 && password.text === confirm.text)

    // Why the last create failed, in the backend's words.
    property string problem: ""

    function reset() {
        passwordBox.checked = true
        password.text = ""
        confirm.text = ""
        problem = ""
        password.field.forceActiveFocus()
    }

    function submit() {
        if (!root.valid || root.store.busy)
            return
        problem = ""
        root.store.backend.createAccount(root.withPassword ? password.text : "")
    }

    // The password is not kept once the screen is left.
    onVisibleChanged: if (!visible) reset()

    Connections {
        target: root.store.backend
        ignoreUnknownSignals: true
        function onFailed(what, message) {
            if (what === "createAccount")
                root.problem = message
        }
    }

    Panel {
        anchors.centerIn: parent
        width: Math.min(640, parent.width - 48)
        padding: Theme.spacing.xxlarge
        horizontalPadding: Theme.spacing.xxlarge
        spacing: Theme.spacing.medium

        LogosText {
            Layout.fillWidth: true
            text: qsTr("Create an account")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.titleText
            font.weight: Theme.typography.weightBold
        }

        LogosText {
            Layout.fillWidth: true
            text: qsTr("An account is a key made on this computer. Its address is the key's public half, and every entry in its log is signed with it.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.palette.textSecondary
        }

        LogosText {
            Layout.fillWidth: true
            text: qsTr("A password seals the key on this computer. The account stays unlocked until the app closes, and after that the password opens it once per session.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.palette.textSecondary
        }

        LogosCheckbox {
            id: passwordBox
            Layout.topMargin: Theme.spacing.small
            text: qsTr("Protect this account with a password")
            checked: true
        }

        Field {
            id: password
            objectName: "createPasswordField"
            Layout.fillWidth: true
            enabled: root.withPassword
            opacity: root.withPassword ? 1 : 0.5
            label: qsTr("Password")
            echoMode: TextInput.Password
            onAccepted: root.submit()
            onTextChanged: root.problem = ""
        }

        Field {
            id: confirm
            objectName: "createPasswordConfirmField"
            Layout.fillWidth: true
            enabled: root.withPassword
            opacity: root.withPassword ? 1 : 0.5
            label: qsTr("Confirm password")
            echoMode: TextInput.Password
            problem: root.withPassword && confirm.text.length > 0
                     && password.text !== confirm.text
                     ? qsTr("The two do not match.") : ""
            onAccepted: root.submit()
            onTextChanged: root.problem = ""
        }

        NoticeBar {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.small
            dismissable: false
            tone: "warning"
            title: root.withPassword
                   ? qsTr("A lost password loses the account key")
                   : qsTr("Without a password the key is stored unsealed")
            body: root.withPassword
                  ? qsTr("The key is kept only in this vault. An account key cannot be recovered or rotated, so without it no entry can be signed for this address again.")
                  : qsTr("Anything that can read this computer's files can read the key and write this account's log. Convenient for a demo, wrong for an account that matters.")
        }

        HelpText {
            objectName: "createAccountProblem"
            Layout.fillWidth: true
            visible: root.problem !== ""
            body: root.problem
            color: Theme.palette.error
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.small
            spacing: Theme.spacing.small

            LogosButton {
                text: qsTr("Back")
                onClicked: root.cancelled()
            }
            Item { Layout.fillWidth: true }
            LogosButton {
                objectName: "createAccountSubmit"
                text: qsTr("Create account")
                variant: LogosButton.Variant.Primary
                enabled: root.valid && !root.store.busy
                onClicked: root.submit()
            }
        }
    }
}
