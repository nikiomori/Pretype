import HuggingFace
import MLX
import MLXLMCommon
import XCTest
@testable import Pretype

/// A residency on a tiny Gemma (CPU) with a clock of its own: it records the
/// blueprints each load is handed and counts the loads, and `held` keeps a
/// load in flight — cancellably — until the test lets it finish.
private final class TinyResidency {
    let now: LockedValue<Date>
    let blueprintsSeen = LockedValue<[[String]]>([])
    let loads = LockedValue(0)
    let held: LockedValue<Bool>
    let tokenizers = TokenizerCache { _ in CharTokenizer() }
    let promptCache = MLXEngine.PromptCache()
    let residency: ModelResidency

    /// `failsPrimary`: only the completion model's loads fail.
    init(primaryID: String = "test/tiny-gemma", style: CompletionStyle = .base, fails: Bool = false,
         failsPrimary: Bool = false, hold: Bool = false, loadPrimary: Bool = true, after previous: TinyResidency? = nil) {
        now = previous?.now ?? LockedValue(Date(timeIntervalSince1970: 1_000_000))
        held = LockedValue(hold)
        let (now, seen, loads, held) = (now, blueprintsSeen, loads, held)
        residency = ModelResidency(
            primaryID: primaryID, style: style, promptCache: promptCache, after: previous?.residency,
            load: { _, slot, blueprints, _, _ in
                loads.mutate { $0 += 1 }
                seen.mutate { $0.append(blueprints.get().keys.sorted()) }
                while held.get() { try await Task.sleep(for: .milliseconds(2)) }
                if fails || (failsPrimary && slot.id == primaryID) { throw URLError(.cannotConnectToHost) }
                return try tinyContainer()
            },
            tokenizers: tokenizers, clock: { now.get() })
        residency.start(loadPrimary: loadPrimary)
    }

    func use(_ role: ModelResidency.Role = .completion) async throws -> ModelResidency.Lease {
        let lease = try XCTUnwrap(residency.begin(role))
        _ = try await lease.task.value
        return lease
    }

    func advance(_ seconds: TimeInterval) { now.mutate { $0 += seconds } }
}

/// What is in memory and for how long: leases, releases, memory pressure,
/// the idle timer, failed and called-off loads, and the hand-over to the
/// engine that replaces this one — on a tiny Gemma, on the CPU.
final class ModelResidencyTests: MLXTestCase {
    /// A scratch Hugging Face cache and the CPU device for `body`.
    private func inScratchHub(_ body: () async throws -> Void) async throws {
        let root = try TinyGemma.scratch("hub")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Device.withDefaultDevice(.cpu) {
            try await ModelStorage.$hub.withValue(HubCache(cacheDirectory: root), operation: body)
        }
    }

    /// A complete (if bogus) snapshot of `repo` in the current hub.
    private func download(_ repo: String) throws {
        let directory = try folder(of: repo)
        for file in ["config.json", "tokenizer.json", "model.safetensors"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(file))
        }
    }

    private func folder(of repo: String) throws -> URL {
        let directory = try XCTUnwrap(ModelStorage.cacheDirectory(repo: repo)).appendingPathComponent("snapshots/rev")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // No suggestion asks the completion model: it never loads and reads as
    // resting, not loading — and a fix still loads its own model on first use.
    func testWithoutCompletionsOnlyAFixLoadsAModel() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(loadPrimary: false)
            XCTAssertEqual(tiny.loads.get(), 0)
            XCTAssertFalse(tiny.residency.isLoading)
            let lease = try await tiny.use(.fix)
            tiny.residency.end(lease)
            XCTAssertEqual(tiny.loads.get(), 1)
            XCTAssertNil(tiny.residency.loadedRepos.primary)
            XCTAssertNotNil(tiny.residency.loadedRepos.sibling)
        }
    }

    // A lease holds the model through a release, which drops the KV
    // snapshots and keeps a blueprint for the next load. Memory pressure
    // drops the blueprints whatever the models' state, idle-unloaded
    // included, and the models once unused for 3 s. It drops the parsed
    // tokenizers too, but a resident model's: that one is held by the model
    // anyway, and dropping it cost a re-parse on the way back. Only a
    // pressure that freed the completion model puts Words in its place.
    func testResidencyLeasesAndMemoryPressure() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            let first = try await tiny.use(), second = try await tiny.use()
            XCTAssertEqual(residency.state, .ready)
            let tokens = Array(0 ..< 40)
            let kv = KVCacheSimple()
            kv.offset = 40
            tiny.promptCache.store(forFullTokens: tokens, live: .init(tokens: tokens, cache: [kv]), checkpoint: nil)
            residency.end(first)
            residency.releaseNow()
            XCTAssertTrue(residency.primaryLoadedOrLoading, "a lease is still out")
            residency.end(second)
            residency.releaseNow()
            XCTAssertFalse(residency.primaryLoadedOrLoading)
            XCTAssertEqual(residency.state, .preparing("idle — model unloaded"))
            XCTAssertNil(tiny.promptCache.take(for: tokens), "a release drops the KV snapshots")

            residency.end(try await tiny.use())
            XCTAssertEqual(tiny.blueprintsSeen.get().last, ["test/tiny-gemma"], "the reload finds the release's blueprint")
            let resident = try folder(of: "test/tiny-gemma"), other = try folder(of: "test/other")
            for directory in [resident, other] { _ = try await tiny.tokenizers.load(from: directory) }
            XCTAssertFalse(residency.relieveMemoryPressure(), "freed nothing: Words stays out")
            XCTAssertTrue(residency.primaryLoadedOrLoading, "used a moment ago")
            XCTAssertEqual(tiny.tokenizers.directories, [resident], "keeps the resident model's tokenizer only")
            tiny.advance(10)
            XCTAssertTrue(residency.relieveMemoryPressure(), "freed the completion model: Words stands in")
            XCTAssertFalse(residency.primaryLoadedOrLoading)
            XCTAssertTrue(tiny.tokenizers.directories.isEmpty, "nothing resident, nothing kept")
            residency.end(try await tiny.use())
            XCTAssertEqual(tiny.blueprintsSeen.get().last, [], "pressure unloads without a blueprint")

            tiny.advance(10)
            residency.releaseNow()
            XCTAssertFalse(residency.relieveMemoryPressure(), "already idle-unloaded")
            residency.end(try await tiny.use())
            XCTAssertEqual(tiny.blueprintsSeen.get().last, [], "pressure on an idle-unloaded model kept its blueprint")
        }
    }

    // A dictation prewarms the fix model it will tidy up with; on a model
    // already loaded that is still a use, or the idle timer could free it
    // mid-dictation. A focus change's prewarm of the completion model is no
    // use: it would keep a model nobody types into resident.
    func testWhichPrewarmCountsAsUse() async throws {
        try await inScratchHub {
            let fix = TinyResidency(style: .instruct)
            defer { fix.residency.shutdown() }
            fix.residency.end(try await fix.use(.fix))
            fix.advance(100)
            fix.residency.prewarm(.fix)
            fix.advance(1)
            fix.residency.relieveMemoryPressure()
            XCTAssertTrue(fix.residency.primaryLoadedOrLoading, "freed a second after the dictation asked for it")

            let focus = TinyResidency()
            defer { focus.residency.shutdown() }
            focus.residency.end(try await focus.use())
            focus.advance(100)
            focus.residency.prewarm(.completion)
            focus.advance(1)
            focus.residency.relieveMemoryPressure()
            XCTAssertFalse(focus.residency.primaryLoadedOrLoading, "a focus change kept an unused model")
        }
    }

    // A failed load names no repo, and holds off the next one for the
    // primary's cooldown: offline, a retry per keystroke would hit the Hub
    // every time.
    func testAFailedLoadCoolsDown() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(fails: true), residency = tiny.residency
            defer { residency.shutdown() }
            let lease = try XCTUnwrap(residency.begin(.completion))
            do {
                _ = try await lease.task.value
                XCTFail("the load was meant to fail")
            } catch {}
            residency.end(lease)
            XCTAssertNil(residency.loadedRepos.primary)
            XCTAssertEqual(residency.state, .failed(URLError(.cannotConnectToHost).localizedDescription))
            tiny.advance(10)
            XCTAssertNil(residency.begin(.completion), "retried inside the cooldown")
            XCTAssertEqual(tiny.loads.get(), 1)
            tiny.advance(25)
            let retry = try XCTUnwrap(residency.begin(.completion))
            _ = try? await retry.task.value
            residency.end(retry)
            XCTAssertEqual(tiny.loads.get(), 2)
        }
    }

    // A load in flight — a first download can take minutes — is never cut
    // off by an unload: not the idle tick's, not a manual one.
    func testAnUnloadNeverCancelsALoadInFlight() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(hold: true), residency = tiny.residency
            defer { residency.shutdown() }
            XCTAssertTrue(residency.isLoading)
            residency.releaseNow()
            tiny.advance(3_600)
            residency.idleTick(limit: 60)
            XCTAssertTrue(residency.primaryLoadedOrLoading)
            tiny.held.set(false)
            residency.end(try await tiny.use())
            XCTAssertEqual(residency.state, .ready)
        }
    }

    // A finished load is a use: the idle clock starts at "ready", not when
    // a download that can take minutes began.
    func testAFinishedLoadCountsAsUse() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(hold: true), residency = tiny.residency
            defer { residency.shutdown() }
            tiny.advance(3_600)
            tiny.held.set(false)
            while residency.state != .ready { try await Task.sleep(for: .milliseconds(2)) }
            residency.idleTick(limit: 60)
            XCTAssertTrue(residency.primaryLoadedOrLoading, "loaded just now")
            tiny.advance(61)
            residency.idleTick(limit: 60)
            XCTAssertFalse(residency.primaryLoadedOrLoading, "unused past the limit")
        }
    }

    // A load called off — the engine retired mid-load — is no failure: a
    // re-pack marked failed falls back to the original build for the launch.
    func testACalledOffLoadIsNoFailure() async throws {
        try await inScratchHub {
            let id = "mlx-community/gemma-4-e2b-4bit", repo = ModelCatalog.repo(for: id)
            XCTAssertEqual(repo, "nikimori/gemma-4-e2b-4bit-slim")
            let tiny = TinyResidency(primaryID: id, hold: true), residency = tiny.residency
            let lease = try XCTUnwrap(residency.begin(.completion))
            residency.shutdown()
            _ = try? await lease.task.value
            XCTAssertFalse(ModelStorage.loadFailed(repo: repo))
            XCTAssertNil(residency.loadedRepos.primary)
        }
    }

    // A request's end is a use: a first download can outlast the idle
    // limit, and the model it brought must not go the moment it answers.
    func testARequestsEndCountsAsUse() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            let lease = try await tiny.use()
            tiny.advance(3_600)
            residency.idleTick(limit: 60)
            XCTAssertTrue(residency.primaryLoadedOrLoading, "never under a request")
            residency.end(lease)
            residency.idleTick(limit: 60)
            XCTAssertTrue(residency.primaryLoadedOrLoading, "used just now")
            tiny.advance(61)
            residency.idleTick(limit: 60)
            XCTAssertFalse(residency.primaryLoadedOrLoading, "unused past the limit")
        }
    }

    // A fix model that loaded is on disk, whatever the disk probe said, and
    // stays known as such through an unload: the next tidy-up must not be
    // skipped as "not fetched".
    func testALoadedFixModelIsReadyForTheNextFix() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            XCTAssertFalse(residency.isCorrectionReady)
            residency.end(try await tiny.use(.fix))
            residency.releaseNow()
            XCTAssertTrue(residency.isCorrectionReady)
        }
    }

    // The minute-idle trim keeps the newest KV snapshot only.
    func testTheIdleTrimKeepsTheNewestSnapshot() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            residency.end(try await tiny.use())
            func snapshot(_ tokens: [Int]) {
                let kv = KVCacheSimple()
                kv.offset = tokens.count
                tiny.promptCache.store(forFullTokens: tokens, live: .init(tokens: tokens, cache: [kv]), checkpoint: nil)
            }
            let older = Array(0 ..< 40), newer = Array(100 ..< 140)
            snapshot(older)
            snapshot(newer)
            tiny.advance(61)
            residency.idleTick(limit: 0)
            XCTAssertTrue(residency.primaryLoadedOrLoading, "\"never unload\" still trims, and only trims")
            XCTAssertNil(tiny.promptCache.take(for: older))
            XCTAssertNotNil(tiny.promptCache.take(for: newer))
        }
    }

    // Retired, an engine hands its blueprints to the one replacing it — but
    // not mid-request (a Qwen3.5 husk would be emptied under the running
    // generation), and the replacement keeps only those of its own models.
    func testTheHandOverKeepsOnlyUsableBlueprints() async throws {
        try await inScratchHub {
            let busy = TinyResidency()
            let lease = try await busy.use()
            busy.residency.shutdown()
            busy.residency.end(lease)
            let afterBusy = TinyResidency(after: busy)
            defer { afterBusy.residency.shutdown() }
            afterBusy.residency.end(try await afterBusy.use())
            XCTAssertEqual(afterBusy.blueprintsSeen.get().first, [], "a blueprint taken mid-request")

            let loading = TinyResidency(hold: true)
            loading.residency.shutdown()
            XCTAssertEqual(loading.residency.handOver.blueprints.get().keys.sorted(), [], "a blueprint of a load called off")

            let idle = TinyResidency()
            idle.residency.end(try await idle.use())
            idle.residency.shutdown()
            let same = TinyResidency(after: idle)
            defer { same.residency.shutdown() }
            same.residency.end(try await same.use())
            XCTAssertEqual(same.blueprintsSeen.get().first, ["test/tiny-gemma"], "the same model's blueprint carries over")

            let other = TinyResidency(primaryID: "test/a")
            other.residency.end(try await other.use())
            other.residency.releaseNow()
            let switched = TinyResidency(primaryID: "test/b", after: other)
            defer { switched.residency.shutdown() }
            switched.residency.end(try await switched.use())
            XCTAssertEqual(switched.blueprintsSeen.get().first, [], "another model's blueprint")
        }
    }

    // The fix sibling idles on its own clock while completions keep the
    // primary busy — but a fix model still loading, a first ⌥⇥'s download,
    // is never cut off by it.
    func testTheSiblingsIdleUnloadSparesALoadInFlight() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            let typing = try await tiny.use()
            tiny.held.set(true)
            residency.prewarm(.fix)
            XCTAssertTrue(residency.isLoading)
            tiny.advance(3_600)
            residency.idleTick(limit: 60)
            tiny.held.set(false)
            let fix = try XCTUnwrap(residency.begin(.fix))
            _ = try await fix.task.value
            residency.end(fix)
            residency.end(typing)
            XCTAssertEqual(tiny.loads.get(), 2, "the idle tick cancelled the fix model's load")
        }
    }

    // The fix sibling idles on its own clock while a completion keeps the
    // primary busy: kept while used within the limit, freed past it.
    func testTheSiblingIdlesOnItsOwnClock() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            let typing = try await tiny.use()
            residency.end(try await tiny.use(.fix))
            let sibling = try XCTUnwrap(residency.loadedRepos.sibling)
            tiny.advance(30)
            residency.idleTick(limit: 60)
            XCTAssertEqual(residency.loadedRepos.sibling, sibling, "used 30 s ago")
            tiny.advance(31)
            residency.idleTick(limit: 60)
            XCTAssertNil(residency.loadedRepos.sibling, "unused past the limit")
            XCTAssertNotNil(residency.loadedRepos.primary, "the busy primary stays")
            residency.end(typing)
        }
    }

    // A retired residency loads nothing more: a late request or prewarm
    // would build a whole model next to the replacement's.
    func testARetiredResidencyLoadsNothing() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            residency.end(try await tiny.use())
            residency.shutdown()
            XCTAssertNil(residency.begin(.completion))
            XCTAssertNil(residency.begin(.fix))
            residency.prewarm(.completion)
            residency.prewarm(.fix)
            XCTAssertEqual(tiny.loads.get(), 1)
        }
    }

    // Which model serves a fix is read from the weights each one holds, not
    // from what the disk resolves now: Qwen3.5 Base on an old install runs on
    // the post-trained 4-bit — its fix sibling's weights — and the 6-bit
    // build landing meanwhile must not send the next ⌥⇥ to a second copy.
    func testTheFixModelIsTheOneHoldingTheWeights() async throws {
        try await inScratchHub {
            try download("mlx-community/Qwen3.5-2B-4bit")
            let tiny = TinyResidency(primaryID: "nikimori/Qwen3.5-2B-Base-6bit"), residency = tiny.residency
            defer { residency.shutdown() }
            residency.end(try await tiny.use())
            XCTAssertEqual(residency.loadedRepos.primary, "mlx-community/Qwen3.5-2B-4bit")
            try download("nikimori/Qwen3.5-2B-Base-6bit")
            residency.end(try await tiny.use(.fix))
            XCTAssertEqual(tiny.loads.get(), 1, "a second copy of the weights the primary holds")
        }
    }

    // A focus change reloads an idle-unloaded model, hiding the reload.
    func testAPrewarmReloadsAnIdleUnloadedModel() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            residency.end(try await tiny.use())
            residency.releaseNow()
            XCTAssertFalse(residency.primaryLoadedOrLoading)
            residency.prewarm(.completion)
            XCTAssertTrue(residency.primaryLoadedOrLoading)
            residency.end(try await tiny.use())
            XCTAssertEqual(tiny.loads.get(), 2)
        }
    }

    // A fix costs at most a load once its model is on disk, never before;
    // the answer, once true, is kept without another directory read.
    func testTheFixModelIsReadyOnceOnDisk() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            let fixID = try XCTUnwrap(ModelCatalog.option(for: ModelCatalog.options[0].id)?.correctionModelID)
            XCTAssertFalse(residency.isCorrectionReady)
            XCTAssertFalse(residency.isCorrectionReady, "asked twice")
            try download(fixID)
            XCTAssertTrue(residency.isCorrectionReady)
            try FileManager.default.removeItem(at: try folder(of: fixID))
            XCTAssertTrue(residency.isCorrectionReady, "kept once true")
        }
    }

    // A download's status line: the bytes so far once the total is known —
    // a multi-GB model otherwise sits at "0%" for minutes — else the percent.
    func testTheDownloadStatusShowsTheBytesOnceKnown() {
        let sized = Progress(totalUnitCount: 2_000_000_000)
        sized.completedUnitCount = 500_000_000
        XCTAssertTrue(ModelResidency.downloadStatus(sized).contains("/"), ModelResidency.downloadStatus(sized))
        XCTAssertTrue(ModelResidency.downloadStatus(sized, fixModel: true).contains("/"))
        let unsized = Progress(totalUnitCount: 0)
        XCTAssertFalse(ModelResidency.downloadStatus(unsized).contains("/"), ModelResidency.downloadStatus(unsized))
        XCTAssertFalse(ModelResidency.downloadStatus(unsized, fixModel: true).contains("/"))
        XCTAssertNotEqual(ModelResidency.downloadStatus(sized), ModelResidency.downloadStatus(sized, fixModel: true))
    }

    // A failed primary stays on screen as failed: freeing a fix model that
    // loaded on its own must not paint "idle" over the reason.
    func testAnUnloadKeepsAFailureOnScreen() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(failsPrimary: true), residency = tiny.residency
            defer { residency.shutdown() }
            let failed = try XCTUnwrap(residency.begin(.completion))
            _ = try? await failed.task.value
            residency.end(failed)
            residency.end(try await tiny.use(.fix))
            residency.releaseNow()
            XCTAssertEqual(residency.state, .failed(URLError(.cannotConnectToHost).localizedDescription))
        }
    }
}
