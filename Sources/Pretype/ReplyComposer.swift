import AppKit

/// What the reply flow may ask of the completion pipeline — the protocol keeps
/// `ReplyComposer` from growing casual reach into it, as `DictationHost` does
/// for dictation. `SuggestionController` in the app, a fake in ReplyComposerTests.
@MainActor
protocol ReplyHost: AnyObject {
    /// One line of what just happened, surfaced in the Diagnostics menu.
    var lastEvent: String { get }
    func report(_ event: String)
    var typingContext: TypingContext { get }
    var engine: CompletionEngine { get }
    /// Why the pipeline can start nothing now, or nil (`SuggestionController.busyReason`).
    var busyReason: String? { get }
    /// The field the pipeline reads and types into.
    func currentTextElement() -> AXUIElement?
    /// The app whose window holds the conversation.
    var observedPID: pid_t { get }
    /// The field a reply is for was just read whole: its caret and its text
    /// become the pipeline's, so a notice lands at it and the reply lands on
    /// this read without another.
    func adoptReplyField(_ context: TextContext, caret: CGRect)
    /// Take the overlay and the query slot for a reply: `run` makes its task,
    /// given the id to `endReply` with.
    func startReply(run: (_ id: Int) -> Task<Void, Never>)
    /// The reply's task is done: free the slot, stop the dots.
    func endReply(_ id: Int)
    /// Offer `reply` as the ghost on `context`. Whether it was shown.
    func offerReply(_ reply: String, on context: TextContext) -> Bool
}

/// The reply flow (⌥⇧⇥, the double-tap, or the caret landing in an empty chat
/// box): the conversation on screen in, the user's next message out, offered
/// as one ghost through the completion pipeline's own apply path. Kept apart
/// from it the way the fix flows are (`CorrectionController`).
@MainActor
final class ReplyComposer {
    private unowned let host: any ReplyHost
    private let env: SuggestionController.Environment
    private let indicator: CaretIndicator
    /// Builds the request, and says what the screen context is missing.
    private let prompts: PromptContext

    init(host: any ReplyHost, env: SuggestionController.Environment,
         indicator: CaretIndicator, prompts: PromptContext) {
        self.host = host
        self.env = env
        self.indicator = indicator
        self.prompts = prompts
    }

    /// Write the user's next message for them: OCR the conversation in front of
    /// them, ask the engine to answer it, and offer the whole thing as one ghost
    /// the normal accept keys take (⇥ word by word, ⇧⇥ all of it, ⎋ to drop it).
    /// Asked for by the chord, or — `auto`, with "Offer replies in chats" on —
    /// by the caret landing in an empty message box. Nothing is typed unasked.
    /// An automatic reply stays silent when it can't run: no hints, no
    /// download of a fix model nobody asked for. Returns whether it started.
    ///
    /// It borrows the query slot for the duration, so the thinking dots run, a
    /// keystroke or a focus change cancels it, and it can't race a completion.
    /// Never call inside the event-tap callback: it does synchronous AX reads.
    @discardableResult
    func compose(auto: Bool = false) -> Bool {
        // Every stop below says why, in the console and in the menu's "Last:"
        // line: an explicitly-pressed chord that does nothing, silently, is
        // indistinguishable from a broken build.
        DebugLog.shared.log("REPLY", auto ? "offered — empty message box"
            : "requested (\(Settings.replyGesture.label) / \(Settings.hotkeyStyle.replyLabel))")
        func stop(_ why: String) -> Bool {
            if !auto { host.report("reply: \(why)") }
            DebugLog.shared.log("REPLY", "not composing — \(why)")
            return false
        }
        if let busy = host.busyReason { return stop(busy) }
        // Element first: it reads the site the blacklist check needs.
        guard let element = host.currentTextElement() else {
            return stop("no text field in focus")
        }
        let typingContext = host.typingContext
        guard !AppPolicy.isBlacklisted(typingContext) else {
            return stop("off in \(typingContext.site ?? typingContext.appName ?? "this app")")
        }
        // allowEmpty: an empty chat box is the case this feature exists for —
        // the completion pipeline's "nothing to continue" is not a refusal here.
        guard let ctx = env.context(of: element, allowEmpty: true),
              let rect = ctx.caretRect else {
            return stop("cannot read the field or place the ghost")
        }
        if auto {
            guard (ctx.textBeforeCaret + ctx.textAfterCaret).allSatisfy(\.isWhitespace) else {
                return stop("the message box isn't empty")
            }
            guard host.engine.isCorrectionReady else { return stop("the reply model isn't loaded") }
        }
        host.adoptReplyField(ctx, caret: rect)
        // Without the screen there is nothing to reply *to*: say so at the caret
        // instead of answering from the empty field.
        guard Settings.screenContextEnabled, env.screenRecordingAllowed(),
              AppPolicy.allowsScreenContext(typingContext) else {
            _ = stop("needs screen context — \(prompts.screenStatus)")
            if auto { return false }
            // Say which of the three is missing, in the words the fix is found
            // under — "needs screen context" left the user to work out which.
            let why = !Settings.screenContextEnabled
                ? String(localized: "reply reads the screen — turn on “Use screen context” in Settings")
                : !env.screenRecordingAllowed()
                    ? String(localized: "reply needs Screen Recording — allow Pretype in System Settings, then relaunch")
                    : typingContext.appName.map { String(localized: "reply doesn't read the screen in \($0)") }
                        ?? String(localized: "reply doesn't read the screen in this app")
            indicator.flashTransient(.hint(why), hideAfter: 3.5)
            return false
        }
        let request = prompts.makeRequest(text: ctx.textBeforeCaret, after: ctx.textAfterCaret)
        let engine = host.engine
        let capture = env.captureScreen
        let pid = host.observedPID
        host.report("composing a reply…")
        host.startReply { queryID in Task { [weak self] in
            // A fresh, wider capture — not the 25 s-cached completion context:
            // the message being answered may have landed a second ago. No caret
            // ROI either: that band is ±250 pt of the input box, while a reply
            // needs the exchange above it — the whole window, capped from the
            // bottom, which is where the recent messages are.
            let conversation = await capture(pid, ctx.textBeforeCaret, nil, 1200)
            if Task.isCancelled { return }
            let outcome: Result<String?, Error>
            if let conversation {
                do {
                    outcome = .success(try await engine.reply(to: conversation, request: request))
                } catch is CancellationError {
                    return
                } catch {
                    outcome = .failure(error)
                }
            } else {
                outcome = .success(nil)
            }
            // A focus change (or anything else that ended the reply) has
            // cancelled this task: `dismiss` frees the slot first.
            guard let self, !Task.isCancelled else { return }
            host.endReply(queryID)
            // Count only, never the text: this is OTHER people's on-screen
            // text and the log is exportable (same rule as the OCR log).
            DebugLog.shared.log(
                "REPLY", "\(conversation?.count ?? 0) chars of screen context")
            switch outcome {
            case .success(let reply?):
                let shown = host.offerReply(reply, on: ctx)
                DebugLog.shared.log("REPLY", shown ? "shown" : "dropped — \(host.lastEvent)")
            case .success(nil):
                // Two different silences: nothing readable on screen, or the
                // model had nothing to say about it.
                let why = conversation == nil ? "nothing to reply to" : "no answer from the model"
                DebugLog.shared.log("REPLY", why)
                guard !auto else { return }
                host.report("reply: \(why)")
                indicator.flashTransient(.hint(conversation == nil
                    ? String(localized: "nothing to reply to") : String(localized: "no answer from the model")),
                    orAtPointer: true)
            case .failure(let error):
                DebugLog.shared.log("ERROR", "reply failed: \(error.localizedDescription)")
                guard !auto else { return }
                host.report("reply failed: \(error.localizedDescription)")
                indicator.flashTransient(SuggestionController.failureNotice(error, fallback: String(localized: "reply failed")),
                                         orAtPointer: true)
            }
        } }
        return true
    }
}

/// The host side that needs no more than the controller's internal API; what
/// moves pipeline state (`adoptReplyField`, `startReply`, `endReply`) lives
/// with that state, in SuggestionController.swift.
extension SuggestionController: ReplyHost {
    /// Through the normal apply path: same anchoring, settle and journal rules
    /// as a completion — only longer, reading an empty field as a real (empty)
    /// context, and never trimmed to the line: a reply cut to its first 70
    /// chars lost the rest.
    func offerReply(_ reply: String, on context: TextContext) -> Bool {
        apply(reply, requestText: context.textBeforeCaret, cachedContext: context, reply: true)
    }
}
