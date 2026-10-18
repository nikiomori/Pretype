import Foundation

/// The journal record of the suggestion on screen, from the moment it is
/// offered to the moment it resolves — what `Stats` books and the local
/// journal stores (`SuggestionJournal`). Pure: the controller opens it, keeps
/// it current, and books what `resolve` hands back. OfferRecordTests pin it.
struct OfferRecord {
    /// The record, and when its suggestion first showed. The entry's `app` is
    /// captured at show time: resolution can arrive after focus has already
    /// moved (an `.abandoned` on app switch), and the typing context names the
    /// NEW app by then — booking the offer, or journaling it, against that one
    /// blames the wrong app.
    private var current: (entry: SuggestionJournal.Entry, shownAt: Date)?

    var isOpen: Bool { current != nil }

    /// A fresh offer, first shown at `now`. The timestamp, outcome, shown time
    /// and logprob are stamped when it resolves; its ctx is capped then too.
    mutating func open(_ entry: SuggestionJournal.Entry, at now: Date) {
        current = (entry, now)
    }

    /// The ghost now shows `remaining` at `text` — streamed growth of the same
    /// suggestion, or trimmed to the line.
    mutating func showing(_ remaining: String, at text: String) {
        guard let ctx = current?.entry.ctx else { return }
        current?.entry.suggestion = Self.journalSuggestion(remaining, current: text, recordCtx: ctx)
    }

    mutating func accepted(_ chunk: String) {
        current?.entry.acceptedChars += chunk.count
    }

    /// Close the record with `outcome` at `now`, given what the ghost on
    /// screen still shows. Returns the entry stamped with its outcome, how long
    /// it showed and how much of it the user took — nil when none was open, so
    /// the first resolution wins (the `dismiss()` after an Escape finds
    /// nothing). A `superseded` record takes nothing from the screen: the
    /// ghost there is already the newer one.
    mutating func resolve(_ outcome: SuggestionJournal.Outcome, ghost: String?,
                          at now: Date) -> SuggestionJournal.Entry? {
        guard let (shown, shownAt) = current else { return nil }
        current = nil
        var entry = shown
        entry.outcome = outcome
        entry.shownForMs = Int(now.timeIntervalSince(shownAt) * 1000)
        if outcome != .superseded, let ghost {
            entry.consumedChars = Self.consumedChars(outcome: outcome, offered: entry.suggestion, remaining: ghost)
        }
        return entry
    }

    /// The record's suggestion for a ghost now showing `remaining` at
    /// `current`: what was typed since the record's `ctx`, then `remaining` —
    /// a stream that re-anchors after the user typed hands over only the rest,
    /// and storing that alone made `ctx + suggestion` text nobody was offered.
    static func journalSuggestion(_ remaining: String, current: String, recordCtx: String?) -> String {
        guard let recordCtx, current.hasPrefix(recordCtx) else { return remaining }
        return String(current.dropFirst(recordCtx.count)) + remaining
    }

    /// How much of the offered suggestion the user took before it resolved.
    /// Accepted / typed-through took all of it; otherwise what is no longer on
    /// screen (the record holds the whole offer, `remaining` the rest).
    static func consumedChars(outcome: SuggestionJournal.Outcome, offered: String, remaining: String) -> Int {
        outcome == .accepted || outcome == .typedThrough
            ? offered.count : max(0, offered.count - remaining.count)
    }
}
