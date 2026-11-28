import Foundation
import PrimuseKit

// MARK: - 例行维护的 `.launchMaintenance` 占用(DL5)

/// 真机第 6 轮:从没装过歌曲模型的会话在后台挂起约 150 秒后回到前台,恢复的那一刻装回了模型(`hold+ launchMaintenance`,
/// 比 `scene=foreground` 早半秒)。进后台的场景收尾排上的两个计时 —— 搜索索引欠着的准备(再等 3 秒)、等认领的云端身份
/// (再等 8 秒)—— 在挂起之前没到点,恢复时一下子到点,赶在场景切换(`.inactive` 会取消它们)之前要了模型。那一次是云端
/// 身份:它在要占用之前已经清掉了自己的任务句柄,`.inactive` 取消不到,占用一直拿到装完(1.9 秒);搜索索引那个被取消时
/// 占用当场撤掉,不会拿满。这里是这两处在模型不在内存里时的判法,以及每一处 `.launchMaintenance` 占用的日志。
/// 模型在内存里时(开关关着时总是这样)两处都不走这里,与以前相同。
extension MusicLibrary {
    /// 拿 `.launchMaintenance` 占用的三处。日志里按它点名。
    enum LaunchMaintenanceSite: String, Sendable {
        case searchIndex = "search-index"
        case pendingIdentities = "pending-identities"
        case tagEdits = "tag-edits"
    }

    #if DEBUG
    /// 测试:设成空数组之后按先后记下例行维护在模型不在内存里时的每一步(哪一处;`hold: <理由>`、`without the song model`、
    /// `deferred`、`waits`、`dropped`);nil 时不记。
    nonisolated(unsafe) static var launchMaintenanceEventsForTesting: [(site: LaunchMaintenanceSite, event: String)]?
    /// 测试:目录答不了云端身份的情形(小状态落不了盘、读不了目录……)。
    nonisolated(unsafe) static var catalogIdentityResolutionUnavailableForTesting = false
    #endif

    /// 真要为例行维护占用歌曲模型之前记一行:哪一处、为什么。下一次真机能直接点出还剩下的触发者。
    nonisolated static func noteLaunchMaintenanceHold(_ site: LaunchMaintenanceSite, reason: String) {
        noteLaunchMaintenance(site, "hold", detail: "reason=\(reason)", recorded: "hold: \(reason)")
    }

    /// 一行 `🧠 launch maintenance <做了什么> site=<哪一处> <细节>`(测试里同时记一笔)。
    nonisolated static func noteLaunchMaintenance(
        _ site: LaunchMaintenanceSite, _ event: String, detail: String, recorded: String? = nil
    ) {
        plog("🧠 launch maintenance \(event) site=\(site.rawValue) \(detail)")
        #if DEBUG
        launchMaintenanceEventsForTesting?.append((site, recorded ?? event))
        #endif
    }

    /// 进后台时排上的一次维护计时:记下排上的时刻与要等多久,到点时判断中间进程有没有被挂起过
    /// (`LibraryIndexMaintenancePolicy.timerFiredAfterSuspension`)。挂起过就是恢复的那一刻才到点 —— 多半是用户回来了。
    struct BackgroundMaintenanceTimer: Sendable {
        let armedAt: ContinuousClock.Instant
        let delay: Duration

        init(delay: Duration, armedAt: ContinuousClock.Instant = .now) {
            self.armedAt = armedAt
            #if DEBUG
            self.delay = Self.delayForTesting ?? delay
            #else
            self.delay = delay
            #endif
        }

        var firedAfterSuspension: Bool {
            #if DEBUG
            if let forced = Self.firedAfterSuspensionForTesting { return forced }
            #endif
            return LibraryIndexMaintenancePolicy.timerFiredAfterSuspension(armedAt: armedAt, delay: delay, now: .now)
        }

        #if DEBUG
        /// 测试:所有这种计时都只等这么久(不等 8 秒的去抖)。
        nonisolated(unsafe) static var delayForTesting: Duration?
        /// 测试:当作挂起过(true)或没挂起过(false);nil 时照实判。
        nonisolated(unsafe) static var firedAfterSuspensionForTesting: Bool?
        #endif
    }

    // MARK: 搜索索引欠着的准备

    /// 搜索索引欠着准备(`LibrarySearchIndex.hasPendingPreparation`)而歌曲模型不在内存里时,要不要、什么时候占用。
    ///
    /// 准备要整库的歌:整库对账逐首比元数据与歌词的指纹;按目录流水补时也要在整库列表里按 id 找改过的歌,并拿整库的
    /// id 清掉索引里多出来的行。搜索索引那一侧还没有从曲库目录一页一页取歌的入口(P3-design 20p),所以欠着时照旧占用、
    /// 装回来做 —— 这是真活,记一行。只有一处不同:进后台排上的计时是挂起之后才到点的(恢复的那一刻),先等
    /// `suspendedTimerResumeGrace`。用户回来时场景切换在这段时间里取消这个计时(`BackgroundLibraryMaintenanceCoordinator`
    /// 的 `cancel()`),这次什么都不做,标记留着,下一次后台再来;系统在后台唤醒时没人取消,等完照做。以前在这一刻也做
    /// 不成:占用等装载的途中就被 `.inactive` 取消了,白装一次模型。
    /// 没欠着:nil,不装。返回的占用由调用方在准备做完之后结束;等的途中任务被取消或者没装上:nil。
    func holdSongModelForOwedSearchIndexPreparation(
        timer: BackgroundMaintenanceTimer?, defaults: UserDefaults
    ) async -> SongModelHold? {
        guard LibrarySearchIndex.hasPendingPreparation(defaults: defaults) else { return nil }
        if let timer, timer.firedAfterSuspension {
            let grace = LibraryIndexMaintenancePolicy.suspendedTimerResumeGrace
            Self.noteLaunchMaintenance(.searchIndex, "waits", detail: "reason=the timer fired after a suspension "
                + "graceMs=\(Int(grace / .milliseconds(1)))")
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else {
                Self.noteLaunchMaintenance(.searchIndex, "dropped", detail: "reason=the scene is coming back; "
                    + "the preparation stays owed for the next background")
                return nil
            }
            guard LibrarySearchIndex.hasPendingPreparation(defaults: defaults) else { return nil }
        }
        if !isReady {
            let generation = LibrarySearchIndex.pendingPreparationGeneration(defaults: defaults)
            Self.noteLaunchMaintenanceHold(.searchIndex, reason: "a preparation is owed generation=\(generation)")
        }
        let hold = await holdSongModel(.launchMaintenance)
        guard isReady, !Task.isCancelled else {
            hold.end()
            return nil
        }
        return hold
    }

    // MARK: 等认领的云端身份

    /// 等认领的云端身份重试一次(`schedulePendingIdentityFlush` 到点),歌曲模型不在内存里时。
    ///
    /// - 候选从曲库目录读:CK-b 的 `prepareCatalogIdentityResolution`(身份上的 id 在不在,按 id 认不出的那些的标题与路径
    ///   候选;读多少由身份的条数定,在主线程外)。读好之后在同一轮主线程里核对:候选还作数、覆盖此刻全部的身份;再装上它跑
    ///   `flush`(与模型在内存里时同一个重试,`flush(false)` 是整套三级匹配),认出来的与拿整库数组认的逐首相同,不装模型。
    ///   返回 nil。用户回来时计时晚到也照做:它不装模型、只读身份那么多行,与模型在内存里的会话在这一刻做的是同一件事。
    /// - 目录答不了(小状态此刻落不了盘、目录读不了、候选取不全、读的途中曲库或身份变了),或者这一次只按 id 重试(iOS 前台的
    ///   那一种,要可见曲库里本机文件源的位置):要占用模型。计时是挂起之后才到点的,不在这一刻装:`reschedule` 过
    ///   `suspendedTimerResumeGrace` 再判一次(用户回来时场景切换会取消它,系统在后台唤醒时到点照判),返回 nil。
    ///   否则记一行、拿 `.launchMaintenance` 占用,返回它:模型装回来了,调用方照旧跑。占用等的途中任务被取消或者没装上:nil。
    /// 「答不了」从不当成「没有」:身份留着等下一次,一条都不丢、不标成认领过。
    func flushPendingIdentitiesOutsideTheModel(
        exactIDOnly: Bool, timer: BackgroundMaintenanceTimer, identities: () -> [SongIdentity],
        flush: (_ exactIDOnly: Bool) -> Void, reschedule: (Duration) -> Void
    ) async -> SongModelHold? {
        let site = LaunchMaintenanceSite.pendingIdentities
        var reason = "an exact-id retry reads the visible library"
        if !exactIDOnly {
            let started = ContinuousClock.now
            let asked = identities()
            reason = "the catalog cannot answer the identities now"
            #if DEBUG
            let unavailable = Self.catalogIdentityResolutionUnavailableForTesting
            #else
            let unavailable = false
            #endif
            if !unavailable, let resolution = await prepareCatalogIdentityResolution(for: asked) {
                let current = identities()
                if Set(current).isSubset(of: Set(asked)), readyToResolveRemoteIdentities(resolution) {
                    resolvingRemoteIdentities(resolution) { flush(false) }
                    let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
                    Self.noteLaunchMaintenance(site, "without the song model", detail: "identities=\(current.count) "
                        + "stillWaiting=\(identities().count) candidates=\(resolution.candidateCount) ms=\(milliseconds)")
                    return nil
                }
                reason = "the library or the identities changed during the catalog read"
            }
        }
        // 读目录的途中别处把模型装了回来:占用当场返回,照模型在内存里时那样做,不记。
        if !isReady, timer.firedAfterSuspension {
            Self.noteLaunchMaintenance(site, "deferred", detail: "reason=the timer fired after a suspension; \(reason)")
            reschedule(LibraryIndexMaintenancePolicy.suspendedTimerResumeGrace)
            return nil
        }
        if !isReady { Self.noteLaunchMaintenanceHold(site, reason: reason) }
        let hold = await holdSongModel(.launchMaintenance)
        guard !Task.isCancelled, isReady else {
            hold.end()
            return nil
        }
        return hold
    }
}
