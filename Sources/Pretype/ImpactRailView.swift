import SwiftUI

/// The Live Impact rail (trailing inspector): the master switch, the active
/// configuration, and four meters — accuracy, speed, memory, compute — for
/// what the committed configuration measures to. Hovering any wired control
/// overlays a ghost band and delta chip showing where that change would move
/// each meter, before anything commits. All figures come from
/// `ConfigProjection` (eval-backed); compute is the one estimate, labeled so.
struct ImpactRailView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let base = store.projection
        let target = store.previewedProjection
        let deltas = store.previewDeltas

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 14) {
                    MeterView(icon: "scope", tint: .green, label: "Accuracy",
                              value: base.accuracyText, sub: base.accuracySub,
                              fraction: base.accuracyFraction,
                              previewFraction: target?.accuracyFraction,
                              delta: deltas.first { $0.label == "Accuracy" })
                    MeterView(icon: "bolt.fill", tint: .blue, label: "Speed",
                              value: base.latencyText, sub: base.latencySub,
                              fraction: base.speedFraction,
                              previewFraction: target?.speedFraction,
                              delta: deltas.first { $0.label == "Speed" })
                    MeterView(icon: "memorychip", tint: .teal, label: "Memory",
                              value: base.memoryText, sub: base.memorySub,
                              fraction: base.memoryFraction,
                              previewFraction: target?.memoryFraction,
                              delta: deltas.first { $0.label == "Memory" })
                    MeterView(icon: "gauge.with.needle", tint: .red, label: "Compute",
                              value: base.computeText, sub: base.computeSub,
                              fraction: base.computeFraction,
                              previewFraction: target?.computeFraction,
                              delta: deltas.first { $0.label == "Compute" })
                }
                .opacity(store.enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.25), value: store.enabled)

                footer
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
                Toggle("Enable suggestions", isOn: $store.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(store.enabled ? "Suggestions are on" : "Suggestions are off")
            }
            HStack(spacing: 7) {
                Circle()
                    .fill(store.enabled ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(store.setupLine)
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

    @ViewBuilder private var footer: some View {
        let previewing = store.previewedProjection != nil
        VStack(alignment: .leading, spacing: 4) {
            Text(previewing ? "Previewing change" : "Tip")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(previewing
                ? "This is where the current configuration would move. Click to apply."
                : (store.activeTab == .model
                    ? "Hover a model to preview it. Bigger bubble = more memory."
                    : "Hover any control to see exactly what it improves or costs — before you commit."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
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
    let delta: ConfigProjection.MetricDelta?

    var body: some View {
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
                        .foregroundStyle(delta.improved ? Color.green : Color.orange)
                }
                Text(value)
                    .font(.callout.monospacedDigit().weight(.bold))
            }
            bar
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        }
        .frame(height: 8)
    }
}
