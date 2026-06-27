import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// In-process inference on Apple Silicon via MLX. The model is downloaded
/// from Hugging Face on first use and cached in ~/.cache/huggingface.
///
/// Latency strategy: the KV cache is kept between keystrokes. Each request
/// trims it back to the common token prefix with the previous prompt and
/// prefills only the few new tokens, so per-keystroke cost is dominated by
/// decoding ~14 tokens instead of re-reading the whole context.
///
/// The model catalog and runtime support live in `ModelCatalog.swift`; the
/// token-iteration core, KV-cache and logit processors in
/// `MLXEngine+Generation.swift`; the shared output/correction gates in
/// `CompletionGates`/`CorrectionGates`.
final class MLXEngine: CompletionEngine {
    // These three are process-wide knobs the dev/eval harness sets ONCE at
    // startup, before any engine spins up, and the generation tasks then only
    // read them. A `LockedValue` makes the shared mutable state explicit and
    // thread-safe under the Swift 6 language mode.
    /// Verbose generation logging for the --complete test harness.
    static let debugLogging = LockedValue<Bool>(false)
    /// Force greedy (argmax) decoding — set by the eval harness so runs are
    /// deterministic and comparable (no temperature jitter between configs).
    static let greedy = LockedValue<Bool>(false)
    /// Instruct prompt format, A/B-swept on eval-v2 (PRETYPE_PROMPT_VARIANT
    /// overrides). One of: userturn · prefill · localized · prefill-localized.
    static let defaultPromptVariant = LockedValue<String>("userturn")

    let name = "Local LLM (MLX)"

    private let modelID: String
    private let extraEOSTokens: Set<String>
    /// Fixed at init: switching style reloads the engine (different model).
    private let style: CompletionStyle
    /// Live-tunable from the menu without a reload.
    private let lengthBox: LockedValue<CompletionLength>
    private let instructionsBox: LockedValue<String>
    private let personalizationBox: LockedValue<PersonalizationLevel>
    /// Self-consistency confidence gate (opt-in): when K>1 the engine samples the
    /// completion K times and only returns one if its first word agrees on
    /// ≥threshold of the draws — otherwise it abstains. Trades coverage for
    /// precision (much higher first-word accuracy on real text; validated in
    /// Eval/BASELINE.md). Off by default (it costs ~K× decode); enabled via
    /// Settings.confidenceGate / PRETYPE_CONFIDENCE_GATE.
    private let confidenceGateK: Int
    private let confidenceGateThreshold: Double
    /// Forces sampling (temperature) inside the gate's K draws even when the eval
    /// harness pinned greedy. Set only around the gate loop.
    private let gateForceSample = LockedValue(false)
    private let stateBox = StateBox()
    private var loadTask: Task<ModelContainer, Error>?
    /// Instruct model for fix-selection; loaded lazily on first ⌥Tab.
    private var correctionLoadTask: Task<ModelContainer, Error>?

    /// Serializes model lifecycle (load · idle-unload · reload) across the
    /// generation tasks, the idle timer, and the memory-pressure source.
    private let modelLock = NSLock()
    /// True once the initial load was started (false when Metal is missing), so
    /// reload/prewarm only ever rebuild a model we genuinely had.
    private var didInitLoad = false
    /// Requests currently holding the model; the idle/pressure unload waits for 0.
    private var inFlightCount = 0
    /// Last time the model was used — drives the idle-unload timer.
    private var lastActivity = Date()
    /// After a load failure, back off before retrying so a genuinely unavailable
    /// model (offline, bad repo id) isn't re-attempted on every keystroke — each
    /// retry otherwise re-hits the Hub and flips state preparing↔failed per press.
    private static let loadRetryCooldown: TimeInterval = 30
    /// When the last load attempt failed; nil once a load succeeds. Guarded by modelLock.
    private var lastLoadFailure: Date?
    private let maintenanceQueue = DispatchQueue(label: "app.pretype.mlx.maintenance")
    private var idleTimer: DispatchSourceTimer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// KV-cache + token snapshots reused between keystrokes (LRU; type lives in
    /// `MLXEngine+Generation.swift`).
    private let promptCache = PromptCache()

    var state: EngineState { stateBox.get() }

    var statusLine: String? {
        let model = modelID.split(separator: "/").last.map(String.init) ?? modelID
        switch stateBox.get() {
        case .preparing(let detail): return "\(model): \(detail)"
        case .ready: return "\(model): ready"
        case .failed(let detail): return "\(model): failed — \(detail)"
        }
    }

    init(modelID: String, config: CompletionConfig = .resolved()) {
        let baseOption = ModelCatalog.option(for: modelID)
        self.style = config.style
        self.extraEOSTokens = baseOption?.extraEOSTokens ?? []
        self.lengthBox = LockedValue(config.length)
        self.instructionsBox = LockedValue(config.instructions)
        self.personalizationBox = LockedValue(config.personalization)
        let env = ProcessInfo.processInfo.environment
        self.confidenceGateK = Int(env["PRETYPE_CONFIDENCE_GATE"] ?? "")
            ?? (Settings.confidenceGate ? Settings.confidenceGateSamples : 0)
        self.confidenceGateThreshold = Double(env["PRETYPE_CONFIDENCE_THRESHOLD"] ?? "")
            ?? Settings.confidenceGateThreshold

        // Instruct style runs completion *and* correction on the instruct
        // sibling, so load that as the primary model (no second model in RAM).
        // PRETYPE_INSTRUCT_MODEL overrides the sibling so the harness can A/B
        // instruct at a fairer quant (the catalog only maps to `…-it-4bit`).
        let primaryID: String
        switch config.style {
        case .base:
            primaryID = modelID
        case .instruct:
            primaryID = ProcessInfo.processInfo.environment["PRETYPE_INSTRUCT_MODEL"]
                ?? baseOption?.instructModelID ?? baseOption?.correctionModelID ?? modelID
        }
        self.modelID = primaryID

        guard MLXSupport.isAvailable else {
            stateBox.set(.failed("Metal shaders missing — build with Scripts/make-app.sh or run Scripts/dev.sh"))
            return
        }
        // Bounded but generous buffer cache: enough for fast decode reuse
        // without hoarding memory between keystrokes.
        Memory.cacheLimit = 512 * 1024 * 1024
        loadTask = makeLoadTask()
        didInitLoad = true
        startIdleMaintenance()
    }

    // MARK: - Model lifecycle (load · idle-unload · reload)

    private func makeLoadTask() -> Task<ModelContainer, Error> {
        let stateBox = self.stateBox
        let id = self.modelID
        let eos = self.extraEOSTokens
        stateBox.set(.preparing("loading…"))
        return Task { [weak self] in
            do {
                // A fine-tuned model is a local directory (no download); a
                // catalog id resolves through the Hub.
                let configuration: ModelConfiguration
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: id, isDirectory: &isDir), isDir.boolValue {
                    configuration = ModelConfiguration(directory: URL(fileURLWithPath: id), extraEOSTokens: eos)
                } else {
                    configuration = ModelConfiguration(id: id, extraEOSTokens: eos)
                }
                let container = try await #huggingFaceLoadModelContainer(
                    configuration: configuration,
                    progressHandler: { progress in
                        stateBox.set(.preparing(Self.downloadStatus(progress)))
                    }
                )
                // The first generation pays for Metal kernel compilation; do it
                // now so the first real keystroke doesn't. A warm-up failure
                // shouldn't block readiness (the next real request surfaces it),
                // but it must not be swallowed silently.
                stateBox.set(.preparing("warming up…"))
                do {
                    _ = try await Self.generate(
                        in: container, prompt: "Hello",
                        parameters: GenerateParameters(maxTokens: 2, temperature: 0.0),
                        extraEOSTokens: eos, promptCache: nil
                    )
                } catch {
                    DebugLog.shared.log("ERROR", "warm-up generation failed: \(error.localizedDescription)")
                }
                stateBox.set(.ready)
                self?.markLoadSucceeded()
                return container
            } catch {
                stateBox.set(.failed(error.localizedDescription))
                self?.clearLoadTaskOnFailure()
                throw error
            }
        }
    }

    private func clearLoadTaskOnFailure() {
        modelLock.lock()
        defer { modelLock.unlock() }
        loadTask = nil
        lastLoadFailure = Date()
    }

    private func markLoadSucceeded() {
        modelLock.lock()
        defer { modelLock.unlock() }
        lastLoadFailure = nil
    }

    /// Marks a request in-flight and returns the model-load task, reloading it if
    /// it was idle-unloaded. Returns nil when the engine never initialized (e.g.
    /// Metal missing) — callers then abstain, as before. Pair with `endRequest()`.
    private func beginRequest() -> Task<ModelContainer, Error>? {
        modelLock.lock(); defer { modelLock.unlock() }
        guard didInitLoad else { return nil }
        if loadTask == nil {
            // Back off after a failure: don't recreate the load task (and re-hit
            // the Hub) until the cooldown passes, so an unavailable model isn't
            // retried on every keystroke. Abstain meanwhile without leaking the
            // in-flight count.
            if let failedAt = lastLoadFailure, Date().timeIntervalSince(failedAt) < Self.loadRetryCooldown {
                return nil
            }
            DebugLog.shared.log("MLX", "loading model (idle-unloaded or retry after failure)")
            loadTask = makeLoadTask()
        }
        inFlightCount += 1
        lastActivity = Date()
        return loadTask
    }

    private func endRequest() {
        modelLock.lock()
        inFlightCount = max(0, inFlightCount - 1)
        lastActivity = Date()
        modelLock.unlock()
    }

    /// Starts a background reload if the model was idle-unloaded, so a focus
    /// change or first keystroke hides the reload latency. Cheap no-op (lock +
    /// nil check) when the model is already loaded or loading.
    func prewarmIfNeeded() {
        modelLock.lock(); defer { modelLock.unlock() }
        guard didInitLoad, loadTask == nil else { return }
        // Same failure backoff as beginRequest — a focus change shouldn't retry a
        // model that just failed to load.
        if let failedAt = lastLoadFailure, Date().timeIntervalSince(failedAt) < Self.loadRetryCooldown { return }
        DebugLog.shared.log("MLX", "prewarming model after idle")
        lastActivity = Date()
        loadTask = makeLoadTask()
    }

    /// Free the resident model right now (menu action). Reloads on next use.
    func releaseModelNow() {
        unload(reason: "manual", force: true)
    }

    /// Releases the resident model (weights + buffer cache) so an idle menu-bar
    /// app doesn't hold several GB. The next request or prewarm reloads it from
    /// disk. No-op while a request is in flight, mid-load, or just used.
    private func unload(reason: String, force: Bool = false) {
        modelLock.lock()
        let idleEnough = force || Date().timeIntervalSince(lastActivity) > 3
        guard inFlightCount == 0, idleEnough,
              loadTask != nil || correctionLoadTask != nil,
              case .ready = stateBox.get() else {
            modelLock.unlock(); return
        }
        let before = Memory.snapshot().activeMemory
        loadTask?.cancel(); loadTask = nil
        correctionLoadTask?.cancel(); correctionLoadTask = nil
        modelLock.unlock()

        Memory.clearCache()
        promptCache.clear()
        let freed = Int64(max(0, before - Memory.snapshot().activeMemory))
        let amount = ByteCountFormatter.string(fromByteCount: freed, countStyle: .memory)
        stateBox.set(.preparing("idle — model unloaded"))
        DebugLog.shared.log("MLX", "unloaded model (\(reason)) — freed ~\(amount)")
    }

    /// Idle-unload timer + memory-pressure source: both free the model when it
    /// is unused or the system needs RAM; the next use reloads it.
    private func startIdleMaintenance() {
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: maintenanceQueue
        )
        pressure.setEventHandler { [weak self] in
            self?.unload(reason: "memory pressure")
        }
        pressure.resume()
        memoryPressureSource = pressure

        // The idle timer always runs; the timeout is read live so the Settings
        // control takes effect without an engine reload (0 minutes = disabled).
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let minutes = Settings.idleUnloadMinutes
            guard minutes > 0 else { return }
            self.modelLock.lock()
            let idle = Date().timeIntervalSince(self.lastActivity)
            let busy = self.inFlightCount > 0
            self.modelLock.unlock()
            if !busy, idle >= TimeInterval(minutes) * 60 {
                self.unload(reason: "idle \(Int(idle))s")
            }
        }
        timer.resume()
        idleTimer = timer
    }

    deinit {
        idleTimer?.cancel()
        memoryPressureSource?.cancel()
    }

    // MARK: - Completion

    func complete(_ request: CompletionRequest) async throws -> String? {
        // The gate's agreement→correctness signal only holds for base continuation
        // (instruct confidently paraphrases), so it's a base-style-only feature.
        if confidenceGateK > 1, style == .base { return try await completeGated(request) }
        return try await completeOnce(request)
    }

    /// One ungated decode of the active style.
    private func completeOnce(_ request: CompletionRequest) async throws -> String? {
        switch style {
        case .base: return try await completeBase(request)
        case .instruct: return try await completeInstruct(request)
        }
    }

    /// Self-consistency confidence gate: draw the completion `confidenceGateK`
    /// times (sampling), keep the suggestion only if its first word is the modal
    /// one on ≥`confidenceGateThreshold` of the draws — otherwise abstain. The
    /// returned suggestion is the modal-first-word draw seen most, so the user
    /// gets a high-agreement continuation. Higher precision, lower coverage.
    private func completeGated(_ request: CompletionRequest) async throws -> String? {
        gateForceSample.set(true)
        defer { gateForceSample.set(false) }
        var byFirstWord: [String: (count: Int, sample: String)] = [:]
        var draws = 0
        for _ in 0..<confidenceGateK {
            try Task.checkCancellation()
            guard let sug = try await completeOnce(request),
                  let fw = Self.gateFirstWord(sug) else { continue }
            draws += 1
            let prev = byFirstWord[fw]
            byFirstWord[fw] = (count: (prev?.count ?? 0) + 1, sample: prev?.sample ?? sug)
        }
        guard draws > 0, let best = byFirstWord.max(by: { $0.value.count < $1.value.count }) else { return nil }
        // Agreement is measured over the K attempts (abstentions count against it,
        // so a model that only answers once isn't spuriously "consistent").
        guard Double(best.value.count) / Double(confidenceGateK) >= confidenceGateThreshold else {
            DebugLog.shared.log("GATE", "low self-consistency (\(best.value.count)/\(confidenceGateK)) — abstaining")
            return nil
        }
        return best.value.sample
    }

    /// First word of a suggestion, folded to match across draws (lowercased,
    /// ё→е, split on non-alphanumerics).
    private static func gateFirstWord(_ s: String) -> String? {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.first.map(String.init)
    }

    func completions(for request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // The self-consistency gate needs K full draws to measure
                    // first-word agreement, so it can't stream partials. When it's
                    // active (Base style only — instruct confidently paraphrases),
                    // run the gated decode and yield its single result. This is the
                    // live path, so the Settings/menu "High-precision mode" toggle
                    // now actually changes what the user sees.
                    if confidenceGateK > 1, style == .base {
                        if let gated = try await completeGated(request) { continuation.yield(gated) }
                        continuation.finish()
                        return
                    }
                    let onPartial: @Sendable (String) -> Void = { continuation.yield($0) }
                    switch style {
                    case .base: _ = try await completeBase(request, onPartial: onPartial)
                    case .instruct: _ = try await completeInstruct(request, onPartial: onPartial)
                    }
                    // The final result equals the last gated partial, so the
                    // stream's last element is already the answer — just finish.
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shared prompt preparation for both completion paths. Trims the trailing
    /// spaces the user typed (a dangling space derails SentencePiece models into
    /// a stray newline), enforces a per-path context floor, and records the
    /// word-boundary state the output gate needs. Returns nil — abstain — below
    /// the floor or when nothing is left to encode.
    private struct PreparedPrompt {
        /// Context tail with trailing spaces removed; what actually gets encoded.
        let text: String
        /// How many trailing spaces the user typed (the gate restores the separator).
        let trailingSpaces: Int
        /// The caret sits right after a run of letters with no separator.
        let endsMidWord: Bool
        /// …and that run is a finished word — so a leading-space suggestion is the
        /// separator the user hasn't typed yet, not a stranded fragment.
        let endsCompleteWord: Bool
        let textAfterCaret: String
        let singleWord: Bool

        /// The output gate for this prompt: run a raw decode snapshot (partial or
        /// final) through the shared `CompletionGates`. `cleanInstruct` first
        /// strips wrapping quotes and restores the separator instruct models
        /// answer without — base continuations bring their own separator.
        func gate(cleanInstruct: Bool) -> @Sendable (String) -> String? {
            let text = self.text
            let trailing = trailingSpaces
            let endsMidWord = self.endsMidWord
            let endsCompleteWord = self.endsCompleteWord
            let after = textAfterCaret
            let singleWord = self.singleWord
            return { output in
                var raw = output
                if cleanInstruct {
                    raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    for quote in ["\"", "“", "”"] {
                        if raw.hasPrefix(quote) { raw.removeFirst() }
                        if raw.hasSuffix(quote) { raw.removeLast() }
                    }
                    // Instruct models answer flush (no leading space). Restore the
                    // separator the shared gate expects when the user already typed
                    // it (trailing > 0) OR the caret sits right after a finished
                    // word (the space they haven't typed yet), so the new word
                    // doesn't glue onto the previous one.
                    if trailing > 0 || endsCompleteWord, !raw.hasPrefix(" ") { raw = " " + raw }
                }
                return CompletionGates.postProcess(
                    raw, prompt: text, trailingSpaces: trailing,
                    endsMidWord: endsMidWord, endsCompleteWord: endsCompleteWord,
                    textAfterCaret: after, singleWord: singleWord
                )
            }
        }
    }

    /// Builds a `PreparedPrompt`, or nil to abstain. `midWordFloor` applies when
    /// the caret is mid-word (a partial word is a strong constraint, so a lower
    /// floor is safe and surfaces word completions earlier); `boundaryFloor`
    /// applies at a word boundary. Screen context counts toward the threshold.
    private func prepare(_ request: CompletionRequest,
                         midWordFloor: Int, boundaryFloor: Int) -> PreparedPrompt? {
        var text = request.completionPrompt(maxChars: 1000)
        let floor = text.last?.isLetter == true ? midWordFloor : boundaryFloor
        guard text.count >= floor else {
            DebugLog.shared.log("GATE", "below context floor (\(text.count) chars < \(floor)) — not querying the model")
            return nil
        }
        var trailingSpaces = 0
        while text.hasSuffix(" ") {
            text.removeLast()
            trailingSpaces += 1
        }
        guard !text.isEmpty else { return nil }

        let after = request.textAfterCaret
        let endsMidWord = trailingSpaces == 0 && text.last?.isLetter == true
        let endsCompleteWord = endsMidWord
            && (request.endsOnCompleteWord ?? SpellChecker.endsOnCompleteWord(before: text, after: after))
        return PreparedPrompt(
            text: text, trailingSpaces: trailingSpaces,
            endsMidWord: endsMidWord, endsCompleteWord: endsCompleteWord,
            textAfterCaret: after, singleWord: lengthBox.get().isSingleWord
        )
    }

    /// Raw text continuation against a base model: encode the tail, continue it.
    /// A base model given only 3-4 tokens lands in random-language territory
    /// (verified: "а теперь" → Turkish gibberish), so it floors higher than the
    /// instruct path — except mid-word, where the partial word constrains it.
    private func completeBase(_ request: CompletionRequest,
                              onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String? {
        guard let task = beginRequest() else { return nil }
        defer { endRequest() }
        let container = try await task.value
        try Task.checkCancellation()

        guard let prepared = prepare(request, midWordFloor: 10, boundaryFloor: 16) else { return nil }

        let parameters = completionParameters(for: request)
        let gate = prepared.gate(cleanInstruct: false)
        let output = try await Self.generate(
            in: container, prompt: prepared.text, parameters: parameters,
            extraEOSTokens: extraEOSTokens, promptCache: promptCache, bias: currentBias(),
            onPartial: Self.makeStreamHandler(onPartial, gate: gate)
        )
        try Task.checkCancellation()
        return gate(output)
    }

    /// Persona-aware continuation through the instruct model's chat template:
    /// a "continue, ~N words, match voice" directive + optional author profile,
    /// then the text. The KV cache still applies — the directive/persona are a
    /// constant prefix, so only the new characters re-prefill per keystroke.
    private func completeInstruct(_ request: CompletionRequest,
                                  onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String? {
        guard let task = beginRequest() else { return nil }
        defer { endRequest() }
        let container = try await task.value
        try Task.checkCancellation()

        // Lower floor than the base path: the instruct model is grounded by the
        // directive + persona, so it stays coherent on short context (e.g. the
        // first few words of a chat message) instead of going off-language.
        guard let prepared = prepare(request, midWordFloor: 6, boundaryFloor: 10) else { return nil }
        let promptText = prepared.text

        // Prompt format is A/B-tunable via PRETYPE_PROMPT_VARIANT (swept on
        // eval-v2). Gemma has no system role, so the directive rides in the user
        // turn. "prefill" instead opens the assistant turn with the text so the
        // model literally continues it; "localized" writes the directive in the
        // text's language.
        let length = lengthBox.get()
        let persona = instructionsBox.get().trimmingCharacters(in: .whitespacesAndNewlines)
        let envVariant = ProcessInfo.processInfo.environment["PRETYPE_PROMPT_VARIANT"]
        let variant = envVariant ?? Self.defaultPromptVariant.get()
        let localized = variant.contains("localized") && Self.isCyrillicHeavy(promptText)
        let prefill = variant.hasPrefix("prefill")
        // Fill-in-the-Middle: emulate suffix-conditioning via the prompt (Gemma 4
        // has no FIM tokens). An explicit PRETYPE_PROMPT_VARIANT fully controls it
        // (A/B); otherwise auto-enable only when the user's toggle is on AND the
        // model is E4B-class — it's unreliable on the smaller E2B (measured), where
        // we log the skip. Needs a non-trivial suffix, so it's a no-op at end-of-line.
        let suffixForPrompt = String(request.textAfterCaret.prefix(200))
        let hasSuffix = !suffixForPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let infill: Bool = {
            guard hasSuffix else { return false }
            if let envVariant { return envVariant.contains("infill") }
            guard Settings.fimEnabled else { return false }
            if Self.isFIMCapable(modelID) { return true }
            DebugLog.shared.log("GATE", "fill-in-the-middle off — \(modelID) is not E4B-class (unreliable here)")
            return false
        }()

        var directive: String
        if infill {
            directive = """
            You are filling a gap in the user's text where the cursor sits between BEFORE \
            and AFTER. Output ONLY the specific missing words that belong in the gap — the \
            content itself (an object, name, time, place or action), NEVER a linking word \
            such as "because", "and", "so", "before" or "due to". BEFORE + your words + \
            AFTER must read as one natural sentence in the same language, and your words \
            must not repeat anything already in AFTER. No quotes, no explanation.

            BEFORE: \(promptText)
            AFTER: \(suffixForPrompt)
            """
            if !persona.isEmpty {
                directive += "\n\nAuthor profile (for voice only, never quote it):\n\(persona)"
            }
        } else if localized {
            let hint: String
            switch length.directiveLength {
            case .word: hint = "только одно следующее слово"  // unreachable: word → short
            case .short: hint = "не больше 2–3 слов"
            case .medium: hint = "короткой фразой, до ~6 слов"
            case .long: hint = "не больше одного предложения"
            }
            directive = """
            Продолжи текст на том же языке, в том же тоне и регистре. Ответь ТОЛЬКО \
            следующими словами (\(hint)) — не повторяй уже написанное, без кавычек и \
            пояснений.
            """
            if !persona.isEmpty {
                directive += "\n\nО пользователе (для стиля, не цитировать):\n\(persona)"
            }
        } else {
            directive = """
            Continue the text in the same language, tone and register. Reply with \
            ONLY the words that come next (\(length.directiveLength.wordsHint)) — do \
            not repeat the existing text, no quotes, no explanation.
            """
            if !persona.isEmpty {
                directive += "\n\nAuthor profile (for voice only, never quote it):\n\(persona)"
            }
        }
        // Capture an immutable copy in the @Sendable token closure below: a
        // captured `var` crosses a concurrency boundary.
        let directiveText = directive

        let parameters = completionParameters(for: request)
        let gate = prepared.gate(cleanInstruct: true)
        let output = try await Self.generate(
            in: container,
            makeTokens: { context in
                // prefill opens the assistant turn with the text; infill already
                // embeds BEFORE/AFTER in the directive — both send the directive alone.
                let userContent = (prefill || infill) ? directiveText : "\(directiveText)\n\nText:\n\(promptText)"
                let messages: [[String: any Sendable]] = [["role": "user", "content": userContent]]
                var toks = try context.tokenizer.applyChatTemplate(messages: messages)
                if prefill {
                    // Open the assistant turn with the user's text (BOS stripped)
                    // so the model continues it instead of answering about it.
                    let bos = context.tokenizer.convertTokenToId("<bos>")
                    toks.append(contentsOf: context.tokenizer.encode(text: promptText).filter { $0 != bos })
                }
                return toks
            },
            parameters: parameters,
            // Instruct replies end on the turn marker; add it defensively.
            extraEOSTokens: extraEOSTokens.union(["<end_of_turn>"]),
            promptCache: promptCache, bias: currentBias(),
            // Prefill needs ≥a few real tokens before EOS is allowed, or Gemma
            // ends the turn immediately after the prefilled text.
            minTokens: prefill ? 3 : 0,
            onPartial: Self.makeStreamHandler(onPartial, gate: gate)
        )
        try Task.checkCancellation()
        return gate(output)
    }

    /// Per-keystroke token budget: the length setting, trimmed harder for chat.
    /// Cyrillic tokenizes to ~2× tokens/word, so the same word-count target needs
    /// a bigger token cap — without this, `short` clips Russian mid-phrase
    /// (eval: instruct short ru 50 vs medium ru 54). The directive stays in
    /// *words*; only the hard cap scales with the script.
    private func tokenBudget(for request: CompletionRequest) -> Int {
        let cyrillic = Self.isCyrillicHeavy(request.textBeforeCaret)
        var budget = lengthBox.get().maxTokens
        if cyrillic { budget = Int((Double(budget) * 1.7).rounded()) }
        let chatCap = cyrillic ? 13 : 8
        return request.isChatApp ? min(budget, chatCap) : budget
    }

    /// Sampling parameters shared by both completion paths (base and instruct),
    /// with values from Cotabby: a touch of temperature with a tight nucleus
    /// avoids greedy degeneracy, and a gentle (non-destructive) repetition
    /// penalty keeps it from looping. The eval harness forces greedy for determinism.
    private func completionParameters(for request: CompletionRequest) -> GenerateParameters {
        let envTemp = Float(ProcessInfo.processInfo.environment["PRETYPE_TEMPERATURE"] ?? "")
        // The confidence gate needs diverse draws, so it samples (default 0.6)
        // even when greedy is pinned. Otherwise: greedy → 0, else the live touch
        // of temperature (PRETYPE_TEMPERATURE overrides for dev sweeps).
        let temperature: Float = gateForceSample.get()
            ? (envTemp ?? 0.6)
            : (Self.greedy.get() ? 0.0 : (envTemp ?? 0.1))
        return GenerateParameters(
            maxTokens: tokenBudget(for: request),
            temperature: temperature,
            topP: 0.7,
            topK: 20,
            minP: 0.08,
            repetitionPenalty: 1.05
        )
    }

    func updateCompletion(length: CompletionLength, instructions: String) {
        lengthBox.set(length)
        instructionsBox.set(instructions)
    }

    func updatePersonalization(_ level: PersonalizationLevel) {
        personalizationBox.set(level)
    }

    /// The favored-word bias to apply this request, or nil when off / no history.
    private func currentBias() -> PersonalizationBias? {
        let level = personalizationBox.get()
        guard level.bias > 0 else { return nil }
        let words = Personalization.shared.topWords(256)
        guard !words.isEmpty else { return nil }
        return PersonalizationBias(words: words, weight: level.bias)
    }

    /// True when the recent text is majority-Cyrillic — used to widen the token
    /// budget so Russian word-count targets aren't clipped, and to localize the
    /// instruct directive.
    private static func isCyrillicHeavy(_ text: String) -> Bool {
        var cyrillic = 0
        var letters = 0
        for scalar in text.suffix(120).unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                cyrillic += 1
                letters += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        return letters >= 6 && cyrillic * 2 > letters
    }

    // MARK: - Fix selection

    var supportsCorrection: Bool { true }

    /// Fixes typos/grammar in a selected line via the instruct sibling model
    /// (loaded lazily, fresh KV cache). Minimal-edit prompt + a divergence guard
    /// keep it from rewriting the selection. The shared prompt/cleanup/guard live
    /// in `CorrectionGates`.
    func correct(selection: String, request: CompletionRequest) async throws -> String? {
        guard let task = beginRequest() else { return nil }
        defer { endRequest() }
        // Instruct style already runs the instruct model as primary; base
        // style loads the instruct sibling lazily on first ⌥Tab.
        let container = style == .instruct
            ? try await task.value
            : try await correctionContainer()
        try Task.checkCancellation()

        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500, !trimmed.contains("\n") else { return nil }

        // Instruct model through its OWN chat template — much stronger
        // instruction following than a raw few-shot prompt.
        let instruction = """
        \(CorrectionGates.correctionDirective)

        \(trimmed)
        """
        let messages: [[String: any Sendable]] = [["role": "user", "content": instruction]]

        // NO repetition penalty here: fixing typos means re-emitting most of
        // the original tokens verbatim, which a penalty actively punishes.
        // Budget scales with the selection so long lines aren't clipped.
        let parameters = GenerateParameters(
            maxTokens: CorrectionGates.correctionTokenBudget(forChars: trimmed.count), temperature: 0.0
        )
        let output = try await Self.generate(
            in: container,
            makeTokens: { context in
                try context.tokenizer.applyChatTemplate(messages: messages)
            },
            parameters: parameters,
            extraEOSTokens: extraEOSTokens,
            promptCache: nil
        )
        try Task.checkCancellation()

        let fixed = CorrectionGates.cleanCorrectionOutput(output)
        guard !fixed.isEmpty, fixed != trimmed else { return nil }
        guard CorrectionGates.isMinimalCorrection(original: trimmed, fixed: fixed) else {
            DebugLog.shared.log("FIX", "rejected over-rewrite",
                                detail: "\"\(trimmed)\" → \"\(fixed)\"")
            return nil
        }
        return fixed
    }

    /// FIM emulation is only reliable on E4B-class instruct models; on the smaller
    /// E2B it echoes the suffix / misfires (measured). Fine-tunes & unknown ids are
    /// treated as not capable, so auto-FIM stays conservative.
    static func isFIMCapable(_ modelID: String) -> Bool {
        modelID.lowercased().contains("e4b")
    }

    /// A reassuring download line. A multi-GB model otherwise sits at "0%" for
    /// minutes — the percent only reaches 1% after ~1% of several GB, and the
    /// large shards stream over HF's slower Xet path. Showing the byte counts
    /// proves it is alive and moving.
    private static func downloadStatus(_ progress: Progress, label: String = "downloading") -> String {
        let pct = Int((progress.fractionCompleted * 100).rounded())
        guard progress.totalUnitCount > 0 else { return "\(label) \(pct)%" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        let done = formatter.string(fromByteCount: progress.completedUnitCount)
        let total = formatter.string(fromByteCount: progress.totalUnitCount)
        return "\(label) \(done) / \(total) (\(pct)%)"
    }

    func shutdown() {
        idleTimer?.cancel(); idleTimer = nil
        memoryPressureSource?.cancel(); memoryPressureSource = nil
        modelLock.lock()
        loadTask?.cancel(); loadTask = nil
        correctionLoadTask?.cancel(); correctionLoadTask = nil
        modelLock.unlock()
    }

    private func correctionContainer() async throws -> ModelContainer {
        try await correctionLoadTaskOrCreate().value
    }

    private func correctionLoadTaskOrCreate() -> Task<ModelContainer, Error> {
        modelLock.lock(); defer { modelLock.unlock() }
        if let correctionLoadTask { return correctionLoadTask }
        let id = ProcessInfo.processInfo.environment["PRETYPE_TEST_FIX_MODEL"]
            ?? ModelCatalog.option(for: modelID)?.correctionModelID
            ?? ModelCatalog.options[0].correctionModelID
        let stateBox = self.stateBox
        let task = Task<ModelContainer, Error> { [weak self] in
            let previous = stateBox.get()
            stateBox.set(.preparing("loading fix model…"))
            do {
                let container = try await #huggingFaceLoadModelContainer(
                    configuration: ModelConfiguration(id: id),
                    progressHandler: { progress in
                        stateBox.set(.preparing(Self.downloadStatus(progress, label: "fix model")))
                    }
                )
                stateBox.set(previous)
                return container
            } catch {
                stateBox.set(previous)
                self?.clearCorrectionLoadTaskOnFailure()
                throw error
            }
        }
        correctionLoadTask = task
        return task
    }

    private func clearCorrectionLoadTaskOnFailure() {
        modelLock.lock()
        defer { modelLock.unlock() }
        correctionLoadTask = nil
    }
}
