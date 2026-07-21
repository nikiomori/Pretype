import Foundation

/// Gemoji-style shortcodes (":shrug:" → 🤷) resolved without shipping a table.
///
/// Convention: **every string here carries its colons** — `trailingShortcode`
/// returns ":shrug:" and `emoji(for:)` takes ":shrug:". That keeps the token the
/// correction pill deletes (a count of typed characters) identical to the key we
/// looked up, with no stripping in between.
enum EmojiShortcodes {
    /// The closed shortcode sitting just before the caret, colons included, or
    /// nil. Mid-typing (":shru") stays silent by construction: only a trailing
    /// ":" starts the walk.
    static func trailingShortcode(in text: String) -> String? {
        guard text.hasSuffix(":") else { return nil }
        var body: [Character] = []
        var iter = text.dropLast().reversed().makeIterator()
        var opened = false
        // The character before the opening colon, once we find one.
        var preceding: Character?
        while let ch = iter.next() {
            if ch == ":" {
                opened = true
                preceding = iter.next()
                break
            }
            guard ch.isLetter || ch.isNumber || ch == "_" || ch == "+" || ch == "-" else { return nil }
            // Longest real Gemoji name is 30-odd chars; past that it's prose
            // between two colons, not a shortcode.
            guard body.count < 32 else { return nil }
            body.append(ch)
        }
        // No opening colon at all — a bare ":" or "http:".
        guard opened, body.count >= 2 else { return nil }
        let name = String(body.reversed())
        // Digits-only bodies are ratios and times, never names. "+1"/"-1" are
        // the two Gemoji codes with no letter in them — the only reason +/- are
        // in the charset above at all.
        guard body.contains(where: { $0.isLetter }) || name == "+1" || name == "-1" else { return nil }
        // A colon glued to the end of a word or number is a time ("10:30:"), a
        // ratio ("ratio3:4:") or code ("foo:bar:") — all of which must stay quiet.
        // A second colon means C++/Rust scope ("ns::member:"), never a shortcode.
        if let preceding, preceding.isLetter || preceding.isNumber || preceding == ":" { return nil }
        return ":" + name + ":"
    }

    /// The emoji for a shortcode, cheapest lookup first: the curated aliases,
    /// then the system's Unicode-name table.
    static func emoji(for shortcode: String) -> String? {
        if let known = aliases[shortcode] { return known }
        return viaUnicodeName(shortcode)
    }

    /// macOS already knows every Unicode character name, so most Gemoji codes
    /// resolve for free: `kCFStringTransformToUnicodeName` in REVERSE turns
    /// "\N{PILE OF POO}" back into 💩. ~2000 names work with nothing shipped.
    ///
    /// The raw transform also happily returns non-emoji lookalikes — "smile" is
    /// ⌣ U+2323, "sun" is ☉, "check_mark" is ✓, and single digits resolve — so
    /// the filter below (one scalar, above the symbol blocks, actually `isEmoji`)
    /// is what makes this usable rather than a source of typographic garbage.
    private static func viaUnicodeName(_ shortcode: String) -> String? {
        let name = shortcode.dropFirst().dropLast().replacingOccurrences(of: "_", with: " ").uppercased()
        let spelled = "\\N{" + name + "}"
        let buffer = NSMutableString(string: spelled) as CFMutableString
        guard CFStringTransform(buffer, nil, kCFStringTransformToUnicodeName, true) else { return nil }
        let out = buffer as String
        guard out != spelled, out.unicodeScalars.count == 1, let scalar = out.unicodeScalars.first,
              scalar.value > 0x1000, scalar.properties.isEmoji else { return nil }
        // Legacy dingbats (⚙ ✏ ✔) default to text presentation; VS16 makes them
        // render as the colour emoji the user was asking for.
        return scalar.properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
    }

    /// Only the codes people actually type that the Unicode-name table misses —
    /// Gemoji nicknames (":joy:", ":tada:") rather than character names.
    ///
    /// ponytail: curated aliases + the system table, so ~2000 names work without
    /// shipping Gemoji. If the full alias set is ever wanted, ship it as ONE
    /// newline-separated string literal parsed in a lazy static — a dictionary
    /// literal that size melts the type-checker.
    private static let aliases: [String: String] = [
        ":joy:": "😂", ":sob:": "😭", ":cry:": "😢", ":smile:": "😄", ":smiley:": "😃",
        ":grin:": "😁", ":laughing:": "😆", ":sweat_smile:": "😅", ":wink:": "😉",
        ":heart_eyes:": "😍", ":sunglasses:": "😎", ":thinking:": "🤔", ":smirk:": "😏",
        ":neutral_face:": "😐", ":upside_down:": "🙃", ":facepalm:": "🤦", ":hugs:": "🤗",
        ":star_struck:": "🤩", ":partying_face:": "🥳", ":party:": "🥳", ":exploding_head:": "🤯",
        ":angry:": "😠", ":rage:": "😡", ":poop:": "💩",
        ":thumbsup:": "👍", ":+1:": "👍", ":thumbsdown:": "👎", ":-1:": "👎",
        ":ok_hand:": "👌", ":pray:": "🙏",
        ":clap:": "👏", ":wave:": "👋", ":muscle:": "💪", ":raised_hands:": "🙌",
        ":point_right:": "👉", ":point_left:": "👈", ":fingers_crossed:": "🤞", ":salute:": "🫡",
        ":heart:": "❤️", ":boom:": "💥", ":zap:": "⚡️", ":dizzy:": "💫", ":zzz:": "💤",
        ":tada:": "🎉", ":warning:": "⚠️", ":star:": "⭐️", ":white_check_mark:": "✅",
        // No ":x:": the ≥2-character body guard (pinned by the tests) rejects it,
        // and ❌ already resolves natively as ":cross_mark:".
        ":link:": "🔗", ":target:": "🎯", ":bulb:": "💡", ":robot:": "🤖",
        ":alien:": "👽", ":gem:": "💎", ":moon:": "🌙", ":sun:": "☀️", ":scissors:": "✂️",
        ":coffee:": "☕️", ":beer:": "🍺", ":pizza:": "🍕", ":apple:": "🍎", ":cake:": "🍰",
        ":laptop:": "💻", ":house:": "🏠", ":car:": "🚗", ":email:": "📧", ":telephone:": "☎️",
        ":mute:": "🔇", ":loudspeaker:": "📢", ":basketball:": "🏀", ":medal:": "🏅",
        ":gift:": "🎁", ":checkered_flag:": "🏁", ":puzzle:": "🧩", ":dice:": "🎲",
        ":chart_increasing:": "📈", ":chart_decreasing:": "📉",
        ":arrow_up:": "⬆️", ":arrow_down:": "⬇️", ":arrow_right:": "➡️", ":arrow_left:": "⬅️",
    ]
}
