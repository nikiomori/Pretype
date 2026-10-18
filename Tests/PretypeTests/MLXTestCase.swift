import Metal
import MLX
import XCTest
@testable import Pretype

/// Base of every suite that runs MLX: HostPLETests, MLXEngineTests,
/// ModelLoadingTests, ModelResidencyTests, GenerationTests,
/// EngineCoordinatorTests. MLX opens the
/// Metal device even for work on the CPU — its allocator is Metal's — and
/// without one it aborts in C++, taking the whole test process down with it.
/// A hosted CI runner may have no usable Metal device; there these suites
/// skip, saying why. Everywhere else they run on the CPU device: they compare
/// numbers, not speed.
class MLXTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil,
                      "No Metal device: MLX would abort the test process")
    }

    override func invokeTest() {
        // Even `Device.cpu` starts MLX's default (GPU) stream, which aborts
        // with no Metal device — so `setUpWithError` must get to skip first.
        let run = { super.invokeTest() }
        guard MTLCreateSystemDefaultDevice() != nil else { return run() }
        Device.withDefaultDevice(.cpu, run)
        // A load the test let go can still be warming up: the next test's
        // measurements, or MLX's static teardown at exit, must not run under it.
        let deadline = Date() + 10
        while ModelResidency.runningLoads.get() > 0, Date() < deadline { usleep(1000) }
    }
}
