import QtQuick

import Logos.Theme
import Logos.Controls

// A line of explanation under a control. `lead` is the clause the sentence
// turns on, set in the body colour so the eye finds it before reading the rest.
LogosText {
    property string lead: ""
    property string body: ""

    id: root
    text: lead === ""
          ? body
          : "<b>" + lead + "</b>" + body
    // The only place in this app that is not PlainText, and it renders markup
    // this file wrote, never a value from the log or the store.
    textFormat: lead === "" ? Text.PlainText : Text.StyledText
    wrapMode: Text.Wrap
    font.pixelSize: Theme.typography.secondaryText
    color: Theme.palette.textSecondary
    lineHeight: 1.35
}
