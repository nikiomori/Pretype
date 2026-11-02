import HuggingFace
import MLX
import MLXLMCommon
import XCTest
@testable import Pretype

/// A residency on a tiny Gemma (CPU) with a clock of its own: it records the
/// blueprints each load is handed and counts the loads, and `held` keeps a
/// load in flight — cancellably, unless `stubborn` — until the test lets it
/// finish, and `fetches` records what comes in by `ModelStorage.fetchQuietly`.
private final class TinyResidency {
    let now: LockedValue<Date>
    let blueprintsSeen = LockedValue<[[String]]>([])
    let loads = LockedValue(0)
    let held: LockedValue<Bool>
    let fetches = LockedValue<[(repo: String, sizeHint: Int64)]>([])
    let tokenizers = TokenizerCache { _ in CharTokenizer() }
    let promptCache = MLXEngine.PromptCache()
    let residency: ModelResidency

    /// `failsPrimary`: only the completion model's loads fail. `stubborn`: a
    /// load past its last cancellation point, which lands all the same.
    /// `urlCancel`: a load called off the way the Hub client's URLSession ends.
    init(primaryID: String = "test/tiny-gemma", style: CompletionStyle = .base, fails: Bool = false,
         failsPrimary: Bool = false, hold: Bool = false, stubborn: Bool = false, urlCancel: Bool = false,
         loadPrimary: Bool = true, after previous: TinyResidency? = nil) {
        now = previous?.now ?? LockedValue(Date(timeIntervalSince1970: 1_000_000))
        held = LockedValue(hold)
        let (now, seen, loads, held, fetches) = (now, blueprintsSeen, loads, held, fetches)
        residency = ModelResidency(
            primaryID: primaryID, style: style, promptCache: promptCache, after: previous?.residency,
            load: { _, slot, blueprints, _, _ in
                loads.mutate { $0 += 1 }
                seen.mutate { $0.append(blueprints.get().keys.sorted()) }
                while held.get() {
                    if stubborn {
                        usleep(2_000)
                    } else {
                        do { try await Task.sleep(for: .milliseconds(2)) } catch { throw urlCancel ? URLError(.cancelled) : error }
                    }
                }
                if fails || (failsPrimary && slot.id == primaryID) { throw URLError(.cannotConnectToHost) }
                return try tinyContainer()
            },
            tokenizers: tokenizers, clock: { now.get() },
            fetch: { repo, size in
                fetches.mutate { $0.append((repo, size)) }
                return false
            })
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
            // No load at start: on a busy Mac it fails before `begin` and the
            // first use already sits in the cooldown.
            let tiny = TinyResidency(fails: true, loadPrimary: false), residency = tiny.residency
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
    // off by the idle tick or memory pressure.
    func testAnIdleUnloadNeverCancelsALoadInFlight() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(hold: true), residency = tiny.residency
            defer { residency.shutdown() }
            XCTAssertTrue(residency.isLoading)
            tiny.advance(3_600)
            residency.idleTick(limit: 60)
            residency.relieveMemoryPressure()
            XCTAssertTrue(residency.primaryLoadedOrLoading)
            tiny.held.set(false)
            residency.end(try await tiny.use())
            XCTAssertEqual(residency.state, .ready)
        }
    }

    // A release calls a load off, a request waiting on it included: choosing
    // Words mid-download must not leave gigabytes coming in. Nothing it reports
    // after that reaches the slot, and the next use starts clean — no failure,
    // no cooldown.
    func testAReleaseCallsOffALoad() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(hold: true), residency = tiny.residency
            defer { residency.shutdown() }
            let waiting = try XCTUnwrap(residency.begin(.completion))
            await waitUntil { tiny.loads.get() > 0 }
            residency.releaseNow()
            XCTAssertFalse(residency.primaryLoadedOrLoading)
            XCTAssertFalse(residency.isLoading)
            XCTAssertEqual(residency.state, .preparing("idle — model unloaded"))
            do {
                _ = try await waiting.model()
                XCTFail("no model")
            } catch {
                XCTAssertTrue(error is EngineNotReady, "not a cancellation: a fix would keep its dots spinning")
            }
            residency.end(waiting)
            XCTAssertEqual(residency.state, .preparing("idle — model unloaded"), "a late failure")
            tiny.held.set(false)
            residency.end(try await tiny.use())
            XCTAssertEqual(tiny.loads.get(), 2)
            XCTAssertEqual(residency.state, .ready)
        }
    }

    // The same for a fix model: its status clears, or the app reads busy for
    // good.
    func testAReleaseCallsOffAFixModelsLoad() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            defer { residency.shutdown() }
            residency.end(try await tiny.use())
            tiny.held.set(true)
            let waiting = try XCTUnwrap(residency.begin(.fix))
            XCTAssertTrue(residency.isLoading)
            residency.releaseNow()
            XCTAssertFalse(residency.isLoading)
            XCTAssertNil(residency.loadedRepos.primary, "a release frees everything")
            XCTAssertNil(residency.loadedRepos.sibling)
            _ = await waiting.task.result
            residency.end(waiting)
        }
    }

    // The Hub client's URLSession ends a called-off download with its own
    // error: to whoever waits that is no model all the same, not a failure.
    func testACalledOffDownloadIsNoModelToItsWaiter() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(hold: true, urlCancel: true), residency = tiny.residency
            defer { residency.shutdown() }
            let waiting = try XCTUnwrap(residency.begin(.completion))
            await waitUntil { tiny.loads.get() > 0 }
            residency.releaseNow()
            do {
                _ = try await waiting.model()
                XCTFail("no model")
            } catch {
                XCTAssertTrue(error is EngineNotReady, "\(error)")
            }
            residency.end(waiting)
        }
    }

    // A model switch mid-load: the replacing engine's first load waits out the
    // one its predecessor called off, as a load in the same slot does — and
    // finds the blueprint that load leaves.
    func testAReplacementWaitsForALoadCalledOffBeforeIt() async throws {
        try await inScratchHub {
            let old = TinyResidency(hold: true, stubborn: true)
            await waitUntil { old.loads.get() > 0 }
            old.residency.shutdown()
            let new = TinyResidency(after: old)
            defer { new.residency.shutdown() }
            old.held.set(false)
            new.residency.end(try await new.use())
            XCTAssertEqual(new.blueprintsSeen.get(), [["test/tiny-gemma"]])
        }
    }

    // The fix model's load shows while it runs and then simply goes away: the
    // primary's own state, whatever it became meanwhile, shows through (a
    // snapshot/restore once pinned "loading…" over a ready model).
    func testEngineLoadingIgnoresAFinishedFixModel() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(hold: true), residency = tiny.residency
            defer { residency.shutdown() }
            XCTAssertTrue(residency.isLoading, "the primary's own load")
            tiny.held.set(false)
            residency.end(try await tiny.use())
            XCTAssertFalse(residency.isLoading)

            tiny.held.set(true)
            let fix = try XCTUnwrap(residency.begin(.fix))
            XCTAssertTrue(residency.isLoading)
            XCTAssertEqual(residency.state, .preparing("loading fix model…"))
            tiny.held.set(false)
            _ = try await fix.task.value
            residency.end(fix)
            XCTAssertFalse(residency.isLoading, "a finished fix model")
            XCTAssertEqual(residency.state, .ready)

            // The idle-unloaded resting state, with a fix model and without.
            tiny.advance(3_600)
            residency.relieveMemoryPressure()
            XCTAssertFalse(residency.isLoading)
            XCTAssertEqual(residency.state, .preparing("idle — model unloaded"))
            residency.end(try await tiny.use(.fix))
            XCTAssertFalse(residency.isLoading)
            XCTAssertEqual(residency.state, .preparing("idle — model unloaded"))

            let failed = TinyResidency(fails: true)
            defer { failed.residency.shutdown() }
            await waitUntil { if case .failed = failed.residency.state { true } else { false } }
            XCTAssertFalse(failed.residency.isLoading)
        }
    }

    // A load past its last cancellation point lands anyway. The model goes,
    // and no second one builds beside it: the next load waits, and finds the
    // blueprint a load dropped bare would have taken with it (`keepBlueprint`).
    func testALoadCalledOffAsItLandsLeavesItsBlueprint() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(hold: true, stubborn: true), residency = tiny.residency
            defer { residency.shutdown() }
            await waitUntil { tiny.loads.get() > 0 }
            residency.releaseNow()
            let next = try XCTUnwrap(residency.begin(.completion))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(tiny.loads.get(), 1, "a second model building beside the first")
            tiny.held.set(false)
            _ = try await next.task.value
            residency.end(next)
            XCTAssertEqual(tiny.loads.get(), 2)
            XCTAssertEqual(tiny.blueprintsSeen.get().last, ["test/tiny-gemma"])
            XCTAssertEqual(residency.state, .ready)
        }
    }

    // A download holds up only its own slot: the resident primary still goes
    // on the idle timer and under memory pressure while the fix model comes
    // in, a request waiting on it included — and the load lands untouched.
    func testASiblingsLoadDoesNotPinThePrimary() async throws {
        try await inScratchHub {
            for free in [{ (tiny: TinyResidency) in tiny.residency.idleTick(limit: 60) },
                         { (tiny: TinyResidency) in tiny.residency.relieveMemoryPressure() }] {
                let tiny = TinyResidency(), residency = tiny.residency
                defer { residency.shutdown() }
                residency.end(try await tiny.use())
                tiny.held.set(true)
                let fix = try XCTUnwrap(residency.begin(.fix))
                tiny.advance(3_600)
                free(tiny)
                XCTAssertFalse(residency.primaryLoadedOrLoading)
                XCTAssertTrue(residency.isLoading, "the fix model's load stays")
                XCTAssertNotEqual(residency.state, .preparing("idle — model unloaded"), "the fix model's status shows")
                tiny.held.set(false)
                _ = try await fix.task.value
                residency.end(fix)
                XCTAssertNotNil(residency.loadedRepos.sibling)
            }
        }
    }

    // And the other way round: a primary downloading doesn't pin a resident
    // fix model, whose status stays out of the primary's "loading…".
    func testAPrimarysLoadDoesNotPinTheSibling() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(loadPrimary: false), residency = tiny.residency
            defer { residency.shutdown() }
            residency.end(try await tiny.use(.fix))
            tiny.held.set(true)
            residency.prewarm(.completion)
            tiny.advance(3_600)
            residency.idleTick(limit: 60)
            XCTAssertNil(residency.loadedRepos.sibling)
            XCTAssertEqual(residency.state, .preparing("loading…"))
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
            await waitUntil { residency.state == .ready }
            residency.idleTick(limit: 60)
            XCTAssertTrue(residency.primaryLoadedOrLoading, "loaded just now")
            tiny.advance(61)
            residency.idleTick(limit: 60)
            XCTAssertFalse(residency.primaryLoadedOrLoading, "unused past the limit")
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
            let fix = try XCTUnwrap(residency.begin(.fix))
            XCTAssertTrue(residency.isLoading)
            tiny.advance(3_600)
            residency.idleTick(limit: 60)
            tiny.held.set(false)
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

    // A fix model not on disk comes in by the road every download nobody
    // clicked for takes, sized for its own weights, not by a load: that is
    // what checks the network and the disk. Not with a load already bringing
    // it in, nor where no model can ever load.
    func testPrewarmingAFixModelNotOnDiskFetchesItQuietly() async throws {
        try await inScratchHub {
            let tiny = TinyResidency(), residency = tiny.residency
            residency.end(try await tiny.use())
            residency.prewarm(.fix)
            await waitUntil { !tiny.fetches.get().isEmpty }
            let fix = try XCTUnwrap(ModelCatalog.option(for: ModelCatalog.options[0].id)?.correctionModelID)
            XCTAssertEqual(tiny.fetches.get().first?.repo, ModelCatalog.repo(for: fix))
            XCTAssertEqual(tiny.fetches.get().first?.sizeHint, 5_560_000_000)
            XCTAssertEqual(tiny.loads.get(), 1, "a load has no room check")

            tiny.held.set(true)
            let waiting = try XCTUnwrap(residency.begin(.fix))
            residency.prewarm(.fix)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(tiny.fetches.get().count, 1, "two downloaders in one repo fail each other")
            tiny.held.set(false)
            _ = try await waiting.task.value
            residency.end(waiting)

            let retired = TinyResidency(), gone = retired.residency
            gone.shutdown()
            gone.prewarm(.fix)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(retired.fetches.get().isEmpty, "this engine can't use it")
            residency.shutdown()
        }
    }

    // A size for every fix model a catalog entry loads: without one, the room
    // check would ask for the 2 GB margin alone.
    func testEveryFixModelHasASize() {
        for option in ModelCatalog.options where option.id != ModelCatalog.appleIntelligenceID {
            XCTAssertNotNil(ModelMetrics.taskRamGB(for: option.correctionModelID), option.correctionModelID)
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
            // Held: a load that fails at once may land, and start its
            // cooldown, before the lease is taken.
            let tiny = TinyResidency(failsPrimary: true, hold: true), residency = tiny.residency
            defer { residency.shutdown() }
            let failed = try XCTUnwrap(residency.begin(.completion))
            tiny.held.set(false)
            _ = try? await failed.task.value
            residency.end(failed)
            residency.end(try await tiny.use(.fix))
            residency.releaseNow()
            XCTAssertEqual(residency.state, .failed(URLError(.cannotConnectToHost).localizedDescription))
        }
    }
}
