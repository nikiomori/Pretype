import XCTest
@testable import Pretype

/// A settings change rebuilds the engine. The old one is retired — it
/// loads nothing more, so a late request can't build a model next to the
/// new one's — and the new one takes over its caches: the blueprint of the
/// model the two share reaches the new engine's first load (no MLX build
/// leak), and the parsed tokenizers carry over (no re-parse).
final class EngineCoordinatorTests: MLXTestCase {
    @MainActor
    func testARebuildRetiresTheEngineAndHandsItsCachesOn() async throws {
        let saved = Settings.mlxModelID
        defer { Settings.mlxModelID = saved }
        Settings.mlxModelID = "test/tiny"
        try await withScratchHub {
            let seen = LockedValue<[[String]]>([])
            let coordinator = EngineCoordinator { id, previous in
                MLXEngine(modelID: id, after: previous, load: { _, _, blueprints, _, _ in
                    seen.mutate { $0.append(blueprints.get().keys.sorted()) }
                    return try tinyContainer()
                }, shadersPresent: true)
            }
            defer { coordinator.engine.shutdown() }
            let old = try XCTUnwrap(coordinator.engine as? MLXEngine, "the local engine")
            let lease = try XCTUnwrap(old.residency.begin(.completion))
            _ = try await lease.task.value
            old.residency.end(lease)

            coordinator.rebuild()
            let new = try XCTUnwrap(coordinator.engine as? MLXEngine)
            XCTAssertFalse(new === old)
            XCTAssertNil(old.residency.begin(.completion), "the old engine is retired")
            let first = try XCTUnwrap(new.residency.begin(.completion))
            _ = try await first.task.value
            new.residency.end(first)
            XCTAssertEqual(seen.get(), [[], ["test/tiny"]], "the new engine's load finds the old one's blueprint")
            XCTAssertTrue(new.residency.handOver.tokenizers === old.residency.handOver.tokenizers)
        }
    }

    /// A tiny-Gemma engine whose chats land in `chats`.
    private static func tiny(chats: LockedValue<[String]>) -> EngineCoordinator.MakeMLX {
        { id, previous in
            MLXEngine(modelID: id, after: previous, load: { _, _, _, _, _ in try tinyContainer(window: 512, chats: chats) },
                      shadersPresent: true)
        }
    }

    // A model or style change is one write-out and one rebuild, the owner
    // told; length, persona and the gate reach the running engine, no rebuild.
    @MainActor
    func testApplyRebuildsOnceAndTheLiveKnobsReachTheEngine() async throws {
        let saved = (Settings.mlxModelID, Settings.completionStyle, Settings.completionLength, Settings.logprobGate,
                     Settings.useRecommendedSettings, Settings.customInstructions)
        defer {
            (Settings.mlxModelID, Settings.completionStyle, Settings.completionLength, Settings.logprobGate,
             Settings.useRecommendedSettings, Settings.customInstructions) = saved
        }
        (Settings.mlxModelID, Settings.completionStyle, Settings.completionLength, Settings.customInstructions)
            = ("test/tiny", .instruct, .short, "")
        try await withScratchHub {
            let chats = LockedValue<[String]>([])
            let coordinator = EngineCoordinator(makeMLX: Self.tiny(chats: chats))
            defer { coordinator.engine.shutdown() }
            var rebuilds = 0
            coordinator.onRebuild = { rebuilds += 1 }
            let first = coordinator.engine
            let request = CompletionRequest(textBeforeCaret: "Let us meet at the cafe on Monday")

            coordinator.setCustomInstructions("Writes tersely.")
            XCTAssertEqual(Settings.customInstructions, "Writes tersely.")
            _ = try await coordinator.engine.complete(request)
            XCTAssertTrue(chats.get().last?.contains("Writes tersely.") ?? false, "\(chats.get())")
            coordinator.setCompletionLength(.long)
            XCTAssertEqual(Settings.completionLength, .long)
            _ = try await coordinator.engine.complete(request)
            XCTAssertTrue(chats.get().last?.contains("(\(CompletionLength.long.wordsHint))") ?? false, "\(chats.get())")
            XCTAssertTrue(coordinator.engine === first)
            XCTAssertEqual(rebuilds, 0)

            let target = ProjectionConfig(modelID: "test/other", style: .base, length: .medium, logprobGate: true,
                                          useRecommended: false)
            coordinator.apply(target)
            XCTAssertEqual(coordinator.current, target)
            XCTAssertFalse(coordinator.engine === first)
            XCTAssertEqual(rebuilds, 1)

            // The gate and auto mode keep the loaded model: no rebuild, the
            // running engine reads the new gate.
            let second = try XCTUnwrap(coordinator.engine as? MLXEngine)
            XCTAssertEqual(second.logprobGateThreshold, Settings.logprobGateThreshold)
            coordinator.apply(.logprobGate(false))
            XCTAssertNil(second.logprobGateThreshold)
            coordinator.apply(.useRecommended(true))
            XCTAssertEqual(coordinator.current.style, .base)
            XCTAssertTrue(coordinator.engine === second)
            XCTAssertEqual(rebuilds, 1)
        }
    }

    // Which engine the settings build: the API when it is on, Apple
    // Intelligence by its id, else the local model.
    @MainActor
    func testTheEngineFollowsTheSettings() throws {
        let saved = (Settings.mlxModelID, Settings.apiText)
        defer { (Settings.mlxModelID, Settings.apiText) = saved }
        try withScratchHub {
            var api = APIConfig(provider: .custom, kind: .text, enabled: true)
            api.baseURL = "https://llm.example.com/v1"
            api.model = "m"
            Settings.apiText = api
            Settings.mlxModelID = "test/tiny"
            XCTAssertTrue(EngineCoordinator().engine is CloudEngine)
            api.enabled = false
            Settings.apiText = api
            Settings.mlxModelID = ModelCatalog.appleIntelligenceID
            XCTAssertTrue(EngineCoordinator().engine is FoundationModelsEngine)
            Settings.mlxModelID = "test/tiny"
            let local = EngineCoordinator(makeMLX: Self.tiny(chats: LockedValue([])))
            defer { local.engine.shutdown() }
            XCTAssertTrue(local.engine is MLXEngine)
        }
    }
}
