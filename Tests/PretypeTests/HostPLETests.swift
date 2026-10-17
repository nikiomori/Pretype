import MLX
import XCTest
@testable import Pretype

/// `HostPLE.tableSpans` picks the bytes a lookup reads on every keystroke: a
/// span off by the header is garbage rows, one past the end of the file a SIGBUS.
final class HostPLETests: XCTestCase {
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
        func file(length: UInt64 = UInt64(json.count), payload: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
            let data = withUnsafeBytes(of: length.littleEndian) { Data($0) } + json + Data(count: payload)
            try data.write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
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
    }
}
