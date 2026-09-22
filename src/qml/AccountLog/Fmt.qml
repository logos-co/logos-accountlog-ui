pragma Singleton

import QtQuick

// The formatting rules the whole app shares, in one place so a log cannot be
// numbered one way in the table and another way in the sentence beside it.
QtObject {
    // The account log's own lifetime budget, from the format: 128 KiB. The
    // backend reports it per account too; this is the fallback for a screen
    // drawn before any account has been read.
    readonly property int maxBytes: 131072

    // First `keep` characters, then the last `keep`. What the mockup calls
    // mid(): an address or a key is recognised by both ends, never by the
    // middle, and eliding in the middle is what keeps both on screen.
    function mid(text, keep) {
        if (!text)
            return ""
        return text.length <= keep * 2 + 1
            ? text
            : text.substring(0, keep) + "…" + text.substring(text.length - keep)
    }

    function bytes(count) {
        if (count === undefined || count === null)
            return "0 B"
        return count < 1024 ? count + " B" : (count / 1024).toFixed(1) + " KiB"
    }

    // "1 entry" / "8 entries". Written out rather than appending an s, because
    // every plural in this app is one of these two and a wrong one reads as a
    // bug in the log rather than in the sentence.
    function plural(count, one, many) {
        return count + " " + (count === 1 ? one : many)
    }

    function entries(count) {
        return plural(count, "entry", "entries")
    }

    // How long ago `ms` was: a read is either recent enough to be measured in
    // minutes or old enough that the clock time is what matters. `now` is
    // passed in rather than read here, since a binding cannot depend on a
    // clock that no property changes.
    function since(ms, now) {
        var seconds = Math.max(0, Math.round((now - ms) / 1000))
        if (seconds < 90)
            return qsTr("just now")
        var minutes = Math.round(seconds / 60)
        if (minutes < 60)
            return plural(minutes, qsTr("minute ago"), qsTr("minutes ago"))
        var hours = Math.round(minutes / 60)
        if (hours < 24)
            return plural(hours, qsTr("hour ago"), qsTr("hours ago"))
        return qsTr("at %1").arg(new Date(ms).toLocaleString(Qt.locale(), Locale.ShortFormat))
    }

    // `#7`: the index a revocation targets, in the one spelling the whole app
    // uses for it.
    function index(value) {
        return "#" + value
    }

    // `130,631`: the budget is a number to read, not to count digits in.
    function count(value) {
        return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    }

    // A pasted key the way the core reads one: without the spaces a copy picks
    // up, without a 0x prefix, in lowercase.
    function hex(text) {
        return (text || "").replace(/\s+/g, "").replace(/^0x/i, "").toLowerCase()
    }

    // Why `text` through hex() is not 64 hex characters, or "" when it is. A
    // stray character is counted in `text` as typed, where the person looks
    // for it. `noun` is what the key is called: "An account key".
    function hexProblem(text, noun) {
        var key = hex(text)
        if (key === "")
            return ""
        var bad = key.search(/[^0-9a-f]/)
        if (bad >= 0) {
            var seen = /^0x/i.test(text.replace(/\s+/g, "")) ? -2 : 0
            for (var i = 0; i < text.length; ++i) {
                if (/\s/.test(text.charAt(i)))
                    continue
                if (seen++ === bad)
                    return qsTr("%1 holds only 0-9 and a-f, and character %2 is \"%3\".")
                               .arg(noun).arg(i + 1).arg(text.charAt(i))
            }
        }
        if (key.length !== 64)
            return qsTr("%1 is 64 hex characters, and this one is %2.").arg(noun).arg(key.length)
        return ""
    }

    // Where `text` holds a character that breaks a line or turns the text
    // around it, which the core refuses in a name: its position, counted in
    // characters from 1, or 0 when there is none.
    function movesText(text) {
        var chars = Array.from(text || "")
        for (var i = 0; i < chars.length; ++i)
            if (/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/.test(chars[i]))
                return i + 1
        return 0
    }

    // The log charges UTF-8 bytes, not characters, so a name is counted the way
    // the format will count it. Every escape from encodeURIComponent is one
    // byte, written as %XX.
    function utf8Bytes(text) {
        if (!text)
            return 0
        return encodeURIComponent(text).replace(/%[0-9A-F]{2}/g, "b").length
    }
}
