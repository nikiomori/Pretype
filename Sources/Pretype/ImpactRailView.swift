import SwiftUI

/// The Live Impact rail (the Model pane's trailing column): the active
/// configuration and four meters — accuracy, speed, memory, compute — for
/// what the committed configuration measures to. Hovering any wired control
/// overlays a ghost band and delta chip showing where that change would move
/// each meter, before anything commits. All figures come from
/// `ConfigProjection` (eval-backed); compute is the one estimate, labeled so.
struct ImpactRailView: View {
    @Bindable var store: SettingsStore

    /// The four meters, top to bottom. Indigo, not red, for Compute: that
    /// meter is mostly full in the default state (longer = lighter load), and
    /// a full red bar reads as an alarm, not a resting figure. The source
    /// lines are tooltips: four lines of eval provenance under four bars was
    /// a wall of fine print. `label` is the identity `MetricDelta.label`
    /// matches on and stays English; `title` is what the meter shows.
    private static let meters: [(icon: String, tint: Color, label: String, title: String,
                                 value: KeyPath<ConfigProjection, String>,
                                 help: KeyPath<ConfigProjection, String>,
                                 fraction: KeyPath<ConfigProjection, Double?>)] = [
        ("scope", .green, "Accuracy", String(localized: "Accuracy"), \.accuracyText, \.accuracySub, \.accuracyFraction),
        ("bolt.fill", .blue, "Speed", String(localized: "Speed"), \.latencyText, \.latencySub, \.speedFraction),
        ("memorychip", .teal, "Memory", String(localized: "Memory"), \.memoryText, \.memorySub, \.memoryFraction),
        ("gauge.with.needle", .indigo, "Compute", String(localized: "Compute"), \.computeText, \.computeSub, \.computeFraction),
    ]

    var body: some View {
        let base = store.projection
        // A hover that lands on the committed runtime (the selected segment,
        // the active preset) previews nothing — treat it as no preview instead
        // of offering "Click to apply" over identical figures.
        let previewsRuntime = store.previewedConfig
            .map { !$0.sameRuntime(as: store.committedConfig) } ?? false
        let target = previewsRuntime ? store.previewedConfig.map { ConfigProjection.project($0, pleFromDisk: store.pleFromDisk) } : nil
        let deltas = target.map { ConfigProjection.deltas(from: base, to: $0) } ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // The meters project ON-DEVICE configurations; none of them
                // describes a hosted model, so none is shown while one runs.
                if store.apiText.enabled {
                    Caption(String(localized: "Text runs on \(store.apiText.preset.name). Pretype hasn't measured it."))
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.meters, id: \.label) { m in
                            MeterView(icon: m.icon, tint: m.tint, label: m.title,
                                      value: base[keyPath: m.value],
                                      sub: m.label == "Accuracy" ? coverageLine(base, target) : nil,
                                      help: (target ?? base)[keyPath: m.help],
                                      fraction: base[keyPath: m.fraction],
                                      previewFraction: target?[keyPath: m.fraction],
                                      previewValue: target?[keyPath: m.value],
                                      delta: deltas.first { $0.label == m.label })
                        }
                    }
                    .opacity(store.enabled ? 1 : 0.4)
                    .animation(.easeOut(duration: 0.25), value: store.enabled)
                }

                if target != nil {
                    Text("Click to apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Impact")
                .font(.headline)
            HStack(spacing: 7) {
                Circle()
                    .fill(store.enabled ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                (store.enabled ? Text(store.setupLine) : Text("Paused"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The gate's whole trade is coverage, which no bar shows: "suggests 82%
    /// → 19% of the time" under Accuracy is the one line the rail keeps.
    private func coverageLine(_ base: ConfigProjection, _ target: ConfigProjection?) -> String? {
        guard let now = base.coveragePct else { return nil }
        if let next = target?.coveragePct, next != now {
            return String(localized: "suggests \(now)% → \(next)% of the time")
        }
        return String(localized: "suggests \(now)% of the time")
    }
}

/// One meter: icon + label + optional delta chip + value, then a bar with the
/// committed fill and, while previewing, an outlined ghost band spanning
/// committed → previewed. Bar semantics: longer = better on every axis.
private struct MeterView: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String
    let sub: String?
    /// Where the figure comes from — a tooltip, not a caption.
    let help: String
    let fraction: Double?
    let previewFraction: Double?
    /// The hovered target's value. While previewing, the value area shows
    /// "→ target" instead of the committed figure — a delta chip next to the
    /// OLD number read as a contradiction ("4× slower · 49 ms").
    let previewValue: String?
    let delta: ConfigProjection.MetricDelta?

    var body: some View {
        // One stop per meter: label, delta, value and sub are fragments on their
        // own ("Accuracy", "62%", "first word of shown suggestions…").
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .frame(width: 14)
                    .accessibilityHidden(true)  // decoration: the label names the meter
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let delta {
                    Text(delta.text)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle((delta.improved ? Color.green : Color.orange).legible)
                }
                if let previewValue, previewValue != value {
                    Text("\(Text("→ ").foregroundStyle(.secondary))\(previewValue)")
                        .font(.callout.monospacedDigit().weight(.bold))
                } else {
                    Text(value)
                        .font(.callout.monospacedDigit().weight(.bold))
                }
            }
            .animation(.easeOut(duration: 0.15), value: previewValue)
            bar
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                if let fraction {
                    Capsule().fill(tint)
                        .frame(width: max(6, width * fraction))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
                if let fraction, let preview = previewFraction,
                   abs(preview - fraction) > 0.005 {
                    let lo = min(fraction, preview), hi = max(fraction, preview)
                    Capsule()
                        .strokeBorder(preview > fraction ? Color.green : Color.orange,
                                      lineWidth: 1.5)
                        .frame(width: max(8, width * (hi - lo)))
                        .offset(x: width * lo)
                }
            }
            // The committed fill glided while the preview band popped in beside
            // it. Faster than the fill — this tracks the pointer, not a commit.
            .animation(.easeOut(duration: 0.15), value: previewFraction)
        }
        .frame(height: 8)
    }
}
