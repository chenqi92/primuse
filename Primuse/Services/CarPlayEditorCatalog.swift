#if os(iOS)
import Foundation
import Observation
import PrimuseKit

/// Source projection has its own lifetime; layout edits never invalidate it.
@MainActor @Observable
final class CarPlayEditorCatalog {
    static let shared = CarPlayEditorCatalog()
    struct Snapshot: Sendable {
        var entries: [CarPlayLayoutItem.Kind: [CarPlayHomeItem]] = [:]
        var lookup: [CarPlayLayoutItem.Kind: [String: CarPlayHomeItem]] = [:]
        var recent: [CarPlayHomeItem] = []
        var ranking: [CarPlayHomeItem] = []
        var memberships: [String: [String]] = [:]
        var albumSongs: [String: [String]] = [:]
        var artists: [Artist] = []
        var artistSongs: [String: [String]] = [:]
        var searchItems: [CarPlayLayoutItem.Kind: [CarPlayLayoutItem]] = [:]

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
            configuration.blocks.map { block in
                var items: [CarPlayHomeItem]
                if block.usesCustomContent || block.kind == .custom {
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
                    case .shortcuts:
                        items = nowPlaying.map { [$0] } ?? []
                        let pinned = [MusicLibrary.likedSongsPlaylistID] + configuration.pinnedPlaylistIDs.filter { $0 != MusicLibrary.likedSongsPlaylistID }
                        items += pinned.compactMap { lookup[.playlist]?[$0] }
                        items += configuration.folderIDs.compactMap { folders?.node(withID: $0).map(Self.folder) }
                    case .playlists: items = Array((entries[.playlist] ?? []).prefix(block.itemLimit))
                    case .albums: items = Array((entries[.album] ?? []).prefix(block.itemLimit))
                    case .recentlyAdded: items = Array(recent.prefix(block.itemLimit))
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
        var artists: [Artist] = []
        /// Kept out of "recently added": one scanned-in audiobook would fill
        /// the whole block with its chapters.
        var spokenWordSongIDs: Set<String> = []
    }

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
        let radioVersion = AppServices.shared.radioStationsStore.stations.map { $0.id + $0.name + $0.playbackSubtitle }.joined(separator: "|")
        let version = "\(library.visibleSongCollectionRevision):\(library.searchRevision):\(library.playlistCollectionRevision):\(PlayHistoryStore.shared.revision):\(radioVersion)"
        guard version != cachedVersion else { return }
        let playlists = library.playlists
        let input = Input(songs: library.visibleSongs, albums: library.visibleAlbums,
            playlists: playlists, memberships: Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, library.rawSongIDs(forPlaylist: $0.id)) }),
            stations: AppServices.shared.radioStationsStore.stations.map {
                CarPlayHomeItem(id: $0.id, title: $0.name, subtitle: $0.playbackSubtitle, symbol: "radio", target: .radio($0.id))
            }, artistNames: library.artistNameConfiguration, history: PlayHistoryStore.shared.musicEntries.map(\.listeningEvent), artists: library.visibleArtists,
            spokenWordSongIDs: library.spokenWordSongIDs)
        load(input, sourceVersion: version)
    }

    func load(_ input: Input, sourceVersion: String? = nil) {
        task?.cancel()
        generation &+= 1
        let expected = generation
        isLoading = revision == 0
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { Self.project(input) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, expected == self.generation else { return }
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
        let recent = input.songs.filter { !input.spokenWordSongIDs.contains($0.id) }.sorted { $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded > $1.dateAdded }.prefix(100)
        let queue = recent.map(\.id)
        result.recent = recent.map {
            CarPlayHomeItem(id: $0.id, title: $0.title, subtitle: $0.displayArtistName(configuration: input.artistNames), artwork: .songReference(id: $0.id, coverRef: $0.coverArtFileName), target: .song($0.id, queue: queue))
        }
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
        let ranked = HomeListeningRanking.ranks(events: input.history, songs: [:], folders: nil, period: .all, category: .songs)
        let rankedQueue = ranked.compactMap { $0.songIDs.first }.filter { valid.contains($0) }
        result.ranking = rankedQueue.prefix(60).compactMap { id in
            guard let entry = result.lookup[.song]?[id] else { return nil }
            return CarPlayHomeItem(id: entry.id, title: entry.title, subtitle: entry.subtitle,
                artwork: entry.artwork, target: .song(entry.id, queue: rankedQueue))
        }
        return result
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
        case .unavailable: return nil
        }
        return CarPlayLayoutItem(id: id, kind: kind, targetID: targetID, title: title)
    }
}
#endif
