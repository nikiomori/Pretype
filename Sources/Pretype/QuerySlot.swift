/// The one completion query or composed reply in flight — debouncing,
/// streaming, or waiting on its OCR — and the rules for who holds the slot.
/// One value, so what the task is for can't drift from whether there is one:
/// as separate flags, a retired completion once read as a reply, and a scroll
/// or click spared its stream — the next partial painted at the moved caret.
/// QuerySlotTests pin the rules.
struct QuerySlot {
    enum Kind: Equatable {
        /// A completion for this field. One edit reaches `textDidChange`
        /// twice (the AX notification, then the keystroke timer); the second
        /// must not restart the debounce, or cancel the stream, of a query
        /// already running for exactly this text (`isRunning`).
        case completion(before: String, after: String)
        /// A completion whose ghost was retired under it: the same text must
        /// re-query — backspacing onto a retired ghost's text found no
        /// suggestion at all.
        case retired
        case reply
    }

    struct Query {
        let id: Int
        var kind: Kind
        let task: Task<Void, Never>
    }

    private(set) var current: Query?
    /// Numbers the queries, so a finishing task gives up the slot only while
    /// it still holds it (a newer query owns it otherwise).
    private var lastID = 0

    var isReply: Bool { current?.kind == .reply }

    /// A completion for exactly this field is already on its way.
    func isRunning(before: String, after: String) -> Bool {
        current?.kind == .completion(before: before, after: after)
    }

    /// Take the slot for a query of `kind`, cancelling the one holding it.
    /// `run` makes its task, given the id to `finish` with.
    mutating func start(_ kind: Kind, run: (_ id: Int) -> Task<Void, Never>) {
        cancel()
        lastID += 1
        current = Query(id: lastID, kind: kind, task: run(lastID))
    }

    /// Cancel the query in flight and free the slot — nil, not just
    /// cancelled, or "a query is running" would read true over a task that
    /// will never finish.
    mutating func cancel() {
        current?.task.cancel()
        current = nil
    }

    /// Query `id`'s task is done: it frees the slot, unless a newer one has it.
    mutating func finish(_ id: Int) {
        if current?.id == id { current = nil }
    }

    /// The ghost a completion was streaming into was retired: its stream may
    /// run on, but the same text must query again (see `Kind.retired`).
    mutating func ghostRetired() {
        if case .completion = current?.kind { current?.kind = .retired }
    }
}
