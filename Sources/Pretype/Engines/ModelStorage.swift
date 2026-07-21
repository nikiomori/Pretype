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

    /// Bytes on disk for one repo. Blocking I/O — callers must keep it off the
    /// main actor.
    ///
    /// Only `blobs/` is summed. `snapshots/` is symlinks INTO blobs and
    /// `URL.resourceValues` stats through symlinks, so walking the whole repo
    /// dir reports exactly double (measured: du -sh 1.6G vs du -shL 3.3G).
    /// blobs/ is flat, so no enumerator is needed, and it also holds
    /// `<etag>.incomplete` partials — a cancelled download still shows its
    /// footprint, which is precisely the space a user wants to reclaim.
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
