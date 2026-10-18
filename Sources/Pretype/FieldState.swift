import ApplicationServices
import Foundation

/// What the completion pipeline believes about the focused field between AX
/// reads — the text before the caret, where the caret is and how the field
/// draws there, the ghost offered on it, the settle window after a synthetic
/// edit, the ⎋/⌘Z decline, the ⌘Z record, the field the tracker missed and
/// the dead-handle probe's throttle — and every rule that moves them. Pure: the
/// controller reads the field, draws, types and journals, and asks this what
/// each event means. FieldStateTests pin the rules on their own.
struct FieldState {
    /// A suggestion on screen.
    struct Ghost {
        /// Text before the caret at the moment the suggestion became valid.
        var anchor: String
        /// Text after the caret when it was shown (typing at the caret leaves
        /// it be) — with `anchor`, the field a ⎋ declines.
        var after = ""
        /// Remaining (not yet accepted) suggestion text.
        var text: String
        /// Already counted as an accepted suggestion, so accepting word-by-word
        /// counts once (not once per word). Carried across streamed growth;
        /// reset only when a fresh suggestion is offered.
        var accepted = false
        /// false for a composed reply: shown whole — in the pill when it
        /// doesn't fit the line — never trimmed to the line like a completion.
        var trimToLine = true
        /// From the personal n-gram fast-path (shown instantly, before the LLM
        /// answers). The LLM stream supersedes it via the normal `apply` path;
        /// its *abstain* must not hide it though — a confident personal phrase
        /// beats showing nothing.
        var isInstant = false
    }

    struct Undoable {
        let chunk: String
        /// The cache exactly as it read right after the chunk landed. ⌘Z-undo
        /// is offered only while the field still reads like this — a
        /// same-field mouse click can land the caret after identical text, so
        /// a bare "ends with the chunk" check would delete the wrong occurrence.
        let snapshot: String
        /// SPOKEN rather than suggested. The undo path books its chunk into
        /// the debug log, the Diagnostics line and the journal — all three
        /// fine for a suggestion the model produced, none of them allowed to
        /// hold a dictated sentence (`docs/privacy.md`: the transcript is
        /// redacted from the log and never journaled).
        let dictated: Bool
    }

    /// The text before the caret as last known: set by every field read,
    /// moved by every key the tap passes on and every synthetic edit, nil when
    /// unknown. Lets a streamed partial and the ⌘Z gate tell — without an AX
    /// read, which the key tap can't afford — whether the field moved since.
    var cache: String?
    /// The caret rect of the latest read or side-flow measure — shared by the
    /// completion overlay, the indicator and the correction previews — nil
    /// when unknown (a new field; a scroll moved it).
    private(set) var caret: CGRect?
    /// The field's style at that caret, refreshed with it on every read. The
    /// indicator's shows (thinking dots, status, transients) pass it so they
    /// carry measured, current evidence — the dots decide ghost-vs-pill on
    /// `textFollowsCaret`, and the window's own remembered style can be many
    /// keystrokes stale while no suggestion is live.
    private(set) var style = HostTextStyle()
    /// The field the system reported focused when the tracker had none, and
    /// the site read for it — once per field (`foundUntracked`).
    private(set) var untracked: (element: AXUIElement, site: String?)?
    var ghost: Ghost?
    /// The last chunk typed into the field — an accepted suggestion or a
    /// dictation — while ⌘Z can still take it back. Any other keystroke
    /// clears it.
    var undoable: Undoable?
    /// While in the future, a synthetic edit is still landing in the target
    /// app, and the cache is the authority over a read that disagrees.
    private(set) var settleDeadline: Date?
    /// The field (before/after the caret) whose ghost ⎋ dropped or ⌘Z undid.
    /// Nothing is offered there again until it changes: an AX notification
    /// that leaves the text alone (React re-setting the value, a mention popup
    /// closing) re-ran the pipeline, which re-drew the declined ghost from the
    /// n-gram and queried the model for it again.
    private(set) var declined: (before: String, after: String)?
    /// The tracked handle a nil read last probed for liveness, when, and
    /// whether the app answered fast (`admit`).
    private var probed: (element: AXUIElement, at: Date, fast: Bool)?

    var isDeclined: Bool { declined != nil }

    func isSettling(at now: Date) -> Bool { settleDeadline.map { now < $0 } ?? false }

    // MARK: - Reads

    enum Admission {
        /// The read is the field now.
        case taken(TextContext)
        /// Read again shortly: the read trails a synthetic edit still
        /// landing, or the handle had died and was re-latched.
        case retry
        /// Nothing readable: the field is gone, or can't be read right now.
        case lost
    }

    /// A pass's read of `element`, and what it means.
    ///
    /// While an edit settles, a read that disagrees with the cache trails the
    /// synthetic keys (worst in Electron): taking it would regress the cache,
    /// re-query a stale prompt and re-offer — or resurrect — the just-accepted
    /// or undone text. The deadline bounds the wait. A read taken becomes the
    /// cache, and any edit or caret move ends a decline.
    ///
    /// A nil read may be a node the app replaced under the caret: `probe`
    /// asks whether the handle died, re-latching it when it did — nil where
    /// that round trip isn't worth it (a terminal; a handle the tracker
    /// doesn't hold). `clock` times it: see `mayProbe`.
    mutating func admit(_ read: TextContext?, of element: AXUIElement,
                        probe: (() -> Bool)?, clock: () -> Date) -> Admission {
        let now = clock()
        guard let read else {
            guard let probe, mayProbe(element, at: now) else { return .lost }
            let dead = probe()
            probed = (element, now, fast: clock().timeIntervalSince(now) < Self.fastProbe)
            return dead ? .retry : .lost
        }
        // An app that answered its last probe fast may probe again on the next
        // nil read; one that answered slowly keeps its second's wait.
        if probed?.fast == true { probed = nil }
        if let deadline = settleDeadline {
            if now < deadline, let cache, cache != read.textBeforeCaret { return .retry }
            settleDeadline = nil
        }
        cache = read.textBeforeCaret
        if let declined, declined.before != read.textBeforeCaret || declined.after != read.textAfterCaret {
            self.declined = nil
        }
        return .taken(read)
    }

    // MARK: - The caret

    /// A read or a side flow measured the caret, and the style there.
    mutating func noteCaret(_ rect: CGRect?, style: HostTextStyle) {
        caret = rect
        self.style = style
    }

    /// A side flow measured where its text is (a selection, the word at the caret).
    mutating func noteCaret(_ rect: CGRect) { caret = rect }

    /// Adopt `rect` only when the caret was forgotten (`forgetCaret`): a fix
    /// that lands after a scroll is drawn at its text, not under the pointer.
    mutating func recoverCaret(_ rect: CGRect?) {
        if caret == nil { caret = rect }
    }

    /// The view scrolled under a reply or fix in flight: the caret, and the
    /// text before it, are wherever the next read says.
    mutating func forgetCaret() {
        caret = nil
        cache = nil
    }

    // MARK: - The field the tracker missed

    /// The system reports `element` focused where the tracker holds none.
    /// Its site is read once per field (`pageHost`, an ancestor walk) and
    /// only when the tracker read none (`trackerSite`) — a site switched off
    /// must not fall through to the app check. Returns the element.
    mutating func foundUntracked(_ element: AXUIElement, trackerSite: String?,
                                 pageHost: (AXUIElement) -> String?) -> AXUIElement {
        if untracked?.element != element { untracked = (element, trackerSite == nil ? pageHost(element) : nil) }
        return element
    }

    /// A read made outside `admit` — the reply's own, of an empty chat box the
    /// pipeline's read refuses — becomes the cache, so a result asked for on
    /// it lands without another read and an accept advances from it.
    mutating func adoptRead(_ before: String) { cache = before }

    /// Faster than this, a probe answered rather than waited out its timeout.
    static let fastProbe = TimeInterval(FocusTracker.axMessagingTimeout) / 2

    /// A nil read of `element` may pay for a liveness probe, one more AX round
    /// trip that a hung app answers only with its timeout — on the main
    /// thread, where the key tap runs. Once a second per handle; at once for
    /// a handle not probed yet, or one whose fast probe was followed by a read
    /// it answered: a node replaced right after a legitimate nil read (an IME
    /// composition, an empty web field) must still be re-latched. An app
    /// whose reads keep timing out, or alternate with timeouts, answers its
    /// probes slowly and so pays at most one a second.
    private func mayProbe(_ element: AXUIElement, at now: Date) -> Bool {
        guard let probed, probed.element == element else { return true }
        return now.timeIntervalSince(probed.at) > 1
    }

    enum Anchor {
        case context(TextContext)
        /// An edit is still settling: every anchor in reach, the cache or a
        /// read, predates or trails its synthetic keys, and narrowing a result
        /// against one resurrects the just-accepted word. The refresh after
        /// the settle re-streams from the true context.
        case settling
        /// The read trails a key the tap already saw ("hel" read, "hell"
        /// cached): anchoring there would let ⇥ type the "l" twice. The
        /// keystroke's own refresh follows.
        case trailing
        case unreadable
    }

    /// Where an engine result asked for on `cached` lands. The cached context
    /// holds while the cache says nothing was typed since — the cheap compare
    /// spares a synchronous AX read per streamed partial — and otherwise
    /// `read` is the field now, made only then.
    func anchor(cached: TextContext?, read: () -> TextContext?, at now: Date) -> Anchor {
        if isSettling(at: now) { return .settling }
        if let cached, cached.textBeforeCaret == cache { return .context(cached) }
        guard let fresh = read() else { return .unreadable }
        if let cache, cache.count > fresh.textBeforeCaret.count, cache.hasPrefix(fresh.textBeforeCaret) {
            return .trailing
        }
        return .context(fresh)
    }

    // MARK: - The ghost

    /// Show `text` as the ghost at `before`|`after`. `fresh`: a new offer —
    /// otherwise streamed growth of the one up, which keeps its "already
    /// counted as accepted" flag, so accepted ≤ shown even when the user
    /// accepts word by word while the model is still streaming.
    mutating func offer(_ text: String, before: String, after: String,
                        fresh: Bool, trimToLine: Bool, instant: Bool) {
        ghost = Ghost(anchor: before, after: after, text: text,
                      accepted: fresh ? false : (ghost?.accepted ?? false),
                      trimToLine: trimToLine, isInstant: instant)
    }

    /// The ghost against a fresh read: typing its head narrows it in place.
    /// A retired ghost is left up for the caller to resolve and drop. nil
    /// with no ghost.
    mutating func reconcileGhost(with text: String) -> GhostUpdate? {
        guard var ghost else { return nil }
        let update = Self.ghostUpdate(anchor: ghost.anchor, remaining: ghost.text, text: text)
        if case .narrowed(let remaining) = update {
            ghost.anchor = text
            ghost.text = remaining
            self.ghost = ghost
        }
        return update
    }

    /// ⇥ typed `chunk`, the ghost's head: the rest stays up, past it, and is
    /// returned. nil when that was all of it — the caller retires it.
    mutating func advanceGhost(past chunk: String) -> String? {
        guard var ghost, chunk.count < ghost.text.count else { return nil }
        ghost.accepted = true
        ghost.anchor += chunk
        ghost.text = String(ghost.text.dropFirst(chunk.count))
        self.ghost = ghost
        return ghost.text
    }

    // MARK: - Keys

    /// A key the tap passed on to the app, from the characters the event
    /// carried — no AX round trip, so it can't block on a hung app. The cache
    /// must stay truthful for EVERY such key, ghost or not: a streamed partial
    /// landing before the next read anchors on it, and pre-keystroke text
    /// would make ⇥ duplicate the typed character. Returns what the key did
    /// to the ghost (nil: none up, or nothing typed).
    ///
    /// `chord`: ⌘ or ⌃ held. Those carry no typed text but can rewrite the
    /// field (⌘V, ⌘X, the app's own ⌘Z) — the cache and the ghost both stop
    /// being trustworthy, and the next read says what's there.
    mutating func keystroke(_ typed: String, chord: Bool) -> GhostUpdate? {
        guard !chord else {
            cache = nil
            return ghost == nil ? nil : .retired(.abandoned)
        }
        guard !typed.isEmpty else { return nil }   // dead keys, bare modifiers
        // Control input (backspace, arrows) can't be replayed onto the cache:
        // unknown, so `apply` falls back to a fresh read. Typed text is
        // appended with no re-cap: the read window's start holds still
        // (`AXText.windowStart`), so a fresh read is this plus what was typed
        // — a cap counted in Characters sat at a different offset than the
        // UTF-16 window and failed the settle and undo equality checks. Every
        // read re-syncs it, so it can't grow unbounded.
        let isControl = Self.isControlInput(typed)
        if isControl { cache = nil } else { cache? += typed }
        guard var ghost else { return nil }
        // The typed text alone, not appended to the anchor: a mark typed onto
        // the anchor's last letter (Thai, Devanagari) merges into it, and the
        // joined text no longer starts with the anchor.
        let update = isControl ? .retired(.abandoned)
            : Self.ghostUpdate(anchor: "", remaining: ghost.text, text: typed)
        if case .narrowed(let remaining) = update {
            ghost.anchor += typed
            ghost.text = remaining
            self.ghost = ghost
        }
        return update
    }

    /// A synthetic edit — `deleted` gone and `text` typed onto `before` (nil:
    /// unknown, e.g. a selection typed over). The cache moves in step and the
    /// settle window opens, so a read still trailing the synthetic keys can't
    /// re-offer, resurrect or re-fix what was just typed. Returns the cache.
    mutating func injected(_ text: String, deleting deleted: String, over before: String?,
                           at now: Date) -> String? {
        cache = Self.textAfterInjection(text, deleting: deleted, over: before)
        settleDeadline = now.addingTimeInterval(0.3)
        return cache
    }

    /// `chunk` was just typed and left the cache at `snapshot` (nil: unknown):
    /// ⌘Z may take it back while the field still reads so.
    mutating func typed(_ chunk: String, snapshot: String?, dictated: Bool) {
        undoable = snapshot.map { Undoable(chunk: chunk, snapshot: $0, dictated: dictated) }
    }

    /// Return went after it: the app sent the text or opened a line, so the
    /// text before the caret is unknown and nothing is left for ⌘Z.
    mutating func sent() {
        cache = nil
        undoable = nil
    }

    /// The ⌘Z record, while the field still reads exactly as it did right
    /// after the chunk landed.
    var pendingUndo: Undoable? {
        guard let undoable, cache == undoable.snapshot else { return nil }
        return undoable
    }

    /// ⎋ dropped the ghost offered on this field, or ⌘Z took one back.
    mutating func decline(before: String, after: String) { declined = (before, after) }

    /// The focus moved: the cache, the caret and its style, a settle window,
    /// a decline and an untracked field all describe the field just left.
    /// Carried into the new one, the cache would glue the next keystroke onto
    /// the old text, a settle window would hold its reads hostage to it until
    /// the deadline, and a notice drawn before the first read would sit at the
    /// old caret in the old field's style.
    mutating func focusMoved() {
        cache = nil
        caret = nil
        style = HostTextStyle()
        settleDeadline = nil
        declined = nil
        untracked = nil
    }

    // MARK: - Rules

    enum GhostUpdate: Equatable {
        case unchanged
        case narrowed(String)
        case retired(SuggestionJournal.Outcome)
    }

    /// What a ghost offered at `anchor`, still showing `remaining`, becomes
    /// once the field reads `text` — the one rule behind a keystroke, an AX
    /// re-read and a stream landing after the user typed on. Typing its head
    /// narrows it; typing all of it, or something else, retires it
    /// (`.typedThrough`, `.diverged`); text that no longer starts with the
    /// anchor (a backspace, a caret move, a programmatic edit) abandons it.
    static func ghostUpdate(anchor: String, remaining: String, text: String) -> GhostUpdate {
        guard text.hasPrefix(anchor) else { return .retired(.abandoned) }
        let delta = String(text.dropFirst(anchor.count))
        if delta.isEmpty { return .unchanged }
        if delta.count < remaining.count, remaining.hasPrefix(delta) {
            return .narrowed(String(remaining.dropFirst(delta.count)))
        }
        return .retired(delta.hasPrefix(remaining) ? .typedThrough : .diverged)
    }

    /// The text before the caret once `deleted` is gone and `text` has landed
    /// on `before` — nil when that can't be known.
    static func textAfterInjection(_ text: String, deleting deleted: String, over before: String?) -> String? {
        guard let before, before.hasSuffix(deleted) else { return nil }
        return before.dropLast(deleted.count) + text
    }

    /// What an injection presses to turn `deleted` into `text`: only the tails
    /// past their shared head. "12*7=" → "12*7=84" presses no Backspace at
    /// all, and a typo fix keeps the letters it got right — every synthetic
    /// delete is one more key that can land somewhere it shouldn't.
    /// Compared by `Character`, so the cut is a grapheme boundary in both.
    static func keystrokes(replacing deleted: String, with text: String) -> (delete: String, type: String) {
        let shared = zip(deleted, text).prefix { $0 == $1 }.count
        return (String(deleted.dropFirst(shared)), String(text.dropFirst(shared)))
    }

    /// Backspace, arrows, function keys (the private-use F7xx range) and
    /// other non-text input.
    static func isControlInput(_ typed: String) -> Bool {
        typed.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
        }
    }
}
