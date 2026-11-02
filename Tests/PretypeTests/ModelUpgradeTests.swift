import XCTest
@testable import Pretype

/// An app update that changes which build a pick runs on must never turn into
/// a forced download or a dead engine offline.
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
        // The post-trained build is still the entry's ⌥⇥ sibling, and both
        // count as the entry's while on disk.
        XCTAssertEqual(ModelCatalog.option(for: id)?.correctionModelID, old)
        XCTAssertTrue(try withScratchHub { ModelStorage.repos(for: id) }.isSuperset(of: [id, base4, old]))
        // A stored pick of an old id is rewritten at launch — safe only
        // because of the fallback above; the old ids are no catalog entries.
        XCTAssertNil(ModelCatalog.options.first { $0.id == old || $0.id == base4 })
    }

    // MiniCPM5 moved to our 8-bit build (10-15): the hub bf16 keeps serving
    // until it's fetched — the chords ride Qwen3.5's sibling, so the bf16 is
    // no sibling.
    func testMiniCPMServesBF16UntilEightBitIsFetched() throws {
        let id = "nikimori/MiniCPM5-1B-Base-8bit"
        let bf16 = "openbmb/MiniCPM5-1B-Base"
        XCTAssertEqual(ModelCatalog.previousBuilds[id], [bf16])
        for (have, expected) in [([String](), id), ([bf16], bf16), ([bf16, id], id)] {
            XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: have.contains), expected, "\(have)")
        }
        XCTAssertNotEqual(ModelCatalog.option(for: id)?.correctionModelID, bf16)
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
