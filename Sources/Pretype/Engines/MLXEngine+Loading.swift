import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import MLXNN
import MLXVLM
import HuggingFace
import Tokenizers

/// How `MLXEngine` builds a model: a first load through the model factory,
/// a reload from the blueprint an unloaded model left behind (the MLX
/// reload leak, below), the MTP drafter beside it, and the parsed
/// tokenizers both reuse.
extension MLXEngine {
    typealias Blueprints = LockedValue<[String: Task<Blueprint?, Never>]>

    /// An unloaded model's configuration, plus a placeholder for each of its
    /// quantized layers. The tokenizer stays with `tokenizers` — held here it
    /// could never be let go. `vlm`: the MTP-capable build (see `loadTarget`).
    /// `husk`: the model itself, emptied, with its arrays, when it has
    /// compiled traces (see `husk(of:)`).
    struct Blueprint: @unchecked Sendable {
        let configuration: ModelConfiguration
        let tokenizerDirectory: URL
        let layers: [(path: String, placeholder: () -> Module)]
        let vlm: Bool
        let husk: Husk?
    }

    typealias Husk = (model: any LanguageModel, arrays: [(path: String, array: MLXArray)])

    /// Pretype feeds models token arrays it builds itself, never a
    /// `UserInput`: a rebuilt context needs no input processor — and the
    /// factory's holds the tokenizer, which `tokenizers` must be able to drop.
    private struct UnusedInputProcessor: UserInputProcessor {
        func prepare(input: UserInput) async throws -> LMInput { throw EngineNotReady() }
    }

    /// Frees the weights of a multimodal build's vision/audio towers: the
    /// engine only ever sends text (−320 MB on E2B-it).
    private static func dropUnusedTowers(_ container: ModelContainer) async {
        await container.perform { (context: ModelContext) in
            let towers = context.model.parameters().flattened().filter { key, _ in
                ["vision_tower", "audio_tower", "embed_vision", "embed_audio"].contains { key.hasPrefix($0) }
            }
            guard !towers.isEmpty else { return }
            // Lazy zeros of the real shape: never evaluated, so never
            // allocated, and the model's blueprint keeps the true shapes.
            let empty = Dictionary(uniqueKeysWithValues: towers.map {
                ($0.0, MLXArray.zeros($0.1.shape, dtype: $0.1.dtype))
            })
            _ = try? context.model.update(parameters: ModuleParameters.unflattened(empty), verify: [.none])
        }
        Memory.clearCache()
    }

    /// Drafters whose background fetch already ran this launch. An idle-unload
    /// reload retried it every time — offline, a failure per reload; on a slow
    /// line, a second 150 MB fetch overlapping the first.
    private static let drafterFetches = LockedValue<Set<String>>([])
    /// Drafters on disk that failed to load this launch. Without the memo every
    /// idle reload paid two loads (the VLM build, then the plain fallback) and
    /// never matched a blueprint again.
    static let brokenDrafters = LockedValue<Set<String>>([])

    /// Loads `repo` — from its downloaded snapshot (no network round trip, see
    /// `ModelStorage.localSnapshot`), else from the Hub at the pinned revision —
    /// with its MTP drafter into `drafterBox` when `drafterID` names one that
    /// is already on disk. The drafter is handled here alone, whichever way
    /// the target loads (`drafterPlan`): a missing one downloads in the
    /// background for the next load — 150 MB must not hold up this one —
    /// once per launch; one that fails to load is remembered for the launch,
    /// and the target that already loaded serves without it. It is part of
    /// the model the user already chose (listed and deleted with it, see
    /// `ModelStorage.repos`), so it rides that consent.
    static func loadTarget(
        repo: String, drafterID: String?,
        into drafterBox: LockedValue<(any MTPDrafterModel)?>, tokenizers: TokenizerCache,
        blueprints: Blueprints,
        progressHandler: @escaping @Sendable (Progress) -> Void,
        loadModel: ((_ vlm: Bool) async throws -> ModelContainer)? = nil,
        downloadDrafter: @escaping DrafterDownload = hubDrafterDownload
    ) async throws -> ModelContainer {
        // The same bytes a background fetch is already bringing in.
        await ModelStorage.waitForQuietFetch(repo: repo)
        try Task.checkCancellation()
        drafterBox.set(nil)
        let plan = drafterPlan(drafterID, broken: brokenDrafters.get(), onDisk: ModelStorage.localSnapshot(for:))
        if let fetch = plan.fetch { fetchDrafterInBackground(fetch, download: downloadDrafter) }
        let load = loadModel ?? { vlm in
            try await Self.loadModel(repo: repo, vlm: vlm, tokenizers: tokenizers, blueprints: blueprints,
                                     progressHandler: progressHandler).container
        }
        guard let drafterID, let directory = plan.load else { return try await load(false) }
        // Whether a failed VLM build is the build's: on weights already here.
        // A download that dropped says nothing about the drafter.
        let targetOnDisk = ModelStorage.cacheDirectory(repo: repo).flatMap(ModelStorage.localSnapshot(at:)) != nil
        // MTP needs the target's last hidden state, which only the VLM build
        // of Gemma 4 emits; its unused vision tower is freed right after, so
        // the drafter is the whole extra cost.
        let target: ModelContainer
        do {
            target = try await load(true)
        } catch where !isCancellation(error) {
            if targetOnDisk { brokenDrafters.mutate { _ = $0.insert(drafterID) } }
            DebugLog.shared.log("MLX", "VLM build failed (\(error.localizedDescription)) — plain decoding")
            return try await load(false)
        }
        await dropUnusedTowers(target)
        do {
            drafterBox.set(try await loadDrafter(at: directory))
        } catch where !isCancellation(error) {
            brokenDrafters.mutate { _ = $0.insert(drafterID) }
            DebugLog.shared.log("MLX", "MTP drafter unavailable (\(error.localizedDescription)) — plain decoding")
        }
        return target
    }

    /// A load that was called off, as the load meets it: Swift's
    /// cancellation, or the Hub client's URLSession one (`URLError.cancelled`).
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// What a load does about a drafter: load it from `onDisk`'s snapshot,
    /// or fetch it in the background for the next load. Neither for no
    /// drafter, or one broken this launch.
    static func drafterPlan(_ drafterID: String?, broken: Set<String>,
                            onDisk: (String) -> URL?) -> (load: URL?, fetch: String?) {
        guard let drafterID, !broken.contains(drafterID) else { return (nil, nil) }
        let directory = onDisk(drafterID)
        return (directory, directory == nil ? drafterID : nil)
    }

    /// How a missing drafter is fetched: `hubDrafterDownload`; tests record it.
    typealias DrafterDownload = @Sendable (_ drafterID: String) async throws -> Void

    static let hubDrafterDownload: DrafterDownload = { drafterID in
        _ = try await #hubDownloader().download(
            id: drafterID, revision: ModelCatalog.revision(for: drafterID),
            matching: ["*.safetensors", "*.json"],
            useLatest: false, progressHandler: { _ in })
    }

    private static func fetchDrafterInBackground(_ drafterID: String, download: @escaping DrafterDownload) {
        guard drafterFetches.mutate({ $0.insert(drafterID).inserted }) else { return }
        Task.detached(priority: .utility) {
            do {
                try await download(drafterID)
            } catch {
                DebugLog.shared.log("MLX", "MTP drafter download failed: \(error.localizedDescription)")
            }
        }
    }

    /// The ways a target may load, cheapest first; each that fails falls
    /// through to the next, and the factory is always last.
    enum Route: Equatable { case blueprint, servingTable, factory }

    /// The load order, as a rule: the blueprint, when it was drawn from this
    /// snapshot and for the same build (an upgrade since, or a drafter gained
    /// or lost, gets a fresh load); the build with the per-layer table served
    /// from disk (`HostPLE.loadWeights`), for a Gemma on disk with "Reduce
    /// memory use" — the factory's load brings the table in whole; then the
    /// factory, which also downloads.
    static func routes(vlm: Bool, snapshot: URL?, blueprint: (vlm: Bool, directory: URL)?,
                       servesTable: Bool) -> [Route] {
        var routes: [Route] = []
        if let snapshot, let blueprint, blueprint.vlm == vlm, blueprint.directory == snapshot { routes.append(.blueprint) }
        if snapshot != nil, servesTable { routes.append(.servingTable) }
        return routes + [.factory]
    }

    /// The target model alone — the VLM build when `vlm` — by the first of
    /// its `routes` that works, and which one it was.
    static func loadModel(repo: String, vlm: Bool, tokenizers: TokenizerCache, blueprints: Blueprints,
                          ple: HostPLE.Policy = .live,
                          progressHandler: @escaping @Sendable (Progress) -> Void) async throws
        -> (container: ModelContainer, route: Route) {
        let snapshot = ModelStorage.cacheDirectory(repo: repo).flatMap(ModelStorage.localSnapshot(at:))
        let blueprint = await blueprints.mutate({ $0.removeValue(forKey: repo) })?.value
        let drawnFrom: URL? = if case .directory(let directory)? = blueprint?.configuration.id { directory } else { nil }
        let plan = routes(vlm: vlm, snapshot: snapshot, blueprint: blueprint.flatMap { b in drawnFrom.map { (b.vlm, $0) } },
                          servesTable: ple.enabled && HostPLE.savingGB(for: repo) != nil)
        for route in plan where route != .factory {
            guard let directory = snapshot else { break }
            do {
                switch route {
                case .blueprint:
                    guard let blueprint else { continue }
                    return (try await build(from: directory, vlm: vlm, configuration: blueprint.configuration,
                                            tokenizerDirectory: blueprint.tokenizerDirectory, layers: blueprint.layers,
                                            husk: blueprint.husk, tokenizers: tokenizers, ple: ple), route)
                default:
                    return (try await build(from: directory, vlm: vlm, configuration: try factoryConfiguration(of: directory),
                                            tokenizerDirectory: directory, layers: [], husk: nil, tokenizers: tokenizers,
                                            ple: ple), route)
                }
            } catch where !isCancellation(error) {
                DebugLog.shared.log("MLX", "\(route) load failed (\(error.localizedDescription)) — trying the next way")
            }
        }
        let configuration = snapshot.map { ModelConfiguration(directory: $0) }
            ?? ModelConfiguration(id: repo, revision: ModelCatalog.revision(for: repo))
        // A scoped random state: building a model draws placeholder weights
        // for every layer, and from the global state each draw grew a lazy key
        // chain that state holds for the app's life.
        let container = try await withRandomState(MLXRandom.RandomState(seed: 0)) {
            if vlm {
                return try await VLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(), using: tokenizers,
                    configuration: configuration, progressHandler: progressHandler)
            }
            // LLMModelFactory, not loadModelContainer: with MLXVLM linked the
            // generic loader picks the VLM classes first (Qwen3.5's lacks the
            // raw-token call the decode loop uses).
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: tokenizers,
                configuration: configuration, progressHandler: progressHandler)
        }
        return (container, .factory)
    }

    /// Builds a model from `directory` without the factory: a fresh instance
    /// from the type registry, with `layers` in place — a blueprint's
    /// lazy-zero placeholders, so `loadWeights` finds nothing to quantize and
    /// only replaces them — then its weights, the per-layer table served from
    /// disk where `HostPLE.loadWeights` can; and `husk`, if given, adopted.
    static func build(from directory: URL, vlm: Bool, configuration: ModelConfiguration,
                      tokenizerDirectory: URL, layers: [(path: String, placeholder: () -> Module)],
                      husk: Husk?, tokenizers: TokenizerCache, ple: HostPLE.Policy = .live) async throws -> ModelContainer {
        // A cache hit, unless memory pressure let it go: then parsed alongside
        // the weights, as the factory does.
        async let tokenizer = tokenizers.load(from: tokenizerDirectory)
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        let registry = vlm ? VLMModelFactory.shared.typeRegistry : LLMModelFactory.shared.typeRegistry
        let model = try await withRandomState(MLXRandom.RandomState(seed: 0)) {
            try await registry.createModel(configuration: configData, modelType: base.modelType)
        }
        try model.update(modules: ModuleChildren.unflattened(layers.map { ($0.path, $0.placeholder()) }),
                         verify: [.none])
        if try await !HostPLE.loadWeights(into: model, from: directory, perLayerQuantization: base.perLayerQuantization,
                                          ple: ple) {
            try await loadWeights(modelDirectory: directory, model: model,
                                  perLayerQuantization: base.perLayerQuantization)
        }
        let served = husk.flatMap { adopt(model, into: $0) } ?? model
        return ModelContainer(context: ModelContext(
            configuration: configuration, model: served,
            processor: UnusedInputProcessor(), tokenizer: try await tokenizer))
    }

    /// What the model factory makes of `directory`'s configuration, for a
    /// model built without it: the EOS ids of config.json, overridden by
    /// generation_config.json's (mlx-lm's rule), and the latter's stop
    /// strings. The ids are all of it Pretype reads: `generate` stops on them.
    static func factoryConfiguration(of directory: URL) throws -> ModelConfiguration {
        let base = try JSONDecoder.json5().decode(
            BaseConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let generation = (try? Data(contentsOf: directory.appendingPathComponent("generation_config.json")))
            .flatMap { try? JSONDecoder.json5().decode(GenerationConfigFile.self, from: $0) }
        return ModelConfiguration(directory: directory, stopStrings: generation?.stopStrings ?? [],
                                  eosTokenIds: generation?.eosTokenIds.map { Set($0.values) } ?? base.effectiveEOSTokenIds)
    }

    /// A model with compiled traces (Qwen3.5), emptied to be kept: every array
    /// it holds becomes lazy zeros, so the weights go and the traces stay. A
    /// rebuilt model brings new traces, and erasing the old ones leaks their
    /// tapes in the bundled MLX: ~22 MB per Qwen3.5 2B reload (measured; MLX
    /// #4453 and #4440 don't fix it). nil without traces: the blueprint alone
    /// rebuilds such a model leak-free.
    /// ponytail: delete once the bundled MLX frees an erased tape.
    private static func husk(of model: any LanguageModel) -> Husk? {
        let (arrays, traced) = arrays(of: model)
        guard traced else { return nil }
        for (_, array) in arrays { array._updateInternal(MLXArray.zeros(array.shape, dtype: array.dtype)) }
        return (model, arrays)
    }

    /// `husk` with `fresh`'s arrays written into its own, the ones its traces
    /// read — or nil when the two don't line up: then `fresh` serves, and the
    /// husk's traces leak once.
    private static func adopt(_ fresh: any LanguageModel, into husk: Husk) -> (any LanguageModel)? {
        let new = arrays(of: fresh).arrays, old = husk.arrays
        guard new.count == old.count, zip(new, old).allSatisfy({
            $0.path == $1.path && $0.array.shape == $1.array.shape && $0.array.dtype == $1.array.dtype
        }) else {
            DebugLog.shared.log("MLX", "kept model doesn't match its rebuild — serving the rebuild")
            return nil
        }
        for (new, old) in zip(new, old) { old.array._updateInternal(new.array) }
        return husk.model
    }

    /// Every array `model` holds, by its path through the object graph, and
    /// whether that graph holds a compiled trace. Reflection, not
    /// `parameters()`: derived state such as a fused projection is no
    /// registered parameter, and it is found without naming library internals.
    private static func arrays(of model: any LanguageModel) -> (arrays: [(path: String, array: MLXArray)], traced: Bool) {
        var found: [(path: String, array: MLXArray)] = []
        var traced = false
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any, _ path: String) {
            if let array = value as? MLXArray {
                if seen.insert(ObjectIdentifier(array)).inserted { found.append((path, array)) }
                return
            }
            if value is CompiledTraceInvalidating { traced = true }
            let mirror = Mirror(reflecting: value)
            switch mirror.displayStyle {
            case .class:
                guard seen.insert(ObjectIdentifier(value as AnyObject)).inserted else { return }
            case .dictionary:
                // Sorted: a dictionary's order differs between two equal ones.
                let entries = mirror.children.map { Array(Mirror(reflecting: $0.value).children) }
                for entry in entries.sorted(by: { "\($0[0].value)" < "\($1[0].value)" }) {
                    walk(entry[1].value, "\(path)[\(entry[0].value)]")
                }
                return
            default:
                break
            }
            var level: Mirror? = mirror
            while let current = level {
                for (index, child) in current.children.enumerated() {
                    walk(child.value, "\(path).\(child.label ?? String(index))")
                }
                level = current.superclassMirror
            }
        }
        walk(model, "")
        return (found, traced)
    }

    /// Records how to rebuild an unloaded model (see `Blueprint`), so the next
    /// load doesn't leak. A build leaked ~5 MB (E4B) to ~20 MB (Qwen3.5 2B)
    /// for good, and idle unloads made one of every return to the keyboard:
    /// the bundled MLX predates the fix for sibling arrays released by
    /// assignment (ml-explore/mlx#4453), and `loadWeights` quantizes each
    /// layer's placeholder weights into such sibling triples that the loaded
    /// weights then replace by assignment. Placeholders made here have no
    /// siblings.
    /// ponytail: delete once mlx-swift bundles an MLX with #4453 (0.32.3 doesn't).
    static func keepBlueprint(_ task: Task<ModelContainer, Error>?, repo: String, in blueprints: Blueprints) {
        guard let task else { return }
        // The sole owner of the old model now (the engine dropped its task):
        // let go of it before clearing the buffer pool, or its freed weights
        // fill the pool the unload just emptied and sit there all idle.
        let owner = LockedValue<Task<ModelContainer, Error>?>(task)
        blueprints.mutate { $0[repo] = Task.detached(priority: .userInitiated) {
            let blueprint: Blueprint? = await {
                guard let container = try? await owner.exchange(nil)?.value,
                      let tokenizerDirectory = try? await container.tokenizerDirectory else { return nil }
                return await container.perform { context in
                    let layers = context.model.leafModules().flattened().compactMap(Self.placeholder)
                    return Blueprint(configuration: context.configuration, tokenizerDirectory: tokenizerDirectory,
                                     layers: layers, vlm: context.model is any VLMModel, husk: Self.husk(of: context.model))
                }
            }()
            Memory.clearCache()
            return blueprint
        } }
    }

    /// A lazy-zero stand-in for a loaded quantized layer, same shapes and
    /// settings — what `quantize` would have built, minus the siblings. Only
    /// shapes are captured: an array captured here would keep its weights.
    private static func placeholder(_ path: String, _ module: Module) -> (path: String, placeholder: () -> Module)? {
        typealias Spec = (shape: [Int], dtype: DType)
        func spec(_ array: MLXArray) -> Spec { (array.shape, array.dtype) }
        func zeros(_ spec: Spec) -> MLXArray { MLXArray.zeros(spec.shape, dtype: spec.dtype) }
        // Exact classes: a subclass (QLoRA, a rotated or sharded layer) is no
        // plain layer to stand in for.
        if type(of: module) == QuantizedLinear.self, let layer = module as? QuantizedLinear, layer.globalScale == nil {
            let (weight, scales) = (spec(layer.weight), spec(layer.scales))
            let (bias, biases) = (layer.bias.map(spec), layer.biases.map(spec))
            let (groupSize, bits, mode) = (layer.groupSize, layer.bits, layer.mode)
            return (path, {
                QuantizedLinear(weight: zeros(weight), bias: bias.map(zeros), scales: zeros(scales),
                                biases: biases.map(zeros), groupSize: groupSize, bits: bits, mode: mode)
            })
        }
        // Served from the file, but the rebuild loads it as the table it was.
        if let host = module as? HostPLE {
            let (tensors, groupSize, bits, mode) = (host.tensors.map { ($0.shape, $0.dtype) }, host.groupSize, host.bits, host.mode)
            return (path, {
                QuantizedEmbedding(weight: zeros(tensors[0]), scales: zeros(tensors[1]), biases: zeros(tensors[2]),
                                   groupSize: groupSize, bits: bits, mode: mode)
            })
        }
        if type(of: module) == QuantizedEmbedding.self, let layer = module as? QuantizedEmbedding, layer.globalScale == nil {
            let (weight, scales, biases) = (spec(layer.weight), spec(layer.scales), layer.biases.map(spec))
            let (groupSize, bits, mode) = (layer.groupSize, layer.bits, layer.mode)
            return (path, {
                QuantizedEmbedding(weight: zeros(weight), scales: zeros(scales), biases: biases.map(zeros),
                                   groupSize: groupSize, bits: bits, mode: mode)
            })
        }
        return nil
    }

    private static func loadDrafter(at directory: URL) async throws -> any MTPDrafterModel {
        let config = try JSONDecoder().decode(
            Gemma4AssistantConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        // Scoped random state, as for the target's build (see `loadTarget`).
        let model = withRandomState(MLXRandom.RandomState(seed: 0)) { Gemma4AssistantDraftModel(config) }
        try await loadWeights(modelDirectory: directory, model: model)
        return model
    }
}

/// `TokenizerLoader` that parses each tokenizer directory once per engine.
final class TokenizerCache: TokenizerLoader, @unchecked Sendable {
    private let byDirectory = LockedValue<[URL: any MLXLMCommon.Tokenizer]>([:])
    private let parse: @Sendable (URL) async throws -> any MLXLMCommon.Tokenizer

    /// `parse`: the Hugging Face tokenizer loader; tests swap in a fake.
    init(parse: @escaping @Sendable (URL) async throws -> any MLXLMCommon.Tokenizer = {
        try await #huggingFaceTokenizerLoader().load(from: $0)
    }) {
        self.parse = parse
    }

    /// The directories whose tokenizers are kept.
    var directories: Set<URL> { Set(byDirectory.get().keys) }

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        if let hit = byDirectory.get()[directory] { return hit }
        let tokenizer = try await parse(directory)
        // A superseded build's (~100 MB): another snapshot of this repo, or
        // a directory gone from disk (the original a re-pack replaced).
        let snapshots = directory.deletingLastPathComponent()
        byDirectory.mutate { cache in
            cache = cache.filter {
                $0.key.deletingLastPathComponent() != snapshots && FileManager.default.fileExists(atPath: $0.key.path)
            }
            cache[directory] = tokenizer
        }
        return tokenizer
    }

    func retain(where keep: (URL) -> Bool) {
        byDirectory.mutate { $0 = $0.filter { keep($0.key) } }
    }
}
