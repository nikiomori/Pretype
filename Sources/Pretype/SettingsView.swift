import AppKit
import AVFoundation
import Carbon
import SwiftUI

extension Color {
    /// This tint as small TEXT, at 4.5:1 or better on a grouped form in both
    /// appearances. Light: system green, orange and teal at caption size sit
    /// near 2:1, and a 35% darkening still left them at 3.7:1 — 45% clears
    /// it. Dark: purple and blue sat at 3.7:1 untouched; a fifth of white
    /// lifts them.
    var legible: Color {
        let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? (resolved.blended(withFraction: 0.2, of: .white) ?? resolved)
                : (resolved.blended(withFraction: 0.45, of: .black) ?? resolved)
        })
    }
}

/// One requirement of a currently-unavailable feature: a ✓/✗ line with a
/// one-click fix, so "why is this greyed out" is visible and actionable
/// instead of a sentence the user has to decode.
struct RequirementRow: View {
    let met: Bool
    let text: String
    let fixTitle: String
    let fix: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(met ? Color.green : Color.orange)
                .font(.caption)
                // Not just symbol + color: VoiceOver read the row the same either way.
                .accessibilityLabel(met ? Text("Done") : Text("Missing"))
            Text(text)
                .font(.caption)
                .foregroundStyle(met ? Color.secondary : Color.primary)
            if !met {
                // .mini is a ~14pt target on the one button whose job is
                // rescuing a blocked state — .small is the smallest honest size.
                Button(fixTitle, action: fix)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }
}

/// Secondary explanatory text under a control (System Settings caption style).
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One decimal in the user's own number format: "1.2" or "1,2".
func oneDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

/// "640 ms", "1.2 s": past a second, milliseconds read as seconds.
func latencyLabel(ms: Int) -> String {
    ms >= 1000 ? String(localized: "\(oneDecimal(Double(ms) / 1000)) s") : String(localized: "\(ms) ms")
}

/// "1.4 GB" — one decimal, the unit through the catalog; "0 GB" for the
/// system model, which holds no app memory.
func gbLabel(_ gb: Double) -> String {
    gb <= 0 ? String(localized: "0 GB") : String(localized: "\(oneDecimal(gb)) GB")
}

// MARK: - Root

enum SettingsTab: String, CaseIterable {
    case general, model, dictation, personalization, api

    /// Sidebar icon, drawn as a tile in `tint`.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .model: return "cpu.fill"
        case .dictation: return "mic.fill"
        case .personalization: return "person.fill"
        case .api: return "cloud.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .model: return .purple
        case .dictation: return .red
        case .personalization: return .blue
        case .api: return .teal
        }
    }

    /// Sidebar label and pane title.
    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .model: return String(localized: "Model")
        case .dictation: return String(localized: "Dictation")
        case .personalization: return String(localized: "Personalization")
        case .api: return String(localized: "API")
        }
    }

    /// Whether the pane has rows behind the header's Advanced switch.
    var hasAdvanced: Bool { [.model, .dictation, .personalization].contains(self) }
}

/// A System Settings icon tile: a white glyph on a colored rounded square,
/// so a row is found by its picture before its words are read.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row title with its icon tile and an optional one-line subtitle — the
/// label of the main switches.
struct IconLabel: View {
    let symbol: String
    let tint: Color
    let title: Text
    var subtitle: Text?

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                title
                if let subtitle {
                    subtitle.font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The ✓ of a pick-one card, and an empty ring in the same spot when it
/// isn't picked — so a row of cards reads as one choice before any click.
struct SelectionMark: View {
    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.callout)
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
            .accessibilityHidden(true)  // the card's .isSelected trait says it
    }
}

extension View {
    /// The one look of every pick-one card (display, goal, precision):
    /// separator stroke, a darker one on hover, and an accent ring with a
    /// faint accent fill when picked.
    func choiceCard(isSelected: Bool, hovering: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return padding(10)
            .background(shape.fill(isSelected ? Color.accentColor.opacity(0.08)
                                   : (hovering ? Color.primary.opacity(0.04) : Color.clear)))
            .overlay(shape.stroke(isSelected ? Color.accentColor
                                  : (hovering ? Color.primary.opacity(0.22) : Color(nsColor: .separatorColor)),
                                  lineWidth: isSelected ? 2 : 1))
            .contentShape(shape)
    }
}

/// Sidebar + pane + Live Impact inspector — the System Settings shape of the
/// new macOS: navigation and the rail render on system Liquid Glass, content
/// stays on standard grouped-form backgrounds (per the HIG, glass is for the
/// floating layer, never the content itself).
struct SettingsRootView: View {
    @Bindable var store: SettingsStore
    /// One switch for every pane — whoever wants the detail once wants it
    /// everywhere. Rows appear in place, unanimated: rows sliding into a
    /// grouped Form re-laid out the whole pane on every frame of the slide.
    @AppStorage("showAdvancedSettings") private var showAdvanced = false
    /// The pane column's width, for the Form's trailing margin below.
    @State private var paneWidth: CGFloat = 0

    /// A grouped Form stops growing at ~704 pt (plus its own ~22 pt
    /// margins) and centers that column in whatever it's given.
    private static let column: CGFloat = 704

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 1020, minHeight: 620)
        // The window's title (Mission Control, the Window menu, VoiceOver)
        // names the pane, as the visible header does.
        .navigationTitle(store.activeTab.title)
        // On the root, not a tab: rows, cards and the map ask from Model, the
        // Style picker and "Use recommended settings" from Suggestions.
        .confirmationDialog(store.pendingDownload.map { String(localized: "Download \($0.name)?") } ?? "",
                            isPresented: Binding(get: { store.pendingDownload != nil },
                                                 set: { if !$0 { store.pendingDownload = nil } }),
                            presenting: store.pendingDownload) { pending in
            Button("Download") {
                store.pendingDownload = nil
                pending.commit()
            }
            Button("Cancel", role: .cancel) { store.pendingDownload = nil }
        } message: { pending in
            pending.sizeGB > 0
                ? Text("About \(oneDecimal(pending.sizeGB)) GB. Suggestions pause until it's ready.")
                : Text("Suggestions pause until it's ready.")
        }
    }

    private var sidebar: some View {
        List(selection: $store.activeTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Label { Text(tab.title) } icon: { SettingsIcon(symbol: tab.symbol, tint: tab.tint) }
            }
        }
        .listStyle(.sidebar)
        // A settings window's navigation stays put: no button to hide it.
        // On the column's list, under the width — on the split view it's
        // ignored, and over the width it let the column drop below 176 pt.
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 176, ideal: 200, max: 240)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                // The version on hover, not as a tertiary caption under the
                // name: at 10 pt that read 1.9:1, for a figure About and
                // Check for Updates… already give.
                Text(verbatim: "Pretype").font(.headline)
                    .help(Text(verbatim: "Pretype \(UpdateChecker.currentVersion)"))
                Spacer(minLength: 0)
                // The master switch, on every pane: fix, reply and dictation
                // stop with it, same as Pause Pretype in the menu bar.
                Toggle("Pretype", isOn: $store.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Off pauses suggestions, fix, reply and dictation — same as Pause Pretype in the menu bar")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom) {
            EngineStatusFooter(controller: store.controller)
        }
    }

    private var detail: some View {
        HStack(spacing: 0) {
            // The column hugs the sidebar instead of centering: centered, it
            // jumped ~116 pt left whenever the Model rail took its width.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(store.activeTab.title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    // Same spot on every pane that has detail, absent on the
                    // rest; the rows it shows sit where they belong.
                    if store.activeTab.hasAdvanced {
                        Toggle("Advanced", isOn: $showAdvanced)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: Self.column)
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 8)
                ProblemBanner(controller: store.controller)
                    .frame(maxWidth: Self.column)
                    .padding(.horizontal, 22)
                Group {
                    switch store.activeTab {
                    case .general: GeneralTab(store: store)
                    case .model: ModelTab(store: store)
                    case .dictation: DictationTab(store: store)
                    case .personalization: PersonalTab(store: store)
                    case .api: APITab(store: store)
                    }
                }
                // A margin, not a narrower frame: the Form's column moves
                // left while it still scrolls under the pointer anywhere in
                // the pane, with its scroller at the pane's edge.
                .contentMargins(.trailing, max(0, paneWidth - Self.column - 44), for: .scrollContent)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            // The rail measures model settings, so it stands beside the Model
            // pane only. A plain column, not an .inspector: an inspector shown
            // per pane made the split view animate its columns, and the
            // sidebar collapsed and sprang back on every visit to Model.
            if store.activeTab == .model {
                Divider()
                ImpactRailView(store: store)
                    .frame(width: 280)
            }
        }
        // One surface from the title down: the grouped Form's own backdrop
        // differs from the window's, and the title band stood out above it.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The sidebar's engine line: the menu's own status, on its own 1 s clock. A
/// download's byte counts change every tick, and published on the store they
/// re-rendered every tab's Form with them.
private struct EngineStatusFooter: View {
    let controller: SuggestionController?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = StatusMenuController.status(of: controller)
            HStack(alignment: .top, spacing: 7) {
                // A download, a load or a warm-up — never the idle-unloaded
                // resting state, which the menu (and this) calls ready.
                // The detail wraps instead of truncating in a 176pt column.
                Group {
                    if status.color == .systemOrange, controller?.engine.isLoading == true {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Circle().fill(Color(nsColor: status.color))
                    }
                }
                .frame(width: 8, height: 8)
                .padding(.top, 3)   // align with the caption's first baseline
                Text(status.text)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(status.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// A state that stops Pretype, over every pane with the click that fixes it.
/// The sidebar footer says the same in a grey caption at the window's
/// bottom edge — where a window dragged half off-screen hides it, and with
/// nothing to press. The 1 s clock is the footer's: neither state is observed.
private struct ProblemBanner: View {
    let controller: SuggestionController?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if !Permissions.isTrusted {
                banner(String(localized: "Pretype needs Accessibility permission to read the field you're typing in."),
                       action: String(localized: "Grant Accessibility…")) { Permissions.openSettings() }
            } else if let controller, case .failed = controller.engine.state {
                banner(StatusMenuController.status(of: controller).text,
                       action: String(localized: "Retry Loading the Model")) { controller.engineCoordinator.rebuild() }
            }
        }
    }

    private func banner(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)  // the sentence says it
            Text(text)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Segmented control with per-option hover callbacks (the native Picker
/// exposes none). The selection thumb is a single view that SLIDES between
/// segments (matchedGeometryEffect + spring), rendered as an elevated control
/// surface so the selection is unmistakable in both light and dark.
struct HoverSegments<T: Hashable>: View {
    /// Spoken name — the control is one native segmented picker to VoiceOver.
    let title: String
    let options: [(value: T, label: String)]
    let selection: T
    let select: (T) -> Void
    var hover: ((T, Bool) -> Void)?

    @Namespace private var thumbSpace
    @State private var hovered: T?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button { select(option.value) } label: {
                    Text(option.label)
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusable(false)   // one Tab stop for the whole control, below
                .background {
                    if isOn {
                        thumb.matchedGeometryEffect(id: "thumb", in: thumbSpace)
                    } else if hovered == option.value {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.4))
                    }
                }
                .onHover { over in
                    guard isEnabled else { return }
                    hovered = over ? option.value : (hovered == option.value ? nil : hovered)
                    hover?(option.value, over)
                }
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .opacity(isEnabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: selection)
        .animation(.easeOut(duration: 0.12), value: hovered)
        // Like the native control: one Tab stop, arrows move the selection,
        // and VoiceOver reads a segmented picker ("Base, 1 of 2") rather than
        // a row of loose buttons.
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            guard let i = options.firstIndex(where: { $0.value == selection }) else { return }
            let j = direction == .left ? i - 1 : direction == .right ? i + 1 : i
            if j != i, options.indices.contains(j) { select(options[j].value) }
        }
        .accessibilityRepresentation {
            Picker(title, selection: Binding(get: { selection }, set: select)) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }

    /// The sliding selection thumb — an elevated surface that reads clearly in
    /// both themes. macOS 26's `Color.clear.glassEffect` rendered as frosted-
    /// clear over the translucent track: on a light form it matched the
    /// background, so only the bold label marked the selection. A solid control
    /// surface + soft shadow is the native segmented-picker look and is
    /// unmistakable in either appearance.
    private var thumb: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlColor))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}
