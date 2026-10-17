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

    /// What serving the table from disk frees on `modelID` — the table's size
    /// (262144 rows × layers × 256, 4-bit) — or nil for a model without one.
    static func savingGB(for modelID: String) -> Double? {
        modelID.contains("gemma-4-e2b") ? 1.3 : modelID.contains("gemma-4-e4b") ? 1.6 : nil
    }

    /// With `Settings.pleFromDisk` on, swaps the loaded model's PLE table for
    /// one served from its snapshot files and frees the GPU copy. Leaves any
    /// other model, a layout it doesn't recognize, or rows that don't match
    /// the loaded ones alone. The setting applies from the next load: flipping
    /// it rebuilds the engine.
    static func install(in container: ModelContainer, repo: String) async {
        guard Settings.pleFromDisk else { return }
        let directory = ModelStorage.cacheDirectory(repo: repo).flatMap(ModelStorage.localSnapshot(at:))
        let installed = await container.perform { (context: ModelContext) -> Bool in
            guard case let (path, module)? = context.model.leafModules().flattened()
                    .first(where: { $0.0.hasSuffix("embed_tokens_per_layer") }),
                  type(of: module) == QuantizedEmbedding.self, let layer = module as? QuantizedEmbedding,
                  let directory, let biases = layer.biases, layer.globalScale == nil, layer.mode == .affine,
                  let host = map(directory, matching: [layer.weight, layer.scales, biases], of: layer)
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
        if installed { Memory.clearCache() }
    }

    /// Maps the file range that holds `loaded`'s three tensors, if the
    /// snapshot stores them with the same shapes and dtypes.
    private static func map(_ directory: URL, matching loaded: [MLXArray], of layer: QuantizedEmbedding) -> HostPLE? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "safetensors" {
            guard let spans = tableSpans(in: file, matching: loaded.map { ($0.shape, $0.dtype) }) else { continue }
            // A mapped page read back from a volume that went away (an external
            // or network drive holding the cache) is a SIGBUS, not an error:
            // anywhere but an internal disk the table stays resident.
            let volume = try? file.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
            guard volume?.volumeIsInternal == true, volume?.volumeIsLocal == true else {
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
            return HostPLE(region: region, length: length,
                           tensors: spans.map { ($0.start - low, $0.shape, $0.dtype) }, of: layer)
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
