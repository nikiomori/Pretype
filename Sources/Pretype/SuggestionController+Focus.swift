import AppKit

@MainActor
extension SuggestionController {
    /// A real focus change — `FocusTracker` drops the duplicates.
    func focusDidChange() {
        focusGeneration += 1
        field.focusMoved()
        // The overlay's remembered field style and the probe's pixel verdict
        // describe the field we just left; carried across they outrank what the
        // new field reports about itself (dark verdict from the previous app on
        // a white page — the same unreadable pill the tone resolver exists to
        // prevent).
        window.fieldChanged()
        correctionController.focusChanged()
        let policy = !AppPolicy.allowsCompletions(typingContext) ? " — suggestions off (blacklisted)"
            : AppPolicy.isTerminal(typingContext.bundleID) ? " — terminal, AI agent prompts only"
            : (AppPolicy.isCodeEditor(typingContext.bundleID) ? " — code editor, no screen context" : "")
        DebugLog.shared.log(
            "FOCUS",
            "\(typingContext.appName ?? "?")\(policy)",
            detail: "window: \(typingContext.windowTitle ?? "—")\nfield: \(typingContext.fieldLabel ?? "—")"
        )
        // Stale window text must not leak into the new context.
        promptContext.focusChanged()
        dismiss()
        // A capture belongs to the field it started in: carried across a focus
        // change it would type a sentence meant for one app into another.
        // After the teardown above, so its notice is the last thing painted
        // (and `fieldChanged()` no longer strips its protection either way).
        dictationController.invalidate()
        // Capture shortly after focus settles: passing through apps with
        // cmd-tab must not trigger screenshots, but a chat's first message
        // should still have context before the first keystroke lands.
        // Paused (or on battery), blacklisted or quiet: no reload, no
        // indicator, no screenshot.
        if let element = env.trackedElement(), Settings.enabled, completionsWelcome {
            // Entered a text field — start reloading the model now (no-op unless
            // it was idle-unloaded) so the first keystroke doesn't wait for it.
            // Unless no suggestion asks it (or Words stands in while memory is
            // short): then it loads for a fix or a reply.
            let usesModel = Settings.completionsUseModel && Settings.activeSuggestionMode == .sentences
            if usesModel {
                engine.prewarmIfNeeded()
            }
            if usesModel, case .preparing = engine.state {
                if let ctx = env.context(of: element) {
                    field.noteCaret(ctx.caretRect, style: ctx.host)
                    indicator.start()
                }
            }
            let generation = focusGeneration
            env.after(0.8) { [weak self] in
                guard let self, self.focusGeneration == generation else { return }
                // An empty message box in a chat: the reply's own, wider
                // capture replaces the completion's.
                if Settings.repliesEnabled, Settings.autoReply, AppPolicy.isChat(self.typingContext),
                   self.replyComposer.compose(auto: true) {
                    return
                }
                self.promptContext.refreshScreenIfNeeded(typed: "")
                // No capture coming (context off, no permission, blocked app):
                // warm the new field's prompt now — its first keystroke would
                // otherwise prefill the whole text. A capture warms on landing.
                if !self.promptContext.screenCaptureInFlight {
                    self.promptContext.warm(self.currentTextElement().flatMap {
                        self.env.context(of: $0)?.textBeforeCaret
                    })
                }
            }
        }
    }

    /// One edit posts two notifications ~0.1 ms apart (selection, then
    /// value) and the main queue drains between them: one short wait answers
    /// both with a single read instead of two identical ones.
    func focusedTextDidChange(valueChanged: Bool) {
        guard reread.notified(valueChanged: valueChanged) else { return }
        env.after(0.004) { [weak self] in
            guard let self else { return }
            reread.notifiedReadStarts()
            textDidChange()
            reread.notifiedReadEnded()
        }
    }

    func focusedAppDidResign() {
        // Left the app we were typing in — drop any ghost/indicator left at its
        // caret. A returning keystroke re-queries from the live context, so this
        // can't strand a still-wanted suggestion.
        dropOverlay(why: "left the app")
        // A capture dies with the app it started in. This is the only signal
        // that fires when the app switched *to* is Pretype itself — the tracker
        // never attaches to our own pid, so no focus change bumps
        // `focusGeneration`, and a capture left alive here would pass its
        // stale-focus check and type the transcript into our own menu or
        // Settings field. After `dropOverlay`, which would strip its notice's
        // protection and fade it at once.
        dictationController.invalidate()
    }
}
