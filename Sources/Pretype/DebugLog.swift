import AppKit

struct DebugEntry {
    let date: Date
    let category: String
    let message: String
    let detail: String?
}

/// Always-on ring buffer of pipeline events; the Debug Console window
/// renders it live. Cheap enough to keep enabled permanently.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    static let didAppend = Notification.Name("PretypeDebugLogDidAppend")

    private let lock = NSLock()
    private var entries: [DebugEntry] = []
    private let capacity = 400

    func log(_ category: String, _ message: String, detail: String? = nil) {
        let entry = DebugEntry(date: Date(), category: category, message: message, detail: detail)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        // Only pay the NotificationCenter cost when the Debug Console is
        // actually on screen. At hundreds of entries/second (decode streaming,
        // AX polling) the cross-thread dispatch is the dominant cost when nobody
        // is watching — this makes it free.
        guard DebugWindowController.shared.isVisible else { return }
        NotificationCenter.default.post(name: Self.didAppend, object: entry)
    }

    func snapshot() -> [DebugEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Window

/// Live debug window with metrics, filtering, search, and export.
final class DebugWindowController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    static let shared = DebugWindowController()

    /// Whether the debug window is currently on screen. Checked by `DebugLog`
    /// so the per-entry `NotificationCenter` post — expensive at hundreds of
    /// entries per second — is skipped when nobody is watching.
    private(set) var isVisible = false

    private var window: NSWindow?
    private var textView: NSTextView?
    private var metricsLabel: NSTextField?
    private var countLabel: NSTextField?

    private var autoscroll = true
    private var paused = false
    private var showDetails = true
    private var observer: NSObjectProtocol?

    private var enabledCategories: Set<String> = []      // empty = all
    private var searchText: String = ""

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// All categories we know about, in display order.
    private static let allCategories: [(tag: String, label: String)] = [
        ("PROMPT", "Prompt"),
        ("GEN",    "Gen"),
        ("GATE",   "Gate"),
        ("SHOW",   "Show"),
        ("ACCEPT", "Accept"),
        ("FIX",    "Fix"),
        ("ERROR",  "Error"),
        ("OCR",    "OCR"),
        ("AX",     "AX"),
        ("MLX",    "MLX"),
        ("FM",     "FM"),
        ("FOCUS",  "Focus"),
    ]

    func show() {
        if window == nil {
            build()
        }
        isVisible = true
        reloadAll()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI construction

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pretype Debug Console"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.minSize = NSSize(width: 600, height: 400)

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        // -- Toolbar row (bottom) --
        let barHeight: CGFloat = 34
        let toolbar = NSView(frame: NSRect(
            x: 0, y: 0,
            width: content.bounds.width, height: barHeight
        ))
        toolbar.autoresizingMask = [.width]

        // -- Filter chips row --
        let filterHeight: CGFloat = 28
        let filterRow = NSView(frame: NSRect(
            x: 0, y: barHeight,
            width: content.bounds.width, height: filterHeight
        ))
        filterRow.autoresizingMask = [.width]

        // -- Metrics bar --
        let metricsHeight: CGFloat = 22
        let metricsBar = NSView(frame: NSRect(
            x: 0, y: barHeight + filterHeight,
            width: content.bounds.width, height: metricsHeight
        ))
        metricsBar.autoresizingMask = [.width]

        // -- Scroll view --
        let scrollTop = barHeight + filterHeight + metricsHeight
        let scroll = NSScrollView(frame: NSRect(
            x: 0, y: scrollTop,
            width: content.bounds.width,
            height: content.bounds.height - scrollTop
        ))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        // Metrics label
        let metricsLabel = NSTextField(labelWithString: "")
        metricsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metricsLabel.textColor = .secondaryLabelColor
        metricsLabel.lineBreakMode = .byTruncatingTail
        metricsLabel.frame = NSRect(x: 8, y: 3, width: metricsBar.bounds.width - 16, height: 16)
        metricsLabel.autoresizingMask = [.width]
        metricsBar.addSubview(metricsLabel)

        // Filter buttons
        buildFilterChips(in: filterRow)

        // Toolbar items
        buildToolbarItems(in: toolbar)

        content.addSubview(scroll)
        content.addSubview(metricsBar)
        content.addSubview(filterRow)
        content.addSubview(toolbar)
        window.contentView = content

        self.window = window
        self.textView = textView
        self.metricsLabel = metricsLabel

        observer = NotificationCenter.default.addObserver(
            forName: DebugLog.didAppend, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let entry = note.object as? DebugEntry else { return }
            if self.paused {
                // While paused we don't render, but we still want the counter.
                DispatchQueue.main.async { self.updateCount() }
                return
            }
            DispatchQueue.main.async {
                self.appendIfVisible(entry)
                self.updateMetrics()
            }
        }

        // Refresh metrics periodically.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateMetrics() }
        }
    }

    // MARK: - Filter chips

    private var categoryButtons: [String: NSButton] = [:]

    private func buildFilterChips(in container: NSView) {
        var x: CGFloat = 8
        for cat in Self.allCategories {
            let button = NSButton(
                checkboxWithTitle: cat.label,
                target: self,
                action: #selector(toggleCategory(_:))
            )
            button.state = .off   // off = shown (empty set = all)
            button.tag = Self.allCategories.firstIndex { $0.tag == cat.tag } ?? 0
            button.font = .systemFont(ofSize: 10, weight: .regular)
            button.frame = NSRect(x: x, y: 4, width: 0, height: 20)
            button.sizeToFit()
            let w = button.bounds.width + 4
            button.frame = NSRect(x: x, y: 4, width: w, height: 20)
            button.toolTip = "Click to show only \(cat.label) events"
            categoryButtons[cat.tag] = button
            container.addSubview(button)
            x += w + 2
        }
    }

    // MARK: - Toolbar

    private var pauseButton: NSButton?
    private var detailsButton: NSButton?
    private var searchField: NSSearchField?

    private func buildToolbarItems(in container: NSView) {
        var x: CGFloat = 8

        let clearButton = makeButton(title: "Clear", action: #selector(clearLog))
        clearButton.frame = NSRect(x: x, y: 4, width: 60, height: 26)
        container.addSubview(clearButton)
        x += 68

        pauseButton = makeButton(title: "Pause", action: #selector(togglePause))
        pauseButton?.frame = NSRect(x: x, y: 4, width: 64, height: 26)
        container.addSubview(pauseButton!)
        x += 72

        detailsButton = makeButton(title: "Details ✓", action: #selector(toggleDetails))
        detailsButton?.frame = NSRect(x: x, y: 4, width: 76, height: 26)
        container.addSubview(detailsButton!)
        x += 84

        let exportButton = makeButton(title: "Export…", action: #selector(exportLog))
        exportButton.frame = NSRect(x: x, y: 4, width: 68, height: 26)
        container.addSubview(exportButton)
        x += 76

        let autoscrollButton = NSButton(
            checkboxWithTitle: "Autoscroll",
            target: self,
            action: #selector(toggleAutoscroll(_:))
        )
        autoscrollButton.state = .on
        autoscrollButton.font = .systemFont(ofSize: 11, weight: .regular)
        autoscrollButton.frame = NSRect(x: x, y: 7, width: 100, height: 20)
        autoscrollButton.sizeToFit()
        container.addSubview(autoscrollButton)
        x += autoscrollButton.bounds.width + 12

        // Count label on the right side.
        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.frame = NSRect(
            x: container.bounds.width - 140, y: 9, width: 64, height: 14
        )
        countLabel.autoresizingMask = [.minXMargin]
        container.addSubview(countLabel)
        self.countLabel = countLabel

        // Search field on the far right.
        let search = NSSearchField(frame: NSRect(
            x: container.bounds.width - 70, y: 5, width: 62, height: 24
        ))
        search.placeholderString = "Search…"
        search.delegate = self
        search.autoresizingMask = [.minXMargin]
        search.font = .systemFont(ofSize: 11, weight: .regular)
        container.addSubview(search)
        searchField = search
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .regular)
        return button
    }

    // MARK: - Rendering

    private func reloadAll() {
        guard let textView else { return }
        textView.textStorage?.setAttributedString(NSAttributedString())
        for entry in DebugLog.shared.snapshot() {
            if matchesFilters(entry) {
                append(entry)
            }
        }
        updateMetrics()
        updateCount()
        if autoscroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func appendIfVisible(_ entry: DebugEntry) {
        guard window?.isVisible == true else { return }
        if !matchesFilters(entry) {
            updateCount()
            return
        }
        append(entry)
    }

    private func append(_ entry: DebugEntry) {
        guard let textView else { return }
        textView.textStorage?.append(Self.render(entry, showDetails: showDetails))
        if autoscroll {
            textView.scrollToEndOfDocument(nil)
        }
        updateCount()
    }

    private func matchesFilters(_ entry: DebugEntry) -> Bool {
        if !enabledCategories.isEmpty && !enabledCategories.contains(entry.category) {
            return false
        }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            let hay = "\(entry.category) \(entry.message) \(entry.detail ?? "")".lowercased()
            if !hay.contains(needle) { return false }
        }
        return true
    }

    // Colour per category — more distinctive than the old 6-colour scheme.
    private static func color(for category: String) -> NSColor {
        switch category {
        case "PROMPT": return .systemTeal
        case "GEN":    return .systemBlue
        case "GATE":   return .systemOrange
        case "SHOW":   return .systemGreen
        case "ACCEPT": return .systemMint
        case "FIX":    return .systemCyan
        case "ERROR":  return .systemRed
        case "OCR":    return .systemPurple
        case "AX":     return .systemBrown
        case "MLX":    return .systemIndigo
        case "FM":     return .systemPink
        case "FOCUS":  return .secondaryLabelColor
        default:       return .secondaryLabelColor
        }
    }

    private static func render(_ entry: DebugEntry, showDetails: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let detailFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let color = Self.color(for: entry.category)
        let result = NSMutableAttributedString(
            string: "\(timeFormatter.string(from: entry.date)) [\(entry.category)] \(entry.message)\n",
            attributes: [.foregroundColor: color, .font: font]
        )
        if showDetails, let detail = entry.detail, !detail.isEmpty {
            let indented = detail
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    \($0)" }
                .joined(separator: "\n")
            result.append(NSAttributedString(
                string: indented + "\n",
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: detailFont,
                ]
            ))
        }
        return result
    }

    // MARK: - Metrics

    private func updateMetrics() {
        let m = DebugMetrics.from(DebugLog.shared.snapshot())
        let parts: [String] = [
            "GEN \(m.completions)",
            "shown \(m.shown)",
            "accepted \(m.accepted)",
            String(format: "accept %d%%", Int(m.acceptRate * 100)),
            String(format: "abstain %d%%", Int(m.abstainRate * 100)),
            m.avgLatencyMs > 0 ? String(format: "latency %.0fms", m.avgLatencyMs) : "latency —",
            m.avgDecodeTokPerS > 0
                ? String(format: "decode %.0f tok/s", m.avgDecodeTokPerS)
                : "decode —",
            m.avgPrefillTokPerS > 0
                ? String(format: "prefill %.0f tok/s", m.avgPrefillTokPerS)
                : "prefill —",
        ]
        metricsLabel?.stringValue = parts.joined(separator: "  ·  ")
    }

    private func updateCount() {
        let total = DebugLog.shared.count
        let shown = textView?.string.isEmpty == false
            ? countRenderedLines()
            : 0
        countLabel?.stringValue = "\(shown)/\(total)"
    }

    private func countRenderedLines() -> Int {
        // Approximate: count non-empty rendered entries by counting lines
        // that start with a timestamp.
        guard let text = textView?.string else { return 0 }
        var n = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.range(of: #"^\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil {
                n += 1
            }
        }
        return n
    }

    // MARK: - Actions

    @objc private func clearLog() {
        DebugLog.shared.clear()
        textView?.textStorage?.setAttributedString(NSAttributedString())
        updateMetrics()
        updateCount()
    }

    @objc private func toggleAutoscroll(_ sender: NSButton) {
        autoscroll = sender.state == .on
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseButton?.title = paused ? "Resume" : "Pause"
        if !paused {
            reloadAll()
        }
    }

    @objc private func toggleDetails() {
        showDetails.toggle()
        detailsButton?.title = showDetails ? "Details ✓" : "Details"
        reloadAll()
    }

    @objc private func toggleCategory(_ sender: NSButton) {
        let index = sender.tag
        guard index < Self.allCategories.count else { return }
        let cat = Self.allCategories[index].tag
        if sender.state == .on {
            enabledCategories.insert(cat)
        } else {
            enabledCategories.remove(cat)
        }
        reloadAll()
    }

    /// Detail blocks (full prompts, raw model output) can run to thousands of
    /// characters of typed/OCR'd content; cap each so an export is a bounded
    /// diagnostic, not a verbatim transcript.
    private static let exportDetailCap = 500

    @objc private func exportLog() {
        // The buffer holds fragments of what the user typed — suggestions shown,
        // accepted words, fix originals, raw model output. Writing it to disk
        // turns an in-memory diagnostic into a plaintext record of their content,
        // so make that explicit and require confirmation before the save panel.
        let warning = NSAlert()
        warning.messageText = "Export debug log?"
        warning.informativeText = "The exported file contains text you typed this "
            + "session — suggestions, accepted words, and corrections. Only share it "
            + "with people you trust."
        warning.addButton(withTitle: "Export…")
        warning.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard warning.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "pretype-debug-\(Int(Date().timeIntervalSince1970)).txt"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let entries = DebugLog.shared.snapshot()
        let fmt = Self.timeFormatter
        let text = entries.map { entry -> String in
            var line = "\(fmt.string(from: entry.date)) [\(entry.category)] \(entry.message)"
            if var detail = entry.detail, !detail.isEmpty {
                if detail.count > Self.exportDetailCap {
                    detail = String(detail.prefix(Self.exportDetailCap)) + "… (truncated)"
                }
                line += "\n" + detail.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }.joined(separator: "\n")
            }
            return line
        }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        searchText = field.stringValue
        reloadAll()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Keep the controller and buffer alive; reopening reloads history.
        isVisible = false
    }
}
