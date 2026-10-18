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
/// The model catalog lives in `ModelCatalog.swift`; which models are in
/// memory, and for how long, in `ModelResidency`; the token-iteration core,
/// KV-cache and logit processors in `MLXEngine+Generation.swift`; how a model
/// is built and rebuilt in `MLXEngine+Loading.swift`; the shared
/// output/correction gates in `CompletionGates`/`CorrectionGates`.
final class MLXEngine: CompletionEngine {
    /// Pre-caret context-tail cap (chars).
    static let maxContextChars = 1000

    let name = "Local LLM (MLX)"

    private let modelID: String
    /// Fixed at init: switching style reloads the engine (different model).
    private let style: CompletionStyle
    /// Live-tunable from the menu without a reload.
    private let lengthBox: LockedValue<CompletionLength>
    private let instructionsBox: LockedValue<String>
    /// Logprob confidence gate (base only): abstain when the shown suggestion's
    /// first-word logprob < this. nil = off. Fixed at init; enabled via
    /// Settings.logprobGate / PRETYPE_LOGPROB_GATE. 0× extra decode — the value
    /// is already captured by the live decode loop (firstWordLogProbBox).
    let logprobGateThreshold: Double?
    /// Per-script overrides of `logprobGateThreshold` (`Recommendation.scriptGateTau`),
    /// recommended settings only: an env pin or a hand-tuned threshold applies
    /// to every script as-is.
    let scriptGateTau: [GateScript: Double]
    /// Scripts with no suggestions at all, gate on or off (`ModelCatalog.silentScripts`).
    let silentScripts: Set<GateScript>
    /// The τ floor per script, gate on or off (`ModelCatalog.alwaysOnGateTau`).
    let alwaysOnGateTau: [GateScript: Double]
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

    /// What is in memory, and for how long (see `ModelResidency`).
    let residency: ModelResidency

    /// KV-cache + token snapshots reused between keystrokes (LRU; type lives in
    /// `MLXEngine+Generation.swift`).
    let promptCache = PromptCache()

    /// The fix model's progress while it loads, else the primary's state.
    var state: EngineState { residency.state }

    var isLoading: Bool { residency.isLoading }

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
        let model = loadedModelID ?? modelID
        switch state {
        case .preparing(let detail): return "\(model): \(detail)"
        case .ready: return String(localized: "\(model): ready")
        case .failed(let detail): return String(localized: "\(model): failed — \(detail)")
        }
    }

    /// `previous`: the engine this one replaces, already shut down — its
    /// blueprints and tokenizers carry over (see `EngineCoordinator.rebuild`).
    /// `load` and `shadersPresent` are seams for tests: a tiny model's
    /// loader, and whether MLX's Metal shaders are here.
    init(modelID: String, after previous: MLXEngine? = nil,
         load: @escaping ModelResidency.Loader = ModelResidency.loadFromDisk,
         shadersPresent: Bool = MLXEngine.metalShadersPresent) {
        let baseOption = ModelCatalog.option(for: modelID)
        let config = CompletionConfig.resolved()
        self.style = config.style
        self.lengthBox = LockedValue(config.length)
        self.instructionsBox = LockedValue(config.instructions)
        let env = ProcessInfo.processInfo.environment
        // A SET env var pins the knob regardless of Settings — non-numeric
        // ("off") disables. Falling back to Settings on a set-but-non-numeric
        // value would let eval runs silently inherit the app's live config.
        // PRETYPE_LOGPROB_GATE=recommended pins the shipped per-model +
        // per-script τ whatever Settings say (the eval's gate-on arm).
        let gatePin = env["PRETYPE_LOGPROB_GATE"]
        let recommended = ModelCatalog.recommended(for: modelID)
        (logprobGateThreshold, scriptGateTau) = if let gatePin, gatePin != "recommended" {
            (Double(gatePin), [:])
        } else if gatePin != nil || (Settings.logprobGate && Settings.useRecommendedSettings) {
            // Recommended settings follow the model: τ is calibrated per model
            // (Q4 edges −0.94…−1.34) and per script where that still loses —
            // see Recommendation.logprobGateTau / scriptGateTau.
            (recommended.logprobGateTau ?? Settings.logprobGateThreshold,
             recommended.logprobGateTau == nil ? [:] : recommended.scriptGateTau)
        } else {
            // Off, or a hand-tuned threshold (useRecommendedSettings off) as-is.
            (Settings.logprobGate ? Settings.logprobGateThreshold : nil, [:])
        }
        self.silentScripts = ModelCatalog.silentScripts(for: modelID)
        self.alwaysOnGateTau = ModelCatalog.alwaysOnGateTau(for: modelID)
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
                ?? baseOption?.instructModelID ?? modelID
        }
        self.modelID = primaryID
        residency = ModelResidency(primaryID: primaryID, style: config.style, promptCache: promptCache,
                                   after: previous?.residency, load: load)
        // Once per engine, not per keystroke: the reason never changes while
        // it lives, and logged inline it filled the 400-entry ring.
        if config.style == .instruct, !Self.isFIMCapable(primaryID) {
            DebugLog.shared.log("GATE", "fill-in-the-middle off — \(primaryID) is not E4B-class (unreliable here)")
        }

        guard shadersPresent else {
            residency.fail(String(localized: "Metal shaders missing — build with Scripts/make-app.sh or run Scripts/dev.sh"))
            return
        }
        // MLX's freed-buffer pool fills to whatever cap it gets: 512 MB sat
        // full (~510 MB on top of the weights), while 64 MB measured the same
        // per-keystroke latency on E4B-8bit and E2B-4bit (16 MB starts to
        // show in p90). ~450 MB back for the rest of the Mac.
        Memory.cacheLimit = 64 * 1024 * 1024
        residency.start()
    }

    /// MLX needs its compiled Metal shaders at runtime: `default.metallib`,
    /// which `swift build` and xcodebuild both put in
    /// `mlx-swift_Cmlx.bundle` — when the toolchain has the Metal component
    /// (`xcodebuild -downloadComponent MetalToolchain`). Built without it, a
    /// binary would crash deep in C++ on first use; detect that up front.
    /// Mirrors the lookup order in mlx's device.cpp.
    static var metalShadersPresent: Bool {
        let fm = FileManager.default
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates: [URL?] = [
            executableDir?.appendingPathComponent("mlx.metallib"),
            executableDir?.appendingPathComponent("Resources/mlx.metallib"),
            Bundle.main.resourceURL?.appendingPathComponent("mlx-swift_Cmlx.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("mlx-swift_Cmlx.bundle"),
        ]
        return candidates.compactMap { $0 }.contains { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Model lifecycle (see `ModelResidency`)

    /// Starts a background reload if the model was idle-unloaded, so a focus
    /// change or first keystroke hides the reload latency. Cheap no-op (lock +
    /// nil check) when the model is already loaded or loading.
    func prewarmIfNeeded() { residency.prewarm(.completion) }

    func prewarmCorrection() { residency.prewarm(.fix) }

    /// Prefills `request`'s prompt into the KV cache without decoding. The
    /// context blocks at the head of the prompt (window OCR, retrieved
    /// examples) refresh off the typing path, and each refresh invalidates the
    /// cache from the head on: the next keystroke re-read the whole prompt
    /// (~0.45 s on E4B-8bit for 460 tokens, measured). Called when such a
    /// block lands, this moves that read here, ahead of the keystroke. Only
    /// with the model resident or already loading (it then prefills once the
    /// load lands) — a context refresh is no reason to start a load.
    func warmPrompt(for request: CompletionRequest) {
        guard residency.primaryLoadedOrLoading else { return }
        Task { [weak self] in
            _ = try? await self?.run(request, prefillOnly: true)
        }
    }

    /// Free the resident models right now (menu action). Reloads on next use.
    func releaseModelNow() { residency.releaseNow() }

    func shutdown() { residency.shutdown() }

    /// Whether a fix would cost at most a load, never a download (see
    /// `ModelResidency.isCorrectionReady`).
    var isCorrectionReady: Bool { residency.isCorrectionReady }

    // MARK: - Completion

    func complete(_ request: CompletionRequest) async throws -> String? {
        try await run(request)
    }

    /// One request's τ: with the gate on, the script's override of the model
    /// τ; then raised to the script's always-on floor (nil = no gate).
    static func gateTau(base: Double?, script: GateScript?, scriptTau: [GateScript: Double],
                        floor: [GateScript: Double]) -> Double? {
        let on = base.map { b in script.flatMap { scriptTau[$0] } ?? b }
        guard let f = script.flatMap({ floor[$0] }) else { return on }
        return max(on ?? -.infinity, f)
    }

    /// The completion path: one request's model, prompt floor, decode and
    /// first-word confidence, around its style's prompt and output gates
    /// (`basePlan` / `instructPlan`).
    private func run(_ request: CompletionRequest, onPartial: (@Sendable (String) -> Void)? = nil,
                     prefillOnly: Bool = false) async throws -> String? {
        // Every style: a script this model never pays off in costs no decode.
        if let script = GateScript.of(request.textBeforeCaret), silentScripts.contains(script) {
            if !prefillOnly { DebugLog.shared.log("GATE", "no suggestions in this script for this model — not querying it") }
            return nil
        }
        guard let lease = residency.begin(.completion) else { return nil }
        defer { residency.end(lease) }
        let container = try await lease.task.value
        try Task.checkCancellation()

        // A base model given only 3-4 tokens lands in random-language territory
        // (verified: "а теперь" → Turkish gibberish), so it floors higher than
        // the instruct model, which the directive + persona keep coherent on
        // short context (the first few words of a chat message) — except
        // mid-word, where the partial word constrains both. The retrieved
        // accepted phrases ride the base prompt as a label-free preamble (the
        // RAG signal, p=0.016 on instruct, ported to the path that actually
        // wins — see Eval/BASELINE.md "the prize").
        let base = style == .base
        guard let prepared = PreparedPrompt(
            request.completionPrompt(maxChars: Self.maxContextChars), request: request,
            midWordFloor: base ? 10 : 6, boundaryFloor: base ? 16 : 10,
            preamble: base ? request.personalPreambleBlock : nil) else { return nil }
        let plan = base ? basePlan(request, prepared) : instructPlan(request, prepared)

        // First-word confidence capture: reset up front so a stale value from a
        // previous generation can never be journaled against this one; publish
        // below only when the result survives the output gate, so a resolve-time
        // read refers to the suggestion that was shown. A warm-up prefill must
        // not touch the box: it describes the suggestion on screen, which this
        // call doesn't replace.
        let recording = !prefillOnly
        if recording { firstWordLogProbBox.set(nil) }
        let logProbSink = recording ? LockedValue<Double?>(nil) : nil
        let output = try await Self.generate(
            in: container,
            makeTokens: plan.makeTokens,
            parameters: completionParameters(for: request),
            promptCache: promptCache,
            logProbSink: logProbSink,
            trimLogProb: recording ? trimLogProbThreshold : nil,
            trimEntropy: recording ? Self.trimEntropyThreshold : nil,
            gateLogProb: recording ? plan.gateLogProb : nil,
            healExpected: plan.healExpected,
            prefillOnly: prefillOnly,
            // No drafter: starting the speculative iterator costs ~25 ms
            // before the first token, and a streamed suggestion is judged by
            // its first word (instruct primary: first-visible p50 +8 ms,
            // final −5%). The drafter pays off on the longer, non-streamed
            // fix and reply.
            onPartial: Self.makeStreamHandler(onPartial, gate: plan.streamGate)
        )
        if prefillOnly { return nil }
        try Task.checkCancellation()
        let lp = logProbSink?.get()
        let result = plan.finish(output, lp)
        if result != nil { firstWordLogProbBox.set(lp) }
        return result
    }

    /// A style's half of a completion (see `run`): what to decode, and how
    /// to gate what comes back.
    private struct Plan {
        let makeTokens: @Sendable (ModelContext) throws -> [Int]
        /// Logprob-gate τ and the token-healing fragment (see `generate`).
        var gateLogProb: Double?
        var healExpected: String?
        /// The output gate for each streamed partial.
        let streamGate: @Sendable (String) -> String?
        /// The final output's gate, given its first-word logprob.
        let finish: (_ output: String, _ firstWordLogProb: Double?) -> String?
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
    private func basePlan(_ request: CompletionRequest, _ prepared: PreparedPrompt) -> Plan {
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
        // The script of what the user typed — the text the table was calibrated on.
        let gateTau = Self.gateTau(base: logprobGateThreshold, script: GateScript.of(request.textBeforeCaret),
                                   scriptTau: scriptGateTau, floor: alwaysOnGateTau)
        let generationText = heal.map { String(prepared.generationText.dropLast($0.dropCount)) }
            ?? prepared.generationText
        let promptCache = self.promptCache
        return Plan(
            makeTokens: { promptCache.encoder.encode(generationText, with: $0.tokenizer) },
            // Healed suggestions bypass the gate (see below).
            gateLogProb: heal == nil ? gateTau : nil,
            healExpected: heal?.expected,
            streamGate: healed(prepared.gate(cleanInstruct: false, logRejects: false)),
            finish: { output, lp in
                if let heal, !output.hasPrefix(heal.expected) {
                    DebugLog.shared.log("GATE", "token-healing: decode \(output.prefix(24).debugDescription) contradicts typed fragment \(heal.expected.debugDescription) — abstaining")
                }
                let result = healedGate(output)
                // Logprob confidence gate: abstain on a low-confidence first word. 0×
                // extra decode (lp is already captured). Base only by construction —
                // the instruct plan never sets it, as the calibration doesn't hold there.
                // Healed suggestions bypass the gate: τ is calibrated on word-boundary
                // next-word logprobs, but under healing lp is the fragment path of the
                // CURRENT word (forced tokens under constrained decode) — a different
                // scale that the word-boundary τ mostly rejects, while fragment-match
                // already holds healed precision at ~77% (mid3, ANALYTICS §6в′).
                if let thr = gateTau, result != nil, heal == nil, let lp, lp < thr {
                    DebugLog.shared.log("GATE", "logprob-gate: first-word \(String(format: "%.2f", lp)) < \(thr) — abstaining")
                    return nil
                }
                return result
            }
        )
    }

    /// Persona-aware continuation through the instruct model's chat template:
    /// a "continue, ~N words, match voice" directive + optional author profile,
    /// then the text. The KV cache still applies — the directive/persona are a
    /// constant prefix, so only the new characters re-prefill per keystroke.
    /// One caveat for calibration: the first-word logprob here is conditioned
    /// on the instruct prompt (directive + persona + template), i.e. the
    /// distribution the live path actually sampled from — deliberately NOT the
    /// raw-context score `logProbMean` computes offline.
    private func instructPlan(_ request: CompletionRequest, _ prepared: PreparedPrompt) -> Plan {
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

        let gate = prepared.gate(cleanInstruct: true)
        let promptCache = self.promptCache
        return Plan(
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
            streamGate: prepared.gate(cleanInstruct: true, logRejects: false),
            finish: { output, _ in gate(output) }
        )
    }

    /// Per-keystroke token budget: the length setting, trimmed harder for chat.
    /// Cyrillic tokenizes to ~2× tokens/word, so the same word-count target needs
    /// a bigger token cap — without this, `short` clips Russian mid-phrase
    /// (eval: instruct short ru 50 vs medium ru 54). The directive stays in
    /// *words*; only the hard cap scales with the script.
    static func tokenBudget(for request: CompletionRequest, length: CompletionLength) -> Int {
        let cyrillic = isCyrillicHeavy(request.textBeforeCaret)
        var budget = length.maxTokens
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
        GenerateParameters(maxTokens: Self.tokenBudget(for: request, length: lengthBox.get()), temperature: 0)
    }

    func updateCompletion(length: CompletionLength, instructions: String) {
        lengthBox.set(length)
        instructionsBox.set(instructions)
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
    func correct(selection: String, redactLog: Bool) async throws -> String? {
        try await CorrectionGates.fix(selection, redactLog: redactLog, logTag: "FIX") {
            // The generation log prints its own raw output — redacting only the
            // divergence-guard line would leave the same sentence in the
            // buffer twenty lines earlier, on the SUCCESS path at that.
            try await self.chatGenerate($0, maxTokens: $1, copiesInput: true, logRaw: !redactLog)
        }
    }

    // MARK: - Voice command

    func rewrite(selection: String, instruction: String) async throws -> String? {
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
        guard let lease = residency.begin(.fix) else { throw EngineNotReady() }
        defer { residency.end(lease) }
        let container = try await lease.task.value
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
            drafter: lease.drafter,
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
}
