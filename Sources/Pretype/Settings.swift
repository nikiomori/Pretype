import Carbon
import CoreGraphics
import Foundation

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
/// drift (Cotypist defaults to ~2–4 words for exactly this reason). `word`
/// predicts a single next word — minimal and low-distraction, and the most
/// reliable use of the lighter Apple Intelligence model (it is weak on longer
/// multi-word / Russian continuations; one word it gets right far more often).
enum CompletionLength: String, CaseIterable {
    case word
    case short
    case medium
    case long

    /// Token budget handed to the sampler. `word` is tight but leaves room for
    /// a long single word (the Cyrillic widener stretches it for Russian).
    var maxTokens: Int {
        switch self {
        case .word: return 5
        case .short: return 6
        case .medium: return 12
        case .long: return 22
        }
    }

    /// Phrase injected into the instruct directive so the model self-limits.
    var wordsHint: String {
        switch self {
        case .word: return "only the single next word"
        case .short: return "at most 2–3 words"
        case .medium: return "a short phrase of at most ~6 words"
        case .long: return "at most one sentence"
        }
    }

    /// Whether the suggestion should be cut to one word after generation.
    var isSingleWord: Bool { self == .word }

    /// Length whose word-count hint goes into the instruct directive. `word`
    /// borrows `short`'s phrasing: telling the model "exactly one word" measurably
    /// worsened its first-word pick (eval-v2: Gemma 84→75, Russian 76→63). Ask for
    /// a short phrase and let `postProcess` trim to one word instead.
    var directiveLength: CompletionLength { self == .word ? .short : self }
}

/// How strongly to bias the model toward the user's previously-accepted words.
/// Off by default; collection only happens while this is non-off.
enum PersonalizationLevel: String, CaseIterable {
    case off
    case subtle
    case medium
    case strong

    /// Logit bias added to favored word-start tokens. Kept modest — too high
    /// favors a frequent word over a better-fitting one.
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

    var shiftLabel: String {
        switch self {
        case .tab: return "⇧Tab"
        case .cmdSpace: return "⇧⌘Space"
        case .optSpace: return "⇧⌥Space"
        case .ctrlSpace: return "⇧⌃Space"
        }
    }

    var correctionLabel: String {
        switch self {
        case .tab: return "⌥Tab"
        case .cmdSpace: return "⌥⌘Space"
        case .optSpace: return "⌥⌘Space"
        case .ctrlSpace: return "⌥⌃Space"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .tab: return KeyCode.tab
        case .cmdSpace, .optSpace, .ctrlSpace: return KeyCode.space
        }
    }

    func matchesAcceptWord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let actualFlags = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        switch self {
        case .tab:
            return actualFlags.isEmpty
        case .cmdSpace:
            return actualFlags == [.maskCommand]
        case .optSpace:
            return actualFlags == [.maskAlternate]
        case .ctrlSpace:
            return actualFlags == [.maskControl]
        }
    }

    func matchesAcceptAll(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let actualFlags = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        switch self {
        case .tab:
            return actualFlags == [.maskShift]
        case .cmdSpace:
            return actualFlags == [.maskCommand, .maskShift]
        case .optSpace:
            return actualFlags == [.maskAlternate, .maskShift]
        case .ctrlSpace:
            return actualFlags == [.maskControl, .maskShift]
        }
    }

    func matchesCorrection(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let actualFlags = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        switch self {
        case .tab:
            return actualFlags == [.maskAlternate]
        case .cmdSpace:
            return actualFlags == [.maskCommand, .maskAlternate]
        case .optSpace:
            return actualFlags == [.maskCommand, .maskAlternate]
        case .ctrlSpace:
            return actualFlags == [.maskControl, .maskAlternate]
        }
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

    /// "English", "English and Russian", "English, Russian and German".
    private static func formatLanguages(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.dropLast().joined(separator: ", ")) and \(names.last ?? "")"
        }
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            "enabled": true,
            "mlxModelID": ModelCatalog.defaultID,
            "debounceMs": 120,
            "maxContextChars": 1200,
            "idleUnloadMinutes": 5,
            "fimEnabled": true,
            // Default to the instruct path: it hits ≥70% first-word at the
            // minimum viable load (Gemma 4 it-6bit, ~6.8 GB), where base and
            // lighter quants fall off a quality cliff.
            "completionStyle": CompletionStyle.instruct.rawValue,
            "completionLength": CompletionLength.short.rawValue,
            "customInstructions": defaultInstructions,
            "personalizationLevel": PersonalizationLevel.off.rawValue,
            "suggestionPresentation": SuggestionPresentation.inline.rawValue,
            "fmPromptVariant": FMPromptVariant.fewshot.rawValue,
            "useRecommendedSettings": true,
            "confidenceGate": false,
            "confidenceGateSamples": 5,
            // 0.6 (≥3/5 draws agree) clears a 35% first-word bar on real text at
            // the most coverage (~54%); 0.8/1.0 trade coverage for precision.
            "confidenceGateThreshold": 0.6,
            "userBlacklist": [String](),
            "suggestionJournal": true,
            "personalExamples": true,
            "ghostOpacity": 0.45,
            "hotkeyStyle": HotkeyStyle.tab.rawValue,
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

    /// Retrieval-augmented few-shot: inject the user's own most-similar past
    /// accepted phrases into the instruct prompt. A no-op until the journal has
    /// data; the eval harness A/Bs it via PRETYPE_RAG.
    static var personalExamplesEnabled: Bool {
        get { defaults.bool(forKey: "personalExamples") }
        set { defaults.set(newValue, forKey: "personalExamples") }
    }

    /// Opt-in OCR of the focused window for richer model context.
    static var screenContextEnabled: Bool {
        get { defaults.bool(forKey: "screenContext") }
        set { defaults.set(newValue, forKey: "screenContext") }
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

    /// Self-consistency confidence gate: when on, the MLX engine samples each
    /// completion `confidenceGateSamples` times and only suggests when the first
    /// word agrees on ≥`confidenceGateThreshold` of the draws (else abstains).
    /// Much higher first-word precision on real text at a coverage + ~K× latency
    /// cost (see Eval/BASELINE.md). Off by default.
    static var confidenceGate: Bool {
        get { defaults.bool(forKey: "confidenceGate") }
        set { defaults.set(newValue, forKey: "confidenceGate") }
    }
    static var confidenceGateSamples: Int {
        get { max(2, defaults.integer(forKey: "confidenceGateSamples")) }
        set { defaults.set(newValue, forKey: "confidenceGateSamples") }
    }
    static var confidenceGateThreshold: Double {
        get { let v = defaults.double(forKey: "confidenceGateThreshold"); return v > 0 ? v : 0.6 }
        set { defaults.set(newValue, forKey: "confidenceGateThreshold") }
    }

    /// Free the resident MLX model after this many minutes idle (0 = never). A
    /// background menu-bar app shouldn't hold several GB while unused; the next
    /// focus/keystroke reloads it from the on-disk cache.
    static var idleUnloadMinutes: Int {
        get { defaults.integer(forKey: "idleUnloadMinutes") }
        set { defaults.set(newValue, forKey: "idleUnloadMinutes") }
    }

    /// Fill-in-the-middle: when editing mid-sentence, condition the completion on
    /// the text after the cursor too. Auto-applies only on E4B-class models (it's
    /// unreliable on the smaller E2B). On by default.
    static var fimEnabled: Bool {
        get { defaults.bool(forKey: "fimEnabled") }
        set { defaults.set(newValue, forKey: "fimEnabled") }
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

    /// Strength of favored-word logit biasing. Off disables learning too.
    static var personalizationLevel: PersonalizationLevel {
        get { PersonalizationLevel(rawValue: defaults.string(forKey: "personalizationLevel") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "personalizationLevel") }
    }

    /// Inline ghost text vs a floating panel beside the caret.
    static var suggestionPresentation: SuggestionPresentation {
        get { SuggestionPresentation(rawValue: defaults.string(forKey: "suggestionPresentation") ?? "") ?? .inline }
        set { defaults.set(newValue.rawValue, forKey: "suggestionPresentation") }
    }

    /// Prompt recipe for the Apple Intelligence engine (no effect on the MLX
    /// path). `fewshot` measured best on eval-v2; `directive` is fastest. The
    /// env override `PRETYPE_FM_PROMPT_VARIANT` still wins for A/B in the harness.
    static var fmPromptVariant: FMPromptVariant {
        get { FMPromptVariant(rawValue: defaults.string(forKey: "fmPromptVariant") ?? "") ?? .fewshot }
        set { defaults.set(newValue.rawValue, forKey: "fmPromptVariant") }
    }

    static var ghostOpacity: Double {
        get { defaults.double(forKey: "ghostOpacity") }
        set { defaults.set(newValue, forKey: "ghostOpacity") }
    }

    static var hotkeyStyle: HotkeyStyle {
        get { HotkeyStyle(rawValue: defaults.string(forKey: "hotkeyStyle") ?? "") ?? .tab }
        set { defaults.set(newValue.rawValue, forKey: "hotkeyStyle") }
    }
}
