import XCTest
@testable import Pretype

/// An app update that changes which build a pick runs on must never turn into
/// a forced download, a dead engine offline, or a deleted build that worked.
final class ModelUpgradeTests: XCTestCase {
    // Qwen3.5's pick moved to its Base build (10-11), then to 6-bit (10-14): an
    // install holding only an older build keeps completing on the newest one
    // it has until the 6-bit build is here.
    func testPreviousBuildServesUntilTheNewOneIsFetched() {
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
        XCTAssertTrue(ModelStorage.repos(for: id).isSuperset(of: [id, base4, old]))
        // A stored pick of an old id is rewritten at launch — safe only
        // because of the fallback above; the old ids are no catalog entries.
        XCTAssertNil(ModelCatalog.options.first { $0.id == old || $0.id == base4 })
    }

    // A replacement that fails to load counts as absent for the rest of the
    // launch, so the engine's retry resolves the original still on disk.
    func testFailedReplacementFallsBackToTheOriginal() {
        let id = "mlx-community/gemma-4-e2b-4bit"
        let slim = "nikimori/gemma-4-e2b-4bit-slim"
        let have: Set = [id, slim]
        let isFetched = { (repo: String) in have.contains(repo) && !ModelStorage.loadFailed(repo: repo) }
        XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: isFetched), slim)
        ModelStorage.noteLoad(repo: slim, succeeded: false)
        defer { ModelStorage.noteLoad(repo: slim, succeeded: true) }
        XCTAssertTrue(ModelStorage.loadFailed(repo: slim))
        XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: isFetched), id)
        // Originals are never marked: there is nothing behind them to fall back to.
        ModelStorage.noteLoad(repo: id, succeeded: false)
        XCTAssertFalse(ModelStorage.loadFailed(repo: id))
    }
}
