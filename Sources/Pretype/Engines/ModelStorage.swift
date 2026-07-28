import Foundation
import HuggingFace

/// Disk accounting for the Hugging Face cache the app downloads into, so the
/// Models tab can show what a model costs on disk and hand back the space.
///
/// The cache is located via `HubCache.default` — the very instance
/// `MLXEngine.makeLoadTask` ends up using — rather than a hardcoded
/// `~/.cache/huggingface/hub`, because that resolution honours HF_HUB_CACHE /
/// HF_HOME (the eval harness sets them) and the sandbox container. Measuring
/// one directory while the downloader writes another is the whole bug class
/// this avoids.
///
/// That cache is SHARED with whatever other Hugging Face tooling the user runs
/// (this machine has PaddleOCR and TTS repos sitting next to ours), so only ids
/// reachable from `ModelCatalog` may ever reach `delete`.
enum ModelStorage {
    /// The cache directory a catalog id occupies, or nil when there is nothing
    /// on disk to account for: the Apple Intelligence pseudo-id (system model,
    /// zero download) and local fine-tune folders, which are the user's OWN
    /// directories and must never reach `removeItem`.
    static func directory(for id: String) -> URL? {
        guard id != ModelCatalog.appleIntelligenceID, !id.hasPrefix("/"),
              let repo = Repo.ID(rawValue: id) else { return nil }
        return HubCache.default.repoDirectory(repo: repo, kind: .model)
    }

    /// Whether loading `id` would cost at most a read from disk — no network.
    ///
    /// Cheap on purpose (one directory listing of `snapshots/`, no blob walk),
    /// because the dictation tidy-up asks this on the main thread while a
    /// transcript waits: the question is only ever "would this go to the
    /// network", and a repo with a materialized snapshot answers no. Ids with
    /// no cache directory at all — the Apple Intelligence pseudo-id, a local
    /// fine-tune folder — are already on the machine, so they answer no too.
    static func isFetched(_ id: String) -> Bool {
        guard let directory = directory(for: id) else { return true }
        return isFetched(at: directory)
    }

    /// The same question against an explicit repo directory — the seam a test
    /// can point at a fixture, since the id form resolves through the real
    /// shared cache.
    static func isFetched(at directory: URL) -> Bool {
        let manager = FileManager.default
        let snapshots = directory.appendingPathComponent("snapshots")
        guard let revisions = try? manager.contentsOfDirectory(atPath: snapshots.path) else {
            return false
        }
        let named = revisions.filter { !$0.hasPrefix(".") }
        // WHICH revision matters, and picking whichever the filesystem listed
        // first does not. Nothing prunes old revision directories, and this
        // cache is shared with the user's other Hugging Face tooling: one
        // `hf_hub_download(repo, "config.json")` at another sha leaves a
        // metadata-only sibling, and enumerating that one would report a fully
        // downloaded model as missing — permanently, since the answer is
        // latched. `refs/main` is the cache's own record of the current head,
        // so ask about that one; without it, any complete revision will do.
        if let head = try? String(
            contentsOf: directory.appendingPathComponent("refs/main"), encoding: .utf8) {
            let sha = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if named.contains(sha) {
                return isRevisionComplete(snapshots.appendingPathComponent(sha))
            }
        }
        return named.contains { isRevisionComplete(snapshots.appendingPathComponent($0)) }
    }

    /// Whether one snapshot revision holds the model's weights, not just the
    /// metadata that lands first.
    private static func isRevisionComplete(_ root: URL) -> Bool {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(atPath: root.path) else { return false }
        func present(_ name: String) -> Bool {
            // The entries are symlinks into `blobs/`, and the downloader writes
            // a blob only once its file is complete — so a link that resolves
            // is a finished file. `fileExists` follows the link, which is
            // exactly the semantics wanted here.
            manager.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        // A revision directory is NOT proof of a finished download: the hub
        // populates it file by file, so `snapshots/<rev>/` appears the moment a
        // few-kilobyte config.json lands with gigabytes of weights still on the
        // wire — and a download abandoned there leaves exactly that behind, no
        // `.incomplete` residue of any kind (this client streams into a
        // URLSession temp file and only copies in on success; the `.incomplete`
        // path is the resume branch, which needs the file to exist already).
        // The honest question is therefore whether the WEIGHTS are here.
        if let data = try? Data(contentsOf: root.appendingPathComponent("model.safetensors.index.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let shards = json["weight_map"] as? [String: String] {
            return Set(shards.values).allSatisfy(present)
        }
        // No shard index to go by. Anything that looks like weights — by
        // extension, or simply by being far too big to be metadata — counts
        // once its link resolves (a single-file repo mid-download leaves a
        // dangling snapshot symlink), and an unrecognized layout is read as
        // ready on purpose: the cost of guessing wrong that way is one stalled
        // tidy-up during a download, while guessing the other way turns the
        // feature permanently off.
        return files.contains { name in
            if name.hasSuffix(".safetensors") || name.hasSuffix(".npz") || name.hasSuffix(".gguf") {
                return present(name)
            }
            guard name != "config.json", present(name) else { return false }
            let size = try? root.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize
            return (size ?? 0) > 20_000_000
        }
    }

    /// Bytes on disk for one repo. Blocking I/O — callers must keep it off the
    /// main actor.
    ///
    /// Only `blobs/` is summed. `snapshots/` is symlinks INTO blobs and
    /// `URL.resourceValues` stats through symlinks, so walking the whole repo
    /// dir reports exactly double (measured: du -sh 1.6G vs du -shL 3.3G).
    /// blobs/ is flat, so no enumerator is needed. It also holds any
    /// `<etag>.incomplete` partial left by OTHER Hugging Face tooling sharing
    /// this cache — space a user reclaiming a model wants counted. Our own
    /// downloader leaves none: it streams into a URLSession temp file and
    /// copies in only on success, so an abandoned fetch of ours costs the
    /// blobs that did complete and nothing more.
    static func bytes(at repoDirectory: URL) -> Int64 {
        let blobs = repoDirectory.appendingPathComponent("blobs")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
    }

    /// Every repo a catalog entry pulls: its own weights plus the ⌥Tab rewrite
    /// siblings, which are downloaded lazily on first fix and are invisible in
    /// the entry's advertised size. Leaving orphaned siblings behind is exactly
    /// how 82 GB of cache accumulates without anyone noticing.
    static func repos(for id: String) -> Set<String> {
        guard let option = ModelCatalog.option(for: id) else { return [] }
        return Set([option.id, option.correctionModelID, option.instructModelID]
            .filter { directory(for: $0) != nil })
    }

    /// Repos that can be freed if `id` is dropped while `selected` stays.
    ///
    /// Protecting the selected entry's WHOLE sibling set sidesteps the fact
    /// that `MLXEngine`'s live modelID is a resolved sibling in instruct style
    /// (and the correction model appears only after the first ⌥Tab) — reading
    /// the engine's private state to find out would race with a load.
    ///
    /// ponytail: two unselected Gemma entries can share the same -it-4bit
    /// sibling, so their figures overlap and deleting one shrinks the other's
    /// figure on the next refresh. Per-repo attribution (charge a shared blob
    /// to one owner, or show it as "shared") only if that ever confuses anyone.
    static func deletableRepos(for id: String, selected: String) -> Set<String> {
        repos(for: id).subtracting(repos(for: selected))
    }

    /// Remove one repo from the cache. Belt and braces on purpose: this is the
    /// one place where a malformed id could steer `removeItem` at the user's
    /// own files, so the target must be a `models--…` directory sitting
    /// directly in the resolved cache root, and `directory(for:)` must have
    /// accepted the id in the first place. Anything else is a silent no-op.
    ///
    /// `<cache>/.locks/…` and `<cache>/.metadata/…` leftovers survive this;
    /// they are zero-byte in practice, so chasing them isn't worth the extra
    /// paths pointed at a delete call.
    static func delete(_ id: String) throws {
        guard let directory = directory(for: id),
              directory.lastPathComponent.hasPrefix("models--"),
              directory.deletingLastPathComponent().standardizedFileURL.path
                == HubCache.default.cacheDirectory.standardizedFileURL.path
        else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
