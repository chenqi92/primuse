import Foundation
import Observation
import PrimuseKit

enum PodcastPlaybackSettings {
    /// 一集放完接着放下一集(节目页按收听顺序、最新单集列表按列表顺序)。iPhone、Mac、Apple TV 同一个键。
    static let continuousPlaybackKey = "primuse.podcast.continuousPlayback"
}

extension CloudKVSKey {
    /// 播客订阅的定义(订了哪些、每档设置、已播水位线)。只有用户改了才推。
    static let podcastSubscriptions = "primuse_podcast_subscriptions_v1"
    /// 喜欢的单集(只有单集 id 与时间,`PodcastLikeDocument`)。只有用户改了才推。
    static let podcastLikedEpisodes = "primuse_podcast_liked_episodes_v1"
}

extension Notification.Name {
    /// 订阅、单集列表或某档节目的设置变了。
    static let primusePodcastsDidChange = Notification.Name("primuse.podcastsDidChange")
}

/// 喜欢的一集,连同它的节目(退订了就是 nil)和节目名。
struct PodcastLikedEpisodeItem: Identifiable {
    let episode: PodcastEpisode
    let show: PodcastShow?
    let showTitle: String
    var id: String { episode.id }
}

/// 订阅的播客节目和它们的单集。
///
/// - 节目与单集存在 `Application Support/Primuse/Podcasts`:节目一份 `shows.json`,
///   单集每档一个文件,刷新一档只重写那一档。
/// - 订阅定义经 iCloud 键值存储同步(`PodcastSubscriptionDocument`),只在用户改动时推。
///   刷新得来的东西(单集、ETag)每台设备自己取。
/// - 听到哪、听没听完记在有声内容那份账(`SpokenWordStore`,也同步);
///   「全部标为已播」用每档一条水位线(`PodcastShow.playedThrough`),不逐集写。
/// - 喜欢的单集单独一份账(`PodcastLikeDocument`,经 iCloud 同步),本机另存单集快照
///   (`liked.json`):feed 不再列、节目退订了,喜欢过的照样在。不进「我喜欢」歌单,也不推音乐服务端。
@MainActor
@Observable
final class PodcastStore {
    static let shared = PodcastStore()

    /// 全部订阅,含当前店面不显示的那些。存盘、iCloud 同步、刷新结果落回都用它;界面读 `shows`。
    private(set) var subscribedShows: [PodcastShow] = []
    /// 节目 id → 在当前店面目录里核过的结果(见 `PodcastRegionGate`)。只在中国大陆店面用得上。
    private(set) var regionChecks: [String: PodcastRegionGate.Check] = [:]
    private(set) var episodesByShow: [String: [PodcastEpisode]] = [:]
    private(set) var isLoaded = false
    private(set) var refreshingShowIDs: Set<String> = []
    /// 节目 id → 最近一次刷新失败的原因。成功一次就清掉。
    private(set) var refreshFailures: [String: String] = [:]
    /// 预览(还没订阅的节目)。订阅时直接转正,不用再取一次 feed。
    private(set) var previews: [String: (show: PodcastShow, episodes: [PodcastEpisode])] = [:]
    /// 喜欢的单集 id。心形键与列表读它,改了界面跟着变。
    private(set) var likedEpisodeIDs: Set<String> = []

    /// 单集 id → (节目 id, 在该节目单集数组里的位置)。按 id 找一集是 O(1),
    /// 首页和「接着听」每次重算都要按 id 查几十上百集。
    @ObservationIgnored private var episodeShowIndex: [String: (showID: String, index: Int)] = [:]
    @ObservationIgnored private var numberingTrust: [String: (count: Int, firstID: String?, trusted: Bool)] = [:]
    @ObservationIgnored private var removed: [String: Date] = [:]
    @ObservationIgnored private var failureCounts: [String: Int] = [:]
    @ObservationIgnored private var dirtyShowIDs: Set<String> = []
    @ObservationIgnored private var showsDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAllTask: Task<Void, Never>?
    @ObservationIgnored private var isRegisteredWithCloud = false
    @ObservationIgnored private var regionCheckTask: Task<Void, Never>?
    @ObservationIgnored private var likeDocument = PodcastLikeDocument()
    /// 单集 id → 喜欢时留的快照。
    @ObservationIgnored private var likedSnapshots: [String: PodcastLikedEpisode] = [:]
    /// 正在放的那一集。删已播下载时要跳过它;各端启动时接上自己的播放器。
    @ObservationIgnored var nowPlayingEpisodeID: @MainActor () -> String? = { nil }

    private let defaults: UserDefaults
    private let directory: URL
    private var episodesDirectory: URL { directory.appendingPathComponent("Episodes", isDirectory: true) }
    private var showsURL: URL { directory.appendingPathComponent("shows.json") }
    private var likedURL: URL { directory.appendingPathComponent("liked.json") }

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        if let directory {
            self.directory = directory
        } else {
            #if os(tvOS)
            let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            #else
            let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            #endif
            self.directory = base.appendingPathComponent("Primuse/Podcasts", isDirectory: true)
        }
    }

    // MARK: - Loading

    private struct LocalLibrary: Codable {
        var shows: [PodcastShow]
        var removed: [String: Date]?
    }

    /// `liked.json`:喜欢的账(和推到 iCloud 的同一份)加单集快照。
    private struct LikedLibrary: Codable {
        var document: PodcastLikeDocument
        var snapshots: [PodcastLikedEpisode]
    }

    /// 读盘在后台做;订阅很多时单集文件加起来有几 MB。读完才接上 iCloud,
    /// 否则云端那份会和一个空的本机合并,把所有节目当成新订阅。
    func loadIfNeeded() {
        guard !isLoaded, loadTask == nil else { return }
        let directory = directory
        let episodesDirectory = episodesDirectory
        loadTask = Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> (LocalLibrary, [String: [PodcastEpisode]], LikedLibrary?) in
                let decoder = Self.makeDecoder()
                let library = (try? Data(contentsOf: directory.appendingPathComponent("shows.json")))
                    .flatMap { try? decoder.decode(LocalLibrary.self, from: $0) } ?? LocalLibrary(shows: [], removed: [:])
                var episodes: [String: [PodcastEpisode]] = [:]
                for show in library.shows {
                    let url = episodesDirectory.appendingPathComponent(Self.episodesFileName(for: show.id))
                    if let data = try? Data(contentsOf: url),
                       let decoded = try? decoder.decode([PodcastEpisode].self, from: data) {
                        episodes[show.id] = decoded
                    }
                }
                let liked = (try? Data(contentsOf: directory.appendingPathComponent("liked.json")))
                    .flatMap { try? decoder.decode(LikedLibrary.self, from: $0) }
                return (library, episodes, liked)
            }.value
            guard let self else { return }
            self.subscribedShows = loaded.0.shows
            self.regionChecks = self.loadRegionChecks()
            self.removed = loaded.0.removed ?? [:]
            self.episodesByShow = loaded.1
            if let liked = loaded.2 {
                self.likeDocument = liked.document
                self.likedSnapshots = Dictionary(
                    liked.snapshots.map { ($0.episode.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.likedEpisodeIDs = Set(liked.document.liked.keys)
            }
            self.rebuildIndex()
            self.isLoaded = true
            self.loadTask = nil
            self.registerWithCloud()
            self.postChange()
            self.purgeUnsubscribedDownloads()
            self.verifyRegionalAvailabilityIfNeeded()
            plog("🎙️ Podcasts loaded: \(self.subscribedShows.count) shows, \(self.episodeShowIndex.count) episodes")
        }
    }

    private func registerWithCloud() {
        guard !isRegisteredWithCloud, defaults === UserDefaults.standard else { return }
        isRegisteredWithCloud = true
        CloudKVSSync.shared.register(key: CloudKVSKey.podcastSubscriptions) { [weak self] in
            Task { @MainActor [weak self] in self?.mergeCloudCopy() }
        }
        CloudKVSSync.shared.register(key: CloudKVSKey.podcastLikedEpisodes) { [weak self] in
            Task { @MainActor [weak self] in self?.mergeCloudLikes() }
        }
    }

    // MARK: - Reading

    /// 当前店面能显示的订阅。中国大陆店面只显示在中国区 Apple 播客目录里查得到的节目:
    /// 别的设备同步来的手填地址、换店面前订的,都留在 `subscribedShows` 里但不显示、不刷新。
    var shows: [PodcastShow] {
        let policy = PodcastAvailabilityService.shared.policy
        guard !policy.allowsCustomFeeds else { return subscribedShows }
        return subscribedShows.filter { PodcastRegionGate.isVisible($0, policy: policy, check: regionChecks[$0.id]) }
    }

    /// 订着、但当前店面不显示的节目数。资料库底下据此说明一句。
    var regionHiddenShowCount: Int {
        PodcastAvailabilityService.shared.policy.allowsCustomFeeds ? 0 : subscribedShows.count - shows.count
    }

    func show(id: String) -> PodcastShow? {
        shows.first { $0.id == id } ?? previews[id]?.show
    }

    func isSubscribed(_ showID: String) -> Bool {
        shows.contains { $0.id == showID }
    }

    func isSubscribed(feedURL: URL) -> PodcastShow? {
        let key = PodcastFeedURL.identityKey(for: feedURL)
        return shows.first { PodcastFeedURL.identityKey(for: $0.feedURL) == key || $0.id == PodcastIdentity.showID(feedURL: feedURL) }
    }

    func subscribedShow(directoryID: Int) -> PodcastShow? {
        shows.first { $0.directoryID == directoryID }
    }

    func episodes(forShowID showID: String) -> [PodcastEpisode] {
        guard show(id: showID) != nil else { return [] }
        return episodesByShow[showID] ?? previews[showID]?.episodes ?? []
    }

    func episode(id: String) -> (episode: PodcastEpisode, show: PodcastShow)? {
        if let location = episodeShowIndex[id],
           let show = show(id: location.showID),
           let episodes = episodesByShow[location.showID],
           episodes.indices.contains(location.index),
           episodes[location.index].id == id {
            return (episodes[location.index], show)
        }
        for preview in previews.values {
            if let episode = preview.episodes.first(where: { $0.id == id }) { return (episode, preview.show) }
        }
        return nil
    }

    /// 这档节目的集号能不能显示成「第 N 集」;按单集列表的长度和最新一集记一份,列表没变就不重算。
    func showsEpisodeNumbers(forShowID showID: String) -> Bool {
        let episodes = episodes(forShowID: showID)
        if let cached = numberingTrust[showID], cached.count == episodes.count, cached.firstID == episodes.first?.id {
            return cached.trusted
        }
        let trusted = PodcastEpisodeListPolicy.numbersFollowPublishOrder(episodes)
        numberingTrust[showID] = (episodes.count, episodes.first?.id, trusted)
        return trusted
    }

    /// 一集在本机的状态:进度与听完来自有声那份账,水位线来自节目,下载来自下载账。
    func state(for episode: PodcastEpisode) -> PodcastEpisodeState {
        let spokenWord = SpokenWordStore.shared
        let markedPlayed = show(id: episode.showID)?.isMarkedPlayed(episode) ?? false
        let finished = spokenWord.isFinished(songID: episode.id) || markedPlayed
        return PodcastEpisodeState(
            position: finished ? nil : spokenWord.position(forSongID: episode.id)?.position,
            isFinished: finished,
            isDownloaded: PodcastDownloadStore.shared.isDownloaded(episode.id)
        )
    }

    func newEpisodeCount(showID: String) -> Int {
        guard let show = show(id: showID) else { return 0 }
        return PodcastEpisodeListPolicy.newEpisodeCount(show: show, episodes: episodes(forShowID: showID), state: state(for:))
    }

    /// 所有订阅里最近发布、还没听完的单集。
    func latestEpisodes(limit: Int, includeFinished: Bool = false) -> [PodcastEpisode] {
        PodcastEpisodeListPolicy.latest(
            episodesByShow: visibleEpisodesByShow,
            state: state(for:),
            excludingFinished: !includeFinished,
            limit: limit
        )
    }

    /// 当前店面能显示的节目的单集。
    private var visibleEpisodesByShow: [String: [PodcastEpisode]] {
        guard !PodcastAvailabilityService.shared.policy.allowsCustomFeeds else { return episodesByShow }
        let visible = Set(shows.map(\.id))
        return episodesByShow.filter { visible.contains($0.key) }
    }

    /// 听到一半的单集,最近听的在前。
    func inProgressEpisodes(limit: Int = 20) -> [(episode: PodcastEpisode, show: PodcastShow, updatedAt: Date)] {
        let spokenWord = SpokenWordStore.shared
        return spokenWord.positions
            .filter { PodcastIdentity.isEpisodeID($0.key) }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .compactMap { id, stored -> (PodcastEpisode, PodcastShow, Date)? in
                guard let found = episode(id: id), !state(for: found.episode).isFinished else { return nil }
                return (found.episode, found.show, stored.updatedAt)
            }
            .prefix(limit)
            .map { ($0.0, $0.1, $0.2) }
    }

    /// 最近听过的那一集(首页「接着听」的播客卡)。
    var mostRecentInProgress: (episode: PodcastEpisode, show: PodcastShow, updatedAt: Date)? {
        inProgressEpisodes(limit: 1).first
    }

    // MARK: - Subscribing

    enum SubscribeError: LocalizedError {
        case notInDirectory
        /// 当前店面只能从 Apple 播客目录订阅。
        case directoryOnly

        var errorDescription: String? {
            switch self {
            case .notInDirectory: String(localized: "podcast_error_not_in_directory")
            case .directoryOnly: String(localized: "podcast_region_directory_only")
            }
        }
    }

    /// 取一档节目来看,不订阅。已经订了就直接给本机那份。
    @discardableResult
    func preview(feedURL: URL, directoryID: Int? = nil) async throws -> PodcastShow {
        if let existing = isSubscribed(feedURL: feedURL) { return existing }
        // 界面已经藏起了手填地址与 OPML;这里再挡一道,别处的入口也绕不过去。
        guard directoryID != nil || PodcastAvailabilityService.shared.allowsCustomFeeds else {
            throw SubscribeError.directoryOnly
        }
        let showID = PodcastIdentity.showID(feedURL: feedURL)
        if let cached = previews[showID] { return cached.show }
        guard case let .fetched(data, finalURL, etag, lastModified) = try await PodcastNetwork.fetchFeed(feedURL) else {
            throw PodcastNetwork.Failure.emptyResponse
        }
        let result = try await Task.detached(priority: .userInitiated) {
            let feed = try PodcastFeedParser.parse(data, feedURL: finalURL)
            return PodcastFeedMerge.subscribe(feed: feed, feedURL: feedURL, directoryID: directoryID, now: Date())
        }.value
        var show = result.show
        if finalURL.scheme == "https", feedURL.scheme == "http" { show.feedURL = finalURL }
        show.httpETag = etag
        show.httpLastModified = lastModified
        previews[show.id] = (show, result.episodes)
        return show
    }

    func preview(directoryShow: PodcastDirectoryShow) async throws -> PodcastShow {
        if let existing = subscribedShow(directoryID: directoryShow.id) { return existing }
        let feedURL: URL
        if let known = directoryShow.feedURL {
            feedURL = known
        } else if let looked = try await PodcastDirectoryService.shared.lookup(directoryShow.id)?.feedURL {
            feedURL = looked
        } else {
            throw SubscribeError.notInDirectory
        }
        let show = try await preview(feedURL: feedURL, directoryID: directoryShow.id)
        // 从本店面目录里找到的:就是在这个店面能显示的节目(同步来、之前藏着的同一档也随之显示)。
        if !PodcastAvailabilityService.shared.allowsCustomFeeds {
            recordRegionCheck(showID: show.id, available: true)
        }
        return show
    }

    @discardableResult
    func subscribe(feedURL: URL, directoryID: Int? = nil) async throws -> PodcastShow {
        if let existing = isSubscribed(feedURL: feedURL) { return existing }
        let preview = try await preview(feedURL: feedURL, directoryID: directoryID)
        return adopt(previewID: preview.id) ?? preview
    }

    @discardableResult
    func subscribe(directoryShow: PodcastDirectoryShow) async throws -> PodcastShow {
        let preview = try await preview(directoryShow: directoryShow)
        if isSubscribed(preview.id) { return preview }
        return adopt(previewID: preview.id) ?? preview
    }

    /// 预览转成订阅。订阅时间从现在算:订阅前就有的单集不算「新」。
    @discardableResult
    func adopt(previewID: String) -> PodcastShow? {
        if let existing = subscribedShows.first(where: { $0.id == previewID }) {
            previews.removeValue(forKey: previewID)
            return existing
        }
        guard let preview = previews.removeValue(forKey: previewID) else { return nil }
        var show = preview.show
        let now = Date()
        show.subscribedAt = now
        show.definitionModifiedAt = now
        subscribedShows.append(show)
        episodesByShow[show.id] = preview.episodes
        removed.removeValue(forKey: show.id)
        rebuildIndex()
        markDirty(showID: show.id, showsChanged: true)
        pushSubscriptions()
        postChange()
        plog("🎙️ Subscribed '\(show.title)' (\(preview.episodes.count) episodes)")
        return show
    }

    func unsubscribe(_ showID: String) {
        guard let index = subscribedShows.firstIndex(where: { $0.id == showID }) else { return }
        let show = subscribedShows.remove(at: index)
        // 退订后这档还能当预览看:节目页不会停在转圈上,正在放的这一集也还找得到说明和章节。
        previews[showID] = (show, episodesByShow.removeValue(forKey: showID) ?? [])
        refreshFailures.removeValue(forKey: showID)
        removed[showID] = Date()
        rebuildIndex()
        PodcastDownloadStore.shared.deleteAll(showID: showID, keeping: nowPlayingEpisodeIDs)
        try? FileManager.default.removeItem(at: episodesDirectory.appendingPathComponent(Self.episodesFileName(for: showID)))
        showsDirty = true
        scheduleSave()
        pushSubscriptions()
        postChange()
        plog("🎙️ Unsubscribed '\(show.title)'")
    }

    /// 改一档节目的设置或水位线。算用户的决定:推 iCloud。
    func updateDefinition(_ showID: String, mutate: (inout PodcastShow) -> Void) {
        guard let index = subscribedShows.firstIndex(where: { $0.id == showID }) else { return }
        var show = subscribedShows[index]
        mutate(&show)
        show.definitionModifiedAt = Date()
        subscribedShows[index] = show
        markDirty(showID: nil, showsChanged: true)
        pushSubscriptions()
        postChange()
    }

    // MARK: - Played state

    func setPlayed(_ played: Bool, episode: PodcastEpisode) {
        let spokenWord = SpokenWordStore.shared
        if played {
            spokenWord.markFinished(true, songIDs: [episode.id])
            spokenWord.clearPosition(forSongID: episode.id)
            if let show = show(id: episode.showID), show.reopenedEpisodeIDs.contains(episode.id) {
                updateDefinition(show.id) { $0.reopenedEpisodeIDs.remove(episode.id) }
            }
        } else {
            spokenWord.markFinished(false, songIDs: [episode.id])
            spokenWord.clearPosition(forSongID: episode.id)
            if let show = show(id: episode.showID), show.isMarkedPlayed(episode) {
                updateDefinition(show.id) { $0.reopenedEpisodeIDs.insert(episode.id) }
            }
        }
        postChange()
    }

    /// 整档标为已播:水位线拉到最新一集。
    func markAllPlayed(showID: String) {
        let latest = episodes(forShowID: showID).compactMap(\.publishedAt).max() ?? Date()
        updateDefinition(showID) {
            $0.playedThrough = max(latest, $0.playedThrough ?? .distantPast)
            $0.reopenedEpisodeIDs = []
        }
    }

    /// 这一集之前(更早发布)的都标为已播,这一集自己不动。
    func markOlderPlayed(than episode: PodcastEpisode) {
        guard let published = episode.publishedAt else { return }
        updateDefinition(episode.showID) {
            $0.playedThrough = max(published.addingTimeInterval(-1), $0.playedThrough ?? .distantPast)
            $0.reopenedEpisodeIDs = $0.reopenedEpisodeIDs.filter { id in
                self.episode(id: id)?.episode.publishedAt.map { $0 >= published } ?? false
            }
        }
    }

    // MARK: - Refreshing

    var isRefreshingAll: Bool { !refreshingShowIDs.isEmpty }

    /// 打开播客页、回到前台时调:只刷到期的。
    func refreshAllIfDue() {
        guard isLoaded, refreshAllTask == nil else { return }
        let now = Date()
        let due = shows.filter {
            PodcastRefreshSchedule.isDue(lastRefreshedAt: $0.lastRefreshedAt, failureCount: failureCounts[$0.id] ?? 0, now: now)
        }
        guard !due.isEmpty else { return }
        startRefresh(of: due.map(\.id), force: false)
    }

    /// 下拉刷新:全部都取,不看间隔。
    func refreshAll() async {
        guard isLoaded else { return }
        if let running = refreshAllTask {
            await running.value
            return
        }
        startRefresh(of: shows.map(\.id), force: true)
        await refreshAllTask?.value
    }

    private func startRefresh(of showIDs: [String], force: Bool) {
        refreshAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = showIDs.makeIterator()
                // 同时取四档,订阅上百档时也不会一下子开一百个连接。
                for _ in 0..<4 {
                    guard let id = iterator.next() else { break }
                    group.addTask { await self.refresh(showID: id, force: force) }
                }
                while await group.next() != nil {
                    if let id = iterator.next() {
                        group.addTask { await self.refresh(showID: id, force: force) }
                    }
                }
            }
            self.refreshAllTask = nil
            self.purgePlayedDownloads()
        }
    }

    func refresh(showID: String, force: Bool = true) async {
        guard let show = shows.first(where: { $0.id == showID }), !refreshingShowIDs.contains(showID) else { return }
        refreshingShowIDs.insert(showID)
        defer { refreshingShowIDs.remove(showID) }
        let hasEpisodes = !(episodesByShow[showID] ?? []).isEmpty
        do {
            let result = try await PodcastNetwork.fetchFeed(
                show.feedURL,
                etag: hasEpisodes ? show.httpETag : nil,
                lastModified: hasEpisodes ? show.httpLastModified : nil
            )
            switch result {
            case .notModified:
                updateRefreshState(showID) { $0.lastRefreshedAt = Date() }
            case let .fetched(data, finalURL, etag, lastModified):
                let existing = episodesByShow[showID] ?? []
                let retaining = retainedEpisodeIDs(existing)
                let merged = try await Task.detached(priority: .utility) {
                    let feed = try PodcastFeedParser.parse(data, feedURL: finalURL)
                    return PodcastFeedMerge.refresh(show: show, existing: existing, feed: feed, retaining: retaining, now: Date())
                }.value
                apply(merged, etag: etag, lastModified: lastModified, upgradedURL: finalURL)
            }
            failureCounts[showID] = nil
            refreshFailures.removeValue(forKey: showID)
        } catch {
            failureCounts[showID, default: 0] += 1
            refreshFailures[showID] = error.localizedDescription
            updateRefreshState(showID) { $0.lastRefreshedAt = Date() }
            plog("🎙️ Refresh failed '\(show.title)': \(error.localizedDescription)")
        }
    }

    /// 本机下载过、听过一半、听完或喜欢的单集:feed 只留最近几十集时也别把它们冲掉。
    private func retainedEpisodeIDs(_ episodes: [PodcastEpisode]) -> Set<String> {
        let spokenWord = SpokenWordStore.shared
        let downloads = PodcastDownloadStore.shared
        let liked = likedEpisodeIDs
        return Set(episodes.lazy.map(\.id).filter {
            downloads.isDownloaded($0) || spokenWord.position(forSongID: $0) != nil || spokenWord.isFinished(songID: $0)
                || liked.contains($0)
        })
    }

    private func apply(_ merged: PodcastFeedMerge.Result, etag: String?, lastModified: String?, upgradedURL: URL) {
        guard let index = subscribedShows.firstIndex(where: { $0.id == merged.show.id }) else { return }
        // 刷新期间用户改了设置或退订后又订:定义部分以本机此刻为准。
        var show = merged.show
        let current = subscribedShows[index]
        show.settings = current.settings
        show.playedThrough = current.playedThrough
        show.reopenedEpisodeIDs = current.reopenedEpisodeIDs
        show.definitionModifiedAt = current.definitionModifiedAt
        show.subscribedAt = current.subscribedAt
        show.httpETag = etag
        show.httpLastModified = lastModified
        if upgradedURL.scheme == "https", show.feedURL.scheme == "http",
           PodcastFeedURL.identityKey(for: upgradedURL) == PodcastFeedURL.identityKey(for: show.feedURL) {
            show.feedURL = upgradedURL
        }
        let feedMoved = show.feedURL != current.feedURL
        subscribedShows[index] = show
        episodesByShow[show.id] = merged.episodes
        rebuildIndex()
        markDirty(showID: show.id, showsChanged: true)
        if feedMoved { pushSubscriptions() }
        if !merged.addedEpisodeIDs.isEmpty {
            plog("🎙️ '\(show.title)': \(merged.addedEpisodeIDs.count) new episodes")
            if show.settings.autoDownloadsNewEpisodes {
                let added = Set(merged.addedEpisodeIDs)
                PodcastDownloadStore.shared.autoDownload(merged.episodes.filter { added.contains($0.id) })
            }
        }
        postChange()
    }

    private func updateRefreshState(_ showID: String, mutate: (inout PodcastShow) -> Void) {
        guard let index = subscribedShows.firstIndex(where: { $0.id == showID }) else { return }
        mutate(&subscribedShows[index])
        markDirty(showID: nil, showsChanged: true)
    }

    func purgePlayedDownloads() {
        PodcastDownloadStore.shared.deletePlayedDownloads { [weak self] id in
            guard let self, let found = self.episode(id: id) else { return false }
            // 正在放的那集不删。
            if self.nowPlayingEpisodeID() == id { return false }
            return self.state(for: found.episode).isFinished
        }
        purgeUnsubscribedDownloads()
    }

    /// 退订时正在放的那一集,下载先留着;换到别的以后,下次清理(启动、刷新完)再删。
    /// 退订后还开着当预览看的节目先不动:用户可能又从预览里下了一集。
    private func purgeUnsubscribedDownloads() {
        let downloads = PodcastDownloadStore.shared
        let playing = nowPlayingEpisodeID()
        let leftovers = downloads.records.values.filter { record in
            removed[record.showID] != nil
                && !subscribedShows.contains(where: { $0.id == record.showID })
                && previews[record.showID] == nil
                && record.episodeID != playing
        }
        guard !leftovers.isEmpty else { return }
        for record in leftovers { downloads.delete(record.episodeID) }
        plog("🎙️ Removed \(leftovers.count) downloads of unsubscribed podcasts")
    }

    private var nowPlayingEpisodeIDs: Set<String> {
        guard let id = nowPlayingEpisodeID() else { return [] }
        return [id]
    }

    // MARK: - OPML

    func exportOPML() -> Data {
        PodcastOPML.export(shows)
    }

    /// 逐个订阅,失败的跳过。返回成功的数量。
    func importOPML(_ entries: [PodcastOPML.Entry]) async -> (added: Int, failed: Int) {
        guard PodcastAvailabilityService.shared.allowsCustomFeeds else { return (0, entries.count) }
        var added = 0
        var failed = 0
        for entry in entries {
            if isSubscribed(feedURL: entry.feedURL) != nil { continue }
            do {
                try await subscribe(feedURL: entry.feedURL)
                added += 1
            } catch {
                failed += 1
                plog("🎙️ OPML import skipped \(entry.feedURL.host ?? "?"): \(error.localizedDescription)")
            }
        }
        return (added, failed)
    }

    // MARK: - iCloud

    private func pushSubscriptions() {
        guard defaults === UserDefaults.standard else { return }
        let document = PodcastSubscriptionSync.document(shows: subscribedShows, removed: removed, now: Date())
        defaults.set(document.encoded(), forKey: CloudKVSKey.podcastSubscriptions)
        CloudKVSSync.shared.markChanged(key: CloudKVSKey.podcastSubscriptions)
    }

    private func mergeCloudCopy() {
        guard isLoaded, let remote = PodcastSubscriptionDocument.decode(defaults.string(forKey: CloudKVSKey.podcastSubscriptions)) else { return }
        let outcome = PodcastSubscriptionSync.merge(local: subscribedShows, localRemoved: removed, remote: remote, now: Date())
        let before = subscribedShows
        subscribedShows = outcome.shows
        removed = outcome.removed
        for id in outcome.removedShowIDs {
            if let show = before.first(where: { $0.id == id }) {
                previews[id] = (show, episodesByShow[id] ?? [])
            }
            episodesByShow.removeValue(forKey: id)
            PodcastDownloadStore.shared.deleteAll(showID: id, keeping: nowPlayingEpisodeIDs)
            try? FileManager.default.removeItem(at: episodesDirectory.appendingPathComponent(Self.episodesFileName(for: id)))
        }
        rebuildIndex()
        if before != subscribedShows || !outcome.removedShowIDs.isEmpty {
            showsDirty = true
            scheduleSave()
            postChange()
        }
        if outcome.needsPush { pushSubscriptions() }
        if !outcome.addedShowIDs.isEmpty {
            plog("🎙️ iCloud brought \(outcome.addedShowIDs.count) podcast subscriptions")
            // 当前店面不显示的不取 feed;要核的先去目录里核,核过能显示了再取。
            let visible = Set(shows.map(\.id))
            let refreshable = outcome.addedShowIDs.filter { visible.contains($0) }
            if !refreshable.isEmpty { startRefresh(of: refreshable, force: true) }
            verifyRegionalAvailabilityIfNeeded()
        }
    }

    // MARK: - App Store region

    private static let regionChecksKey = "primuse.podcast.regionChecks.v1"

    /// 店面变了(或刚取到)。中国大陆店面上把订阅按本店面目录核一遍;界面跟着 `shows` 自己刷新。
    func availabilityDidChange() {
        regionCheckTask?.cancel()
        regionCheckTask = nil
        verifyRegionalAvailabilityIfNeeded()
        postChange()
    }

    /// 中国大陆店面:有目录 id、还没按本店面核过(或过期)的订阅,一档一档去目录里查。
    /// 查不通的这次跳过,期间仍不显示;店面还没真正取到时不查,免得按手机地区白查一轮。
    func verifyRegionalAvailabilityIfNeeded() {
        let availability = PodcastAvailabilityService.shared
        let policy = availability.policy
        guard isLoaded, availability.isStorefrontResolved, !policy.allowsCustomFeeds, regionCheckTask == nil else { return }
        let now = Date()
        let pending = subscribedShows.filter {
            PodcastRegionGate.needsCheck($0, policy: policy, check: regionChecks[$0.id], now: now)
        }
        guard !pending.isEmpty else { return }
        regionCheckTask = Task { @MainActor [weak self] in
            var becameVisible: [String] = []
            for show in pending {
                guard !Task.isCancelled, let directoryID = show.directoryID else { break }
                do {
                    let found = try await PodcastDirectoryService.shared.lookup(directoryID)
                    guard !Task.isCancelled, let self else { return }
                    self.recordRegionCheck(showID: show.id, available: found != nil, country: policy.directoryCountry)
                    if found != nil { becameVisible.append(show.id) }
                } catch {
                    plog("🎙️ Region check failed for '\(show.title)': \(error.localizedDescription)")
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.regionCheckTask = nil
            plog("🎙️ Region check (\(policy.directoryCountry)): \(pending.count) checked, \(self.regionHiddenShowCount) hidden")
            // 刚核出来能显示的,单集可能还停在别的店面时取的那一份。
            let due = becameVisible.filter { id in
                self.subscribedShows.first { $0.id == id }.map {
                    PodcastRefreshSchedule.isDue(lastRefreshedAt: $0.lastRefreshedAt, failureCount: 0, now: Date())
                } ?? false
            }
            if !due.isEmpty, self.refreshAllTask == nil { self.startRefresh(of: due, force: false) }
        }
    }

    private func recordRegionCheck(showID: String, available: Bool, country: String? = nil) {
        let country = country ?? PodcastAvailabilityService.shared.policy.directoryCountry
        let check = PodcastRegionGate.Check(country: country, available: available, checkedAt: Date())
        guard regionChecks[showID] != check else { return }
        regionChecks[showID] = check
        // 退订过、早已不在订阅里的不留。
        let subscribed = Set(subscribedShows.map(\.id)).union(previews.keys)
        regionChecks = regionChecks.filter { subscribed.contains($0.key) }
        if let data = try? JSONEncoder().encode(regionChecks) {
            defaults.set(data, forKey: Self.regionChecksKey)
        }
        postChange()
    }

    private func loadRegionChecks() -> [String: PodcastRegionGate.Check] {
        guard let data = defaults.data(forKey: Self.regionChecksKey),
              let checks = try? JSONDecoder().decode([String: PodcastRegionGate.Check].self, from: data) else { return [:] }
        return checks
    }

    // MARK: - Liked episodes

    func isLiked(episodeID: String) -> Bool {
        likedEpisodeIDs.contains(episodeID)
    }

    /// 喜欢或取消一集。算用户的决定:推 iCloud。
    func setLiked(_ liked: Bool, episode: PodcastEpisode) {
        guard isLoaded, likeDocument.set(liked, episodeID: episode.id, at: Date()) else { return }
        if liked {
            likedSnapshots[episode.id] = likedSnapshot(of: episode, likedAt: Date())
        } else {
            likedSnapshots.removeValue(forKey: episode.id)
        }
        likedEpisodeIDs = Set(likeDocument.liked.keys)
        saveLikes()
        pushLikes()
        postChange()
        plog("🎙️ \(liked ? "Liked" : "Unliked") episode '\(episode.title)'")
    }

    /// 正在放的、菜单里点的那一集:按 id 找,feed 里没有了就用快照。
    func toggleLiked(episodeID: String) {
        guard let episode = episode(id: episodeID)?.episode ?? likedSnapshots[episodeID]?.episode else { return }
        setLiked(!isLiked(episodeID: episodeID), episode: episode)
    }

    /// 喜欢的单集,最近喜欢的在前。feed 里还有就用 feed 里的内容,没有了用快照;
    /// 别的设备喜欢、本机还没见过的那几集先不列。
    func likedEpisodes() -> [PodcastLikedEpisodeItem] {
        // 账本本身不被观察;读一下这个,喜欢或取消后列表跟着刷新。
        _ = likedEpisodeIDs
        let ordered = likeDocument.liked.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var items: [PodcastLikedEpisodeItem] = []
        items.reserveCapacity(ordered.count)
        for entry in ordered {
            if let found = episode(id: entry.key) {
                items.append(PodcastLikedEpisodeItem(episode: found.episode, show: found.show, showTitle: found.show.title))
            } else if let snapshot = likedSnapshots[entry.key] {
                items.append(PodcastLikedEpisodeItem(
                    episode: snapshot.episode,
                    show: show(id: snapshot.episode.showID),
                    showTitle: snapshot.showTitle
                ))
            }
        }
        return items
    }

    /// 喜欢的单集的封面地址,节目退订后也还有。
    func likedShowArtworkURL(episodeID: String) -> URL? {
        likedSnapshots[episodeID]?.showArtworkURL
    }

    private func likedSnapshot(of episode: PodcastEpisode, likedAt: Date) -> PodcastLikedEpisode {
        let show = show(id: episode.showID)
        return PodcastLikedEpisode(
            episode: episode,
            showTitle: show?.title ?? "",
            showArtworkURL: show?.artworkURL,
            likedAt: likedAt
        )
    }

    /// 别的设备喜欢的、本机刚刷新出来的单集补上快照。
    private func captureLikedSnapshots() {
        var captured = false
        for (id, likedAt) in likeDocument.liked where likedSnapshots[id] == nil {
            guard let found = episode(id: id) else { continue }
            likedSnapshots[id] = likedSnapshot(of: found.episode, likedAt: likedAt)
            captured = true
        }
        if captured { saveLikes() }
    }

    private func pushLikes() {
        guard defaults === UserDefaults.standard else { return }
        defaults.set(likeDocument.encoded(), forKey: CloudKVSKey.podcastLikedEpisodes)
        CloudKVSSync.shared.markChanged(key: CloudKVSKey.podcastLikedEpisodes)
    }

    private func mergeCloudLikes() {
        guard isLoaded,
              let remote = PodcastLikeDocument.decode(defaults.string(forKey: CloudKVSKey.podcastLikedEpisodes)) else { return }
        let outcome = PodcastLikeSync.merge(local: likeDocument, remote: remote, now: Date())
        if outcome.document != likeDocument {
            likeDocument = outcome.document
            likedSnapshots = likedSnapshots.filter { likeDocument.liked[$0.key] != nil }
            likedEpisodeIDs = Set(likeDocument.liked.keys)
            captureLikedSnapshots()
            saveLikes()
            postChange()
        }
        if outcome.needsPush { pushLikes() }
    }

    private func saveLikes() {
        guard isLoaded else { return }
        let library = LikedLibrary(
            document: likeDocument,
            snapshots: likedSnapshots.values.sorted { $0.likedAt > $1.likedAt }
        )
        let directory = directory
        let url = likedURL
        Task.detached(priority: .utility) {
            guard let data = try? Self.makeEncoder().encode(library) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Persistence

    private func rebuildIndex() {
        var index: [String: (showID: String, index: Int)] = [:]
        for (showID, episodes) in episodesByShow {
            for (position, episode) in episodes.enumerated() { index[episode.id] = (showID, position) }
        }
        episodeShowIndex = index
        if isLoaded { captureLikedSnapshots() }
    }

    private func markDirty(showID: String?, showsChanged: Bool) {
        if let showID { dirtyShowIDs.insert(showID) }
        if showsChanged { showsDirty = true }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// 退后台时立刻写。
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func saveNow() {
        guard isLoaded else { return }
        let library = showsDirty ? LocalLibrary(shows: subscribedShows, removed: removed) : nil
        let episodes = dirtyShowIDs.compactMap { id in episodesByShow[id].map { (id, $0) } }
        showsDirty = false
        dirtyShowIDs = []
        guard library != nil || !episodes.isEmpty else { return }
        let directory = directory
        let episodesDirectory = episodesDirectory
        Task.detached(priority: .utility) {
            let encoder = Self.makeEncoder()
            try? FileManager.default.createDirectory(at: episodesDirectory, withIntermediateDirectories: true)
            if let library, let data = try? encoder.encode(library) {
                try? data.write(to: directory.appendingPathComponent("shows.json"), options: .atomic)
            }
            for (id, list) in episodes {
                guard let data = try? encoder.encode(list) else { continue }
                try? data.write(to: episodesDirectory.appendingPathComponent(Self.episodesFileName(for: id)), options: .atomic)
            }
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .primusePodcastsDidChange, object: nil)
    }

    nonisolated private static func episodesFileName(for showID: String) -> String {
        PodcastIdentity.digest(showID) + ".json"
    }

    nonisolated private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
