import XCTest
@testable import Pretype

/// An app update that changes which build a pick runs on must never turn into
/// a forced download, a dead engine offline, or a deleted build that worked.
final class ModelUpgradeTests: XCTestCase {
    // Qwen3.5's pick moved to its Base build: an install holding only the old
    // post-trained build keeps completing on it until the Base build is here.
    func testPreviousBuildServesUntilTheNewOneIsFetched() {
        let id = "nikimori/Qwen3.5-2B-Base-4bit"
        let old = "mlx-community/Qwen3.5-2B-4bit"
        XCTAssertEqual(ModelCatalog.previousBuilds[id], old)
        for (have, expected) in [([String](), id), ([old], old), ([old, id], id), ([id], id)] {
            XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: have.contains), expected, "\(have)")
        }
        // The old build is still the entry's ⌥⇥ sibling, so the upgrade pass
        // (which needs both in the selected entry's set) keeps it.
        XCTAssertEqual(ModelCatalog.option(for: id)?.correctionModelID, old)
        XCTAssertTrue(ModelStorage.repos(for: id).isSuperset(of: [id, old]))
        // A stored pick of the old id is rewritten at launch — safe only
        // because of the fallback above; the old id is no catalog entry.
        XCTAssertNil(ModelCatalog.options.first { $0.id == old })
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
