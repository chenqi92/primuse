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
}

extension Notification.Name {
    /// 订阅、单集列表或某档节目的设置变了。
    static let primusePodcastsDidChange = Notification.Name("primuse.podcastsDidChange")
}

/// 订阅的播客节目和它们的单集。
///
/// - 节目与单集存在 `Application Support/Primuse/Podcasts`:节目一份 `shows.json`,
///   单集每档一个文件,刷新一档只重写那一档。
/// - 订阅定义经 iCloud 键值存储同步(`PodcastSubscriptionDocument`),只在用户改动时推。
///   刷新得来的东西(单集、ETag)每台设备自己取。
/// - 听到哪、听没听完记在有声内容那份账(`SpokenWordStore`,也同步);
///   「全部标为已播」用每档一条水位线(`PodcastShow.playedThrough`),不逐集写。
@MainActor
@Observable
final class PodcastStore {
    static let shared = PodcastStore()

    private(set) var shows: [PodcastShow] = []
    private(set) var episodesByShow: [String: [PodcastEpisode]] = [:]
    private(set) var isLoaded = false
    private(set) var refreshingShowIDs: Set<String> = []
    /// 节目 id → 最近一次刷新失败的原因。成功一次就清掉。
    private(set) var refreshFailures: [String: String] = [:]
    /// 预览(还没订阅的节目)。订阅时直接转正,不用再取一次 feed。
    private(set) var previews: [String: (show: PodcastShow, episodes: [PodcastEpisode])] = [:]

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
    /// 正在放的那一集。删已播下载时要跳过它;各端启动时接上自己的播放器。
    @ObservationIgnored var nowPlayingEpisodeID: @MainActor () -> String? = { nil }

    private let defaults: UserDefaults
    private let directory: URL
    private var episodesDirectory: URL { directory.appendingPathComponent("Episodes", isDirectory: true) }
    private var showsURL: URL { directory.appendingPathComponent("shows.json") }

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

    /// 读盘在后台做;订阅很多时单集文件加起来有几 MB。读完才接上 iCloud,
    /// 否则云端那份会和一个空的本机合并,把所有节目当成新订阅。
    func loadIfNeeded() {
        guard !isLoaded, loadTask == nil else { return }
        let directory = directory
        let episodesDirectory = episodesDirectory
        loadTask = Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> (LocalLibrary, [String: [PodcastEpisode]]) in
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
                return (library, episodes)
            }.value
            guard let self else { return }
            self.shows = loaded.0.shows
            self.removed = loaded.0.removed ?? [:]
            self.episodesByShow = loaded.1
            self.rebuildIndex()
            self.isLoaded = true
            self.loadTask = nil
            self.registerWithCloud()
            self.postChange()
            plog("🎙️ Podcasts loaded: \(self.shows.count) shows, \(self.episodeShowIndex.count) episodes")
        }
    }

    private func registerWithCloud() {
        guard !isRegisteredWithCloud, defaults === UserDefaults.standard else { return }
        isRegisteredWithCloud = true
        CloudKVSSync.shared.register(key: CloudKVSKey.podcastSubscriptions) { [weak self] in
            Task { @MainActor [weak self] in self?.mergeCloudCopy() }
        }
    }

    // MARK: - Reading

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
        episodesByShow[showID] ?? previews[showID]?.episodes ?? []
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
            episodesByShow: episodesByShow,
            state: state(for:),
            excludingFinished: !includeFinished,
            limit: limit
        )
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

        var errorDescription: String? {
            switch self {
            case .notInDirectory: String(localized: "podcast_error_not_in_directory")
            }
        }
    }

    /// 取一档节目来看,不订阅。已经订了就直接给本机那份。
    @discardableResult
    func preview(feedURL: URL, directoryID: Int? = nil) async throws -> PodcastShow {
        if let existing = isSubscribed(feedURL: feedURL) { return existing }
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
        return try await preview(feedURL: feedURL, directoryID: directoryShow.id)
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
        if let existing = shows.first(where: { $0.id == previewID }) { return existing }
        guard let preview = previews.removeValue(forKey: previewID) else { return nil }
        var show = preview.show
        let now = Date()
        show.subscribedAt = now
        show.definitionModifiedAt = now
        shows.append(show)
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
        guard let index = shows.firstIndex(where: { $0.id == showID }) else { return }
        let show = shows.remove(at: index)
        episodesByShow.removeValue(forKey: showID)
        refreshFailures.removeValue(forKey: showID)
        removed[showID] = Date()
        rebuildIndex()
        PodcastDownloadStore.shared.deleteAll(showID: showID)
        try? FileManager.default.removeItem(at: episodesDirectory.appendingPathComponent(Self.episodesFileName(for: showID)))
        showsDirty = true
        scheduleSave()
        pushSubscriptions()
        postChange()
        plog("🎙️ Unsubscribed '\(show.title)'")
    }

    /// 改一档节目的设置或水位线。算用户的决定:推 iCloud。
    func updateDefinition(_ showID: String, mutate: (inout PodcastShow) -> Void) {
        guard let index = shows.firstIndex(where: { $0.id == showID }) else { return }
        var show = shows[index]
        mutate(&show)
        show.definitionModifiedAt = Date()
        shows[index] = show
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

    /// 本机下载过、听过一半或听完的单集:feed 只留最近几十集时也别把它们冲掉。
    private func retainedEpisodeIDs(_ episodes: [PodcastEpisode]) -> Set<String> {
        let spokenWord = SpokenWordStore.shared
        let downloads = PodcastDownloadStore.shared
        return Set(episodes.lazy.map(\.id).filter {
            downloads.isDownloaded($0) || spokenWord.position(forSongID: $0) != nil || spokenWord.isFinished(songID: $0)
        })
    }

    private func apply(_ merged: PodcastFeedMerge.Result, etag: String?, lastModified: String?, upgradedURL: URL) {
        guard let index = shows.firstIndex(where: { $0.id == merged.show.id }) else { return }
        // 刷新期间用户改了设置或退订后又订:定义部分以本机此刻为准。
        var show = merged.show
        let current = shows[index]
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
        shows[index] = show
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
        guard let index = shows.firstIndex(where: { $0.id == showID }) else { return }
        mutate(&shows[index])
        markDirty(showID: nil, showsChanged: true)
    }

    func purgePlayedDownloads() {
        PodcastDownloadStore.shared.deletePlayedDownloads { [weak self] id in
            guard let self, let found = self.episode(id: id) else { return false }
            // 正在放的那集不删。
            if self.nowPlayingEpisodeID() == id { return false }
            return self.state(for: found.episode).isFinished
        }
    }

    // MARK: - OPML

    func exportOPML() -> Data {
        PodcastOPML.export(shows)
    }

    /// 逐个订阅,失败的跳过。返回成功的数量。
    func importOPML(_ entries: [PodcastOPML.Entry]) async -> (added: Int, failed: Int) {
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
        let document = PodcastSubscriptionSync.document(shows: shows, removed: removed, now: Date())
        defaults.set(document.encoded(), forKey: CloudKVSKey.podcastSubscriptions)
        CloudKVSSync.shared.markChanged(key: CloudKVSKey.podcastSubscriptions)
    }

    private func mergeCloudCopy() {
        guard isLoaded, let remote = PodcastSubscriptionDocument.decode(defaults.string(forKey: CloudKVSKey.podcastSubscriptions)) else { return }
        let outcome = PodcastSubscriptionSync.merge(local: shows, localRemoved: removed, remote: remote, now: Date())
        let before = shows
        shows = outcome.shows
        removed = outcome.removed
        for id in outcome.removedShowIDs {
            episodesByShow.removeValue(forKey: id)
            PodcastDownloadStore.shared.deleteAll(showID: id)
            try? FileManager.default.removeItem(at: episodesDirectory.appendingPathComponent(Self.episodesFileName(for: id)))
        }
        rebuildIndex()
        if before != shows || !outcome.removedShowIDs.isEmpty {
            showsDirty = true
            scheduleSave()
            postChange()
        }
        if outcome.needsPush { pushSubscriptions() }
        if !outcome.addedShowIDs.isEmpty {
            plog("🎙️ iCloud brought \(outcome.addedShowIDs.count) podcast subscriptions")
            startRefresh(of: outcome.addedShowIDs, force: true)
        }
    }

    // MARK: - Persistence

    private func rebuildIndex() {
        var index: [String: (showID: String, index: Int)] = [:]
        for (showID, episodes) in episodesByShow {
            for (position, episode) in episodes.enumerated() { index[episode.id] = (showID, position) }
        }
        episodeShowIndex = index
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
        let library = showsDirty ? LocalLibrary(shows: shows, removed: removed) : nil
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
