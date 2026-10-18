import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import XCTest
@testable import Pretype

/// `HostPLE.tableSpans` picks the bytes a lookup reads on every keystroke: a
/// span off by the header is garbage rows, one past the end of the file a SIGBUS.
final class HostPLETests: MLXTestCase {

    func testTableSpansReadTheHeaderAndStayInsideTheFile() throws {
        // weight U32 [4, 2], scales and biases BF16 [4, 1]: 32 + 8 + 8 bytes.
        let prefix = "language_model.model.embed_tokens_per_layer."
        let header: [String: Any] = [
            "__metadata__": ["format": "mlx"],
            prefix + "weight": ["dtype": "U32", "shape": [4, 2], "data_offsets": [0, 32]],
            prefix + "scales": ["dtype": "BF16", "shape": [4, 1], "data_offsets": [32, 40]],
            prefix + "biases": ["dtype": "BF16", "shape": [4, 1], "data_offsets": [40, 48]],
        ]
        let json = try JSONSerialization.data(withJSONObject: header)
        let expected: [(shape: [Int], dtype: DType)] = [([4, 2], .uint32), ([4, 1], .bfloat16), ([4, 1], .bfloat16)]
        func file(length: UInt64 = UInt64(json.count), payload: Int, json: Data = json) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
            let data = withUnsafeBytes(of: length.littleEndian) { Data($0) } + json + Data(count: payload)
            try data.write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }
        /// The header with the scales' entry changed.
        func scales(_ entry: [String: Any]) throws -> URL {
            var changed = header
            changed[prefix + "scales"] = entry
            let json = try JSONSerialization.data(withJSONObject: changed)
            return try file(length: UInt64(json.count), payload: 48, json: json)
        }

        let spans = HostPLE.tableSpans(in: try file(payload: 48), matching: expected)
        let base = 8 + json.count
        XCTAssertEqual(spans?.map(\.start), [base, base + 32, base + 40])
        XCTAssertEqual(spans?.map(\.end), [base + 32, base + 40, base + 48])
        XCTAssertEqual(spans?.map(\.dtype), [.uint32, .bfloat16, .bfloat16])
        // A truncated file, a table loaded at another shape, a garbage header length.
        XCTAssertNil(HostPLE.tableSpans(in: try file(payload: 47), matching: expected))
        XCTAssertNil(HostPLE.tableSpans(in: try file(payload: 48), matching: [([4, 4], .uint32)] + expected.dropFirst()))
        XCTAssertNil(HostPLE.tableSpans(in: try file(length: .max, payload: 48), matching: expected))
        // A file too short for its header length; malformed or mismatched entries.
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
        try Data([1, 2, 3, 4]).write(to: stub)
        addTeardownBlock { try? FileManager.default.removeItem(at: stub) }
        XCTAssertNil(HostPLE.tableSpans(in: stub, matching: expected))
        XCTAssertNil(HostPLE.tableSpans(in: try scales(["dtype": "BF16", "shape": [4, 1], "data_offsets": [32]]),
                                        matching: expected), "one offset")
        XCTAssertNil(HostPLE.tableSpans(in: try scales(["dtype": "F16", "shape": [4, 1], "data_offsets": [32, 40]]),
                                        matching: expected), "another dtype, as wide")
        XCTAssertNil(HostPLE.tableSpans(in: try scales(["dtype": "BF16", "shape": [4, 1], "data_offsets": [32, 44]]),
                                        matching: expected), "a span wider than the shape")
        XCTAssertNil(HostPLE.tableSpans(in: try scales(["dtype": "BF16", "shape": [4, 1], "data_offsets": [-8, 0]]),
                                        matching: expected), "a span reaching back into the header")
        XCTAssertNotNil(HostPLE.tableSpans(in: try scales(["dtype": "BF16", "shape": [4, 1], "data_offsets": [32, 40]]),
                                           matching: expected), "the control")
    }

    /// Every memory figure subtracts the table only where `install` really
    /// serves it from disk: not on a model without one, not after `install`
    /// declined this launch, not off an internal disk.
    func testResidentFiguresSubtractOnlyATableServedFromDisk() throws {
        try withScratchHub { try checkResidentFigures() }
    }

    private func checkResidentFigures() throws {
        let e2b = "mlx-community/gemma-4-e2b-4bit"
        let served = { (_: String) in true }, kept = { (_: String) in false }
        XCTAssertEqual(HostPLE.residentGB(2.51, of: e2b, pleFromDisk: true, servesTable: served), 2.51 - 1.3, accuracy: 0.001)
        XCTAssertEqual(HostPLE.residentGB(2.51, of: e2b, pleFromDisk: true, servesTable: kept), 2.51)
        XCTAssertEqual(HostPLE.residentGB(2.51, of: e2b, pleFromDisk: false, servesTable: served), 2.51)
        XCTAssertEqual(HostPLE.residentGB(1.5, of: "nikimori/Qwen3.5-2B-Base-6bit", pleFromDisk: true, servesTable: served), 1.5)

        // A declined install holds for the launch, whatever the disk; after a
        // served one the disk decides.
        let repo = ModelCatalog.repo(for: e2b)
        let internalDisk = { (_: URL) in true }, externalDisk = { (_: URL) in false }
        HostPLE.noteInstall(repo: repo, served: false)
        XCTAssertFalse(HostPLE.servesTable(of: e2b, onInternalDisk: internalDisk))
        XCTAssertEqual(HostPLE.residentGB(2.51, of: e2b, pleFromDisk: true), 2.51)
        HostPLE.noteInstall(repo: repo, served: true)
        XCTAssertTrue(HostPLE.servesTable(of: e2b, onInternalDisk: internalDisk))
        XCTAssertFalse(HostPLE.servesTable(of: e2b, onInternalDisk: externalDisk))
    }

    /// The volume rule `map` and the figures share: an internal, local disk
    /// only — an external or a network one can vanish under a mapped page.
    /// A model still to download is judged by the folder it will land in.
    func testOnlyAnInternalLocalDiskServesTheTable() {
        func verdict(_ volume: HostPLE.Volume) -> Bool { HostPLE.isOnInternalDisk(URL(fileURLWithPath: "/")) { _ in volume } }
        XCTAssertTrue(verdict((true, true)))
        XCTAssertFalse(verdict((false, true)), "an external drive")
        XCTAssertFalse(verdict((true, false)), "a network volume")
        XCTAssertFalse(verdict((nil, nil)), "unknown")

        let tmp = FileManager.default.temporaryDirectory
        var asked: URL?
        _ = HostPLE.isOnInternalDisk(tmp.appendingPathComponent("\(UUID())/models--a--b/blobs")) { url in
            asked = url
            return (true, true)
        }
        XCTAssertEqual(asked?.path, tmp.resolvingSymlinksInPath().path)
        // …all the way up to the root, when nothing below it exists.
        _ = HostPLE.isOnInternalDisk(URL(fileURLWithPath: "/pretype-\(UUID())/models--a--b/blobs")) { url in
            asked = url
            return (true, true)
        }
        XCTAssertEqual(asked?.path, "/")
    }

    /// A served table must still be found where `install` and the blueprint
    /// look: among the leaf modules. Its layout was an array property once,
    /// which `Module` reads as children — and the module vanished from
    /// `leafModules`, so every reload quantized a fresh table placeholder.
    func testAServedTableIsALeafModule() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pretype-ple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = "language_model.model.embed_tokens_per_layer."
        let header = try JSONSerialization.data(withJSONObject: [
            prefix + "weight": ["dtype": "U32", "shape": [4, 2], "data_offsets": [0, 32]],
            prefix + "scales": ["dtype": "BF16", "shape": [4, 1], "data_offsets": [32, 40]],
            prefix + "biases": ["dtype": "BF16", "shape": [4, 1], "data_offsets": [40, 48]],
        ])
        let file = withUnsafeBytes(of: UInt64(header.count).littleEndian) { Data($0) } + header + Data(count: 48)
        try file.write(to: directory.appendingPathComponent("model.safetensors"))
        let table = [MLXArray.zeros([4, 2], dtype: .uint32), MLXArray.zeros([4, 1], dtype: .bfloat16),
                     MLXArray.zeros([4, 1], dtype: .bfloat16)]
        XCTAssertNil(HostPLE.map(directory, matching: table, groupSize: 64, bits: 4, mode: .affine) { _ in false },
                     "a file off the internal disk is never mapped")
        let host = try XCTUnwrap(HostPLE.map(directory, matching: table, groupSize: 64, bits: 4, mode: .affine) { _ in true })
        XCTAssertTrue(host.children().isEmpty)
        XCTAssertEqual(Holder(host).leafModules().flattened().map(\.0), ["embed_tokens_per_layer"])
    }

    /// Built without the factory, a model must stop where the factory's
    /// would: on config.json's EOS ids, which generation_config.json
    /// overrides (mlx-lm's rule).
    func testAModelBuiltWithoutTheFactoryKeepsItsEOSIds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pretype-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type": "gemma4", "eos_token_id": 1}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        XCTAssertEqual(try MLXEngine.factoryConfiguration(of: directory).eosTokenIds, [1])
        try Data(#"{"eos_token_id": [1, 106, 50]}"#.utf8).write(to: directory.appendingPathComponent("generation_config.json"))
        XCTAssertEqual(try MLXEngine.factoryConfiguration(of: directory).eosTokenIds, [1, 50, 106])
    }

    /// The weight files, chosen as mlx-swift-lm chooses them: the index's,
    /// else `model*`, else `weight*`, else every safetensors file.
    func testWeightFilesFollowTheLibrarysChoice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pretype-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func touch(_ name: String) throws { try Data().write(to: directory.appendingPathComponent(name)) }
        func names() -> [String] { HostPLE.weightFiles(in: directory).map(\.lastPathComponent) }
        try touch("extra.safetensors")
        XCTAssertEqual(names(), ["extra.safetensors"])
        try touch("weights.safetensors")
        XCTAssertEqual(names(), ["weights.safetensors"])
        try touch("model-00002-of-00002.safetensors")
        try touch("model-00001-of-00002.safetensors")
        XCTAssertEqual(names(), ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        try JSONSerialization.data(withJSONObject: ["weight_map": ["a": "model-00002-of-00002.safetensors"]])
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertEqual(names(), ["model-00002-of-00002.safetensors"])
        try JSONSerialization.data(withJSONObject: ["weight_map": ["a": "model-00003-of-00003.safetensors"]])
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertEqual(names(), ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"],
                       "an index naming a missing file")
        try JSONSerialization.data(withJSONObject: ["weight_map": [String: String]()])
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertEqual(names(), ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"],
                       "an index naming no file")
    }

    /// The volume flags, read for real: devfs is no disk, internal or not,
    /// so nothing is mapped from it; the temporary folder is a local volume
    /// on any Mac, a CI runner's virtual disk included.
    func testTheVolumeFlagsReadForReal() {
        XCTAssertFalse(HostPLE.isOnInternalDisk(URL(fileURLWithPath: "/dev")))
        XCTAssertEqual(HostPLE.volume(of: FileManager.default.temporaryDirectory).isLocal, true)
    }

    /// The two cheap checks that stand between a file and a served table.
    func testTheTableChecksAreStrict() {
        XCTAssertTrue(HostPLE.quantizationFits(weight: [96, 2], scales: [96, 2], bits: 1, groupSize: 32), "any positive width")
        // 4-bit, group 32: a 64-wide row packs into 8 words, and has 2 scales.
        XCTAssertTrue(HostPLE.quantizationFits(weight: [262_144, 8], scales: [262_144, 2], bits: 4, groupSize: 32))
        XCTAssertFalse(HostPLE.quantizationFits(weight: [262_144, 8], scales: [262_144, 2], bits: 8, groupSize: 32))
        XCTAssertFalse(HostPLE.quantizationFits(weight: [262_144, 8], scales: [262_144, 1], bits: 4, groupSize: 32))
        XCTAssertFalse(HostPLE.quantizationFits(weight: [8], scales: [2], bits: 4, groupSize: 32))
        XCTAssertFalse(HostPLE.quantizationFits(weight: [262_144, 8], scales: [2], bits: 4, groupSize: 32))
        XCTAssertFalse(HostPLE.quantizationFits(weight: [8], scales: [262_144, 2], bits: 4, groupSize: 32))
        XCTAssertFalse(HostPLE.quantizationFits(weight: [262_144, 8], scales: [262_144, 2], bits: 0, groupSize: 32))
        // Renamed by sanitize, the same arrays: served. Rewritten: not.
        let weight = MLXArray.zeros([4, 2], dtype: .uint32), scales = MLXArray.zeros([4, 1])
        let raw = ["model.language_model.embed_tokens_per_layer.weight": weight, "model.language_model.x.scales": scales]
        XCTAssertTrue(HostPLE.passedThrough([weight, scales], from: raw))
        XCTAssertFalse(HostPLE.passedThrough([weight, scales * 2], from: raw))
    }

    /// The row a lookup serves from the file is the row `QuantizedEmbedding`
    /// serves from memory, for every token — what "outputs are identical"
    /// rests on.
    func testServedRowsMatchQuantizedEmbedding() throws {
        let directory = try scratch()
        let table = MLXRandom.normal([96, 64], key: MLXRandom.key(1)).asType(.bfloat16)
        let (weight, scales, biases) = MLX.quantized(table, groupSize: 32, bits: 4)
        let biasesValue = try XCTUnwrap(biases)
        try save(arrays: ["language_model.model.embed_tokens_per_layer.weight": weight,
                          "language_model.model.embed_tokens_per_layer.scales": scales,
                          "language_model.model.embed_tokens_per_layer.biases": biasesValue],
                 url: directory.appendingPathComponent("model.safetensors"))
        let host = try XCTUnwrap(HostPLE.map(directory, matching: [weight, scales, biasesValue],
                                             groupSize: 32, bits: 4, mode: .affine) { _ in true })
        let memory = QuantizedEmbedding(weight: weight, scales: scales, biases: biasesValue, groupSize: 32, bits: 4)
        let ids = MLXArray(Array(0 ..< 96).map(Int32.init)).reshaped([2, 48])
        XCTAssertEqual(host(ids).shape, memory(ids).shape)
        XCTAssertTrue(host(ids).arrayEqual(memory(ids)).item(Bool.self))
        // An id past either end reads the edge row, never past the table.
        func row(_ id: Int32) -> MLXArray { host(MLXArray([id])) }
        XCTAssertTrue(row(200).arrayEqual(row(95)).item(Bool.self))
        XCTAssertTrue(row(-5).arrayEqual(row(0)).item(Bool.self))
    }

    /// A tiny Gemma 4 built both ways — the library's `loadWeights`, which
    /// reads the table, and `HostPLE.loadServingTable`, which never does —
    /// computes the same logits, bit for bit: a 4-bit table in one file, as
    /// the slim re-packs ship it; an 8-bit one in the second of two shards
    /// behind an index, as an original might; and the `gemma4` wrapper, whose
    /// sanitize renames every checkpoint key the table is found by.
    func testServedTableLoadMatchesTheLibraryLoad() async throws {
        try await Device.withDefaultDevice(.cpu) {
            try await checkServedLoad(bits: 4, shards: 1)
            try await checkServedLoad(bits: 8, shards: 2)
            try await checkServedLoad(bits: 4, shards: 1, wrapper: true)
        }
    }

    private func checkServedLoad(bits: Int, shards: Int, wrapper: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let directory = try scratch()
        try await TinyGemma.write(to: directory, bits: bits, shards: shards, wrapper: wrapper)
        let config = TinyGemma.config(bits: bits, wrapper: wrapper)
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: Data(config.utf8))
        let library = try await TinyGemma.model(config, seed: 1)
        try await loadWeights(modelDirectory: directory, model: library, perLayerQuantization: base.perLayerQuantization)
        let served = try await TinyGemma.model(config, seed: 2)
        XCTAssertTrue(try HostPLE.loadServingTable(into: served, from: directory, base.perLayerQuantization) { _ in true },
                      file: file, line: line)
        XCTAssertTrue(TinyGemma.table(library) is QuantizedEmbedding, file: file, line: line)
        XCTAssertTrue(TinyGemma.table(served) is HostPLE, file: file, line: line)
        let expected = TinyGemma.logits(library), got = TinyGemma.logits(served)
        XCTAssertEqual(got.shape, expected.shape, file: file, line: line)
        XCTAssertTrue(got.arrayEqual(expected).item(Bool.self),
                      "\(bits)-bit, \(shards) shard(s)\(wrapper ? ", wrapper" : "")", file: file, line: line)
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pretype-ple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The two checks between a file and a served table, at the load that
    /// makes them: a table sanitize rewrote is no longer the file's bytes,
    /// and one whose shapes don't fit the configured bits would be read at
    /// the wrong width. Either way the load leaves the table to the library.
    func testTheServedLoadTrustsOnlyTheFilesOwnTable() async throws {
        let directory = try scratch()
        let (weight, scales, biases) = MLX.quantized(MLXRandom.normal([96, 64], key: MLXRandom.key(1)), groupSize: 32, bits: 4)
        try save(arrays: ["embed_tokens_per_layer.weight": weight, "embed_tokens_per_layer.scales": scales,
                          "embed_tokens_per_layer.biases": try XCTUnwrap(biases)],
                 metadata: ["format": "mlx"], url: directory.appendingPathComponent("model.safetensors"))
        func quantization(bits: Int) throws -> BaseConfiguration.PerLayerQuantization? {
            let config = #"{"model_type": "t", "quantization": {"group_size": 32, "bits": BITS}}"#
                .replacingOccurrences(of: "BITS", with: "\(bits)")
            return try JSONDecoder.json5().decode(BaseConfiguration.self, from: Data(config.utf8)).perLayerQuantization
        }
        let control = TableModel()
        XCTAssertTrue(try HostPLE.loadServingTable(into: control, from: directory, quantization(bits: 4)) { _ in true },
                      "the control: the file's own table, at its own bits")
        XCTAssertEqual(control.metadata.get(), ["format": "mlx"], "sanitize sees the file's metadata, as in the library's load")
        XCTAssertFalse(try HostPLE.loadServingTable(into: TableModel(rewrites: true), from: directory,
                                                    quantization(bits: 4)) { _ in true }, "a table sanitize rewrote")
        XCTAssertFalse(try HostPLE.loadServingTable(into: TableModel(), from: directory, quantization(bits: 8)) { _ in true },
                       "a table read at the wrong bits")
        let off = try await HostPLE.loadWeights(into: TableModel(), from: directory, perLayerQuantization: quantization(bits: 4),
                                                ple: HostPLE.Policy(enabled: false) { _ in true })
        XCTAssertFalse(off, "the setting off")

        let plain = try scratch()
        try save(arrays: ["embed_tokens_per_layer.weight": MLXRandom.normal([96, 64], key: MLXRandom.key(2))],
                 url: plain.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(try HostPLE.loadServingTable(into: TableModel(), from: plain, quantization(bits: 4)) { _ in true },
                       "a table the file holds unquantized")
    }
}

/// A parent for one table, as Gemma's text model holds it.
private final class Holder: Module {
    @ModuleInfo(key: "embed_tokens_per_layer") var table: Embedding

    init(_ table: Embedding) {
        _table.wrappedValue = table
        super.init()
    }
}

/// A model that is nothing but a per-layer table; `rewrites`: its sanitize
/// hands back copies of the arrays it was given.
private final class TableModel: Module, LLMModel {
    @ModuleInfo(key: "embed_tokens_per_layer") var table: Embedding
    let rewrites: Bool
    /// The metadata its sanitize was handed.
    let metadata = LockedValue<[String: String]>([:])

    init(rewrites: Bool = false) {
        self.rewrites = rewrites
        _table.wrappedValue = Embedding(embeddingCount: 96, dimensions: 64)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray { table(inputs) }
    func newCache(parameters: GenerateParameters?) throws -> [any KVCache] { [] }
    func sanitize(weights: [String: MLXArray], metadata: [String: String]) throws -> [String: MLXArray] {
        self.metadata.set(metadata)
        return rewrites ? weights.mapValues { $0[.ellipsis] } : weights
    }
    var loraLayers: [Module] { [] }
}
