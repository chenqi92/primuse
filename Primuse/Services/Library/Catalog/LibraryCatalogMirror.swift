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

/// 持有方(`MusicLibrary`)还在装内存模型时就启动目录(冷启动):只打开、按旧库的变更流水追上、跟写增量。
/// 列表读者与整库的活照旧等持有方发布(`ownerBecameReady()`)。
struct LibraryCatalogMirrorEarlyStart: Sendable {
    /// 发布时会交的输入,按构造时已经知道的先算一份(源的名字还不知道,留空)。目录里存着的分组指纹、
    /// 停用的源与它相同才采用;不同就不动目录,等发布时的正式输入(与提前启动之前一样)。
    var inputs: LibraryCatalogMirrorInputs
    /// 内存模型这一次是不是原样装旧库里的行(旧库作数、装载时不用再迁移)。在工作线程上问。
    /// 不是的话发布那一步还要改旧库,目录这时跟上的不是模型将来的样子:不采用,等发布。
    var storeIsWhatTheModelLoads: @Sendable () -> Bool
}

struct LibraryCatalogMirrorStatistics: Sendable, Equatable {
    var importRuns = 0
    var importsCompleted = 0
    /// 最近一次导入开始时目录里已经导入的行数(续导的证据)。
    var lastImportStartedAt: Int?
    var resyncs = 0
    /// 打开时目录落后旧库,按旧库的变更流水只补改过的行追上的次数,与补的行数。
    var journalCatchUps = 0
    var journalCatchUpRows = 0
    /// 流水接不上(旧库还没有流水、整份替换过、流水超限清空过、缺修订号、要补的太多),改为整库对账的次数。
    var journalCatchUpFallbacks = 0
    var resyncFallbacksToImport = 0
    var groupingRebuilds = 0
    /// 整库重建分组、对账期间读者改读冻结视图的次数。
    var frozenReads = 0
    /// 目录从可读变成不可读的次数。
    var unreadableSpells = 0
    var appliedOperations = 0
    var skippedOperations = 0
    var overflows = 0
    var failures = 0
    /// 进后台、内存警告时放掉目录各连接缓存的次数(做完才计)。
    var memoryReleases = 0
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
    /// 启动时目录落后旧库:流水里要补的记录不超过 `journalCatchUpMaximumRows`、每个修订号不超过
    /// `journalCatchUpMaximumRowsPerRevision`(一个修订号在目录的一个事务里写完)才按流水追,否则整库对账。
    /// 按流水追算增量写入,不等整库那道门,所以总量要有界。
    var journalCatchUpMaximumRows = 20_000
    var journalCatchUpMaximumRowsPerRevision = 4_096
    /// 主线程上问一次:此刻能不能做后台目录工作(没在滑、没有转场、App 在前台、温度正常、没在扫描)。
    /// 只管整库的活:首次迁移、整库对账、整库分组重建、补建排序索引。打开目录不等它。
    var interactionGate: @Sendable () async -> Bool = { true }
    /// 增量写入(一次突变、一批扫描结果、启动时按流水追上旧库)只在用户正在滑的时候让一让,后台、扫描中、
    /// 温度高时照样写,目录才跟得上内存模型(读目录的地方不读到旧值)。
    var incrementalApplyGate: @Sendable () async -> Bool = { true }
    /// 增量写入为滑动让路最多让这么久,之后照写(一批的耗时以 `applyChunkSize` 为界)。
    var incrementalApplyMaximumPause: Duration = .seconds(1)
    var log: @Sendable (String) -> Void = { _ in }
    /// 测试:导入每写完一批调一次,返回 false 模拟进程在这里被杀。
    var importBatchHook: (@Sendable (LibraryCatalogImportProgress) -> Bool)?
}

/// 曲库目录(`library-catalog.sqlite`)在 App 里的持有者。P1 阶段旧的内存模型仍是真相,
/// 目录只跟着写:
/// - 打开不等任何门;首次迁移(从 `library-songs.sqlite` 可续导入 + 整库分组)、整库对账在后台串行队列上做,
///   等整库那道门,滑动、转场时原地停下;
/// - 打开时落后旧库:旧库的变更流水接得上就只补改过的行(`runJournalCatchUp`),接不上才整库对账;
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
        /// 持有方已经发布(或者一开始就不是提前启动的):列表读者可以读、整库的活可以做。
        var ownerReady = true
        var earlyStart: LibraryCatalogMirrorEarlyStart?
        var stopped = false
        var poisoned = false
        var catalog: LibraryCatalog?
        /// 跟旧库用的那个只读连接(导入、补流水、对账都经它读);放页缓存时一起放。
        var scanner: IncrementalSongStoreScanner?
        /// 整库重建分组、对账期间给读者的冻结视图(开始那一刻的目录);nil 时读者读实时目录。
        var frozenView: LibraryCatalog?
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
        /// 专辑的发行类别在目录里算齐了没有;nil:还没看过。齐了不会再变回去(之后写的专辑都连同发行类别一起写)。
        var releaseCategoriesComplete: Bool?
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
    /// `announceReadability()` 用:上一次发出去的可读状态,与发事件一起串行。
    private let readabilityAnnouncements = NSLock()
    private var announcedReadable = false

    init(
        environment: LibraryCatalogMirrorEnvironment,
        events: @escaping @Sendable (LibraryCatalogMirrorEvent) -> Void = { _ in }
    ) {
        self.environment = environment
        self.events = events
    }

    // MARK: - Public surface (thread-safe)

    /// 开始后台工作(打开、迁移、跟写)。重复调用无效。
    ///
    /// - Parameter early: 持有方还没发布就启动时给。这时只打开、按流水追上、跟写增量;`readableCatalog`
    ///   一直是 nil(列表读者照旧等发布),整库的活也等;持有方发布后调 `ownerBecameReady()`。
    func start(beforeOwnerIsReady early: LibraryCatalogMirrorEarlyStart? = nil) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            state.ownerReady = early == nil
            state.earlyStart = early
            return true
        }
        guard shouldStart else { return }
        let task = Task.detached(priority: .utility) { [self] in
            await self.run()
        }
        lock.withLock { state.worker = task }
    }

    /// 提前启动的目录:持有方发布了(正式输入已经用 `updateInputs` 交上)。这之后列表读者能读、整库的活能做。
    func ownerBecameReady() {
        let (changed, wakeup) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            guard !state.ownerReady else { return (false, nil) }
            state.ownerReady = true
            state.earlyStart = nil
            // 等着的整库的活(欠着的排序索引)现在可以做了。
            return (true, takeWakeup())
        }
        guard changed else { return }
        announceReadability()
        wakeup?.resume()
    }

    /// 停下(测试、库释放)。在途的一批写完就退出;等待中的调用方都会被唤醒。
    func stop() async {
        let (wakeup, waiters, verifications, worker, wasFollowing) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, [CheckedContinuation<Void, Never>], [PendingVerification], Task<Void, Never>?, Bool) in
            let wasFollowing = !state.stopped && !state.poisoned
            state.stopped = true
            state.frozenView = nil
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

    /// 目录可读时给出句柄(导入与分组都做完、没有待对账、没出过错),并且持有方已经发布:列表、搜索、
    /// 扫描这些读者在内存模型装好之前不读目录(与目录改成提前启动之前一样)。
    var readableCatalog: LibraryCatalog? {
        lock.withLock {
            state.readable && state.ownerReady && !state.poisoned ? state.frozenView ?? state.catalog : nil
        }
    }

    /// 目录此刻就是旧库的样子时给出句柄,不管持有方发布了没有。只给按 id 的读法用
    /// (`LibraryCatalogHost.songLookup()`),它们另外先看待写登记。
    ///
    /// 不变量:这里给出的目录从不落后于旧库。`state.readable` 只在工作线程的循环走到「导入做完、分组不欠
    /// 重建、打开时落后的修订号已经按流水追上或者整库对过账」之后才置真(见 `run()` 里的 `setReadable(true)`);
    /// 那之后本进程对旧库的每一次写都先进待写登记、再排进来,所以「待写登记 + 目录 = 旧库」。在那之前这里
    /// 是 nil,按 id 读照内存模型还没装好的答法(答不出)。
    var caughtUpCatalog: LibraryCatalog? {
        lock.withLock { state.readable && !state.poisoned ? state.frozenView ?? state.catalog : nil }
    }

    /// 专辑的发行类别在目录里算齐了(从 v3 升上来、后台还没补完时为 false):专辑页的发行类别筛选、艺术家页
    /// 「不列只有单曲、EP 的人」据此决定问目录还是照旧用内存模型。
    var releaseCategoriesComplete: Bool {
        lock.withLock { state.releaseCategoriesComplete == true }
    }

    /// 进后台、收到内存警告:放掉目录各连接的页缓存与列表缓存(都能重读,PLAN §4.1)。
    /// 要等手上的读写做完才放得掉,所以在后台队列上做,不占调用线程。
    func releaseMemory() {
        DispatchQueue.global(qos: .utility).async { [self] in releaseMemoryNow() }
    }

    /// 同上,做完才返回(后台放掉歌曲模型、醒着等空页还完之后,挂起之前再放一次时用)。跟旧库的那个只读连接
    /// 一起放(冻结视图的快照连接放不了,它只在整库重建、对账期间存在)。
    func releaseMemoryAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                releaseMemoryNow()
                continuation.resume()
            }
        }
    }

    private func releaseMemoryNow() {
        let held = lock.withLock { () -> (LibraryCatalog, IncrementalSongStoreScanner?)? in
            guard !state.stopped, let catalog = state.catalog else { return nil }
            return (catalog, state.scanner)
        }
        guard let (catalog, scanner) = held else { return }
        catalog.releaseMemory()
        scanner?.releaseMemory()
        lock.withLock { state.statistics.memoryReleases += 1 }
    }

    /// 读者此刻读的是冻结视图(整库重建分组或对账还没做完,列表停在开始那一刻)。按 id 读照样对:
    /// 冻结期间不确认修订号(对账先换回实时目录再确认),这之后的改动都还在待写登记里。
    var readsAreFrozen: Bool { lock.withLock { state.frozenView != nil } }

    var statistics: LibraryCatalogMirrorStatistics { lock.withLock { state.statistics } }
    var lastShadowReport: LibraryCatalogShadowReport? { lock.withLock { state.lastShadowReport } }
    var mirroredStoreRevision: Int64? { lock.withLock { state.mirroredRevision } }

    /// 提前启动的目录已经认下了预估的输入,并且此刻至少是旧库 `storeRevision` 那一刻的样子(不装歌曲模型的启动,
    /// P3 15b 启动条件第 4 条)。持有方发布之后(不再是提前启动)恒为假。
    func earlyStartIsCaughtUp(through storeRevision: Int64) -> Bool {
        lock.withLock {
            state.earlyStart != nil && state.inputs != nil && state.readable && !state.poisoned
                && (state.mirroredRevision ?? -1) >= storeRevision
        }
    }

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
                // 提前启动、还在等持有方的输入:手上没有能做的活。
                if state.idle, state.inputs == nil { return true }
                let hasSourceIndexes = state.ownerReady && (state.folderIndex != nil || !state.fileNameIndexes.isEmpty)
                if state.idle, state.operations.isEmpty, !state.overflowed, state.verifications.isEmpty,
                   state.inputs == state.appliedInputs, !hasSourceIndexes {
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
        /// 打开时目录落后旧库、知道落在哪个修订号:先试着按旧库的变更流水追(接不上再置 `needsResync`)。
        var needsCatchUp = false
        var needsResync = false
        var mirroredRevision: Int64?
        /// 导入或对账开始时旧库的修订号:修订号不超过它的排队增量已经包含在内。
        var baselineRevision: Int64?
    }

    private func run() async {
        // 迁移过的目录打开只要几十毫秒:直接开,不等整库那道门(App 在后台、温度高时也开):开了才能跟写增量、
        // 按流水追上旧库,读目录的地方从启动那一刻起就能用。
        // 还没有目录(第一次迁移,整库的活)才先等持有方发布、再等 `startDelay`(从发布算起,与提前启动之前
        // 一样)、再等那道门,不跟冷启动抢资源;续导等 `resumeDelay`(见下)。
        let catalogExisted = FileManager.default.fileExists(atPath: environment.catalogURL.path)
        if !catalogExisted {
            await waitForOwner()
            if environment.startDelay > .zero, !isStopped { try? await Task.sleep(for: environment.startDelay) }
            guard !isStopped else { return finishWorker() }
            await waitForGate()
        }
        guard !isStopped else { return finishWorker() }

        var startedAt = ProcessInfo.processInfo.systemUptime
        var opened: (LibraryCatalog, IncrementalSongStoreScanner)?
        while opened == nil {
            do {
                opened = try await perform { [self] in try self.open() }
            } catch {
                // 提前启动时旧库可能正被装载那一边打开(恢复 WAL、头一回建流水表):这一次不算数,等持有方发布
                // (那时旧库已经开好,也就是目录改成提前启动之前打开它的时刻)再开一次,再失败才算目录用不了。
                guard lock.withLock({ !state.ownerReady }) else {
                    environment.log("📚 catalog open failed: \(error.localizedDescription)")
                    poison()
                    return finishWorker()
                }
                environment.log("📚 catalog early open failed, retrying when the library is ready: \(error.localizedDescription)")
                await waitForOwner()
                guard !isStopped else { return finishWorker() }
                startedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        guard let (catalog, scanner) = opened else { return finishWorker() }
        let summary = await performNonThrowing { [self] in
            (self.progress.needsImport, self.progress.needsResync, self.progress.mirroredRevision, self.progress.needsCatchUp)
        }
        lock.withLock {
            state.catalog = catalog
            state.scanner = scanner
            state.mirroredRevision = summary.2
        }
        if catalogExisted, summary.0, environment.resumeDelay > .zero {
            // 上次没导完:稍等再续,不跟冷启动抢资源。
            try? await Task.sleep(for: environment.resumeDelay)
            guard !isStopped else { return finishWorker() }
        }
        environment.log(String(
            format: "📚 catalog open ms=%.0f import=%@ resync=%@ catchUp=%@ mirrored=%@",
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            summary.0 ? "needed" : "done",
            summary.1 ? "needed" : "no",
            summary.3 ? "needed" : "no",
            summary.2.map(String.init) ?? "none"
        ))
        if let early = lock.withLock({ state.earlyStart }) {
            // 提前启动:预估的输入与目录里存着的一致才采用(不写目录);不一致、问不出来都等发布时的正式输入。
            do {
                try await perform { [self] in try self.adoptEarlyInputs(early, catalog: catalog) }
            } catch {
                environment.log("📚 catalog early start: inputs not adopted (\(error.localizedDescription))")
            }
        }

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
                // 还没有输入(提前启动、预估的输入没被采用,等持有方发布)时不动目录:配置、导入、按流水追
                // 都照目录当前的分组配置逐行派生,配置不对写下去的派生就是错的。
                guard lock.withLock({ state.inputs != nil }) else {
                    await waitForWork()
                    continue
                }
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
                let pending = await performNonThrowing { [self] in
                    (self.progress.needsImport, self.progress.needsCatchUp, self.progress.needsResync)
                }
                // 整库的活(导入、整库重建分组、整库对账)先让读者让开,再等整库那道门(持有方已发布、App 在前台、
                // 温度正常、没在滑),然后才动手;动手之后滑动、转场时原地停。
                if pending.0 {
                    setReadable(false)
                    // 整库导入写得多,不留快照拖住检查点。
                    releaseFrozenView(reason: "import")
                    try await waitForBulkGate()
                    try await perform { [self] in try self.runImport(catalog: catalog, scanner: scanner) }
                    continue
                }
                if try await perform({ try catalog.groupingNeedsRebuild }) {
                    try await perform { [self] in try self.freezeReadsOrMakeUnreadable(catalog) }
                    try await waitForBulkGate()
                    try await perform { [self] in try self.runGroupingRebuild(catalog: catalog) }
                    continue
                }
                if pending.1 {
                    // 按旧库的变更流水追上:只补改过的行,算增量写入,不等整库那道门。接不上就改成整库对账。
                    try await perform { [self] in try self.runJournalCatchUp(catalog: catalog, scanner: scanner) }
                    continue
                }
                if pending.2 {
                    try await perform { [self] in try self.freezeReadsOrMakeUnreadable(catalog) }
                    try await waitForBulkGate()
                    try await perform { [self] in try self.runResync(catalog: catalog, scanner: scanner) }
                    continue
                }
                if lock.withLock({ state.releaseCategoriesComplete != true }) {
                    await performNonThrowing { [self] in self.noteReleaseCategoryState(catalog) }
                }
                // 不变量(按 id 读目录的前提,见 `caughtUpCatalog`):走到这里,目录已经是旧库此刻的样子 ——
                // 导入做完,分组不欠重建,打开时落后的修订号按流水追上了或者整库对过账。在这之前目录对
                // 谁都不可读,按 id 读照内存模型没装好的答法;这之后旧库的每一次写都先进待写登记再排进来。
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
                    // 整库的活:持有方发布之后才做。
                    if lock.withLock({ state.ownerReady }),
                       try await perform({ try catalog.hasPendingSortIndexes() }),
                       try await perform({ [self] in try self.runPendingSortIndexes(catalog: catalog) }) {
                        continue
                    }
                    // 从 v3 升上来时已经在的专辑补算发行类别(可续;滑动、转场、来了增量就停在两批之间)。
                    if lock.withLock({ state.ownerReady }),
                       try await perform({ try catalog.hasPendingReleaseCategoryBackfill() }),
                       try await perform({ [self] in try self.runReleaseCategoryBackfill(catalog: catalog) }) {
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
            // 知道落在哪个修订号:先按旧库的变更流水追;不知道(很旧的目录)只能整库对账。
            if progress.mirroredRevision != nil { progress.needsCatchUp = true } else { progress.needsResync = true }
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
            // 父文件夹、文件名索引是按源整批改写:持有方发布之前先攒着(与目录改成提前启动之前同一个时刻生效)。
            let hasSourceIndexes = state.ownerReady && (state.folderIndex != nil || !state.fileNameIndexes.isEmpty)
            guard state.inputs != state.appliedInputs || hasSourceIndexes else { return nil }
            let step = Step.configure(
                state.inputs != state.appliedInputs ? state.inputs : nil,
                hasSourceIndexes ? state.folderIndex : nil,
                hasSourceIndexes ? state.fileNameIndexes : [:]
            )
            if hasSourceIndexes {
                state.folderIndex = nil
                state.fileNameIndexes = [:]
            }
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
                // 还没有输入时别的都做不了(见 `run()`),只等输入来。
                let hasSourceIndexes = state.ownerReady && (state.folderIndex != nil || !state.fileNameIndexes.isEmpty)
                let hasWork = state.stopped || (state.inputs != nil && (
                    state.inputs != state.appliedInputs || hasSourceIndexes
                        || !state.operations.isEmpty || state.overflowed || !state.verifications.isEmpty
                ))
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
        let wasFollowing = lock.withLock { () -> Bool in
            let wasFollowing = !state.stopped && !state.poisoned
            state.poisoned = true
            state.frozenView = nil
            state.operations = []
            state.queuedSongs = 0
            state.readable = false
            return wasFollowing
        }
        announceReadability()
        if wasFollowing { events(.stoppedFollowing) }
    }

    /// 整库重建分组、对账之前调用:读者正在读目录时冻结一份此刻的目录接着给他们读(各表还是上一次
    /// 分组的完整样子);冻不了(上次重建没做完、各表新旧混着,或取不到快照)就先不让读。
    /// 本来就不可读(刚启动、还在导入)时不动。
    private func freezeReadsOrMakeUnreadable(_ catalog: LibraryCatalog) throws {
        guard lock.withLock({ state.readable }) else { return }
        if try !freezeReadsIfConsistent(catalog) { setReadable(false) }
    }

    /// 给读者冻结一份此刻的目录(已经冻着就沿用)。整库分组重建上次没做完、各表不一致时不冻,返回 false。
    private func freezeReadsIfConsistent(_ catalog: LibraryCatalog) throws -> Bool {
        if lock.withLock({ state.frozenView != nil }) { return true }
        guard try !catalog.groupingRebuildInProgress else { return false }
        let view: LibraryCatalog
        do {
            view = try catalog.frozenView()
        } catch {
            // 取不到快照不算目录出错:这一回照旧先不让读。
            environment.log("📚 catalog reads not frozen: \(error.localizedDescription)")
            return false
        }
        lock.withLock {
            state.frozenView = view
            state.statistics.frozenReads += 1
        }
        environment.log("📚 catalog reads frozen")
        return true
    }

    /// 放掉冻结视图,读者改读实时目录,整个目录按变了通知一次(行缓存、列表都重取)。
    private func thawReads(reason: String) {
        releaseFrozenView(reason: reason)
        events(.invalidatedAll(reason: reason))
    }

    /// 只放掉冻结视图,不另发通知(调用方随后自己通知,或目录这时本来就不可读)。
    /// 真放掉了就记一行,诊断日志里与「reads frozen」成对。
    private func releaseFrozenView(reason: String) {
        let wasFrozen = lock.withLock { () -> Bool in
            let wasFrozen = state.frozenView != nil
            state.frozenView = nil
            return wasFrozen
        }
        if wasFrozen { environment.log("📚 catalog reads thawed (\(reason))") }
    }

    private func setReadable(_ readable: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard state.readable != readable else { return false }
            state.readable = readable
            if !readable { state.statistics.unreadableSpells += 1 }
            return true
        }
        if changed { announceReadability() }
    }

    /// 读者那边看到的可读状态(目录可读、持有方已发布、没出过错)变了就发一次事件。工作线程与持有方的线程都会
    /// 走到这里,串行着算、串行着发,发出去的最后一个值才一定是此刻的状态。
    private func announceReadability() {
        readabilityAnnouncements.withLock {
            let readable = lock.withLock { state.readable && state.ownerReady && !state.poisoned }
            guard readable != announcedReadable else { return }
            announcedReadable = readable
            events(.readability(readable))
        }
    }

    /// 提前启动的目录:等持有方发布(或者停止)。不是提前启动的立即返回。
    private func waitForOwner() async {
        while !isStopped, lock.withLock({ !state.ownerReady }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 等整库那道门:持有方已经发布(提前启动的目录在那之前不做整库的活),App 侧说此刻可以。
    private func waitForGate() async {
        while !isStopped {
            if lock.withLock({ state.ownerReady }), await environment.interactionGate() {
                interaction.set(false)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// 整库的活动手之前调用。停止时抛 `cancelled`。
    private func waitForBulkGate() async throws {
        await waitForGate()
        if isStopped { throw LibraryCatalogError.cancelled }
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
        thawReads(reason: "grouping")
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

    /// 补算升级之前就在的专辑的发行类别。补完返回 true(并记下「算齐了」、通知读者),停下返回 false。
    private func runReleaseCategoryBackfill(catalog: LibraryCatalog) throws -> Bool {
        let startedAt = ProcessInfo.processInfo.systemUptime
        environment.log("📚 catalog releaseCategories stage=begin")
        let done = try catalog.backfillReleaseCategories(isCancelled: { [self] in bulkWorkShouldYield() })
        environment.log(String(
            format: "📚 catalog releaseCategories stage=%@ ms=%.0f", done ? "done" : "paused",
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        ))
        if done { noteReleaseCategoryState(catalog) }
        return done
    }

    /// 工作线程上:看一眼目录的发行类别算齐了没有。第一次看只记下;之后由「没齐」变成「齐了」时通知读者一次,
    /// 读它的界面改问目录。
    private func noteReleaseCategoryState(_ catalog: LibraryCatalog) {
        let complete = (try? catalog.releaseCategoriesAreComplete()) ?? false
        let became = lock.withLock { () -> Bool in
            let previous = state.releaseCategoriesComplete
            guard previous != true else { return false }
            state.releaseCategoriesComplete = complete
            return previous == false && complete
        }
        if became { events(.invalidatedAll(reason: "release categories")) }
    }

    // MARK: - Early start (before the owner publishes)

    /// 提前启动时预估的输入:目录里存着的停用源、分组指纹都与它相同(分组也没有做到一半的整库重建),
    /// 并且内存模型这一次原样装旧库里的行,才当作已经生效的输入 —— 一个字节都不写。之后发布时交来的正式输入
    /// 与它不同的话走普通的配置步骤(该重建就重建)。
    private func adoptEarlyInputs(_ early: LibraryCatalogMirrorEarlyStart, catalog: LibraryCatalog) throws {
        guard lock.withLock({ state.inputs == nil && !state.ownerReady }) else { return }
        guard try catalog.hasCompletedImport else { return }
        guard early.storeIsWhatTheModelLoads() else {
            environment.log("📚 catalog early start: waiting for the library (the model does not load the store as it is)")
            return
        }
        guard try appliedDisabledSources(in: catalog) == early.inputs.disabledSourceIDs,
              try catalog.adoptGroupingConfigurationIfCurrent(early.inputs.grouping) else {
            environment.log("📚 catalog early start: waiting for the library (inputs differ from the catalog's)")
            return
        }
        let adopted = lock.withLock { () -> Bool in
            // 正式输入抢先到了:走普通的配置步骤。
            guard state.inputs == nil else { return false }
            state.inputs = early.inputs
            state.appliedInputs = early.inputs
            return true
        }
        if adopted { environment.log("📚 catalog early start: inputs match the catalog") }
    }

    private func appliedDisabledSources(in catalog: LibraryCatalog) throws -> Set<String> {
        Set(try catalog.mirrorMetadata(MetaKey.disabledSources)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
    }

    // MARK: - Journal catch-up (replays only what the store changed)

    /// 目录停在旧库的修订号 `progress.mirroredRevision`,旧库这之后又写过(上次两边之间被杀、目录晚打开、
    /// 目录写失败过):旧库的变更流水接得上就只补改过的行。每个修订号一批,连同「镜像到这个修订号」在目录的
    /// 一个事务里写下去,中途被杀下次从停下的那个修订号接着追。
    ///
    /// 流水接不上(旧库还没有流水、整份替换过、超限清空过、缺修订号、要补的太多)、重放中途出错、追完行数
    /// 对不上:都改成整库对账(`needsResync`),与没有流水时一样。追的过程中目录一直不可读。
    private func runJournalCatchUp(catalog: LibraryCatalog, scanner: IncrementalSongStoreScanner) throws {
        guard let mirrored = progress.mirroredRevision else {
            progress.needsCatchUp = false
            progress.needsResync = true
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        func fallBack(_ reason: String) {
            progress.needsCatchUp = false
            progress.needsResync = true
            lock.withLock { state.statistics.journalCatchUpFallbacks += 1 }
            environment.log("📚 catalog catch-up stage=unavailable → resync (\(reason))")
        }
        let outcome: IncrementalSongStoreChangeReplay
        do {
            outcome = try scanner.replayChanges(
                after: mirrored,
                maximumRows: environment.journalCatchUpMaximumRows,
                maximumRowsPerRevision: environment.journalCatchUpMaximumRowsPerRevision
            ) { batch in
                try pauseForIncrementalApply()
                let summary = try catalog.apply(
                    upserts: batch.upserts, deletingIDs: batch.deletingIDs, renaming: batch.renaming,
                    mirrorMetadata: [MetaKey.storeRevision: String(batch.storeRevision)]
                )
                progress.mirroredRevision = batch.storeRevision
                lock.withLock { state.mirroredRevision = batch.storeRevision }
                if !summary.isEmpty {
                    events(.applied(summary, touchedSourceIDs: Set(batch.upserts.map(\.sourceID))))
                }
                events(.mirrored(storeRevision: batch.storeRevision))
            }
        } catch LibraryCatalogError.cancelled {
            throw LibraryCatalogError.cancelled
        } catch {
            return fallBack(error.localizedDescription)
        }
        guard case .replayed(let storeRevision, let revisions, let rows, let storeSongCount) = outcome else {
            if case .unavailable(let reason) = outcome { fallBack(reason) }
            return
        }
        // 追完再核一遍行数(读流水那一刻旧库的行数;目录只有这条线程在写)。
        let catalogSongCount = try catalog.songCount(.everything)
        guard catalogSongCount == storeSongCount else {
            return fallBack("\(catalogSongCount) catalog rows, \(storeSongCount) store rows after the replay")
        }
        progress.needsCatchUp = false
        // 修订号不超过 `storeRevision` 的排队增量已经包含在内(发布那一步写的可能已经排进来了)。
        progress.baselineRevision = storeRevision
        if progress.mirroredRevision != storeRevision { try recordMirroredRevision(storeRevision, catalog: catalog) }
        lock.withLock {
            state.statistics.journalCatchUps += 1
            state.statistics.journalCatchUpRows += rows
        }
        environment.log(String(
            format: "📚 catalog catch-up stage=done storeRevision=%lld revisions=%d rows=%d ms=%.0f",
            storeRevision, revisions, rows, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        ))
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
        // 先换回实时目录再确认修订号:确认之后按 id 读不再看待写登记,读者必须已经在读对过账的目录。
        thawReads(reason: "resync")
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
            let applied = try appliedDisabledSources(in: catalog)
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
            // 配置变了就按要整库重建算(指纹相同不重建时只是白冻一回)。
            let rebuilds = before || previousFingerprint != inputs.grouping
            // 要整库重建分组:还在用旧配置、各表完整时冻结一份给读者,重建期间读者读它,不读重建到一半的表。
            if rebuilds { try freezeReadsOrMakeUnreadable(catalog) }
            try catalog.setGroupingConfiguration(inputs.grouping, isCancelled: { [self] in
                (try? pauseWhileInteracting()) == nil
            })
            if rebuilds { releaseFrozenView(reason: "configuration") }
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

extension LibraryCatalogMirror {
    /// 只换停用的源,其余输入照这里手上的那一份。持有方的歌曲模型不在内存里时用:它这时不重新给一整份输入
    /// (分组输入是跟着模型算的),而停用哪些源只是一份设置。还没收到过输入时不动。
    func updateDisabledSourceIDs(_ ids: Set<String>) {
        let wakeup = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard var inputs = state.inputs, inputs.disabledSourceIDs != ids else { return nil }
            inputs.disabledSourceIDs = ids
            state.inputs = inputs
            return takeWakeup()
        }
        wakeup?.resume()
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
