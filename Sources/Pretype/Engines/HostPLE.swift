import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Gemma 4's per-layer embedding table (E2B 1.3 GB, E4B 1.6 GB: a third to
/// half of the weights) read from the mapped model file on the CPU instead of
/// a GPU copy. A token reads one ~5 KB row of it; the same bytes go into the
/// same `dequantized` as `QuantizedEmbedding`'s, so outputs are identical.
/// Mapped file pages are clean: they don't count in the app's footprint, and
/// under memory pressure macOS drops them and reads a row back from disk.
/// The cost: a row needs its token on the CPU, so decode can't encode step
/// t+1 while the GPU still runs step t.
final class HostPLE: Embedding {
    typealias Tensor = (offset: Int, shape: [Int], dtype: DType)

    let groupSize: Int, bits: Int, mode: QuantizationMode
    /// weight, scales, biases: where each sits in `region`, as loaded.
    var tensors: [Tensor] { layout.tensors }
    /// Boxed: `Module` reflects an array or tuple property as child
    /// structure, and with one this module was no leaf — `leafModules`, which
    /// `install` and the blueprint's placeholders search, skipped it.
    private let layout: Layout
    private struct Layout { let tensors: [Tensor] }
    private let region: UnsafeMutableRawPointer, regionLength: Int

    private init(region: UnsafeMutableRawPointer, length: Int, tensors: [Tensor],
                 groupSize: Int, bits: Int, mode: QuantizationMode) {
        (self.region, regionLength, layout) = (region, length, Layout(tensors: tensors))
        (self.groupSize, self.bits, self.mode) = (groupSize, bits, mode)
        super.init(weight: MLXArray.zeros([1, 1], dtype: .uint32))
    }

    deinit { munmap(region, regionLength) }

    /// Its weights are the file's: a strict `update` (`loadWeights`) finds
    /// none of them to set, and that is no error.
    override func updateMissing(parameter: String, verify: VerifyUpdate, path: [String], modulePath: [String]) throws {}

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        // In the token's own dtype: a conversion would be one more GPU round trip.
        let ids: [Int] = switch x.dtype {
        case .uint32: x.asArray(UInt32.self).map { Int($0) }
        case .int32: x.asArray(Int32.self).map { Int($0) }
        default: x.asType(.int32).asArray(Int32.self).map { Int($0) }
        }
        let rows = tensors[0].shape[0]
        let parts = tensors.map { tensor -> MLXArray in
            let rowBytes = tensor.shape[1] * tensor.dtype.size
            var data = Data(count: ids.count * rowBytes)
            data.withUnsafeMutableBytes { out in
                guard let out = out.baseAddress else { return }
                for (i, id) in ids.enumerated() {
                    let row = min(max(id, 0), rows - 1)
                    out.advanced(by: i * rowBytes).copyMemory(
                        from: region.advanced(by: tensor.offset + row * rowBytes), byteCount: rowBytes)
                }
            }
            return MLXArray(data, [ids.count, tensor.shape[1]], dtype: tensor.dtype)
        }
        return dequantized(parts[0], scales: parts[1], biases: parts[2],
                           groupSize: groupSize, bits: bits, mode: mode).reshaped(x.shape + [-1])
    }

    /// What serving the table from disk frees on `modelID` — the table's size
    /// (262144 rows × layers × 256, 4-bit) — or nil for a model without one.
    static func savingGB(for modelID: String) -> Double? {
        modelID.contains("gemma-4-e2b") ? 1.3 : modelID.contains("gemma-4-e4b") ? 1.6 : nil
    }

    /// What `modelID` keeps resident of its booked `gb` weights: less the
    /// table while it is served from disk (`servesTable`). Every memory
    /// figure on the Model tab and the Live Impact rail reads this one, so
    /// none of them disagrees with the "Reduce memory use" toggle — or claims
    /// a saving `install` won't make. Not the download size.
    static func residentGB(_ gb: Double, of modelID: String, pleFromDisk: Bool = Settings.pleFromDisk,
                           servesTable: (String) -> Bool = { HostPLE.servesTable(of: $0) }) -> Double {
        guard pleFromDisk, let saving = savingGB(for: modelID), servesTable(modelID) else { return gb }
        return gb - saving
    }

    /// Whether `install` serves `modelID`'s table from disk: not once it
    /// declined to this launch, and only from an internal disk — its own
    /// check, on the folder the model's files sit in, or will.
    static func servesTable(of modelID: String,
                            onInternalDisk: (URL) -> Bool = { HostPLE.isOnInternalDisk($0) }) -> Bool {
        let repo = ModelCatalog.repo(for: modelID)
        guard !declined.get().contains(repo), let folder = ModelStorage.cacheDirectory(repo: repo) else { return false }
        return onInternalDisk(folder)
    }

    /// Repos whose table `install` kept on the GPU this launch: a layout or
    /// rows it doesn't recognize, files it couldn't map. In memory only —
    /// each launch tries again.
    private static let declined = LockedValue<Set<String>>([])

    static func noteInstall(repo: String, served: Bool) {
        declined.mutate { if served { $0.remove(repo) } else { $0.insert(repo) } }
    }

    /// A mapped page read back from a volume that went away (an external or
    /// network drive holding the cache, through `HF_HUB_CACHE`, `HF_HOME` or
    /// a symlink) is a SIGBUS, not an error: anywhere but an internal disk
    /// the table stays resident. A `url` not there yet — a model still to
    /// download — is judged by the nearest folder that is.
    static func isOnInternalDisk(_ url: URL, volume: (URL) -> Volume = HostPLE.volume(of:)) -> Bool {
        var url = url
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let found = volume(url.resolvingSymlinksInPath())
        return found.isInternal == true && found.isLocal == true
    }

    typealias Volume = (isInternal: Bool?, isLocal: Bool?)

    static func volume(of url: URL) -> Volume {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        return (values?.volumeIsInternal, values?.volumeIsLocal)
    }

    /// With `Settings.pleFromDisk` on, makes sure the loaded model serves its
    /// PLE table from the snapshot files: one built by `loadWeights` already
    /// does; one the factory loaded (a first download, a fallback) has the
    /// table swapped and the GPU copy freed — after a load that read it whole.
    /// Leaves any other model, a layout it doesn't recognize, or rows that
    /// don't match the loaded ones alone, and remembers the decline
    /// (`servesTable`). The setting applies from the next load: flipping it
    /// rebuilds the engine.
    static func install(in container: ModelContainer, repo: String, ple: Policy = .live) async {
        guard ple.enabled else { return }
        let directory = ModelStorage.cacheDirectory(repo: repo).flatMap(ModelStorage.localSnapshot(at:))
        // nil: the model has no such table.
        let served = await container.perform { (context: ModelContext) -> Bool? in
            guard case let (path, module)? = context.model.leafModules().flattened()
                    .first(where: { $0.0.hasSuffix("embed_tokens_per_layer") }) else { return nil }
            if module is HostPLE { return true }
            guard type(of: module) == QuantizedEmbedding.self, let layer = module as? QuantizedEmbedding,
                  let directory, let biases = layer.biases, layer.globalScale == nil, layer.mode == .affine,
                  let host = map(directory, matching: [layer.weight, layer.scales, biases],
                                 groupSize: layer.groupSize, bits: layer.bits, mode: layer.mode,
                                 onInternalDisk: ple.onInternalDisk)
            else { return false }
            // The mapped rows must be the loaded ones: first, last and a middle row.
            let probe = MLXArray([0, Int32(layer.weight.dim(0) / 2), Int32(layer.weight.dim(0) - 1)])
            guard host(probe).arrayEqual(layer(probe)).item(Bool.self) else {
                DebugLog.shared.log("MLX", "PLE rows in the file differ from the loaded table — kept on the GPU")
                return false
            }
            do {
                try context.model.update(modules: ModuleChildren.unflattened([(path, host)]), verify: [.none])
                return true
            } catch {
                DebugLog.shared.log("MLX", "PLE swap failed: \(error.localizedDescription)")
                return false
            }
        }
        guard let served else { return }
        noteInstall(repo: repo, served: served)
        if served { Memory.clearCache() }
    }

    /// `loadWeights` for a model whose per-layer table is served from disk:
    /// every other weight loads as the library loads it — the same files,
    /// `prepareCheckpoint`, quantization and strict `update`, then `prepare`
    /// and `eval` — and the table's bytes are never read; this module serves
    /// them from the file. The library can't skip them: `loadModelCheckpoint`
    /// evaluates every tensor of the files before `sanitize`, `update` or
    /// `eval(model)` sees one, so each load held the whole table (E2B 1.3 GB,
    /// E4B 1.6 GB) on top of the rest until `install` freed it. false, with
    /// `model` untouched, when the setting is off or the table can't be
    /// served; the caller then runs `loadWeights`.
    static func loadWeights(into model: any LanguageModel, from directory: URL,
                            perLayerQuantization: BaseConfiguration.PerLayerQuantization?,
                            ple: Policy = .live) async throws -> Bool {
        guard ple.enabled else { return false }
        // Off the cooperative pool, as the library's own loader: `eval` blocks
        // on file reads. On the caller's device: a queue doesn't carry it.
        nonisolated(unsafe) let model = model
        let device = Device.defaultDevice()
        return try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result {
                    try Device.withDefaultDevice(device) {
                        try loadServingTable(into: model, from: directory, perLayerQuantization, onInternalDisk: ple.onInternalDisk)
                    }
                })
            }
        }
    }

    /// Whether loads serve the table from disk ("Reduce memory use"), and
    /// which volumes they map it from — read when a load starts; tests pin
    /// both instead of this Mac's settings and disk.
    struct Policy: Sendable {
        var enabled: Bool
        var onInternalDisk: @Sendable (URL) -> Bool

        static var live: Policy { Policy(enabled: Settings.pleFromDisk) { HostPLE.isOnInternalDisk($0) } }
    }

    /// `loadWeights`' work, on the calling thread. `onInternalDisk`: the
    /// volume rule `map` applies (a test's scratch folder may not pass it).
    static func loadServingTable(into model: any LanguageModel, from directory: URL,
                                 _ perLayerQuantization: BaseConfiguration.PerLayerQuantization?,
                                 onInternalDisk: (URL) -> Bool = { HostPLE.isOnInternalDisk($0) }) throws -> Bool {
        guard let path = model.leafModules().flattened().first(where: { $0.0.hasSuffix("embed_tokens_per_layer") })?.0
        else { return false }
        // Lazy: MLX reads a tensor's bytes only when it is evaluated.
        var raw: [String: MLXArray] = [:], weightMetadata: [String: [String: String]] = [:]
        var metadata: [String: String] = [:]
        for file in weightFiles(in: directory) {
            let (arrays, fileMetadata) = try loadArraysAndMetadata(url: file)
            raw.merge(arrays) { $1 }
            for key in arrays.keys { weightMetadata[key] = fileMetadata }
            if metadata.isEmpty { metadata = fileMetadata }
        }
        var checkpoint = try model.prepareCheckpoint(ModelCheckpoint(
            weights: raw, metadata: metadata, weightMetadata: weightMetadata, perLayerQuantization: perLayerQuantization))
        let keys = ["weight", "scales", "biases"].map { "\(path).\($0)" }
        let table = keys.compactMap { checkpoint.weights[$0] }
        guard table.count == 3, passedThrough(table, from: raw),
              let q = checkpoint.perLayerQuantization?.quantization(layer: path), q.mode == .affine,
              quantizationFits(weight: table[0].shape, scales: table[1].shape, bits: q.bits, groupSize: q.groupSize),
              let host = map(directory, matching: table, groupSize: q.groupSize, bits: q.bits, mode: q.mode,
                             onInternalDisk: onInternalDisk)
        else { return false }
        for key in keys { checkpoint.weights[key] = nil }
        let weights = checkpoint.weights
        if let perLayerQuantization = checkpoint.perLayerQuantization {
            quantize(model: model) { path, _ in
                weights["\(path).scales"] != nil ? perLayerQuantization.quantization(layer: path)?.asTuple : nil
            }
        }
        try model.update(modules: ModuleChildren.unflattened([(path, host)]), verify: [.none])
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        // The library logs a failed optional optimization and serves the
        // unfused path; so does this.
        do { try model.prepare() } catch { DebugLog.shared.log("MLX", "inference state not prepared: \(error.localizedDescription)") }
        eval(model)
        return true
    }

    /// The table is the very arrays read from the file — `sanitize` renamed,
    /// not rewrote, them — so the mapped bytes are what the model would load.
    static func passedThrough(_ table: [MLXArray], from raw: [String: MLXArray]) -> Bool {
        let fromFile = Set(raw.values.map(ObjectIdentifier.init))
        return table.allSatisfy { fromFile.contains(ObjectIdentifier($0)) }
    }

    /// The table's packed weight and its scales describe one row width at
    /// the configured `bits` and `groupSize` — or `dequantized` would read
    /// the rows at the wrong width.
    static func quantizationFits(weight: [Int], scales: [Int], bits: Int, groupSize: Int) -> Bool {
        weight.count == 2 && scales.count == 2 && bits > 0 && weight[1] * 32 / bits == scales[1] * groupSize
    }

    /// The weight files `loadWeights` reads, chosen as the library chooses
    /// them: the ones the index names, else `model*.safetensors`, else
    /// `weight*.safetensors`, else every safetensors file at the top level.
    static func weightFiles(in directory: URL) -> [URL] {
        if let shards = ModelStorage.shards(listedIn: directory.appendingPathComponent("model.safetensors.index.json")) {
            let urls = shards.sorted().map { directory.appendingPathComponent($0) }
            if !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return urls }
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for prefix in ["model", "weight"] {
            let named = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
            if !named.isEmpty { return named }
        }
        return files
    }

    /// Maps the file range that holds `loaded`'s three tensors, if the
    /// snapshot stores them with the same shapes and dtypes.
    static func map(_ directory: URL, matching loaded: [MLXArray], groupSize: Int, bits: Int, mode: QuantizationMode,
                    onInternalDisk: (URL) -> Bool = { HostPLE.isOnInternalDisk($0) }) -> HostPLE? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "safetensors" {
            guard let spans = tableSpans(in: file, matching: loaded.map { ($0.shape, $0.dtype) }) else { continue }
            guard onInternalDisk(file) else {
                DebugLog.shared.log("MLX", "PLE kept on the GPU: the model files are not on an internal disk")
                return nil
            }
            let page = Int(getpagesize())
            guard let start = spans.map(\.start).min(), let end = spans.map(\.end).max() else { return nil }
            let low = start / page * page, length = end - low
            let fd = open(file.path, O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard let region = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, off_t(low)), region != MAP_FAILED
            else { return nil }
            // A token's row is all a lookup needs: no read-ahead around it.
            madvise(region, length, MADV_RANDOM)
            return HostPLE(region: region, length: length, tensors: spans.map { ($0.start - low, $0.shape, $0.dtype) },
                           groupSize: groupSize, bits: bits, mode: mode)
        }
        return nil
    }

    /// Where the per-layer table's weight, scales and biases sit in one
    /// safetensors file, as byte offsets from its start — nil unless the
    /// header names them with `expected`'s shapes and dtypes and every byte
    /// lies inside the file (a page mapped past the end is a SIGBUS too).
    static func tableSpans(in file: URL, matching expected: [(shape: [Int], dtype: DType)])
        -> [(start: Int, end: Int, shape: [Int], dtype: DType)]? {
        let dtypes: [String: DType] = ["U32": .uint32, "BF16": .bfloat16, "F16": .float16, "F32": .float32]
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let size = try? handle.read(upToCount: 8), size.count == 8,
              let headerLength = Int(exactly: UInt64(littleEndian: size.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })),
              headerLength <= Int(fileSize) - 8,
              let headerData = try? handle.read(upToCount: headerLength),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let key = header.keys.first(where: { $0.hasSuffix("embed_tokens_per_layer.weight") })
        else { return nil }
        let prefix = String(key.dropLast("weight".count)), base = 8 + headerLength
        var spans: [(start: Int, end: Int, shape: [Int], dtype: DType)] = []
        for (name, want) in zip(["weight", "scales", "biases"], expected) {
            guard let entry = header[prefix + name] as? [String: Any],
                  let offsets = entry["data_offsets"] as? [Int], offsets.count == 2,
                  let shape = entry["shape"] as? [Int],
                  let dtype = (entry["dtype"] as? String).flatMap({ dtypes[$0] }),
                  shape == want.shape, dtype == want.dtype, offsets[0] >= 0,
                  offsets[1] - offsets[0] == shape.reduce(dtype.size, *),
                  offsets[1] <= Int(fileSize) - base
            else { return nil }
            spans.append((base + offsets[0], base + offsets[1], shape, dtype))
        }
        return spans.count == 3 ? spans : nil
    }
}
