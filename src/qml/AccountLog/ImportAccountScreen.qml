import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Take custody of an account made elsewhere. The secret arrives by hand, and
// the password asked for here is the one this vault will seal it with, not the
// one it had wherever it came from.
Item {
    property var store: null

    signal cancelled()

    id: root

    // A click makes the checkbox write its own `checked`, so the box is where
    // this choice lives and the screen reads it from there.
    readonly property bool withPassword: passwordBox.checked

    readonly property string secretHex: Fmt.hex(secret.text)
    readonly property bool secretValid: /^[0-9a-f]{64}$/.test(root.secretHex)
    readonly property bool valid: root.secretValid
                                  && (!withPassword
                                      || (password.text.length > 0
                                          && password.text === confirm.text))

    // Why the last import failed, in the backend's words.
    property string problem: ""

    function reset() {
        clear()
        secret.field.forceActiveFocus()
    }

    function clear() {
        passwordBox.checked = true
        showSecret.checked = false
        secret.text = ""
        password.text = ""
        confirm.text = ""
        problem = ""
    }

    function submit() {
        if (!root.valid || root.store.busy)
            return
        problem = ""
        root.store.backend.importAccount(root.secretHex, root.withPassword ? password.text : "")
    }

    // Neither the key nor its password is kept once the screen is left.
    onVisibleChanged: if (!visible) clear()

    Connections {
        target: root.store.backend
        ignoreUnknownSignals: true
        function onFailed(what, message) {
            if (what === "importAccount")
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
            text: qsTr("Import an account")
            textFormat: Text.PlainText
            font.pixelSize: Theme.typography.titleText
            font.weight: Theme.typography.weightBold
        }

        LogosText {
            Layout.fillWidth: true
            text: qsTr("Paste the 32-byte secret key of an account made elsewhere. Its address is derived from the key, so nothing else is asked for.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.palette.textSecondary
        }

        Field {
            id: secret
            objectName: "importSecretField"
            Layout.fillWidth: true
            label: qsTr("Secret key")
            placeholderText: qsTr("64 hex characters")
            echoMode: showSecret.checked ? TextInput.Normal : TextInput.Password
            mono: true
            problem: Fmt.hexProblem(secret.text, qsTr("An account key"))
            onAccepted: root.submit()
            onTextChanged: root.problem = ""
            help: qsTr("Exported from the module that held the account. Two modules holding one key can split its log, so forget it there once it lives here.")
        }

        LogosCheckbox {
            id: showSecret
            objectName: "importShowSecret"
            text: qsTr("Show the key")
        }

        LogosCheckbox {
            id: passwordBox
            Layout.topMargin: Theme.spacing.small
            text: qsTr("Protect this account with a password")
            checked: true
        }

        Field {
            id: password
            objectName: "importPasswordField"
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
            objectName: "importPasswordConfirmField"
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
            objectName: "importAccountProblem"
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
                objectName: "importAccountSubmit"
                text: qsTr("Import account")
                variant: LogosButton.Variant.Primary
                enabled: root.valid && !root.store.busy
                onClicked: root.submit()
            }
        }
    }
}
