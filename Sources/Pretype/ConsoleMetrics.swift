import Foundation

/// Session-scoped pipeline metrics derived from the `DebugLog` ring buffer.
/// No separate instrumentation is needed: GEN entries already carry timing, and
/// SHOW/ACCEPT/GATE categories mark the pipeline stages. Values reflect only
/// what is still in the 400-entry buffer (they roll over on busy sessions).
struct DebugMetrics {
    let completions: Int        // GEN events
    let shown: Int              // SHOW events
    let accepted: Int           // ACCEPT events
    let abstains: Int           // GATE rejections

    let avgLatencyMs: Double
    let avgDecodeTokPerS: Double
    let avgPrefillTokPerS: Double

    /// Accepted / shown. The headline quality signal at a glance.
    var acceptRate: Double { shown > 0 ? Double(accepted) / Double(shown) : 0 }
    /// Gated / (shown + gated): how often the engine chose to stay silent.
    var abstainRate: Double {
        let attempts = shown + abstains
        return attempts > 0 ? Double(abstains) / Double(attempts) : 0
    }

    static func from(_ entries: [DebugEntry]) -> DebugMetrics {
        var gen = 0, shown = 0, accepted = 0, abstains = 0
        var latMsSum = 0.0, latMsN = 0
        var decodeSum = 0.0, decodeN = 0
        var prefillSum = 0.0, prefillN = 0

        for e in entries {
            switch e.category {
            case "GEN":
                gen += 1
                if let ms = capture(prefillRe, 2, in: e.message) { latMsSum += ms; latMsN += 1 }
                if let ms = capture(decodeRe, 2, in: e.message) { latMsSum += ms }
                if let v = capture(decodeRe, 3, in: e.message) { decodeSum += v; decodeN += 1 }
                if let v = capture(prefillRe, 3, in: e.message) { prefillSum += v; prefillN += 1 }
            case "SHOW": shown += 1
            case "ACCEPT": accepted += 1
            case "GATE": abstains += 1
            default: break
            }
        }
        return DebugMetrics(
            completions: gen, shown: shown, accepted: accepted, abstains: abstains,
            avgLatencyMs: latMsN > 0 ? latMsSum / Double(latMsN) : 0,
            avgDecodeTokPerS: decodeN > 0 ? decodeSum / Double(decodeN) : 0,
            avgPrefillTokPerS: prefillN > 0 ? prefillSum / Double(prefillN) : 0
        )
    }

    // GEN message format (MLXEngine):
    //   reused=YES prefill=42tok/12ms (348 tok/s) decode=5tok/41ms (121 tok/s)
    // Constant patterns — cannot fail at runtime.
    // swiftlint:disable force_try
    private static let prefillRe = try! NSRegularExpression(
        pattern: "prefill=(\\d+)tok/([0-9.]+)ms \\(([0-9.]+) tok/s\\)")
    private static let decodeRe = try! NSRegularExpression(
        pattern: "decode=(\\d+)tok/([0-9.]+)ms \\(([0-9.]+) tok/s\\)")
    // swiftlint:enable force_try

    /// Capture group `group` of the first match of `re` in `s`, as a number.
    private static func capture(_ re: NSRegularExpression, _ group: Int, in s: String) -> Double? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            .flatMap { Range($0.range(at: group), in: s) }
            .flatMap { Double(s[$0]) }
    }
}
