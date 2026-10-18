/// When the field is re-read after an edit. Its AX notifications — one edit
/// posts two, selection then value, ~0.1 ms apart — are answered by one
/// coalesced read; the keystroke's own timer re-reads too, as the fallback
/// for apps whose notifications don't come (Electron), and stands down when
/// they did: both landed and a read after them got the field, so it would only
/// repeat that read — a round of IPC the typed-in app's main thread answers.
/// Pure: the controller schedules and reads, this says when. RereadScheduleTests
/// pin it.
struct RereadSchedule {
    private var keyRereadPending = false
    /// The pending timer re-read is only a keystroke's fallback — not a retry
    /// riding the same timer, which always reads.
    private var keyRereadIsFallback = false
    /// The edit's two notifications since the last key.
    private var seen = (value: false, selection: false)
    /// A read after both of them got the field.
    private var notifiedReadSinceKey = false
    private var notificationReadPending = false
    /// Successful field reads, so a notification's read can tell one ran.
    private var reads = 0
    /// `reads` when a notification read that saw both notifications started.
    private var readsBeforeNotifiedRead: Int?

    /// A key went to the app: its notifications, and their read, are to come.
    mutating func keyPressed() {
        seen = (false, false)
        notifiedReadSinceKey = false
    }

    /// Ask for a re-read on the keystroke timer. true: schedule one. false:
    /// one is on its way already — and stays a fallback only if this is too.
    mutating func requestKeyReread(fallback: Bool) -> Bool {
        guard !keyRereadPending else {
            if !fallback { keyRereadIsFallback = false }
            return false
        }
        keyRereadPending = true
        keyRereadIsFallback = fallback
        return true
    }

    /// The keystroke timer fired: whether to read.
    mutating func keyRereadFired() -> Bool {
        keyRereadPending = false
        return !(keyRereadIsFallback && notifiedReadSinceKey)
    }

    /// An AX notification on the field. true: schedule the coalesced read.
    mutating func notified(valueChanged: Bool) -> Bool {
        if valueChanged { seen.value = true } else { seen.selection = true }
        guard !notificationReadPending else { return false }
        notificationReadPending = true
        return true
    }

    /// The coalesced read is starting; `notifiedReadEnded` follows it.
    mutating func notifiedReadStarts() {
        notificationReadPending = false
        readsBeforeNotifiedRead = seen.value && seen.selection ? reads : nil
    }

    /// Only a read that got the field stands in for the fallback: a timed-out
    /// one (Electron) still wants its second chance.
    mutating func notifiedReadEnded() {
        if let before = readsBeforeNotifiedRead, reads != before { notifiedReadSinceKey = true }
        readsBeforeNotifiedRead = nil
    }

    /// A read got the field.
    mutating func fieldRead() { reads &+= 1 }
}
