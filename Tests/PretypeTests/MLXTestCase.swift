import Metal
import MLX
import XCTest
@testable import Pretype

/// Base of every suite that runs MLX: HostPLETests, MLXEngineTests,
/// ModelLoadingTests, ModelResidencyTests, GenerationTests,
/// EngineCoordinatorTests. MLX opens the
/// Metal device even for work on the CPU — its allocator is Metal's — and
/// without one it aborts in C++, taking the whole test process down with it.
/// It aborts the same way when the build has no compiled shaders
/// (`default.metallib`): SwiftPM's native build system compiles no Metal, only
/// Swift Build does. Without either, these suites skip, saying why — except on
/// CI, where a Metal device with no shaders fails them: a skip there went
/// unnoticed for every run. Everywhere else they run on the CPU device: they
/// compare numbers, not speed.
class MLXTestCase: XCTestCase {
    /// Why MLX can't run in this process, or nil. The shader lookup is mlx's
    /// own (device.cpp): `mlx-swift_Cmlx.bundle` in a loaded bundle's resources.
    static let whyMLXCannotRun: String? = {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return "No Metal device: MLX would abort the test process"
        }
        let shaders = (Bundle.allBundles + [Bundle(for: MLXTestCase.self)]).contains {
            guard let resources = $0.resourceURL else { return false }
            let lib = resources.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
            return FileManager.default.fileExists(atPath: lib.path)
        }
        return shaders ? nil : "No compiled MLX shaders (default.metallib): MLX would abort the test process"
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let why = Self.whyMLXCannotRun {
            if ProcessInfo.processInfo.environment["CI"] != nil, MTLCreateSystemDefaultDevice() != nil {
                throw NSError(domain: "MLXTestCase", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
            }
            throw XCTSkip(why)
        }
    }

    override func invokeTest() {
        // Even `Device.cpu` starts MLX's default (GPU) stream, which aborts
        // without a device or shaders — so `setUpWithError` must skip first.
        let run = { super.invokeTest() }
        guard Self.whyMLXCannotRun == nil else { return run() }
        Device.withDefaultDevice(.cpu, run)
        // A load the test let go can still be warming up: the next test's
        // measurements, or MLX's static teardown at exit, must not run under it.
        let deadline = Date() + 10
        while ModelResidency.runningLoads.get() > 0, Date() < deadline { usleep(1000) }
    }
}
