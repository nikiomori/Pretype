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
    let tensors: [Tensor]
    private let region: UnsafeMutableRawPointer, regionLength: Int

    private init(region: UnsafeMutableRawPointer, length: Int, tensors: [Tensor], of layer: QuantizedEmbedding) {
        (self.region, regionLength, self.tensors) = (region, length, tensors)
        (groupSize, bits, mode) = (layer.groupSize, layer.bits, layer.mode)
        super.init(weight: MLXArray.zeros([1, 1], dtype: .uint32))
    }

    deinit { munmap(region, regionLength) }

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

    /// Whether loads serve the table from disk: `Settings.pleFromDisk`, or
    /// `PRETYPE_HOST_PLE=on|off` pinning it (the A/B arms).
    static var enabled: Bool {
        switch ProcessInfo.processInfo.environment["PRETYPE_HOST_PLE"] {
        case "on": true
        case "off": false
        default: Settings.pleFromDisk
        }
    }

    /// What serving the table from disk frees on `modelID` — the table's size
    /// (262144 rows × layers × 256, 4-bit) — or nil for a model without one.
    static func savingGB(for modelID: String) -> Double? {
        modelID.contains("gemma-4-e2b") ? 1.3 : modelID.contains("gemma-4-e4b") ? 1.6 : nil
    }

    /// When `enabled`, swaps the loaded model's PLE table for one served from
    /// its snapshot files and frees the GPU copy. Leaves any other model, a
    /// layout it doesn't recognize, or rows that don't match the loaded ones
    /// alone. Returns the mode it was loaded for (`enabled`, even when the
    /// swap couldn't happen — a retry would fail the same way), nil without a table.
    @discardableResult
    static func install(in container: ModelContainer, repo: String) async -> Bool? {
        let enabled = enabled
        let directory = ModelStorage.cacheDirectory(repo: repo).flatMap(ModelStorage.localSnapshot(at:))
        let (installed, hasTable) = await container.perform { (context: ModelContext) -> (Bool, Bool) in
            guard case let (path, module)? = context.model.leafModules().flattened()
                    .first(where: { $0.0.hasSuffix("embed_tokens_per_layer") }),
                  type(of: module) == QuantizedEmbedding.self, let layer = module as? QuantizedEmbedding
            else { return (false, false) }
            guard enabled, let directory, let biases = layer.biases, layer.globalScale == nil, layer.mode == .affine,
                  let host = map(directory, matching: [layer.weight, layer.scales, biases], of: layer)
            else { return (false, true) }
            // The mapped rows must be the loaded ones: first, last and a middle row.
            let probe = MLXArray([0, Int32(layer.weight.dim(0) / 2), Int32(layer.weight.dim(0) - 1)])
            guard host(probe).arrayEqual(layer(probe)).item(Bool.self) else {
                DebugLog.shared.log("MLX", "PLE rows in the file differ from the loaded table — kept on the GPU")
                return (false, true)
            }
            do {
                try context.model.update(modules: ModuleChildren.unflattened([(path, host)]), verify: [.none])
                return (true, true)
            } catch {
                DebugLog.shared.log("MLX", "PLE swap failed: \(error.localizedDescription)")
                return (false, true)
            }
        }
        if installed { Memory.clearCache() }
        return hasTable ? enabled : nil
    }

    /// Maps the file range that holds `loaded`'s three tensors, if the
    /// snapshot stores them with the same shapes and dtypes.
    private static func map(_ directory: URL, matching loaded: [MLXArray], of layer: QuantizedEmbedding) -> HostPLE? {
        let dtypes: [String: DType] = ["U32": .uint32, "BF16": .bfloat16, "F16": .float16, "F32": .float32]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "safetensors" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.read(upToCount: 8), size.count == 8 else { continue }
            let headerLength = Int(size.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            guard let headerData = try? handle.read(upToCount: headerLength),
                  let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  let key = header.keys.first(where: { $0.hasSuffix("embed_tokens_per_layer.weight") })
            else { continue }
            let prefix = String(key.dropLast("weight".count))
            var spans: [(start: Int, end: Int, shape: [Int], dtype: DType)] = []
            for (name, array) in zip(["weight", "scales", "biases"], loaded) {
                guard let entry = header[prefix + name] as? [String: Any],
                      let offsets = entry["data_offsets"] as? [Int], offsets.count == 2,
                      let shape = entry["shape"] as? [Int],
                      let dtype = (entry["dtype"] as? String).flatMap({ dtypes[$0] }),
                      shape == array.shape, dtype == array.dtype,
                      offsets[1] - offsets[0] == shape.reduce(dtype.size, *)
                else { return nil }
                spans.append((8 + headerLength + offsets[0], 8 + headerLength + offsets[1], shape, dtype))
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
            return HostPLE(region: region, length: length,
                           tensors: spans.map { ($0.start - low, $0.shape, $0.dtype) }, of: layer)
        }
        return nil
    }
}
