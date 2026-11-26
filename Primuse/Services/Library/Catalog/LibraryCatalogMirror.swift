import Foundation
import PrimuseKit

/// 目录跟着内存模型要的输入:分组配置、停用的源、源的显示名。
struct LibraryCatalogMirrorInputs: Equatable, Sendable {
    var grouping: LibraryGroupingConfiguration
    var disabledSourceIDs: Set<String>
    /// nil:调用方还没给(不改目录里已有的名字)。
    var sourceNames: [String: String]?
}

/// 目录的变化,发给读接口(行缓存失效)与主线程上的修订号。
enum LibraryCatalogMirrorEvent: Sendable {
    /// 一次增量写入。`touchedSourceIDs` 只含这次写入的歌所在的源(删除的行不知道源,算全局)。
    case applied(LibraryCatalogChangeSummary, touchedSourceIDs: Set<String>)
    /// 导入、整库分组重建、对账、换配置:整个目录都可能变了。
    case invalidatedAll(reason: String)
    /// 目录能不能读(导入、分组都做完、没有待对账)。
    case readability(Bool)
    /// 目录已经是旧库这个修订号的样子(增量写完、导入或对账做完)。在工作线程上、下一次写目录之前发出。
    case mirrored(storeRevision: Int64)
    /// 不再跟写(停下、出错):目录不会再跟上内存模型。
    case stoppedFollowing
}

struct LibraryCatalogMirrorStatistics: Sendable, Equatable {
    var importRuns = 0
    var importsCompleted = 0
    /// 最近一次导入开始时目录里已经导入的行数(续导的证据)。
    var lastImportStartedAt: Int?
    var resyncs = 0
    var resyncFallbacksToImport = 0
    var groupingRebuilds = 0
    var appliedOperations = 0
    var skippedOperations = 0
    var overflows = 0
    var failures = 0
}

struct LibraryCatalogMirrorEnvironment: Sendable {
    var catalogURL: URL
    var storeURL: URL
    /// 还没有目录文件(第一次迁移)时,启动后等这么久再开始(不跟冷启动抢资源)。已有目录直接打开;
    /// 打开后发现上次没导完时等 `resumeDelay` 再续。
    var startDelay: Duration = .seconds(3)
    var resumeDelay: Duration = .seconds(1)
    var importBatchSize = LibraryScale.importBatchSize
    var applyChunkSize = LibraryScale.importBatchSize
    /// 排队等写的歌超过这么多就丢掉队列、改为对账(队列里的歌不能攒成整库规模)。
    var maximumQueuedSongs = 50_000
    /// 校验请求最多等这么久(目录追上内存模型那一刻)。
    var verificationTimeout: Duration = .seconds(120)
    /// 主线程上问一次:此刻能不能做后台目录工作(没在滑、没有转场、App 在前台、温度正常、没在扫描)。
    /// 只管整库的活:打开、迁移、对账、整库分组重建、补建排序索引。
    var interactionGate: @Sendable () async -> Bool = { true }
    /// 增量写入(一次突变、一批扫描结果)只在用户正在滑的时候让一让,后台、扫描中、温度高时照样写,
    /// 目录才跟得上内存模型(读目录的地方不读到旧值)。
    var incrementalApplyGate: @Sendable () async -> Bool = { true }
    /// 增量写入为滑动让路最多让这么久,之后照写(一批的耗时以 `applyChunkSize` 为界)。
    var incrementalApplyMaximumPause: Duration = .seconds(1)
    var log: @Sendable (String) -> Void = { _ in }
    /// 测试:导入每写完一批调一次,返回 false 模拟进程在这里被杀。
    var importBatchHook: (@Sendable (LibraryCatalogImportProgress) -> Bool)?
}

/// 曲库目录(`library-catalog.sqlite`)在 App 里的持有者。P1 阶段旧的内存模型仍是真相,
/// 目录只跟着写:
/// - 打开、首次迁移(从 `library-songs.sqlite` 可续导入 + 整库分组)、按需对账,都在后台串行队列上做,
///   滑动、转场时原地停下;
/// - 每次写进 `library-songs.sqlite` 的增量按同样的顺序排进来,合并成有界的批写进目录,
///   写完记下镜像到的旧库修订号(`mirror.storeRevision`),下次启动据此发现漂移。
///   增量写入不等整库那道门(后台、扫描中照写),只为正在进行的滑动短暂让路;
/// - 写失败只记日志,本次不再写,下次启动对账。永远不影响旧路径。
final class LibraryCatalogMirror: @unchecked Sendable {
    enum Operation: Sendable {
        /// `renaming`:只换了 id 的歌(旧 id → 新 id),目录原地改名(与旧库一致)。
        case apply(upserts: [Song], deletingIDs: Set<String>, renaming: [String: String], storeRevision: Int64)
        case replaceAll(storeRevision: Int64)

        var songCount: Int {
            switch self {
            case .apply(let upserts, let deletingIDs, let renaming, _): return upserts.count + deletingIDs.count + renaming.count
            case .replaceAll: return 0
            }
        }
    }

    private struct PendingVerification {
        let request: LibraryCatalogShadowRequest
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<LibraryCatalogShadowReport?, Never>?
    }

    private struct State {
        var started = false
        var stopped = false
        var poisoned = false
        var catalog: LibraryCatalog?
        var readable = false
        var operations: [Operation] = []
        var queuedSongs = 0
        var overflowed = false
        var inputs: LibraryCatalogMirrorInputs?
        var appliedInputs: LibraryCatalogMirrorInputs?
        var folderIndex: AlbumArtistFolderIndex?
        var fileNameIndexes: [String: SourceSyncIndex?] = [:]
        var verifications: [PendingVerification] = []
        var wakeup: CheckedContinuation<Void, Never>?
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var idle = false
        var statistics = LibraryCatalogMirrorStatistics()
        var lastShadowReport: LibraryCatalogShadowReport?
        var mirroredRevision: Int64?
        var worker: Task<Void, Never>?
    }

    let environment: LibraryCatalogMirrorEnvironment
    private let events: @Sendable (LibraryCatalogMirrorEvent) -> Void
    private let lock = NSLock()
    private var state = State()
    /// 目录的读写都在这条串行队列上同步执行(阻塞的 SQLite 工作不占 Swift 并发线程池)。
    private let workQueue = DispatchQueue(label: "com.primuse.library-catalog.mirror", qos: .utility)
    private let interaction = InteractionFlag()
    /// 增量写入要不要让路(只看滑动)。
    private let applyInteraction = InteractionFlag()
    /// 只在工作线程上(经 `perform` 串行)读写。
    private var progress = Progress()

    init(
        environment: LibraryCatalogMirrorEnvironment,
        events: @escaping @Sendable (LibraryCatalogMirrorEvent) -> Void = { _ in }
    ) {
        self.environment = environment
        self.events = events
    }

    // MARK: - Public surface (thread-safe)

    /// 开始后台工作(打开、迁移、跟写)。重复调用无效。
    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }
        let task = Task.detached(priority: .utility) { [self] in
            await self.run()
        }
        lock.withLock { state.worker = task }
    }

    /// 停下(测试、库释放)。在途的一批写完就退出;等待中的调用方都会被唤醒。
    func stop() async {
        let (wakeup, waiters, verifications, worker, wasFollowing) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, [CheckedContinuation<Void, Never>], [PendingVerification], Task<Void, Never>?, Bool) in
            let wasFollowing = !state.stopped && !state.poisoned
            state.stopped = true
            let wakeup = state.wakeup
            state.wakeup = nil
            let waiters = state.idleWaiters
            state.idleWaiters = []
            let verifications = state.verifications
            state.verifications = []
            return (wakeup, waiters, verifications, state.worker, wasFollowing)
        }
        if wasFollowing { events(.stoppedFollowing) }
        wakeup?.resume()
        waiters.forEach { $0.resume() }
        verifications.forEach { $0.continuation?.resume(returning: nil) }
        await worker?.value
    }

    /// 库释放时调用:不等工作线程退出。
    func requestStop() {
        Task { [self] in await self.stop() }
    }

    var isStopped: Bool { lock.withLock { state.stopped } }

    /// 目录可读时给出句柄(导入与分组都做完、没有待对账、没出过错)。
    var readableCatalog: LibraryCatalog? {
        lock.withLock { state.readable && !state.poisoned ? state.catalog : nil }
    }

    var statistics: LibraryCatalogMirrorStatistics { lock.withLock { state.statistics } }
    var lastShadowReport: LibraryCatalogShadowReport? { lock.withLock { state.lastShadowReport } }
    var mirroredStoreRevision: Int64? { lock.withLock { state.mirroredRevision } }

    /// `library-songs.sqlite` 刚提交了一次增量(按提交顺序调用)。
    func enqueueApply(upserts: [Song], deletingIDs: Set<String>, renaming: [String: String] = [:], storeRevision: Int64) {
        guard !upserts.isEmpty || !deletingIDs.isEmpty || !renaming.isEmpty else { return }
        enqueue(.apply(upserts: upserts, deletingIDs: deletingIDs, renaming: renaming, storeRevision: storeRevision))
    }

    /// `library-songs.sqlite` 刚被整份替换(外部快照、恢复写入、首次播种)。
    func enqueueReplaceAll(storeRevision: Int64) {
        enqueue(.replaceAll(storeRevision: storeRevision))
    }

    private func enqueue(_ operation: Operation) {
        let wakeup = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !state.stopped, !state.poisoned else { return nil }
            switch operation {
            case .replaceAll:
                // 整份替换之前排着的增量都被它盖掉了。
                state.operations = [operation]
                state.queuedSongs = 0
                state.overflowed = false
            case .apply:
                if state.overflowed { return takeWakeup() }
                if state.queuedSongs + operation.songCount > environment.maximumQueuedSongs {
                    state.operations.removeAll { if case .apply = $0 { return true } else { return false } }
                    state.queuedSongs = 0
                    state.overflowed = true
                    state.statistics.overflows += 1
                } else {
                    state.operations.append(operation)
                    state.queuedSongs += operation.songCount
                }
            }
            return takeWakeup()
        }
        wakeup?.resume()
    }

    func updateInputs(_ inputs: LibraryCatalogMirrorInputs) {
        let wakeup = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard state.inputs != inputs else { return nil }
            state.inputs = inputs
            return takeWakeup()
        }
        wakeup?.resume()
    }

    /// 按文件 id 寻址的网盘:扫描索引给的父文件夹(内存模型用的那一整份)。
    /// 索引里没有的源按路径取目录;以前给过、这次没有的源恢复按路径。
    func updateFolderParents(_ index: AlbumArtistFolderIndex) {
        let wakeup = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            state.folderIndex = index
            return takeWakeup()
        }
        wakeup?.resume()
    }

    /// 文件名排序用的扫描索引(只在内存排序也用它的平台上给)。值为 nil 恢复按路径取名。
    func updateFileNameIndexes(_ indexes: [String: SourceSyncIndex?]) {
        guard !indexes.isEmpty else { return }
        let wakeup = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            for (sourceID, index) in indexes { state.fileNameIndexes[sourceID] = .some(index) }
            return takeWakeup()
        }
        wakeup?.resume()
    }

    /// 排一次影子校验:目录追上 `request.storeRevision`、输入与请求一致时比对;过时了就跳过。
    @discardableResult
    func verify(_ request: LibraryCatalogShadowRequest) async -> LibraryCatalogShadowReport? {
        await withCheckedContinuation { continuation in
            let wakeup = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard !state.stopped, !state.poisoned else {
                    continuation.resume(returning: nil)
                    return nil
                }
                state.verifications.append(PendingVerification(
                    request: request,
                    deadline: .now + environment.verificationTimeout,
                    continuation: continuation
                ))
                return takeWakeup()
            }
            wakeup?.resume()
        }
    }

    /// 等到手上的工作都做完(测试与发版前对账用)。没启动或已停止时立即返回。
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if !state.started || state.stopped || state.poisoned { return true }
                if state.idle, state.operations.isEmpty, !state.overflowed, state.verifications.isEmpty,
                   state.inputs == state.appliedInputs, state.folderIndex == nil, state.fileNameIndexes.isEmpty {
                    return true
                }
                state.idleWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// 调用时必须持锁。
    private func takeWakeup() -> CheckedContinuation<Void, Never>? {
        state.idle = false
        let wakeup = state.wakeup
        state.wakeup = nil
        return wakeup
    }

    // MARK: - Worker

    private enum Step {
        case configure(LibraryCatalogMirrorInputs?, AlbumArtistFolderIndex?, [String: SourceSyncIndex?])
        case operations([Operation], overflowed: Bool)
        case verify([PendingVerification])
        case idle
    }

    /// 只在工作线程上读写。
    private struct Progress {
        var needsImport = false
        var needsResync = false
        var mirroredRevision: Int64?
        /// 导入或对账开始时旧库的修订号:修订号不超过它的排队增量已经包含在内。
        var baselineRevision: Int64?
    }

    private func run() async {
        // 迁移过的目录打开只要几十毫秒:直接开,读目录的地方从启动那一刻起就能用。
        // 还没有目录(第一次迁移)才先等 `startDelay`,不跟冷启动抢资源;续导等 `resumeDelay`(见下)。
        let catalogExisted = FileManager.default.fileExists(atPath: environment.catalogURL.path)
        if !catalogExisted, environment.startDelay > .zero { try? await Task.sleep(for: environment.startDelay) }
        guard !isStopped else { return finishWorker() }
        await waitForGate()
        guard !isStopped else { return finishWorker() }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let opened: (LibraryCatalog, IncrementalSongStoreScanner)
        do {
            opened = try await perform { [self] in try self.open() }
        } catch {
            environment.log("📚 catalog open failed: \(error.localizedDescription)")
            poison()
            return finishWorker()
        }
        let (catalog, scanner) = opened
        let summary = await performNonThrowing { [self] in
            (self.progress.needsImport, self.progress.needsResync, self.progress.mirroredRevision)
        }
        lock.withLock {
            state.catalog = catalog
            state.mirroredRevision = summary.2
        }
        if catalogExisted, summary.0, environment.resumeDelay > .zero {
            // 上次没导完:稍等再续,不跟冷启动抢资源。
            try? await Task.sleep(for: environment.resumeDelay)
            guard !isStopped else { return finishWorker() }
        }
        environment.log(String(
            format: "📚 catalog open ms=%.0f import=%@ resync=%@ mirrored=%@",
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            summary.0 ? "needed" : "done",
            summary.1 ? "needed" : "no",
            summary.2.map(String.init) ?? "none"
        ))

        let watcher = Task.detached(priority: .utility) { [environment, interaction, applyInteraction] in
            while !Task.isCancelled {
                let allowed = await environment.interactionGate()
                interaction.set(!allowed)
                let applyAllowed = await environment.incrementalApplyGate()
                applyInteraction.set(!applyAllowed)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }

        while !isStopped {
            do {
                // 配置先于导入:导入按目录当前的分组配置逐行派生,配置不对就要再整库重建一遍。
                if case .configure(let inputs, let parents, let fileNames) = nextConfigurationStep() {
                    try await perform { [self] in
                        try self.applyConfiguration(inputs, folderParents: parents, fileNameIndexes: fileNames, catalog: catalog)
                    }
                    continue
                }
                // 还没拿到输入(App 侧先给输入再启动,这里只是兜底):先不动目录。
                guard lock.withLock({ state.appliedInputs != nil }) else {
                    await waitForWork()
                    continue
                }
                let pending = await performNonThrowing { [self] in (self.progress.needsImport, self.progress.needsResync) }
                if pending.0 {
                    setReadable(false)
                    try await perform { [self] in try self.runImport(catalog: catalog, scanner: scanner) }
                    continue
                }
                if try await perform({ try catalog.groupingNeedsRebuild }) {
                    setReadable(false)
                    try await perform { [self] in try self.runGroupingRebuild(catalog: catalog) }
                    continue
                }
                if pending.1 {
                    setReadable(false)
                    try await perform { [self] in try self.runResync(catalog: catalog, scanner: scanner) }
                    continue
                }
                setReadable(true)
                switch nextStep() {
                case .configure:
                    continue
                case .operations(let operations, let overflowed):
                    try await perform { [self] in
                        try self.applyOperations(operations, overflowed: overflowed, catalog: catalog, scanner: scanner)
                    }
                case .verify(let verifications):
                    await performNonThrowing { [self] in
                        self.runVerifications(verifications, catalog: catalog)
                    }
                case .idle:
                    // 迁移后留到后台的排序索引(艺人、专辑、文件名)在空闲时补:排序照样对,只是没建好前要整表排。
                    if try await perform({ try catalog.hasPendingSortIndexes() }),
                       try await perform({ [self] in try self.runPendingSortIndexes(catalog: catalog) }) {
                        continue
                    }
                    await waitForWork()
                }
            } catch LibraryCatalogError.cancelled {
                continue
            } catch {
                environment.log("⛔ catalog dual-write failed; the catalog re-syncs on the next launch: \(error.localizedDescription)")
                lock.withLock { state.statistics.failures += 1 }
                poison()
                break
            }
        }
        finishWorker()
    }

    private func open() throws -> (LibraryCatalog, IncrementalSongStoreScanner) {
        try FileManager.default.createDirectory(
            at: environment.catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let catalog = try LibraryCatalog(path: environment.catalogURL.path)
        let scanner = try IncrementalSongStoreScanner(path: environment.storeURL.path)
        let storeRevision = try scanner.contentRevision()
        progress = Progress()
        progress.mirroredRevision = try catalog.mirrorMetadata(MetaKey.storeRevision).flatMap(Int64.init)
        if try !catalog.hasCompletedImport {
            progress.needsImport = true
        } else if progress.mirroredRevision != storeRevision {
            environment.log("📚 catalog drift store=\(storeRevision) mirrored=\(progress.mirroredRevision.map(String.init) ?? "none")")
            progress.needsResync = true
        } else {
            let storeCount = try scanner.songCount()
            let catalogCount = try catalog.songCount(.everything)
            if storeCount != catalogCount {
                environment.log("📚 catalog drift store=\(storeCount) catalog=\(catalogCount) songs at the same revision")
                progress.needsResync = true
            }
        }
        return (catalog, scanner)
    }

    private func nextConfigurationStep() -> Step? {
        lock.withLock {
            guard state.inputs != state.appliedInputs || state.folderIndex != nil || !state.fileNameIndexes.isEmpty
            else { return nil }
            let step = Step.configure(
                state.inputs != state.appliedInputs ? state.inputs : nil,
                state.folderIndex,
                state.fileNameIndexes
            )
            state.folderIndex = nil
            state.fileNameIndexes = [:]
            return step
        }
    }

    private func nextStep() -> Step {
        if let configure = nextConfigurationStep() { return configure }
        return lock.withLock {
            if !state.operations.isEmpty || state.overflowed {
                let step = Step.operations(state.operations, overflowed: state.overflowed)
                state.operations = []
                state.queuedSongs = 0
                state.overflowed = false
                return step
            }
            if !state.verifications.isEmpty {
                let pending = state.verifications
                state.verifications = []
                return .verify(pending)
            }
            return .idle
        }
    }

    private func waitForWork() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (resumeNow, waiters) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                let hasWork = state.stopped || state.inputs != state.appliedInputs || state.folderIndex != nil
                    || !state.fileNameIndexes.isEmpty || !state.operations.isEmpty || state.overflowed
                    || !state.verifications.isEmpty
                if hasWork { return (true, []) }
                state.idle = true
                state.wakeup = continuation
                let waiters = state.idleWaiters
                state.idleWaiters = []
                return (false, waiters)
            }
            waiters.forEach { $0.resume() }
            if resumeNow { continuation.resume() }
        }
    }

    private func finishWorker() {
        let (waiters, verifications) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], [PendingVerification]) in
            state.idle = true
            let waiters = state.idleWaiters
            state.idleWaiters = []
            let verifications = state.verifications
            state.verifications = []
            return (waiters, verifications)
        }
        waiters.forEach { $0.resume() }
        verifications.forEach { $0.continuation?.resume(returning: nil) }
    }

    private func poison() {
        let (changed, wasFollowing) = lock.withLock { () -> (Bool, Bool) in
            let wasFollowing = !state.stopped && !state.poisoned
            state.poisoned = true
            state.operations = []
            state.queuedSongs = 0
            let changed = state.readable
            state.readable = false
            return (changed, wasFollowing)
        }
        if changed { events(.readability(false)) }
        if wasFollowing { events(.stoppedFollowing) }
    }

    private func setReadable(_ readable: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard state.readable != readable else { return false }
            state.readable = readable
            return true
        }
        if changed { events(.readability(readable)) }
    }

    private func waitForGate() async {
        while !isStopped {
            if await environment.interactionGate() {
                interaction.set(false)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// 在工作队列上调用:用户在滑动、转场时原地等(不放弃已经做到一半的批次)。
    /// 停止时抛 `cancelled`。
    private func pauseWhileInteracting() throws {
        while interaction.isSet {
            if isStopped { throw LibraryCatalogError.cancelled }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if isStopped { throw LibraryCatalogError.cancelled }
    }

    /// 在工作队列上、可读期间的整库活两步之间调用:排着增量、或者已经停止时返回 true(先停下);
    /// 整库那道门关着时原地等,其间来了增量也停下。
    private func bulkWorkShouldYield() -> Bool {
        while true {
            if isStopped { return true }
            if lock.withLock({ !state.operations.isEmpty || state.overflowed }) { return true }
            if !interaction.isSet { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// 在工作队列上调用:增量写入前,用户正在滑就等一等,最多等 `incrementalApplyMaximumPause`。
    /// 停止时抛 `cancelled`。
    private func pauseForIncrementalApply() throws {
        let deadline = ContinuousClock.now.advanced(by: environment.incrementalApplyMaximumPause)
        while applyInteraction.isSet, ContinuousClock.now < deadline {
            if isStopped { throw LibraryCatalogError.cancelled }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isStopped { throw LibraryCatalogError.cancelled }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func performNonThrowing<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            workQueue.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - Import (first migration, replaced store)

    private func runImport(catalog: LibraryCatalog, scanner: IncrementalSongStoreScanner) throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let baseline = try scanner.contentRevision()
        let hook = environment.importBatchHook
        let log = environment.log
        let killed = InteractionFlag()
        var firstReport: Int?
        var batches = 0
        lock.withLock { state.statistics.importRuns += 1 }
        LibraryCatalogImportProfile.reset()
        log("📚 catalog import stage=begin storeRevision=\(baseline)")
        let result = try LibraryCatalogImporter.importIncrementalSongStore(
            at: environment.storeURL.path,
            into: catalog,
            batchSize: environment.importBatchSize,
            progress: { [self] report in
                if firstReport == nil {
                    firstReport = report.imported
                    let resumedFrom = max(0, report.imported - min(environment.importBatchSize, report.imported))
                    lock.withLock { state.statistics.lastImportStartedAt = resumedFrom }
                }
                batches += 1
                if batches.isMultiple(of: 25) || report.isComplete {
                    log("📚 catalog import stage=batch imported=\(report.imported)/\(report.total)")
                }
                if let hook, !hook(report) {
                    killed.set(true)
                    lock.withLock { state.stopped = true }
                }
                // 批与批之间:在滑就原地等,不丢已导入的进度(不同进程之间靠 meta 里的游标续导)。
                while interaction.isSet && !isStopped && !killed.isSet { Thread.sleep(forTimeInterval: 0.1) }
            },
            isCancelled: { [self] in killed.isSet || isStopped }
        )
        guard result.isComplete else { throw LibraryCatalogError.cancelled }
        progress.needsImport = false
        progress.needsResync = false
        progress.baselineRevision = baseline
        try recordMirroredRevision(baseline, catalog: catalog)
        lock.withLock { state.statistics.importsCompleted += 1 }
        log(String(
            format: "📚 catalog import stage=done songs=%d ms=%.0f %@",
            result.total,
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            LibraryCatalogImportProfile.summary()
        ))
        events(.invalidatedAll(reason: "import"))
    }

    private func runGroupingRebuild(catalog: LibraryCatalog) throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        environment.log("📚 catalog grouping stage=begin")
        try catalog.rebuildGrouping(isCancelled: { [self] in
            (try? pauseWhileInteracting()) == nil
        })
        lock.withLock { state.statistics.groupingRebuilds += 1 }
        environment.log(String(
            format: "📚 catalog grouping stage=done ms=%.0f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        ))
        events(.invalidatedAll(reason: "grouping"))
    }

    /// 补建迁移后留到后台的排序索引。每条一个写事务,用户在滑动时停在两条之间等;
    /// 排进了增量就先停下,让循环先把增量写进目录,下次空闲再接着建。
    /// 建好返回 true,停下或目录拒绝(导入还没收尾)返回 false。
    private func runPendingSortIndexes(catalog: LibraryCatalog) throws -> Bool {
        let startedAt = ProcessInfo.processInfo.systemUptime
        environment.log("📚 catalog sortIndexes stage=begin")
        let done = try catalog.buildPendingSortIndexes(isCancelled: { [self] in
            bulkWorkShouldYield()
        })
        environment.log(String(
            format: "📚 catalog sortIndexes stage=%@ ms=%.0f", done ? "done" : "deferred",
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        ))
        return done
    }

    // MARK: - Drift re-sync (streams ids, no re-import)

    /// 旧库在目录没跟上的时候写过(两次写之间被杀、旧版本只写了旧库、目录写失败过):
    /// 按库内顺序分批读旧库,交给目录的 upsert(没变的行目录自己跳过),再删掉旧库里没有的行。
    /// 行序对不上(旧版本整份替换过)就改为重新导入。
    private func runResync(catalog: LibraryCatalog, scanner: IncrementalSongStoreScanner) throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let baseline = try scanner.contentRevision()
        lock.withLock { state.statistics.resyncs += 1 }
        environment.log("📚 catalog resync stage=begin storeRevision=\(baseline)")

        // 目录里现有行的库内顺序(4 字节一行,与行号列表同阶)。
        let order = try catalog.rowList(.everything)
        let maximumRowid = Int(order.rowids.max() ?? 0)
        var positionByRowid = ContiguousArray<Int32>(repeating: -1, count: maximumRowid + 1)
        for (position, rowid) in order.rowids.enumerated() { positionByRowid[Int(rowid)] = Int32(position) }

        var cursor: (orderKey: Int64, id: String)?
        var lastPosition: Int32 = -1
        var sawNewRow = false
        var changedRows = 0
        while true {
            try pauseWhileInteracting()
            let rows = try scanner.rows(after: cursor, limit: environment.applyChunkSize)
            guard let last = rows.last else { break }
            let rowids = try catalog.rowids(forIDs: rows.map(\.song.id))
            for rowid in rowids {
                if let rowid, Int(rowid) < positionByRowid.count, positionByRowid[Int(rowid)] >= 0 {
                    let position = positionByRowid[Int(rowid)]
                    if sawNewRow || position <= lastPosition {
                        environment.log("📚 catalog resync stage=reordered → full import")
                        lock.withLock { state.statistics.resyncFallbacksToImport += 1 }
                        try catalog.invalidateImport()
                        progress.needsResync = false
                        progress.needsImport = true
                        return
                    }
                    lastPosition = position
                } else {
                    sawNewRow = true
                }
            }
            let summary = try catalog.apply(upserts: rows.map(\.song))
            changedRows += summary.insertedRowids.count + summary.updatedRowids.count
            if !summary.isEmpty {
                events(.applied(summary, touchedSourceIDs: Set(rows.map(\.song.sourceID))))
            }
            cursor = (last.orderKey, last.song.id)
            if rows.count < environment.applyChunkSize { break }
        }

        // 目录里有、旧库里没有的行。每轮最多收一批,删完从头再找,内存只占一批。
        var deletedRows = 0
        while true {
            try pauseWhileInteracting()
            var batch: [String] = []
            var stale: [String] = []
            var scanError: Error?
            try catalog.forEachSongIdentity(.everything) { _, id, _ in
                batch.append(id)
                if batch.count >= environment.applyChunkSize {
                    do {
                        let existing = try scanner.existingIDs(among: batch)
                        stale.append(contentsOf: batch.filter { !existing.contains($0) })
                    } catch {
                        scanError = error
                        return false
                    }
                    batch.removeAll(keepingCapacity: true)
                }
                return stale.count < environment.applyChunkSize
            }
            if let scanError { throw scanError }
            if !batch.isEmpty, stale.count < environment.applyChunkSize {
                let existing = try scanner.existingIDs(among: batch)
                stale.append(contentsOf: batch.filter { !existing.contains($0) })
            }
            guard !stale.isEmpty else { break }
            let summary = try catalog.apply(upserts: [], deletingIDs: stale)
            deletedRows += summary.deletedRowids.count
            if !summary.isEmpty { events(.applied(summary, touchedSourceIDs: [])) }
        }

        progress.needsResync = false
        progress.baselineRevision = baseline
        try recordMirroredRevision(baseline, catalog: catalog)
        environment.log(String(
            format: "📚 catalog resync stage=done changed=%d deleted=%d ms=%.0f",
            changedRows, deletedRows, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        ))
    }

    // MARK: - Dual-write

    private func applyOperations(
        _ operations: [Operation],
        overflowed: Bool,
        catalog: LibraryCatalog,
        scanner: IncrementalSongStoreScanner
    ) throws {
        let pending = operations[...]
        // 整份替换:之前的都作废,从头导入;之后的增量留着,导入完再按修订号补。
        if let replaceIndex = pending.lastIndex(where: { if case .replaceAll = $0 { return true } else { return false } }) {
            try catalog.invalidateImport()
            progress.needsImport = true
            progress.needsResync = false
            let remaining = Array(pending[pending.index(after: replaceIndex)...])
            requeue(remaining, overflowed: overflowed)
            environment.log("📚 catalog store replaced → full import")
            return
        }
        if overflowed {
            // 队列攒得太大被丢掉了:目录行数不到旧库一半时重新导入更快,否则对账。
            let storeCount = try scanner.songCount()
            let catalogCount = try catalog.songCount(.everything)
            if catalogCount * 2 < storeCount {
                try catalog.invalidateImport()
                progress.needsImport = true
            } else {
                progress.needsResync = true
            }
            requeue(Array(pending), overflowed: false)
            environment.log("📚 catalog queue overflow → \(progress.needsImport ? "full import" : "resync")")
            return
        }

        var skipped = 0
        var merged = MergedOperation()
        var groups: [MergedOperation] = []
        let baseline = progress.baselineRevision ?? .min
        let mirrored = progress.mirroredRevision ?? .min
        // 旧库的提交是串行的,修订号就是提交顺序;排队时偶尔先后颠倒(启动迁移在主线程直写),按修订号排回去。
        let ordered = pending.enumerated().sorted { lhs, rhs in
            guard case .apply(_, _, _, let left) = lhs.element, case .apply(_, _, _, let right) = rhs.element else { return lhs.offset < rhs.offset }
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        for operation in ordered {
            guard case .apply(let upserts, let deletingIDs, let renaming, let revision) = operation else { continue }
            // 已经包含在导入或对账的起点里,或者与已镜像的那次是同一个修订号(旧库没变)。
            if revision <= baseline || revision == mirrored {
                skipped += 1
                continue
            }
            if revision < mirrored {
                // 比已经写进目录的更早:顺序乱了,内容可能被盖回旧的。对账一次。
                environment.log("📚 catalog late write rev=\(revision) < mirrored=\(mirrored) → resync")
                progress.needsResync = true
                return
            }
            if !merged.canAbsorb(deletingIDs: deletingIDs, renaming: renaming) {
                groups.append(merged)
                merged = MergedOperation()
            }
            merged.absorb(upserts: upserts, deletingIDs: deletingIDs, renaming: renaming, revision: revision)
        }
        if !merged.isEmpty { groups.append(merged) }
        if skipped > 0 { lock.withLock { state.statistics.skippedOperations += skipped } }

        for group in groups {
            if !group.renaming.isEmpty {
                // 先原地改名(与旧库同序:改名、删除、写入),改了名的行目录自己按新值重算派生。
                try pauseForIncrementalApply()
                let summary = try catalog.apply(upserts: [], renaming: group.renaming)
                if !summary.isEmpty { events(.applied(summary, touchedSourceIDs: [])) }
            }
            let deletions = Array(group.deletingIDs)
            let upserts = group.orderedIDs.compactMap { group.songsByID[$0] }
            var deletionStart = 0
            while deletionStart < deletions.count {
                try pauseForIncrementalApply()
                let end = min(deletions.count, deletionStart + environment.applyChunkSize)
                let summary = try catalog.apply(upserts: [], deletingIDs: deletions[deletionStart..<end])
                if !summary.isEmpty { events(.applied(summary, touchedSourceIDs: [])) }
                deletionStart = end
            }
            var upsertStart = 0
            while upsertStart < upserts.count {
                try pauseForIncrementalApply()
                let end = min(upserts.count, upsertStart + environment.applyChunkSize)
                let chunk = Array(upserts[upsertStart..<end])
                let summary = try catalog.apply(upserts: chunk)
                if !summary.isEmpty {
                    events(.applied(summary, touchedSourceIDs: Set(chunk.map(\.sourceID))))
                }
                upsertStart = end
            }
            try recordMirroredRevision(group.revision, catalog: catalog)
            lock.withLock { state.statistics.appliedOperations += group.operationCount }
        }
    }

    /// 合并后的一组增量。规则保证与逐次写入结果相同:新行按第一次出现的先后追加,
    /// 同一首取最后一次的值;后一次要删前面刚 upsert 过的行时另起一组。
    private struct MergedOperation {
        var orderedIDs: [String] = []
        var songsByID: [String: Song] = [:]
        var deletingIDs: Set<String> = []
        var renaming: [String: String] = [:]
        var revision: Int64 = .min
        var operationCount = 0

        var isEmpty: Bool { operationCount == 0 }

        /// 带改名的一次单独成组(很少见:改标签换了身份),组内顺序才与逐次写入一致。
        func canAbsorb(deletingIDs: Set<String>, renaming: [String: String]) -> Bool {
            isEmpty || (renaming.isEmpty && self.renaming.isEmpty && deletingIDs.isDisjoint(with: songsByID.keys))
        }

        mutating func absorb(upserts: [Song], deletingIDs: Set<String>, renaming: [String: String], revision: Int64) {
            self.renaming.merge(renaming) { _, new in new }
            self.deletingIDs.formUnion(deletingIDs)
            for song in upserts {
                if songsByID.updateValue(song, forKey: song.id) == nil { orderedIDs.append(song.id) }
            }
            self.revision = max(self.revision, revision)
            operationCount += 1
        }
    }

    private func requeue(_ operations: [Operation], overflowed: Bool) {
        lock.withLock {
            state.operations.insert(contentsOf: operations, at: 0)
            state.queuedSongs += operations.reduce(0) { $0 + $1.songCount }
            state.overflowed = state.overflowed || overflowed
        }
    }

    private func recordMirroredRevision(_ revision: Int64, catalog: LibraryCatalog) throws {
        try catalog.setMirrorMetadata([MetaKey.storeRevision: String(revision)])
        progress.mirroredRevision = revision
        lock.withLock { state.mirroredRevision = revision }
        events(.mirrored(storeRevision: revision))
    }

    // MARK: - Configuration

    private func applyConfiguration(
        _ inputs: LibraryCatalogMirrorInputs?,
        folderParents folderIndex: AlbumArtistFolderIndex?,
        fileNameIndexes: [String: SourceSyncIndex?],
        catalog: LibraryCatalog
    ) throws {
        var invalidated = false
        if let inputs {
            let applied = Set(try catalog.mirrorMetadata(MetaKey.disabledSources)
                .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
            for sourceID in inputs.disabledSourceIDs.subtracting(applied).sorted() {
                try catalog.setSourceEnabled(false, sourceID: sourceID)
                invalidated = true
            }
            for sourceID in applied.subtracting(inputs.disabledSourceIDs).sorted() {
                try catalog.setSourceEnabled(true, sourceID: sourceID)
                invalidated = true
            }
            if invalidated {
                let encoded = String(decoding: try JSONEncoder().encode(inputs.disabledSourceIDs.sorted()), as: UTF8.self)
                try catalog.setMirrorMetadata([MetaKey.disabledSources: encoded])
            }
            if let names = inputs.sourceNames {
                let fingerprint = Self.fingerprint(names.sorted { $0.key < $1.key }.map { "\($0.key)\u{1}\($0.value)" })
                if try catalog.mirrorMetadata(MetaKey.sourceNames) != fingerprint {
                    try catalog.setSourceNames(names.mapValues { Optional($0) })
                    try catalog.setMirrorMetadata([MetaKey.sourceNames: fingerprint])
                }
            }
            let before = try catalog.groupingNeedsRebuild
            let previousFingerprint = catalog.groupingConfiguration
            try catalog.setGroupingConfiguration(inputs.grouping, isCancelled: { [self] in
                (try? pauseWhileInteracting()) == nil
            })
            if before || previousFingerprint != inputs.grouping { invalidated = true }
            lock.withLock { state.appliedInputs = inputs }
        }
        if let folderIndex {
            var applied = Set(try catalog.mirrorMetadata(MetaKey.folderParentSources)
                .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
            for sourceID in applied.union(folderIndex.parentsBySource.keys).sorted() {
                let parents = folderIndex.parentsBySource[sourceID]
                try pauseWhileInteracting()
                let fingerprint = parents.map { entries in Self.fingerprint(entries.map { entry in "\(entry.key)\u{1}\(entry.value)" }) } ?? "none"
                let key = MetaKey.folderParents(sourceID)
                let stored = try catalog.mirrorMetadata(key) ?? (applied.contains(sourceID) ? nil : "none")
                guard stored != fingerprint else { continue }
                try catalog.setFolderParents(sourceID: sourceID, parents: parents)
                try catalog.setMirrorMetadata([key: parents == nil ? nil : fingerprint])
                if parents == nil { applied.remove(sourceID) } else { applied.insert(sourceID) }
                invalidated = true
            }
            let encoded = String(decoding: try JSONEncoder().encode(applied.sorted()), as: UTF8.self)
            try catalog.setMirrorMetadata([MetaKey.folderParentSources: encoded])
        }
        for (sourceID, index) in fileNameIndexes.sorted(by: { $0.key < $1.key }) {
            try pauseWhileInteracting()
            let fingerprint = index.map(Self.fingerprint(fileNameIndex:)) ?? "none"
            let key = MetaKey.fileNameIndex(sourceID)
            guard try (catalog.mirrorMetadata(key) ?? "none") != fingerprint else { continue }
            try catalog.setFileNameIndex(sourceID: sourceID, index: index)
            try catalog.setMirrorMetadata([key: index == nil ? nil : fingerprint])
            invalidated = true
        }
        if invalidated { events(.invalidatedAll(reason: "configuration")) }
    }

    /// 与顺序无关的 64 位指纹(FNV-1a 逐项,再相加),跨进程稳定。
    static func fingerprint(_ items: some Sequence<String>) -> String {
        var total: UInt64 = 0
        var count: UInt64 = 0
        for item in items {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in item.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            total = total &+ hash
            count &+= 1
        }
        return String(total, radix: 16) + "-" + String(count)
    }

    static func fingerprint(fileNameIndex index: SourceSyncIndex) -> String {
        var entries: [String] = []
        for item in index.values where !item.isDirectory {
            guard let name = item.displayName, !name.isEmpty else { continue }
            entries.append("\(item.path)\u{1}\(name)\u{1}\(item.songIDs.sorted().joined(separator: ","))")
        }
        return fingerprint(entries)
    }

    // MARK: - Shadow verification

    private func runVerifications(_ verifications: [PendingVerification], catalog: LibraryCatalog) {
        let mirroredRevision = progress.mirroredRevision
        var waiting: [PendingVerification] = []
        for pending in verifications {
            let request = pending.request
            let applied = lock.withLock { state.appliedInputs }
            let report: LibraryCatalogShadowReport?
            if let mirroredRevision, mirroredRevision > request.storeRevision {
                report = .skipped(reason: "catalog moved past the snapshot (\(mirroredRevision) > \(request.storeRevision))", request: request)
            } else if mirroredRevision != request.storeRevision || applied != request.inputs {
                if ContinuousClock.now >= pending.deadline {
                    report = .skipped(reason: "catalog did not catch up before the deadline", request: request)
                } else {
                    waiting.append(pending)
                    continue
                }
            } else {
                report = LibraryCatalogShadowVerifier.compare(request, catalog: catalog)
            }
            if let report {
                environment.log(report.logLine)
                lock.withLock { state.lastShadowReport = report }
            }
            pending.continuation?.resume(returning: report)
        }
        guard !waiting.isEmpty else { return }
        lock.withLock { state.verifications.insert(contentsOf: waiting, at: 0) }
        // 还没追上:过一会儿再看(新的增量或配置会先唤醒工作线程)。
        Thread.sleep(forTimeInterval: 0.2)
    }

    enum MetaKey {
        static let storeRevision = "storeRevision"
        static let disabledSources = "disabledSources"
        static let sourceNames = "sourceNames"
        static let folderParentSources = "folderParentSources"
        static func folderParents(_ sourceID: String) -> String { "folderParents." + sourceID }
        static func fileNameIndex(_ sourceID: String) -> String { "fileNameIndex." + sourceID }
    }
}

/// 线程安全的布尔开关。
final class InteractionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set(_ newValue: Bool = true) {
        lock.withLock { value = newValue }
    }
}
