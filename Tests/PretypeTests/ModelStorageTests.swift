import XCTest
@testable import Pretype

final class ModelStorageTests: XCTestCase {
    // An already-downloaded model loads from its snapshot with no network
    // round trip — but only when everything the loader reads is there.
    func testLocalSnapshotNeedsWeightsConfigAndTokenizer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func repo(_ name: String, files: [String]) throws -> URL {
            let dir = root.appendingPathComponent(name)
            let rev = dir.appendingPathComponent("snapshots/abc")
            try FileManager.default.createDirectory(at: rev, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("refs"), withIntermediateDirectories: true)
            try "abc".write(to: dir.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
            for f in files { try "x".write(to: rev.appendingPathComponent(f), atomically: true, encoding: .utf8) }
            return dir
        }
        let full = try repo("full", files: ["config.json", "tokenizer.json", "model.safetensors"])
        XCTAssertEqual(ModelStorage.localSnapshot(at: full)?.lastPathComponent, "abc")
        XCTAssertNil(ModelStorage.localSnapshot(at: try repo("no-tokenizer", files: ["config.json", "model.safetensors"])))
        XCTAssertNil(ModelStorage.localSnapshot(at: try repo("no-weights", files: ["config.json", "tokenizer.json"])))
    }

    // Deleting model weights points `removeItem` at a cache shared with every
    // other Hugging Face tool on the Mac — pin what may and may not be a target,
    // and the symlink trap that would otherwise double every reported size.
    func testModelStorage() throws {
        // A filesystem path is the user's OWN directory: never a cache repo.
        XCTAssertNil(ModelStorage.directory(for: "/Users/someone/models/my-finetune"))
        // The system model downloads nothing.
        XCTAssertNil(ModelStorage.directory(for: ModelCatalog.appleIntelligenceID))

        let repoDir = try XCTUnwrap(ModelStorage.cacheDirectory(repo: "mlx-community/gemma-4-e2b-4bit"))
        XCTAssertEqual(repoDir.lastPathComponent, "models--mlx-community--gemma-4-e2b-4bit")
        // A catalog id resolves to the repo it downloads from: its slim re-pack,
        // or the original when that is already on disk (whichever this Mac has).
        let id = "mlx-community/gemma-4-e2b-4bit"
        XCTAssertTrue([id, "nikimori/gemma-4-e2b-4bit-slim"].contains(ModelCatalog.repo(for: id)))
        XCTAssertEqual(ModelStorage.directory(for: id),
                       ModelStorage.cacheDirectory(repo: ModelCatalog.repo(for: id)))
        // Every slim re-pack replaces something the catalog actually downloads.
        let downloaded = Set(ModelCatalog.options.flatMap { [$0.id, $0.correctionModelID, $0.instructModelID] })
        XCTAssertTrue(Set(ModelCatalog.slimRepos.keys).isSubset(of: downloaded))
        XCTAssertEqual(ModelCatalog.repo(for: "mlx-community/Qwen2.5-0.5B-bf16"), "mlx-community/Qwen2.5-0.5B-bf16")
        // The re-pack wins whenever it's here; the original only while it's all there is.
        let slim = "nikimori/gemma-4-e2b-4bit-slim"
        for (have, expected) in [([String](), slim), ([id], id), ([id, slim], slim), ([slim], slim)] {
            XCTAssertEqual(ModelCatalog.repo(for: id, isFetched: have.contains), expected, "\(have)")
        }
        // Both builds are this entry's to count and delete — an install may hold either.
        XCTAssertTrue(ModelStorage.repos(for: id).isSuperset(of: [id, slim]))

        // Nothing is deletable when the entry being inspected is the selected one.
        XCTAssertTrue(ModelStorage.deletableRepos(
            for: "mlx-community/gemma-4-e2b-4bit",
            selected: "mlx-community/gemma-4-e2b-4bit"
        ).isEmpty)

        // The symlink trap: snapshots/ points into blobs/, and resourceValues
        // stats THROUGH symlinks, so a naive recursive walk reports double.
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelStorageTests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }

        let fakeRepo = root.appendingPathComponent("models--acme--tiny")
        let blobs = fakeRepo.appendingPathComponent("blobs")
        let snapshot = fakeRepo.appendingPathComponent("snapshots/deadbeef")
        try manager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for name in ["aaaa1111", "bbbb2222"] {
            let blob = blobs.appendingPathComponent(name)
            try Data(repeating: 0x41, count: 8 * 1024).write(to: blob)
            try manager.createSymbolicLink(
                at: snapshot.appendingPathComponent("\(name).safetensors"),
                withDestinationURL: blob
            )
        }

        let measured = ModelStorage.bytes(at: fakeRepo)
        XCTAssertGreaterThanOrEqual(measured, 16 * 1024)
        XCTAssertLessThan(measured, 24 * 1024, "snapshot symlinks are being counted as real bytes")
    }

    /// The gate the dictation tidy-up asks before spending its budget: it must
    /// answer "would this go to the network", not "is the model resident".
    /// Anything with no Hugging Face cache directory of its own — the Apple
    /// Intelligence pseudo-id, a filesystem path — is already on the
    /// machine and must never be treated as an unfetched download.
    func testCorrectionFetchGateAnswersForLocalIDs() {
        XCTAssertTrue(ModelStorage.isFetched(ModelCatalog.appleIntelligenceID))
        XCTAssertTrue(ModelStorage.isFetched("/Users/someone/models/my-finetune"))
        XCTAssertFalse(ModelStorage.isFetched("pretype-test/definitely-not-downloaded"))
    }

    /// The gate has to fail closed on a download IN FLIGHT, which is the whole
    /// point: the hub populates `snapshots/<rev>/` file by file, so the
    /// directory shows up as soon as a few-kilobyte config.json lands, with
    /// gigabytes of weights still on the wire — and an abandoned fetch leaves
    /// exactly that state behind, with no partial-file residue to spot it by.
    func testFetchGateReadsTheWeightsNotTheDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pretype-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func repo(_ name: String, revision revisionName: String = "rev1",
                  files: [String: String] = [:], danglingLinks: [String] = [],
                  head: String? = nil) throws -> URL {
            let directory = root.appendingPathComponent(name)
            let revision = directory.appendingPathComponent("snapshots/\(revisionName)")
            try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
            for (file, contents) in files {
                try contents.write(to: revision.appendingPathComponent(file),
                                   atomically: true, encoding: .utf8)
            }
            for link in danglingLinks {
                // What a snapshot entry looks like before its blob is copied in.
                try FileManager.default.createSymbolicLink(
                    at: revision.appendingPathComponent(link),
                    withDestinationURL: directory.appendingPathComponent("blobs/not-here-yet"))
            }
            if let head {
                let refs = directory.appendingPathComponent("refs")
                try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
                try head.write(to: refs.appendingPathComponent("main"),
                               atomically: true, encoding: .utf8)
            }
            return directory
        }

        let index = #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
        // Only the config has landed — a download in flight, or one abandoned.
        XCTAssertFalse(ModelStorage.isFetched(
            at: try repo("config-only", files: ["config.json": "{}"])))
        // Sharded, one shard still coming.
        XCTAssertFalse(ModelStorage.isFetched(at: try repo("half", files: [
            "config.json": "{}", "model.safetensors.index.json": index,
            "model-00001-of-00002.safetensors": "w",
        ])))
        // Both shards present: ready.
        XCTAssertTrue(ModelStorage.isFetched(at: try repo("whole", files: [
            "config.json": "{}", "model.safetensors.index.json": index,
            "model-00001-of-00002.safetensors": "w", "model-00002-of-00002.safetensors": "w",
        ])))
        // A snapshot link whose blob has not been copied in yet resolves to
        // nothing — `fileExists` follows it, which is why that is the test.
        XCTAssertFalse(ModelStorage.isFetched(at: try repo(
            "dangling",
            files: ["config.json": "{}", "model.safetensors.index.json": #"{"weight_map":{"a":"model.safetensors"}}"#],
            danglingLinks: ["model.safetensors"])))
        // No shard index at all — a single-file repo is ready on its weights.
        XCTAssertTrue(ModelStorage.isFetched(
            at: try repo("single", files: ["config.json": "{}", "model.safetensors": "w"])))
        // ...and mid-download that single file IS a dangling link: the no-index
        // branch must check it resolves too, or the tidy-up stalls on it.
        XCTAssertFalse(ModelStorage.isFetched(at: try repo(
            "single-dangling", files: ["config.json": "{}"], danglingLinks: ["model.safetensors"])),
            "a dangling single-file weight link is a download in flight")
        // Nothing there at all.
        XCTAssertFalse(ModelStorage.isFetched(at: root.appendingPathComponent("absent")))

        // A second revision holding only metadata — what another tool sharing
        // this cache leaves behind with one `hf_hub_download(repo, "config.json")`
        // at a different sha. The complete revision must still answer, whichever
        // order the filesystem lists them in: reading the stray one would report
        // a fully downloaded model as missing, and the answer is latched.
        let shared = try repo("shared-cache", revision: "aaa-metadata-only",
                              files: ["config.json": "{}"])
        try repo("shared-cache", revision: "bbb-complete",
                 files: ["config.json": "{}", "model.safetensors": "w"])
        XCTAssertTrue(ModelStorage.isFetched(at: shared))

        // With `refs/main` present it decides, so a re-converted head still
        // downloading is not masked by the complete revision it replaces.
        let rolling = try repo("rolling", revision: "old-complete",
                               files: ["config.json": "{}", "model.safetensors": "w"])
        try repo("rolling", revision: "new-head", files: ["config.json": "{}"],
                 head: "new-head")
        XCTAssertFalse(ModelStorage.isFetched(at: rolling))
    }
}
