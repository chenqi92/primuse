#if os(iOS)
import Foundation
import Observation
import PrimuseKit

@MainActor
final class HomeHeroRecommendationCatalog {
    let albums = HomeHeroRecommendationModel()
    private let collections = Dictionary(uniqueKeysWithValues: HomeHeroRecommendationTheme.allCases.map {
        ($0, HomeHeroRecommendationModel(theme: $0))
    })

    func collection(_ theme: HomeHeroRecommendationTheme) -> HomeHeroRecommendationModel {
        collections[theme]!
    }
}

@MainActor
@Observable
final class HomeHeroRecommendationModel {
    struct Configuration: Equatable, Sendable {
        var content: HomeHeroRecommendationContent
        var songCount: Int
        var albumCount: Int

        init(content: HomeHeroRecommendationContent, songCount: Int, albumCount: Int) {
            self.content = content
            self.songCount = HomeHeroRecommendationPolicy.songCount(songCount)
            self.albumCount = HomeHeroRecommendationPolicy.albumCount(albumCount)
        }
    }

    private struct Snapshot: Codable {
        let day: Int
        let round: Int
        let content: String
        let count: Int
        let songIDs: [String]
        let albumIDs: [String]
        let providerName: String?
        let usesAI: Bool
        let routingSignature: String
    }

    let theme: HomeHeroRecommendationTheme
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var providerName: String?
    private(set) var isLoading = false
    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recommendationLoader: ((AIRecommendationRequest) async -> AIRecommendationOutcome)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedSettingsRevision: UInt64?
    @ObservationIgnored private var loadedRegionRevision: UInt64?
    private static let cacheKey = "primuse.home.heroRecommendations.v2"

    init(
        theme: HomeHeroRecommendationTheme = .daily,
        defaults: UserDefaults = .standard,
        recommendationLoader: ((AIRecommendationRequest) async -> AIRecommendationOutcome)? = nil
    ) {
        self.theme = theme
        self.defaults = defaults
        self.recommendationLoader = recommendationLoader
    }

    func refresh(
        configuration: Configuration,
        library: MusicLibrary,
        intelligence: MusicIntelligenceService,
        force: Bool = false,
        now: Date = Date()
    ) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let operation = generation
        let day = HomeHeroRecommendationPolicy.dayStamp(now)
        let key = Self.cacheKey + "." + configuration.content.rawValue + "." + theme.rawValue
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        let count = configuration.content == .songs ? configuration.songCount : configuration.albumCount
        let settingsRevision = intelligence.settingsStore.revision
        let regionRevision = intelligence.regionAvailability.revision
        let usesAI = recommendationLoader != nil || intelligence.isPersonalizedRecommendationsConfigured
        let routingSignature = "\(intelligence.settingsStore.primuseRelayEnabled)#" + intelligence.settingsStore.providerSet
            .routedProviders(for: .recommendations).map { "\($0.id):\($0.generationModel)" }.joined(separator: "|")
        let settingsChanged = loadedSettingsRevision.map { $0 != settingsRevision } ?? false
        let regionChanged = loadedRegionRevision.map { $0 != regionRevision } ?? false
        let disliked = library.dislikedSongIDs
        if !force, !settingsChanged, !regionChanged, let saved,
           saved.day == day, saved.count == count,
           saved.usesAI == usesAI, saved.routingSignature == routingSignature {
            let restoredSongs = saved.songIDs.compactMap { library.unobservedVisibleSong(id: $0) }
                .filter { $0.isPlayable && !SpokenWordStore.shared.isSpokenWord($0) && !disliked.contains($0.id) }
            let restoredAlbums = saved.albumIDs.compactMap { library.visibleAlbum(id: $0) }
            if restoredSongs.count == saved.songIDs.count,
               restoredAlbums.count == saved.albumIDs.count, !restoredSongs.isEmpty,
               configuration.content == .songs || !restoredAlbums.isEmpty || library.visibleAlbums.isEmpty {
                songs = restoredSongs
                albums = restoredAlbums
                providerName = saved.providerName
                isLoading = false
                loadedSettingsRevision = settingsRevision
                loadedRegionRevision = regionRevision
                return
            }
        }

        isLoading = true
        defer { if operation == generation { isLoading = false } }
        let round = force && saved?.day == day ? (saved?.round ?? 0) + 1 : 0
        let snapshot = MusicDiscoveryEngine.recommendationSnapshot(in: library, now: now)
        let previousSongs = Set(saved?.songIDs ?? [])
        let previousAlbums = Set(saved?.albumIDs ?? [])
        let theme = self.theme
        let worker = Task.detached(priority: .utility) {
            let input = snapshot.makeInput()
            let ranked = MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 200, isCancelled: { Task.isCancelled })
            var pool = ranked.map(\.song)
            if theme != .daily || pool.count < AIRecommendationRequest.maximumCandidates {
                var seen = Set(pool.map(\.id))
                for song in input.songs where song.isPlayable && !input.excludedSongIDs.contains(song.id) {
                    if theme != .daily, (song.year ?? 0) <= 0 { continue }
                    if seen.insert(song.id).inserted { pool.append(song) }
                    if theme == .daily, pool.count >= 200 { break }
                }
            }
            pool = theme.candidatePool(from: pool, minimumCount: configuration.songCount)
            let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let freshCount = pool.filter { !previousSongs.contains($0.id) }.count
            let ids = HomeHeroRecommendationPolicy.candidates(
                rankedIDs: pool.map(\.id), day: day + theme.rotationOffset, round: round,
                excluding: previousSongs,
                limit: min(AIRecommendationRequest.maximumCandidates, max(configuration.songCount, freshCount))
            )
            return ids.compactMap { byID[$0] }
        }
        let candidates = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard operation == generation, !Task.isCancelled else { return }
        var seenAlbums = Set<String>()
        let availableAlbums = candidates.compactMap { song -> Album? in
            guard let id = song.albumID, seenAlbums.insert(id).inserted else { return nil }
            return library.visibleAlbum(id: id)
        }
        let albumIDs = HomeHeroRecommendationPolicy.candidates(
            rankedIDs: availableAlbums.map(\.id), day: day, round: round,
            excluding: previousAlbums,
            limit: min(AIRecommendationRequest.maximumAlbumCandidates,
                       max(configuration.albumCount, availableAlbums.filter { !previousAlbums.contains($0.id) }.count))
        )
        let albumByID = Dictionary(availableAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        songs = Array(candidates.prefix(configuration.songCount))
        albums = configuration.content == .albums ? Array(albumIDs.prefix(configuration.albumCount)).compactMap { albumByID[$0] } : []
        providerName = nil
        var selectedSongs: [String] = []
        var selectedAlbums: [String] = []
        var source: String?

        // The provider's per-request limits stay intact; larger collections are
        // assembled from disjoint pages through the existing authorized router.
        if usesAI {
            var remaining = candidates
            let unit: AIRecommendationUnit = configuration.content == .albums ? .albums : .songs
            let albumCandidates = albumIDs.compactMap { id -> AIRecommendationAlbumCandidate? in
                guard let album = albumByID[id] else { return nil }
                let tracks = library.songs(forAlbum: id).filteredPlayable()
                return AIRecommendationAlbumCandidate(
                    albumKey: id, title: album.title, artist: album.artistName ?? "", genre: album.genre,
                    year: album.year, trackCount: tracks.count,
                    durationSeconds: Int(min(360_000, tracks.reduce(0) { $0 + ($1.duration.isFinite ? max(0, $1.duration) : 0) }))
                )
            }
            var remainingAlbums = albumCandidates
            for _ in 0..<5 {
                let needed = count - (configuration.content == .songs ? selectedSongs.count : selectedAlbums.count)
                guard needed > 0, !remaining.isEmpty,
                      var request = AIRecommendationContextBuilder.request(
                        scene: .automatic, intent: theme.intent, candidates: remaining,
                        maximumResults: min(needed, AIRecommendationRequest.maximumSongSelections),
                        minimumResults: min(needed, 10), candidateLimit: AIRecommendationRequest.maximumCandidates,
                        unit: unit, albumCandidates: remainingAlbums, followsTimeOfDay: false
                      ) else { break }
                if configuration.content == .albums {
                    request.maximumAlbumResults = min(needed, AIRecommendationRequest.maximumAlbumSelections, remainingAlbums.count)
                }
                let outcome: AIRecommendationOutcome
                if let recommendationLoader {
                    outcome = await recommendationLoader(request)
                } else {
                    outcome = await intelligence.recommendationOutcome(for: request, forceRefresh: true)
                }
                guard operation == generation, !Task.isCancelled else { return }
                guard case .success(let execution) = outcome else { break }
                let newSongs = execution.plan.songSelections.map(\.songID).filter { id in remaining.contains { $0.id == id } }
                let newAlbums = execution.plan.albumSelections.compactMap(\.albumKey).filter { id in remainingAlbums.contains { $0.albumKey == id } }
                guard configuration.content == .songs ? !newSongs.isEmpty : !newAlbums.isEmpty else { break }
                source = execution.providerName
                selectedSongs += newSongs
                selectedAlbums += newAlbums
                let pickedSongs = Set(selectedSongs)
                let pickedAlbums = Set(selectedAlbums)
                remaining.removeAll { pickedSongs.contains($0.id) }
                remainingAlbums.removeAll { pickedAlbums.contains($0.albumKey) }
                if configuration.content == .albums, remainingAlbums.isEmpty { break }
            }
        }
        guard operation == generation, !Task.isCancelled else { return }
        let songIDs = HomeHeroRecommendationPolicy.merged(preferred: selectedSongs, fallback: candidates.map(\.id), limit: configuration.songCount)
        let chosenAlbumIDs = configuration.content == .albums
            ? HomeHeroRecommendationPolicy.merged(preferred: selectedAlbums, fallback: albumIDs, limit: configuration.albumCount) : []
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        songs = songIDs.compactMap { byID[$0] }
        albums = chosenAlbumIDs.compactMap { albumByID[$0] }
        providerName = source
        loadedSettingsRevision = settingsRevision
        loadedRegionRevision = regionRevision
        revision &+= 1
        let result = Snapshot(day: day, round: round, content: configuration.content.rawValue, count: count,
                              songIDs: songIDs, albumIDs: chosenAlbumIDs, providerName: source,
                              usesAI: usesAI, routingSignature: routingSignature)
        if !songs.isEmpty, let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: key) }
    }
}
#endif
