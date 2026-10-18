import HuggingFace
import MLX
import MLXLMCommon
import MLXLLM
import MLXNN
import XCTest
@testable import Pretype

/// How a model gets into memory: the load order and its fallbacks, the
/// drafter's fate, the per-layer table served without being read, and the
/// tokenizer cache — on a tiny Gemma, on the CPU, through the app's own
/// load code.
final class ModelLoadingTests: MLXTestCase {
    /// A scratch Hugging Face cache for `body`, and the CPU device.
    private func inScratchHub(_ body: () async throws -> Void) async throws {
        let root = try TinyGemma.scratch("hub")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Device.withDefaultDevice(.cpu) {
            try await ModelStorage.$hub.withValue(HubCache(cacheDirectory: root), operation: body)
        }
    }

    /// A complete snapshot of `repo` in the current hub, with `files`.
    private func snapshot(of repo: String) throws -> URL {
        let directory = try XCTUnwrap(ModelStorage.cacheDirectory(repo: repo)).appendingPathComponent("snapshots/rev")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func bogusSnapshot(of repo: String) throws {
        let directory = try snapshot(of: repo)
        for file in ["config.json", "tokenizer.json", "model.safetensors"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(file))
        }
    }

    // The load order as a rule: a blueprint only when drawn from this
    // snapshot for the same build — a VLM blueprint rebuilt as a plain model
    // or the reverse mismatched every placeholder — the table served from
    // disk only for a model on disk, the factory always last.
    func testRoutes() {
        typealias E = MLXEngine
        let here = URL(fileURLWithPath: "/tmp/snapshots/a"), there = URL(fileURLWithPath: "/tmp/snapshots/b")
        XCTAssertEqual(E.routes(vlm: false, snapshot: here, blueprint: (false, here), servesTable: true),
                       [.blueprint, .servingTable, .factory])
        XCTAssertEqual(E.routes(vlm: true, snapshot: here, blueprint: (false, here), servesTable: true),
                       [.servingTable, .factory], "a plain blueprint for a VLM load")
        XCTAssertEqual(E.routes(vlm: false, snapshot: here, blueprint: (true, here), servesTable: false), [.factory])
        XCTAssertEqual(E.routes(vlm: false, snapshot: here, blueprint: (false, there), servesTable: false), [.factory],
                       "drawn from another snapshot")
        XCTAssertEqual(E.routes(vlm: false, snapshot: nil, blueprint: (false, here), servesTable: true), [.factory],
                       "nothing on disk yet")
    }

    // The real `loadModel` on a tiny Gemma "E2B": built here with the table
    // served from the file; rebuilt from its blueprint, served again; a
    // blueprint that no longer fits falls through to the served build; the
    // setting off loads through the factory, which reads the table whole.
    // All four compute the same logits.
    func testLoadModelTakesTheCheapestRouteThatWorks() async throws {
        try await inScratchHub {
            let repo = "test/gemma-4-e2b-tiny"
            let directory = try snapshot(of: repo)
            try await TinyGemma.write(to: directory)
            let tokenizers = TokenizerCache { _ in CharTokenizer() }
            let blueprints = MLXEngine.Blueprints([:])
            func load(_ ple: HostPLE.Policy = TinyGemma.serving) async throws -> (container: ModelContainer, route: MLXEngine.Route) {
                try await MLXEngine.loadModel(repo: repo, vlm: false, tokenizers: tokenizers, blueprints: blueprints,
                                              ple: ple, progressHandler: { _ in })
            }
            func table(_ container: ModelContainer) async -> String {
                await container.perform { context in TinyGemma.table(context.model).map { "\(type(of: $0))" } ?? "none" }
            }
            func logits(_ container: ModelContainer) async -> [Float] {
                await container.perform { context in TinyGemma.logits(context.model).asArray(Float.self) }
            }

            let served = try await load()
            XCTAssertEqual(served.route, .servingTable)
            let servedTable = await table(served.container)
            XCTAssertEqual(servedTable, "HostPLE")

            MLXEngine.keepBlueprint(Task { served.container }, repo: repo, in: blueprints)
            // A stand-in for every quantized layer and the served table; no
            // husk, Gemma holding no compiled trace.
            let kept = try await kept(repo, in: blueprints)
            XCTAssertNil(kept.husk)
            let quantized = await served.container.perform { context in
                context.model.leafModules().flattened()
                    .filter { $0.1 is QuantizedLinear || $0.1 is QuantizedEmbedding || $0.1 is HostPLE }.map(\.0).sorted()
            }
            XCTAssertEqual(kept.layers.map(\.path).sorted(), quantized)
            XCTAssertTrue(quantized.contains { $0.hasSuffix("embed_tokens_per_layer") }, "the served table among them")
            let rebuilt = try await load()
            XCTAssertEqual(rebuilt.route, .blueprint)
            let rebuiltTable = await table(rebuilt.container)
            XCTAssertEqual(rebuiltTable, "HostPLE")

            let layer = await rebuilt.container.perform { context in
                context.model.leafModules().flattened().first { $0.1 is QuantizedLinear }?.0
            }
            let stale = MLXEngine.Blueprint(
                configuration: ModelConfiguration(directory: directory), tokenizerDirectory: directory,
                layers: [(path: try XCTUnwrap(layer), placeholder: {
                    QuantizedLinear(weight: MLXArray.zeros([7, 1], dtype: .uint32), scales: MLXArray.zeros([7, 1]),
                                    biases: MLXArray.zeros([7, 1]), groupSize: 32, bits: 4)
                })],
                vlm: false, husk: nil)
            blueprints.set([repo: Task { stale }])
            let fallback = try await load()
            XCTAssertEqual(fallback.route, .servingTable, "a blueprint that no longer fits")

            let factory = try await load(HostPLE.Policy(enabled: false) { _ in true })
            XCTAssertEqual(factory.route, .factory)
            let factoryTable = await table(factory.container)
            XCTAssertEqual(factoryTable, "QuantizedEmbedding")

            let expected = await logits(factory.container)
            for container in [served.container, rebuilt.container, fallback.container] {
                let got = await logits(container)
                XCTAssertEqual(got, expected)
            }

            // No Gemma E-model by name, no table to serve: the factory, setting on.
            let plainRepo = "test/qwen-tiny"
            try await TinyGemma.write(to: try snapshot(of: plainRepo))
            let plain = try await MLXEngine.loadModel(repo: plainRepo, vlm: false, tokenizers: tokenizers,
                                                      blueprints: blueprints, ple: TinyGemma.serving, progressHandler: { _ in })
            XCTAssertEqual(plain.route, .factory)
        }
    }

    private func kept(_ repo: String, in blueprints: MLXEngine.Blueprints) async throws -> MLXEngine.Blueprint {
        let blueprint = await blueprints.get()[repo]?.value
        return try XCTUnwrap(blueprint, "a blueprint for \(repo)")
    }

    // A model with compiled traces (Qwen3.5) is kept as a husk: every array
    // emptied, the traces kept. Its rebuild writes the fresh weights into
    // the husk and serves it — unless the two don't line up array for
    // array, when the rebuild itself serves.
    func testAQwenRebuildServesItsHuskRefilled() async throws {
        try await inScratchHub {
            let repo = "test/qwen-tiny"
            try await TinyGemma.write(to: try snapshot(of: repo), config: """
                {"model_type": "qwen3_5_text", "hidden_size": 64, "num_hidden_layers": 2, "intermediate_size": 64,
                 "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 32, "linear_num_value_heads": 2,
                 "linear_num_key_heads": 2, "linear_key_head_dim": 32, "linear_value_head_dim": 32,
                 "linear_conv_kernel_dim": 4, "vocab_size": 64, "tie_word_embeddings": true, "full_attention_interval": 2,
                 "rope_parameters": {"type": "default", "rope_theta": 10000.0, "partial_rotary_factor": 0.25,
                                     "mrope_section": [2, 1, 1]},
                 "quantization": {"group_size": 32, "bits": 4}}
                """)
            let tokenizers = TokenizerCache { _ in CharTokenizer() }
            let blueprints = MLXEngine.Blueprints([:])
            func load() async throws -> (container: ModelContainer, route: MLXEngine.Route) {
                try await MLXEngine.loadModel(repo: repo, vlm: false, tokenizers: tokenizers, blueprints: blueprints,
                                              ple: TinyGemma.serving, progressHandler: { _ in })
            }
            // No forward: Qwen3.5's recurrent kernel runs only on the GPU.
            func weights(_ container: ModelContainer) async -> [[Float]] {
                await container.perform { context in
                    context.model.parameters().flattened().map { $0.1.asType(.float32).asArray(Float.self) }
                }
            }
            func model(_ container: ModelContainer) async -> AnyObject {
                await container.perform { $0.model as AnyObject }
            }

            let first = try await load()
            let loaded = await weights(first.container)
            MLXEngine.keepBlueprint(Task { first.container }, repo: repo, in: blueprints)
            let kept = try await kept(repo, in: blueprints)
            let husk = try XCTUnwrap(kept.husk, "compiled traces: kept as a husk")
            XCTAssertGreaterThanOrEqual(husk.arrays.count, loaded.count)
            let emptied = await weights(first.container)
            XCTAssertTrue(emptied.allSatisfy { $0.allSatisfy { $0 == 0 } }, "the husk holds no weights")

            let rebuilt = try await load()
            XCTAssertEqual(rebuilt.route, .blueprint)
            let rebuiltModel = await model(rebuilt.container)
            XCTAssertTrue(rebuiltModel === husk.model as AnyObject, "the husk serves")
            let refilled = await weights(rebuilt.container)
            XCTAssertEqual(refilled, loaded)

            let last = try XCTUnwrap(husk.arrays.last)
            let otherType: DType = last.array.dtype == .float32 ? .float16 : .float32
            for misfit in [Array(husk.arrays.dropLast()),
                           husk.arrays.dropLast() + [(path: last.path, array: MLXArray.zeros([1]))],
                           husk.arrays.dropLast() + [(path: last.path, array: MLXArray.zeros(last.array.shape, dtype: otherType))],
                           husk.arrays.map { (path: $0.path + ".moved", array: $0.array) }] {
                blueprints.set([repo: Task { MLXEngine.Blueprint(
                    configuration: kept.configuration, tokenizerDirectory: kept.tokenizerDirectory, layers: kept.layers,
                    vlm: kept.vlm, husk: (model: husk.model, arrays: misfit)) }])
                let fresh = try await load()
                XCTAssertEqual(fresh.route, .blueprint)
                let freshModel = await model(fresh.container)
                XCTAssertFalse(freshModel === husk.model as AnyObject, "a husk that doesn't line up stays out")
                let freshWeights = await weights(fresh.container)
                XCTAssertEqual(freshWeights, loaded)
            }
        }
    }

    // A blueprint stands in only for the plain quantized layers: not for a
    // subclass (a rotated or sharded layer is no plain one), nor for a
    // global-scale (NVFP4) layer. A reference cycle in the model is walked once.
    func testABlueprintStandsInOnlyForPlainQuantizedLayers() async throws {
        let directory = try TinyGemma.scratch("blueprint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(directory: directory), model: MixedQuantizedModel(),
            processor: NoInputProcessor(), tokenizer: CharTokenizer()))
        let blueprints = MLXEngine.Blueprints([:])
        MLXEngine.keepBlueprint(Task { container }, repo: "test/mixed", in: blueprints)
        let kept = try await kept("test/mixed", in: blueprints)
        XCTAssertEqual(kept.layers.map(\.path).sorted(), ["embedding", "linear"])
    }

    // A load called off mid-route ends there: no next route behind an engine
    // already retired.
    func testACalledOffLoadTriesNoOtherRoute() async throws {
        try await inScratchHub {
            let repo = "test/gemma-4-e2b-tiny"
            let directory = try snapshot(of: repo)
            try await TinyGemma.write(to: directory)
            let parses = LockedValue(0)
            let tokenizers = TokenizerCache { _ in
                parses.mutate { $0 += 1 }
                try await Task.sleep(for: .seconds(30))
                return CharTokenizer()
            }
            let blueprint = MLXEngine.Blueprint(configuration: ModelConfiguration(directory: directory),
                                                tokenizerDirectory: directory, layers: [], vlm: false, husk: nil)
            let load = Task {
                try await MLXEngine.loadModel(repo: repo, vlm: false, tokenizers: tokenizers,
                                              blueprints: LockedValue([repo: Task { blueprint }]),
                                              ple: TinyGemma.serving, progressHandler: { _ in })
            }
            while parses.get() == 0 { try await Task.sleep(for: .milliseconds(2)) }
            load.cancel()
            let result = await load.result
            XCTAssertThrowsError(try result.get())
            XCTAssertEqual(parses.get(), 1, "a called-off load went on to the next route")
        }
    }

    // The VLM build carries towers the engine never runs; `loadTarget` frees
    // them (−320 MB on E2B-it), whatever becomes of the drafter.
    func testTheVLMTargetDropsItsTowers() async throws {
        try await inScratchHub {
            let drafter = "test/drafter-\(UUID().uuidString)"
            try bogusSnapshot(of: drafter)
            let target = try await MLXEngine.loadTarget(
                repo: "test/target-\(UUID().uuidString)", drafterID: drafter, into: LockedValue(nil),
                tokenizers: TokenizerCache(), blueprints: LockedValue([:]), progressHandler: { _ in },
                loadModel: { _ in
                    ModelContainer(context: ModelContext(
                        configuration: ModelConfiguration(directory: FileManager.default.temporaryDirectory),
                        model: ToweredModel(), processor: NoInputProcessor(), tokenizer: CharTokenizer()))
                })
            let tower = await target.perform { context in
                (context.model as? ToweredModel)?.visionTower.weight.abs().sum().item(Float.self) ?? -1
            }
            XCTAssertEqual(tower, 0, "the vision tower stayed resident")
        }
    }

    // A load waits out a background fetch of the same repo: two hub
    // downloaders moving blobs into one cache fail each other.
    func testALoadWaitsForABackgroundFetchOfItsRepo() async throws {
        try await inScratchHub {
            let repo = "test/fetching-\(UUID().uuidString)"
            let fetching = LockedValue(true), loaded = LockedValue(false)
            ModelStorage.quietFetches.mutate {
                $0[repo] = Task {
                    while fetching.get() { try? await Task.sleep(for: .milliseconds(2)) }
                    return true
                }
            }
            defer { ModelStorage.quietFetches.mutate { $0[repo] = nil } }
            let load = Task {
                try await MLXEngine.loadTarget(repo: repo, drafterID: nil, into: LockedValue(nil), tokenizers: TokenizerCache(),
                                               blueprints: LockedValue([:]), progressHandler: { _ in },
                                               loadModel: { _ in
                                                   loaded.set(true)
                                                   return try tinyContainer()
                                               })
            }
            for _ in 0 ..< 50 where !loaded.get() { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertFalse(loaded.get(), "loaded while its repo was still being fetched")
            fetching.set(false)
            _ = try await load.value
            XCTAssertTrue(loaded.get())
        }
    }

    // The drafter's fate, decided in `loadTarget` whichever way the target
    // loads: a drafter that fails to load is remembered for the launch and the
    // target serves without it; a VLM build that fails on weights already on
    // disk retires the drafter path too; a download that drops does not;
    // a load called off — the Hub client's `URLError.cancelled` included —
    // is no failure at all.
    func testLoadTargetDecidesTheDrafterOnce() async throws {
        try await inScratchHub {
            func run(targetOnDisk: Bool, vlmFailure: Error?) async throws -> (drafter: String, plainLoads: Int, result: Result<Void, Error>) {
                let target = "test/target-\(UUID().uuidString)", drafter = "test/drafter-\(UUID().uuidString)"
                try bogusSnapshot(of: drafter)
                if targetOnDisk { try bogusSnapshot(of: target) }
                let plainLoads = LockedValue(0)
                let result: Result<Void, Error>
                do {
                    _ = try await MLXEngine.loadTarget(
                        repo: target, drafterID: drafter, into: LockedValue(nil), tokenizers: TokenizerCache(),
                        blueprints: LockedValue([:]), progressHandler: { _ in },
                        loadModel: { vlm in
                            if vlm, let vlmFailure { throw vlmFailure }
                            if !vlm { plainLoads.mutate { $0 += 1 } }
                            return try tinyContainer()
                        })
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                return (drafter, plainLoads.get(), result)
            }
            func broken(_ drafter: String) -> Bool { MLXEngine.brokenDrafters.get().contains(drafter) }

            let badDrafter = try await run(targetOnDisk: true, vlmFailure: nil)
            XCTAssertTrue(broken(badDrafter.drafter), "a drafter that fails to load is remembered")
            XCTAssertEqual(badDrafter.plainLoads, 0, "the VLM target that loaded serves")

            let dropped = try await run(targetOnDisk: false, vlmFailure: URLError(.notConnectedToInternet))
            XCTAssertFalse(broken(dropped.drafter), "a dropped download says nothing about the drafter")
            XCTAssertEqual(dropped.plainLoads, 1)

            let failedBuild = try await run(targetOnDisk: true, vlmFailure: URLError(.cannotDecodeContentData))
            XCTAssertTrue(broken(failedBuild.drafter), "a VLM build that fails on weights on disk")
            XCTAssertEqual(failedBuild.plainLoads, 1)

            let calledOff = try await run(targetOnDisk: true, vlmFailure: URLError(.cancelled))
            XCTAssertFalse(broken(calledOff.drafter))
            XCTAssertEqual(calledOff.plainLoads, 0, "an engine retired mid-download starts no second load")
            XCTAssertThrowsError(try calledOff.result.get())
        }
    }

    // A drafter not on disk is fetched in the background — once a launch,
    // however often its target reloads — while the target loads without it.
    func testAMissingDrafterIsFetchedOnceALaunch() async throws {
        try await inScratchHub {
            let drafter = "test/drafter-\(UUID().uuidString)"
            let fetched = LockedValue<[String]>([])
            func load() async throws -> (any MTPDrafterModel)? {
                let box = LockedValue<(any MTPDrafterModel)?>(nil)
                _ = try await MLXEngine.loadTarget(
                    repo: "test/target-\(UUID().uuidString)", drafterID: drafter, into: box, tokenizers: TokenizerCache(),
                    blueprints: LockedValue([:]), progressHandler: { _ in }, loadModel: { _ in try tinyContainer() },
                    downloadDrafter: { id in fetched.mutate { $0.append(id) } })
                return box.get()
            }
            let first = try await load()
            XCTAssertNil(first)
            for _ in 0 ..< 500 where fetched.get().isEmpty { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertEqual(fetched.get(), [drafter])
            let second = try await load()
            XCTAssertNil(second)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(fetched.get(), [drafter], "fetched again on a reload")
        }
    }

    // `install` swaps the table only for rows the file really holds: the
    // same shapes from another checkpoint must stay on the GPU.
    func testInstallSwapsTheTableOnlyForTheFilesOwnRows() async throws {
        try await inScratchHub {
            let repo = "test/gemma-4-e2b-tiny"
            let directory = try snapshot(of: repo)
            try await TinyGemma.write(to: directory, seed: 7)
            let other = try TinyGemma.scratch("other")
            defer { try? FileManager.default.removeItem(at: other) }
            try await TinyGemma.write(to: other, seed: 8)
            let config = TinyGemma.config()
            let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: Data(config.utf8))
            func loaded(from directory: URL) async throws -> ModelContainer {
                let model = try await TinyGemma.model(config, seed: 1)
                try await loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
                return ModelContainer(context: ModelContext(
                    configuration: ModelConfiguration(directory: directory), model: model,
                    processor: NoInputProcessor(), tokenizer: CharTokenizer()))
            }
            func table(_ container: ModelContainer) async -> String {
                await container.perform { context in TinyGemma.table(context.model).map { "\(type(of: $0))" } ?? "none" }
            }

            let own = try await loaded(from: directory)
            await HostPLE.install(in: own, repo: repo, ple: HostPLE.Policy(enabled: false) { _ in true })
            let keptTable = await table(own)
            XCTAssertEqual(keptTable, "QuantizedEmbedding", "the setting off")
            let before = await own.perform { context in TinyGemma.logits(context.model).asArray(Float.self) }
            await HostPLE.install(in: own, repo: repo, ple: TinyGemma.serving)
            let ownTable = await table(own)
            XCTAssertEqual(ownTable, "HostPLE")
            XCTAssertTrue(HostPLE.servesTable(of: repo) { _ in true })
            let after = await own.perform { context in TinyGemma.logits(context.model).asArray(Float.self) }
            XCTAssertEqual(after, before)

            let foreign = try await loaded(from: other)
            await HostPLE.install(in: foreign, repo: repo, ple: TinyGemma.serving)
            let foreignTable = await table(foreign)
            XCTAssertEqual(foreignTable, "QuantizedEmbedding", "rows of another checkpoint")
            XCTAssertFalse(HostPLE.servesTable(of: repo) { _ in true }, "the figures still claim the saving")
            // A table already served from the file is served: the decline goes.
            await HostPLE.install(in: own, repo: repo, ple: TinyGemma.serving)
            XCTAssertTrue(HostPLE.servesTable(of: repo) { _ in true })

            // The first, middle and last rows are checked: one changed row
            // in memory at any of them keeps the table on the GPU.
            for changed in [0, 32, 63] {
                let edited = try await loaded(from: directory)
                await edited.perform { context in
                    guard case let (path, layer as QuantizedEmbedding)? = context.model.leafModules().flattened()
                        .first(where: { $0.0.hasSuffix("embed_tokens_per_layer") }) else { return }
                    let rows = MLXArray(Array(0 ..< Int32(layer.weight.dim(0)))).reshaped([-1, 1])
                    let weight = MLX.where(rows .== Int32(changed), layer.weight + 1, layer.weight)
                    try? context.model.update(parameters: ModuleParameters.unflattened([path + ".weight": weight]),
                                              verify: [.none])
                }
                await HostPLE.install(in: edited, repo: repo, ple: TinyGemma.serving)
                let editedTable = await table(edited)
                XCTAssertEqual(editedTable, "QuantizedEmbedding", "row \(changed) differs")
            }

            // A subclass of the plain layer is no table to swap.
            let custom = try await loaded(from: directory)
            await custom.perform { context in
                guard case let (path, layer as QuantizedEmbedding)? = context.model.leafModules().flattened()
                    .first(where: { $0.0.hasSuffix("embed_tokens_per_layer") }) else { return }
                let table = CustomTable(weight: layer.weight, scales: layer.scales, biases: layer.biases,
                                        groupSize: layer.groupSize, bits: layer.bits)
                try? context.model.update(modules: ModuleChildren.unflattened([(path, table)]), verify: [.none])
            }
            await HostPLE.install(in: own, repo: repo, ple: TinyGemma.serving)
            await HostPLE.install(in: custom, repo: repo, ple: TinyGemma.serving)
            let customTable = await table(custom)
            XCTAssertEqual(customTable, "CustomTable")
            XCTAssertFalse(HostPLE.servesTable(of: repo) { _ in true }, "a table it can't swap is declined")
        }
    }

    // The served load never reads the table: with the table far larger than
    // the rest of the model, the load's peak stays below it — where the
    // library's load, which reads every tensor first, passes it.
    func testTheServedLoadNeverReadsTheTable() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let directory = try TinyGemma.scratch("big-table")
            defer { try? FileManager.default.removeItem(at: directory) }
            let rows = 65_536
            try await TinyGemma.write(to: directory, tableRows: rows)
            let config = TinyGemma.config(tableRows: rows)
            let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: Data(config.utf8))
            // 4-bit, 64 wide: 8 packed words, 2 scales and 2 biases a row (fp32).
            let tableBytes = rows * (8 * 4 + 2 * 4 + 2 * 4)

            func peak(_ load: () throws -> Void) rethrows -> Int {
                let baseline = Memory.activeMemory
                Memory.peakMemory = 0
                try load()
                return Memory.peakMemory - baseline
            }
            let served = try await TinyGemma.model(config, seed: 2)
            let servedPeak = try peak {
                XCTAssertTrue(try HostPLE.loadServingTable(into: served, from: directory, base.perLayerQuantization) { _ in true })
            }
            let library = try await TinyGemma.model(config, seed: 1)
            let libraryPeak = try peak {
                try loadWeights(modelDirectory: directory, model: library, perLayerQuantization: base.perLayerQuantization)
            }
            XCTAssertLessThan(servedPeak, tableBytes, "the served load read the table")
            XCTAssertGreaterThan(libraryPeak - servedPeak, tableBytes / 2, "the measure must see a read table")
        }
    }

    // A tokenizer stays cached across idle unloads, but not a superseded
    // build's — another snapshot of the same repo — nor one whose folder is
    // gone from disk.
    func testTheTokenizerCacheDropsSupersededBuilds() async throws {
        let root = try TinyGemma.scratch("tokenizers")
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let parses = LockedValue(0)
        let cache = TokenizerCache { _ in
            parses.mutate { $0 += 1 }
            return CharTokenizer()
        }
        let old = try folder("models--a--x/snapshots/1"), new = try folder("models--a--x/snapshots/2")
        let other = try folder("models--a--y/snapshots/1"), third = try folder("models--a--z/snapshots/1")
        for directory in [old, other, new] { _ = try await cache.load(from: directory) }
        XCTAssertEqual(cache.directories, [new, other])
        _ = try await cache.load(from: new)
        XCTAssertEqual(parses.get(), 3, "a kept tokenizer is not parsed again")
        try FileManager.default.removeItem(at: other)
        _ = try await cache.load(from: third)
        XCTAssertEqual(cache.directories, [new, third])
    }

    // An engine rebuilt for another model keeps only the tokenizers of the
    // models the two share.
    func testAReplacingResidencyKeepsOnlySharedTokenizers() async throws {
        try await inScratchHub {
            let cache = TokenizerCache { _ in CharTokenizer() }
            let first = ModelResidency(primaryID: "test/a", style: .base, promptCache: MLXEngine.PromptCache(),
                                       after: nil, tokenizers: cache)
            let a = try snapshot(of: "test/a"), b = try snapshot(of: "test/b")
            for directory in [a, b] { _ = try await cache.load(from: directory) }
            XCTAssertEqual(cache.directories, [a, b])
            _ = ModelResidency(primaryID: "test/b", style: .base, promptCache: MLXEngine.PromptCache(), after: first)
            XCTAssertEqual(cache.directories, [b])
        }
    }
}

/// A per-layer table of its own kind.
private final class CustomTable: QuantizedEmbedding {}

/// Quantized layers of every kind a blueprint meets: plain, a subclass,
/// and global-scale ones.
private final class MixedQuantizedModel: Module, LLMModel {
    private final class Rotated: QuantizedLinear {}
    private final class Sharded: QuantizedEmbedding {}

    @ModuleInfo var linear: QuantizedLinear
    @ModuleInfo var rotated: QuantizedLinear
    @ModuleInfo var scaledLinear: QuantizedLinear
    @ModuleInfo var embedding: QuantizedEmbedding
    @ModuleInfo var sharded: QuantizedEmbedding
    @ModuleInfo var scaledEmbedding: QuantizedEmbedding
    /// A reference cycle, which the walk for the husk must not follow forever.
    let loop = Loop()

    final class Loop {
        weak var next: Loop?
        init() { next = self }
    }

    override init() {
        let (weight, scales) = (MLXArray.zeros([8, 4], dtype: .uint32), MLXArray.zeros([8, 1]))
        func linear(_ scale: MLXArray? = nil) -> QuantizedLinear {
            QuantizedLinear(weight: weight, scales: scales, biases: scales, groupSize: 32, bits: 4, globalScale: scale)
        }
        func embedding(_ scale: MLXArray? = nil) -> QuantizedEmbedding {
            QuantizedEmbedding(weight: weight, scales: scales, biases: scales, groupSize: 32, bits: 4, globalScale: scale)
        }
        _linear.wrappedValue = linear()
        _rotated.wrappedValue = Rotated(weight: weight, scales: scales, biases: scales, groupSize: 32, bits: 4)
        _scaledLinear.wrappedValue = linear(MLXArray(1))
        _embedding.wrappedValue = embedding()
        _sharded.wrappedValue = Sharded(weight: weight, scales: scales, biases: scales, groupSize: 32, bits: 4)
        _scaledEmbedding.wrappedValue = embedding(MLXArray(1))
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray { inputs }
    func newCache(parameters: GenerateParameters?) throws -> [any KVCache] { [] }
    var loraLayers: [Module] { [] }
}

/// A model with a vision tower, as Gemma 4's VLM build has one.
private final class ToweredModel: Module, LLMModel {
    @ModuleInfo(key: "vision_tower") var visionTower: Linear

    override init() {
        _visionTower.wrappedValue = Linear(8, 8)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray { inputs }
    func newCache(parameters: GenerateParameters?) throws -> [any KVCache] { [] }
    var loraLayers: [Module] { [] }
}
