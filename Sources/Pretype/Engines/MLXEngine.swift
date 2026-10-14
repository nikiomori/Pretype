import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import MLXNN
import MLXVLM
import HuggingFace
import Tokenizers

/// In-process inference on Apple Silicon via MLX. The model is downloaded
/// from Hugging Face on first use and cached in ~/.cache/huggingface.
///
/// Latency strategy: the KV cache is kept between keystrokes. Each request
/// resumes from the cached state sharing the longest prefix with its prompt
/// (trimmed back, or a checkpoint for caches that can't trim) and prefills
/// only the few new tokens; decoding stops as soon as the gate or trim has
/// decided the rest would never be shown. Per-keystroke cost is a handful of
/// decode steps instead of re-reading the whole context.
///
/// The model catalog and runtime support live in `ModelCatalog.swift`; the
/// token-iteration core, KV-cache and logit processors in
/// `MLXEngine+Generation.swift`; the shared output/correction gates in
/// `CompletionGates`/`CorrectionGates`.
final class MLXEngine: CompletionEngine {
    // These two are process-wide knobs the dev/eval harness sets ONCE at
    // startup, before any engine spins up, and the generation tasks then only
    // read them. A `LockedValue` makes the shared mutable state explicit and
    // thread-safe under the Swift 6 language mode.
    /// Verbose generation logging for the --complete test harness.
    static let debugLogging = LockedValue<Bool>(false)
    /// The harness's decoding pin (`PRETYPE_EVAL_SAMPLING=1` clears it), which
    /// it hands on to Apple Intelligence. MLX itself always decodes greedily
    /// (see `completionParameters`).
    static let greedy = LockedValue<Bool>(true)
    /// Pre-caret context-tail cap (chars).
    static let maxContextChars = 1000

    let name = "Local LLM (MLX)"

    private let modelID: String
    /// Fixed at init: switching style reloads the engine (different model).
    private let style: CompletionStyle
    /// Live-tunable from the menu without a reload.
    private let lengthBox: LockedValue<CompletionLength>
    private let instructionsBox: LockedValue<String>
    private let personalizationBox: LockedValue<PersonalizationLevel>
    /// Logprob confidence gate (base only): abstain when the shown suggestion's
    /// first-word logprob < this. nil = off. Fixed at init; enabled via
    /// Settings.logprobGate / PRETYPE_LOGPROB_GATE. 0× extra decode — the value
    /// is already captured by the live decode loop (firstWordLogProbBox).
    let logprobGateThreshold: Double?
    /// Confidence trim: cut the shown suggestion just before the first decode
    /// token whose logprob < this (never inside the first word). Same live
    /// recorder as the logprob gate — 0× extra decode; unlike the gate it trims
    /// instead of abstaining, so it's always on. −1.5 calibrated 2026-07-20
    /// (even-half sweep −4…−1, odd-half verified, MiniCPM + E2B-8bit): cuts ~8
    /// of ~14 garbage-tail chars per row at zero correct-char loss.
    /// PRETYPE_TRIM_LOGPROB pins it (numeric = τ sweep, "off" = force off).
    let trimLogProbThreshold: Float?
    /// The entropy half of the confidence trim (see `confidenceTrimmed`):
    /// stop at a token sampled from a distribution flatter than 2.5 nats.
    /// On top of the −1.5 logprob trim it cuts another ~1.1–1.3 garbage chars
    /// per suggestion (−17…−19%) at no measurable cost in correct chars or
    /// latency — eval-real EN+RU core, even-picked / odd-verified on E2B 8-bit
    /// and Qwen3.5 2B (Eval/runs-2026-10-11, analyze-entropy.py). Instruct
    /// primaries too: E2B-it / E4B-it 4-bit −0.14 / −0.37 garbage chars per
    /// row, correct chars unchanged, p50 a tie in interleaved pairs
    /// (Eval/runs-2026-10-11-audit, analyze-ient.py).
    private static let trimEntropyThreshold: Float = 2.5
    /// The PRIMARY model's state, written only by its own load and unload.
    private let stateBox = LockedValue<EngineState>(.preparing("starting…"))
    private var loadTask: Task<ModelContainer, Error>?
    /// Instruct model for fix-selection; loaded lazily on first ⌥Tab.
    private var correctionLoadTask: Task<ModelContainer, Error>?
    /// The fix model's load progress while that load runs, else nil. Kept
    /// apart from `stateBox`: the two loads overlap, and snapshotting the
    /// primary's state to restore it afterwards put back one that had moved
    /// on ("loading…" after the primary went ready pinned it busy for good).
    private let correctionStatus = LockedValue<String?>(nil)
    /// "The fix model's weights are on this machine" — see `isCorrectionReady`.
    /// Outlives an idle unload on purpose: unloading frees memory, not disk.
    private let correctionFetched = LockedValue(false)

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

    /// MTP drafters (see `ModelCatalog.mtpDrafterID`) for the instruct primary
    /// and for the base style's fix sibling, loaded and released with their
    /// model; nil = plain decoding.
    private let drafter = LockedValue<(any MTPDrafterModel)?>(nil)
    private let correctionDrafter = LockedValue<(any MTPDrafterModel)?>(nil)

    /// Parsed tokenizers, kept across idle unloads. Parsing tokenizer.json is
    /// most of a reload — Gemma 1.45 s of ~1.9 s, the weights loading in
    /// parallel finish first — for ~120 MB resident (Qwen3.5 ~86 MB) against
    /// the gigabytes the unload frees. Dropped with the engine, and when
    /// memory pressure forces the unload.
    private let tokenizers = TokenizerCache()

    /// The fix model's progress while it loads, else the primary's state.
    var state: EngineState { correctionStatus.get().map(EngineState.preparing) ?? stateBox.get() }

    var isLoading: Bool {
        modelLock.withLock {
            Self.isLoading(primary: stateBox.get(), primaryTaskLive: loadTask != nil,
                           correctionStatus: correctionStatus.get())
        }
    }

    /// `.preparing` with a live task = loading or downloading; `.preparing`
    /// with no task = the idle-unloaded resting state, where nothing runs and
    /// nothing writes — the protocol's default (any `.preparing` is busy)
    /// would report the app's most common state as busy forever. A finished
    /// fix model doesn't count: its task outlives its load.
    static func isLoading(primary: EngineState, primaryTaskLive: Bool, correctionStatus: String?) -> Bool {
        if correctionStatus != nil { return true }
        guard case .preparing = primary else { return false }
        return primaryTaskLive
    }

    /// The RESOLVED primary model (instruct sibling in instruct style) — what
    /// the journal must stamp. `modelID` is already post-resolution here (see
    /// `init`), unlike `Settings.mlxModelID`.
    var loadedModelID: String? {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    /// First-word confidence of the last completed ungated generation (see the
    /// protocol doc). Reset to nil when a generation starts, set only when it
    /// survives the output gate — so a read at suggestion-resolve time refers
    /// to the suggestion that was actually shown, not an abstained draw.
    private let firstWordLogProbBox = LockedValue<Double?>(nil)
    var lastFirstWordLogProb: Double? { firstWordLogProbBox.get() }

    var statusLine: String? {
        let model = modelID.split(separator: "/").last.map(String.init) ?? modelID
        switch state {
        case .preparing(let detail): return "\(model): \(detail)"
        case .ready: return "\(model): ready"
        case .failed(let detail): return "\(model): failed — \(detail)"
        }
    }

    init(modelID: String, config: CompletionConfig = .resolved()) {
        let baseOption = ModelCatalog.option(for: modelID)
        self.style = config.style
        self.lengthBox = LockedValue(config.length)
        self.instructionsBox = LockedValue(config.instructions)
        self.personalizationBox = LockedValue(config.personalization)
        let env = ProcessInfo.processInfo.environment
        // A SET env var pins the knob regardless of Settings — non-numeric
        // ("off") disables. Falling back to Settings on a set-but-non-numeric
        // value would let eval runs silently inherit the app's live config.
        if let e = env["PRETYPE_LOGPROB_GATE"] {
            self.logprobGateThreshold = Double(e)
        } else if Settings.logprobGate {
            // Recommended settings follow the model: τ is calibrated per model
            // (Q4 edges −0.75…−1.12 — see Recommendation.logprobGateTau); a
            // hand-tuned threshold (useRecommendedSettings off) applies as-is.
            self.logprobGateThreshold = Settings.useRecommendedSettings
                ? ModelCatalog.recommended(for: modelID).logprobGateTau ?? Settings.logprobGateThreshold
                : Settings.logprobGateThreshold
        } else {
            self.logprobGateThreshold = nil
        }
        self.trimLogProbThreshold = env["PRETYPE_TRIM_LOGPROB"].map { Float($0) } ?? -1.5

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
        // Once per engine, not per keystroke: the reason never changes while
        // it lives, and logged inline it filled the 400-entry ring.
        if config.style == .instruct, !Self.isFIMCapable(primaryID) {
            DebugLog.shared.log("GATE", "fill-in-the-middle off — \(primaryID) is not E4B-class (unreliable here)")
        }

        guard MLXSupport.isAvailable else {
            stateBox.set(.failed("Metal shaders missing — build with Scripts/make-app.sh or run Scripts/dev.sh"))
            return
        }
        // MLX's freed-buffer pool fills to whatever cap it gets: 512 MB sat
        // full (~510 MB on top of the weights), while 64 MB measured the same
        // per-keystroke latency on E4B-8bit and E2B-4bit (16 MB starts to
        // show in p90). ~450 MB back for the rest of the Mac.
        Memory.cacheLimit = 64 * 1024 * 1024
        loadTask = makeLoadTask()
        didInitLoad = true
        startIdleMaintenance()
    }

    // MARK: - Model lifecycle (load · idle-unload · reload)

    private func makeLoadTask() -> Task<ModelContainer, Error> {
        let stateBox = self.stateBox
        let id = self.modelID
        let tokenizers = self.tokenizers
        let drafterBox = self.drafter
        let drafterID = style == .instruct ? ModelCatalog.mtpDrafterID(for: id) : nil
        stateBox.set(.preparing("loading…"))
        return Task { [weak self] in
            // Resolved once, so the load report names the build that loaded.
            let repo = ModelCatalog.repo(for: id)
            do {
                let loaded = try await Self.loadTarget(
                    Self.configuration(for: repo), drafterID: drafterID, into: drafterBox, tokenizers: tokenizers,
                    progressHandler: { progress in stateBox.set(.preparing(Self.downloadStatus(progress))) })
                ModelStorage.noteLoad(repo: repo, succeeded: true)
                // Retired mid-load (a model switch, `shutdown`): don't warm up
                // weights nobody will use next to the replacement's.
                try Task.checkCancellation()
                // The first generation pays for Metal kernel compilation; do it
                // now so the first real keystroke doesn't. The prompt is long
                // enough to take the split-prefill path too — a 2-token warm-up
                // left those kernels to the first keystroke (up to +120 ms on a
                // cold Metal shader cache, measured).
                // A warm-up failure shouldn't block readiness (the next real
                // request surfaces it), but it must not be swallowed silently.
                // Reloads after an idle unload warm up too: kernels survive the
                // unload, but the fresh weights and buffer pool don't — skipping
                // it moved +30–140 ms onto the first keystroke (measured).
                stateBox.set(.preparing("warming up…"))
                do {
                    _ = try await Self.generate(
                        in: loaded, makeTokens: { $0.tokenizer.encode(text: Self.warmUpPrompt) },
                        parameters: GenerateParameters(maxTokens: 3, temperature: 0.0),
                        promptCache: nil
                    )
                } catch {
                    DebugLog.shared.log("ERROR", "warm-up generation failed: \(error.localizedDescription)")
                }
                try Task.checkCancellation()
                stateBox.set(.ready)
                if let self { self.modelLock.withLock { self.lastLoadFailure = nil } }
                return loaded
            } catch {
                if !(error is CancellationError) { ModelStorage.noteLoad(repo: repo, succeeded: false) }
                stateBox.set(.failed(error.localizedDescription))
                if let self {
                    self.modelLock.withLock {
                        self.loadTask = nil
                        self.lastLoadFailure = Date()
                    }
                }
                throw error
            }
        }
    }

    /// Where to load `repo` from: its downloaded snapshot (no network round
    /// trip, see `ModelStorage.localSnapshot`), else the Hub at the pinned
    /// revision.
    private static func configuration(for repo: String) -> ModelConfiguration {
        ModelStorage.cacheDirectory(repo: repo).flatMap(ModelStorage.localSnapshot(at:))
            .map { ModelConfiguration(directory: $0) }
            ?? ModelConfiguration(id: repo, revision: ModelCatalog.revision(for: repo))
    }

    private static let warmUpPrompt = String(repeating: "The weekly update covers hiring, the roadmap and next steps. ", count: 7)

    /// Frees the weights of a multimodal build's vision/audio towers: the
    /// engine only ever sends text (−320 MB on E2B-it).
    private static func dropUnusedTowers(_ container: ModelContainer) async {
        await container.perform { (context: ModelContext) in
            let towers = context.model.parameters().flattened().filter { key, _ in
                ["vision_tower", "audio_tower", "embed_vision", "embed_audio"].contains { key.hasPrefix($0) }
            }
            guard !towers.isEmpty else { return }
            let empty = Dictionary(uniqueKeysWithValues: towers.map { ($0.0, MLXArray.zeros([0], dtype: $0.1.dtype)) })
            try? context.model.update(parameters: ModuleParameters.unflattened(empty), verify: [.none])
        }
        Memory.clearCache()
    }

    /// Drafters whose background fetch already ran this launch. An idle-unload
    /// reload retried it every time — offline, a failure per reload; on a slow
    /// line, a second 150 MB fetch overlapping the first.
    private static let drafterFetches = LockedValue<Set<String>>([])

    /// Loads a model, with its MTP drafter into `drafterBox` when `drafterID`
    /// names one that is already on disk. A missing drafter downloads in the
    /// background for the next load — 150 MB must not hold up this one — once
    /// per launch. It is part of the model the user already chose (listed and
    /// deleted with it, see `ModelStorage.repos`), so it rides that consent.
    private static func loadTarget(
        _ configuration: ModelConfiguration, drafterID: String?,
        into drafterBox: LockedValue<(any MTPDrafterModel)?>, tokenizers: TokenizerCache,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        drafterBox.set(nil)
        if let drafterID {
            if let local = ModelStorage.localSnapshot(for: drafterID) {
                // MTP needs the target's last hidden state, which only the VLM
                // build of Gemma 4 emits; its unused vision tower is freed right
                // after, so the drafter is the whole extra cost.
                do {
                    let vlm = try await VLMModelFactory.shared.loadContainer(
                        from: #hubDownloader(), using: tokenizers,
                        configuration: configuration, progressHandler: progressHandler)
                    await dropUnusedTowers(vlm)
                    drafterBox.set(try await loadDrafter(at: local))
                    return vlm
                } catch {
                    drafterBox.set(nil)
                    // Cancelled is not "no drafter": falling through would start
                    // a second, plain load for an engine already retired.
                    if error is CancellationError { throw error }
                    DebugLog.shared.log("MLX", "MTP drafter unavailable (\(error.localizedDescription)) — plain decoding")
                }
            } else if drafterFetches.mutate({ $0.insert(drafterID).inserted }) {
                Task.detached(priority: .utility) {
                    do {
                        _ = try await #hubDownloader().download(
                            id: drafterID, revision: ModelCatalog.revision(for: drafterID),
                            matching: ["*.safetensors", "*.json"],
                            useLatest: false, progressHandler: { _ in })
                    } catch {
                        DebugLog.shared.log("MLX", "MTP drafter download failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        // LLMModelFactory, not loadModelContainer: with MLXVLM linked the generic
        // loader picks the VLM classes first (Qwen3.5's lacks the raw-token call
        // the decode loop uses).
        return try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: tokenizers,
            configuration: configuration, progressHandler: progressHandler)
    }

    private static func loadDrafter(at directory: URL) async throws -> any MTPDrafterModel {
        let config = try JSONDecoder().decode(
            Gemma4AssistantConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let model = Gemma4AssistantDraftModel(config)
        try await loadWeights(modelDirectory: directory, model: model)
        return model
    }

    /// Marks a request in-flight and returns the model-load task, reloading it if
    /// it was idle-unloaded. Returns nil when the engine never initialized (e.g.
    /// Metal missing) or is in its post-failure cooldown — callers then abstain.
    /// Pair with `endRequest()`.
    func beginRequest() -> Task<ModelContainer, Error>? {
        modelLock.withLock {
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
    }

    /// `beginRequest` for work that runs on the fix sibling only (base style's
    /// fix and reply): holds off the idle unload without reloading — or, in its
    /// failure cooldown, refusing on behalf of — the completion model, which
    /// this request never touches. Pair with `endRequest()`.
    private func beginSiblingRequest() -> Bool {
        modelLock.withLock {
            guard didInitLoad else { return false }
            inFlightCount += 1
            lastActivity = Date()
            return true
        }
    }

    func endRequest() {
        modelLock.withLock {
            inFlightCount = max(0, inFlightCount - 1)
            lastActivity = Date()
        }
    }

    /// Starts a background reload if the model was idle-unloaded, so a focus
    /// change or first keystroke hides the reload latency. Cheap no-op (lock +
    /// nil check) when the model is already loaded or loading.
    func prewarmIfNeeded() {
        modelLock.withLock {
            guard didInitLoad, loadTask == nil else { return }
            // Same failure backoff as beginRequest — a focus change shouldn't retry a
            // model that just failed to load.
            if let failedAt = lastLoadFailure, Date().timeIntervalSince(failedAt) < Self.loadRetryCooldown { return }
            DebugLog.shared.log("MLX", "prewarming model after idle")
            lastActivity = Date()
            loadTask = makeLoadTask()
        }
    }

    /// Prefills `request`'s prompt into the KV cache without decoding. The
    /// context blocks at the head of the prompt (window OCR, retrieved
    /// examples) refresh off the typing path, and each refresh invalidates the
    /// cache from the head on: the next keystroke re-read the whole prompt
    /// (~0.45 s on E4B-8bit for 460 tokens, measured). Called when such a
    /// block lands, this moves that read here, ahead of the keystroke. Only
    /// with the model resident or already loading (it then prefills once the
    /// load lands) — a context refresh is no reason to start a load.
    func warmPrompt(for request: CompletionRequest) {
        guard modelLock.withLock({ loadTask != nil }) else { return }
        Task { [weak self] in
            _ = try? await self?.run(request, prefillOnly: true)
        }
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
        // Not mid-load. An idle-unloaded or failed primary (its task is nil
        // either way) still lets a fix model that loaded on its own
        // (prewarmCorrection, a base-style ⌥⇥) be freed.
        let primary = stateBox.get()
        guard inFlightCount == 0, idleEnough,
              loadTask != nil || correctionLoadTask != nil,
              !Self.isLoading(primary: primary, primaryTaskLive: loadTask != nil,
                              correctionStatus: correctionStatus.get()) else {
            modelLock.unlock(); return
        }
        let before = Memory.snapshot().activeMemory
        loadTask?.cancel(); loadTask = nil
        correctionLoadTask?.cancel(); correctionLoadTask = nil
        // Still under the lock: a request arriving the moment it drops starts
        // a reload, and these writes landing after it would erase that load's
        // drafter and paint "idle" over its "loading…".
        drafter.set(nil)
        correctionDrafter.set(nil)
        Memory.clearCache()
        promptCache.clear()
        if reason == "memory pressure" { tokenizers.clear() }
        // A failure stays on screen until a retry replaces it.
        if case .failed = primary {} else { stateBox.set(.preparing("idle — model unloaded")) }
        modelLock.unlock()

        let freed = Int64(max(0, before - Memory.snapshot().activeMemory))
        let amount = ByteCountFormatter.string(fromByteCount: freed, countStyle: .memory)
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
            let (idle, busy) = self.modelLock.withLock {
                (Date().timeIntervalSince(self.lastActivity), self.inFlightCount > 0)
            }
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
        try await run(request)
    }

    /// The completion path for this engine's style.
    private func run(_ request: CompletionRequest, onPartial: (@Sendable (String) -> Void)? = nil,
                     prefillOnly: Bool = false) async throws -> String? {
        switch style {
        case .base: return try await completeBase(request, onPartial: onPartial, prefillOnly: prefillOnly)
        case .instruct: return try await completeInstruct(request, onPartial: onPartial, prefillOnly: prefillOnly)
        }
    }

    func completions(for request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // The logprob gate streams too: its verdict (first-word mean
                    // logprob) exists as soon as the first word is decoded, and
                    // the decode loop holds partials back until then — so no
                    // gated stream flashes a suggestion the gate retracts.
                    let lastYielded = LockedValue<String?>(nil)
                    let onPartial: @Sendable (String) -> Void = {
                        lastYielded.set($0)
                        continuation.yield($0)
                    }
                    let final = try await run(request, onPartial: onPartial)
                    // The confidence trim shortens the final text AFTER the last
                    // partial went out — yield the reconciled result so the UI
                    // replaces the streamed tail with the trimmed suggestion.
                    if let final, final != lastYielded.get() {
                        continuation.yield(final)
                    } else if final == nil, lastYielded.get() != nil {
                        // A post-stream abstain (logprob gate; a final-only gate
                        // rejection like a language flip that needs ≥12 chars)
                        // must RETRACT the partials already on screen. "" is the
                        // retract signal — a real suggestion is never empty (the
                        // gates reject empty).
                        continuation.yield("")
                    }
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

    /// Shared prompt preparation for both completion paths (see `PreparedPrompt`).
    private func prepare(_ request: CompletionRequest,
                         midWordFloor: Int, boundaryFloor: Int,
                         personalPreamble: Bool = false) -> PreparedPrompt? {
        PreparedPrompt(request.completionPrompt(maxChars: Self.maxContextChars), request: request,
                       midWordFloor: midWordFloor, boundaryFloor: boundaryFloor,
                       preamble: personalPreamble ? request.personalPreambleBlock : nil)
    }

    /// Token healing for the mid-word caret state. A prompt that ends inside a
    /// word usually ends inside a BPE token too, and the model then continues
    /// as if a fresh word were starting — "goi" + "ing" → "goiing" (measured:
    /// 5–9% first-word on eval-real-mid vs ~30% at word boundaries, 2026-07-17).
    /// Back the prompt up to the word boundary so the model regenerates the
    /// whole word, require the decode to reproduce the fragment the user
    /// already typed, and emit only the remainder; a decode that contradicts
    /// the fragment abstains — precision over coverage mid-word. Side effect:
    /// the healed prompt is stable while a word is being typed, so the KV
    /// cache holds across those keystrokes. Returns nil at a word boundary,
    /// when nothing precedes the fragment, or when the fragment isn't
    /// healable (CJK letter-runs have no word boundary to back up to; the
    /// length cap rejects pasted letter-runs).
    static func tokenHealing(text: String) -> (dropCount: Int, expected: String)? {
        let fragment = String(text.reversed().prefix(while: \.isLetter).reversed())
        guard !fragment.isEmpty, fragment.count <= 24,
              !fragment.unicodeScalars.contains(where: isHealBlockedScript)
        else { return nil }
        var head = text.dropLast(fragment.count)
        var separated = false
        while head.hasSuffix(" ") {
            head.removeLast()
            separated = true
        }
        guard !head.isEmpty else { return nil }
        return (dropCount: text.count - head.count,
                expected: (separated ? " " : "") + fragment)
    }

    /// Han / kana / Hangul — scripts where a trailing letter-run is not "a word
    /// being typed", so there is no boundary to heal from.
    private static func isHealBlockedScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF65...0xFF9F:
            return true
        default:
            return false
        }
    }

    /// Raw text continuation against a base model: encode the tail, continue it.
    /// A base model given only 3-4 tokens lands in random-language territory
    /// (verified: "а теперь" → Turkish gibberish), so it floors higher than the
    /// instruct path — except mid-word, where the partial word constrains it.
    private func completeBase(_ request: CompletionRequest,
                              onPartial: (@Sendable (String) -> Void)? = nil,
                              prefillOnly: Bool = false) async throws -> String? {
        guard let task = beginRequest() else { return nil }
        defer { endRequest() }
        let container = try await task.value
        try Task.checkCancellation()

        // The retrieved accepted phrases ride the base prompt as a label-free
        // preamble (the RAG signal, p=0.016 on instruct, ported to the path
        // that actually wins — see Eval/BASELINE.md "the prize").
        guard let prepared = prepare(request, midWordFloor: 10, boundaryFloor: 16,
                                     personalPreamble: true) else { return nil }

        // First-word confidence capture: reset up front so a stale value from a
        // previous generation can never be journaled against this one; publish
        // below only when the result survives the output gate, so a resolve-time
        // read refers to the suggestion that was shown. A warm-up prefill must
        // not touch the box: it describes the suggestion on screen, which this
        // call doesn't replace.
        let recording = !prefillOnly
        if recording { firstWordLogProbBox.set(nil) }
        let logProbSink = recording ? LockedValue<Double?>(nil) : nil

        let parameters = completionParameters(for: request)
        // Mid-word: decode from the word boundary and strip the re-generated
        // fragment (see tokenHealing).
        let heal = prepared.endsMidWord ? Self.tokenHealing(text: prepared.text) : nil
        func healed(_ gate: @escaping @Sendable (String) -> String?) -> @Sendable (String) -> String? {
            guard let expected = heal?.expected else { return gate }
            return { out in
                out.hasPrefix(expected) ? gate(String(out.dropFirst(expected.count))) : nil
            }
        }
        let healedGate = healed(prepared.gate(cleanInstruct: false))
        let generationText = heal.map { String(prepared.generationText.dropLast($0.dropCount)) }
            ?? prepared.generationText
        let promptCache = self.promptCache
        let output = try await Self.generate(
            in: container,
            makeTokens: { promptCache.encoder.encode(generationText, with: $0.tokenizer) },
            parameters: parameters,
            promptCache: promptCache,
            // Under healing the first decoded word is the CURRENT word being
            // re-generated, not the next one — the next-word bias would
            // fight the fragment match.
            bias: heal == nil ? ngramBias(for: prepared) : nil,
            logProbSink: logProbSink,
            trimLogProb: recording ? trimLogProbThreshold : nil,
            trimEntropy: recording ? Self.trimEntropyThreshold : nil,
            // Healed suggestions bypass the gate (see below).
            gateLogProb: recording && heal == nil ? logprobGateThreshold : nil,
            healExpected: heal?.expected,
            prefillOnly: prefillOnly,
            onPartial: Self.makeStreamHandler(
                onPartial, gate: healed(prepared.gate(cleanInstruct: false, logRejects: false)))
        )
        if prefillOnly { return nil }
        try Task.checkCancellation()
        if let heal, !output.hasPrefix(heal.expected) {
            DebugLog.shared.log("GATE", "token-healing: decode \(output.prefix(24).debugDescription) contradicts typed fragment \(heal.expected.debugDescription) — abstaining")
        }
        let result = healedGate(output)
        let lp = recording ? logProbSink?.get() : nil
        // Logprob confidence gate: abstain on a low-confidence first word. 0× extra
        // decode (lp is already captured above). Base only by construction —
        // completeBase is never the instruct path, where the calibration doesn't hold.
        // Healed suggestions bypass the gate: τ is calibrated on word-boundary
        // next-word logprobs, but under healing lp is the fragment path of the
        // CURRENT word (forced tokens under constrained decode) — a different
        // scale that the word-boundary τ mostly rejects, while fragment-match
        // already holds healed precision at ~77% (mid3, ANALYTICS §6в′).
        if let thr = logprobGateThreshold, result != nil, heal == nil, let lp, lp < thr {
            DebugLog.shared.log("GATE", "logprob-gate: first-word \(String(format: "%.2f", lp)) < \(thr) — abstaining")
            firstWordLogProbBox.set(nil)
            return nil
        }
        if recording, result != nil { firstWordLogProbBox.set(lp) }
        return result
    }

    /// Persona-aware continuation through the instruct model's chat template:
    /// a "continue, ~N words, match voice" directive + optional author profile,
    /// then the text. The KV cache still applies — the directive/persona are a
    /// constant prefix, so only the new characters re-prefill per keystroke.
    private func completeInstruct(_ request: CompletionRequest,
                                  onPartial: (@Sendable (String) -> Void)? = nil,
                                  prefillOnly: Bool = false) async throws -> String? {
        guard let task = beginRequest() else { return nil }
        defer { endRequest() }
        let container = try await task.value
        try Task.checkCancellation()

        // Lower floor than the base path: the instruct model is grounded by the
        // directive + persona, so it stays coherent on short context (e.g. the
        // first few words of a chat message) instead of going off-language.
        guard let prepared = prepare(request, midWordFloor: 6, boundaryFloor: 10) else { return nil }
        let promptText = prepared.text

        // Gemma has no system role, so the directive rides in the user turn.
        let length = lengthBox.get()
        let persona = request.persona(global: instructionsBox.get())
        // Fill-in-the-Middle: emulate suffix-conditioning via the prompt (Gemma 4
        // has no FIM tokens). Only on E4B-class models — it's unreliable on the
        // smaller E2B (measured; the skip is logged once, in init). Needs a
        // non-trivial suffix, so it's a no-op at end-of-line.
        let suffixForPrompt = String(request.textAfterCaret.prefix(200))
        let hasSuffix = !suffixForPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let infill = hasSuffix && Self.isFIMCapable(modelID)

        var directive = infill
            ? """
            You are filling a gap in the user's text where the cursor sits between BEFORE \
            and AFTER. Output ONLY the specific missing words that belong in the gap — the \
            content itself (an object, name, time, place or action), NEVER a linking word \
            such as "because", "and", "so", "before" or "due to". BEFORE + your words + \
            AFTER must read as one natural sentence in the same language, and your words \
            must not repeat anything already in AFTER. No quotes, no explanation.

            BEFORE: \(promptText)
            AFTER: \(suffixForPrompt)
            """
            : """
            Continue the text in the same language, tone and register. Reply with \
            ONLY the words that come next (\(length.wordsHint)) — do \
            not repeat the existing text, no quotes, no explanation.
            """
        if !persona.isEmpty {
            directive += "\n\nAuthor profile (for voice only, never quote it):\n\(persona)"
        }
        // Retrieval-augmented few-shot: the user's own past continuations, most
        // similar to the current context (LaMP-style personalization). Rides in
        // the directive AFTER persona so the changing text stays the prompt tail
        // (KV-cache-friendly: examples only change on their off-path refresh).
        if !request.personalExamples.isEmpty {
            directive += "\n\nHow the author continued similar text before (style reference only, do not copy verbatim):"
            for example in request.personalExamples.prefix(3) {
                directive += "\nText: …\(example.ctx)\nNext:\(example.next.hasPrefix(" ") ? "" : " ")\(example.next)"
            }
        }
        // Capture an immutable copy in the @Sendable token closure below: a
        // captured `var` crosses a concurrency boundary.
        let directiveText = directive

        // Same first-word confidence capture as the base path (see there). One
        // caveat for calibration: this logprob is conditioned on the instruct
        // prompt (directive + persona + template), i.e. the distribution the
        // live path actually sampled from — deliberately NOT the raw-context
        // score `logProbMean` computes offline.
        let recording = !prefillOnly
        if recording { firstWordLogProbBox.set(nil) }
        let logProbSink = recording ? LockedValue<Double?>(nil) : nil

        let parameters = completionParameters(for: request)
        let gate = prepared.gate(cleanInstruct: true)
        let promptCache = self.promptCache
        let output = try await Self.generate(
            in: container,
            makeTokens: { context in
                // infill already embeds BEFORE/AFTER in the directive.
                let userContent = infill ? directiveText : "\(directiveText)\n\nText:\n\(promptText)"
                let messages: [[String: any Sendable]] = [["role": "user", "content": userContent]]
                // Hybrid-reasoning templates (MiniCPM5/Qwen3-style) default to a
                // <think> block that burns the whole token budget; ask for the
                // no-think branch. Templates without the variable (Gemma) ignore it.
                let render = {
                    try context.tokenizer.applyChatTemplate(
                        messages: messages, tools: nil,
                        additionalContext: ["enable_thinking": false])
                }
                // The text is the user turn's tail here, so only it changes per
                // keystroke — splice it instead of re-rendering the template.
                return infill
                    ? try render()
                    : try promptCache.templateSplice.tokens(
                        key: directiveText, text: promptText, tokenizer: context.tokenizer, render: render)
            },
            parameters: parameters,
            // No first-token boost: instruct answers flush, so the space-led
            // boost tokens can't match — personalization rides the directive
            // (persona + RAG examples) here instead.
            promptCache: promptCache,
            logProbSink: logProbSink,
            trimLogProb: recording ? trimLogProbThreshold : nil,
            trimEntropy: recording ? Self.trimEntropyThreshold : nil,
            prefillOnly: prefillOnly,
            // No drafter here: starting the speculative iterator costs ~25 ms
            // before the first token, and a streamed suggestion is judged by
            // its first word (measured: first-visible p50 +8 ms, final −5%).
            // The drafter pays off on the longer, non-streamed fix and reply.
            onPartial: Self.makeStreamHandler(
                onPartial, gate: prepared.gate(cleanInstruct: true, logRejects: false))
        )
        if prefillOnly { return nil }
        try Task.checkCancellation()
        let result = gate(output)
        if recording, result != nil { firstWordLogProbBox.set(logProbSink?.get()) }
        return result
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

    /// Decoding parameters shared by both completion paths (base and instruct).
    /// Greedy — argmax IS the model's best guess (beam rerank on its own
    /// posterior scored p=1.0), so every draw below argmax is expected loss,
    /// and the T=0.1 "touch of temperature" inherited from Cotabby was never
    /// measured here: the harness always pinned greedy, so no booked number ever
    /// described that decoder. No repetition penalty for the same reason plus
    /// one of its own — in real typing the words most likely to repeat (a
    /// name, a term, the project you're writing about) are exactly the ones it
    /// suppresses, and its processor also skews the logprobs the gate reads.
    private func completionParameters(for request: CompletionRequest) -> GenerateParameters {
        GenerateParameters(maxTokens: tokenBudget(for: request), temperature: 0)
    }

    func updateCompletion(length: CompletionLength, instructions: String) {
        lengthBox.set(length)
        instructionsBox.set(instructions)
    }

    func updatePersonalization(_ level: PersonalizationLevel) {
        personalizationBox.set(level)
    }

    /// Context-conditioned personal boost for the first generated token: the
    /// words the user has typed after this very context (personal n-gram),
    /// weighted by evidence — level.bias × `PersonalNgram.fusionBoost` (measured
    /// directionally positive, discordants 3/0), at zero extra decode cost. Replaces the flat
    /// favored-word bias, which measured null (p=1.0): context-free frequent
    /// words are already probable, so biasing them moves nothing. nil when
    /// personalization is off or the context is unseen.
    private func ngramBias(for prepared: PreparedPrompt) -> [String: Float]? {
        let level = personalizationBox.get()
        guard level.bias > 0 else { return nil }
        // An unfinished word at the caret: a next-word boost could truncate it.
        if prepared.endsMidWord, !prepared.endsCompleteWord { return nil }
        let counts = PersonalNgram.shared.continuations(after: prepared.text)
        guard !counts.isEmpty else { return nil }
        // ponytail: top-32 by evidence — bounds the per-generation tokenizer
        // encodes in makeBiasProcessor (a frequent context word can carry
        // hundreds of continuations); raise if a measured win ever wants more.
        let top = counts.sorted { $0.value > $1.value }.prefix(32)
        return Dictionary(uniqueKeysWithValues: top.map {
            ($0.key, level.bias * Float(PersonalNgram.fusionBoost(count: $0.value)))
        })
    }

    /// True when the recent text is majority-Cyrillic — used to widen the token
    /// budget so Russian word-count targets aren't clipped.
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

    /// Fixes typos/grammar in a selected line via the instruct sibling model
    /// (loaded lazily, fresh KV cache). Minimal-edit prompt + a divergence guard
    /// keep it from rewriting the selection (see `CorrectionGates.fix`). NO
    /// repetition penalty: fixing typos means re-emitting most of the original
    /// tokens verbatim, which a penalty actively punishes.
    func correct(selection: String, request: CompletionRequest,
                 redactLog: Bool) async throws -> String? {
        try await CorrectionGates.fix(selection, redactLog: redactLog, logTag: "FIX") {
            // The generation log prints its own raw output — redacting only the
            // divergence-guard line would leave the same sentence in the
            // buffer twenty lines earlier, on the SUCCESS path at that.
            try await self.chatGenerate($0, maxTokens: $1, copiesInput: true, logRaw: !redactLog)
        }
    }

    // MARK: - Voice command

    func rewrite(selection: String, instruction: String,
                 request: CompletionRequest) async throws -> String? {
        try await CorrectionGates.rewrite(selection, instruction: instruction) {
            try await self.chatGenerate($0, maxTokens: $1, logRaw: false)
        }
    }

    // MARK: - Reply

    /// Writes the user's next message from the conversation on screen, through
    /// the same instruct sibling (and the same lazy load) as the ⌥⇥ fix — a base
    /// model can't follow "answer this". One shot, no prompt cache: the prompt is
    /// a fresh screenful every time, so a cache would only ever miss.
    func reply(to conversation: String, request: CompletionRequest) async throws -> String? {
        try await CorrectionGates.reply(to: conversation, request: request, instructions: instructionsBox.get()) {
            try await self.chatGenerate($0, maxTokens: $1)
        }
    }

    /// One greedy turn through the instruct model's OWN chat template — much
    /// stronger instruction following than a raw few-shot prompt. Instruct
    /// style already runs that model as primary; base style loads the instruct
    /// sibling lazily on first use. No prompt cache: each prompt is fresh.
    /// `copiesInput`: the answer mostly re-types the prompt's text (the fix,
    /// and the dictation tidy-up that runs through it) — draft from it rather
    /// than from the MTP drafter. Not voice rewrites: "translate this" copies
    /// nothing, and that path was never measured.
    private func chatGenerate(_ content: String, maxTokens: Int, copiesInput: Bool = false,
                              logRaw: Bool = true) async throws -> String {
        let primary: Task<ModelContainer, Error>?
        if style == .instruct {
            guard let task = beginRequest() else { throw EngineNotReady() }
            primary = task
        } else {
            guard beginSiblingRequest() else { throw EngineNotReady() }
            primary = nil
        }
        defer { endRequest() }
        let container: ModelContainer
        if let primary {
            container = try await primary.value
        } else {
            container = try await correctionContainer()
        }
        try Task.checkCancellation()
        let messages: [[String: any Sendable]] = [["role": "user", "content": content]]
        return try await Self.generate(
            in: container,
            makeTokens: { context in
                // Without enable_thinking=false the MiniCPM RL template opens a
                // think turn and the fix path generates NOTHING (eval-correct
                // 2026-07-25: 0/510 offered); Gemma templates ignore the key.
                try context.tokenizer.applyChatTemplate(
                    messages: messages, tools: nil,
                    additionalContext: ["enable_thinking": false])
            },
            parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.0),
            promptCache: nil,
            drafter: style == .instruct ? drafter.get() : correctionDrafter.get(),
            lookup: copiesInput,
            logRaw: logRaw
        )
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
        modelLock.withLock {
            // A late `warmPrompt` or prewarm on this retired engine must not
            // rebuild a whole model next to the replacement's.
            didInitLoad = false
            loadTask?.cancel(); loadTask = nil
            correctionLoadTask?.cancel(); correctionLoadTask = nil
        }
    }

    /// Whether a fix would cost at most a LOAD, never a download.
    ///
    /// Deliberately not "is the model resident": an idle-unloaded model is
    /// still on disk, and re-reading it is exactly the kind of wait the
    /// tidy-up's own budget is there to bound. What no budget can absorb is a
    /// multi-gigabyte fetch — so that, and only that, answers false.
    ///
    /// Both styles are probed, and the first draft of this was wrong to skip
    /// instruct: it fixes with the PRIMARY model, which is only "already here"
    /// after its own first download — on a fresh install that is the same
    /// multi-gigabyte wait, reached by a different branch.
    ///
    /// Memoized once true: the answer can only go from "not fetched" to
    /// "fetched" while an engine lives. The first probe is still a small
    /// directory read on whatever thread asks (often main); the memo only
    /// spares every call after it.
    var isCorrectionReady: Bool {
        if correctionFetched.get() { return true }
        let fetched = ModelStorage.isFetched(style == .instruct ? modelID : correctionModelID)
        if fetched { correctionFetched.set(true) }
        return fetched
    }

    func prewarmCorrection() {
        guard style != .instruct else { return prewarmIfNeeded() }
        _ = correctionLoadTaskOrCreate()
    }

    /// The sibling `correct` would use — resolved the same way
    /// `correctionLoadTaskOrCreate` resolves it.
    private var correctionModelID: String {
        ProcessInfo.processInfo.environment["PRETYPE_TEST_FIX_MODEL"]
            ?? ModelCatalog.option(for: modelID)?.correctionModelID
            ?? ModelCatalog.options[0].correctionModelID
    }

    private func correctionContainer() async throws -> ModelContainer {
        try await correctionLoadTaskOrCreate().value
    }

    private func correctionLoadTaskOrCreate() -> Task<ModelContainer, Error> {
        modelLock.withLock {
            if let correctionLoadTask { return correctionLoadTask }
            let id = correctionModelID
            let status = self.correctionStatus
            let correctionFetched = self.correctionFetched
            let tokenizers = self.tokenizers
            let drafterBox = self.correctionDrafter
            // Set under the lock, before the task runs, so `unload` can't cancel
            // a load that hasn't reported itself yet.
            status.set("loading fix model…")
            let task = Task<ModelContainer, Error> { [weak self] in
                let repo = ModelCatalog.repo(for: id)
                do {
                    let container = try await Self.loadTarget(
                        Self.configuration(for: repo),
                        drafterID: ModelCatalog.mtpDrafterID(for: id), into: drafterBox, tokenizers: tokenizers,
                        progressHandler: { progress in
                            status.set(Self.downloadStatus(progress, label: "fix model"))
                        }
                    )
                    ModelStorage.noteLoad(repo: repo, succeeded: true)
                    status.set(nil)
                    // Whatever the disk probe thought, the weights are provably
                    // here now — and after an idle unload nils the task, this is
                    // what keeps the next fix from being skipped as "not fetched".
                    correctionFetched.set(true)
                    return container
                } catch {
                    if !(error is CancellationError) { ModelStorage.noteLoad(repo: repo, succeeded: false) }
                    // Before the slot frees: a retry's fresh status must not be cleared.
                    status.set(nil)
                    if let self { self.modelLock.withLock { self.correctionLoadTask = nil } }
                    throw error
                }
            }
            correctionLoadTask = task
            return task
        }
    }
}

/// `TokenizerLoader` that parses each tokenizer directory once per engine.
final class TokenizerCache: TokenizerLoader, @unchecked Sendable {
    private let byDirectory = LockedValue<[URL: any MLXLMCommon.Tokenizer]>([:])

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        if let hit = byDirectory.get()[directory] { return hit }
        let tokenizer = try await #huggingFaceTokenizerLoader().load(from: directory)
        byDirectory.mutate { $0[directory] = tokenizer }
        return tokenizer
    }

    func clear() {
        byDirectory.set([:])
    }
}
