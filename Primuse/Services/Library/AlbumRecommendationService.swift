import Foundation
import PrimuseKit

/// The album for the moment, shared by the iPhone/iPad home card, the Mac home
/// hero and the Apple TV home hero.
///
/// Everything that walks the library runs off the main actor: the candidate
/// index (whole albums, one pass over the music songs) is rebuilt at most every
/// five minutes while the library changes, and the picks themselves are
/// recomputed only when the moment changes (morning → commute → …), the index
/// was rebuilt, or a pick was dismissed — so the card holds still while you
/// listen and moves on with the day. "Another one" steps through the
/// alternates of the same moment; "don't recommend" is kept on this device.
@MainActor
@Observable
final class AlbumRecommendationService {
    static let shared = AlbumRecommendationService()

    /// Album IDs never to recommend again. Local to this device, not synced.
    nonisolated static let dismissedKey = "primuse.albumPick.dismissed.v1"
    /// "Another one": which alternate is showing, for which moment.
    nonisolated static let selectionKey = "primuse.albumPick.selection.v1"
    nonisolated static let dismissedLimit = 500
    /// The home section's switch (iPhone/iPad home editor, Mac settings).
    nonisolated static let homeVisibilityKey = "primuse.home.showAlbumPick"
    /// Whole albums ranked after the moment's picks, for the album cards at
    /// the head of "For You" (and the candidates an AI service reranks).
    nonisolated static let forYouAlbumCount = 12

    private(set) var recommendations: AlbumRecommendationSet?
    /// Ranked right after `picks`, so the two never show the same album.
    private(set) var forYouAlbums: [AlbumRecommendation] = []
    private(set) var selectedIndex = 0
    /// Bumped whenever a refresh lands, for views that key work on it.
    private(set) var revision = 0

    var picks: [AlbumRecommendation] { recommendations?.picks ?? [] }

    var currentPick: AlbumRecommendation? {
        let picks = picks
        guard !picks.isEmpty else { return nil }
        return picks[min(max(0, selectedIndex), picks.count - 1)]
    }

    var moment: ListeningMoment? { recommendations?.moment }
    var canShowAnother: Bool { picks.count > 1 }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var index: AlbumCandidateIndex?
    @ObservationIgnored private var indexBuiltAt: Date?
    /// Track-ordered song IDs of every pick, resolved with the picks.
    @ObservationIgnored private var trackOrder: [String: [String]] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var forcePicksOnNextRefresh = false
    @ObservationIgnored private var momentTimer: Task<Void, Never>?
    @ObservationIgnored private weak var library: MusicLibrary?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Chinese festivals only for listeners who would expect them.
    nonisolated static var observesLunarFestivals: Bool {
        let locale = Locale.current
        if locale.language.languageCode?.identifier == "zh" { return true }
        let region = locale.region?.identifier ?? ""
        return ["CN", "HK", "MO", "TW", "SG", "MY"].contains(region)
    }

    // MARK: Refreshing

    /// Cheap to call on every appearance and library change: it coalesces,
    /// reuses the index for five minutes, and only re-picks when needed.
    func refresh(library: MusicLibrary, now currentDate: Date = Date()) {
        self.library = library
        #if DEBUG
        // Screenshot hook: pick for another moment, e.g. PRIMUSE_DEBUG_ALBUM_PICK_AT=2026-10-05T08:10:00+08:00.
        let pinned = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_ALBUM_PICK_AT"]
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        let now = pinned ?? currentDate
        let followsClock = pinned == nil
        #else
        let now = currentDate
        let followsClock = true
        #endif
        guard library.isReady else { return }
        if refreshTask != nil {
            refreshPending = true
            return
        }
        let moment = ListeningMoment.resolve(
            at: now,
            calendar: ListeningCalendar.current,
            observesLunarFestivals: Self.observesLunarFestivals
        )
        if followsClock { scheduleMomentChange(at: moment.validUntil) }

        let generation = library.musicSongsRevision
        let indexIsStale = index.map { index in
            guard index.libraryGeneration != generation else { return false }
            // The library moved on: rebuild, but not more often than the
            // other whole-library derivations while a scan keeps it moving.
            return index.candidates.isEmpty
                || now.timeIntervalSince(indexBuiltAt ?? .distantPast) >= ListeningIntentEngine.refreshInterval
        } ?? true
        let picksAreStale = forcePicksOnNextRefresh
            || recommendations == nil
            || recommendations?.moment != moment
            || indexIsStale
            || picks.contains { library.visibleAlbum(id: $0.albumID) == nil }
        guard picksAreStale else { return }
        forcePicksOnNextRefresh = false

        // Everything below is captured on the main actor and walked in the worker.
        let songs = library.musicSongs
        let lookup = library.visibleSongLookup()
        let history = PlayHistoryStore.shared.musicEntries
        let favorites = LibraryFavoritesStore.shared
        let likedAlbumIDs = favorites.hasLikedAlbums
            ? Set(favorites.likedAlbums(in: library.visibleAlbums).map(\.id))
            : []
        let likedArtistKeys = favorites.hasLikedArtists
            ? Set(favorites.likedArtists(in: library.visibleArtists).map { ListeningTextKey.folded($0.name) })
            : []
        let dismissed = dismissedAlbumIDs
        let reusableIndex = indexIsStale ? nil : index
        let startedAt = ProcessInfo.processInfo.systemUptime

        refreshTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) { () -> (AlbumCandidateIndex, AlbumRecommendationSet, [AlbumRecommendation], [String: [String]])? in
                guard let index = reusableIndex ?? AlbumCandidateIndex.build(
                    librarySongs: songs,
                    libraryGeneration: generation,
                    isCancelled: { Task.isCancelled }
                ) else { return nil }
                let events = history.map { entry in
                    AlbumListeningEvent(
                        songID: entry.songID,
                        albumID: lookup.song(id: entry.songID)?.albumID,
                        artistName: entry.artistName,
                        playedAt: entry.playedAt
                    )
                }
                // One ranked list: its head is exactly `recommend`'s picks,
                // the rest feeds the album cards in "For You".
                let ranked = AlbumRecommender.rankedCandidates(
                    index: index,
                    context: AlbumRecommendationContext(
                        moment: moment,
                        now: now,
                        events: events,
                        likedAlbumIDs: likedAlbumIDs,
                        likedArtistKeys: likedArtistKeys,
                        dismissedAlbumIDs: dismissed
                    ),
                    limit: AlbumRecommender.pickCount + Self.forYouAlbumCount
                )
                let set = AlbumRecommendationSet(
                    moment: moment,
                    picks: Array(ranked.prefix(AlbumRecommender.pickCount))
                )
                let forYou = Array(ranked.dropFirst(AlbumRecommender.pickCount))
                guard !Task.isCancelled else { return nil }
                return (index, set, forYou, Self.trackOrder(for: ranked, in: songs))
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            self.refreshTask = nil
            if let result {
                let (index, set, forYou, order) = result
                if reusableIndex == nil {
                    self.index = index
                    self.indexBuiltAt = now
                }
                self.forYouAlbums = forYou
                self.apply(set, trackOrder: order)
                plog(String(
                    format: "🎯 album pick %@ picks=%d candidates=%d index=%@ %.0fms",
                    set.moment.seedKey,
                    set.picks.count,
                    index.candidates.count,
                    reusableIndex == nil ? "rebuilt" : "reused",
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
                ))
            }
            if self.refreshPending, let library = self.library {
                self.refreshPending = false
                self.refresh(library: library)
            }
        }
    }

    private func apply(_ set: AlbumRecommendationSet, trackOrder: [String: [String]]) {
        recommendations = set
        self.trackOrder = trackOrder
        let stored = defaults.dictionary(forKey: Self.selectionKey)
        if stored?["moment"] as? String == set.moment.seedKey,
           let index = stored?["index"] as? Int, set.picks.indices.contains(index) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
        revision &+= 1
    }

    /// Re-pick when the moment ends, even if nobody touched the library.
    private func scheduleMomentChange(at date: Date) {
        momentTimer?.cancel()
        let delay = max(1, date.timeIntervalSinceNow + 1)
        momentTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let library = self.library else { return }
            self.refresh(library: library)
        }
    }

    /// Album songs in disc/track order, for the few albums picked.
    nonisolated private static func trackOrder(
        for picks: [AlbumRecommendation],
        in songs: [Song]
    ) -> [String: [String]] {
        let wanted = Set(picks.map(\.albumID))
        guard !wanted.isEmpty else { return [:] }
        var grouped: [String: [Song]] = [:]
        for song in songs {
            guard let albumID = song.albumID, wanted.contains(albumID), song.isPlayable else { continue }
            grouped[albumID, default: []].append(song)
        }
        return grouped.mapValues { AlbumTrackOrder.sorted($0).map(\.id) }
    }

    // MARK: Actions

    /// "Another one": the next alternate for this moment, round and round.
    func showAnother() {
        let picks = picks
        guard picks.count > 1, let moment else { return }
        selectedIndex = (selectedIndex + 1) % picks.count
        defaults.set(["moment": moment.seedKey, "index": selectedIndex], forKey: Self.selectionKey)
    }

    /// "Don't recommend this album": never again on this device.
    func dismiss(albumID: String) {
        var dismissed = Array(dismissedAlbumIDsInOrder.filter { $0 != albumID })
        dismissed.append(albumID)
        if dismissed.count > Self.dismissedLimit { dismissed.removeFirst(dismissed.count - Self.dismissedLimit) }
        defaults.set(dismissed, forKey: Self.dismissedKey)
        if let set = recommendations {
            let remaining = set.picks.filter { $0.albumID != albumID }
            recommendations = AlbumRecommendationSet(moment: set.moment, picks: remaining)
            selectedIndex = remaining.isEmpty ? 0 : min(selectedIndex, remaining.count - 1)
            revision &+= 1
        }
        forYouAlbums.removeAll { $0.albumID == albumID }
        forcePicksOnNextRefresh = true
        if let library { refresh(library: library) }
    }

    var dismissedAlbumIDs: Set<String> { Set(dismissedAlbumIDsInOrder) }

    /// Album cards for the head of "For You": the albums ranked after the
    /// moment's picks. A small library that runs out there borrows the
    /// moment's alternates — never the one the album card is showing now.
    func forYouAlbumCandidates(excludingCurrentPick: Bool) -> [AlbumRecommendation] {
        guard forYouAlbums.isEmpty else { return forYouAlbums }
        let current = excludingCurrentPick ? currentPick?.albumID : nil
        return picks.filter { $0.albumID != current }
    }

    private var dismissedAlbumIDsInOrder: [String] {
        defaults.stringArray(forKey: Self.dismissedKey) ?? []
    }

    /// The album's songs in disc and track order, ready to play. Resolved
    /// with the picks; another album falls back to the library's own lookup.
    func songsInTrackOrder(albumID: String, library: MusicLibrary) -> [Song] {
        if let ids = trackOrder[albumID] {
            let songs = ids.compactMap { library.unobservedVisibleSong(id: $0) }
            if !songs.isEmpty { return songs }
        }
        return library.songs(forAlbum: albumID).filteredPlayable()
    }

}

// MARK: - Copy

extension ListeningGenreFamily {
    /// Localization key of the family's name, e.g. `album_pick_genre_jazz`.
    var nameKey: String { "album_pick_genre_" + rawValue }
}

extension AlbumRecommendationReason {
    /// One line of copy under the album.
    var text: String {
        switch self {
        case .holiday:
            return String(localized: "album_pick_reason_holiday")
        case .likedAlbum:
            return String(localized: "album_pick_reason_liked_album")
        case .artistPlayedThisWeek(let artist, let count):
            return String(format: String(localized: "album_pick_reason_artist_week %@ %lld"), artist, count)
        case .recentVibe(let family):
            return String(
                format: String(localized: "album_pick_reason_recent_vibe %@"),
                String(localized: String.LocalizationValue(family.nameKey))
            )
        case .likedArtist(let artist):
            return String(format: String(localized: "album_pick_reason_liked_artist %@"), artist)
        case .addedNotHeard(let weeks):
            guard weeks > 0 else { return String(localized: "album_pick_reason_added_recently") }
            return String(format: String(localized: "album_pick_reason_added_weeks %lld"), weeks)
        case .artistPlayedRecently(let artist, let count):
            return String(format: String(localized: "album_pick_reason_artist_recent %@ %lld"), artist, count)
        case .notHeardInAWhile:
            return String(localized: "album_pick_reason_not_heard")
        case .fitsMoment(let situation):
            return String(localized: String.LocalizationValue("album_pick_reason_fits_" + situation.rawValue))
        case .libraryPick:
            return String(localized: "album_pick_reason_library")
        }
    }
}

extension ListeningMoment {
    /// The section title: "Tonight", "On your commute", "Weekend afternoon"…
    var title: String { String(localized: String.LocalizationValue(titleKey)) }
}

extension AlbumRecommendation {
    /// 交给智能服务重排的整张专辑候选;流派取曲库里这张专辑自己的。
    func intelligenceCandidate(genre: String?) -> AIRecommendationAlbumCandidate {
        let duration = totalDuration.isFinite ? max(0, totalDuration) : 0
        return AIRecommendationAlbumCandidate(
            albumKey: albumID,
            title: title,
            artist: artistName,
            genre: genre,
            year: year,
            trackCount: trackCount,
            durationSeconds: Int(min(duration, 360_000).rounded())
        )
    }

    /// "2001 · 12 songs · 48 min"
    var detailLine: String {
        var parts: [String] = []
        if let year, year > 0 { parts.append(String(year)) }
        parts.append(String(format: String(localized: "album_pick_tracks %lld"), trackCount))
        let minutes = Int((totalDuration / 60).rounded())
        if minutes > 0 { parts.append(String(format: String(localized: "album_pick_minutes %lld"), minutes)) }
        return parts.joined(separator: " · ")
    }
}
