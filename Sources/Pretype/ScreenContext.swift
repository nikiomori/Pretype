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
            case kept, offColumn, lowConfidence, tooShort, typed, notProse, overLimit

            var reason: String {
                switch self {
                case .kept: ""
                case .offColumn: String(localized: "outside the message column")
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

    /// A line as Vision read it. `box` is in window points from the top left.
    struct Reading: Sendable {
        let text: String
        let confidence: Float
        let box: CGRect
    }

    /// The last capture, line by line. Other people's text: it stays in
    /// memory and never reaches the debug log.
    struct Report: Sendable {
        let app: String
        let date: Date
        let region: String
        let lines: [Line]

        var listing: String {
            let when = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
            let rows = lines.isEmpty ? [String(localized: "No text was read.")]
                : lines.map { $0.fate == .kept ? "✓ \($0.text)" : "✗ \($0.fate.reason): \($0.text)" }
            return ([[app, when, region].joined(separator: " · ")] + rows).joined(separator: "\n")
        }
    }

    @MainActor private(set) static var lastReport: Report?

    /// An app's window as ScreenCaptureKit and AX both describe it. `frame`
    /// is in top-left-origin screen points.
    struct Window: Equatable, Sendable {
        let frame: CGRect
        var title: String?
    }

    /// Which of `windows` is the app's focused one: the one AX calls focused,
    /// by frame, by title as well when two sit on the same frame (two
    /// maximized browser windows). With no answer from AX, or a frame that
    /// matches none, the one window holding `caret`: after a miss, only one
    /// about AX's size, because a panel too small to be listed sits over its
    /// parent, under the same caret. nil when that is not exactly one: another
    /// window's text must never reach the prompt, so a doubt reads nothing.
    static func focusedWindow(among windows: [Window], focused: Window?, caret: CGRect?) -> Int? {
        var hits: [Int] = []
        if let focused {
            let framed = windows.indices.filter {
                let frame = windows[$0].frame
                return frame.insetBy(dx: -2, dy: -2).contains(focused.frame)
                    && focused.frame.insetBy(dx: -2, dy: -2).contains(frame)
            }
            let titled = framed.filter { windows[$0].title == focused.title }
            hits = titled.isEmpty ? framed : titled
        }
        if hits.isEmpty, let caret {
            hits = windows.indices.filter { index in
                let frame = windows[index].frame
                return frame.contains(CGPoint(x: caret.midX, y: caret.midY))
                    && focused.map { isAboutTheSame(frame, $0.frame) } ?? true
            }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// ponytail: 80% shared area, a guess at what a frame off by more than the
    /// rounding still looks like; measure real misses if OCR stays empty.
    private static func isAboutTheSame(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return shared.width * shared.height >= 0.8 * max(a.width * a.height, b.width * b.height)
    }

    /// OCR summary of `pid`'s focused window in reading order, deduplicated
    /// against the already-typed text, capped at `maxChars` (keeping the
    /// bottom of the window — in chats that's where the recent messages are).
    /// `field`: a chat's message box, Cocoa coordinates. Then only its column
    /// counts (`sift`) and the whole height is read: a picture above the box
    /// can fill the ±250 pt band and leave the messages out of it.
    /// `wholeWindow`: `caretRect` only finds the window (a reply needs the
    /// exchange above the box, not the band around it).
    static let defaultMaxChars = 600

    static func capture(pid: pid_t, excluding typedText: String, caretRect: CGRect?, field: CGRect? = nil,
                        maxChars: Int = defaultMaxChars, wholeWindow: Bool = false) async -> String? {
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
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid
                    && $0.isOnScreen
                    && $0.windowLayer == 0
                    && $0.frame.width > 200 && $0.frame.height > 150
            }
            guard let index = focusedWindow(among: windows.map { Window(frame: $0.frame, title: $0.title) },
                                            focused: AXText.focusedWindow(of: pid),
                                            caret: (caretRect ?? field).map(AXText.flipped)) else { return nil }
            let window = windows[index]

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
            if field == nil, !wholeWindow, let caret = caretRect {
                let height = window.frame.height
                let top = min(max(0, AXText.flipped(caret).minY - window.frame.minY - 250), height)
                let cropHeight = min(height - top, 500)
                roi = CGRect(x: 0, y: 1 - (top + cropHeight) / height, width: 1, height: cropHeight / height)
            }

            let read = try recognizeText(in: image, regionOfInterest: roi, languages: languages)
            let box = field.map { AXText.flipped($0).offsetBy(dx: -window.frame.minX, dy: -window.frame.minY) }
            let sifted = sift(read, excluding: typedText, field: box, maxChars: maxChars)
            let region = field != nil ? String(localized: "the message column")
                : roi != nil ? String(localized: "250 pt above and below the caret")
                : String(localized: "the whole window")
            let report = Report(app: window.owningApplication?.applicationName ?? "", date: .now,
                                region: region, lines: sifted.lines)
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

    /// The text in a region the user drags out with macOS's own crosshair
    /// (`screencapture -i`: Space picks a window, Escape cancels). nil when
    /// cancelled, "" when nothing was read. The picture is deleted once read.
    /// ponytail: lines join top to bottom, so two columns side by side
    /// interleave; group by column if people copy tables.
    static func readRegion() async -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pretype-region-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-o", url.path]
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch {
                process.terminationHandler = nil
                done.resume()
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let languages = recognitionLanguages(keyboard: await MainActor.run { keyboardLanguages })
        return (try? recognizeText(in: image, regionOfInterest: nil, languages: languages))?
            .map(\.text).joined(separator: "\n") ?? ""
    }

    /// Every line Vision read, top of the window first.
    private static func recognizeText(
        in image: CGImage, regionOfInterest: CGRect?, languages: [String]?
    ) throws -> [Reading] {
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
        // Relative to the region when there is one: only a whole-window read
        // uses `box`.
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { observation -> Reading? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return Reading(text: candidate.string, confidence: candidate.confidence,
                               box: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                           width: box.width * width, height: box.height * height))
            }
    }

    /// The block for the prompt, and what became of each line read. With a
    /// `field` (window points, top left), a line counts only above it and
    /// over its width. A bubble starts a little past the box's edge, so the
    /// edge gives 40 pt; a chat list or a side panel lies farther out. There
    /// a line loses its time, and a reply of one or two words counts: the
    /// rule of three words stood against interface text, and the column has
    /// little of it.
    static func sift(_ read: [Reading], excluding typedText: String, field: CGRect? = nil,
                     maxChars: Int) -> (summary: String?, lines: [Line]) {
        let column = field?.insetBy(dx: -40, dy: 0)
        var lines = read.map { reading -> Line in
            let line = reading.text.trimmingCharacters(in: .whitespaces)
            let text = field == nil ? line : withoutTime(line)
            let fate: Line.Fate
            if let column, reading.box.maxX < column.minX || reading.box.minX > column.maxX {
                fate = .offColumn
            } else if reading.confidence <= 0.4 {
                fate = .lowConfidence
            } else if text.count < (field == nil ? 3 : 2) {
                fate = .tooShort
            } else if typedText.contains(text) || field.map({ reading.box.midY >= $0.minY }) == true {
                // The typed text is already in the prompt; don't duplicate it.
                fate = .typed
            } else {
                fate = looksLikeProse(text, short: field != nil) ? .kept : .notProse
            }
            return Line(text: text.isEmpty ? line : text, fate: fate)
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

    /// A chat prints the time at a bubble's end, and the read marks after it:
    /// "see you 7:47 PM //". OCR reads PM in Cyrillic too, or only its last
    /// letter.
    static func withoutTime(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s*\b\d{1,2}:\d{2}(\s*[AaPpРрАа]?[MmМм])?(\s*[/\\vVwW✓✔]{1,3})?\s*$"#,
                                  with: "", options: .regularExpression)
    }

    /// Keeps conversation/document text, drops terminal prompts, paths,
    /// log lines and ALL-CAPS UI fragments — OCR noise that poisons a prose
    /// model far more than it helps. Script-aware: Han and kana run words
    /// together (4+ letters stand in for 3 words), and a script without case
    /// (Arabic, Hebrew, Hangul, Han) can't be ALL-CAPS. `short` lifts the
    /// length rule.
    static func looksLikeProse(_ line: String, short: Bool = false) -> Bool {
        if line.contains("%") || line.contains("$ ") || line.contains("./")
            || line.contains("~/") || line.contains("://") {
            return false
        }
        let letterCount = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount * 2 >= line.count else { return false }
        let unspaced = line.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
        guard short || (unspaced ? letterCount >= 4 : line.split(separator: " ").count >= 3) else { return false }
        return !line.contains(where: \.isCased) || line.rangeOfCharacter(from: .lowercaseLetters) != nil
    }
}
