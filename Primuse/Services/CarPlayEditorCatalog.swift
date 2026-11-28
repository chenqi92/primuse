#if os(iOS)
import Foundation
import Observation
import PrimuseKit

/// Source projection has its own lifetime; layout edits never invalidate it.
@MainActor @Observable
final class CarPlayEditorCatalog {

    private(set) var snapshot = Snapshot()
    private(set) var revision = 0
    private(set) var isLoading = false
    private(set) var projectionCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var owners: Set<UUID> = []
    @ObservationIgnored private var cachedVersion: String?
    /// 「为你推荐」最近算好的那一批(哪一天、本机挑的先后、每首的那一项):歌曲模型不在内存里时首页用它(C2)。
    @ObservationIgnored private var forYouCarry: ForYouCarry?
    /// 模型不在内存里而这一天还没有「为你推荐」时,为它占用一次模型(一天至多一次)。
    @ObservationIgnored private var forYouHoldDay: Int?
    @ObservationIgnored private var forYouHoldTask: Task<Void, Never>?
    /// 眼下这份是真答案(模型在内存里时投影的,或从目录取的),不是启动发布之前拿空数组投影出的那份空的。
    @ObservationIgnored private var answered = false
    /// 从目录取首页时同一时刻只读一份:读的途中又要重来(扫描期间目录一秒动几回),读完再按最新的来一次。
    @ObservationIgnored private var catalogRefreshRunning = false
    @ObservationIgnored private var catalogRefreshPending = false
    @ObservationIgnored nonisolated(unsafe) private var memoryPressureObserver: NSObjectProtocol?

    init() {
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .primuseMemoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reclaimSnapshotIfIdle()
            }
        }
    }

    deinit {
        if let memoryPressureObserver {
            NotificationCenter.default.removeObserver(memoryPressureObserver)
        }
    }
}

extension CarPlayEditorCatalog {
    static let shared = CarPlayEditorCatalog()
    struct Snapshot: Sendable {
        var entries: [CarPlayLayoutItem.Kind: [CarPlayHomeItem]] = [:]
        var lookup: [CarPlayLayoutItem.Kind: [String: CarPlayHomeItem]] = [:]
        var recent: [CarPlayHomeItem] = []
        var recentAlbums: [CarPlayHomeItem] = []
        var ranking: [CarPlayHomeItem] = []
        var forYou: [CarPlayHomeItem] = []
        var startListening: [CarPlayHomeItem] = []
        var recentlyPlayed: [CarPlayHomeItem] = []
        var memberships: [String: [String]] = [:]
        var albumSongs: [String: [String]] = [:]
        var artists: [Artist] = []
        var artistSongs: [String: [String]] = [:]
        var searchItems: [CarPlayLayoutItem.Kind: [CarPlayLayoutItem]] = [:]
        /// 「为你推荐」本机挑出的那几首(智能排序之前的先后):模型放掉之后首页按它与新的智能排序重排(C2)。
        var forYouLocalIDs: [String] = []

        func resolve(_ item: CarPlayLayoutItem, directly: Bool) -> CarPlayHomeItem {
            if item.kind == .nowPlaying {
                return CarPlayHomeItem(id: item.id, title: item.title, symbol: "play.circle", enabled: false, target: .nowPlaying)
            }
            guard let value = lookup[item.kind]?[item.targetID] else {
                return CarPlayHomeItem(id: item.id, title: item.title,
                    subtitle: String(localized: "carplay_content_unavailable"),
                    symbol: "exclamationmark.circle", enabled: false, target: .unavailable)
            }
            return value.configured(id: item.id, directly: directly)
        }

        func blocks(for configuration: CarPlayLayoutConfiguration, folders: LibraryFolderIndex? = nil,
                    nowPlaying: CarPlayHomeItem? = nil) -> [CarPlayHomeBlock] {
            blocks(configuration.blocks, in: configuration, folders: folders, nowPlaying: nowPlaying)
        }

        /// 同一套取法，块由调用方给（不经过布局的规整，个数不封顶）：首页每块多取一个判断后面还有没有，
        /// 「查看全部」只受车机列表上限。返回的块与传入的一一对应、顺序不变。
        func blocks(_ blocks: [CarPlayLayoutBlock], in configuration: CarPlayLayoutConfiguration,
                    folders: LibraryFolderIndex? = nil, nowPlaying: CarPlayHomeItem? = nil) -> [CarPlayHomeBlock] {
            blocks.map { block in
                var items: [CarPlayHomeItem]
                if (block.usesCustomContent && !block.kind.keepsLiveContent) || block.kind == .custom {
                    items = block.items.prefix(block.itemLimit).map { item in
                        if item.kind == .nowPlaying, let nowPlaying {
                            return nowPlaying.configured(id: item.id, directly: block.playsImmediately)
                        }
                        if let id = item.folderID, let node = folders?.node(withID: id) {
                            return Self.folder(node).configured(id: item.id, directly: block.playsImmediately)
                        }
                        return resolve(item, directly: block.playsImmediately)
                    }
                } else {
                    switch block.kind {
                    case .siri: items = []
                    case .ranking: items = Array(ranking.prefix(block.itemLimit))
                    case .forYou: items = Array(forYou.prefix(block.itemLimit))
                    case .startListening: items = Array(startListening.prefix(block.itemLimit))
                    case .recentlyPlayed: items = Array(recentlyPlayed.prefix(block.itemLimit))
                    case .shortcuts:
                        items = nowPlaying.map { [$0] } ?? []
                        let pinned = [MusicLibrary.likedSongsPlaylistID] + configuration.pinnedPlaylistIDs.filter { $0 != MusicLibrary.likedSongsPlaylistID }
                        items += pinned.compactMap { lookup[.playlist]?[$0] }
                        items += configuration.folderIDs.compactMap { folders?.node(withID: $0).map(Self.folder) }
                    case .playlists: items = Array((entries[.playlist] ?? []).prefix(block.itemLimit))
                    case .albums: items = Array((entries[.album] ?? []).prefix(block.itemLimit))
                    case .recentlyAdded:
                        items = Array((block.recentlyAddedGrouping == .albums ? recentAlbums : recent).prefix(block.itemLimit))
                    case .radio: items = Array((entries[.radio] ?? []).prefix(block.itemLimit))
                    case .folders: items = (folders?.sourceNodes ?? []).prefix(block.itemLimit).map(Self.folder)
                    case .custom: items = []
                    }
                    items = items.prefix(block.itemLimit).map { $0.configured(directly: block.playsImmediately) }
                }
                return CarPlayHomeBlock(configuration: block, items: items)
            }
        }

        func detail(for item: CarPlayHomeItem) -> [CarPlayHomeItem] {
            let ids: [String]
            switch item.target {
            case .playlist(let id, _): ids = memberships[id] ?? []
            case .album(let id, _): ids = albumSongs[id] ?? []
            default: return []
            }
            return ids.lazy.compactMap { lookup[.song]?[$0] }.prefix(60).map { $0 }
        }

        static func folder(_ node: LibraryFolderNode) -> CarPlayHomeItem {
            CarPlayHomeItem(id: HomeFolderPinStorage.encode([node.id]), title: HomeDiscoveryText.folderTitle(node),
                subtitle: String(format: String(localized: "carplay_playlist_song_count_format"), node.descendantSongCount),
                symbol: "folder.fill", enabled: node.descendantSongCount > 0, target: .folder(node.id, directly: true))
        }
    }

    struct Input: Sendable {
        var songs: [Song]
        var albums: [Album]
        var playlists: [Playlist]
        var memberships: [String: [String]]
        var stations: [CarPlayHomeItem]
        var artistNames: ArtistNameConfiguration
        var history: [HomeListeningEvent] = []
        /// 播放记录里本机找不到的歌认出的本机候选(`PlayHistoryStore.resolvedHistoryCandidates`),至多 5000 项。
        var historyCandidates: [String: [String]] = [:]
        var artists: [Artist] = []
        /// Kept out of "recently added": one scanned-in audiobook would fill
        /// the whole block with its chapters.
        var spokenWordSongIDs: Set<String> = []
        /// 下面几项只在布局里有对应模块时才取,没有就不算。
        var recommendation: MusicDiscoveryEngine.RecommendationSnapshot?
        /// 手机首页「为你推荐」已经拿到的智能排序,排在前面;车机自己不去问智能服务。
        var intelligentForYouOrder: [String] = []
        var recentlyPlayedIDs: [String] = []
        var listeningIntents: [CarPlayHomeItem] = []
    }

    func acquire(_ owner: UUID) {
        guard owners.insert(owner).inserted, owners.count == 1 else { return }
        observing = true
        observationGeneration &+= 1
        observe(observationGeneration)
        refresh()
    }

    func release(_ owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        observing = false
        observationGeneration &+= 1
        generation &+= 1
        task?.cancel()
        task = nil
        forYouHoldTask?.cancel()
        forYouHoldTask = nil
        isLoading = false
        reclaimSnapshotIfIdle()
    }

    private func reclaimSnapshotIfIdle() {
        guard owners.isEmpty else { return }
        let displaced = snapshot
        snapshot = Snapshot()
        cachedVersion = nil
        answered = false
        Task.detached(priority: .utility) { withExtendedLifetime(displaced) {} }
    }

    private func observe(_ expected: Int) {
        withObservationTracking {
            let library = AppServices.shared.musicLibrary
            _ = library.visibleSongCollectionRevision
            _ = library.searchRevision
            _ = library.playlistCollectionRevision
            _ = library.artistNameConfiguration
            _ = AppServices.shared.radioStationsStore.stations
            _ = PlayHistoryStore.shared.entries
            _ = PlayHistoryStore.shared.resolutionRevision
            let wanted = Self.wantedLiveKinds()
            if wanted.contains(.forYou) {
                _ = HomeForYouAIFeed.shared.resultKey
                _ = HomeForYouAIFeed.shared.recommendation.orderedSongIDs
            }
            if wanted.contains(.startListening) {
                _ = ListeningIntentService.shared.row(player: AppServices.shared.playerService)
            }
            if wanted.contains(.recentlyPlayed) { _ = library.recentlyPlayedSongs(limit: 1) }
            // 歌曲模型不在内存里时首页跟着曲库目录走(C2);在内存里时与以前相同,只多看装上、放掉这一下。
            _ = library.isReady
            if !library.isReady {
                _ = library.isUsable
                _ = LibraryFavoritesStore.shared.revision
                _ = CarPlaySettingsStore.shared.configuration
                if let revisions = library.catalogHost?.revisions {
                    _ = revisions.isReadable
                    _ = revisions.songs
                    _ = revisions.membership
                    _ = revisions.albums
                    _ = revisions.everything
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing, expected == self.observationGeneration else { return }
                self.observe(expected)
                self.refresh()
            }
        }
    }

    private func refresh() {
        let library = AppServices.shared.musicLibrary
        let wanted = Self.wantedLiveKinds()
        let now = Date()
        let intelligentOrder = wanted.contains(.forYou) ? Self.intelligentForYouOrder() : []
        let recentSongs = wanted.contains(.recentlyPlayed) ? library.recentlyPlayedSongs(limit: 60) : []
        let recentIDs = recentSongs.map(\.id)
        let intents = wanted.contains(.startListening) ? Self.listeningIntentItems(library: library) : []
        let radioVersion = AppServices.shared.radioStationsStore.stations.map { $0.id + $0.name + $0.playbackSubtitle }.joined(separator: "|")
        // 每日推荐跨天会换一批,带上日期。
        let liveVersion = [
            wanted.map(\.rawValue).sorted().joined(separator: ","),
            wanted.contains(.forYou) ? String(Int(Calendar.current.startOfDay(for: now).timeIntervalSinceReferenceDate)) : "",
            intelligentOrder.joined(separator: ","),
            recentIDs.joined(separator: ","),
            intents.map { $0.id + "/" + ($0.subtitle ?? "") }.joined(separator: ","),
        ].joined(separator: "#")
        var version = "\(library.visibleSongCollectionRevision):\(library.searchRevision):\(library.playlistCollectionRevision):\(PlayHistoryStore.shared.revision):\(PlayHistoryStore.shared.resolutionRevision):\(radioVersion):\(liveVersion)"
        // 歌曲模型不在内存里(放掉了,或这次启动没装):不读整库数组,首页从曲库目录取(C2)。
        if !library.isReady, library.isUsable || library.songModelLaunch == "unloaded"
            || library.songModelResidencyStatistics.releases > 0 {
            version += catalogVersion(library)
            guard version != cachedVersion else { return }
            refreshFromTheCatalog(library, wanted: wanted, now: now, intelligentOrder: intelligentOrder,
                                  recentSongs: recentSongs, intents: intents, sourceVersion: version)
            return
        }
        guard version != cachedVersion else { return }
        load(Self.memoryInput(library, wanted: wanted, now: now, intelligentOrder: intelligentOrder, recentIDs: recentIDs,
                              intents: intents), sourceVersion: version, answers: library.isReady)
    }

    /// 模型在内存里时首页的输入(整库数组),与以前逐字相同。
    static func memoryInput(
        _ library: MusicLibrary, wanted: Set<CarPlayLayoutBlockKind>, now: Date, intelligentOrder: [String],
        recentIDs: [String], intents: [CarPlayHomeItem]
    ) -> Input {
        let playlists = library.playlists
        let musicEntries = PlayHistoryStore.shared.musicEntries
        return Input(songs: library.visibleSongs, albums: library.visibleAlbums,
            playlists: playlists, memberships: Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, library.rawSongIDs(forPlaylist: $0.id)) }),
            stations: AppServices.shared.radioStationsStore.stations.map {
                CarPlayHomeItem(id: $0.id, title: $0.name, subtitle: $0.playbackSubtitle, symbol: "radio", target: .radio($0.id))
            }, artistNames: library.artistNameConfiguration, history: musicEntries.map(\.listeningEvent),
            historyCandidates: PlayHistoryStore.shared.resolvedHistoryCandidates, artists: library.visibleArtists,
            // 有声与环境音都不进「最近添加」。
            spokenWordSongIDs: library.nonMusicSongIDs,
            // 与手机首页同一套输入,同一天里两边推荐的是同一批歌。
            recommendation: wanted.contains(.forYou) ? MusicDiscoveryEngine.RecommendationSnapshot(
                songs: library.musicSongs, recentSongs: library.recentlyPlayedSongs(limit: 12), historyEntries: musicEntries,
                now: now, libraryRevision: library.musicSongsRevision, excludedSongIDs: library.dislikedSongIDs) : nil,
            intelligentForYouOrder: intelligentOrder, recentlyPlayedIDs: recentIDs, listeningIntents: intents)
    }

    private static func wantedLiveKinds() -> Set<CarPlayLayoutBlockKind> {
        CarPlaySettingsStore.shared.liveKinds
    }

    private static func intelligentForYouOrder() -> [String] {
        let feed = HomeForYouAIFeed.shared
        guard feed.resultKey != nil, !feed.recommendation.isStreaming,
              HomeForYouAIFeed.isAvailable(AppServices.shared.musicIntelligence) else { return [] }
        return feed.recommendation.orderedSongIDs
    }

    /// 「开始听」的卡片与手机首页同一行;车机冷启动时首页还没出现过,由这里先点亮一次。
    private static func listeningIntentItems(library: MusicLibrary) -> [CarPlayHomeItem] {
        let service = ListeningIntentService.shared
        service.refresh(library: library)
        return service.row(player: AppServices.shared.playerService).map { item in
            CarPlayHomeItem(id: "intent." + item.id, title: service.title(for: item.intent),
                subtitle: String(format: String(localized: "carplay_playlist_song_count_format"), item.songCount),
                symbol: item.intent.symbolName, target: .listeningIntent(item.intent.id))
        }
    }

    func load(_ input: Input, sourceVersion: String? = nil, answers: Bool = true) {
        task?.cancel()
        generation &+= 1
        let expected = generation
        isLoading = revision == 0
        let forYouDay = input.recommendation.map { Self.day(of: $0.now) }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { Self.project(input) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, expected == self.generation else { return }
            if let forYouDay { self.forYouCarry = ForYouCarry(day: forYouDay, snapshot: result) }
            self.answered = answers
            self.snapshot = result
            self.cachedVersion = sourceVersion
            self.revision &+= 1
            self.projectionCount &+= 1
            self.isLoading = false
        }
    }

    func waitForLoad() async { await task?.value }

    nonisolated static func project(_ input: Input) -> Snapshot {
        var result = Snapshot()
        guard !Task.isCancelled else { return result }
        let valid = Set(input.songs.map(\.id))
        result.memberships = input.memberships
        result.artists = input.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.artistSongs = Dictionary(grouping: input.songs, by: { $0.artistID ?? "" }).mapValues { $0.map(\.id) }
        let songs = input.songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        result.entries[.song] = songs.map {
            CarPlayHomeItem(id: $0.id, title: $0.title, subtitle: $0.displayArtistName(configuration: input.artistNames), artwork: .songReference(id: $0.id, coverRef: $0.coverArtFileName), target: .song($0.id, queue: [$0.id]))
        }
        guard !Task.isCancelled else { return result }
        let musicSongs = input.songs.filter { !input.spokenWordSongIDs.contains($0.id) }
        let recent = musicSongs.sorted { $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded > $1.dateAdded }.prefix(100)
        let queue = recent.map(\.id)
        result.recent = recent.map {
            CarPlayHomeItem(id: $0.id, title: $0.title, subtitle: $0.displayArtistName(configuration: input.artistNames), artwork: .songReference(id: $0.id, coverRef: $0.coverArtFileName), target: .song($0.id, queue: queue))
        }
        let albums = input.albums.filter { !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let albumIDs = Set(albums.map(\.id))
        var albumDates: [String: Date] = [:]
        var singles: [Song] = []
        // Aggregate the whole library before limiting cards: one large album
        // must not consume all the recent-track slots and hide other albums.
        for song in musicSongs {
            if let id = song.albumID, albumIDs.contains(id) {
                albumDates[id] = max(albumDates[id] ?? .distantPast, RecentlyAddedAlbumPolicy.date(for: song))
            } else {
                singles.append(song)
            }
        }
        var recentCollections: [(item: CarPlayHomeItem, date: Date)] = albums.compactMap { album in
            guard let date = albumDates[album.id] else { return nil }
            return (CarPlayHomeItem(id: "recent.album:" + album.id, title: album.title, subtitle: album.artistName,
                symbol: "square.stack", artwork: .album(album), target: .album(album.id, directly: true)), date)
        }
        singles.sort {
            let lhs = RecentlyAddedAlbumPolicy.date(for: $0), rhs = RecentlyAddedAlbumPolicy.date(for: $1)
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        let singleQueue = singles.prefix(100).map(\.id)
        recentCollections += singles.prefix(60).map { song in
            (CarPlayHomeItem(id: "recent.song:" + song.id, title: song.title,
                subtitle: song.displayArtistName(configuration: input.artistNames),
                artwork: .songReference(id: song.id, coverRef: song.coverArtFileName),
                target: .song(song.id, queue: singleQueue)), RecentlyAddedAlbumPolicy.date(for: song))
        }
        result.recentAlbums = recentCollections.sorted {
            $0.date == $1.date ? $0.item.id < $1.item.id : $0.date > $1.date
        }.prefix(60).map(\.item)
        result.albumSongs = Dictionary(grouping: input.songs, by: { $0.albumID ?? "" }).mapValues { songs in
            AlbumTrackOrder.sorted(songs).map(\.id)
        }
        guard !Task.isCancelled else { return result }
        result.entries[.album] = input.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map {
            CarPlayHomeItem(id: $0.id, title: $0.title, subtitle: $0.artistName, symbol: "square.stack", artwork: .album($0), target: .album($0.id, directly: true))
        }
        result.entries[.playlist] = input.playlists.sorted { $0.updatedAt > $1.updatedAt }.map {
            let count = (input.memberships[$0.id] ?? []).reduce(0) { $0 + (valid.contains($1) ? 1 : 0) }
            return CarPlayHomeItem(id: $0.id, title: $0.name,
                subtitle: String(format: String(localized: "carplay_playlist_song_count_format"), count),
                symbol: $0.id == MusicLibrary.likedSongsPlaylistID ? "heart.fill" : "music.note.list",
                artwork: .playlist($0), enabled: count > 0, target: .playlist($0.id, directly: true))
        }
        result.entries[.radio] = input.stations
        for (kind, values) in result.entries {
            result.lookup[kind] = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            result.searchItems[kind] = values.map { CarPlayLayoutItem(id: $0.id, kind: kind, targetID: $0.id, title: $0.title) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        if let recommendation = input.recommendation {
            let local = MusicDiscoveryEngine.dailyRecommendations(from: recommendation.makeInput(), limit: 12,
                isCancelled: { Task.isCancelled }).map(\.song.id)
            result.forYouLocalIDs = local
            let candidates = Set(local)
            var seen = Set<String>()
            let queue = (input.intelligentForYouOrder.filter(candidates.contains) + local).filter { seen.insert($0).inserted }
            result.forYou = queue.compactMap { id in
                result.lookup[.song]?[id].map { CarPlayHomeItem(id: $0.id, title: $0.title, subtitle: $0.subtitle,
                    artwork: $0.artwork, target: .song($0.id, queue: queue)) }
            }
        }
        let recentQueue = input.recentlyPlayedIDs.filter(valid.contains)
        result.recentlyPlayed = recentQueue.compactMap { id in
            result.lookup[.song]?[id].map { CarPlayHomeItem(id: $0.id, title: $0.title, subtitle: $0.subtitle,
                artwork: $0.artwork, target: .song($0.id, queue: recentQueue)) }
        }
        result.startListening = input.listeningIntents
        guard !Task.isCancelled else { return result }
        let ranked = HomeListeningRanking.ranks(events: input.history, songs: [:], folders: nil, period: .all, category: .songs)
        // 同一首歌在几个源里各有一份时取库里还在的那份;别的设备上播的、本机 ID 不同的,取认出来的本机那首。
        let rankedQueue = ranked.compactMap { rank in
            rank.songGroups.first.flatMap {
                ListeningSongIdentity.expandingCandidateIDs($0, candidates: input.historyCandidates).first(where: valid.contains)
            }
        }
        result.ranking = rankedQueue.prefix(60).compactMap { id in
            guard let entry = result.lookup[.song]?[id] else { return nil }
            return CarPlayHomeItem(id: entry.id, title: entry.title, subtitle: entry.subtitle,
                artwork: entry.artwork, target: .song(entry.id, queue: rankedQueue))
        }
        return result
    }
}

// MARK: - 歌曲模型不在内存里时(C2)

extension CarPlayEditorCatalog {
    /// 「为你推荐」最近算好的那一批:哪一天、本机挑的先后、每首在首页的那一项。模型不在内存里时首页按它与此刻的
    /// 智能排序重排(同 `project` 的排法);换了一天就要重算(要整库打分,目录答不了,见 `holdForYou`)。
    struct ForYouCarry {
        let day: Int
        let localIDs: [String]
        let itemsByID: [String: CarPlayHomeItem]

        init(day: Int, snapshot: Snapshot) {
            self.day = day
            localIDs = snapshot.forYouLocalIDs
            itemsByID = Dictionary(snapshot.forYou.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        init(day: Int, songs: [Song], names: ArtistNameConfiguration) {
            self.day = day
            localIDs = songs.map(\.id)
            itemsByID = Dictionary(songs.map { ($0.id, CarPlayHomeCatalog.songItem($0, names: names, queue: [])) },
                               uniquingKeysWith: { first, _ in first })
        }

        /// 智能排序里本机也挑了的在前,再接本机的先后;每一项的队列是排好的整份(同 `project`)。
        func items(intelligentOrder: [String]) -> [CarPlayHomeItem] {
            let candidates = Set(localIDs)
            var seen = Set<String>()
            let queue = (intelligentOrder.filter(candidates.contains) + localIDs).filter { seen.insert($0).inserted }
            return queue.compactMap { id in
                itemsByID[id].map { CarPlayHomeItem(id: $0.id, title: $0.title, subtitle: $0.subtitle, artwork: $0.artwork,
                                                target: .song($0.id, queue: queue)) }
            }
        }
    }

    /// 首页还没有从目录答过、模型也不在内存里:车机摆一行「正在准备」,不拿空首页当「没有内容」。
    /// 车机这时要首页(连上、可用之后第一次建根模板)就催一次:这次启动没装模型时,发布前那次投影的输入是空的,
    /// 发布之后未必有它跟着的值变。版本没变时 `refresh` 什么都不做。
    var waitsForTheCatalog: Bool {
        let library = AppServices.shared.musicLibrary
        guard !library.isReady, !answered else { return false }
        if observing { Task { @MainActor [weak self] in self?.refresh() } }
        return true
    }

    static func day(of date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSinceReferenceDate)
    }

    /// 模型不在内存里时首页还要跟着变的那几样:目录能不能读、修订号、喜欢的账本、布局里要取的内容、「为你推荐」那一批。
    private func catalogVersion(_ library: MusicLibrary) -> String {
        let revisions = library.catalogHost?.revisions
        let request = CarPlayHomeCatalog.request(for: CarPlaySettingsStore.shared.configuration, listLimit: CarPlayHomeCatalog.listLimit)
        return ":catalog:\(library.isUsable):\(revisions?.isReadable == true):\(revisions?.songs ?? 0):\(revisions?.membership ?? 0)"
            + ":\(revisions?.albums ?? 0):\(revisions?.everything ?? 0):\(LibraryFavoritesStore.shared.revision)"
            + ":\(request.albumLimit):\(request.wantsRecentlyAdded):\(request.wantsRanking)"
            + ":\(request.customSongIDs.joined(separator: ",")):\(request.customAlbumIDs.joined(separator: ","))"
            + ":\(forYouCarry.map { "\($0.day)/\($0.localIDs.joined(separator: ","))" } ?? "-")"
    }

    /// 首页从目录取(`CarPlayHomeCatalog`),在主线程外;答不出时留着上一份、不记版本,目录再动时重来。
    private func refreshFromTheCatalog(
        _ library: MusicLibrary, wanted: Set<CarPlayLayoutBlockKind>, now: Date, intelligentOrder: [String],
        recentSongs: [Song], intents: [CarPlayHomeItem], sourceVersion: String
    ) {
        var forYou: [CarPlayHomeItem] = []
        if wanted.contains(.forYou) {
            let day = Self.day(of: now)
            if let carry = forYouCarry, carry.day == day {
                forYou = carry.items(intelligentOrder: intelligentOrder)
            } else {
                holdForYou(library, day: day)
            }
        }
        guard !catalogRefreshRunning else {
            catalogRefreshPending = true
            return
        }
        let request = Self.catalogRequest(library, configuration: CarPlaySettingsStore.shared.configuration,
                                          recentSongs: recentSongs, intents: intents, forYou: forYou)
        task?.cancel()
        generation &+= 1
        let expected = generation
        isLoading = revision == 0
        catalogRefreshRunning = true
        catalogRefreshPending = false
        task = Task { [weak self] in
            defer {
                if let self {
                    self.catalogRefreshRunning = false
                    if self.catalogRefreshPending, self.observing {
                        self.catalogRefreshPending = false
                        self.refresh()
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let result = await CarPlayHomeCatalog.shared.snapshot(request, library: library)
            guard let self, !Task.isCancelled, expected == self.generation else { return }
            self.isLoading = false
            guard let result else { return }
            self.answered = true
            self.snapshot = result
            self.cachedVersion = sourceVersion
            self.revision &+= 1
            self.projectionCount &+= 1
        }
    }

    /// 模型不在内存里时首页的输入:布局要的内容(`CarPlayHomeCatalog.request`)加上小状态 —— 歌单与成员、电台、
    /// 艺人名设置、播放历史 —— 与 `memoryInput` 里同样取法的那几样。
    static func catalogRequest(
        _ library: MusicLibrary, configuration: CarPlayLayoutConfiguration, recentSongs: [Song],
        intents: [CarPlayHomeItem], forYou: [CarPlayHomeItem]
    ) -> CarPlayHomeCatalog.Request {
        var request = CarPlayHomeCatalog.request(for: configuration, listLimit: CarPlayHomeCatalog.listLimit)
        let playlists = library.playlists
        request.playlists = playlists
        request.memberships = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, library.rawSongIDs(forPlaylist: $0.id)) })
        request.stations = AppServices.shared.radioStationsStore.stations.map {
            CarPlayHomeItem(id: $0.id, title: $0.name, subtitle: $0.playbackSubtitle, symbol: "radio", target: .radio($0.id))
        }
        request.artistNames = library.artistNameConfiguration
        request.history = PlayHistoryStore.shared.musicEntries.map(\.listeningEvent)
        request.historyCandidates = PlayHistoryStore.shared.resolvedHistoryCandidates
        request.recentlyPlayed = recentSongs
        request.listeningIntents = intents
        request.forYou = forYou
        return request
    }

    /// 这一天的「为你推荐」要整库打分,目录答不了:为它占用一次歌曲模型(`.carPlay`),按模型在内存里时同一套输入挑出
    /// 来、记下,放手;之后模型放掉了首页仍用这一批。一天至多一次;占用等不到、被取消时这一块先空着。
    private func holdForYou(_ library: MusicLibrary, day: Int) {
        guard library.isUsable, forYouHoldDay != day, forYouHoldTask == nil else { return }
        forYouHoldDay = day
        forYouHoldTask = Task { @MainActor [weak self, weak library] in
            guard let library else { return }
            let hold = await library.holdSongModel(.carPlay)
            guard !Task.isCancelled, library.isReady else {
                hold.end()
                // 没挑成(车机断开、等不到模型):这一天还可以再试。
                self?.forYouHoldTask = nil
                self?.forYouHoldDay = nil
                return
            }
            let now = Date()
            let recommendation = MusicDiscoveryEngine.RecommendationSnapshot(
                // crash-pattern: allow legacy-library-api 刚为这一下占用、模型在内存里时才读;快照握着它直到挑完
                songs: library.musicSongs, recentSongs: library.recentlyPlayedSongs(limit: 12),
                historyEntries: PlayHistoryStore.shared.musicEntries, now: now,
                libraryRevision: library.musicSongsRevision, excludedSongIDs: library.dislikedSongIDs
            )
            let names = library.artistNameConfiguration
            hold.end()
            let picked = await Task.detached(priority: .userInitiated) {
                MusicDiscoveryEngine.dailyRecommendations(from: recommendation.makeInput(), limit: 12,
                                                          isCancelled: { Task.isCancelled }).map(\.song)
            }.value
            guard let self else { return }
            self.forYouHoldTask = nil
            guard !Task.isCancelled else { return }
            // 「为你推荐」那一批在版本里,记下之后再问一次就会按它重来。
            self.forYouCarry = ForYouCarry(day: Self.day(of: now), songs: picked, names: names)
            self.refresh()
        }
    }
}

extension CarPlayHomeItem {
    func configured(id: String? = nil, directly: Bool) -> Self {
        let target: Target
        switch self.target {
        case .album(let id, _): target = .album(id, directly: directly)
        case .playlist(let id, _): target = .playlist(id, directly: directly)
        case .folder(let id, _): target = .folder(id, directly: directly)
        default: target = self.target
        }
        let browsable: Bool
        switch target { case .album, .playlist, .folder: browsable = true; default: browsable = false }
        return Self(id: id ?? self.id, title: title, subtitle: subtitle, symbol: symbol, artwork: artwork,
                    enabled: enabled || (!directly && browsable), target: target)
    }

    var layoutItem: CarPlayLayoutItem? {
        let kind: CarPlayLayoutItem.Kind
        let targetID: String
        switch target {
        case .nowPlaying: kind = .nowPlaying; targetID = "nowPlaying"
        case .song(let id, _): kind = .song; targetID = id
        case .playlist(let id, _): kind = .playlist; targetID = id
        case .album(let id, _): kind = .album; targetID = id
        case .folder(let id, _): kind = .folder; targetID = HomeFolderPinStorage.encode([id])
        case .radio(let id): kind = .radio; targetID = id
        case .listeningIntent, .unavailable: return nil
        }
        return CarPlayLayoutItem(id: id, kind: kind, targetID: targetID, title: title)
    }
}
#endif
