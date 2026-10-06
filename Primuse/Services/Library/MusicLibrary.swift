import Foundation
import PrimuseKit
import CryptoKit
import GRDB
import os
#if os(iOS)
import UIKit
#endif

struct PlaylistBrowseArtworkAccumulator {
    private struct RankedCandidate {
        let song: Song
        let hasArtworkReference: Bool
        let rank: UInt64
        let identity: String
    }

    private let limit: Int
    private let seed: UInt64
    private var rankedCandidates: [RankedCandidate] = []
    private(set) var visibleCount = 0

    init(playlistID: String, limit: Int) {
        self.limit = max(0, limit)
        self.seed = Self.stableHash(playlistID)
        rankedCandidates.reserveCapacity(self.limit)
    }

    mutating func consider(_ song: Song) {
        visibleCount += 1
        guard limit > 0 else { return }
        let artworkReference = song.coverArtFileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = [
            song.id,
            artworkReference ?? "",
            song.sourceID,
            song.filePath,
        ].joined(separator: "\u{1F}")
        let candidate = RankedCandidate(
            song: song,
            hasArtworkReference: artworkReference?.isEmpty == false,
            rank: Self.stableHash(identity, startingAt: seed),
            identity: identity
        )
        if rankedCandidates.count < limit {
            rankedCandidates.append(candidate)
            rankedCandidates.sort(by: Self.precedes)
        } else if let last = rankedCandidates.last, Self.precedes(candidate, last) {
            rankedCandidates[rankedCandidates.count - 1] = candidate
            rankedCandidates.sort(by: Self.precedes)
        }
    }

    var artworkCandidates: [Song] { rankedCandidates.map(\.song) }

    private static func precedes(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        if lhs.hasArtworkReference != rhs.hasArtworkReference {
            return lhs.hasArtworkReference
        }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.identity < rhs.identity
    }

    private static func stableHash(
        _ value: String,
        startingAt initialHash: UInt64 = 14_695_981_039_346_656_037
    ) -> UInt64 {
        var hash = initialHash
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

/// Observation's Equatable fast path is counterproductive for large model
/// arrays: comparing two `[Song]` values also compares lyricsText. Publishing
/// an immutable reference keeps the same observation semantics while making
/// the pre-notification check an O(1) identity change.
/// Two arrays backed by the same buffer. Without disabled sources the visible
/// array is the library array itself; a patch then makes one copy and both
/// take it, instead of each being copied separately.
fileprivate func sharesStorage(_ lhs: [Song], _ rhs: [Song]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return lhs.withUnsafeBufferPointer { left in
        rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
    }
}

private final class LibraryArrayReference<Element: Sendable>: @unchecked Sendable {
    let value: [Element]

    init(_ value: [Element] = []) {
        self.value = value
    }
}

@MainActor
@Observable
final class LibrarySourceSongListState {
    @ObservationIgnored private var reference: LibraryArrayReference<Song>
    @ObservationIgnored private(set) var replacedSongIDs: Set<String> = []
    private(set) var version = SongListSnapshotVersion(collectionRevision: 0, replacementToken: UUID())
    private(set) var sortInvalidationRevision: UInt64 = 0

    var songs: [Song] {
        _ = version
        return reference.value
    }

    init(songs: [Song]) {
        reference = LibraryArrayReference(songs)
    }

    func publish(_ songs: [Song], replacedIDs: Set<String>?, invalidatesSort: Bool = false) {
        let previous = reference
        reference = LibraryArrayReference(songs)
        LibraryArrayReclaimer.release(previous)
        replacedSongIDs = replacedIDs ?? []
        version = SongListSnapshotVersion(
            collectionRevision: version.collectionRevision &+ (replacedIDs == nil ? 1 : 0),
            replacementToken: UUID()
        )
        if invalidatesSort { sortInvalidationRevision &+= 1 }
    }
}

/// Releasing a 10K+ value-type array can recursively release tens of thousands
/// of strings and nested values. ARC normally performs that work on whichever
/// thread swaps the final reference; for observable library publications that
/// is the main actor. During process suspension/termination this used enough of
/// UIKit's five-second watchdog window to trigger 0x8BADF00D.
///
/// Keep small arrays synchronous, but hand the final ownership of large,
/// immutable snapshots to a serial utility queue. The serial queue bounds the
/// amount of simultaneous ARC work and preserves value lifetime safely because
/// every element is Sendable and the wrapper never mutates its array.
private enum LibraryArrayReclaimer {
    private static let asynchronousReleaseThreshold = 512
    private static let queue = DispatchQueue(
        label: "com.welape.primuse.library-array-reclaimer",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    static func release<Element: Sendable>(_ reference: LibraryArrayReference<Element>) {
        guard reference.value.count >= asynchronousReleaseThreshold else { return }
        queue.async {
            withExtendedLifetime(reference) {}
        }
    }

    /// Same contract for a holder that owns several displaced containers at
    /// once (the derived-index lookups). `approximateElementCount` keeps the
    /// 512-element threshold: small libraries stay synchronous and therefore
    /// deterministic.
    static func release<Holder: AnyObject & Sendable>(
        holder: Holder,
        approximateElementCount: Int
    ) {
        guard approximateElementCount >= asynchronousReleaseThreshold else { return }
        queue.async {
            withExtendedLifetime(holder) {}
        }
    }
}

/// Ownership handle for the lookup dictionaries one derived-index apply
/// displaces. Retaining them here before the new ones are stored turns the
/// dozen assignments into plain pointer writes: the recursive teardown of the
/// previous 10K-entry dictionaries (tens of thousands of String/Song releases)
/// then happens on the reclaimer's utility queue instead of the main actor,
/// which is where it used to show up as a scroll hitch.
///
/// Every displaced container is a dictionary of Sendable values, so the holder
/// is checked-`Sendable`: immutable storage of `any Sendable`, never exposed
/// again, which is all the deferred release needs.
private final class DisplacedLibraryLookups: Sendable {
    private let retained: [any Sendable]

    init(_ retained: [any Sendable]) {
        self.retained = retained
    }
}

enum LibrarySearchMatchKind: CaseIterable, Sendable {
    case metadata
    case path
    case lyrics
    case fuzzy

    static let all = Set(allCases)
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
    private let shouldTransliterateCandidates: Bool

    var isValid: Bool { !normalizedQuery.isEmpty }
    var normalizedLength: Int { normalizedQuery.count }

    init(query: String) {
        rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Han query can be matched in its original script. Transliteration
        // is only useful when the user typed Latin pinyin/initials; avoiding it
        // for normal Chinese queries prevents thousands of unnecessary ICU
        // transforms in a large library.
        shouldTransliterateCandidates = !Self.containsHan(rawQuery)
        normalizedQuery = Self.normalized(rawQuery, transliterateHan: false)
    }

    func score(candidate: String) -> (score: Int, kind: LibrarySearchMatchKind)? {
        guard !candidate.isEmpty else { return nil }

        if candidate.localizedCaseInsensitiveContains(rawQuery) {
            return (120, .metadata)
        }

        let normalizedCandidate = Self.normalized(
            candidate,
            transliterateHan: shouldTransliterateCandidates
        )
        guard !normalizedCandidate.isEmpty else { return nil }

        if normalizedCandidate.contains(normalizedQuery) {
            return (110, .metadata)
        }

        if shouldTransliterateCandidates {
            let initials = Self.initials(candidate)
            if !initials.isEmpty, initials.contains(normalizedQuery) {
                return (100, .metadata)
            }
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

        var matchPosition: Int?
        for (index, item) in indexedLines.enumerated() {
            guard !Task.isCancelled else { return nil }
            if lyricsContainQuery(item.text) {
                matchPosition = index
                break
            }
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

    func lyricsContainQuery(_ text: String) -> Bool {
        guard !rawQuery.isEmpty else { return false }
        // Lyrics search is literal full-text search. Pinyin matching remains
        // available for title/artist/album metadata, but transliterating every
        // lyric line is prohibitively expensive and was the source of a
        // MetricKit CPU exception on a 5K-file lyrics library.
        return text.range(
            of: rawQuery,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }

    private static func normalized(_ text: String, transliterateHan: Bool) -> String {
        let latin: String
        if text.unicodeScalars.allSatisfy(\.isASCII) {
            latin = text.lowercased()
        } else if transliterateHan, containsHan(text) {
            latin = text
                .applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)
                ?? text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        } else {
            latin = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }

        let allowed = CharacterSet.alphanumerics
        let scalars = latin.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func initials(_ text: String) -> String {
        let latin: String
        if containsHan(text) {
            latin = text
                .applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)
                ?? text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        } else {
            latin = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }

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

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
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
    var lyricsTextByKey: [String: String] = [:]
    var lyricsLinesByKey: [String: [LyricLine]] = [:]
    var missingLyricsKeys: Set<String> = []
}

struct LibrarySearchOutput: Sendable {
    var songResults: [LibrarySearchResult]
    var albumResults: [Album]
    var cache: LibrarySearchCache
}

private func librarySearchableArtistText(_ song: Song) -> String {
    let nativeNames = song.sourceArtistNames ?? []
    return nativeNames.isEmpty
        ? (song.artistName ?? "")
        : nativeNames.joined(separator: " ")
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
        includeMetadata: Bool = true,
        includeLyrics: Bool = true,
        matchKinds: Set<LibrarySearchMatchKind> = LibrarySearchMatchKind.all,
        songLimit: Int = 120,
        albumLimit: Int = 10
    ) -> LibrarySearchOutput {
        let matcher = LibrarySearchMatcher(query: query)
        guard matcher.isValid else {
            return LibrarySearchOutput(songResults: [], albumResults: [], cache: cache)
        }

        var cache = cache
        let shouldSearchLyrics = includeLyrics
            && matchKinds.contains(.lyrics)
            && matcher.normalizedLength >= minimumLyricsQueryLength

        var rankedSongs: [LibrarySearchResult] = []
        rankedSongs.reserveCapacity(min(songs.count, songLimit * 2))
        for song in songs {
            guard !Task.isCancelled else { break }
            var bestScore = 0
            var bestKind: LibrarySearchMatchKind?
            var lyricSnippet: String?
            var lyricTimestamp: TimeInterval?

            func consider(
                _ candidate: String?,
                boost: Int,
                matchKindOverride: LibrarySearchMatchKind? = nil
            ) {
                guard let candidate,
                      let match = matcher.score(candidate: candidate) else { return }
                // 用户关掉的那类命中不占这首歌, 让它还能落进开着的那类。
                let kind = matchKindOverride ?? match.kind
                guard matchKinds.contains(kind) else { return }
                let score = match.score + boost
                if score > bestScore {
                    bestScore = score
                    bestKind = kind
                }
            }

            if includeMetadata {
                consider(song.title, boost: 30)
                consider(librarySearchableArtistText(song), boost: 20)
                consider(song.albumTitle, boost: 14)
                consider(song.genre, boost: 6)
                consider(song.fileFormat.rawValue, boost: 2)
                consider(
                    SongPathPresentationPolicy.displayPath(
                        filePath: song.filePath,
                        sourceID: song.sourceID
                    ),
                    boost: 10,
                    matchKindOverride: .path
                )
            }

            if shouldSearchLyrics,
               bestScore < 90,
               let searchableText = searchableLyricsText(for: song, cache: &cache),
               matcher.lyricsContainQuery(searchableText),
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

            guard let bestKind else { continue }
            rankedSongs.append(LibrarySearchResult(
                song: song,
                matchKind: bestKind,
                score: bestScore,
                lyricSnippet: lyricSnippet,
                lyricTimestamp: lyricTimestamp
            ))
        }

        let songResults = Array(rankedSongs.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.song.title.localizedCaseInsensitiveCompare(rhs.song.title) == .orderedAscending
        }.prefix(songLimit))

        let albumResults = includeMetadata
            ? searchAlbums(query: query, albums: albums, limit: albumLimit)
            : []

        return LibrarySearchOutput(songResults: songResults, albumResults: albumResults, cache: cache)
    }

    private static func searchAlbums(query: String, albums: [Album], limit: Int) -> [Album] {
        let matcher = LibrarySearchMatcher(query: query)
        guard matcher.isValid else { return [] }
        var ranked: [(Album, Int)] = []
        ranked.reserveCapacity(min(albums.count, limit * 2))
        for album in albums {
            guard !Task.isCancelled else { break }
            var best = 0
            if let score = matcher.score(candidate: album.title)?.score {
                best = max(best, score + 20)
            }
            if let artist = album.artistName,
               let score = matcher.score(candidate: artist)?.score {
                best = max(best, score + 10)
            }
            if best > 0 { ranked.append((album, best)) }
        }
        return Array(ranked.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }.map(\.0).prefix(limit))
    }

    private static func searchableLyricsLines(for song: Song, cache: inout LibrarySearchCache) -> [LyricLine]? {
        let cacheKey = lyricsCacheKey(for: song)
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

    private static func searchableLyricsText(for song: Song, cache: inout LibrarySearchCache) -> String? {
        if let text = song.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        let cacheKey = lyricsCacheKey(for: song)
        if let cached = cache.lyricsTextByKey[cacheKey] { return cached }
        if cache.missingLyricsKeys.contains(cacheKey) { return nil }

        guard let lines = MetadataAssetStore.shared.cachedLyricsForSearch(
            songID: song.id,
            lyricsFileName: song.lyricsFileName
        ) else {
            cache.missingLyricsKeys.insert(cacheKey)
            return nil
        }

        let text = lines
            .flatMap { line -> [LyricLine] in
                var parts = [line]
                if let background = line.background {
                    parts.append(contentsOf: background)
                }
                return parts
            }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else {
            cache.missingLyricsKeys.insert(cacheKey)
            return nil
        }
        cache.lyricsTextByKey[cacheKey] = text
        return text
    }

    private static func lyricsCacheKey(for song: Song) -> String {
        "\(song.id)|\(song.lyricsFileName ?? "")"
    }
}

/// Result returned by the persistent search index. `lyricsIndexComplete` is
/// false only during the first incremental build (or immediately after songs
/// are added). SearchView uses the inexpensive, cancellable literal fallback
/// in that window so existing lyrics search never disappears.
struct LibraryIndexedSearchOutput: Sendable {
    var output: LibrarySearchOutput
    var lyricsIndexComplete: Bool
}

/// Private on-device search engine for the snapshot-backed MusicLibrary.
///
/// Search-time work is deliberately limited to FTS lookups and ranking. ICU
/// Mandarin transliteration happens only when metadata/lyrics change, and the
/// resulting original text, full pinyin, compact pinyin and initials are kept
/// in a persistent SQLite database. This avoids the old behavior where every
/// keystroke transliterated thousands of lyric lines.
actor LibrarySearchIndex {
    static let shared = LibrarySearchIndex()

    private static let baseSchemaVersion = "v1_persistent_original_pinyin"
    private static let substringSchemaVersion = "v2_compact_pinyin_substring"
    private static let externalContentSchemaVersion = "v3_external_lyrics_content"
    private static let displayPathSchemaVersion = "v4_user_visible_song_path"
    private static let incrementalAllSongsSchemaVersion = "v5_incremental_all_songs"
    /// FTS5 external-content triggers touch several indexes per transaction.
    /// Larger utility batches drastically reduce WAL checkpoints/write
    /// amplification while the short inter-batch pause keeps reads responsive.
    private static let lyricsBatchSize = 96
    private static let lyricQueryMinimumLength = 3
    private static let preparationPendingKey =
        "primuse.librarySearchIndex.preparationPending.v1"
    private static let preparationGenerationKey =
        "primuse.librarySearchIndex.preparationGeneration.v1"
    private static let completedPreparationGenerationKey =
        "primuse.librarySearchIndex.completedPreparationGeneration.v1"

    private let dbPool: DatabasePool?
    private var lastMetadataRevisionKey: String?
    private var isPreparing = false

    private struct PendingFullPreparation {
        let songs: [Song]
        let generation: Int
    }

    private struct PendingLyricsRefresh {
        let fallbackText: String?
    }

    private struct PendingSearchDelta {
        var upserts: [String: Song] = [:]
        var mutations = IncrementalLibrarySearchMutationState()
        var lyricsRefreshes: [String: PendingLyricsRefresh] = [:]
        var firstGeneration: Int?
        var lastGeneration = 0

        var isEmpty: Bool {
            mutations.isEmpty && lyricsRefreshes.isEmpty
        }

        mutating func merge(
            upserts songs: [Song],
            deletingIDs ids: Set<String>,
            generation nextGeneration: Int
        ) {
            if firstGeneration == nil { firstGeneration = nextGeneration }
            mutations.recordUpserts(songs.map(\.id))
            mutations.recordDeletions(ids)
            for song in songs {
                upserts[song.id] = song
            }
            for id in ids {
                upserts.removeValue(forKey: id)
            }
            lastGeneration = nextGeneration
        }

        mutating func mergeLyricsRefresh(
            songID: String,
            fallbackText: String?,
            generation nextGeneration: Int
        ) {
            if firstGeneration == nil { firstGeneration = nextGeneration }
            lyricsRefreshes[songID] = PendingLyricsRefresh(fallbackText: fallbackText)
            lastGeneration = nextGeneration
        }
    }

    private var pendingFullPreparation: PendingFullPreparation?
    private var pendingSearchDelta = PendingSearchDelta()

    /// Set synchronously from the library Observation callback. Persisting the
    /// generation closes the crash window between a song mutation and the next
    /// background index pass, while still letting a clean index skip all 14K
    /// metadata/lyrics fingerprint reads on later launches.
    ///
    /// `defaults` 是可注入的偏好存储 (与 AppReviewPromptCoordinator /
    /// CarPlaySettingsStore / AudioEngine 同一写法); 不传时就是 `.standard`,
    /// 生产行为不变。
    @discardableResult
    nonisolated static func persistLibraryChangePending(
        defaults: UserDefaults = .standard
    ) -> Int {
        let current = defaults.integer(forKey: preparationGenerationKey)
        let generation = LibraryIndexMaintenancePolicy.nextPreparationGeneration(current: current)
        defaults.set(generation, forKey: preparationGenerationKey)
        defaults.set(true, forKey: preparationPendingKey)
        return generation
    }

    private nonisolated static func isPreparationPending(
        defaults: UserDefaults = .standard
    ) -> Bool {
        (defaults.object(forKey: preparationPendingKey) as? Bool ?? true)
            || defaults.integer(forKey: completedPreparationGenerationKey)
                != defaults.integer(forKey: preparationGenerationKey)
    }

    nonisolated static var hasPendingPreparation: Bool {
        isPreparationPending()
    }

    nonisolated static func hasPendingPreparation(
        defaults: UserDefaults = .standard
    ) -> Bool {
        isPreparationPending(defaults: defaults)
    }

    nonisolated static func pendingPreparationGeneration(
        defaults: UserDefaults = .standard
    ) -> Int {
        defaults.integer(forKey: preparationGenerationKey)
    }

    private nonisolated static func markPreparationCompleted(
        generation: Int,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(generation, forKey: completedPreparationGenerationKey)
        if generation == defaults.integer(forKey: preparationGenerationKey) {
            defaults.set(false, forKey: preparationPendingKey)
        }
    }

    private nonisolated static func markIncrementalPreparationCompleted(
        firstGeneration: Int,
        lastGeneration: Int,
        defaults: UserDefaults = .standard
    ) {
        let completed = defaults.integer(forKey: completedPreparationGenerationKey)
        // Never mark a crash-recovery gap clean merely because a later delta
        // succeeded. A launch-time full pass remains responsible for the gap.
        guard LibraryIndexMaintenancePolicy.canCompleteIncrementally(
            completedGeneration: completed,
            firstPendingGeneration: firstGeneration
        ) else { return }
        markPreparationCompleted(generation: lastGeneration, defaults: defaults)
    }

    private init(fileManager: FileManager = .default) {
        do {
            #if os(tvOS)
            let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
            #else
            let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
            #endif
            let directory = base.appendingPathComponent("Primuse", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let pool = try DatabasePool(
                path: directory.appendingPathComponent("library-search.sqlite").path
            )
            try Self.migrate(pool)
            dbPool = pool
        } catch {
            dbPool = nil
            plog("🔎 Search index unavailable: \(error.localizedDescription)")
        }
    }

    private static func migrate(_ pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(baseSchemaVersion) { db in
            try db.create(table: "metadataSearchState") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("songID", .text).notNull().unique()
                t.column("fingerprint", .text).notNull()
            }
            try db.create(virtualTable: "metadataLexicalFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("title")
                t.column("artist")
                t.column("album")
                t.column("genre")
            }
            try db.create(virtualTable: "metadataPinyinFts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.prefixes = [1, 2, 3, 4]
                t.column("title")
                t.column("artist")
                t.column("album")
                t.column("initials")
                t.column("compact")
            }

            try db.create(table: "lyricsSearchDocuments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("songID", .text).notNull().unique()
                t.column("signature", .text).notNull()
                t.column("originalText", .text).notNull()
                t.column("pinyinText", .text).notNull()
                t.column("compactPinyin", .text).notNull()
                t.column("initials", .text).notNull()
                t.column("timestamps", .blob).notNull()
            }
            try db.create(virtualTable: "lyricsOriginalFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("originalText")
            }
            try db.create(virtualTable: "lyricsPinyinFts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3, 4]
                t.column("pinyinText")
                t.column("compactPinyin")
                t.column("initials")
            }
        }
        migrator.registerMigration(substringSchemaVersion) { db in
            // unicode61 handles word/phrase prefixes efficiently, while
            // trigram handles compact pinyin and initials at any position
            // (for example `henaihenaini` or `zjl`).
            try db.create(virtualTable: "metadataPinyinSubstringFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("compact")
                t.column("initials")
            }
            try db.create(virtualTable: "lyricsPinyinSubstringFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("compactPinyin")
                t.column("initials")
            }
            // Preserve an index created by an earlier development build.
            try db.execute(sql: """
                INSERT INTO metadataPinyinSubstringFts (rowid, compact, initials)
                SELECT rowid, compact, initials FROM metadataPinyinFts
                """)
            try db.execute(sql: """
                INSERT INTO lyricsPinyinSubstringFts (rowid, compactPinyin, initials)
                SELECT rowid, compactPinyin, initials FROM lyricsPinyinFts
                """)
        }
        migrator.registerMigration(externalContentSchemaVersion) { db in
            // Lyrics text already lives in lyricsSearchDocuments. External-
            // content FTS keeps only posting lists instead of another full
            // copy in each virtual table, and GRDB installs synchronization
            // triggers for later inserts, updates and deletes.
            for table in ["lyricsOriginalFts", "lyricsPinyinFts", "lyricsPinyinSubstringFts"] {
                for suffix in ["ai", "ad", "au"] {
                    try db.execute(sql: "DROP TRIGGER IF EXISTS \"__\(table)_\(suffix)\"")
                }
                try db.execute(sql: "DROP TABLE IF EXISTS \"\(table)\"")
            }
            try db.create(virtualTable: "lyricsOriginalFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.synchronize(withTable: "lyricsSearchDocuments")
                t.column("originalText")
            }
            try db.create(virtualTable: "lyricsPinyinFts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3, 4]
                t.synchronize(withTable: "lyricsSearchDocuments")
                t.column("pinyinText")
                t.column("compactPinyin")
                t.column("initials")
            }
            try db.create(virtualTable: "lyricsPinyinSubstringFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.synchronize(withTable: "lyricsSearchDocuments")
                t.column("compactPinyin")
                t.column("initials")
            }
            try db.create(table: "searchIndexMaintenance", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO searchIndexMaintenance (key) VALUES ('vacuum_v3')"
            )
        }
        migrator.registerMigration(displayPathSchemaVersion) { db in
            try db.create(virtualTable: "metadataPathFts", using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("path")
            }
            // The previous fingerprint did not include a display-safe path, so
            // every existing metadata row must be refreshed once.
            UserDefaults.standard.set(true, forKey: preparationPendingKey)
        }
        migrator.registerMigration(incrementalAllSongsSchemaVersion) { _ in
            // Older builds indexed only the currently visible source set. The
            // incremental index keeps all library rows and filters results
            // against the caller's visible snapshot, so rebuild once when the
            // policy changes.
            UserDefaults.standard.set(true, forKey: preparationPendingKey)
        }
        try migrator.migrate(pool)
        let needsVacuum = try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM searchIndexMaintenance WHERE key = 'vacuum_v3')"
            ) ?? false
        }
        if needsVacuum {
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
                try db.execute(sql: "DELETE FROM searchIndexMaintenance WHERE key = 'vacuum_v3'")
            }
        }
    }

    /// Runs at utility/background priority. Full reconciliation is reserved
    /// for first launch, schema migration, or crash recovery. Routine library
    /// mutations enter through `applyChanges` and touch only changed rows.
    func prepare(songs: [Song], generation: Int) async {
        guard dbPool != nil, !Task.isCancelled, Self.isPreparationPending() else { return }
        pendingFullPreparation = PendingFullPreparation(
            songs: songs,
            generation: generation
        )
        // A newer full snapshot contains every earlier metadata mutation.
        pendingSearchDelta = PendingSearchDelta()
        await drainPendingWork()
    }

    /// Applies a durable, bounded search-index delta. Reentrant calls merge
    /// into one latest-value batch while the actor is writing the current one.
    func applyChanges(
        upserts: [Song],
        deletingIDs: Set<String>,
        generation: Int
    ) async {
        guard dbPool != nil, !upserts.isEmpty || !deletingIDs.isEmpty else { return }
        pendingSearchDelta.merge(
            upserts: upserts,
            deletingIDs: deletingIDs,
            generation: generation
        )
        await drainPendingWork()
    }

    /// Index a newly written lyric immediately. The normal background pass
    /// remains the source of truth and repairs any interrupted update later.
    func refreshLyrics(
        songID: String,
        fallbackText: String?,
        generation: Int
    ) async {
        guard dbPool != nil else { return }
        pendingSearchDelta.mergeLyricsRefresh(
            songID: songID,
            fallbackText: fallbackText,
            generation: generation
        )
        await drainPendingWork()
    }

    private func drainPendingWork() async {
        guard !isPreparing else { return }
        isPreparing = true
        var didCompleteWork = false

        while !Task.isCancelled {
            if let full = pendingFullPreparation {
                pendingFullPreparation = nil
                guard await synchronizeMetadata(songs: full.songs, revisionKey: nil),
                      !Task.isCancelled,
                      await synchronizeLyrics(songs: full.songs),
                      !Task.isCancelled else { break }
                Self.markPreparationCompleted(generation: full.generation)
                didCompleteWork = true
                continue
            }

            if !pendingSearchDelta.isEmpty {
                let work = pendingSearchDelta
                pendingSearchDelta = PendingSearchDelta()
                let upserts = Array(work.upserts.values)
                guard await synchronizeMetadataChanges(
                    upserts: upserts,
                    deletingIDs: work.mutations.deletingIDs
                ), !Task.isCancelled,
                await synchronizeLyricsChanges(
                    upserts: upserts,
                    deletingIDs: work.mutations.deletingIDs
                ), !Task.isCancelled,
                synchronizeLyricsRefreshes(work.lyricsRefreshes),
                !Task.isCancelled else { break }
                if let firstGeneration = work.firstGeneration {
                    Self.markIncrementalPreparationCompleted(
                        firstGeneration: firstGeneration,
                        lastGeneration: work.lastGeneration
                    )
                }
                didCompleteWork = true
                continue
            }
            break
        }

        let wasCancelled = Task.isCancelled
        if wasCancelled {
            // A lifecycle cancellation must stop the whole-library recovery
            // pass. Its durable dirty bit remains set for the next allowed
            // window, while row deltas that arrived during the pass are kept.
            pendingFullPreparation = nil
        }
        isPreparing = false
        if !pendingSearchDelta.isEmpty || (!wasCancelled && pendingFullPreparation != nil) {
            // A cancelled recovery caller must not strand deltas that arrived
            // while its actor method was suspended.
            Task.detached(priority: .utility) { await self.drainPendingWork() }
        }

        if didCompleteWork {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .primuseLibrarySearchIndexDidChange,
                    object: nil
                )
            }
        }
    }

    private func synchronizeLyricsRefreshes(
        _ refreshes: [String: PendingLyricsRefresh]
    ) -> Bool {
        guard !refreshes.isEmpty else { return true }
        guard let pool = dbPool else { return false }
        let store = MetadataAssetStore.shared
        do {
            var documents: [LyricsDocument] = []
            for (songID, refresh) in refreshes {
                if Task.isCancelled { return false }
                let signature = store.cachedLyricsSearchSignature(
                    songID: songID,
                    lyricsFileName: nil
                )
                // Keep the signature namespace identical to the background
                // indexer so a notification and recovery pass cannot alternate
                // between two signatures for the same lyric.
                let resolvedSignature = signature.map { "file:\($0)" }
                    ?? "inline:\(Self.digest(refresh.fallbackText ?? ""))"
                if try Self.lyricsSignature(songID: songID, in: pool) == resolvedSignature {
                    continue
                }
                let lines = store.cachedLyricsForSearch(songID: songID, lyricsFileName: nil)
                    ?? Self.lines(fromPlainText: refresh.fallbackText)
                guard let lines, !lines.isEmpty else { continue }
                documents.append(Self.makeLyricsDocument(
                    songID: songID,
                    signature: resolvedSignature,
                    lines: lines
                ))
            }
            try Self.upsertLyricsDocuments(documents, in: pool)
            return true
        } catch {
            plog("🔎 Failed to refresh lyrics index: \(error.localizedDescription)")
            return false
        }
    }

    /// Search a fully indexed snapshot. Metadata and display-path synchronization
    /// are cheap on normal queries because stable fingerprints avoid writes and ICU.
    func search(
        query: String,
        songs: [Song],
        albums: [Album],
        metadataRevisionKey: String,
        matchKinds: Set<LibrarySearchMatchKind> = LibrarySearchMatchKind.all,
        songLimit: Int = 120,
        albumLimit: Int = 10
    ) async -> LibraryIndexedSearchOutput? {
        guard let pool = dbPool else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LibraryIndexedSearchOutput(
                output: LibrarySearchOutput(
                    songResults: [],
                    albumResults: [],
                    cache: LibrarySearchCache()
                ),
                lyricsIndexComplete: true
            )
        }

        // Mutation paths update the persistent index directly. A query must
        // remain an FTS read even while crash recovery is pending; SearchView
        // listens for the completion notification and reruns automatically.
        lastMetadataRevisionKey = metadataRevisionKey

        do {
            // 只存下标: 每次查询都把整库歌曲拷进字典, 二十多万首时就是几百 MB。
            let songIndexByID: [String: Int] = {
                var indexByID: [String: Int] = [:]
                indexByID.reserveCapacity(songs.count)
                for (offset, song) in songs.enumerated() where indexByID[song.id] == nil {
                    indexByID[song.id] = offset
                }
                return indexByID
            }()
            func indexedSong(withID id: String) -> Song? { songIndexByID[id].map { songs[$0] } }
            var metadataIDs: [String] = []
            var seenMetadata = Set<String>()
            var pathIDs: [String] = []
            var seenPaths = Set<String>()

            if trimmed.count >= 3 {
                let ids = try Self.matchingSongIDs(
                    pool: pool,
                    ftsTable: "metadataLexicalFts",
                    stateTable: "metadataSearchState",
                    pattern: Self.quotedFTS(trimmed),
                    limit: songLimit * 2
                )
                Self.appendUnique(ids, to: &metadataIDs, seen: &seenMetadata)
            } else if Self.containsHan(trimmed) {
                // Trigram indexes intentionally do not handle one/two-character
                // queries. A short literal metadata pass is bounded and never
                // invokes transliteration.
                let ids = songs.lazy
                    .filter { Self.metadataContainsLiteral($0, query: trimmed) }
                    .prefix(songLimit * 2)
                    .map(\.id)
                Self.appendUnique(Array(ids), to: &metadataIDs, seen: &seenMetadata)
            }

            if !Self.containsHan(trimmed) {
                let normalized = Self.normalizedLatinQuery(trimmed)
                let terms = Set([normalized.spaced, normalized.compact])
                    .filter { !$0.isEmpty }
                    .map { Self.quotedFTS($0) + "*" }
                    .sorted()
                if !terms.isEmpty {
                    let ids = try Self.matchingSongIDs(
                        pool: pool,
                        ftsTable: "metadataPinyinFts",
                        stateTable: "metadataSearchState",
                        pattern: terms.joined(separator: " OR "),
                        limit: songLimit * 2
                    )
                    Self.appendUnique(ids, to: &metadataIDs, seen: &seenMetadata)
                }
                if normalized.compact.count >= Self.lyricQueryMinimumLength {
                    let ids = try Self.matchingSongIDs(
                        pool: pool,
                        ftsTable: "metadataPinyinSubstringFts",
                        stateTable: "metadataSearchState",
                        pattern: Self.quotedFTS(normalized.compact),
                        limit: songLimit * 2
                    )
                    Self.appendUnique(ids, to: &metadataIDs, seen: &seenMetadata)
                }
            }

            let searchesPaths = matchKinds.contains(.path)
            if searchesPaths, trimmed.count >= 3 {
                let ids = try Self.matchingSongIDs(
                    pool: pool,
                    ftsTable: "metadataPathFts",
                    stateTable: "metadataSearchState",
                    pattern: Self.quotedFTS(trimmed),
                    limit: songLimit * 2
                )
                Self.appendUnique(ids, to: &pathIDs, seen: &seenPaths)
            } else if searchesPaths {
                let ids = songs.lazy
                    .filter { Self.pathContainsLiteral($0, query: trimmed) }
                    .prefix(songLimit * 2)
                    .map(\.id)
                Self.appendUnique(Array(ids), to: &pathIDs, seen: &seenPaths)
            }

            var lyricHits: [LyricsHit] = []
            var seenLyrics = Set<String>()
            if matchKinds.contains(.lyrics), trimmed.count >= Self.lyricQueryMinimumLength {
                let originalIDs = try Self.matchingLyricsIDs(
                    pool: pool,
                    ftsTable: "lyricsOriginalFts",
                    pattern: Self.quotedFTS(trimmed),
                    limit: songLimit
                )
                let documents = try Self.lyricsDocuments(ids: originalIDs, pool: pool)
                for id in originalIDs where !seenLyrics.contains(id) {
                    guard let document = documents[id],
                          let match = Self.originalLyricsMatch(document, query: trimmed) else { continue }
                    seenLyrics.insert(id)
                    lyricHits.append(LyricsHit(songID: id, snippet: match.snippet, timestamp: match.timestamp))
                }

                if !Self.containsHan(trimmed) {
                    let normalized = Self.normalizedLatinQuery(trimmed)
                    var pinyinIDs: [String] = []
                    var seenPinyin = Set<String>()
                    let terms = Set([normalized.spaced, normalized.compact])
                        .filter { $0.count >= Self.lyricQueryMinimumLength }
                        .map { Self.quotedFTS($0) + "*" }
                        .sorted()
                    if !terms.isEmpty {
                        let ids = try Self.matchingLyricsIDs(
                            pool: pool,
                            ftsTable: "lyricsPinyinFts",
                            pattern: terms.joined(separator: " OR "),
                            limit: songLimit
                        )
                        Self.appendUnique(ids, to: &pinyinIDs, seen: &seenPinyin)
                    }
                    if normalized.compact.count >= Self.lyricQueryMinimumLength {
                        let ids = try Self.matchingLyricsIDs(
                            pool: pool,
                            ftsTable: "lyricsPinyinSubstringFts",
                            pattern: Self.quotedFTS(normalized.compact),
                            limit: songLimit
                        )
                        Self.appendUnique(ids, to: &pinyinIDs, seen: &seenPinyin)
                    }
                    if !pinyinIDs.isEmpty {
                        let pinyinDocuments = try Self.lyricsDocuments(ids: pinyinIDs, pool: pool)
                        for id in pinyinIDs where !seenLyrics.contains(id) {
                            guard let document = pinyinDocuments[id],
                                  let match = Self.pinyinLyricsMatch(document, query: normalized) else { continue }
                            seenLyrics.insert(id)
                            lyricHits.append(LyricsHit(songID: id, snippet: match.snippet, timestamp: match.timestamp))
                        }
                    }
                }
            }

            var ranked: [LibrarySearchResult] = []
            ranked.reserveCapacity(min(
                songLimit * 2,
                metadataIDs.count + pathIDs.count + lyricHits.count
            ))
            var resultIDs = Set<String>()
            for (offset, id) in metadataIDs.enumerated() {
                guard let song = indexedSong(withID: id) else { continue }
                let literal = Self.metadataContainsLiteral(song, query: trimmed)
                let kind: LibrarySearchMatchKind = literal ? .metadata : .fuzzy
                // 用户关掉的那类命中不占这首歌, 让它还能落进路径或歌词命中。
                guard matchKinds.contains(kind) else { continue }
                ranked.append(LibrarySearchResult(
                    song: song,
                    matchKind: kind,
                    score: max(100, 220 - offset),
                    lyricSnippet: nil,
                    lyricTimestamp: nil
                ))
                resultIDs.insert(id)
            }
            for (offset, id) in pathIDs.enumerated() where !resultIDs.contains(id) {
                guard let song = indexedSong(withID: id) else { continue }
                ranked.append(LibrarySearchResult(
                    song: song,
                    matchKind: .path,
                    score: max(80, 130 - offset),
                    lyricSnippet: nil,
                    lyricTimestamp: nil
                ))
                resultIDs.insert(id)
            }
            for (offset, hit) in lyricHits.enumerated() where !resultIDs.contains(hit.songID) {
                guard let song = indexedSong(withID: hit.songID) else { continue }
                ranked.append(LibrarySearchResult(
                    song: song,
                    matchKind: .lyrics,
                    score: max(60, 95 - offset),
                    lyricSnippet: hit.snippet,
                    lyricTimestamp: hit.timestamp
                ))
                resultIDs.insert(hit.songID)
            }
            let songResults = Array(ranked.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.song.title.localizedCaseInsensitiveCompare(rhs.song.title) == .orderedAscending
            }.prefix(songLimit))

            let albumByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
            var albumResults: [Album] = []
            var albumIDs = Set<String>()
            for id in metadataIDs {
                guard let albumID = indexedSong(withID: id)?.albumID,
                      !albumIDs.contains(albumID),
                      let album = albumByID[albumID] else { continue }
                albumIDs.insert(albumID)
                albumResults.append(album)
                if albumResults.count == albumLimit { break }
            }

            let lyricsComplete = !Self.isPreparationPending()
            return LibraryIndexedSearchOutput(
                output: LibrarySearchOutput(
                    songResults: songResults,
                    albumResults: albumResults,
                    cache: LibrarySearchCache()
                ),
                lyricsIndexComplete: lyricsComplete
            )
        } catch {
            plog("🔎 Indexed search failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func synchronizeMetadata(songs: [Song], revisionKey: String?) async -> Bool {
        guard let pool = dbPool else { return false }
        if let revisionKey, lastMetadataRevisionKey == revisionKey { return true }

        do {
            let existing = try Self.metadataStates(in: pool)
            let songIDs = Set(songs.map(\.id))
            var changed: [(song: Song, fingerprint: String, stateID: Int64?)] = []
            changed.reserveCapacity(min(songs.count, 256))
            for (offset, song) in songs.enumerated() {
                if offset.isMultiple(of: 128), Task.isCancelled { return false }
                let fingerprint = Self.metadataFingerprint(song)
                if existing[song.id]?.fingerprint != fingerprint {
                    changed.append((song, fingerprint, existing[song.id]?.id))
                }
            }
            guard !Task.isCancelled else { return false }
            let removed = existing.filter { !songIDs.contains($0.key) }.map(\.value.id)
            let metadataChanges = changed

            if !metadataChanges.isEmpty || !removed.isEmpty {
                try await pool.write { db in
                    for (offset, id) in removed.enumerated() {
                        if offset.isMultiple(of: 64), Task.isCancelled {
                            throw CancellationError()
                        }
                        try db.execute(sql: "DELETE FROM metadataLexicalFts WHERE rowid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM metadataPinyinFts WHERE rowid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM metadataPinyinSubstringFts WHERE rowid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM metadataPathFts WHERE rowid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM metadataSearchState WHERE id = ?", arguments: [id])
                    }
                    for (offset, change) in metadataChanges.enumerated() {
                        if offset.isMultiple(of: 32), Task.isCancelled {
                            throw CancellationError()
                        }
                        let document = Self.makeMetadataDocument(change.song)
                        let stateID: Int64
                        if let existingID = change.stateID {
                            stateID = existingID
                            try db.execute(
                                sql: "UPDATE metadataSearchState SET fingerprint = ? WHERE id = ?",
                                arguments: [change.fingerprint, existingID]
                            )
                            try db.execute(sql: "DELETE FROM metadataLexicalFts WHERE rowid = ?", arguments: [existingID])
                            try db.execute(sql: "DELETE FROM metadataPinyinFts WHERE rowid = ?", arguments: [existingID])
                            try db.execute(sql: "DELETE FROM metadataPinyinSubstringFts WHERE rowid = ?", arguments: [existingID])
                            try db.execute(sql: "DELETE FROM metadataPathFts WHERE rowid = ?", arguments: [existingID])
                        } else {
                            try db.execute(
                                sql: "INSERT INTO metadataSearchState (songID, fingerprint) VALUES (?, ?)",
                                arguments: [change.song.id, change.fingerprint]
                            )
                            stateID = db.lastInsertedRowID
                        }
                        try db.execute(
                            sql: "INSERT INTO metadataLexicalFts (rowid, title, artist, album, genre) VALUES (?, ?, ?, ?, ?)",
                            arguments: [stateID, change.song.title, librarySearchableArtistText(change.song), change.song.albumTitle ?? "", change.song.genre ?? ""]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPinyinFts (rowid, title, artist, album, initials, compact) VALUES (?, ?, ?, ?, ?, ?)",
                            arguments: [stateID, document.title, document.artist, document.album, document.initials, document.compact]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPinyinSubstringFts (rowid, compact, initials) VALUES (?, ?, ?)",
                            arguments: [stateID, document.compact, document.initials]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPathFts (rowid, path) VALUES (?, ?)",
                            arguments: [
                                stateID,
                                SongPathPresentationPolicy.displayPath(
                                    filePath: change.song.filePath,
                                    sourceID: change.song.sourceID
                                ) ?? "",
                            ]
                        )
                    }
                }
            }
            lastMetadataRevisionKey = revisionKey
            return true
        } catch is CancellationError {
            // Search requests and metadata snapshots are intentionally
            // replaceable. GRDB observes the parent task cancellation while
            // writing and rolls the transaction back; the next snapshot will
            // retry it. Do not report this normal hand-off as an index error.
            return false
        } catch {
            plog("🔎 Metadata index sync failed: \(error.localizedDescription)")
            return false
        }
    }

    private func synchronizeMetadataChanges(
        upserts: [Song],
        deletingIDs: Set<String>
    ) async -> Bool {
        guard !upserts.isEmpty || !deletingIDs.isEmpty else { return true }
        guard let pool = dbPool else { return false }

        do {
            let requestedIDs = Set(upserts.map(\.id)).union(deletingIDs)
            let existing = try Self.metadataStates(songIDs: requestedIDs, in: pool)
            var changes: [(song: Song, fingerprint: String, stateID: Int64?)] = []
            changes.reserveCapacity(upserts.count)
            for (offset, song) in upserts.enumerated() {
                if offset.isMultiple(of: 64), Task.isCancelled { return false }
                let fingerprint = Self.metadataFingerprint(song)
                if existing[song.id]?.fingerprint != fingerprint {
                    changes.append((song, fingerprint, existing[song.id]?.id))
                }
            }
            let removed = deletingIDs.compactMap { existing[$0]?.id }
            let metadataChanges = changes

            if !metadataChanges.isEmpty || !removed.isEmpty {
                try await pool.write { db in
                    for id in removed {
                        if Task.isCancelled { throw CancellationError() }
                        try db.execute(
                            sql: "DELETE FROM metadataLexicalFts WHERE rowid = ?",
                            arguments: [id]
                        )
                        try db.execute(
                            sql: "DELETE FROM metadataPinyinFts WHERE rowid = ?",
                            arguments: [id]
                        )
                        try db.execute(
                            sql: "DELETE FROM metadataPinyinSubstringFts WHERE rowid = ?",
                            arguments: [id]
                        )
                        try db.execute(
                            sql: "DELETE FROM metadataPathFts WHERE rowid = ?",
                            arguments: [id]
                        )
                        try db.execute(
                            sql: "DELETE FROM metadataSearchState WHERE id = ?",
                            arguments: [id]
                        )
                    }

                    for (offset, change) in metadataChanges.enumerated() {
                        if offset.isMultiple(of: 32), Task.isCancelled {
                            throw CancellationError()
                        }
                        let document = Self.makeMetadataDocument(change.song)
                        let stateID: Int64
                        if let existingID = change.stateID {
                            stateID = existingID
                            try db.execute(
                                sql: "UPDATE metadataSearchState SET fingerprint = ? WHERE id = ?",
                                arguments: [change.fingerprint, existingID]
                            )
                            try db.execute(
                                sql: "DELETE FROM metadataLexicalFts WHERE rowid = ?",
                                arguments: [existingID]
                            )
                            try db.execute(
                                sql: "DELETE FROM metadataPinyinFts WHERE rowid = ?",
                                arguments: [existingID]
                            )
                            try db.execute(
                                sql: "DELETE FROM metadataPinyinSubstringFts WHERE rowid = ?",
                                arguments: [existingID]
                            )
                            try db.execute(
                                sql: "DELETE FROM metadataPathFts WHERE rowid = ?",
                                arguments: [existingID]
                            )
                        } else {
                            try db.execute(
                                sql: "INSERT INTO metadataSearchState (songID, fingerprint) VALUES (?, ?)",
                                arguments: [change.song.id, change.fingerprint]
                            )
                            stateID = db.lastInsertedRowID
                        }
                        try db.execute(
                            sql: "INSERT INTO metadataLexicalFts (rowid, title, artist, album, genre) VALUES (?, ?, ?, ?, ?)",
                            arguments: [
                                stateID,
                                change.song.title,
                                librarySearchableArtistText(change.song),
                                change.song.albumTitle ?? "",
                                change.song.genre ?? "",
                            ]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPinyinFts (rowid, title, artist, album, initials, compact) VALUES (?, ?, ?, ?, ?, ?)",
                            arguments: [
                                stateID,
                                document.title,
                                document.artist,
                                document.album,
                                document.initials,
                                document.compact,
                            ]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPinyinSubstringFts (rowid, compact, initials) VALUES (?, ?, ?)",
                            arguments: [stateID, document.compact, document.initials]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPathFts (rowid, path) VALUES (?, ?)",
                            arguments: [
                                stateID,
                                SongPathPresentationPolicy.displayPath(
                                    filePath: change.song.filePath,
                                    sourceID: change.song.sourceID
                                ) ?? "",
                            ]
                        )
                    }
                }
            }
            lastMetadataRevisionKey = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            plog("🔎 Metadata index delta failed: \(error.localizedDescription)")
            return false
        }
    }

    private func synchronizeLyrics(songs: [Song]) async -> Bool {
        guard let pool = dbPool else { return false }
        do {
            var existing = try Self.lyricsStates(in: pool)
            let visibleIDs = Set(songs.map(\.id))
            let store = MetadataAssetStore.shared

            for start in stride(from: 0, to: songs.count, by: Self.lyricsBatchSize) {
                if Task.isCancelled { return false }
                let end = min(start + Self.lyricsBatchSize, songs.count)
                var documents: [LyricsDocument] = []
                var removals: [Int64] = []

                for song in songs[start..<end] {
                    let fileSignature = store.cachedLyricsSearchSignature(
                        songID: song.id,
                        lyricsFileName: song.lyricsFileName
                    )
                    let inlineText = song.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let signature: String?
                    if let fileSignature {
                        signature = "file:\(fileSignature)"
                    } else if let inlineText, !inlineText.isEmpty {
                        signature = "inline:\(Self.digest(inlineText))"
                    } else {
                        signature = nil
                    }

                    guard let signature else {
                        if let old = existing.removeValue(forKey: song.id) { removals.append(old.id) }
                        continue
                    }
                    if existing[song.id]?.signature == signature { continue }

                    let lines = store.cachedLyricsForSearch(
                        songID: song.id,
                        lyricsFileName: song.lyricsFileName
                    ) ?? Self.lines(fromPlainText: inlineText)
                    guard let lines, !lines.isEmpty else { continue }
                    documents.append(Self.makeLyricsDocument(
                        songID: song.id,
                        signature: signature,
                        lines: lines
                    ))
                    existing[song.id] = StoredLyricsState(id: existing[song.id]?.id ?? -1, signature: signature)
                }

                if !removals.isEmpty {
                    try Self.removeLyricsDocuments(ids: removals, in: pool)
                }
                if !documents.isEmpty {
                    try Self.upsertLyricsDocuments(documents, in: pool)
                }

                if Task.isCancelled { return false }

                // Let interactive FTS reads interleave with the first build,
                // and keep one-time indexing from becoming sustained CPU load.
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(18))
            }

            guard !Task.isCancelled else { return false }
            let staleIDs = existing
                .filter { !visibleIDs.contains($0.key) }
                .map(\.value.id)
                .filter { $0 >= 0 }
            if !staleIDs.isEmpty {
                try Self.removeLyricsDocuments(ids: staleIDs, in: pool)
            }
            return true
        } catch {
            plog("🔎 Lyrics index sync failed: \(error.localizedDescription)")
            return false
        }
    }

    private func synchronizeLyricsChanges(
        upserts: [Song],
        deletingIDs: Set<String>
    ) async -> Bool {
        guard !upserts.isEmpty || !deletingIDs.isEmpty else { return true }
        guard let pool = dbPool else { return false }

        do {
            let requestedIDs = Set(upserts.map(\.id)).union(deletingIDs)
            var existing = try Self.lyricsStates(songIDs: requestedIDs, in: pool)
            let store = MetadataAssetStore.shared
            var documents: [LyricsDocument] = []
            var removalIDs = Set<Int64>()

            for (offset, song) in upserts.enumerated() {
                if offset.isMultiple(of: 32), Task.isCancelled { return false }
                let fileSignature = store.cachedLyricsSearchSignature(
                    songID: song.id,
                    lyricsFileName: song.lyricsFileName
                )
                let inlineText = song.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let signature: String?
                if let fileSignature {
                    signature = "file:\(fileSignature)"
                } else if let inlineText, !inlineText.isEmpty {
                    signature = "inline:\(Self.digest(inlineText))"
                } else {
                    signature = nil
                }

                guard let signature else {
                    if let old = existing.removeValue(forKey: song.id), old.id >= 0 {
                        removalIDs.insert(old.id)
                    }
                    continue
                }
                if existing[song.id]?.signature == signature { continue }
                let lines = store.cachedLyricsForSearch(
                    songID: song.id,
                    lyricsFileName: song.lyricsFileName
                ) ?? Self.lines(fromPlainText: inlineText)
                guard let lines, !lines.isEmpty else { continue }
                documents.append(Self.makeLyricsDocument(
                    songID: song.id,
                    signature: signature,
                    lines: lines
                ))
            }

            for id in deletingIDs {
                if let old = existing[id], old.id >= 0 {
                    removalIDs.insert(old.id)
                }
            }
            if !removalIDs.isEmpty {
                try Self.removeLyricsDocuments(ids: Array(removalIDs), in: pool)
            }
            if !documents.isEmpty {
                try Self.upsertLyricsDocuments(documents, in: pool)
            }
            return !Task.isCancelled
        } catch {
            plog("🔎 Lyrics index delta failed: \(error.localizedDescription)")
            return false
        }
    }

    private struct StoredMetadataState {
        let id: Int64
        let fingerprint: String
    }

    private struct StoredLyricsState {
        let id: Int64
        let signature: String
    }

    private struct MetadataDocument {
        let title: String
        let artist: String
        let album: String
        let initials: String
        let compact: String
    }

    private struct LyricsDocument {
        let songID: String
        let signature: String
        let originalText: String
        let pinyinText: String
        let compactPinyin: String
        let initials: String
        let timestamps: [TimeInterval]
    }

    private struct LyricsHit {
        let songID: String
        let snippet: String
        let timestamp: TimeInterval
    }

    private struct NormalizedLatinQuery {
        let spaced: String
        let compact: String
    }

    private static func metadataStates(in pool: DatabasePool) throws -> [String: StoredMetadataState] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, songID, fingerprint FROM metadataSearchState")
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: Int64 = row["id"]
                let songID: String = row["songID"]
                let fingerprint: String = row["fingerprint"]
                return (songID, StoredMetadataState(id: id, fingerprint: fingerprint))
            })
        }
    }

    private static func metadataStates(
        songIDs: Set<String>,
        in pool: DatabasePool
    ) throws -> [String: StoredMetadataState] {
        guard !songIDs.isEmpty else { return [:] }
        return try pool.read { db in
            var result: [String: StoredMetadataState] = [:]
            result.reserveCapacity(songIDs.count)
            for songID in songIDs {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT id, fingerprint FROM metadataSearchState WHERE songID = ?",
                    arguments: [songID]
                ) {
                    let id: Int64 = row["id"]
                    let fingerprint: String = row["fingerprint"]
                    result[songID] = StoredMetadataState(id: id, fingerprint: fingerprint)
                }
            }
            return result
        }
    }

    private static func lyricsStates(in pool: DatabasePool) throws -> [String: StoredLyricsState] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, songID, signature FROM lyricsSearchDocuments")
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: Int64 = row["id"]
                let songID: String = row["songID"]
                let signature: String = row["signature"]
                return (songID, StoredLyricsState(id: id, signature: signature))
            })
        }
    }

    private static func lyricsStates(
        songIDs: Set<String>,
        in pool: DatabasePool
    ) throws -> [String: StoredLyricsState] {
        guard !songIDs.isEmpty else { return [:] }
        return try pool.read { db in
            var result: [String: StoredLyricsState] = [:]
            result.reserveCapacity(songIDs.count)
            for songID in songIDs {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT id, signature FROM lyricsSearchDocuments WHERE songID = ?",
                    arguments: [songID]
                ) {
                    let id: Int64 = row["id"]
                    let signature: String = row["signature"]
                    result[songID] = StoredLyricsState(id: id, signature: signature)
                }
            }
            return result
        }
    }

    private static func lyricsSignature(
        songID: String,
        in pool: DatabasePool
    ) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT signature FROM lyricsSearchDocuments WHERE songID = ?",
                arguments: [songID]
            )
        }
    }

    private static func upsertLyricsDocuments(_ documents: [LyricsDocument], in pool: DatabasePool) throws {
        guard !documents.isEmpty else { return }
        try pool.write { db in
            for document in documents {
                let existingID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM lyricsSearchDocuments WHERE songID = ?",
                    arguments: [document.songID]
                )
                let timestamps = try JSONEncoder().encode(document.timestamps)
                if let existingID {
                    try db.execute(
                        sql: """
                        UPDATE lyricsSearchDocuments
                        SET signature = ?, originalText = ?, pinyinText = ?,
                            compactPinyin = ?, initials = ?, timestamps = ?
                        WHERE id = ?
                        """,
                        arguments: [document.signature, document.originalText, document.pinyinText, document.compactPinyin, document.initials, timestamps, existingID]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO lyricsSearchDocuments
                            (songID, signature, originalText, pinyinText, compactPinyin, initials, timestamps)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [document.songID, document.signature, document.originalText, document.pinyinText, document.compactPinyin, document.initials, timestamps]
                    )
                }
            }
        }
    }

    private static func removeLyricsDocuments(ids: [Int64], in pool: DatabasePool) throws {
        guard !ids.isEmpty else { return }
        try pool.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM lyricsSearchDocuments WHERE id = ?", arguments: [id])
            }
        }
    }

    private static func matchingSongIDs(
        pool: DatabasePool,
        ftsTable: String,
        stateTable: String,
        pattern: String,
        limit: Int
    ) throws -> [String] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT state.songID
                FROM \(ftsTable)
                JOIN \(stateTable) AS state ON state.id = \(ftsTable).rowid
                WHERE \(ftsTable) MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [pattern, limit])
            return rows.map { row in
                let songID: String = row["songID"]
                return songID
            }
        }
    }

    private static func matchingLyricsIDs(
        pool: DatabasePool,
        ftsTable: String,
        pattern: String,
        limit: Int
    ) throws -> [String] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT documents.songID
                FROM \(ftsTable)
                JOIN lyricsSearchDocuments AS documents ON documents.id = \(ftsTable).rowid
                WHERE \(ftsTable) MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [pattern, limit])
            return rows.map { row in
                let songID: String = row["songID"]
                return songID
            }
        }
    }

    private static func lyricsDocuments(
        ids: [String],
        pool: DatabasePool
    ) throws -> [String: LyricsDocument] {
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in
            var result: [String: LyricsDocument] = [:]
            result.reserveCapacity(ids.count)
            for songID in ids {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT songID, signature, originalText, pinyinText,
                           compactPinyin, initials, timestamps
                    FROM lyricsSearchDocuments WHERE songID = ?
                    """,
                    arguments: [songID]
                ) else { continue }
                let data: Data = row["timestamps"]
                let timestamps = (try? JSONDecoder().decode([TimeInterval].self, from: data)) ?? []
                let id: String = row["songID"]
                let signature: String = row["signature"]
                let originalText: String = row["originalText"]
                let pinyinText: String = row["pinyinText"]
                let compactPinyin: String = row["compactPinyin"]
                let initials: String = row["initials"]
                result[id] = LyricsDocument(
                    songID: id,
                    signature: signature,
                    originalText: originalText,
                    pinyinText: pinyinText,
                    compactPinyin: compactPinyin,
                    initials: initials,
                    timestamps: timestamps
                )
            }
            return result
        }
    }

    private static func makeMetadataDocument(_ song: Song) -> MetadataDocument {
        let title = song.titlePinyin ?? PinyinTransformer.pinyin(song.title) ?? folded(song.title)
        let artistSource = librarySearchableArtistText(song)
        let albumSource = song.albumTitle ?? ""
        let artist = song.artistPinyin ?? PinyinTransformer.pinyin(artistSource) ?? folded(artistSource)
        let album = song.albumPinyin ?? PinyinTransformer.pinyin(albumSource) ?? folded(albumSource)
        let values = [title, artist, album]
        return MetadataDocument(
            title: title,
            artist: artist,
            album: album,
            initials: values.map(initialsFromPinyin).joined(separator: " "),
            compact: values.map(compactLatin).joined(separator: " ")
        )
    }

    private static func makeLyricsDocument(
        songID: String,
        signature: String,
        lines: [LyricLine]
    ) -> LyricsDocument {
        let flattened = lines.flatMap { line -> [LyricLine] in
            var result = [line]
            if let background = line.background { result.append(contentsOf: background) }
            return result
        }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let originals = flattened.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let originalText = originals.joined(separator: "\n")

        // Transform the whole lyric in one ICU call. Newlines survive the
        // transform, preserving line/timestamp alignment without thousands of
        // per-line CoreFoundation invocations.
        let transformed = PinyinTransformer.pinyin(originalText) ?? folded(originalText)
        var pinyinLines = splitLines(transformed)
        if pinyinLines.count != originals.count {
            pinyinLines = originals.map { PinyinTransformer.pinyin($0) ?? folded($0) }
        }
        let compactLines = pinyinLines.map(compactLatin)
        let initialLines = pinyinLines.map(initialsFromPinyin)
        return LyricsDocument(
            songID: songID,
            signature: signature,
            originalText: originalText,
            pinyinText: pinyinLines.joined(separator: "\n"),
            compactPinyin: compactLines.joined(separator: "\n"),
            initials: initialLines.joined(separator: "\n"),
            timestamps: flattened.map(\.timestamp)
        )
    }

    private static func originalLyricsMatch(
        _ document: LyricsDocument,
        query: String
    ) -> (snippet: String, timestamp: TimeInterval)? {
        let lines = splitLines(document.originalText)
        guard let index = lines.firstIndex(where: {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
        }) else { return nil }
        return snippet(document: document, lineIndex: index)
    }

    private static func pinyinLyricsMatch(
        _ document: LyricsDocument,
        query: NormalizedLatinQuery
    ) -> (snippet: String, timestamp: TimeInterval)? {
        let pinyin = splitLines(document.pinyinText)
        let compact = splitLines(document.compactPinyin)
        let initials = splitLines(document.initials)
        let count = min(pinyin.count, compact.count, initials.count)
        guard count > 0 else { return nil }
        for index in 0..<count {
            if (!query.spaced.isEmpty && pinyin[index].localizedCaseInsensitiveContains(query.spaced))
                || (!query.compact.isEmpty && compact[index].contains(query.compact))
                || (!query.compact.isEmpty && initials[index].contains(query.compact)) {
                return snippet(document: document, lineIndex: index)
            }
        }
        return nil
    }

    private static func snippet(
        document: LyricsDocument,
        lineIndex: Int
    ) -> (snippet: String, timestamp: TimeInterval)? {
        let lines = splitLines(document.originalText)
        guard lines.indices.contains(lineIndex) else { return nil }
        let lower = max(0, lineIndex - 1)
        let upper = min(lines.count - 1, lineIndex + 1)
        var snippetLines = Array(lines[lower...upper])
        if lower > 0 { snippetLines[0] = "..." + snippetLines[0] }
        if upper < lines.count - 1 { snippetLines[snippetLines.count - 1] += "..." }
        let timestamp = document.timestamps.indices.contains(lineIndex)
            ? document.timestamps[lineIndex]
            : 0
        return (snippetLines.joined(separator: "\n"), timestamp)
    }

    private static func metadataFingerprint(_ song: Song) -> String {
        digest([
            song.title,
            song.artistName ?? "",
            song.sourceArtistNames?.joined(separator: "\u{1F}") ?? "",
            song.albumTitle ?? "",
            song.genre ?? "",
            song.titlePinyin ?? "",
            song.artistPinyin ?? "",
            song.albumPinyin ?? "",
            SongPathPresentationPolicy.displayPath(
                filePath: song.filePath,
                sourceID: song.sourceID
            ) ?? ""
        ].joined(separator: "\u{1F}"))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedLatinQuery(_ text: String) -> NormalizedLatinQuery {
        let value = folded(text)
        let spacedScalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
            CharacterSet.alphanumerics.contains(scalar) ? scalar : UnicodeScalar(32)!
        }
        let spaced = String(String.UnicodeScalarView(spacedScalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return NormalizedLatinQuery(spaced: spaced, compact: compactLatin(spaced))
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private static func compactLatin(_ text: String) -> String {
        let scalars = folded(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func initialsFromPinyin(_ text: String) -> String {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func lines(fromPlainText text: String?) -> [LyricLine]? {
        guard let text else { return nil }
        let lines = splitLines(text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.map { LyricLine(timestamp: 0, text: $0) }
    }

    private static func metadataContainsLiteral(_ song: Song, query: String) -> Bool {
        [song.title, librarySearchableArtistText(song), song.albumTitle, song.genre]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func pathContainsLiteral(_ song: Song, query: String) -> Bool {
        SongPathPresentationPolicy.displayPath(
            filePath: song.filePath,
            sourceID: song.sourceID
        )?.localizedCaseInsensitiveContains(query) == true
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func quotedFTS(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func appendUnique(_ ids: [String], to output: inout [String], seen: inout Set<String>) {
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            output.append(id)
        }
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

struct MusicDiscoveryResult: Identifiable, Equatable, Sendable {
    let song: Song
    let score: Double
    let reasons: [MusicDiscoveryReason]

    var id: String { song.id }
    var primaryReason: MusicDiscoveryReason { reasons.first ?? .libraryPick }
}

enum MusicDiscoveryEngine {
    struct RecommendationSnapshot: Sendable {
        let songs: [Song]
        let recentSongs: [Song]
        let historyEntries: [PlayHistoryStore.Entry]
        let now: Date
        /// `MusicLibrary.musicSongsRevision` when `songs` came from the library;
        /// lets the feature index be reused until the song list changes.
        var libraryRevision: UInt64? = nil

        func makeInput() -> RecommendationInput {
            func entries(in range: PlayHistoryStore.Range) -> [PlayHistoryStore.Entry] {
                let cutoff = range.startDate(now: now)
                return historyEntries.filter { $0.playedAt >= cutoff && $0.playedAt <= now }
            }
            let monthEntries = entries(in: .month)
            let topSongs = PlayHistoryStore.rankedItems(from: entries(in: .year), category: .songs, limit: 12)
            let topArtists = PlayHistoryStore.rankedItems(from: monthEntries, category: .artists, limit: 6)
            // 种子只能是库里可播放的歌。候选最多二十几首, 只为它们查一遍,
            // 不为整库建 id 集合、也不复制一份只含可播放歌曲的数组。
            let candidateSeedIDs = topSongs.map(\.id) + recentSongs.map(\.id)
            let wanted = Set(candidateSeedIDs)
            var playableSeedIDs = Set<String>()
            for song in songs where wanted.contains(song.id) && song.isPlayable {
                playableSeedIDs.insert(song.id)
                if playableSeedIDs.count == wanted.count { break }
            }
            var seenSeedIDs = Set<String>()
            let seedIDs = candidateSeedIDs.filter {
                playableSeedIDs.contains($0) && seenSeedIDs.insert($0).inserted
            }
            return RecommendationInput(
                songs: songs,
                recentWeekIDs: Set(entries(in: .week).map(\.songID)),
                recentMonthIDs: Set(monthEntries.map(\.songID)),
                topArtists: Set(topArtists.map { normalized($0.title) }),
                seedIDs: seedIDs,
                now: now,
                libraryRevision: libraryRevision
            )
        }
    }

    struct RecommendationInput: Sendable {
        /// Candidate songs. Songs that are not playable are skipped by the
        /// engine, so the library's list can be passed without filtering.
        let songs: [Song]
        let recentWeekIDs: Set<String>
        let recentMonthIDs: Set<String>
        let topArtists: Set<String>
        let seedIDs: [String]
        let now: Date
        var libraryRevision: UInt64? = nil
    }

    @MainActor
    static func similarSongs(
        to seed: Song,
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 24
    ) -> [MusicDiscoveryResult] {
        let recentIDs = Set(history.entries(in: .month).map(\.songID))
        // Music only: spoken word is never suggested as "similar".
        let songs = library.musicSongs
        let index = featureIndex(for: songs, revision: library.musicSongsRevision)
        return similarSongs(to: seed, songs: songs, index: index, recentIDs: recentIDs, limit: limit)
    }

    static func similarSongs(
        to seed: Song,
        songs: [Song],
        recentIDs: Set<String>,
        limit: Int
    ) -> [MusicDiscoveryResult] {
        similarSongs(
            to: seed,
            songs: songs,
            index: featureIndex(for: songs, revision: nil),
            recentIDs: recentIDs,
            limit: limit
        )
    }

    private static func similarSongs(
        to seed: Song,
        songs: [Song],
        index: FeatureIndex?,
        recentIDs: Set<String>,
        limit: Int
    ) -> [MusicDiscoveryResult] {
        guard let index else { return [] }
        let seedFeature = index.feature(for: seed)
        var results: [Candidate] = []
        for position in index.ids.indices where index.playable[position] {
            guard index.ids[position] != seed.id else { continue }
            var match = similarity(between: seedFeature, and: position, in: index)
            guard match.score > 0 else { continue }
            if !recentIDs.contains(index.ids[position]) {
                match.score += 4
                match.reasons.insert(.notRecentlyPlayed)
            }
            results.append(Candidate(position: position, score: match.score, reasons: match.reasons))
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return index.titles[lhs.position].localizedCompare(index.titles[rhs.position]) == .orderedAscending
        }
        return results.prefix(limit).map { $0.result(in: songs) }
    }

    /// Songs to follow a music queue that ran out (#166): the songs most like
    /// each seed — the queue's last few — interleaved, at most three per album
    /// and five per artist, skipping `excluded` (the queue and what was just
    /// played). Off the main actor on the library's own array; the feature
    /// index is reused while `revision` holds. Each seed keeps only a bounded
    /// best-of list instead of sorting the whole library.
    static func continuationSongIDs(
        seeds: [Song],
        songs: [Song],
        revision: UInt64,
        recentIDs: Set<String>,
        excluding excluded: Set<String>,
        limit: Int,
        isCancelled: () -> Bool = { false }
    ) -> [String] {
        guard limit > 0, !seeds.isEmpty,
              let index = featureIndex(for: songs, revision: revision, isCancelled: isCancelled) else { return [] }
        let keep = limit * 3
        var rankings: [[String]] = []
        var positionByID: [String: Int] = [:]
        for seed in seeds {
            guard !isCancelled() else { return [] }
            let seedFeature = index.feature(for: seed)
            // Ties are common (same genre, similar length); a per-seed salt
            // breaks them differently each time instead of by library order.
            let salt = UInt64(truncatingIfNeeded: seed.id.hashValue)
            var top: [(score: Double, position: Int)] = []
            top.reserveCapacity(keep + 1)
            for position in index.ids.indices where index.playable[position] {
                if position.isMultiple(of: 4_096), isCancelled() { return [] }
                let match = similarity(between: seedFeature, and: position, in: index)
                guard match.score > 0 else { continue }
                var mixed = (UInt64(position) &+ salt) &* 0x9E37_79B9_7F4A_7C15
                mixed ^= mixed >> 29
                let jitter = Double(mixed % 1_000) / 1_000
                // Only songs that can still make the list pay for the string lookups.
                if top.count == keep, match.score + 4 + jitter <= top[keep - 1].score { continue }
                let id = index.ids[position]
                guard id != seed.id, !excluded.contains(id) else { continue }
                let score = match.score + (recentIDs.contains(id) ? 0 : 4) + jitter
                if top.count == keep, score <= top[keep - 1].score { continue }
                var low = 0
                var high = top.count
                while low < high {
                    let middle = (low + high) / 2
                    if top[middle].score >= score { low = middle + 1 } else { high = middle }
                }
                top.insert((score, position), at: low)
                if top.count > keep { top.removeLast() }
            }
            rankings.append(top.map { entry in
                let id = index.ids[entry.position]
                positionByID[id] = entry.position
                return id
            })
        }
        var merged = QueueContinuationPolicy.merge(
            rankedBySeed: rankings,
            excluding: excluded,
            limit: limit,
            groupLimits: [
                .init(maximum: 3, key: { id in positionByID[id].map { String(index.albumIdentity[$0]) } }),
                .init(maximum: 5, key: { id in positionByID[id].map { String(index.artistIdentity[$0]) } }),
            ]
        )
        // A library with nothing alike (no tags at all) still keeps playing.
        if merged.count < limit {
            var taken = excluded.union(merged)
            for seed in seeds { taken.insert(seed.id) }
            var attempts = 0
            while merged.count < limit, attempts < limit * 20, !index.ids.isEmpty {
                attempts += 1
                let position = Int.random(in: index.ids.indices)
                guard index.playable[position] else { continue }
                let id = index.ids[position]
                if taken.insert(id).inserted { merged.append(id) }
            }
        }
        return merged
    }

    @MainActor
    static func recommendationInput(
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        now: Date = Date()
    ) -> RecommendationInput {
        recommendationSnapshot(in: library, history: history, now: now).makeInput()
    }

    @MainActor
    static func recommendationSnapshot(
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        now: Date = Date()
    ) -> RecommendationSnapshot {
        // Music only: books neither get recommended nor seed recommendations.
        RecommendationSnapshot(
            songs: library.musicSongs,
            recentSongs: library.recentlyPlayedSongs(limit: 12),
            historyEntries: history.musicEntries,
            now: now,
            libraryRevision: library.musicSongsRevision
        )
    }

    @MainActor
    static func recommendations(
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 12,
        now: Date = Date()
    ) -> [MusicDiscoveryResult] {
        recommendations(
            from: recommendationInput(in: library, history: history, now: now),
            limit: limit
        )
    }

    private static func recommendations(
        from input: RecommendationInput,
        limit: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [MusicDiscoveryResult] {
        let songs = input.songs
        guard !songs.isEmpty, !isCancelled() else { return [] }
        // 整库打分只在紧凑的特征索引上做: 每首歌几十字节的整数键, 不复制歌曲本身;
        // 只有最后选中的那十几首才取出完整的 Song。
        guard let index = featureIndex(for: songs, revision: input.libraryRevision, isCancelled: isCancelled),
              !isCancelled() else { return [] }

        let seedIDSet = Set(input.seedIDs)
        var seedPositionByID: [String: Int] = [:]
        for position in index.ids.indices
        where index.playable[position] && seedIDSet.contains(index.ids[position]) {
            if seedPositionByID[index.ids[position]] == nil { seedPositionByID[index.ids[position]] = position }
        }
        let seeds = input.seedIDs.compactMap { seedPositionByID[$0] }.map { index.feature(at: $0) }

        guard !seeds.isEmpty else {
            return coldStartCandidates(
                in: index,
                excluding: [],
                limit: limit,
                now: input.now,
                isCancelled: isCancelled
            ).map { $0.result(in: songs) }
        }

        let topArtistKeys = Set(input.topArtists.compactMap { index.textKeys[$0] })
        var results: [Candidate] = []
        for position in index.ids.indices where index.playable[position] {
            if position.isMultiple(of: 128), isCancelled() { return [] }
            let id = index.ids[position]
            guard !input.recentWeekIDs.contains(id) else { continue }

            var best = Match(score: 0, reasons: [])
            for seed in seeds where seed.id != id {
                let match = similarity(between: seed, and: position, in: index)
                if match.score > best.score { best = match }
            }

            var score = best.score
            var reasons = best.reasons

            let artistName = index.artistName[position]
            if artistName != FeatureIndex.noKey, topArtistKeys.contains(artistName) {
                score += 18
                reasons.insert(.recentFavorite)
            }

            if !input.recentMonthIDs.contains(id) {
                score += 12
                reasons.insert(.notRecentlyPlayed)
            }

            if input.now.timeIntervalSince(index.dateAdded[position]) <= 30 * 24 * 60 * 60 {
                score += 8
                reasons.insert(.newToLibrary)
            }

            if index.hasCoverArt[position] {
                score += 3
            }

            guard score >= 16 else { continue }
            if reasons.isEmpty { reasons = ReasonSet([.libraryPick]) }
            results.append(Candidate(position: position, score: score, reasons: reasons))
        }

        guard !isCancelled() else { return [] }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return index.dateAdded[lhs.position] > index.dateAdded[rhs.position]
        }
        guard !isCancelled() else { return [] }

        var ranked = uniqued(results, in: index)
        // 目标最多 4 位艺人, 数够就停。
        let artistCountCap = min(4, max(0, limit))
        var availableArtists = Set<Int64>()
        for position in index.ids.indices where availableArtists.count < artistCountCap {
            guard index.playable[position], !input.recentWeekIDs.contains(index.ids[position]) else { continue }
            availableArtists.insert(index.artistIdentity[position])
        }
        let targetArtistCount = min(artistCountCap, availableArtists.count)
        let rankedArtistCount = Set(ranked.map { index.artistIdentity[$0.position] }).count
        if ranked.count < limit || rankedArtistCount < targetArtistCount {
            let excluded = Set(ranked.map { index.ids[$0.position] }).union(input.recentWeekIDs)
            ranked.append(contentsOf: coldStartCandidates(
                in: index,
                excluding: excluded,
                limit: max(limit * 2, limit - ranked.count),
                now: input.now,
                isCancelled: isCancelled
            ))
        }
        guard !isCancelled() else { return [] }
        return diversified(ranked, limit: limit, in: index).map { $0.result(in: songs) }
    }

    @MainActor
    static func dailyRecommendations(
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 12,
        now: Date = Date()
    ) -> [MusicDiscoveryResult] {
        dailyRecommendations(
            from: recommendationInput(in: library, history: history, now: now),
            limit: limit
        )
    }

    static func dailyRecommendations(
        from input: RecommendationInput,
        limit: Int = 12,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [MusicDiscoveryResult] {
        guard !isCancelled() else { return [] }
        let ranked = recommendations(
            from: input,
            limit: max(limit * 3, limit),
            isCancelled: isCancelled
        )
            .sorted { lhs, rhs in
                let left = lhs.score + stableDailyNoise(lhs.song.id, now: input.now) * 8
                let right = rhs.score + stableDailyNoise(rhs.song.id, now: input.now) * 8
                if left != right { return left > right }
                return lhs.song.title.localizedCompare(rhs.song.title) == .orderedAscending
            }
        guard !isCancelled() else { return [] }
        return diversifiedRecommendations(ranked, limit: limit)
    }

    @MainActor
    static func songRadio(
        from seed: Song,
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        limit: Int = 48,
        now: Date = Date()
    ) -> [MusicDiscoveryResult] {
        guard seed.isPlayable else { return [] }
        let songs = library.musicSongs
        let index = featureIndex(for: songs, revision: library.musicSongsRevision)
        let recentMonthIDs = Set(history.entries(in: .month, now: now).map(\.songID))
        // Fallback recommendations don't depend on the moving cursor, so build
        // them once and just skip already-used songs as the queue grows.
        let fallbacks = dailyRecommendations(in: library, history: history, limit: 24, now: now)
        return songRadio(
            from: seed,
            songs: songs,
            index: index,
            recentMonthIDs: recentMonthIDs,
            fallbacks: fallbacks,
            limit: limit,
            now: now
        )
    }

    static func songRadio(
        from seed: Song,
        songs: [Song],
        recentMonthIDs: Set<String>,
        fallbacks: [MusicDiscoveryResult],
        limit: Int,
        now: Date
    ) -> [MusicDiscoveryResult] {
        guard seed.isPlayable else { return [] }
        return songRadio(
            from: seed,
            songs: songs,
            index: featureIndex(for: songs, revision: nil),
            recentMonthIDs: recentMonthIDs,
            fallbacks: fallbacks,
            limit: limit,
            now: now
        )
    }

    /// Greedy walk: each step picks the candidate most similar to the previous
    /// pick. Everything that does not depend on the moving cursor — the
    /// normalized features and the per-song daily noise — is computed once,
    /// so each step is a single pass over integers.
    private static func songRadio(
        from seed: Song,
        songs: [Song],
        index: FeatureIndex?,
        recentMonthIDs: Set<String>,
        fallbacks: [MusicDiscoveryResult],
        limit: Int,
        now: Date
    ) -> [MusicDiscoveryResult] {
        var output = [
            MusicDiscoveryResult(song: seed, score: .greatestFiniteMagnitude, reasons: [.libraryPick])
        ]
        guard let index else { return output }
        var usedIDs: Set<String> = [seed.id]
        var cursor = index.feature(for: seed)
        var dailyNoise: [Double] = []

        while output.count < limit {
            if dailyNoise.isEmpty {
                let day = dailyNoiseDay(now)
                dailyNoise = index.ids.map { stableDailyNoise($0, day: day) }
            }
            var best: (position: Int, match: Match, sortScore: Double)?
            for position in index.ids.indices where index.playable[position] {
                let id = index.ids[position]
                guard !usedIDs.contains(id), id != cursor.id else { continue }
                var match = similarity(between: cursor, and: position, in: index)
                guard match.score > 0 else { continue }
                if !recentMonthIDs.contains(id) {
                    match.score += 4
                    match.reasons.insert(.notRecentlyPlayed)
                }
                let sortScore = match.score + dailyNoise[position] * 3
                let isBetter: Bool
                if let current = best {
                    if sortScore != current.sortScore {
                        isBetter = sortScore > current.sortScore
                    } else {
                        isBetter = index.titles[position]
                            .localizedCompare(index.titles[current.position]) == .orderedAscending
                    }
                } else {
                    isBetter = true
                }
                if isBetter { best = (position, match, sortScore) }
            }

            if let next = best {
                output.append(Candidate(
                    position: next.position,
                    score: next.match.score,
                    reasons: next.match.reasons
                ).result(in: songs))
                usedIDs.insert(index.ids[next.position])
                cursor = index.feature(at: next.position)
                continue
            }

            guard let fallback = fallbacks.first(where: { !usedIDs.contains($0.song.id) }) else {
                break
            }
            output.append(fallback)
            usedIDs.insert(fallback.song.id)
            cursor = index.feature(for: fallback.song)
        }

        return output
    }

    // MARK: - Feature index

    /// Reasons in the order the scoring steps add them. Every step adds a
    /// reason at most once and always in this order, so a set reproduces the
    /// list exactly.
    private struct ReasonSet: Equatable {
        private static let order: [MusicDiscoveryReason] = [
            .sameAlbum, .sameArtist, .sameGenre, .sameEra, .similarDuration, .sameFolder,
            .recentFavorite, .notRecentlyPlayed, .newToLibrary, .libraryPick,
        ]
        private var bits: UInt16 = 0

        init(_ reasons: [MusicDiscoveryReason]) {
            for reason in reasons { insert(reason) }
        }

        var isEmpty: Bool { bits == 0 }

        mutating func insert(_ reason: MusicDiscoveryReason) {
            guard let offset = Self.order.firstIndex(of: reason) else { return }
            bits |= 1 << UInt16(offset)
        }

        var reasons: [MusicDiscoveryReason] {
            Self.order.enumerated().compactMap { offset, reason in
                bits & (1 << UInt16(offset)) != 0 ? reason : nil
            }
        }
    }

    private struct Match {
        var score: Double
        var reasons: ReasonSet

        init(score: Double, reasons: [MusicDiscoveryReason]) {
            self.score = score
            self.reasons = ReasonSet(reasons)
        }
    }

    private struct Candidate {
        let position: Int
        let score: Double
        let reasons: ReasonSet

        func result(in songs: [Song]) -> MusicDiscoveryResult {
            MusicDiscoveryResult(song: songs[position], score: score, reasons: reasons.reasons)
        }
    }

    /// The comparison features of one song, as keys into a `FeatureIndex`.
    private struct Feature {
        let id: String
        let albumID: Int32
        let albumTitle: Int32
        let artistID: Int32
        let artistName: Int32
        let genre: Int32
        let folder: Int32
        let source: Int32
        let year: Int?
        let duration: TimeInterval
    }

    /// Struct-of-arrays feature table over one song list. Every text field is
    /// case/diacritic-folded once and interned to an integer key, so scoring a
    /// 200K-song library compares integers instead of copying and re-folding
    /// strings — the previous per-call `NormalizedSong` array kept a full `Song`
    /// copy per entry and cost hundreds of MB on large libraries.
    private struct FeatureIndex: Sendable {
        /// Nil or empty after normalization: never equal to anything.
        static let noKey: Int32 = -1

        var ids: [String] = []
        var titles: [String] = []
        var dateAdded: [Date] = []
        var playable: [Bool] = []
        var hasCoverArt: [Bool] = []
        var hasArtistName: [Bool] = []
        var hasAlbumTitle: [Bool] = []
        var hasGenre: [Bool] = []
        var albumID: [Int32] = []
        var albumTitle: [Int32] = []
        var artistID: [Int32] = []
        var artistName: [Int32] = []
        var genre: [Int32] = []
        var folder: [Int32] = []
        var source: [Int32] = []
        var year: [Int?] = []
        var duration: [TimeInterval] = []
        var artistIdentity: [Int64] = []
        var albumIdentity: [Int64] = []
        var coldStartNoise: [Double] = []
        /// Normalized text → key. Shared by every folded field; keys are only
        /// ever compared within the same field.
        var textKeys: [String: Int32] = [:]
        var sourceKeys: [String: Int32] = [:]
        /// Raw text → key while building. A library repeats the same album,
        /// artist and genre strings across every track, and folding each one
        /// again was most of the build (a million songs: tens of seconds).
        /// Emptied once the index is built.
        private var rawTextKeys: [String: Int32] = [:]
        private var folderKeys: [String: Int32] = [:]

        init?(songs: [Song], isCancelled: () -> Bool) {
            let count = songs.count
            ids.reserveCapacity(count)
            titles.reserveCapacity(count)
            dateAdded.reserveCapacity(count)
            playable.reserveCapacity(count)
            hasCoverArt.reserveCapacity(count)
            hasArtistName.reserveCapacity(count)
            hasAlbumTitle.reserveCapacity(count)
            hasGenre.reserveCapacity(count)
            albumID.reserveCapacity(count)
            albumTitle.reserveCapacity(count)
            artistID.reserveCapacity(count)
            artistName.reserveCapacity(count)
            genre.reserveCapacity(count)
            folder.reserveCapacity(count)
            source.reserveCapacity(count)
            year.reserveCapacity(count)
            duration.reserveCapacity(count)
            artistIdentity.reserveCapacity(count)
            albumIdentity.reserveCapacity(count)
            coldStartNoise.reserveCapacity(count)
            var albumTitleIdentityKeys: [AlbumTitleIdentity: Int64] = [:]

            for (position, song) in songs.enumerated() {
                if position.isMultiple(of: 512), isCancelled() { return nil }
                ids.append(song.id)
                titles.append(song.title)
                dateAdded.append(song.dateAdded)
                playable.append(song.isPlayable)
                hasCoverArt.append(song.coverArtFileName?.isEmpty == false)
                hasArtistName.append(song.artistName?.isEmpty == false)
                hasAlbumTitle.append(song.albumTitle?.isEmpty == false)
                hasGenre.append(song.genre?.isEmpty == false)
                let albumIDKey = intern(song.albumID)
                let albumTitleKey = intern(song.albumTitle)
                let artistIDKey = intern(song.artistID)
                let artistNameKey = intern(song.artistName)
                albumID.append(albumIDKey)
                albumTitle.append(albumTitleKey)
                artistID.append(artistIDKey)
                artistName.append(artistNameKey)
                genre.append(intern(song.genre))
                folder.append(internFolder(of: song.filePath))
                source.append(internSource(song.sourceID))
                year.append(song.year)
                duration.append(song.duration)
                coldStartNoise.append(MusicDiscoveryEngine.stableNoise(song.id))

                // Same precedence as `artistIdentity(_:)` / `albumIdentity(_:artistKey:)`:
                // id, then name/title, then the song itself.
                let artistKey: Int64
                if artistIDKey != Self.noKey {
                    artistKey = Int64(artistIDKey)
                } else if artistNameKey != Self.noKey {
                    artistKey = (1 << 32) | Int64(artistNameKey)
                } else {
                    artistKey = (2 << 32) | Int64(position)
                }
                artistIdentity.append(artistKey)
                if albumIDKey != Self.noKey {
                    albumIdentity.append(Int64(albumIDKey))
                } else if albumTitleKey != Self.noKey {
                    let pair = AlbumTitleIdentity(artist: artistKey, title: albumTitleKey)
                    let next = (1 << 40) | Int64(albumTitleIdentityKeys.count)
                    albumIdentity.append(albumTitleIdentityKeys[pair, default: next])
                    if albumTitleIdentityKeys[pair] == nil { albumTitleIdentityKeys[pair] = next }
                } else {
                    albumIdentity.append((2 << 40) | Int64(position))
                }
            }
            rawTextKeys = [:]
            folderKeys = [:]
        }

        private struct AlbumTitleIdentity: Hashable {
            let artist: Int64
            let title: Int32
        }

        private mutating func intern(_ text: String?) -> Int32 {
            guard let text else { return Self.noKey }
            if let key = rawTextKeys[text] { return key }
            let key = internNormalized(MusicDiscoveryEngine.normalized(text))
            rawTextKeys[text] = key
            return key
        }

        private mutating func internFolder(of path: String) -> Int32 {
            let folder = MusicDiscoveryEngine.folderPath(of: path)
            if let key = folderKeys[folder] { return key }
            let key = internNormalized(MusicDiscoveryEngine.normalizedFolder(folder))
            folderKeys[folder] = key
            return key
        }

        private mutating func internNormalized(_ value: String) -> Int32 {
            guard !value.isEmpty else { return Self.noKey }
            if let key = textKeys[value] { return key }
            let key = Int32(textKeys.count)
            textKeys[value] = key
            return key
        }

        private mutating func internSource(_ sourceID: String) -> Int32 {
            if let key = sourceKeys[sourceID] { return key }
            let key = Int32(sourceKeys.count)
            sourceKeys[sourceID] = key
            return key
        }

        func feature(at position: Int) -> Feature {
            Feature(
                id: ids[position],
                albumID: albumID[position],
                albumTitle: albumTitle[position],
                artistID: artistID[position],
                artistName: artistName[position],
                genre: genre[position],
                folder: folder[position],
                source: source[position],
                year: year[position],
                duration: duration[position]
            )
        }

        /// Features of a song that may not be in the list (a radio seed). Text
        /// absent from the index cannot equal any indexed song's text.
        func feature(for song: Song) -> Feature {
            func key(_ text: String?) -> Int32 {
                guard let text else { return Self.noKey }
                let value = MusicDiscoveryEngine.normalized(text)
                guard !value.isEmpty else { return Self.noKey }
                return textKeys[value] ?? -2
            }
            let folderText = MusicDiscoveryEngine.parentFolder(song.filePath)
            return Feature(
                id: song.id,
                albumID: key(song.albumID),
                albumTitle: key(song.albumTitle),
                artistID: key(song.artistID),
                artistName: key(song.artistName),
                genre: key(song.genre),
                folder: folderText.isEmpty ? Self.noKey : (textKeys[folderText] ?? -2),
                source: sourceKeys[song.sourceID] ?? -2,
                year: song.year,
                duration: song.duration
            )
        }
    }

    private struct CachedFeatureIndex: Sendable {
        let revision: UInt64
        let count: Int
        let index: FeatureIndex
    }

    private static let featureIndexCache = OSAllocatedUnfairLock<CachedFeatureIndex?>(initialState: nil)

    /// The feature index for `songs`, reused while the library's music list
    /// keeps the same revision. Nil only when cancelled mid-build.
    private static func featureIndex(
        for songs: [Song],
        revision: UInt64?,
        isCancelled: () -> Bool = { false }
    ) -> FeatureIndex? {
        if let revision,
           let cached = featureIndexCache.withLock({ $0 }),
           cached.revision == revision,
           cached.count == songs.count {
            return cached.index
        }
        guard let index = FeatureIndex(songs: songs, isCancelled: isCancelled) else { return nil }
        if let revision {
            featureIndexCache.withLock { cache in
                if cache == nil || cache!.revision <= revision {
                    cache = CachedFeatureIndex(revision: revision, count: songs.count, index: index)
                }
            }
        }
        return index
    }

    private static func keysMatch(_ lhs: Int32, _ rhs: Int32) -> Bool {
        lhs >= 0 && lhs == rhs
    }

    /// Scoring over interned features; identical rules and weights to the
    /// string comparison it replaces (folded, non-empty equality).
    private static func similarity(
        between seed: Feature,
        and position: Int,
        in index: FeatureIndex
    ) -> Match {
        var score: Double = 0
        var reasons = ReasonSet([])

        if keysMatch(seed.albumID, index.albumID[position])
            || keysMatch(seed.albumTitle, index.albumTitle[position]) {
            score += 46
            reasons.insert(.sameAlbum)
        }

        if keysMatch(seed.artistID, index.artistID[position])
            || keysMatch(seed.artistName, index.artistName[position]) {
            score += 40
            reasons.insert(.sameArtist)
        }

        if keysMatch(seed.genre, index.genre[position]) {
            score += 30
            reasons.insert(.sameGenre)
        }

        if let seedYear = seed.year, let candidateYear = index.year[position] {
            let delta = abs(seedYear - candidateYear)
            if delta <= 2 {
                score += 10
                reasons.insert(.sameEra)
            } else if delta <= 6 {
                score += 5
                reasons.insert(.sameEra)
            }
        }

        let candidateDuration = index.duration[position]
        if seed.duration > 30, candidateDuration > 30 {
            let delta = abs(seed.duration - candidateDuration)
            let ratio = delta / max(seed.duration, candidateDuration)
            if ratio <= 0.12 {
                score += 7
                reasons.insert(.similarDuration)
            } else if ratio <= 0.22 {
                score += 3
            }
        }

        if seed.source == index.source[position],
           keysMatch(seed.folder, index.folder[position]) {
            score += 12
            reasons.insert(.sameFolder)
        }

        var match = Match(score: score, reasons: [])
        match.reasons = reasons
        return match
    }

    private static func coldStartCandidates(
        in index: FeatureIndex,
        excluding excludedIDs: Set<String>,
        limit: Int,
        now: Date,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [Candidate] {
        var ranked: [Candidate] = []
        for position in index.ids.indices where index.playable[position] {
            if position.isMultiple(of: 128), isCancelled() { return [] }
            guard !excludedIDs.contains(index.ids[position]) else { continue }
            let dateAdded = index.dateAdded[position]
            var score = index.hasCoverArt[position] ? 12.0 : 0.0
            score += max(0, 10 - now.timeIntervalSince(dateAdded) / (7 * 24 * 60 * 60))
            if index.hasArtistName[position] { score += 3 }
            if index.hasAlbumTitle[position] { score += 3 }
            if index.hasGenre[position] { score += 2 }
            score += index.coldStartNoise[position]

            let reason: MusicDiscoveryReason = now.timeIntervalSince(dateAdded) <= 30 * 24 * 60 * 60
                ? .newToLibrary
                : .libraryPick
            ranked.append(Candidate(position: position, score: score, reasons: ReasonSet([reason])))
        }
        guard !isCancelled() else { return [] }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return index.dateAdded[lhs.position] > index.dateAdded[rhs.position]
        }
        guard !isCancelled() else { return [] }
        return diversified(ranked, limit: limit, in: index)
    }

    private static func uniqued(_ candidates: [Candidate], in index: FeatureIndex) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert(index.ids[$0.position]).inserted }
    }

    /// `diversifiedRecommendations` over index positions.
    private static func diversified(
        _ rankedCandidates: [Candidate],
        limit: Int,
        in index: FeatureIndex
    ) -> [Candidate] {
        guard limit > 0 else { return [] }
        // 与先整份 `uniqued` 再挑逐项相同, 只是去重只做到挑够为止: 冷启动时
        // 候选是整库, 整份去重要为百万首各建一项集合。
        var ranked: [Candidate] = []
        var rankedIDs = Set<String>()
        var nextRankedCandidate = 0
        func rankedCandidate(at offset: Int) -> Candidate? {
            while ranked.count <= offset, nextRankedCandidate < rankedCandidates.count {
                let candidate = rankedCandidates[nextRankedCandidate]
                nextRankedCandidate += 1
                if rankedIDs.insert(index.ids[candidate.position]).inserted { ranked.append(candidate) }
            }
            return offset < ranked.count ? ranked[offset] : nil
        }
        var output: [Candidate] = []
        var selectedIDs = Set<String>()
        var artistCounts: [Int64: Int] = [:]
        var albumCounts: [Int64: Int] = [:]

        func appendPass(maxPerArtist: Int?, maxPerAlbum: Int?) {
            guard output.count < limit else { return }
            var offset = 0
            while output.count < limit, let candidate = rankedCandidate(at: offset) {
                offset += 1
                let id = index.ids[candidate.position]
                guard !selectedIDs.contains(id) else { continue }
                let artistKey = index.artistIdentity[candidate.position]
                let albumKey = index.albumIdentity[candidate.position]
                if let maxPerArtist, artistCounts[artistKey, default: 0] >= maxPerArtist {
                    continue
                }
                if let maxPerAlbum, albumCounts[albumKey, default: 0] >= maxPerAlbum {
                    continue
                }
                selectedIDs.insert(id)
                artistCounts[artistKey, default: 0] += 1
                albumCounts[albumKey, default: 0] += 1
                output.append(candidate)
            }
        }

        appendPass(maxPerArtist: 1, maxPerAlbum: 1)
        appendPass(maxPerArtist: 2, maxPerAlbum: 1)
        appendPass(maxPerArtist: 2, maxPerAlbum: 2)
        appendPass(maxPerArtist: nil, maxPerAlbum: nil)
        return output
    }

    /// Keeps the strongest tracks first while preventing one artist or album
    /// from occupying the whole recommendation surface. The final unrestricted
    /// pass still fills small or single-artist libraries instead of returning
    /// an unnecessarily short queue.
    static func diversifiedRecommendations(
        _ rankedResults: [MusicDiscoveryResult],
        limit: Int
    ) -> [MusicDiscoveryResult] {
        guard limit > 0 else { return [] }
        let ranked = uniqued(rankedResults)
        var output: [MusicDiscoveryResult] = []
        var selectedIDs = Set<String>()
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]

        func appendPass(maxPerArtist: Int?, maxPerAlbum: Int?) {
            guard output.count < limit else { return }
            for result in ranked where output.count < limit && !selectedIDs.contains(result.song.id) {
                let artistKey = artistIdentity(result.song)
                let albumKey = albumIdentity(result.song, artistKey: artistKey)
                if let maxPerArtist, artistCounts[artistKey, default: 0] >= maxPerArtist {
                    continue
                }
                if let maxPerAlbum, albumCounts[albumKey, default: 0] >= maxPerAlbum {
                    continue
                }
                selectedIDs.insert(result.song.id)
                artistCounts[artistKey, default: 0] += 1
                albumCounts[albumKey, default: 0] += 1
                output.append(result)
            }
        }

        appendPass(maxPerArtist: 1, maxPerAlbum: 1)
        appendPass(maxPerArtist: 2, maxPerAlbum: 1)
        appendPass(maxPerArtist: 2, maxPerAlbum: 2)
        appendPass(maxPerArtist: nil, maxPerAlbum: nil)
        return output
    }

    private static func uniqued(_ results: [MusicDiscoveryResult]) -> [MusicDiscoveryResult] {
        var seen = Set<String>()
        var output: [MusicDiscoveryResult] = []
        for result in results where seen.insert(result.song.id).inserted {
            output.append(result)
        }
        return output
    }

    private static func artistIdentity(_ song: Song) -> String {
        if let artistID = song.artistID, !normalized(artistID).isEmpty {
            return "id:\(normalized(artistID))"
        }
        if let artistName = song.artistName, !normalized(artistName).isEmpty {
            return "name:\(normalized(artistName))"
        }
        return "song:\(song.id)"
    }

    private static func albumIdentity(_ song: Song, artistKey: String) -> String {
        if let albumID = song.albumID, !normalized(albumID).isEmpty {
            return "id:\(normalized(albumID))"
        }
        if let albumTitle = song.albumTitle, !normalized(albumTitle).isEmpty {
            return "title:\(artistKey):\(normalized(albumTitle))"
        }
        return "song:\(song.id)"
    }

    private static func parentFolder(_ path: String) -> String {
        normalizedFolder(folderPath(of: path))
    }

    /// `(path as NSString).deletingLastPathComponent` without bridging every
    /// song's path; shapes it does not handle the same way go to NSString.
    fileprivate static func folderPath(of path: String) -> String {
        AlbumArtistInferencePolicy.directory(ofPath: path)
    }

    fileprivate static func normalizedFolder(_ folder: String) -> String {
        guard folder != "." else { return "" }
        return normalized(folder)
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func stableNoise(_ id: String) -> Double {
        let sum = id.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 }
        return Double(sum) / 997.0
    }

    private static func stableDailyNoise(_ id: String, now: Date) -> Double {
        stableDailyNoise(id, day: dailyNoiseDay(now))
    }

    private static func dailyNoiseDay(_ now: Date) -> Int {
        Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
    }

    private static func stableDailyNoise(_ id: String, day: Int) -> Double {
        let mixed = "\(id):\(day)"
        let sum = mixed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }
        return Double(sum) / 997.0
    }
}

/// Global in-memory music library shared across the app
enum LibraryMaintenanceDisposition: Sendable, Equatable {
    case immediate
    /// Long cap (`maximumDeferredMaintenanceInterval`): hours-long backfills.
    case deferred
    /// Short cap (`incrementalScanMaintenanceInterval(lastRebuildSeconds:)`):
    /// a scan's intermediate flushes. They still coalesce, but the visible
    /// catalogue lags the scan by a few seconds — longer only on libraries
    /// whose rebuild itself takes seconds.
    case deferredIncremental
}

enum LibraryReviewKind: String, Codable, CaseIterable, Sendable {
    case song
    case album
    case playlist
    case genre
}

struct LibraryReviewSubject: Codable, Hashable, Sendable {
    let kind: LibraryReviewKind
    let entityID: String

    var storageKey: String { "\(kind.rawValue):\(entityID)" }

    static func song(_ id: String) -> Self { Self(kind: .song, entityID: id) }
    static func album(_ id: String) -> Self { Self(kind: .album, entityID: id) }
    static func playlist(_ id: String) -> Self { Self(kind: .playlist, entityID: id) }
    static func genre(_ id: String) -> Self { Self(kind: .genre, entityID: id) }
}

struct LibraryReview: Codable, Hashable, Identifiable, Sendable {
    let subject: LibraryReviewSubject
    let rating: Int?
    let comment: String
    let updatedAt: Date
    let deletedAt: Date?
    // Numeric clocks retain sub-second edits through ISO8601 snapshots.
    var ratingModifiedAt: TimeInterval? = nil
    var commentModifiedAt: TimeInterval? = nil
    var serverRatingTarget: ServerSongRatingTarget? = nil
    /// 这个评分是扫描时从服务端读回来的(别的客户端打的),不是在本机打的。
    /// 本机一改就清掉;界面据此写「来自 <服务器名>」。
    var ratingFromServer: Bool? = nil

    var id: String { subject.storageKey }
    var isDeleted: Bool { deletedAt != nil }
    var ratingVersion: TimeInterval { ratingModifiedAt ?? updatedAt.timeIntervalSince1970 }
    var commentVersion: TimeInterval { commentModifiedAt ?? updatedAt.timeIntervalSince1970 }
}

struct ServerSongRatingTarget: Codable, Hashable, Sendable {
    enum ItemKind: String, Codable, Sendable {
        case album
    }

    let sourceID: String
    let itemID: String
    let accountFingerprint: String
    /// nil 是歌曲(旧数据都是);专辑时 `itemID` 是服务端的专辑 id。
    var itemKind: ItemKind? = nil

    var isAlbum: Bool { itemKind == .album }

    static func album(serverAlbumID: String, source: MusicSource) -> Self? {
        guard ServerRatingWritebackPolicy.supportsAlbumRatings(source.type), !serverAlbumID.isEmpty else {
            return nil
        }
        return Self(
            sourceID: source.id, itemID: serverAlbumID,
            accountFingerprint: MusicSourceScopeFingerprint.make(for: source, includeSourceID: true),
            itemKind: .album
        )
    }

    static func make(song: Song, source: MusicSource) -> Self? {
        guard ServerRatingWritebackPolicy.supports(source.type), source.id == song.sourceID,
              !song.isCueTrack, !song.isStreamDescriptor,
              let itemID = ServerRatingWritebackPolicy.songID(
                fromConnectorPath: song.filePath, sourceType: source.type
              ) else { return nil }
        return Self(
            sourceID: source.id, itemID: itemID,
            accountFingerprint: MusicSourceScopeFingerprint.make(for: source, includeSourceID: true)
        )
    }
}

enum LibraryReviewPreferences {
    static let enabledKey = "primuse.library.ratingsAndComments.enabled"
    static let maximumCommentLength = 2_000

    static func normalizedRating(_ rating: Int?) -> Int? {
        rating.flatMap { (1...5).contains($0) ? $0 : nil }
    }

    static func normalizedComment(_ comment: String) -> String {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumCommentLength))
    }
}

enum LibraryReviewReconciliationPolicy {
    static func winner(local: LibraryReview, remote: LibraryReview) -> LibraryReview {
        let rating: LibraryReview
        if local.ratingVersion != remote.ratingVersion {
            rating = local.ratingVersion > remote.ratingVersion ? local : remote
        } else {
            // Legacy snapshots may have lost ordering within a second. Prefer
            // an explicit clear over reviving a star from that same second.
            func key(_ review: LibraryReview) -> String {
                "\(review.rating == nil ? 1 : 0):\(review.rating ?? 0):\(review.serverRatingTarget?.accountFingerprint ?? ""):"
                    + "\(review.serverRatingTarget?.itemID ?? "")"
            }
            rating = key(local) >= key(remote) ? local : remote
        }
        let comment: LibraryReview
        if local.commentVersion != remote.commentVersion {
            comment = local.commentVersion > remote.commentVersion ? local : remote
        } else {
            let localKey = "\(local.isDeleted ? 1 : 0):\(local.comment)"
            let remoteKey = "\(remote.isDeleted ? 1 : 0):\(remote.comment)"
            comment = localKey >= remoteKey ? local : remote
        }
        let date = Date(timeIntervalSince1970: max(rating.ratingVersion, comment.commentVersion))
        var merged = LibraryReview(
            subject: local.subject, rating: rating.rating, comment: comment.comment,
            updatedAt: date,
            deletedAt: rating.rating == nil && comment.comment.isEmpty ? date : nil
        )
        merged.ratingModifiedAt = rating.ratingModifiedAt
        merged.commentModifiedAt = comment.commentModifiedAt
        // Preserve independent clocks even when one side came from an old client.
        if rating.ratingVersion != date.timeIntervalSince1970 {
            merged.ratingModifiedAt = rating.ratingVersion
        }
        if comment.commentVersion != date.timeIntervalSince1970 {
            merged.commentModifiedAt = comment.commentVersion
        }
        merged.serverRatingTarget = rating.serverRatingTarget
        merged.ratingFromServer = rating.ratingFromServer
        return merged
    }
}

/// 库的发布状态。`.preparing` 表示可观察模型尚未装载完成:
/// 此时既不落盘, 也不直接应用突变(见 MusicLibrary 的 S1/S2 不变量)。
enum LibraryReadiness: Equatable, Sendable {
    case preparing
    case ready
}

/// 一张专辑 / 一个艺人自己的封面版本, 见 `MusicLibrary.scopedPreferredArtworkSong`。
@MainActor
@Observable
final class LibraryArtworkLookupToken {
    fileprivate(set) var revision = 0
}

/// See `MusicLibrary.visibleSongLookup()`.
struct VisibleSongLookup: Sendable {
    fileprivate let indexByID: [String: Int]
    fileprivate let songs: [Song]

    func song(id: String) -> Song? {
        guard let index = indexByID[id], songs.indices.contains(index) else { return nil }
        let song = songs[index]
        return song.id == id ? song : nil
    }

    func contains(id: String, playableOnly: Bool) -> Bool {
        guard let index = indexByID[id], songs.indices.contains(index),
              songs[index].id == id else { return false }
        return !playableOnly || songs[index].isPlayable
    }
}

@MainActor
@Observable
final class MusicLibrary {
    @ObservationIgnored private var songMutationGeneration: UInt64 = 0
    var songMutationGenerationForMaintenance: UInt64 { songMutationGeneration }
    private var songsReference = LibraryArrayReference<Song>()
    private(set) var songs: [Song] {
        get { songsReference.value }
        set {
            let previous = songsReference
            songsReference = LibraryArrayReference(newValue)
            songMutationGeneration &+= 1
            LibraryArrayReclaimer.release(previous)
        }
    }
    /// Hands the library array to a caller that will put a changed version
    /// back through `songs` in the same main-actor turn. The reference is
    /// emptied so the returned array can be mutated without a copy when no
    /// one else holds it.
    private func takeSongsForInPlaceMutation() -> [Song] {
        let reference = songsReference
        songsReference = LibraryArrayReference()
        return reference.value
    }

    /// `takeSongsForInPlaceMutation` 的补丁版: 没有禁用源时 `visibleSongs` 与
    /// `songs` 是同一份缓冲, 只交出 `songs` 那份仍有两个持有者, 第一次下标
    /// 写入照样整份复制(40 万首约 160MB, 回填封面时每批一次)。这里把可见
    /// 那份一起交出来; 只给成员与顺序都不变的补丁用, 改完经 `songs` 与
    /// `visibleSongs` 两个 setter 放回同一个数组。两步之间不能读这两个属性。
    /// 数组经 `inout` 直接交到调用方的变量里: 先放进元组再取出来, 元组自己
    /// 还握着一份引用, 第一次写入照样整份复制。返回可见数组是否与它共用。
    private func takeLibrarySongsForPatching(into songs: inout [Song]) -> Bool {
        let visibleShared = sharesStorage(visibleSongsReference.value, songsReference.value)
        if visibleShared {
            visibleSongsReference = LibraryArrayReference()
            visibleSongsLookupReference = visibleSongsReference
            materializedSourceSongs.removeAll()
        }
        songs = takeSongsForInPlaceMutation()
        return visibleShared
    }

    private func takeSongIndexForInPlaceMutation() -> [String: Int] {
        var index: [String: Int] = [:]
        swap(&index, &songIndexByID)
        return index
    }

    private var albumsReference = LibraryArrayReference<Album>()
    private(set) var albums: [Album] {
        get { albumsReference.value }
        set {
            let previous = albumsReference
            albumsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
    }
    private var artistsReference = LibraryArrayReference<Artist>()
    private(set) var artists: [Artist] {
        get { artistsReference.value }
        set {
            let previous = artistsReference
            artistsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
    }
    private(set) var artistNameConfiguration: ArtistNameConfiguration
    /// 按文件 ID 寻址的网盘(Google Drive、OneDrive、123…)的歌曲父目录。它们的
    /// `filePath` 是文件 ID, 推不出目录, 专辑艺术家推断原先只能把整个源当成
    /// 没有目录; 父目录来自扫描同步索引, 由 `ScanService` 送进来。
    @ObservationIgnored private(set) var albumArtistFolders: AlbumArtistFolderIndex = .empty
    /// 按「原始艺术家字段 + 源给的艺术家数组」记住解析出来的显示名。列表每一行都要
    /// 问一次 `artistDisplayName(for:)`,而解析要折叠整套分隔符/保护名再逐字比对,
    /// Mac 端一次窗口跳变重建几十行时就是明显的掉帧 (#156)。同一串字段的结果只跟
    /// 命名配置有关,所以配置一换就整个清掉。
    @ObservationIgnored
    private var artistDisplayNameCache: [ArtistDisplayNameCacheKey: ArtistDisplayNameCacheEntry] = [:]
    /// Backing storage that includes soft-deleted entries. UI-facing
    /// `playlists` filters this down.
    private(set) var allPlaylists: [Playlist] = []
    private var artworkOverridesByOwner: [String: LibraryArtworkOverride] = [:]
    private var libraryReviewsBySubject: [String: LibraryReview] = [:]
    /// 专辑 / 艺人简介(含删除留下的墓碑),按记录 id 存。
    private var libraryInsightRecordsByID: [String: LibraryInsightRecord] = [:]
    @ObservationIgnored private var didMigrateLegacyArtistIdentities = false
    @ObservationIgnored
    private var automaticArtistArtworkCatalogsBySource: [String: SourceArtistArtworkCatalog] = [:]
    @ObservationIgnored private var automaticArtistArtworkCatalogRevision: UInt64 = 0
    /// Lightweight invalidation token for album, artist, and playlist artwork surfaces.
    /// It is intentionally separate from song and playlist collection
    /// revisions so choosing a cover does not rebuild unrelated lists.
    private(set) var artworkOverrideRevision: Int = 0
    var allArtworkOverrides: [LibraryArtworkOverride] {
        artworkOverridesByOwner.values.sorted { $0.id < $1.id }
    }
    private(set) var libraryReviewRevision: Int = 0
    var allLibraryReviews: [LibraryReview] {
        libraryReviewsBySubject.values.sorted { $0.id < $1.id }
    }
    private(set) var libraryInsightRevision: Int = 0
    var allLibraryInsightRecords: [LibraryInsightRecord] {
        libraryInsightRecordsByID.values.sorted { $0.id < $1.id }
    }
    private var mirrorPlaylistSuppressions: [String: MirrorPlaylistSuppression] = [:]
    @ObservationIgnored private var disabledSourcePlaylistCache: (
        songs: UInt64, membership: UInt64, sources: Set<String>, hiddenIDs: Set<String>
    )?

    /// 自动隐藏只影响显示；保留歌单和完整成员，重新启用源时即可恢复。
    var playlists: [Playlist] {
        let hidesAppleMusicMirrors = !appleMusicLibrarySyncEnabled
            || !appleMusicSourceInstalled
        let hiddenBySource = playlistIDsHiddenByDisabledSources()
        return allPlaylists.filter { playlist in
            guard !playlist.isDeleted else { return false }
            guard !isMirrorPlaylistSuppressed(playlist.id) else { return false }
            guard !hiddenBySource.contains(playlist.id) else { return false }
            return !hidesAppleMusicMirrors
                || !AppleMusicLibraryIdentity.isMirrorPlaylist(playlist.id)
        }
    }

    private func playlistIDsHiddenByDisabledSources() -> Set<String> {
        guard !disabledSourceIDs.isEmpty else { return [] }
        // 缓存命中时也订阅成员与歌曲变化，避免仅切换源后才刷新可见性。
        _ = songsReference
        _ = playlistSongIDs
        if let cached = disabledSourcePlaylistCache,
           cached.songs == songMutationGeneration,
           cached.membership == playlistMembershipRevision,
           cached.sources == disabledSourceIDs {
            return cached.hiddenIDs
        }
        var hiddenIDs = Set<String>()
        for playlist in allPlaylists {
            let members = playlistSongIDs[playlist.id] ?? []
            let sourceID: String?
            if let firstID = members.first, let index = songIndexByID[firstID] {
                sourceID = songs[index].sourceID
            } else if members.isEmpty {
                sourceID = MirrorPlaylistSuppressionPolicy.key(forPlaylistID: playlist.id)?.sourceID
            } else {
                sourceID = nil
            }
            guard let sourceID, disabledSourceIDs.contains(sourceID) else { continue }
            // 未解析成员不能证明同源；混合来源和待匹配歌单继续保留。
            if members.allSatisfy({ id in
                guard let index = songIndexByID[id] else { return false }
                return songs[index].sourceID == sourceID
            }) {
                hiddenIDs.insert(playlist.id)
            }
        }
        disabledSourcePlaylistCache = (
            songMutationGeneration, playlistMembershipRevision, disabledSourceIDs, hiddenIDs
        )
        return hiddenIDs
    }
    /// Soft-deleted playlists, newest deletion first. Drives the "Recently
    /// Deleted" recovery panel.
    var recentlyDeletedPlaylists: [Playlist] {
        allPlaylists
            .filter { $0.isDeleted && !$0.isPurged }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }
    var hiddenMirrorPlaylists: [MirrorPlaylistSuppression] {
        mirrorPlaylistSuppressions.values.sorted { $0.hiddenAt > $1.hiddenAt }
    }

    func hiddenMirrorPlaylists(forSourceID sourceID: String) -> [MirrorPlaylistSuppression] {
        hiddenMirrorPlaylists.filter { $0.key.sourceID == sourceID }
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
    private var playlistSongIDs: [String: [String]] = [:] {
        didSet { playlistMembershipRevision &+= 1 }
    }
    /// `playlistSongIDs` 每改一次就加一。`isLiked(songID:)` 靶着它决定要不要重建
    /// 「我喜欢」的 Set —— 曲目表本身是有序数组 (顺序要保住),但列表每行都要判一次
    /// 喜欢没喜欢,按数组 `contains` 走是 O(喜欢数) 的线性扫描 (#156)。
    @ObservationIgnored private var playlistMembershipRevision: UInt64 = 0
    @ObservationIgnored private var likedSongIDLookup: (revision: UInt64, ids: Set<String>)?
    /// 每个歌单上一次与云端一致时的曲目表(远端套用后、合并后、本机保存成功后都会
    /// 更新)。冲突合并拿它当三方合并的基线: 基线里有、一边没有的, 就是那一边删掉的。
    private var playlistSyncBaseSongIDs: [String: [String]] = [:]
    /// Changes when playlist metadata, membership, or Apple Music mirror
    /// visibility changes. Folder projections observe this separately from the
    /// song collection because a playlist rename does not mutate any Song.
    private(set) var playlistCollectionRevision: Int = 0
    private var recentPlaybackSongIDs: [String] = []
    /// Identities pulled from CloudKit that didn't resolve to a local
    /// `Song.id` at apply time — usually because the receiving device
    /// hasn't scanned the relevant cloud source yet. Persisted across
    /// launches and re-attempted whenever the songs collection mutates,
    /// so a freshly-synced device fills in playlist entries as its scan
    /// catches up. Pruned after 30 days to bound the persistent state.
    private var pendingPlaylistIdentities: [String: [PendingSongIdentity]] = [:]
    private var pendingHistoryIdentities: [PendingSongIdentity] = []
    @ObservationIgnored private var pendingIdentityFlushTask: Task<Void, Never>?
    /// 歌单里置灰的占位条目(见 `PlaylistPendingEntry`), 键是占位 id —— 也就是
    /// `playlistSongIDs` 里占着位置的那个元素。和上面的 pending identities 不同:
    /// 它们在界面上看得见、保持原来的位置, 也不过期, 一直等到曲库里有了为止。
    private(set) var playlistPendingEntries: [String: PlaylistPendingEntry] = [:]
    @ObservationIgnored private var playlistPendingResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var playlistPendingResolutionGeneration: UInt64 = 0
    @ObservationIgnored let playlistEntryMatchKeyCache = PlaylistEntryMatchKeyCache()
    #if os(iOS)
    @ObservationIgnored private var allowsPendingIdentityFlush = false
    #else
    @ObservationIgnored private var allowsPendingIdentityFlush = true
    #endif
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

    /// 每条墓碑的证据: 什么时候删的、源文件到底删了没有、删除那一刻这行的
    /// 签名, 以及撤销时刻。远端源问不到"文件此刻在不在磁盘上", 只能靠比签名
    /// 判断"同一路径上现在这一份是不是另一个文件"。
    ///
    /// 本版本之前产生的墓碑在这里没有记录, 它们退化成「无证据的旧墓碑」——
    /// 永不因扫描撤销, 与历史行为一致。没有任何界面读它, 所以不参与观察。
    @ObservationIgnored
    private(set) var deletedSongIdentityDetails: [String: LibrarySongTombstoneDetail] = [:]

    /// Identity keys the user removed from *this device's* library only.
    ///
    /// `deletedSongIdentities` is part of the portable snapshot and is unioned
    /// across devices by iCloud/Apple TV snapshot sync, so writing a tombstone
    /// there turns a local clean-up into a global deletion. When the source
    /// file itself must survive (a WebDAV server that refuses DELETE), the
    /// identity goes here instead: same shape (`"<accountID-or-sourceID>:<filePath>"`),
    /// but persisted in a separate device-local file that is never encoded
    /// into `Snapshot`, uploaded to CloudKit, or put into the Apple TV payload.
    private(set) var deviceLocalExcludedSongIdentities: Set<String> = []
    @ObservationIgnored private var deviceLocalExcludedSongsByID: [String: Song] = [:]
    /// Why each retained row was removed, so the recovery screen can explain an
    /// entry long after the deletion attempt that produced it.
    @ObservationIgnored
    private var deviceLocalRemovalMetadataByID: [String: SongLocalRemovalMetadata] = [:]

    /// Sync retains the original catalogue even when this device hides a row.
    /// Ordinary playback and UI lookups must continue to use `song(id:)`.
    func songForSynchronization(id: String) -> Song? {
        if let song = song(id: id) { return song }
        guard let retained = deviceLocalExcludedSongsByID[id],
              !deletedSongIdentities.contains(identityKey(for: retained)) else { return nil }
        return retained
    }

    /// Plug-in to translate a `Song.sourceID` (mount UUID) into its
    /// canonical identity prefix — usually the source's `cloudAccountID`
    /// for OAuth mounts, falling back to the sourceID itself for
    /// local/NAS sources where there's no account concept.
    /// Set by `AppServices` at startup; nil-safe for tests.
    var sourceIdentityResolver: ((_ sourceID: String) -> String?)? {
        didSet {
            // 换了 resolver, 之前解析不出来的云账号身份可能就能解析出来了。
            artworkSongIDResolutions.removeAll(keepingCapacity: true)
        }
    }

    /// 回答"这些歌属于本机文件源, 而且它们的文件此刻确实在磁盘上吗"。
    /// 准入判定只在命中全局墓碑时才问它, 所以常态(库里没有删除记录)是零
    /// 开销 —— `hasAdmissionFilters` 先短路了整批。另一个调用点是删除的那
    /// 一刻(`recordExclusionsForRetainedSourceFiles`), 用来认出"源文件是
    /// 故意保留的"那一种删除。
    ///
    /// 签名收的是一批而不是一首: 本机源的根目录要么是沙箱里的目录、要么是
    /// 一份安全域书签, 解析一次就够整批用, 按源分组后只解析一次比逐首解析
    /// 便宜得多。返回的是文件确实存在的那些 `song.id`。
    ///
    /// nil 时保持历史行为(墓碑一律拦下): 离主线程的装载路径和 tvOS 拿不到
    /// 源目录, 而它们本来就不做墓碑准入过滤, 见 `StartupStorage`。
    /// 由 `AppServices` 在安装 `sourceIdentityResolver` 的地方一并装上。
    @ObservationIgnored
    var deviceLocalFilePresenceProbe: ((_ candidates: [Song]) -> Set<String>)?

    /// 封面覆盖解析的记忆化结果, 按 owner 存一条。解析 `.selectedSong` 覆盖时
    /// 的慢路径 (跨设备挂载导致 songID 不同) 要整库扫一遍, 卡片 body 却会随
    /// `songReplacementToken` 在整轮回填里反复求值。换代后怎么续用见
    /// `LibraryArtworkSongResolutionCachePolicy`; 失败结果同样缓存, 慢的正是失败那一支。
    @ObservationIgnored
    private var artworkSongIDResolutions: [String: LibraryArtworkSongResolutionCachePolicy.Entry] = [:]

    /// AppServices wires supported server-favorite persistence here. Local
    /// liked state is updated synchronously for responsive UI; the handler
    /// confirms it with the server and can reconcile or roll it back without
    /// triggering a second mutation.
    @ObservationIgnored
    var likedStateMutationHandler: ((_ song: Song, _ previous: Bool, _ desired: Bool) -> Void)?
    private(set) var serverFavoriteErrorMessage: String?
    @ObservationIgnored var serverRatingTargetProvider: ((Song) -> ServerSongRatingTarget?)?
    @ObservationIgnored var ratingStateMutationHandler: ((LibraryReview) -> Void)?
    /// 整张专辑 / 一位艺人的全部歌曲改成了同一个新名字（标签编辑、刮削）时报出来，
    /// 专辑 / 艺人的「喜欢」据此跟过去（见 `LibraryFavoritesStore.applyCollectionRenames`）。
    @ObservationIgnored var collectionRenameHandler: (([CollectionRename]) -> Void)?
    private(set) var serverRatingErrorMessage: String?

    var serverRatingStorageKey: String {
        // The data container can move during an app update; its absolute path
        // must not become part of a device's pending-write identity.
        "primuse.server-ratings.v1." + Self.hashID(snapshotURL.deletingLastPathComponent().lastPathComponent)
    }

    private func identityKey(for song: Song) -> String {
        LibrarySongAdmissionPolicy.identityKey(
            prefix: sourceIdentityResolver?(song.sourceID),
            sourceID: song.sourceID,
            filePath: song.filePath
        )
    }

    /// A song is kept out of the library when the user tombstoned it globally
    /// or excluded it on this device only. Scans, incremental flushes and
    /// imported snapshots all have to honour both sets.
    private func isBlockedFromLibrary(_ song: Song) -> Bool {
        deletedSongIdentities.contains(identityKey(for: song))
            || isExcludedOnThisDevice(song)
    }

    /// 批量准入。`prefixes` 在一批的开头按源解析一次, 于是一首歌只构造一次
    /// 身份键, 也不再为每一行在源表里线性找一遍账号 ID。拦下与否的判定与
    /// `isBlockedFromLibrary(_:)` 完全一致; 多出来的只是"被哪本账拦下的",
    /// 因为全局墓碑可以在文件回到磁盘上时撤销, 而「从本机移除」不行。
    private func admissionVerdict(
        _ song: Song,
        prefixes: [String: String]
    ) -> LibrarySongAdmissionPolicy.Verdict {
        LibrarySongAdmissionPolicy.verdict(
            sourceID: song.sourceID,
            filePath: song.filePath,
            prefixes: prefixes,
            tombstones: deletedSongIdentities,
            deviceExclusions: deviceLocalExcludedSongIdentities
        )
    }

    /// Exposed for callers (and tests) that need to know whether a row was
    /// removed from this device without deleting the underlying file.
    ///
    /// Both key shapes are accepted on purpose: the ledger records
    /// `identityKey(for:)`, whose prefix is the resolved account identity when
    /// one exists, but `loadSnapshot` runs from `init` — before AppServices
    /// installs `sourceIdentityResolver` — so at load time the same song
    /// computes the raw `"<sourceID>:<filePath>"` form. Matching either one
    /// keeps an exclusion effective regardless of which side of that
    /// load-order window recorded it.
    func isExcludedOnThisDevice(_ song: Song) -> Bool {
        deviceLocalExcludedSongIdentities.contains(identityKey(for: song))
            || deviceLocalExcludedSongIdentities.contains("\(song.sourceID):\(song.filePath)")
    }
    private(set) var disabledSourceIDs: Set<String> = []
    /// 每次设置禁用源集合都前进; 后台准备的可见缓存据此判断自己是否已被更新的请求取代。
    @ObservationIgnored private var disabledSourceIDsRequestGeneration: UInt64 = 0
    /// Mirrors the Apple Music library-sync preference as observable state.
    /// Reading UserDefaults directly from `playlists` would not invalidate
    /// SwiftUI views when the macOS settings toggle changes.
    private(set) var appleMusicLibrarySyncEnabled =
        AppleMusicLibraryPreferences.syncUserLibraryEnabled
    /// Apple Music 现在跟其它音乐源一样由用户添加/移除。移除之后它的镜像歌单
    /// 在被清理线程真正删掉之前还留在集合里,这个标记让它们当场从资料库里消失。
    /// 默认 true:没有源列表可读的目标(tvOS 共享这份 MusicLibrary)保持原行为。
    private(set) var appleMusicSourceInstalled = true

    /// Cached filtered views — rebuilt only when songs/disabled state change
    private var visibleSongsReference = LibraryArrayReference<Song>()
    /// 每次可见缓存发布都会前进。`songMutationGeneration` 只覆盖 `songs`,
    /// 而 applyPreparedVisibleCache / publishStableMembershipReplacements 等
    /// 路径可以在 `songs` 不变的情况下换掉 visibleSongs 与它的索引; 离主线程
    /// 准备好的补丁必须能看出这一点, 否则会用旧副本盖掉更新的可见缓存。
    @ObservationIgnored private var visibleCacheGeneration: UInt64 = 0
    private(set) var visibleSongs: [Song] {
        get { visibleSongsReference.value }
        set {
            let previous = visibleSongsReference
            visibleSongsReference = LibraryArrayReference(newValue)
            visibleSongsLookupReference = visibleSongsReference
            materializedSourceSongs.removeAll()
            visibleCacheGeneration &+= 1
            LibraryArrayReclaimer.release(previous)
            // 可见歌曲换了一份, 查找表里的首选封面歌曲可能跟着换了内容。
            scheduleArtworkLookupTokenRefresh()
        }
    }
    private var musicSongsReference = LibraryArrayReference<Song>()
    /// `visibleSongs` minus the spoken-word items. The songs list, and every
    /// music surface built from it, reads this so an audiobook or a long
    /// 相声 series cannot bury the library. It is the same array as
    /// `visibleSongs` when nothing is classified as spoken word.
    private(set) var musicSongs: [Song] {
        get {
            // Reading the reference keeps the Observation dependency exactly
            // as before; when nothing is spoken word the songs come from the
            // visible array, so an in-place patch of it never leaves the
            // pre-patch library alive here as one more full copy.
            let reference = musicSongsReference
            return musicSongsSharesVisibleSongs ? visibleSongsLookupReference.value : reference.value
        }
        set {
            let previous = musicSongsReference
            musicSongsReference = LibraryArrayReference(newValue)
            musicSongsRevision &+= 1
            LibraryArrayReclaimer.release(previous)
        }
    }
    /// 每次换 `musicSongs` 都前进; 推荐引擎按它复用整库特征索引。
    @ObservationIgnored private(set) var musicSongsRevision: UInt64 = 0
    /// Set at each publish: the music songs are the visible songs.
    @ObservationIgnored private var musicSongsSharesVisibleSongs = false
    /// 扫描分批入库期间共用: 新存进来的歌的重复字段(源 ID、专辑/歌手名与 ID、
    /// 流派、封面文件名、拼音…)和前几批并成一份。装载时 `loadSongs` 也这么做,
    /// 没有这一步时首轮扫描几十万首要到下次启动才省下这一半内存。
    @ObservationIgnored private var incomingSongInterner = SongStringInterner()
    private var spokenWordSongsReference = LibraryArrayReference<Song>()
    private(set) var spokenWordContentRevision: UInt64 = 0
    /// The spoken-word items, in the same order they hold in `visibleSongs`.
    private(set) var spokenWordSongs: [Song] {
        get { spokenWordSongsReference.value }
        set {
            let previous = spokenWordSongsReference
            spokenWordSongsReference = LibraryArrayReference(newValue)
            spokenWordContentRevision &+= 1
            LibraryArrayReclaimer.release(previous)
        }
    }
    @ObservationIgnored private(set) var spokenWordSongIDs: Set<String> = [] {
        didSet {
            // Music rankings and stats read the split from the play history.
            if PlayHistoryStore.shared.spokenWordSongIDs != spokenWordSongIDs {
                PlayHistoryStore.shared.spokenWordSongIDs = spokenWordSongIDs
            }
            if oldValue != spokenWordSongIDs {
                spokenWordClassificationRevision &+= 1
            }
        }
    }
    /// 有声 / 音乐的分流真的变了才加一。改目录标签、别的设备改分类时,可见歌曲的
    /// 顺序一首没动,`visibleSongCollectionRevision` 不会变;按修订号缓存「音乐」
    /// 列表的读者(电视的查找表、随机队列)靠这一个失效。
    private(set) var spokenWordClassificationRevision = 0

    /// The listener's own podcast files — downloaded episodes in a music
    /// source, marked or tagged as podcasts. Played the spoken-word way, kept
    /// off the book shelf, shown with the podcasts.
    private(set) var localPodcastSongs: [Song] = [] {
        didSet { localPodcastContentRevision &+= 1 }
    }
    private(set) var localPodcastContentRevision: UInt64 = 0
    /// Local podcast item id → the show it is grouped into, the way
    /// `spokenWordBookIDs` does it for books.
    @ObservationIgnored private(set) var localPodcastBookIDs: [String: String] = [:]
    /// Spoken-word item id → the id of the book the shelf puts it in.
    @ObservationIgnored private(set) var spokenWordBookIDs: [String: String] = [:]
    /// How many books the spoken-word items make.
    private(set) var spokenWordBookCount = 0
    private var visibleAlbumsReference = LibraryArrayReference<Album>()
    private(set) var visibleAlbums: [Album] {
        get { visibleAlbumsReference.value }
        set {
            let previous = visibleAlbumsReference
            visibleAlbumsReference = LibraryArrayReference(newValue)
            visibleAlbumsRevision &+= 1
            LibraryArrayReclaimer.release(previous)
        }
    }
    /// 每换上一份 `visibleAlbums` 加一。要把整库专辑筛一遍的视图拿它当缓存键,
    /// 一次重绘里问好几回也只筛一遍。
    private(set) var visibleAlbumsRevision = 0
    private var visibleArtistsReference = LibraryArrayReference<Artist>()
    private(set) var visibleArtists: [Artist] {
        get { visibleArtistsReference.value }
        set {
            let previous = visibleArtistsReference
            visibleArtistsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
            scheduleArtworkLookupTokenRefresh()
        }
    }
    /// 资料库艺术家页切到「专辑艺术家」时列的人，与 `visibleArtists` 同一次发布。
    private var visibleAlbumArtistsReference = LibraryArrayReference<Artist>()
    private(set) var visibleAlbumArtists: [Artist] {
        get { visibleAlbumArtistsReference.value }
        set {
            let previous = visibleAlbumArtistsReference
            visibleAlbumArtistsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
    }
    private var visibleGenresReference = LibraryArrayReference<LibraryGenre>()
    private(set) var visibleGenres: [LibraryGenre] {
        get { visibleGenresReference.value }
        set {
            let previous = visibleGenresReference
            visibleGenresReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
    }
    @ObservationIgnored private var songIndexByID: [String: Int] = [:]
    @ObservationIgnored private var visibleSongIndexByID: [String: Int] = [:]
    /// The same array object as `visibleSongs`, read without registering an
    /// Observation dependency. Lookups by ID go through `visibleSongIndexByID`
    /// into it; a second dictionary holding every song again cost a full copy
    /// of the library (several hundred MB at a few hundred thousand songs).
    @ObservationIgnored private var visibleSongsLookupReference = LibraryArrayReference<Song>()
    @ObservationIgnored private var visibleAlbumByID: [String: Album] = [:]
    @ObservationIgnored private var visibleArtistByID: [String: Artist] = [:]
    @ObservationIgnored private var visibleAlbumArtistByID: [String: Artist] = [:]
    /// 只当过专辑艺人的人（「群星」）→ 名下专辑。他们没有自己署名的歌，艺人页、右键播放、
    /// CarPlay 与电视取歌都经 `songs(forArtist:)`，从这些专辑里取。
    @ObservationIgnored private var albumIDsByAlbumOnlyArtistID: [String: [String]] = [:]
    /// 上面这些人的歌，第一次有人要时才整库找一遍；每次发布可见缓存时清空。
    @ObservationIgnored private var albumOnlyArtistSongIDsCache: [String: [String]] = [:]
    /// Artist detail bodies can ask for the same slice several times per frame.
    /// Keep stable IDs here and resolve through `lookupVisibleSong` so lightweight
    /// lyrics/artwork patches remain current without rescanning or reparsing the library.
    @ObservationIgnored private var visibleSongIDsByArtistID: [String: [String]] = [:]
    @ObservationIgnored private var visibleSongIDsByGenreID: [String: [String]] = [:]
    @ObservationIgnored private var visibleAlbumIDsByGenreID: [String: [String]] = [:]
    /// Where each source's songs sit in `visibleSongs`, in library order.
    /// Only positions are kept: a source holding the whole library used to be
    /// one more full copy of it, and every artwork or lyrics patch copied the
    /// patched source's array again. Pages that want a source's songs read
    /// them through `sourceSongs(_:)`.
    @ObservationIgnored private var visibleSongPositionsBySourceID: [String: [Int]] = [:]
    /// Sources with at least one visible song that cannot be played.
    @ObservationIgnored private var sourceIDsWithUnplayableSongs: Set<String> = []
    /// Per-source lists built for one visible array; dropped whenever it changes.
    @ObservationIgnored private var materializedSourceSongs: [String: [Song]] = [:]
    @ObservationIgnored private var sourceSongListStates: [String: LibrarySourceSongListState] = [:]
    /// 哪些源此刻至少有一首能播的歌。来源页只要这个判定, 可上面那份缓存不被
    /// 观察, 卡片原本只能顺手读一下整库引用才收得到更新 —— 于是扫描每 flush
    /// 一次, 整张来源列表连同长按菜单、滑动操作全部重建。这份集合只在结果真的
    /// 变了才写, 一轮扫描里通常只翻一次。
    private(set) var sourceIDsWithPlayableSongs: Set<String> = []
    /// Sidebar counters need all visible songs, not just playable ones. Keeping
    /// counts here avoids one full-library filter per source on every sidebar
    /// body evaluation.
    @ObservationIgnored private var visibleSongCountBySourceID: [String: Int] = [:]
    /// Device-local source counts include disabled sources as well. Keep the
    /// aggregate beside the other immutable snapshot lookups so source-card
    /// reconciliation never groups the complete library on the main actor.
    @ObservationIgnored private var songCountBySourceID: [String: Int] = [:]
    /// Album grids ask for one deterministic song fallback per card. Keep the
    /// selection beside the other visible lookups so scrolling never scans and
    /// sorts the complete library from a card body.
    @ObservationIgnored private var preferredArtworkSongIDByAlbumID: [String: String] = [:]
    /// Artist rows use the same O(1) fallback so an artist without dedicated
    /// artwork can still show representative embedded or album artwork.
    @ObservationIgnored private var preferredArtworkSongIDByArtistID: [String: String] = [:]

    /// 一首歌的旁挂资源补丁。`nil` = 不改这一项; MV 的"清空"是有意义的写入,
    /// 所以额外用 `updatesMusicVideo` 区分"不改"与"改成 nil"。
    private struct PendingAssetReferencePatch {
        var coverRef: String? = nil
        var lyricsRef: String? = nil
        var musicVideoPath: String? = nil
        var updatesMusicVideo: Bool = false

        mutating func merge(_ other: PendingAssetReferencePatch) {
            if let coverRef = other.coverRef { self.coverRef = coverRef }
            if let lyricsRef = other.lyricsRef { self.lyricsRef = lyricsRef }
            if other.updatesMusicVideo {
                musicVideoPath = other.musicVideoPath
                updatesMusicVideo = true
            }
        }
    }

    fileprivate struct PreparedVisibleCache: Sendable {
        let spokenWordClassification: SpokenWordClassificationInputs
        let songs: [Song]
        /// `songs` without the spoken-word items, which is what the music
        /// surfaces (songs list, albums, artists, genres) are built from. It
        /// is the same array instance when the library holds no spoken word.
        let musicSongs: [Song]
        /// The book shelf's items: spoken word that is not a podcast.
        let spokenWordSongs: [Song]
        /// Everything played the spoken-word way — books and the listener's own
        /// podcast files — which is what the music lists leave out.
        let spokenWordSongIDs: Set<String>
        /// The listener's own podcast files (`ListeningContentKind.podcast`).
        let podcastSongs: [Song]
        /// Local podcast item id → show id, grouped like books.
        let podcastBookIDs: [String: String]
        /// Spoken-word item id → book id, as the bookshelf groups them.
        let spokenWordBookIDs: [String: String]
        let albums: [Album]
        let artists: [Artist]
        let albumArtistIndex: AlbumArtistIndex
        let albumArtistByID: [String: Artist]
        let genres: [LibraryGenre]
        let allSongIndexByID: [String: Int]
        let songIndexByID: [String: Int]
        let albumByID: [String: Album]
        let artistByID: [String: Artist]
        let songIDsByArtistID: [String: [String]]
        let songIDsByGenreID: [String: [String]]
        let albumIDsByGenreID: [String: [String]]
        let songPositionsBySourceID: [String: [Int]]
        let unplayableSourceIDs: Set<String>
        let countBySourceID: [String: Int]
        let allCountBySourceID: [String: Int]
        let preferredArtworkSongIDByAlbumID: [String: String]
        let preferredArtworkSongIDByArtistID: [String: String]
        let orderedIDsChanged: Bool
    }
    /// Changes only when the ordered set of visible song IDs changes. Views
    /// that cache a sorted song list observe this lightweight counter instead
    /// of comparing `[Song]`; a derived `Song` equality also walks lyricsText,
    /// which made a 10K-song library block AttributeGraph for several seconds.
    private(set) var visibleSongCollectionRevision: Int = 0
    private(set) var albumArtworkLookupRevision: Int = 0 {
        didSet { scheduleArtworkLookupTokenRefresh() }
    }
    private(set) var sourceSyncCompletionRevision: Int = 0
    private(set) var searchRevision: Int = 0
    /// Whole-library Spotlight snapshots follow this explicit checkpoint,
    /// rather than every row-level replacement token.
    private(set) var spotlightIndexRevision: Int = 0
    /// Lyrics cache files are searched directly by `LibrarySearchWorker`.
    /// Keep their invalidation separate from structural library revisions so
    /// each scraped lyric does not refresh Home and other whole-library views.
    private(set) var lyricsSearchRevision: Int = 0

    private let snapshotURL: URL
    private let backupSnapshotURL: URL
    private let startupCacheURL: URL
    private let derivedIndexCacheURL: URL
    private let playlistDurabilityURL: URL
    /// Device-local song exclusions. Deliberately a separate file from
    /// `snapshotURL`: nothing in the iCloud/Apple TV transfer path reads or
    /// copies it, so the exclusion cannot leak to another device.
    private let deviceLocalExclusionURL: URL
    private let playlistSyncWriterID: String
    /// Canonical device-local song rows. JSON is retained as an interoperable
    /// iCloud/Apple TV snapshot, but routine scan/backfill writes go here.
    /// `var` 而非 `let`: `.preparing` 构造的库在 `publish(_:)` 时装入
    /// 准备阶段已打开的存储句柄。同步路径下 init 后不再变化。
    @ObservationIgnored private var songStore: IncrementalSongStore?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    @ObservationIgnored private var persistenceBlockedByCorruption = false
    @ObservationIgnored private var derivedIndexSignature: String?
    /// 2: 启动缓存不再带歌曲数组, 歌曲总是从 SQLite 读。1 是带整库歌曲的旧格式,
    /// 仍然读得懂, 读到后按 2 重写一次。
    private nonisolated static let startupCacheFormatVersion = 2
    private nonisolated static let legacyStartupCacheFormatVersion = 1
    private nonisolated static let loadedSongMigrationVersion = 10

    // MARK: - Readiness

    /// 可观察的发布状态。同步启动路径在 `loadSnapshot` 末尾即置为 `.ready`,
    /// 因此当前行为与历史版本完全一致(init 返回前库已就绪)。
    private(set) var readiness: LibraryReadiness = .preparing
    var isReady: Bool { readiness == .ready }
    @ObservationIgnored private var readinessContinuations: [CheckedContinuation<Void, Never>] = []
    /// `whenReady(timeout:)` 的等待者。按 id 登记, 这样超时的一方能只摘掉
    /// 自己那一条, 不影响其它等待者。
    @ObservationIgnored private var boundedReadinessContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var readinessHandlers: [@MainActor () -> Void] = []
    /// S2: `.preparing` 期间进入的顶层突变按 FIFO 排队, 发布后原样重放。
    ///
    /// 规则: **每一个会改写可观察 / 持久化状态的顶层入口都必须排队**。发布时
    /// `loadSnapshot` 用准备结果整体覆盖 songs / 歌单成员 / 智能歌单 / 播放历史 /
    /// 评分评论 / 封面覆盖 / 镜像隐藏 / 同步墓碑 / 设备本地排除, 没排队的突变会被
    /// 这次拷回悄悄抹掉, 紧接着的补写再把丢失固化到磁盘上。例外只有三类:
    ///
    /// 1. **配置 setter 在发布时对账, 不排队**: `updateDisabledSourceIDs` /
    ///    `updateArtistNameConfiguration` 是可见缓存与派生索引的计算依据, 准备结果
    ///    正是用存储里的值算出来的。准备期间只记录最新值, 拷回之后再用普通 setter
    ///    重放差异, 于是重建可见缓存 / bump `spotlightIndexRevision` 的路径与
    ///    "启动之后用户改设置"完全一致;
    /// 2. `publish(_:)` 与 `reloadFromDisk()` 本身就是装载入口, 不能排进自己的队列;
    /// 3. 不在拷回范围内的瞬时信号立即生效, 不会丢: `presentServerFavoriteError` /
    ///    `dismissServerFavoriteError` / `sourceSyncDidComplete` /
    ///    `updateAppleMusicLibrarySyncEnabled` / `suspendPendingIdentityResolution` /
    ///    `resumePendingIdentityResolution` / 场景切换静默与派生维护调度。
    @ObservationIgnored private var deferredMutations: [@MainActor () -> Void] = []
    /// S2 例外 1: `.preparing` 期间记录下来的配置最新值, 发布后对账用。
    @ObservationIgnored private var preparingDisabledSourceIDs: Set<String>?
    @ObservationIgnored private var preparingArtistNameConfiguration: ArtistNameConfiguration?
    @ObservationIgnored private var preparingAlbumArtistFolders: AlbumArtistFolderIndex?
    @ObservationIgnored private var preparingContentClassificationRefresh = false
    @ObservationIgnored private var visibleContentClassification: SpokenWordClassificationInputs = .empty
    /// S1: `.preparing` 期间被拦截的持久化请求, 发布后各补一次。
    @ObservationIgnored private var deferredPortableSnapshotPersistRequested = false
    @ObservationIgnored private var deferredStartupCacheWriteRequested = false
    @ObservationIgnored private var deferredDerivedIndexCacheWriteRequested = false
    @ObservationIgnored private var deferredPlaylistDurabilityWriteRequested = false
    @ObservationIgnored private var deferredDeviceLocalExclusionWriteRequested = false

    /// 已就绪时立即返回; 否则挂起到发布完成。
    func whenReady() async {
        guard readiness != .ready else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if readiness == .ready {
                continuation.resume()
            } else {
                readinessContinuations.append(continuation)
            }
        }
    }

    /// 有界等待: 就绪与超时哪个先到都立刻返回, 输的一方当场清掉 ——
    /// 就绪先到时取消还在睡的计时任务, 超时先到时把自己这条续体从登记表里
    /// 摘走(不连累其它等待者)。返回值就是返回时刻的 `isReady`。
    ///
    /// SiriKit 只给约 10 秒预算, 所以调用方用它代替无界的 `whenReady()`:
    /// 超时后按今天的代码路径继续, 空库自然落到既有的"没找到"应答。
    func whenReady(timeout: Duration) async -> Bool {
        guard readiness != .ready else { return true }
        let id = UUID()
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeBoundedReadinessWaiter(id: id)
        }
        // 取消是第三个"先到者": 调用方的任务(Siri 的 Task、视图的 .task)被
        // 拆掉时必须当场摘掉自己这条续体并停掉计时任务, 否则被取消的调用方
        // 还要白等满整个 timeout。两个方向都要覆盖 —— 登记之后才取消走
        // `onCancel`, 登记之前就已取消则由闭包里的 `Task.isCancelled` 兜住。
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if readiness == .ready || Task.isCancelled {
                    continuation.resume()
                } else {
                    boundedReadinessContinuations[id] = continuation
                }
            }
        } onCancel: {
            // 弱引用在这条主 actor 跳转里现取: 取消处理器本身不隔离, 若由它
            // 捕获再交给主 actor 闭包, 就是把任务隔离的库送进另一个隔离域。
            Task { @MainActor [weak self] in
                self?.resumeBoundedReadinessWaiter(id: id)
            }
        }
        timer.cancel()
        return isReady
    }

    /// 超时侧的唤醒。已经被发布唤醒过就什么都不做(续体只能 resume 一次)。
    private func resumeBoundedReadinessWaiter(id: UUID) {
        guard let continuation = boundedReadinessContinuations.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    /// 库在等待者还挂着的时候被释放(测试里只 `makePreparing` 不 `publish`,
    /// 或者一次被丢弃的准备): 续体不能就这么丢掉 —— `CheckedContinuation`
    /// 会报 misuse, 调用方则永远挂在那里。`deinit` 对 `self` 是独占访问,
    /// 这里只搬走两张续体表并逐个唤醒; `onReady` 回调不必再跑, 它们要看的
    /// 库已经没了。
    deinit {
        let unbounded = readinessContinuations
        readinessContinuations = []
        let bounded = boundedReadinessContinuations
        boundedReadinessContinuations = [:]
        let snapshotWriteWaiters = externalSnapshotWriteWaiters
        externalSnapshotWriteWaiters = []
        for continuation in unbounded { continuation.resume() }
        for continuation in bounded.values { continuation.resume() }
        for continuation in snapshotWriteWaiters { continuation.resume() }
    }

    /// 已就绪时立即执行; 否则按注册顺序在发布后执行一次。
    func onReady(_ handler: @escaping @MainActor () -> Void) {
        if readiness == .ready {
            handler()
        } else {
            readinessHandlers.append(handler)
        }
    }

    /// S1/S2 的统一判定入口。
    private var isPreparing: Bool { readiness == .preparing }

    /// 顶层突变入口的排队助手。返回 `true` 表示调用方应立刻返回,
    /// 该次调用已被记录, 发布后按顺序重放。
    private func deferringUntilReady(_ work: @escaping @MainActor () -> Void) -> Bool {
        guard isPreparing else { return false }
        deferredMutations.append(work)
        return true
    }

    /// 发布步骤第 1 步: 只翻转状态, 不做任何补写。
    /// 在可观察状态写入之后、耐久写入之前调用, 这样 `loadSnapshot` 末尾
    /// 那几项落盘与历史版本一样正常执行(它们不会再被 S1 拦下)。
    /// 被推迟的持久化必须等到排队突变重放完成后才补, 否则会写出一份
    /// 缺少这些突变的快照。
    private func markReadyBeforeDurableWrites() {
        guard isPreparing else { return }
        readiness = .ready
    }

    /// 发布步骤第 3 步: 按 FIFO 重放 `.preparing` 期间排队的顶层突变 (S2)。
    /// 必须在 G5 的耐久写入之后、S1 的补写之前, 这样补写看到的是
    /// "已发布的行 + 排队突变" 的最终状态。
    private func replayDeferredMutations() {
        while !deferredMutations.isEmpty {
            let pending = deferredMutations
            deferredMutations.removeAll(keepingCapacity: false)
            for work in pending { work() }
        }
    }

    /// 发布步骤第 2.5 步: 配置对账 (S2 例外 1)。准备期间记录的最新配置在这里
    /// 通过普通 setter 重放一次差异 —— 拷回已经把存储里的值装进来了, 所以
    /// 这一步要么什么都不做, 要么走出与"启动后改设置"完全相同的重建路径。
    /// 必须排在排队突变重放之前: 突变看到的应当是最终配置下的可见缓存。
    private func reconcilePreparingConfiguration() {
        if let ids = preparingDisabledSourceIDs {
            preparingDisabledSourceIDs = nil
            updateDisabledSourceIDs(ids)
        }
        if let configuration = preparingArtistNameConfiguration {
            preparingArtistNameConfiguration = nil
            updateArtistNameConfiguration(configuration)
        }
        if let folders = preparingAlbumArtistFolders {
            preparingAlbumArtistFolders = nil
            updateAlbumArtistFolders(folders)
        }
        if preparingContentClassificationRefresh {
            preparingContentClassificationRefresh = false
            refreshContentClassification()
        }
    }

    /// 发布步骤第 5/6 步: 先跑 `onReady` 回调, 再唤醒 `whenReady()` 等待者。
    /// 排在突变重放与补写之后, 观察者因此永远看到完整且已落盘的库。
    private func notifyReadinessObservers() {
        let handlers = readinessHandlers
        readinessHandlers.removeAll(keepingCapacity: false)
        for handler in handlers { handler() }
        let continuations = readinessContinuations
        readinessContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume() }
        let bounded = boundedReadinessContinuations
        boundedReadinessContinuations.removeAll(keepingCapacity: false)
        for continuation in bounded.values { continuation.resume() }
    }

    /// 发布步骤第 4 步: 把 `.preparing` 期间被 S1 拦下的持久化各补一次。
    private func flushDeferredPersistenceAfterReadiness() {
        if deferredDeviceLocalExclusionWriteRequested {
            deferredDeviceLocalExclusionWriteRequested = false
            try? persistDeviceLocalExclusions()
        }
        if deferredPlaylistDurabilityWriteRequested {
            deferredPlaylistDurabilityWriteRequested = false
            _ = persistPlaylistDurabilityLedger()
        }
        if deferredDerivedIndexCacheWriteRequested {
            deferredDerivedIndexCacheWriteRequested = false
            persistDerivedIndexCache()
        }
        if deferredStartupCacheWriteRequested {
            deferredStartupCacheWriteRequested = false
            scheduleStartupCacheWrite(
                snapshot: makeSnapshot(includingSongs: false),
                songStoreRevision: try? songStore?.startupState().contentRevision,
                snapshotFingerprint: Self.snapshotFingerprint(at: snapshotURL)
            )
        }
        if deferredPortableSnapshotPersistRequested {
            deferredPortableSnapshotPersistRequested = false
            persistNow()
        }
    }

    /// 用未发布的准备结果构造一个处于 `.preparing` 的库。
    /// 目前仅供测试与 Stage 2 使用, 生产代码仍走同步构造。
    static func makePreparing(
        storageDirectory: URL? = nil,
        disabledSourceIDs: Set<String> = [],
        artistNameConfiguration: ArtistNameConfiguration? = nil
    ) -> MusicLibrary {
        MusicLibrary(
            disabledSourceIDs: disabledSourceIDs,
            storageDirectory: storageDirectory,
            artistNameConfiguration: artistNameConfiguration,
            startsPreparing: true
        )
    }

    /// 主线程上的唯一发布步骤: 装载准备结果、翻转就绪状态、重放排队突变。
    func publish(_ prepared: PreparedStartup) {
        guard isPreparing else { return }
        loadSnapshot(preparedStartup: prepared)
    }

    func updateDisabledSourceIDs(_ ids: Set<String>) {
        // 任何一次同步设置都让还在后台算的那一次作废, 最后一次调用说了算。
        disabledSourceIDsRequestGeneration &+= 1
        // S2 例外 1: 配置不排队。准备结果的可见缓存是用存储里的禁用集合算的,
        // 这里只记下最新值, 发布拷回之后再对账。
        if isPreparing {
            preparingDisabledSourceIDs = ids
            return
        }
        guard disabledSourceIDs != ids else { return }
        disabledSourceIDs = ids
        rebuildVisibleCache()
        playlistCollectionRevision &+= 1
        spotlightIndexRevision &+= 1
        // 重新启用一个源可能让置灰的歌有了着落。
        schedulePlaylistPendingResolution()
    }

    /// `updateDisabledSourceIDs` 的离主线程版本。整库可见缓存 (过滤、艺术家解析、
    /// 分类、流派) 在后台算好, 主 actor 上只做装载 —— 6.6 万首时同步重算要一两秒。
    /// 期间 songs / 专辑 / 歌手 / 可见缓存 / 命名配置 / 分类输入任何一样变了就重算
    /// 一次, 仍对不上才退回同步路径, 所以最终状态与同步版本相同。之后到来的任何
    /// 一次设置 (同步或异步) 都会让这一次作废。
    func updateDisabledSourceIDsInBackground(_ ids: Set<String>) async {
        disabledSourceIDsRequestGeneration &+= 1
        let request = disabledSourceIDsRequestGeneration
        for _ in 0..<2 {
            guard !isPreparing, disabledSourceIDs != ids else {
                updateDisabledSourceIDs(ids)
                return
            }
            let songsSnapshot = songsReference
            let albumsSnapshot = albumsReference
            let artistsSnapshot = artistsReference
            let visibilityGeneration = visibleCacheGeneration
            let configuration = artistNameConfiguration
            let classification = SpokenWordStore.shared.classificationSnapshot
            let previousVisible = visibleSongs
            let startedAt = ProcessInfo.processInfo.systemUptime
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.prepareVisibleCache(
                    songs: songsSnapshot.value,
                    albums: albumsSnapshot.value,
                    artists: artistsSnapshot.value,
                    artistNameConfiguration: configuration,
                    disabledSourceIDs: ids,
                    spokenWordClassification: classification,
                    previousVisibleSongs: previousVisible
                )
            }.value
            guard request == disabledSourceIDsRequestGeneration else { return }
            guard !isPreparing,
                  songsSnapshot === songsReference,
                  albumsSnapshot === albumsReference,
                  artistsSnapshot === artistsReference,
                  visibilityGeneration == visibleCacheGeneration,
                  configuration == artistNameConfiguration,
                  classification == SpokenWordStore.shared.classificationSnapshot else { continue }
            guard disabledSourceIDs != ids else { return }
            disabledSourceIDs = ids
            applyPreparedVisibleCache(prepared)
            playlistCollectionRevision &+= 1
            spotlightIndexRevision &+= 1
            schedulePlaylistPendingResolution()
            plog("📚 disabled sources applied off-main prepareMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) songs=\(songsSnapshot.value.count) hidden=\(ids.count)")
            return
        }
        updateDisabledSourceIDs(ids)
    }

    /// Re-splits only when corrections or folder rules differ from the
    /// inputs already used by the published cache.
    func refreshContentClassification() {
        guard !isPreparing else {
            preparingContentClassificationRefresh = true
            return
        }
        guard visibleContentClassification != SpokenWordStore.shared.classificationSnapshot else { return }
        rebuildVisibleCache()
    }

    func updateAppleMusicLibrarySyncEnabled(_ enabled: Bool) {
        guard appleMusicLibrarySyncEnabled != enabled else { return }
        appleMusicLibrarySyncEnabled = enabled
        playlistCollectionRevision &+= 1
    }

    /// 由源列表驱动:Apple Music 被添加为音乐源时为 true,被移除后为 false。
    func updateAppleMusicSourceInstalled(_ installed: Bool) {
        guard appleMusicSourceInstalled != installed else { return }
        appleMusicSourceInstalled = installed
        playlistCollectionRevision &+= 1
    }

    func sourceSyncDidComplete() {
        sourceSyncCompletionRevision &+= 1
    }

    var songCount: Int { visibleSongs.count }
    var albumCount: Int { visibleAlbums.count }
    var artistCount: Int { visibleArtists.count }

    /// 资料库艺术家页按设置列出的人。
    func browsableArtists(_ mode: ArtistBrowseMode) -> [Artist] {
        switch mode {
        case .allArtists: return visibleArtists
        case .albumArtists: return visibleAlbumArtists
        }
    }
    var genreCount: Int { visibleGenres.count }

    private func rebuildVisibleCache() {
        let prepared = Self.prepareVisibleCache(
            songs: songs,
            albums: albums,
            artists: artists,
            artistNameConfiguration: artistNameConfiguration,
            disabledSourceIDs: disabledSourceIDs,
            spokenWordClassification: SpokenWordStore.shared.classificationSnapshot,
            previousVisibleSongs: visibleSongs
        )
        applyPreparedVisibleCache(prepared)
    }

    private func applyPreparedVisibleCache(_ prepared: PreparedVisibleCache) {
        visibleContentClassification = prepared.spokenWordClassification
        let signpost = PrimuseSignposts.hitch.beginInterval("library.applyVisibleCache")
        defer { PrimuseSignposts.hitch.endInterval("library.applyVisibleCache", signpost) }
        // 先把上一代查找表整体 retain 到一个持有者里, 再做下面的赋值:
        // 这样每次赋值只是指针写入, 上一代字典的递归释放交给
        // LibraryArrayReclaimer 的 utility 队列, 不再同步压在主线程上。
        // 释放门限要看这一组里最大的那本字典: 禁用源的歌只在 songIndexByID /
        // songCountBySourceID 里, 可见库很小而全库很大的时候 (大半资料库在
        // 禁用源里) 才不会被当成"小库"同步拆掉。
        let displacedLookupCount = max(visibleSongIndexByID.count, songIndexByID.count)
        let displacedLookups = DisplacedLibraryLookups([
            songIndexByID,
            visibleSongIndexByID,
            visibleAlbumByID,
            visibleArtistByID,
            visibleAlbumArtistByID,
            albumIDsByAlbumOnlyArtistID,
            albumOnlyArtistSongIDsCache,
            visibleSongIDsByArtistID,
            visibleSongIDsByGenreID,
            visibleAlbumIDsByGenreID,
            visibleSongPositionsBySourceID,
            visibleSongCountBySourceID,
            songCountBySourceID,
            preferredArtworkSongIDByAlbumID,
            preferredArtworkSongIDByArtistID,
        ])
        // Album/artist artwork surfaces only care about the fallback song
        // lookups. A regroup that leaves both untouched (the common case
        // while a backfill only refreshes technical metadata) must not
        // invalidate every mounted album card.
        // 映射没变不代表封面没变: 回填给"已经是首选"的那一首写入内嵌封面时
        // 歌曲 ID 不动, 只有它解析出来的 coverArtFileName 变了。漏掉这一次
        // bump, 只盯这个 revision 的读者 (资料库快捷入口、CarPlay 编辑器预览)
        // 会一直显示占位图。
        let artworkLookupsChanged =
            preferredArtworkSongIDByAlbumID != prepared.preferredArtworkSongIDByAlbumID
                || preferredArtworkSongIDByArtistID != prepared.preferredArtworkSongIDByArtistID
                || Self.preferredArtworkReferencesChanged(
                    currentSong: { self.lookupVisibleSong($0) },
                    preparedSong: { id in
                        prepared.songIndexByID[id].flatMap {
                            prepared.songs.indices.contains($0) ? prepared.songs[$0] : nil
                        }
                    },
                    preferredSongIDs: [
                        prepared.preferredArtworkSongIDByAlbumID,
                        prepared.preferredArtworkSongIDByArtistID,
                    ]
                )
        visibleSongs = prepared.songs
        let musicShares = sharesStorage(prepared.musicSongs, prepared.songs)
        musicSongsSharesVisibleSongs = musicShares
        musicSongs = musicShares ? [] : prepared.musicSongs
        spokenWordSongs = prepared.spokenWordSongs
        spokenWordSongIDs = prepared.spokenWordSongIDs
        // 扫描时每批都发布一次,没变就不写,播客页不必跟着重画。
        localPodcastBookIDs = prepared.podcastBookIDs
        if localPodcastSongs != prepared.podcastSongs {
            localPodcastSongs = prepared.podcastSongs
        }
        spokenWordBookIDs = prepared.spokenWordBookIDs
        spokenWordBookCount = Set(prepared.spokenWordBookIDs.values).count
        visibleAlbums = prepared.albums
        visibleArtists = prepared.artists
        visibleAlbumArtists = prepared.albumArtistIndex.artists
        visibleGenres = prepared.genres
        songIndexByID = prepared.allSongIndexByID
        visibleSongIndexByID = prepared.songIndexByID
        visibleAlbumByID = prepared.albumByID
        visibleArtistByID = prepared.artistByID
        visibleAlbumArtistByID = prepared.albumArtistByID
        albumIDsByAlbumOnlyArtistID = prepared.albumArtistIndex.albumIDsByAlbumOnlyArtistID
        albumOnlyArtistSongIDsCache = [:]
        visibleSongIDsByArtistID = prepared.songIDsByArtistID
        visibleSongIDsByGenreID = prepared.songIDsByGenreID
        visibleAlbumIDsByGenreID = prepared.albumIDsByGenreID
        visibleSongPositionsBySourceID = prepared.songPositionsBySourceID
        sourceIDsWithUnplayableSongs = prepared.unplayableSourceIDs
        for (sourceID, state) in sourceSongListStates {
            state.publish(sourceSongs(sourceID), replacedIDs: nil)
        }
        refreshSourceIDsWithPlayableSongs()
        visibleSongCountBySourceID = prepared.countBySourceID
        songCountBySourceID = prepared.allCountBySourceID
        preferredArtworkSongIDByAlbumID = prepared.preferredArtworkSongIDByAlbumID
        preferredArtworkSongIDByArtistID = prepared.preferredArtworkSongIDByArtistID
        if artworkLookupsChanged {
            albumArtworkLookupRevision &+= 1
        }
        // 自动艺人图、艺人改名这类只动了艺人查找表的发布也要让对应卡片比对一次。
        scheduleArtworkLookupTokenRefresh()
        if prepared.orderedIDsChanged {
            visibleSongCollectionRevision &+= 1
        }
        LibraryArrayReclaimer.release(
            holder: displacedLookups,
            approximateElementCount: displacedLookupCount
        )
    }

    /// O(专辑 + 歌手) 地比一遍"首选回退歌解析出来的封面引用"。映射本身不同时
    /// 不会走到这里 —— 那一步已经判定要 bump 了。
    private static func preferredArtworkReferencesChanged(
        currentSong: (String) -> Song?,
        preparedSong: (String) -> Song?,
        preferredSongIDs: [[String: String]]
    ) -> Bool {
        for lookup in preferredSongIDs {
            for songID in lookup.values
            where currentSong(songID)?.coverArtFileName
                != preparedSong(songID)?.coverArtFileName {
                return true
            }
        }
        return false
    }

    private nonisolated static func prepareVisibleCache(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        artistNameConfiguration: ArtistNameConfiguration,
        disabledSourceIDs: Set<String>,
        spokenWordClassification: SpokenWordClassificationInputs = .empty,
        previousVisibleSongs: [Song]
    ) -> PreparedVisibleCache {
        let nextVisibleSongs = disabledSourceIDs.isEmpty
            ? songs
            : songs.filter { !disabledSourceIDs.contains($0.sourceID) }
        let lookups = makeVisibleLookups(
            songs: nextVisibleSongs,
            artistNameConfiguration: artistNameConfiguration,
            spokenWordClassification: spokenWordClassification
        )
        // An audiobook or a 200-episode 评书 series would otherwise flood the
        // album and artist grids it has nothing to do with. `visibleSongs`
        // stays the whole library — search, playback, statistics and the
        // per-source counts all depend on it — and only the music surfaces
        // read the split-out array. Apple Music playlist entries that are not
        // in the listener's library stay out of the music lists as well.
        let spokenWordSongIDs = lookups.spokenWordSongIDs
        let collectionOnlySongIDs = lookups.collectionOnlySongIDs
        let splitsMusic = !spokenWordSongIDs.isEmpty || !collectionOnlySongIDs.isEmpty
        let musicSongs = splitsMusic
            ? nextVisibleSongs.filter {
                !spokenWordSongIDs.contains($0.id) && !collectionOnlySongIDs.contains($0.id)
            }
            : nextVisibleSongs
        // 本机下载的播客单集也是有声的听法(不进音乐),但不上书架,单独放在播客那边。
        let podcastSongIDs = lookups.podcastSongIDs
        let spokenWordSongs = spokenWordSongIDs.isEmpty
            ? []
            : nextVisibleSongs.filter { spokenWordSongIDs.contains($0.id) && !podcastSongIDs.contains($0.id) }
        let podcastSongs = podcastSongIDs.isEmpty
            ? []
            : nextVisibleSongs.filter { podcastSongIDs.contains($0.id) }
        let nextVisibleAlbums: [Album]
        let candidateVisibleArtists: [Artist]
        if disabledSourceIDs.isEmpty, !splitsMusic {
            nextVisibleAlbums = albums
            candidateVisibleArtists = artists
        } else {
            let visibleAlbumIDs = Set(musicSongs.compactMap(\.albumID))
            nextVisibleAlbums = albums.filter { visibleAlbumIDs.contains($0.id) }
            candidateVisibleArtists = artists.filter { lookups.musicArtistIDs.contains($0.id) }
        }
        // Older derived-index caches may contain two display-name variants
        // that resolve to the same stable artist ID. Keep launch resilient
        // while the disposable cache is rebuilt with the current grouping.
        var artistByID: [String: Artist] = [:]
        let nextVisibleArtists = candidateVisibleArtists.filter { artist in
            guard artistByID[artist.id] == nil else { return false }
            artistByID[artist.id] = artist
            return true
        }
        let albumArtistIndex = AlbumArtistIndexBuilder.build(
            albums: nextVisibleAlbums,
            trackArtists: nextVisibleArtists,
            trackArtistsByID: artistByID
        )
        let allCounts = disabledSourceIDs.isEmpty
            ? lookups.countBySourceID
            : makeSongCountsBySourceID(songs)
        let genreIndex = LibraryGenreIndexBuilder.build(from: musicSongs)
        return PreparedVisibleCache(
            spokenWordClassification: spokenWordClassification,
            songs: nextVisibleSongs,
            musicSongs: musicSongs,
            spokenWordSongs: spokenWordSongs,
            spokenWordSongIDs: spokenWordSongIDs,
            podcastSongs: podcastSongs,
            podcastBookIDs: podcastSongs.isEmpty
                ? [:]
                : SpokenWordBookGrouping.bookIDs(for: podcastSongs.map { SpokenWordBookItem(song: $0) }),
            // Grouping reads other items (a folder's album, an album's only
            // author), so it is done once per library change, here, rather
            // than per item wherever a book id is needed.
            spokenWordBookIDs: spokenWordSongs.isEmpty
                ? [:]
                : SpokenWordBookGrouping.bookIDs(for: spokenWordSongs.map { SpokenWordBookItem(song: $0) }),
            albums: nextVisibleAlbums,
            artists: nextVisibleArtists,
            albumArtistIndex: albumArtistIndex,
            albumArtistByID: Dictionary(
                albumArtistIndex.artists.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            genres: genreIndex.genres,
            allSongIndexByID: disabledSourceIDs.isEmpty
                ? lookups.indexByID
                : makeSongIndex(songs),
            songIndexByID: lookups.indexByID,
            albumByID: Dictionary(
                nextVisibleAlbums.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            artistByID: artistByID,
            songIDsByArtistID: lookups.songIDsByArtistID,
            songIDsByGenreID: genreIndex.songIDsByGenreID,
            albumIDsByGenreID: genreIndex.albumIDsByGenreID,
            songPositionsBySourceID: lookups.songPositionsBySourceID,
            unplayableSourceIDs: lookups.unplayableSourceIDs,
            countBySourceID: lookups.countBySourceID,
            allCountBySourceID: allCounts,
            preferredArtworkSongIDByAlbumID: makePreferredArtworkSongLookup(
                songs: nextVisibleSongs
            ),
            preferredArtworkSongIDByArtistID: lookups.preferredArtworkSongIDByArtistID,
            orderedIDsChanged: !haveSameOrderedIDs(previousVisibleSongs, nextVisibleSongs)
        )
    }

    private nonisolated static func haveSameOrderedIDs(_ lhs: [Song], _ rhs: [Song]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id }
    }

    private nonisolated static func makeVisibleLookups(
        songs: [Song],
        artistNameConfiguration: ArtistNameConfiguration,
        spokenWordClassification: SpokenWordClassificationInputs
    ) -> (
        indexByID: [String: Int],
        songIDsByArtistID: [String: [String]],
        songPositionsBySourceID: [String: [Int]],
        unplayableSourceIDs: Set<String>,
        countBySourceID: [String: Int],
        preferredArtworkSongIDByArtistID: [String: String],
        spokenWordSongIDs: Set<String>,
        podcastSongIDs: Set<String>,
        collectionOnlySongIDs: Set<String>,
        musicArtistIDs: Set<String>
    ) {
        var indexByID: [String: Int] = [:]
        var songIDsByArtistID: [String: [String]] = [:]
        var positionsBySourceID: [String: [Int]] = [:]
        var unplayableSourceIDs: Set<String> = []
        var countBySourceID: [String: Int] = [:]
        // Positions, not songs: the comparison below would otherwise copy a
        // whole song into the table every time one wins.
        var preferredArtworkPositionByArtistID: [String: Int] = [:]
        // Artist field combinations already counted towards the music artists.
        var musicArtistFields: Set<ArtistResolutionFields> = []
        // Growing a dictionary rehashes into a table twice the size while the
        // old one is still alive; sized up front, the peak stays one table.
        indexByID.reserveCapacity(songs.count)
        // Classifying inside this existing pass keeps the whole-library cost
        // to one extension check plus one genre check per song; a separate
        // filter over the library would walk every row a second time.
        var spokenWordSongIDs: Set<String> = []
        var podcastSongIDs: Set<String> = []
        var collectionOnlySongIDs: Set<String> = []
        let collectionOnlyCandidates = spokenWordClassification.collectionOnlySongIDs
        var musicArtistIDs: Set<String> = []
        // 同一组艺术家字段在整库里反复出现(6.6 万首通常只有几千种), 而每次
        // 解析都要做带区域设置的分隔符检索、折叠和哈希, 这一趟按字段记一次。
        var artistIDsByFields: [ArtistResolutionFields: [String]] = [:]
        var spokenWordGenreVerdicts: [String: ListeningContentKind] = [:]
        for (index, song) in songs.enumerated() {
            indexByID[song.id] = index
            let isCollectionOnly = collectionOnlyCandidates.contains(song.id)
            let kind: ListeningContentKind
            if isCollectionOnly {
                kind = .music
                collectionOnlySongIDs.insert(song.id)
            } else {
                kind = spokenWordClassification.kind(
                    songID: song.id,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    genre: song.genre,
                    serverLibraryID: song.serverLibraryID,
                    genreVerdicts: &spokenWordGenreVerdicts
                )
            }
            let isSpokenWord = kind.isSpokenWordListening
            if isSpokenWord { spokenWordSongIDs.insert(song.id) }
            if kind == .podcast { podcastSongIDs.insert(song.id) }
            let artistFields = ArtistResolutionFields(song)
            let artistIDs: [String]
            if let memoized = artistIDsByFields[artistFields] {
                artistIDs = memoized
            } else {
                artistIDs = resolvedArtistIDs(
                    for: song,
                    configuration: artistNameConfiguration
                )
                artistIDsByFields[artistFields] = artistIDs
            }
            if !isSpokenWord, !isCollectionOnly, musicArtistFields.insert(artistFields).inserted {
                musicArtistIDs.formUnion(artistIDs)
            }
            for artistID in artistIDs {
                songIDsByArtistID[artistID, default: []].append(song.id)
                if let current = preferredArtworkPositionByArtistID[artistID] {
                    if artworkFallbackPrecedes(song, songs[current]) {
                        preferredArtworkPositionByArtistID[artistID] = index
                    }
                } else {
                    preferredArtworkPositionByArtistID[artistID] = index
                }
            }
            positionsBySourceID[song.sourceID, default: []].append(index)
            countBySourceID[song.sourceID, default: 0] += 1
            if !song.isPlayable { unplayableSourceIDs.insert(song.sourceID) }
        }
        return (
            indexByID,
            songIDsByArtistID,
            positionsBySourceID,
            unplayableSourceIDs,
            countBySourceID,
            preferredArtworkPositionByArtistID.mapValues { songs[$0].id },
            spokenWordSongIDs,
            podcastSongIDs,
            collectionOnlySongIDs,
            musicArtistIDs
        )
    }

    private nonisolated static func makeSongCountsBySourceID(
        _ songs: [Song]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for song in songs {
            counts[song.sourceID, default: 0] += 1
        }
        return counts
    }

    private nonisolated static func makePreferredArtworkSongLookup(
        songs: [Song]
    ) -> [String: String] {
        var preferredPositions: [String: Int] = [:]
        for (index, song) in songs.enumerated() {
            guard let albumID = song.albumID, !albumID.isEmpty else { continue }
            guard let current = preferredPositions[albumID] else {
                preferredPositions[albumID] = index
                continue
            }
            if artworkFallbackPrecedes(song, songs[current]) {
                preferredPositions[albumID] = index
            }
        }
        return preferredPositions.mapValues { songs[$0].id }
    }

    private nonisolated static func artworkFallbackPrecedes(
        _ lhs: Song,
        _ rhs: Song
    ) -> Bool {
        let lhsHasArtwork = lhs.coverArtFileName?.isEmpty == false
        let rhsHasArtwork = rhs.coverArtFileName?.isEmpty == false
        if lhsHasArtwork != rhsHasArtwork { return lhsHasArtwork }

        let lhsDisc = lhs.discNumber ?? Int.max
        let rhsDisc = rhs.discNumber ?? Int.max
        if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

        let lhsTrack = lhs.trackNumber ?? Int.max
        let rhsTrack = rhs.trackNumber ?? Int.max
        if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }
        return lhs.id < rhs.id
    }

    private nonisolated static func makeSongIndex(_ songs: [Song]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(songs.count)
        for (index, song) in songs.enumerated() {
            result[song.id] = index
        }
        return result
    }

    private func invalidateSearchCaches() {
        searchRevision &+= 1
    }

    private func enqueueSearchIndexChanges(
        upserts: [Song],
        deletingIDs: Set<String>,
        generation: Int,
        after durableWrite: Task<Int64?, Never>?
    ) {
        let previous = searchIndexUpdateTask
        searchIndexUpdateTask = Task.detached(priority: .utility) {
            _ = await previous?.value
            if let durableWrite, await durableWrite.value == nil {
                // Keep the synchronously-persisted dirty generation. A later
                // full recovery will reconcile the index with the last
                // successfully committed song-store snapshot.
                return
            }
            await LibrarySearchIndex.shared.applyChanges(
                upserts: upserts,
                deletingIDs: deletingIDs,
                generation: generation
            )
        }
    }

    /// Captures the full recovery snapshot and its durable generation in one
    /// main-actor turn, then places it in the same queue as row-level updates.
    /// A later mutation therefore cannot be marked complete by an older full
    /// snapshot, even if the search actor is busy when this request is made.
    func prepareSearchIndexIfNeeded() async {
        // S3: 全量准备会把这份快照当成索引的全部内容, 并在结束时把 pending
        // 标记置为已完成。`.preparing` 期间 songs 还是空的, 那一次就会永久地
        // 把搜索索引标成"已经准备好的空索引"。标记留着, 下一次机会再跑。
        guard isReady else { return }
        guard LibrarySearchIndex.hasPendingPreparation(defaults: searchIndexDefaults) else { return }
        let snapshot = songs
        let generation = LibrarySearchIndex.pendingPreparationGeneration(
            defaults: searchIndexDefaults
        )
        let previous = searchIndexUpdateTask
        let pendingSongStoreWrite = songStoreWriteTask
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            if let pendingSongStoreWrite, await pendingSongStoreWrite.value == nil {
                return
            }
            await LibrarySearchIndex.shared.prepare(
                songs: snapshot,
                generation: generation
            )
        }
        searchIndexUpdateTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 搜索索引准备代际的偏好存储。测试注入独立 suite, 生产是 `.standard`。
    @ObservationIgnored private let searchIndexDefaults: UserDefaults
    /// 歌词索引刷新的注入点。非 nil 时替代 `LibrarySearchIndex.shared`,
    /// 让"代际分配与入链发生在同一个主线程轮次"这条不变量可以被确定性地断言。
    @ObservationIgnored private let lyricsSearchIndexRefresh: (
        @MainActor (_ songID: String, _ fallbackText: String?, _ generation: Int) -> Void
    )?

    private func enqueueLyricsSearchIndexRefresh(
        songID: String,
        fallbackText: String?,
        generation: Int
    ) {
        if let lyricsSearchIndexRefresh {
            lyricsSearchIndexRefresh(songID, fallbackText, generation)
            return
        }
        let previous = searchIndexUpdateTask
        searchIndexUpdateTask = Task.detached(priority: .utility) {
            _ = await previous?.value
            await LibrarySearchIndex.shared.refreshLyrics(
                songID: songID,
                fallbackText: fallbackText,
                generation: generation
            )
        }
    }

    init(
        fileManager: FileManager = .default,
        disabledSourceIDs: Set<String> = [],
        storageDirectory: URL? = nil,
        artistNameConfiguration: ArtistNameConfiguration? = nil,
        preferExternalSnapshot: Bool = false,
        preparedStartup: PreparedStartup? = nil,
        deferredMaintenanceAllowed: (@MainActor () -> Bool)? = nil,
        songStoreSnapshotWriter: @escaping @Sendable (IncrementalSongStore, [Song], String?) throws -> Int64 = {
            try $0.replaceAll(with: $1, snapshotImportID: $2)
        },
        /// 同步路径的身份前缀输入(sourceID → cloudAccountID)。
        /// 传 nil 时沿用旧行为, 回落到 `sourceIdentityResolver`。
        sourceIdentityPrefixes: [String: String]? = nil,
        /// 搜索索引准备代际所用的偏好存储。默认 `.standard` = 生产行为。
        searchIndexDefaults: UserDefaults = .standard,
        /// 歌词缓存到达后的索引刷新接缝。为 nil 时走
        /// `LibrarySearchIndex.shared`, 即生产路径。
        lyricsSearchIndexRefresh: (
            @MainActor (_ songID: String, _ fallbackText: String?, _ generation: Int) -> Void
        )? = nil,
        /// 以 `.preparing` 构造: 不读盘、不发布, 等待 `publish(_:)`。
        startsPreparing: Bool = false
    ) {
        self.searchIndexDefaults = searchIndexDefaults
        self.lyricsSearchIndexRefresh = lyricsSearchIndexRefresh
        self.deferredMaintenanceAllowed = deferredMaintenanceAllowed ?? {
            #if os(iOS)
            UIApplication.shared.applicationState == .active
                && ProcessInfo.processInfo.thermalState == .nominal
            #else
            true
            #endif
        }
        self.artistNameConfiguration = preparedStartup?.storage.artistNameConfiguration ?? (
            artistNameConfiguration
                ?? ArtistNameConfiguration.load(from: .standard)
        ).normalized()
        let directory = preparedStartup?.storage.directory
            ?? storageDirectory ?? Self.defaultStorageDirectory(fileManager: fileManager)
        if preparedStartup == nil {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        snapshotURL = directory.appendingPathComponent("library-cache.json")
        backupSnapshotURL = directory.appendingPathComponent("library-cache.backup.json")
        startupCacheURL = directory.appendingPathComponent("library-startup-cache.plist")
        derivedIndexCacheURL = directory.appendingPathComponent("library-derived-index.plist")
        playlistDurabilityURL = directory.appendingPathComponent("playlist-durability.json")
        deviceLocalExclusionURL = directory
            .appendingPathComponent("library-device-local-excluded-songs.json")
        portableSnapshotNeedsInitialWrite = !fileManager.fileExists(atPath: snapshotURL.path)
        playlistSyncWriterID = preparedStartup?.storage.playlistSyncWriterID ?? Self.startupPlaylistWriterID()
        if let preparedStartup {
            songStore = preparedStartup.storage.songStore
        } else if startsPreparing {
            // 准备阶段的库不持有存储句柄, `publish(_:)` 会装入准备结果的实例,
            // 避免同一个 SQLite 文件出现两个连接池。
            songStore = nil
        } else {
            do {
                songStore = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path)
            } catch {
                songStore = nil
                plog("⚠️ Incremental song store unavailable; using JSON fallback: \(error.localizedDescription)")
            }
        }
        // G2: 准备结果自带禁用源集合, 且可见缓存就是用它算出来的。
        // 以准备结果为准, 避免已发布的可见缓存与禁用集合互相矛盾。
        assert(
            preparedStartup == nil || preparedStartup?.storage.disabledSourceIDs == disabledSourceIDs
                || disabledSourceIDs.isEmpty,
            "prepareStartup(disabledSourceIDs:) and MusicLibrary(disabledSourceIDs:) disagree"
        )
        self.disabledSourceIDs = preparedStartup?.storage.disabledSourceIDs ?? disabledSourceIDs
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        self.songStoreSnapshotWriter = songStoreSnapshotWriter
        // `startsPreparing` 且没有准备结果时停在 `.preparing`:
        // 不读盘、不发布、不落盘, 等待 `publish(_:)`。
        if !startsPreparing || preparedStartup != nil {
            // Must precede `loadSnapshot`: the loader filters the decoded rows
            // through this set so an imported snapshot cannot resurrect them.
            if preparedStartup == nil { loadDeviceLocalExclusions() }
            loadSnapshot(
                preferExternalSnapshot: preferExternalSnapshot,
                preparedStartup: preparedStartup,
                sourceIdentityPrefixes: sourceIdentityPrefixes
            )
        }

        #if os(iOS)
        for name in [UIApplication.didBecomeActiveNotification, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.flushDeferredLibraryMaintenance()
                }
            }
        }
        #endif

        NotificationCenter.default.addObserver(
            forName: .primuseArtistNameConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let value = notification.object as? ArtistNameConfiguration else { return }
            Task { @MainActor [weak self, value] in
                self?.updateArtistNameConfiguration(value)
            }
        }

        // MetadataAssetStore writes the actual searchable lyrics files. Search
        // reads those files directly, so do not mirror every scrape into the
        // two observable 11k-song arrays. That old mirror caused a full-array
        // traversal/publication about once per scraped song. A small, separate
        // revision only invalidates SearchView's lyrics cache.
        NotificationCenter.default.addObserver(
            forName: .primuseLyricsDidCache,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let songID = info["songID"] as? String else { return }
            let fallbackText = info["lyricsText"] as? String
            // 观察者注册在 `queue: .main`, 所以这里已经在主线程上。代际分配
            // 必须和入链发生在同一个 main actor 轮次 (persistSongChanges 就是
            // 这么做的): 中间插一次 Task hop 时, 后分配的代际会先入链, 让
            // markIncrementalPreparationCompleted 的连续性检查永久失败, 增量
            // 索引再也无法结账, 每次启动 / 退到后台都要跑全库 prepare。
            MainActor.assumeIsolated {
                let generation = LibrarySearchIndex.persistLibraryChangePending(
                    defaults: self.searchIndexDefaults
                )
                self.enqueueLyricsSearchIndexRefresh(
                    songID: songID,
                    fallbackText: fallbackText,
                    generation: generation
                )
                self.scheduleLyricsSearchInvalidation()
            }
        }
    }

    private static let pendingLyricsFlushDelay: TimeInterval = 0.5
    /// 等待写入的 (songID → 最新 lyricsText)。同一 songID 多次 schedule 后,
    /// flush 时只用最新值, 中间快照丢弃。
    private var pendingLyricsText: [String: String] = [:]
    private var pendingLyricsFlushTask: Task<Void, Never>?
    /// 一批资源引用补丁的最长等待时间。刮削逐首回调, 这个窗口把一轮刮削
    /// 压成一次发布, 又短到用户看不出封面是"批量"刷新的。
    private static let pendingAssetPatchFlushDelay: TimeInterval = 0.3
    /// 等待应用的 (songID → 旁挂资源补丁)。同一首歌多次入队按字段合并,
    /// 最后一次写入获胜。
    private var pendingAssetPatches: [String: PendingAssetReferencePatch] = [:]
    private var pendingAssetPatchFlushTask: Task<Void, Never>?
    private var searchIndexUpdateTask: Task<Void, Never>?
    private var lyricsSearchInvalidationTask: Task<Void, Never>?
    private var deferredLyricsSearchInvalidation = false
    private var isDeferringSceneTransitionPublications = false
    private var deferredPersistRequested = false
    /// Apple TV 安装整库快照时, 事务会整份替换 `library-cache.json`。那次写入
    /// 不走本类的写入链, 所以安装区间内本类自己的快照写入必须让路: 否则一笔
    /// 在安装开始之前就出发的后台写入完全可以在事务落盘之后才写完, 把刚装好
    /// 的整库覆盖回安装前的内容, 随后的重载再把这份旧内容当成导入结果。
    @ObservationIgnored private var externalSnapshotWriteOwners = 0
    @ObservationIgnored private var externalSnapshotWriteWaiters: [CheckedContinuation<Void, Never>] = []

    /// SwiftUI scene commits have a strict watchdog budget. Keep incoming
    /// lyrics-search updates buffered while iOS moves active → background;
    /// scraping and cache writes continue, but the two 11k-element observable
    /// arrays are not republished in that narrow window.
    func beginSceneTransitionQuiescence() {
        guard !isDeferringSceneTransitionPublications else { return }
        // 攒着的资源补丁在这里落地, 这样紧接着的持久化屏障能带上它们 ——
        // 逐首发布时它们本来就已经写进 songs 了。
        flushPendingAssetReferencePatches()
        isDeferringSceneTransitionPublications = true
        pendingLyricsFlushTask?.cancel()
        pendingLyricsFlushTask = nil
        if lyricsSearchInvalidationTask != nil {
            deferredLyricsSearchInvalidation = true
        }
        lyricsSearchInvalidationTask?.cancel()
        lyricsSearchInvalidationTask = nil
        let needsImmediatePersistence = persistTask != nil || deferredPersistRequested
        persistTask?.cancel()
        persistTask = nil
        persistDeadline = nil
        if needsImmediatePersistence {
            deferredPersistRequested = false
            persistNow()
        }
        plog("📚 Deferring library publications during scene transition")
    }

    /// 外部要整份替换快照文件时取得写入所有权。返回时: 已武装的防抖写入被
    /// 收起(记账留到交还时补), 在途的整份写入与启动缓存写入都已经落完。
    /// 之后本类的快照写入要么推迟、要么阻塞, 直到 `endExternalSnapshotWrite`。
    func beginExternalSnapshotWrite() async {
        externalSnapshotWriteOwners += 1
        if externalSnapshotWriteOwners == 1 {
            let armed = persistTask != nil || deferredPersistRequested
            persistTask?.cancel()
            persistTask = nil
            persistDeadline = nil
            deferredPersistRequested = armed
        }
        // 在途的写入是真正的危险:它早于栅栏出发, 却可能晚于事务落盘。
        _ = await persistWriteTask?.value
        _ = await startupCacheWriteTask?.value
    }

    /// 交还写入所有权: 放行被挡住的写入方, 并补上区间内攒下的那次防抖写入。
    func endExternalSnapshotWrite() {
        guard externalSnapshotWriteOwners > 0 else { return }
        externalSnapshotWriteOwners -= 1
        guard externalSnapshotWriteOwners == 0 else { return }
        let waiters = externalSnapshotWriteWaiters
        externalSnapshotWriteWaiters = []
        for waiter in waiters { waiter.resume() }
        if deferredPersistRequested {
            deferredPersistRequested = false
            persistSnapshot(marksMutation: false)
        }
    }

    var isExternalSnapshotWriteOwned: Bool { externalSnapshotWriteOwners > 0 }

    /// 正在等待栅栏交还的屏障写入方数量。回归测试用它作为真实的同步点,
    /// 不必靠 sleep 去猜"被挡住的那个调用有没有跑到等待点"。
    var blockedSnapshotWriterCount: Int { externalSnapshotWriteWaiters.count }

    /// 屏障语义的写入方在这里排队等安装结束, 而不是被丢掉: 调用方要的是
    /// "返回时已落盘", 空写成功会让它提交一个磁盘上并不存在的状态。
    private func awaitExternalSnapshotWriteRelease() async {
        guard externalSnapshotWriteOwners > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            externalSnapshotWriteWaiters.append(continuation)
        }
    }

    func endSceneTransitionQuiescence() {
        guard isDeferringSceneTransitionPublications else { return }
        isDeferringSceneTransitionPublications = false
        plog("📚 Resuming deferred library publications after scene transition")

        if !pendingLyricsText.isEmpty {
            schedulePendingLyricsTextFlush()
        }
        if deferredLyricsSearchInvalidation {
            deferredLyricsSearchInvalidation = false
            scheduleLyricsSearchInvalidation()
        }
        if deferredPersistRequested {
            deferredPersistRequested = false
            persistSnapshot(marksMutation: false)
        }
    }

    private func scheduleLyricsSearchInvalidation() {
        if isDeferringSceneTransitionPublications {
            deferredLyricsSearchInvalidation = true
            return
        }
        guard lyricsSearchInvalidationTask == nil else { return }
        lyricsSearchInvalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.lyricsSearchRevision &+= 1
            self.lyricsSearchInvalidationTask = nil
        }
    }

    private func schedulePendingLyricsTextFlush() {
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
        if deferringUntilReady({ [weak self] in self?.updateLyricsText(lyricsTextBySongID) }) { return }
        if isDeferringSceneTransitionPublications {
            pendingLyricsText.merge(lyricsTextBySongID) { _, latest in latest }
            return
        }
        let signpost = PrimuseSignposts.hitch.beginInterval("library.lyricsTextBatch")
        defer { PrimuseSignposts.hitch.endInterval("library.lyricsTextBatch", signpost) }

        // 先挑出真要写的行, 再交出数组就地写: 一首都不用改时不碰数组。
        var writes: [(index: Int, songID: String, text: String)] = []
        writes.reserveCapacity(lyricsTextBySongID.count)
        for (songID, text) in lyricsTextBySongID {
            guard let index = songIndexByID[songID],
                  songsReference.value[index].lyricsText != text else { continue }
            writes.append((index, songID, text))
        }
        guard !writes.isEmpty else { return }
        var nextSongs: [Song] = []
        let visibleSharesSongs = takeLibrarySongsForPatching(into: &nextSongs)
        var nextVisibleSongs = visibleSharesSongs ? [] : visibleSongs
        for write in writes {
            nextSongs[write.index].lyricsText = write.text
            if !visibleSharesSongs, let visibleIndex = visibleSongIndexByID[write.songID] {
                nextVisibleSongs[visibleIndex].lyricsText = write.text
            }
        }
        let appliedIDs = writes.map(\.songID)
        songs = nextSongs
        visibleSongs = visibleSharesSongs ? nextSongs : nextVisibleSongs
        patchSourceAssetReferences(songIDs: appliedIDs)
        plog("📚 updateLyricsText: requested=\(lyricsTextBySongID.count) applied=\(appliedIDs.count) librarySongs=\(songs.count)")
        invalidateSearchCaches()
        persistSongChanges(
            upserts: appliedIDs.compactMap { songIndexByID[$0].map { nextSongs[$0] } }
        )
    }

    /// Update cached artwork / lyrics references without rebuilding album,
    /// artist, playlist, and history indexes. Scraped sidecar assets only
    /// change where UI loaders read media from; they don't affect grouping.
    ///
    /// 刮削一轮会对几十首歌各调一次这里。逐首发布等于每首都把 `songs` 与
    /// `visibleSongs` 整份拷贝一遍并触发一次全局发布, 所以补丁先攒进
    /// `pendingAssetPatches`, 最多 `pendingAssetPatchFlushDelay` 秒后一次性
    /// 应用: 一批只拷一次、发布一次、落盘一次。需要立刻看到结果的调用方
    /// (整行替换与持久化屏障) 会先同步 flush。
    func updateAssetReferences(songID: String, coverRef: String? = nil, lyricsRef: String? = nil) {
        if deferringUntilReady({ [weak self] in
            self?.updateAssetReferences(songID: songID, coverRef: coverRef, lyricsRef: lyricsRef)
        }) { return }
        guard coverRef != nil || lyricsRef != nil else { return }
        enqueueAssetReferencePatch(
            songID: songID,
            patch: PendingAssetReferencePatch(coverRef: coverRef, lyricsRef: lyricsRef)
        )
    }

    /// Update the optional MV reference without rebuilding album, artist,
    /// playlist, and history indexes. `nil` is meaningful here: it clears a
    /// stale video sidecar discovered during playback or scanning.
    func updateMusicVideoReference(songID: String, mvPath: String?) {
        // S2: 与 updateAssetReferences / updateLyricsText 同批排队, 否则这条
        // 编辑会因为空库查不到行而被直接丢掉。
        if deferringUntilReady({ [weak self] in
            self?.updateMusicVideoReference(songID: songID, mvPath: mvPath)
        }) { return }
        // 与封面/歌词引用共用同一个批次: 两者改的都是同一行的旁挂资源指针,
        // 合批后刮削期间的 MV 清理不会再多拷一遍整库数组。
        enqueueAssetReferencePatch(
            songID: songID,
            patch: PendingAssetReferencePatch(musicVideoPath: mvPath, updatesMusicVideo: true)
        )
    }

    private func enqueueAssetReferencePatch(
        songID: String,
        patch: PendingAssetReferencePatch
    ) {
        pendingAssetPatches[songID, default: PendingAssetReferencePatch()].merge(patch)
        // 故意不做"每次调用都重排": 刮削的间隔可能短于窗口, 重排会让这批
        // 补丁一直等不到落地。第一条补丁定下截止时间, 窗口内的其余补丁搭车。
        guard pendingAssetPatchFlushTask == nil else { return }
        pendingAssetPatchFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingAssetPatchFlushDelay))
            guard !Task.isCancelled else { return }
            self?.flushPendingAssetReferencePatches()
        }
    }

    /// 立刻应用攒下的资源引用补丁。整行替换 (`replaceSong(s)`)、场景切换静默
    /// 与持久化屏障都要先走这里, 这样"先补丁后整行替换"的顺序与逐首发布时
    /// 完全一致, 落盘也不会漏掉窗口内的补丁。
    func flushPendingAssetReferencePatches() {
        pendingAssetPatchFlushTask?.cancel()
        pendingAssetPatchFlushTask = nil
        guard !pendingAssetPatches.isEmpty else { return }
        let pending = pendingAssetPatches
        pendingAssetPatches.removeAll(keepingCapacity: true)
        applyAssetReferencePatches(pending)
    }

    /// 整行替换的输入通常读自补丁入队之前的 `songs` 快照: 只 flush 会让补丁
    /// 先落地, 再被这一行的旧封面 / 旧歌词指针整行盖回去 (丢更新)。所以先把
    /// 受影响歌曲的待落地补丁取出来, flush 之后再把补丁写过的字段叠回整行 ——
    /// 补丁总是比调用方手里的那次读取更新, 与两者的调用先后无关。
    private func flushPendingAssetReferencePatches(overlaying incoming: [Song]) -> [Song] {
        var overlays: [String: PendingAssetReferencePatch] = [:]
        if !pendingAssetPatches.isEmpty {
            for song in incoming {
                guard let patch = pendingAssetPatches[song.id] else { continue }
                overlays[song.id] = patch
            }
        }
        flushPendingAssetReferencePatches()
        guard !overlays.isEmpty else { return incoming }
        return incoming.map { song in
            guard let patch = overlays[song.id] else { return song }
            var merged = song
            if let coverRef = patch.coverRef { merged.coverArtFileName = coverRef }
            if let lyricsRef = patch.lyricsRef { merged.lyricsFileName = lyricsRef }
            // MV 的"清空"是有意义的写入, 只有带 updatesMusicVideo 的补丁才叠。
            if patch.updatesMusicVideo { merged.mvPath = patch.musicVideoPath }
            return merged
        }
    }

    private func applyAssetReferencePatches(_ patches: [String: PendingAssetReferencePatch]) {
        let signpost = PrimuseSignposts.hitch.beginInterval("library.assetPatchBatch")
        defer { PrimuseSignposts.hitch.endInterval("library.assetPatchBatch", signpost) }
        var writes: [(index: Int, song: Song)] = []
        var appliedIDs: [String] = []
        var updatedSongs: [Song] = []
        var promotableSongs: [Song] = []
        var artworkChanges: [(songID: String, oldRef: String?, newRef: String?)] = []
        writes.reserveCapacity(patches.count)
        appliedIDs.reserveCapacity(patches.count)
        updatedSongs.reserveCapacity(patches.count)
        for (songID, patch) in patches {
            guard let index = songIndexByID[songID] else { continue }
            var updatedSong = songsReference.value[index]
            let oldCoverRef = updatedSong.coverArtFileName
            // 封面 / 歌词引用的改动才参与封面回退提升 —— 逐首发布时
            // `updateMusicVideoReference` 从不调用 promote。
            var assetReferenceChanged = false
            if let coverRef = patch.coverRef, updatedSong.coverArtFileName != coverRef {
                updatedSong.coverArtFileName = coverRef
                assetReferenceChanged = true
            }
            if let lyricsRef = patch.lyricsRef, updatedSong.lyricsFileName != lyricsRef {
                updatedSong.lyricsFileName = lyricsRef
                assetReferenceChanged = true
            }
            var changed = assetReferenceChanged
            if patch.updatesMusicVideo, updatedSong.mvPath != patch.musicVideoPath {
                updatedSong.mvPath = patch.musicVideoPath
                changed = true
            }
            guard changed else { continue }
            writes.append((index, updatedSong))
            appliedIDs.append(songID)
            updatedSongs.append(updatedSong)
            if assetReferenceChanged {
                promotableSongs.append(updatedSong)
            }
            if oldCoverRef != updatedSong.coverArtFileName {
                artworkChanges.append(
                    (songID: songID, oldRef: oldCoverRef, newRef: updatedSong.coverArtFileName)
                )
            }
        }
        guard !appliedIDs.isEmpty else { return }

        // 只有真要写时才交出数组: 与可见数组共用一份缓冲时就地写, 不整份复制。
        var nextSongs: [Song] = []
        let visibleShared = takeLibrarySongsForPatching(into: &nextSongs)
        for write in writes { nextSongs[write.index] = write.song }
        if visibleShared {
            songs = nextSongs
            visibleSongs = nextSongs
        } else {
            var nextVisibleSongs = visibleSongs
            var visibleChanged = false
            for song in updatedSongs {
                guard let visibleIndex = visibleSongIndexByID[song.id] else { continue }
                nextVisibleSongs[visibleIndex] = song
                visibleChanged = true
            }
            songs = nextSongs
            if visibleChanged { visibleSongs = nextVisibleSongs }
        }
        patchSourceAssetReferences(songIDs: appliedIDs)
        let artworkRevisionBeforePromotion = albumArtworkLookupRevision
        for song in promotableSongs {
            promotePreferredArtworkSongIfNeeded(song)
        }
        // 提升只在"优先级变好"时 bump。首选那一首把封面从一个引用换成另一个
        // (sidecar 落盘后回写路径) 时优先级不变, 仍然要让卡片失效。
        if albumArtworkLookupRevision == artworkRevisionBeforePromotion {
            bumpArtworkLookupRevisionIfPreferred(songIDs: artworkChanges.map(\.songID))
        }
        lastReplacedSong = updatedSongs.count == 1 ? updatedSongs.first : nil
        lastReplacedSongIDs = Set(appliedIDs)
        songReplacementToken = UUID()
        // 每首受影响的歌仍然各发一条失效通知 (object / userInfo 与逐首发布
        // 时完全一样), 只是发生在整批应用之后。
        for change in artworkChanges {
            postArtworkInvalidation(
                songID: change.songID,
                oldRef: change.oldRef,
                newRef: change.newRef
            )
        }
        persistSongChanges(upserts: updatedSongs)
    }

    /// Add songs from a scan result and rebuild albums/artists.
    ///
    /// `notifyRemovals` 控制是否在发现"affected source 里有歌不在 incoming 里"
    /// 时发出 `primuseSongsRemoved` 通知。完整扫描结束 (completeScan) 应当
    /// 传 true (远端真的少了一首歌, listener 应当清缓存); 中间 flush 应当
    /// 传 false ── 因为中间 flush 拿到的是部分扫描结果, 还没扫到的歌会被
    /// line 164 临时移除, 下次 flush 又补回, 这种"伪移除"不应触发缓存清理。
    /// `pruneMissingSongs` 进一步控制是否真的从内存资料库移除缺失歌曲；远端请求
    /// 降级为本机部分结果时必须传 false，否则未下载的 Apple Music 歌曲及其元数据
    /// 会被误删。
    func addSongs(
        _ newSongs: [Song],
        affectedSourceIDs explicitAffectedSourceIDs: Set<String>? = nil,
        notifyRemovals: Bool = true,
        pruneMissingSongs: Bool = true,
        authoritativeIncomingIDs: Set<String>? = nil,
        mergeServerCatalogRows: Bool = false,
        // 中间 flush 传 `.deferredIncremental`: 合并连续 flush 的整库重建与
        // Spotlight 脏位, 最终提交仍然用 `.immediate`。
        indexMaintenance: LibraryMaintenanceDisposition = .immediate
    ) {
        // S2: 发布前排队, 发布后按原顺序重放, 免得扫描/Siri 把结果并进空库。
        if deferringUntilReady({ [weak self] in
            self?.addSongs(
                newSongs,
                affectedSourceIDs: explicitAffectedSourceIDs,
                notifyRemovals: notifyRemovals,
                pruneMissingSongs: pruneMissingSongs,
                authoritativeIncomingIDs: authoritativeIncomingIDs,
                mergeServerCatalogRows: mergeServerCatalogRows,
                indexMaintenance: indexMaintenance
            )
        }) { return }
        let signpost = PrimuseSignposts.hitch.beginInterval("library.addSongs")
        defer { PrimuseSignposts.hitch.endInterval("library.addSongs", signpost) }
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
        // unchanged, and we want the tombstone to keep working.
        // 墓碑不是永久判决: 本机文件源的歌只要文件此刻又在磁盘上, 下面的
        // 复活步骤会当场撤销它 (`restoreDeletedSong` 是同一套撤销语义的
        // 单首入口)。准入判定另外还会丢掉设备本地排除账本里的行 —— 源文件
        // 是故意留着的, 所以文件在不在都不放行, 重扫永远不会把它们加回来。
        // 给每首新歌就近填 albumID/artistID。这样后台 rebuildIndex 不需要回头
        // mutate songs 数组, 1w+ 首库扫描时 main actor 不会被全表 ID 重赋值
        // 卡到。计算成本 = SHA256(string) × 2 per song, 1w 首约 5ms 总。
        // Keep only compact identity sets during the first pass. Retaining a
        // second full `[Song]` snapshot here doubled the peak of every remote
        // incremental flush, even though preparation can be done lazily below.
        if pruneMissingSongs, !deviceLocalExcludedSongsByID.isEmpty {
            let scannedSourceIDs = explicitAffectedSourceIDs ?? Set(newSongs.map(\.sourceID))
            let scannedIDs = authoritativeIncomingIDs ?? Set(newSongs.map(\.id))
            discardRetainedSongs {
                scannedSourceIDs.contains($0.sourceID) && !scannedIDs.contains($0.id)
            }
        }
        var incomingIDs = authoritativeIncomingIDs ?? []
        var sourceIDs = explicitAffectedSourceIDs ?? []
        var appendedIDs: Set<String> = []
        if pruneMissingSongs, authoritativeIncomingIDs == nil {
            incomingIDs.reserveCapacity(newSongs.count)
        }
        // 中间 flush 会把整份累积目录再交上来一次, 所以准入判定跑在每一首上、
        // 每一批两遍。身份前缀按源解析一次即可 (与离主线程装载路径同形),
        // 判定结果也只算一遍, 第二遍复用被拒集合: 被拒行通常是空的, 这比再
        // 物化一份 `[Song]` 便宜, 后者会让每次远端增量 flush 的内存峰值翻倍。
        let hasAdmissionFilters = LibrarySongAdmissionPolicy.hasAdmissionFilters(
            tombstones: deletedSongIdentities,
            deviceExclusions: deviceLocalExcludedSongIdentities
        )
        var identityPrefixBySourceID: [String: String] = [:]
        if hasAdmissionFilters {
            for sourceID in Set(newSongs.map(\.sourceID)) {
                identityPrefixBySourceID[sourceID] = sourceIdentityResolver?(sourceID)
            }
        }
        var blockedIDs: Set<String> = []
        // 命中全局墓碑的行单独记一份, 好在循环之后一次性问探针。只装墓碑
        // 那一支, 所以这份数组通常是空的, 不会再物化一份 `[Song]`。
        var tombstonedCandidates: [Song] = []
        var tombstoneKeyBySongID: [String: String] = [:]
        // 两条放行规则各自需要的输入: 本机源要探针, 远端源要证据表。两样都
        // 没有就没有任何撤销的可能, 连候选都不必收(旧库全是无证据的旧墓碑,
        // 走的正是这条零开销路径)。
        let canRevokeTombstones = deviceLocalFilePresenceProbe != nil
            || !deletedSongIdentityDetails.isEmpty
        for song in newSongs {
            if hasAdmissionFilters {
                switch admissionVerdict(song, prefixes: identityPrefixBySourceID) {
                case .admitted:
                    break
                case .blockedByTombstone(let key):
                    blockedIDs.insert(song.id)
                    if canRevokeTombstones, tombstoneKeyBySongID.updateValue(key, forKey: song.id) == nil {
                        tombstonedCandidates.append(song)
                    }
                    continue
                case .blockedByDeviceExclusion:
                    blockedIDs.insert(song.id)
                    continue
                }
            }
            if pruneMissingSongs {
                if authoritativeIncomingIDs == nil {
                    incomingIDs.insert(song.id)
                }
                if explicitAffectedSourceIDs == nil {
                    sourceIDs.insert(song.sourceID)
                }
            }
            if songIndexByID[song.id] == nil {
                appendedIDs.insert(song.id)
            }
        }

        // 墓碑挡的是"陈旧目录快照 / 其它设备的旧快照"把已删的歌带回来; 对本机
        // 文件源来说磁盘就是事实。文件此刻确实躺在磁盘上, 就说明是用户自己又
        // 把它放回来了(删掉标签不全的几首、改好标签后重新导入同名文件), 这时
        // 墓碑让路并当场撤销 —— 否则那几首无论怎么重扫、换哪种导入方式都永远
        // 进不了资料库, 只有卸载重装才好。
        //
        // 证据取「文件现在存在」而不是「扫描看见过它」: 用户刚删掉一首、而一轮
        // 更早开始的扫描随后才 flush 时, 文件已经不在磁盘上, 探针为 false, 这
        // 批仍然被挡住 —— 删除不会被一次迟到的扫描撤销。
        //
        // 远端源没有"文件在不在磁盘上"可问, 改比签名: 删除那一刻记下的大小 /
        // 修改时间 / 修订标记与扫描到的这一份不同, 才说明服务端在同一路径上
        // 放了另一个文件。同样不拿"扫描时间晚于删除时间"当证据 —— 续扫会重放
        // 删除之前暂存的目录页, 它带的是旧签名, 按签名比才挡得住。
        //
        // 「从资料库移除但保留源文件」那一种删除在删的时候就被记进了设备本地
        // 排除账本, 于是 `admissionVerdict` 给的是 `.blockedByDeviceExclusion`,
        // 根本不会进到这份候选里 —— 它的文件本来就一直在。
        if !tombstonedCandidates.isEmpty {
            // 探针是本机源那条规则用的; 没装探针(tvOS / 测试 / 离主线程装载)
            // 时远端源那条规则照样成立, 它只需要证据表和扫描到的签名。
            let presentSongIDs = deviceLocalFilePresenceProbe?(tombstonedCandidates) ?? []
            var revokedKeys: Set<String> = []
            for song in tombstonedCandidates {
                // 放行规则只有一份, 在 `LibrarySongAdmissionPolicy` 里 —— 那份
                // 是能脱离 App 单独跑测试的, 这里不再另写一遍。
                guard let recordedKey = tombstoneKeyBySongID[song.id],
                      let key = LibrarySongAdmissionPolicy.revocableTombstoneKey(
                          for: .blockedByTombstone(key: recordedKey),
                          isDeviceLocalFilePresent: presentSongIDs.contains(song.id),
                          detail: deletedSongIdentityDetails[recordedKey],
                          scannedFileSize: song.fileSize,
                          scannedLastModified: song.lastModified,
                          scannedRevision: song.revision
                      ) else { continue }
                revokedKeys.insert(key)
                blockedIDs.remove(song.id)
                // 循环里跳过的记账在这里补上, 否则这几首会被下面的
                // `shouldRemove` 当成"扫描没交出来"而立刻又被剪掉。
                if pruneMissingSongs {
                    if authoritativeIncomingIDs == nil {
                        incomingIDs.insert(song.id)
                    }
                    if explicitAffectedSourceIDs == nil {
                        sourceIDs.insert(song.sourceID)
                    }
                }
                if songIndexByID[song.id] == nil {
                    appendedIDs.insert(song.id)
                }
            }
            // 整批撤销一次、落盘一次: 逐首撤销会把整份快照重新编码 N 遍。
            revokeDeletedSongIdentities(revokedKeys)
        }

        // A degraded/partial provider response is not an authoritative source
        // snapshot. Keep existing rows (and, critically, their persistent
        // metadata caches) until a complete scan succeeds.
        let shouldRemove: (Song) -> Bool = { song in
            pruneMissingSongs
                && sourceIDs.contains(song.sourceID)
                && !incomingIDs.contains(song.id)
        }
        let removalCount = pruneMissingSongs
            ? songs.reduce(into: 0) { count, song in
                if shouldRemove(song) { count += 1 }
            }
            : 0
        let appendedSongCount = appendedIDs.count

        var mergedSongs: [Song]
        var removedSongs: [Song] = []
        var existingIndexByID: [String: Int]
        if removalCount == 0 {
            // Nothing leaves: patch and append in place. The array and its
            // index are taken out of the library first so that, unless a
            // just-published visible cache or a background task still holds
            // them, they are uniquely referenced and grow without a copy. A
            // scan flushes every 1.5 s; copying the whole library (and its
            // index) on each one was most of the CPU of a large first sync.
            // Nothing below reads `songs` before the merged array goes back.
            mergedSongs = takeSongsForInPlaceMutation()
            existingIndexByID = takeSongIndexForInPlaceMutation()
            mergedSongs.reserveCapacity(mergedSongs.count + appendedSongCount)
            existingIndexByID.reserveCapacity(existingIndexByID.count + appendedSongCount)
        } else {
            let existingSongs = songs
            // Build the final buffer once. `var mergedSongs = songs` followed by
            // `removeAll` forces Array CoW to allocate another full-library buffer
            // at the worst point of an incremental scan and was the allocation
            // failure reported by Organizer.
            mergedSongs = []
            mergedSongs.reserveCapacity(existingSongs.count - removalCount + appendedSongCount)
            removedSongs.reserveCapacity(removalCount)
            existingIndexByID = [:]
            existingIndexByID.reserveCapacity(existingSongs.count - removalCount + appendedSongCount)
            for song in existingSongs {
                if shouldRemove(song) {
                    removedSongs.append(song)
                } else {
                    existingIndexByID[song.id] = mergedSongs.count
                    mergedSongs.append(song)
                }
            }
        }

        var contentChanged: [Song] = []
        var previousLocationsByID: [String: Song] = [:]
        var replacementIDs: Set<String> = []
        var songListSnapshotChanged = false
        var persistedSongIDs: Set<String> = []

        func recordPersistence(_ song: Song) {
            persistedSongIDs.insert(song.id)
        }

        let derivedIDMemo = DerivedIDMemo()
        for song in newSongs where !blockedIDs.contains(song.id) {
            var newSong = song
            if mergeServerCatalogRows,
               let idx = existingIndexByID[newSong.id] {
                let existing = mergedSongs[idx]
                newSong = ServerSongCatalogMergePolicy.merged(
                    existing: existing,
                    incoming: newSong
                )
                newSong.dateAdded = existing.dateAdded
                if Self.serverReplacedArtwork(from: existing, to: newSong) {
                    // Covers read the song-ID mirror before the reference, so
                    // it has to go before the new reference is published.
                    MetadataAssetStore.shared.invalidateCoverCacheSync(forSongID: newSong.id)
                }
            }
            // 扫描入库仍旧走逐首口径: 整批的目录兄弟关系由随后的整库重建
            // 通过 `albumIDCorrections` 纠正。
            MusicLibrary.fillDerivedIDs(
                &newSong,
                configuration: artistNameConfiguration,
                memo: derivedIDMemo
            )
            applyAutomaticArtistArtwork(to: &newSong)
            if let idx = existingIndexByID[newSong.id] {
                let existing = mergedSongs[idx]
                if !newSong.filePath.isEmpty, newSong.filePath != existing.filePath {
                    previousLocationsByID[newSong.id] = existing
                }
                // Use the same replacement predicate as server-catalogue
                // merging. Format and CUE-boundary changes must invalidate
                // cached bytes and metadata just like size, mtime or revision
                // changes; otherwise the bare-row preservation path below can
                // silently restore stale technical fields.
                if ServerSongCatalogMergePolicy.contentChanged(
                    existing: existing,
                    incoming: newSong
                ) {
                    incomingSongInterner.intern(&newSong)
                    mergedSongs[idx] = newSong
                    contentChanged.append(newSong)
                    replacementIDs.insert(newSong.id)
                    if existing.sourceID != newSong.sourceID
                        || existing.isPlayable != newSong.isPlayable {
                        songListSnapshotChanged = true
                    }
                    recordPersistence(newSong)
                    continue
                }
                // "Bare incoming" matches `MetadataBackfillService.isBareSong` —
                // a Phase A scan that found no metadata. If the existing
                // entry has any metadata at all, prefer it.
                let incomingHasTechnicalMetadata = newSong.duration > 0 || newSong.bitRate != nil
                let incomingHasCatalogMetadata = newSong.artistID != nil
                    || newSong.albumID != nil
                    || newSong.year != nil
                    || newSong.genre != nil
                let incomingIsBare = !incomingHasTechnicalMetadata && !incomingHasCatalogMetadata
                let existingHasTechnicalMetadata = existing.duration > 0 || existing.bitRate != nil
                let existingHasCatalogMetadata = existing.artistID != nil
                    || existing.albumID != nil
                    || existing.year != nil
                    || existing.genre != nil
                let existingHasMetadata = existingHasTechnicalMetadata || existingHasCatalogMetadata
                if incomingIsBare && existingHasMetadata {
                    var merged = existing
                    // A stable provider identity can survive a remote rename
                    // or move. The fresh scan is authoritative for location
                    // even when its metadata payload is otherwise bare.
                    if !newSong.filePath.isEmpty {
                        merged.filePath = newSong.filePath
                    }
                    merged.fileSize = newSong.fileSize
                    merged.lastModified = newSong.lastModified
                    if newSong.dateAdded < merged.dateAdded {
                        merged.dateAdded = newSong.dateAdded
                    }
                    merged.serverPlayCount = newSong.serverPlayCount
                    if let libraryID = newSong.serverLibraryID { merged.serverLibraryID = libraryID }
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
                    if let artistArtwork = newSong.artistArtworkFileName {
                        merged.artistArtworkFileName = artistArtwork
                    }
                    if let lyrics = newSong.lyricsFileName { merged.lyricsFileName = lyrics }
                    if let mvPath = newSong.mvPath { merged.mvPath = mvPath }
                    if merged != existing {
                        mergedSongs[idx] = merged
                        recordPersistence(merged)
                    }
                    if Self.songPresentationChanged(from: existing, to: merged) {
                        replacementIDs.insert(newSong.id)
                        if existing.sourceID != merged.sourceID
                            || existing.isPlayable != merged.isPlayable {
                            songListSnapshotChanged = true
                        }
                    }
                } else {
                    if newSong != existing {
                        incomingSongInterner.intern(&newSong)
                        mergedSongs[idx] = newSong
                        recordPersistence(newSong)
                    }
                    if Self.songPresentationChanged(from: existing, to: newSong) {
                        replacementIDs.insert(newSong.id)
                        if existing.sourceID != newSong.sourceID
                            || existing.isPlayable != newSong.isPlayable {
                            songListSnapshotChanged = true
                        }
                    }
                }
            } else {
                incomingSongInterner.intern(&newSong)
                mergedSongs.append(newSong)
                existingIndexByID[newSong.id] = mergedSongs.count - 1
                recordPersistence(newSong)
            }
        }

        songs = mergedSongs
        songIndexByID = existingIndexByID
        #if !os(tvOS)
        // tvOS 的扫描剪枝可以回滚(`rollbackScanPruning`), 回滚按原成员表比对;
        // 这里改写成员会让回滚认不出来, 所以电视上保持原来的直接清理。
        reassignPlaylistMembers(ofRemoved: removedSongs, leavingPlaceholders: true)
        #endif
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Newly-added songs may resolve identities that were stashed when
        // a CloudKit playlist/history record arrived before the local scan.
        schedulePendingIdentityFlush()
        invalidateSearchCaches()
        requestLibraryIndexMaintenance(indexMaintenance)
        if indexMaintenance == .immediate {
            // 扫描的最终提交: 这一轮的歌都已入库并共用了字段, 表可以放掉了。
            incomingSongInterner = SongStringInterner()
        }
        let persistedIncoming = persistedSongIDs.compactMap { id in
            existingIndexByID[id].map { mergedSongs[$0] }
        }
        persistSongChanges(
            upserts: persistedIncoming,
            deletingIDs: Set(removedSongs.map(\.id))
        )

        // A full re-scan can update metadata while preserving the exact same
        // ordered song IDs (for example correcting a PCM WAV that an older
        // build labelled as DTS). `visibleSongCollectionRevision` intentionally
        // does not change in that case, so publish the lightweight replacement
        // token used by SongListCache to patch only the affected rows.
        if !replacementIDs.isEmpty {
            lastReplacedSongIDs = replacementIDs
            lastReplacedSong = replacementIDs.count == 1
                ? replacementIDs.first.flatMap { song(id: $0) }
                : nil
            if songListSnapshotChanged {
                songListSnapshotInvalidationRevision &+= 1
            }
            songReplacementToken = UUID()
        }

        let locationTransitions = previousLocationsByID.values
            .sorted { $0.id < $1.id }
            .compactMap { previous -> (previous: Song, current: Song)? in
                guard let current = song(id: previous.id),
                      current.filePath != previous.filePath else { return nil }
                return (previous, current)
            }
        if !locationTransitions.isEmpty {
            NotificationCenter.default.post(
                name: .primuseSongLocationChanged,
                object: nil,
                userInfo: [
                    "previousSongs": locationTransitions.map { $0.previous },
                    "songs": locationTransitions.map { $0.current },
                ]
            )
        }
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

    #if os(tvOS)
    struct ScanPruningRecovery {
        fileprivate let songs: [Song]
        fileprivate let memberships: [String: [String]]
        fileprivate let playlistDates: [String: Date]
        fileprivate let recentIDs: [String]
    }

    func beginScanPruning(_ incoming: [Song], sourceID: String) -> ScanPruningRecovery {
        let incomingIDs = Set(incoming.map(\.id))
        let removed = songs.filter { $0.sourceID == sourceID && !incomingIDs.contains($0.id) }
        let recovery = ScanPruningRecovery(
            songs: removed, memberships: playlistSongIDs,
            playlistDates: Dictionary(allPlaylists.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first }),
            recentIDs: recentPlaybackSongIDs
        )
        // 扫描途中每一行变化都已经分批交给过曲库。没有要剪的、保留目录里也没有
        // 要清的、每一行又都和库里一样时,整源再合并一遍只是在主线程上把几万首
        // 重新派生、比较一遍,再排一次整库索引重建 —— 重扫收尾那 1 秒多的卡顿。
        let hasStaleRetainedRows = deviceLocalExcludedSongsByID.values.contains {
            $0.sourceID == sourceID && !incomingIDs.contains($0.id)
        }
        if removed.isEmpty, !hasStaleRetainedRows {
            // 没有要剪的:只把和库里不一样的几行交出去。强制重读元数据的重扫里
            // 常有零星几行对不上,以前一行不同就整源再合并一遍。
            let changed = incoming.filter { !matchesStoredSong($0) }
            plog("📥 TV scan prune source=\(sourceID) incoming=\(incoming.count) changed=\(changed.count) removed=0")
            if !changed.isEmpty {
                addSongs(changed, affectedSourceIDs: nil, notifyRemovals: false,
                         pruneMissingSongs: false)
            }
            return recovery
        }
        plog("📥 TV scan prune source=\(sourceID) incoming=\(incoming.count) removed=\(removed.count) staleRetained=\(hasStaleRetainedRows)")
        // Cache deletion notifications are irreversible; publish them only
        // after both the library and source checkpoint have committed.
        addSongs(incoming, affectedSourceIDs: [sourceID], notifyRemovals: false)
        return recovery
    }

    func rollbackScanPruning(_ recovery: ScanPruningRecovery) {
        // S2: 成员回滚必须在发布后的歌单集合上做, 否则整段回滚落在空库上。
        if deferringUntilReady({ [weak self] in self?.rollbackScanPruning(recovery) }) { return }
        let removedIDs = Set(recovery.songs.map(\.id))
        addSongs(recovery.songs.filter { songIndexByID[$0.id] == nil },
                 notifyRemovals: false, pruneMissingSongs: false)
        for playlist in allPlaylists where !playlist.isDeleted {
            guard playlist.updatedAt == recovery.playlistDates[playlist.id],
                  let original = recovery.memberships[playlist.id],
                  playlistSongIDs[playlist.id] == original.filter({ !removedIDs.contains($0) }) else { continue }
            // A user edit made while persistence was suspended takes priority
            // over the pre-prune membership; only undo the scan's cleanup.
            playlistSongIDs[playlist.id] = original.filter { songIndexByID[$0] != nil }
        }
        if recentPlaybackSongIDs == recovery.recentIDs.filter({ !removedIDs.contains($0) }) {
            recentPlaybackSongIDs = recovery.recentIDs.filter { songIndexByID[$0] != nil }
        }
        playlistCollectionRevision &+= 1
        persistNow()
    }

    func finishScanPruning(_ recovery: ScanPruningRecovery) {
        guard !recovery.songs.isEmpty else { return }
        NotificationCenter.default.post(name: .primuseSongsRemoved, object: nil,
                                        userInfo: ["songs": recovery.songs])
    }
    #endif

    /// The server now names different artwork for this song. Navidrome 0.64
    /// re-encoding the id of the same artwork does not count.
    private nonisolated static func serverReplacedArtwork(from existing: Song, to updated: Song) -> Bool {
        guard let previous = existing.coverArtFileName,
              let current = updated.coverArtFileName,
              previous != current,
              ServerSongCatalogMergePolicy.isServerArtworkReference(previous),
              ServerSongCatalogMergePolicy.isServerArtworkReference(current) else {
            return false
        }
        return !SubsonicSongIdentityCarryPolicy.isCanonicalCoverArtRekey(
            previousReference: previous,
            currentReference: current,
            canonicalID: { NavidromeCanonicalIDPolicy.canonicalID($0) }
        )
    }

    /// Compare fields consumed by song rows, Now Playing, and technical-info
    /// views without invoking Song's synthesized equality. The latter also
    /// walks the potentially large `lyricsText` payload for every track in a
    /// multi-thousand-song rescan.
    private nonisolated static func songPresentationChanged(from old: Song, to new: Song) -> Bool {
        old.title != new.title
            || old.albumID != new.albumID
            || old.artistID != new.artistID
            || old.albumTitle != new.albumTitle
            || old.artistName != new.artistName
            || old.albumArtistName != new.albumArtistName
            || old.trackNumber != new.trackNumber
            || old.discNumber != new.discNumber
            || old.duration != new.duration
            || old.fileFormat != new.fileFormat
            || old.filePath != new.filePath
            || old.sourceID != new.sourceID
            || old.fileSize != new.fileSize
            || old.bitRate != new.bitRate
            || old.sampleRate != new.sampleRate
            || old.bitDepth != new.bitDepth
            || old.genre != new.genre
            || old.year != new.year
            || old.dateAdded != new.dateAdded
            || old.lastModified != new.lastModified
            || old.coverArtFileName != new.coverArtFileName
            || old.artistArtworkFileName != new.artistArtworkFileName
            || old.lyricsFileName != new.lyricsFileName
            || old.mvPath != new.mvPath
            || old.replayGainTrackGain != new.replayGainTrackGain
            || old.replayGainTrackPeak != new.replayGainTrackPeak
            || old.replayGainAlbumGain != new.replayGainAlbumGain
            || old.replayGainAlbumPeak != new.replayGainAlbumPeak
            || old.cueSheetPath != new.cueSheetPath
            || old.cueStartTime != new.cueStartTime
            || old.cueEndTime != new.cueEndTime
            || old.revision != new.revision
    }

    /// 删除路径必须在同一个主线程轮次里把被删的行从可见查找表里摘掉。
    /// `requestLibraryIndexMaintenance(.immediate)` 触发的重建是去抖之后的
    /// 异步任务, 在它落地之前 `song(id:)` / `visibleSong(id:)` /
    /// `visibleSongCount(forSourceID:)` / `playableSongs(forSourceID:)` 仍然
    /// 会从旧字典里答出已经删掉的行; 紧接着运行的 `cleanPlaylistEntries()` /
    /// `cleanPlaybackHistoryEntries()` 也因此认为这些歌还在, 把歌单与最近
    /// 播放里的条目原样留下, 随后的快照又把它们写回磁盘。
    ///
    /// 只摘除以 ID 为键的查找表与按源分组的切片, 代价 O(可见行), 与
    /// `songs.removeAll` 同量级。派生的歌手 / 流派 ID 列表不重建: 它们都通过
    /// `lookupVisibleSong` 解析, 索引里没有了行就已经看不见, 重建那些列表要额外
    /// 付 O(全部歌手) 的开销。
    private func pruneVisibleCachesAfterRemoval(
        removedIDs: Set<String>,
        affectedSourceIDs: Set<String>,
        remainingCountsBySource: [String: Int]
    ) {
        guard !removedIDs.isEmpty else { return }
        // 全库计数含禁用源, 因此即使被删的行都不可见也要对齐。
        for sourceID in affectedSourceIDs {
            let remaining = remainingCountsBySource[sourceID] ?? 0
            if remaining > 0 {
                songCountBySourceID[sourceID] = remaining
            } else {
                songCountBySourceID.removeValue(forKey: sourceID)
            }
        }
        let removedVisibleIDs = removedIDs.filter { visibleSongIndexByID[$0] != nil }
        guard !removedVisibleIDs.isEmpty else { return }

        let displacedIndexByID = visibleSongIndexByID
        let retainedCount = max(visibleSongs.count - removedVisibleIDs.count, 0)
        var nextVisibleSongs: [Song] = []
        nextVisibleSongs.reserveCapacity(retainedCount)
        // 下标会整体前移, 索引必须为保留下来的行重建。
        var rebuiltIndexByID: [String: Int] = [:]
        rebuiltIndexByID.reserveCapacity(retainedCount)
        for song in visibleSongs where !removedVisibleIDs.contains(song.id) {
            rebuiltIndexByID[song.id] = nextVisibleSongs.count
            nextVisibleSongs.append(song)
        }
        let removedSourceIDs = Set(removedVisibleIDs.compactMap { lookupVisibleSong($0)?.sourceID })
        visibleSongs = nextVisibleSongs
        visibleSongIndexByID = rebuiltIndexByID
        // 下标整体前移, 按源的位置表跟着重排一遍 (与上面的数组重建同为 O(可见行))。
        rebuildSourcePositions()
        if musicSongsSharesVisibleSongs { musicSongsRevision &+= 1 }

        for sourceID in affectedSourceIDs.union(removedSourceIDs) {
            // 整组重建不会为空源留下键, 摘除也保持一致。
            let remaining = visibleSongPositionsBySourceID[sourceID]?.count ?? 0
            if remaining == 0 {
                visibleSongCountBySourceID.removeValue(forKey: sourceID)
            } else {
                visibleSongCountBySourceID[sourceID] = remaining
            }
            // `replacedIDs: nil` = 成员发生变化, 与整组重建的发布形状一致。
            sourceSongListStates[sourceID]?.publish(sourceSongs(sourceID), replacedIDs: nil)
        }
        refreshSourceIDsWithPlayableSongs()

        // 兜底封面指向被删的那一首时先摘掉映射, 卡片会在随后的异步重建里拿到
        // 新的回退歌; 留着它只会让读者解析出空封面。
        var artworkLookupsChanged = false
        let staleArtworkAlbumIDs = preferredArtworkSongIDByAlbumID.compactMap {
            removedVisibleIDs.contains($0.value) ? $0.key : nil
        }
        for albumID in staleArtworkAlbumIDs {
            preferredArtworkSongIDByAlbumID.removeValue(forKey: albumID)
            artworkLookupsChanged = true
        }
        let staleArtworkArtistIDs = preferredArtworkSongIDByArtistID.compactMap {
            removedVisibleIDs.contains($0.value) ? $0.key : nil
        }
        for artistID in staleArtworkArtistIDs {
            preferredArtworkSongIDByArtistID.removeValue(forKey: artistID)
            artworkLookupsChanged = true
        }
        if artworkLookupsChanged { albumArtworkLookupRevision &+= 1 }
        visibleSongCollectionRevision &+= 1
        LibraryArrayReclaimer.release(
            holder: DisplacedLibraryLookups([displacedIndexByID]),
            approximateElementCount: displacedIndexByID.count
        )
    }

    /// Delete a single song and rebuild index
    ///
    /// `sourceFileDeleted` 说的是"调用这里之前, 源文件确实已经删掉了(并且删除
    /// 被确认过)"。默认取保守侧 false: 只有 true 的墓碑才可能因为日后同一路径
    /// 上出现另一个文件而被撤销, 所以拿不准的路径必须落在 false 上。
    @discardableResult
    func deleteSong(_ song: Song, sourceFileDeleted: Bool = false) -> Int {
        if deferringUntilReady({ [weak self] in
            _ = self?.deleteSong(song, sourceFileDeleted: sourceFileDeleted)
        }) { return 0 }
        discardRetainedSongs { $0.id == song.id }
        songs.removeAll { $0.id == song.id }
        songIndexByID = Self.makeSongIndex(songs)
        // Tombstone keyed by canonical identity (account+path, not
        // mount-UUID+path) so re-adding the same Baidu account on
        // a fresh source UUID doesn't bypass it.
        deletedSongIdentities.insert(identityKey(for: song))
        recordTombstoneEvidence(for: [song], sourceFileDeleted: sourceFileDeleted)
        recordExclusionsForRetainedSourceFiles([song])
        let remaining = songs.filter { $0.sourceID == song.sourceID }.count
        pruneVisibleCachesAfterRemoval(
            removedIDs: [song.id],
            affectedSourceIDs: [song.sourceID],
            remainingCountsBySource: [song.sourceID: remaining]
        )
        reassignPlaylistMembers(ofRemoved: [song], leavingPlaceholders: false)
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        requestLibraryIndexMaintenance(.immediate)
        persistSongChanges(deletingIDs: [song.id], needsPromptCompatibilitySnapshot: true)
        postSongsRemoved([song], songIDs: [song.id])
        return remaining
    }

    /// Batch delete. Calling `deleteSong` in a 3000-song loop did
    /// `removeAll`/clean*/`rebuildIndex` once per song — O(N) each, so
    /// O(N×K) on the main actor, plus K Observable mutations triggering
    /// view rebuilds; on a 10K-song library with 3K duplicates the
    /// watchdog killed the app. Doing the bulk operations once amortizes
    /// the work to a single O(N) pass.
    @discardableResult
    func deleteSongs(
        _ songsToDelete: [Song],
        sourceFileDeleted: Bool = false
    ) -> [String: Int] {
        guard !songsToDelete.isEmpty else { return [:] }
        if deferringUntilReady({ [weak self] in
            _ = self?.deleteSongs(songsToDelete, sourceFileDeleted: sourceFileDeleted)
        }) { return [:] }
        let idsToDelete = Set(songsToDelete.map(\.id))
        discardRetainedSongs { idsToDelete.contains($0.id) }
        let affectedSourceIDs = Set(songsToDelete.map(\.sourceID))
        for song in songsToDelete {
            deletedSongIdentities.insert(identityKey(for: song))
        }
        recordTombstoneEvidence(for: songsToDelete, sourceFileDeleted: sourceFileDeleted)
        recordExclusionsForRetainedSourceFiles(songsToDelete)
        songs.removeAll { idsToDelete.contains($0.id) }
        songIndexByID = Self.makeSongIndex(songs)
        var remainingCounts = Dictionary(
            uniqueKeysWithValues: affectedSourceIDs.map { ($0, 0) }
        )
        for song in songs where affectedSourceIDs.contains(song.sourceID) {
            remainingCounts[song.sourceID, default: 0] += 1
        }
        // 必须早于歌单 / 最近播放清理: 那两步经 `song(id:)` 解析成员, 可见缓存
        // 还留着被删的行时它们会判定条目仍然有效。
        pruneVisibleCachesAfterRemoval(
            removedIDs: idsToDelete,
            affectedSourceIDs: affectedSourceIDs,
            remainingCountsBySource: remainingCounts
        )
        // 清理重复歌曲删掉的多余版本, 在歌单里换成留下的那一份。
        reassignPlaylistMembers(ofRemoved: songsToDelete, leavingPlaceholders: false)
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        requestLibraryIndexMaintenance(.immediate)
        persistSongChanges(deletingIDs: idsToDelete, needsPromptCompatibilitySnapshot: true)
        postSongsRemoved(songsToDelete, songIDs: idsToDelete)
        return remainingCounts
    }

    /// 给这一批新墓碑记下证据。远端源日后在同一路径上又看到文件时, 只有这份
    /// 签名能回答"是不是另一个文件"—— 陈旧的目录页重放的是旧签名, 所以按签名
    /// 比才挡得住, 而"扫描时间晚于删除时间"挡不住(续扫会重放删除之前暂存的
    /// 目录页, 可以晚到几天之后才交上来)。
    ///
    /// 体积: 未压缩约 276 字节/条(其中一多半是被重复一次的身份键), 但快照上
    /// 传前会压缩, 三千条实测只多 ~17 KB。只给本版本之后产生的墓碑记, 撤销后
    /// 的记录过了保留期由跨设备合并清掉。
    private func recordTombstoneEvidence(for deletedSongs: [Song], sourceFileDeleted: Bool) {
        let now = Date()
        for song in deletedSongs {
            deletedSongIdentityDetails[identityKey(for: song)] = LibrarySongTombstoneDetail(
                deletedAt: now,
                sourceFileDeleted: sourceFileDeleted,
                fileSize: song.fileSize > 0 ? song.fileSize : nil,
                lastModified: song.lastModified,
                revision: song.revision,
                // 重新删除同一路径时证据整条换新, 旧的撤销记录不再有意义 ——
                // `deletedAt` 已经推到现在, 墓碑自然重新生效。
                revivedAt: nil
            )
        }
    }

    /// 删库记录的那一刻源文件还在磁盘上, 说明用户选的是「从资料库移除, 源文件
    /// 保留」(批量删除的 `.libraryOnly`) —— 弹窗明确承诺过"重新扫描时不会再被
    /// 加回"。这类身份同时记进设备本地排除账本, 于是扫描期的墓碑复活会跳过
    /// 它们: 它们的文件本来就一直在, "文件在磁盘上"不构成"用户又把它放回来了"。
    ///
    /// 删源文件、单首删除、重复项清理都是先确认文件删掉了才来删库记录, 所以
    /// 这三条路上探针一律答 false, 什么也不会记。不装探针(tvOS / 测试)时同样
    /// 什么都不记, 行为与历史版本一致。
    ///
    /// 只记身份、不记保留曲目记录: 恢复界面读的是保留目录, 这里不往里放东西,
    /// 所以界面和快照导出都与今天完全一样。
    private func recordExclusionsForRetainedSourceFiles(_ deletedSongs: [Song]) {
        guard let probe = deviceLocalFilePresenceProbe else { return }
        let retainedSongIDs = probe(deletedSongs)
        guard !retainedSongIDs.isEmpty else { return }
        var changed = false
        for song in deletedSongs where retainedSongIDs.contains(song.id) {
            // 两种键形态都写, 与 `removeSongsFromThisDevice` 一致: 账号解析器
            // 要到启动装载之后才装上。
            if deviceLocalExcludedSongIdentities.insert(identityKey(for: song)).inserted {
                changed = true
            }
            if deviceLocalExcludedSongIdentities.insert("\(song.sourceID):\(song.filePath)").inserted {
                changed = true
            }
        }
        guard changed else { return }
        do { try persistDeviceLocalExclusions() }
        catch { plog("Retained-file exclusion update failed: \(error.localizedDescription)") }
    }

    /// Persist the local exclusion before removing rows. Retained catalogue
    /// records keep snapshot mirrors and CloudKit membership unchanged.
    ///
    /// `reason` and `detailsBySongID` are what the per-source recovery screen
    /// shows, so a row removed because a WebDAV share refused DELETE can be
    /// told apart from one the user chose to keep on the server.
    @discardableResult
    func removeSongsFromThisDevice(
        _ songsToRemove: [Song],
        reason: SongLocalRemovalReason = .userKeptRemoteFile,
        detailsBySongID: [String: String] = [:]
    ) throws -> [String: Int] {
        guard !songsToRemove.isEmpty else { return [:] }
        if deferringUntilReady({ [weak self] in
            _ = try? self?.removeSongsFromThisDevice(
                songsToRemove,
                reason: reason,
                detailsBySongID: detailsBySongID
            )
        }) {
            return [:]
        }
        let idsToRemove = Set(songsToRemove.map(\.id))
        let affectedSourceIDs = Set(songsToRemove.map(\.sourceID))
        let previousIdentities = deviceLocalExcludedSongIdentities
        let previousSongs = deviceLocalExcludedSongsByID
        let previousMetadata = deviceLocalRemovalMetadataByID
        let removedAt = Date()
        for song in songsToRemove {
            deviceLocalExcludedSongIdentities.insert(identityKey(for: song))
            // The account resolver is installed after startup snapshot loading.
            deviceLocalExcludedSongIdentities.insert("\(song.sourceID):\(song.filePath)")
            deviceLocalExcludedSongsByID[song.id] = song
            deviceLocalRemovalMetadataByID[song.id] = SongLocalRemovalMetadata(
                reason: reason,
                removedAt: removedAt,
                detail: detailsBySongID[song.id]
            )
        }
        do {
            try persistDeviceLocalExclusions()
        } catch {
            deviceLocalExcludedSongIdentities = previousIdentities
            deviceLocalExcludedSongsByID = previousSongs
            deviceLocalRemovalMetadataByID = previousMetadata
            throw error
        }
        songs.removeAll { idsToRemove.contains($0.id) }
        songIndexByID = Self.makeSongIndex(songs)
        var remainingCounts = Dictionary(
            uniqueKeysWithValues: affectedSourceIDs.map { ($0, 0) }
        )
        for song in songs where affectedSourceIDs.contains(song.sourceID) {
            remainingCounts[song.sourceID, default: 0] += 1
        }
        pruneVisibleCachesAfterRemoval(
            removedIDs: idsToRemove,
            affectedSourceIDs: affectedSourceIDs,
            remainingCountsBySource: remainingCounts
        )
        requestLibraryIndexMaintenance(.immediate)
        persistSongChanges(deletingIDs: idsToRemove, needsPromptCompatibilitySnapshot: true)
        postSongsRemoved(songsToRemove, songIDs: idsToRemove)
        return remainingCounts
    }

    /// 账本的磁盘格式与 v2 → v3 迁移都在 PrimuseKit 里, 便于纯函数测试。
    typealias DeviceLocalExclusionLedger = SongLocalRemovalLedger

    static let legacyLocalRemovalReason = SongLocalRemovalLedger.legacyReason

    private func loadDeviceLocalExclusions() {
        guard let data = try? Data(contentsOf: deviceLocalExclusionURL) else { return }
        guard let ledger = try? JSONDecoder().decode(DeviceLocalExclusionLedger.self, from: data) else {
            plog("Device-local song exclusions unreadable; keeping the file untouched")
            return
        }
        deviceLocalExcludedSongIdentities = Set(ledger.identities)
        let resolved = ledger.resolved()
        deviceLocalExcludedSongsByID = resolved.songs
        deviceLocalRemovalMetadataByID = resolved.metadata
    }

    private func persistDeviceLocalExclusions() throws {
        // S1: 发布前不写设备本地排除账本。
        guard !isPreparing else {
            deferredDeviceLocalExclusionWriteRequested = true
            return
        }
        let retained = deviceLocalExcludedSongsByID.values.sorted { $0.id < $1.id }
        let ledger = DeviceLocalExclusionLedger(
            identities: deviceLocalExcludedSongIdentities.sorted(),
            entries: retained.map { song in
                let metadata = deviceLocalRemovalMetadataByID[song.id]
                return SongLocalRemovalEntry(
                    song: song,
                    reason: metadata?.reason ?? Self.legacyLocalRemovalReason,
                    removedAt: metadata?.removedAt ?? Date(timeIntervalSince1970: 0),
                    detail: metadata?.detail
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: deviceLocalExclusionURL, options: .atomic)
    }

    // MARK: - Device-local removals

    /// Rows this device dropped while the source copy stayed in place.
    ///
    /// Reading `deviceLocalExcludedSongIdentities` first is deliberate: it is
    /// the observed property, and it changes on every removal and restore, so
    /// a view built from this list is invalidated even though the retained
    /// catalogue itself is observation-ignored.
    func locallyRemovedEntries(forSourceID sourceID: String? = nil) -> [SongLocalRemovalEntry] {
        guard !deviceLocalExcludedSongIdentities.isEmpty else { return [] }
        let entries = deviceLocalExcludedSongsByID.values.compactMap { song -> SongLocalRemovalEntry? in
            if let sourceID, song.sourceID != sourceID { return nil }
            let metadata = deviceLocalRemovalMetadataByID[song.id]
            return SongLocalRemovalEntry(
                song: song,
                reason: metadata?.reason ?? Self.legacyLocalRemovalReason,
                removedAt: metadata?.removedAt ?? Date(timeIntervalSince1970: 0),
                detail: metadata?.detail
            )
        }
        return SongLocalRemovalPolicy.sorted(entries)
    }

    /// Cheap enough to call from a source row: the entry point only has to
    /// appear when the source actually has something to recover.
    func locallyRemovedCount(forSourceID sourceID: String) -> Int {
        guard !deviceLocalExcludedSongIdentities.isEmpty else { return 0 }
        return deviceLocalExcludedSongsByID.values.reduce(into: 0) { count, song in
            if song.sourceID == sourceID { count += 1 }
        }
    }

    /// Song ids of the retained rows for one source. A scan needs these to
    /// hold the retained catalogue to the same deletion-confirmation rule as
    /// the live library: a row the user can still recover must not lose its
    /// record because one flaky snapshot failed to list it.
    func locallyRemovedSongIDs(forSourceID sourceID: String) -> Set<String> {
        guard !deviceLocalExcludedSongIdentities.isEmpty else { return [] }
        return Set(
            deviceLocalExcludedSongsByID.values
                .lazy
                .filter { $0.sourceID == sourceID }
                .map(\.id)
        )
    }

    var locallyRemovedSourceIDs: Set<String> {
        guard !deviceLocalExcludedSongIdentities.isEmpty else { return [] }
        return Set(deviceLocalExcludedSongsByID.values.map(\.sourceID))
    }

    /// Undo `removeSongsFromThisDevice`. The retained record goes straight back
    /// into the library, so recovery does not have to wait for a scan — and a
    /// source that can no longer be reached can still be recovered from.
    @discardableResult
    func restoreSongsRemovedFromThisDevice(_ songIDs: [String]) throws -> [String: Int] {
        guard !songIDs.isEmpty else { return [:] }
        if deferringUntilReady({ [weak self] in
            _ = try? self?.restoreSongsRemovedFromThisDevice(songIDs)
        }) {
            return [:]
        }
        let restored = songIDs.compactMap { deviceLocalExcludedSongsByID[$0] }
        guard !restored.isEmpty else { return [:] }

        let previousIdentities = deviceLocalExcludedSongIdentities
        let previousSongs = deviceLocalExcludedSongsByID
        let previousMetadata = deviceLocalRemovalMetadataByID
        for song in restored {
            // Both shapes were written on removal; clearing only one would
            // leave the row blocked by the other on the next load.
            deviceLocalExcludedSongIdentities.remove(identityKey(for: song))
            deviceLocalExcludedSongIdentities.remove("\(song.sourceID):\(song.filePath)")
            deviceLocalExcludedSongsByID[song.id] = nil
            deviceLocalRemovalMetadataByID[song.id] = nil
        }
        do {
            try persistDeviceLocalExclusions()
        } catch {
            deviceLocalExcludedSongIdentities = previousIdentities
            deviceLocalExcludedSongsByID = previousSongs
            deviceLocalRemovalMetadataByID = previousMetadata
            throw error
        }
        // 覆盖解析的 2b / 3b 层读的是保留目录, 恢复后这些歌走正常索引。
        artworkSongIDResolutions.removeAll(keepingCapacity: true)
        let affectedSourceIDs = Set(restored.map(\.sourceID))
        addSongs(
            restored,
            affectedSourceIDs: affectedSourceIDs,
            notifyRemovals: false,
            pruneMissingSongs: false
        )
        markPortableSnapshotDirty()
        var remainingCounts = Dictionary(
            uniqueKeysWithValues: affectedSourceIDs.map { ($0, 0) }
        )
        for song in songs where affectedSourceIDs.contains(song.sourceID) {
            remainingCounts[song.sourceID, default: 0] += 1
        }
        return remainingCounts
    }

    private func discardRetainedSongs(where shouldRemove: (Song) -> Bool) {
        let removed = deviceLocalExcludedSongsByID.values.filter(shouldRemove)
        guard !removed.isEmpty else { return }
        for song in removed {
            deviceLocalExcludedSongsByID[song.id] = nil
            deviceLocalRemovalMetadataByID[song.id] = nil
        }
        // 覆盖解析的 2b / 3b 层读的就是这份保留目录。
        artworkSongIDResolutions.removeAll(keepingCapacity: true)
        // A genuine source deletion or authoritative rescan must not export
        // stale records retained only for a previous local exclusion.
        do { try persistDeviceLocalExclusions() }
        catch { plog("Device-local retained catalogue update failed: \(error.localizedDescription)") }
        markPortableSnapshotDirty()
    }

    /// Reverse a previous `deleteSong` so the next scan can re-add the
    /// path. Caller passes the same Song object that was deleted (or
    /// any Song with the same source/path).
    func restoreDeletedSong(_ song: Song) {
        // S2: 墓碑集合在发布时整体拷回, 排队后重放才能真正撤销删除。
        if deferringUntilReady({ [weak self] in self?.restoreDeletedSong(song) }) { return }
        revokeDeletedSongIdentities([identityKey(for: song)])
    }

    /// 撤销一批全局删除墓碑。单首恢复、本机源的"文件又回到磁盘上"复活、远端源
    /// 的"同一路径换了文件"复活走同一条语义, 免得几处各写一套"什么时候能重新
    /// 入库"。落盘只发一次。
    ///
    /// 光把键从集合里拿掉撑不过一次跨设备同步 —— 另一台设备尚未同步的旧快照
    /// 会在并集里把它原样带回来。所以撤销要在证据表上打 `revivedAt`, 合并时
    /// 按键做 last-writer-wins 才减得掉(见 `LibrarySongTombstoneLedgerMergePolicy`)。
    private func revokeDeletedSongIdentities(_ keys: Set<String>) {
        let revoked = keys.intersection(deletedSongIdentities)
        guard !revoked.isEmpty else { return }
        deletedSongIdentities.subtract(revoked)
        let now = Date()
        for key in revoked {
            if var detail = deletedSongIdentityDetails[key] {
                detail.revivedAt = now
                deletedSongIdentityDetails[key] = detail
            } else {
                // 无证据的旧墓碑(本机源那条规则不需要证据也能放行)也要留下
                // 撤销标记, 否则别的设备的旧快照会把它并回来。删除时刻不可考,
                // 用与设备本地账本同一个纪元哨兵 —— 只要日后真的重新删除,
                // `deletedAt` 会被推到那一刻, 墓碑自然重新生效。
                //
                // 不用 `.distantPast`: 它编码成 `0001-01-01T00:00:00Z`, 而整份
                // 快照共用一个 `.iso8601` 解码器, 万一哪个平台的格式化器不认这
                // 个年份, 坏的就不只是这一条记录, 是整个 library-cache.json。
                deletedSongIdentityDetails[key] = LibrarySongTombstoneDetail(
                    deletedAt: Date(timeIntervalSince1970: 0),
                    sourceFileDeleted: true,
                    revivedAt: now
                )
            }
        }
        persistSnapshot()
    }

    private func postSongsRemoved(
        _ songs: [Song],
        sourceIDs: Set<String>? = nil,
        songIDs: Set<String>? = nil
    ) {
        guard songs.isEmpty == false else { return }
        var userInfo: [String: Any] = [
            "songs": songs,
            "songIDs": songIDs ?? Set(songs.map(\.id)),
        ]
        if let sourceIDs, !sourceIDs.isEmpty {
            userInfo["sourceIDs"] = Array(sourceIDs)
        }
        NotificationCenter.default.post(
            name: .primuseSongsRemoved,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Remove all songs for a given source
    func removeSongsForSource(_ sourceID: String) async {
        await removeSongsForSources([sourceID])
    }

    private struct PreparedSourceSongRemoval: Sendable {
        let retainedSongs: [Song]
        let removedSongs: [Song]
        let retainedIndexByID: [String: Int]
        let removedSongIDs: Set<String>
    }

    /// 仅供测试注入: 拉长离主线程准备的时长, 好让并发的歌曲突变确定性地
    /// 抢在这次整源移除前面落地。生产路径保持 nil。
    @ObservationIgnored var sourceSongRemovalPreparationDelayForTesting: Duration?

    private nonisolated static func prepareSourceSongRemoval(
        songs: [Song],
        sourceIDs: Set<String>
    ) -> PreparedSourceSongRemoval {
        var retainedSongs: [Song] = []
        retainedSongs.reserveCapacity(songs.count)
        var removedSongs: [Song] = []
        removedSongs.reserveCapacity(min(songs.count, 1_024))
        var retainedIndexByID: [String: Int] = [:]
        retainedIndexByID.reserveCapacity(songs.count)
        var removedSongIDs: Set<String> = []

        for song in songs {
            if sourceIDs.contains(song.sourceID) {
                removedSongs.append(song)
                removedSongIDs.insert(song.id)
            } else {
                retainedIndexByID[song.id] = retainedSongs.count
                retainedSongs.append(song)
            }
        }
        return PreparedSourceSongRemoval(
            retainedSongs: retainedSongs,
            removedSongs: removedSongs,
            retainedIndexByID: retainedIndexByID,
            removedSongIDs: removedSongIDs
        )
    }

    /// Remove several sources in one library pass. Repeated per-source
    /// removeAll/playlist cleanup/index rebuild made rapid source deletion
    /// O(sourceCount × librarySize) on the main actor. Partitioning and the
    /// replacement lookup are prepared off-main; a generation fence retries
    /// (at most twice) if another scan/backfill mutation landed while that
    /// snapshot was read, then falls back to in-place preparation.
    @discardableResult
    func removeSongsForSources(_ sourceIDs: Set<String>) async -> Set<String> {
        guard !sourceIDs.isEmpty else { return [] }
        // S2: 异步入口排队它的同步回退路径。
        if deferringUntilReady({ [weak self] in
            self?.removeSongsForSourcesSynchronously(sourceIDs)
        }) { return [] }

        // 持续的扫描 / 回填突变会一直推进 songMutationGeneration。无上限重试
        // 会被这种突变流活活拖住, 所以只离主线程准备两次, 之后退回就地准备:
        // 主线程上快照与应用之间没有窗口, 必然一次成功。
        for _ in 0..<2 {
            let snapshot = songs
            let generation = songMutationGeneration
            let preparationDelay = sourceSongRemovalPreparationDelayForTesting
            let candidate = await Task.detached(priority: .userInitiated) {
                if let preparationDelay { try? await Task.sleep(for: preparationDelay) }
                return Self.prepareSourceSongRemoval(
                    songs: snapshot,
                    sourceIDs: sourceIDs
                )
            }.value
            guard generation == songMutationGeneration else { continue }
            return applyPreparedSourceSongRemoval(candidate, sourceIDs: sourceIDs)
        }

        let prepared = Self.prepareSourceSongRemoval(songs: songs, sourceIDs: sourceIDs)
        return applyPreparedSourceSongRemoval(prepared, sourceIDs: sourceIDs)
    }

    /// `removeSongsForSources` 的同步回退: 就地准备后立即应用。
    /// 仅在 S2 重放排队突变时使用, 此时没有并发突变需要代际围栏。
    private func removeSongsForSourcesSynchronously(_ sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        let prepared = Self.prepareSourceSongRemoval(songs: songs, sourceIDs: sourceIDs)
        _ = applyPreparedSourceSongRemoval(prepared, sourceIDs: sourceIDs)
    }

    @discardableResult
    private func applyPreparedSourceSongRemoval(
        _ prepared: PreparedSourceSongRemoval,
        sourceIDs: Set<String>
    ) -> Set<String> {
        let removedCatalog = sourceIDs.reduce(into: false) { removed, sourceID in
            if automaticArtistArtworkCatalogsBySource.removeValue(forKey: sourceID) != nil {
                removed = true
            }
        }
        if removedCatalog { automaticArtistArtworkCatalogRevision &+= 1 }
        disabledSourceIDs.subtract(sourceIDs)
        let removedRetainedIDs = Set(deviceLocalExcludedSongsByID.values
            .filter { sourceIDs.contains($0.sourceID) }.map(\.id))
        discardRetainedSongs { sourceIDs.contains($0.sourceID) }
        guard !prepared.removedSongs.isEmpty else {
            if !removedRetainedIDs.isEmpty {
                cleanPlaylistEntries()
                cleanPlaybackHistoryEntries()
            }
            if removedCatalog || !removedRetainedIDs.isEmpty { persistSnapshot() }
            return []
        }

        songs = prepared.retainedSongs
        songIndexByID = prepared.retainedIndexByID
        // 整源移除后这些源不再有任何行, 剩余计数一律为 0。同样必须早于歌单 /
        // 最近播放清理。
        pruneVisibleCachesAfterRemoval(
            removedIDs: prepared.removedSongIDs,
            affectedSourceIDs: sourceIDs,
            remainingCountsBySource: [:]
        )
        invalidateSearchCaches()
        reassignPlaylistMembers(ofRemoved: prepared.removedSongs, leavingPlaceholders: true)
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        requestLibraryIndexMaintenance(.immediate)
        persistSongChanges(
            deletingIDs: prepared.removedSongIDs,
            needsPromptCompatibilitySnapshot: true
        )
        postSongsRemoved(
            prepared.removedSongs,
            sourceIDs: sourceIDs,
            songIDs: prepared.removedSongIDs
        )
        return prepared.removedSongIDs
    }

    /// Look up the current Song by its stable id. Used by row views to
    /// re-read after backfill mutates the library in place — passing the
    /// row a snapshot freezes the spinner forever even after duration is
    /// filled, because SwiftUI doesn't always re-build NavigationDestination
    /// views from their parent's latest state.
    func song(id: String) -> Song? {
        // Backfill asks this several times per result. Enabled songs are in the
        // visible cache; disabled songs retain an all-library index. Both paths
        // stay O(1) instead of falling back to a 10K-item scan.
        _ = visibleSongsReference
        if let visibleSong = lookupVisibleSong(id) { return visibleSong }
        guard let index = songIndexByID[id] else { return nil }
        return songs[index]
    }

    /// 资料库里存着的那一行,不经可见集缓存。可见集延后发布,判断「扫描交来的
    /// 这一行是否和库里一样」必须比对这一份,否则会把刚提交的改动当成没变。
    func storedSong(id: String) -> Song? {
        songIndexByID[id].map { songs[$0] }
    }

    /// 把这一行交给 `addSongs` 会不会改变库里的任何东西。库里的行已经补过派生
    /// ID 与自动艺术家图,所以原样不同时按合并时的同一套规则补齐再比;原样相同的
    /// (重扫时的绝大多数)不必再算哈希。
    func matchesStoredSong(_ song: Song) -> Bool {
        guard let stored = storedSong(id: song.id) else { return false }
        if stored == song { return true }
        var prepared = song
        Self.fillDerivedIDs(&prepared, configuration: artistNameConfiguration)
        applyAutomaticArtistArtwork(to: &prepared)
        return stored == prepared
    }

    /// O(1) visible-only lookup for background workers and external routes.
    /// Unlike `song(id:)`, this deliberately excludes disabled sources.
    func visibleSong(id: String) -> Song? {
        _ = visibleSongsReference
        return lookupVisibleSong(id)
    }

    /// O(1) artist lookup for artwork cells. Reading the reference preserves
    /// Observation invalidation when a scan rebuilds automatic artwork.
    func visibleArtist(id: String) -> Artist? {
        _ = visibleArtistsReference
        return visibleArtistByID[id]
    }

    /// 「专辑艺术家」列表里的那一项；只当过专辑艺人的人（「群星」）只在这里有。
    func visibleAlbumArtist(id: String) -> Artist? {
        _ = visibleAlbumArtistsReference
        return visibleAlbumArtistByID[id]
    }

    /// O(1) album lookup. 快捷收藏这类"按 id 取回少量条目"的视图不该对整个
    /// 专辑数组做线性扫描 —— 一万张专辑时每渲染一次就是几万次比较。
    func visibleAlbum(id: String) -> Album? {
        _ = visibleAlbumsReference
        return visibleAlbumByID[id]
    }

    /// O(1) lookup for views whose structural invalidation is driven by
    /// `visibleSongCollectionRevision` and `songReplacementToken` explicitly.
    /// Avoiding a read of `visibleSongsReference` prevents one metadata update
    /// from invalidating an entire large list; existing row models are patched
    /// through the replacement token, while newly-created rows resolve the
    /// latest value here.
    func unobservedVisibleSong(id: String) -> Song? {
        lookupVisibleSong(id)
    }

    /// O(1) through the index into the current visible array. The ID check
    /// keeps a lookup honest across the few statements where a new array and
    /// its index are assigned one after the other.
    private func lookupVisibleSong(_ id: String) -> Song? {
        guard let index = visibleSongIndexByID[id] else { return nil }
        let songs = visibleSongsLookupReference.value
        guard songs.indices.contains(index) else { return nil }
        let song = songs[index]
        return song.id == id ? song : nil
    }

    /// A read-only view of the visible songs for work that runs off the main
    /// actor (preparing a whole-library queue). Copy-on-write: taking it costs
    /// nothing, and later library changes don't affect it.
    func visibleSongLookup() -> VisibleSongLookup {
        VisibleSongLookup(indexByID: visibleSongIndexByID, songs: visibleSongsLookupReference.value)
    }

    /// O(1) membership check for UI observers that must distinguish the
    /// enabled/visible library from songs retained under a disabled source.
    func containsVisibleSong(id: String) -> Bool {
        _ = visibleSongsReference
        return lookupVisibleSong(id) != nil
    }

    /// The source's playable songs, in library order.
    func playableSongs(forSourceID sourceID: String) -> [Song] {
        _ = visibleSongsReference
        let songs = sourceSongs(sourceID)
        return sourceIDsWithUnplayableSongs.contains(sourceID) ? songs.filter(\.isPlayable) : songs
    }

    /// 写之前先比, 内容一样就不惊动观察者。
    private func refreshSourceIDsWithPlayableSongs() {
        var next: Set<String> = []
        for (sourceID, positions) in visibleSongPositionsBySourceID where !positions.isEmpty {
            if !sourceIDsWithUnplayableSongs.contains(sourceID)
                || sourceSongs(sourceID).contains(where: \.isPlayable) {
                next.insert(sourceID)
            }
        }
        guard next != sourceIDsWithPlayableSongs else { return }
        sourceIDsWithPlayableSongs = next
    }

    /// The source's visible songs, in library order.
    func visibleSongs(forSourceID sourceID: String) -> [Song] {
        _ = visibleSongsReference
        return sourceSongs(sourceID)
    }

    /// A source holding every visible song is the visible array itself;
    /// other sources are gathered from their positions once per visible array.
    private func sourceSongs(_ sourceID: String) -> [Song] {
        guard let positions = visibleSongPositionsBySourceID[sourceID], !positions.isEmpty else { return [] }
        let visible = visibleSongsLookupReference.value
        if positions.count == visible.count { return visible }
        if let cached = materializedSourceSongs[sourceID] { return cached }
        var songs: [Song] = []
        songs.reserveCapacity(positions.count)
        for position in positions where visible.indices.contains(position) {
            songs.append(visible[position])
        }
        materializedSourceSongs[sourceID] = songs
        return songs
    }

    private func rebuildSourcePositions() {
        var positions: [String: [Int]] = [:]
        var unplayable: Set<String> = []
        for (index, song) in visibleSongsLookupReference.value.enumerated() {
            positions[song.sourceID, default: []].append(index)
            if !song.isPlayable { unplayable.insert(song.sourceID) }
        }
        visibleSongPositionsBySourceID = positions
        sourceIDsWithUnplayableSongs = unplayable
    }

    func sourceSongListState(for sourceID: String) -> LibrarySourceSongListState {
        if let state = sourceSongListStates[sourceID] { return state }
        let state = LibrarySourceSongListState(songs: sourceSongs(sourceID))
        sourceSongListStates[sourceID] = state
        return state
    }

    /// After songs were replaced in place (same positions): hand each open
    /// source list its fresh slice, and keep the playable bookkeeping honest.
    private func patchSourceAssetReferences(songIDs: [String], invalidatesSort: Bool = false) {
        var replacedBySource: [String: Set<String>] = [:]
        for id in songIDs {
            guard let song = lookupVisibleSong(id) else { continue }
            replacedBySource[song.sourceID, default: []].insert(id)
            if !song.isPlayable { sourceIDsWithUnplayableSongs.insert(song.sourceID) }
        }
        for (sourceID, replacedIDs) in replacedBySource {
            sourceSongListStates[sourceID]?.publish(
                sourceSongs(sourceID), replacedIDs: replacedIDs, invalidatesSort: invalidatesSort
            )
        }
        if invalidatesSort { refreshSourceIDsWithPlayableSongs() }
    }

    func visibleSongCount(forSourceID sourceID: String) -> Int {
        _ = visibleSongsReference
        return visibleSongCountBySourceID[sourceID, default: 0]
    }

    /// 精确的单源计数, 不吃 `songCountsBySourceID()` 的"总数相等就复用缓存"
    /// 启发式: 扫描的最终提交写进源卡片的数字必须是这一刻的真值, 而缓存聚合
    /// 可能还落后几秒的派生重建。`lazy` 让它只走一遍 `songs`, 不为计数分配
    /// 一整份匹配歌曲数组。
    func exactSongCount(forSourceID sourceID: String) -> Int {
        songs.lazy.filter { $0.sourceID == sourceID }.count
    }

    /// Snapshot-sized dictionary (normally only a handful of sources), backed
    /// by the cached all-library aggregate prepared with the song lookups.
    func songCountsBySourceID() -> [String: Int] {
        guard songCountBySourceID.values.reduce(0, +) == songs.count else {
            return Self.makeSongCountsBySourceID(songs)
        }
        return songCountBySourceID
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

    func libraryReview(for subject: LibraryReviewSubject) -> LibraryReview? {
        _ = libraryReviewRevision
        let review = storedLibraryReview(for: subject)
        return review?.isDeleted == false ? review : nil
    }

    func storedLibraryReview(for subject: LibraryReviewSubject) -> LibraryReview? {
        let exact = libraryReviewsBySubject[subject.storageKey]
        guard subject.kind == .song,
              let song = songForSynchronization(id: subject.entityID),
              let target = serverRatingTargetProvider?(song) else { return exact }
        let candidates = libraryReviewsBySubject.values.filter {
            $0.serverRatingTarget == target || ($0.subject == subject && $0.serverRatingTarget == nil)
        }
        return candidates.reduce(nil as LibraryReview?) { result, next in
            result.map { LibraryReviewReconciliationPolicy.winner(local: $0, remote: next) } ?? next
        }
    }

    func review(forServerRatingTarget target: ServerSongRatingTarget) -> LibraryReview? {
        libraryReviewsBySubject.values.filter { $0.serverRatingTarget == target }
            .reduce(nil as LibraryReview?) { result, next in
                result.map { LibraryReviewReconciliationPolicy.winner(local: $0, remote: next) } ?? next
            }
    }

    func bindServerRating(_ target: ServerSongRatingTarget, to subject: LibraryReviewSubject) -> LibraryReview? {
        guard var review = libraryReviewsBySubject[subject.storageKey],
              review.serverRatingTarget == nil, review.rating != nil, !review.isDeleted else { return nil }
        review.serverRatingTarget = target
        libraryReviewsBySubject[subject.storageKey] = review
        libraryReviewRevision &+= 1
        persistSnapshot(after: 0.2)
        return review
    }

    /// 音乐源只换了线路（加外网地址、换 QuickConnect / FN Connect ID…）时，把绑在
    /// 旧线路账号指纹上的评分改绑到新值。账号指纹的算法含线路，不改绑的话这些评分
    /// 在界面上查不到（`storedLibraryReview` 只认当前算出来的目标）。
    func rebindServerRatingTargets(
        sourceID: String,
        fromAccountFingerprint previous: String,
        toAccountFingerprint current: String
    ) {
        guard previous != current else { return }
        // S2: 发布前的改动会被存储里的值整体覆盖，排队到发布后再做。
        if deferringUntilReady({ [weak self] in
            self?.rebindServerRatingTargets(
                sourceID: sourceID,
                fromAccountFingerprint: previous,
                toAccountFingerprint: current
            )
        }) { return }
        var changed = false
        for (key, review) in libraryReviewsBySubject {
            guard let target = review.serverRatingTarget,
                  target.sourceID == sourceID,
                  target.accountFingerprint == previous else { continue }
            var rebound = review
            rebound.serverRatingTarget = ServerSongRatingTarget(
                sourceID: target.sourceID,
                itemID: target.itemID,
                accountFingerprint: current,
                itemKind: target.itemKind
            )
            libraryReviewsBySubject[key] = rebound
            changed = true
        }
        guard changed else { return }
        libraryReviewRevision &+= 1
        persistSnapshot(after: 0.2)
    }

    /// 按服务端条目建一次现有评分的表,不再每条都把全部评分过滤一遍(评分上千条时
    /// 回前台就是几百万次比较,#182)。写进一条后表作废,下一条按写过的状态重建。
    func restoreLocallyAuthoredServerRatings(_ reviews: [LibraryReview]) {
        var reviewsByTarget: [ServerSongRatingTarget: LibraryReview]?
        var changed = false
        for review in reviews {
            guard let target = review.serverRatingTarget else { continue }
            let byTarget = reviewsByTarget ?? reviewsByServerRatingTarget()
            reviewsByTarget = byTarget
            let current = byTarget[target] ?? libraryReviewsBySubject[review.subject.storageKey]
            guard current.map({ $0.ratingVersion < review.ratingVersion }) ?? true else { continue }
            let restored = current.map {
                LibraryReviewReconciliationPolicy.winner(local: review, remote: $0)
            } ?? review
            libraryReviewsBySubject[restored.subject.storageKey] = restored
            reviewsByTarget = nil
            changed = true
        }
        guard changed else { return }
        libraryReviewRevision &+= 1
        persistSnapshot(after: 0.2)
    }

    /// 与逐个调用 `review(forServerRatingTarget:)` 的结果相同:同一条目的评分按同样的顺序取胜者。
    private func reviewsByServerRatingTarget() -> [ServerSongRatingTarget: LibraryReview] {
        var result: [ServerSongRatingTarget: LibraryReview] = [:]
        for review in libraryReviewsBySubject.values {
            guard let target = review.serverRatingTarget else { continue }
            result[target] = result[target].map {
                LibraryReviewReconciliationPolicy.winner(local: $0, remote: review)
            } ?? review
        }
        return result
    }

    /// 把扫描读到、别的客户端改过的服务端评分写回本机。和用户在本机改评分不同:不经
    /// `ratingStateMutationHandler`,不会被当成本机改动再上传回去。时钟取当下,别的设备上
    /// 更早的改动合并时让位给它;评论不动。
    @discardableResult
    func applyServerObservedRating(
        _ rating: Int?,
        to subject: LibraryReviewSubject,
        target: ServerSongRatingTarget,
        observedAt: Date = Date()
    ) -> LibraryReview? {
        guard readiness == .ready else { return nil }
        let rating = LibraryReviewPreferences.normalizedRating(rating)
        let existing = storedLibraryReview(for: subject)
        let current = existing?.isDeleted == false ? existing?.rating : nil
        guard current != rating else { return existing }
        let comment = existing?.isDeleted == false ? existing?.comment ?? "" : ""
        let version = max(
            observedAt.timeIntervalSince1970,
            max(existing?.ratingVersion ?? -.infinity, existing?.commentVersion ?? -.infinity).nextUp
        )
        let shouldDelete = rating == nil && comment.isEmpty
        var review = LibraryReview(
            subject: subject,
            rating: rating,
            comment: comment,
            updatedAt: Date(timeIntervalSince1970: version),
            deletedAt: shouldDelete ? Date(timeIntervalSince1970: version) : nil
        )
        review.ratingModifiedAt = version
        review.commentModifiedAt = existing?.commentVersion ?? 0
        review.serverRatingTarget = target
        review.ratingFromServer = rating == nil ? nil : true
        libraryReviewsBySubject[subject.storageKey] = review
        libraryReviewRevision &+= 1
        persistSnapshot(after: 0.2)
        return review
    }

    func presentServerRatingError() {
        serverRatingErrorMessage = String(localized: "server_rating_sync_failed_message")
    }

    func dismissServerRatingError() {
        serverRatingErrorMessage = nil
    }

    func updateLibraryReview(
        for subject: LibraryReviewSubject,
        rating: Int?,
        comment: String,
        updatedAt: Date = Date()
    ) {
        // S2: 评分评论在发布时被存储里的值整体覆盖, 必须排队重放。
        if deferringUntilReady({ [weak self] in
            self?.updateLibraryReview(
                for: subject,
                rating: rating,
                comment: comment,
                updatedAt: updatedAt
            )
        }) { return }
        let rating = LibraryReviewPreferences.normalizedRating(rating)
        let comment = LibraryReviewPreferences.normalizedComment(comment)
        let existing = storedLibraryReview(for: subject)

        guard existing?.rating != rating || existing?.comment != comment else { return }

        let shouldDelete = rating == nil && comment.isEmpty
        if shouldDelete, existing == nil { return }

        let changedRating = existing?.rating != rating
        let version = max(
            updatedAt.timeIntervalSince1970,
            max(existing?.ratingVersion ?? -.infinity, existing?.commentVersion ?? -.infinity).nextUp
        )
        var review = LibraryReview(
            subject: subject,
            rating: shouldDelete ? nil : rating,
            comment: shouldDelete ? "" : comment,
            updatedAt: Date(timeIntervalSince1970: version),
            deletedAt: shouldDelete ? Date(timeIntervalSince1970: version) : nil
        )
        review.ratingModifiedAt = changedRating ? version : (existing?.ratingVersion ?? 0)
        review.commentModifiedAt = (existing?.comment ?? "") != comment
            ? version : (existing?.commentVersion ?? 0)
        if changedRating, subject.kind == .song,
           let song = songForSynchronization(id: subject.entityID) {
            review.serverRatingTarget = serverRatingTargetProvider == nil
                ? existing?.serverRatingTarget : serverRatingTargetProvider?(song)
        } else {
            review.serverRatingTarget = existing?.serverRatingTarget
        }
        // 本机改了评分,它就不再是服务端读回的值;只改评论时保留原来的出处。
        review.ratingFromServer = changedRating ? nil : existing?.ratingFromServer
        libraryReviewsBySubject[subject.storageKey] = review
        libraryReviewRevision &+= 1
        persistSnapshot(after: 0.2)
        if changedRating { ratingStateMutationHandler?(review) }
    }

    /// 专辑 / 艺人简介;删掉的不返回。
    func libraryInsightRecord(id: String) -> LibraryInsightRecord? {
        guard let record = libraryInsightRecordsByID[id], !record.isDeleted else { return nil }
        return record
    }

    /// 连墓碑一起返回:新版本要排在它后面。
    func storedLibraryInsightRecord(id: String) -> LibraryInsightRecord? {
        libraryInsightRecordsByID[id]
    }

    /// 保存一份简介(删除就是保存墓碑)。比现有的旧才落盘,和同步合并用同一条规则。
    /// 每次落盘都是整库快照:批量补简介传更长的 `persistAfter`,把连着存的几十份并成一次写。
    func saveLibraryInsightRecord(_ record: LibraryInsightRecord, persistAfter delay: TimeInterval = 0.2) {
        // S2: 发布时存储里的值会整体覆盖内存,必须排队重放。
        if deferringUntilReady({ [weak self] in self?.saveLibraryInsightRecord(record, persistAfter: delay) }) { return }
        if let existing = libraryInsightRecordsByID[record.id] {
            guard existing != record, LibraryInsightEditing.winner(existing, record) == record else { return }
        }
        libraryInsightRecordsByID[record.id] = record
        libraryInsightRevision &+= 1
        persistSnapshot(after: delay)
    }

    func songs(forAlbum albumID: String) -> [Song] {
        AlbumTrackOrder.sorted(visibleSongs.filter { $0.albumID == albumID })
    }

    func preferredArtworkSong(forAlbumID albumID: String) -> Song? {
        _ = albumArtworkLookupRevision
        _ = songReplacementToken
        guard let songID = preferredArtworkSongIDByAlbumID[albumID] else { return nil }
        return lookupVisibleSong(songID)
    }

    func preferredArtworkSong(forArtistID artistID: String) -> Song? {
        _ = albumArtworkLookupRevision
        _ = songReplacementToken
        guard let songID = preferredArtworkSongID(forArtistID: artistID) else { return nil }
        return lookupVisibleSong(songID)
    }

    /// 艺人头像的回退歌。只当过专辑艺人的人（「群星」）没有自己署名的歌，
    /// 用名下专辑里第一张有封面的专辑的首选歌。
    private func preferredArtworkSongID(forArtistID artistID: String) -> String? {
        if let songID = preferredArtworkSongIDByArtistID[artistID] { return songID }
        guard let albumIDs = albumIDsByAlbumOnlyArtistID[artistID] else { return nil }
        var fallback: String?
        for albumID in albumIDs {
            guard let songID = preferredArtworkSongIDByAlbumID[albumID] else { continue }
            if lookupVisibleSong(songID)?.coverArtFileName?.isEmpty == false { return songID }
            if fallback == nil { fallback = songID }
        }
        return fallback
    }

    // MARK: - 按条目失效的封面查找

    /// 一张专辑 / 一个艺人自己的封面版本。上面两个 `preferredArtworkSong` 读的是
    /// 整库级的版本号: 扫描每入库一批就会有新专辑加入, 屏幕上每张已经挂着的封面
    /// 卡片都跟着失效重算。卡片改读这里, 只有它自己的首选歌曲、那首歌的封面
    /// 引用、艺人自己的封面字段真的变了才失效。
    private enum ArtworkLookupKey: Hashable {
        case album(String)
        case artist(String)
    }

    @ObservationIgnored private var artworkLookupTokens: [ArtworkLookupKey: LibraryArtworkLookupToken] = [:]
    @ObservationIgnored private var artworkLookupIdentities: [ArtworkLookupKey: String] = [:]
    @ObservationIgnored private var artworkLookupTokenRefreshScheduled = false

    /// 专辑卡片用: 只在这张专辑的首选封面歌曲或它的封面引用变了时失效。
    func scopedPreferredArtworkSong(forAlbumID albumID: String) -> Song? {
        _ = artworkLookupToken(for: .album(albumID)).revision
        guard let songID = preferredArtworkSongIDByAlbumID[albumID] else { return nil }
        return lookupVisibleSong(songID)
    }

    /// 艺人卡片用: 同上, 另外跟着这个艺人自己的名字和封面引用。
    func scopedPreferredArtworkSong(forArtistID artistID: String) -> Song? {
        _ = artworkLookupToken(for: .artist(artistID)).revision
        guard let songID = preferredArtworkSongID(forArtistID: artistID) else { return nil }
        return lookupVisibleSong(songID)
    }

    /// 艺人卡片用的当前艺人值, 失效范围同 `scopedPreferredArtworkSong(forArtistID:)`。
    /// `visibleArtist(id:)` 读的是整份艺人数组, 扫描时每次入库都会让它失效。
    func scopedVisibleArtist(id artistID: String) -> Artist? {
        _ = artworkLookupToken(for: .artist(artistID)).revision
        return visibleArtistByID[artistID]
    }

    private func artworkLookupToken(for key: ArtworkLookupKey) -> LibraryArtworkLookupToken {
        if let token = artworkLookupTokens[key] { return token }
        let token = LibraryArtworkLookupToken()
        artworkLookupTokens[key] = token
        artworkLookupIdentities[key] = artworkLookupIdentity(for: key)
        return token
    }

    private func artworkLookupIdentity(for key: ArtworkLookupKey) -> String {
        func songIdentity(_ songID: String?) -> String {
            guard let songID, let song = lookupVisibleSong(songID) else { return "" }
            return [
                song.id,
                song.coverArtFileName ?? "",
                song.revision ?? "",
                song.sourceID,
                song.filePath,
                song.fileFormat.rawValue,
            ].joined(separator: "\u{1F}")
        }
        switch key {
        case .album(let albumID):
            return songIdentity(preferredArtworkSongIDByAlbumID[albumID])
        case .artist(let artistID):
            let artist = visibleArtistByID[artistID]
            return [
                artist == nil ? "-" : "+",
                artist?.name ?? "",
                artist?.thumbnailPath ?? "",
                songIdentity(preferredArtworkSongID(forArtistID: artistID)),
            ].joined(separator: "\u{1E}")
        }
    }

    /// 查找表的几条发布路径各自在不同时刻换掉字典与版本号, 所以不在某一个
    /// 赋值点上当场比对, 而是排到这一轮主线程工作之后比一次, 那时查找表已经
    /// 是一致的新状态。只比对有卡片读过的那些条目, 成本随挂过的卡片数走。
    private func scheduleArtworkLookupTokenRefresh() {
        guard !artworkLookupTokens.isEmpty, !artworkLookupTokenRefreshScheduled else { return }
        artworkLookupTokenRefreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshArtworkLookupTokens()
        }
    }

    private func refreshArtworkLookupTokens() {
        artworkLookupTokenRefreshScheduled = false
        for (key, token) in artworkLookupTokens {
            let identity = artworkLookupIdentity(for: key)
            guard artworkLookupIdentities[key] != identity else { continue }
            artworkLookupIdentities[key] = identity
            token.revision &+= 1
        }
    }

    private func promotePreferredArtworkSongIfNeeded(_ song: Song) {
        guard lookupVisibleSong(song.id) != nil else { return }
        var changed = false
        if let albumID = song.albumID, !albumID.isEmpty {
            let current = preferredArtworkSongIDByAlbumID[albumID]
                .flatMap { lookupVisibleSong($0) }
            if current.map({ Self.artworkFallbackPrecedes(song, $0) }) != false {
                preferredArtworkSongIDByAlbumID[albumID] = song.id
                changed = true
            }
        }
        for artistID in artistIDs(for: song) {
            let current = preferredArtworkSongIDByArtistID[artistID]
                .flatMap { lookupVisibleSong($0) }
            if current.map({ Self.artworkFallbackPrecedes(song, $0) }) != false {
                preferredArtworkSongIDByArtistID[artistID] = song.id
                changed = true
            }
        }
        if changed { albumArtworkLookupRevision &+= 1 }
    }

    /// 首选回退歌的 ID 没变、变的是它自己的封面引用时, 回退映射一模一样, 但
    /// 每一张用它兜底的专辑 / 歌手卡片都要重新取图。只盯
    /// `albumArtworkLookupRevision` 的读者 (资料库快捷入口、CarPlay 编辑器
    /// 预览) 否则会一直停在旧图 / 占位图上。O(改动行)。
    private func bumpArtworkLookupRevisionIfPreferred(songIDs: [String]) {
        for songID in songIDs {
            guard let song = lookupVisibleSong(songID) else { continue }
            if let albumID = song.albumID,
               !albumID.isEmpty,
               preferredArtworkSongIDByAlbumID[albumID] == songID {
                albumArtworkLookupRevision &+= 1
                return
            }
            if artistIDs(for: song).contains(where: {
                preferredArtworkSongIDByArtistID[$0] == songID
            }) {
                albumArtworkLookupRevision &+= 1
                return
            }
        }
    }

    // MARK: - User-selected library artwork

    func artworkOverride(for owner: LibraryArtworkOwner) -> LibraryArtworkOverride? {
        artworkOverridesByOwner[owner.storageKey]
    }

    func artworkOverride(cloudRecordID: String) -> LibraryArtworkOverride? {
        guard let owner = LibraryArtworkOwner.fromCloudRecordID(cloudRecordID) else { return nil }
        return artworkOverride(for: owner)
    }

    func artworkOverrideResolution(
        for owner: LibraryArtworkOwner,
        eligibleSongs: [Song]
    ) -> LibraryArtworkOverrideResolution {
        let override = artworkOverride(for: owner)
        return LibraryArtworkOverridePolicy.resolve(override: override) {
            guard let identity = override?.selectedSongIdentity,
                  let resolvedSongID = resolveArtworkSongID(identity, for: owner) else {
                return nil
            }
            return (
                songID: resolvedSongID,
                isEligible: eligibleSongs.contains { $0.id == resolvedSongID }
            )
        }
    }

    struct ArtworkPresentation {
        let resolution: LibraryArtworkOverrideResolution
        let selectedSong: Song?

        var uploadedContentID: String? {
            guard case .uploaded(let contentID) = resolution else { return nil }
            return contentID
        }
    }

    /// Resolves the lightweight override state used by artwork views without
    /// materializing every song in an album or playlist. Automatic and uploaded
    /// modes never touch song membership; selected-song mode performs only an
    /// indexed lookup in the common case.
    func artworkPresentation(for owner: LibraryArtworkOwner) -> ArtworkPresentation {
        let override = artworkOverride(for: owner)
        var selectedSong: Song?
        let resolution = LibraryArtworkOverridePolicy.resolve(override: override) {
            guard let identity = override?.selectedSongIdentity,
                  let resolvedSongID = resolveArtworkSongID(identity, for: owner) else {
                return nil
            }
            guard let song = visibleSong(id: resolvedSongID) else {
                return (songID: resolvedSongID, isEligible: false)
            }

            let isEligible: Bool
            switch owner.kind {
            case .album:
                isEligible = song.albumID == owner.id
            case .artist:
                isEligible = visibleSongIDsByArtistID[owner.id]?.contains(resolvedSongID) == true
            case .playlist:
                isEligible = playlistSongIDs[owner.id]?.contains(resolvedSongID) == true
            }
            if isEligible {
                selectedSong = song
            }
            return (songID: resolvedSongID, isEligible: isEligible)
        }
        return ArtworkPresentation(
            resolution: resolution,
            selectedSong: selectedSong
        )
    }

    func artworkSong(
        for owner: LibraryArtworkOwner,
        eligibleSongs: [Song]
    ) -> Song? {
        guard case .selectedSong(let songID) = artworkOverrideResolution(
            for: owner,
            eligibleSongs: eligibleSongs
        ) else { return nil }
        return eligibleSongs.first(where: { $0.id == songID })
    }

    /// Replaces one source's authoritative directory-artwork topology and
    /// reapplies it to songs whose artist metadata is already known. Bare
    /// first-scan rows are resolved later by `replaceSong(s)` after metadata
    /// backfill fills their artist names.
    func updateAutomaticArtistArtworkCatalog(_ catalog: SourceArtistArtworkCatalog, isCompleteListing: Bool = true) {
        // S2: 目录表与它改写的 songs 都在发布时被拷回覆盖。
        if deferringUntilReady({ [weak self] in
            self?.updateAutomaticArtistArtworkCatalog(catalog, isCompleteListing: isCompleteListing)
        }) { return }
        let catalog = isCompleteListing ? catalog
            : automaticArtistArtworkCatalogsBySource[catalog.sourceID]?.merging(catalog) ?? catalog
        guard !catalog.sourceID.isEmpty,
              automaticArtistArtworkCatalogsBySource[catalog.sourceID] != catalog else {
            return
        }
        automaticArtistArtworkCatalogsBySource[catalog.sourceID] = catalog
        automaticArtistArtworkCatalogRevision &+= 1

        var nextSongs = songs
        var changedSongs: [Song] = []
        for index in nextSongs.indices where nextSongs[index].sourceID == catalog.sourceID {
            let previousReference = nextSongs[index].artistArtworkFileName
            applyAutomaticArtistArtwork(to: &nextSongs[index])
            if nextSongs[index].artistArtworkFileName != previousReference {
                changedSongs.append(nextSongs[index])
            }
        }
        guard !changedSongs.isEmpty else {
            persistSnapshot()
            return
        }
        // 这个突变只写 `artistArtworkFileName`: 歌曲 ID 与顺序都不变, 所以
        // `songIndexByID` 已经是对的, 可见成员与排序也没变。整库重组一遍
        // (分组 + 排序 + 每一本查找表) 是同步压在主线程上的 O(全库) 工作,
        // 而且紧接着的 `.immediate` 重建会在几百毫秒内再算一次同样的结果。
        // 改成 O(改动行) 的就地补丁, 与旁挂资源补丁走同一条已验证的路径。
        let changedSongIDs = changedSongs.map(\.id)
        let visibleSharesSongs = sharesStorage(visibleSongs, songs)
        var nextVisible = visibleSharesSongs ? nextSongs : visibleSongs
        var visibleChanged = visibleSharesSongs
        if !visibleSharesSongs {
            for song in changedSongs {
                guard let visibleIndex = visibleSongIndexByID[song.id] else { continue }
                nextVisible[visibleIndex] = song
                visibleChanged = true
            }
        }
        songs = nextSongs
        if visibleChanged { visibleSongs = nextVisible }
        // 按源分组的切片与 macOS 源详情列表由这条既有接缝保持一致。
        patchSourceAssetReferences(songIDs: changedSongIDs)
        // 回退映射本身不会变 (`artworkFallbackPrecedes` 只看封面 / 碟号 /
        // 音轨号 / ID), 但被选为回退的那一首自己的歌手图引用变了时, 只盯
        // `albumArtworkLookupRevision` 的读者仍然要失效。
        bumpArtworkLookupRevisionIfPreferred(songIDs: changedSongIDs)
        // 不动 `visibleSongCollectionRevision`: 成员与顺序都没变, bump 它会让
        // 每一个大列表白白重建。
        lastReplacedSong = changedSongs.count == 1 ? changedSongs.first : nil
        lastReplacedSongIDs = Set(changedSongIDs)
        songReplacementToken = UUID()
        requestLibraryIndexMaintenance(.immediate)
        persistSongChanges(upserts: changedSongs)
    }

    private func applyAutomaticArtistArtwork(to song: inout Song) {
        Self.applyAutomaticArtistArtwork(
            to: &song,
            catalogsBySource: automaticArtistArtworkCatalogsBySource,
            artistNameConfiguration: artistNameConfiguration
        )
    }

    private nonisolated static func applyAutomaticArtistArtwork(
        to song: inout Song,
        catalogsBySource: [String: SourceArtistArtworkCatalog],
        artistNameConfiguration: ArtistNameConfiguration
    ) {
        // A media server's own artist image is authoritative automatic
        // artwork. Directory discovery only owns values carrying its marker.
        if let current = song.artistArtworkFileName,
           AutomaticArtistArtworkReference.resolve(current) == nil {
            return
        }
        guard let catalog = catalogsBySource[song.sourceID] else {
            return
        }
        song.artistArtworkFileName = catalog.automaticReference(
            forSongID: song.id,
            artistNames: Self.resolvedArtistNames(
                for: song,
                configuration: artistNameConfiguration
            )
        )
    }

    @discardableResult
    func setAutomaticArtwork(for owner: LibraryArtworkOwner) -> Bool {
        setArtworkOverride(
            owner: owner,
            mode: .automatic,
            selectedSongIdentity: nil,
            uploadedContentID: nil
        )
    }

    @discardableResult
    func setArtwork(for owner: LibraryArtworkOwner, to song: Song) -> Bool {
        setArtworkOverride(
            owner: owner,
            mode: .selectedSong,
            selectedSongIdentity: portableSongIdentity(for: song),
            uploadedContentID: nil
        )
    }

    @discardableResult
    func setUploadedArtwork(contentID: String, for owner: LibraryArtworkOwner) -> Bool {
        guard LibraryArtworkContentIDPolicy.isValid(contentID),
              MetadataAssetStore.shared.hasCustomArtwork(contentID: contentID) else {
            return false
        }
        return setArtworkOverride(
            owner: owner,
            mode: .uploaded,
            selectedSongIdentity: nil,
            uploadedContentID: contentID
        )
    }

    private func setArtworkOverride(
        owner: LibraryArtworkOwner,
        mode: LibraryArtworkOverrideMode,
        selectedSongIdentity: SongIdentity?,
        uploadedContentID: String?
    ) -> Bool {
        guard !owner.id.isEmpty else { return false }
        // S2: `setAutomaticArtwork` / `setArtwork` / `setUploadedArtwork` 三个入口
        // 共用这里, 排队一次即可。返回 true 表示"已接受", 与 S1 下
        // `persistPlaylistDurabilityLedger()` 返回 true 的约定一致。
        if deferringUntilReady({ [weak self] in
            _ = self?.setArtworkOverride(
                owner: owner,
                mode: mode,
                selectedSongIdentity: selectedSongIdentity,
                uploadedContentID: uploadedContentID
            )
        }) { return true }
        let existing = artworkOverridesByOwner[owner.storageKey]
        if existing?.mode == mode,
           existing?.selectedSongIdentity == selectedSongIdentity,
           existing?.uploadedContentID == uploadedContentID {
            return true
        }
        let next = LibraryArtworkOverride(
            owner: owner,
            mode: mode,
            selectedSongIdentity: selectedSongIdentity,
            uploadedContentID: uploadedContentID,
            updatedAt: Date(),
            syncRevision: max(existing?.syncRevision ?? 0, 0) + 1,
            syncWriterID: playlistSyncWriterID,
            syncOperationID: UUID().uuidString
        )
        artworkOverridesByOwner[owner.storageKey] = next
        guard persistPlaylistDurabilityLedger() else {
            artworkOverridesByOwner[owner.storageKey] = existing
            return false
        }
        persistSnapshot()
        notifyArtworkOverrideChanged(next)
        return true
    }

    func portableSongIdentity(for song: Song) -> SongIdentity {
        SongIdentity(
            songID: song.id,
            title: song.title,
            artistName: song.artistName,
            duration: song.duration,
            cloudAccountID: sourceIdentityResolver?(song.sourceID),
            filePath: song.filePath
        )
    }

    /// Resolve portable identities back to this device's visible songs while
    /// preserving the stored order. This is shared by AI smart playlists and
    /// the existing cross-device playlist identity semantics.
    func visibleSongs(matching identities: [SongIdentity]) -> [Song] {
        guard !identities.isEmpty else { return [] }
        let resolutionIndex = makeIdentityResolutionIndex(for: identities)
        let visibleIDs = Set(visibleSongs.map(\.id))
        var seen = Set<String>()
        return identities.compactMap { identity in
            guard let songID = resolveIdentity(identity, using: resolutionIndex),
                  visibleIDs.contains(songID),
                  seen.insert(songID).inserted else { return nil }
            return song(id: songID)
        }
    }

    /// Applies a remote value and returns true when the existing local value
    /// wins, allowing CloudKit's conflict path to reassert it.
    @discardableResult
    func applyRemoteArtworkOverride(_ remote: LibraryArtworkOverride) -> Bool {
        guard !remote.owner.id.isEmpty else { return false }
        // S2: 本地值要等发布后才存在, 冲突判定必须在重放时做; 返回 false
        // (= 远端值胜出) 让调用方不要立刻回推本地值。
        if deferringUntilReady({ [weak self] in
            _ = self?.applyRemoteArtworkOverride(remote)
        }) { return false }
        if let local = artworkOverridesByOwner[remote.owner.storageKey],
           LibraryArtworkOverrideReconciliationPolicy.winner(
            local: local,
            remote: remote
           ) == .local {
            return true
        }
        let previous = artworkOverridesByOwner[remote.owner.storageKey]
        artworkOverridesByOwner[remote.owner.storageKey] = remote
        guard persistPlaylistDurabilityLedger() else {
            artworkOverridesByOwner[remote.owner.storageKey] = previous
            return previous != nil
        }
        persistSnapshot()
        notifyArtworkOverrideChanged(remote, origin: "remote")
        return false
    }

    func deleteArtworkOverrideFromRemote(owner: LibraryArtworkOwner) {
        // S2: 封面覆盖表在发布时整体拷回, 现在删只会删到空表。
        if deferringUntilReady({ [weak self] in
            self?.deleteArtworkOverrideFromRemote(owner: owner)
        }) { return }
        guard let removed = artworkOverridesByOwner.removeValue(forKey: owner.storageKey) else { return }
        guard persistPlaylistDurabilityLedger() else {
            artworkOverridesByOwner[owner.storageKey] = removed
            return
        }
        persistSnapshot()
        artworkOverrideRevision &+= 1
    }

    /// `origin` 与源表同一套约定: "remote" 表示这次变更是在应用 CloudKit
    /// 刚送来的记录, 云同步的保存队列要忽略它, 否则两台设备会把同一份封面
    /// 覆盖来回推送。UI 观察者两种来源都照常刷新。
    private func notifyArtworkOverrideChanged(
        _ value: LibraryArtworkOverride,
        origin: String = "local"
    ) {
        artworkOverrideRevision &+= 1
        var userInfo: [AnyHashable: Any] = [
            "ids": [value.cloudRecordID],
            "ownerIDs": [value.owner.id],
            "origin": origin,
        ]
        if let contentID = value.uploadedContentID {
            userInfo["contentID"] = contentID
        }
        NotificationCenter.default.post(
            name: .primuseArtworkOverridesDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    func artistNames(for song: Song) -> [String] {
        Self.resolvedArtistNames(
            for: song,
            configuration: artistNameConfiguration
        )
    }

    func artistDisplayName(for song: Song) -> String? {
        let key = ArtistDisplayNameCacheKey(
            rawName: song.artistName,
            sourceNames: song.sourceArtistNames
        )
        if let cached = artistDisplayNameCache[key] { return cached.value }
        let value = song.displayArtistName(configuration: artistNameConfiguration)
        // 不同的原始字段远少于歌曲数 (同一艺术家成百上千首),这个上限只防极端库
        // 把内存吃满;真到了就整个清掉重来,不做 LRU。
        if artistDisplayNameCache.count >= Self.artistDisplayNameCacheLimit {
            artistDisplayNameCache.removeAll(keepingCapacity: true)
        }
        artistDisplayNameCache[key] = ArtistDisplayNameCacheEntry(value: value)
        return value
    }

    private static let artistDisplayNameCacheLimit = 20_000

    private func invalidateArtistDisplayNameCache() {
        artistDisplayNameCache.removeAll(keepingCapacity: true)
    }

    private struct ArtistDisplayNameCacheKey: Hashable {
        let rawName: String?
        let sourceNames: [String]?
    }

    /// 字典值要能装下 `nil`(字段为空时显示名就是 nil),裸 `String?` 当值会让赋 nil
    /// 变成删键,下次照样重算。
    private struct ArtistDisplayNameCacheEntry {
        let value: String?
    }

    func artistIDs(for song: Song) -> [String] {
        artistNames(for: song).map { Self.hashID(ArtistIdentityPolicy.groupingKey($0)) }
    }

    func song(_ song: Song, includesArtistID artistID: String) -> Bool {
        artistIDs(for: song).contains(artistID)
    }

    func songs(forArtist artistID: String) -> [Song] {
        _ = visibleSongsReference
        if let songIDs = visibleSongIDsByArtistID[artistID] {
            return songIDs.compactMap { lookupVisibleSong($0) }
        }
        return albumOnlyArtistSongIDs(artistID).compactMap { lookupVisibleSong($0) }
    }

    /// 只当过专辑艺人的人名下专辑里的歌，按专辑、再按曲目顺序。要整库找一遍，
    /// 所以第一次要时才找并记住（艺人页一次重绘会问好几回）。
    private func albumOnlyArtistSongIDs(_ artistID: String) -> [String] {
        if let cached = albumOnlyArtistSongIDsCache[artistID] { return cached }
        guard let albumIDs = albumIDsByAlbumOnlyArtistID[artistID], !albumIDs.isEmpty else { return [] }
        let wanted = Set(albumIDs)
        var songsByAlbumID: [String: [Song]] = [:]
        let songs = visibleSongsLookupReference.value
        // 按下标读字段：逐个拷出整首歌，几十万首的曲库上就是几十万次拷贝。
        for index in songs.indices {
            guard let albumID = songs[index].albumID, wanted.contains(albumID) else { continue }
            songsByAlbumID[albumID, default: []].append(songs[index])
        }
        let songIDs = albumIDs.flatMap { albumID in
            AlbumTrackOrder.sorted(songsByAlbumID[albumID] ?? []).map(\.id)
        }
        albumOnlyArtistSongIDsCache[artistID] = songIDs
        return songIDs
    }

    func songs(forGenre genreID: String) -> [Song] {
        _ = visibleSongsReference
        return visibleSongIDsByGenreID[genreID]?.compactMap { lookupVisibleSong($0) } ?? []
    }

    /// The genre's song IDs in display order without materializing `Song`
    /// values: a broad genre can hold most of a large library.
    func songIDs(forGenre genreID: String) -> [String] {
        _ = visibleSongsReference
        return visibleSongIDsByGenreID[genreID] ?? []
    }

    func albums(forGenre genreID: String) -> [Album] {
        _ = visibleAlbumsReference
        return visibleAlbumIDsByGenreID[genreID]?.compactMap { visibleAlbumByID[$0] } ?? []
    }

    func updateArtistNameConfiguration(_ value: ArtistNameConfiguration) {
        // S2 例外 1: 配置不排队。准备结果的 artistID / albums / artists 都是用
        // 存储里的命名配置算出来的, 这里只记下最新值, 发布拷回之后再对账。
        if isPreparing {
            preparingArtistNameConfiguration = value
            return
        }
        let value = value.normalized()
        guard artistNameConfiguration != value else { return }
        artistNameConfiguration = value
        invalidateArtistDisplayNameCache()

        var nextSongs = songs
        var changedSongs: [Song] = []
        changedSongs.reserveCapacity(nextSongs.count)
        let inferred = Self.inferredAlbumArtists(for: nextSongs, folders: albumArtistFolders)
        let derivedIDMemo = DerivedIDMemo()
        for index in nextSongs.indices {
            let previousArtistID = nextSongs[index].artistID
            let previousAlbumID = nextSongs[index].albumID
            let previousArtistArtwork = nextSongs[index].artistArtworkFileName
            let inferredAlbumArtist = inferred[nextSongs[index].id]
            Self.fillDerivedIDs(
                &nextSongs[index],
                configuration: value,
                inferredAlbumArtist: inferredAlbumArtist,
                memo: derivedIDMemo
            )
            applyAutomaticArtistArtwork(to: &nextSongs[index])
            if nextSongs[index].artistID != previousArtistID
                || nextSongs[index].albumID != previousAlbumID
                || nextSongs[index].artistArtworkFileName != previousArtistArtwork {
                changedSongs.append(nextSongs[index])
            }
        }
        if !changedSongs.isEmpty {
            songs = nextSongs
            songIndexByID = Self.makeSongIndex(nextSongs)
            persistSongChanges(upserts: changedSongs)
            markPortableSnapshotDirty()
        }

        requestLibraryIndexMaintenance(.immediate)
        invalidateSearchCaches()
    }

    /// 目录只影响专辑归属: 整库派生重建会按新目录重算专辑艺术家, 纠正并落盘
    /// 每首歌的 albumID, 所以这里只换掉目录再触发一次重建。准备期间照配置的
    /// 例外处理, 发布后对账; 启动装载时没有目录, 所以网盘用户每次启动都会在
    /// 这里补一次后台重建。
    func updateAlbumArtistFolders(_ value: AlbumArtistFolderIndex) {
        if isPreparing {
            preparingAlbumArtistFolders = value
            return
        }
        guard albumArtistFolders != value else { return }
        albumArtistFolders = value
        rebuildIndex()
    }

    func recentlyAddedAlbums(limit: Int = 10) -> [Album] {
        RecentlyAddedAlbumPolicy.sorted(albums: visibleAlbums, songs: visibleSongs, limit: limit)
    }

    func playlist(id: String) -> Playlist? {
        allPlaylists.first(where: { $0.id == id })
    }

    func songs(forPlaylist playlistID: String) -> [Song] {
        _ = visibleSongsReference
        return (playlistSongIDs[playlistID] ?? []).compactMap { lookupVisibleSong($0) }
    }

    /// The playlist's entries as stored, including songs that are not visible
    /// right now; resolve them with `visibleSong(id:)`.
    func songIDs(forPlaylist playlistID: String) -> [String] {
        _ = visibleSongsReference
        return playlistSongIDs[playlistID] ?? []
    }

    /// Count and first visible entry without materializing the full playlist.
    /// List rows frequently need only these two values.
    func songSummary(forPlaylist playlistID: String) -> (first: Song?, count: Int) {
        _ = visibleSongsReference
        var first: Song?
        var count = 0
        for songID in playlistSongIDs[playlistID] ?? [] {
            guard let song = lookupVisibleSong(songID) else { continue }
            if first == nil { first = song }
            count += 1
        }
        return (first, count)
    }

    /// Returns an exact visible count plus only the small candidate window a
    /// browse surface needs for artwork. This avoids materializing a 10K+
    /// member playlist merely to render its card.
    func playlistBrowseSummary(
        forPlaylist playlistID: String,
        artworkCandidateLimit: Int
    ) -> (artworkCandidates: [Song], count: Int) {
        _ = visibleSongsReference
        var accumulator = PlaylistBrowseArtworkAccumulator(
            playlistID: playlistID,
            limit: artworkCandidateLimit
        )
        for songID in playlistSongIDs[playlistID] ?? [] {
            guard let song = lookupVisibleSong(songID) else { continue }
            accumulator.consider(song)
        }
        return (accumulator.artworkCandidates, accumulator.visibleCount)
    }

    func songCount(forPlaylist playlistID: String) -> Int {
        _ = visibleSongsReference
        // 只数个数时不取出 Song: 字典取值要把整首歌拷一份, 几十个上千首的歌单
        // 加起来就是几万次拷贝 (Spotlight 快照、歌单列表都走这里)。
        var count = 0
        for songID in playlistSongIDs[playlistID] ?? []
        where visibleSongIndexByID[songID] != nil {
            count += 1
        }
        return count
    }

    /// Recently played music. Spoken word is left out — a book is resumed
    /// from its own shelf, and one evening of chapters would otherwise fill
    /// the row.
    func recentlyPlayedSongs(limit: Int = 6) -> [Song] {
        _ = visibleSongsReference
        _ = musicSongsReference
        var result: [Song] = []
        for songID in recentPlaybackSongIDs where !spokenWordSongIDs.contains(songID) {
            guard result.count < limit else { break }
            if let song = lookupVisibleSong(songID) { result.append(song) }
        }
        return result
    }

    func contains(songID: String, inPlaylist playlistID: String) -> Bool {
        playlistSongIDs[playlistID]?.contains(songID) == true
    }

    func recordPlayback(of songID: String) {
        // S2: 空库里 `songs.contains` 必然为 false, 不排队这条播放记录就没了。
        if deferringUntilReady({ [weak self] in self?.recordPlayback(of: songID) }) { return }
        guard songs.contains(where: { $0.id == songID }) else { return }

        recentPlaybackSongIDs.removeAll { $0 == songID }
        recentPlaybackSongIDs.insert(songID, at: 0)

        if recentPlaybackSongIDs.count > 100 {
            recentPlaybackSongIDs.removeLast(recentPlaybackSongIDs.count - 100)
        }

        // 每首歌都整库落盘会把几十 MB 的快照一天重写上百次; 最近播放不值这个价,
        // 走低优先级间隔, 由其它写入、进后台或导出顺带落盘。
        persistSnapshot(after: Self.lowPriorityPortableSnapshotDelay)
        NotificationCenter.default.post(name: .primusePlaybackHistoryDidChange, object: nil)
    }

    private func stampedPlaylist(
        _ playlist: Playlist,
        deleting: Bool = false,
        restoringDeleteOperationID: String? = nil,
        purging: Bool = false,
        now: Date = Date()
    ) -> Playlist {
        var result = playlist
        result.updatedAt = now
        result.syncRevision = max(0, playlist.syncRevision) + 1
        result.syncWriterID = playlistSyncWriterID
        result.syncOperationID = UUID().uuidString
        if deleting {
            result.isDeleted = true
            result.deletedAt = playlist.deletedAt ?? now
            result.deleteOperationID = UUID().uuidString
            result.restoredDeleteOperationID = nil
        } else if let restoringDeleteOperationID {
            result.isDeleted = false
            result.deletedAt = nil
            result.deleteOperationID = nil
            result.restoredDeleteOperationID = restoringDeleteOperationID
        }
        result.isPurged = purging
        return result
    }

    private func isMirrorPlaylistSuppressed(_ playlistID: String) -> Bool {
        guard let key = MirrorPlaylistSuppressionPolicy.key(forPlaylistID: playlistID) else {
            return false
        }
        return mirrorPlaylistSuppressions[keyID(key)] != nil
    }

    private func keyID(_ key: MirrorPlaylistSuppressionKey) -> String {
        "\(key.sourceID)\u{1F}\(key.remotePlaylistID)"
    }

    func hideMirrorPlaylist(id: String) {
        // S2: 镜像隐藏表在发布时整体拷回, 且这里要找的镜像歌单此刻还不存在。
        if deferringUntilReady({ [weak self] in self?.hideMirrorPlaylist(id: id) }) { return }
        guard MirrorPlaylistIdentity.isMirrorPlaylist(id),
              let key = MirrorPlaylistSuppressionPolicy.key(forPlaylistID: id),
              let playlist = allPlaylists.first(where: { $0.id == id }) else { return }
        let suppressionID = keyID(key)
        let previous = mirrorPlaylistSuppressions[suppressionID]
        mirrorPlaylistSuppressions[suppressionID] = MirrorPlaylistSuppression(
            key: key,
            playlistID: id,
            displayName: playlist.name
        )
        guard persistPlaylistDurabilityLedger() else {
            mirrorPlaylistSuppressions[suppressionID] = previous
            plog("Mirror playlist source=\(LogRedactionPolicy.digest(key.sourceID)) playlist=\(LogRedactionPolicy.digest(key.remotePlaylistID)) action=hide result=persistence-failed")
            return
        }
        persistSnapshot()
        playlistCollectionRevision &+= 1
        plog("Mirror playlist source=\(LogRedactionPolicy.digest(key.sourceID)) playlist=\(LogRedactionPolicy.digest(key.remotePlaylistID)) action=hide result=complete")
    }

    func restoreHiddenMirrorPlaylist(_ suppression: MirrorPlaylistSuppression) {
        // S2: 同上, 取消隐藏要落在发布后的抑制表上。
        if deferringUntilReady({ [weak self] in
            self?.restoreHiddenMirrorPlaylist(suppression)
        }) { return }
        let suppressionID = keyID(suppression.key)
        guard let removed = mirrorPlaylistSuppressions.removeValue(forKey: suppressionID) else { return }
        guard persistPlaylistDurabilityLedger() else {
            mirrorPlaylistSuppressions[suppressionID] = removed
            plog("Mirror playlist source=\(LogRedactionPolicy.digest(suppression.key.sourceID)) playlist=\(LogRedactionPolicy.digest(suppression.key.remotePlaylistID)) action=restore result=persistence-failed")
            return
        }
        persistSnapshot()
        playlistCollectionRevision &+= 1
        plog("Mirror playlist source=\(LogRedactionPolicy.digest(suppression.key.sourceID)) playlist=\(LogRedactionPolicy.digest(suppression.key.remotePlaylistID)) action=restore result=complete")
    }

    func createPlaylist(name: String) -> Playlist {
        createPlaylist(name: name, songIDs: [])
    }

    /// Create a playlist with its initial contents in one observable mutation,
    /// persistence request, and CloudKit notification. Importing 1000 tracks
    /// through `createPlaylist` + 1000 calls to `add` previously serialized the
    /// whole library snapshot and invalidated playlist views 1001 times.
    func createPlaylist(
        name: String,
        songIDs: [String],
        folderBinding: PlaylistFolderBinding? = nil
    ) -> Playlist {
        let playlist = stampedPlaylist(Playlist(name: name, folderBinding: folderBinding))
        // S2: 返回值必须当场给出 (调用方拿着它继续加歌 / 跳转), 所以只把插入
        // 排队 —— 重放用的是同一个 playlist 值, id 与时间戳都不会变。成员过滤
        // 也留到重放: 空库上 `validUniqueSongIDs` 会把每一首都滤掉。
        if deferringUntilReady({ [weak self] in
            self?.insertCreatedPlaylist(playlist, songIDs: songIDs)
        }) { return playlist }
        insertCreatedPlaylist(playlist, songIDs: songIDs)
        return allPlaylists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    /// `createPlaylist` / `createFolderPlaylist` / `ensurePlaylist` 新建分支共用的
    /// 插入尾巴, 也正是 S2 重放时执行的那一份。
    private func insertCreatedPlaylist(
        _ playlist: Playlist,
        songIDs: [String],
        pendingEntries: [PlaylistPendingEntry] = []
    ) {
        for entry in pendingEntries { playlistPendingEntries[entry.id] = entry }
        let entries = validUniqueSongIDs(songIDs)
        allPlaylists.append(playlist)
        playlistSongIDs[playlist.id] = entries
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlist.id])
    }

    @discardableResult
    func createFolderPlaylist(
        name: String,
        nodeID: LibraryFolderNodeID,
        cloudAccountID: String?,
        songIDs: [String]
    ) -> Playlist {
        let binding = PlaylistFolderBinding(nodeID: nodeID, cloudAccountID: cloudAccountID)
        if let existing = allPlaylists.first(where: { !$0.isDeleted && $0.folderBinding == binding }) {
            return existing
        }
        // S2: 绑定去重必须在发布后的歌单集合上再判一次, 否则重放会插进第二份。
        if isPreparing {
            let playlist = stampedPlaylist(Playlist(name: name, folderBinding: binding))
            _ = deferringUntilReady { [weak self] in
                guard let self,
                      !self.allPlaylists.contains(where: {
                          !$0.isDeleted && $0.folderBinding == binding
                      }) else { return }
                self.insertCreatedPlaylist(playlist, songIDs: songIDs)
            }
            return playlist
        }
        return createPlaylist(name: name, songIDs: songIDs, folderBinding: binding)
    }

    func folderPlaylistBindings(for source: MusicSource) -> [String: PlaylistFolderBinding] {
        allPlaylists.reduce(into: [:]) { result, playlist in
            guard !playlist.isDeleted, let binding = playlist.folderBinding,
                  binding.matches(source: source) else { return }
            result[playlist.id] = binding
        }
    }

    @discardableResult
    func applyFolderPlaylistMemberships(
        _ memberships: [String: [String]],
        expectedBindings: [String: PlaylistFolderBinding],
        previousMemberships: [String: [String]] = [:]
    ) -> Bool {
        // S2: 成员替换要比对发布后的歌单与歌曲, 空库上这个循环什么都匹配不到。
        if deferringUntilReady({ [weak self] in
            _ = self?.applyFolderPlaylistMemberships(
                memberships,
                expectedBindings: expectedBindings,
                previousMemberships: previousMemberships
            )
        }) { return false }
        var changedIDs: [String] = []
        for index in allPlaylists.indices {
            let playlist = allPlaylists[index]
            guard !playlist.isDeleted, let binding = playlist.folderBinding,
                  expectedBindings[playlist.id] == binding,
                  let incoming = memberships[playlist.id] else { continue }
            let entries = validUniqueSongIDs(incoming)
            guard playlistSongIDs[playlist.id] != entries
                    || previousMemberships[playlist.id].map({ $0 != entries }) == true
                    || pendingPlaylistIdentities[playlist.id]?.isEmpty == false else { continue }
            playlistSongIDs[playlist.id] = entries
            pendingPlaylistIdentities[playlist.id] = nil
            allPlaylists[index] = stampedPlaylist(playlist)
            changedIDs.append(playlist.id)
        }
        guard !changedIDs.isEmpty else { return false }
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged(changedIDs)
        return true
    }

    /// 用固定 ID 创建/取回 playlist ── 给"系统级"歌单 (Apple Music 资料库
    /// 镜像等) 用, 保证多端同步 + 重启后映射稳定, 不会重复创建。
    /// 镜像歌单的可见性由 suppression 独立控制；本地歌单若已删除，只能走显式恢复。
    @discardableResult
    func ensurePlaylist(id: String, name: String) -> Playlist {
        // S2: 空库上必然落到"新建"分支。排队时保留同一个 playlist 值,
        // 重放时若存储里已经有这一行, 就改走正常的改名 / 取消删除路径。
        if isPreparing {
            let playlist = MirrorPlaylistIdentity.isMirrorPlaylist(id)
                ? Playlist(id: id, name: name)
                : stampedPlaylist(Playlist(id: id, name: name))
            _ = deferringUntilReady { [weak self] in
                guard let self else { return }
                if self.allPlaylists.contains(where: { $0.id == id }) {
                    _ = self.ensurePlaylist(id: id, name: name)
                } else {
                    self.insertCreatedPlaylist(playlist, songIDs: [])
                }
            }
            return playlist
        }
        if let idx = allPlaylists.firstIndex(where: { $0.id == id }) {
            var p = allPlaylists[idx]
            let isMirror = MirrorPlaylistIdentity.isMirrorPlaylist(id)
            if p.isDeleted && !isMirror { return p }
            var changed = false
            if p.isDeleted { p.isDeleted = false; p.deletedAt = nil; changed = true }
            if p.name != name { p.name = name; changed = true }
            if changed {
                if isMirror {
                    p.updatedAt = Date()
                } else {
                    p = stampedPlaylist(p)
                }
                allPlaylists[idx] = p
                sortPlaylists()
                persistPlaylistDurabilityLedger()
                persistSnapshot(after: Self.snapshotDelay(forPlaylistID: id))
                notifyPlaylistsChanged([id])
            }
            return p
        }
        let playlist = MirrorPlaylistIdentity.isMirrorPlaylist(id)
            ? Playlist(id: id, name: name)
            : stampedPlaylist(Playlist(id: id, name: name))
        allPlaylists.append(playlist)
        playlistSongIDs[playlist.id] = []
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot(after: Self.snapshotDelay(forPlaylistID: playlist.id))
        notifyPlaylistsChanged([playlist.id])
        return playlist
    }

    /// 整体替换普通用户歌单（例如手动重排或把当前队列另存为歌单）。镜像歌单
    /// 必须走 `replaceMirrorPlaylistSongs`，防止任一遗漏的 UI 入口改写只读镜像。
    func replacePlaylistSongs(playlistID: String, songIDs: [String]) {
        // S2: 下面的 guard 读的是发布后才存在的歌单行。
        if deferringUntilReady({ [weak self] in
            self?.replacePlaylistSongs(playlistID: playlistID, songIDs: songIDs)
        }) { return }
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID),
              let playlist = allPlaylists.first(where: { $0.id == playlistID }),
              !playlist.isDeleted, playlist.allowsManualSongMembership
        else { return }
        replacePlaylistSongsUnchecked(playlistID: playlistID, songIDs: songIDs)
    }

    /// 用外部源的权威快照覆盖镜像歌单。不存在的 songID 会被静默忽略，避免
    /// 同步结果比歌曲写库稍晚时留下悬空引用。
    func replaceMirrorPlaylistSongs(
        playlistID: String,
        songIDs: [String],
        coverArtPath: String?
    ) {
        // S2: 同上, 镜像歌单与它的歌曲都要等发布之后才在库里。
        if deferringUntilReady({ [weak self] in
            self?.replaceMirrorPlaylistSongs(
                playlistID: playlistID,
                songIDs: songIDs,
                coverArtPath: coverArtPath
            )
        }) { return }
        guard MirrorPlaylistIdentity.isMirrorPlaylist(playlistID) else { return }
        replacePlaylistSongsUnchecked(
            playlistID: playlistID,
            songIDs: songIDs,
            mirrorCoverArtPath: coverArtPath,
            replacesCoverArtPath: true
        )
    }

    private func replacePlaylistSongsUnchecked(
        playlistID: String,
        songIDs: [String],
        mirrorCoverArtPath: String? = nil,
        replacesCoverArtPath: Bool = false
    ) {
        guard let idx = allPlaylists.firstIndex(where: { $0.id == playlistID }) else { return }
        let kept = songIDs.filter { songIndexByID[$0] != nil }
        let normalizedCoverArtPath = replacesCoverArtPath
            ? normalizedArtworkReference(mirrorCoverArtPath)
            : allPlaylists[idx].coverArtPath
        let hasDedicatedCoverArt = replacesCoverArtPath
            ? normalizedCoverArtPath != nil
            : allPlaylists[idx].hasDedicatedCoverArt
        guard playlistSongIDs[playlistID] != kept
                || allPlaylists[idx].coverArtPath != normalizedCoverArtPath
                || allPlaylists[idx].hasDedicatedCoverArt != hasDedicatedCoverArt else {
            return
        }
        playlistSongIDs[playlistID] = kept
        allPlaylists[idx].updatedAt = Date()
        if replacesCoverArtPath {
            allPlaylists[idx].coverArtPath = normalizedCoverArtPath
            allPlaylists[idx].hasDedicatedCoverArt = hasDedicatedCoverArt
        }
        if !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID) {
            allPlaylists[idx] = stampedPlaylist(allPlaylists[idx])
            persistPlaylistDurabilityLedger()
        }
        sortPlaylists()
        persistSnapshot(after: Self.snapshotDelay(forPlaylistID: playlistID))
        notifyPlaylistsChanged([playlistID])
    }

    /// Refresh a source-owned mirror cover without replacing its membership.
    /// Used when a remote playlist's artwork arrives even though its tracks are
    /// temporarily unresolved on this device.
    func updateMirrorPlaylistArtwork(
        playlistID: String,
        coverArtPath: String?,
        forceRefresh: Bool = false
    ) {
        // S2: 封面刷新落在发布后的镜像歌单行上。
        if deferringUntilReady({ [weak self] in
            self?.updateMirrorPlaylistArtwork(
                playlistID: playlistID,
                coverArtPath: coverArtPath,
                forceRefresh: forceRefresh
            )
        }) { return }
        guard MirrorPlaylistIdentity.isMirrorPlaylist(playlistID),
              let index = allPlaylists.firstIndex(where: { $0.id == playlistID }) else { return }
        let normalized = normalizedArtworkReference(coverArtPath)
        guard allPlaylists[index].coverArtPath != normalized
                || allPlaylists[index].hasDedicatedCoverArt != (normalized != nil) else {
            if forceRefresh { notifyPlaylistsChanged([playlistID]) }
            return
        }
        allPlaylists[index].coverArtPath = normalized
        allPlaylists[index].hasDedicatedCoverArt = normalized != nil
        allPlaylists[index].updatedAt = Date()
        sortPlaylists()
        persistSnapshot(after: Self.mirrorPlaylistSnapshotDelay)
        notifyPlaylistsChanged([playlistID])
    }

    private func normalizedArtworkReference(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Soft-delete: mark `isDeleted = true`, propagated to other devices as
    /// an update so the recycle bin converges.
    func deletePlaylist(id: String) {
        deletePlaylists(ids: [id])
    }

    /// Soft-delete several playlists with one snapshot write and one CloudKit
    /// change notification. Calling `deletePlaylist` in a selection loop makes
    /// a nominal batch operation perform a full persistence pass per row.
    func deletePlaylists(ids: Set<String>) {
        // S2: 软删除要打在发布后的歌单行上 (`deletePlaylist(id:)` 也走这里)。
        if deferringUntilReady({ [weak self] in self?.deletePlaylists(ids: ids) }) { return }
        let editableIDs = Set(ids.filter { !MirrorPlaylistIdentity.isMirrorPlaylist($0) })
        guard !editableIDs.isEmpty else { return }
        var changedIDs: [String] = []
        var originals: [String: Playlist] = [:]
        changedIDs.reserveCapacity(editableIDs.count)
        for index in allPlaylists.indices where editableIDs.contains(allPlaylists[index].id) {
            guard !allPlaylists[index].isDeleted else { continue }
            originals[allPlaylists[index].id] = allPlaylists[index]
            allPlaylists[index] = stampedPlaylist(allPlaylists[index], deleting: true)
            changedIDs.append(allPlaylists[index].id)
        }
        guard !changedIDs.isEmpty else { return }
        guard persistPlaylistDurabilityLedger() else {
            for index in allPlaylists.indices {
                if let original = originals[allPlaylists[index].id] {
                    allPlaylists[index] = original
                }
            }
            return
        }
        persistSnapshot()
        notifyPlaylistsChanged(changedIDs)
    }

    /// Restore a soft-deleted playlist (e.g. from the Recently Deleted view).
    func restorePlaylist(id: String) {
        // S2: 恢复的目标行要等发布之后才存在。
        if deferringUntilReady({ [weak self] in self?.restorePlaylist(id: id) }) { return }
        guard let index = allPlaylists.firstIndex(where: { $0.id == id }),
              allPlaylists[index].isDeleted,
              !allPlaylists[index].isPurged,
              let deleteOperationID = allPlaylists[index].deleteOperationID else { return }
        let original = allPlaylists[index]
        allPlaylists[index] = stampedPlaylist(
            allPlaylists[index],
            restoringDeleteOperationID: deleteOperationID
        )
        guard persistPlaylistDurabilityLedger() else {
            allPlaylists[index] = original
            return
        }
        persistSnapshot()
        notifyPlaylistsChanged([id])
    }

    /// Compact a deleted playlist without dropping its tombstone. Membership
    /// is removed, while the record remains syncable for long-offline devices.
    func permanentlyDeletePlaylist(id: String) {
        permanentlyDeletePlaylists(ids: [id])
    }

    /// Compact several deleted playlists with the same tombstone semantics as
    /// the single-item action, but only one durability and snapshot write.
    func permanentlyDeletePlaylists(ids: Set<String>) {
        // S2: 彻底删除同样要落在发布后的歌单集合上
        // (`permanentlyDeletePlaylist(id:)` / `prunePlaylists(deletedBefore:)`
        // 都汇到这里)。
        if deferringUntilReady({ [weak self] in
            self?.permanentlyDeletePlaylists(ids: ids)
        }) { return }
        // 已经清除过的墓碑不再重清: 重清会推进版本、整库落盘并同步给所有设备。
        let targetIDs = Set(allPlaylists.lazy.filter {
            ids.contains($0.id) && $0.isDeleted && !$0.isPurged
        }.map(\.id))
        guard !targetIDs.isEmpty else { return }

        let originalPlaylists = allPlaylists
        let originalSongIDs = playlistSongIDs
        let originalPending = pendingPlaylistIdentities
        for index in allPlaylists.indices where targetIDs.contains(allPlaylists[index].id) {
            allPlaylists[index] = stampedPlaylist(allPlaylists[index], purging: true)
            playlistSongIDs[allPlaylists[index].id] = nil
            pendingPlaylistIdentities[allPlaylists[index].id] = nil
        }
        guard persistPlaylistDurabilityLedger() else {
            allPlaylists = originalPlaylists
            playlistSongIDs = originalSongIDs
            pendingPlaylistIdentities = originalPending
            return
        }
        persistSnapshot()
        notifyPlaylistsChanged(Array(targetIDs))
    }

    /// Sweep playlists whose `deletedAt` is older than `threshold` and remove
    /// them for good. Called on launch with a 30-day threshold.
    func prunePlaylists(deletedBefore threshold: Date) {
        // S2: 回收站清理要扫发布后的歌单集合。
        if deferringUntilReady({ [weak self] in
            self?.prunePlaylists(deletedBefore: threshold)
        }) { return }
        // 清除后墓碑会留下(`isPurged`), 它的 deletedAt 永远早于阈值; 不排除它们,
        // 每次启动都会把同一批墓碑重清一遍、整库落盘再推给所有设备。
        let toPrune = allPlaylists.filter {
            $0.isDeleted && !$0.isPurged && ($0.deletedAt ?? .distantFuture) < threshold
        }
        guard !toPrune.isEmpty else { return }
        for playlist in toPrune {
            permanentlyDeletePlaylist(id: playlist.id)
        }
    }

    /// Permanently remove generated playlists that mirror an external source and
    /// are no longer part of that source's latest authoritative snapshot.
    func prunePlaylists(withIDPrefix prefix: String, keepingIDs: Set<String>) {
        prunePlaylists(withIDPrefixes: [prefix], keepingIDs: keepingIDs)
    }

    /// 删除源时一次清掉该批源产生的服务端歌单镜像。即使源里已经没有歌曲，
    /// 镜像本身也仍需删除，不能留下永远不会再同步的空歌单。
    func pruneServerPlaylistMirrors(forSourceIDs sourceIDs: Set<String>) {
        let prefixes = Set(sourceIDs.map {
            ServerPlaylistIdentity.playlistIDPrefix(sourceID: $0)
        })
        prunePlaylists(withIDPrefixes: prefixes, keepingIDs: [])
    }

    /// 移除 Apple Music 音乐源时,连同它同步出来的镜像歌单一起删掉 ——
    /// 「Apple Music 资料库」全集镜像和每一个用户歌单镜像。只删源不删歌单,
    /// 用户会留下一批永远不再更新、在界面上也删不掉的空歌单。用户自己手动
    /// 隐藏过的记录一并清掉,重新添加 Apple Music 才能回到干净状态。
    func pruneAppleMusicMirrorPlaylists() {
        // S2: 镜像歌单与隐藏表都要等发布之后才在集合里。
        if deferringUntilReady({ [weak self] in
            self?.pruneAppleMusicMirrorPlaylists()
        }) { return }
        let staleIDs = AppleMusicSourcePolicy.mirrorPlaylistIDs(in: allPlaylists.map(\.id))
        let staleSuppressionIDs = mirrorPlaylistSuppressions
            .filter { $0.value.key.sourceID == AppleMusicSourcePolicy.sourceID }
            .map(\.key)
        guard !staleIDs.isEmpty || !staleSuppressionIDs.isEmpty else { return }

        allPlaylists.removeAll { staleIDs.contains($0.id) }
        for id in staleIDs {
            playlistSongIDs[id] = nil
            pendingPlaylistIdentities[id] = nil
        }
        if !staleSuppressionIDs.isEmpty {
            let previous = mirrorPlaylistSuppressions
            for id in staleSuppressionIDs {
                mirrorPlaylistSuppressions[id] = nil
            }
            if !persistPlaylistDurabilityLedger() {
                mirrorPlaylistSuppressions = previous
            }
        }
        sortPlaylists()
        persistSnapshot()
        for id in staleIDs {
            notifyPlaylistDeleted(id)
        }
    }

    private func prunePlaylists(withIDPrefixes prefixes: Set<String>, keepingIDs: Set<String>) {
        guard !prefixes.isEmpty else { return }
        // S2: `prunePlaylists(withIDPrefix:)` 与 `pruneServerPlaylistMirrors` 共用
        // 这里; 镜像歌单要等发布之后才在集合里。
        if deferringUntilReady({ [weak self] in
            self?.prunePlaylists(withIDPrefixes: prefixes, keepingIDs: keepingIDs)
        }) { return }
        let staleIDs = allPlaylists
            .filter { playlist in
                !keepingIDs.contains(playlist.id)
                    && prefixes.contains(where: { playlist.id.hasPrefix($0) })
            }
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

    /// 用户拖出来的歌单顺序。位次写进歌单本身(跟着 iCloud 走),所以另一台
    /// 设备也是同一个顺序;`updatedAt` 保持不动 —— 排一次序不该把每个歌单的
    /// "最近更新"时间都改掉,顺序由 `sortOrder` 说了算。
    func reorderPlaylists(_ orderedIDs: [String]) {
        // S2: 歌单集合要等发布之后才在手上。
        if deferringUntilReady({ [weak self] in self?.reorderPlaylists(orderedIDs) }) { return }
        let known = Set(allPlaylists.lazy.filter { !$0.isDeleted }.map(\.id))
        let targetIDs = orderedIDs.filter { known.contains($0) }
        guard !targetIDs.isEmpty else { return }
        // 只比对这一批被重排的歌单:调用方传的是它自己列表里那一部分
        // (「我喜欢」这类不在列表里的歌单不参与), 拿全表比会永远判成"变了"。
        let targetSet = Set(targetIDs)
        guard PlaylistManualOrderPolicy.orderChanged(
            currentOrderedIDs: allPlaylists.filter { targetSet.contains($0.id) }.map(\.id),
            newOrderedIDs: targetIDs,
            currentSortOrders: Dictionary(
                allPlaylists.map { ($0.id, $0.sortOrder) },
                uniquingKeysWith: { current, _ in current }
            )
        ) else { return }

        let sortOrders = PlaylistManualOrderPolicy.sortOrders(forOrderedIDs: targetIDs)
        var changedIDs: [String] = []
        for index in allPlaylists.indices {
            guard let sortOrder = sortOrders[allPlaylists[index].id],
                  allPlaylists[index].sortOrder != sortOrder else { continue }
            allPlaylists[index].sortOrder = sortOrder
            // 只推进逻辑版本, 不动 updatedAt —— 跨设备和解看的是 syncRevision。
            allPlaylists[index].syncRevision = max(0, allPlaylists[index].syncRevision) + 1
            allPlaylists[index].syncWriterID = playlistSyncWriterID
            allPlaylists[index].syncOperationID = UUID().uuidString
            changedIDs.append(allPlaylists[index].id)
        }
        guard !changedIDs.isEmpty else { return }
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged(changedIDs)
    }

    // MARK: - Smart Playlists

    /// 创建 / 更新一份智能歌单。Caller 自己构造 SmartPlaylist (含 rules), 这里
    /// 只负责存进 allSmartPlaylists 并刷新 updatedAt + 触发同步。
    func saveSmartPlaylist(_ smart: SmartPlaylist) {
        // S2: 智能歌单集合在发布时被存储里的值整体覆盖。
        if deferringUntilReady({ [weak self] in self?.saveSmartPlaylist(smart) }) { return }
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
        // S2: 目标行要等发布之后才在集合里。
        if deferringUntilReady({ [weak self] in self?.deleteSmartPlaylist(id: id) }) { return }
        guard let idx = allSmartPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allSmartPlaylists[idx].isDeleted = true
        allSmartPlaylists[idx].deletedAt = Date()
        allSmartPlaylists[idx].updatedAt = Date()
        persistSnapshot()
        notifySmartPlaylistsChanged([id])
    }

    func restoreSmartPlaylist(id: String) {
        // S2: 同上。
        if deferringUntilReady({ [weak self] in self?.restoreSmartPlaylist(id: id) }) { return }
        guard let idx = allSmartPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allSmartPlaylists[idx].isDeleted = false
        allSmartPlaylists[idx].deletedAt = nil
        allSmartPlaylists[idx].updatedAt = Date()
        persistSnapshot()
        notifySmartPlaylistsChanged([id])
    }

    func permanentlyDeleteSmartPlaylist(id: String) {
        permanentlyDeleteSmartPlaylists(ids: [id])
    }

    func permanentlyDeleteSmartPlaylists(ids: Set<String>) {
        // S2: `permanentlyDeleteSmartPlaylist(id:)` / `pruneSmartPlaylists` 都汇到这里。
        if deferringUntilReady({ [weak self] in
            self?.permanentlyDeleteSmartPlaylists(ids: ids)
        }) { return }
        let targetIDs = Set(allSmartPlaylists.lazy.filter {
            ids.contains($0.id)
        }.map(\.id))
        guard !targetIDs.isEmpty else { return }
        allSmartPlaylists.removeAll { targetIDs.contains($0.id) }
        persistSnapshot()
        for id in targetIDs {
            notifySmartPlaylistDeleted(id)
        }
    }

    func pruneSmartPlaylists(deletedBefore threshold: Date) {
        // S2: 清理要扫发布后的智能歌单集合。
        if deferringUntilReady({ [weak self] in
            self?.pruneSmartPlaylists(deletedBefore: threshold)
        }) { return }
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
        add(songIDs: [songID], toPlaylist: playlistID)
    }

    /// Batch playlist insertion. Input order is retained, missing songs and
    /// duplicate IDs are ignored exactly as repeated calls to `add` did, but
    /// the playlist is published and persisted only once.
    func add(songIDs: [String], toPlaylist playlistID: String) {
        add(
            songIDs: songIDs,
            toPlaylist: playlistID,
            propagatesLikedMutation: true
        )
    }

    private func add(
        songIDs: [String],
        toPlaylist playlistID: String,
        propagatesLikedMutation: Bool
    ) {
        // S2: `add(songID:toPlaylist:)` / `add(songIDs:toPlaylist:)` 共用这里。
        // 歌单行与歌曲行都要等发布之后才存在, 不排队这批插入就没了。
        if deferringUntilReady({ [weak self] in
            self?.add(
                songIDs: songIDs,
                toPlaylist: playlistID,
                propagatesLikedMutation: propagatesLikedMutation
            )
        }) { return }
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID),
              !songIDs.isEmpty,
              let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }),
              !allPlaylists[existingIndex].isDeleted,
              allPlaylists[existingIndex].allowsManualSongMembership
        else { return }

        var entries = playlistSongIDs[playlistID] ?? []
        var seen = Set(entries)
        var changed = false
        var changedSongs: [Song] = []
        entries.reserveCapacity(entries.count + songIDs.count)
        for songID in songIDs where songIndexByID[songID] != nil {
            if seen.insert(songID).inserted {
                entries.append(songID)
                changed = true
                if playlistID == Self.likedSongsPlaylistID,
                   propagatesLikedMutation,
                   let songIndex = songIndexByID[songID] {
                    changedSongs.append(songs[songIndex])
                }
            }
        }
        guard changed else { return }
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex] = stampedPlaylist(allPlaylists[existingIndex])
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
        for song in changedSongs {
            likedStateMutationHandler?(song, false, true)
        }
    }

    private func validUniqueSongIDs(_ songIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(songIDs.count)
        for songID in songIDs where songIndexByID[songID] != nil || playlistPendingEntries[songID] != nil {
            if seen.insert(songID).inserted {
                result.append(songID)
            }
        }
        return result
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

    /// Likes many songs with a single publication of the liked list, for a
    /// liked list brought over from another device. Every newly liked song
    /// still reaches its server the way a tap on the heart does; without that
    /// the next server sync would take the imported likes away again.
    func likeSongs(_ songIDs: [String]) {
        // S2: 「我喜欢」歌单与歌曲行都要等发布之后才在库里。
        if deferringUntilReady({ [weak self] in self?.likeSongs(songIDs) }) { return }
        guard !songIDs.isEmpty else { return }
        ensureLikedPlaylist()
        add(songIDs: songIDs, toPlaylist: Self.likedSongsPlaylistID)
    }

    func toggleLiked(songID: String) {
        // S2: 空库里 `isLiked` 恒为 false, 不排队的话取反结果会是错的 ——
        // 当前状态必须在发布之后再读一次。
        if deferringUntilReady({ [weak self] in self?.toggleLiked(songID: songID) }) { return }
        let previous = isLiked(songID: songID)
        setLiked(songID: songID, isLiked: !previous, propagatesServerMutation: true)
    }

    func isLiked(songID: String) -> Bool {
        // 读一次存储属性把 Observation 依赖登记上 (喜欢/取消喜欢时行要刷新),
        // 判定本身走按修订号缓存的 Set,不再逐个比对整张「我喜欢」曲目表。
        let membership = playlistSongIDs
        if let cached = likedSongIDLookup, cached.revision == playlistMembershipRevision {
            return cached.ids.contains(songID)
        }
        let ids = Set(membership[Self.likedSongsPlaylistID] ?? [])
        likedSongIDLookup = (playlistMembershipRevision, ids)
        return ids.contains(songID)
    }

    func setLiked(
        songID: String,
        isLiked desired: Bool,
        propagatesServerMutation: Bool
    ) {
        // S2: 目标歌曲与「我喜欢」歌单都要等发布之后才在库里。
        if deferringUntilReady({ [weak self] in
            self?.setLiked(
                songID: songID,
                isLiked: desired,
                propagatesServerMutation: propagatesServerMutation
            )
        }) { return }
        guard song(id: songID) != nil else { return }
        let previous = isLiked(songID: songID)
        guard previous != desired else { return }

        ensureLikedPlaylist()
        if desired {
            add(
                songIDs: [songID],
                toPlaylist: Self.likedSongsPlaylistID,
                propagatesLikedMutation: propagatesServerMutation
            )
        } else {
            remove(
                songIDs: [songID],
                fromPlaylist: Self.likedSongsPlaylistID,
                propagatesLikedMutation: propagatesServerMutation
            )
        }
    }

    /// Replaces only the liked membership owned by one source. Other local or
    /// server sources retain their entries, while an authoritative empty
    /// server snapshot removes stale likes from that account.
    func replaceLikedSongs(
        fromSourceID sourceID: String,
        with authoritativeSongIDs: [String]
    ) {
        // S2: 该源的歌曲与「我喜欢」歌单成员都要等发布之后才存在。
        if deferringUntilReady({ [weak self] in
            self?.replaceLikedSongs(fromSourceID: sourceID, with: authoritativeSongIDs)
        }) { return }
        let sourceSongIDs = Set(songs.lazy.filter { $0.sourceID == sourceID }.map(\.id))
        let authoritative = validUniqueSongIDs(authoritativeSongIDs).filter {
            sourceSongIDs.contains($0)
        }
        let current = playlistSongIDs[Self.likedSongsPlaylistID] ?? []
        var next = current.filter { !sourceSongIDs.contains($0) }
        let retained = Set(next)
        next.append(contentsOf: authoritative.filter { !retained.contains($0) })
        guard next != current else { return }

        if allPlaylists.contains(where: { $0.id == Self.likedSongsPlaylistID }) == false {
            guard next.isEmpty == false else { return }
            ensureLikedPlaylist()
        }
        guard let playlistIndex = allPlaylists.firstIndex(where: {
            $0.id == Self.likedSongsPlaylistID && !$0.isDeleted
        }) else { return }

        playlistSongIDs[Self.likedSongsPlaylistID] = next
        allPlaylists[playlistIndex] = stampedPlaylist(allPlaylists[playlistIndex])
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([Self.likedSongsPlaylistID])
    }

    func presentServerFavoriteError(_ message: String) {
        serverFavoriteErrorMessage = message
    }

    func dismissServerFavoriteError() {
        serverFavoriteErrorMessage = nil
    }

    func remove(songID: String, fromPlaylist playlistID: String) {
        remove(songIDs: [songID], fromPlaylist: playlistID)
    }

    /// 批量移除。逐首调用会按条数重复 sortPlaylists / persistSnapshot / 发通知,
    /// 在歌单里一次移除几十首时那是几十轮全量落盘 + 视图重建。
    func remove(songIDs: [String], fromPlaylist playlistID: String) {
        remove(
            songIDs: songIDs,
            fromPlaylist: playlistID,
            propagatesLikedMutation: true
        )
    }

    private func remove(
        songIDs: [String],
        fromPlaylist playlistID: String,
        propagatesLikedMutation: Bool
    ) {
        // S2: `remove(songID:fromPlaylist:)` / `remove(songIDs:fromPlaylist:)` 共用这里。
        if deferringUntilReady({ [weak self] in
            self?.remove(
                songIDs: songIDs,
                fromPlaylist: playlistID,
                propagatesLikedMutation: propagatesLikedMutation
            )
        }) { return }
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID),
              !songIDs.isEmpty,
              let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }),
              !allPlaylists[existingIndex].isDeleted,
              allPlaylists[existingIndex].allowsManualSongMembership
        else { return }

        let removalSet = Set(songIDs)
        var entries = playlistSongIDs[playlistID] ?? []
        let removedSongIDs = entries.filter { removalSet.contains($0) }
        let originalCount = entries.count
        entries.removeAll { removalSet.contains($0) }
        guard entries.count != originalCount else { return }
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex] = stampedPlaylist(allPlaylists[existingIndex])
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
        if playlistID == Self.likedSongsPlaylistID, propagatesLikedMutation {
            for songID in removedSongIDs {
                guard let songIndex = songIndexByID[songID] else { continue }
                likedStateMutationHandler?(songs[songIndex], true, false)
            }
        }
    }

    // MARK: - Pending (grayed-out) playlist entries

    /// 歌单里的一行: 曲库里的歌, 或者还没有的歌(置灰占位)。
    enum PlaylistEntry: Identifiable {
        case song(Song)
        case pending(PlaylistPendingEntry)

        var id: String {
            switch self {
            case .song(let song): song.id
            case .pending(let entry): entry.id
            }
        }
    }

    /// 导入时的一个成员: 已经对上的歌, 或者要置灰保留的占位。
    enum PlaylistImportMember: Sendable {
        case song(String)
        case pending(PlaylistPendingEntry)
    }

    /// 歌单的完整条目, 按歌单顺序, 包括置灰的占位。停用源里的歌与
    /// `songs(forPlaylist:)` 一样不出现。
    func entries(forPlaylist playlistID: String) -> [PlaylistEntry] {
        _ = visibleSongsReference
        return (playlistSongIDs[playlistID] ?? []).compactMap { id -> PlaylistEntry? in
            if let song = lookupVisibleSong(id) { return .song(song) }
            if let entry = playlistPendingEntries[id] { return .pending(entry) }
            return nil
        }
    }

    func pendingEntryCount(forPlaylist playlistID: String) -> Int {
        guard !playlistPendingEntries.isEmpty else { return 0 }
        return (playlistSongIDs[playlistID] ?? []).reduce(0) { count, id in
            playlistPendingEntries[id] == nil ? count : count + 1
        }
    }

    func pendingEntry(id: String) -> PlaylistPendingEntry? {
        playlistPendingEntries[id]
    }

    /// 导入别处的歌单: 对上的歌和置灰占位按原顺序一起写进新歌单。
    @discardableResult
    func createPlaylist(name: String, members: [PlaylistImportMember]) -> Playlist {
        var songIDs: [String] = []
        var pendingEntries: [PlaylistPendingEntry] = []
        songIDs.reserveCapacity(members.count)
        for member in members {
            switch member {
            case .song(let id):
                songIDs.append(id)
            case .pending(let entry):
                songIDs.append(entry.id)
                pendingEntries.append(entry)
            }
        }
        let playlist = stampedPlaylist(Playlist(name: name))
        if deferringUntilReady({ [weak self] in
            self?.insertCreatedPlaylist(playlist, songIDs: songIDs, pendingEntries: pendingEntries)
        }) { return playlist }
        insertCreatedPlaylist(playlist, songIDs: songIDs, pendingEntries: pendingEntries)
        return allPlaylists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    /// 导入时能合并进去的歌单(#174): 用户自己的歌单。镜像与文件夹歌单的内容跟着来源走,
    /// 「我喜欢」有自己的导入去向(只收对上的歌、不留占位)。
    var playlistImportMergeTargets: [Playlist] {
        playlists.filter { $0.allowsManualSongMembership && $0.id != Self.likedSongsPlaylistID }
    }

    /// 合并会怎么改这个歌单, 只算不写。规则见 `PlaylistImportMergePolicy`。
    func playlistImportMergePlan(
        _ members: [PlaylistImportMember],
        intoPlaylist playlistID: String
    ) -> PlaylistImportMergePolicy.Plan? {
        guard let playlist = allPlaylists.first(where: { $0.id == playlistID }),
              !playlist.isDeleted,
              playlist.allowsManualSongMembership,
              playlistID != Self.likedSongsPlaylistID
        else { return nil }
        let keyCache = playlistEntryMatchKeyCache
        let existing = (playlistSongIDs[playlistID] ?? []).map { id in
            if let entry = playlistPendingEntries[id] {
                return PlaylistImportMergePolicy.Member(id: id, key: ExternalTrackMatchPolicy.Key(entry.matchSubject))
            }
            return PlaylistImportMergePolicy.Member(id: id, key: storedSong(id: id).map { keyCache.key(for: $0) })
        }
        let incoming = members.compactMap { member -> PlaylistImportMergePolicy.Member? in
            switch member {
            case .song(let id):
                // 预览拍的是当时的曲库; 这期间被删掉的歌不再写进去。
                guard let song = storedSong(id: id) else { return nil }
                return PlaylistImportMergePolicy.Member(id: id, key: keyCache.key(for: song))
            case .pending(let entry):
                return PlaylistImportMergePolicy.Member(id: entry.id, key: ExternalTrackMatchPolicy.Key(entry.matchSubject))
            }
        }
        return PlaylistImportMergePolicy.plan(existing: existing, incoming: incoming)
    }

    /// 导入的歌单合并进已有歌单: 原有的歌与顺序不动, 已经有的不再加, 原来置灰的这次
    /// 对上了就原位点亮, 其余接在末尾。一次发布、一次持久化, 和手动加歌一样推给别的设备。
    func mergeImportedPlaylist(_ members: [PlaylistImportMember], intoPlaylist playlistID: String) {
        // S2: 目标歌单与歌曲行都要等发布之后才在库里。
        if deferringUntilReady({ [weak self] in
            self?.mergeImportedPlaylist(members, intoPlaylist: playlistID)
        }) { return }
        guard let index = allPlaylists.firstIndex(where: { $0.id == playlistID }),
              let plan = playlistImportMergePlan(members, intoPlaylist: playlistID),
              plan.hasChanges
        else { return }
        if !plan.appendedPendingIDs.isEmpty {
            var pendingByID: [String: PlaylistPendingEntry] = [:]
            for case .pending(let entry) in members { pendingByID[entry.id] = entry }
            for id in plan.appendedPendingIDs {
                if let entry = pendingByID[id] { playlistPendingEntries[id] = entry }
            }
        }
        playlistSongIDs[playlistID] = plan.memberIDs
        if plan.resolvedPendingCount > 0 {
            playlistPendingEntries = Self.referencedPendingEntries(playlistPendingEntries, memberships: playlistSongIDs)
        }
        allPlaylists[index] = stampedPlaylist(allPlaylists[index])
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
        plog("🎵 Merged import into playlist: +\(plan.appendedSongCount) song(s), +\(plan.appendedPendingIDs.count) pending, \(plan.resolvedPendingCount) lit up, \(plan.alreadyPresentCount) already present")
    }

    /// 用户确认「就是这首」: 占位原位换成这首歌; 歌单里已经有这首时只摘掉占位。
    func resolvePendingEntry(_ pendingID: String, inPlaylist playlistID: String, with songID: String) {
        if deferringUntilReady({ [weak self] in
            self?.resolvePendingEntry(pendingID, inPlaylist: playlistID, with: songID)
        }) { return }
        guard songIndexByID[songID] != nil,
              let index = allPlaylists.firstIndex(where: { $0.id == playlistID }),
              !allPlaylists[index].isDeleted,
              let members = playlistSongIDs[playlistID],
              members.contains(pendingID) else { return }
        let alreadyPresent = members.contains(songID)
        var next: [String] = []
        next.reserveCapacity(members.count)
        for id in members {
            if id == pendingID {
                if !alreadyPresent { next.append(songID) }
            } else {
                next.append(id)
            }
        }
        playlistSongIDs[playlistID] = next
        playlistPendingEntries = Self.referencedPendingEntries(playlistPendingEntries, memberships: playlistSongIDs)
        // 用户亲手确认的改动要推给别的设备, 和手动加歌一样。
        allPlaylists[index] = stampedPlaylist(allPlaylists[index])
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    /// 曲库变了(扫描、回填、启用了一个源)之后, 在后台把占位和曲库重新对一遍:
    /// 把握大的原位点亮, 只够得上「可能是」的记下候选等用户确认。
    private func schedulePlaylistPendingResolution(after delay: Duration = .seconds(3)) {
        guard !playlistPendingEntries.isEmpty, !isPreparing else { return }
        playlistPendingResolutionTask?.cancel()
        playlistPendingResolutionGeneration &+= 1
        let generation = playlistPendingResolutionGeneration
        playlistPendingResolutionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if self.isDeferringSceneTransitionPublications {
                self.playlistPendingResolutionTask = nil
                self.schedulePlaylistPendingResolution(after: .seconds(10))
                return
            }
            let entries = self.playlistPendingEntries
            let candidates = self.visibleSongs
            let cache = self.playlistEntryMatchKeyCache
            let outcome = await Task.detached(priority: .utility) {
                Self.matchPendingEntries(entries, against: candidates, keyCache: cache)
            }.value
            guard generation == self.playlistPendingResolutionGeneration else { return }
            self.playlistPendingResolutionTask = nil
            self.applyPendingResolutions(outcome)
        }
    }

    struct PendingEntryMatchOutcome: Sendable {
        /// 占位 id → 点亮用的歌。
        var resolved: [String: String] = [:]
        /// 占位 id → 「可能是」的候选(nil 表示原来的候选已经不成立)。
        var suggestions: [String: String?] = [:]
    }

    nonisolated static func matchPendingEntries(
        _ entries: [String: PlaylistPendingEntry],
        against songs: [Song],
        keyCache: PlaylistEntryMatchKeyCache?
    ) -> PendingEntryMatchOutcome {
        var outcome = PendingEntryMatchOutcome()
        guard !entries.isEmpty, !songs.isEmpty else { return outcome }
        let matcher = PlaylistEntryMatcher(songs: songs, keyCache: keyCache)
        for (id, entry) in entries where entry.hasPlayableMetadata {
            let match = matcher.match(entry.matchSubject)
            if let best = match.best {
                outcome.resolved[id] = best.id
            } else {
                let suggestion = match.probable.first?.id
                if suggestion != entry.suggestedSongID { outcome.suggestions[id] = suggestion }
            }
        }
        return outcome
    }

    /// 点亮不改歌单的版本号、也不推给 iCloud: 别的设备用同一套规则会得出同样的
    /// 结果, 各自点亮即可; 推上去反而会在几台设备之间来回覆盖。下一次用户编辑
    /// 这个歌单时, 点亮后的成员表会随那次保存一起同步。
    private func applyPendingResolutions(_ outcome: PendingEntryMatchOutcome) {
        var membershipChanged = false
        if !outcome.resolved.isEmpty {
            for (playlistID, members) in playlistSongIDs
            where members.contains(where: { outcome.resolved[$0] != nil }) {
                var present = Set(members.filter { !PlaylistPendingEntry.isPendingID($0) })
                var next: [String] = []
                next.reserveCapacity(members.count)
                for id in members {
                    guard let songID = outcome.resolved[id], playlistPendingEntries[id] != nil,
                          songIndexByID[songID] != nil else {
                        next.append(id)
                        continue
                    }
                    // 同一首已经在歌单里(手动加过, 或者两个占位对到同一首)时只摘掉占位。
                    if present.insert(songID).inserted { next.append(songID) }
                }
                if next != members {
                    playlistSongIDs[playlistID] = next
                    membershipChanged = true
                }
            }
        }
        var suggestionsChanged = false
        for (id, suggestion) in outcome.suggestions {
            guard var entry = playlistPendingEntries[id], entry.suggestedSongID != suggestion else { continue }
            entry.suggestedSongID = suggestion
            playlistPendingEntries[id] = entry
            suggestionsChanged = true
        }
        if membershipChanged {
            playlistPendingEntries = Self.referencedPendingEntries(playlistPendingEntries, memberships: playlistSongIDs)
            plog("🎵 Lit \(outcome.resolved.count) pending playlist entr(y/ies)")
        }
        if membershipChanged || suggestionsChanged {
            playlistCollectionRevision &+= 1
            persistSnapshot()
        }
    }

    /// 歌从曲库里消失时(`songs` 已是删除后的状态、`cleanPlaylistEntries` 之前)调用。
    /// 引用了被删歌曲的手动歌单里: 别的源还有同一首就原位换过去; 没有时,
    /// `leavingPlaceholders` 为真(音乐源被移除、文件从源里消失)留下置灰占位,
    /// 以后有了再点亮; 为假(用户亲手删歌)照旧从歌单里去掉。「我喜欢」不留占位 ——
    /// 它和服务端收藏双向同步, 占位在那边没有对应物。
    private func reassignPlaylistMembers(ofRemoved removed: [Song], leavingPlaceholders: Bool) {
        guard !removed.isEmpty, !playlistSongIDs.isEmpty else { return }
        let removedByID = Dictionary(removed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var affectedPlaylistIDs: [String] = []
        var referencedRemoved: [String: Song] = [:]
        for playlist in allPlaylists where !playlist.isDeleted && playlist.allowsManualSongMembership {
            guard let members = playlistSongIDs[playlist.id] else { continue }
            var hit = false
            for id in members {
                if let song = removedByID[id] {
                    referencedRemoved[id] = song
                    hit = true
                }
            }
            if hit { affectedPlaylistIDs.append(playlist.id) }
        }
        // 常见情况(没有歌单引用被删的歌)到这里就结束, 不碰整库。
        guard !referencedRemoved.isEmpty else { return }

        let replacements = siblingReplacements(for: Array(referencedRemoved.values))
        var placeholders: [String: PlaylistPendingEntry] = [:]
        var changed = false
        for playlistID in affectedPlaylistIDs {
            guard let members = playlistSongIDs[playlistID] else { continue }
            let allowsPlaceholder = leavingPlaceholders && playlistID != Self.likedSongsPlaylistID
            var present = Set(members.filter { removedByID[$0] == nil && !PlaylistPendingEntry.isPendingID($0) })
            var next: [String] = []
            next.reserveCapacity(members.count)
            for id in members {
                guard let song = referencedRemoved[id] else {
                    next.append(id)
                    continue
                }
                if let sibling = replacements[id] {
                    if present.insert(sibling).inserted { next.append(sibling) }
                } else if allowsPlaceholder, !song.title.isEmpty {
                    // 同一首歌在几个歌单里共用一条占位, 点亮时一起亮。
                    let entry = placeholders[id] ?? PlaylistPendingEntry(
                        title: song.title,
                        artists: PlaylistEntryMatcher.artists(of: song),
                        album: song.albumTitle,
                        duration: song.duration > 0 ? song.duration : nil,
                        origin: "removed-source"
                    )
                    placeholders[id] = entry
                    playlistPendingEntries[entry.id] = entry
                    next.append(entry.id)
                } else {
                    // 留给紧随其后的 `cleanPlaylistEntries` 按老规矩清掉。
                    next.append(id)
                }
            }
            if next != members {
                playlistSongIDs[playlistID] = next
                changed = true
            }
        }
        if changed {
            plog("🎵 Reassigned \(replacements.count) removed playlist song(s) to other copies, \(placeholders.count) left as pending")
            persistSnapshot()
        }
    }

    /// 被删的歌 → 曲库里同一首歌的另一份(停用源除外)。只拿标题粗筛过的少数歌建索引,
    /// 不对整库做繁简归一化。
    private func siblingReplacements(for removed: [Song]) -> [String: String] {
        let coarseKeys = Set(removed.map { Self.coarseTitleKey($0.title) }.filter { !$0.isEmpty })
        guard !coarseKeys.isEmpty else { return [:] }
        let removedIDs = Set(removed.map(\.id))
        let candidates = songs.filter {
            !removedIDs.contains($0.id)
                && !disabledSourceIDs.contains($0.sourceID)
                && coarseKeys.contains(Self.coarseTitleKey($0.title))
        }
        guard !candidates.isEmpty else { return [:] }
        let matcher = PlaylistEntryMatcher(songs: candidates, keyCache: playlistEntryMatchKeyCache)
        var result: [String: String] = [:]
        for song in removed {
            if let best = matcher.match(PlaylistEntryMatcher.subject(of: song)).best {
                result[song.id] = best.id
            }
        }
        return result
    }

    /// 这些歌各自在别的(启用中的)源里的其他版本, 不含自己。播放时原曲所在的源连不上,
    /// 播放器从这里挑一份能播的。一次调用只扫一遍可见曲库。
    func otherCopies(of targets: [Song]) -> [String: [Song]] {
        guard !targets.isEmpty else { return [:] }
        let coarseKeys = Set(targets.map { Self.coarseTitleKey($0.title) }.filter { !$0.isEmpty })
        guard !coarseKeys.isEmpty else { return [:] }
        let candidates = visibleSongs.filter { coarseKeys.contains(Self.coarseTitleKey($0.title)) }
        guard candidates.count > 1 else { return [:] }
        let matcher = PlaylistEntryMatcher(songs: candidates, keyCache: playlistEntryMatchKeyCache)
        var result: [String: [Song]] = [:]
        for song in targets {
            let copies = matcher.match(PlaylistEntryMatcher.subject(of: song)).confident.filter {
                $0.id != song.id && $0.sourceID != song.sourceID
            }
            if !copies.isEmpty { result[song.id] = copies }
        }
        return result
    }

    /// 标题在第一个括号之前的部分, 只折叠大小写与空白。用来粗筛候选, 不求精确。
    nonisolated private static func coarseTitleKey(_ title: String) -> String {
        let head = title.prefix { !"([（【［".contains($0) }
        return String(head.lowercased().filter { !$0.isWhitespace })
    }

    // MARK: - Cloud sync hooks

    /// Raw stored song IDs for a playlist (no visibility filtering).
    func rawSongIDs(forPlaylist playlistID: String) -> [String] {
        playlistSongIDs[playlistID] ?? []
    }

    /// 歌单成员在库里存着的那一行，不经可见集、也不按禁用源过滤。扫描刚提交的
    /// 新大小 / 修订号要等整库分组重建后才进可见集，刮削、回填一直在改库时那次
    /// 重建会被反复作废；要按文件内容做决定的调用方（「始终保持离线」）读这一份。
    func storedSongs(forPlaylist playlistID: String) -> [Song] {
        rawSongIDs(forPlaylist: playlistID).compactMap { storedSong(id: $0) }
    }

    /// Projects the already-persisted Apple Music mirrors into the folder
    /// browser. This is deliberately local-only: opening the library never
    /// starts another MusicKit request or authorization prompt.
    func appleMusicFolderCollections(
        availableSongs: [Song]
    ) -> [LibraryFolderVirtualCollectionDescriptor] {
        let sourceID = AppleMusicLibraryIdentity.sourceID
        guard appleMusicLibrarySyncEnabled,
              appleMusicSourceInstalled,
              !disabledSourceIDs.contains(sourceID) else {
            return []
        }

        var availableIDs: [String] = []
        var availableIDSet = Set<String>()
        for song in availableSongs where song.sourceID == sourceID {
            if availableIDSet.insert(song.id).inserted {
                availableIDs.append(song.id)
            }
        }

        var librarySongIDs: [String] = []
        var seenLibrarySongIDs = Set<String>()
        for songID in playlistSongIDs[AppleMusicLibraryIdentity.systemPlaylistID] ?? []
        where availableIDSet.contains(songID) && seenLibrarySongIDs.insert(songID).inserted {
            librarySongIDs.append(songID)
        }
        librarySongIDs.append(contentsOf: availableIDs.filter {
            seenLibrarySongIDs.insert($0).inserted
        })

        var collections: [LibraryFolderVirtualCollectionDescriptor] = []
        if !isMirrorPlaylistSuppressed(AppleMusicLibraryIdentity.systemPlaylistID) {
            collections.append(LibraryFolderVirtualCollectionDescriptor(
                sourceID: sourceID,
                identity: AppleMusicLibraryIdentity.systemPlaylistID,
                displayName: String(localized: "library_folder_apple_music_library_songs"),
                kind: .librarySongs,
                songIDs: librarySongIDs
            ))
        }

        let userMirrors = allPlaylists
            .filter {
                !$0.isDeleted
                    && !isMirrorPlaylistSuppressed($0.id)
                    && $0.id.hasPrefix(AppleMusicLibraryIdentity.userPlaylistIDPrefix)
            }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
        var playlistMembership = Set<String>()
        for playlist in userMirrors {
            var seenSongIDs = Set<String>()
            let memberIDs = (playlistSongIDs[playlist.id] ?? []).filter {
                availableIDSet.contains($0) && seenSongIDs.insert($0).inserted
            }
            playlistMembership.formUnion(memberIDs)
            let trimmedName = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            collections.append(LibraryFolderVirtualCollectionDescriptor(
                sourceID: sourceID,
                identity: playlist.id,
                displayName: trimmedName.isEmpty
                    ? String(localized: "library_folder_apple_music_unnamed_playlist")
                    : trimmedName,
                kind: .playlist,
                songIDs: memberIDs
            ))
        }

        if !userMirrors.isEmpty {
            let notInPlaylist = librarySongIDs.filter { !playlistMembership.contains($0) }
            if !notInPlaylist.isEmpty {
                collections.append(LibraryFolderVirtualCollectionDescriptor(
                    sourceID: sourceID,
                    identity: AppleMusicLibraryIdentity.notInPlaylistCollectionID,
                    displayName: String(localized: "library_folder_apple_music_not_in_playlist"),
                    kind: .notInPlaylist,
                    songIDs: notInPlaylist
                ))
            }
        }
        return collections
    }

    /// Cross-device identities that have not resolved on this device yet.
    ///
    /// These must be included again when a locally-dirty playlist is saved
    /// after merging a fetched CloudKit record. Otherwise a song that exists
    /// only on the other device is kept in the local pending bucket but is
    /// silently removed from the next CloudKit payload.
    func pendingSongIdentities(forPlaylist playlistID: String) -> [SongIdentity] {
        let cutoff = Date().addingTimeInterval(-Self.pendingIdentityTTL)
        return (pendingPlaylistIdentities[playlistID] ?? [])
            .filter { $0.firstSeenAt >= cutoff }
            .map(\.identity)
    }

    /// Snapshot of recent playback song IDs — used by CloudKit sync.
    var recentPlaybackSongIDsForSync: [String] { recentPlaybackSongIDs }

    /// Wipe playback history (in response to a remote deletion).
    func clearPlaybackHistory() {
        // S2: 播放历史在发布时被存储里的值整体覆盖, 现在清只会清到空数组。
        if deferringUntilReady({ [weak self] in self?.clearPlaybackHistory() }) { return }
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
    @discardableResult
    func applyRemotePlaylist(
        _ playlist: Playlist,
        songIDs: [String],
        identities: [SongIdentity]? = nil
    ) -> Bool {
        // S2: 冲突判定要比对发布后的本地行, 身份解析也要在有歌之后再做;
        // 返回 false (= 远端值胜出) 让调用方不要立刻回推本地值。
        if deferringUntilReady({ [weak self] in
            _ = self?.applyRemotePlaylist(playlist, songIDs: songIDs, identities: identities)
        }) { return false }
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            if PlaylistReconciliationPolicy.winner(
                local: allPlaylists[index],
                remote: playlist
            ) == .local {
                // 同一次写入不回推(见 `isEquivalent`); 只有本地确实更新才让调用方重申。
                return !PlaylistReconciliationPolicy.isEquivalent(
                    local: allPlaylists[index],
                    remote: playlist
                )
            }
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
        if playlist.isPurged {
            playlistSongIDs[playlist.id] = nil
            pendingPlaylistIdentities[playlist.id] = nil
        }
        // 远端这份现在就是本机与云端一致的状态: 记成下次合并的基线。
        playlistSyncBaseSongIDs[playlist.id] = playlist.isPurged ? nil : playlistSongIDs[playlist.id]

        sortPlaylists()
        scheduleRemotePlaylistDurabilityLedgerWrite()
        persistSnapshot()
        playlistCollectionRevision &+= 1
        return false
    }

    /// 本机的歌单记录保存成功: 服务器上现在就是这份曲目表, 记成下次合并的基线。
    func markPlaylistSynced(id: String, songIDs: [String]) {
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(id),
              LibraryArtworkOwner.fromCloudRecordID(id) == nil,
              playlistSyncBaseSongIDs[id] != songIDs else { return }
        playlistSyncBaseSongIDs[id] = songIDs
        // 基线丢了只是退化成并集合并, 不值得为它立刻整库落盘。
        persistSnapshot(after: Self.lowPriorityPortableSnapshotDelay)
    }

    /// Merge a server-side playlist update into the existing local playlist.
    /// Used by CloudKit's conflict path so server-only adds aren't lost.
    /// Server identities flow through the same resolver as `applyRemotePlaylist`;
    /// IDs that resolve are unioned with the local list, IDs that don't go
    /// to pending so the next scan can backfill them.
    @discardableResult
    func mergeRemotePlaylist(
        _ playlist: Playlist,
        baseSongIDs: [String],
        additionalIdentities: [SongIdentity]
    ) -> Bool {
        // S2: 同 `applyRemotePlaylist`; 返回 false 表示本地没有胜出。
        if deferringUntilReady({ [weak self] in
            _ = self?.mergeRemotePlaylist(
                playlist,
                baseSongIDs: baseSongIDs,
                additionalIdentities: additionalIdentities
            )
        }) { return false }
        let previousPlaylist = allPlaylists.first { $0.id == playlist.id }
        let previousSongIDs = playlistSongIDs[playlist.id]
        let previousPending = pendingPlaylistIdentities[playlist.id]
        var localWon = false
        var reconciled = playlist
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            if PlaylistReconciliationPolicy.winner(
                local: allPlaylists[index],
                remote: playlist
            ) == .local {
                localWon = true
                reconciled = allPlaylists[index]
            } else {
                allPlaylists[index] = playlist
            }
        } else {
            allPlaylists.append(playlist)
        }

        let (resolved, unresolved) = resolveIdentitiesPartitioned(additionalIdentities)
        // `baseSongIDs` 是本机现在的曲目表。有上次同步的基线就做三方合并: 基线里有而
        // 一边没有的, 是那一边删掉的, 不能再从另一边并回来; 没有基线(旧快照)才退化
        // 成并集 —— 那种情况下一台删歌、另一台同时改, 被删的歌会回来。
        var seen = Set<String>()
        let merged: [String]
        if let syncBase = playlistSyncBaseSongIDs[playlist.id] {
            let removedLocally = Set(syncBase).subtracting(baseSongIDs)
            let removedRemotely = Set(syncBase).subtracting(resolved)
            merged = (baseSongIDs + resolved).filter {
                !removedLocally.contains($0) && !removedRemotely.contains($0) && seen.insert($0).inserted
            }
        } else {
            merged = (baseSongIDs + resolved).filter { seen.insert($0).inserted }
        }
        playlistSongIDs[reconciled.id] = merged
        updatePendingPlaylistIdentities(playlistID: reconciled.id, with: unresolved)
        if reconciled.isPurged {
            playlistSongIDs[reconciled.id] = nil
            pendingPlaylistIdentities[reconciled.id] = nil
            playlistSyncBaseSongIDs[reconciled.id] = nil
        } else if !localWon,
                  !Set(merged).isSubset(of: Set(resolved)),
                  let index = allPlaylists.firstIndex(where: { $0.id == reconciled.id }) {
            // 远端版本赢了元数据, 但本机独有的曲目并了进去: 推上去的必须是一个
            // 更新的版本。否则别的设备按「同一版本」跳过, 这些曲目在它们那里永远
            // 不出现, 而它们下一次编辑又会把这份并集整个覆盖掉。
            allPlaylists[index].syncRevision = max(0, playlist.syncRevision) + 1
            allPlaylists[index].syncWriterID = playlistSyncWriterID
            allPlaylists[index].syncOperationID = UUID().uuidString
            reconciled = allPlaylists[index]
        }
        if !reconciled.isPurged {
            // 合并结果马上会随待传的保存推上去, 它就是下一次合并的基线。
            playlistSyncBaseSongIDs[reconciled.id] = merged
        }

        // 合并前后完全一样(典型是源类型指纹重置后本机重排、又原样拉回来的那些)
        // 就不再落盘: 每次都是整库快照, 一次全量拉取会被拖成几十次整库重写。
        if allPlaylists.first(where: { $0.id == reconciled.id }) == previousPlaylist,
           playlistSongIDs[reconciled.id] == previousSongIDs,
           pendingPlaylistIdentities[reconciled.id] == previousPending {
            return localWon
        }

        sortPlaylists()
        scheduleRemotePlaylistDurabilityLedgerWrite()
        persistSnapshot()
        playlistCollectionRevision &+= 1
        return localWon
    }

    /// Replace the local playback history with one pulled from CloudKit.
    /// Identity resolution mirrors `applyRemotePlaylist` — unresolved
    /// entries hang in `pendingHistoryIdentities` until a matching song
    /// shows up locally.
    func applyRemotePlaybackHistory(
        songIDs: [String],
        identities: [SongIdentity]? = nil
    ) {
        // S2: 播放历史在发布时整体拷回, 身份解析也需要发布后的歌曲行。
        if deferringUntilReady({ [weak self] in
            self?.applyRemotePlaybackHistory(songIDs: songIDs, identities: identities)
        }) { return }
        let previousSongIDs = recentPlaybackSongIDs
        let previousPending = pendingHistoryIdentities
        // 远端那份排在前面(那台设备刚放过), 本机独有的最近播放接在后面。以前是
        // 整份替换: 本机刚放的一首还没轮到五分钟节流上传, 别的设备一条记录到了,
        // 它就从「最近播放」里消失, 也再没机会传出去。
        let incoming: [String]
        if let identities, !identities.isEmpty {
            let (resolved, unresolved) = resolveIdentitiesPartitioned(identities)
            incoming = resolved
            updatePendingHistoryIdentities(with: unresolved)
        } else {
            incoming = songIDs
        }
        var seen = Set<String>()
        recentPlaybackSongIDs = Array((incoming + previousSongIDs).filter { seen.insert($0).inserted }.prefix(100))
        // 拉回来的就是本机已有的那份时不必再整库落盘。
        guard recentPlaybackSongIDs != previousSongIDs
            || pendingHistoryIdentities != previousPending else { return }
        persistSnapshot()
    }

    /// Merge a server-side playback history update into the local list.
    /// Used by CloudKit's conflict path; mirrors `mergeRemotePlaylist`.
    func mergeRemotePlaybackHistory(
        baseSongIDs: [String],
        additionalIdentities: [SongIdentity]
    ) {
        // S2: 同上。
        if deferringUntilReady({ [weak self] in
            self?.mergeRemotePlaybackHistory(
                baseSongIDs: baseSongIDs,
                additionalIdentities: additionalIdentities
            )
        }) { return }
        let previousSongIDs = recentPlaybackSongIDs
        let previousPending = pendingHistoryIdentities
        let (resolved, unresolved) = resolveIdentitiesPartitioned(additionalIdentities)
        var seen = Set<String>()
        let merged = (baseSongIDs + resolved).filter { seen.insert($0).inserted }
        recentPlaybackSongIDs = Array(merged.prefix(100))
        updatePendingHistoryIdentities(with: unresolved)
        // 合并结果与本机相同(全量重拉时的常态)就不必整库落盘。
        guard recentPlaybackSongIDs != previousSongIDs
            || pendingHistoryIdentities != previousPending else { return }
        persistSnapshot()
    }

    // MARK: - Identity resolution & pending flush

    /// Walk a batch of identities through the 3-tier resolver, splitting
    /// them into "matched a local song" and "still no match" groups.
    private func resolveIdentitiesPartitioned(_ identities: [SongIdentity]) -> (resolved: [String], unresolved: [SongIdentity]) {
        let resolutionIndex = makeIdentityResolutionIndex(for: identities)
        var resolved: [String] = []
        var unresolved: [SongIdentity] = []
        for identity in identities {
            if let songID = resolveIdentity(identity, using: resolutionIndex) {
                resolved.append(songID)
            } else if let entry = PlaylistPendingEntry(syncIdentity: identity) {
                // 别的设备上置灰的条目: 原位保留成本机的占位, 由本机曲库去点亮。
                if playlistPendingEntries[entry.id] == nil { playlistPendingEntries[entry.id] = entry }
                resolved.append(entry.id)
            } else {
                unresolved.append(identity)
            }
        }
        return (resolved, unresolved)
    }

    private struct IdentityCloudPathKey: Hashable {
        let accountID: String
        let filePath: String
    }

    private struct IdentityResolutionIndex {
        let songIDByCloudPath: [IdentityCloudPathKey: String]
        let songIndicesByTitle: [String: [Int]]
    }

    /// Builds only the lookup buckets required by the pending identities.
    /// A metadata batch can otherwise perform one complete `songs.first` scan
    /// per pending playlist entry on the main actor.
    private func makeIdentityResolutionIndex(for identities: [SongIdentity]) -> IdentityResolutionIndex {
        let requestedTitles = Set(identities.lazy.compactMap { identity in
            identity.title.isEmpty ? nil : identity.title
        })
        let requestedCloudPaths = Set(identities.compactMap { identity -> IdentityCloudPathKey? in
            guard let accountID = identity.cloudAccountID, !identity.filePath.isEmpty else { return nil }
            return IdentityCloudPathKey(accountID: accountID, filePath: identity.filePath)
        })
        let requestedFilePaths = Set(requestedCloudPaths.map(\.filePath))

        var songIDByCloudPath: [IdentityCloudPathKey: String] = [:]
        var songIndicesByTitle: [String: [Int]] = [:]
        songIDByCloudPath.reserveCapacity(requestedCloudPaths.count)
        songIndicesByTitle.reserveCapacity(requestedTitles.count)

        // 单张封面只需要它引用的路径；不要为无关歌曲生成云端路径索引。
        // 同一来源的账号解析（包括失败）在本批只做一次。
        var accountIDBySourceID: [String: String] = [:]
        var resolvedSourceIDs = Set<String>()

        // 按下标只取要比对的字段: `for song in songs` 每一首都要整份拷贝 Song
        // (几十个字符串字段逐个 retain/release), 整库五六万首时这才是大头。
        let allSongs = songs
        let matchesTitles = !requestedTitles.isEmpty
        let matchesPaths = !requestedFilePaths.isEmpty
        guard matchesTitles || matchesPaths else {
            return IdentityResolutionIndex(songIDByCloudPath: [:], songIndicesByTitle: [:])
        }
        for songIndex in allSongs.indices {
            if matchesTitles {
                let title = allSongs[songIndex].title
                if requestedTitles.contains(title) {
                    songIndicesByTitle[title, default: []].append(songIndex)
                }
            }
            guard matchesPaths else { continue }
            let filePath = allSongs[songIndex].filePath
            guard requestedFilePaths.contains(filePath) else { continue }
            let sourceID = allSongs[songIndex].sourceID
            if resolvedSourceIDs.insert(sourceID).inserted {
                accountIDBySourceID[sourceID] = sourceIdentityResolver?(sourceID)
            }
            guard let accountID = accountIDBySourceID[sourceID] else { continue }
            let key = IdentityCloudPathKey(accountID: accountID, filePath: filePath)
            if requestedCloudPaths.contains(key), songIDByCloudPath[key] == nil {
                songIDByCloudPath[key] = allSongs[songIndex].id
            }
        }

        return IdentityResolutionIndex(
            songIDByCloudPath: songIDByCloudPath,
            songIndicesByTitle: songIndicesByTitle
        )
    }

    private func resolveIdentity(
        _ identity: SongIdentity,
        using resolutionIndex: IdentityResolutionIndex
    ) -> String? {
        // Tier 1: exact ID — same mount on both devices, or hash collision.
        if songForSynchronization(id: identity.songID) != nil {
            return identity.songID
        }
        // Tier 2: cloud account + file path. `sourceIdentityResolver`
        // returns the `cloudAccountID` for OAuth-typed mounts (which is
        // SHA256(provider:accountUID) — stable across devices).
        if let acc = identity.cloudAccountID, !identity.filePath.isEmpty {
            let key = IdentityCloudPathKey(accountID: acc, filePath: identity.filePath)
            if let songID = resolutionIndex.songIDByCloudPath[key] {
                return songID
            }
        }
        if let accountID = identity.cloudAccountID, !identity.filePath.isEmpty,
           let retained = deviceLocalExcludedSongsByID.values.first(where: {
               sourceIdentityResolver?($0.sourceID) == accountID
                   && $0.filePath == identity.filePath
                   && songForSynchronization(id: $0.id) != nil
           }) {
            return retained.id
        }
        // Tier 3: fuzzy match — for NAS / FTP / SMB / WebDAV / local
        // sources where there's no cloud account anchor.
        if !identity.title.isEmpty {
            for songIndex in resolutionIndex.songIndicesByTitle[identity.title] ?? [] {
                let song = songs[songIndex]
                if abs(song.duration - identity.duration) < 1.0,
                   (identity.artistName == nil || song.artistName == identity.artistName) {
                    return song.id
                }
            }
        }
        if !identity.title.isEmpty,
           let retained = deviceLocalExcludedSongsByID.values.first(where: {
               $0.title == identity.title && abs($0.duration - identity.duration) < 1.0
                   && (identity.artistName == nil || $0.artistName == identity.artistName)
                   && songForSynchronization(id: $0.id) != nil
           }) {
            return retained.id
        }
        return nil
    }

    private func resolveArtworkSongID(
        _ identity: SongIdentity,
        for owner: LibraryArtworkOwner
    ) -> String? {
        if songIndexByID[identity.songID] != nil {
            return identity.songID
        }
        let key = owner.storageKey
        let cached = artworkSongIDResolutions[key]
        let songCount = songs.count
        switch LibraryArtworkSongResolutionCachePolicy.decision(
            cached: cached,
            identity: identity,
            generation: songMutationGeneration,
            songCount: songCount,
            now: Date()
        ) {
        case .reuse:
            return cached?.songID
        case .verify(let songID):
            if let cached, artworkSong(songID, stillMatches: identity) {
                artworkSongIDResolutions[key] = cached.carried(
                    to: songMutationGeneration,
                    songCount: songCount
                )
                return songID
            }
        case .resolve:
            break
        }
        resolveArtworkSongIDsInOneScan(including: (key, identity))
        return artworkSongIDResolutions[key]?.songID
    }

    private func artworkSong(_ songID: String, stillMatches identity: SongIdentity) -> Bool {
        guard let song = songForSynchronization(id: songID) else { return false }
        return LibraryArtworkSongResolutionCachePolicy.song(
            title: song.title,
            artistName: song.artistName,
            duration: song.duration,
            filePath: song.filePath,
            cloudAccountID: { sourceIdentityResolver?(song.sourceID) },
            matches: identity
        )
    }

    /// 首页一屏常有十几张自选封面的卡片, 一张要整库找时顺手把其它同样要找的一并找了:
    /// 一次遍历建好所有待找身份的索引, 而不是每张卡各扫一遍。
    private func resolveArtworkSongIDsInOneScan(including requested: (key: String, identity: SongIdentity)) {
        let generation = songMutationGeneration
        let songCount = songs.count
        let now = Date()
        var pending = [requested]
        for (key, override) in artworkOverridesByOwner where key != requested.key {
            guard override.mode == .selectedSong,
                  let identity = override.selectedSongIdentity,
                  songIndexByID[identity.songID] == nil,
                  LibraryArtworkSongResolutionCachePolicy.decision(
                      cached: artworkSongIDResolutions[key],
                      identity: identity,
                      generation: generation,
                      songCount: songCount,
                      now: now
                  ) == .resolve else { continue }
            pending.append((key, identity))
        }
        let index = makeIdentityResolutionIndex(for: pending.map(\.identity))
        for item in pending {
            artworkSongIDResolutions[item.key] = LibraryArtworkSongResolutionCachePolicy.Entry(
                identity: item.identity,
                songID: resolveIdentity(item.identity, using: index),
                generation: generation,
                songCount: songCount,
                checkedAt: now
            )
        }
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
        let existingByIdentity = Dictionary(
            existing.map { ($0.identity, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.firstSeenAt <= rhs.firstSeenAt ? lhs : rhs }
        )
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
    private func flushPendingIdentities() -> Bool {
        guard !pendingPlaylistIdentities.isEmpty || !pendingHistoryIdentities.isEmpty else { return false }

        var changed = false

        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.pendingIdentityTTL)
        var identitiesToResolve = pendingHistoryIdentities.map(\.identity)
        identitiesToResolve.reserveCapacity(
            identitiesToResolve.count
                + pendingPlaylistIdentities.values.reduce(0) { $0 + $1.count }
        )
        for pending in pendingPlaylistIdentities.values {
            identitiesToResolve.append(contentsOf: pending.lazy.map(\.identity))
        }
        let resolutionIndex = makeIdentityResolutionIndex(for: identitiesToResolve)

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
                if let songID = resolveIdentity(entry.identity, using: resolutionIndex) {
                    newlyResolved.append(songID)
                } else {
                    stillPending.append(entry)
                }
            }
            if !newlyResolved.isEmpty {
                var seen = Set(playlistSongIDs[playlistID] ?? [])
                let toAppend = newlyResolved.filter { seen.insert($0).inserted }
                if !toAppend.isEmpty {
                    changed = true
                    playlistSongIDs[playlistID, default: []].append(contentsOf: toAppend)
                }
            }
            if stillPending != pending { changed = true }
            pendingPlaylistIdentities[playlistID] = stillPending.isEmpty ? nil : stillPending
        }

        // Playback history: resolved entries prepend (most-recent-first
        // is the existing convention); cap at 100.
        var stillPendingHistory: [PendingSongIdentity] = []
        var resolvedHistory: [String] = []
        for entry in pendingHistoryIdentities {
            if entry.firstSeenAt < cutoff { continue }
            if let songID = resolveIdentity(entry.identity, using: resolutionIndex) {
                resolvedHistory.append(songID)
            } else {
                stillPendingHistory.append(entry)
            }
        }
        if !resolvedHistory.isEmpty {
            var seen = Set(recentPlaybackSongIDs)
            let toAdd = resolvedHistory.filter { seen.insert($0).inserted }
            if !toAdd.isEmpty {
                changed = true
                recentPlaybackSongIDs.insert(contentsOf: toAdd, at: 0)
                recentPlaybackSongIDs = Array(recentPlaybackSongIDs.prefix(100))
            }
        }
        if stillPendingHistory != pendingHistoryIdentities { changed = true }
        pendingHistoryIdentities = stillPendingHistory
        return changed
    }

    /// Scan/backfill can publish several library snapshots a second. Resolving
    /// CloudKit identities after every publication repeatedly rebuilds a large
    /// lookup on the main actor. Resolve once after the mutation burst settles;
    /// the pending entries are durable, so this changes latency rather than
    /// correctness.
    private func schedulePendingIdentityFlush() {
        schedulePlaylistPendingResolution()
        guard !pendingPlaylistIdentities.isEmpty || !pendingHistoryIdentities.isEmpty else { return }
        guard allowsPendingIdentityFlush else { return }
        pendingIdentityFlushTask?.cancel()
        pendingIdentityFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingIdentityFlushTask = nil
            if self.flushPendingIdentities() {
                self.persistSnapshot()
            }
        }
    }

    /// Pending CloudKit identities are opportunistic reconciliation. Keep its
    /// whole-library lookup out of the interactive iOS foreground, including
    /// the delayed launch window that previously fired several seconds later.
    func suspendPendingIdentityResolution() {
        allowsPendingIdentityFlush = false
        pendingIdentityFlushTask?.cancel()
        pendingIdentityFlushTask = nil
    }

    func resumePendingIdentityResolution() {
        allowsPendingIdentityFlush = true
        schedulePendingIdentityFlush()
    }

    /// Convert a legacy CloudKit hard deletion into a durable tombstone. The
    /// caller re-uploads it so old offline clients cannot later recreate it.
    @discardableResult
    func deletePlaylistFromRemote(id: String) -> Bool {
        // S2: 要墓碑化的行要等发布之后才存在; 返回 false 让调用方稍后重试回推。
        if deferringUntilReady({ [weak self] in
            _ = self?.deletePlaylistFromRemote(id: id)
        }) { return false }
        guard let index = allPlaylists.firstIndex(where: { $0.id == id }) else { return false }
        let original = allPlaylists[index]
        if !allPlaylists[index].isDeleted {
            allPlaylists[index] = stampedPlaylist(allPlaylists[index], deleting: true)
        }
        guard persistPlaylistDurabilityLedger() else {
            allPlaylists[index] = original
            return false
        }
        playlistCollectionRevision &+= 1
        persistSnapshot()
        return true
    }

    private func notifyPlaylistsChanged(_ ids: [String]) {
        playlistCollectionRevision &+= 1
        NotificationCenter.default.post(
            name: .primusePlaylistsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func notifyPlaylistDeleted(_ id: String) {
        playlistCollectionRevision &+= 1
        NotificationCenter.default.post(
            name: .primusePlaylistDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    private func notifySmartPlaylistsChanged(_ ids: [String]) {
        playlistCollectionRevision &+= 1
        NotificationCenter.default.post(
            name: .primuseSmartPlaylistsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func notifySmartPlaylistDeleted(_ id: String) {
        playlistCollectionRevision &+= 1
        NotificationCenter.default.post(
            name: .primuseSmartPlaylistDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// 删除来自远端 (CloudKit) 的智能歌单。不触发 changed notification 避免
    /// 回声同步。
    func deleteSmartPlaylistFromRemote(id: String) {
        // S2: 目标行要等发布之后才在集合里。
        if deferringUntilReady({ [weak self] in
            self?.deleteSmartPlaylistFromRemote(id: id)
        }) { return }
        guard allSmartPlaylists.contains(where: { $0.id == id }) else { return }
        allSmartPlaylists.removeAll { $0.id == id }
        playlistCollectionRevision &+= 1
        persistSnapshot()
    }

    /// 应用来自远端 (CloudKit) 的智能歌单更新。比 Playlist 简单很多 ── 没有
    /// songID 解析问题, 因为 SmartPlaylist 只存规则定义不存歌曲列表。
    /// 返回 true 表示本机那份更新、远端副本被忽略, 调用方应把本机这份再推一次。
    @discardableResult
    func applyRemoteSmartPlaylist(_ smart: SmartPlaylist) -> Bool {
        // S2: 智能歌单集合在发布时整体拷回。
        if deferringUntilReady({ [weak self] in _ = self?.applyRemoteSmartPlaylist(smart) }) { return false }
        if let idx = allSmartPlaylists.firstIndex(where: { $0.id == smart.id }) {
            guard allSmartPlaylists[idx] != smart else { return false }
            // 智能歌单没有逻辑版本号, 只能比修改时间。以前拉到什么就覆盖什么:
            // 通道关着期间的本机编辑、或者只是到得晚的一份旧副本, 都会把更新的
            // 那份冲掉。
            if Self.smartPlaylistClock(allSmartPlaylists[idx]) > Self.smartPlaylistClock(smart) {
                return true
            }
            allSmartPlaylists[idx] = smart
        } else {
            allSmartPlaylists.append(smart)
        }
        sortSmartPlaylists()
        playlistCollectionRevision &+= 1
        persistSnapshot()
        return false
    }

    private static func smartPlaylistClock(_ smart: SmartPlaylist) -> Date {
        max(smart.updatedAt, smart.deletedAt ?? .distantPast)
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
    /// Advances when a replacement changes source grouping or playability
    /// used by immutable song-list snapshots. Unlike a latest-value Boolean,
    /// this cannot be cleared by a later metadata-only replacement before UI
    /// observation delivers the change.
    private(set) var songListSnapshotInvalidationRevision: UInt64 = 0
    private(set) var songReplacementToken = UUID() {
        didSet { scheduleArtworkLookupTokenRefresh() }
    }

    struct CollectionRename: Equatable, Sendable {
        let kind: LibraryFavoriteKind
        let fromTitle: String
        let fromArtist: String
        let toTitle: String
        let toArtist: String
    }

    /// 只有一整张专辑（一位艺人名下的全部歌）都挪到同一个新名字下才算改名；只挪走几首
    /// 是把歌移到别的专辑，喜欢不该跟过去。
    nonisolated static func collectionRenames(
        pairs: [(previous: Song, updated: Song)],
        originalSongs: [Song],
        oldAlbums: [String: Album],
        oldArtistNames: [String: String],
        configuration: ArtistNameConfiguration
    ) -> [CollectionRename] {
        struct Move {
            var count = 0
            var targets: Set<String> = []
            var sample: Song
        }
        var albumMoves: [String: Move] = [:]
        var artistMoves: [String: Move] = [:]
        for (previous, updated) in pairs {
            if let old = previous.albumID, let new = updated.albumID, old != new {
                albumMoves[old, default: Move(sample: updated)].count += 1
                albumMoves[old]?.targets.insert(new)
            }
            if let old = previous.artistID, let new = updated.artistID, old != new {
                artistMoves[old, default: Move(sample: updated)].count += 1
                artistMoves[old]?.targets.insert(new)
            }
        }
        guard !albumMoves.isEmpty || !artistMoves.isEmpty else { return [] }
        var albumTotals: [String: Int] = [:]
        var artistTotals: [String: Int] = [:]
        for song in originalSongs {
            if let albumID = song.albumID, albumMoves[albumID] != nil { albumTotals[albumID, default: 0] += 1 }
            if let artistID = song.artistID, artistMoves[artistID] != nil { artistTotals[artistID, default: 0] += 1 }
        }
        let unknownArtist = String(localized: "unknown_artist")
        var renames: [CollectionRename] = []
        for (oldID, move) in albumMoves.sorted(by: { $0.key < $1.key })
        where move.targets.count == 1 && move.count == albumTotals[oldID] {
            guard let album = oldAlbums[oldID],
                  let identity = AlbumGroupingPolicy.identity(
                    albumTitle: move.sample.albumTitle,
                    albumArtistName: move.sample.albumArtistName,
                    trackArtistName: move.sample.artistName,
                    unknownArtistName: unknownArtist
                  ) else { continue }
            renames.append(CollectionRename(
                kind: .album,
                fromTitle: album.title,
                fromArtist: album.artistName ?? "",
                toTitle: identity.albumTitle,
                toArtist: identity.artistName
            ))
        }
        for (oldID, move) in artistMoves.sorted(by: { $0.key < $1.key })
        where move.targets.count == 1 && move.count == artistTotals[oldID] {
            guard let oldName = oldArtistNames[oldID],
                  let newName = resolvedArtistNames(for: move.sample, configuration: configuration).first
            else { continue }
            renames.append(CollectionRename(
                kind: .artist, fromTitle: "", fromArtist: oldName, toTitle: "", toArtist: newName
            ))
        }
        return renames
    }

    private func reportCollectionRenames(
        pairs: [(previous: Song, updated: Song)],
        originalSongs: [Song]
    ) {
        guard let collectionRenameHandler, !pairs.isEmpty else { return }
        var oldAlbums: [String: Album] = [:]
        var oldArtistNames: [String: String] = [:]
        for (previous, _) in pairs {
            if let albumID = previous.albumID, oldAlbums[albumID] == nil {
                oldAlbums[albumID] = visibleAlbum(id: albumID)
            }
            if let artistID = previous.artistID, oldArtistNames[artistID] == nil {
                oldArtistNames[artistID] = visibleArtist(id: artistID)?.name
            }
        }
        let renames = Self.collectionRenames(
            pairs: pairs,
            originalSongs: originalSongs,
            oldAlbums: oldAlbums,
            oldArtistNames: oldArtistNames,
            configuration: artistNameConfiguration
        )
        if !renames.isEmpty { collectionRenameHandler(renames) }
    }

    func replaceSong(_ updatedSong: Song) {
        // S2: 与 `replaceSongs` 一致地排队。空库上 `validatedSongIndex` 返回 nil,
        // 不排队的话标签编辑 / 歌词回写 / 播放时长纠正会被直接丢掉。
        if deferringUntilReady({ [weak self] in self?.replaceSong(updatedSong) }) { return }
        // 整行替换必须排在已入队的旁挂资源补丁之后, 否则窗口内的补丁会把
        // 这次替换里的封面/歌词/MV 指针盖回旧值; 反过来, 调用方拿到的整行
        // 往往读自补丁入队之前, 所以 flush 之后还要把补丁叠回这一行。
        let updatedSong = flushPendingAssetReferencePatches(
            overlaying: [updatedSong]
        ).first ?? updatedSong
        // 这里不留整库数组的局部引用: 下面的就地发布要求缓冲只有库自己持有。
        guard let index = validatedSongIndex(for: updatedSong.id, in: songs) else { return }
        let previousSong = songsReference.value[index]
        let oldCoverRef = previousSong.coverArtFileName
        var s = updatedSong
        let keepsGrouping = Self.sharesGroupingInputs(previousSong, s)
        if keepsGrouping {
            // A duration correction at playback start or a technical refresh:
            // nothing that decides grouping changed, so the stored IDs stand.
            // Judging the row against its folder means walking the whole
            // library, on the main actor, at every such update.
            s.albumID = previousSong.albumID
            s.artistID = previousSong.artistID
        } else {
            // 标签编辑要按它将要落在的那个目录来判专辑归属, 否则改完一首歌
            // 它会先从合并后的专辑里弹出去, 等下一次整库重建才回来。
            let inferred = MusicLibrary.inferredAlbumArtists(
                for: [s],
                among: songs,
                folders: albumArtistFolders
            )
            MusicLibrary.fillDerivedIDs(
                &s,
                configuration: artistNameConfiguration,
                inferredAlbumArtist: inferred[s.id]
            )
        }
        applyAutomaticArtistArtwork(to: &s)
        // 单行改动 (播放开始纠正时长、标签编辑、单曲刮削) 此前也要在主 actor
        // 上重算整库的可见查找表, 而 250ms 后的异步派生重建又会把同一份结果
        // 再算一遍。ID / 源 / 可见性不变时走 O(改动行) 补丁, 其余情况仍旧
        // 退回整库重建。专辑 / 歌手 ID 沿用时不可能是改名, 连整库数组也不必
        // 先复制一份。
        if !(keepsGrouping && publishStableReplacementsInPlace([(index, s)])) {
            let currentSongs = songs
            var nextSongs = currentSongs
            nextSongs[index] = s
            if !publishStableMembershipReplacements(
                originalSongs: currentSongs,
                nextSongs: nextSongs,
                appliedIDs: [s.id],
                idToIndex: songIndexByID
            ) {
                songs = nextSongs
                rebuildVisibleCache()
            }
            reportCollectionRenames(pairs: [(previousSong, s)], originalSongs: currentSongs)
        }
        lastReplacedSong = s
        lastReplacedSongIDs = [s.id]
        if previousSong.sourceID != s.sourceID
            || previousSong.isPlayable != s.isPlayable {
            songListSnapshotInvalidationRevision &+= 1
        }
        songReplacementToken = UUID()
        if oldCoverRef != s.coverArtFileName {
            postArtworkInvalidation(songID: s.id, oldRef: oldCoverRef, newRef: s.coverArtFileName)
            bumpArtworkLookupRevisionIfPreferred(songIDs: [s.id])
        }
        invalidateSearchCaches()
        requestLibraryIndexMaintenance(
            .immediate,
            rebuildDerivedCollections: LibraryIndexMaintenancePolicy
                .derivedCollectionsChanged(from: previousSong, to: s)
        )
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Backfill may have just filled in title/artist/duration that lets
        // a stale pending identity finally match.
        schedulePendingIdentityFlush()
        persistSongChanges(upserts: [s])
    }

    /// Same text in every field that album/artist grouping and text repair
    /// read, so the derived IDs of the previous row still apply.
    private nonisolated static func sharesGroupingInputs(_ previous: Song, _ updated: Song) -> Bool {
        previous.id == updated.id
            && previous.sourceID == updated.sourceID
            && previous.filePath == updated.filePath
            && previous.title == updated.title
            && previous.albumTitle == updated.albumTitle
            && previous.artistName == updated.artistName
            && previous.albumArtistName == updated.albumArtistName
            && previous.sourceArtistNames == updated.sourceArtistNames
            && previous.cueSheetPath == updated.cueSheetPath
            && previous.userMetadataEditedAt == updated.userMetadataEditedAt
            // Rows from before derived IDs existed still go the full way.
            && previous.artistID != nil
            && (previous.albumID != nil || previous.albumTitle == nil)
    }

    /// Batch counterpart to `replaceSong`. Used by `MetadataBackfillService`
    /// to apply many metadata fills at once — running rebuildIndex /
    /// persistSnapshot once per batch instead of per song keeps the UI
    /// responsive when the backfill worker is at full speed (otherwise
    /// the artists/albums grouping is recomputed dozens of times a second).
    func replaceSongs(
        _ updatedSongs: [Song],
        maintenance: LibraryMaintenanceDisposition = .immediate
    ) {
        guard !updatedSongs.isEmpty else { return }
        if deferringUntilReady({ [weak self] in
            self?.replaceSongs(updatedSongs, maintenance: maintenance)
        }) { return }
        // 与 `replaceSong` 同一个约定: 先取出窗口内的补丁, flush 之后叠回整行。
        let updatedSongs = flushPendingAssetReferencePatches(overlaying: updatedSongs)
        let originalSongs = songs
        var nextSongs = originalSongs
        var idToIndex = songIndexByID
        // 与 `replaceSong` 同一个理由: 整批一起判目录兄弟, 免得刚改完的行
        // 短暂地掉出已经合并好的专辑。只有分组输入真的变了的行需要判:
        // 清封面、补时长这类批次不必在主 actor 上把整个曲库按目录过一遍。
        let regrouped = updatedSongs.filter { updated in
            guard let index = idToIndex[updated.id],
                  originalSongs.indices.contains(index),
                  originalSongs[index].id == updated.id else { return true }
            return !Self.sharesGroupingInputs(originalSongs[index], updated)
        }
        let inferred = regrouped.isEmpty ? [:] : MusicLibrary.inferredAlbumArtists(
            for: regrouped,
            among: originalSongs,
            folders: albumArtistFolders
        )

        var lastApplied: Song?
        var appliedIDs: Set<String> = []
        var missedIDs: [String] = []
        var artworkChanges: [(songID: String, oldRef: String?, newRef: String?)] = []
        var derivedCollectionsChanged = false
        var songListSnapshotChanged = false
        var repairedIndexLookup = false
        var renamePairs: [(previous: Song, updated: Song)] = []
        let derivedIDMemo = DerivedIDMemo()
        for updated in updatedSongs {
            var index = idToIndex[updated.id]
            if index.map({
                !nextSongs.indices.contains($0) || nextSongs[$0].id != updated.id
            }) ?? true {
                if !repairedIndexLookup {
                    idToIndex = Self.makeSongIndex(nextSongs)
                    repairedIndexLookup = true
                }
                index = idToIndex[updated.id]
            }
            guard let index,
                  nextSongs.indices.contains(index),
                  nextSongs[index].id == updated.id else {
                missedIDs.append(updated.id)
                continue
            }
            let previousSong = nextSongs[index]
            let oldCoverRef = previousSong.coverArtFileName
            var s = updated
            if Self.sharesGroupingInputs(previousSong, s) {
                s.albumID = previousSong.albumID
                s.artistID = previousSong.artistID
            } else {
                MusicLibrary.fillDerivedIDs(
                    &s,
                    configuration: artistNameConfiguration,
                    inferredAlbumArtist: inferred[s.id],
                    memo: derivedIDMemo
                )
            }
            applyAutomaticArtistArtwork(to: &s)
            if LibraryIndexMaintenancePolicy.derivedCollectionsChanged(
                from: previousSong,
                to: s
            ) {
                derivedCollectionsChanged = true
            }
            if previousSong.sourceID != s.sourceID
                || previousSong.isPlayable != s.isPlayable {
                songListSnapshotChanged = true
            }
            if previousSong.albumID != s.albumID || previousSong.artistID != s.artistID {
                renamePairs.append((previousSong, s))
            }
            nextSongs[index] = s
            lastApplied = s
            appliedIDs.insert(s.id)
            if oldCoverRef != s.coverArtFileName {
                artworkChanges.append((s.id, oldCoverRef, s.coverArtFileName))
            }
        }
        if repairedIndexLookup {
            songIndexByID = idToIndex
        }
        plog("📚 replaceSongs: requested=\(updatedSongs.count) applied=\(appliedIDs.count) missed=\(missedIDs.count) librarySongs=\(nextSongs.count) missedSampleID=\(missedIDs.first ?? "-") sampleLibID=\(nextSongs.first?.id ?? "-")")
        guard let lastApplied else { return }
        // Metadata backfill and scraper batches retain the same IDs, order,
        // source and visibility. Patch that common path in O(changed rows)
        // instead of rebuilding five full-library lookup collections on the
        // main actor every flush. The debounced background index rebuild below
        // refreshes source-group caches and album/artist aggregates.
        if !publishStableMembershipReplacements(
            originalSongs: originalSongs,
            nextSongs: nextSongs,
            appliedIDs: appliedIDs,
            idToIndex: idToIndex
        ) {
            songs = nextSongs
            rebuildVisibleCache()
        }
        reportCollectionRenames(pairs: renamePairs, originalSongs: originalSongs)
        lastReplacedSong = lastApplied
        lastReplacedSongIDs = appliedIDs
        if songListSnapshotChanged {
            songListSnapshotInvalidationRevision &+= 1
        }
        songReplacementToken = UUID()
        if !artworkChanges.isEmpty {
            postArtworkInvalidations(artworkChanges)
            bumpArtworkLookupRevisionIfPreferred(songIDs: artworkChanges.map(\.songID))
        }
        invalidateSearchCaches()
        requestLibraryIndexMaintenance(
            maintenance,
            rebuildDerivedCollections: derivedCollectionsChanged
        )
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Batch backfill may have surfaced enough metadata for a chunk of
        // pending identities to resolve at once.
        schedulePendingIdentityFlush()
        persistSongChanges(
            upserts: appliedIDs.compactMap { idToIndex[$0].map { nextSongs[$0] } }
        )
    }

    private struct StableMetadataReplacementRequest: Sendable {
        let songMutationGeneration: UInt64
        let visibleCacheGeneration: UInt64
        let automaticArtworkCatalogRevision: UInt64
        let updatedSongs: [Song]
        let originalSongs: [Song]
        let visibleSongs: [Song]
        let songIndexByID: [String: Int]
        let visibleSongIndexByID: [String: Int]
        let disabledSourceIDs: Set<String>
        let artistNameConfiguration: ArtistNameConfiguration
        let automaticArtworkCatalogsBySource: [String: SourceArtistArtworkCatalog]
    }

    private struct StableVisibleSongReplacement: Sendable {
        let index: Int
        let song: Song
    }

    private struct StableArtworkReplacement: Sendable {
        let songID: String
        let oldReference: String?
        let newReference: String?
    }

    private struct PreparedStableMetadataReplacements: Sendable {
        let nextSongs: [Song]
        let nextVisibleSongs: [Song]
        let idToIndex: [String: Int]
        let repairedIndexLookup: Bool
        let lastApplied: Song
        let appliedIDs: Set<String>
        let appliedSongs: [Song]
        let missedIDs: [String]
        let visibleUpdates: [StableVisibleSongReplacement]
        let artworkChanges: [StableArtworkReplacement]
        let derivedCollectionsChanged: Bool
        let songListSnapshotChanged: Bool
    }

    /// 仅供测试注入: 拉长离主线程准备的时长, 好让另一次可见缓存发布确定性地
    /// 抢在这批补丁前面落地。生产路径保持 nil。
    @ObservationIgnored var stableMetadataPreparationDelayForTesting: Duration?

    /// Metadata backfill retains song IDs, order, source membership, and
    /// visibility. Prepare its copy-on-write array snapshots on a utility
    /// executor so publishing the batch on the main actor is only a pointer
    /// swap plus O(changed rows) lookup patches.
    func replaceSongsPreparedOffMain(
        _ updatedSongs: [Song],
        maintenance: LibraryMaintenanceDisposition = .deferred
    ) async {
        guard !updatedSongs.isEmpty else { return }
        // S2: 异步入口排队它的同步回退路径。
        if deferringUntilReady({ [weak self] in
            self?.replaceSongs(updatedSongs, maintenance: maintenance)
        }) { return }
        // 先落地补丁再快照: 离主线程准备的整行替换必须看到窗口内的补丁, 并且
        // 补丁写过的字段要叠回这一批整行, 否则更早的读取会把它们盖回去。
        let updatedSongs = flushPendingAssetReferencePatches(overlaying: updatedSongs)

        // A source toggle or another song mutation can land while preparation
        // is suspended. Rebase once on the newest immutable snapshots before
        // falling back to the general synchronous path.
        for _ in 0..<2 {
            let request = StableMetadataReplacementRequest(
                songMutationGeneration: songMutationGeneration,
                visibleCacheGeneration: visibleCacheGeneration,
                automaticArtworkCatalogRevision: automaticArtistArtworkCatalogRevision,
                updatedSongs: updatedSongs,
                originalSongs: songs,
                visibleSongs: visibleSongs,
                songIndexByID: songIndexByID,
                visibleSongIndexByID: visibleSongIndexByID,
                disabledSourceIDs: disabledSourceIDs,
                artistNameConfiguration: artistNameConfiguration,
                automaticArtworkCatalogsBySource: automaticArtistArtworkCatalogsBySource
            )
            let preparationDelay = stableMetadataPreparationDelayForTesting
            let prepared = await Task.detached(priority: .utility) {
                if let preparationDelay { try? await Task.sleep(for: preparationDelay) }
                return Self.prepareStableMetadataReplacements(request)
            }.value

            // visibleCacheGeneration 覆盖 songs 不变但可见缓存已被重新发布的
            // 情况 (异步派生重建落地 / 稳定成员替换), 否则这份补丁会把更新的
            // visibleSongs 换回旧数组, 而 visibleSongIndexByID 仍指向新数组。
            guard songMutationGeneration == request.songMutationGeneration,
                  visibleCacheGeneration == request.visibleCacheGeneration,
                  automaticArtistArtworkCatalogRevision == request.automaticArtworkCatalogRevision,
                  disabledSourceIDs == request.disabledSourceIDs,
                  artistNameConfiguration == request.artistNameConfiguration else {
                continue
            }
            guard let prepared else {
                replaceSongs(updatedSongs, maintenance: maintenance)
                return
            }
            applyPreparedStableMetadataReplacements(prepared, maintenance: maintenance)
            return
        }

        replaceSongs(updatedSongs, maintenance: maintenance)
    }

    private nonisolated static func prepareStableMetadataReplacements(
        _ request: StableMetadataReplacementRequest
    ) -> PreparedStableMetadataReplacements? {
        var nextSongs = request.originalSongs
        var idToIndex = request.songIndexByID
        var repairedIndexLookup = false
        var lastApplied: Song?
        var appliedIDs: Set<String> = []
        var missedIDs: [String] = []
        var artworkChanges: [StableArtworkReplacement] = []
        var derivedCollectionsChanged = false
        var songListSnapshotChanged = false

        let derivedIDMemo = DerivedIDMemo()
        for updated in request.updatedSongs {
            var index = idToIndex[updated.id]
            if index.map({
                !nextSongs.indices.contains($0) || nextSongs[$0].id != updated.id
            }) ?? true {
                if !repairedIndexLookup {
                    idToIndex = makeSongIndex(nextSongs)
                    repairedIndexLookup = true
                }
                index = idToIndex[updated.id]
            }
            guard let index,
                  nextSongs.indices.contains(index),
                  nextSongs[index].id == updated.id else {
                missedIDs.append(updated.id)
                continue
            }

            let previousSong = nextSongs[index]
            let oldCoverReference = previousSong.coverArtFileName
            var song = updated
            if sharesGroupingInputs(previousSong, song) {
                // 只补了时长、码率、封面这类字段: 沿用整库重建纠正过的 ID,
                // 逐首口径重算会把它们算回去, 再引来一次整库重建。
                song.albumID = previousSong.albumID
                song.artistID = previousSong.artistID
            } else {
                // 离主 actor 的稳定替换同样走逐首口径, 由整库重建的
                // `albumIDCorrections` 纠正。
                fillDerivedIDs(&song, configuration: request.artistNameConfiguration, memo: derivedIDMemo)
            }
            applyAutomaticArtistArtwork(
                to: &song,
                catalogsBySource: request.automaticArtworkCatalogsBySource,
                artistNameConfiguration: request.artistNameConfiguration
            )
            if LibraryIndexMaintenancePolicy.derivedCollectionsChanged(
                from: previousSong,
                to: song
            ) {
                derivedCollectionsChanged = true
            }
            if previousSong.sourceID != song.sourceID
                || previousSong.isPlayable != song.isPlayable {
                songListSnapshotChanged = true
            }
            nextSongs[index] = song
            lastApplied = song
            appliedIDs.insert(song.id)
            if oldCoverReference != song.coverArtFileName {
                artworkChanges.append(
                    StableArtworkReplacement(
                        songID: song.id,
                        oldReference: oldCoverReference,
                        newReference: song.coverArtFileName
                    )
                )
            }
        }

        guard let lastApplied else { return nil }
        // 没有停用的源时可见数组就是整库数组本身: 补完一份直接共用,
        // 不再为可见集另拷一份整库。
        let visibleSharesSongs = sharesStorage(request.visibleSongs, request.originalSongs)
        var nextVisibleSongs = visibleSharesSongs ? [] : request.visibleSongs
        var visibleUpdates: [StableVisibleSongReplacement] = []
        visibleUpdates.reserveCapacity(appliedIDs.count)
        for id in appliedIDs {
            guard let songIndex = idToIndex[id],
                  request.originalSongs.indices.contains(songIndex),
                  nextSongs.indices.contains(songIndex) else {
                return nil
            }
            let oldSong = request.originalSongs[songIndex]
            let newSong = nextSongs[songIndex]
            guard oldSong.id == newSong.id,
                  oldSong.sourceID == newSong.sourceID else {
                return nil
            }

            let isVisible = !request.disabledSourceIDs.contains(newSong.sourceID)
            if isVisible {
                guard let visibleIndex = request.visibleSongIndexByID[id],
                      request.visibleSongs.indices.contains(visibleIndex),
                      request.visibleSongs[visibleIndex].id == id else {
                    return nil
                }
                if !visibleSharesSongs { nextVisibleSongs[visibleIndex] = newSong }
                visibleUpdates.append(
                    StableVisibleSongReplacement(index: visibleIndex, song: newSong)
                )
            } else if request.visibleSongIndexByID[id] != nil {
                return nil
            }
        }

        if visibleSharesSongs { nextVisibleSongs = nextSongs }

        let appliedSongs = appliedIDs.compactMap { id in
            idToIndex[id].map { nextSongs[$0] }
        }
        return PreparedStableMetadataReplacements(
            nextSongs: nextSongs,
            nextVisibleSongs: nextVisibleSongs,
            idToIndex: idToIndex,
            repairedIndexLookup: repairedIndexLookup,
            lastApplied: lastApplied,
            appliedIDs: appliedIDs,
            appliedSongs: appliedSongs,
            missedIDs: missedIDs,
            visibleUpdates: visibleUpdates,
            artworkChanges: artworkChanges,
            derivedCollectionsChanged: derivedCollectionsChanged,
            songListSnapshotChanged: songListSnapshotChanged
        )
    }

    private func applyPreparedStableMetadataReplacements(
        _ prepared: PreparedStableMetadataReplacements,
        maintenance: LibraryMaintenanceDisposition
    ) {
        if prepared.repairedIndexLookup {
            songIndexByID = prepared.idToIndex
        }
        plog("📚 replaceSongsPreparedOffMain: requested=\(prepared.appliedIDs.count + prepared.missedIDs.count) applied=\(prepared.appliedIDs.count) missed=\(prepared.missedIDs.count) librarySongs=\(prepared.nextSongs.count) missedSampleID=\(prepared.missedIDs.first ?? "-") sampleLibID=\(prepared.nextSongs.first?.id ?? "-")")

        songs = prepared.nextSongs
        visibleSongs = prepared.nextVisibleSongs
        patchSourceAssetReferences(
            songIDs: prepared.visibleUpdates.map(\.song.id),
            invalidatesSort: prepared.songListSnapshotChanged
        )

        lastReplacedSong = prepared.lastApplied
        lastReplacedSongIDs = prepared.appliedIDs
        if prepared.songListSnapshotChanged {
            songListSnapshotInvalidationRevision &+= 1
        }
        songReplacementToken = UUID()
        if !prepared.artworkChanges.isEmpty {
            postArtworkInvalidations(
                prepared.artworkChanges.map {
                    ($0.songID, $0.oldReference, $0.newReference)
                }
            )
            bumpArtworkLookupRevisionIfPreferred(
                songIDs: prepared.artworkChanges.map(\.songID)
            )
        }
        invalidateSearchCaches()
        requestLibraryIndexMaintenance(
            maintenance,
            rebuildDerivedCollections: prepared.derivedCollectionsChanged
        )
        // IDs and membership are guaranteed stable, so playlist/history cleanup
        // cannot remove anything here. Pending identity resolution may still
        // benefit from newly filled title/artist metadata.
        schedulePendingIdentityFlush()
        persistSongChanges(upserts: prepared.appliedSongs)
    }

    private func validatedSongIndex(for id: String, in snapshot: [Song]) -> Int? {
        if let index = songIndexByID[id],
           snapshot.indices.contains(index),
           snapshot[index].id == id {
            return index
        }

        songIndexByID = Self.makeSongIndex(snapshot)
        guard let index = songIndexByID[id],
              snapshot.indices.contains(index),
              snapshot[index].id == id else {
            return nil
        }
        return index
    }

    private func publishStableMembershipReplacements(
        originalSongs: [Song],
        nextSongs: [Song],
        appliedIDs: Set<String>,
        idToIndex: [String: Int]
    ) -> Bool {
        guard originalSongs.count == nextSongs.count else { return false }

        var visibleUpdates: [(visibleIndex: Int, song: Song)] = []
        visibleUpdates.reserveCapacity(appliedIDs.count)
        for id in appliedIDs {
            guard let songIndex = idToIndex[id],
                  originalSongs.indices.contains(songIndex),
                  nextSongs.indices.contains(songIndex) else {
                return false
            }
            let oldSong = originalSongs[songIndex]
            let newSong = nextSongs[songIndex]
            guard oldSong.id == newSong.id,
                  oldSong.sourceID == newSong.sourceID else {
                return false
            }

            let isVisible = !disabledSourceIDs.contains(newSong.sourceID)
            if isVisible {
                guard let visibleIndex = visibleSongIndexByID[id],
                      visibleSongs.indices.contains(visibleIndex) else {
                    return false
                }
                visibleUpdates.append((visibleIndex, newSong))
            } else if visibleSongIndexByID[id] != nil {
                return false
            }
        }

        // One observable array publication per batch. Without disabled
        // sources the visible array is the library array itself, so the
        // patched copy is shared instead of copying the library twice.
        let nextVisibleSongs: [Song]
        if sharesStorage(visibleSongs, originalSongs) {
            nextVisibleSongs = nextSongs
        } else {
            var patched = visibleSongs
            for update in visibleUpdates {
                patched[update.visibleIndex] = update.song
            }
            nextVisibleSongs = patched
        }
        songs = nextSongs
        visibleSongs = nextVisibleSongs
        patchSourceAssetReferences(
            songIDs: visibleUpdates.map(\.song.id),
            invalidatesSort: appliedIDs.contains { id in
                guard let index = idToIndex[id] else { return false }
                return originalSongs[index].isPlayable != nextSongs[index].isPlayable
            }
        )
        return true
    }

    /// `publishStableMembershipReplacements` 的就地版: 调用方只交改动行
    /// (下标 + 新行), 不必先复制整库。判定与发布和原版一致; 判定不过时
    /// 什么都没动, 返回 false 让调用方退回原路。
    private func publishStableReplacementsInPlace(_ replacements: [(index: Int, song: Song)]) -> Bool {
        var visibleUpdates: [(visibleIndex: Int, song: Song)] = []
        visibleUpdates.reserveCapacity(replacements.count)
        var playabilityChanged = false
        for replacement in replacements {
            guard songsReference.value.indices.contains(replacement.index) else { return false }
            let oldSong = songsReference.value[replacement.index]
            let newSong = replacement.song
            guard oldSong.id == newSong.id,
                  oldSong.sourceID == newSong.sourceID else {
                return false
            }
            if oldSong.isPlayable != newSong.isPlayable { playabilityChanged = true }
            if !disabledSourceIDs.contains(newSong.sourceID) {
                guard let visibleIndex = visibleSongIndexByID[newSong.id],
                      visibleSongsReference.value.indices.contains(visibleIndex) else {
                    return false
                }
                visibleUpdates.append((visibleIndex, newSong))
            } else if visibleSongIndexByID[newSong.id] != nil {
                return false
            }
        }
        var nextSongs: [Song] = []
        let visibleShared = takeLibrarySongsForPatching(into: &nextSongs)
        for replacement in replacements { nextSongs[replacement.index] = replacement.song }
        if visibleShared {
            songs = nextSongs
            visibleSongs = nextSongs
        } else {
            var patched = visibleSongs
            for update in visibleUpdates { patched[update.visibleIndex] = update.song }
            songs = nextSongs
            visibleSongs = patched
        }
        patchSourceAssetReferences(
            songIDs: visibleUpdates.map(\.song.id),
            invalidatesSort: playabilityChanged
        )
        return true
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

    private func postArtworkInvalidations(
        _ changes: [(songID: String, oldRef: String?, newRef: String?)]
    ) {
        let songIDs = changes.map(\.songID)
        let refs = changes.flatMap { [$0.oldRef, $0.newRef].compactMap { $0 } }
        NotificationCenter.default.post(
            name: .primuseArtworkDidInvalidate,
            object: nil,
            userInfo: [
                "songIDs": songIDs,
                "tokens": refs,
            ]
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
    private struct DerivedIndexRequest: Sendable {
        let generation: Int
        let songMutationGeneration: UInt64
        let songs: [Song]
        let artistNameConfiguration: ArtistNameConfiguration
        let albumArtistFolders: AlbumArtistFolderIndex
        let disabledSourceIDs: Set<String>
        let spokenWordClassification: SpokenWordClassificationInputs
        let previousVisibleSongs: [Song]
    }

    private struct DerivedIndexComputation: Sendable {
        let signature: String
        let albums: [Album]
        let artists: [Artist]
        let albumIDCorrections: [String: String]
        let visibleCache: PreparedVisibleCache
        /// 后台整库重建实际花的时间；其它路径（换 ID 等）不计。
        var elapsedSeconds: TimeInterval = 0
        /// The request's songs with the corrections applied, when there were
        /// any; the visible cache was built from this very array.
        var correctedSongs: [Song]? = nil
    }

    /// 上一次后台整库重建花了多久：扫描期间的合并间隔按它放宽（大曲库每次重建要好几秒）。
    @ObservationIgnored private var lastIndexRebuildSeconds: TimeInterval = 0

    private var rebuildIndexTask: Task<Void, Never>?
    private var rebuildIndexGeneration: Int = 0
    private var rebuildIndexWorkState = LatestOnlyLibraryIndexWorkState()
    private var pendingRebuildIndexRequest: DerivedIndexRequest?
    private var deferredLibraryMaintenancePending = false
    private var deferredDerivedIndexMaintenancePending = false
    /// 这一批待落地的维护里是否包含扫描的中间 flush。中间 flush 不受
    /// `deferredMaintenanceAllowed()` 闸门约束, 见 requestLibraryIndexMaintenance。
    private var deferredIncrementalScanMaintenancePending = false
    private var deferredLibraryMaintenanceTask: Task<Void, Never>?
    /// 已排期的延后维护截止时间。用于"更早的截止时间获胜"的重排判定。
    @ObservationIgnored private var deferredLibraryMaintenanceDeadline: Date?
    /// 一次"丢弃连击"里是否已经立即补发过一次派生重建。落地一次就清零。
    @ObservationIgnored private var didRequeueAfterDiscard = false
    /// 只统计"丢弃后立即补发"的次数, 单调递增。与
    /// `songMutationGenerationForMaintenance` 一样只读暴露, 供维护与回归测试
    /// 观察补发是否被合并。
    @ObservationIgnored private(set) var immediateIndexRequeueCountForMaintenance = 0
    @ObservationIgnored private let deferredMaintenanceAllowed: @MainActor () -> Bool
    /// Collapse mutations published in the same run-loop burst before starting
    /// a full-library grouping/sort. More importantly, cancellation can happen
    /// while the task is still sleeping instead of after expensive work began.
    private static let rebuildIndexDebounce: Duration = .milliseconds(250)

    private func requestLibraryIndexMaintenance(
        _ disposition: LibraryMaintenanceDisposition,
        rebuildDerivedCollections: Bool = true
    ) {
        switch disposition {
        case .immediate:
            let shouldRebuildDerivedCollections = rebuildDerivedCollections
                || deferredDerivedIndexMaintenancePending
            deferredLibraryMaintenanceTask?.cancel()
            deferredLibraryMaintenanceTask = nil
            deferredLibraryMaintenanceDeadline = nil
            deferredLibraryMaintenancePending = false
            deferredDerivedIndexMaintenancePending = false
            deferredIncrementalScanMaintenancePending = false
            spotlightIndexRevision &+= 1
            if shouldRebuildDerivedCollections { rebuildIndex() }
        case .deferred, .deferredIncremental:
            deferredLibraryMaintenancePending = true
            deferredDerivedIndexMaintenancePending =
                deferredDerivedIndexMaintenancePending || rebuildDerivedCollections
            // 扫描的中间 flush 不看"设备忙"闸门: 闸门是给数小时的 backfill 准备
            // 的, 而扫描是用户刚刚发起、已经在跑的工作。挡住它等于热状态不是
            // nominal / app 不在前台时, 整个扫描期间可见资料库一直停在扫描前。
            let isIncrementalScanFlush = disposition == .deferredIncremental
            if isIncrementalScanFlush {
                deferredIncrementalScanMaintenancePending = true
            }
            guard LibraryIndexMaintenancePolicy.allowsDeferredMaintenance(
                isIncrementalScanFlush: isIncrementalScanFlush,
                deviceMaintenanceAllowed: deferredMaintenanceAllowed()
            ) else { return }
            let requestedInterval = isIncrementalScanFlush
                ? LibraryIndexMaintenancePolicy.incrementalScanMaintenanceInterval(
                    lastRebuildSeconds: lastIndexRebuildSeconds
                )
                : LibraryIndexMaintenancePolicy.maximumDeferredMaintenanceInterval
            // 已排期的 flush 更早就沿用它: 每次 flush 都重排会把截止时间一直
            // 往后推, 连续扫描下这个定时器永远等不到。
            let scheduled = deferredLibraryMaintenanceTask == nil
                ? nil
                : deferredLibraryMaintenanceDeadline.map {
                    max(0, $0.timeIntervalSinceNow)
                }
            guard let interval = LibraryIndexMaintenancePolicy.deferredMaintenanceRearmInterval(
                secondsUntilScheduledFlush: scheduled,
                requestedInterval: requestedInterval
            ) else { return }
            deferredLibraryMaintenanceTask?.cancel()
            deferredLibraryMaintenanceDeadline = Date().addingTimeInterval(interval)
            deferredLibraryMaintenanceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.flushDeferredLibraryMaintenance()
            }
        }
    }

    /// Backfill persists song changes independently. Keep its global grouping
    /// and Spotlight work pending while iOS is backgrounded or thermally busy;
    /// activation and thermal recovery coalesce those changes into one rebuild.
    func flushDeferredLibraryMaintenance(force: Bool = false) {
        deferredLibraryMaintenanceTask?.cancel()
        deferredLibraryMaintenanceTask = nil
        deferredLibraryMaintenanceDeadline = nil
        guard deferredLibraryMaintenancePending else { return }
        // 定时器为扫描的中间 flush 武装过, 到点的这次重建同样不看闸门。
        guard force || LibraryIndexMaintenancePolicy.allowsDeferredMaintenance(
            isIncrementalScanFlush: deferredIncrementalScanMaintenancePending,
            deviceMaintenanceAllowed: deferredMaintenanceAllowed()
        ) else { return }
        deferredLibraryMaintenancePending = false
        deferredIncrementalScanMaintenancePending = false
        let shouldRebuildDerivedCollections = deferredDerivedIndexMaintenancePending
        deferredDerivedIndexMaintenancePending = false
        spotlightIndexRevision &+= 1
        if shouldRebuildDerivedCollections { rebuildIndex() }
    }

    private func rebuildIndex() {
        rebuildIndexGeneration &+= 1
        let request = DerivedIndexRequest(
            generation: rebuildIndexGeneration,
            songMutationGeneration: songMutationGeneration,
            songs: songs,
            artistNameConfiguration: artistNameConfiguration,
            albumArtistFolders: albumArtistFolders,
            disabledSourceIDs: disabledSourceIDs,
            spokenWordClassification: SpokenWordStore.shared.classificationSnapshot,
            previousVisibleSongs: visibleSongs
        )

        switch rebuildIndexWorkState.submit(generation: request.generation) {
        case .start:
            startIndexRebuild(request)
        case .replacePending:
            pendingRebuildIndexRequest = request
            rebuildIndexTask?.cancel()
        }
    }

    private func startIndexRebuild(_ request: DerivedIndexRequest) {
        rebuildIndexTask = Task.detached(priority: .utility) { [weak self] in
            var computation: DerivedIndexComputation?
            do {
                try await Task.sleep(for: Self.rebuildIndexDebounce)
            } catch {
                await MainActor.run {
                    self?.finishIndexRebuild(request: request, computation: nil)
                }
                return
            }
            if !Task.isCancelled {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let signature = MusicLibrary.derivedIndexSignature(
                    for: request.songs,
                    configuration: request.artistNameConfiguration
                )
                if !Task.isCancelled,
                   let result = MusicLibrary.computeAlbumsAndArtistsCancellable(
                    songs: request.songs,
                    configuration: request.artistNameConfiguration,
                    folders: request.albumArtistFolders
                   ), !Task.isCancelled {
                    // 可见缓存要看的是纠正后的 albumID, 否则刚合并的那几首会
                    // 在下一次整库重建之前一直挂在旧专辑上。
                    var correctedSongs = request.songs
                    if !result.albumIDCorrections.isEmpty {
                        for index in correctedSongs.indices {
                            guard let albumID = result.albumIDCorrections[correctedSongs[index].id],
                                  correctedSongs[index].albumID != albumID else { continue }
                            correctedSongs[index].albumID = albumID
                        }
                    }
                    let visibleCache = MusicLibrary.prepareVisibleCache(
                        songs: correctedSongs,
                        albums: result.albums,
                        artists: result.artists,
                        artistNameConfiguration: request.artistNameConfiguration,
                        disabledSourceIDs: request.disabledSourceIDs,
                        spokenWordClassification: request.spokenWordClassification,
                        previousVisibleSongs: request.previousVisibleSongs
                    )
                    if !Task.isCancelled {
                        computation = DerivedIndexComputation(
                            signature: signature,
                            albums: result.albums,
                            artists: result.artists,
                            albumIDCorrections: result.albumIDCorrections,
                            visibleCache: visibleCache,
                            elapsedSeconds: ProcessInfo.processInfo.systemUptime - startedAt,
                            correctedSongs: result.albumIDCorrections.isEmpty ? nil : correctedSongs
                        )
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.finishIndexRebuild(request: request, computation: computation)
            }
        }
    }

    private func finishIndexRebuild(
        request: DerivedIndexRequest,
        computation: DerivedIndexComputation?
    ) {
        guard rebuildIndexWorkState.activeGeneration == request.generation else { return }
        if let computation { lastIndexRebuildSeconds = computation.elapsedSeconds }
        var applied = false
        if let computation,
           rebuildIndexGeneration == request.generation,
           songMutationGeneration == request.songMutationGeneration,
           disabledSourceIDs == request.disabledSourceIDs,
           artistNameConfiguration == request.artistNameConfiguration {
            albums = computation.albums
            artists = computation.artists
            derivedIndexSignature = computation.signature
            applyPreparedVisibleCache(computation.visibleCache)
            applyAlbumIDCorrections(
                computation.albumIDCorrections,
                correctedSongs: computation.correctedSongs
            )
            persistDerivedIndexCache()
            applied = true
            migrateLegacyArtistIdentities(artists: computation.artists)
            // 落地一次即结束当前的丢弃连击, 下一轮重叠可以再立即补发一次。
            didRequeueAfterDiscard = false
        }

        let nextGeneration = rebuildIndexWorkState.complete(generation: request.generation)
        rebuildIndexTask = nil
        if let nextGeneration,
           let nextRequest = pendingRebuildIndexRequest,
           nextRequest.generation == nextGeneration {
            pendingRebuildIndexRequest = nil
            startIndexRebuild(nextRequest)
            return
        }
        pendingRebuildIndexRequest = nil

        // 守卫失败时结果只能丢弃 (否则旧快照会盖掉更新的 lyricsText /
        // coverRef), 但推进 songMutationGeneration 的一批 mutator 并不请求
        // 派生维护 —— updateLyricsText / updateAssetReferences /
        // updateMusicVideoReference, 以及只改技术字段的 backfill 批次。
        // 没有人补发时 `songs` 已经更新而 visibleSongs/visibleAlbums 会一直
        // 停留在扫描前的样子, 所以这里自己补一次。不走
        // requestLibraryIndexMaintenance(.immediate), 避免无谓地 bump
        // spotlightIndexRevision; 后台 / 高热时只置位标志, 交给
        // didBecomeActive / 热状态观察者或 backfill 结束时的 flush 接手。
        guard computation != nil, !applied else { return }
        let maintenanceAllowed = deferredMaintenanceAllowed()
        if maintenanceAllowed, !didRequeueAfterDiscard {
            // 一次连击只允许一次立即补发。刮削 / 回填批量跑的时候几乎每一次
            // 分组都会撞上新的 mutation, 无条件补发会让整库分组背靠背连跑到
            // 扫描结束, 而每次落地又会作废正在准备的 off-main 补丁。
            didRequeueAfterDiscard = true
            immediateIndexRequeueCountForMaintenance &+= 1
            rebuildIndex()
        } else if maintenanceAllowed {
            // 之后的丢弃交回 60s 维护节奏
            // (LibraryIndexMaintenancePolicy.maximumDeferredMaintenanceInterval),
            // 它设计出来针对的正是这种连续抖动。
            requestLibraryIndexMaintenance(.deferred)
        } else {
            deferredLibraryMaintenancePending = true
            deferredDerivedIndexMaintenancePending = true
        }
    }

    /// 启动 / 测试场景下需要"调用即生效"的同步重建。比异步版本贵 (会卡
    /// main actor 一下), 但只在 init / migration 等 UI 还没起来的路径用。
    private func rebuildIndexSync(precomputedSignature: String? = nil) {
        let result = MusicLibrary.computeAlbumsAndArtists(
            songs: songs,
            configuration: artistNameConfiguration,
            folders: albumArtistFolders
        )
        albums = result.albums
        artists = result.artists
        derivedIndexSignature = precomputedSignature
            ?? MusicLibrary.derivedIndexSignature(
                for: songs,
                configuration: artistNameConfiguration
            )
        applyAlbumIDCorrections(result.albumIDCorrections)
        rebuildVisibleCache()
        migrateLegacyArtistIdentities(artists: artists)
    }

    /// Artist IDs changed key once (case/width/diacritic folding). State that
    /// is addressed by an artist ID follows the artist to its new ID; the old
    /// entry is left in place so nothing is deleted remotely.
    private func migrateLegacyArtistIdentities(artists: [Artist]) {
        guard !didMigrateLegacyArtistIdentities else { return }
        didMigrateLegacyArtistIdentities = true
        var moved: [(legacy: LibraryArtworkOwner, current: LibraryArtworkOwner)] = []
        for artist in artists {
            let legacyID = Self.hashID(ArtistIdentityPolicy.legacyGroupingKey(artist.name))
            guard legacyID != artist.id else { continue }
            moved.append((
                LibraryArtworkOwner(kind: .artist, id: legacyID),
                LibraryArtworkOwner(kind: .artist, id: artist.id)
            ))
        }
        guard !moved.isEmpty else { return }
        for pair in moved {
            if let legacy = artworkOverridesByOwner[pair.legacy.storageKey],
               artworkOverridesByOwner[pair.current.storageKey] == nil {
                _ = setArtworkOverride(
                    owner: pair.current,
                    mode: legacy.mode,
                    selectedSongIdentity: legacy.selectedSongIdentity,
                    uploadedContentID: legacy.uploadedContentID
                )
            }
        }
        #if !os(tvOS)
        // 快捷入口只存在于 iOS / macOS 的资料库页, 固定项由它自己的存储改写。
        LibraryPinStorage.migrateArtistIdentities(
            renames: Dictionary(
                moved.map { ($0.legacy.id, $0.current.id) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        #endif
    }

    /// Songs added or edited one at a time got the per-song album ID; the full
    /// rebuild knows their folder siblings and hands the corrected IDs back.
    /// `correctedSongs`: the same library already corrected off the main
    /// actor (and, without disabled sources, just published as the visible
    /// array). Adopting it keeps one array instead of correcting a second
    /// copy of the whole library here.
    private func applyAlbumIDCorrections(_ corrections: [String: String], correctedSongs: [Song]? = nil) {
        guard !corrections.isEmpty else { return }
        if let correctedSongs, correctedSongs.count == songs.count {
            var changed: [Song] = []
            var consistent = true
            for (songID, albumID) in corrections {
                guard let index = songIndexByID[songID], songs[index].albumID != albumID else { continue }
                guard correctedSongs[index].id == songID, correctedSongs[index].albumID == albumID else {
                    consistent = false
                    break
                }
                changed.append(correctedSongs[index])
            }
            if consistent {
                guard !changed.isEmpty else { return }
                songs = correctedSongs
                persistSongChanges(upserts: changed)
                markPortableSnapshotDirty()
                return
            }
        }
        var next = songs
        var changed: [Song] = []
        for (songID, albumID) in corrections {
            guard let index = songIndexByID[songID], next[index].albumID != albumID else { continue }
            next[index].albumID = albumID
            changed.append(next[index])
        }
        guard !changed.isEmpty else { return }
        songs = next
        persistSongChanges(upserts: changed)
        markPortableSnapshotDirty()
    }

    /// tvOS 下载到新快照后重新从磁盘加载整库(songs/playlists 等)。
    func reloadFromDisk(preferExternalSnapshot: Bool = true) {
        loadSnapshot(preferExternalSnapshot: preferExternalSnapshot)
    }

    /// A scan must not publish completion while its visible catalogue still
    /// represents the preceding generation.
    func waitForPendingIndex() async {
        flushDeferredLibraryMaintenance(force: true)
        while let task = rebuildIndexTask {
            await task.value
        }
    }

    func remapSongIDs(_ replacements: [String: String]) {
        guard !replacements.isEmpty else { return }
        // S2: 换 ID 要作用在发布后的 songs / 歌单成员 / 播放历史上, 空库上做
        // 等于什么都没做, 而随后的拷回还会把旧 ID 原样带回来。
        if deferringUntilReady({ [weak self] in self?.remapSongIDs(replacements) }) { return }
        applySongIDRemapping(replacements)
    }

    @discardableResult
    func remapSongIDsInBackground(_ replacements: [String: String]) async -> Bool {
        guard !replacements.isEmpty else { return true }
        while !Task.isCancelled {
            await whenReady()
            await waitForPendingIndex()
            let generation = songMutationGeneration
            let visibilityGeneration = visibleCacheGeneration
            let snapshot = songs
            let configuration = artistNameConfiguration
            let folders = albumArtistFolders
            let hidden = disabledSourceIDs
            let classification = SpokenWordStore.shared.classificationSnapshot
            let previousVisible = visibleSongs
            let prepared = await Task.detached(priority: .userInitiated) {
                var remapped = Self.songsByRemappingIDs(snapshot, replacements: replacements)
                let result = Self.computeAlbumsAndArtists(
                    songs: remapped,
                    configuration: configuration,
                    folders: folders
                )
                for index in remapped.indices {
                    if let corrected = result.albumIDCorrections[remapped[index].id] {
                        remapped[index].albumID = corrected
                    }
                }
                return DerivedIndexComputation(
                    signature: Self.derivedIndexSignature(for: remapped, configuration: configuration),
                    albums: result.albums,
                    artists: result.artists,
                    albumIDCorrections: result.albumIDCorrections,
                    visibleCache: Self.prepareVisibleCache(
                        songs: remapped, albums: result.albums, artists: result.artists,
                        artistNameConfiguration: configuration, disabledSourceIDs: hidden,
                        spokenWordClassification: classification, previousVisibleSongs: previousVisible
                    )
                )
            }.value
            guard !Task.isCancelled else { return false }
            guard isReady, generation == songMutationGeneration,
                  visibilityGeneration == visibleCacheGeneration,
                  configuration == artistNameConfiguration, hidden == disabledSourceIDs else { continue }
            applySongIDRemapping(replacements, preparedIndex: prepared)
            return true
        }
        return false
    }

    private nonisolated static func songsByRemappingIDs(
        _ songs: [Song], replacements: [String: String]
    ) -> [Song] {
        var seen = Set<String>()
        return songs.compactMap { original in
            var song = original
            song.id = replacements[song.id] ?? song.id
            return seen.insert(song.id).inserted ? song : nil
        }
    }

    private func applySongIDRemapping(
        _ replacements: [String: String], preparedIndex: DerivedIndexComputation? = nil
    ) {
        var remappedReviews: [String: LibraryReview] = [:]
        for review in libraryReviewsBySubject.values {
            let subject = review.subject.kind == .song
                ? LibraryReviewSubject.song(replacements[review.subject.entityID] ?? review.subject.entityID)
                : review.subject
            let remapped = LibraryReview(
                subject: subject, rating: review.rating, comment: review.comment,
                updatedAt: review.updatedAt, deletedAt: review.deletedAt,
                ratingModifiedAt: review.ratingModifiedAt, commentModifiedAt: review.commentModifiedAt,
                serverRatingTarget: review.serverRatingTarget, ratingFromServer: review.ratingFromServer
            )
            remappedReviews[subject.storageKey] = remappedReviews[subject.storageKey].map {
                LibraryReviewReconciliationPolicy.winner(local: $0, remote: remapped)
            } ?? remapped
        }
        libraryReviewsBySubject = remappedReviews
        libraryReviewRevision &+= 1
        songs = Self.songsByRemappingIDs(songs, replacements: replacements)
        for playlistID in playlistSongIDs.keys {
            var included = Set<String>()
            playlistSongIDs[playlistID] = playlistSongIDs[playlistID]?.compactMap { old in
                let id = replacements[old] ?? old
                return included.insert(id).inserted ? id : nil
            }
        }
        var recent = Set<String>()
        recentPlaybackSongIDs = recentPlaybackSongIDs.compactMap { old in
            let id = replacements[old] ?? old
            return recent.insert(id).inserted ? id : nil
        }
        if let preparedIndex {
            albums = preparedIndex.albums
            artists = preparedIndex.artists
            derivedIndexSignature = preparedIndex.signature
            applyPreparedVisibleCache(preparedIndex.visibleCache)
            applyAlbumIDCorrections(preparedIndex.albumIDCorrections)
            migrateLegacyArtistIdentities(artists: preparedIndex.artists)
        } else {
            rebuildIndexSync()
        }
        persistSongChanges(upserts: songs, deletingIDs: Set(replacements.keys))
        persistPlaylistDurabilityLedger()
        persistNow()
        playlistCollectionRevision &+= 1
    }

    /// 启动装载里与当前线程并行的一段纯计算。`wait()` 只调一次。
    private final class LaunchBackgroundComputation<Value: Sendable>: @unchecked Sendable {
        private let group = DispatchGroup()
        private var value: Value?

        init(_ work: @escaping @Sendable () -> Value) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.value = work()
                self.group.leave()
            }
        }

        func wait() -> Value {
            group.wait()
            guard let value else { preconditionFailure("background computation finished without a value") }
            return value
        }
    }

    /// A complete, unpublished library. No observable model exists while disk
    /// reads, migrations and whole-library indexes are being prepared.
    struct PreparedStartup: Sendable {
        fileprivate let storage: StartupStorage
    }

    /// G5: 准备阶段只做纯读取与内存迁移。所有耐久写入记录成意图,
    /// 由主线程的发布步骤按与历史版本相同的顺序执行, 于是一次被丢弃的
    /// 准备不会在磁盘上留下任何痕迹。
    fileprivate enum PendingStoreWrite: Sendable {
        case none
        case replaceAll(importID: String?)
        case upserts([Song])
    }

    fileprivate struct StartupStorage: Sendable {
        let directory: URL
        let artistNameConfiguration: ArtistNameConfiguration
        var disabledSourceIDs: Set<String>
        var knownSourceIDs: Set<String>?
        let playlistSyncWriterID: String
        let songStore: IncrementalSongStore?
        var sourceIdentityPrefixes: [String: String] = [:]
        var previousVisibleSongs: [Song] = []
        var spokenWordClassification: SpokenWordClassificationInputs = .empty
        let songStoreSnapshotWriter: @Sendable (IncrementalSongStore, [Song], String?) throws -> Int64
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var allPlaylists: [Playlist] = []
        var allSmartPlaylists: [SmartPlaylist] = []
        var playlistSongIDs: [String: [String]] = [:]
        var playlistSyncBaseSongIDs: [String: [String]] = [:]
        var recentPlaybackSongIDs: [String] = []
        var deletedSongIdentities: Set<String> = []
        var deletedSongIdentityDetails: [String: LibrarySongTombstoneDetail] = [:]
        var pendingPlaylistIdentities: [String: [PendingSongIdentity]] = [:]
        var pendingHistoryIdentities: [PendingSongIdentity] = []
        var playlistPendingEntries: [String: PlaylistPendingEntry] = [:]
        var automaticArtistArtworkCatalogsBySource: [String: SourceArtistArtworkCatalog] = [:]
        var artworkOverridesByOwner: [String: LibraryArtworkOverride] = [:]
        var libraryReviewsBySubject: [String: LibraryReview] = [:]
        var libraryInsightRecordsByID: [String: LibraryInsightRecord] = [:]
        var mirrorPlaylistSuppressions: [String: MirrorPlaylistSuppression] = [:]
        var deviceLocalExcludedSongIdentities: Set<String> = []
        var deviceLocalExcludedSongsByID: [String: Song] = [:]
        var deviceLocalRemovalMetadataByID: [String: SongLocalRemovalMetadata] = [:]
        var songIndexByID: [String: Int] = [:]
        var persistenceBlockedByCorruption = false
        var songStoreRequiresReplacement = false
        var pendingSnapshotImportID: String?
        var derivedIndexSignature: String?
        var visibleCache: PreparedVisibleCache?
        var shouldWriteStartupCache = false
        var shouldWriteDerivedCache = false
        var shouldPersistSnapshot = false
        /// 装载确实产出了一份快照(与历史版本 `guard let snapshot` 之后的路径对应)。
        var didPublishSnapshot = false
        // MARK: 推迟到发布步骤执行的耐久副作用 (G5)
        var corruptSnapshotToArchive: URL?
        var shouldPersistDeviceLocalExclusions = false
        var shouldPersistPlaylistDurabilityLedger = false
        var pendingStoreWrite: PendingStoreWrite = .none
        var migrationVersionToMark: Int?
        var pendingStoreExternalSnapshotImportID: String?

        var snapshotURL: URL { directory.appendingPathComponent("library-cache.json") }
        var backupSnapshotURL: URL { directory.appendingPathComponent("library-cache.backup.json") }
        var startupCacheURL: URL { directory.appendingPathComponent("library-startup-cache.plist") }
        var derivedIndexCacheURL: URL { directory.appendingPathComponent("library-derived-index.plist") }
        var playlistDurabilityURL: URL { directory.appendingPathComponent("playlist-durability.json") }
        var deviceLocalExclusionURL: URL { directory.appendingPathComponent("library-device-local-excluded-songs.json") }
        var encoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }
        var decoder: JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
        var allArtworkOverrides: [LibraryArtworkOverride] {
            artworkOverridesByOwner.values.sorted { $0.id < $1.id }
        }
        var hiddenMirrorPlaylists: [MirrorPlaylistSuppression] {
            mirrorPlaylistSuppressions.values.sorted { $0.hiddenAt > $1.hiddenAt }
        }
        func identityKey(for song: Song) -> String {
            "\(sourceIdentityPrefixes[song.sourceID] ?? song.sourceID):\(song.filePath)"
        }
        func isExcludedOnThisDevice(_ song: Song) -> Bool {
            deviceLocalExcludedSongIdentities.contains(identityKey(for: song))
                || deviceLocalExcludedSongIdentities.contains("\(song.sourceID):\(song.filePath)")
        }
        func songForSynchronization(id: String) -> Song? {
            if let index = songIndexByID[id] { return songs[index] }
            guard let song = deviceLocalExcludedSongsByID[id],
                  !deletedSongIdentities.contains(identityKey(for: song)) else { return nil }
            return song
        }
        mutating func cleanPlaylistEntries() {
            for id in playlistSongIDs.keys {
                playlistSongIDs[id] = playlistSongIDs[id]?.filter {
                    songForSynchronization(id: $0) != nil || playlistPendingEntries[$0] != nil
                }
            }
            playlistPendingEntries = MusicLibrary.referencedPendingEntries(
                playlistPendingEntries,
                memberships: playlistSongIDs
            )
        }
        mutating func cleanPlaybackHistoryEntries() {
            recentPlaybackSongIDs = recentPlaybackSongIDs.filter { songForSynchronization(id: $0) != nil }
        }
        mutating func rebuildVisibleCache() {
            visibleCache = MusicLibrary.prepareVisibleCache(
                songs: songs, albums: albums, artists: artists,
                artistNameConfiguration: artistNameConfiguration,
                disabledSourceIDs: disabledSourceIDs,
                spokenWordClassification: spokenWordClassification,
                previousVisibleSongs: previousVisibleSongs
            )
        }
        /// `inferredAlbumArtists` 是迁移阶段对同一批歌、同样没有目录时算好的推断。
        mutating func rebuildIndexSync(
            precomputedSignature: String,
            inferredAlbumArtists: [String: String]? = nil
        ) {
            // 启动阶段还没有网盘父目录, 见 `migrateLoadedSongs`。
            let result = MusicLibrary.computeAlbumsAndArtists(
                songs: songs,
                configuration: artistNameConfiguration,
                inferredAlbumArtists: inferredAlbumArtists
            )
            albums = result.albums
            artists = result.artists
            derivedIndexSignature = precomputedSignature
            applyAlbumIDCorrections(result.albumIDCorrections)
            rebuildVisibleCache()
        }

        /// 与主 actor 上的同名方法一样: 整库知道兄弟文件, 逐首入库时算出的
        /// albumID 在这里对账。装载阶段没有 store 句柄, 改动折进待写队列。
        /// ID 不变、行序不变, `songIndexByID` 仍然有效。
        mutating func applyAlbumIDCorrections(_ corrections: [String: String]) {
            guard !corrections.isEmpty else { return }
            var changed: [Song] = []
            for (songID, albumID) in corrections {
                guard let index = songIndexByID[songID],
                      songs.indices.contains(index),
                      songs[index].id == songID,
                      songs[index].albumID != albumID else { continue }
                songs[index].albumID = albumID
                changed.append(songs[index])
            }
            guard !changed.isEmpty else { return }
            switch pendingStoreWrite {
            case .none:
                pendingStoreWrite = .upserts(changed)
            case .upserts(var list):
                var indexByID: [String: Int] = [:]
                for (offset, song) in list.enumerated() { indexByID[song.id] = offset }
                for song in changed {
                    if let offset = indexByID[song.id] {
                        list[offset] = song
                    } else {
                        indexByID[song.id] = list.count
                        list.append(song)
                    }
                }
                pendingStoreWrite = .upserts(list)
            case .replaceAll:
                // 整库重写本来就会带上纠正后的行。
                break
            }
        }

        mutating func loadSnapshot(preferExternalSnapshot: Bool = false) {
            let loadStartedAt = ProcessInfo.processInfo.systemUptime
            plog("🚀 library load stage=begin external=\(preferExternalSnapshot)")
            let hasCompatibilitySnapshot = FileManager.default.fileExists(atPath: snapshotURL.path)
            let compatibilityFingerprint = hasCompatibilitySnapshot
                ? MusicLibrary.snapshotFingerprint(at: snapshotURL)
                : nil

            let initialStoreState: IncrementalSongStoreStartupState? = {
                guard !preferExternalSnapshot, let songStore else { return nil }
                do {
                    return try songStore.startupState()
                } catch {
                    plog("⚠️ Incremental song store metadata read failed; recovering from JSON: \(error.localizedDescription)")
                    return nil
                }
            }()
            let portableStartupCache = initialStoreState?.isAuthoritative == true
                ? loadStartupCache(
                    snapshotFingerprint: compatibilityFingerprint
                )
                : nil
            let startupCacheReadFinishedAt = ProcessInfo.processInfo.systemUptime
            // 只有旧格式带歌曲; 修订号对得上才能直接用里面的歌。
            let startupCache = portableStartupCache.flatMap { cache in
                cache.formatVersion == MusicLibrary.legacyStartupCacheFormatVersion
                    && cache.songStoreRevision == initialStoreState?.contentRevision ? cache : nil
            }

            var canonicalSongs: [Song]?
            var resolvedSnapshot: Snapshot?
            var snapshotByteCount = 0
            var externalSnapshotImportID: String?
            var canRefreshStartupCache = false
            var usedPortableStartupCache = false
            var readFinishedAt = ProcessInfo.processInfo.systemUptime
            var decodeFinishedAt = readFinishedAt
            if let startupCache {
                resolvedSnapshot = startupCache.snapshot
                canonicalSongs = startupCache.snapshot.songs
                canRefreshStartupCache = true
                readFinishedAt = ProcessInfo.processInfo.systemUptime
                decodeFinishedAt = readFinishedAt
                persistenceBlockedByCorruption = false
            } else {
                // Ordinary metadata batches commit to SQLite immediately while the
                // portable JSON snapshot is intentionally coalesced. The cached
                // snapshot still exactly mirrors that JSON (playlists, tombstones,
                // etc.), so reuse it and replace only its stale song array from the
                // authoritative store. This avoids decoding a multi-megabyte JSON
                // document on every launch during a long-running backfill.
                if let portableStartupCache,
                   initialStoreState?.isAuthoritative == true,
                   let songStore {
                    do {
                        canonicalSongs = try songStore.loadSongs()
                        resolvedSnapshot = portableStartupCache.snapshot
                        canRefreshStartupCache = true
                        usedPortableStartupCache = true
                        persistenceBlockedByCorruption = false
                        readFinishedAt = ProcessInfo.processInfo.systemUptime
                        decodeFinishedAt = readFinishedAt
                    } catch {
                        plog("⚠️ Incremental song store read failed; recovering from JSON: \(error.localizedDescription)")
                    }
                }

                if resolvedSnapshot == nil,
                   initialStoreState?.isAuthoritative == true,
                   let songStore,
                   canonicalSongs == nil {
                    do {
                        canonicalSongs = try songStore.loadSongs()
                    } catch {
                        plog("⚠️ Incremental song store read failed; recovering from JSON: \(error.localizedDescription)")
                    }
                }

                if resolvedSnapshot != nil {
                    // The portable startup cache path above already supplied the
                    // non-song snapshot and canonical SQLite rows.
                } else if !hasCompatibilitySnapshot {
                    persistenceBlockedByCorruption = false
                    if let canonicalSongs {
                        resolvedSnapshot = Snapshot(
                            songs: canonicalSongs,
                            playlists: [],
                            mirrorPlaylistSuppressions: nil,
                            smartPlaylists: nil,
                            playlistSongIDs: nil,
                            recentPlaybackSongIDs: nil,
                            deletedSongIdentities: nil,
                            pendingPlaylistIdentities: nil,
                            pendingHistoryIdentities: nil
                        )
                        canRefreshStartupCache = true
                    } else {
                        loadPlaylistDurabilityLedger()
                        return
                    }
                    readFinishedAt = ProcessInfo.processInfo.systemUptime
                    decodeFinishedAt = readFinishedAt
                } else {
                    guard let data = try? Data(contentsOf: snapshotURL) else {
                        persistenceBlockedByCorruption = true
                        plog("⛔ Library snapshot exists but cannot be read; persistence disabled to protect it")
                        return
                    }
                    readFinishedAt = ProcessInfo.processInfo.systemUptime
                    snapshotByteCount = data.count
                    if let decoded = try? decoder.decode(Snapshot.self, from: data) {
                        if preferExternalSnapshot { externalSnapshotImportID = MusicLibrary.snapshotImportID(for: data) }
                        resolvedSnapshot = decoded
                        canRefreshStartupCache = true
                        persistenceBlockedByCorruption = false
                    } else {
                        corruptSnapshotToArchive = snapshotURL.deletingLastPathComponent()
                            .appendingPathComponent("library-cache.corrupt-\(Int(Date().timeIntervalSince1970)).json")

                        guard let backupData = try? Data(contentsOf: backupSnapshotURL),
                              let backup = try? decoder.decode(Snapshot.self, from: backupData) else {
                            persistenceBlockedByCorruption = true
                            plog("⛔ Library snapshot is corrupt and no valid backup exists; persistence disabled to prevent an empty overwrite")
                            return
                        }
                        resolvedSnapshot = backup
                        canRefreshStartupCache = false
                        persistenceBlockedByCorruption = false
                        plog("⚠️ Library snapshot was corrupt; restored the last valid backup")
                    }
                    decodeFinishedAt = ProcessInfo.processInfo.systemUptime
                }
            }
            guard let snapshot = resolvedSnapshot else { return }
            if snapshot.separateSongStore == true, canonicalSongs == nil {
                // 这份快照的歌只在增量库里, 而增量库这次没读出来。不能拿快照里
                // 那份空歌单发布: 发布会登记整库替换把增量库写空, 歌单与播放历史
                // 也会按空曲库清理后写进启动缓存。与快照损坏且无备份一样, 这次
                // 不发布、不持久化, 下次启动再读一次增量库。
                persistenceBlockedByCorruption = true
                plog("⛔ Library snapshot keeps its songs in the incremental store, which could not be read; persistence disabled to protect it")
                return
            }
            didPublishSnapshot = true
            MusicLibrary.restorePortableArtworkAssets(snapshot, assetStore: .shared)

            // Migrate the decoded value before publishing it. `songs` is backed by
            // an immutable observable reference, so mutating `songs[i]` would run
            // its setter once per item. With a 10K+ library that copied and
            // published the complete array thousands of times during cold launch.
            // Keeping the work local gives the array one copy-on-write mutation
            // and the observable model one final publication.
            var loadedSongs = canonicalSongs ?? snapshot.songs
            // Device-local exclusions never travel inside the snapshot, so a
            // snapshot imported from another device (LibrarySnapshotSync writes
            // `library-cache.json` wholesale, then the library reloads from disk)
            // still carries the rows this device removed locally. Re-apply the
            // exclusion here — before the SQLite mirror is rewritten below — so
            // the removal survives snapshot sync instead of bouncing back.
            if !deviceLocalExcludedSongIdentities.isEmpty {
                let tombstones = Set(snapshot.deletedSongIdentities ?? [])
                for song in loadedSongs where isExcludedOnThisDevice(song)
                    && !tombstones.contains(identityKey(for: song)) {
                    deviceLocalExcludedSongsByID[song.id] = song
                }
                deviceLocalExcludedSongsByID = deviceLocalExcludedSongsByID.filter {
                    !tombstones.contains(identityKey(for: $0.value))
                }
                deviceLocalRemovalMetadataByID = deviceLocalRemovalMetadataByID.filter {
                    deviceLocalExcludedSongsByID[$0.key] != nil
                }
                shouldPersistDeviceLocalExclusions = true
                let beforeCount = loadedSongs.count
                loadedSongs.removeAll { isExcludedOnThisDevice($0) }
                let skipped = beforeCount - loadedSongs.count
                if skipped > 0 {
                    plog("ℹ️ Library load skipped \(skipped) song(s) excluded on this device")
                }
            }
            let shouldInspectLoadedSongs = preferExternalSnapshot
                || canonicalSongs == nil
                || (initialStoreState?.completedMigrationVersion ?? 0) < MusicLibrary.loadedSongMigrationVersion
            // 分阶段落点: 冷启动卡在「加载中」时, 看最后一行停在哪一段。
            plog("🚀 library load stage=decoded songs=\(loadedSongs.count) inspect=\(shouldInspectLoadedSongs)"
                 + " external=\(preferExternalSnapshot) canonical=\(canonicalSongs != nil)"
                 + " ms=\(Int((ProcessInfo.processInfo.systemUptime - loadStartedAt) * 1_000))")
            let migration = shouldInspectLoadedSongs
                ? MusicLibrary.migrateLoadedSongs(
                    &loadedSongs,
                    configuration: artistNameConfiguration
                )
                : (
                    repairedTextCount: 0,
                    filledDerivedIDCount: 0,
                    repairedDTSDurationCount: 0,
                    changedSongs: [],
                    inferredAlbumArtists: nil
                )
            let migrationFinishedAt = ProcessInfo.processInfo.systemUptime
            plog("🚀 library load stage=migrated changed=\(migration.changedSongs.count)"
                 + " ms=\(Int((migrationFinishedAt - loadStartedAt) * 1_000))")
            if shouldInspectLoadedSongs, songStore != nil {
                // G5: 记录意图, 发布步骤按历史顺序执行(先写库, 再标记迁移版本),
                // 失败时的 `songStoreRequiresReplacement` / `pendingSnapshotImportID`
                // 处理与历史版本完全一致。
                if preferExternalSnapshot || canonicalSongs == nil {
                    pendingStoreWrite = .replaceAll(importID: externalSnapshotImportID)
                } else if !migration.changedSongs.isEmpty {
                    pendingStoreWrite = .upserts(migration.changedSongs)
                }
                pendingStoreExternalSnapshotImportID = externalSnapshotImportID
                migrationVersionToMark = MusicLibrary.loadedSongMigrationVersion
            }
            songs = loadedSongs
            songIndexByID = MusicLibrary.makeSongIndex(loadedSongs)
            allPlaylists = snapshot.playlists
            automaticArtistArtworkCatalogsBySource = Dictionary(
                uniqueKeysWithValues: (snapshot.automaticArtistArtworkCatalogs ?? []).map {
                    ($0.sourceID, $0)
                }
            )
            artworkOverridesByOwner = Dictionary(
                (snapshot.artworkOverrides ?? []).map { ($0.owner.storageKey, $0) },
                uniquingKeysWith: { local, remote in
                    LibraryArtworkOverrideReconciliationPolicy.winner(
                        local: local,
                        remote: remote
                    ) == .local ? local : remote
                }
            )
            libraryReviewsBySubject = Dictionary(
                (snapshot.libraryReviews ?? []).map { ($0.subject.storageKey, $0) },
                uniquingKeysWith: { local, remote in
                    LibraryReviewReconciliationPolicy.winner(local: local, remote: remote)
                }
            )
            libraryInsightRecordsByID = Dictionary(
                (snapshot.libraryInsights ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { LibraryInsightEditing.winner($0, $1) }
            )
            mirrorPlaylistSuppressions = Dictionary(
                uniqueKeysWithValues: (snapshot.mirrorPlaylistSuppressions ?? []).map { ($0.id, $0) }
            )
            loadPlaylistDurabilityLedger()
            allSmartPlaylists = snapshot.smartPlaylists ?? []
            playlistSongIDs = snapshot.playlistSongIDs ?? [:]
            playlistSyncBaseSongIDs = snapshot.playlistSyncBaseSongIDs ?? [:]
            recentPlaybackSongIDs = snapshot.recentPlaybackSongIDs ?? []
            // Old `deletedSongIDs` field stored mount-UUID-derived song.id
            // tombstones — useless after re-OAuth changes the source UUID.
            // Drop them silently; new identity-based tombstones replace.
            // 装载时对账一次: 证据表说已撤销的键不再进集合, 过了保留期的撤销
            // 记录和孤儿记录一并清掉。一次启动只跑一遍。
            let tombstoneLedger = MusicLibrary.reconciledTombstoneLedger(
                identities: Set(snapshot.deletedSongIdentities ?? []),
                details: snapshot.deletedSongIdentityDetails ?? [:]
            )
            deletedSongIdentities = tombstoneLedger.identities
            deletedSongIdentityDetails = tombstoneLedger.details
            pendingPlaylistIdentities = snapshot.pendingPlaylistIdentities ?? [:]
            pendingHistoryIdentities = snapshot.pendingHistoryIdentities ?? []
            playlistPendingEntries = snapshot.playlistPendingEntries ?? [:]
            cleanPlaylistEntries()
            cleanPlaybackHistoryEntries()
            // Songs may already include matches for pending entries from a
            // previous launch (e.g. user added the right cloud source between
            // sessions). Try resolving them once on load.

            if let knownSourceIDs {
                disabledSourceIDs.formUnion(Set(songs.map(\.sourceID)).subtracting(knownSourceIDs))
            }
            let cleanupFinishedAt = ProcessInfo.processInfo.systemUptime
            let usedDerivedIndexCache: Bool
            let usedCurrentStartupCache = usedPortableStartupCache
                && portableStartupCache?.formatVersion == MusicLibrary.startupCacheFormatVersion
            let derivedStartupCache = startupCache ?? (usedCurrentStartupCache ? portableStartupCache : nil)
            // 签名只用来确认启动缓存里的专辑/艺术家还能用, 而命中是常态: 签名放到
            // 另一个核上算, 这边同时按命中建可见缓存; 对不上时下面照原路重建。
            let signatureSongs = loadedSongs
            let signatureConfiguration = artistNameConfiguration
            let signatureComputation = LaunchBackgroundComputation {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let signature = MusicLibrary.derivedIndexSignature(
                    for: signatureSongs,
                    configuration: signatureConfiguration
                )
                return (signature, ProcessInfo.processInfo.systemUptime - startedAt)
            }
            let speculativeStartupCache = migration.changedSongs.isEmpty ? derivedStartupCache : nil
            if let speculativeStartupCache {
                albums = speculativeStartupCache.albums
                artists = speculativeStartupCache.artists
                rebuildVisibleCache()
            }
            let (currentDerivedSignature, signatureSeconds) = signatureComputation.wait()
            let speculationOutcome: String
            if let speculativeStartupCache {
                speculationOutcome = speculativeStartupCache.derivedIndexSignature == currentDerivedSignature
                    ? "used" : "discarded"
            } else {
                speculationOutcome = "none"
            }
            if let speculativeStartupCache,
               speculativeStartupCache.derivedIndexSignature == currentDerivedSignature {
                derivedIndexSignature = currentDerivedSignature
                usedDerivedIndexCache = true
            } else {
                if let cachedIndex = loadDerivedIndexCache(matching: currentDerivedSignature) {
                    albums = cachedIndex.albums
                    artists = cachedIndex.artists
                    derivedIndexSignature = currentDerivedSignature
                    rebuildVisibleCache()
                    usedDerivedIndexCache = true
                } else {
                    // The cache is disposable. An old installation pays the grouping
                    // cost once, then subsequent launches decode the compact binary
                    // index instead of sorting the whole library before the first frame.
                    rebuildIndexSync(
                        precomputedSignature: currentDerivedSignature,
                        inferredAlbumArtists: migration.inferredAlbumArtists
                    )
                    shouldWriteDerivedCache = true
                    usedDerivedIndexCache = false
                }
            }
            let indexFinishedAt = ProcessInfo.processInfo.systemUptime
            plog("🚀 library load stage=indexed ms=\(Int((indexFinishedAt - loadStartedAt) * 1_000))")

            // `songStoreRequiresReplacement` 只有在发布步骤执行完推迟的存储写入后
            // 才是最终值, 所以那一项条件留到发布步骤再判断。
            if !usedCurrentStartupCache, canRefreshStartupCache {
                shouldWriteStartupCache = true
            }
            // 启动缓存命中后不会再重写, 里面的专辑/艺术家一旦过期(索引重建发生在
            // 快照落盘之后), 以后每次启动都要白建一遍可见缓存再读另一份派生索引。
            // 这次已经拿到了对得上的索引, 顺手刷新, 下次就直接命中。
            if speculationOutcome == "discarded", usedDerivedIndexCache, usedCurrentStartupCache {
                shouldWriteStartupCache = true
            }
            plog(String(
                format: "🚀 library load total=%.0fms read=%.0f (cache=%.0f) decode=%.0f migrate=%.0f cleanup=%.0f derived=%.0f (signature=%.0f) startupCache=%@ derivedCache=%@ bytes=%d songs=%d speculativeIndex=%@",
                (indexFinishedAt - loadStartedAt) * 1_000,
                (readFinishedAt - loadStartedAt) * 1_000,
                (startupCacheReadFinishedAt - loadStartedAt) * 1_000,
                (decodeFinishedAt - readFinishedAt) * 1_000,
                (migrationFinishedAt - decodeFinishedAt) * 1_000,
                (cleanupFinishedAt - migrationFinishedAt) * 1_000,
                (indexFinishedAt - cleanupFinishedAt) * 1_000,
                signatureSeconds * 1_000,
                usedCurrentStartupCache ? "hit"
                    : (startupCache != nil ? "legacy" : (usedPortableStartupCache ? "partial" : "miss")),
                usedDerivedIndexCache ? "hit" : "miss",
                snapshotByteCount,
                loadedSongs.count,
                speculationOutcome
            ))
            if migration.repairedTextCount > 0 {
                plog("📚 repaired legacy Chinese metadata text for \(migration.repairedTextCount) song(s)")
            }
            if migration.repairedDTSDurationCount > 0 {
                plog("📚 repaired missing or legacy DTS duration for \(migration.repairedDTSDurationCount) song(s)")
            }
            if migration.repairedTextCount > 0
                || migration.filledDerivedIDCount > 0
                || migration.repairedDTSDurationCount > 0 {
                shouldPersistSnapshot = true
            }
        }

        mutating func loadPlaylistDurabilityLedger() {
            if let data = try? Data(contentsOf: playlistDurabilityURL),
               let ledger = try? decoder.decode(PlaylistDurabilityLedger.self, from: data) {
                for durable in ledger.playlists {
                    if let index = allPlaylists.firstIndex(where: { $0.id == durable.id }) {
                        if PlaylistReconciliationPolicy.winner(
                            local: allPlaylists[index],
                            remote: durable
                        ) == .remote {
                            allPlaylists[index] = durable
                        }
                    } else {
                        allPlaylists.append(durable)
                    }
                }
                for suppression in ledger.mirrorPlaylistSuppressions {
                    mirrorPlaylistSuppressions[suppression.id] = suppression
                }
                for durable in ledger.artworkOverrides ?? [] {
                    if let current = artworkOverridesByOwner[durable.owner.storageKey],
                       LibraryArtworkOverrideReconciliationPolicy.winner(
                        local: current,
                        remote: durable
                       ) == .local {
                        continue
                    }
                    artworkOverridesByOwner[durable.owner.storageKey] = durable
                }
            }

            var migratedDurabilityState = false
            for index in allPlaylists.indices
            where allPlaylists[index].isDeleted
                && MirrorPlaylistIdentity.isMirrorPlaylist(allPlaylists[index].id) {
                let playlist = allPlaylists[index]
                if let key = MirrorPlaylistSuppressionPolicy.key(forPlaylistID: playlist.id) {
                    let suppression = MirrorPlaylistSuppression(
                        key: key,
                        playlistID: playlist.id,
                        displayName: playlist.name,
                        hiddenAt: playlist.deletedAt ?? playlist.updatedAt
                    )
                    mirrorPlaylistSuppressions[suppression.id] = suppression
                }
                allPlaylists[index].isDeleted = false
                allPlaylists[index].deletedAt = nil
                migratedDurabilityState = true
            }
            for index in allPlaylists.indices
            where allPlaylists[index].isDeleted
                && !MirrorPlaylistIdentity.isMirrorPlaylist(allPlaylists[index].id)
                && allPlaylists[index].deleteOperationID == nil {
                allPlaylists[index].syncRevision = max(1, allPlaylists[index].syncRevision)
                allPlaylists[index].syncWriterID = playlistSyncWriterID
                allPlaylists[index].syncOperationID = UUID().uuidString
                allPlaylists[index].deleteOperationID = UUID().uuidString
                migratedDurabilityState = true
            }
            if migratedDurabilityState {
                shouldPersistPlaylistDurabilityLedger = true
            }
        }

        private func loadStartupCache(
            snapshotFingerprint: SnapshotFileFingerprint?
        ) -> StartupCache? {
            guard let data = try? Data(contentsOf: startupCacheURL),
                  let cache = try? PropertyListDecoder().decode(StartupCache.self, from: data),
                  cache.formatVersion == MusicLibrary.startupCacheFormatVersion
                    || cache.formatVersion == MusicLibrary.legacyStartupCacheFormatVersion,
                  cache.snapshotFingerprint == snapshotFingerprint else {
                return nil
            }
            return cache
        }

        private func loadDerivedIndexCache(matching signature: String) -> DerivedIndexCache? {
            guard let data = try? Data(contentsOf: derivedIndexCacheURL),
                  let cache = try? PropertyListDecoder().decode(DerivedIndexCache.self, from: data),
                  cache.signature == signature else {
                return nil
            }
            return cache
        }

        mutating func loadDeviceLocalExclusions() {
            guard let data = try? Data(contentsOf: deviceLocalExclusionURL) else { return }
            guard let ledger = try? JSONDecoder().decode(DeviceLocalExclusionLedger.self, from: data) else {
                plog("Device-local song exclusions unreadable; keeping the file untouched")
                return
            }
            deviceLocalExcludedSongIdentities = Set(ledger.identities)
            let resolved = ledger.resolved()
            deviceLocalExcludedSongsByID = resolved.songs
            deviceLocalRemovalMetadataByID = resolved.metadata
        }

        // G5: 这里刻意不提供任何写盘方法。准备阶段只登记意图,
        // 由主线程的发布步骤调用 MusicLibrary 上同名的持久化实现。
    }

    private func storageForReload(sourceIdentityPrefixes: [String: String]? = nil) -> StartupStorage {
        var storage = StartupStorage(
            directory: snapshotURL.deletingLastPathComponent(),
            artistNameConfiguration: artistNameConfiguration,
            disabledSourceIDs: disabledSourceIDs,
            playlistSyncWriterID: playlistSyncWriterID,
            songStore: songStore,
            songStoreSnapshotWriter: songStoreSnapshotWriter
        )
        storage.songs = songs
        storage.albums = albums
        storage.artists = artists
        storage.allPlaylists = allPlaylists
        storage.allSmartPlaylists = allSmartPlaylists
        storage.playlistSongIDs = playlistSongIDs
        storage.playlistSyncBaseSongIDs = playlistSyncBaseSongIDs
        storage.recentPlaybackSongIDs = recentPlaybackSongIDs
        storage.deletedSongIdentities = deletedSongIdentities
        storage.deletedSongIdentityDetails = deletedSongIdentityDetails
        storage.pendingPlaylistIdentities = pendingPlaylistIdentities
        storage.pendingHistoryIdentities = pendingHistoryIdentities
        storage.playlistPendingEntries = playlistPendingEntries
        storage.automaticArtistArtworkCatalogsBySource = automaticArtistArtworkCatalogsBySource
        storage.artworkOverridesByOwner = artworkOverridesByOwner
        storage.libraryReviewsBySubject = libraryReviewsBySubject
        storage.libraryInsightRecordsByID = libraryInsightRecordsByID
        storage.mirrorPlaylistSuppressions = mirrorPlaylistSuppressions
        storage.deviceLocalExcludedSongIdentities = deviceLocalExcludedSongIdentities
        storage.deviceLocalExcludedSongsByID = deviceLocalExcludedSongsByID
        storage.deviceLocalRemovalMetadataByID = deviceLocalRemovalMetadataByID
        storage.persistenceBlockedByCorruption = persistenceBlockedByCorruption
        storage.songStoreRequiresReplacement = songStoreRequiresReplacement
        storage.pendingSnapshotImportID = pendingSnapshotImportID
        storage.derivedIndexSignature = derivedIndexSignature
        storage.songIndexByID = songIndexByID
        storage.previousVisibleSongs = visibleSongs
        storage.spokenWordClassification = SpokenWordStore.shared.classificationSnapshot
        // G3: 调用方(AppServices)在库构造前就能从 SourcesStore 算出身份前缀;
        // 没有传入时沿用旧行为, 回落到构造后才安装的 resolver。
        if let sourceIdentityPrefixes {
            storage.sourceIdentityPrefixes = sourceIdentityPrefixes
        } else {
            let sourceIDs = Set(songCountBySourceID.keys)
                .union(deviceLocalExcludedSongsByID.values.map(\.sourceID))
            for sourceID in sourceIDs {
                storage.sourceIdentityPrefixes[sourceID] = sourceIdentityResolver?(sourceID)
            }
        }
        return storage
    }

    /// Queue mutations while preparing a replacement, so edits arriving during
    /// the disk read are replayed against the published library.
    func reloadFromDiskInBackground(preferExternalSnapshot: Bool = true) async {
        await whenReady()
        await waitForPendingIndex()
        let baseline = storageForReload()
        readiness = .preparing
        let prepared = await Task.detached(priority: .userInitiated) {
            var storage = baseline
            storage.loadSnapshot(preferExternalSnapshot: preferExternalSnapshot)
            return PreparedStartup(storage: storage)
        }.value
        publish(prepared)
    }

    private func loadSnapshot(
        preferExternalSnapshot: Bool = false,
        preparedStartup: PreparedStartup? = nil,
        sourceIdentityPrefixes: [String: String]? = nil
    ) {
        // 发布在主线程上分段计时: 冷启动那一下主线程阻塞落在哪一步, 看这一行。
        let publishStartedAt = ProcessInfo.processInfo.systemUptime
        var publishMarks: [(String, Double)] = []
        func markPublish(_ step: String) {
            publishMarks.append((step, ProcessInfo.processInfo.systemUptime))
        }
        var storage: StartupStorage
        if let preparedStartup {
            storage = preparedStartup.storage
            // G2: 准备结果的禁用源集合是可见缓存的计算依据, 以它为准。
            disabledSourceIDs = storage.disabledSourceIDs
            // 同理, 拷回的 songs.artistID / albums / artists / 派生索引签名全都
            // 是用准备阶段那份命名配置算出来的; 配置不一起换过来的话,
            // songs(forArtist:) 与 visibleArtists 会按另一份配置分组, 直到下一次
            // 全量重建才纠正。`.preparing` 期间进来的新配置由第 2.5 步对账。
            artistNameConfiguration = storage.artistNameConfiguration
            invalidateArtistDisplayNameCache()
            // `.preparing` 构造的库此时才拿到准备阶段打开的存储句柄。
            songStore = storage.songStore
        } else {
            storage = storageForReload(sourceIdentityPrefixes: sourceIdentityPrefixes)
            storage.loadSnapshot(preferExternalSnapshot: preferExternalSnapshot)
        }
        // C2: 历史版本的三条提前返回路径(快照不可读 / 损坏且无有效备份 /
        // 既没有兼容快照也没有存储行)只写 `persistenceBlockedByCorruption`,
        // 其中"无快照"那条还会把歌单耐久账本并进 `allPlaylists` /
        // `mirrorPlaylistSuppressions` / `artworkOverridesByOwner`。它们不会
        // 重新赋值 `songs`, 因此不会推进 `songMutationGeneration`、不会发布
        // 新的数组引用、也不会回收旧引用。拷回必须保持同样的最小集合。
        persistenceBlockedByCorruption = storage.persistenceBlockedByCorruption
        allPlaylists = storage.allPlaylists
        mirrorPlaylistSuppressions = storage.mirrorPlaylistSuppressions
        artworkOverridesByOwner = storage.artworkOverridesByOwner
        // 设备本地排除对应历史版本 init 里 `loadSnapshot` 之前的
        // `loadDeviceLocalExclusions()`, 提前返回时它同样已经载入过,
        // 所以这一对不受 `didPublishSnapshot` 约束。同步路径下这只是把
        // 原值写回。
        deviceLocalExcludedSongIdentities = storage.deviceLocalExcludedSongIdentities
        deviceLocalExcludedSongsByID = storage.deviceLocalExcludedSongsByID
        deviceLocalRemovalMetadataByID = storage.deviceLocalRemovalMetadataByID
        if storage.didPublishSnapshot {
            songs = storage.songs
            // G1: 历史版本每次 `songs =` 之后都显式重建索引, 拷回时同样必须带上。
            songIndexByID = storage.songIndexByID
            albums = storage.albums
            artists = storage.artists
            allSmartPlaylists = storage.allSmartPlaylists
            playlistSongIDs = storage.playlistSongIDs
            playlistSyncBaseSongIDs = storage.playlistSyncBaseSongIDs
            recentPlaybackSongIDs = storage.recentPlaybackSongIDs
            deletedSongIdentities = storage.deletedSongIdentities
            deletedSongIdentityDetails = storage.deletedSongIdentityDetails
            pendingPlaylistIdentities = storage.pendingPlaylistIdentities
            pendingHistoryIdentities = storage.pendingHistoryIdentities
            playlistPendingEntries = storage.playlistPendingEntries
            automaticArtistArtworkCatalogsBySource = storage.automaticArtistArtworkCatalogsBySource
            let liveReviews = libraryReviewsBySubject
            libraryReviewsBySubject = storage.libraryReviewsBySubject
            if isExternalSnapshotWriteOwned {
                // Edits made while an external snapshot was prepared still
                // belong to this device and must survive its eventual reload.
                for (key, review) in liveReviews {
                    libraryReviewsBySubject[key] = libraryReviewsBySubject[key].map {
                        LibraryReviewReconciliationPolicy.winner(local: review, remote: $0)
                    } ?? review
                }
                if libraryReviewsBySubject != storage.libraryReviewsBySubject {
                    deferredPersistRequested = true
                }
            }
            let liveInsights = libraryInsightRecordsByID
            libraryInsightRecordsByID = storage.libraryInsightRecordsByID
            if isExternalSnapshotWriteOwned {
                // 同上:外部快照准备期间本机写的简介要留下来。
                for (id, record) in liveInsights {
                    libraryInsightRecordsByID[id] = libraryInsightRecordsByID[id].map {
                        LibraryInsightEditing.winner(record, $0)
                    } ?? record
                }
                if libraryInsightRecordsByID != storage.libraryInsightRecordsByID {
                    deferredPersistRequested = true
                }
            }
            songStoreRequiresReplacement = storage.songStoreRequiresReplacement
            pendingSnapshotImportID = storage.pendingSnapshotImportID
            derivedIndexSignature = storage.derivedIndexSignature
            if let visibleCache = storage.visibleCache {
                applyPreparedVisibleCache(visibleCache)
            }
            playlistCollectionRevision &+= 1
            artworkOverrideRevision &+= 1
            libraryReviewRevision &+= 1
            libraryInsightRevision &+= 1
        }

        markPublish("apply")
        // 发布步骤 (1): 可观察模型到此为止已经完整, 翻转就绪状态。
        // 之后的耐久写入与历史版本一样在 `loadSnapshot` 内部直接执行。
        markReadyBeforeDurableWrites()
        markPublish("ready")

        // 发布步骤 (2) — G5: 准备阶段登记的耐久副作用, 按历史版本的顺序补做。
        if let corruptSnapshotToArchive = storage.corruptSnapshotToArchive {
            try? FileManager.default.copyItem(at: snapshotURL, to: corruptSnapshotToArchive)
        }
        if storage.shouldPersistDeviceLocalExclusions {
            try? persistDeviceLocalExclusions()
        }
        if let migrationVersionToMark = storage.migrationVersionToMark, let songStore {
            do {
                switch storage.pendingStoreWrite {
                case .none:
                    break
                case .replaceAll(let importID):
                    _ = try songStoreSnapshotWriter(songStore, storage.songs, importID)
                    songStoreRequiresReplacement = false
                    pendingSnapshotImportID = nil
                case .upserts(let changedSongs):
                    try songStore.apply(upserts: changedSongs)
                }
                try songStore.markMigrationCompleted(version: migrationVersionToMark)
            } catch {
                songStoreRequiresReplacement = true
                pendingSnapshotImportID = storage.pendingStoreExternalSnapshotImportID
                plog("⚠️ Incremental song store migration failed; JSON remains authoritative: \(error.localizedDescription)")
            }
        }
        if storage.shouldPersistPlaylistDurabilityLedger {
            _ = persistPlaylistDurabilityLedger()
        }
        if storage.didPublishSnapshot {
            // Songs may already include matches for pending entries from a
            // previous launch (e.g. user added the right cloud source between
            // sessions). Try resolving them once on load.
            schedulePendingIdentityFlush()
        }
        markPublish("durable")
        if storage.shouldWriteDerivedCache { persistDerivedIndexCache() }
        if storage.shouldWriteStartupCache, !songStoreRequiresReplacement {
            scheduleStartupCacheWrite(
                snapshot: makeSnapshot(includingSongs: false),
                songStoreRevision: try? songStore?.startupState().contentRevision,
                snapshotFingerprint: Self.snapshotFingerprint(at: snapshotURL)
            )
        }
        if storage.shouldPersistSnapshot {
            markPortableSnapshotDirty()
            persistNow()
        }

        markPublish("caches")
        // 发布步骤 (2.5): 配置对账 —— 准备期间记录的禁用源 / 命名配置在这里
        // 按普通 setter 重放差异, 必须早于排队突变的重放。
        reconcilePreparingConfiguration()
        markPublish("reconcile")

        // 发布步骤 (3) 重放排队突变 → (4) 补齐被推迟的持久化 →
        // (5) `onReady` 回调 → (6) 唤醒 `whenReady()`。
        replayDeferredMutations()
        flushDeferredPersistenceAfterReadiness()
        markPublish("replay")
        notifyReadinessObservers()
        markPublish("observers")
        if preparedStartup != nil {
            var previous = publishStartedAt
            let steps = publishMarks.map { step, at in
                defer { previous = at }
                return "\(step)=\(Int((at - previous) * 1_000))"
            }
            plog("🚀 library publish total=\(Int((ProcessInfo.processInfo.systemUptime - publishStartedAt) * 1_000))ms "
                 + steps.joined(separator: " "))
        }
    }

    /// 在主线程之外完成一次完整的库装载, 结果是不可变的 `PreparedStartup`。
    /// 只做纯读取与内存迁移: 任何耐久写入都推迟到主线程的发布步骤(G5)。
    ///
    /// Stage 2b: 必须是 `nonisolated` 的。留在 `@MainActor` 上时, 调用方
    /// (`AppServices.init`) 建的准备任务要等主线程空出来才能跑到下面那句
    /// `Task.detached` —— 也就是要等整个服务图谱构造完, 装载与构造根本没有
    /// 重叠。前导部分只读 UserDefaults 与 FileManager, 两者都是线程安全的。
    nonisolated static func prepareStartup(
        preferExternalSnapshot: Bool = false,
        disabledSourceIDs: Set<String> = [],
        knownSourceIDs: Set<String>? = nil,
        storageDirectory: URL? = nil,
        artistNameConfiguration: ArtistNameConfiguration? = nil,
        /// G3: sourceID → cloudAccountID。resolver 直到库构造之后才安装,
        /// 因此账号型源的身份键必须由调用方在准备阶段直接提供。
        sourceIdentityPrefixes: [String: String] = [:],
        spokenWordClassification: SpokenWordClassificationInputs = .empty
    ) async -> PreparedStartup {
        let configuration = (artistNameConfiguration ?? ArtistNameConfiguration.load(from: .standard)).normalized()
        let writerID = startupPlaylistWriterID()
        let directory = storageDirectory ?? defaultStorageDirectory()
        return await Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let songStore: IncrementalSongStore?
            do {
                songStore = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path)
            } catch {
                songStore = nil
                plog("⚠️ Incremental song store unavailable; using JSON fallback: \(error.localizedDescription)")
            }
            var storage = StartupStorage(
                directory: directory,
                artistNameConfiguration: configuration,
                disabledSourceIDs: disabledSourceIDs,
                playlistSyncWriterID: writerID,
                songStore: songStore,
                songStoreSnapshotWriter: { try $0.replaceAll(with: $1, snapshotImportID: $2) }
            )
            storage.sourceIdentityPrefixes = sourceIdentityPrefixes
            storage.spokenWordClassification = spokenWordClassification
            storage.knownSourceIDs = knownSourceIDs
            storage.loadDeviceLocalExclusions()
            storage.loadSnapshot(preferExternalSnapshot: preferExternalSnapshot)
            return PreparedStartup(storage: storage)
        }.value
    }

    private nonisolated static func defaultStorageDirectory(fileManager: FileManager = .default) -> URL {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return base.appendingPathComponent("Primuse", isDirectory: true)
    }

    /// Stage 2b: 准备任务与主线程上的 `makePreparing` 现在是真并发了, 而首次
    /// 启动时两边都会看到"键还不存在"并各自铸一个 UUID —— 写赢的那个与库内存
    /// 里用的那个可能不是同一个, 于是同一台设备的歌单会带上两个 writer ID,
    /// LWW 会把它们当成两台设备的改动。UserDefaults 本身线程安全, 但这里是
    /// 一个读-铸-写序列, 用进程内的锁把它合成一步。
    private nonisolated static let startupPlaylistWriterIDLock = NSLock()

    private nonisolated static func startupPlaylistWriterID() -> String {
        let key = "primuse.playlist.syncWriterID"
        startupPlaylistWriterIDLock.lock()
        defer { startupPlaylistWriterIDLock.unlock() }
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }


    private nonisolated static func migrateLoadedSongs(
        _ songs: inout [Song],
        configuration: ArtistNameConfiguration
    ) -> (
        repairedTextCount: Int,
        filledDerivedIDCount: Int,
        repairedDTSDurationCount: Int,
        changedSongs: [Song],
        inferredAlbumArtists: [String: String]?
    ) {
        var repairedTextCount = 0
        var filledDerivedIDCount = 0
        var repairedDTSDurationCount = 0
        var changedSongs: [Song] = []
        var repairedSongIDs = Set<String>()
        for index in songs.indices {
            if repairLegacyChineseMetadataText(in: &songs[index]) {
                repairedSongIDs.insert(songs[index].id)
            }
        }
        // 同一目录同名专辑的 album artist 归属只有整库口径才算得出来,
        // 装载时算一次, 逐首复用。网盘的父目录在扫描同步索引里, 装载时还
        // 拿不到; 发布后 `updateAlbumArtistFolders` 会按目录再整库重建一次。
        let inferred = inferredAlbumArtists(for: songs, folders: .empty)
        let memo = DerivedIDMemo()

        for index in songs.indices {
            var song = songs[index]
            let repairedText = repairedSongIDs.contains(song.id)
            let repairedDTSDuration = Self.repairedDTSDuration(for: song)
            var songWithExpectedDerivedIDs = song
            // 第一遍文本修复对这首没有改动 = 修复对它是恒等的，这里不必再跑。
            fillDerivedIDs(
                &songWithExpectedDerivedIDs,
                configuration: configuration,
                inferredAlbumArtist: inferred[song.id],
                memo: memo,
                textRepairIsNoOp: !repairedText
            )
            let needsDerivedIDs = song.artistID != songWithExpectedDerivedIDs.artistID
                || song.albumID != songWithExpectedDerivedIDs.albumID

            if let repairedDTSDuration {
                song.duration = repairedDTSDuration.duration
                if let inferredCueEndTime = repairedDTSDuration.inferredCueEndTime {
                    song.cueEndTime = inferredCueEndTime
                }
            }
            if needsDerivedIDs {
                song.artistID = songWithExpectedDerivedIDs.artistID
                song.albumID = songWithExpectedDerivedIDs.albumID
            }
            if repairedText || needsDerivedIDs || repairedDTSDuration != nil {
                songs[index] = song
                changedSongs.append(song)
            }
            if repairedText { repairedTextCount += 1 }
            if needsDerivedIDs { filledDerivedIDCount += 1 }
            if repairedDTSDuration != nil { repairedDTSDurationCount += 1 }
        }

        // 之后只改了 artistID / albumID / 时长，推断用到的字段（源、路径、专辑名、
        // 专辑艺人、艺人）没变：同一份结果交给装载时的派生重建，不再整库算第二遍。
        return (
            repairedTextCount,
            filledDerivedIDCount,
            repairedDTSDurationCount,
            changedSongs,
            inferred
        )
    }

    private nonisolated static func repairedDTSDuration(
        for song: Song
    ) -> (duration: TimeInterval, inferredCueEndTime: TimeInterval?)? {
        guard song.fileFormat == .dts,
              !song.duration.isFinite || song.duration <= 0 else {
            return AudioDurationPolicy.repairedStoredDTSDuration(
                stored: song.duration,
                fileSize: song.fileSize,
                bitRateKbps: song.bitRate,
                fileExtension: (song.filePath as NSString).pathExtension,
                format: song.fileFormat
            ).map { ($0, nil) }
        }

        if song.isCueTrack, let start = song.cueStartTime {
            if let end = song.cueEndTime, end.isFinite, end > start {
                return (end - start, nil)
            }
            if let containerDuration = AudioDurationPolicy.provisionalStandaloneDTSDuration(
                fileSize: song.fileSize,
                bitRateKbps: song.bitRate,
                fileExtension: (song.filePath as NSString).pathExtension
            ), containerDuration > start {
                return (containerDuration - start, containerDuration)
            }
            return nil
        }

        return AudioDurationPolicy.repairedStoredDTSDuration(
            stored: song.duration,
            fileSize: song.fileSize,
            bitRateKbps: song.bitRate,
            fileExtension: (song.filePath as NSString).pathExtension,
            format: song.fileFormat
        ).map { ($0, nil) }
    }

    nonisolated static func repairLegacyChineseMetadataText(in song: inout Song) -> Bool {
        guard song.userMetadataEditedAt == nil else { return false }
        let originalTitle = song.title
        let originalArtist = song.artistName
        let originalAlbum = song.albumTitle
        var changed = MediaMetadataTextRepair.repairFileBackedMetadata(in: &song)
        changed = repairLegacyChineseText(&song.title) || changed
        changed = repairLegacyChineseText(&song.artistName) || changed
        if var sourceArtistNames = song.sourceArtistNames {
            for index in sourceArtistNames.indices {
                changed = repairLegacyChineseText(&sourceArtistNames[index]) || changed
            }
            song.sourceArtistNames = sourceArtistNames
        }
        if var albumArtistName = song.albumArtistName,
           repairLegacyChineseText(&albumArtistName) {
            song.albumArtistName = albumArtistName
            changed = true
        }
        changed = repairLegacyChineseText(&song.albumTitle) || changed
        song.albumTitle = MediaMetadataTextRepair.repairedAlbumTitle(
            song.albumTitle, artist: song.artistName, albumArtist: song.albumArtistName
        )
        if song.albumTitle != originalAlbum {
            song.albumPinyin = nil
            changed = true
        }
        if song.title != originalTitle { song.titlePinyin = nil }
        if song.artistName != originalArtist { song.artistPinyin = nil }
        changed = repairLegacyChineseText(&song.genre) || changed
        return changed
    }

    private nonisolated static func repairLegacyChineseText(_ text: inout String) -> Bool {
        let repaired = FileMetadataReader.repairLegacyChineseMojibake(text)
        guard repaired != text else { return false }
        text = repaired
        return true
    }

    private nonisolated static func repairLegacyChineseText(_ text: inout String?) -> Bool {
        guard var value = text else { return false }
        let repaired = FileMetadataReader.repairLegacyChineseMojibake(value)
        guard repaired != value else { return false }
        value = repaired
        text = value
        return true
    }

    private var persistTask: Task<Void, Never>?
    /// 已武装的 `persistTask` 的到期时刻。用来保留"最早的那个截止时间",
    /// 否则 backfill 的 30s 合并写会不断把用户操作的 0.2s / 2s 落盘推后。
    @ObservationIgnored private var persistDeadline: ContinuousClock.Instant?
    /// Incremental SQLite writes are serialized independently from the JSON
    /// compatibility snapshot. Scan cursor commits await this chain.
    private var songStoreWriteTask: Task<Int64?, Never>?
    @ObservationIgnored private var songStoreRequiresReplacement = false
    @ObservationIgnored private var pendingSnapshotImportID: String?
    @ObservationIgnored private var songStoreSnapshotWriter: @Sendable (IncrementalSongStore, [Song], String?) throws -> Int64 = {
        try $0.replaceAll(with: $1, snapshotImportID: $2)
    }
    /// Serializes off-main-actor snapshot writes. Each `persistNow` chains
    /// onto the previous write so the JSON encode + atomic write happen in
    /// order off the main thread, and the latest snapshot always wins.
    private var persistWriteTask: Task<Bool, Never>?
    /// A lifecycle flush may be requested many times without any library
    /// mutation. Track the latest mutation written to the portable JSON so an
    /// unchanged 10K+ song library is never re-encoded just for backgrounding.
    @ObservationIgnored private var portableSnapshotMutationGeneration: UInt64 = 0
    @ObservationIgnored private var portableSnapshotPersistedGeneration: UInt64 = 0
    @ObservationIgnored private var portableSnapshotEnqueuedGeneration: UInt64?
    @ObservationIgnored private var portableSnapshotNeedsInitialWrite = false
    private var derivedIndexCacheWriteTask: Task<Void, Never>?
    private var startupCacheWriteTask: Task<Void, Never>?
    /// 远端歌单并进来之后还没写进耐久账本(见 `scheduleRemotePlaylistDurabilityLedgerWrite`)。
    @ObservationIgnored private var remotePlaylistLedgerWritePending = false
    @ObservationIgnored private var remotePlaylistLedgerWriteTask: Task<Void, Never>?

    private nonisolated static func snapshotFingerprint(at url: URL) -> SnapshotFileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        let nanoseconds = Int64((modifiedAt.timeIntervalSince1970 * 1_000_000_000).rounded())
        return SnapshotFileFingerprint(
            fileSize: size,
            modificationTimeNanoseconds: nanoseconds,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func scheduleStartupCacheWrite(
        snapshot: Snapshot,
        songStoreRevision: Int64?,
        snapshotFingerprint: SnapshotFileFingerprint?
    ) {
        // S1: 发布前不写启动缓存。
        guard !isPreparing else {
            deferredStartupCacheWriteRequested = true
            return
        }
        let cache = StartupCache(
            formatVersion: Self.startupCacheFormatVersion,
            songStoreRevision: songStoreRevision,
            snapshotFingerprint: snapshotFingerprint,
            snapshot: snapshot,
            albums: albums,
            artists: artists,
            derivedIndexSignature: derivedIndexSignature
        )
        let url = startupCacheURL
        let previous = startupCacheWriteTask
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            Self.writeStartupCache(cache, to: url)
        }
        startupCacheWriteTask = task
    }

    private nonisolated static func writeStartupCache(_ cache: StartupCache, to url: URL) {
        do {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            plog("💾 Library startup cache written bytes=\(data.count) total=\(elapsedMS)ms")
        } catch {
            // The cache is an accelerator only. Keep the durable SQLite/JSON
            // state untouched and simply rebuild on the next launch.
            plog("⚠️ Library startup cache write failed: \(error.localizedDescription)")
        }
    }

    private func persistDerivedIndexCache() {
        // S1: 发布前不写派生索引缓存。
        guard !isPreparing else {
            deferredDerivedIndexCacheWriteRequested = true
            return
        }
        guard let derivedIndexSignature else { return }
        let cache = DerivedIndexCache(
            signature: derivedIndexSignature,
            albums: albums,
            artists: artists
        )
        let url = derivedIndexCacheURL
        let previous = derivedIndexCacheWriteTask
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(cache)
                try data.write(to: url, options: .atomic)
            } catch {
                plog("⚠️ Derived library index cache write failed: \(error.localizedDescription)")
            }
        }
        derivedIndexCacheWriteTask = task
    }

    private func persistSongChanges(
        upserts: [Song] = [],
        deletingIDs: Set<String> = [],
        needsPromptCompatibilitySnapshot: Bool = false
    ) {
        guard !upserts.isEmpty || !deletingIDs.isEmpty else { return }
        // S1: 发布前不落盘。产生这些改动的顶层突变本身已被排队(S2),
        // 重放时会带着正确的参数再次走到这里。
        guard !isPreparing else {
            deferredPortableSnapshotPersistRequested = true
            return
        }
        // Persist the dirty generation before the song-store transaction can
        // start. A process exit can therefore leave extra recovery work, but
        // can never commit new songs while leaving the old index marked clean.
        let searchIndexGeneration = LibrarySearchIndex.persistLibraryChangePending(
            defaults: searchIndexDefaults
        )

        if let songStore {
            let previous = songStoreWriteTask
            songStoreWriteTask = Task.detached(priority: .utility) { [weak self] in
                let previousSucceeded = await previous?.value != nil
                // A failed earlier delta may have left unknown rows stale, so
                // this delta must not commit a cursor over that gap. Hand the
                // gap to `flushIncrementalSongStore()` instead of freezing a
                // full `[Song]` copy per queued write: the chain is serial, so
                // an eager capture keeps one complete library buffer alive for
                // every queued delta, and recovering from a snapshot taken at
                // enqueue time would also roll back everything that landed
                // between the failure and the recovery.
                guard previous == nil || previousSucceeded else {
                    await MainActor.run { self?.songStoreRequiresReplacement = true }
                    return nil
                }
                do {
                    return try songStore.apply(upserts: upserts, deletingIDs: deletingIDs)
                } catch {
                    plog("⛔ Incremental song persistence failed: \(error.localizedDescription)")
                    return nil
                }
            }
        }

        enqueueSearchIndexChanges(
            upserts: upserts,
            deletingIDs: deletingIDs,
            generation: searchIndexGeneration,
            after: songStoreWriteTask
        )

        // The SQLite transaction is the durable local commit. Keep producing
        // the existing portable JSON for iCloud/TV, but coalesce ordinary
        // metadata batches instead of encoding a multi-thousand-song array
        // every two seconds. Destructive/user-visible mutations stay prompt.
        let delay: TimeInterval
        if needsPromptCompatibilitySnapshot || songStore == nil {
            delay = 2
        } else {
            delay = Self.lowPriorityPortableSnapshotDelay
        }
        persistSnapshot(after: delay)
    }

    /// 只影响可移植快照新鲜度的改动(歌曲已进 SQLite 的元数据批次、最近播放)
    /// 最多隔这么久整库落一次盘。整库快照是 O(整库) 字节 —— 4 万首约 35MB JSON
    /// 加 16MB 启动缓存 —— 原先 30 秒一次(回填时)或每首歌一次(播放时),
    /// 一天就能写出好几 GB。进后台、导出到 iCloud / Apple TV 之前都会先强制落盘,
    /// 启动时 SQLite 也比 JSON 权威, 所以这里放宽只影响崩溃时丢几分钟的「最近播放」。
    static let lowPriorityPortableSnapshotDelay: TimeInterval = 600

    /// 服务端歌单的镜像随时能从服务器重新拉回来, 不值得按用户编辑的 2 秒档落盘:
    /// 扫描收尾逐个落地几十个歌单时, 2 秒档意味着同步期间每两秒一份整库快照。
    /// 已经为用户改动武装的更早截止时间不受影响(persistSnapshot 保留最早的那个)。
    static let mirrorPlaylistSnapshotDelay: TimeInterval = 15

    static func snapshotDelay(forPlaylistID playlistID: String) -> TimeInterval {
        MirrorPlaylistIdentity.isMirrorPlaylist(playlistID) ? mirrorPlaylistSnapshotDelay : 2
    }

    private func persistSnapshot(
        after delay: TimeInterval = 2,
        marksMutation: Bool = true,
        trigger: StaticString = #function
    ) {
        if marksMutation { markPortableSnapshotDirty() }
        if isDeferringSceneTransitionPublications || externalSnapshotWriteOwners > 0 {
            deferredPersistRequested = true
            return
        }
        let deadline = ContinuousClock.now + .seconds(delay)
        // 保留最早的截止时间: 一次 30s 的 backfill 合并写不能顶掉已经为
        // 点赞 / 评分 / 歌单编辑 / 删除墓碑武装好的 0.2s / 2s 落盘。
        if persistTask != nil, let armed = persistDeadline, armed <= deadline { return }
        persistTask?.cancel()
        persistDeadline = deadline
        // 每次整库快照写都是 O(整库) 的字节量; 记下由谁在多久之后触发,
        // 写盘超限时才分得清是哪类改动在推节奏。合并掉的调用不记。
        plog("💾 Library snapshot write armed in \(delay)s by \(trigger)")
        persistTask = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            persistTask = nil
            persistDeadline = nil
            persistNow()
        }
    }

    /// Persist the library snapshot. Only the value-type snapshot is built on
    /// the main actor (cheap struct copies); the expensive JSON encode + atomic
    /// disk write run off the main thread so a large library (every Song carries
    /// its full `lyricsText`) doesn't block the UI — backfill flushes used to
    /// stall the main actor for hundreds of ms every few seconds while encoding
    /// the whole library inline.
    func persistNow() {
        // S1: 发布前不落盘, 记账后在发布步骤补一次。
        guard !isPreparing else {
            deferredPortableSnapshotPersistRequested = true
            return
        }
        // 整份替换进行中: 这是不等结果的写入方, 记下欠一次即可, 交还所有权
        // 时会按重载之后的内存状态补写。
        guard externalSnapshotWriteOwners == 0 else {
            deferredPersistRequested = true
            return
        }
        persistTask?.cancel()
        persistTask = nil
        persistDeadline = nil
        _ = enqueueSnapshotWrite()
    }

    /// 远端记录已经并进内存、CloudKit 游标马上要落盘: 已武装的短防抖写入现在就
    /// 写, 否则进程在这两秒里被杀, 游标越过的那批歌单曲目、智能歌单就再也拉不回
    /// 来了。只管两秒档: 最近播放那种 600 秒档丢了也只是几分钟的记录, 不值得为它
    /// 在每批远端事件后整库写一次。
    func flushArmedSnapshotWriteNow() {
        guard persistTask != nil, let deadline = persistDeadline,
              deadline <= ContinuousClock.now + .seconds(5) else { return }
        persistNow()
    }

    var hasPendingPortableSnapshotChanges: Bool {
        portableSnapshotNeedsInitialWrite
            || portableSnapshotMutationGeneration != portableSnapshotPersistedGeneration
            || portableSnapshotEnqueuedGeneration != nil
    }

    private func markPortableSnapshotDirty() {
        // S1: 发布前不推进可移植快照的写入代际。
        guard !isPreparing else {
            deferredPortableSnapshotPersistRequested = true
            return
        }
        portableSnapshotMutationGeneration &+= 1
    }

    private func enqueueSnapshotWrite() -> Task<Bool, Never>? {
        // S1: 发布前不落盘。
        guard !isPreparing else {
            deferredPortableSnapshotPersistRequested = true
            return nil
        }
        guard !persistenceBlockedByCorruption else {
            plog("⛔ Library persistence skipped because the on-disk snapshot is corrupt")
            return nil
        }
        let generation = portableSnapshotMutationGeneration
        let needsWrite = portableSnapshotNeedsInitialWrite
            || generation != portableSnapshotPersistedGeneration
        guard needsWrite else { return nil }
        if portableSnapshotEnqueuedGeneration == generation,
           let persistWriteTask {
            return persistWriteTask
        }
        let snapshot = makeSnapshot(includingSongs: writesSongsIntoPortableSnapshot)
        let url = snapshotURL
        let backupURL = backupSnapshotURL
        let cacheURL = startupCacheURL
        let pendingSongStoreWrite = songStoreWriteTask
        let capturedStoreRevision = pendingSongStoreWrite == nil
            ? (try? songStore?.startupState().contentRevision)
            : nil
        let cachedAlbums = albums
        let cachedArtists = artists
        let cachedDerivedSignature = derivedIndexSignature
        let cacheFormatVersion = Self.startupCacheFormatVersion
        let previous = persistWriteTask
        let previousStartupCacheWrite = startupCacheWriteTask
        let task = Task.detached(priority: .utility) {
            // Chain after any in-flight write so the atomic file is updated in
            // call order and we never run two encodes against the same path.
            // 前一笔的结果同时说明"磁盘上那份字节是它写的、而且有效", 备份提升
            // 就不必再解码一次整份快照。
            let previousSucceeded = await previous?.value
            let existingFileIsKnownValid = LibrarySnapshotBackupPolicy
                .existingFileIsKnownValid(previousChainedWriteSucceeded: previousSucceeded)
            let songStoreRevision = await pendingSongStoreWrite?.value ?? capturedStoreRevision
            guard Self.writeSnapshot(
                snapshot,
                to: url,
                backupURL: backupURL,
                existingFileIsKnownValid: existingFileIsKnownValid
            ) else {
                return false
            }
            _ = await previousStartupCacheWrite?.value
            let cache = StartupCache(
                formatVersion: cacheFormatVersion,
                songStoreRevision: songStoreRevision,
                snapshotFingerprint: Self.snapshotFingerprint(at: url),
                snapshot: snapshot,
                albums: cachedAlbums,
                artists: cachedArtists,
                derivedIndexSignature: cachedDerivedSignature
            )
            Self.writeStartupCache(cache, to: cacheURL)
            return true
        }
        persistWriteTask = task
        portableSnapshotEnqueuedGeneration = generation
        Task { @MainActor [weak self] in
            let succeeded = await task.value
            self?.recordPortableSnapshotWriteCompletion(
                generation: generation,
                succeeded: succeeded
            )
        }
        return task
    }

    private func recordPortableSnapshotWriteCompletion(
        generation: UInt64,
        succeeded: Bool
    ) {
        if succeeded, generation == portableSnapshotMutationGeneration {
            portableSnapshotPersistedGeneration = generation
            portableSnapshotNeedsInitialWrite = false
        }
        if portableSnapshotEnqueuedGeneration == generation {
            portableSnapshotEnqueuedGeneration = nil
        }
    }

    /// `includingSongs: false` leaves the library's songs to the incremental
    /// store (see `Snapshot.separateSongStore`); rows excluded on this device
    /// still travel, they are not in the store.
    private func makeSnapshot(includingSongs: Bool = true) -> Snapshot {
        let retained = deviceLocalExcludedSongsByID.values.filter {
            songIndexByID[$0.id] == nil && !deletedSongIdentities.contains(identityKey(for: $0))
        }.sorted { $0.id < $1.id }
        var snapshot = Snapshot(
            songs: !includingSongs ? retained : (retained.isEmpty ? songs : songs + retained),
            playlists: allPlaylists,
            artworkOverrides: allArtworkOverrides.isEmpty ? nil : allArtworkOverrides,
            libraryReviews: allLibraryReviews.isEmpty ? nil : allLibraryReviews,
            libraryInsights: libraryInsightRecordsByID.isEmpty ? nil : allLibraryInsightRecords,
            automaticArtistArtworkCatalogs: automaticArtistArtworkCatalogsBySource
                .values
                .sorted { $0.sourceID < $1.sourceID },
            artworkAssets: nil,
            mirrorPlaylistSuppressions: hiddenMirrorPlaylists.isEmpty ? nil : hiddenMirrorPlaylists,
            smartPlaylists: allSmartPlaylists.isEmpty ? nil : allSmartPlaylists,
            playlistSongIDs: playlistSongIDs,
            playlistSyncBaseSongIDs: playlistSyncBaseSongIDs.isEmpty ? nil : playlistSyncBaseSongIDs,
            recentPlaybackSongIDs: recentPlaybackSongIDs,
            deletedSongIdentities: Array(deletedSongIdentities),
            deletedSongIdentityDetails: deletedSongIdentityDetails.isEmpty
                ? nil
                : deletedSongIdentityDetails,
            pendingPlaylistIdentities: pendingPlaylistIdentities.isEmpty ? nil : pendingPlaylistIdentities,
            pendingHistoryIdentities: pendingHistoryIdentities.isEmpty ? nil : pendingHistoryIdentities,
            playlistPendingEntries: playlistPendingEntries.isEmpty ? nil : playlistPendingEntries
        )
        if !includingSongs { snapshot.separateSongStore = true }
        return snapshot
    }

    enum PortableSnapshotExport: Sendable {
        case snapshot(Data)
        case tooLarge(songCount: Int)
        case unavailable
    }

    /// 带歌的整库快照, 供 iCloud 整库上传与 Apple TV 直传按需导出: 十万首以上的曲库写盘
    /// 的快照不带歌(`separateSongStore`), 这里从内存里的曲库编出与不到十万首时写盘同形的
    /// 那份。先抽样估算, 明显放不进 `byteLimit` 就不编整库。曲库还没装载成功时不导出,
    /// 免得把空曲库发出去。
    func portableSnapshotIncludingSongs(byteLimit: Int) async -> PortableSnapshotExport {
        guard isReady, !persistenceBlockedByCorruption else { return .unavailable }
        let snapshot = makeSnapshot(includingSongs: true)
        return await Task.detached(priority: .userInitiated) {
            Self.encodePortableSnapshot(snapshot, byteLimit: byteLimit)
        }.value
    }

    private nonisolated static func encodePortableSnapshot(
        _ snapshot: Snapshot,
        byteLimit: Int
    ) -> PortableSnapshotExport {
        let songs = snapshot.songs
        if !songs.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let step = max(1, songs.count / 512)
            var sampledBytes = 0
            var sampledCount = 0
            for index in stride(from: 0, to: songs.count, by: step) {
                guard let data = try? encoder.encode(songs[index]) else { return .unavailable }
                sampledBytes += data.count + 1
                sampledCount += 1
            }
            let estimatedBytes = Double(sampledBytes) / Double(sampledCount) * Double(songs.count)
            // 只在明显放不下时提前拒绝, 贴近上限的照样编一遍再按真实字节判断。
            if estimatedBytes > Double(byteLimit) * 1.1 {
                return .tooLarge(songCount: songs.count)
            }
        }
        guard let data = try? encodeSnapshotForDisk(snapshot) else { return .unavailable }
        return data.count <= byteLimit ? .snapshot(data) : .tooLarge(songCount: songs.count)
    }

    /// Libraries past this many songs write their portable snapshot without
    /// the songs. The full form is only needed by the iCloud / Apple TV
    /// transfer, which refuses snapshots over 64 MB (about 80K songs); past
    /// that it was rewritten in full — several hundred MB of JSON — after
    /// every like or playlist edit, for nothing but a local fallback the
    /// incremental store already provides.
    static let separateSongStoreMinimumSongs = 100_000

    /// Test hook for the threshold above.
    @ObservationIgnored var separateSongStoreMinimumSongsOverride: Int?

    private var writesSongsIntoPortableSnapshot: Bool {
        #if os(tvOS)
        return true
        #else
        guard songStore != nil, !songStoreRequiresReplacement else { return true }
        return songs.count < (separateSongStoreMinimumSongsOverride ?? Self.separateSongStoreMinimumSongs)
        #endif
    }

    /// Whether `data` is a snapshot whose songs live only in this device's
    /// incremental store; the transfer to other devices must not send it.
    nonisolated static func snapshotKeepsSongsSeparately(_ data: Data) -> Bool {
        struct Marker: Decodable { let separateSongStore: Bool? }
        return (try? JSONDecoder().decode(Marker.self, from: data))?.separateSongStore == true
    }

    /// Persist the current snapshot and wait until its atomic file replacement
    /// finishes. Explicit export/sync actions use this instead of racing an
    /// asynchronous `persistNow()` against an immediate file read.
    func persistNowAndWait() async -> Result<Void, AppleTVTransferFailure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        // `.preparing` 期间 songStore 还是 nil, S1 又会拦下快照写入, 于是这里
        // 会在一个字节都没写的情况下返回 .success —— 把 addSongs 提交的行当成
        // 已落盘, 调用方 (扫描游标 / Apple TV 传输检查点) 就会提交一个磁盘上
        // 并不存在的检查点。屏障语义要求先等发布 (含排队突变重放) 完成。
        await whenReady()
        // 整份替换进行中就先等它结束: 这个调用的契约是"返回时已落盘", 既不能
        // 空写成功, 也不能和事务抢同一个文件。
        await awaitExternalSnapshotWriteRelease()
        guard !Task.isCancelled else { return .failure(.cancelled) }
        // 屏障语义: 窗口内的资源补丁也必须进这次落盘。
        flushPendingAssetReferencePatches()
        persistTask?.cancel()
        persistTask = nil
        persistDeadline = nil
        guard await flushIncrementalSongStore() else {
            return .failure(.snapshotPreparationFailed)
        }
        if persistenceBlockedByCorruption {
            return .failure(.snapshotPreparationFailed)
        }
        guard let task = enqueueSnapshotWrite() else { return .success(()) }
        let generation = portableSnapshotMutationGeneration
        let succeeded = await task.value
        recordPortableSnapshotWriteCompletion(
            generation: generation,
            succeeded: succeeded
        )
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard succeeded else {
            plog("⛔ Library snapshot persistence failed before transfer")
            return .failure(.snapshotPreparationFailed)
        }
        return .success(())
    }

    /// Durable commit used by source synchronization. SQLite is sufficient for
    /// the device-local cursor transaction; the portable JSON snapshot remains
    /// debounced until iCloud/TV export or a lifecycle flush requests it.
    func persistIncrementalNowAndWait() async -> Result<Void, AppleTVTransferFailure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        // 同 `persistNowAndWait`: 存储句柄要等发布才装入, 分支判断也必须在
        // 发布之后做, 否则增量提交会退回 JSON 路径并同样空写成功。
        await whenReady()
        flushPendingAssetReferencePatches()
        guard songStore != nil else {
            // Older/unsupported environments retain the proven JSON path.
            return await persistNowAndWait()
        }
        guard await flushIncrementalSongStore() else {
            return .failure(.snapshotPreparationFailed)
        }
        return .success(())
    }

    private func flushIncrementalSongStore() async -> Bool {
        let pendingSucceeded: Bool
        if let songStoreWriteTask { pendingSucceeded = await songStoreWriteTask.value != nil }
        else { pendingSucceeded = true }
        guard songStoreRequiresReplacement || !pendingSucceeded else { return true }
        guard let songStore else { return false }
        // 曲库这次没装载成功时内存里的歌不完整, 绝不能拿它整库替换增量库。
        guard !persistenceBlockedByCorruption else {
            plog("⛔ Incremental song recovery skipped: library did not load")
            return false
        }

        let recoverySnapshot = songs
        let writer = songStoreSnapshotWriter
        let importID = pendingSnapshotImportID
        // 恢复写入必须留在 songStoreWriteTask 这条串行链上, 并且在 await 之前
        // 就成为链头: 等待期间 persistSongChanges 产生的增量才会排在恢复之后,
        // 既不会被更旧的恢复快照覆盖, 也不会因为 await 之后重新赋值链头而被
        // 挤出链外 (它们的成败也就再没人观察得到)。
        let previous = songStoreWriteTask
        let recoveryTask = Task<Int64?, Never>.detached(priority: .utility) {
            _ = await previous?.value
            do {
                return try writer(songStore, recoverySnapshot, importID)
            } catch {
                plog("⛔ Incremental song recovery failed: \(error.localizedDescription)")
                return nil
            }
        }
        songStoreWriteTask = recoveryTask
        guard await recoveryTask.value != nil else {
            plog("⛔ Incremental song persistence failed before library commit")
            return false
        }
        // 不再回写 songStoreWriteTask: 等待期间 chain 上来的增量才是真正的链头。
        // reloadFromDisk 可能在等待期间重新武装一次更新的替换, 所以只清除本次
        // 处理的那一个 importID。
        if pendingSnapshotImportID == importID {
            songStoreRequiresReplacement = false
            pendingSnapshotImportID = nil
        }
        return true
    }

    nonisolated static func snapshotImportID(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Encode + atomically write a snapshot. `nonisolated` so it runs off the
    /// main actor; uses a fresh encoder rather than sharing the main-actor one.
    ///
    /// `existingFileIsKnownValid` 只在这条串行写入链的前一笔刚刚把同一份字节
    /// 写进 `url` 并报告成功时为真; 那一次解码是纯粹的重复劳动 (整份快照含
    /// 内嵌歌词, 一次解码就是一遍完整的 `Song` 反序列化)。每次成功写入还会记下
    /// 文件身份, 下次(包括下一次启动)文件身份没变也视为有效。其它任何来源 ——
    /// `reloadFromDisk`、iCloud / Apple TV 快照导入、失败的写入 —— 都会换掉文件
    /// 身份, 走原来的解码校验, 它是"损坏文件不得被提升为备份"的那道保险。
    private nonisolated static func writeSnapshot(
        _ snapshot: Snapshot,
        to url: URL,
        backupURL: URL,
        existingFileIsKnownValid: Bool
    ) -> Bool {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let data: Data
        do {
            data = try encodeSnapshotForDisk(snapshot)
        } catch {
            plog("⚠️ Library snapshot encoding failed: \(error.localizedDescription)")
            return false
        }
        let encodedAt = ProcessInfo.processInfo.systemUptime
        let verifiedFingerprintURL = verifiedSnapshotFingerprintURL(for: url)
        let existingFingerprint = snapshotFingerprint(at: url)
        let existingFileMatchesLastVerifiedWrite = existingFingerprint != nil
            && existingFingerprint == loadVerifiedSnapshotFingerprint(from: verifiedFingerprintURL)
        let existingValidityKnown = LibrarySnapshotBackupPolicy.existingFileIsKnownValid(
            previousChainedWriteSucceeded: existingFileIsKnownValid ? true : nil,
            existingFileMatchesLastVerifiedWrite: existingFileMatchesLastVerifiedWrite
        )
        let existingFileIsValid: Bool?
        if LibrarySnapshotBackupPolicy.shouldValidateExistingFile(
            existingFileIsKnownValid: existingValidityKnown
        ) {
            existingFileIsValid = (try? Data(contentsOf: url))
                .map(isValidSnapshotData) ?? false
        } else {
            existingFileIsValid = nil
        }
        let shouldPreserveCurrentAsBackup = LibrarySnapshotBackupPolicy
            .shouldPreserveExistingAsBackup(
                existingFileIsKnownValid: existingValidityKnown,
                existingFileIsValid: existingFileIsValid
            )
        do {
            try AtomicBackupFileWriter.write(
                data,
                to: url,
                backupURL: backupURL,
                preserveExistingAsBackup: shouldPreserveCurrentAsBackup
            )
            saveVerifiedSnapshotFingerprint(snapshotFingerprint(at: url), to: verifiedFingerprintURL)
            let finishedAt = ProcessInfo.processInfo.systemUptime
            plog(
                "💾 Library snapshot written bytes=\(data.count) songs=\(snapshot.songs.count) "
                    + "encode=\(Int((encodedAt - startedAt) * 1000))ms "
                    + "write=\(Int((finishedAt - encodedAt) * 1000))ms "
                    + "validatedExisting=\(existingFileIsValid != nil)"
            )
            return true
        } catch {
            plog("⚠️ Library snapshot write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 整库快照的 JSON 字节。歌曲数组按批编码再拼接, 字节与整份 `encode` 相同,
    /// 但不必为二十多万首歌一次建出整棵值树(实测多占近 1GB, 大曲库会因此被系统
    /// 按内存超限杀掉)。拼不上时(比如以后加了排在 `songs` 之后的键)退回整份编码。
    private nonisolated static func encodeSnapshotForDisk(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var head = snapshot
        head.songs = []
        if let data = try TrailingArrayJSONEncoding.encode(
            emptyArrayObject: encoder.encode(head),
            trailingKey: "songs",
            elements: snapshot.songs,
            encoder: encoder
        ) {
            return data
        }
        return try encoder.encode(snapshot)
    }

    /// 上一次成功写入后快照文件的身份(大小、修改时间、文件号)。磁盘上的文件还是
    /// 这个身份, 就是那次编码并原子替换的字节, 不必再整份解码一遍来证明它有效。
    private nonisolated static func verifiedSnapshotFingerprintURL(for snapshotURL: URL) -> URL {
        snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("library-cache.verified-fingerprint.json")
    }

    private nonisolated static func loadVerifiedSnapshotFingerprint(from url: URL) -> SnapshotFileFingerprint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SnapshotFileFingerprint.self, from: data)
    }

    private nonisolated static func saveVerifiedSnapshotFingerprint(
        _ fingerprint: SnapshotFileFingerprint?,
        to url: URL
    ) {
        guard let fingerprint, let data = try? JSONEncoder().encode(fingerprint) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// 装载时对账一次墓碑账本, 规则与跨设备合并完全一致, 只是这里没有第二份
    /// 快照可并: 证据表说已撤销的键不该还留在集合里(旧版本写回的快照可能两者
    /// 不一致), 已撤销的记录留到保留期结束再清, 仍然生效的证据跟着键走。
    nonisolated static func reconciledTombstoneLedger(
        identities: Set<String>,
        details: [String: LibrarySongTombstoneDetail],
        now: Date = Date()
    ) -> (identities: Set<String>, details: [String: LibrarySongTombstoneDetail]) {
        guard !details.isEmpty else { return (identities, [:]) }
        let merged = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: Array(identities),
            localDetails: details,
            incomingIdentities: nil,
            incomingDetails: nil,
            now: now
        )
        return (Set(merged.identities), merged.details)
    }

    nonisolated static func isValidSnapshotData(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Snapshot.self, from: data)) != nil
    }

    /// 多台设备各自上传的曲库快照合并成一份给 Apple TV。`payloads` 按上传时间新的
    /// 在前: 歌曲按 id 取并集, 同一首以前面的设备为准; 封面按键取并集, 合计不超过
    /// 一份快照的封面预算; 歌单、智能歌单、最近播放、墓碑这些用户状态沿用
    /// `mergingSnapshotUserState` 的版本规则, 不看是哪台设备传的。
    nonisolated static func mergingDeviceSnapshots(_ payloads: [Data]) throws -> Data {
        guard var mergedData = payloads.first else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for olderData in payloads.dropFirst() {
            var merged = try decoder.decode(Snapshot.self, from: mergedData)
            let older = try decoder.decode(Snapshot.self, from: olderData)

            var songIDs = Set(merged.songs.map(\.id))
            merged.songs.append(contentsOf: older.songs.filter { songIDs.insert($0.id).inserted })

            var artworkBytes = (merged.artworkAssets ?? [:]).values.reduce(0) { $0 + $1.count }
                + (merged.cachedArtworkAssets ?? [:]).values.reduce(0) { $0 + $1.count }
            func absorb(_ incoming: [String: Data]?, into target: inout [String: Data]?) {
                guard let incoming, !incoming.isEmpty else { return }
                var current = target ?? [:]
                for (key, data) in incoming where current[key] == nil {
                    guard artworkBytes + data.count <= portableArtworkBudgetBytes else { continue }
                    current[key] = data
                    artworkBytes += data.count
                }
                target = current
            }
            absorb(older.artworkAssets, into: &merged.artworkAssets)
            absorb(older.cachedArtworkAssets, into: &merged.cachedArtworkAssets)
            if let references = older.artworkCacheReferences, !references.isEmpty {
                merged.artworkCacheReferences = (merged.artworkCacheReferences ?? [:])
                    .merging(references) { current, _ in current }
            }
            if let catalogs = older.automaticArtistArtworkCatalogs, !catalogs.isEmpty {
                var known = Set((merged.automaticArtistArtworkCatalogs ?? []).map(\.sourceID))
                merged.automaticArtistArtworkCatalogs = (merged.automaticArtistArtworkCatalogs ?? [])
                    + catalogs.filter { known.insert($0.sourceID).inserted }
            }
            if let overrides = older.artworkOverrides, !overrides.isEmpty {
                var known = Set((merged.artworkOverrides ?? []).map(\.owner.storageKey))
                merged.artworkOverrides = (merged.artworkOverrides ?? [])
                    + overrides.filter { known.insert($0.owner.storageKey).inserted }
            }

            mergedData = try encoder.encode(merged)
            mergedData = try mergingSnapshotUserState(
                localData: olderData,
                incomingData: mergedData,
                locallyRetainedSongIDs: []
            )
        }
        return mergedData
    }

    nonisolated static func mergingSnapshotUserState(
        localData: Data,
        incomingData: Data,
        locallyRetainedSongIDs: Set<String>
    ) throws -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let local = try decoder.decode(Snapshot.self, from: localData)
        var incoming = try decoder.decode(Snapshot.self, from: incomingData)
        var membership = incoming.playlistSongIDs ?? [:]
        var pending = incoming.pendingPlaylistIdentities ?? [:]
        for playlist in local.playlists {
            if let index = incoming.playlists.firstIndex(where: { $0.id == playlist.id }) {
                if PlaylistReconciliationPolicy.winner(local: playlist, remote: incoming.playlists[index]) == .local {
                    incoming.playlists[index] = playlist
                    membership[playlist.id] = local.playlistSongIDs?[playlist.id] ?? []
                    pending[playlist.id] = local.pendingPlaylistIdentities?[playlist.id] ?? []
                } else if !incoming.playlists[index].isDeleted {
                    // Cloud snapshots omit device-local songs. A newer remote
                    // playlist must not erase its locally owned occurrences.
                    let retained = (local.playlistSongIDs?[playlist.id] ?? []).filter {
                        locallyRetainedSongIDs.contains($0)
                    }
                    var seen = Set(membership[playlist.id] ?? [])
                    membership[playlist.id, default: []].append(contentsOf: retained.filter { seen.insert($0).inserted })
                }
            } else {
                incoming.playlists.append(playlist)
                membership[playlist.id] = local.playlistSongIDs?[playlist.id] ?? []
                pending[playlist.id] = local.pendingPlaylistIdentities?[playlist.id] ?? []
            }
        }
        incoming.playlistSongIDs = membership
        incoming.pendingPlaylistIdentities = pending
        // 占位条目按 id 取并集: 成员表里引用到谁, 谁就得有元数据; 多出来的
        // 下次装载时由 `cleanPlaylistEntries` 回收。
        var pendingEntries = incoming.playlistPendingEntries ?? [:]
        for (id, entry) in local.playlistPendingEntries ?? [:] where pendingEntries[id] == nil {
            pendingEntries[id] = entry
        }
        incoming.playlistPendingEntries = pendingEntries.isEmpty ? nil : pendingEntries
        var smart = incoming.smartPlaylists ?? []
        for playlist in local.smartPlaylists ?? [] {
            if let index = smart.firstIndex(where: { $0.id == playlist.id }) {
                if playlist.updatedAt > smart[index].updatedAt { smart[index] = playlist }
            } else { smart.append(playlist) }
        }
        incoming.smartPlaylists = smart
        var recent = Set<String>()
        incoming.recentPlaybackSongIDs = Array(
            ((local.recentPlaybackSongIDs ?? []) + (incoming.recentPlaybackSongIDs ?? []))
                .filter { recent.insert($0).inserted }.prefix(100)
        )
        var identities = Set<PendingSongIdentity>()
        incoming.pendingHistoryIdentities = ((local.pendingHistoryIdentities ?? []) + (incoming.pendingHistoryIdentities ?? []))
            .filter { identities.insert($0).inserted }
        // 墓碑不能再简单取并集: 本机刚撤销的键会被另一台设备尚未同步的旧快照
        // 原样带回来, 复活撑不过一次同步。按键做 last-writer-wins, 并集之后减
        // 掉证据表判定已撤销的那些。
        let mergedTombstones = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: local.deletedSongIdentities,
            localDetails: local.deletedSongIdentityDetails,
            incomingIdentities: incoming.deletedSongIdentities,
            incomingDetails: incoming.deletedSongIdentityDetails
        )
        incoming.deletedSongIdentities = mergedTombstones.identities
        incoming.deletedSongIdentityDetails = mergedTombstones.details.isEmpty
            ? nil
            : mergedTombstones.details
        var reviewsBySubject = Dictionary(
            (incoming.libraryReviews ?? []).map { ($0.subject.storageKey, $0) },
            uniquingKeysWith: { local, remote in
                LibraryReviewReconciliationPolicy.winner(local: local, remote: remote)
            }
        )
        for localReview in local.libraryReviews ?? [] {
            if let incomingReview = reviewsBySubject[localReview.subject.storageKey] {
                reviewsBySubject[localReview.subject.storageKey] =
                    LibraryReviewReconciliationPolicy.winner(
                        local: localReview,
                        remote: incomingReview
                    )
            } else {
                reviewsBySubject[localReview.subject.storageKey] = localReview
            }
        }
        incoming.libraryReviews = reviewsBySubject.values.sorted { $0.id < $1.id }
        let insights = LibraryInsightEditing.merged(
            local.libraryInsights ?? [],
            incoming.libraryInsights ?? []
        )
        incoming.libraryInsights = insights.isEmpty ? nil : insights
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(incoming)
    }

    nonisolated static func isValidSnapshot(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isValidSnapshotData(data)
    }

    struct PortableSnapshotTransferData: Sendable {
        let data: Data
        /// Nil keeps the LAN transfer's historical all-lyrics behavior. A set
        /// limits CloudKit to songs retained after device-local filtering.
        let eligibleLyricsFileNames: Set<String>?
        /// Songs left in the payload after cloud-source filtering. Callers that
        /// overwrite a shared cloud snapshot use this to refuse an automatic
        /// upload that would replace a real library with an empty one.
        let eligibleSongCount: Int
        /// Raw cover bytes embedded in `data`. A transport that must fit a
        /// size limit shrinks the next attempt's budget from this figure.
        let artworkBytes: Int
        /// True when the payload's source list still carries at least one
        /// cloud-sync-eligible source. A library assembled only from device-local
        /// imports and the Apple Music Library always filters down to zero
        /// eligible songs, so the empty-library guard must not read that as a
        /// library that was wiped.
        let hasCloudEligibleSources: Bool
    }

    nonisolated static let portableArtworkBudgetBytes = 24 * 1024 * 1024

    /// The local snapshot stays metadata-only. Transport copies include bounded,
    /// content-deduplicated covers so tvOS can display artwork without the sender's cache.
    nonisolated static func preparePortableSnapshotDataIncludingArtworkAssets(
        _ data: Data,
        cloudSources: [MusicSource]? = nil,
        assetStore: MetadataAssetStore = .shared,
        maximumArtworkBytes: Int = portableArtworkBudgetBytes
    ) async -> PortableSnapshotTransferData? {
        guard !Task.isCancelled else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var snapshot = try? decoder.decode(Snapshot.self, from: data) else { return nil }

        var eligibleLyricsFileNames: Set<String>?
        // Without a cloud source list nothing is filtered out, so the payload is
        // not the device-local-only case the automatic upload guard looks for.
        var hasCloudEligibleSources = true
        if let cloudSources {
            hasCloudEligibleSources = cloudSources.contains(
                where: MusicSourceCloudSyncPolicy.isEligible
            )
            snapshot.songs = MusicSourceCloudSyncPolicy.eligibleSongs(
                snapshot.songs,
                sources: cloudSources
            )
            let retainedSourceIDs = Set(snapshot.songs.map(\.sourceID))
            snapshot.automaticArtistArtworkCatalogs?.removeAll {
                !retainedSourceIDs.contains($0.sourceID)
            }
            let retainedSongIDs = Set(snapshot.songs.map(\.id))
            if var playlistSongIDs = snapshot.playlistSongIDs {
                for playlistID in playlistSongIDs.keys {
                    playlistSongIDs[playlistID]?.removeAll {
                        !retainedSongIDs.contains($0) && !PlaylistPendingEntry.isPendingID($0)
                    }
                }
                snapshot.playlistSongIDs = playlistSongIDs
            }
            snapshot.recentPlaybackSongIDs?.removeAll {
                !retainedSongIDs.contains($0)
            }
            var names = Set<String>()
            names.reserveCapacity(snapshot.songs.count * 2)
            for song in snapshot.songs {
                names.insert(
                    MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
                )
                if let legacyName = song.lyricsFileName,
                   LyricsSnapshotEncoder.isValidFileName(legacyName) {
                    names.insert(legacyName)
                }
            }
            eligibleLyricsFileNames = names
        }

        let maximumEncodedSnapshotBytes = 60 * 1024 * 1024
        let availableEncodedBytes = max(0, maximumEncodedSnapshotBytes - data.count - 512)
        let maximumRawArtworkBytes = min(max(0, maximumArtworkBytes), availableEncodedBytes * 3 / 4)
        guard let artwork = await collectPortableArtwork(
            songs: snapshot.songs,
            artworkOverrides: snapshot.artworkOverrides,
            assetStore: assetStore,
            maximumRawBytes: maximumRawArtworkBytes,
            maximumEncodedBytes: availableEncodedBytes
        ) else { return nil }
        snapshot.artworkAssets = artwork.customAssets.isEmpty ? nil : artwork.customAssets
        snapshot.cachedArtworkAssets = artwork.cachedAssets.isEmpty ? nil : artwork.cachedAssets
        snapshot.artworkCacheReferences = artwork.references.isEmpty ? nil : artwork.references

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(snapshot),
           encoded.count <= maximumEncodedSnapshotBytes {
            return PortableSnapshotTransferData(
                data: encoded,
                eligibleLyricsFileNames: eligibleLyricsFileNames,
                eligibleSongCount: snapshot.songs.count,
                artworkBytes: artwork.rawBytes,
                hasCloudEligibleSources: hasCloudEligibleSources
            )
        }

        // Artwork is optional. Never fall back to the unfiltered raw snapshot
        // for CloudKit, because that would reintroduce device-local songs.
        snapshot.artworkAssets = nil
        snapshot.cachedArtworkAssets = nil
        snapshot.artworkCacheReferences = nil
        guard let encoded = try? encoder.encode(snapshot),
              encoded.count <= 64 * 1024 * 1024 else { return nil }
        return PortableSnapshotTransferData(
            data: encoded,
            eligibleLyricsFileNames: eligibleLyricsFileNames,
            eligibleSongCount: snapshot.songs.count,
            artworkBytes: 0,
            hasCloudEligibleSources: hasCloudEligibleSources
        )
    }

    struct PortableArtworkCollection: Sendable {
        /// User-uploaded covers keyed by content ID.
        var customAssets: [String: Data] = [:]
        /// Cached covers keyed by content ID.
        var cachedAssets: [String: Data] = [:]
        /// Cache file name → content ID.
        var references: [String: String] = [:]
        var rawBytes = 0
    }

    /// LAN pairing sends the library first and its covers afterwards in
    /// batches, so the covers are gathered on their own here with only a raw
    /// byte budget. Returns nil when the snapshot is unreadable or the task is
    /// cancelled.
    nonisolated static func collectPortableArtwork(
        fromSnapshotData data: Data,
        assetStore: MetadataAssetStore = .shared,
        maximumRawBytes: Int = portableArtworkBudgetBytes
    ) async -> PortableArtworkCollection? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return nil }
        return await collectPortableArtwork(
            songs: snapshot.songs,
            artworkOverrides: snapshot.artworkOverrides,
            assetStore: assetStore,
            maximumRawBytes: maximumRawBytes,
            maximumEncodedBytes: Int.max / 4
        )
    }

    /// Bounded, content-deduplicated covers for a transport copy. The encoded
    /// budget counts the base64 text the covers become inside snapshot JSON.
    private nonisolated static func collectPortableArtwork(
        songs: [Song],
        artworkOverrides: [LibraryArtworkOverride]?,
        assetStore: MetadataAssetStore,
        maximumRawBytes: Int,
        maximumEncodedBytes: Int
    ) async -> PortableArtworkCollection? {
        var usedBytes = 0
        var usedEncodedBytes = 0
        var assets: [String: Data] = [:]
        let uploaded = (artworkOverrides ?? [])
            .filter { $0.mode == .uploaded }
            .sorted { $0.updatedAt > $1.updatedAt }
        for value in uploaded {
            guard let contentID = value.uploadedContentID,
                  assets[contentID] == nil,
                  let artworkData = assetStore.customArtworkData(
                    contentID: contentID
                  ),
                  usedBytes <= maximumRawBytes - artworkData.count else {
                continue
            }
            let encodedBytes = ((artworkData.count + 2) / 3) * 4 + contentID.utf8.count + 6
            guard encodedBytes <= maximumEncodedBytes - usedEncodedBytes else { continue }
            assets[contentID] = artworkData
            usedBytes += artworkData.count
            usedEncodedBytes += encodedBytes
        }

        var cachedAssets: [String: Data] = [:]
        var references: [String: String] = [:]
        var preparedContent: [String: String] = [:]
        var attemptedContent = Set<String>()
        var visitedFiles = Set<String>()
        var artworkBudgetExhausted = false
        func includeCachedCover(named sourceName: String, as destinationName: String) async {
            guard references[destinationName] == nil,
                  visitedFiles.insert(destinationName).inserted,
                  let cacheIdentity = assetStore.coverContentIdentifier(named: sourceName) else { return }
            let sourceID = cacheIdentity.hasPrefix("sha256:") ? cacheIdentity : sourceName + ":" + cacheIdentity
            let referenceBytes = destinationName.utf8.count + 64 + 6
            guard referenceBytes <= maximumEncodedBytes - usedEncodedBytes else { return }
            if let contentID = preparedContent[sourceID] {
                references[destinationName] = contentID
                usedEncodedBytes += referenceBytes
                return
            }
            // A cover that cannot fit the remaining budget must not be
            // decoded again for every track on the same album.
            guard !artworkBudgetExhausted,
                  usedBytes < maximumRawBytes,
                  attemptedContent.insert(sourceID).inserted else { return }
            let startedAt = ContinuousClock.now
            guard let cover = assetStore.preparePortableCover(
                named: sourceName, contentIdentifier: sourceID
            ) else { return }
            if cover.requiredProcessing {
                // Cold exports can encounter thousands of distinct covers.
                // Yield between conversions and leave CPU time for playback.
                do {
                    try await Task.sleep(for: max(.milliseconds(20), startedAt.duration(to: .now)))
                } catch { return }
            }
            guard !Task.isCancelled else { return }
            let image = cover.data
            let contentID = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
            if cachedAssets[contentID] == nil {
                let encodedBytes = ((image.count + 2) / 3) * 4 + contentID.utf8.count + 6
                guard image.count <= maximumRawBytes - usedBytes,
                      encodedBytes + referenceBytes <= maximumEncodedBytes - usedEncodedBytes else {
                    artworkBudgetExhausted = true
                    return
                }
                cachedAssets[contentID] = image
                usedBytes += image.count
                usedEncodedBytes += encodedBytes
            }
            preparedContent[sourceID] = contentID
            references[destinationName] = contentID
            usedEncodedBytes += referenceBytes
        }
        // Iterate only retained songs: CloudKit excludes device-local media and
        // must also exclude the ordinary covers belonging solely to that media.
        for song in songs {
            if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return nil }
            if let albumID = song.albumID, !albumID.isEmpty {
                let name = "album/" + assetStore.expectedCoverFileName(for: "album_\(albumID)")
                await includeCachedCover(named: name, as: name)
            }
            let name = assetStore.expectedCoverFileName(for: song.id)
            let sourceName: String
            if assetStore.coverContentIdentifier(named: name) != nil {
                sourceName = name
            } else if let legacy = song.coverArtFileName, assetStore.isLegacyLocalRef(legacy) {
                sourceName = legacy
            } else {
                continue
            }
            await includeCachedCover(named: sourceName, as: name)
        }
        for name in portableArtistCacheNames(songs: songs, assetStore: assetStore).sorted() {
            guard !Task.isCancelled else { return nil }
            await includeCachedCover(named: name, as: name)
        }
        guard !Task.isCancelled else { return nil }
        return PortableArtworkCollection(
            customAssets: assets,
            cachedAssets: cachedAssets,
            references: references,
            rawBytes: usedBytes
        )
    }

    private nonisolated static func portableArtistCacheNames(songs: [Song], assetStore: MetadataAssetStore) -> Set<String> {
        let artists = computeAlbumsAndArtists(songs: songs, configuration: ArtistNameConfiguration.load(from: .standard)).artists
        var names = Set<String>()
        for artist in artists {
            var cacheIDs = [artist.id]
            if let reference = artist.thumbnailPath, !reference.isEmpty {
                cacheIDs.append(artist.id + "\u{1F}" + reference)
            }
            for id in cacheIDs {
                names.insert("artist/" + assetStore.expectedCoverFileName(for: "artist_\(id)"))
            }
        }
        return names
    }

    nonisolated static func restorePortableArtworkAssets(
        from data: Data,
        assetStore: MetadataAssetStore
    ) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        restorePortableArtworkAssets(snapshot, assetStore: assetStore)
    }

    private nonisolated static func restorePortableArtworkAssets(
        _ snapshot: Snapshot,
        assetStore: MetadataAssetStore
    ) {
        let hasCachedArtwork = snapshot.artworkCacheReferences != nil && snapshot.cachedArtworkAssets != nil
        let restored = restorePortableArtwork(
            customAssets: snapshot.artworkAssets ?? [:],
            cachedAssets: snapshot.cachedArtworkAssets ?? [:],
            references: snapshot.artworkCacheReferences ?? [:],
            eligibleNames: hasCachedArtwork
                ? portableArtworkEligibleNames(songs: snapshot.songs, assetStore: assetStore)
                : [],
            assetStore: assetStore
        )
        if restored.cached > 0 {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .primuseArtworkDidCache, object: nil, userInfo: ["all": true])
            }
        }
    }

    /// Cache names a portable cover may be installed under: each song's own
    /// cover plus its album and artist covers. Other references are ignored.
    nonisolated static func portableArtworkEligibleNames(
        songs: [Song],
        assetStore: MetadataAssetStore
    ) -> Set<String> {
        var eligibleNames = Set<String>()
        for song in songs {
            eligibleNames.insert(assetStore.expectedCoverFileName(for: song.id))
            if let albumID = song.albumID, !albumID.isEmpty {
                eligibleNames.insert("album/" + assetStore.expectedCoverFileName(for: "album_\(albumID)"))
            }
        }
        eligibleNames.formUnion(portableArtistCacheNames(songs: songs, assetStore: assetStore))
        return eligibleNames
    }

    /// Installs transported covers. Returns how many custom and cached covers
    /// were written; the caller decides when to announce them.
    @discardableResult
    nonisolated static func restorePortableArtwork(
        customAssets: [String: Data],
        cachedAssets: [String: Data],
        references: [String: String],
        eligibleNames: Set<String>,
        assetStore: MetadataAssetStore
    ) -> (custom: Int, cached: Int) {
        var custom = 0
        for (contentID, data) in customAssets {
            if assetStore.storeCustomArtworkSync(data, expectedContentID: contentID) != nil {
                custom += 1
            }
        }
        let byContent = Dictionary(grouping: references.filter { eligibleNames.contains($0.key) }, by: \.value)
        var cached = 0
        for (contentID, entries) in byContent {
            guard let data = cachedAssets[contentID] else { continue }
            if assetStore.installPortableCachedArtwork(data, contentID: contentID, referenceFileNames: entries.map(\.key)) {
                cached += 1
            }
        }
        return (custom, cached)
    }

    private func sortPlaylists() {
        allPlaylists.sort {
            PlaylistManualOrderPolicy.isOrderedBefore(
                .init(sortOrder: $0.sortOrder, updatedAt: $0.updatedAt),
                .init(sortOrder: $1.sortOrder, updatedAt: $1.updatedAt)
            )
        }
    }

    private func cleanPlaylistEntries() {
        for playlistID in playlistSongIDs.keys {
            let current = playlistSongIDs[playlistID] ?? []
            let kept = current.filter {
                songForSynchronization(id: $0) != nil || playlistPendingEntries[$0] != nil
            }
            // 没变就别写: 每写一次都会让观察者以为成员变了。
            if kept.count != current.count { playlistSongIDs[playlistID] = kept }
        }
        let referenced = Self.referencedPendingEntries(playlistPendingEntries, memberships: playlistSongIDs)
        if referenced.count != playlistPendingEntries.count { playlistPendingEntries = referenced }
    }

    /// 只留下仍被某个歌单引用的占位条目。
    nonisolated static func referencedPendingEntries(
        _ entries: [String: PlaylistPendingEntry],
        memberships: [String: [String]]
    ) -> [String: PlaylistPendingEntry] {
        guard !entries.isEmpty else { return entries }
        var referenced: [String: PlaylistPendingEntry] = [:]
        for members in memberships.values {
            for id in members where PlaylistPendingEntry.isPendingID(id) {
                if let entry = entries[id] { referenced[id] = entry }
            }
        }
        return referenced
    }

    private func cleanPlaybackHistoryEntries() {
        recentPlaybackSongIDs = recentPlaybackSongIDs.filter { songForSynchronization(id: $0) != nil }
    }

    /// CloudKit 逐条并进来的远端歌单只记账: 账本整份重写, 逐条写会让一批同步的
    /// 写入量随歌单数平方增长。`CloudKitSyncService` 在一批处理完、引擎游标落盘
    /// 之前调 `flushRemotePlaylistDurabilityLedger()`, 零散调用由短延迟兜底。
    /// 封面覆盖的远端写入要靠写盘结果决定回滚, 仍然当场写。
    private func scheduleRemotePlaylistDurabilityLedgerWrite() {
        remotePlaylistLedgerWritePending = true
        guard remotePlaylistLedgerWriteTask == nil else { return }
        remotePlaylistLedgerWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flushRemotePlaylistDurabilityLedger()
        }
    }

    /// 远端歌单还有没写进耐久账本的就立刻写。
    func flushRemotePlaylistDurabilityLedger() {
        guard remotePlaylistLedgerWritePending else { return }
        _ = persistPlaylistDurabilityLedger()
    }

    @discardableResult
    private func persistPlaylistDurabilityLedger() -> Bool {
        // S1: 发布前不写歌单耐久账本。返回 true 让调用方的回滚分支
        // 不被误触发, 写入在发布步骤补做。
        guard !isPreparing else {
            deferredPlaylistDurabilityWriteRequested = true
            return true
        }
        // 整份写, 远端攒着的也一并写进去; 写失败就留着待写, 下一次批末再试。
        remotePlaylistLedgerWriteTask?.cancel()
        remotePlaylistLedgerWriteTask = nil
        let ledger = PlaylistDurabilityLedger(
            playlists: allPlaylists.filter { !MirrorPlaylistIdentity.isMirrorPlaylist($0.id) },
            mirrorPlaylistSuppressions: hiddenMirrorPlaylists,
            artworkOverrides: allArtworkOverrides.isEmpty ? nil : allArtworkOverrides
        )
        do {
            let data = try encoder.encode(ledger)
            try data.write(to: playlistDurabilityURL, options: .atomic)
            remotePlaylistLedgerWritePending = false
            return true
        } catch {
            plog("⛔ Playlist durability write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 纯函数, 可跨 actor 调用 ── rebuildIndex 后台化时 nonisolated
    /// computeAlbumsAndArtists 也要用。
    nonisolated static func hashID(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for byte in hash.prefix(16) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 给单首歌就近填好 albumID / artistID, 不依赖整库 rebuildIndex。这样
    /// addSongs / replaceSong 同步路径里, song 加入 library 时 IDs 立刻
    /// 可读, 后台 rebuildIndex 只负责 derive albums/artists 集合。
    nonisolated static func resolvedArtistNames(
        for song: Song,
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> [String] {
        let names = song.effectiveArtistNames(configuration: configuration)
        return names.isEmpty ? [String(localized: "unknown_artist")] : names
    }

    /// `resolvedArtistIDs` 读到的全部歌曲字段; 配置在一趟遍历里不变。
    private struct ArtistResolutionFields: Hashable {
        let artistID: String?
        let artistName: String?
        let sourceArtistNames: [String]?

        init(_ song: Song) {
            artistID = song.artistID
            artistName = song.artistName
            sourceArtistNames = song.sourceArtistNames
        }
    }

    private nonisolated static func resolvedArtistIDs(
        for song: Song,
        configuration: ArtistNameConfiguration
    ) -> [String] {
        if let primaryID = song.artistID, !primaryID.isEmpty {
            var firstNativeName: String?
            var nativeNameCount = 0
            for value in song.sourceArtistNames ?? [] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if firstNativeName == nil { firstNativeName = trimmed }
                nativeNameCount += 1
                if nativeNameCount == 2 { break }
            }
            let rawName = song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = rawName.flatMap { $0.isEmpty ? nil : $0 }
                ?? firstNativeName
                ?? ""
            let containsConfiguredSeparator = configuration.separators.contains { separator in
                guard !separator.isEmpty else { return false }
                return candidate.range(
                    of: separator,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) != nil
            }
            if nativeNameCount <= 1, !containsConfiguredSeparator {
                return [primaryID]
            }
        }

        var seen = Set<String>()
        return resolvedArtistNames(for: song, configuration: configuration).compactMap { name in
            let id = hashID(ArtistIdentityPolicy.groupingKey(name))
            return seen.insert(id).inserted ? id : nil
        }
    }

    /// 整库一遍重算 id 时记住已经算过的：同样的艺人名只解析、哈希一次，同一张专辑的
    /// 身份只哈希一次。装载时 5 万首里艺人名与专辑各只有几千个，原来逐首重算。
    /// 只在一趟遍历里用（艺人名配置在一趟里不变）。
    final class DerivedIDMemo {
        struct ArtistNames: Hashable {
            let artistName: String?
            let sourceArtistNames: [String]?
        }

        let unknownArtist = String(localized: "unknown_artist")
        var artistIDs: [ArtistNames: String] = [:]
        var albumIDs: [AlbumGroupingIdentity: String] = [:]
    }

    nonisolated static func fillDerivedIDs(
        _ song: inout Song,
        configuration: ArtistNameConfiguration = .defaultValue,
        inferredAlbumArtist: String? = nil,
        memo: DerivedIDMemo? = nil,
        /// 调用方已对这一行跑过同一个修复且它没有改动任何东西（修复对它是恒等的），
        /// 再跑一遍必然还是原样：跳过。
        textRepairIsNoOp: Bool = false
    ) {
        let previousAlbumArtist = song.albumArtistName
        if !textRepairIsNoOp {
            MediaMetadataTextRepair.repairFileBackedMetadata(in: &song)
        }
        let correctedInference = inferredAlbumArtist == previousAlbumArtist
            ? song.albumArtistName : inferredAlbumArtist
        let unknownArtist = memo?.unknownArtist ?? String(localized: "unknown_artist")
        let artistNames = DerivedIDMemo.ArtistNames(
            artistName: song.artistName,
            sourceArtistNames: song.sourceArtistNames
        )
        if let cached = memo?.artistIDs[artistNames] {
            song.artistID = cached
        } else {
            let artist = resolvedArtistNames(
                for: song,
                configuration: configuration
            ).first ?? unknownArtist
            let artistID = hashID(ArtistIdentityPolicy.groupingKey(artist))
            song.artistID = artistID
            memo?.artistIDs[artistNames] = artistID
        }
        if let identity = AlbumGroupingPolicy.identity(
            albumTitle: song.albumTitle,
            albumArtistName: correctedInference ?? song.albumArtistName,
            trackArtistName: song.artistName,
            unknownArtistName: unknownArtist
        ) {
            if let cached = memo?.albumIDs[identity] {
                song.albumID = cached
            } else {
                let albumID = hashID("\(identity.artistName):\(identity.albumTitle)")
                song.albumID = albumID
                memo?.albumIDs[identity] = albumID
            }
        } else {
            song.albumID = nil
        }
    }

    nonisolated static func albumArtistInferenceTrack(
        _ song: Song,
        folders: AlbumArtistFolderIndex
    ) -> AlbumArtistInferencePolicy.Track {
        AlbumArtistInferencePolicy.Track(
            id: song.id,
            sourceID: song.sourceID,
            directory: folders.directory(sourceID: song.sourceID, filePath: song.filePath),
            albumTitle: song.albumTitle,
            albumArtistName: song.albumArtistName,
            trackArtistName: song.artistName
        )
    }

    /// 整库口径: 每个源的所有歌一起判定目录权威性与同目录同名专辑的归属。
    nonisolated static func inferredAlbumArtists(
        for songs: [Song],
        folders: AlbumArtistFolderIndex
    ) -> [String: String] {
        AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: songs.map { albumArtistInferenceTrack($0, folders: folders) }
        )
    }

    /// Candidates being inserted/replaced, judged against the library rows they
    /// will sit next to. `replaceSong` runs on every playback start (the
    /// duration correction), so the library is only pre-filtered by source and
    /// album title here; the policy then splits by folder, or by album title
    /// alone for a source whose paths carry none, and runs on the few rows that
    /// share a scope. The album title is the wider of the two keys, so
    /// pre-filtering by it feeds both splits. Directory authority still stops
    /// at the second distinct folder of a source.
    nonisolated static func inferredAlbumArtists(
        for candidates: [Song],
        among library: [Song],
        folders: AlbumArtistFolderIndex
    ) -> [String: String] {
        guard !candidates.isEmpty else { return [:] }
        var titlesBySource: [String: Set<String>] = [:]
        for song in candidates {
            guard let title = albumArtistInferenceTitle(song.albumTitle) else { continue }
            titlesBySource[song.sourceID, default: []].insert(title)
        }
        guard !titlesBySource.isEmpty else { return [:] }

        let candidateIDs = Set(candidates.map(\.id))
        let candidateTracks = candidates.map { albumArtistInferenceTrack($0, folders: folders) }
        var directoriesBySource: [String: Set<String>] = [:]
        var authoritative: Set<String> = []
        for track in candidateTracks {
            guard let directory = track.directory else { continue }
            directoriesBySource[track.sourceID, default: []].insert(directory)
        }

        var scoped: [AlbumArtistInferencePolicy.Track] = []
        for song in library where !candidateIDs.contains(song.id) {
            guard let titles = titlesBySource[song.sourceID] else { continue }
            let needsAuthority = !authoritative.contains(song.sourceID)
            let sharesTitle = albumArtistInferenceTitle(song.albumTitle)
                .map { titles.contains($0) } ?? false
            guard needsAuthority || sharesTitle else { continue }
            let track = albumArtistInferenceTrack(song, folders: folders)
            if needsAuthority, let directory = track.directory {
                directoriesBySource[song.sourceID, default: []].insert(directory)
                if (directoriesBySource[song.sourceID]?.count ?? 0) >= 2 {
                    authoritative.insert(song.sourceID)
                }
            }
            if sharesTitle {
                scoped.append(track)
            }
        }
        for (sourceID, directories) in directoriesBySource where directories.count >= 2 {
            authoritative.insert(sourceID)
        }
        scoped.append(contentsOf: candidateTracks)

        let inferred = AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: scoped,
            directoryAuthoritativeSourceIDs: authoritative
        )
        return inferred.filter { candidateIDs.contains($0.key) }
    }

    private nonisolated static func albumArtistInferenceTitle(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    /// 后台 derive albums / artists 集合。纯函数 ── 给定 songs 数组, 算出
    /// 派生集合, 不操作 self。
    /// `inferredAlbumArtists` 非空时必须是对同一批歌、同一份 `folders` 算出的推断。
    nonisolated static func computeAlbumsAndArtists(
        songs: [Song],
        configuration: ArtistNameConfiguration = .defaultValue,
        folders: AlbumArtistFolderIndex = .empty,
        inferredAlbumArtists: [String: String]? = nil
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String]) {
        computeAlbumsAndArtists(
            songs: songs,
            configuration: configuration,
            folders: folders,
            precomputedInference: inferredAlbumArtists,
            cancellationCheck: { false }
        )!
    }

    /// Task-aware counterpart used by the incremental rebuild worker. The old
    /// worker only checked cancellation after all filtering/grouping/sorting had
    /// completed, so every superseded task still consumed a full-library pass.
    private nonisolated static func computeAlbumsAndArtistsCancellable(
        songs: [Song],
        configuration: ArtistNameConfiguration,
        folders: AlbumArtistFolderIndex
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String])? {
        computeAlbumsAndArtists(
            songs: songs,
            configuration: configuration,
            folders: folders,
            cancellationCheck: { Task.isCancelled }
        )
    }

    private struct ArtistNameKey: Hashable {
        let artistName: String?
        let sourceArtistNames: [String]?
    }

    /// One pass per question instead of one per song: each album identity,
    /// album ID, artist name list and artist ID is worked out once and looked
    /// up by position afterwards. Songs are referred to by index, never copied
    /// into groups — at a few hundred thousand songs the former grouping held
    /// two extra copies of the library and hashed every song several times.
    private nonisolated static func computeAlbumsAndArtists(
        songs: [Song],
        configuration: ArtistNameConfiguration,
        folders: AlbumArtistFolderIndex,
        precomputedInference: [String: String]? = nil,
        cancellationCheck: () -> Bool
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String])? {
        guard !cancellationCheck() else { return nil }
        // 整库才看得见同一目录里的兄弟文件, 所以 album artist 的补全在这里先
        // 算一次, 下面两处 identity 与逐首 albumID 的对账都用同一份结果。
        let inferredAlbumArtists = precomputedInference
            ?? Self.inferredAlbumArtists(for: songs, folders: folders)
        guard !cancellationCheck() else { return nil }
        let unknownArtist = String(localized: "unknown_artist")

        var artistIDByName: [String: String] = [:]
        func artistID(named name: String) -> String {
            if let id = artistIDByName[name] { return id }
            let id = hashID(ArtistIdentityPolicy.groupingKey(name))
            artistIDByName[name] = id
            return id
        }

        // Albums ── 只 group 有 albumTitle 的歌曲。Every song gets its album's
        // slot (or -1); per album the first song supplies year/genre/source.
        var slotByIdentity: [AlbumGroupingIdentity: Int] = [:]
        var albumIdentities: [AlbumGroupingIdentity] = []
        var albumFirstSong: [Int] = []
        var albumSongCount: [Int] = []
        var albumDuration: [TimeInterval] = []
        var albumSlotBySong = [Int32](repeating: -1, count: songs.count)
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 256), cancellationCheck() { return nil }
            guard let identity = AlbumGroupingPolicy.identity(
                albumTitle: song.albumTitle,
                albumArtistName: inferredAlbumArtists[song.id] ?? song.albumArtistName,
                trackArtistName: song.artistName,
                unknownArtistName: unknownArtist
            ) else { continue }
            let slot: Int
            if let existing = slotByIdentity[identity] {
                slot = existing
            } else {
                slot = albumIdentities.count
                slotByIdentity[identity] = slot
                albumIdentities.append(identity)
                albumFirstSong.append(offset)
                albumSongCount.append(0)
                albumDuration.append(0)
            }
            albumSlotBySong[offset] = Int32(slot)
            albumSongCount[slot] += 1
            albumDuration[slot] += song.duration.sanitizedDuration
        }
        slotByIdentity = [:]
        guard !cancellationCheck() else { return nil }
        var albumIDBySlot: [String] = []
        var albumArtistIDBySlot: [String] = []
        albumIDBySlot.reserveCapacity(albumIdentities.count)
        albumArtistIDBySlot.reserveCapacity(albumIdentities.count)
        var albums: [Album] = []
        albums.reserveCapacity(albumIdentities.count)
        for (slot, identity) in albumIdentities.enumerated() {
            if slot.isMultiple(of: 64), cancellationCheck() { return nil }
            let albumID = hashID("\(identity.artistName):\(identity.albumTitle)")
            let albumArtistID = artistID(named: identity.artistName)
            albumIDBySlot.append(albumID)
            albumArtistIDBySlot.append(albumArtistID)
            let first = songs[albumFirstSong[slot]]
            albums.append(Album(
                id: albumID,
                title: identity.albumTitle,
                artistID: albumArtistID,
                artistName: identity.artistName,
                year: first.year,
                genre: first.genre,
                songCount: albumSongCount[slot],
                totalDuration: albumDuration[slot],
                sourceID: first.sourceID
            ))
        }
        albums.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        guard !cancellationCheck() else { return nil }

        // Artists ── every contributor participates while album grouping stays
        // tied to albumArtistName above. This lets a guest artist own the song
        // without incorrectly gaining the host album.
        var namesByKey: [ArtistNameKey: [String]] = [:]
        func artistNames(for song: Song) -> [String] {
            let key = ArtistNameKey(artistName: song.artistName, sourceArtistNames: song.sourceArtistNames)
            if let names = namesByKey[key] { return names }
            let names = resolvedArtistNames(for: song, configuration: configuration)
            namesByKey[key] = names
            return names
        }
        var artistSlotByID: [String: Int] = [:]
        var artistIDs: [String] = []
        var artistEntries: [[(name: String, song: Int32)]] = []
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 256), cancellationCheck() { return nil }
            for name in artistNames(for: song) {
                let id = artistID(named: name)
                let slot: Int
                if let existing = artistSlotByID[id] {
                    slot = existing
                } else {
                    slot = artistIDs.count
                    artistSlotByID[id] = slot
                    artistIDs.append(id)
                    artistEntries.append([])
                }
                artistEntries[slot].append((name, Int32(offset)))
            }
        }
        artistSlotByID = [:]
        guard !cancellationCheck() else { return nil }
        var artists: [Artist] = []
        artists.reserveCapacity(artistIDs.count)
        for (slot, id) in artistIDs.enumerated() {
            if slot.isMultiple(of: 64), cancellationCheck() { return nil }
            let entries = artistEntries[slot]
            guard let name = entries.first?.name else { continue }
            var albumIDs: Set<String> = []
            var thumbnailPath: String?
            for entry in entries {
                let songIndex = Int(entry.song)
                let albumSlot = Int(albumSlotBySong[songIndex])
                if albumSlot >= 0, albumArtistIDBySlot[albumSlot] == id {
                    albumIDs.insert(albumIDBySlot[albumSlot])
                }
                if thumbnailPath == nil {
                    let song = songs[songIndex]
                    if let automatic = AutomaticArtistArtworkReference.resolve(
                        song.artistArtworkFileName
                    ), let artwork = automatic.entry(forArtistName: name) {
                        thumbnailPath = SourceOwnedArtworkReference.make(
                            sourceID: song.sourceID,
                            reference: artwork.reference,
                            cacheDiscriminator: artwork.cacheDiscriminator
                        )
                    } else if artistNames(for: song).first.map({ artistID(named: $0) }) == id,
                              let reference = song.artistArtworkFileName {
                        thumbnailPath = SourceOwnedArtworkReference.make(
                            sourceID: song.sourceID,
                            reference: reference
                        )
                    }
                }
            }
            artists.append(Artist(
                id: id,
                name: name,
                albumCount: albumIDs.count,
                songCount: entries.count,
                thumbnailPath: thumbnailPath
            ))
        }
        artistEntries = []
        artists.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !cancellationCheck() else { return nil }

        // 逐首入库时只看得见自己那一行, albumID 可能停在未合并的旧值。整库
        // 知道正确答案, 这里把差异交回给调用方去落地。
        var albumIDCorrections: [String: String] = [:]
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 256), cancellationCheck() { return nil }
            let albumSlot = Int(albumSlotBySong[offset])
            guard albumSlot >= 0 else { continue }
            let expected = albumIDBySlot[albumSlot]
            if song.albumID != expected {
                albumIDCorrections[song.id] = expected
            }
        }
        guard !cancellationCheck() else { return nil }

        return (albums, artists, albumIDCorrections)
    }

    #if DEBUG
    /// Whether a row patch right now would write the shared library array in
    /// place, or copy it because something besides the library still holds
    /// it (scale harness). Copies when it would, as the patch would.
    func patchWouldWriteInPlaceForTesting() -> Bool {
        var working: [Song] = []
        let visibleShared = takeLibrarySongsForPatching(into: &working)
        let before = working.withUnsafeBufferPointer { $0.baseAddress }
        working.withUnsafeMutableBufferPointer { _ in }
        let after = working.withUnsafeBufferPointer { $0.baseAddress }
        songs = working
        if visibleShared { visibleSongs = working }
        return before == after
    }

    /// Which library arrays share one buffer (scale harness).
    var storageSharingSummaryForTesting: String {
        let visible = visibleSongsLookupReference.value
        return "visible=songs:\(sharesStorage(visible, songs)) music=visible:\(musicSongsSharesVisibleSongs) "
            + "songsRefUnique:\(isKnownUniquelyReferenced(&songsReference))"
    }

    /// Times the whole-library stages of one index rebuild on this library's
    /// current songs (scale harness); runs the stages off the main actor.
    func measureIndexRebuildStagesForTesting() async -> String {
        let songs = self.songs
        let configuration = artistNameConfiguration
        let folders = albumArtistFolders
        let disabled = disabledSourceIDs
        let classification = SpokenWordStore.shared.classificationSnapshot
        let previous = visibleSongs
        return await Task.detached(priority: .userInitiated) {
            func ms(_ start: Double) -> Int { Int((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
            var started = ProcessInfo.processInfo.systemUptime
            _ = Self.derivedIndexSignature(for: songs, configuration: configuration)
            let signature = ms(started)
            started = ProcessInfo.processInfo.systemUptime
            _ = Self.inferredAlbumArtists(for: songs, folders: folders)
            let inference = ms(started)
            started = ProcessInfo.processInfo.systemUptime
            let derived = Self.computeAlbumsAndArtists(songs: songs, configuration: configuration, folders: folders)
            let grouping = ms(started)
            started = ProcessInfo.processInfo.systemUptime
            _ = Self.prepareVisibleCache(
                songs: songs,
                albums: derived.albums,
                artists: derived.artists,
                artistNameConfiguration: configuration,
                disabledSourceIDs: disabled,
                spokenWordClassification: classification,
                previousVisibleSongs: previous
            )
            let visible = ms(started)
            return "signature=\(signature)ms inference=\(inference)ms albumsArtists=\(grouping)ms visibleCache=\(visible)ms albums=\(derived.albums.count) artists=\(derived.artists.count)"
        }.value
    }

    /// The former implementation, kept for the equivalence test.
    nonisolated static func computeAlbumsAndArtistsReference(
        songs: [Song],
        configuration: ArtistNameConfiguration = .defaultValue,
        folders: AlbumArtistFolderIndex = .empty
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String]) {
        computeAlbumsAndArtistsReferenceImplementation(
            songs: songs,
            configuration: configuration,
            folders: folders,
            cancellationCheck: { false }
        )!
    }

    private nonisolated static func computeAlbumsAndArtistsReferenceImplementation(
        songs: [Song],
        configuration: ArtistNameConfiguration,
        folders: AlbumArtistFolderIndex,
        cancellationCheck: () -> Bool
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String])? {
        guard !cancellationCheck() else { return nil }
        // 整库才看得见同一目录里的兄弟文件, 所以 album artist 的补全在这里先
        // 算一次, 下面两处 identity 与逐首 albumID 的对账都用同一份结果。
        let inferredAlbumArtists = Self.inferredAlbumArtists(for: songs, folders: folders)
        guard !cancellationCheck() else { return nil }
        let unknownArtist = String(localized: "unknown_artist")
        var resolvedNamesMemo: [DerivedIDMemo.ArtistNames: [String]] = [:]
        func artistNames(for song: Song) -> [String] {
            let key = DerivedIDMemo.ArtistNames(artistName: song.artistName, sourceArtistNames: song.sourceArtistNames)
            if let cached = resolvedNamesMemo[key] { return cached }
            let names = resolvedArtistNames(for: song, configuration: configuration)
            resolvedNamesMemo[key] = names
            return names
        }
        var artistIDMemo: [String: String] = [:]
        func artistID(named name: String) -> String {
            if let cached = artistIDMemo[name] { return cached }
            let id = hashID(ArtistIdentityPolicy.groupingKey(name))
            artistIDMemo[name] = id
            return id
        }
        var albumIDMemo: [AlbumGroupingIdentity: String] = [:]
        func albumID(for identity: AlbumGroupingIdentity) -> String {
            if let cached = albumIDMemo[identity] { return cached }
            let id = hashID("\(identity.artistName):\(identity.albumTitle)")
            albumIDMemo[identity] = id
            return id
        }

        // Albums ── 只 group 有 albumTitle 的歌曲。Use explicit loops so a
        // superseded request can stop inside the 10K-row phases, not merely
        // between them.
        var albumGroups: [AlbumGroupingIdentity: [Song]] = [:]
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 64), cancellationCheck() { return nil }
            guard let identity = AlbumGroupingPolicy.identity(
                albumTitle: song.albumTitle,
                albumArtistName: inferredAlbumArtists[song.id] ?? song.albumArtistName,
                trackArtistName: song.artistName,
                unknownArtistName: unknownArtist
            ) else { continue }
            albumGroups[identity, default: []].append(song)
        }
        guard !cancellationCheck() else { return nil }
        var albums: [Album] = []
        albums.reserveCapacity(albumGroups.count)
        for (offset, entry) in albumGroups.enumerated() {
            if offset.isMultiple(of: 16), cancellationCheck() { return nil }
            let identity = entry.key
            let groupedSongs = entry.value
            var totalDuration: TimeInterval = 0
            for (songOffset, song) in groupedSongs.enumerated() {
                if songOffset.isMultiple(of: 128), cancellationCheck() { return nil }
                totalDuration += song.duration.sanitizedDuration
            }
            albums.append(Album(
                id: albumID(for: identity),
                title: identity.albumTitle,
                artistID: artistID(named: identity.artistName),
                artistName: identity.artistName,
                year: groupedSongs.first?.year,
                genre: groupedSongs.first?.genre,
                songCount: groupedSongs.count,
                totalDuration: totalDuration,
                sourceID: groupedSongs.first?.sourceID
            ))
        }
        albums.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        guard !cancellationCheck() else { return nil }

        // Artists ── every contributor participates while album grouping stays
        // tied to albumArtistName above. This lets a guest artist own the song
        // without incorrectly gaining the host album.
        var artistGroups: [String: [(name: String, song: Song)]] = [:]
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 64), cancellationCheck() { return nil }
            for name in artistNames(for: song) {
                artistGroups[artistID(named: name), default: []].append((name, song))
            }
        }
        guard !cancellationCheck() else { return nil }
        var artists: [Artist] = []
        artists.reserveCapacity(artistGroups.count)
        for (offset, entry) in artistGroups.enumerated() {
            if offset.isMultiple(of: 16), cancellationCheck() { return nil }
            let id = entry.key
            let entries = entry.value
            guard let name = entries.first?.name else { continue }
            var albumIDs: Set<String> = []
            var thumbnailPath: String?
            for (songOffset, artistEntry) in entries.enumerated() {
                if songOffset.isMultiple(of: 64), cancellationCheck() { return nil }
                let song = artistEntry.song
                if let identity = AlbumGroupingPolicy.identity(
                    albumTitle: song.albumTitle,
                    albumArtistName: inferredAlbumArtists[song.id] ?? song.albumArtistName,
                    trackArtistName: song.artistName,
                    unknownArtistName: unknownArtist
                ), artistID(named: identity.artistName) == id {
                    albumIDs.insert(albumID(for: identity))
                }
                if thumbnailPath == nil {
                    if let automatic = AutomaticArtistArtworkReference.resolve(
                        song.artistArtworkFileName
                    ), let artwork = automatic.entry(forArtistName: name) {
                        thumbnailPath = SourceOwnedArtworkReference.make(
                            sourceID: song.sourceID,
                            reference: artwork.reference,
                            cacheDiscriminator: artwork.cacheDiscriminator
                        )
                    } else if artistNames(for: song).first.map({ artistID(named: $0) }) == id,
                    let reference = song.artistArtworkFileName {
                        thumbnailPath = SourceOwnedArtworkReference.make(
                            sourceID: song.sourceID,
                            reference: reference
                        )
                    }
                }
            }
            artists.append(Artist(
                id: id,
                name: name,
                albumCount: albumIDs.count,
                songCount: entries.count,
                thumbnailPath: thumbnailPath
            ))
        }
        artists.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !cancellationCheck() else { return nil }

        // 逐首入库时只看得见自己那一行, albumID 可能停在未合并的旧值。整库
        // 知道正确答案, 这里把差异交回给调用方去落地。
        var albumIDCorrections: [String: String] = [:]
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 64), cancellationCheck() { return nil }
            guard let identity = AlbumGroupingPolicy.identity(
                albumTitle: song.albumTitle,
                albumArtistName: inferredAlbumArtists[song.id] ?? song.albumArtistName,
                trackArtistName: song.artistName,
                unknownArtistName: unknownArtist
            ) else { continue }
            let expected = albumID(for: identity)
            if song.albumID != expected {
                albumIDCorrections[song.id] = expected
            }
        }
        guard !cancellationCheck() else { return nil }

        return (albums, artists, albumIDCorrections)
    }
    #endif

    /// Stable digest of every value consumed by `computeAlbumsAndArtists`.
    /// The derived cache is only a launch accelerator; any metadata, ordering,
    /// duration, locale, or schema change makes the digest differ and falls
    /// back to a full rebuild.
    private nonisolated static func derivedIndexSignature(
        for songs: [Song],
        configuration: ArtistNameConfiguration
    ) -> String {
        // Hashed in 64 KB chunks: the same byte stream as before, without a
        // buffer the size of every song's path and names put together (a few
        // hundred MB at a large library).
        var hasher = SHA256()
        var input = Data()
        input.reserveCapacity(1 << 16)
        appendStableString("derived-index-v6", to: &input)
        appendStableString(String(localized: "unknown_artist"), to: &input)
        appendStableString(configuration.cacheSignature, to: &input)

        for song in songs {
            if input.count >= 1 << 16 {
                hasher.update(data: input)
                input.removeAll(keepingCapacity: true)
            }
            appendStableString(song.artistName, to: &input)
            appendStableString(song.sourceArtistNames?.joined(separator: "\u{1F}"), to: &input)
            appendStableString(song.albumArtistName, to: &input)
            appendStableString(song.albumTitle, to: &input)
            appendStableInteger(song.year.map(Int64.init) ?? Int64.min, to: &input)
            appendStableString(song.genre, to: &input)
            appendStableInteger(song.duration.sanitizedDuration.bitPattern, to: &input)
            appendStableString(song.sourceID, to: &input)
            // 专辑归属现在还看文件所在目录。
            appendStableString(song.filePath, to: &input)
            appendStableString(song.artistArtworkFileName, to: &input)
        }
        hasher.update(data: input)

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func appendStableString(_ value: String?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendStableInteger(UInt64(value.utf8.count), to: &data)
        data.append(contentsOf: value.utf8)
    }

    private nonisolated static func appendStableInteger<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private struct DerivedIndexCache: Codable, Sendable {
        let signature: String
        let albums: [Album]
        let artists: [Artist]
    }

    private struct SnapshotFileFingerprint: Codable, Equatable, Sendable {
        let fileSize: Int64
        let modificationTimeNanoseconds: Int64
        let fileNumber: UInt64?
    }

    /// Disposable binary mirror used only for local launch. The portable JSON
    /// remains the interchange and recovery format. A matching JSON identity
    /// makes the non-song snapshot reusable; songs always come from the
    /// authoritative SQLite store, and a matching derived signature makes the
    /// cached album/artist arrays reusable.
    ///
    /// 格式 1 还带着整库歌曲: 每次落盘都要把二十多万首歌编进 plist(瞬时多占
    /// 三百多 MB、多写近 100MB), SQLite 修订号一变又整份解码后丢掉。格式 2
    /// 写入时总是清空 `snapshot.songs`。
    private struct StartupCache: Codable, Sendable {
        let formatVersion: Int
        let songStoreRevision: Int64?
        let snapshotFingerprint: SnapshotFileFingerprint?
        let snapshot: Snapshot
        let albums: [Album]
        let artists: [Artist]
        let derivedIndexSignature: String?

        init(
            formatVersion: Int,
            songStoreRevision: Int64?,
            snapshotFingerprint: SnapshotFileFingerprint?,
            snapshot: Snapshot,
            albums: [Album],
            artists: [Artist],
            derivedIndexSignature: String?
        ) {
            var songlessSnapshot = snapshot
            songlessSnapshot.songs = []
            self.formatVersion = formatVersion
            self.songStoreRevision = songStoreRevision
            self.snapshotFingerprint = snapshotFingerprint
            self.snapshot = songlessSnapshot
            self.albums = albums
            self.artists = artists
            self.derivedIndexSignature = derivedIndexSignature
        }
    }

    private struct Snapshot: Codable, Sendable {
        var songs: [Song]
        var playlists: [Playlist]
        var artworkOverrides: [LibraryArtworkOverride]? = nil
        var libraryReviews: [LibraryReview]? = nil
        /// 专辑 / 艺人简介。旧版本读不到这个键,合并时按 id 取新的那份。
        var libraryInsights: [LibraryInsightRecord]? = nil
        var automaticArtistArtworkCatalogs: [SourceArtistArtworkCatalog]? = nil
        /// Transport-only copies used by the Apple TV/LAN library snapshot.
        /// Normal local persistence always writes nil; images remain canonical
        /// in MetadataAssetStore's durable custom directory.
        var artworkAssets: [String: Data]? = nil
        var cachedArtworkAssets: [String: Data]? = nil
        var artworkCacheReferences: [String: String]? = nil
        var mirrorPlaylistSuppressions: [MirrorPlaylistSuppression]?
        /// 智能歌单。Optional 让旧 snapshot decode 不报错。
        var smartPlaylists: [SmartPlaylist]?
        var playlistSongIDs: [String: [String]]?
        /// 三方合并基线, 见 `MusicLibrary.playlistSyncBaseSongIDs`。Optional: 旧快照没有。
        var playlistSyncBaseSongIDs: [String: [String]]? = nil
        var recentPlaybackSongIDs: [String]?
        /// Account-or-source-prefixed identity keys ("<id>:<filePath>").
        /// Persisted via Array because Set isn't Codable-stable across
        /// SDK revs. Optional so old snapshots decode without it.
        var deletedSongIdentities: [String]?
        /// 每条墓碑的证据, 见 `MusicLibrary.deletedSongIdentityDetails`。
        /// Optional: 旧快照没有这张表, 解码照常; 旧版本的 App 写回快照时会把
        /// 它整个丢掉, 那些键退化成「无证据的旧墓碑」, 永不因扫描撤销 ——
        /// 安全退化, 不会把已删的歌放回来。
        var deletedSongIdentityDetails: [String: LibrarySongTombstoneDetail]? = nil
        /// CloudKit-pulled playlist entries waiting for a local song to
        /// match. Optional so old snapshots decode cleanly with no entries.
        var pendingPlaylistIdentities: [String: [PendingSongIdentity]]?
        var pendingHistoryIdentities: [PendingSongIdentity]?
        /// 歌单里置灰的占位条目。Optional: 旧快照没有; 旧版本写回时会丢掉它,
        /// 占位 id 随后被当成失效成员清掉 —— 退化成以前「没对上就不导入」的样子。
        var playlistPendingEntries: [String: PlaylistPendingEntry]? = nil
        /// True when `songs` was left out because the incremental song store
        /// holds them (a library far past what the iCloud / Apple TV transfer
        /// accepts). Such a snapshot is never handed to another device, and a
        /// load that cannot read the store will not persist over it. Sorts
        /// before `songs`, which the trailing-array encoder needs last.
        var separateSongStore: Bool? = nil
    }

    private struct PlaylistDurabilityLedger: Codable, Sendable {
        var playlists: [Playlist]
        var mirrorPlaylistSuppressions: [MirrorPlaylistSuppression]
        var artworkOverrides: [LibraryArtworkOverride]? = nil
    }
}

extension Notification.Name {
    /// Posted by MetadataAssetStore after lyrics are cached for a songID.
    /// userInfo: ["songID": String, "lyricsText": String]. MusicLibrary 监听
    /// 后, 把对应 song 的 lyricsText 字段更新写库 + 翻 FTS5 索引, 让歌词
    /// 全文搜索覆盖新写入的歌 (不止 backfill 跑过的老歌)。
    static let primuseLyricsDidCache = Notification.Name("primuse.lyricsDidCache")
    /// Posted once a background persistent search-index pass completes. An
    /// open search page reruns only its local query so newly indexed pinyin
    /// lyrics appear without issuing another Apple Music network request.
    static let primuseLibrarySearchIndexDidChange = Notification.Name("primuse.librarySearchIndexDidChange")
    /// 请求全屏打开 NowPlayingView。SearchView 点歌词命中结果时会触发, 让
    /// 用户立刻看到歌词上下文 + auto-seek 到命中行。
    static let primuseRequestShowNowPlaying = Notification.Name("primuse.requestShowNowPlaying")
    /// Apple Music 即将开始 / 接管系统侧播放。AudioPlayerService 收到要停掉
    /// 自家 player + 清 currentSong, 让 mini player 切换到 AppleMusicAccessory,
    /// audio session 让给 ApplicationMusicPlayer。
    static let primuseAppleMusicWillPlay = Notification.Name("primuse.appleMusicWillPlay")
    static let primusePlaylistsDidChange = Notification.Name("primuse.playlistsDidChange")
    static let primuseArtworkOverridesDidChange = Notification.Name("primuse.artworkOverridesDidChange")
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
    /// Posted when a stable Song ID moves to another provider path. Parallel
    /// `previousSongs` and `songs` arrays let cache owners migrate path-keyed
    /// files without touching Song-ID-keyed user metadata.
    static let primuseSongLocationChanged = Notification.Name("primuse.songLocationChanged")
    /// Posted when lyrics for a song are replaced by a user action such as
    /// manual scraping. Current playback surfaces (MacNowPlayingView,
    /// MacMiniPlayerView, DesktopLyricsView) reload their in-memory lyrics
    /// when their current song matches `note.object as? String`.
    static let primuseLyricsDidChange = Notification.Name("primuse.lyricsDidChange")
    /// Posted when artwork memory cache entries are invalidated. Visible
    /// `CachedArtworkView`s whose song/ref matches reload even when the
    /// deterministic cover file name did not change after scraping.
    static let primuseArtworkDidInvalidate = Notification.Name("primuse.artworkDidInvalidate")
    /// Posted after artwork data is persisted under a song ID. Matching
    /// placeholders and the active player retry their artwork lookup, while
    /// cover-driven theme extraction refreshes from the same cache entry.
    static let primuseArtworkDidCache = Notification.Name("primuse.artworkDidCache")
    /// Posted when the artwork content pool evicts cover bytes for capacity.
    /// `userInfo["refs"]` is the `Set<String>` of cover reference file names
    /// whose bytes are gone. Listeners must clear the matching
    /// `Song.coverArtFileName` so the backfill queue can read the cover again —
    /// a reference left pointing at deleted bytes reads as "this song already
    /// has a cover" and is never repaired.
    static let primuseArtworkContentEvicted = Notification.Name("primuse.artworkContentEvicted")
    /// Posted when songs leave the library because the user deleted them or a
    /// complete re-scan no longer sees their source files. `userInfo["songs"]`
    /// is the removed `[Song]`; listeners drop audio/artwork/lyrics caches.
    static let primuseSongsRemoved = Notification.Name("primuse.songsRemoved")
    /// Posted in addition to `primuseSourcesDidChange` when a source is
    /// soft-deleted locally. CloudKitSyncService persists a tombstone payload
    /// so a reset cursor or fresh device cannot interpret absence as restore.
    static let primuseSourceDidSoftDelete = Notification.Name("primuse.sourceDidSoftDelete")
    /// Posted after CloudKit confirms a MusicSource tombstone payload save.
    /// AppServices uses it to retire the corresponding durable cleanup step.
    static let primuseSourceTombstoneDidSync = Notification.Name("primuse.sourceTombstoneDidSync")
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
