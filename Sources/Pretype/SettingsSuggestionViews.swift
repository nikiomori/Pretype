import AppKit
import AVFoundation
import Carbon
import SwiftUI

struct SuggestionLineMock: View {
    static let typed = String(localized: "Write ", comment: "Settings overlay preview: the sample sentence “Write a reply to Anna” is drawn in three parts. This is part 1, the text typed before the caret. Keep the trailing space.")
    static let chunk = String(localized: "a reply", comment: "Settings overlay preview: the sample sentence “Write a reply to Anna” is drawn in three parts. This is part 2, the suggestion's first chunk right after the caret.")
    static let rest = String(localized: " to Anna", comment: "Settings overlay preview: the sample sentence “Write a reply to Anna” is drawn in three parts. This is part 3, the rest of the suggestion up to its end. Keep the leading space.")
    static let wordTyped = String(localized: "See you tomo", comment: "Settings → Suggestions → Words: sample text typed so far, ending in the middle of a word. Part 1 of “See you tomorrow”: cut a common word of your language so that “rrow” (part 2) completes it.")
    static let wordRest = String(localized: "rrow", comment: "Settings → Suggestions → Words: the rest of the half-typed word in “See you tomo”. Together the two parts read “See you tomorrow”.")

    /// The sample line: typed text, the ⇥ chunk, the rest — a phrase, or with
    /// `words` the end of the word being typed.
    static func sample(words: Bool) -> (typed: String, chunk: String, rest: String) {
        words ? (wordTyped, wordRest, "") : (typed, chunk, rest)
    }

    let presentation: SuggestionPresentation
    let opacity: Double
    let hotkey: String
    /// Words mode's sample. Every preview draws the mode AND the display
    /// that are picked, so the two choices never show two different looks.
    var words = false
    private let ink = Color.primary

    var body: some View {
        // The slider dims inline ghost text; the panel pill is an opaque HUD and
        // stays full-strength, so the preview must not move it either — else it
        // promises an effect the real panel never applies.
        let effective = presentation == .inline ? opacity : 1.0
        // Same split the real ghost draws with (SuggestionWindow.suggestionGhost):
        // the ⇥ chunk at full strength, the tail at 0.72 — a preview that dimmed
        // differently promised a look the caret never delivered.
        let head = ink.opacity(1.0 * effective)
        let tail = ink.opacity(0.72 * effective)
        let (typed, chunk, rest) = Self.sample(words: words)
        return Group {
            if presentation == .inline {
                // The ghost, then the accept keycap a new user sees beside it.
                HStack(spacing: 6) {
                    Text("\(Text(typed).foregroundColor(ink))\(Text(chunk).foregroundColor(head))\(Text(rest).foregroundColor(tail))")
                    MenuHintsView.keycap(hotkey)
                        .opacity(min(1, effective / 0.7))
                }
            } else {
                // The pill floats just ABOVE the line, starting at the caret —
                // where the real one sits — never beside the typed words.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(typed).hidden()
                        HStack(spacing: 6) {
                            Text("\(Text(chunk).foregroundColor(ink))\(Text(rest).foregroundColor(ink.opacity(0.55)))")
                            MenuHintsView.keycap(hotkey)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ink.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(ink.opacity(0.15), lineWidth: 0.5))
                    }
                    Text(typed).foregroundColor(ink)
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        // One description for VoiceOver instead of the sample sentence read
        // word by word.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation == .inline
            ? (words ? Text("Preview: grey letters finish the word after the cursor")
                     : Text("Preview: grey suggestion text continues the line after the cursor"))
            : Text("Preview: the suggestion floats in a small box above the line"))
    }
}

/// A pick-one card that shows its choice in miniature — the line at the
/// caret as it would look — so the choice is visual, not abstract.
struct PreviewCard<Preview: View>: View {
    let title: String
    /// What this choice is, in one line: each card says its own, so neither
    /// has to be picked to be understood.
    let subtitle: String
    /// Short status tag beside the title (e.g. "Unstable").
    var badge: String? = nil
    /// What the choice costs, as a tinted line under the subtitle — "No
    /// model" against "E4B 6-bit · 5.0 GB" reads before any sentence does.
    var cost: (symbol: String, text: String, tint: Color)? = nil
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview
    /// Local hover only — a card highlight, never published to the store the
    /// Form observes (that path hitches list scrolling).
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                    preview()
                        .padding(.horizontal, 10)
                }
                .frame(height: 44)
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange.legible)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                    Spacer()
                    SelectionMark(isOn: isSelected)
                }
                Caption(subtitle)
                if let cost {
                    Label(cost.text, systemImage: cost.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(cost.tint.legible)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(cost.tint.opacity(0.13), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .choiceCard(isSelected: isSelected, hovering: hovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityHint(cost.map { "\(subtitle) \($0.text)" } ?? subtitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Suggestion tuning

/// Style and length: the Model pane's advanced section. "Use recommended
/// settings" sets both per model, and most people never leave it.
struct TuningSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Section("Suggestions") {
            // Apple Intelligence runs as the macOS system model on the Neural
            // Engine: Style and the precision gate never reach it
            // (EngineCoordinator sends only length + persona).
            if store.isAppleIntelligence {
                Caption(String(localized: "Style and precision don't apply to Apple Intelligence."))
            } else {
                Toggle(isOn: $store.useRecommended) {
                    Text("Use recommended settings")
                    if store.useRecommended {
                        Text("Now \(store.recommendation.summary). Changing Style or Length turns this off.")
                    } else {
                        Text("Best for this model: \(store.recommendation.summary).")
                    }
                }
                .onHover { store.setHover(.useRecommended(!store.useRecommended), $0) }
                LabeledContent {
                    HoverSegments(title: String(localized: "Style"),
                                  options: CompletionStyle.allCases.map { ($0, $0.label) },
                                  selection: store.style,
                                  select: { style in
                                      // Base↔Instruct inserts/removes the
                                      // length row and the precision cards.
                                      withAnimation(.easeInOut(duration: 0.18)) { store.style = style }
                                  },
                                  hover: { style, hovering in
                                      store.setHover(.style(style), hovering)
                                  })
                        .frame(width: 220)
                } label: {
                    Text("Style")
                    if store.style == .instruct {
                        Text("Follows your persona. Loads a second model.")
                    } else {
                        Text("Continues your text. Most accurate on everyday typing.")
                    }
                }
                if store.style == .instruct, store.instructUnusable {
                    RequirementRow(met: false,
                                   text: String(localized: "Instruct doesn't work on \(store.selectedModelName)"),
                                   fixTitle: String(localized: "Switch to Base")) { withAnimation(.easeInOut(duration: 0.18)) { store.style = .base } }
                        .help("It answers the text instead of continuing it. Instruct needs a Gemma E4B model.")
                }
            }
            // Base style's entropy stop ends a suggestion inside even Short's
            // budget (identical output at all three lengths, 2026-10-15), so
            // the control only shows where it does something. Apple
            // Intelligence reads length whatever the style says.
            if store.style != .base || store.isAppleIntelligence {
                LabeledContent {
                    HoverSegments(title: String(localized: "Length"),
                                  options: CompletionLength.allCases.map { ($0, $0.label) },
                                  selection: store.length,
                                  select: { store.length = $0 },
                                  hover: { length, hovering in
                                      store.setHover(.length(length), hovering)
                                  })
                        .frame(width: 260)
                } label: {
                    Text("Length")
                    Text(lengthLine)
                }
            }
        }
    }

    /// How far one suggestion runs and what it costs, from the projection
    /// the rail reads (measured on the EN+RU core, 2026-10-15).
    private var lengthLine: String {
        // One whole sentence per case, with and without the latency.
        let each = ConfigProjection.project(store.committedConfig).p50Ms.map { latencyLabel(ms: $0) }
        switch store.length {
        case .short:
            return each.map { String(localized: "2–3 words ahead, about \($0) each.") }
                ?? String(localized: "2–3 words ahead.")
        case .medium:
            return each.map { String(localized: "Up to ~6 words ahead, about \($0) each.") }
                ?? String(localized: "Up to ~6 words ahead.")
        case .long:
            return each.map { String(localized: "Up to a sentence ahead, about \($0) each.") }
                ?? String(localized: "Up to a sentence ahead.")
        }
    }
}
