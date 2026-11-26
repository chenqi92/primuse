import Foundation
import os
import SwiftUI
import PrimuseKit

enum HomeRecommendationPause: Hashable {
    case player(UUID)
    case applicationBackground
}

/// 「开始听」:按听歌意图(流行、九十年代、安静一点、很久没听的……)直接起播。
///
/// 点亮(每个意图在曲库里有多少首)是一次整库遍历,只在后台算:曲库变了且距上次至少五分钟
/// 才重算(与情景推荐专辑、专辑艺人判定同一节奏),换了一天也重算(「新加的」按天数算)。
/// 钉选、隐藏与把智能歌单钉成意图只存在本机。点卡片按规则抽 50 首随机起播,
/// 放完由播放器按 #166 的规则接着续相似歌曲。
///
/// 「为你」:同一次后台遍历还攒出听歌画像(按类别分的文件夹、常听的艺人与专辑、无损/高解析
/// 偏好、最近在循环的歌),由此生成个人意图,和内置意图一起按「最近播放占比 + 曲库占比」排序。
/// 能用 AI 时把画像摘要交给 AI 挑选、组合并命名(先内置 AI,再自己的服务),结果在本机核对后
/// 缓存;画像变了、距上次超过六小时才再问。没有 AI 时就用本机生成的那一份。
@MainActor
@Observable
final class ListeningIntentService {
    static let shared = ListeningIntentService()

    /// 经典首页「开始听」区块的开关(首页界面编辑、Mac 外观设置)。
    nonisolated static let homeVisibilityKey = "primuse.home.showStartListening"
    /// 极简导航里「歌曲」页顶上同一行卡片的开关(界面编辑 › 资料库)。
    nonisolated static let minimalSongsVisibilityKey = "primuse.minimal.showStartListening"
    /// 首页铺开成网格时是不是展开着。
    nonisolated static let gridExpandedKey = "primuse.home.startListening.expanded"
    /// 「查看歌曲」最多列出多少首;整库那么大的意图看全部用歌曲页。
    nonisolated static let songListLimit = 1_000
    /// 「用 AI 整理『为你』」开关,默认开(只在允许向 AI 发送内容时才真的发)。
    nonisolated static let aiCurationKey = "primuse.listeningIntents.aiCuration"
    nonisolated static let curationCacheKey = "primuse.listeningIntents.aiCuration.cache.v1"
    nonisolated static let curationAttemptKey = "primuse.listeningIntents.aiCuration.lastAttempt"
    /// 自动再问 AI 的最短间隔;画像没变时缓存一周内都算新。
    nonisolated static let curationRetryInterval: TimeInterval = 6 * 3_600
    nonisolated static let curationFreshness: TimeInterval = 7 * 86_400
    /// 播放记录多了这么多条才值得按新的收听重新排序。
    nonisolated static let historyGrowthForRefresh = 15

    /// 「为你」整理到哪一步了,给「全部意图」页底下那行说明用。
    enum CurationStatus: Equatable {
        /// 开关关着:只用本机规则。
        case off
        /// 本机规则生成;AI 不可用或还没问过。
        case local
        case working
        case curated(provider: String, at: Date)
        /// 问过了,没有可用的 AI 回答,先用本机规则。
        case unavailable
    }

    /// AI 整理的结果,连同它对应的画像一起存在本机。
    struct CuratedIntents: Codable, Equatable {
        var fingerprint: String
        var provider: String
        var curatedAt: Date
        var intents: [ListeningIntent]
    }

    private(set) var availability: ListeningIntentAvailability?
    private(set) var configuration: ListeningIntentShelfConfiguration
    /// 钉成意图、而且还在的智能歌单:意图 ID → 现在匹配到的曲数。
    private(set) var smartPlaylistCounts: [String: Int] = [:]
    /// 钉成意图的智能歌单的名字,卡片标题用。
    private(set) var smartPlaylistNames: [String: String] = [:]
    /// 「为你」:AI 整理过的在前,其余是本机按画像生成的。
    private(set) var personalIntents: [ListeningIntent] = []
    private(set) var curationStatus: CurationStatus = .local
    private(set) var isAICurationEnabled: Bool
    /// 建议卡片的顺序(意图 id),由 `ListeningIntentRankingPolicy` 排:收听、此刻的时段、
    /// 你从货架上点过什么、同类打散。回到首页或回到前台时才重排,不在你刚点完时挪卡片。
    private(set) var rankedOrder: [String] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var refreshPauses: Set<HomeRecommendationPause> = []
    @ObservationIgnored private var settleRefresh: Task<Void, Never>?
    @ObservationIgnored private var deferredRefresh: Task<Void, Never>?
    @ObservationIgnored private var smartPlaylistCountTask: Task<Void, Never>?
    @ObservationIgnored private var smartPlaylistCountsKey: String?
    /// 上次点亮时停用着的音乐源。停用、重新启用是用户自己的操作,不等五分钟的节流,马上重数。
    @ObservationIgnored private var countedDisabledSourceIDs: Set<String> = []
    @ObservationIgnored private weak var library: MusicLibrary?
    @ObservationIgnored private let musicSongsWatcher = LibraryMusicSongsWatcher()
    /// 上次点亮用的播放记录条数;多出 `historyGrowthForRefresh` 条就按新的收听重排。
    @ObservationIgnored private var countedHistoryCount = 0
    /// 下一次点亮不等节流(AI 结果到了、开关变了)。
    @ObservationIgnored private var forcesNextRefresh = false
    @ObservationIgnored private var forcesNextCuration = false
    @ObservationIgnored private var profile: ListeningProfile?
    @ObservationIgnored private var profileReleaseGeneration: UInt64 = 0
    @ObservationIgnored private var curated: CuratedIntents?
    @ObservationIgnored private var curationTask: Task<Void, Never>?
    @ObservationIgnored private var usage: ListeningIntentUsage
    @ObservationIgnored private var usageRevision = 0
    @ObservationIgnored private var rankingKey: String?
    @ObservationIgnored nonisolated(unsafe) private var memoryPressureObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = ListeningIntentShelfConfiguration.decode(
            defaults.string(forKey: ListeningIntentShelfConfiguration.storageKey) ?? ""
        )
        isAICurationEnabled = defaults.object(forKey: Self.aiCurationKey) as? Bool ?? true
        usage = ListeningIntentUsage.decode(defaults.data(forKey: ListeningIntentUsage.storageKey))
        curated = defaults.data(forKey: Self.curationCacheKey)
            .flatMap { try? JSONDecoder().decode(CuratedIntents.self, from: $0) }
        if isAICurationEnabled, let curated {
            curationStatus = .curated(provider: curated.provider, at: curated.curatedAt)
        } else if !isAICurationEnabled {
            curationStatus = .off
        }
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .primuseMemoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseRebuildableCaches()
            }
        }
    }

    deinit {
        if let memoryPressureObserver {
            NotificationCenter.default.removeObserver(memoryPressureObserver)
        }
    }

    func releaseRebuildableCaches() {
        profileReleaseGeneration &+= 1
        guard let displaced = profile else { return }
        profile = nil
        Task.detached(priority: .utility) { withExtendedLifetime(displaced) {} }
    }

    /// 「为你」只在手机、iPad、Mac 上有;电视首页是居家场景。
    nonisolated static var computesPersonalIntents: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// 一次遍历要数的意图:手机、Mac 数「开始听」的内置意图,电视数首页的居家场景。
    var countedIntents: [ListeningIntent] {
        #if os(tvOS)
        ListeningScene.intents
        #else
        ListeningIntentShelfPolicy.builtInCatalog
        #endif
    }

    func setRefreshSuspended(_ suspended: Bool, for reason: HomeRecommendationPause) {
        if suspended {
            guard refreshPauses.insert(reason).inserted else { return }
            if reason == .applicationBackground { releaseRebuildableCaches() }
            settleRefresh?.cancel()
            settleRefresh = nil
            if refreshTask != nil {
                refreshPending = true
                forcesNextRefresh = true
                refreshTask?.cancel()
            }
            deferredRefresh?.cancel()
            deferredRefresh = nil
        } else if refreshPauses.remove(reason) != nil,
                  refreshPauses.isEmpty, let library {
            refreshAfterInteractionSettles(library: library)
        }
    }

    /// 收起播放页时收起动画还在走：等它停稳（最多几秒）再补这一轮，不和动画抢。
    private func refreshAfterInteractionSettles(library: MusicLibrary) {
        settleRefresh?.cancel()
        settleRefresh = Task { @MainActor [weak self, weak library] in
            #if os(iOS) || os(macOS)
            await UserScrollActivityMonitor.shared.waitUntilSettled(maximumHold: 5)
            #endif
            guard let self, let library, !Task.isCancelled, self.refreshPauses.isEmpty else { return }
            self.settleRefresh = nil
            self.refresh(library: library)
        }
    }

    // MARK: Lighting

    /// 每次出现、曲库每次变化都可以调:合并并发、按节奏节流,不该算时什么都不做。
    func refresh(library: MusicLibrary, now: Date = Date()) {
        self.library = library
        musicSongsWatcher.watch(library) { [weak self] in
            guard let self, let library = self.library else { return }
            self.refresh(library: library)
        }
        guard refreshPauses.isEmpty else {
            refreshPending = true
            return
        }
        guard library.isReady else { return }
        refreshSmartPlaylists(library: library)
        updateRankingIfNeeded(now: now)
        let generation = library.musicSongsRevision
        let interval = ListeningIntentEngine.refreshInterval(songCount: library.musicSongs.count)
        // 停用集合与 `musicSongs` 在同一拍里换上,看到集合变了时数组已经是新的。
        let disabledSourceIDs = library.disabledSourceIDs
        let sourcesChanged = disabledSourceIDs != countedDisabledSourceIDs
        let historyCount = PlayHistoryStore.shared.entries.count
        // 听了一阵之后按新的收听重排,但同样守节流。
        let listenedMore = Self.computesPersonalIntents
            && historyCount - countedHistoryCount >= Self.historyGrowthForRefresh
            && availability.map { now.timeIntervalSince($0.computedAt) >= interval } ?? true
        if let last = availability, !sourcesChanged, !forcesNextRefresh, !listenedMore,
           !needsRefresh(last, generation: generation, now: now, interval: interval) {
            if last.libraryGeneration != generation {
                // 曲库还在变但离上次不到一个节拍:到点再补一次,免得扫描停下后一直停在旧数。
                scheduleDeferredRefresh(after: interval - now.timeIntervalSince(last.computedAt))
            }
            return
        }
        if refreshTask != nil {
            refreshPending = true
            return
        }
        deferredRefresh?.cancel()
        deferredRefresh = nil
        forcesNextRefresh = false

        // 在主线程上取好快照,遍历交给后台。曲库目录可读时在目录上逐首算(同交整库数组的结果),
        // 不先取整库音乐;读失败时这一轮照旧交内存里的数组。
        let catalogReader = Self.catalogHost(for: library)?.reader
        let entries = PlayHistoryStore.shared.musicEntries
        let intents = countedIntents
        let curatedIntents = isAICurationEnabled ? curated?.intents ?? [] : []
        let computesPersonal = Self.computesPersonalIntents
        let releaseGeneration = profileReleaseGeneration
        let startedAt = ProcessInfo.processInfo.systemUptime
        refreshTask = Task { @MainActor [weak self, weak library] in
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            let isCancelled: @Sendable () -> Bool = { cancelled.withLock { $0 } }
            var outcome: LightingResult??
            if let catalogReader {
                do {
                    let fromCatalog = try await withTaskCancellationHandler {
                        try await catalogReader.read { catalog -> LightingResult? in
                            try Self.lighting(
                                history: Self.history(entries, now: now), intents: intents, curatedIntents: curatedIntents,
                                computesPersonal: computesPersonal, libraryGeneration: generation, isCancelled: isCancelled,
                                profile: { try ListeningProfile.build(catalog: catalog, scope: .visibleMusic, history: $0, isCancelled: isCancelled) },
                                availability: { try ListeningIntentEngine.availability(
                                    catalog: catalog, scope: .visibleMusic, intents: $0, history: $1,
                                    libraryGeneration: generation, isCancelled: isCancelled
                                ) }
                            )
                        }
                    } onCancel: {
                        cancelled.withLock { $0 = true }
                    }
                    outcome = .some(fromCatalog)
                } catch {
                    plog("🎯 Listening intents catalog read failed (\(error)); using the in-memory library")
                }
            }
            if outcome == nil {
                let memorySongs = library?.musicSongs ?? []
                let worker = Task.detached(priority: .utility) { () -> LightingResult? in
                    try? Self.lighting(
                        history: Self.history(entries, now: now), intents: intents, curatedIntents: curatedIntents,
                        computesPersonal: computesPersonal, libraryGeneration: generation, isCancelled: isCancelled,
                        profile: { ListeningProfile.build(librarySongs: memorySongs, history: $0, isCancelled: isCancelled) },
                        availability: { ListeningIntentEngine.availability(
                            librarySongs: memorySongs, intents: $0, history: $1,
                            libraryGeneration: generation, isCancelled: isCancelled
                        ) }
                    )
                }
                outcome = .some(await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    cancelled.withLock { $0 = true }
                    worker.cancel()
                })
            }
            let computed = outcome ?? nil
            guard let self else { return }
            self.refreshTask = nil
            let result = Task.isCancelled || !self.refreshPauses.isEmpty ? nil : computed
            if let result {
                self.countedDisabledSourceIDs = disabledSourceIDs
                self.countedHistoryCount = historyCount
                if self.profileReleaseGeneration == releaseGeneration {
                    self.profile = result.profile
                }
                if result.personal != self.personalIntents { self.personalIntents = result.personal }
            }
            if let result, result.availability != self.availability {
                self.availability = result.availability
                self.updateRankingIfNeeded(now: Date())
                if let library = self.library { self.refreshSmartPlaylists(library: library) }
                plog(String(
                    format: "🎯 listening intents lit=%d personal=%d largest=%d %.0fms",
                    result.availability.litIntents(intents).count,
                    result.personal.count,
                    result.availability.songCounts.values.max() ?? 0,
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
                ))
            }
            if result != nil, self.profile != nil {
                let forced = self.forcesNextCuration
                self.forcesNextCuration = false
                self.considerCuration(force: forced)
            } else if self.forcesNextCuration {
                self.forcesNextRefresh = true
            }
            if self.refreshPending, let library = self.library {
                self.refreshPending = false
                self.refresh(library: library)
            }
        }
    }

    private struct LightingResult: Sendable {
        let availability: ListeningIntentAvailability
        let profile: ListeningProfile?
        let personal: [ListeningIntent]
    }

    /// 播放历史 → 规则读的「上次听」「听过几次」。在后台调用,只读条目的存储字段。
    nonisolated private static func history(_ entries: [PlayHistoryStore.Entry], now: Date) -> ListeningHistoryIndex {
        ListeningHistoryIndex(
            events: entries.map {
                HomeListeningEvent(songID: $0.songID, playedAt: $0.playedAt, listenedSeconds: $0.listenedSec)
            },
            now: now
        )
    }

    private func needsRefresh(
        _ last: ListeningIntentAvailability, generation: UInt64, now: Date, interval: TimeInterval
    ) -> Bool {
        // 「新加的」「很久没听的」按天数算:跨了一天就重算,哪怕曲库没变。
        if !Calendar.current.isDate(last.computedAt, inSameDayAs: now) { return true }
        return ListeningIntentEngine.shouldRefresh(last: last, libraryGeneration: generation, now: now, interval: interval)
    }

    private func scheduleDeferredRefresh(after delay: TimeInterval) {
        guard deferredRefresh == nil else { return }
        let seconds = max(1, delay + 1)
        deferredRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.deferredRefresh = nil
            if let library = self.library { self.refresh(library: library) }
        }
    }

    /// 钉成意图的智能歌单:名字与曲数。只数钉了的那几个(曲库目录可读时在目录上匹配,随后填上),
    /// 跟着点亮的节奏(点亮重算过或钉选变了)才重数,扫描时不会每批都数;删掉的歌单顺手从钉选里拿掉。
    private func refreshSmartPlaylists(library: MusicLibrary) {
        let pinned = configuration.pinnedSmartPlaylistIDs
        guard !pinned.isEmpty else {
            smartPlaylistCountTask?.cancel()
            if !smartPlaylistCounts.isEmpty { smartPlaylistCounts = [:] }
            if !smartPlaylistNames.isEmpty { smartPlaylistNames = [:] }
            smartPlaylistCountsKey = nil
            return
        }
        let revisions = library.smartPlaylists.filter { pinned.contains($0.id) }.map {
            "\($0.id):\($0.updatedAt.timeIntervalSince1970)"
        }.joined(separator: ",")
        let key = "\(availability?.libraryGeneration ?? 0)|" + pinned.joined(separator: ",") + "|" + revisions
        guard key != smartPlaylistCountsKey else { return }
        let playlists = Dictionary(
            library.smartPlaylists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // 一个智能歌单都还没有(刚装、还没同步过来)时不清钉选,只是这次不数。
        var updated = configuration
        if !playlists.isEmpty, updated.pruneSmartPlaylists(keeping: Set(playlists.keys)) {
            configuration = updated
            persistConfiguration()
        }
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        var onCatalog: [(intentID: String, smart: SmartPlaylist)] = []
        for playlistID in configuration.pinnedSmartPlaylistIDs {
            guard let smart = playlists[playlistID] else { continue }
            let intentID = ListeningIntent.smartPlaylistIntentID(playlistID)
            if SmartPlaylistEngine.matchesOnCatalog(smart, in: library) {
                // 在曲库目录上匹配(主线程外),数好之前先留着上次的数。
                onCatalog.append((intentID, smart))
                counts[intentID] = smartPlaylistCounts[intentID]
            } else {
                counts[intentID] = SmartPlaylistEngine.match(smart, in: library, history: .shared).count
            }
            names[intentID] = smart.name
        }
        smartPlaylistCountsKey = key
        if counts != smartPlaylistCounts { smartPlaylistCounts = counts }
        if names != smartPlaylistNames { smartPlaylistNames = names }
        smartPlaylistCountTask?.cancel()
        guard !onCatalog.isEmpty else { return }
        smartPlaylistCountTask = Task { @MainActor [weak self, weak library] in
            var counted: [String: Int] = [:]
            for pinned in onCatalog {
                guard let library, !Task.isCancelled else { return }
                counted[pinned.intentID] = await SmartPlaylistEngine.matchedSongIDs(
                    pinned.smart, in: library, history: .shared
                ).count
            }
            // 钉选又变了(另起了一轮)时这一轮作废。
            guard let self, !Task.isCancelled, self.smartPlaylistCountsKey == key else { return }
            let merged = self.smartPlaylistCounts.merging(counted) { _, new in new }
            if merged != self.smartPlaylistCounts { self.smartPlaylistCounts = merged }
        }
    }

    /// 曲库目录此刻可读时它的持有方(点亮、起播、查看歌曲在目录上逐首算)。
    private static func catalogHost(for library: MusicLibrary) -> LibraryCatalogHost? {
        guard let host = library.catalogHost, host.revisions.isReadable else { return nil }
        return host
    }

    /// 一轮点亮:先建个人口味画像(要算个人意图时),再给所有意图数歌。两份数据源(目录逐首、内存数组)
    /// 共用这一段,结果只差在歌从哪里来。取消时为 nil。
    nonisolated private static func lighting(
        history: ListeningHistoryIndex,
        intents: [ListeningIntent],
        curatedIntents: [ListeningIntent],
        computesPersonal: Bool,
        libraryGeneration: UInt64,
        isCancelled: () -> Bool,
        profile buildProfile: (ListeningHistoryIndex) throws -> ListeningProfile?,
        availability countAvailability: ([ListeningIntent], ListeningHistoryIndex) throws -> ListeningIntentAvailability?
    ) throws -> LightingResult? {
        var profile: ListeningProfile?
        var local: [ListeningIntent] = []
        if computesPersonal {
            profile = try buildProfile(history)
            guard let profile else { return nil }
            local = PersonalListeningIntentPolicy.intents(from: profile)
        }
        let personal = PersonalListeningIntentPolicy.merged(ai: curatedIntents, local: local)
        guard !isCancelled(), let availability = try countAvailability(personal + intents, history) else { return nil }
        return LightingResult(availability: availability, profile: profile, personal: personal)
    }

    // MARK: Ranking

    /// 排序的输入(时段、点过的记录、点亮结果、个人意图)变了才重排。
    private func updateRankingIfNeeded(now: Date) {
        #if !os(tvOS)
        guard let availability else { return }
        let moment = ListeningMoment.resolve(
            at: now,
            calendar: ListeningCalendar.current,
            observesLunarFestivals: AlbumRecommendationService.observesLunarFestivals
        )
        let key = "\(moment.seedKey)|\(usageRevision)|\(availability.computedAt.timeIntervalSince1970)|"
            + personalIntents.map(\.id).joined(separator: ",")
        guard key != rankingKey else { return }
        rankingKey = key
        let lit = availability.litIntents(personalIntents + ListeningIntentShelfPolicy.builtInCatalog)
        let order = ListeningIntentRankingPolicy.rank(
            lit,
            availability: availability,
            moment: moment,
            usage: usage,
            now: now
        ).map(\.id)
        if order != rankedOrder { rankedOrder = order }
        #endif
    }

    /// 从货架上起播了一个意图:记下时间和时段,下次排序时它在这个时段会靠前,刚放过的先让一让。
    func recordStart(of intentID: String, now: Date = Date()) {
        #if !os(tvOS)
        let moment = ListeningMoment.resolve(
            at: now,
            calendar: ListeningCalendar.current,
            observesLunarFestivals: AlbumRecommendationService.observesLunarFestivals
        )
        usage.record(intentID, at: now, situation: moment.situation)
        usageRevision &+= 1
        if let data = usage.encoded() { defaults.set(data, forKey: ListeningIntentUsage.storageKey) }
        #endif
    }

    // MARK: AI curation

    /// 「用 AI 整理」开关。关掉只用本机规则,缓存留着,再打开就接着用。
    func setAICurationEnabled(_ enabled: Bool) {
        guard enabled != isAICurationEnabled else { return }
        isAICurationEnabled = enabled
        defaults.set(enabled, forKey: Self.aiCurationKey)
        if enabled {
            curationStatus = curated.map { .curated(provider: $0.provider, at: $0.curatedAt) } ?? .local
        } else {
            curationTask?.cancel()
            curationTask = nil
            curationStatus = .off
        }
        relightPersonalIntents()
    }

    /// 现在有没有能问的 AI(内置或自己的服务,且允许发送内容)。
    var canCurateWithAI: Bool {
        #if os(tvOS)
        false
        #else
        AppServices.shared.musicIntelligence.isListeningIntentCurationAvailable
        #endif
    }

    /// 「重新整理」:不等节奏,马上再问一次。
    func recurate() {
        if profile == nil, let library {
            forcesNextCuration = true
            forcesNextRefresh = true
            refresh(library: library)
            return
        }
        considerCuration(force: true)
    }

    /// 个人意图换了一份:不等节流重新点亮,曲数与排序跟着变。
    private func relightPersonalIntents() {
        forcesNextRefresh = true
        if let library { refresh(library: library) }
    }

    /// 该问 AI 时才问:开关开着、能问、值得问(画像变了或缓存旧了),且离上次尝试够久。
    private func considerCuration(force: Bool, now: Date = Date()) {
        #if !os(tvOS)
        guard Self.computesPersonalIntents, let profile else { return }
        guard isAICurationEnabled else {
            curationStatus = .off
            return
        }
        let intelligence = AppServices.shared.musicIntelligence
        guard intelligence.isListeningIntentCurationAvailable else {
            if case .working = curationStatus { curationStatus = .local }
            if curated == nil, curationStatus != .unavailable { curationStatus = .local }
            return
        }
        guard curationTask == nil else { return }
        let fingerprint = profile.fingerprint
        if !force {
            if let curated, curated.fingerprint == fingerprint,
               now.timeIntervalSince(curated.curatedAt) < Self.curationFreshness { return }
            if let last = defaults.object(forKey: Self.curationAttemptKey) as? Date,
               now.timeIntervalSince(last) < Self.curationRetryInterval { return }
        }
        let prepared = ListeningIntentAIExchange.prepare(
            profile: profile,
            languageCode: Locale.preferredLanguages.first ?? "en",
            includesListening: intelligence.allowsListeningContextForCuration
        )
        guard ListeningIntentAIExchange.isWorthAsking(prepared.request) else { return }
        defaults.set(now, forKey: Self.curationAttemptKey)
        let previousStatus = curationStatus
        curationStatus = .working
        curationTask = Task { @MainActor [weak self] in
            let outcome = await intelligence.curateListeningIntents(prepared.request)
            guard let self, !Task.isCancelled else { return }
            self.curationTask = nil
            guard self.isAICurationEnabled else { return }
            switch outcome {
            case .success(let execution):
                let intents = ListeningIntentAIExchange.intents(
                    from: execution.drafts,
                    context: prepared.context,
                    profile: profile
                )
                guard !intents.isEmpty else {
                    self.curationStatus = self.curated.map { .curated(provider: $0.provider, at: $0.curatedAt) } ?? .unavailable
                    return
                }
                let result = CuratedIntents(
                    fingerprint: fingerprint,
                    provider: execution.providerName,
                    curatedAt: Date(),
                    intents: intents
                )
                self.curated = result
                if let data = try? JSONEncoder().encode(result) {
                    self.defaults.set(data, forKey: Self.curationCacheKey)
                }
                self.curationStatus = .curated(provider: result.provider, at: result.curatedAt)
                plog("🎯 listening intents curated by \(result.provider): \(intents.count)")
                self.relightPersonalIntents()
            case .unavailable:
                if let curated = self.curated {
                    self.curationStatus = .curated(provider: curated.provider, at: curated.curatedAt)
                } else {
                    self.curationStatus = force || previousStatus == .unavailable ? .unavailable : .local
                }
            }
        }
        #endif
    }

    // MARK: Shelf

    /// 「全部意图」整页。
    var pageSections: [ListeningIntentShelfSection] {
        ListeningIntentShelfPolicy.page(
            availability: availability,
            configuration: configuration,
            smartPlaylists: smartPlaylistCounts,
            personal: personalIntents,
            order: rankedOrder
        )
    }

    func title(for intent: ListeningIntent) -> String {
        if let customTitle = intent.customTitle, !customTitle.isEmpty {
            return customTitle
        }
        if let titleKey = intent.titleKey {
            let template = String(localized: String.LocalizationValue(titleKey))
            if let argument = intent.titleArgument {
                return String(format: template, argument)
            }
            return template
        }
        if case .smartPlaylist = intent.source, let name = smartPlaylistNames[intent.id], !name.isEmpty {
            return name
        }
        return String(localized: "listening_intent_smart_playlist")
    }

    // MARK: Editing

    func setPinned(_ pinned: Bool, intentID: String) {
        var updated = configuration
        updated.setPinned(pinned, intentID: intentID)
        apply(updated)
    }

    func setHidden(_ hidden: Bool, intentID: String) {
        var updated = configuration
        updated.setHidden(hidden, intentID: intentID)
        apply(updated)
    }

    func movePinned(_ intentID: String, by offset: Int) {
        var updated = configuration
        updated.movePinned(intentID, by: offset)
        apply(updated)
    }

    func movePinned(_ moved: String, onto target: String) {
        var updated = configuration
        updated.movePinned(moved, onto: target)
        apply(updated)
    }

    func isSmartPlaylistPinned(_ playlistID: String) -> Bool {
        configuration.isPinned(ListeningIntent.smartPlaylistIntentID(playlistID))
    }

    /// 智能歌单「钉为意图」/「取消钉选」。
    func setSmartPlaylistPinned(_ pinned: Bool, playlistID: String) {
        guard isSmartPlaylistPinned(playlistID) != pinned else { return }
        setPinned(pinned, intentID: ListeningIntent.smartPlaylistIntentID(playlistID))
    }

    private func apply(_ updated: ListeningIntentShelfConfiguration) {
        guard updated != configuration else { return }
        configuration = updated
        persistConfiguration()
        if let library { refreshSmartPlaylists(library: library) }
    }

    private func persistConfiguration() {
        defaults.set(configuration.encoded(), forKey: ListeningIntentShelfConfiguration.storageKey)
    }

    // MARK: Songs

    /// 「查看歌曲」按艺人、专辑、碟号、轨号排,看起来像一张张专辑,而不是入库的先后。
    /// 命中的歌(按库内顺序)按艺人、专辑、碟号、曲号、歌名排好的 id。
    nonisolated private static func sortedForBrowsing(_ matched: [Song]) -> [String] {
        guard matched.count > 1 else { return matched.map(\.id) }
        func artist(_ song: Song) -> String { song.albumArtistName ?? song.artistName ?? "" }
        return matched.sorted { lhs, rhs in
            let artistOrder = artist(lhs).localizedStandardCompare(artist(rhs))
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            let albumOrder = (lhs.albumTitle ?? "").localizedStandardCompare(rhs.albumTitle ?? "")
            if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
            if (lhs.discNumber ?? 0) != (rhs.discNumber ?? 0) { return (lhs.discNumber ?? 0) < (rhs.discNumber ?? 0) }
            if (lhs.trackNumber ?? 0) != (rhs.trackNumber ?? 0) { return (lhs.trackNumber ?? 0) < (rhs.trackNumber ?? 0) }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        .map(\.id)
    }

    /// 起播用的队列:规则意图在后台抽样(每次点都换一批),智能歌单在匹配结果里随机抽。
    func queueSongIDs(for intent: ListeningIntent, library: MusicLibrary) async -> [String] {
        let seed = UInt64.random(in: .min ... .max)
        switch intent.source {
        case .smartPlaylist(let playlistID):
            guard let smart = library.smartPlaylists.first(where: { $0.id == playlistID }) else { return [] }
            let ids = await SmartPlaylistEngine.matchedSongIDs(smart, in: library, history: .shared)
            return ListeningIntentShelfPolicy.sample(ids, limit: intent.playback.songLimit, seed: seed)
        case .builtIn, .scene, .personal:
            guard intent.rule != nil else { return [] }
            // 按规则替人挑歌,不挑不喜欢的歌(#193)。
            let entries = PlayHistoryStore.shared.musicEntries
            let now = Date()
            if let host = Self.catalogHost(for: library) {
                // 曲库目录可读时在目录上逐首抽样(同交整库数组的结果),不先取整库音乐。
                let disliked = library.dislikedSongIDs
                do {
                    return try await host.reader.read { catalog in
                        try ListeningIntentEngine.queueSongIDs(
                            for: intent, catalog: catalog, scope: .visibleMusic, excluding: disliked,
                            history: Self.history(entries, now: now), seed: seed
                        )
                    }
                } catch {
                    plog("🎯 Listening intent queue catalog read failed (\(error)); using the in-memory library")
                }
            }
            let songs = library.musicSongsExcludingDisliked
            return await Task.detached(priority: .userInitiated) {
                let history = Self.history(entries, now: now)
                return ListeningIntentEngine.queueSongIDs(
                    for: intent,
                    librarySongs: songs,
                    history: history,
                    seed: seed
                )
            }.value
        }
    }

    /// 「查看歌曲」:按曲库顺序列出匹配的歌(最多 `songListLimit` 首)和总数。
    func matchingSongIDs(for intent: ListeningIntent, library: MusicLibrary) async -> (ids: [String], total: Int) {
        switch intent.source {
        case .smartPlaylist(let playlistID):
            guard let smart = library.smartPlaylists.first(where: { $0.id == playlistID }) else { return ([], 0) }
            let ids = await SmartPlaylistEngine.matchedSongIDs(smart, in: library, history: .shared)
            return (Array(ids.prefix(Self.songListLimit)), ids.count)
        case .builtIn, .scene, .personal:
            let entries = PlayHistoryStore.shared.musicEntries
            let now = Date()
            let limit = Self.songListLimit
            if let host = Self.catalogHost(for: library) {
                // 曲库目录可读时在目录上逐首数,命中的那些(最多 `songListLimit` 首)再按 id 取来排。
                do {
                    return try await host.reader.read { catalog in
                        guard let matched = try ListeningIntentEngine.matchingSongIDs(
                            for: intent, catalog: catalog, scope: .visibleMusic,
                            history: Self.history(entries, now: now), limit: limit
                        ) else { return ([], 0) }
                        let byID = try LibraryCatalogReader.songsByID(matched.ids, scope: .visibleMusic, in: catalog)
                        return (Self.sortedForBrowsing(matched.ids.compactMap { byID[$0] }), matched.total)
                    }
                } catch {
                    plog("🎯 Listening intent songs catalog read failed (\(error)); using the in-memory library")
                }
            }
            let songs = library.musicSongs
            return await Task.detached(priority: .userInitiated) {
                let history = Self.history(entries, now: now)
                guard let matched = ListeningIntentEngine.matchingSongIDs(
                    for: intent,
                    librarySongs: songs,
                    history: history,
                    limit: limit,
                    isCancelled: { Task.isCancelled }
                ) else { return ([], 0) }
                let wanted = Set(matched.ids)
                return (Self.sortedForBrowsing(songs.filter { wanted.contains($0.id) }), matched.total)
            }.value
        }
    }
}

#if !os(tvOS)
// 电视用 TVStore 播放,不走这里:电视的场景卡自己起播。
extension ListeningIntentService {
    /// 首页这一行:第一张「接着上次」或「随便听听」,然后是钉选的,再按点亮强度,最多 `limit` 张。
    func row(player: AudioPlayerService, limit: Int = ListeningIntentShelfPolicy.rowLimit) -> [ListeningIntentShelfItem] {
        ListeningIntentShelfPolicy.row(
            availability: availability,
            configuration: configuration,
            resumeSongCount: resumeSongCount(player: player),
            smartPlaylists: smartPlaylistCounts,
            personal: personalIntents,
            order: rankedOrder,
            limit: limit
        )
    }

    /// 能「接着上次」的曲数:离开音乐去听书、听电台时记下的音乐队列,或者停在那儿的音乐队列。
    /// 停用的源里的歌不算,一首都放不了就不出这张卡;源重新启用后又算回来。
    func resumeSongCount(player: AudioPlayerService) -> Int? {
        guard !player.musicSessionMemoryStore.isPreparingResumeTarget else { return nil }
        let count = player.rememberedMusicSessionPlayableCount
        if count > 0 { return count }
        guard !player.isPlaying, !player.isLoading,
              player.currentListeningSpace == .music,
              !player.queueEntries.isEmpty else { return nil }
        let available = player.queueEntries.reduce(0) { total, entry in
            player.isSourceEnabledForPlayback(entry.song.sourceID) ? total + 1 : total
        }
        return available > 0 ? available : nil
    }

    // MARK: Playing

    /// 点卡片:直接起播。规则抽出来的队列本身就是随机顺序,随机开关先关掉,
    /// 这样放完是按相似歌曲续播,而不是整库随机。
    @discardableResult
    func play(_ intent: ListeningIntent, player: AudioPlayerService, library: MusicLibrary) async -> Bool {
        if intent.habit == .resume {
            let store = player.musicSessionMemoryStore
            if store.isPreparingResumeTarget {
                let command = player.castingCommandGeneration
                let queueRequest = player.queueRequestToken
                let advance = player.playbackAdvancePolicy.generation
                await store.waitForStartupResumeTarget()
                guard !Task.isCancelled, !store.isPreparingResumeTarget,
                      command == player.castingCommandGeneration, queueRequest == player.queueRequestToken,
                      advance == player.playbackAdvancePolicy.generation else { return false }
            }
            if player.rememberedMusicSessionPlayableCount > 0 {
                return await player.resumeMusicSession()
            }
            return await player.resumeStoppedMusicQueue()
        }
        let ids = await queueSongIDs(for: intent, library: library)
        guard !ids.isEmpty else { return false }
        player.shuffleEnabled = false
        await player.play(queueIDs: ids)
        recordStart(of: intent.id)
        plog("🎯 listening intent \(intent.id) queued \(ids.count)")
        return true
    }

    /// 长按「下一首播放」/「加入队列」:同样抽一批,插到当前之后或排到队尾。
    func enqueue(_ intent: ListeningIntent, next: Bool, player: AudioPlayerService, library: MusicLibrary) async {
        let ids = await queueSongIDs(for: intent, library: library)
        let songs = ids.compactMap { library.unobservedVisibleSong(id: $0) }
        guard !songs.isEmpty else { return }
        if next {
            player.insertNextInQueue(songs)
        } else {
            player.appendToQueue(songs)
        }
    }
}
#endif

// MARK: - Look

extension ListeningIntent {
    /// 卡片底色。风格各有一个色相,年代偏暖,状态偏冷,习惯跟主题色。
    var tint: Color {
        switch source {
        case .smartPlaylist:
            return Color(red: 0.56, green: 0.35, blue: 0.85)
        case .personal(let personalID):
            switch personalID {
            case "lossless": return Color(red: 0.16, green: 0.55, blue: 0.62)
            case "hiRes": return Color(red: 0.74, green: 0.56, blue: 0.16)
            case "rotation": return Color(red: 0.91, green: 0.42, blue: 0.24)
            default: return Self.tint(seed: personalID)
            }
        case .scene(let sceneID):
            switch ListeningScene(rawValue: sceneID) {
            case .guests: return Color(red: 0.86, green: 0.50, blue: 0.22)
            case .leisure: return Color(red: 0.30, green: 0.58, blue: 0.40)
            case .night: return Color(red: 0.24, green: 0.25, blue: 0.56)
            case .focus: return Color(red: 0.16, green: 0.52, blue: 0.58)
            case .party: return Color(red: 0.82, green: 0.26, blue: 0.56)
            case nil: return Self.tint(seed: sceneID)
            }
        case .builtIn(let builtIn):
            switch builtIn {
            case .pop: return Color(red: 0.93, green: 0.33, blue: 0.53)
            case .rock: return Color(red: 0.80, green: 0.25, blue: 0.22)
            case .electronic: return Color(red: 0.12, green: 0.62, blue: 0.80)
            case .classical: return Color(red: 0.66, green: 0.50, blue: 0.27)
            case .jazz: return Color(red: 0.32, green: 0.33, blue: 0.75)
            case .soundtrack: return Color(red: 0.55, green: 0.30, blue: 0.70)
            case .folk: return Color(red: 0.36, green: 0.60, blue: 0.33)
            case .hipHop: return Color(red: 0.93, green: 0.52, blue: 0.17)
            case .easyListening: return Color(red: 0.20, green: 0.62, blue: 0.58)
            case .eighties: return Color(red: 0.88, green: 0.36, blue: 0.62)
            case .nineties: return Color(red: 0.85, green: 0.50, blue: 0.20)
            case .twoThousands: return Color(red: 0.72, green: 0.58, blue: 0.16)
            case .twentyTens: return Color(red: 0.25, green: 0.55, blue: 0.82)
            case .calm: return Color(red: 0.35, green: 0.50, blue: 0.78)
            case .focus: return Color(red: 0.18, green: 0.55, blue: 0.50)
            case .workout: return Color(red: 0.90, green: 0.30, blue: 0.20)
            case .bedtime: return Color(red: 0.27, green: 0.28, blue: 0.55)
            case .resume, .anything: return .accentColor
            case .longUnplayed: return Color(red: 0.55, green: 0.42, blue: 0.32)
            case .newlyAdded: return Color(red: 0.86, green: 0.62, blue: 0.10)
            }
        }
    }

    private static func tint(seed: String) -> Color {
        let hue = ListeningSeededGenerator.unitNoise(seed)
        return Color(hue: hue, saturation: 0.55, brightness: 0.72)
    }
}

// MARK: - Library watcher

/// 曲库「音乐」那份数组每换一次就回调一次:扫描入库、回填读到标签、有声与音乐重新分类之后。
///
/// 只盯 `searchRevision` 不够:回填写回的那一刻搜索版本先变,整理好的可见集合稍后才换上,
/// 之后不会再有搜索版本的变化,按整库算的派生结果(意图点亮、情景推荐专辑)就停在旧标签上。
@MainActor
final class LibraryMusicSongsWatcher {
    private weak var library: MusicLibrary?
    private var onChange: (@MainActor () -> Void)?

    init() {}

    /// 换了曲库才重新挂;同一个曲库重复调用什么都不做。
    func watch(_ library: MusicLibrary, onChange: @escaping @MainActor () -> Void) {
        guard self.library !== library else { return }
        self.library = library
        self.onChange = onChange
        arm()
    }

    private func arm() {
        guard let library else { return }
        withObservationTracking {
            _ = library.musicSongs
        } onChange: { [weak self] in
            // 在值换上之前回调:下一拍再读,拿到的才是新数组。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.arm()
                self.onChange?()
            }
        }
    }
}
