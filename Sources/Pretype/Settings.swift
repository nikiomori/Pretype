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

    /// Base language codes of the enabled keyboard layouts, deduped (e.g.
    /// {"en", "ru"}) — the signal behind both the persona languages and the
    /// language-aware `ModelCatalog.defaultID`.
    static var keyboardLanguageCodes: Set<String> {
        Set(keyboardLanguages().compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        })
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
        // Migrate the retired `.word` length (pre-redesign UI offered it) to
        // its successor, so the stored value always matches what the settings
        // surface can display and the projection describes.
        if defaults.string(forKey: "completionLength") == CompletionLength.word.rawValue {
            defaults.set(CompletionLength.short.rawValue, forKey: "completionLength")
        }
        // Controls retired from the UI 2026-07-16/17: the consensus gate (same
        // precision trade as the free logprob gate, at ~5× the decode), the
        // trim toggle (a measured no-cost win — now always on), the FM
        // recipe picker (fewshot measured best; env override still works for
        // the harness), fill-in-the-middle (already auto-gated to the E4B
        // class where it's reliable — the off position only degraded quality)
        // and personal examples (measured instruct win at zero latency cost;
        // journal off / cleared already covers the privacy angle). Clear
        // stored values so the registered defaults rule and nobody is stuck
        // with invisible state.
        for retired in ["confidenceGate", "confidenceTrim", "fmPromptVariant",
                        "fimEnabled", "personalExamples"] {
            defaults.removeObject(forKey: retired)
        }
        // Style/length ship pre-matched to the default model's recommendation:
        // nothing applies it at boot (main only registers defaults), and the
        // engine reads the stored style directly — so a base-only default like
        // MiniCPM5 would otherwise launch in its broken instruct mode.
        let rec = ModelCatalog.recommended(for: ModelCatalog.defaultID)
        defaults.register(defaults: [
            "enabled": true,
            "mlxModelID": ModelCatalog.defaultID,
            "debounceMs": 120,
            "maxContextChars": 1200,
            "idleUnloadMinutes": 5,
            "fimEnabled": true,
            // Follows the default model's recommendation (base·short for the
            // MiniCPM5 default; instruct·short on the Gemma builds).
            "completionStyle": rec.style.rawValue,
            "completionLength": rec.length.rawValue,
            "customInstructions": defaultInstructions,
            // Subtle by default: powers the n-gram first-token boost AND the
            // personal n-gram fast-path; everything stays on-device.
            "personalizationLevel": PersonalizationLevel.subtle.rawValue,
            "suggestionPresentation": SuggestionPresentation.inline.rawValue,
            "fmPromptVariant": FMPromptVariant.fewshot.rawValue,
            "useRecommendedSettings": true,
            "automaticUpdateCheck": true,
            "confidenceGate": false,
            "confidenceGateSamples": 5,
            // 0.6 (≥3/5 draws agree) clears a 35% first-word bar on real text at
            // the most coverage (~54%); 0.8/1.0 trade coverage for precision.
            "confidenceGateThreshold": 0.6,
            "logprobGate": false,
            // Mean first-word logprob floor. Q3 boundary from the eval-real
            // calibration (~11% Net-KSS at ~49% coverage); tune from the journal's
            // captured firstWordLogProb. More negative = laxer, toward 0 = stricter.
            "logprobGateThreshold": -1.5,
            // Confidence trim: cut the suggestion just before the first decode
            // token whose logprob drops below the threshold (never inside the
            // first word) — the fixed-budget tail is a completion's weakest
            // part. Unlike the gates it never abstains, so it's on by default.
            // −1.5 calibrated 2026-07-20 (even-half sweep −4…−1, odd-half
            // verified, MiniCPM + E2B-8bit): cuts ~8 of ~14 garbage-tail chars
            // per row at zero correct-char loss; −1.2/−1 add <1 char and start
            // eating signal. Old −3.0 cut only ~2.7. Eval/runs-2026-07-20.
            "confidenceTrim": true,
            "confidenceTrimThreshold": -1.5,
            "userBlacklist": [String](),
            "suggestionJournal": true,
            "personalExamples": true,
            // 0.45 read as near-invisible over real app backgrounds; 0.7 is
            // still clearly "ghost" next to the host text but survives noise.
            "ghostOpacity": 0.7,
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

    /// Whether Pretype may ask GitHub once a day whether a newer release exists
    /// (see `UpdateChecker`). Off means the app makes no outbound request the
    /// user didn't start. The menu's manual check works either way.
    static var automaticUpdateCheck: Bool {
        get { defaults.bool(forKey: "automaticUpdateCheck") }
        set { defaults.set(newValue, forKey: "automaticUpdateCheck") }
    }

    /// Retrieval-augmented few-shot: inject the user's own most-similar past
    /// accepted phrases into the prompt. A no-op until the journal has data;
    /// the eval harness A/Bs it via PRETYPE_RAG. Always on since 2026-07-17
    /// (UI toggle retired — a measured win at zero cost; clearing the journal
    /// is the way to forget the phrases).
    static var personalExamplesEnabled: Bool {
        get { defaults.bool(forKey: "personalExamples") }
        set { defaults.set(newValue, forKey: "personalExamples") }
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

    /// Logprob confidence gate (base only): abstain when the shown suggestion's
    /// mean first-word logprob is below `logprobGateThreshold`. Same
    /// precision-for-coverage trade as the self-consistency gate but at **0×**
    /// extra decode — the first-word logprob is already captured live by the
    /// decode loop (validated in Eval/BASELINE.md). Off by default.
    static var logprobGate: Bool {
        get { defaults.bool(forKey: "logprobGate") }
        set { defaults.set(newValue, forKey: "logprobGate") }
    }
    static var logprobGateThreshold: Double {
        get { let v = defaults.double(forKey: "logprobGateThreshold"); return v != 0 ? v : -1.5 }
        set { defaults.set(newValue, forKey: "logprobGateThreshold") }
    }

    /// Confidence trim: cut the shown suggestion just before the first decode
    /// token whose logprob falls below `confidenceTrimThreshold` (never inside
    /// the first word). Higher shown-tail precision at 0× extra decode; unlike
    /// the gates it trims instead of abstaining, so it's on by default.
    static var confidenceTrim: Bool {
        get { defaults.bool(forKey: "confidenceTrim") }
        set { defaults.set(newValue, forKey: "confidenceTrim") }
    }
    static var confidenceTrimThreshold: Double {
        get { let v = defaults.double(forKey: "confidenceTrimThreshold"); return v != 0 ? v : -1.5 }
        set { defaults.set(newValue, forKey: "confidenceTrimThreshold") }
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
    /// unreliable on the smaller E2B). Always on since 2026-07-17 (UI toggle
    /// retired — the model-class auto-gate is the only decision that matters).
    static var fimEnabled: Bool {
        get { defaults.bool(forKey: "fimEnabled") }
        set { defaults.set(newValue, forKey: "fimEnabled") }
    }

    /// Which measured axis the Model tab's accuracy surfaces show: "*" =
    /// equal-weight average over all measured languages (the multilingual
    /// default), "core" = the EN+RU booking (largest sample — and the only
    /// axis the settings projections are measured on), or a language code
    /// from `ModelMetrics.evalLanguages`. Presentation-only: never feeds the
    /// completion pipeline.
    static var accuracyAxis: String {
        get { defaults.string(forKey: "accuracyAxis") ?? "*" }
        set { defaults.set(newValue, forKey: "accuracyAxis") }
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
