import HuggingFace
import XCTest
@testable import Pretype

/// An app update that changes which build a pick runs on must never turn into
/// a forced download, a dead engine offline, or a deleted build that worked.
final class ModelUpgradeTests: XCTestCase {
    // Qwen3.5's pick moved to its Base build (10-11), then to 6-bit (10-14): an
    // install holding only an older build keeps completing on the newest one
    // it has until the 6-bit build is here.
    func testPreviousBuildServesUntilTheNewOneIsFetched() throws {
        let id = "nikimori/Qwen3.5-2B-Base-6bit"
        let base4 = "nikimori/Qwen3.5-2B-Base-4bit"
        let old = "mlx-community/Qwen3.5-2B-4bit"
        XCTAssertEqual(ModelCatalog.previousBuilds[id], [base4, old])
        for (have, expected) in [([String](), id), ([old], old), ([old, base4], base4),
                                 ([old, base4, id], id), ([id], id)] {
            XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: have.contains), expected, "\(have)")
        }
        // The post-trained build is still the entry's ⌥⇥ sibling, so the
        // upgrade pass keeps it; the Base 4-bit is no sibling and goes once the
        // 6-bit has loaded. Both count as the entry's while on disk.
        XCTAssertEqual(ModelCatalog.option(for: id)?.correctionModelID, old)
        XCTAssertTrue(try withScratchHub { ModelStorage.repos(for: id) }.isSuperset(of: [id, base4, old]))
        // A stored pick of an old id is rewritten at launch — safe only
        // because of the fallback above; the old ids are no catalog entries.
        XCTAssertNil(ModelCatalog.options.first { $0.id == old || $0.id == base4 })
    }

    // MiniCPM5 moved to our 8-bit build (10-15): the hub bf16 keeps serving
    // until it's fetched, then goes — the chords ride Qwen3.5's sibling, so
    // the bf16 is no sibling to keep.
    func testMiniCPMServesBF16UntilEightBitIsFetched() throws {
        let id = "nikimori/MiniCPM5-1B-Base-8bit"
        let bf16 = "openbmb/MiniCPM5-1B-Base"
        XCTAssertEqual(ModelCatalog.previousBuilds[id], [bf16])
        for (have, expected) in [([String](), id), ([bf16], bf16), ([bf16, id], id)] {
            XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: have.contains), expected, "\(have)")
        }
        let option = ModelCatalog.option(for: id)
        XCTAssertFalse([option?.correctionModelID, option?.instructModelID].contains(bf16))
        XCTAssertTrue(try withScratchHub { ModelStorage.repos(for: id) }.contains(bf16))
        XCTAssertNotNil(ModelCatalog.pinnedRevisions[id])
    }

    // The memory ladder moving on (a re-tier, or a Mac with more memory) must
    // not swap the model before the new default is here.
    func testMovedDefaultKeepsTheOldOneServingUntilFetched() {
        withLadderKeys {
            let ladder = ModelCatalog.defaultID
            let old = ModelCatalog.options.map(\.id).first { $0 != ladder }!
            let defaults = Settings.store
            // First launch with the ladder: seeded with today's default.
            Settings.migrate(isFetched: { _ in true })
            XCTAssertEqual(Settings.autoModelID, ladder)
            XCTAssertNil(Settings.pendingDefault)

            // An install the ladder put on `old`: kept, in old's own style.
            Settings.autoModelID = old
            Settings.migrate(isFetched: { _ in true })
            XCTAssertEqual(defaults.string(forKey: "mlxModelID"), old)
            XCTAssertEqual(Settings.completionStyle, ModelCatalog.recommended(for: old).style)
            XCTAssertEqual(Settings.pendingDefault, ladder)
            // The switch (`AppDelegate`) moves the ladder pick along.
            Settings.autoModelID = ladder
            XCTAssertNil(Settings.pendingDefault)

            // Nothing of old's on disk: take the new default now.
            for key in ["mlxModelID", "completionStyle"] { defaults.removeObject(forKey: key) }
            Settings.autoModelID = old
            Settings.migrate(isFetched: { _ in false })
            XCTAssertNil(defaults.string(forKey: "mlxModelID"))
            XCTAssertEqual(Settings.autoModelID, ladder)

            // A pick of the user's own stops following.
            Settings.autoModelID = old
            Settings.mlxModelID = ModelCatalog.options.map(\.id).first { $0 != ladder && $0 != old }!
            XCTAssertNil(Settings.pendingDefault)
            Settings.migrate(isFetched: { _ in true })
            XCTAssertEqual(Settings.autoModelID, ladder)
            XCTAssertNil(Settings.pendingDefault)

            // A ladder pick whose build changed follows the build first.
            defaults.removeObject(forKey: "mlxModelID")
            Settings.autoModelID = "openbmb/MiniCPM5-1B-Base"
            Settings.migrate(isFetched: { _ in true })
            XCTAssertEqual(Settings.autoModelID, "nikimori/MiniCPM5-1B-Base-8bit")
            XCTAssertEqual(defaults.string(forKey: "mlxModelID"), "nikimori/MiniCPM5-1B-Base-8bit")
        }
    }

    /// Runs `body` with the ladder's keys cleared, restoring them after.
    private func withLadderKeys(_ body: () -> Void) {
        let defaults = Settings.store
        let keys = ["mlxModelID", "autoModelID", "completionStyle"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach(defaults.removeObject(forKey:))
        body()
    }

    // A replacement that fails to load counts as absent for the rest of the
    // launch, so the engine's retry resolves the original still on disk.
    func testFailedReplacementFallsBackToTheOriginal() {
        let id = "mlx-community/gemma-4-e2b-4bit"
        let slim = "nikimori/gemma-4-e2b-4bit-slim"
        let have: Set = [id, slim]
        let isFetched = { (repo: String) in have.contains(repo) && !ModelStorage.loadFailed(repo: repo) }
        XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: isFetched), slim)
        ModelStorage.noteLoad(repo: slim, succeeded: true)  // a load on an earlier launch
        XCTAssertTrue(ModelStorage.hasLoaded(repo: slim))
        ModelStorage.noteLoad(repo: slim, succeeded: false)
        defer { ModelStorage.noteLoad(repo: slim, succeeded: true) }
        XCTAssertTrue(ModelStorage.loadFailed(repo: slim))
        XCTAssertFalse(ModelStorage.hasLoaded(repo: slim),
                       "an earlier launch's load must not license deleting the build in use now")
        XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: isFetched), id)
        // Originals are never marked: there is nothing behind them to fall back to.
        ModelStorage.noteLoad(repo: id, succeeded: false)
        XCTAssertFalse(ModelStorage.loadFailed(repo: id))
    }

    /// `upgradeToSlim` is the only code that deletes weights on its own. A
    /// previous build some entry still runs ⌥⇥ or Instruct on must never be in
    /// its delete list, whichever entry names it.
    func testUpgradeNeverDeletesABuildAChordStillLoads() {
        let siblings = Set(ModelCatalog.options.flatMap { [$0.correctionModelID, $0.instructModelID] })
        for pair in ModelStorage.upgradePairs where ModelCatalog.previousBuilds[pair.slim] != nil {
            XCTAssertEqual(pair.keepOriginal, siblings.contains(pair.original), pair.original)
        }
        // As Qwen3.5 Base's previous build it stays (MiniCPM5's and Qwen3.5's
        // chords load it); only its own re-pack replaces it — and only once
        // the primary no longer falls back to it (below).
        let qwen = ModelStorage.upgradePairs.filter { $0.original == "mlx-community/Qwen3.5-2B-4bit" }
        XCTAssertEqual(qwen.first { $0.slim == "nikimori/Qwen3.5-2B-Base-6bit" }?.keepOriginal, true)
        XCTAssertEqual(qwen.first { $0.slim == "nikimori/Qwen3.5-2B-4bit-slim" }?.keepOriginal, false)
        let base4 = ModelStorage.upgradePairs.first { $0.original == "nikimori/Qwen3.5-2B-Base-4bit" }
        XCTAssertEqual(base4?.keepOriginal, false)
    }

    /// An old 8 GB install holding only Qwen3.5's post-trained 4-bit: one pass
    /// fetched the slim re-pack, a ⌥⇥ loaded it, the 6-bit fetch was declined.
    /// The original is still the primary, so the next pass must keep it.
    func testUpgradeKeepsAnOriginalThatStillServesAsAPreviousBuild() {
        let id = "nikimori/Qwen3.5-2B-Base-6bit"
        let old = "mlx-community/Qwen3.5-2B-4bit"
        let slim = "nikimori/Qwen3.5-2B-4bit-slim"
        func resolving(_ onDisk: [String]) -> (String) -> String {
            { ModelCatalog.repo(for: $0, isFetched: onDisk.contains) }
        }
        XCTAssertTrue(ModelStorage.stillServes(old, selected: id, resolve: resolving([old, slim])))
        // Once the 6-bit build is usable (on disk and loaded once), the re-pack
        // alone stands in for the original.
        XCTAssertFalse(ModelStorage.stillServes(old, selected: id, resolve: resolving([old, slim, id])))
        // MiniCPM5 borrows only the chord sibling, which the re-pack serves.
        XCTAssertFalse(ModelStorage.stillServes(
            old, selected: "nikimori/MiniCPM5-1B-Base-8bit", resolve: resolving([old, slim])))
        // Every slim original that is also a previous build stays while its new build is missing.
        for (new, olds) in ModelCatalog.previousBuilds {
            for original in olds {
                guard let repack = ModelCatalog.slimRepos[original] else { continue }
                XCTAssertTrue(ModelStorage.stillServes(original, selected: new, resolve: resolving([original, repack])), original)
            }
        }
    }

    /// The real upgrade pass on a scratch cache — the delete loop and the
    /// `hasLoaded` rule (`!loadFailed && persisted`) that guards it, with no
    /// resolver of the test's own. An original goes only once its
    /// replacement has loaded here, and not while the pick still loads it.
    func testUpgradePassDeletesAnOriginalOnlyOnceItsReplacementLoaded() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("pretype-hub-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let hub = HubCache(cacheDirectory: root)
        let defaults = Settings.store, key = "loadedReplacementRepos"
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.removeObject(forKey: key)
        func place(_ repo: String) throws {
            let directory = try XCTUnwrap(ModelStorage.cacheDirectory(repo: repo))
            let revision = directory.appendingPathComponent("snapshots/rev")
            try manager.createDirectory(at: revision, withIntermediateDirectories: true)
            for file in ["config.json", "tokenizer.json", "model.safetensors"] {
                try Data("{}".utf8).write(to: revision.appendingPathComponent(file))
            }
        }
        func onDisk(_ repo: String) -> Bool {
            ModelStorage.cacheDirectory(repo: repo).map { manager.fileExists(atPath: $0.path) } ?? false
        }

        try await ModelStorage.$hub.withValue(hub) {
            XCTAssertEqual(ModelStorage.cacheDirectory(repo: "a/b")?.deletingLastPathComponent().standardizedFileURL.path,
                           hub.cacheDirectory.standardizedFileURL.path, "never the real cache")
            // A slim original: kept while its re-pack is only fetched, and
            // while the re-pack fails to load this launch.
            let e2b = "mlx-community/gemma-4-e2b-4bit", slim = "nikimori/gemma-4-e2b-4bit-slim"
            try place(e2b)
            try place(slim)
            await ModelStorage.upgradeToSlim(selected: e2b)
            XCTAssertTrue(onDisk(e2b), "fetched, never loaded")
            ModelStorage.noteLoad(repo: slim, succeeded: true)  // an earlier launch
            ModelStorage.noteLoad(repo: slim, succeeded: false)
            XCTAssertFalse(ModelStorage.isUsable(repo: slim), "on disk, but failing this launch")
            XCTAssertEqual(ModelCatalog.repo(for: e2b), e2b)
            XCTAssertFalse(ModelStorage.isUsable(repo: "nikimori/gemma-4-e4b-4bit-slim"), "not on disk")
            await ModelStorage.upgradeToSlim(selected: e2b)
            XCTAssertTrue(onDisk(e2b), "failing now: the original is what the engine falls back to")
            ModelStorage.noteLoad(repo: slim, succeeded: true)
            await ModelStorage.upgradeToSlim(selected: e2b)
            XCTAssertFalse(onDisk(e2b))
            XCTAssertTrue(onDisk(slim))

            // Qwen3.5's post-trained 4-bit is also the Base pick's previous
            // build: its re-pack has loaded, but until the 6-bit build has too
            // the original is still the primary.
            let qwen = "nikimori/Qwen3.5-2B-Base-6bit", old = "mlx-community/Qwen3.5-2B-4bit"
            let qwenSlim = "nikimori/Qwen3.5-2B-4bit-slim"
            for repo in [old, qwenSlim, qwen] { try place(repo) }
            ModelStorage.noteLoad(repo: qwenSlim, succeeded: true)
            await ModelStorage.upgradeToSlim(selected: qwen)
            XCTAssertTrue(onDisk(old), "the 6-bit build is here but never loaded")
            ModelStorage.noteLoad(repo: qwen, succeeded: true)
            await ModelStorage.upgradeToSlim(selected: qwen)
            XCTAssertFalse(onDisk(old))
            XCTAssertTrue(onDisk(qwen) && onDisk(qwenSlim))

            // The 6-bit build loaded but the re-pack never did: the chords
            // still run on the original, which no new primary build replaces.
            defaults.removeObject(forKey: key)
            try place(old)
            ModelStorage.noteLoad(repo: qwen, succeeded: true)
            await ModelStorage.upgradeToSlim(selected: qwen)
            XCTAssertTrue(onDisk(old), "a build a chord loads")
        }
    }

    /// A pass fetches the re-pack of a whole original only — half an
    /// original is the engine's to finish, its re-pack fetched with it.
    func testUpgradePassFetchesTheRepackOfAWholeOriginalOnly() async throws {
        let root = try TinyGemma.scratch("upgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        try await ModelStorage.$hub.withValue(HubCache(cacheDirectory: root)) {
            let e2b = "mlx-community/gemma-4-e2b-4bit", slim = "nikimori/gemma-4-e2b-4bit-slim"
            let revision = try XCTUnwrap(ModelStorage.cacheDirectory(repo: e2b)).appendingPathComponent("snapshots/rev")
            try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: revision.appendingPathComponent("config.json"))
            let fetched = LockedValue<[String]>([])
            func pass() async {
                await ModelStorage.upgradeToSlim(selected: e2b) { repo, _ in
                    fetched.mutate { $0.append(repo) }
                    return false
                }
            }
            await pass()
            XCTAssertEqual(fetched.get(), [], "half an original")
            for file in ["tokenizer.json", "model.safetensors"] {
                try Data("{}".utf8).write(to: revision.appendingPathComponent(file))
            }
            await pass()
            XCTAssertEqual(fetched.get(), [slim])

            // MiniCPM5's chords run on Qwen3.5's post-trained build: a pass
            // fetches that build's re-pack, not the Qwen3.5 Base build it is
            // also the previous build of — nobody here runs that one.
            let qwen = "mlx-community/Qwen3.5-2B-4bit"
            let qwenRevision = try XCTUnwrap(ModelStorage.cacheDirectory(repo: qwen)).appendingPathComponent("snapshots/rev")
            try FileManager.default.createDirectory(at: qwenRevision, withIntermediateDirectories: true)
            for file in ["config.json", "tokenizer.json", "model.safetensors"] {
                try Data("{}".utf8).write(to: qwenRevision.appendingPathComponent(file))
            }
            fetched.set([])
            await ModelStorage.upgradeToSlim(selected: "nikimori/MiniCPM5-1B-Base-8bit") { repo, _ in
                fetched.mutate { $0.append(repo) }
                return false
            }
            XCTAssertEqual(fetched.get(), ["nikimori/Qwen3.5-2B-4bit-slim"])
        }
    }

    /// The Gemma tiers' move to base (E2B 2026-10-14, E4B -15) must not turn
    /// an update into a forced download: an install holding only the instruct
    /// weights keeps Instruct until the base build is fetched in the background.
    func testGemmaInstallKeepsInstructUntilBaseIsHere() {
        let e2b = "mlx-community/gemma-4-e2b-4bit"
        let have = { (repos: [String]) in { (id: String) in repos.contains(id) } }
        XCTAssertTrue(Settings.keepsLegacyInstruct(model: e2b, isFetched: have(["mlx-community/gemma-4-e2b-it-4bit"])))
        XCTAssertFalse(Settings.keepsLegacyInstruct(model: e2b, isFetched: have([])))           // fresh install
        XCTAssertFalse(Settings.keepsLegacyInstruct(model: e2b, isFetched: have([e2b, "mlx-community/gemma-4-e2b-it-4bit"])))
        XCTAssertTrue(Settings.keepsLegacyInstruct(model: "mlx-community/gemma-4-e4b-6bit",
                                                   isFetched: have(["mlx-community/gemma-4-e4b-it-6bit"])))
        XCTAssertFalse(Settings.keepsLegacyInstruct(model: "nikimori/Qwen3.5-2B-Base-6bit",
                                                    isFetched: have(["mlx-community/Qwen3.5-2B-4bit"])))
        XCTAssertEqual(ModelCatalog.recommended(for: e2b).style, .base)
    }

    /// A pick of an earlier build lands on its entry's current build, not on
    /// a cleared (unknown) id.
    func testOldBuildPicksMigrate() {
        let saved = Settings.mlxModelID
        defer { Settings.mlxModelID = saved }
        for (old, new) in [("mlx-community/Qwen3.5-2B-4bit", "nikimori/Qwen3.5-2B-Base-6bit"),
                           ("nikimori/Qwen3.5-2B-Base-4bit", "nikimori/Qwen3.5-2B-Base-6bit"),
                           ("openbmb/MiniCPM5-1B-Base", "nikimori/MiniCPM5-1B-Base-8bit")] {
            Settings.mlxModelID = old
            Settings.migrate()
            XCTAssertEqual(Settings.mlxModelID, new, old)
        }
    }
}
