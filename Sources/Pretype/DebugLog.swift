import AppKit
import SwiftUI

struct DebugEntry: Identifiable {
    /// Position in the log since launch — stable across the ring's evictions.
    let id: Int
    let date: Date
    let category: String
    let message: String
    let detail: String?
}

/// Always-on ring buffer of pipeline events; the Debug Console window
/// renders it live. Cheap enough to keep enabled permanently.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    private let lock = NSLock()
    private var entries: [DebugEntry] = []
    private let capacity = 400
    private var nextID = 0
    /// A console refresh is already on its way to the main queue.
    private var refreshQueued = false

    func log(_ category: String, _ message: String, detail: String? = nil) {
        let watched = DebugWindowController.shared.isVisible
        lock.lock()
        entries.append(DebugEntry(id: nextID, date: Date(), category: category, message: message, detail: detail))
        nextID += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        // Only pay the main-queue hop when the Debug Console is actually on
        // screen, and only one per burst. At hundreds of entries/second
        // (decode streaming, AX polling) the cross-thread dispatch is the
        // dominant cost when nobody is watching — this makes it free — and a
        // re-render per entry would be the dominant cost when someone is.
        let refresh = watched && !refreshQueued
        if refresh { refreshQueued = true }
        lock.unlock()
        guard refresh else { return }
        DispatchQueue.main.async {
            self.lock.lock()
            self.refreshQueued = false
            self.lock.unlock()
            DebugWindowController.shared.model.reload()
        }
    }

    func snapshot() -> [DebugEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Window

/// Live debug window with filtering, search, and export.
final class DebugWindowController: NSObject, NSWindowDelegate {
    static let shared = DebugWindowController()

    /// Whether the debug window is currently on screen. Checked by `DebugLog`
    /// so the main-queue hop — expensive at hundreds of entries per second —
    /// is skipped when nobody is watching.
    private(set) var isVisible = false
    let model = DebugConsoleModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Pretype Debug Console")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: DebugConsoleView(model: model))
            // Assigning contentViewController resizes to the fitting size — restore.
            window.setContentSize(NSSize(width: 900, height: 600))
            window.minSize = NSSize(width: 600, height: 400)
            window.center()
            self.window = window
        }
        isVisible = true
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the controller and buffer alive; reopening reloads history.
        isVisible = false
    }
}

/// What the console shows, mirrored from the ring buffer on the main queue.
@Observable
final class DebugConsoleModel {
    var entries: [DebugEntry] = []
    /// Entries in the buffer, shown or not — it keeps moving while paused.
    var total = 0
    var paused = false {
        didSet { reload() }
    }
    var showDetails = true
    var autoscroll = true
    var categories: Set<String> = []      // empty = all
    var search = ""

    func reload() {
        let all = DebugLog.shared.snapshot()
        total = all.count
        if !paused { entries = all }
    }

    func clear() {
        DebugLog.shared.clear()
        entries = []
        total = 0
    }

    var shown: [DebugEntry] {
        let needle = search.lowercased()
        return entries.filter { entry in
            (categories.isEmpty || categories.contains(entry.category))
                && (needle.isEmpty
                    || "\(entry.category) \(entry.message) \(entry.detail ?? "")".lowercased().contains(needle))
        }
    }

    /// All categories we know about, in display order, with their colour.
    static let allCategories: [(tag: String, label: String, color: Color)] = [
        ("PROMPT", "Prompt", .teal),
        ("GEN",    "Gen",    .blue),
        ("GATE",   "Gate",   .orange),
        ("SHOW",   "Show",   .green),
        ("ACCEPT", "Accept", .mint),
        ("FIX",    "Fix",    .cyan),
        ("ERROR",  "Error",  .red),
        ("OCR",    "OCR",    .purple),
        ("AX",     "AX",     .brown),
        ("MLX",    "MLX",    .indigo),
        ("FM",     "FM",     .pink),
        ("FOCUS",  "Focus",  .secondary),
    ]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func headline(_ entry: DebugEntry) -> String {
        "\(timeFormatter.string(from: entry.date)) [\(entry.category)] \(entry.message)"
    }

    /// The detail block, indented; `cap` bounds it (the export's limit).
    static func detail(_ entry: DebugEntry, cap: Int? = nil) -> String? {
        guard var detail = entry.detail, !detail.isEmpty else { return nil }
        if let cap, detail.count > cap {
            detail = String(detail.prefix(cap)) + "… (truncated)"
        }
        return detail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    /// Detail blocks (full prompts, raw model output) can run to thousands of
    /// characters of typed/OCR'd content; cap each so an export is a bounded
    /// diagnostic, not a verbatim transcript.
    private static let exportDetailCap = 500

    func export() {
        // The buffer holds fragments of what the user typed — suggestions shown,
        // accepted words, fix originals, raw model output. Writing it to disk
        // turns an in-memory diagnostic into a plaintext record of their content,
        // so make that explicit and require confirmation before the save panel.
        let warning = NSAlert()
        warning.messageText = String(localized: "Export debug log?")
        warning.informativeText = String(localized: "The exported file contains text you typed this session — suggestions, accepted words, and corrections. Only share it with people you trust.")
        warning.addButton(withTitle: String(localized: "Export…"))
        warning.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard warning.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "pretype-debug-\(Int(Date().timeIntervalSince1970)).txt"
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = DebugLog.shared.snapshot().map { entry in
            Self.headline(entry) + "\n"
                + (Self.detail(entry, cap: Self.exportDetailCap).map { $0 + "\n" } ?? "")
        }.joined()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct DebugConsoleView: View {
    @Bindable var model: DebugConsoleModel

    var body: some View {
        let shown = model.shown
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { row($0) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: shown.last?.id) { _, last in
                    if model.autoscroll, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(DebugConsoleModel.allCategories, id: \.tag) { cat in
                        Toggle(cat.label, isOn: Binding(
                            get: { model.categories.contains(cat.tag) },
                            set: { on in
                                if on { model.categories.insert(cat.tag) } else { model.categories.remove(cat.tag) }
                            }))
                            .toggleStyle(.button)
                            .help("Show only \(cat.label) events (with any others picked)")
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                Button("Clear") { model.clear() }
                Button(model.paused ? String(localized: "Resume") : String(localized: "Pause")) { model.paused.toggle() }
                Toggle("Details", isOn: $model.showDetails).toggleStyle(.button)
                Button("Export…") { model.export() }
                Toggle("Autoscroll", isOn: $model.autoscroll)
                Spacer()
                Text("\(shown.count)/\(model.total)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                TextField("Search…", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            .font(.system(size: 11))
            .padding(8)
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func row(_ entry: DebugEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DebugConsoleModel.headline(entry))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DebugConsoleModel.allCategories.first { $0.tag == entry.category }?.color ?? .secondary)
            if model.showDetails, let detail = DebugConsoleModel.detail(entry) {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
