import QtQuick

import Logos.Theme
import Logos.Controls

// A LogosButton sized for dense rows: 72x32 floors and tighter padding. This is
// the design system's own `compact`, spelled out, since the design system
// basecamp 0.3.0 ships predates it.
LogosButton {
    implicitWidth: Math.max(72, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(32, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Theme.spacing.medium
    rightPadding: Theme.spacing.medium
    topPadding: Theme.spacing.small
    bottomPadding: Theme.spacing.small
}
