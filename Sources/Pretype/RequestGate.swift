import Foundation

/// When the completion pipeline asks for a suggestion, and what of an answer
/// lands: the gates of `textDidChange` and `apply` as pure rules over what a
/// pass knows. The controller reads the field, draws and books; these decide.
/// RequestGateTests pin the table.
enum RequestGate {
    // MARK: - A field pass (`textDidChange`)

    /// What a pass knows before it looks the field up.
    struct Pass {
        var enabled = true
        /// A capture owns the overlay (`DictationController.isBusy`).
        var dictating = false
        /// One of Pretype's own windows is frontmost.
        var ownWindowFrontmost = false
        /// Completions are allowed in this app (`AppPolicy.allowsCompletions`).
        var appAllowed = true
        var hasGhost = false
    }

    enum Entry<Field> {
        /// Leave everything as it is. Paused, or a capture owns the overlay:
        /// an AX notification mid-capture (a selection event, the injection
        /// itself) must neither hide its pill nor generate for text the user
        /// is still speaking. The post-injection refresh re-enters normally.
        case idle
        /// Drop the ghost, the query, a fix and the overlay; `why` for "Last:".
        case dismiss(why: String?)
        /// Read the field `findField` found.
        case read(Field)
    }

    /// The gates before a pass reads the field. `findField` looks it up — an
    /// AX read, made only once the cheap checks pass. `siteBlocked`: the site
    /// only that lookup could read (a field the tracker missed) is one
    /// Pretype stays out of. The app is checked on both sides of the lookup:
    /// before it, so a terminal costs no AX read; after it, the site.
    static func entry<Field>(_ pass: Pass, findField: () -> Field?, siteBlocked: () -> Bool) -> Entry<Field> {
        guard pass.enabled, !pass.dictating else { return .idle }
        if pass.ownWindowFrontmost { return .dismiss(why: nil) }
        guard pass.appAllowed else { return .dismiss(why: "suggestions are off in blacklisted apps") }
        guard let field = findField() else { return .dismiss(why: pass.hasGhost ? "lost text element" : nil) }
        if siteBlocked() { return .dismiss(why: "suggestions are off on this site") }
        return .read(field)
    }

    /// A letter or digit right after the caret: the caret splits a word, and
    /// any completion accepted there fuses into its remainder ("hel|lo" +
    /// "p there" → "help therelo"). The gates' after-caret duplication check
    /// only catches the model re-typing that exact remainder, so nothing is
    /// offered while the user edits inside a word.
    static func caretSplitsWord(before textAfterCaret: String) -> Bool {
        guard let next = textAfterCaret.first else { return false }
        return next.isLetter || next.isNumber
    }

    /// Why a read asks the engine nothing new, in the order the "Last:" line
    /// reports it — nil: ask. A ghost already up keeps shrinking as the user
    /// types either way; these only stop a new query.
    ///
    /// - `unproductive`: suggestions here have been offered dozens of times
    ///   and essentially never taken. Quiet rather than interrupting (and
    ///   spending the battery). A typo fix or a shortcode still runs: they
    ///   come before this gate.
    /// - `onBattery`: the user's battery rule — completions are the GPU
    ///   bursts it is about.
    /// - `declined`: ⎋ or ⌘Z declined this exact field.
    static func quietReason(unproductive: Bool, onBattery: Bool, declined: Bool) -> String? {
        if unproductive { return "quiet in this app — suggestions here are almost never taken" }
        if onBattery { return "paused on battery" }
        if declined { return "dismissed — waiting for an edit" }
        return nil
    }

    /// The personal n-gram's instant suggestion for `text`|`after`: a
    /// next word after a space, the rest of the word at the caret, or a space
    /// and a next word after a word the spell-checker calls complete. nil
    /// unless the user's own history is emphatic, for a short field, and for
    /// anything already following the caret. Microseconds: pure in-memory
    /// counts, run on the keystroke path.
    @MainActor
    static func instantSuggestion(text: String, after: String, ngram: PersonalNgram) -> String? {
        guard text.count >= 12 else { return nil }
        let prediction: String?
        if text.hasSuffix(" ") {
            prediction = ngram.nextWord(after: text)
        } else if text.last?.isLetter == true {
            if let remainder = ngram.completeWord(partial: SpellChecker.trailingWord(of: text)) {
                prediction = remainder
            } else if SpellChecker.endsOnCompleteWord(before: text, after: after),
                      let word = ngram.nextWord(after: text) {
                prediction = " " + word
            } else {
                prediction = nil
            }
        } else {
            prediction = nil
        }
        guard let prediction, !prediction.isEmpty else { return nil }
        let nextWord = prediction.trimmingCharacters(in: .whitespaces)
        guard !after.trimmingCharacters(in: .whitespaces).hasPrefix(nextWord) else { return nil }
        return prediction
    }

    // MARK: - An answer landing (`apply`)

    enum Landing: Equatable {
        /// Show this — the answer less what the user typed since, normalized.
        case show(String)
        /// The field moved away from the answer, or past it: hide it. `why`
        /// for "Last:".
        case stale(why: String)
        /// A whole new word fused onto the half-typed one ("быст" + "ответ"
        /// → "быстответ"): instruct and FM models answer flush, so the
        /// engine's gate can't catch it. Retired — nothing beats garbage.
        case glued
    }

    /// What of `suggestion`, asked for on `requestText`, lands on a field
    /// that now reads `current` before the caret. The user may have typed on
    /// while the engine thought: the answer still lands if what they typed is
    /// its head. Then on the main thread (NSSpellChecker is unsafe off it): a
    /// stray separator the engine prepended to a word continuation goes ("при
    /// " + "вет" → "привет"), a leading space the field already has goes, and
    /// a wrongly capitalized mid-sentence continuation is lowered ("я хочу " +
    /// "Поехать" → "поехать").
    @MainActor
    static func landing(_ suggestion: String, askedOn requestText: String, current: String) -> Landing {
        var suggestion = suggestion
        switch FieldState.ghostUpdate(anchor: requestText, remaining: suggestion, text: current) {
        case .unchanged:
            break
        case .narrowed(let remaining):
            suggestion = remaining
        case .retired(let outcome):
            return .stale(why: outcome == .abandoned ? "context changed; dropped result" : "typed past the suggestion")
        }
        suggestion = SpellChecker.strippingStraySeparator(suggestion: suggestion, before: current)
        suggestion = SuggestionController.deduplicatingSeamSpace(suggestion, after: current)
        suggestion = SpellChecker.decapitalizeContinuation(suggestion, before: current)
        if SuggestionController.wouldGlueMidWord(current: current, suggestion: suggestion) { return .glued }
        return .show(suggestion)
    }
}

extension RequestGate.Entry: Equatable where Field: Equatable {}
