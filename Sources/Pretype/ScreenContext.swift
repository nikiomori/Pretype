import AppKit
import ScreenCaptureKit
import Vision

/// Opt-in visual context: a screenshot of the focused app's window, run
/// through local OCR. Gives the model what the text field alone can't —
/// the conversation above a chat box, the email being replied to.
/// Everything stays on device; the captured text is visible in
/// "Show Last Prompt…".
enum ScreenContext {
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Makes Pretype appear in System Settings → Screen Recording: TCC only
    /// lists an app after it actually attempts a capture query, a plain
    /// CGRequestScreenCaptureAccess() is not enough on modern macOS.
    static func registerWithTCC() {
        CGRequestScreenCaptureAccess()
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        }
    }

    /// OCR summary of `pid`'s frontmost window in reading order, deduplicated
    /// against the already-typed text, capped at `maxChars` (keeping the
    /// bottom of the window — in chats that's where the recent messages are).
    static func capture(pid: pid_t, excluding typedText: String, caretRect: CGRect?, maxChars: Int = 600) async -> String? {
        guard hasPermission else { return nil }
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

            return try recognizeText(in: image, regionOfInterest: roi, excluding: typedText, maxChars: maxChars)
        } catch {
            NSLog("Pretype: screen capture failed: %@", error.localizedDescription)
            return nil
        }
    }

    private static func recognizeText(
        in image: CGImage, regionOfInterest: CGRect?, excluding typedText: String, maxChars: Int
    ) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        if let roi = regionOfInterest {
            request.regionOfInterest = roi
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results, !observations.isEmpty else { return nil }

        // Vision's normalized coordinates are bottom-left; top of window first.
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [String] = []
        for observation in sorted {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0.4 else { continue }
            let line = candidate.string.trimmingCharacters(in: .whitespaces)
            guard line.count >= 3 else { continue }
            // The typed text is already in the prompt; don't duplicate it.
            guard !typedText.contains(line) else { continue }
            guard looksLikeProse(line) else { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }

        var summary = lines.joined(separator: "\n")
        if summary.count > maxChars {
            summary = String(summary.suffix(maxChars))
            // Don't start mid-line after the cut.
            if let newline = summary.firstIndex(of: "\n") {
                summary = String(summary[summary.index(after: newline)...])
            }
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // A handful of junk characters is worse than nothing.
        return trimmed.count >= 40 ? trimmed : nil
    }

    /// Keeps conversation/document text, drops terminal prompts, paths,
    /// log lines and ALL-CAPS UI fragments — OCR noise that poisons a prose
    /// model far more than it helps.
    private static func looksLikeProse(_ line: String) -> Bool {
        if line.contains("%") || line.contains("$ ") || line.contains("./")
            || line.contains("~/") || line.contains("://") {
            return false
        }
        let words = line.split(separator: " ")
        guard words.count >= 3 else { return false }
        let letterCount = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount * 2 >= line.count else { return false }
        guard line.rangeOfCharacter(from: .lowercaseLetters) != nil else { return false }
        return true
    }
}
