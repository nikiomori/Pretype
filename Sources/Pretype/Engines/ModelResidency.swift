import Foundation
import MLX
import MLXLMCommon

/// Which of the engine's models sit in memory, and for how long: the
/// completion model and the base style's fix sibling (`Slot`), loaded when a
/// request needs one, freed after idle or under memory pressure, and rebuilt
/// without the MLX reload leak (`MLXEngine+Loading`). `MLXEngine` decides
/// what to ask a model; this decides whether one is there to ask. All
/// lifecycle state is guarded by `modelLock`.
final class ModelResidency {
    /// What a request runs: completion on the primary, fixes and replies on
    /// whichever model `fixSlot` picks.
    enum Role { case completion, fix }

    /// A request's hold on a model: its load task, and what `end` releases.
    struct Lease {
        let task: Task<ModelContainer, Error>
        fileprivate let slot: Slot
        /// Its MTP drafter, when the model loaded with one.
        var drafter: (any MTPDrafterModel)? { slot.drafter.get() }
    }

    /// The PRIMARY model's state, written only by its own load and unload.
    private let stateBox = LockedValue<EngineState>(.preparing(String(localized: "starting…")))
    /// The fix model's load progress while that load runs, else nil. Kept
    /// apart from `stateBox`: the two loads overlap, and snapshotting the
    /// primary's state to restore it afterwards put back one that had moved
    /// on ("loading…" after the primary went ready pinned it busy for good).
    private let correctionStatus = LockedValue<String?>(nil)
    /// "The fix model's weights are on this machine" — see `isCorrectionReady`.
    /// Outlives an idle unload on purpose: unloading frees memory, not disk.
    private let correctionFetched = LockedValue(false)

    /// The completion model, and the base style's fix sibling — loaded
    /// lazily on first ⌥⇥, idling on its own clock. `fixSlot` decides which
    /// of the two fixes and replies run on.
    private let primary: Slot
    private let sibling: Slot
    /// Loads running in this process, retired engines' included: `shutdown`
    /// cancels a load, but a warm-up mid-generate runs to its end, and MLX's
    /// static teardown at exit crashes under it. Tests wait for 0 after each
    /// case (`MLXTestCase`).
    static let runningLoads = LockedValue(0)
    /// Fixed for the engine's life: switching style rebuilds it.
    private let style: CompletionStyle

    /// A model this loads, serves and lets go. The primary and the fix
    /// sibling go through the same code — `startLoad`, `begin`/`end`,
    /// `prewarm`, `letGo` — so their lifecycles can't drift apart; where a
    /// load reports, the warm-up and the failure cooldown are all that
    /// differ. Mutable state is guarded by `modelLock`.
    final class Slot: @unchecked Sendable {
        let id: String
        /// Its MTP drafter (see `ModelCatalog.mtpDrafterID`), loaded and
        /// released with it; nil = plain decoding.
        let drafterID: String?
        let drafter = LockedValue<(any MTPDrafterModel)?>(nil)
        /// How long a failed load holds off the next one — so a genuinely
        /// unavailable model (offline, bad repo id) isn't re-attempted on
        /// every keystroke, each retry re-hitting the Hub. 0 for the fix
        /// sibling: a ⌥⇥ is a deliberate retry.
        let retryCooldown: TimeInterval
        var task: Task<ModelContainer, Error>?
        /// The repo its load resolved: the weights it holds, which
        /// `ModelCatalog.repo(for:)` stops naming the moment a newer build
        /// lands on disk. nil while nothing is loaded.
        var loadedRepo: String?
        /// Requests running on it, and its last use: each model idles on its
        /// own clock — timed off the keystrokes, a fix sibling last used for
        /// one ⌥⇥ hours ago kept gigabytes resident (E4B-it: ~4 GB).
        var inFlight = 0
        var lastUse = Date()
        /// When its last load failed; nil once one succeeds.
        var lastFailure: Date?

        init(id: String, drafterID: String?, retryCooldown: TimeInterval) {
            (self.id, self.drafterID, self.retryCooldown) = (id, drafterID, retryCooldown)
        }

        /// The weights it holds, or else the ones a load would bring in.
        func repo(resolve: (String) -> String = { ModelCatalog.repo(for: $0) }) -> String {
            loadedRepo ?? resolve(id)
        }

        /// A load may start: no failed one's cooldown is running.
        func mayLoad(at now: Date = Date()) -> Bool {
            lastFailure.map { now.timeIntervalSince($0) >= retryCooldown } ?? true
        }

        /// Loaded, unused for `limit`, and serving no request.
        func isIdle(for limit: TimeInterval, at now: Date = Date()) -> Bool {
            task != nil && inFlight == 0 && now.timeIntervalSince(lastUse) >= limit
        }
    }

    /// Serializes model lifecycle (load · idle-unload · reload) across the
    /// generation tasks, the idle timer, and the memory-pressure source.
    private let modelLock = NSLock()
    /// True once the initial load was started (false when Metal is missing), so
    /// reload/prewarm only ever rebuild a model we genuinely had.
    private var didInitLoad = false
    /// The primary's `Slot.retryCooldown`.
    private static let loadRetryCooldown: TimeInterval = 30
    /// Requests on either model; the full idle/pressure unload waits for 0.
    /// Under `modelLock`, like `lastActivity`.
    private var inFlight: Int { primary.inFlight + sibling.inFlight }
    /// The last use of either model — drives the idle-unload timer.
    private var lastActivity: Date { max(primary.lastUse, sibling.lastUse) }
    private let maintenanceQueue = DispatchQueue(label: "app.pretype.mlx.maintenance")
    private var idleTimer: DispatchSourceTimer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// The engine's KV snapshots: an unload drops them, the idle trim keeps
    /// the newest.
    private let promptCache: MLXEngine.PromptCache

    /// How to rebuild each unloaded model without the build leak, by repo —
    /// see `keepBlueprint`. Stored as a task the moment the model is let go,
    /// so a load right after waits for it instead of racing it. Handed to the
    /// residency that replaces this one (see `init`).
    private let blueprints: MLXEngine.Blueprints

    /// Parsed tokenizers, kept across idle unloads. Parsing tokenizer.json is
    /// most of a reload — Gemma 1.45 s of ~1.9 s, the weights loading in
    /// parallel finish first — for ~120 MB resident (Qwen3.5 ~86 MB) against
    /// the gigabytes the unload frees. Handed to the residency that replaces
    /// this one for the models they share, else dropped with it; dropped too
    /// when memory pressure forces the unload.
    private let tokenizers: TokenizerCache

    /// How a slot's model is brought in: `loadFromDisk`, which tests swap
    /// for a tiny model to exercise the residency itself.
    typealias Loader = @Sendable (_ repo: String, _ slot: Slot, _ blueprints: MLXEngine.Blueprints,
                                  _ tokenizers: TokenizerCache,
                                  _ progress: @escaping @Sendable (Progress) -> Void) async throws -> ModelContainer
    private let load: Loader
    /// Now, for every use, idle and cooldown time.
    private let clock: @Sendable () -> Date

    /// The weights from disk or the Hub, the drafter with them
    /// (`MLXEngine.loadTarget`), the per-layer table from disk (`HostPLE`).
    static let loadFromDisk: Loader = { repo, slot, blueprints, tokenizers, progress in
        let loaded = try await MLXEngine.loadTarget(repo: repo, drafterID: slot.drafterID, into: slot.drafter,
                                                    tokenizers: tokenizers, blueprints: blueprints, progressHandler: progress)
        await HostPLE.install(in: loaded, repo: repo)
        return loaded
    }

    /// `previous`: the residency of the engine this one replaces, already
    /// shut down — its blueprints and tokenizers carry over for the models
    /// the two share (see `EngineCoordinator.rebuild`). Loads nothing until
    /// `start`.
    /// `load`, `tokenizers` (the cache a first residency starts from) and
    /// `clock` are seams for tests.
    init(primaryID: String, style: CompletionStyle, promptCache: MLXEngine.PromptCache, after previous: ModelResidency?,
         load: @escaping Loader = ModelResidency.loadFromDisk, tokenizers cache: TokenizerCache = TokenizerCache(),
         clock: @escaping @Sendable () -> Date = Date.init) {
        blueprints = previous?.blueprints ?? LockedValue([:])
        tokenizers = previous?.tokenizers ?? cache
        self.clock = clock
        (self.style, self.promptCache, self.load) = (style, promptCache, load)
        let correctionID = ModelCatalog.option(for: primaryID)?.correctionModelID ?? ModelCatalog.options[0].correctionModelID
        primary = Slot(id: primaryID, drafterID: style == .instruct ? ModelCatalog.mtpDrafterID(for: primaryID) : nil,
                       retryCooldown: Self.loadRetryCooldown)
        sibling = Slot(id: correctionID, drafterID: ModelCatalog.mtpDrafterID(for: correctionID), retryCooldown: 0)
        (primary.lastUse, sibling.lastUse) = (clock(), clock())
        // Models shared with the replaced engine reload without the build
        // leak or a tokenizer parse; the rest go.
        let repos: Set<String> = [ModelCatalog.repo(for: primaryID), ModelCatalog.repo(for: correctionID)]
        blueprints.mutate { kept in kept = kept.filter { repos.contains($0.key) } }
        keepTokenizers(of: repos)
    }

    /// Drops every cached tokenizer but those in `repos`' folders.
    private func keepTokenizers(of repos: some Sequence<String>) {
        let folders = repos.compactMap { ModelStorage.cacheDirectory(repo: $0).map { $0.path + "/" } }
        tokenizers.retain { directory in folders.contains { directory.path.hasPrefix($0) } }
    }

    /// The initial load, and the idle and memory-pressure maintenance.
    func start() {
        primary.task = startLoad(primary)
        didInitLoad = true
        startIdleMaintenance()
    }

    /// The state when no model can ever load here (Metal missing): `start`
    /// is never called.
    func fail(_ detail: String) { stateBox.set(.failed(detail)) }

    /// The fix model's progress while it loads, else the primary's state.
    var state: EngineState { correctionStatus.get().map(EngineState.preparing) ?? stateBox.get() }

    var isLoading: Bool { modelLock.withLock { loading } }

    /// `isLoading`, under `modelLock`.
    private var loading: Bool {
        Self.isLoading(primary: stateBox.get(), primaryTaskLive: primary.task != nil,
                       correctionStatus: correctionStatus.get())
    }

    /// `.preparing` with a live task = loading or downloading; `.preparing`
    /// with no task = the idle-unloaded resting state, where nothing runs and
    /// nothing writes — the protocol's default (any `.preparing` is busy)
    /// would report the app's most common state as busy forever. A finished
    /// fix model doesn't count: its task outlives its load.
    static func isLoading(primary: EngineState, primaryTaskLive: Bool, correctionStatus: String?) -> Bool {
        if correctionStatus != nil { return true }
        guard case .preparing = primary else { return false }
        return primaryTaskLive
    }

    /// The completion model is resident or on its way — a context refresh
    /// may prefill into it (`MLXEngine.warmPrompt`), but is no reason to load it.
    var primaryLoadedOrLoading: Bool { modelLock.withLock { primary.task != nil } }

    // MARK: - Load

    /// `slot`'s load: its weights (`loadTarget`), the PLE table served from
    /// disk (`HostPLE`) and, on the primary, a warm-up. The primary reports
    /// to `stateBox`; the fix sibling to `correctionStatus`, which empties
    /// once the load ends so the primary's own state shows through. Called
    /// under `modelLock` (or from `start`): the status is set before the task
    /// runs, so `unload` can't cancel a load that hasn't reported itself yet.
    private func startLoad(_ slot: Slot) -> Task<ModelContainer, Error> {
        let isPrimary = slot === primary
        let (stateBox, correctionStatus, correctionFetched) = (self.stateBox, self.correctionStatus, self.correctionFetched)
        let (tokenizers, blueprints, load, clock) = (self.tokenizers, self.blueprints, self.load, self.clock)
        let report: @Sendable (String) -> Void = { isPrimary ? stateBox.set(.preparing($0)) : correctionStatus.set($0) }
        report(isPrimary ? String(localized: "loading…") : String(localized: "loading fix model…"))
        // Resolved once, so the load report, `fixSlot` and the blueprint all
        // name the build that loaded.
        let repo = ModelCatalog.repo(for: slot.id)
        slot.loadedRepo = repo
        Self.runningLoads.mutate { $0 += 1 }
        return Task { [weak self] in
            defer { Self.runningLoads.mutate { $0 -= 1 } }
            do {
                let loaded = try await load(repo, slot, blueprints, tokenizers) {
                    report(Self.downloadStatus($0, fixModel: !isPrimary))
                }
                ModelStorage.noteLoad(repo: repo, succeeded: true)
                // A finished load is a use: the idle clock starts now, not
                // when a download that can take minutes began — or the model
                // the user waited for unloads within a minute of "ready".
                self?.modelLock.withLock { (slot.lastFailure, slot.lastUse) = (nil, clock()) }
                if isPrimary {
                    try await Self.warmUp(loaded, report: report)
                    stateBox.set(.ready)
                } else {
                    correctionStatus.set(nil)
                    // Whatever the disk probe thought, the weights are provably
                    // here now — and after an idle unload nils the task, this is
                    // what keeps the next fix from being skipped as "not fetched".
                    correctionFetched.set(true)
                }
                return loaded
            } catch {
                // Called off (an engine retired mid-download) is no failure
                // to fall back from.
                if !MLXEngine.isCancellation(error) { ModelStorage.noteLoad(repo: repo, succeeded: false) }
                // Before the slot frees: a retry's fresh status must not be cleared.
                if isPrimary { stateBox.set(.failed(error.localizedDescription)) } else { correctionStatus.set(nil) }
                self?.modelLock.withLock {
                    slot.task = nil
                    slot.loadedRepo = nil
                    slot.lastFailure = self?.clock() ?? Date()
                }
                throw error
            }
        }
    }

    /// The first generation pays for Metal kernel compilation; do it now so
    /// the first real keystroke doesn't. The prompt is long enough to take
    /// the split-prefill path too — a 2-token warm-up left those kernels to
    /// the first keystroke (up to +120 ms on a cold Metal shader cache,
    /// measured). Reloads after an idle unload warm up too: kernels survive
    /// the unload, but the fresh weights and buffer pool don't — skipping it
    /// moved +30–140 ms onto the first keystroke (measured).
    private static func warmUp(_ loaded: ModelContainer, report: (String) -> Void) async throws {
        // Retired mid-load (a model switch, `shutdown`): don't warm up
        // weights nobody will use next to the replacement's.
        try Task.checkCancellation()
        report(String(localized: "warming up…"))
        // A warm-up failure shouldn't block readiness (the next real request
        // surfaces it), but it must not be swallowed silently.
        do {
            _ = try await MLXEngine.generate(
                in: loaded, makeTokens: { $0.tokenizer.encode(text: Self.warmUpPrompt) },
                parameters: GenerateParameters(maxTokens: 3, temperature: 0.0),
                promptCache: nil
            )
        } catch {
            DebugLog.shared.log("ERROR", "warm-up generation failed: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
    }

    private static let warmUpPrompt = String(repeating: "The weekly update covers hiring, the roadmap and next steps. ", count: 7)

    /// A reassuring download line. A multi-GB model otherwise sits at "0%" for
    /// minutes — the percent only reaches 1% after ~1% of several GB, and the
    /// large shards stream over HF's slower Xet path. Showing the byte counts
    /// proves it is alive and moving.
    static func downloadStatus(_ progress: Progress, fixModel: Bool = false) -> String {
        let pct = Int((progress.fractionCompleted * 100).rounded())
        guard progress.totalUnitCount > 0 else {
            return fixModel ? String(localized: "fix model \(pct)%") : String(localized: "downloading \(pct)%")
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        let done = formatter.string(fromByteCount: progress.completedUnitCount)
        let total = formatter.string(fromByteCount: progress.totalUnitCount)
        return fixModel ? String(localized: "fix model \(done) / \(total) (\(pct)%)")
                        : String(localized: "downloading \(done) / \(total) (\(pct)%)")
    }

    /// `slot`'s load task, started if it has none — nil in a failed load's
    /// cooldown. Under `modelLock`.
    private func loadTask(_ slot: Slot) -> Task<ModelContainer, Error>? {
        if let task = slot.task { return task }
        guard slot.mayLoad(at: clock()) else { return nil }
        DebugLog.shared.log("MLX", "loading \(slot.id)")
        slot.task = startLoad(slot)
        return slot.task
    }

    // MARK: - Requests

    /// Marks a request for `role` in flight and returns its hold on the
    /// model, the load started if it was idle-unloaded. nil when no model
    /// ever loads here (Metal missing), after `shutdown`, or in the slot's
    /// failure cooldown — callers then abstain. A fix on the sibling holds
    /// off the idle unload without reloading — or, in its cooldown, refusing
    /// on behalf of — the completion model, which it never touches. Pair
    /// with `end`.
    func begin(_ role: Role) -> Lease? {
        modelLock.withLock {
            let slot = role == .completion ? primary : fixSlotUnderLock
            guard didInitLoad, let task = loadTask(slot) else { return nil }
            slot.inFlight += 1
            slot.lastUse = clock()
            return Lease(task: task, slot: slot)
        }
    }

    func end(_ lease: Lease) {
        modelLock.withLock {
            lease.slot.inFlight = max(0, lease.slot.inFlight - 1)
            lease.slot.lastUse = clock()
        }
    }

    /// `role`'s model, loaded if it has none (not in its failure cooldown —
    /// a focus change shouldn't retry a model that just failed to load).
    /// Starting a load counts as use; so does any fix prewarm — a dictation
    /// about to tidy up through the fix model, which the idle timer must not
    /// free meanwhile. A focus change alone is no use.
    func prewarm(_ role: Role) {
        modelLock.withLock {
            let slot = role == .completion ? primary : fixSlotUnderLock
            guard didInitLoad, role == .fix || slot.task == nil, loadTask(slot) != nil else { return }
            slot.lastUse = clock()
        }
    }

    /// Whether a fix would cost at most a LOAD, never a download.
    ///
    /// Deliberately not "is the model resident": an idle-unloaded model is
    /// still on disk, and re-reading it is exactly the kind of wait the
    /// tidy-up's own budget is there to bound. What no budget can absorb is a
    /// multi-gigabyte fetch — so that, and only that, answers false.
    ///
    /// Both styles are probed, and the first draft of this was wrong to skip
    /// instruct: it fixes with the PRIMARY model, which is only "already here"
    /// after its own first download — on a fresh install that is the same
    /// multi-gigabyte wait, reached by a different branch.
    ///
    /// Memoized once true: the answer can only go from "not fetched" to
    /// "fetched" while an engine lives. The first probe is still a small
    /// directory read on whatever thread asks (often main); the memo only
    /// spares every call after it.
    var isCorrectionReady: Bool {
        if correctionFetched.get() { return true }
        let fetched = ModelStorage.isFetched(modelLock.withLock { fixSlotUnderLock.id })
        if fetched { correctionFetched.set(true) }
        return fetched
    }

    /// The model fixes and replies run on — decided here and nowhere else,
    /// from the weights each slot holds (`Slot.repo`), not from what the
    /// disk would resolve now. Under `modelLock`.
    private var fixSlotUnderLock: Slot {
        Self.fixesOnPrimary(style: style, primary: primary.repo(), sibling: sibling.repo()) ? primary : sibling
    }

    /// Fixes and replies run on the primary when it is an instruct model, or
    /// when the sibling's weights are the ones it holds — the same repo, or
    /// its slim re-pack (`ModelCatalog.slimRepos`). Ternary Bonsai and the
    /// M40 merge fix with themselves, and an old 8 GB install holding only
    /// Qwen3.5's post-trained 4-bit completes on that build until the 6-bit
    /// one is fetched — and, with the 4-bit still resident, after: the
    /// sibling resolves to it either way. Compared by id, or by what the disk
    /// resolves once the 6-bit build landed, the first ⌥⇥ loaded a second
    /// 1.7 GB copy. `primary` and `sibling` are repos.
    static func fixesOnPrimary(style: CompletionStyle, primary: String, sibling: String) -> Bool {
        func weights(_ repo: String) -> String { ModelCatalog.slimRepos.first { $0.value == repo }?.key ?? repo }
        return style == .instruct || weights(primary) == weights(sibling)
    }

    // MARK: - Unload

    /// Free the resident models right now (menu action). Reloads on next use.
    func releaseNow() {
        unload(reason: "manual", force: true)
    }

    /// The system needs memory. The models go, unless one is mid-request,
    /// mid-load or used within 3 s; the blueprints go whatever the models'
    /// state — idle-unloaded, the common one, is where they are all that is
    /// left — and so do the parsed tokenizers, but a resident model's: it
    /// holds that tokenizer anyway, so dropping the entry frees nothing and
    /// costs a re-parse (~1.45 s of a ~1.9 s Gemma reload) on the way back.
    func relieveMemoryPressure() {
        blueprints.set([:])
        unload(reason: "memory pressure")
        keepTokenizers(of: modelLock.withLock { [primary, sibling].filter { $0.task != nil }.compactMap(\.loadedRepo) })
    }

    /// What a replacing residency inherits (see `init`), for tests.
    var handOver: (blueprints: MLXEngine.Blueprints, tokenizers: TokenizerCache) { (blueprints, tokenizers) }

    /// What each slot holds (`Slot.loadedRepo`), for tests.
    var loadedRepos: (primary: String?, sibling: String?) {
        modelLock.withLock { (primary.loadedRepo, sibling.loadedRepo) }
    }

    /// Releases the resident models (weights + buffer cache) so an idle
    /// menu-bar app doesn't hold several GB. The next request or prewarm
    /// reloads them from disk. No-op while a request is in flight, mid-load,
    /// or just used.
    private func unload(reason: String, force: Bool = false) {
        modelLock.lock()
        let idleEnough = force || clock().timeIntervalSince(lastActivity) > 3
        // Not mid-load. An idle-unloaded or failed primary (its task is nil
        // either way) still lets a fix model that loaded on its own
        // (prewarmCorrection, a base-style ⌥⇥) be freed.
        guard inFlight == 0, idleEnough, primary.task != nil || sibling.task != nil, !loading else {
            modelLock.unlock(); return
        }
        let before = Memory.snapshot().activeMemory
        let pressure = reason == "memory pressure"
        // Still under the lock: a request arriving the moment it drops starts
        // a reload, and these writes landing after it would erase that load's
        // drafter and paint "idle" over its "loading…".
        letGo(primary, keep: !pressure)
        letGo(sibling, keep: !pressure)
        promptCache.clear()
        // After the KV snapshots go, not before: freeing them refills the
        // buffer pool, and it then sat at its 64 MB cap for the whole idle.
        Memory.clearCache()
        // A failure stays on screen until a retry replaces it.
        if case .failed = stateBox.get() {} else { stateBox.set(.preparing(String(localized: "idle — model unloaded"))) }
        modelLock.unlock()

        let freed = Int64(max(0, before - Memory.snapshot().activeMemory))
        let amount = ByteCountFormatter.string(fromByteCount: freed, countStyle: .memory)
        DebugLog.shared.log("MLX", "unloaded model (\(reason)) — freed ~\(amount)")
    }

    /// Frees the base style's fix sibling alone once it has sat unused for
    /// `limit` while completions keep the primary busy. Not mid-load, not
    /// mid-request; the next fix, reply or dictation reloads it.
    private func unloadSibling(idleFor limit: TimeInterval) {
        let idle: TimeInterval? = modelLock.withLock {
            guard style == .base, sibling.isIdle(for: limit, at: clock()), correctionStatus.get() == nil else { return nil }
            letGo(sibling, keep: true)
            return clock().timeIntervalSince(sibling.lastUse)
        }
        guard let idle else { return }
        Memory.clearCache()
        DebugLog.shared.log("MLX", "unloaded fix model (idle \(Int(idle))s)")
    }

    /// Lets go of `slot`, under `modelLock`: its load task, cancelled, and
    /// its drafter — the blueprint recorded first when `keep` (see
    /// `keepBlueprint`).
    private func letGo(_ slot: Slot, keep: Bool) {
        if keep {
            MLXEngine.keepBlueprint(slot.task, repo: slot.repo(), in: blueprints)
        }
        slot.task?.cancel()
        slot.task = nil
        slot.loadedRepo = nil
        slot.drafter.set(nil)
    }

    /// A minute without typing: keep the newest KV snapshot only, and hand the
    /// buffer pool back — ~100 MB of other fields' snapshots plus up to 64 MB
    /// (and tens of thousands of tiny Metal buffers) pooled for a keystroke
    /// that isn't coming. Not mid-request; the next one refills what it needs.
    private func trimWhileIdle() {
        modelLock.withLock {
            guard inFlight == 0, primary.task != nil else { return }
            promptCache.keepNewest()
            Memory.clearCache()
        }
    }

    /// One tick of the idle timer, as a rule: past the idle-unload `limit`
    /// (0 = never) with nothing running, everything goes; short of it, the fix
    /// sibling may go on its own clock, and a minute without use trims the
    /// KV snapshots and the buffer pool — under "never" too.
    enum IdleStep: Equatable { case unloadAll, unloadIdleSibling, trim }

    static func idleSteps(limit: TimeInterval, idle: TimeInterval, busy: Bool) -> [IdleStep] {
        if limit > 0, !busy, idle >= limit { return [.unloadAll] }
        return (limit > 0 ? [.unloadIdleSibling] : []) + (!busy && idle >= 60 ? [.trim] : [])
    }

    /// Idle-unload timer + memory-pressure source: both free the model when it
    /// is unused or the system needs RAM; the next use reloads it.
    private func startIdleMaintenance() {
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: maintenanceQueue
        )
        pressure.setEventHandler { [weak self] in
            self?.relieveMemoryPressure()
        }
        pressure.resume()
        memoryPressureSource = pressure

        // The idle timer always runs; the timeout is read live so the Settings
        // control takes effect without an engine reload.
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.idleTick() }
        timer.resume()
        idleTimer = timer
    }

    /// One minute of the idle timer (`idleSteps`). `limit`: the idle-unload
    /// setting, read live so a change applies without an engine reload.
    func idleTick(limit: TimeInterval = TimeInterval(Settings.idleUnloadMinutes) * 60) {
        let (idle, busy) = modelLock.withLock { (clock().timeIntervalSince(lastActivity), inFlight > 0) }
        for step in Self.idleSteps(limit: limit, idle: idle, busy: busy) {
            switch step {
            case .unloadAll: unload(reason: "idle \(Int(idle))s")
            case .unloadIdleSibling: unloadSibling(idleFor: limit)
            case .trim: trimWhileIdle()
            }
        }
    }

    func shutdown() {
        idleTimer?.cancel(); idleTimer = nil
        memoryPressureSource?.cancel(); memoryPressureSource = nil
        modelLock.withLock {
            // A late `warmPrompt` or prewarm on this retired engine must not
            // rebuild a whole model next to the replacement's.
            didInitLoad = false
            // For the replacement (see `init`). Not mid-request (the husk
            // would be emptied under a running generation) nor mid-load (the
            // replacement's load would wait on this cancelled one).
            let keep = inFlight == 0 && !loading
            letGo(primary, keep: keep)
            letGo(sibling, keep: keep)
        }
    }

    deinit {
        idleTimer?.cancel()
        memoryPressureSource?.cancel()
    }
}
