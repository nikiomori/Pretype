import AppKit
import ScreenCaptureKit

/// Samples the host app's background right where the overlay draws, so the
/// suggestion window can flip its appearance (dark text over light fields,
/// light text over dark) independently of the system theme. A dark editor
/// under a light system — or a white web page under a dark one — is exactly
/// where the ghost text and correction pill used to become unreadable: their
/// semantic colors resolved against the *system* appearance, not the pixels
/// they actually sit on.
///
/// Uses ScreenCaptureKit only when the user already granted Screen Recording
/// (the same opt-in permission as the OCR screen context). Without it the
/// overlay keeps following the system appearance, exactly as before.
@MainActor
final class BackgroundProbe {
    /// Latest verdict; nil = unknown → follow the system appearance.
    private(set) var appearance: NSAppearance?

    /// Forget the verdict: it described the pixels under another field's caret.
    /// Without this, a dark verdict cached in the previous app outranks the new
    /// field's own AX-reported background (the probe is deliberately the top
    /// rung of the tone resolver) until the next async sample lands.
    func invalidate() {
        appearance = nil
        lastRect = .null
        lastAt = 0
    }

    private var lastRect = CGRect.null
    private var lastAt: CFAbsoluteTime = 0
    private var inFlight = false

    /// Hand the cached appearance to `apply` immediately, then re-sample near
    /// `caretRect` (Cocoa screen coordinates) and call `apply` again if the
    /// verdict changed. Throttled: the same spot within 0.7 s reuses the cache,
    /// so per-keystroke callers cost nothing between samples.
    func refresh(near caretRect: CGRect, apply: @escaping (NSAppearance?) -> Void) {
        apply(appearance)
        let now = CFAbsoluteTimeGetCurrent()
        let moved = abs(caretRect.midY - lastRect.midY) > caretRect.height
            || abs(caretRect.midX - lastRect.midX) > 200
        guard !inFlight, moved || now - lastAt > 0.7,
              CGPreflightScreenCaptureAccess() else { return }
        inFlight = true
        lastRect = caretRect
        lastAt = now

        // Sample the line background just right of the caret — where the ghost
        // draws. Text hasn't been typed there yet, so it's clean background.
        let sample = CGRect(x: caretRect.maxX + 2, y: caretRect.minY,
                            width: 60, height: max(4, caretRect.height))
        let cgRect = Self.quartzRect(sample)
        Task { [weak self] in
            let luminance = await Self.sampleLuminance(in: cgRect)
            guard let self else { return }
            self.inFlight = false
            guard let luminance else { return }
            // Hysteresis: mid-gray backgrounds keep the previous verdict
            // instead of flickering between themes at a hard threshold.
            if luminance < 0.42 {
                self.appearance = NSAppearance(named: .darkAqua)
            } else if luminance > 0.58 {
                self.appearance = NSAppearance(named: .aqua)
            }
            apply(self.appearance)
        }
    }

    /// Cocoa (bottom-left origin) → CG global (top-left origin) coordinates.
    private static func quartzRect(_ cocoaRect: CGRect) -> CGRect {
        var r = cocoaRect
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        r.origin.y = (primary?.frame.height ?? 0) - r.origin.y - r.height
        return r
    }

    /// Mean relative luminance (0 dark … 1 light) of the screen area, with the
    /// overlay's own app excluded from the capture so it never samples itself.
    nonisolated private static func sampleLuminance(in cgRect: CGRect) async -> CGFloat? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.frame.intersects(cgRect) })
            else { return nil }
            let ownApp = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: ownApp,
                                         exceptingWindows: [])
            let local = cgRect
                .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            guard !local.isEmpty else { return nil }
            let config = SCStreamConfiguration()
            config.sourceRect = local
            config.width = 8
            config.height = 4
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return meanLuminance(of: image)
        } catch {
            return nil
        }
    }

    /// Average the capture down to one sRGB pixel and read its luminance.
    /// Internal (not private) so the byte-order/color-space assumptions have a test.
    nonisolated static func meanLuminance(of image: CGImage) -> CGFloat? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = ctx.data else { return nil }
        let px = data.assumingMemoryBound(to: UInt8.self)
        let r = CGFloat(px[0]) / 255, g = CGFloat(px[1]) / 255, b = CGFloat(px[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
