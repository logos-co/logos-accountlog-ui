import QtQuick

import Logos.Theme
import Logos.Controls

// The small caps-ish label above a block. One type so the whole app agrees on
// what a section heading looks like.
LogosText {
    property alias label: root.text

    id: root
    textFormat: Text.PlainText
    font.pixelSize: Theme.typography.secondaryText
    font.weight: Theme.typography.weightMedium
    color: Theme.palette.textTertiary
}
