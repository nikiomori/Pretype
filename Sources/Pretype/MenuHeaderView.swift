import SwiftUI

/// The status menu's header and footer, drawn rather than written: an NSMenu can
/// only style text, and four grey stat lines stacked over three grey keycap
/// lines read as a log dump. Both are non-interactive, which is what makes a
/// custom `NSMenuItem.view` safe here — no highlight or keyboard-navigation
/// behaviour to reimplement.
///
/// The visual language is the settings rail's (`ImpactRailView`): 7pt state dot,
/// semibold caption labels, green for a gain, quaternary rounded chips.
struct MenuHeaderView: View {
    /// Width of the whole menu — the header is its widest item, so this sets it.
    static let width: CGFloat = 268

    /// The gain colour. `systemGreen` clears 4.5:1 on a dark menu but sits near
    /// 2:1 on a light one, and the figure is the one thing here that has to read
    /// instantly — so the light variant is darkened rather than dropped.
    static let gain = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1)
    })

    /// Keycap fill, the same weight as the suggestion pill's own keycaps.
    static let keycapFill = Color.primary.opacity(0.08)

    let statusColor: Color
    let statusText: String
    /// Green: the engine is working, so the status is plumbing and stays quiet.
    /// Anything else is news and takes the foreground back.
    let statusOK: Bool
    let savings: Stats.Savings
    /// The user's accept key, for the empty state's invitation.
    let acceptLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusOK ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if savings.isEmpty {
                Text("Press \(acceptLabel) on a suggestion to start saving typing time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    figure
                    Spacer(minLength: 0)
                    sparkline
                }
                Text("\(savings.totalText) all time · \(savings.totalKeystrokes.formatted()) keystrokes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 5)
        .frame(width: Self.width, alignment: .leading)
        // One stop for VoiceOver, which would otherwise land on a bare figure
        // and then on seven unlabelled bars.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            savings.isEmpty
                ? "\(statusText). Press \(acceptLabel) on a suggestion to start saving typing time."
                : "\(statusText). Saved \(savings.todayText) of typing today, "
                    + "\(savings.totalText) all time."
        )
    }

    /// The number the user came for: value large, unit and caption small, so the
    /// figure reads at a glance from the menu bar.
    private var figure: some View {
        VStack(alignment: .leading, spacing: 0) {
            if savings.todayKeystrokes == 0 {
                Text("Nothing yet today")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                let figure = savings.todayFigure
                (
                    Text(figure.value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    + Text(" \(figure.unit)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                )
                .foregroundStyle(Self.gain)
                .monospacedDigit()
            }
            Text("saved today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Seven days of saving, today last and at full strength. A flat row of
    /// floors is the honest picture of a week with nothing taken, so the bars
    /// keep a minimum height rather than disappearing.
    private var sparkline: some View {
        let peak = max(savings.week.max() ?? 0, 1)
        return VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(savings.week.enumerated()), id: \.offset) { index, saved in
                    let isToday = index == savings.week.count - 1
                    Capsule()
                        .fill(Self.gain.opacity(isToday ? 1 : 0.3))
                        .frame(width: 5, height: max(3, 26 * CGFloat(saved) / CGFloat(peak)))
                }
            }
            .frame(height: 26, alignment: .bottom)
            Text("last 7 days")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The footer's shortcut reminders as real keycaps. Same idea as the suggestion
/// pill's hint, which is where the user first meets this notation.
struct MenuHintsView: View {
    /// `(keys, what it does)`, in the order they're learned.
    let hints: [(keys: String, action: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(hints, id: \.keys) { hint in
                HStack(spacing: 8) {
                    Text(hint.keys)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(MenuHeaderView.keycapFill, in: RoundedRectangle(cornerRadius: 4))
                        // Keycaps differ in width ("Tab" vs "⌥⇧Tab"), and a
                        // ragged column of them left the descriptions stepping in
                        // and out. Only the multi-row form needs the column.
                        .frame(minWidth: hints.count > 1 ? 48 : 0, alignment: .leading)
                    Text(hint.action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(width: MenuHeaderView.width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
