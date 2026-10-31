import AppKit
import ScreenCaptureKit
import Vision

/// Opt-in visual context: a screenshot of the focused app's window, run
/// through local OCR. Gives the model what the text field alone can't —
/// the conversation above a chat box, the email being replied to.
/// Everything stays on device; the captured text is visible in
/// "Show Last Prompt…", and every line read, kept or not, in
/// "Show Screen Capture…".
enum ScreenContext {
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Makes Pretype appear in System Settings → Screen Recording: TCC only
    /// lists an app after it actually attempts a capture query, a plain
    /// CGRequestScreenCaptureAccess() is not enough on modern macOS. Then
    /// opens that pane. Every "Open System Settings" for Screen Recording
    /// goes through here, or the user lands on a list without us.
    @MainActor static func openScreenRecordingPane() {
        CGRequestScreenCaptureAccess()
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// One line OCR read and what became of it.
    struct Line: Equatable, Sendable {
        enum Fate: Sendable {
            case kept, lowConfidence, tooShort, typed, notProse, overLimit

            var reason: String {
                switch self {
                case .kept: ""
                case .lowConfidence: String(localized: "unsure reading")
                case .tooShort: String(localized: "too short")
                case .typed: String(localized: "already typed")
                case .notProse: String(localized: "not a sentence")
                case .overLimit: String(localized: "over the limit")
                }
            }
        }

        let text: String
        var fate: Fate
    }

    /// The last capture, line by line. Other people's text: it stays in
    /// memory and never reaches the debug log.
    struct Report: Sendable {
        let app: String
        let date: Date
        let aroundCaret: Bool
        let lines: [Line]

        var listing: String {
            let region = aroundCaret ? String(localized: "250 pt above and below the caret")
                                     : String(localized: "the whole window")
            let when = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
            let rows = lines.map { $0.fate == .kept ? "✓ \($0.text)" : "✗ \($0.fate.reason): \($0.text)" }
            return ([[app, when, region].joined(separator: " · ")] + rows).joined(separator: "\n")
        }
    }

    @MainActor private(set) static var lastReport: Report?

    /// OCR summary of `pid`'s frontmost window in reading order, deduplicated
    /// against the already-typed text, capped at `maxChars` (keeping the
    /// bottom of the window — in chats that's where the recent messages are).
    static let defaultMaxChars = 600

    static func capture(pid: pid_t, excluding typedText: String, caretRect: CGRect?,
                        maxChars: Int = defaultMaxChars) async -> String? {
        guard hasPermission else { return nil }
        // Text Input Sources answer on the main thread only.
        let languages = recognitionLanguages(keyboard: await MainActor.run { keyboardLanguages })
        // Privacy floor, mirroring the AX text path: while a password field is
        // engaged anywhere, don't capture the window either — the screenshot
        // would show the field's surroundings (reveal toggles, account data).
        guard !AXText.isSecureInputActive() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            guard let window = content.windows
                .filter({
                    $0.owningApplication?.processID == pid
                        && $0.isOnScreen
                        && $0.windowLayer == 0
                        && $0.frame.width > 200 && $0.frame.height > 150
                })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return nil }

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            // Region of interest: ±250 pt around the caret line, full window
            // width, in Vision's normalized bottom-left space. The caret is
            // flipped into the window frame's top-left-origin space; `top` is
            // clamped into the window so the rect stays inside the unit square.
            var roi: CGRect?
            if let caret = caretRect {
                let height = window.frame.height
                let top = min(max(0, AXText.flipped(caret).minY - window.frame.minY - 250), height)
                let cropHeight = min(height - top, 500)
                roi = CGRect(x: 0, y: 1 - (top + cropHeight) / height, width: 1, height: cropHeight / height)
            }

            let read = try recognizeText(in: image, regionOfInterest: roi, languages: languages)
            let sifted = sift(read, excluding: typedText, maxChars: maxChars)
            let report = Report(app: window.owningApplication?.applicationName ?? "", date: .now,
                                aroundCaret: caretRect != nil, lines: sifted.lines)
            await MainActor.run { lastReport = report }
            return sifted.summary
        } catch {
            NSLog("Pretype: screen capture failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Read once, on the main thread (Text Input Sources answer only there).
    @MainActor private static let keyboardLanguages = Settings.keyboardLanguages()
    private static let supportedLanguages = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []

    /// What Vision reads: the user's keyboard languages, English always among
    /// them (UI text) — when all of them are Latin or Cyrillic, which one
    /// recognizer covers at the same speed. Auto-detection loads a recognizer
    /// per script instead (CJK, Korean, Devanagari, Arabic, Thai — ~10 MB held
    /// for the process). nil keeps detection on: for a language Vision can't
    /// be told to read, and for other scripts, where the list order picks the
    /// recognizer (Japanese first garbled Cyrillic into Latin lookalikes).
    static func recognitionLanguages(keyboard: [String]) -> [String]? {
        let otherScripts: Set<Substring> = ["zh", "yue", "ja", "ko", "th", "ar", "ars", "hi", "mr"]
        func primary(_ code: String) -> Substring { code.lowercased().prefix { $0 != "-" && $0 != "_" } }
        var picked: [String] = []
        for language in keyboard + ["en"] {
            guard let match = supportedLanguages.first(where: { primary($0) == primary(language) }),
                  !otherScripts.contains(primary(match)) else { return nil }
            if !picked.contains(match) { picked.append(match) }
        }
        return picked
    }

    /// Every line Vision read, top of the window first.
    private static func recognizeText(
        in image: CGImage, regionOfInterest: CGRect?, languages: [String]?
    ) throws -> [(text: String, confidence: Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let languages {
            request.recognitionLanguages = languages
        } else {
            request.automaticallyDetectsLanguage = true
        }
        if let roi = regionOfInterest {
            request.regionOfInterest = roi
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        // Vision's normalized coordinates are bottom-left; top of window first.
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first }
            .map { (text: $0.string, confidence: $0.confidence) }
    }

    /// The block for the prompt, and what became of each line read.
    static func sift(_ read: [(text: String, confidence: Float)], excluding typedText: String,
                     maxChars: Int) -> (summary: String?, lines: [Line]) {
        var lines = read.map { raw -> Line in
            let text = raw.text.trimmingCharacters(in: .whitespaces)
            let fate: Line.Fate
            if raw.confidence <= 0.4 {
                fate = .lowConfidence
            } else if text.count < 3 {
                fate = .tooShort
            } else if typedText.contains(text) {
                // The typed text is already in the prompt; don't duplicate it.
                fate = .typed
            } else {
                fate = looksLikeProse(text) ? .kept : .notProse
            }
            return Line(text: text, fate: fate)
        }
        let kept = lines.filter { $0.fate == .kept }.map(\.text)
        guard !kept.isEmpty else { return (nil, lines) }

        var summary = kept.joined(separator: "\n")
        if summary.count > maxChars {
            summary = String(summary.suffix(maxChars))
            // Don't start mid-line after the cut.
            if let newline = summary.firstIndex(of: "\n") {
                summary = String(summary[summary.index(after: newline)...])
            }
            var cut = kept.count - summary.split(separator: "\n").count
            for index in lines.indices where cut > 0 && lines[index].fate == .kept {
                lines[index].fate = .overLimit
                cut -= 1
            }
        }
        // No floor on the block's length: one short reply above the box is
        // still the conversation (a 40-character floor dropped a third of
        // the chat blocks, and the context gain with them).
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, lines)
    }

    /// Keeps conversation/document text, drops terminal prompts, paths,
    /// log lines and ALL-CAPS UI fragments — OCR noise that poisons a prose
    /// model far more than it helps. Script-aware: Han and kana run words
    /// together (4+ letters stand in for 3 words), and a script without case
    /// (Arabic, Hebrew, Hangul, Han) can't be ALL-CAPS.
    static func looksLikeProse(_ line: String) -> Bool {
        if line.contains("%") || line.contains("$ ") || line.contains("./")
            || line.contains("~/") || line.contains("://") {
            return false
        }
        let letterCount = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount * 2 >= line.count else { return false }
        let unspaced = line.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
        guard unspaced ? letterCount >= 4 : line.split(separator: " ").count >= 3 else { return false }
        return !line.contains(where: \.isCased) || line.rangeOfCharacter(from: .lowercaseLetters) != nil
    }
}
