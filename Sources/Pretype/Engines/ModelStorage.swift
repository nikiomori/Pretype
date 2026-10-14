import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Network

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
    /// zero download) and filesystem paths, which are the user's OWN
    /// directories and must never reach `removeItem`.
    static func directory(for id: String) -> URL? {
        cacheDirectory(repo: ModelCatalog.repo(for: id))
    }

    /// The cache directory of one Hub repo, taken literally — `directory(for:)`
    /// first resolves a catalog id to the repo it downloads from.
    static func cacheDirectory(repo id: String) -> URL? {
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
    /// no cache directory at all — the Apple Intelligence pseudo-id, a
    /// filesystem path — are already on the machine, so they answer no too.
    static func isFetched(_ id: String) -> Bool {
        guard let directory = directory(for: id) else { return true }
        return isFetched(at: directory)
    }

    /// The same question against an explicit repo directory — the seam a test
    /// can point at a fixture, since the id form resolves through the real
    /// shared cache.
    static func isFetched(at directory: URL) -> Bool {
        completeRevision(at: directory) != nil
    }

    /// The downloaded snapshot of `id` the engine can load straight from disk:
    /// weights complete (see `isFetched`), plus the config and tokenizer the
    /// loader reads. nil — load through the hub, which downloads what's
    /// missing. Loading through the hub with revision "main" lists the repo
    /// over the network first, on every load and every idle reload (measured
    /// 160–580 ms, and longer still on a bad connection), so a model that is
    /// already here is loaded from here.
    static func localSnapshot(for id: String) -> URL? {
        guard let directory = directory(for: id) else { return nil }
        return localSnapshot(at: directory)
    }

    static func localSnapshot(at directory: URL) -> URL? {
        guard let revision = completeRevision(at: directory) else { return nil }
        let manager = FileManager.default
        func present(_ name: String) -> Bool {
            manager.fileExists(atPath: revision.appendingPathComponent(name).path)
        }
        guard present("config.json"), present("tokenizer.json") || present("tokenizer_config.json") else { return nil }
        return revision
    }

    /// The snapshot revision directory holding the complete model, if any.
    private static func completeRevision(at directory: URL) -> URL? {
        let manager = FileManager.default
        let snapshots = directory.appendingPathComponent("snapshots")
        guard let revisions = try? manager.contentsOfDirectory(atPath: snapshots.path) else {
            return nil
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
        // The pinned commit outranks it: that is what a download fetches.
        let repo = directory.lastPathComponent.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
        if let pinned = ModelCatalog.pinnedRevisions[repo], named.contains(pinned) {
            let revision = snapshots.appendingPathComponent(pinned)
            if isRevisionComplete(revision) { return revision }
        }
        if let head = try? String(
            contentsOf: directory.appendingPathComponent("refs/main"), encoding: .utf8) {
            let sha = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if named.contains(sha) {
                let revision = snapshots.appendingPathComponent(sha)
                return isRevisionComplete(revision) ? revision : nil
            }
        }
        return named.sorted().lazy.map { snapshots.appendingPathComponent($0) }.first(where: isRevisionComplete)
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

    /// Every Hub repo a catalog entry pulls: its own weights plus the ⌥Tab
    /// rewrite siblings and their MTP drafters, all downloaded lazily and
    /// invisible in the entry's advertised size. Leaving orphaned siblings
    /// behind is exactly how 82 GB of cache accumulates without anyone noticing.
    /// Repo names, taken literally — both builds of a model with a slim
    /// re-pack, since an install may hold either, or both mid-upgrade.
    static func repos(for id: String) -> Set<String> {
        guard let option = ModelCatalog.option(for: id) else { return [] }
        let models = [option.id, option.correctionModelID, option.instructModelID]
        let slim = models.compactMap { ModelCatalog.slimRepos[$0] }
        let previous = ModelCatalog.previousBuilds[option.id] ?? []
        return Set((models + slim + previous + models.compactMap(ModelCatalog.mtpDrafterID(for:)))
            .filter { cacheDirectory(repo: $0) != nil })
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

    /// Remove one Hub repo (a `repos(for:)` member) from the cache. Belt and
    /// braces on purpose: this is the one place where a malformed id could
    /// steer `removeItem` at the user's own files, so the target must be a
    /// `models--…` directory sitting directly in the resolved cache root, and
    /// `cacheDirectory(repo:)` must have accepted the id in the first place.
    /// Anything else is a silent no-op.
    ///
    /// `<cache>/.locks/…` and `<cache>/.metadata/…` leftovers survive this;
    /// they are zero-byte in practice, so chasing them isn't worth the extra
    /// paths pointed at a delete call.
    static func delete(repo id: String) throws {
        guard let directory = cacheDirectory(repo: id),
              directory.lastPathComponent.hasPrefix("models--"),
              directory.deletingLastPathComponent().standardizedFileURL.path
                == HubCache.default.cacheDirectory.standardizedFileURL.path
        else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Re-packs and new builds (`ModelCatalog.slimRepos` values,
    /// `previousBuilds` keys) that have loaded on this Mac. An original is
    /// deleted only once its replacement made it into memory here — a
    /// re-pack that fails to load must not strand a user without the build
    /// that worked.
    private static let loadedKey = "loadedReplacementRepos"
    /// Replacements whose load failed this launch: `ModelCatalog.repo(for:)`
    /// treats them as absent, so the engine's retry falls back to the
    /// original still on disk. In memory only — each launch tries again.
    private static let failedLoads = LockedValue<Set<String>>([])

    private static func isReplacement(_ repo: String) -> Bool {
        ModelCatalog.slimRepos.values.contains(repo) || ModelCatalog.previousBuilds[repo] != nil
    }

    /// The engine's report on a load of `repo` (a resolved repo, not an id).
    static func noteLoad(repo: String, succeeded: Bool) {
        guard isReplacement(repo) else { return }
        if succeeded {
            _ = failedLoads.mutate { $0.remove(repo) }
            var loaded = Set(UserDefaults.standard.stringArray(forKey: loadedKey) ?? [])
            if loaded.insert(repo).inserted { UserDefaults.standard.set(Array(loaded), forKey: loadedKey) }
        } else {
            _ = failedLoads.mutate { $0.insert(repo) }
            DebugLog.shared.log("MLX", "\(repo) failed to load — falling back to the build it replaces this launch")
        }
    }

    static func loadFailed(repo: String) -> Bool { failedLoads.get().contains(repo) }

    private static func hasLoaded(repo: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: loadedKey)?.contains(repo) ?? false
    }

    /// Moves an install that downloaded an original Gemma build before the
    /// slim re-packs existed onto them: fetch the re-pack in the background
    /// while the original keeps serving, then — once the re-pack has loaded
    /// here (`noteLoad`) — delete the original.
    /// `ModelCatalog.repo(for:)` prefers a fetched re-pack, so the next load
    /// (idle reload or relaunch) picks it up — the same weights the engine
    /// already held in memory, so all that changes is disk (−0.6…2.7 GB per
    /// model) and a faster reload. A `previousBuilds` pair is fetched the same
    /// way; its old build stays only while it is the entry's ⌥⇥ sibling.
    ///
    /// Only the selected model's repos: a model nobody uses isn't worth
    /// gigabytes of the user's bandwidth. Skipped on an expensive (cellular,
    /// hotspot) or Low Data Mode network and when the disk can't hold both
    /// builds at once; the next launch tries again.
    static func upgradeToSlim(selected: String) async {
        let inUse = repos(for: selected)
        let pairs = ModelCatalog.slimRepos.map { (original: $0.key, slim: $0.value, keepOriginal: false) }
            + ModelCatalog.previousBuilds.flatMap { new, olds in
                let siblings = ModelCatalog.option(for: new).map { [$0.correctionModelID, $0.instructModelID] } ?? []
                return olds.map { (original: $0, slim: new, keepOriginal: siblings.contains($0)) }
            }
        for (original, slim, keepOriginal) in pairs where inUse.contains(original) && inUse.contains(slim) {
            guard let originalDir = cacheDirectory(repo: original), let slimDir = cacheDirectory(repo: slim),
                  FileManager.default.fileExists(atPath: originalDir.path) else { continue }
            if !isFetched(at: slimDir) {
                // Half an original: the engine already loads (and fetches) the
                // re-pack; this one is deleted on a later pass, once it's here.
                guard isFetched(at: originalDir),
                      await fetchQuietly(repo: slim, sizeHint: bytes(at: originalDir)) else { continue }
            }
            guard !keepOriginal, hasLoaded(repo: slim) else { continue }
            // An engine holding the original keeps it: its weights are in
            // memory, and an unlinked file stays readable while open.
            // ponytail: a reload resolving the original in the instant before
            // this delete fails once and retries after the load cooldown.
            try? delete(repo: original)
            DebugLog.shared.log("MLX", "replaced \(original) with \(slim)")
        }
    }

    /// Auto mode follows `ModelCatalog.recommended(for:)`, and a recommendation
    /// can move an existing install onto weights it doesn't hold (the E2B tiers'
    /// switch to base, 2026-10-14). The stored style keeps serving while those
    /// are fetched quietly; true once the caller can re-apply the
    /// recommendation without a download wait.
    static func fetchRecommendedWeights(selected: String) async -> Bool {
        guard Settings.useRecommendedSettings, let option = ModelCatalog.option(for: selected) else { return false }
        let style = ModelCatalog.recommended(for: selected).style
        guard style != Settings.completionStyle else { return false }
        let weights = style == .instruct ? option.instructModelID : option.id
        if isFetched(weights) { return true }
        return await fetchQuietly(repo: ModelCatalog.repo(for: weights),
                                  sizeHint: Int64(option.approxSizeMB) * 1_000_000)
    }

    /// A download nobody clicked for, on the terms every such fetch keeps: an
    /// unmetered network (`isNetworkUnmetered`) and room for about `sizeHint`
    /// bytes plus 2 GB. Whether `repo` is complete on disk afterwards; a
    /// declined or failed fetch is retried at the next launch.
    static func fetchQuietly(repo: String, sizeHint: Int64) async -> Bool {
        guard let directory = cacheDirectory(repo: repo) else { return false }
        let free = (try? directory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard free > sizeHint + 2_000_000_000, await isNetworkUnmetered() else { return false }
        DebugLog.shared.log("MLX", "fetching \(repo) in the background")
        do {
            _ = try await resolve(configuration: ModelConfiguration(id: repo, revision: ModelCatalog.revision(for: repo)),
                                  from: #hubDownloader(),
                                  useLatest: false, progressHandler: { _ in })
        } catch {
            DebugLog.shared.log("MLX", "background fetch of \(repo) failed: \(error.localizedDescription)")
            return false
        }
        return isFetched(at: directory)
    }

    /// Whether the network is one a multi-GB background fetch may use: up, not
    /// cellular or a hotspot (`isExpensive`), not in Low Data Mode (`isConstrained`).
    static func isNetworkUnmetered() async -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let answered = LockedValue(false)
        return await withCheckedContinuation { done in
            monitor.pathUpdateHandler = { path in
                guard !answered.exchange(true) else { return }
                done.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}
