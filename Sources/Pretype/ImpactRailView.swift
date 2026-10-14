import SwiftUI

/// The Live Impact rail (trailing inspector): the master switch, the active
/// configuration, and four meters — accuracy, speed, memory, compute — for
/// what the committed configuration measures to. Hovering any wired control
/// overlays a ghost band and delta chip showing where that change would move
/// each meter, before anything commits. All figures come from
/// `ConfigProjection` (eval-backed); compute is the one estimate, labeled so.
struct ImpactRailView: View {
    @Bindable var store: SettingsStore

    /// The four meters, top to bottom. Indigo, not red, for Compute: that
    /// meter is mostly full in the default state (longer = lighter load), and
    /// a full red bar reads as an alarm, not a resting figure.
    private static let meters: [(icon: String, tint: Color, label: String,
                                 value: KeyPath<ConfigProjection, String>,
                                 sub: KeyPath<ConfigProjection, String>,
                                 fraction: KeyPath<ConfigProjection, Double?>)] = [
        ("scope", .green, "Accuracy", \.accuracyText, \.accuracySub, \.accuracyFraction),
        ("bolt.fill", .blue, "Speed", \.latencyText, \.latencySub, \.speedFraction),
        ("memorychip", .teal, "Memory", \.memoryText, \.memorySub, \.memoryFraction),
        ("gauge.with.needle", .indigo, "Compute", \.computeText, \.computeSub, \.computeFraction),
    ]

    var body: some View {
        let base = store.projection
        // A hover that lands on the committed runtime (the selected segment,
        // the active preset) previews nothing — treat it as no preview instead
        // of flashing "Previewing change" over identical figures.
        let previewsRuntime = store.previewedConfig
            .map { !$0.sameRuntime(as: store.committedConfig) } ?? false
        let target = previewsRuntime ? store.previewedProjection : nil
        let deltas = previewsRuntime ? store.previewDeltas : []

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // The meters project ON-DEVICE configurations; none of them
                // describes a hosted model, so none is shown while one runs.
                if store.apiText.enabled {
                    Caption("Text runs on an API model, which Pretype hasn't measured. "
                        + "“Test connection” in Settings → API shows its round trip.")
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.meters, id: \.label) { m in
                            MeterView(icon: m.icon, tint: m.tint, label: m.label,
                                      value: base[keyPath: m.value], sub: base[keyPath: m.sub],
                                      fraction: base[keyPath: m.fraction],
                                      previewFraction: target?[keyPath: m.fraction],
                                      previewValue: target?[keyPath: m.value],
                                      delta: deltas.first { $0.label == m.label })
                        }
                    }
                    .opacity(store.enabled ? 1 : 0.4)
                    .animation(.easeOut(duration: 0.25), value: store.enabled)
                }

                footer(target)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live Impact")
                    .font(.headline)
                Spacer()
                // Labeled, not a bare switch: next to the "Live Impact" title an
                // unlabeled toggle reads as showing/hiding the inspector, when it
                // is the master pause — fix, reply and dictation stop with it,
                // so it is named for all of Pretype, not just suggestions.
                Toggle("Pretype", isOn: $store.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.subheadline)
                    .help("Off pauses suggestions, fix, reply and dictation — same as Pause Pretype in the menu bar")
            }
            HStack(spacing: 7) {
                Circle()
                    .fill(store.enabled ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(store.enabled ? store.setupLine : "Paused")
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

    @ViewBuilder private func footer(_ target: ConfigProjection?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target != nil ? "Previewing change" : "Tip")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if let target {
                // The target's own accuracy line — this is where a change
                // whose value lives off the meters (Instruct's authored-text
                // strength, the gate's coverage cost) states its case.
                Text("\(target.accuracyText) accuracy — \(target.accuracySub)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Click to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(tipText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
        // A 1-line tip swapping for a 3-line preview block snapped the rail on
        // every hover enter/exit.
        .animation(.easeOut(duration: 0.2), value: target != nil)
    }

    /// The idle tip, tab-aware: only Model and Suggestions controls drive a
    /// hover preview, so General/Personalization describe the rail as a
    /// read-only readout rather than inviting a hover that does nothing there.
    private var tipText: String {
        switch store.activeTab {
        case .model:
            return "Hover a model to preview it. Bigger bubble = more memory."
        case .suggestions:
            return "Hover any control to see exactly what it improves or costs — before you commit."
        case .general, .personalization, .api:
            return "A live readout of your current setup. Hover a control on the Model or Suggestions tab to preview a change before it commits."
        }
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
    let sub: String
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
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
