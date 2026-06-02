import Foundation
import PrimuseKit
import CryptoKit

enum LibrarySearchMatchKind: Sendable {
    case metadata
    case lyrics
    case fuzzy
}

struct LibrarySearchResult: Identifiable, Sendable {
    let song: Song
    let matchKind: LibrarySearchMatchKind
    let score: Int
    let lyricSnippet: String?
    let lyricTimestamp: TimeInterval?

    var id: String { song.id }
}

private struct LibrarySearchMatcher {
    let rawQuery: String
    let normalizedQuery: String

    var isValid: Bool { !normalizedQuery.isEmpty }
    var normalizedLength: Int { normalizedQuery.count }

    init(query: String) {
        rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedQuery = Self.normalized(rawQuery)
    }

    func score(candidate: String) -> (score: Int, kind: LibrarySearchMatchKind)? {
        guard !candidate.isEmpty else { return nil }

        if candidate.localizedCaseInsensitiveContains(rawQuery) {
            return (120, .metadata)
        }

        let normalizedCandidate = Self.normalized(candidate)
        guard !normalizedCandidate.isEmpty else { return nil }

        if normalizedCandidate.contains(normalizedQuery) {
            return (110, .metadata)
        }

        let initials = Self.initials(candidate)
        if !initials.isEmpty, initials.contains(normalizedQuery) {
            return (100, .metadata)
        }

        if normalizedQuery.count >= 3,
           Self.isSubsequence(normalizedQuery, of: normalizedCandidate) {
            return (55, .fuzzy)
        }

        return nil
    }

    func lyricsMatch(in lines: [LyricLine], contextLines: Int = 1) -> (snippet: String, timestamp: TimeInterval)? {
        let indexedLines = lines
            .enumerated()
            .map { (offset: $0.offset, line: $0.element, text: $0.element.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !indexedLines.isEmpty else { return nil }

        let matchPosition = indexedLines.firstIndex { item in
            item.text.localizedCaseInsensitiveContains(rawQuery)
                || Self.normalized(item.text).contains(normalizedQuery)
        }

        guard let matchPosition else { return nil }
        let lowerBound = max(0, matchPosition - contextLines)
        let upperBound = min(indexedLines.count - 1, matchPosition + contextLines)
        var snippetLines = Array(indexedLines[lowerBound...upperBound].map(\.text))
        if lowerBound > 0 { snippetLines[0] = "..." + snippetLines[0] }
        if upperBound < indexedLines.count - 1 {
            snippetLines[snippetLines.count - 1] += "..."
        }
        return (snippetLines.joined(separator: "\n"), indexedLines[matchPosition].line.timestamp)
    }

    private static func normalized(_ text: String) -> String {
        let latin = text
            .applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)
            ?? text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        let allowed = CharacterSet.alphanumerics
        let scalars = latin.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func initials(_ text: String) -> String {
        let latin = text
            .applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)
            ?? text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        let allowed = CharacterSet.alphanumerics
        var result = String.UnicodeScalarView()
        var shouldTakeNext = true
        for scalar in latin.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                if shouldTakeNext {
                    result.append(scalar)
                    shouldTakeNext = false
                }
            } else {
                shouldTakeNext = true
            }
        }
        return String(result)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for char in haystack {
            if remaining.first == char {
                remaining.removeFirst()
                if remaining.isEmpty { return true }
            }
        }
        return remaining.isEmpty
    }
}

struct LibrarySearchCache: Sendable {
    var lyricsLinesByKey: [String: [LyricLine]] = [:]
    var missingLyricsKeys: Set<String> = []
}

struct LibrarySearchOutput: Sendable {
    var songResults: [LibrarySearchResult]
    var albumResults: [Album]
    var cache: LibrarySearchCache
}

enum LibrarySearchWorker {
    /// Lyrics search is intentionally held back for short queries. One- and
    /// two-character searches match too much text, and normal metadata search
    /// covers that interaction much more cheaply.
    private static let minimumLyricsQueryLength = 3

    static func compute(
        query: String,
        songs: [Song],
        albums: [Album],
        cache: LibrarySearchCache,
        includeLyrics: Bool = true,
        songLimit: Int = 120,
        albumLimit: Int = 10
    ) -> LibrarySearchOutput {
        let matcher = LibrarySearchMatcher(query: query)
        guard matcher.isValid else {
            return LibrarySearchOutput(songResults: [], albumResults: [], cache: cache)
        }

        var cache = cache
        let shouldSearchLyrics = includeLyrics && matcher.normalizedLength >= minimumLyricsQueryLength

        let rankedSongs = songs.compactMap { song -> LibrarySearchResult? in
            if Task.isCancelled { return nil }
            var bestScore = 0
            var bestKind: LibrarySearchMatchKind?
            var lyricSnippet: String?
            var lyricTimestamp: TimeInterval?

            func consider(_ candidate: String?, boost: Int) {
                guard let candidate,
                      let match = matcher.score(candidate: candidate) else { return }
                let score = match.score + boost
                if score > bestScore {
                    bestScore = score
                    bestKind = match.kind
                }
            }

            consider(song.title, boost: 30)
            consider(song.artistName, boost: 20)
            consider(song.albumTitle, boost: 14)
            consider(song.genre, boost: 6)
            consider(song.fileFormat.rawValue, boost: 2)

            if shouldSearchLyrics,
               bestScore < 90,
               let lines = searchableLyricsLines(for: song, cache: &cache),
               let match = matcher.lyricsMatch(in: lines) {
                let score = 70
                if score > bestScore {
                    bestScore = score
                    bestKind = .lyrics
                    lyricSnippet = match.snippet
                    lyricTimestamp = match.timestamp
                }
            }

            guard let bestKind else { return nil }
            return LibrarySearchResult(
                song: song,
                matchKind: bestKind,
                score: bestScore,
                lyricSnippet: lyricSnippet,
                lyricTimestamp: lyricTimestamp
            )
        }

        let songResults = Array(rankedSongs.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.song.title.localizedCaseInsensitiveCompare(rhs.song.title) == .orderedAscending
        }.prefix(songLimit))

        let albumResults = searchAlbums(query: query, albums: albums, limit: albumLimit)

        return LibrarySearchOutput(songResults: songResults, albumResults: albumResults, cache: cache)
    }

    private static func searchAlbums(query: String, albums: [Album], limit: Int) -> [Album] {
        let matcher = LibrarySearchMatcher(query: query)
        guard matcher.isValid else { return [] }
        let ranked = albums.compactMap { album -> (Album, Int)? in
            if Task.isCancelled { return nil }
            var best = 0
            if let score = matcher.score(candidate: album.title)?.score {
                best = max(best, score + 20)
            }
            if let artist = album.artistName,
               let score = matcher.score(candidate: artist)?.score {
                best = max(best, score + 10)
            }
            return best > 0 ? (album, best) : nil
        }
        return Array(ranked.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }.map(\.0).prefix(limit))
    }

    private static func searchableLyricsLines(for song: Song, cache: inout LibrarySearchCache) -> [LyricLine]? {
        let cacheKey = "\(song.id)|\(song.lyricsFileName ?? "")"
        if let cached = cache.lyricsLinesByKey[cacheKey] { return cached }
        if cache.missingLyricsKeys.contains(cacheKey) { return nil }

        guard let lines = MetadataAssetStore.shared.cachedLyricsForSearch(
            songID: song.id,
            lyricsFileName: song.lyricsFileName
        ) else {
            cache.missingLyricsKeys.insert(cacheKey)
            return nil
        }

        let searchable = lines.flatMap { line -> [LyricLine] in
            var parts = [line]
            if let background = line.background {
                parts.append(contentsOf: background)
            }
            return parts
        }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !searchable.isEmpty else {
            cache.missingLyricsKeys.insert(cacheKey)
            return nil
        }
        cache.lyricsLinesByKey[cacheKey] = searchable
        return searchable
    }
}

enum MusicDiscoveryReason: String, Sendable {
    case sameArtist
    case sameAlbum
    case sameGenre
    case sameEra
    case similarDuration
    case sameFolder
    case recentFavorite
    case notRecentlyPlayed
    case newToLibrary
    case libraryPick

    var localizationKey: String { "discovery_reason_\(rawValue)" }
}

struct MusicDiscoveryResult: Identifiable, Sendable {
    let song: Song
    let score: Double
    let reasons: [MusicDiscoveryReason]

    var id: String { song.id }
    var primaryReason: MusicDiscoveryReason { reasons.first ?? .libraryPick }
}

@MainActor
enum MusicDiscoveryEngine {
    static func similarSongs(
        to seed: Song,
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 24
    ) -> [MusicDiscoveryResult] {
        let recentIDs = Set(history.entries(in: .month).map(\.songID))
        return library.visibleSongs
            .filteredPlayable()
            .compactMap { candidate -> MusicDiscoveryResult? in
                guard candidate.id != seed.id else { return nil }
                var match = similarity(between: seed, and: candidate)
                guard match.score > 0 else { return nil }

                if !recentIDs.contains(candidate.id) {
                    match.score += 4
                    append(.notRecentlyPlayed, to: &match.reasons)
                }

                return MusicDiscoveryResult(
                    song: candidate,
                    score: match.score,
                    reasons: match.reasons
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.song.title.localizedCompare(rhs.song.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    static func recommendations(
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 12,
        now: Date = Date()
    ) -> [MusicDiscoveryResult] {
        let songs = library.visibleSongs.filteredPlayable()
        guard !songs.isEmpty else { return [] }

        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let recentWeekIDs = Set(history.entries(in: .week, now: now).map(\.songID))
        let recentMonthIDs = Set(history.entries(in: .month, now: now).map(\.songID))
        let topArtists = Set(history.topArtists(in: .month, limit: 6).map { normalized($0.title) })

        var seeds: [Song] = []
        var seedIDs = Set<String>()
        for item in history.topSongs(in: .year, limit: 12) {
            if let song = byID[item.id], seedIDs.insert(song.id).inserted {
                seeds.append(song)
            }
        }
        for song in library.recentlyPlayedSongs(limit: 12) where seedIDs.insert(song.id).inserted {
            seeds.append(song)
        }

        guard !seeds.isEmpty else {
            return coldStartRecommendations(from: songs, excluding: [], limit: limit, now: now)
        }

        var results = songs.compactMap { candidate -> MusicDiscoveryResult? in
            guard !recentWeekIDs.contains(candidate.id) else { return nil }

            var best = Match(score: 0, reasons: [])
            for seed in seeds where seed.id != candidate.id {
                let match = similarity(between: seed, and: candidate)
                if match.score > best.score { best = match }
            }

            var score = best.score
            var reasons = best.reasons

            if let artist = candidate.artistName, topArtists.contains(normalized(artist)) {
                score += 18
                append(.recentFavorite, to: &reasons)
            }

            if !recentMonthIDs.contains(candidate.id) {
                score += 12
                append(.notRecentlyPlayed, to: &reasons)
            }

            if now.timeIntervalSince(candidate.dateAdded) <= 30 * 24 * 60 * 60 {
                score += 8
                append(.newToLibrary, to: &reasons)
            }

            if candidate.coverArtFileName?.isEmpty == false {
                score += 3
            }

            guard score >= 16 else { return nil }
            if reasons.isEmpty { reasons = [.libraryPick] }
            return MusicDiscoveryResult(song: candidate, score: score, reasons: reasons)
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.song.dateAdded > rhs.song.dateAdded
        }

        var unique = uniqued(results).prefix(limit).map { $0 }
        if unique.count < limit {
            let excluded = Set(unique.map(\.song.id)).union(recentWeekIDs)
            unique.append(contentsOf: coldStartRecommendations(
                from: songs,
                excluding: excluded,
                limit: limit - unique.count,
                now: now
            ))
        }
        return unique
    }

    static func dailyRecommendations(
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 12,
        now: Date = Date()
    ) -> [MusicDiscoveryResult] {
        recommendations(in: library, history: history, limit: max(limit * 3, limit), now: now)
            .sorted { lhs, rhs in
                let left = lhs.score + stableDailyNoise(lhs.song.id, now: now) * 8
                let right = rhs.score + stableDailyNoise(rhs.song.id, now: now) * 8
                if left != right { return left > right }
                return lhs.song.title.localizedCompare(rhs.song.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    static func songRadio(
        from seed: Song,
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 48,
        now: Date = Date()
    ) -> [MusicDiscoveryResult] {
        guard seed.isPlayable else { return [] }

        var output = [
            MusicDiscoveryResult(song: seed, score: .greatestFiniteMagnitude, reasons: [.libraryPick])
        ]
        var usedIDs: Set<String> = [seed.id]
        var cursor = seed

        while output.count < limit {
            let similar = similarSongs(to: cursor, in: library, history: history, limit: 40)
                .filter { !usedIDs.contains($0.song.id) }
                .sorted { lhs, rhs in
                    let left = lhs.score + stableDailyNoise(lhs.song.id, now: now) * 3
                    let right = rhs.score + stableDailyNoise(rhs.song.id, now: now) * 3
                    if left != right { return left > right }
                    return lhs.song.title.localizedCompare(rhs.song.title) == .orderedAscending
                }

            if let next = similar.first {
                output.append(next)
                usedIDs.insert(next.song.id)
                cursor = next.song
                continue
            }

            guard let fallback = dailyRecommendations(in: library, history: history, limit: 24, now: now)
                .first(where: { !usedIDs.contains($0.song.id) }) else {
                break
            }
            output.append(fallback)
            usedIDs.insert(fallback.song.id)
            cursor = fallback.song
        }

        return output
    }

    private struct Match {
        var score: Double
        var reasons: [MusicDiscoveryReason]
    }

    private static func similarity(between seed: Song, and candidate: Song) -> Match {
        var score: Double = 0
        var reasons: [MusicDiscoveryReason] = []

        if nonEmptyEqual(seed.albumID, candidate.albumID)
            || nonEmptyEqual(seed.albumTitle, candidate.albumTitle) {
            score += 46
            append(.sameAlbum, to: &reasons)
        }

        if nonEmptyEqual(seed.artistID, candidate.artistID)
            || nonEmptyEqual(seed.artistName, candidate.artistName) {
            score += 40
            append(.sameArtist, to: &reasons)
        }

        if nonEmptyEqual(seed.genre, candidate.genre) {
            score += 30
            append(.sameGenre, to: &reasons)
        }

        if let seedYear = seed.year, let candidateYear = candidate.year {
            let delta = abs(seedYear - candidateYear)
            if delta <= 2 {
                score += 10
                append(.sameEra, to: &reasons)
            } else if delta <= 6 {
                score += 5
                append(.sameEra, to: &reasons)
            }
        }

        if seed.duration > 30, candidate.duration > 30 {
            let delta = abs(seed.duration - candidate.duration)
            let ratio = delta / max(seed.duration, candidate.duration)
            if ratio <= 0.12 {
                score += 7
                append(.similarDuration, to: &reasons)
            } else if ratio <= 0.22 {
                score += 3
            }
        }

        if seed.sourceID == candidate.sourceID,
           !parentFolder(seed.filePath).isEmpty,
           parentFolder(seed.filePath) == parentFolder(candidate.filePath) {
            score += 12
            append(.sameFolder, to: &reasons)
        }

        return Match(score: score, reasons: reasons)
    }

    private static func coldStartRecommendations(
        from songs: [Song],
        excluding excludedIDs: Set<String>,
        limit: Int,
        now: Date
    ) -> [MusicDiscoveryResult] {
        songs
            .filter { !excludedIDs.contains($0.id) }
            .map { song -> MusicDiscoveryResult in
                var score = song.coverArtFileName?.isEmpty == false ? 12.0 : 0.0
                score += max(0, 10 - now.timeIntervalSince(song.dateAdded) / (7 * 24 * 60 * 60))
                if song.artistName?.isEmpty == false { score += 3 }
                if song.albumTitle?.isEmpty == false { score += 3 }
                if song.genre?.isEmpty == false { score += 2 }
                score += stableNoise(song.id)

                let reason: MusicDiscoveryReason = now.timeIntervalSince(song.dateAdded) <= 30 * 24 * 60 * 60
                    ? .newToLibrary
                    : .libraryPick
                return MusicDiscoveryResult(song: song, score: score, reasons: [reason])
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.song.dateAdded > rhs.song.dateAdded
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func uniqued(_ results: [MusicDiscoveryResult]) -> [MusicDiscoveryResult] {
        var seen = Set<String>()
        var output: [MusicDiscoveryResult] = []
        for result in results where seen.insert(result.song.id).inserted {
            output.append(result)
        }
        return output
    }

    private static func nonEmptyEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = normalized(lhs)
        return !left.isEmpty && left == normalized(rhs)
    }

    private static func parentFolder(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        guard folder != "." else { return "" }
        return normalized(folder)
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func append(_ reason: MusicDiscoveryReason, to reasons: inout [MusicDiscoveryReason]) {
        if !reasons.contains(reason) { reasons.append(reason) }
    }

    private static func stableNoise(_ id: String) -> Double {
        let sum = id.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 }
        return Double(sum) / 997.0
    }

    private static func stableDailyNoise(_ id: String, now: Date) -> Double {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        let mixed = "\(id):\(day)"
        let sum = mixed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }
        return Double(sum) / 997.0
    }
}

/// Global in-memory music library shared across the app
@MainActor
@Observable
final class MusicLibrary {
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    /// Backing storage that includes soft-deleted entries. UI-facing
    /// `playlists` filters this down.
    private(set) var allPlaylists: [Playlist] = []
    /// Live (non-deleted) playlists for normal UI use.
    var playlists: [Playlist] { allPlaylists.filter { !$0.isDeleted } }
    /// Soft-deleted playlists, newest deletion first. Drives the "Recently
    /// Deleted" recovery panel.
    var recentlyDeletedPlaylists: [Playlist] {
        allPlaylists
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }
    /// 智能歌单 ── 跟普通 playlist 共用 soft-delete + snapshot 持久化模型。
    /// 只存定义 (规则 / 排序 / 上限), 不缓存匹配结果 ── 每次 query 实时算,
    /// 避免不同设备 PlayHistoryStore 不一致导致显示错位。
    private(set) var allSmartPlaylists: [SmartPlaylist] = []
    var smartPlaylists: [SmartPlaylist] { allSmartPlaylists.filter { !$0.isDeleted } }
    var recentlyDeletedSmartPlaylists: [SmartPlaylist] {
        allSmartPlaylists
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }
    private var playlistSongIDs: [String: [String]] = [:]
    private var recentPlaybackSongIDs: [String] = []
    /// Identities pulled from CloudKit that didn't resolve to a local
    /// `Song.id` at apply time — usually because the receiving device
    /// hasn't scanned the relevant cloud source yet. Persisted across
    /// launches and re-attempted whenever the songs collection mutates,
    /// so a freshly-synced device fills in playlist entries as its scan
    /// catches up. Pruned after 30 days to bound the persistent state.
    private var pendingPlaylistIdentities: [String: [PendingSongIdentity]] = [:]
    private var pendingHistoryIdentities: [PendingSongIdentity] = []
    /// 30 days. Pending identities older than this are considered
    /// permanently unresolvable (user removed the song, or the source
    /// was never re-added) and dropped on the next flush.
    private static let pendingIdentityTTL: TimeInterval = 30 * 24 * 3600

    /// Persistent record of a sync entry that couldn't be resolved to a
    /// local song yet. Retained until either (a) a song matching the
    /// identity is added to the library, or (b) `firstSeenAt` exceeds
    /// `pendingIdentityTTL`.
    struct PendingSongIdentity: Codable, Sendable, Hashable {
        var identity: SongIdentity
        var firstSeenAt: Date
    }
    /// Tombstones for songs the user has explicitly removed via the
    /// row's "delete song" action. Persisted so the next scan doesn't
    /// re-add the same path.
    ///
    /// Identity key shape: `"<accountID-or-sourceID>:<filePath>"`.
    /// Using `cloudAccountID` (when available) instead of mount UUID
    /// is critical — re-OAuth of the same Baidu account mints a new
    /// `MusicSource.id`, which would change `song.id` and bypass any
    /// tombstone keyed by that. The CloudAccount id is deterministic
    /// (sha256(provider:uid)) and survives the re-add, so tombstones
    /// stick.
    private(set) var deletedSongIdentities: Set<String> = []

    /// Plug-in to translate a `Song.sourceID` (mount UUID) into its
    /// canonical identity prefix — usually the source's `cloudAccountID`
    /// for OAuth mounts, falling back to the sourceID itself for
    /// local/NAS sources where there's no account concept.
    /// Set by `AppServices` at startup; nil-safe for tests.
    var sourceIdentityResolver: ((_ sourceID: String) -> String?)?

    private func identityKey(for song: Song) -> String {
        let prefix = sourceIdentityResolver?(song.sourceID) ?? song.sourceID
        return "\(prefix):\(song.filePath)"
    }
    private(set) var disabledSourceIDs: Set<String> = []

    /// Cached filtered views — rebuilt only when songs/disabled state change
    private(set) var visibleSongs: [Song] = []
    private(set) var visibleAlbums: [Album] = []
    private(set) var visibleArtists: [Artist] = []
    private var visibleSongByID: [String: Song] = [:]
    private(set) var searchRevision: Int = 0

    private let snapshotURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func updateDisabledSourceIDs(_ ids: Set<String>) {
        disabledSourceIDs = ids
        rebuildVisibleCache()
    }

    var songCount: Int { visibleSongs.count }
    var albumCount: Int { visibleAlbums.count }
    var artistCount: Int { visibleArtists.count }

    private func rebuildVisibleCache() {
        if disabledSourceIDs.isEmpty {
            visibleSongs = songs
            visibleAlbums = albums
            visibleArtists = artists
        } else {
            visibleSongs = songs.filter { !disabledSourceIDs.contains($0.sourceID) }
            let visibleAlbumIDs = Set(visibleSongs.compactMap(\.albumID))
            visibleAlbums = albums.filter { visibleAlbumIDs.contains($0.id) }
            let visibleArtistIDs = Set(visibleSongs.compactMap(\.artistID))
            visibleArtists = artists.filter { visibleArtistIDs.contains($0.id) }
        }
        visibleSongByID = Dictionary(
            visibleSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func invalidateSearchCaches() {
        searchRevision &+= 1
    }

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        snapshotURL = directory.appendingPathComponent("library-cache.json")
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSnapshot()

        // MetadataAssetStore 写 lyrics 缓存后会发这个通知 — 把对应 song 的
        // lyricsText 同步进库, 让 FTS5 全文歌词搜索覆盖到这首。
        //
        // 关键: 一次刮削会触发多次 cacheLyrics (主写一次 + sidecar 写一次)。
        // 500ms debounce 合并多个 songID, flush 时只更新 search 用 lyricsText,
        // 不再走 replaceSongs 的全套 album/artist/playlist pipeline。
        NotificationCenter.default.addObserver(
            forName: .primuseLyricsDidCache,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let songID = info["songID"] as? String,
                  let text = info["lyricsText"] as? String else { return }
            self.scheduleLyricsTextFlush(songID: songID, lyricsText: text)
        }
    }

    private static let pendingLyricsFlushDelay: TimeInterval = 0.5
    /// 等待写入的 (songID → 最新 lyricsText)。同一 songID 多次 schedule 后,
    /// flush 时只用最新值, 中间快照丢弃。
    private var pendingLyricsText: [String: String] = [:]
    private var pendingLyricsFlushTask: Task<Void, Never>?

    private func scheduleLyricsTextFlush(songID: String, lyricsText: String) {
        // 内容跟 library 里已有的一致就不排队 — 也避免反复 fire flush。
        if let existing = songs.first(where: { $0.id == songID })?.lyricsText,
           existing == lyricsText {
            return
        }
        pendingLyricsText[songID] = lyricsText
        pendingLyricsFlushTask?.cancel()
        pendingLyricsFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingLyricsFlushDelay))
            guard !Task.isCancelled else { return }
            self?.flushPendingLyricsText()
        }
    }

    private func flushPendingLyricsText() {
        let pending = pendingLyricsText
        pendingLyricsText.removeAll(keepingCapacity: true)
        pendingLyricsFlushTask = nil
        guard !pending.isEmpty else { return }

        updateLyricsText(pending)
    }

    /// Update only the lyrics text used by library search. This deliberately
    /// avoids `replaceSongs`: lyrics text does not affect album/artist grouping,
    /// playlist membership, player metadata, or artwork. Running the full
    /// replace pipeline here made a single scraped word-level lyric trigger
    /// needless main-actor work immediately after the lyrics UI appeared.
    func updateLyricsText(_ lyricsTextBySongID: [String: String]) {
        guard !lyricsTextBySongID.isEmpty else { return }

        var visibleIndexByID: [String: Int] = [:]
        visibleIndexByID.reserveCapacity(visibleSongs.count)
        for (index, song) in visibleSongs.enumerated() {
            visibleIndexByID[song.id] = index
        }

        var appliedIDs: [String] = []
        appliedIDs.reserveCapacity(lyricsTextBySongID.count)
        for (songID, text) in lyricsTextBySongID {
            guard let index = songs.firstIndex(where: { $0.id == songID }) else { continue }
            guard songs[index].lyricsText != text else { continue }
            songs[index].lyricsText = text
            if let visibleIndex = visibleIndexByID[songID] {
                visibleSongs[visibleIndex].lyricsText = text
            }
            appliedIDs.append(songID)
        }

        guard !appliedIDs.isEmpty else { return }
        plog("📚 updateLyricsText: requested=\(lyricsTextBySongID.count) applied=\(appliedIDs.count) librarySongs=\(songs.count)")
        invalidateSearchCaches()
        persistSnapshot()
    }

    /// Add songs from a scan result and rebuild albums/artists.
    ///
    /// `notifyRemovals` 控制是否在发现"affected source 里有歌不在 incoming 里"
    /// 时发出 `primuseSongsRemoved` 通知。完整扫描结束 (completeScan) 应当
    /// 传 true (远端真的少了一首歌, listener 应当清缓存); 中间 flush 应当
    /// 传 false ── 因为中间 flush 拿到的是部分扫描结果, 还没扫到的歌会被
    /// line 164 临时移除, 下次 flush 又补回, 这种"伪移除"不应触发缓存清理。
    func addSongs(
        _ newSongs: [Song],
        affectedSourceIDs explicitAffectedSourceIDs: Set<String>? = nil,
        notifyRemovals: Bool = true
    ) {
        // Merge semantics:
        //
        // - Drop songs from the affected sources that the new scan didn't
        //   yield (file deleted on the remote).
        // - For songs that already exist AND the incoming entry is "bare"
        //   (cloud Phase A scan: duration=0 && bitRate=nil), keep the
        //   previously-backfilled metadata. Just refresh the fields the
        //   scan is authoritative for: fileSize, lastModified, sidecar
        //   pointers when the scan found new ones.
        // - For everything else (local source rescan, full-metadata scan,
        //   or genuinely new songs), trust the incoming entry.
        //
        // The previous implementation simply wiped every song from the
        // source and re-appended — which silently undid hours of cloud
        // metadata backfill the moment the user tapped "scan" again.
        //
        // Filter out paths the user has explicitly deleted. Identity
        // key is account+path (not mount-UUID+path) — re-OAuth of the
        // same upstream account mints a new mount.id but the path is
        // unchanged, and we want the tombstone to keep working. The
        // user can reverse the tombstone via `restoreDeletedSong`.
        // 给每首新歌就近填 albumID/artistID。这样后台 rebuildIndex 不需要回头
        // mutate songs 数组, 1w+ 首库扫描时 main actor 不会被全表 ID 重赋值
        // 卡到。计算成本 = SHA256(string) × 2 per song, 1w 首约 5ms 总。
        let filteredNewSongs = newSongs
            .filter { !deletedSongIdentities.contains(identityKey(for: $0)) }
            .map { song -> Song in
                var s = song
                MusicLibrary.fillDerivedIDs(&s)
                return s
            }
        let incomingIDs = Set(filteredNewSongs.map(\.id))
        let sourceIDs = explicitAffectedSourceIDs ?? Set(filteredNewSongs.map(\.sourceID))

        let removedSongs = songs.filter { sourceIDs.contains($0.sourceID) && !incomingIDs.contains($0.id) }
        songs.removeAll { sourceIDs.contains($0.sourceID) && !incomingIDs.contains($0.id) }

        var existingIndexByID: [String: Int] = [:]
        existingIndexByID.reserveCapacity(songs.count)
        for (i, s) in songs.enumerated() { existingIndexByID[s.id] = i }

        var contentChanged: [Song] = []

        for newSong in filteredNewSongs {
            if let idx = existingIndexByID[newSong.id] {
                let existing = songs[idx]
                // Detect remote replacement: same path/ID but different
                // bytes. Conservative — only triggers when both sides
                // populate the field. Without this, the merge below
                // would silently keep the OLD artist/album/duration
                // backfilled from the previous file.
                let sizeChanged = newSong.fileSize > 0
                    && existing.fileSize > 0
                    && newSong.fileSize != existing.fileSize
                let mtimeChanged: Bool = {
                    guard let a = newSong.lastModified, let b = existing.lastModified else { return false }
                    return a != b
                }()
                // Provider revision (md5/etag/content_hash) catches
                // overwrites that don't change size and that come from
                // sources without a usable mtime — Baidu/Aliyun/Dropbox.
                let revisionChanged: Bool = {
                    guard let a = newSong.revision, let b = existing.revision else { return false }
                    return a != b
                }()
                if sizeChanged || mtimeChanged || revisionChanged {
                    songs[idx] = newSong
                    contentChanged.append(newSong)
                    continue
                }
                // "Bare incoming" matches `MetadataBackfillService.isBareSong` —
                // a Phase A scan that found no metadata. If the existing
                // entry has any metadata at all, prefer it.
                let incomingIsBare = newSong.duration == 0
                    && newSong.bitRate == nil
                    && newSong.artistID == nil
                    && newSong.albumID == nil
                    && newSong.year == nil
                    && newSong.genre == nil
                let existingHasMetadata = existing.duration > 0
                    || existing.bitRate != nil
                    || existing.artistID != nil
                    || existing.albumID != nil
                    || existing.year != nil
                    || existing.genre != nil
                if incomingIsBare && existingHasMetadata {
                    var merged = existing
                    merged.fileSize = newSong.fileSize
                    merged.lastModified = newSong.lastModified
                    // Always refresh revision — when the connector starts
                    // surfacing a fingerprint that wasn't there before
                    // (e.g. user upgraded to a build that reads md5), we
                    // want existing songs to pick it up so the next scan
                    // can detect overwrites.
                    if newSong.revision != nil { merged.revision = newSong.revision }
                    // Sidecar from a fresh scan (sibling listing) wins over
                    // backfill's embedded-art reference; if the scan didn't
                    // find any, keep what backfill stored.
                    if let cover = newSong.coverArtFileName { merged.coverArtFileName = cover }
                    if let lyrics = newSong.lyricsFileName { merged.lyricsFileName = lyrics }
                    songs[idx] = merged
                } else {
                    songs[idx] = newSong
                }
            } else {
                songs.append(newSong)
                existingIndexByID[newSong.id] = songs.count - 1
            }
        }

        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Newly-added songs may resolve identities that were stashed when
        // a CloudKit playlist/history record arrived before the local scan.
        flushPendingIdentities()
        invalidateSearchCaches()
        rebuildIndex()
        persistSnapshot()

        if !contentChanged.isEmpty {
            NotificationCenter.default.post(
                name: .primuseSongContentChanged,
                object: nil,
                userInfo: ["songs": contentChanged]
            )
        }
        if notifyRemovals && !removedSongs.isEmpty {
            NotificationCenter.default.post(
                name: .primuseSongsRemoved,
                object: nil,
                userInfo: ["songs": removedSongs]
            )
        }
    }

    /// Delete a single song and rebuild index
    @discardableResult
    func deleteSong(_ song: Song) -> Int {
        songs.removeAll { $0.id == song.id }
        // Tombstone keyed by canonical identity (account+path, not
        // mount-UUID+path) so re-adding the same Baidu account on
        // a fresh source UUID doesn't bypass it.
        deletedSongIdentities.insert(identityKey(for: song))
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSnapshot()
        postSongsRemoved([song])
        return songs.filter { $0.sourceID == song.sourceID }.count
    }

    /// Batch delete. Calling `deleteSong` in a 3000-song loop did
    /// `removeAll`/clean*/`rebuildIndex` once per song — O(N) each, so
    /// O(N×K) on the main actor, plus K Observable mutations triggering
    /// view rebuilds; on a 10K-song library with 3K duplicates the
    /// watchdog killed the app. Doing the bulk operations once amortizes
    /// the work to a single O(N) pass.
    func deleteSongs(_ songsToDelete: [Song]) {
        guard !songsToDelete.isEmpty else { return }
        let idsToDelete = Set(songsToDelete.map(\.id))
        for song in songsToDelete {
            deletedSongIdentities.insert(identityKey(for: song))
        }
        songs.removeAll { idsToDelete.contains($0.id) }
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSnapshot()
        postSongsRemoved(songsToDelete)
    }

    /// Reverse a previous `deleteSong` so the next scan can re-add the
    /// path. Caller passes the same Song object that was deleted (or
    /// any Song with the same source/path).
    func restoreDeletedSong(_ song: Song) {
        let key = identityKey(for: song)
        guard deletedSongIdentities.contains(key) else { return }
        deletedSongIdentities.remove(key)
        persistSnapshot()
    }

    private func postSongsRemoved(_ songs: [Song]) {
        guard songs.isEmpty == false else { return }
        NotificationCenter.default.post(
            name: .primuseSongsRemoved,
            object: nil,
            userInfo: ["songs": songs]
        )
    }

    /// Remove all songs for a given source
    func removeSongsForSource(_ sourceID: String) {
        songs.removeAll { $0.sourceID == sourceID }
        invalidateSearchCaches()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSnapshot()
    }

    /// Look up the current Song by its stable id. Used by row views to
    /// re-read after backfill mutates the library in place — passing the
    /// row a snapshot freezes the spinner forever even after duration is
    /// filled, because SwiftUI doesn't always re-build NavigationDestination
    /// views from their parent's latest state.
    func song(id: String) -> Song? {
        songs.first(where: { $0.id == id })
    }

    /// Backward-compatible synchronous search. Keep it metadata-only so older
    /// call sites never perform disk-backed lyrics scans on the main actor.
    /// The search tab uses `LibrarySearchWorker` in a detached task when it
    /// wants lyrics matches.
    func searchResults(query: String, limit: Int = 120) -> [LibrarySearchResult] {
        LibrarySearchWorker.compute(
            query: query,
            songs: visibleSongs,
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false,
            songLimit: limit,
            albumLimit: 0
        ).songResults
    }

    /// Backward-compatible song-only search API.
    func search(query: String) -> [Song] {
        searchResults(query: query).map(\.song)
    }

    func searchAlbums(query: String, limit: Int = 10) -> [Album] {
        LibrarySearchWorker.compute(
            query: query,
            songs: [],
            albums: visibleAlbums,
            cache: LibrarySearchCache(),
            includeLyrics: false,
            songLimit: 0,
            albumLimit: limit
        ).albumResults
    }

    func songs(forAlbum albumID: String) -> [Song] {
        visibleSongs.filter { $0.albumID == albumID }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    func songs(forArtist artistID: String) -> [Song] {
        visibleSongs.filter { $0.artistID == artistID }
    }

    func recentlyAddedAlbums(limit: Int = 10) -> [Album] {
        let albumLatestDate = Dictionary(grouping: visibleSongs) { $0.albumID ?? "" }
            .mapValues { $0.map(\.dateAdded).max() ?? .distantPast }
        return visibleAlbums
            .sorted { (albumLatestDate[$0.id] ?? .distantPast) > (albumLatestDate[$1.id] ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func playlist(id: String) -> Playlist? {
        allPlaylists.first(where: { $0.id == id })
    }

    func songs(forPlaylist playlistID: String) -> [Song] {
        (playlistSongIDs[playlistID] ?? []).compactMap { visibleSongByID[$0] }
    }

    func recentlyPlayedSongs(limit: Int = 6) -> [Song] {
        Array(recentPlaybackSongIDs.prefix(limit).compactMap { visibleSongByID[$0] })
    }

    func contains(songID: String, inPlaylist playlistID: String) -> Bool {
        playlistSongIDs[playlistID]?.contains(songID) == true
    }

    func recordPlayback(of songID: String) {
        guard songs.contains(where: { $0.id == songID }) else { return }

        recentPlaybackSongIDs.removeAll { $0 == songID }
        recentPlaybackSongIDs.insert(songID, at: 0)

        if recentPlaybackSongIDs.count > 100 {
            recentPlaybackSongIDs.removeLast(recentPlaybackSongIDs.count - 100)
        }

        persistSnapshot()
        NotificationCenter.default.post(name: .primusePlaybackHistoryDidChange, object: nil)
    }

    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        allPlaylists.append(playlist)
        playlistSongIDs[playlist.id] = []
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlist.id])
        return playlist
    }

    /// 用固定 ID 创建/取回 playlist ── 给"系统级"歌单 (Apple Music 资料库
    /// 镜像等) 用, 保证多端同步 + 重启后映射稳定, 不会重复创建。
    /// 如果对应 id 已被软删, 一并恢复 (避免用户误删后下次同步又新建一份)。
    @discardableResult
    func ensurePlaylist(id: String, name: String) -> Playlist {
        if let idx = allPlaylists.firstIndex(where: { $0.id == id }) {
            var p = allPlaylists[idx]
            var changed = false
            if p.isDeleted { p.isDeleted = false; p.deletedAt = nil; changed = true }
            if p.name != name { p.name = name; changed = true }
            if changed {
                p.updatedAt = Date()
                allPlaylists[idx] = p
                sortPlaylists()
                persistSnapshot()
                notifyPlaylistsChanged([id])
            }
            return p
        }
        let playlist = Playlist(id: id, name: name)
        allPlaylists.append(playlist)
        playlistSongIDs[playlist.id] = []
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlist.id])
        return playlist
    }

    /// 把 playlist 的歌列表整体替换 ── 给同步类场景 (Apple Music 重新拉一遍
    /// 资料库) 用, 比 add/remove 逐条调用快且语义清晰: 当前 source 的
    /// snapshot 即权威, 任何本地手动 add 进来的会被覆盖掉。
    /// 不存在的 songID 会被静默忽略 (避免 sync 比 song 写库稍晚的 race)。
    func replacePlaylistSongs(playlistID: String, songIDs: [String]) {
        guard let idx = allPlaylists.firstIndex(where: { $0.id == playlistID }) else { return }
        let validIDs = Set(songs.map(\.id))
        let kept = songIDs.filter { validIDs.contains($0) }
        playlistSongIDs[playlistID] = kept
        allPlaylists[idx].updatedAt = Date()
        allPlaylists[idx].coverArtPath = kept.first
            .flatMap { id in songs.first(where: { $0.id == id }) }?
            .coverArtFileName
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    /// Soft-delete: mark `isDeleted = true`, propagated to other devices as
    /// an update so the recycle bin converges.
    func deletePlaylist(id: String) {
        guard let index = allPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allPlaylists[index].isDeleted = true
        allPlaylists[index].deletedAt = Date()
        allPlaylists[index].updatedAt = Date()
        persistSnapshot()
        notifyPlaylistsChanged([id])
    }

    /// Restore a soft-deleted playlist (e.g. from the Recently Deleted view).
    func restorePlaylist(id: String) {
        guard let index = allPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allPlaylists[index].isDeleted = false
        allPlaylists[index].deletedAt = nil
        allPlaylists[index].updatedAt = Date()
        persistSnapshot()
        notifyPlaylistsChanged([id])
    }

    /// Permanently remove a playlist (manual purge or 30-day prune). Drops the
    /// record from CloudKit too.
    func permanentlyDeletePlaylist(id: String) {
        allPlaylists.removeAll { $0.id == id }
        playlistSongIDs[id] = nil
        persistSnapshot()
        notifyPlaylistDeleted(id)
    }

    /// Sweep playlists whose `deletedAt` is older than `threshold` and remove
    /// them for good. Called on launch with a 30-day threshold.
    func prunePlaylists(deletedBefore threshold: Date) {
        let toPrune = allPlaylists.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        guard !toPrune.isEmpty else { return }
        for playlist in toPrune {
            permanentlyDeletePlaylist(id: playlist.id)
        }
    }

    /// Permanently remove generated playlists that mirror an external source and
    /// are no longer part of that source's latest authoritative snapshot.
    func prunePlaylists(withIDPrefix prefix: String, keepingIDs: Set<String>) {
        let staleIDs = allPlaylists
            .filter { $0.id.hasPrefix(prefix) && !keepingIDs.contains($0.id) }
            .map(\.id)
        guard !staleIDs.isEmpty else { return }

        let staleIDSet = Set(staleIDs)
        allPlaylists.removeAll { staleIDSet.contains($0.id) }
        for id in staleIDs {
            playlistSongIDs[id] = nil
            pendingPlaylistIdentities[id] = nil
        }
        sortPlaylists()
        persistSnapshot()
        for id in staleIDs {
            notifyPlaylistDeleted(id)
        }
    }

    // MARK: - Smart Playlists

    /// 创建 / 更新一份智能歌单。Caller 自己构造 SmartPlaylist (含 rules), 这里
    /// 只负责存进 allSmartPlaylists 并刷新 updatedAt + 触发同步。
    func saveSmartPlaylist(_ smart: SmartPlaylist) {
        var stored = smart
        stored.updatedAt = Date()
        if let idx = allSmartPlaylists.firstIndex(where: { $0.id == smart.id }) {
            allSmartPlaylists[idx] = stored
        } else {
            allSmartPlaylists.append(stored)
        }
        sortSmartPlaylists()
        persistSnapshot()
        notifySmartPlaylistsChanged([stored.id])
    }

    /// Soft-delete: 跟 Playlist 一致, mark deleted 并保留 30 天给 CloudKit
    /// 多设备收敛时间窗。
    func deleteSmartPlaylist(id: String) {
        guard let idx = allSmartPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allSmartPlaylists[idx].isDeleted = true
        allSmartPlaylists[idx].deletedAt = Date()
        allSmartPlaylists[idx].updatedAt = Date()
        persistSnapshot()
        notifySmartPlaylistsChanged([id])
    }

    func restoreSmartPlaylist(id: String) {
        guard let idx = allSmartPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allSmartPlaylists[idx].isDeleted = false
        allSmartPlaylists[idx].deletedAt = nil
        allSmartPlaylists[idx].updatedAt = Date()
        persistSnapshot()
        notifySmartPlaylistsChanged([id])
    }

    func permanentlyDeleteSmartPlaylist(id: String) {
        allSmartPlaylists.removeAll { $0.id == id }
        persistSnapshot()
        notifySmartPlaylistDeleted(id)
    }

    func pruneSmartPlaylists(deletedBefore threshold: Date) {
        let toPrune = allSmartPlaylists.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        guard !toPrune.isEmpty else { return }
        for smart in toPrune {
            permanentlyDeleteSmartPlaylist(id: smart.id)
        }
    }

    private func sortSmartPlaylists() {
        allSmartPlaylists.sort { $0.updatedAt > $1.updatedAt }
    }

    func add(songID: String, toPlaylist playlistID: String) {
        guard songs.contains(where: { $0.id == songID }),
              let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }

        var entries = playlistSongIDs[playlistID] ?? []
        guard entries.contains(songID) == false else { return }

        entries.append(songID)
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex].updatedAt = Date()
        allPlaylists[existingIndex].coverArtPath = songs.first(where: { $0.id == entries.first })?.coverArtFileName
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    /// 「我喜欢」系统级歌单的固定 ID。NowPlayingView 的 heart 按钮直接 toggle
    /// 这个歌单, 跟 Apple Music 镜像歌单一样按 fixed ID 走 ensurePlaylist /
    /// add / remove 三件套, 多端 / 重装后稳定收敛。
    nonisolated static let likedSongsPlaylistID = "primuse.system.liked"

    /// 第一次 toggleLiked 时自动建出 Liked 歌单 ── 用户不需要去 PlaylistListView
    /// 手动创建。已存在则 ensurePlaylist 内部什么都不做。
    @discardableResult
    private func ensureLikedPlaylist() -> Playlist {
        ensurePlaylist(
            id: Self.likedSongsPlaylistID,
            name: String(localized: "playlist_liked_name")
        )
    }

    func toggleLiked(songID: String) {
        ensureLikedPlaylist()
        if isLiked(songID: songID) {
            remove(songID: songID, fromPlaylist: Self.likedSongsPlaylistID)
        } else {
            add(songID: songID, toPlaylist: Self.likedSongsPlaylistID)
        }
    }

    func isLiked(songID: String) -> Bool {
        contains(songID: songID, inPlaylist: Self.likedSongsPlaylistID)
    }

    func remove(songID: String, fromPlaylist playlistID: String) {
        guard let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }) else { return }

        var entries = playlistSongIDs[playlistID] ?? []
        entries.removeAll { $0 == songID }
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex].updatedAt = Date()
        allPlaylists[existingIndex].coverArtPath = songs.first(where: { $0.id == entries.first })?.coverArtFileName
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    // MARK: - Cloud sync hooks

    /// Raw stored song IDs for a playlist (no visibility filtering).
    func rawSongIDs(forPlaylist playlistID: String) -> [String] {
        playlistSongIDs[playlistID] ?? []
    }

    /// Snapshot of recent playback song IDs — used by CloudKit sync.
    var recentPlaybackSongIDsForSync: [String] { recentPlaybackSongIDs }

    /// Wipe playback history (in response to a remote deletion).
    func clearPlaybackHistory() {
        recentPlaybackSongIDs.removeAll()
        persistSnapshot()
    }

    /// Apply a playlist record + its song list pulled from CloudKit. Does not
    /// re-broadcast a local change notification.
    ///
    /// When `identities` is provided (records pushed from clients that
    /// understand `SongIdentity`), each entry is resolved through the 3-tier
    /// matcher: exact `songID` → `(cloudAccountID, filePath)` → fuzzy
    /// `(title, artistName?, duration ±1s)`. Entries that resolve land in
    /// the playlist; entries that don't are stashed in
    /// `pendingPlaylistIdentities` and retried on every subsequent songs
    /// mutation, so a playlist pulled before the cloud scan completes still
    /// fills in afterwards rather than dropping permanently.
    ///
    /// When `identities` is nil (legacy records from older clients), the
    /// raw `songIDs` are stored as-is — `songs(forPlaylist:)` already
    /// filters at display time.
    func applyRemotePlaylist(
        _ playlist: Playlist,
        songIDs: [String],
        identities: [SongIdentity]? = nil
    ) {
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            allPlaylists[index] = playlist
        } else {
            allPlaylists.append(playlist)
        }

        if let identities, !identities.isEmpty {
            let (resolved, unresolved) = resolveIdentitiesPartitioned(identities)
            playlistSongIDs[playlist.id] = resolved
            updatePendingPlaylistIdentities(playlistID: playlist.id, with: unresolved)
        } else {
            playlistSongIDs[playlist.id] = songIDs
        }

        sortPlaylists()
        persistSnapshot()
    }

    /// Merge a server-side playlist update into the existing local playlist.
    /// Used by CloudKit's conflict path so server-only adds aren't lost.
    /// Server identities flow through the same resolver as `applyRemotePlaylist`;
    /// IDs that resolve are unioned with the local list, IDs that don't go
    /// to pending so the next scan can backfill them.
    func mergeRemotePlaylist(
        _ playlist: Playlist,
        baseSongIDs: [String],
        additionalIdentities: [SongIdentity]
    ) {
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            allPlaylists[index] = playlist
        } else {
            allPlaylists.append(playlist)
        }

        let (resolved, unresolved) = resolveIdentitiesPartitioned(additionalIdentities)
        var seen = Set<String>()
        let merged = (baseSongIDs + resolved).filter { seen.insert($0).inserted }
        playlistSongIDs[playlist.id] = merged
        updatePendingPlaylistIdentities(playlistID: playlist.id, with: unresolved)

        sortPlaylists()
        persistSnapshot()
    }

    /// Replace the local playback history with one pulled from CloudKit.
    /// Identity resolution mirrors `applyRemotePlaylist` — unresolved
    /// entries hang in `pendingHistoryIdentities` until a matching song
    /// shows up locally.
    func applyRemotePlaybackHistory(
        songIDs: [String],
        identities: [SongIdentity]? = nil
    ) {
        if let identities, !identities.isEmpty {
            let (resolved, unresolved) = resolveIdentitiesPartitioned(identities)
            recentPlaybackSongIDs = Array(resolved.prefix(100))
            updatePendingHistoryIdentities(with: unresolved)
        } else {
            recentPlaybackSongIDs = Array(songIDs.prefix(100))
        }
        persistSnapshot()
    }

    /// Merge a server-side playback history update into the local list.
    /// Used by CloudKit's conflict path; mirrors `mergeRemotePlaylist`.
    func mergeRemotePlaybackHistory(
        baseSongIDs: [String],
        additionalIdentities: [SongIdentity]
    ) {
        let (resolved, unresolved) = resolveIdentitiesPartitioned(additionalIdentities)
        var seen = Set<String>()
        let merged = (baseSongIDs + resolved).filter { seen.insert($0).inserted }
        recentPlaybackSongIDs = Array(merged.prefix(100))
        updatePendingHistoryIdentities(with: unresolved)
        persistSnapshot()
    }

    // MARK: - Identity resolution & pending flush

    /// Walk a batch of identities through the 3-tier resolver, splitting
    /// them into "matched a local song" and "still no match" groups.
    private func resolveIdentitiesPartitioned(_ identities: [SongIdentity]) -> (resolved: [String], unresolved: [SongIdentity]) {
        var resolved: [String] = []
        var unresolved: [SongIdentity] = []
        for identity in identities {
            if let songID = resolveIdentity(identity) {
                resolved.append(songID)
            } else {
                unresolved.append(identity)
            }
        }
        return (resolved, unresolved)
    }

    private func resolveIdentity(_ identity: SongIdentity) -> String? {
        // Tier 1: exact ID — same mount on both devices, or hash collision.
        if songs.contains(where: { $0.id == identity.songID }) {
            return identity.songID
        }
        // Tier 2: cloud account + file path. `sourceIdentityResolver`
        // returns the `cloudAccountID` for OAuth-typed mounts (which is
        // SHA256(provider:accountUID) — stable across devices).
        if let acc = identity.cloudAccountID, !identity.filePath.isEmpty {
            if let song = songs.first(where: {
                sourceIdentityResolver?($0.sourceID) == acc && $0.filePath == identity.filePath
            }) {
                return song.id
            }
        }
        // Tier 3: fuzzy match — for NAS / FTP / SMB / WebDAV / local
        // sources where there's no cloud account anchor.
        if !identity.title.isEmpty {
            if let song = songs.first(where: {
                $0.title == identity.title
                && abs($0.duration - identity.duration) < 1.0
                && (identity.artistName == nil || $0.artistName == identity.artistName)
            }) {
                return song.id
            }
        }
        return nil
    }

    /// Merge a fresh batch of unresolved identities into the existing
    /// pending bucket for a playlist, preserving each identity's earliest
    /// `firstSeenAt` so the TTL clock doesn't reset on every re-apply.
    private func updatePendingPlaylistIdentities(playlistID: String, with unresolved: [SongIdentity]) {
        let existing = pendingPlaylistIdentities[playlistID] ?? []
        let merged = mergePendingIdentities(existing: existing, fresh: unresolved)
        if merged.isEmpty {
            pendingPlaylistIdentities[playlistID] = nil
        } else {
            pendingPlaylistIdentities[playlistID] = merged
        }
    }

    private func updatePendingHistoryIdentities(with unresolved: [SongIdentity]) {
        pendingHistoryIdentities = mergePendingIdentities(existing: pendingHistoryIdentities, fresh: unresolved)
    }

    private func mergePendingIdentities(
        existing: [PendingSongIdentity],
        fresh: [SongIdentity]
    ) -> [PendingSongIdentity] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.pendingIdentityTTL)
        let existingByIdentity = Dictionary(uniqueKeysWithValues: existing.map { ($0.identity, $0) })
        var result: [PendingSongIdentity] = []
        var seen = Set<SongIdentity>()
        for identity in fresh {
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            let firstSeenAt = existingByIdentity[identity]?.firstSeenAt ?? now
            guard firstSeenAt > cutoff else { continue }
            result.append(PendingSongIdentity(identity: identity, firstSeenAt: firstSeenAt))
        }
        return result
    }

    /// Re-attempt resolution for every persisted pending identity. Called
    /// after any songs-collection mutation (scan finishes, backfill
    /// applies a batch). Identities that now resolve are appended to
    /// their playlist / promoted into history; identities that have aged
    /// past `pendingIdentityTTL` are dropped.
    private func flushPendingIdentities() {
        guard !pendingPlaylistIdentities.isEmpty || !pendingHistoryIdentities.isEmpty else { return }

        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.pendingIdentityTTL)

        // Playlists: each pending entry that resolves gets appended to
        // the end of the playlist. Original ordering is unrecoverable
        // (the sync record only carries the resolved-side order), but
        // appending matches user expectation that newly-available songs
        // surface at the bottom.
        for (playlistID, pending) in pendingPlaylistIdentities {
            var stillPending: [PendingSongIdentity] = []
            var newlyResolved: [String] = []
            for entry in pending {
                if entry.firstSeenAt < cutoff { continue }
                if let songID = resolveIdentity(entry.identity) {
                    newlyResolved.append(songID)
                } else {
                    stillPending.append(entry)
                }
            }
            if !newlyResolved.isEmpty {
                var seen = Set(playlistSongIDs[playlistID] ?? [])
                let toAppend = newlyResolved.filter { seen.insert($0).inserted }
                playlistSongIDs[playlistID, default: []].append(contentsOf: toAppend)
            }
            pendingPlaylistIdentities[playlistID] = stillPending.isEmpty ? nil : stillPending
        }

        // Playback history: resolved entries prepend (most-recent-first
        // is the existing convention); cap at 100.
        var stillPendingHistory: [PendingSongIdentity] = []
        var resolvedHistory: [String] = []
        for entry in pendingHistoryIdentities {
            if entry.firstSeenAt < cutoff { continue }
            if let songID = resolveIdentity(entry.identity) {
                resolvedHistory.append(songID)
            } else {
                stillPendingHistory.append(entry)
            }
        }
        if !resolvedHistory.isEmpty {
            var seen = Set(recentPlaybackSongIDs)
            let toAdd = resolvedHistory.filter { seen.insert($0).inserted }
            recentPlaybackSongIDs.insert(contentsOf: toAdd, at: 0)
            recentPlaybackSongIDs = Array(recentPlaybackSongIDs.prefix(100))
        }
        pendingHistoryIdentities = stillPendingHistory
    }

    /// Remove a playlist in response to a remote deletion event. Does not fire
    /// the local-change notification (which would echo back to CloudKit).
    func deletePlaylistFromRemote(id: String) {
        allPlaylists.removeAll { $0.id == id }
        playlistSongIDs[id] = nil
        persistSnapshot()
    }

    private func notifyPlaylistsChanged(_ ids: [String]) {
        NotificationCenter.default.post(
            name: .primusePlaylistsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func notifyPlaylistDeleted(_ id: String) {
        NotificationCenter.default.post(
            name: .primusePlaylistDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    private func notifySmartPlaylistsChanged(_ ids: [String]) {
        NotificationCenter.default.post(
            name: .primuseSmartPlaylistsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func notifySmartPlaylistDeleted(_ id: String) {
        NotificationCenter.default.post(
            name: .primuseSmartPlaylistDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// 删除来自远端 (CloudKit) 的智能歌单。不触发 changed notification 避免
    /// 回声同步。
    func deleteSmartPlaylistFromRemote(id: String) {
        allSmartPlaylists.removeAll { $0.id == id }
        persistSnapshot()
    }

    /// 应用来自远端 (CloudKit) 的智能歌单更新。比 Playlist 简单很多 ── 没有
    /// songID 解析问题, 因为 SmartPlaylist 只存规则定义不存歌曲列表。
    func applyRemoteSmartPlaylist(_ smart: SmartPlaylist) {
        if let idx = allSmartPlaylists.firstIndex(where: { $0.id == smart.id }) {
            allSmartPlaylists[idx] = smart
        } else {
            allSmartPlaylists.append(smart)
        }
        sortSmartPlaylists()
        persistSnapshot()
    }

    /// Most recently replaced song — observable so consumers (e.g. player) can sync.
    /// Use songReplacementToken for onChange triggers (it changes on every replace, even same song).
    private(set) var lastReplacedSong: Song?
    /// IDs of every song touched in the most recent replace operation.
    /// Single-song `replaceSong` populates this with one element; batch
    /// `replaceSongs` populates the whole batch. Consumers (e.g. the
    /// player) use this to sync currentSong/queue when a backfilled
    /// song happened to NOT be the last one in a batch.
    private(set) var lastReplacedSongIDs: Set<String> = []
    private(set) var songReplacementToken = UUID()

    func replaceSong(_ updatedSong: Song) {
        guard let index = songs.firstIndex(where: { $0.id == updatedSong.id }) else { return }
        let oldCoverRef = songs[index].coverArtFileName
        var s = updatedSong
        MusicLibrary.fillDerivedIDs(&s)
        songs[index] = s
        rebuildVisibleCache()
        lastReplacedSong = s
        lastReplacedSongIDs = [s.id]
        songReplacementToken = UUID()
        if oldCoverRef != s.coverArtFileName {
            postArtworkInvalidation(songID: s.id, oldRef: oldCoverRef, newRef: s.coverArtFileName)
        }
        invalidateSearchCaches()
        rebuildIndex()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Backfill may have just filled in title/artist/duration that lets
        // a stale pending identity finally match.
        flushPendingIdentities()
        refreshPlaylistArtworkReferences()
        persistSnapshot()
    }

    /// Batch counterpart to `replaceSong`. Used by `MetadataBackfillService`
    /// to apply many metadata fills at once — running rebuildIndex /
    /// persistSnapshot once per batch instead of per song keeps the UI
    /// responsive when the backfill worker is at full speed (otherwise
    /// the artists/albums grouping is recomputed dozens of times a second).
    func replaceSongs(_ updatedSongs: [Song]) {
        guard !updatedSongs.isEmpty else { return }
        var idToIndex: [String: Int] = [:]
        idToIndex.reserveCapacity(songs.count)
        for (i, song) in songs.enumerated() { idToIndex[song.id] = i }

        var lastApplied: Song?
        var appliedIDs: Set<String> = []
        var missedIDs: [String] = []
        var artworkChanges: [(songID: String, oldRef: String?, newRef: String?)] = []
        for updated in updatedSongs {
            guard let index = idToIndex[updated.id] else {
                missedIDs.append(updated.id)
                continue
            }
            let oldCoverRef = songs[index].coverArtFileName
            var s = updated
            MusicLibrary.fillDerivedIDs(&s)
            songs[index] = s
            lastApplied = s
            appliedIDs.insert(s.id)
            if oldCoverRef != s.coverArtFileName {
                artworkChanges.append((s.id, oldCoverRef, s.coverArtFileName))
            }
        }
        plog("📚 replaceSongs: requested=\(updatedSongs.count) applied=\(appliedIDs.count) missed=\(missedIDs.count) librarySongs=\(songs.count) missedSampleID=\(missedIDs.first ?? "-") sampleLibID=\(songs.first?.id ?? "-")")
        guard let lastApplied else { return }
        rebuildVisibleCache()
        lastReplacedSong = lastApplied
        lastReplacedSongIDs = appliedIDs
        songReplacementToken = UUID()
        for change in artworkChanges {
            postArtworkInvalidation(songID: change.songID, oldRef: change.oldRef, newRef: change.newRef)
        }
        invalidateSearchCaches()
        rebuildIndex()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Batch backfill may have surfaced enough metadata for a chunk of
        // pending identities to resolve at once.
        flushPendingIdentities()
        refreshPlaylistArtworkReferences()
        persistSnapshot()
    }

    private func postArtworkInvalidation(songID: String, oldRef: String?, newRef: String?) {
        var userInfo: [AnyHashable: Any] = ["songID": songID]
        if let oldRef { userInfo["oldRef"] = oldRef }
        if let newRef { userInfo["newRef"] = newRef }
        NotificationCenter.default.post(
            name: .primuseArtworkDidInvalidate,
            object: songID,
            userInfo: userInfo
        )
    }

    // MARK: - Index Rebuild

    /// 后台重建 albums / artists 集合。songs 上的 albumID / artistID 在
    /// addSongs / replaceSong 同步路径里就近填好 (`fillDerivedIDs`), rebuildIndex
    /// 不再 mutate songs ── 它只 derive 集合, 可以扔到背景 executor 算, 算完
    /// hop 回 main actor 替换。
    ///
    /// 1w+ 首库 scale 时 main actor 几乎不阻塞: 之前 1000 次同步 rebuildIndex
    /// 累计 main thread 阻塞 ~10s, 现在 0s (后台 thread 算, main 只做数组替换)。
    ///
    /// generation 检查防止 stale 结果覆盖最新数据 ── 短时间多次 rebuildIndex
    /// 时只有最后一次的结果会 apply。
    private var rebuildIndexTask: Task<Void, Never>?
    private var rebuildIndexGeneration: Int = 0

    private func rebuildIndex() {
        rebuildIndexGeneration &+= 1
        let myGen = rebuildIndexGeneration
        let snapshot = songs

        rebuildIndexTask?.cancel()
        rebuildIndexTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MusicLibrary.computeAlbumsAndArtists(songs: snapshot)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // generation 校验: 期间又有新的 rebuildIndex 调度过, 当前结果
                // 已经 stale, 丢弃。
                guard self.rebuildIndexGeneration == myGen else { return }
                self.albums = result.albums
                self.artists = result.artists
                self.rebuildVisibleCache()
            }
        }
    }

    /// 启动 / 测试场景下需要"调用即生效"的同步重建。比异步版本贵 (会卡
    /// main actor 一下), 但只在 init / migration 等 UI 还没起来的路径用。
    private func rebuildIndexSync() {
        let result = MusicLibrary.computeAlbumsAndArtists(songs: songs)
        albums = result.albums
        artists = result.artists
        rebuildVisibleCache()
    }

    /// tvOS 下载到新快照后重新从磁盘加载整库(songs/playlists 等)。
    func reloadFromDisk() { loadSnapshot() }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            return
        }

        songs = snapshot.songs
        let repairedLegacyTextCount = repairLegacyChineseMetadataTextInSnapshot()
        allPlaylists = snapshot.playlists
        allSmartPlaylists = snapshot.smartPlaylists ?? []
        playlistSongIDs = snapshot.playlistSongIDs ?? [:]
        recentPlaybackSongIDs = snapshot.recentPlaybackSongIDs ?? []
        // Old `deletedSongIDs` field stored mount-UUID-derived song.id
        // tombstones — useless after re-OAuth changes the source UUID.
        // Drop them silently; new identity-based tombstones replace.
        deletedSongIdentities = Set(snapshot.deletedSongIdentities ?? [])
        pendingPlaylistIdentities = snapshot.pendingPlaylistIdentities ?? [:]
        pendingHistoryIdentities = snapshot.pendingHistoryIdentities ?? []
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Songs may already include matches for pending entries from a
        // previous launch (e.g. user added the right cloud source between
        // sessions). Try resolving them once on load.
        flushPendingIdentities()
        // 启动时给所有歌就近填 albumID/artistID, 之后 mutation 路径自维护。
        // 老的 snapshot 里如果 ID 已存在, 重填一遍也无妨 (deterministic hash)。
        for i in songs.indices {
            MusicLibrary.fillDerivedIDs(&songs[i])
        }
        // init 阶段直接同步 rebuild ── UI 还没起来, 不需要走异步 schedule。
        rebuildIndexSync()
        if repairedLegacyTextCount > 0 {
            plog("📚 repaired legacy Chinese metadata text for \(repairedLegacyTextCount) song(s)")
            persistNow()
        }
    }

    private func repairLegacyChineseMetadataTextInSnapshot() -> Int {
        var repairedCount = 0

        for index in songs.indices {
            var song = songs[index]
            if Self.repairLegacyChineseMetadataText(in: &song) {
                MusicLibrary.fillDerivedIDs(&song)
                songs[index] = song
                repairedCount += 1
            }
        }

        return repairedCount
    }

    private static func repairLegacyChineseMetadataText(in song: inout Song) -> Bool {
        var changed = false
        changed = repairLegacyChineseText(&song.title) || changed
        changed = repairLegacyChineseText(&song.artistName) || changed
        changed = repairLegacyChineseText(&song.albumTitle) || changed
        changed = repairLegacyChineseText(&song.genre) || changed
        return changed
    }

    private static func repairLegacyChineseText(_ text: inout String) -> Bool {
        let repaired = FileMetadataReader.repairLegacyChineseMojibake(text)
        guard repaired != text else { return false }
        text = repaired
        return true
    }

    private static func repairLegacyChineseText(_ text: inout String?) -> Bool {
        guard var value = text else { return false }
        let repaired = FileMetadataReader.repairLegacyChineseMojibake(value)
        guard repaired != value else { return false }
        value = repaired
        text = value
        return true
    }

    private var persistTask: Task<Void, Never>?

    private func persistSnapshot() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    /// Write library snapshot to disk immediately (e.g. on app backgrounding).
    func persistNow() {
        let snapshot = Snapshot(
            songs: songs,
            playlists: allPlaylists,
            smartPlaylists: allSmartPlaylists.isEmpty ? nil : allSmartPlaylists,
            playlistSongIDs: playlistSongIDs,
            recentPlaybackSongIDs: recentPlaybackSongIDs,
            deletedSongIdentities: Array(deletedSongIdentities),
            pendingPlaylistIdentities: pendingPlaylistIdentities.isEmpty ? nil : pendingPlaylistIdentities,
            pendingHistoryIdentities: pendingHistoryIdentities.isEmpty ? nil : pendingHistoryIdentities
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func sortPlaylists() {
        allPlaylists.sort { $0.updatedAt > $1.updatedAt }
    }

    private func refreshPlaylistArtworkReferences() {
        for index in allPlaylists.indices {
            let firstSongID = playlistSongIDs[allPlaylists[index].id]?.first
            allPlaylists[index].coverArtPath = songs.first(where: { $0.id == firstSongID })?.coverArtFileName
        }
        sortPlaylists()
    }

    private func cleanPlaylistEntries() {
        let validSongIDs = Set(songs.map(\.id))
        for playlistID in playlistSongIDs.keys {
            playlistSongIDs[playlistID] = (playlistSongIDs[playlistID] ?? []).filter { validSongIDs.contains($0) }
        }
    }

    private func cleanPlaybackHistoryEntries() {
        let validSongIDs = Set(songs.map(\.id))
        recentPlaybackSongIDs = recentPlaybackSongIDs.filter { validSongIDs.contains($0) }
    }

    /// 纯函数, 可跨 actor 调用 ── rebuildIndex 后台化时 nonisolated
    /// computeAlbumsAndArtists 也要用。
    nonisolated static func hashID(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 给单首歌就近填好 albumID / artistID, 不依赖整库 rebuildIndex。这样
    /// addSongs / replaceSong 同步路径里, song 加入 library 时 IDs 立刻
    /// 可读, 后台 rebuildIndex 只负责 derive albums/artists 集合。
    nonisolated static func fillDerivedIDs(_ song: inout Song) {
        let unknownArtist = String(localized: "unknown_artist")
        let artist = song.artistName ?? unknownArtist
        song.artistID = hashID(artist.lowercased())
        if let album = song.albumTitle, !album.isEmpty {
            song.albumID = hashID("\(artist):\(album)")
        } else {
            song.albumID = nil
        }
    }

    /// 后台 derive albums / artists 集合。纯函数 ── 给定 songs 数组, 算出
    /// 派生集合, 不操作 self。
    nonisolated static func computeAlbumsAndArtists(songs: [Song]) -> (albums: [Album], artists: [Artist]) {
        let unknownArtist = String(localized: "unknown_artist")

        // Albums ── 只 group 有 albumTitle 的歌曲
        let songsWithAlbum = songs.filter { $0.albumTitle != nil && !$0.albumTitle!.isEmpty }
        let albumGroups = Dictionary(grouping: songsWithAlbum) { song -> String in
            let artist = song.artistName ?? unknownArtist
            let album = song.albumTitle!
            return "\(artist)\0\(album)"
        }
        let albums = albumGroups.map { key, songs -> Album in
            let parts = key.split(separator: "\0", maxSplits: 1)
            let artistName = parts.count > 0 ? String(parts[0]) : unknownArtist
            let albumTitle = parts.count > 1 ? String(parts[1]) : unknownArtist
            return Album(
                id: hashID("\(artistName):\(albumTitle)"),
                title: albumTitle,
                artistID: hashID(artistName.lowercased()),
                artistName: artistName,
                year: songs.first?.year,
                genre: songs.first?.genre,
                songCount: songs.count,
                totalDuration: songs.reduce(0) { $0 + $1.duration.sanitizedDuration },
                sourceID: songs.first?.sourceID
            )
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }

        // Artists ── 全 songs 都参与 group
        let artistGroups = Dictionary(grouping: songs) { $0.artistName ?? unknownArtist }
        let artists = artistGroups.map { name, songs -> Artist in
            let albumCount = Set(songs.compactMap(\.albumTitle)).count
            return Artist(
                id: hashID(name.lowercased()),
                name: name,
                albumCount: albumCount,
                songCount: songs.count
            )
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        return (albums, artists)
    }

    private struct Snapshot: Codable {
        var songs: [Song]
        var playlists: [Playlist]
        /// 智能歌单。Optional 让旧 snapshot decode 不报错。
        var smartPlaylists: [SmartPlaylist]?
        var playlistSongIDs: [String: [String]]?
        var recentPlaybackSongIDs: [String]?
        /// Account-or-source-prefixed identity keys ("<id>:<filePath>").
        /// Persisted via Array because Set isn't Codable-stable across
        /// SDK revs. Optional so old snapshots decode without it.
        var deletedSongIdentities: [String]?
        /// CloudKit-pulled playlist entries waiting for a local song to
        /// match. Optional so old snapshots decode cleanly with no entries.
        var pendingPlaylistIdentities: [String: [PendingSongIdentity]]?
        var pendingHistoryIdentities: [PendingSongIdentity]?
    }
}

extension Notification.Name {
    /// Posted by MetadataAssetStore after lyrics are cached for a songID.
    /// userInfo: ["songID": String, "lyricsText": String]. MusicLibrary 监听
    /// 后, 把对应 song 的 lyricsText 字段更新写库 + 翻 FTS5 索引, 让歌词
    /// 全文搜索覆盖新写入的歌 (不止 backfill 跑过的老歌)。
    static let primuseLyricsDidCache = Notification.Name("primuse.lyricsDidCache")
    /// 请求全屏打开 NowPlayingView。SearchView 点歌词命中结果时会触发, 让
    /// 用户立刻看到歌词上下文 + auto-seek 到命中行。
    static let primuseRequestShowNowPlaying = Notification.Name("primuse.requestShowNowPlaying")
    /// Apple Music 即将开始 / 接管系统侧播放。AudioPlayerService 收到要停掉
    /// 自家 player + 清 currentSong, 让 mini player 切换到 AppleMusicAccessory,
    /// audio session 让给 ApplicationMusicPlayer。
    static let primuseAppleMusicWillPlay = Notification.Name("primuse.appleMusicWillPlay")
    static let primusePlaylistsDidChange = Notification.Name("primuse.playlistsDidChange")
    static let primusePlaylistDidDelete = Notification.Name("primuse.playlistDidDelete")
    static let primuseSmartPlaylistsDidChange = Notification.Name("primuse.smartPlaylistsDidChange")
    static let primuseSmartPlaylistDidDelete = Notification.Name("primuse.smartPlaylistDidDelete")
    static let primusePlaybackHistoryDidChange = Notification.Name("primuse.playbackHistoryDidChange")
    static let primuseSourcesDidChange = Notification.Name("primuse.sourcesDidChange")
    static let primuseSourceDidDelete = Notification.Name("primuse.sourceDidDelete")
    static let primuseScraperConfigDidChange = Notification.Name("primuse.scraperConfigDidChange")
    static let primuseScraperConfigDidDelete = Notification.Name("primuse.scraperConfigDidDelete")
    /// Posted from `MusicLibrary.addSongs` when a re-scan finds an existing
    /// path with different size/mtime — i.e. the user replaced the file
    /// remotely. `userInfo["songs"]` is the `[Song]` of fresh bare songs;
    /// listeners (SourceManager, MetadataBackfillService) drop stale audio
    /// caches and clear failed-backfill marks for these IDs.
    static let primuseSongContentChanged = Notification.Name("primuse.songContentChanged")
    /// Posted when lyrics for a song are replaced by a user action such as
    /// manual scraping. Current playback surfaces (MacNowPlayingView,
    /// MacMiniPlayerView, DesktopLyricsView) reload their in-memory lyrics
    /// when their current song matches `note.object as? String`.
    static let primuseLyricsDidChange = Notification.Name("primuse.lyricsDidChange")
    /// Posted when artwork memory cache entries are invalidated. Visible
    /// `CachedArtworkView`s whose song/ref matches reload even when the
    /// deterministic cover file name did not change after scraping.
    static let primuseArtworkDidInvalidate = Notification.Name("primuse.artworkDidInvalidate")
    /// Posted when songs leave the library because the user deleted them or a
    /// complete re-scan no longer sees their source files. `userInfo["songs"]`
    /// is the removed `[Song]`; listeners drop audio/artwork/lyrics caches.
    static let primuseSongsRemoved = Notification.Name("primuse.songsRemoved")
    /// Posted in addition to `primuseSourcesDidChange` when a source is
    /// soft-deleted locally. CloudKitSyncService listens to this and
    /// enqueues a real `deleteRecord` instead of pushing the soft-delete
    /// flag as a `saveRecord` (the latter caused server-side records to
    /// linger and resurrect on every fetch).
    static let primuseSourceDidSoftDelete = Notification.Name("primuse.sourceDidSoftDelete")
    /// CloudAccount upsert (insert / edit / soft-delete bumping
    /// modifiedAt). Mirror of `primuseSourcesDidChange` for the new
    /// account record type.
    static let primuseCloudAccountsDidChange = Notification.Name("primuse.cloudAccountsDidChange")
    /// CloudAccount soft-delete (push real `deleteRecord` to CloudKit so
    /// the upstream record clears). Mirror of `primuseSourceDidSoftDelete`.
    static let primuseCloudAccountDidSoftDelete = Notification.Name("primuse.cloudAccountDidSoftDelete")
    /// CloudAccount permanent delete (post-30-day prune).
    static let primuseCloudAccountDidDelete = Notification.Name("primuse.cloudAccountDidDelete")
}
