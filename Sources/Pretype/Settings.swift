import Carbon
import CoreGraphics
import Foundation
import ServiceManagement

/// How the MLX engine turns context into a completion.
/// - `base`: raw text continuation against a *base* model (no template, no
///   instructions) — fast, faithful to mid-sentence flow, no steering.
/// - `instruct`: the *instruct* sibling model via its chat template, conditioned
///   on a persona + a "continue, ~N words" directive — steerable, tone-aware
///   (the approach Cotypist uses). Loads the instruct model as primary.
enum CompletionStyle: String, CaseIterable {
    case base
    case instruct
}

/// Caps how much the engine generates per keystroke. Shorter = faster, less
/// drift (Cotypist defaults to ~2–4 words for exactly this reason).
enum CompletionLength: String, CaseIterable {
    case short
    case medium
    case long

    /// Token budget handed to the sampler (the Cyrillic widener stretches it
    /// for Russian).
    var maxTokens: Int {
        switch self {
        case .short: return 6
        case .medium: return 12
        case .long: return 22
        }
    }

    /// Phrase injected into the instruct directive so the model self-limits.
    var wordsHint: String {
        switch self {
        case .short: return "at most 2–3 words"
        case .medium: return "a short phrase of at most ~6 words"
        case .long: return "at most one sentence"
        }
    }
}

/// How strongly to bias the model toward the user's previously-accepted words.
/// Off by default; collection only happens while this is non-off.
enum PersonalizationLevel: String, CaseIterable {
    case off
    case subtle
    case medium
    case strong

    /// β in the first-token n-gram boost: β × ln(1+count) logits on a personal
    /// next-word candidate's start token. Kept modest — too high favors a
    /// habitual word over a better-fitting one.
    var bias: Float {
        switch self {
        case .off: return 0
        case .subtle: return 0.6
        case .medium: return 1.2
        case .strong: return 2.2
        }
    }
}

/// How a completion is shown at the caret.
/// - `inline`: seamless ghost text drawn on the line itself (Cotypist-style) —
///   needs an accurate caret; pixel-perfect in native + Chromium/Electron apps.
/// - `panel`: a small floating box beside the caret with the text + a ⇥ hint —
///   the classic look; more legible on busy backgrounds, never overlaps text,
///   and forgiving when the caret can only be estimated.
enum SuggestionPresentation: String, CaseIterable {
    case inline
    case panel
}

/// One-finger trigger for the composed reply: double-tap a bare modifier. The
/// chord (see `HotkeyStyle.replyLabel`) always works too — this is the reachable
/// twin, and it is a *choice* because every modifier is already somebody's
/// global hotkey (launchers, dictation, window managers).
enum ReplyGesture: String, CaseIterable {
    case option
    case shift
    case control
    case command
    case off

    var label: String {
        switch self {
        case .option: return "Double ⌥"
        case .shift: return "Double ⇧"
        case .control: return "Double ⌃"
        case .command: return "Double ⌘"
        case .off: return "Off"
        }
    }

    /// The two physical keys to watch and the flag the modifier raises — enough
    /// to tell a press from a release, and to ignore every other modifier.
    var keys: (codes: [Int64], mask: CGEventFlags)? {
        switch self {
        case .option: return ([KeyCode.leftOption, KeyCode.rightOption], .maskAlternate)
        case .shift: return ([KeyCode.leftShift, KeyCode.rightShift], .maskShift)
        case .control: return ([KeyCode.leftControl, KeyCode.rightControl], .maskControl)
        case .command: return ([KeyCode.leftCommand, KeyCode.rightCommand], .maskCommand)
        case .off: return nil
        }
    }
}

/// Push-to-talk trigger: HOLD a bare modifier, speak, release — the transcript
/// is typed into the field you were already in.
///
/// A *hold* rather than a tap or a chord, for two reasons. The event tap only
/// watches key-DOWN (see `KeyTap`), so the one kind of key whose release we can
/// see at all is a modifier. And because `ReplyGesture` fires only on taps, a
/// hold can share a modifier with it without either one ever swallowing the
/// other — which is why the defaults (hold right ⌥ / double-tap ⌥) coexist.
///
/// Either side of the modifier counts.
///
/// This shipped right-hand-only, on the theory that the left modifier is the
/// one held while reaching for a chord. The theory was fine and the feature was
/// unusable: someone who reaches for the left key gets no pill, no error and no
/// log line — the gesture simply never fires, which is indistinguishable from
/// broken software. A chord that pauses mid-reach is handled where it should
/// be, by `ModifierHold.keyPressed` cancelling the capture the moment any other
/// key arrives.
enum DictationGesture: String, CaseIterable {
    case option
    case command
    case control
    case off

    var label: String {
        switch self {
        case .option: return "Hold ⌥"
        case .command: return "Hold ⌘"
        case .control: return "Hold ⌃"
        case .off: return "Off"
        }
    }

    /// Short form for the caret pill and the menu ("⌥ to talk").
    var shortLabel: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .off: return ""
        }
    }

    /// Both physical keys to watch and the flag they raise — same shape as
    /// `ReplyGesture`, so the tap-twin and the hold-twin of a modifier behave
    /// identically about which key you actually reach for.
    var keys: (codes: [Int64], mask: CGEventFlags)? {
        switch self {
        case .option: return ([KeyCode.leftOption, KeyCode.rightOption], .maskAlternate)
        case .command: return ([KeyCode.leftCommand, KeyCode.rightCommand], .maskCommand)
        case .control: return ([KeyCode.leftControl, KeyCode.rightControl], .maskControl)
        case .off: return nil
        }
    }
}

/// Hands-free dictation: one chord starts a capture, the next one ends it —
/// for the paragraph nobody wants to hold a key through.
///
/// A chord rather than the bare modifier `DictationGesture` uses, because both
/// one-finger meanings of a bare modifier are already spoken for: a hold is a
/// capture, a double tap is the reply flow. A third meaning on the same key
/// could only be told apart by timing the user cannot see.
///
/// The chord earns something the hold cannot have, too. `ModifierHold` waits
/// out its threshold before opening the microphone, because a modifier on its
/// way to a chord must never start recording — so the first syllable of a hold
/// is spoken into a microphone that isn't open yet. Nothing else means ⌃⌥D, so
/// a latch can open on the key-down itself.
enum DictationLatch: String, CaseIterable {
    case off
    case controlOptionD
    case controlOptionV

    var label: String {
        switch self {
        case .off: return "Off"
        case .controlOptionD: return "⌃⌥D"
        case .controlOptionV: return "⌃⌥V"
        }
    }

    /// Both are letters on purpose. ⌃⌥Space was the obvious third option and
    /// is the wrong one: macOS binds it to "select the next input source", and
    /// this app's dictation language *follows the keyboard layout* — so the
    /// users it would break are exactly the ones the feature is built around.
    private var keyCode: Int64? {
        switch self {
        case .off: return nil
        case .controlOptionD: return KeyCode.d
        case .controlOptionV: return KeyCode.v
        }
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard let expected = self.keyCode, keyCode == expected else { return false }
        return flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            == [.maskControl, .maskAlternate]
    }

    /// True when this chord is already the ⌥⇥ fix's chord under the current
    /// base hotkey.
    ///
    /// No shipped combination reaches it — every fix chord is built on ⇥ or
    /// Space and every latch chord is a letter — but it is what KEEPS that
    /// true. The latch is matched before the fix at the tap, so this guard,
    /// not the ordering, is what stops a new chord from silently eating ⌥⇥'s
    /// twin; and Settings says so rather than letting the latch look broken.
    var collidesWithFixChord: Bool {
        guard let keyCode else { return false }
        return Settings.hotkeyStyle.matchesCorrection(
            keyCode: keyCode, flags: [.maskControl, .maskAlternate])
    }
}

enum HotkeyStyle: String, CaseIterable {
    case tab
    case cmdSpace
    case optSpace
    case ctrlSpace

    var label: String {
        switch self {
        case .tab: return "Tab"
        case .cmdSpace: return "⌘Space"
        case .optSpace: return "⌥Space"
        case .ctrlSpace: return "⌃Space"
        }
    }

    var shiftLabel: String { "⇧" + label }

    var correctionLabel: String {
        switch self {
        case .tab: return "⌥Tab"
        case .cmdSpace: return "⌥⌘Space"
        case .optSpace: return "⌥⌘Space"
        case .ctrlSpace: return "⌥⌃Space"
        }
    }

    /// Compose-a-reply chord: the fix chord plus ⇧.
    var replyLabel: String {
        switch self {
        case .tab: return "⌥⇧Tab"
        case .cmdSpace: return "⌥⇧⌘Space"
        case .optSpace: return "⌥⇧⌘Space"
        case .ctrlSpace: return "⌃⌥⇧Space"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .tab: return KeyCode.tab
        case .cmdSpace, .optSpace, .ctrlSpace: return KeyCode.space
        }
    }

    /// The accept chord's modifier; accept-all adds ⇧, the fix chord adds ⌥
    /// (⌥Space already holds ⌥, so its fix chord is ⌥⌘).
    private var base: CGEventFlags {
        switch self {
        case .tab: return []
        case .cmdSpace: return .maskCommand
        case .optSpace: return .maskAlternate
        case .ctrlSpace: return .maskControl
        }
    }

    /// Exact-modifier match, so the chords can never collide.
    private func matches(_ keyCode: Int64, _ flags: CGEventFlags, _ required: CGEventFlags) -> Bool {
        keyCode == self.keyCode
            && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == required
    }

    func matchesAcceptWord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        matches(keyCode, flags, base)
    }

    func matchesAcceptAll(keyCode: Int64, flags: CGEventFlags) -> Bool {
        matches(keyCode, flags, base.union(.maskShift))
    }

    /// The fix chord with ⇧ added — derived, so the two can never drift apart.
    func matchesReply(keyCode: Int64, flags: CGEventFlags) -> Bool {
        flags.contains(.maskShift)
            && matchesCorrection(keyCode: keyCode, flags: flags.subtracting(.maskShift))
    }

    func matchesCorrection(keyCode: Int64, flags: CGEventFlags) -> Bool {
        matches(keyCode, flags, self == .optSpace ? [.maskCommand, .maskAlternate] : base.union(.maskAlternate))
    }
}

/// The completion knobs, resolved with environment overrides winning over
/// stored settings so the `--eval` / `--complete` harness can A/B them without
/// touching the UI (PRETYPE_COMPLETION_STYLE / _LENGTH / _CUSTOM_INSTRUCTIONS /
/// _PERSONALIZATION).
struct CompletionConfig {
    var style: CompletionStyle
    var length: CompletionLength
    var instructions: String
    var personalization: PersonalizationLevel

    static func resolved() -> CompletionConfig {
        let env = ProcessInfo.processInfo.environment
        let style = env["PRETYPE_COMPLETION_STYLE"].flatMap(CompletionStyle.init(rawValue:))
            ?? Settings.completionStyle
        let length = env["PRETYPE_COMPLETION_LENGTH"].flatMap(CompletionLength.init(rawValue:))
            ?? Settings.completionLength
        let instructions = env["PRETYPE_CUSTOM_INSTRUCTIONS"] ?? Settings.customInstructions
        let personalization = env["PRETYPE_PERSONALIZATION"].flatMap(PersonalizationLevel.init(rawValue:))
            ?? Settings.personalizationLevel
        return CompletionConfig(
            style: style, length: length,
            instructions: instructions, personalization: personalization
        )
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Starter persona auto-filled from on-device system data — the account
    /// full name and the user's preferred languages — so the persona is
    /// personalized (and carries the language steering that matters for Russian)
    /// with zero typing. All local, nothing leaves the Mac; the user edits it in
    /// the menu. Measured: a personal persona lifts the instruct path to ~88%
    /// first-word vs 66% with none.
    static var defaultInstructions: String {
        // Phrasing matches the best persona measured on eval-v2 (~88% first-word):
        // "I write in <langs>, in a friendly, professional and concise voice."
        var result = ""
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name.caseInsensitiveCompare(NSUserName()) != .orderedSame {
            result += "My name is \(name). "
        }
        let langs = writingLanguageNames()
        if langs.isEmpty {
            result += "I write in a friendly, professional and concise voice."
        } else {
            result += "I write in \(formatLanguages(langs)), in a friendly, professional and concise voice."
        }
        return result
    }

    /// English names of the languages the user writes in — enabled **keyboard
    /// layouts** first (the most direct signal of what you type), then preferred
    /// languages — deduped, up to 3.
    private static func writingLanguageNames() -> [String] {
        let english = Locale(identifier: "en_US")
        var seen = Set<String>()
        var names: [String] = []
        func add(_ code: String) {
            guard names.count < 3,
                  let base = Locale(identifier: code).language.languageCode?.identifier,
                  !seen.contains(base) else { return }
            seen.insert(base)
            if let name = english.localizedString(forLanguageCode: base) { names.append(name) }
        }
        keyboardLanguages().forEach(add)
        Locale.preferredLanguages.forEach(add)
        return names
    }

    /// Language of the layout that is selected RIGHT NOW ("ru" while the
    /// Russian keyboard is active). The closest thing to a free signal of which
    /// language the user is about to *speak*, so dictation follows it by
    /// default instead of asking. nil when the active source declares no
    /// language (some IMEs, the emoji picker).
    static var currentKeyboardLanguage: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String],
              let first = langs.first, !first.isEmpty else { return nil }
        return first
    }

    /// First language of each enabled keyboard layout / input mode (e.g. the
    /// "Russian – PC" keyboard → "ru"). Carbon Text Input Sources; no permission.
    private static func keyboardLanguages() -> [String] {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        let keyboardTypes = [kTISTypeKeyboardLayout as String, kTISTypeKeyboardInputMode as String]
        var result: [String] = []
        for source in sources {
            if let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
                let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
                guard keyboardTypes.contains(type) else { continue }
            }
            if let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
               let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String],
               let first = langs.first {
                result.append(first)
            }
        }
        return result
    }

    /// "English", "English and Russian", "English, Russian, and German".
    private static func formatLanguages(_ names: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: names) ?? ""
    }

    static func registerDefaults() {
        // Per-app "this is useless here" verdicts predate the fair denominator.
        Stats.migrateAppRecordsIfNeeded()
        // "core" stopped being a choice in the language picker 2026-07-25: it
        // pooled English and Russian, which measure differently, into one entry
        // sitting among real languages. The sample still exists — it is the only
        // one the settings projections are anchored to — but it is now a mode
        // (`settingsMapMode`) rather than a language, so picking a language and
        // looking at the settings map are no longer the same gesture.
        if defaults.string(forKey: "accuracyAxis") == "core" {
            defaults.set(true, forKey: "settingsMapMode")
            defaults.set("*", forKey: "accuracyAxis")
        }
        // Style/length ship pre-matched to the default model's recommendation:
        // nothing applies it at boot (main only registers defaults), and the
        // engine reads the stored style directly — so the base-only Qwen3.5
        // floor (small-RAM Macs) would otherwise launch in its broken
        // instruct mode.
        let rec = ModelCatalog.recommended(for: ModelCatalog.defaultID)
        defaults.register(defaults: [
            "enabled": true,
            "pauseOnBattery": false,
            "mlxModelID": ModelCatalog.defaultID,
            // Wait after a keystroke before querying. Replayed typing (lognormal
            // gaps, median 190 ms): 120 → 60 ms cut pause→ghost p50 by 55–76 ms
            // across E4B/E2B/Qwen3.5 for +12–18% engine work — most gaps clear
            // 120 ms anyway, so the old value mostly added latency.
            "debounceMs": 60,
            "maxContextChars": 1200,
            // A reload after the idle unload costs ~0.6–1.2 s even with the
            // tokenizer kept; on 32 GB+ Macs, where the memory-pressure unload
            // still frees the model the moment macOS needs the RAM, the model
            // waits out a longer pause instead. A picked value always wins.
            "idleUnloadMinutes": ModelCatalog.machineRamGB >= 32 ? 15 : 5,
            // Follows the default model's recommendation (base·short on the
            // Qwen3.5 floor; instruct·short on the Gemma tiers).
            "completionStyle": rec.style.rawValue,
            "completionLength": rec.length.rawValue,
            "customInstructions": defaultInstructions,
            // Subtle by default: powers the n-gram first-token boost AND the
            // personal n-gram fast-path; everything stays on-device.
            "personalizationLevel": PersonalizationLevel.subtle.rawValue,
            "suggestionPresentation": SuggestionPresentation.inline.rawValue,
            "useRecommendedSettings": true,
            "automaticUpdateCheck": true,
            "logprobGate": false,
            // Mean first-word logprob floor. Q3 boundary from the eval-real
            // calibration (~11% Net-KSS at ~49% coverage); tune from the journal's
            // captured firstWordLogProb. More negative = laxer, toward 0 = stricter.
            "logprobGateThreshold": -1.5,
            "userBlacklist": [String](),
            "suggestionJournal": true,
            // 0.45 read as near-invisible over real app backgrounds; 0.7 is
            // still clearly "ghost" next to the host text but survives noise.
            "ghostOpacity": 0.7,
            "hotkeyStyle": HotkeyStyle.tab.rawValue,
            "replyGesture": ReplyGesture.option.rawValue,
            // Dictation is OFF until asked for: it is the one feature that
            // opens the microphone, and a third permission prompt at first
            // launch (after Accessibility and Screen Recording) is not
            // something to spring on someone who came for autocomplete.
            "dictation": false,
            "dictationGesture": DictationGesture.option.rawValue,
            // The hands-free half. On by default *within* dictation (which is
            // itself off): someone who has just turned the microphone on should
            // find both halves of the feature there, and a chord that starts
            // nothing until dictation is enabled costs an unused key binding.
            "dictationLatch": DictationLatch.controlOptionD.rawValue,
            // Long enough to think mid-sentence, short enough that a capture
            // forgotten about doesn't run to the ceiling. Only ever consulted
            // for a latched capture — a held key says when it is done.
            "dictationSilence": 5.0,
            // The transcript goes through the same minimal-edit fix the ⌥⇥
            // flow uses — free on top of a generation the user is already
            // waiting for, and it is what makes this Pretype's dictation
            // rather than a second copy of the system's.
            "dictationPolish": true,
            "dictationLanguage": "auto",
            "dictationInput": "auto",
            "onboardingCompleted": false,
        ])
        // The catalog changes over time; clear stale model picks every launch.
        if let stored = defaults.string(forKey: "mlxModelID"), ModelCatalog.option(for: stored) == nil {
            defaults.removeObject(forKey: "mlxModelID")
        }
    }

    static var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }

    static var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// No completions while the Mac runs on battery: every suggestion is a GPU
    /// burst, and battery drain is the most-cited reason people quit local
    /// autocomplete. Off by default; see `AppPolicy.pausedForBattery`.
    static var pauseOnBattery: Bool {
        get { defaults.bool(forKey: "pauseOnBattery") }
        set { defaults.set(newValue, forKey: "pauseOnBattery") }
    }

    static var userBlacklist: [String] {
        get { defaults.stringArray(forKey: "userBlacklist") ?? [] }
        set { defaults.set(newValue, forKey: "userBlacklist") }
    }

    /// Local JSONL journal of suggestion outcomes (accepted / dismissed /
    /// typed-past) — the dataset for the offline replay bench and future
    /// personalization. Never leaves the Mac.
    static var suggestionJournalEnabled: Bool {
        get { defaults.bool(forKey: "suggestionJournal") }
        set { defaults.set(newValue, forKey: "suggestionJournal") }
    }

    /// Whether Pretype may ask GitHub once a day whether a newer release exists
    /// (see `UpdateChecker`). Off means the app makes no outbound request the
    /// user didn't start. The menu's manual check works either way.
    static var automaticUpdateCheck: Bool {
        get { defaults.bool(forKey: "automaticUpdateCheck") }
        set { defaults.set(newValue, forKey: "automaticUpdateCheck") }
    }

    /// Opt-in OCR of the focused window for richer model context.
    static var screenContextEnabled: Bool {
        get { defaults.bool(forKey: "screenContext") }
        set { defaults.set(newValue, forKey: "screenContext") }
    }

    /// Opt-in: feed the current clipboard text to the model as extra context
    /// (the thing being replied to is often just-copied). Same label-free
    /// prompt block as the screen context; concealed/transient pasteboards
    /// (password managers mark both) are never read.
    static var clipboardContextEnabled: Bool {
        get { defaults.bool(forKey: "clipboardContext") }
        set { defaults.set(newValue, forKey: "clipboardContext") }
    }

    /// Extra persona lines for one specific app (exact lowercased bundle ID →
    /// text), appended to `customInstructions` in the instruct directive —
    /// "formal, no emoji" for Mail, "casual and short" for Slack.
    static var perAppInstructions: [String: String] {
        get { defaults.dictionary(forKey: "perAppInstructions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "perAppInstructions") }
    }

    /// The per-app addition for the app being typed in, or nil when none is
    /// configured (or it's blank).
    static func perAppInstructions(for bundleID: String?) -> String? {
        guard let id = bundleID?.lowercased(),
              let text = perAppInstructions[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// A website's own lines win over its browser's: in Chrome, Gmail and
    /// Slack want different voices, and the app entry can't tell them apart.
    /// The most specific matching site entry is the one used.
    static func perAppInstructions(for bundleID: String?, site host: String?) -> String? {
        if let host {
            let best = perAppInstructions
                .filter { AppPolicy.site(host, matches: $0.key) }
                .max { $0.key.count < $1.key.count }
            if let text = best?.value.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return perAppInstructions(for: bundleID)
    }

    static var mlxModelID: String {
        get { defaults.string(forKey: "mlxModelID") ?? ModelCatalog.defaultID }
        set { defaults.set(newValue, forKey: "mlxModelID") }
    }

    static var debounceMs: Int { defaults.integer(forKey: "debounceMs") }
    static var maxContextChars: Int { defaults.integer(forKey: "maxContextChars") }

    /// "Auto" mode: Style and Length follow `ModelCatalog.recommended(for:)` for
    /// the selected model (and re-apply on model switch), instead of the user
    /// tuning them by hand. On by default.
    static var useRecommendedSettings: Bool {
        get { defaults.bool(forKey: "useRecommendedSettings") }
        set { defaults.set(newValue, forKey: "useRecommendedSettings") }
    }

    /// Logprob confidence gate (base only): abstain when the shown suggestion's
    /// mean first-word logprob is below `logprobGateThreshold`. Trades coverage
    /// for precision at **0×** extra decode — the first-word logprob is already captured live by the
    /// decode loop (validated in Eval/BASELINE.md). Off by default.
    static var logprobGate: Bool {
        get { defaults.bool(forKey: "logprobGate") }
        set { defaults.set(newValue, forKey: "logprobGate") }
    }
    static var logprobGateThreshold: Double {
        get { let v = defaults.double(forKey: "logprobGateThreshold"); return v != 0 ? v : -1.5 }
        set { defaults.set(newValue, forKey: "logprobGateThreshold") }
    }

    /// Free the resident MLX model after this many minutes idle (0 = never). A
    /// background menu-bar app shouldn't hold several GB while unused; the next
    /// focus/keystroke reloads it from the on-disk cache.
    static var idleUnloadMinutes: Int {
        get { defaults.integer(forKey: "idleUnloadMinutes") }
        set { defaults.set(newValue, forKey: "idleUnloadMinutes") }
    }

    /// Which measured axis the Model tab's accuracy surfaces show: "*" =
    /// equal-weight average over all measured languages (the multilingual
    /// default), "core" = the EN+RU *pooled* booking — English and Russian
    /// score differently inside it, so it answers for neither on its own and
    /// both are selectable separately (largest sample — and the only
    /// axis the settings projections are measured on), or a language code
    /// from `ModelMetrics.evalLanguages`. Presentation-only: never feeds the
    /// completion pipeline.
    static var accuracyAxis: String {
        get { defaults.string(forKey: "accuracyAxis") ?? "*" }
        set { defaults.set(newValue, forKey: "accuracyAxis") }
    }

    /// Show the model map's settings machinery — the config dots, the reachable
    /// zone and the projected ring. Its own switch rather than an entry in the
    /// language picker: those projections are anchored to the pooled
    /// English+Russian booking and to constants from single experiments (the
    /// logprob-gate figures come from one calibration model), so they are not a language's
    /// numbers and can't be redrawn against one. Turning it on moves the whole
    /// tab onto that sample and says so; the language you picked is remembered
    /// and comes back when you turn it off.
    static var settingsMapMode: Bool {
        get { defaults.bool(forKey: "settingsMapMode") }
        set { defaults.set(newValue, forKey: "settingsMapMode") }
    }

    /// Base (raw continuation) vs instruct (persona-aware) completion.
    static var completionStyle: CompletionStyle {
        get { CompletionStyle(rawValue: defaults.string(forKey: "completionStyle") ?? "") ?? .instruct }
        set { defaults.set(newValue.rawValue, forKey: "completionStyle") }
    }

    /// How long a single completion may be.
    static var completionLength: CompletionLength {
        get { CompletionLength(rawValue: defaults.string(forKey: "completionLength") ?? "") ?? .short }
        set { defaults.set(newValue.rawValue, forKey: "completionLength") }
    }

    /// Free-text persona/voice used in instruct mode (Cotypist's "Custom AI
    /// Instructions"). Ships with a generic default; the user can edit or clear it.
    static var customInstructions: String {
        get { defaults.string(forKey: "customInstructions") ?? defaultInstructions }
        set { defaults.set(newValue, forKey: "customInstructions") }
    }

    /// Strength of the personal n-gram boost. Off disables learning too.
    static var personalizationLevel: PersonalizationLevel {
        get { PersonalizationLevel(rawValue: defaults.string(forKey: "personalizationLevel") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "personalizationLevel") }
    }

    /// Inline ghost text vs a floating panel beside the caret.
    static var suggestionPresentation: SuggestionPresentation {
        get { SuggestionPresentation(rawValue: defaults.string(forKey: "suggestionPresentation") ?? "") ?? .inline }
        set { defaults.set(newValue.rawValue, forKey: "suggestionPresentation") }
    }

    static var ghostOpacity: Double {
        // Floored like the Settings slider (0.4…1): a value stored under the
        // old 0.1 floor would otherwise keep the ghost near-invisible.
        get { max(0.4, defaults.double(forKey: "ghostOpacity")) }
        set { defaults.set(newValue, forKey: "ghostOpacity") }
    }

    static var hotkeyStyle: HotkeyStyle {
        get { HotkeyStyle(rawValue: defaults.string(forKey: "hotkeyStyle") ?? "") ?? .tab }
        set { defaults.set(newValue.rawValue, forKey: "hotkeyStyle") }
    }

    /// Read on every modifier event, so a change applies to the next keypress —
    /// no relaunch, no event-tap rebuild.
    static var replyGesture: ReplyGesture {
        get { ReplyGesture(rawValue: defaults.string(forKey: "replyGesture") ?? "") ?? .option }
        set { defaults.set(newValue.rawValue, forKey: "replyGesture") }
    }

    /// Hold-to-talk dictation. Off by default (see `registerDefaults`); turning
    /// it on is what asks for the microphone.
    static var dictationEnabled: Bool {
        get { defaults.bool(forKey: "dictation") }
        set { defaults.set(newValue, forKey: "dictation") }
    }

    static var dictationGesture: DictationGesture {
        get { DictationGesture(rawValue: defaults.string(forKey: "dictationGesture") ?? "") ?? .option }
        set { defaults.set(newValue.rawValue, forKey: "dictationGesture") }
    }

    /// The chord that starts and ends a hands-free capture.
    static var dictationLatch: DictationLatch {
        get { DictationLatch(rawValue: defaults.string(forKey: "dictationLatch") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "dictationLatch") }
    }

    /// How long a hands-free capture may hear nothing before it ends itself and
    /// types what it has. 0 turns it off — then only a second press of the
    /// chord (or the ceiling) stops it.
    static var dictationSilence: TimeInterval {
        get { defaults.double(forKey: "dictationSilence") }
        set { defaults.set(newValue, forKey: "dictationSilence") }
    }

    /// Run the transcript through the model's minimal-edit fix before typing it.
    static var dictationPolish: Bool {
        get { defaults.bool(forKey: "dictationPolish") }
        set { defaults.set(newValue, forKey: "dictationPolish") }
    }

    /// Which microphone a capture opens: "auto" (keep a Bluetooth headset out
    /// of call mode — see `AudioDevices`), "system" (always the system default
    /// input), or a device UID.
    static var dictationInput: String {
        get { defaults.string(forKey: "dictationInput") ?? "auto" }
        set { defaults.set(newValue, forKey: "dictationInput") }
    }

    /// Language to dictate in: "auto" follows the active keyboard layout, any
    /// other value is a language/locale identifier the user pinned.
    static var dictationLanguage: String {
        get { defaults.string(forKey: "dictationLanguage") ?? "auto" }
        set { defaults.set(newValue, forKey: "dictationLanguage") }
    }

    /// The locale a dictation session should open with. "auto" reads the
    /// layout that is active at the moment the key goes down — a bilingual
    /// user switches languages by switching keyboard, which they already do to
    /// type, so there is nothing extra to set.
    static var resolvedDictationLocale: Locale {
        let stored = dictationLanguage
        if stored != "auto", !stored.isEmpty { return Locale(identifier: stored) }
        if let current = currentKeyboardLanguage { return Locale(identifier: current) }
        return Locale.current
    }
}

/// Start Pretype with the Mac. Deliberately NOT a `Settings` key: the truth
/// lives in launchd, and the user can flip the same switch in System Settings →
/// General → Login Items. A mirrored bool would drift into a switch that lies,
/// so every read goes back to `SMAppService.mainApp.status`.
enum LoginItem {
    /// SMAppService registers a login item *by bundle*. A bare `swift build`
    /// binary has no .app around it, so `register()` could only ever throw —
    /// the toggle says so instead of failing silently.
    static var isSupported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Registered *and* allowed to run. `.requiresApproval` means the job exists
    /// but macOS is holding it — on, yet doing nothing, which is exactly the
    /// state a switch must not show as on.
    static func isOn(_ status: SMAppService.Status) -> Bool { status == .enabled }

    /// Extra line under the toggle when the plain caption isn't the whole story.
    static func note(_ status: SMAppService.Status) -> String? {
        guard isSupported else {
            return "Available in the built app only — this binary is running outside a .app bundle, "
                + "and macOS registers login items by bundle."
        }
        return status == .requiresApproval
            ? "macOS is holding this one: allow Pretype in System Settings → General → Login Items."
            : nil
    }

    static func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Recoverable, and already visible to the user: the caller re-reads
            // `status`, so a refused registration snaps the switch back.
            DebugLog.shared.log("ERROR", "login item \(on ? "register" : "unregister") failed: "
                + error.localizedDescription)
        }
    }
}
