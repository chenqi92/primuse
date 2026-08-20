import Foundation
import PrimuseKit
import CryptoKit
import GRDB

/// Observation's Equatable fast path is counterproductive for large model
/// arrays: comparing two `[Song]` values also compares lyricsText. Publishing
/// an immutable reference keeps the same observation semantics while making
/// the pre-notification check an O(1) identity change.
private final class LibraryArrayReference<Element: Sendable>: @unchecked Sendable {
    let value: [Element]

    init(_ value: [Element] = []) {
        self.value = value
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
}

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
        songLimit: Int = 120,
        albumLimit: Int = 10
    ) -> LibrarySearchOutput {
        let matcher = LibrarySearchMatcher(query: query)
        guard matcher.isValid else {
            return LibrarySearchOutput(songResults: [], albumResults: [], cache: cache)
        }

        var cache = cache
        let shouldSearchLyrics = includeLyrics && matcher.normalizedLength >= minimumLyricsQueryLength

        var rankedSongs: [LibrarySearchResult] = []
        rankedSongs.reserveCapacity(min(songs.count, songLimit * 2))
        for song in songs {
            guard !Task.isCancelled else { break }
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

            if includeMetadata {
                consider(song.title, boost: 30)
                consider(song.artistName, boost: 20)
                consider(song.albumTitle, boost: 14)
                consider(song.genre, boost: 6)
                consider(song.fileFormat.rawValue, boost: 2)
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
    private static let lyricsBatchSize = 12
    private static let lyricQueryMinimumLength = 3

    private let dbPool: DatabasePool?
    private var lastMetadataRevisionKey: String?
    private var preparedSongIDs: Set<String> = []
    private var isPreparing = false
    private var pendingPreparationSongs: [Song]?

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

    /// Runs at utility/background priority. Calls made while an older snapshot
    /// is being prepared replace the pending snapshot instead of starting a
    /// second transliteration job.
    func prepare(songs: [Song]) async {
        guard dbPool != nil else { return }
        if isPreparing {
            pendingPreparationSongs = songs
            return
        }

        isPreparing = true
        var currentSongs = songs
        while true {
            await synchronizeMetadata(songs: currentSongs, revisionKey: nil)
            await synchronizeLyrics(songs: currentSongs)

            if let pending = pendingPreparationSongs {
                pendingPreparationSongs = nil
                currentSongs = pending
            } else {
                break
            }
        }
        isPreparing = false

        await MainActor.run {
            NotificationCenter.default.post(
                name: .primuseLibrarySearchIndexDidChange,
                object: nil
            )
        }
    }

    /// Index a newly written lyric immediately. The normal background pass
    /// remains the source of truth and repairs any interrupted update later.
    func refreshLyrics(songID: String, fallbackText: String?) async {
        guard let pool = dbPool else { return }
        let store = MetadataAssetStore.shared
        let signature = store.cachedLyricsSearchSignature(songID: songID, lyricsFileName: nil)
        let lines = store.cachedLyricsForSearch(songID: songID, lyricsFileName: nil)
            ?? Self.lines(fromPlainText: fallbackText)
        guard let lines, !lines.isEmpty else { return }
        let resolvedSignature = signature ?? "inline:\(Self.digest(fallbackText ?? ""))"
        let document = Self.makeLyricsDocument(
            songID: songID,
            signature: resolvedSignature,
            lines: lines
        )
        do {
            try Self.upsertLyricsDocuments([document], in: pool)
        } catch {
            plog("🔎 Failed to refresh lyrics index: \(error.localizedDescription)")
        }
    }

    /// Search a fully indexed snapshot. Metadata synchronization is cheap on
    /// normal queries because stable fingerprints avoid both writes and ICU.
    func search(
        query: String,
        songs: [Song],
        albums: [Album],
        metadataRevisionKey: String,
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

        await synchronizeMetadata(songs: songs, revisionKey: metadataRevisionKey)

        do {
            let songByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
            var metadataIDs: [String] = []
            var seenMetadata = Set<String>()

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

            var lyricHits: [LyricsHit] = []
            var seenLyrics = Set<String>()
            if trimmed.count >= Self.lyricQueryMinimumLength {
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
            ranked.reserveCapacity(min(songLimit * 2, metadataIDs.count + lyricHits.count))
            var resultIDs = Set<String>()
            for (offset, id) in metadataIDs.enumerated() {
                guard let song = songByID[id] else { continue }
                let literal = Self.metadataContainsLiteral(song, query: trimmed)
                ranked.append(LibrarySearchResult(
                    song: song,
                    matchKind: literal ? .metadata : .fuzzy,
                    score: max(100, 220 - offset),
                    lyricSnippet: nil,
                    lyricTimestamp: nil
                ))
                resultIDs.insert(id)
            }
            for (offset, hit) in lyricHits.enumerated() where !resultIDs.contains(hit.songID) {
                guard let song = songByID[hit.songID] else { continue }
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
                guard let albumID = songByID[id]?.albumID,
                      !albumIDs.contains(albumID),
                      let album = albumByID[albumID] else { continue }
                albumIDs.insert(albumID)
                albumResults.append(album)
                if albumResults.count == albumLimit { break }
            }

            let lyricsComplete = preparedSongIDs.count == songs.count
                && songs.allSatisfy { preparedSongIDs.contains($0.id) }
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

    private func synchronizeMetadata(songs: [Song], revisionKey: String?) async {
        guard let pool = dbPool else { return }
        if let revisionKey, lastMetadataRevisionKey == revisionKey { return }

        do {
            let existing = try Self.metadataStates(in: pool)
            let songIDs = Set(songs.map(\.id))
            var changed: [(song: Song, fingerprint: String, stateID: Int64?)] = []
            changed.reserveCapacity(min(songs.count, 256))
            for song in songs {
                let fingerprint = Self.metadataFingerprint(song)
                if existing[song.id]?.fingerprint != fingerprint {
                    changed.append((song, fingerprint, existing[song.id]?.id))
                }
            }
            let removed = existing.filter { !songIDs.contains($0.key) }.map(\.value.id)
            let metadataChanges = changed

            if !metadataChanges.isEmpty || !removed.isEmpty {
                try await pool.write { db in
                    for id in removed {
                        try db.execute(sql: "DELETE FROM metadataLexicalFts WHERE rowid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM metadataPinyinFts WHERE rowid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM metadataPinyinSubstringFts WHERE rowid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM metadataSearchState WHERE id = ?", arguments: [id])
                    }
                    for change in metadataChanges {
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
                        } else {
                            try db.execute(
                                sql: "INSERT INTO metadataSearchState (songID, fingerprint) VALUES (?, ?)",
                                arguments: [change.song.id, change.fingerprint]
                            )
                            stateID = db.lastInsertedRowID
                        }
                        try db.execute(
                            sql: "INSERT INTO metadataLexicalFts (rowid, title, artist, album, genre) VALUES (?, ?, ?, ?, ?)",
                            arguments: [stateID, change.song.title, change.song.artistName ?? "", change.song.albumTitle ?? "", change.song.genre ?? ""]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPinyinFts (rowid, title, artist, album, initials, compact) VALUES (?, ?, ?, ?, ?, ?)",
                            arguments: [stateID, document.title, document.artist, document.album, document.initials, document.compact]
                        )
                        try db.execute(
                            sql: "INSERT INTO metadataPinyinSubstringFts (rowid, compact, initials) VALUES (?, ?, ?)",
                            arguments: [stateID, document.compact, document.initials]
                        )
                    }
                }
            }
            lastMetadataRevisionKey = revisionKey
        } catch is CancellationError {
            // Search requests and metadata snapshots are intentionally
            // replaceable. GRDB observes the parent task cancellation while
            // writing and rolls the transaction back; the next snapshot will
            // retry it. Do not report this normal hand-off as an index error.
            return
        } catch {
            plog("🔎 Metadata index sync failed: \(error.localizedDescription)")
        }
    }

    private func synchronizeLyrics(songs: [Song]) async {
        guard let pool = dbPool else { return }
        do {
            var existing = try Self.lyricsStates(in: pool)
            let visibleIDs = Set(songs.map(\.id))
            let store = MetadataAssetStore.shared

            for start in stride(from: 0, to: songs.count, by: Self.lyricsBatchSize) {
                if Task.isCancelled { return }
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

                // Let interactive FTS reads interleave with the first build,
                // and keep one-time indexing from becoming sustained CPU load.
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(18))
            }

            let staleIDs = existing
                .filter { !visibleIDs.contains($0.key) }
                .map(\.value.id)
                .filter { $0 >= 0 }
            if !staleIDs.isEmpty {
                try Self.removeLyricsDocuments(ids: staleIDs, in: pool)
            }
            preparedSongIDs = visibleIDs
        } catch {
            plog("🔎 Lyrics index sync failed: \(error.localizedDescription)")
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
        let artistSource = song.artistName ?? ""
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
            song.albumTitle ?? "",
            song.genre ?? "",
            song.titlePinyin ?? "",
            song.artistPinyin ?? "",
            song.albumPinyin ?? ""
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
        [song.title, song.artistName, song.albumTitle, song.genre]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
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

struct MusicDiscoveryResult: Identifiable, Sendable {
    let song: Song
    let score: Double
    let reasons: [MusicDiscoveryReason]

    var id: String { song.id }
    var primaryReason: MusicDiscoveryReason { reasons.first ?? .libraryPick }
}

enum MusicDiscoveryEngine {
    struct RecommendationInput: Sendable {
        let songs: [Song]
        let recentWeekIDs: Set<String>
        let recentMonthIDs: Set<String>
        let topArtists: Set<String>
        let seedIDs: [String]
        let now: Date
    }

    @MainActor
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

    @MainActor
    static func recommendationInput(
        in library: MusicLibrary,
        history: PlayHistoryStore = .shared,
        now: Date = Date()
    ) -> RecommendationInput {
        let songs = library.visibleSongs.filteredPlayable()
        let songIDs = Set(songs.map(\.id))
        var seedIDs: [String] = []
        var seenSeedIDs = Set<String>()

        for item in history.topSongs(in: .year, limit: 12)
        where songIDs.contains(item.id) && seenSeedIDs.insert(item.id).inserted {
            seedIDs.append(item.id)
        }
        for song in library.recentlyPlayedSongs(limit: 12)
        where songIDs.contains(song.id) && seenSeedIDs.insert(song.id).inserted {
            seedIDs.append(song.id)
        }

        return RecommendationInput(
            songs: songs,
            recentWeekIDs: Set(history.entries(in: .week, now: now).map(\.songID)),
            recentMonthIDs: Set(history.entries(in: .month, now: now).map(\.songID)),
            topArtists: Set(history.topArtists(in: .month, limit: 6).map { normalized($0.title) }),
            seedIDs: seedIDs,
            now: now
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
        limit: Int
    ) -> [MusicDiscoveryResult] {
        let songs = input.songs
        guard !songs.isEmpty else { return [] }

        // 10K+ 曲库里，推荐算法的热点不是打分本身，而是内层循环反复做
        // String.folding / 路径拆分。先把每首歌的比较特征归一化一次，
        // 后续 candidate × seed 只做普通值比较。
        let normalizedSongs = songs.map(NormalizedSong.init)
        let byID = Dictionary(
            normalizedSongs.map { ($0.song.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let seeds = input.seedIDs.compactMap { byID[$0] }

        guard !seeds.isEmpty else {
            return coldStartRecommendations(from: songs, excluding: [], limit: limit, now: input.now)
        }

        var results = normalizedSongs.compactMap { candidate -> MusicDiscoveryResult? in
            let song = candidate.song
            guard !input.recentWeekIDs.contains(song.id) else { return nil }

            var best = Match(score: 0, reasons: [])
            for seed in seeds where seed.song.id != song.id {
                let match = similarity(between: seed, and: candidate)
                if match.score > best.score { best = match }
            }

            var score = best.score
            var reasons = best.reasons

            if let artist = candidate.artistName, input.topArtists.contains(artist) {
                score += 18
                append(.recentFavorite, to: &reasons)
            }

            if !input.recentMonthIDs.contains(song.id) {
                score += 12
                append(.notRecentlyPlayed, to: &reasons)
            }

            if input.now.timeIntervalSince(song.dateAdded) <= 30 * 24 * 60 * 60 {
                score += 8
                append(.newToLibrary, to: &reasons)
            }

            if song.coverArtFileName?.isEmpty == false {
                score += 3
            }

            guard score >= 16 else { return nil }
            if reasons.isEmpty { reasons = [.libraryPick] }
            return MusicDiscoveryResult(song: song, score: score, reasons: reasons)
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.song.dateAdded > rhs.song.dateAdded
        }

        var unique = uniqued(results).prefix(limit).map { $0 }
        if unique.count < limit {
            let excluded = Set(unique.map(\.song.id)).union(input.recentWeekIDs)
            unique.append(contentsOf: coldStartRecommendations(
                from: songs,
                excluding: excluded,
                limit: limit - unique.count,
                now: input.now
            ))
        }
        return unique
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
        limit: Int = 12
    ) -> [MusicDiscoveryResult] {
        recommendations(from: input, limit: max(limit * 3, limit))
            .sorted { lhs, rhs in
                let left = lhs.score + stableDailyNoise(lhs.song.id, now: input.now) * 8
                let right = rhs.score + stableDailyNoise(rhs.song.id, now: input.now) * 8
                if left != right { return left > right }
                return lhs.song.title.localizedCompare(rhs.song.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
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

        // Precompute everything that doesn't change across the up-to-`limit`
        // greedy iterations: the candidate pool, a normalized feature index
        // (so each song's artist/album/genre/folder strings are folded once
        // instead of O(limit×N) times), the recent-month set, and the
        // fallback list. The original re-ran `similarSongs` (full O(N) scan +
        // per-candidate String.folding + a fresh `history.entries` Set) and
        // `dailyRecommendations` (a 3×limit full-library scoring pass) on every
        // iteration — multiple seconds on a 10k-song library, all on the main
        // actor. Now the per-iteration work is a single O(N) pass over cached
        // numbers/strings.
        let candidates = library.visibleSongs.filteredPlayable()
        let recentMonthIDs = Set(history.entries(in: .month, now: now).map(\.songID))
        let features = candidates.map { NormalizedSong(song: $0) }
        let seedFeature = NormalizedSong(song: seed)

        var output = [
            MusicDiscoveryResult(song: seed, score: .greatestFiniteMagnitude, reasons: [.libraryPick])
        ]
        var usedIDs: Set<String> = [seed.id]
        var cursor = seedFeature

        // Fallback recommendations don't depend on the moving cursor, so build
        // them once and just skip already-used songs as the queue grows.
        let fallbacks = dailyRecommendations(in: library, history: history, limit: 24, now: now)

        while output.count < limit {
            var best: (result: MusicDiscoveryResult, sortScore: Double, title: String)?
            for candidate in features {
                guard !usedIDs.contains(candidate.song.id), candidate.song.id != cursor.song.id else { continue }
                var match = similarity(between: cursor, and: candidate)
                guard match.score > 0 else { continue }
                if !recentMonthIDs.contains(candidate.song.id) {
                    match.score += 4
                    append(.notRecentlyPlayed, to: &match.reasons)
                }
                let sortScore = match.score + stableDailyNoise(candidate.song.id, now: now) * 3
                let isBetter: Bool
                if let current = best {
                    if sortScore != current.sortScore {
                        isBetter = sortScore > current.sortScore
                    } else {
                        isBetter = candidate.song.title.localizedCompare(current.title) == .orderedAscending
                    }
                } else {
                    isBetter = true
                }
                if isBetter {
                    best = (
                        MusicDiscoveryResult(song: candidate.song, score: match.score, reasons: match.reasons),
                        sortScore,
                        candidate.song.title
                    )
                }
            }

            if let next = best {
                output.append(next.result)
                usedIDs.insert(next.result.song.id)
                cursor = NormalizedSong(song: next.result.song)
                continue
            }

            guard let fallback = fallbacks.first(where: { !usedIDs.contains($0.song.id) }) else {
                break
            }
            output.append(fallback)
            usedIDs.insert(fallback.song.id)
            cursor = NormalizedSong(song: fallback.song)
        }

        return output
    }

    /// Per-song feature cache for `songRadio`'s inner loop: all the normalized
    /// (case/diacritic-folded) strings `similarity` needs, computed once so the
    /// greedy radio walk never re-folds the same song. Mirrors exactly the
    /// fields and normalization used by `similarity(between:and:)`.
    private struct NormalizedSong {
        let song: Song
        let albumID: String?
        let albumTitle: String?
        let artistID: String?
        let artistName: String?
        let genre: String?
        let year: Int?
        let duration: TimeInterval
        let sourceID: String
        let folder: String

        init(song: Song) {
            self.song = song
            albumID = Self.normEmptyable(song.albumID)
            albumTitle = Self.normEmptyable(song.albumTitle)
            artistID = Self.normEmptyable(song.artistID)
            artistName = Self.normEmptyable(song.artistName)
            genre = Self.normEmptyable(song.genre)
            year = song.year
            duration = song.duration
            sourceID = song.sourceID
            folder = MusicDiscoveryEngine.parentFolder(song.filePath)
        }

        /// Pre-normalize for `nonEmptyEqual`, which treats empty results as
        /// non-matching. nil here means "won't ever match" — keeps the equality
        /// checks branch-free in the hot loop.
        private static func normEmptyable(_ text: String?) -> String? {
            guard let text else { return nil }
            let value = MusicDiscoveryEngine.normalized(text)
            return value.isEmpty ? nil : value
        }
    }

    /// Same scoring as `similarity(between:and:)` but over pre-normalized
    /// features so no `String.folding` runs in `songRadio`'s inner loop.
    private static func similarity(between seed: NormalizedSong, and candidate: NormalizedSong) -> Match {
        var score: Double = 0
        var reasons: [MusicDiscoveryReason] = []

        if normEqual(seed.albumID, candidate.albumID) || normEqual(seed.albumTitle, candidate.albumTitle) {
            score += 46
            append(.sameAlbum, to: &reasons)
        }

        if normEqual(seed.artistID, candidate.artistID) || normEqual(seed.artistName, candidate.artistName) {
            score += 40
            append(.sameArtist, to: &reasons)
        }

        if normEqual(seed.genre, candidate.genre) {
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
           !seed.folder.isEmpty,
           seed.folder == candidate.folder {
            score += 12
            append(.sameFolder, to: &reasons)
        }

        return Match(score: score, reasons: reasons)
    }

    /// Pre-normalized variant of `nonEmptyEqual` — both sides are already
    /// folded (and nil when empty), so this is a plain comparison.
    private static func normEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs == rhs
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

    // `nonisolated` — pure string helpers with no actor state. Lets the
    // `NormalizedSong` feature cache pre-fold strings without hopping the
    // main actor (and keeps the door open for a future detached radio build).
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
    private var songsReference = LibraryArrayReference<Song>()
    private(set) var songs: [Song] {
        get { songsReference.value }
        set {
            let previous = songsReference
            songsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
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
    /// Backing storage that includes soft-deleted entries. UI-facing
    /// `playlists` filters this down.
    private(set) var allPlaylists: [Playlist] = []
    private var artworkOverridesByOwner: [String: LibraryArtworkOverride] = [:]
    /// Lightweight invalidation token for album/playlist artwork surfaces.
    /// It is intentionally separate from song and playlist collection
    /// revisions so choosing a cover does not rebuild unrelated lists.
    private(set) var artworkOverrideRevision: Int = 0
    var allArtworkOverrides: [LibraryArtworkOverride] {
        artworkOverridesByOwner.values.sorted { $0.id < $1.id }
    }
    private var mirrorPlaylistSuppressions: [String: MirrorPlaylistSuppression] = [:]
    /// Live (non-deleted) playlists for normal UI use. Apple Music's library
    /// and user-playlist mirrors are read-only snapshots, so keep them stored
    /// for fast re-enable but hide them whenever Apple Music library sync or
    /// its virtual source is disabled.
    var playlists: [Playlist] {
        let hidesAppleMusicMirrors = !appleMusicLibrarySyncEnabled
            || disabledSourceIDs.contains(AppleMusicLibraryIdentity.sourceID)
        return allPlaylists.filter { playlist in
            guard !playlist.isDeleted else { return false }
            guard !isMirrorPlaylistSuppressed(playlist.id) else { return false }
            return !hidesAppleMusicMirrors
                || !AppleMusicLibraryIdentity.isMirrorPlaylist(playlist.id)
        }
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
    /// Mirrors the Apple Music library-sync preference as observable state.
    /// Reading UserDefaults directly from `playlists` would not invalidate
    /// SwiftUI views when the macOS settings toggle changes.
    private(set) var appleMusicLibrarySyncEnabled =
        AppleMusicLibraryPreferences.syncUserLibraryEnabled

    /// Cached filtered views — rebuilt only when songs/disabled state change
    private var visibleSongsReference = LibraryArrayReference<Song>()
    private(set) var visibleSongs: [Song] {
        get { visibleSongsReference.value }
        set {
            let previous = visibleSongsReference
            visibleSongsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
    }
    private var visibleAlbumsReference = LibraryArrayReference<Album>()
    private(set) var visibleAlbums: [Album] {
        get { visibleAlbumsReference.value }
        set {
            let previous = visibleAlbumsReference
            visibleAlbumsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
    }
    private var visibleArtistsReference = LibraryArrayReference<Artist>()
    private(set) var visibleArtists: [Artist] {
        get { visibleArtistsReference.value }
        set {
            let previous = visibleArtistsReference
            visibleArtistsReference = LibraryArrayReference(newValue)
            LibraryArrayReclaimer.release(previous)
        }
    }
    @ObservationIgnored private var songIndexByID: [String: Int] = [:]
    @ObservationIgnored private var visibleSongIndexByID: [String: Int] = [:]
    @ObservationIgnored private var visibleSongByID: [String: Song] = [:]
    @ObservationIgnored private var visibleSongsBySourceID: [String: [Song]] = [:]
    /// Source cards are re-rendered frequently while scanning/backfilling.
    /// Keep the source grouping beside the other visible caches so those
    /// renders don't filter a 10K+ song array once per card per frame.
    @ObservationIgnored private var visiblePlayableSongsBySourceID: [String: [Song]] = [:]
    /// Sidebar counters need all visible songs, not just playable ones. Keeping
    /// counts here avoids one full-library filter per source on every sidebar
    /// body evaluation.
    @ObservationIgnored private var visibleSongCountBySourceID: [String: Int] = [:]

    private struct PreparedVisibleCache: Sendable {
        let songs: [Song]
        let albums: [Album]
        let artists: [Artist]
        let allSongIndexByID: [String: Int]
        let songIndexByID: [String: Int]
        let songByID: [String: Song]
        let songsBySourceID: [String: [Song]]
        let playableBySourceID: [String: [Song]]
        let countBySourceID: [String: Int]
        let orderedIDsChanged: Bool
    }
    /// Changes only when the ordered set of visible song IDs changes. Views
    /// that cache a sorted song list observe this lightweight counter instead
    /// of comparing `[Song]`; a derived `Song` equality also walks lyricsText,
    /// which made a 10K-song library block AttributeGraph for several seconds.
    private(set) var visibleSongCollectionRevision: Int = 0
    private(set) var searchRevision: Int = 0
    /// Lyrics cache files are searched directly by `LibrarySearchWorker`.
    /// Keep their invalidation separate from structural library revisions so
    /// each scraped lyric does not refresh Home and other whole-library views.
    private(set) var lyricsSearchRevision: Int = 0

    private let snapshotURL: URL
    private let backupSnapshotURL: URL
    private let startupCacheURL: URL
    private let derivedIndexCacheURL: URL
    private let playlistDurabilityURL: URL
    private let playlistSyncWriterID: String
    /// Canonical device-local song rows. JSON is retained as an interoperable
    /// iCloud/Apple TV snapshot, but routine scan/backfill writes go here.
    @ObservationIgnored private let songStore: IncrementalSongStore?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    @ObservationIgnored private var persistenceBlockedByCorruption = false
    @ObservationIgnored private var derivedIndexSignature: String?
    private static let startupCacheFormatVersion = 1
    private static let loadedSongMigrationVersion = 2

    func updateDisabledSourceIDs(_ ids: Set<String>) {
        guard disabledSourceIDs != ids else { return }
        disabledSourceIDs = ids
        rebuildVisibleCache()
    }

    func updateAppleMusicLibrarySyncEnabled(_ enabled: Bool) {
        guard appleMusicLibrarySyncEnabled != enabled else { return }
        appleMusicLibrarySyncEnabled = enabled
        playlistCollectionRevision &+= 1
    }

    var songCount: Int { visibleSongs.count }
    var albumCount: Int { visibleAlbums.count }
    var artistCount: Int { visibleArtists.count }

    private func rebuildVisibleCache() {
        let prepared = Self.prepareVisibleCache(
            songs: songs,
            albums: albums,
            artists: artists,
            disabledSourceIDs: disabledSourceIDs,
            previousVisibleSongs: visibleSongs
        )
        applyPreparedVisibleCache(prepared)
    }

    private func applyPreparedVisibleCache(_ prepared: PreparedVisibleCache) {
        visibleSongs = prepared.songs
        visibleAlbums = prepared.albums
        visibleArtists = prepared.artists
        songIndexByID = prepared.allSongIndexByID
        visibleSongIndexByID = prepared.songIndexByID
        visibleSongByID = prepared.songByID
        visibleSongsBySourceID = prepared.songsBySourceID
        visiblePlayableSongsBySourceID = prepared.playableBySourceID
        visibleSongCountBySourceID = prepared.countBySourceID
        if prepared.orderedIDsChanged {
            visibleSongCollectionRevision &+= 1
        }
    }

    private nonisolated static func prepareVisibleCache(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        disabledSourceIDs: Set<String>,
        previousVisibleSongs: [Song]
    ) -> PreparedVisibleCache {
        let nextVisibleSongs: [Song]
        let nextVisibleAlbums: [Album]
        let nextVisibleArtists: [Artist]
        if disabledSourceIDs.isEmpty {
            nextVisibleSongs = songs
            nextVisibleAlbums = albums
            nextVisibleArtists = artists
        } else {
            nextVisibleSongs = songs.filter { !disabledSourceIDs.contains($0.sourceID) }
            let visibleAlbumIDs = Set(nextVisibleSongs.compactMap(\.albumID))
            nextVisibleAlbums = albums.filter { visibleAlbumIDs.contains($0.id) }
            let visibleArtistIDs = Set(nextVisibleSongs.compactMap(\.artistID))
            nextVisibleArtists = artists.filter { visibleArtistIDs.contains($0.id) }
        }
        let lookups = makeVisibleLookups(songs: nextVisibleSongs)
        return PreparedVisibleCache(
            songs: nextVisibleSongs,
            albums: nextVisibleAlbums,
            artists: nextVisibleArtists,
            allSongIndexByID: disabledSourceIDs.isEmpty
                ? lookups.indexByID
                : makeSongIndex(songs),
            songIndexByID: lookups.indexByID,
            songByID: lookups.songByID,
            songsBySourceID: lookups.songsBySourceID,
            playableBySourceID: lookups.playableBySourceID,
            countBySourceID: lookups.countBySourceID,
            orderedIDsChanged: !haveSameOrderedIDs(previousVisibleSongs, nextVisibleSongs)
        )
    }

    private nonisolated static func haveSameOrderedIDs(_ lhs: [Song], _ rhs: [Song]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id }
    }

    private nonisolated static func makeVisibleLookups(
        songs: [Song]
    ) -> (
        indexByID: [String: Int],
        songByID: [String: Song],
        songsBySourceID: [String: [Song]],
        playableBySourceID: [String: [Song]],
        countBySourceID: [String: Int]
    ) {
        var indexByID: [String: Int] = [:]
        var songByID: [String: Song] = [:]
        var songsBySourceID: [String: [Song]] = [:]
        var playableBySourceID: [String: [Song]] = [:]
        var countBySourceID: [String: Int] = [:]
        for (index, song) in songs.enumerated() {
            indexByID[song.id] = index
            if songByID[song.id] == nil { songByID[song.id] = song }
            songsBySourceID[song.sourceID, default: []].append(song)
            countBySourceID[song.sourceID, default: 0] += 1
            if song.isPlayable {
                playableBySourceID[song.sourceID, default: []].append(song)
            }
        }
        return (indexByID, songByID, songsBySourceID, playableBySourceID, countBySourceID)
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

    init(
        fileManager: FileManager = .default,
        disabledSourceIDs: Set<String> = []
    ) {
        // tvOS 只允许写 Caches / tmp;须与 LibrarySnapshotSync / SourcesStore 同目录。
        #if os(tvOS)
        let appSupport = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let appSupport = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        snapshotURL = directory.appendingPathComponent("library-cache.json")
        backupSnapshotURL = directory.appendingPathComponent("library-cache.backup.json")
        startupCacheURL = directory.appendingPathComponent("library-startup-cache.plist")
        derivedIndexCacheURL = directory.appendingPathComponent("library-derived-index.plist")
        playlistDurabilityURL = directory.appendingPathComponent("playlist-durability.json")
        let writerDefaultsKey = "primuse.playlist.syncWriterID"
        if let existingWriterID = UserDefaults.standard.string(forKey: writerDefaultsKey),
           !existingWriterID.isEmpty {
            playlistSyncWriterID = existingWriterID
        } else {
            let newWriterID = UUID().uuidString
            UserDefaults.standard.set(newWriterID, forKey: writerDefaultsKey)
            playlistSyncWriterID = newWriterID
        }
        do {
            songStore = try IncrementalSongStore(
                path: directory.appendingPathComponent("library-songs.sqlite").path
            )
        } catch {
            songStore = nil
            plog("⚠️ Incremental song store unavailable; using JSON fallback: \(error.localizedDescription)")
        }
        self.disabledSourceIDs = disabledSourceIDs
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSnapshot()

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
            Task(priority: .utility) {
                await LibrarySearchIndex.shared.refreshLyrics(
                    songID: songID,
                    fallbackText: fallbackText
                )
            }
            Task { @MainActor in
                self.scheduleLyricsSearchInvalidation()
            }
        }
    }

    private static let pendingLyricsFlushDelay: TimeInterval = 0.5
    /// 等待写入的 (songID → 最新 lyricsText)。同一 songID 多次 schedule 后,
    /// flush 时只用最新值, 中间快照丢弃。
    private var pendingLyricsText: [String: String] = [:]
    private var pendingLyricsFlushTask: Task<Void, Never>?
    private var lyricsSearchInvalidationTask: Task<Void, Never>?
    private var deferredLyricsSearchInvalidation = false
    private var isDeferringSceneTransitionPublications = false
    private var deferredPersistRequested = false

    /// SwiftUI scene commits have a strict watchdog budget. Keep incoming
    /// lyrics-search updates buffered while iOS moves active → background;
    /// scraping and cache writes continue, but the two 11k-element observable
    /// arrays are not republished in that narrow window.
    func beginSceneTransitionQuiescence() {
        guard !isDeferringSceneTransitionPublications else { return }
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
        if needsImmediatePersistence {
            deferredPersistRequested = false
            persistNow()
        }
        plog("📚 Deferring library publications during scene transition")
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
            persistSnapshot()
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
        if isDeferringSceneTransitionPublications {
            pendingLyricsText.merge(lyricsTextBySongID) { _, latest in latest }
            return
        }

        var nextSongs = songs
        var nextVisibleSongs = visibleSongs
        var appliedIDs: [String] = []
        appliedIDs.reserveCapacity(lyricsTextBySongID.count)
        for (songID, text) in lyricsTextBySongID {
            guard let index = songIndexByID[songID] else { continue }
            guard nextSongs[index].lyricsText != text else { continue }
            nextSongs[index].lyricsText = text
            if let visibleIndex = visibleSongIndexByID[songID] {
                nextVisibleSongs[visibleIndex].lyricsText = text
            }
            appliedIDs.append(songID)
        }

        guard !appliedIDs.isEmpty else { return }
        songs = nextSongs
        visibleSongs = nextVisibleSongs
        for songID in appliedIDs {
            if let visibleIndex = visibleSongIndexByID[songID] {
                visibleSongByID[songID] = nextVisibleSongs[visibleIndex]
            }
        }
        plog("📚 updateLyricsText: requested=\(lyricsTextBySongID.count) applied=\(appliedIDs.count) librarySongs=\(songs.count)")
        invalidateSearchCaches()
        persistSongChanges(
            upserts: appliedIDs.compactMap { songIndexByID[$0].map { nextSongs[$0] } }
        )
    }

    /// Update cached artwork / lyrics references without rebuilding album,
    /// artist, playlist, and history indexes. Scraped sidecar assets only
    /// change where UI loaders read media from; they don't affect grouping.
    func updateAssetReferences(songID: String, coverRef: String? = nil, lyricsRef: String? = nil) {
        guard let index = songIndexByID[songID] else { return }
        var updatedSong = songs[index]
        let oldCoverRef = updatedSong.coverArtFileName
        var changed = false

        if coverRef != nil, updatedSong.coverArtFileName != coverRef {
            updatedSong.coverArtFileName = coverRef
            changed = true
        }
        if lyricsRef != nil, updatedSong.lyricsFileName != lyricsRef {
            updatedSong.lyricsFileName = lyricsRef
            changed = true
        }
        guard changed else { return }

        var nextSongs = songs
        nextSongs[index] = updatedSong
        songs = nextSongs
        if let visibleIndex = visibleSongIndexByID[songID] {
            var nextVisibleSongs = visibleSongs
            nextVisibleSongs[visibleIndex] = updatedSong
            visibleSongs = nextVisibleSongs
        }
        visibleSongByID[songID] = updatedSong
        lastReplacedSong = updatedSong
        lastReplacedSongIDs = [songID]
        songReplacementToken = UUID()
        if oldCoverRef != updatedSong.coverArtFileName {
            postArtworkInvalidation(songID: songID, oldRef: oldCoverRef, newRef: updatedSong.coverArtFileName)
        }
        persistSongChanges(upserts: [updatedSong])
    }

    /// Update the optional MV reference without rebuilding album, artist,
    /// playlist, and history indexes. `nil` is meaningful here: it clears a
    /// stale video sidecar discovered during playback or scanning.
    func updateMusicVideoReference(songID: String, mvPath: String?) {
        guard let index = songIndexByID[songID],
              songs[index].mvPath != mvPath else { return }

        var updatedSong = songs[index]
        updatedSong.mvPath = mvPath
        var nextSongs = songs
        nextSongs[index] = updatedSong
        songs = nextSongs
        if let visibleIndex = visibleSongIndexByID[songID] {
            var nextVisibleSongs = visibleSongs
            nextVisibleSongs[visibleIndex] = updatedSong
            visibleSongs = nextVisibleSongs
        }
        visibleSongByID[songID] = updatedSong
        lastReplacedSong = updatedSong
        lastReplacedSongIDs = [songID]
        songReplacementToken = UUID()
        persistSongChanges(upserts: [updatedSong])
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
        pruneMissingSongs: Bool = true
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
        // Keep only compact identity sets during the first pass. Retaining a
        // second full `[Song]` snapshot here doubled the peak of every remote
        // incremental flush, even though preparation can be done lazily below.
        var incomingIDs: Set<String> = []
        var sourceIDs = explicitAffectedSourceIDs ?? []
        var appendedIDs: Set<String> = []
        if pruneMissingSongs {
            incomingIDs.reserveCapacity(newSongs.count)
        }
        for song in newSongs where !deletedSongIdentities.contains(identityKey(for: song)) {
            if pruneMissingSongs {
                incomingIDs.insert(song.id)
                if explicitAffectedSourceIDs == nil {
                    sourceIDs.insert(song.sourceID)
                }
            }
            if songIndexByID[song.id] == nil {
                appendedIDs.insert(song.id)
            }
        }

        // A degraded/partial provider response is not an authoritative source
        // snapshot. Keep existing rows (and, critically, their persistent
        // metadata caches) until a complete scan succeeds.
        let existingSongs = songs
        let shouldRemove: (Song) -> Bool = { song in
            pruneMissingSongs
                && sourceIDs.contains(song.sourceID)
                && !incomingIDs.contains(song.id)
        }
        let removalCount = pruneMissingSongs
            ? existingSongs.reduce(into: 0) { count, song in
                if shouldRemove(song) { count += 1 }
            }
            : 0
        let appendedSongCount = appendedIDs.count

        // Build the final buffer once. `var mergedSongs = songs` followed by
        // `removeAll` forces Array CoW to allocate another full-library buffer
        // at the worst point of an incremental scan and was the allocation
        // failure reported by Organizer.
        var mergedSongs: [Song] = []
        mergedSongs.reserveCapacity(existingSongs.count - removalCount + appendedSongCount)
        var removedSongs: [Song] = []
        removedSongs.reserveCapacity(removalCount)

        var existingIndexByID: [String: Int]
        if removalCount == 0 {
            // Share the existing index buffer until a genuinely new ID is
            // appended. An all-existing refresh then avoids another full hash
            // table allocation.
            mergedSongs.append(contentsOf: existingSongs)
            existingIndexByID = songIndexByID
        } else {
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
        var persistedSongIDs: Set<String> = []

        func recordPersistence(_ song: Song) {
            persistedSongIDs.insert(song.id)
        }

        for song in newSongs where !deletedSongIdentities.contains(identityKey(for: song)) {
            var newSong = song
            MusicLibrary.fillDerivedIDs(&newSong)
            if let idx = existingIndexByID[newSong.id] {
                let existing = mergedSongs[idx]
                if !newSong.filePath.isEmpty, newSong.filePath != existing.filePath {
                    previousLocationsByID[newSong.id] = existing
                }
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
                    mergedSongs[idx] = newSong
                    contentChanged.append(newSong)
                    replacementIDs.insert(newSong.id)
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
                    if let mvPath = newSong.mvPath { merged.mvPath = mvPath }
                    if merged != existing {
                        mergedSongs[idx] = merged
                        recordPersistence(merged)
                    }
                    if Self.songPresentationChanged(from: existing, to: merged) {
                        replacementIDs.insert(newSong.id)
                    }
                } else {
                    if newSong != existing {
                        mergedSongs[idx] = newSong
                        recordPersistence(newSong)
                    }
                    if Self.songPresentationChanged(from: existing, to: newSong) {
                        replacementIDs.insert(newSong.id)
                    }
                }
            } else {
                mergedSongs.append(newSong)
                existingIndexByID[newSong.id] = mergedSongs.count - 1
                recordPersistence(newSong)
            }
        }

        songs = mergedSongs
        songIndexByID = existingIndexByID
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Newly-added songs may resolve identities that were stashed when
        // a CloudKit playlist/history record arrived before the local scan.
        flushPendingIdentities()
        invalidateSearchCaches()
        rebuildIndex()
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
            || old.lastModified != new.lastModified
            || old.coverArtFileName != new.coverArtFileName
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

    /// Delete a single song and rebuild index
    @discardableResult
    func deleteSong(_ song: Song) -> Int {
        songs.removeAll { $0.id == song.id }
        songIndexByID = Self.makeSongIndex(songs)
        // Tombstone keyed by canonical identity (account+path, not
        // mount-UUID+path) so re-adding the same Baidu account on
        // a fresh source UUID doesn't bypass it.
        deletedSongIdentities.insert(identityKey(for: song))
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSongChanges(deletingIDs: [song.id], needsPromptCompatibilitySnapshot: true)
        postSongsRemoved([song])
        return songs.filter { $0.sourceID == song.sourceID }.count
    }

    /// Batch delete. Calling `deleteSong` in a 3000-song loop did
    /// `removeAll`/clean*/`rebuildIndex` once per song — O(N) each, so
    /// O(N×K) on the main actor, plus K Observable mutations triggering
    /// view rebuilds; on a 10K-song library with 3K duplicates the
    /// watchdog killed the app. Doing the bulk operations once amortizes
    /// the work to a single O(N) pass.
    @discardableResult
    func deleteSongs(_ songsToDelete: [Song]) -> [String: Int] {
        guard !songsToDelete.isEmpty else { return [:] }
        let idsToDelete = Set(songsToDelete.map(\.id))
        let affectedSourceIDs = Set(songsToDelete.map(\.sourceID))
        for song in songsToDelete {
            deletedSongIdentities.insert(identityKey(for: song))
        }
        songs.removeAll { idsToDelete.contains($0.id) }
        songIndexByID = Self.makeSongIndex(songs)
        var remainingCounts = Dictionary(
            uniqueKeysWithValues: affectedSourceIDs.map { ($0, 0) }
        )
        for song in songs where affectedSourceIDs.contains(song.sourceID) {
            remainingCounts[song.sourceID, default: 0] += 1
        }
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSongChanges(deletingIDs: idsToDelete, needsPromptCompatibilitySnapshot: true)
        postSongsRemoved(songsToDelete)
        return remainingCounts
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

    private func postSongsRemoved(_ songs: [Song], sourceIDs: Set<String>? = nil) {
        guard songs.isEmpty == false else { return }
        var userInfo: [String: Any] = ["songs": songs]
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
    func removeSongsForSource(_ sourceID: String) {
        removeSongsForSources([sourceID])
    }

    /// Remove several sources in one library pass. Repeated per-source
    /// removeAll/playlist cleanup/index rebuild made rapid source deletion
    /// O(sourceCount × librarySize) on the main actor.
    func removeSongsForSources(_ sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        let removedSongs = songs.filter { sourceIDs.contains($0.sourceID) }
        disabledSourceIDs.subtract(sourceIDs)
        guard !removedSongs.isEmpty else {
            rebuildVisibleCache()
            return
        }

        songs.removeAll { sourceIDs.contains($0.sourceID) }
        songIndexByID = Self.makeSongIndex(songs)
        invalidateSearchCaches()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSongChanges(
            deletingIDs: Set(removedSongs.map(\.id)),
            needsPromptCompatibilitySnapshot: true
        )
        postSongsRemoved(removedSongs, sourceIDs: sourceIDs)
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
        if let visibleSong = visibleSongByID[id] { return visibleSong }
        guard let index = songIndexByID[id] else { return nil }
        return songs[index]
    }

    /// O(1) visible-only lookup for background workers and external routes.
    /// Unlike `song(id:)`, this deliberately excludes disabled sources.
    func visibleSong(id: String) -> Song? {
        _ = visibleSongsReference
        return visibleSongByID[id]
    }

    /// O(1) lookup for views whose structural invalidation is driven by
    /// `visibleSongCollectionRevision` and `songReplacementToken` explicitly.
    /// Avoiding a read of `visibleSongsReference` prevents one metadata update
    /// from invalidating an entire large list; existing row models are patched
    /// through the replacement token, while newly-created rows resolve the
    /// latest value here.
    func unobservedVisibleSong(id: String) -> Song? {
        visibleSongByID[id]
    }

    /// O(1) membership check for UI observers that must distinguish the
    /// enabled/visible library from songs retained under a disabled source.
    func containsVisibleSong(id: String) -> Bool {
        _ = visibleSongsReference
        return visibleSongByID[id] != nil
    }

    /// Cached source slice used by SourcesView.
    func playableSongs(forSourceID sourceID: String) -> [Song] {
        _ = visibleSongsReference
        return visiblePlayableSongsBySourceID[sourceID] ?? []
    }

    /// Cached source slice for song-list routes. Avoids re-filtering the full
    /// visible library every time a macOS source detail view is invalidated.
    func visibleSongs(forSourceID sourceID: String) -> [Song] {
        _ = visibleSongsReference
        return visibleSongsBySourceID[sourceID] ?? []
    }

    func visibleSongCount(forSourceID sourceID: String) -> Int {
        _ = visibleSongsReference
        return visibleSongCountBySourceID[sourceID, default: 0]
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

    // MARK: - User-selected album / playlist artwork

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
        let resolvedSongID: String?
        if let identity = override?.selectedSongIdentity {
            let index = makeIdentityResolutionIndex(for: [identity])
            resolvedSongID = resolveIdentity(identity, using: index)
        } else {
            resolvedSongID = nil
        }
        return LibraryArtworkOverridePolicy.resolve(
            override: override,
            resolvedSongID: resolvedSongID,
            eligibleSongIDs: Set(eligibleSongs.map(\.id))
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
            selectedSongIdentity: makeArtworkSongIdentity(song),
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

    private func makeArtworkSongIdentity(_ song: Song) -> SongIdentity {
        SongIdentity(
            songID: song.id,
            title: song.title,
            artistName: song.artistName,
            duration: song.duration,
            cloudAccountID: sourceIdentityResolver?(song.sourceID),
            filePath: song.filePath
        )
    }

    /// Applies a remote value and returns true when the existing local value
    /// wins, allowing CloudKit's conflict path to reassert it.
    @discardableResult
    func applyRemoteArtworkOverride(_ remote: LibraryArtworkOverride) -> Bool {
        guard !remote.owner.id.isEmpty else { return false }
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
        notifyArtworkOverrideChanged(remote)
        return false
    }

    func deleteArtworkOverrideFromRemote(owner: LibraryArtworkOwner) {
        guard let removed = artworkOverridesByOwner.removeValue(forKey: owner.storageKey) else { return }
        guard persistPlaylistDurabilityLedger() else {
            artworkOverridesByOwner[owner.storageKey] = removed
            return
        }
        persistSnapshot()
        artworkOverrideRevision &+= 1
    }

    private func notifyArtworkOverrideChanged(_ value: LibraryArtworkOverride) {
        artworkOverrideRevision &+= 1
        var userInfo: [AnyHashable: Any] = [
            "ids": [value.cloudRecordID],
            "ownerIDs": [value.owner.id],
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
        _ = visibleSongsReference
        return (playlistSongIDs[playlistID] ?? []).compactMap { visibleSongByID[$0] }
    }

    /// Count and first visible entry without materializing the full playlist.
    /// List rows frequently need only these two values.
    func songSummary(forPlaylist playlistID: String) -> (first: Song?, count: Int) {
        _ = visibleSongsReference
        var first: Song?
        var count = 0
        for songID in playlistSongIDs[playlistID] ?? [] {
            guard let song = visibleSongByID[songID] else { continue }
            if first == nil { first = song }
            count += 1
        }
        return (first, count)
    }

    func songCount(forPlaylist playlistID: String) -> Int {
        songSummary(forPlaylist: playlistID).count
    }

    func recentlyPlayedSongs(limit: Int = 6) -> [Song] {
        _ = visibleSongsReference
        return Array(recentPlaybackSongIDs.prefix(limit).compactMap { visibleSongByID[$0] })
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
            return
        }
        persistSnapshot()
        playlistCollectionRevision &+= 1
    }

    func restoreHiddenMirrorPlaylist(_ suppression: MirrorPlaylistSuppression) {
        let suppressionID = keyID(suppression.key)
        guard let removed = mirrorPlaylistSuppressions.removeValue(forKey: suppressionID) else { return }
        guard persistPlaylistDurabilityLedger() else {
            mirrorPlaylistSuppressions[suppressionID] = removed
            return
        }
        persistSnapshot()
        playlistCollectionRevision &+= 1
    }

    func createPlaylist(name: String) -> Playlist {
        createPlaylist(name: name, songIDs: [])
    }

    /// Create a playlist with its initial contents in one observable mutation,
    /// persistence request, and CloudKit notification. Importing 1000 tracks
    /// through `createPlaylist` + 1000 calls to `add` previously serialized the
    /// whole library snapshot and invalidated playlist views 1001 times.
    func createPlaylist(name: String, songIDs: [String]) -> Playlist {
        let playlist = stampedPlaylist(Playlist(name: name))
        let entries = validUniqueSongIDs(songIDs)
        allPlaylists.append(playlist)
        playlistSongIDs[playlist.id] = entries
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlist.id])
        return allPlaylists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    /// 用固定 ID 创建/取回 playlist ── 给"系统级"歌单 (Apple Music 资料库
    /// 镜像等) 用, 保证多端同步 + 重启后映射稳定, 不会重复创建。
    /// 镜像歌单的可见性由 suppression 独立控制；本地歌单若已删除，只能走显式恢复。
    @discardableResult
    func ensurePlaylist(id: String, name: String) -> Playlist {
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
                persistSnapshot()
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
        persistSnapshot()
        notifyPlaylistsChanged([playlist.id])
        return playlist
    }

    /// 整体替换普通用户歌单（例如手动重排或把当前队列另存为歌单）。镜像歌单
    /// 必须走 `replaceMirrorPlaylistSongs`，防止任一遗漏的 UI 入口改写只读镜像。
    func replacePlaylistSongs(playlistID: String, songIDs: [String]) {
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID),
              allPlaylists.first(where: { $0.id == playlistID })?.isDeleted == false
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
        playlistSongIDs[playlistID] = kept
        allPlaylists[idx].updatedAt = Date()
        if replacesCoverArtPath {
            let normalized = normalizedArtworkReference(mirrorCoverArtPath)
            allPlaylists[idx].coverArtPath = normalized
            allPlaylists[idx].hasDedicatedCoverArt = normalized != nil
        }
        if !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID) {
            allPlaylists[idx] = stampedPlaylist(allPlaylists[idx])
            persistPlaylistDurabilityLedger()
        }
        sortPlaylists()
        persistSnapshot()
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
        persistSnapshot()
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
        guard let index = allPlaylists.firstIndex(where: { $0.id == id }),
              allPlaylists[index].isDeleted else { return }
        let original = allPlaylists[index]
        let originalSongIDs = playlistSongIDs[id]
        let originalPending = pendingPlaylistIdentities[id]
        allPlaylists[index] = stampedPlaylist(allPlaylists[index], purging: true)
        playlistSongIDs[id] = nil
        pendingPlaylistIdentities[id] = nil
        guard persistPlaylistDurabilityLedger() else {
            allPlaylists[index] = original
            playlistSongIDs[id] = originalSongIDs
            pendingPlaylistIdentities[id] = originalPending
            return
        }
        persistSnapshot()
        notifyPlaylistsChanged([id])
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

    private func prunePlaylists(withIDPrefixes prefixes: Set<String>, keepingIDs: Set<String>) {
        guard !prefixes.isEmpty else { return }
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
        add(songIDs: [songID], toPlaylist: playlistID)
    }

    /// Batch playlist insertion. Input order is retained, missing songs and
    /// duplicate IDs are ignored exactly as repeated calls to `add` did, but
    /// the playlist is published and persisted only once.
    func add(songIDs: [String], toPlaylist playlistID: String) {
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID),
              !songIDs.isEmpty,
              let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }),
              !allPlaylists[existingIndex].isDeleted
        else { return }

        var entries = playlistSongIDs[playlistID] ?? []
        var seen = Set(entries)
        var changed = false
        entries.reserveCapacity(entries.count + songIDs.count)
        for songID in songIDs where songIndexByID[songID] != nil {
            if seen.insert(songID).inserted {
                entries.append(songID)
                changed = true
            }
        }
        guard changed else { return }
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex] = stampedPlaylist(allPlaylists[existingIndex])
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    private func validUniqueSongIDs(_ songIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(songIDs.count)
        for songID in songIDs where songIndexByID[songID] != nil {
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
        remove(songIDs: [songID], fromPlaylist: playlistID)
    }

    /// 批量移除。逐首调用会按条数重复 sortPlaylists / persistSnapshot / 发通知,
    /// 在歌单里一次移除几十首时那是几十轮全量落盘 + 视图重建。
    func remove(songIDs: [String], fromPlaylist playlistID: String) {
        guard !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID),
              !songIDs.isEmpty,
              let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }),
              !allPlaylists[existingIndex].isDeleted
        else { return }

        let removalSet = Set(songIDs)
        var entries = playlistSongIDs[playlistID] ?? []
        let originalCount = entries.count
        entries.removeAll { removalSet.contains($0) }
        guard entries.count != originalCount else { return }
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex] = stampedPlaylist(allPlaylists[existingIndex])
        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    // MARK: - Cloud sync hooks

    /// Raw stored song IDs for a playlist (no visibility filtering).
    func rawSongIDs(forPlaylist playlistID: String) -> [String] {
        playlistSongIDs[playlistID] ?? []
    }

    /// Projects the already-persisted Apple Music mirrors into the folder
    /// browser. This is deliberately local-only: opening the library never
    /// starts another MusicKit request or authorization prompt.
    func appleMusicFolderCollections(
        availableSongs: [Song]
    ) -> [LibraryFolderVirtualCollectionDescriptor] {
        let sourceID = AppleMusicLibraryIdentity.sourceID
        guard appleMusicLibrarySyncEnabled,
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
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            if PlaylistReconciliationPolicy.winner(
                local: allPlaylists[index],
                remote: playlist
            ) == .local {
                return true
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

        sortPlaylists()
        persistPlaylistDurabilityLedger()
        persistSnapshot()
        playlistCollectionRevision &+= 1
        return false
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
        var seen = Set<String>()
        let merged = (baseSongIDs + resolved).filter { seen.insert($0).inserted }
        playlistSongIDs[reconciled.id] = merged
        updatePendingPlaylistIdentities(playlistID: reconciled.id, with: unresolved)
        if reconciled.isPurged {
            playlistSongIDs[reconciled.id] = nil
            pendingPlaylistIdentities[reconciled.id] = nil
        }

        sortPlaylists()
        persistPlaylistDurabilityLedger()
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
        let resolutionIndex = makeIdentityResolutionIndex(for: identities)
        var resolved: [String] = []
        var unresolved: [SongIdentity] = []
        for identity in identities {
            if let songID = resolveIdentity(identity, using: resolutionIndex) {
                resolved.append(songID)
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
        let needsCloudPathLookup = identities.contains {
            $0.cloudAccountID != nil && !$0.filePath.isEmpty
        }

        var songIDByCloudPath: [IdentityCloudPathKey: String] = [:]
        var songIndicesByTitle: [String: [Int]] = [:]
        if needsCloudPathLookup { songIDByCloudPath.reserveCapacity(min(songs.count, identities.count)) }
        songIndicesByTitle.reserveCapacity(requestedTitles.count)

        for (songIndex, song) in songs.enumerated() {
            if requestedTitles.contains(song.title) {
                songIndicesByTitle[song.title, default: []].append(songIndex)
            }
            if needsCloudPathLookup,
               !song.filePath.isEmpty,
               let accountID = sourceIdentityResolver?(song.sourceID) {
                let key = IdentityCloudPathKey(accountID: accountID, filePath: song.filePath)
                if songIDByCloudPath[key] == nil { songIDByCloudPath[key] = song.id }
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
        if songIndexByID[identity.songID] != nil {
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
    private func flushPendingIdentities() {
        guard !pendingPlaylistIdentities.isEmpty || !pendingHistoryIdentities.isEmpty else { return }

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
            if let songID = resolveIdentity(entry.identity, using: resolutionIndex) {
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

    /// Convert a legacy CloudKit hard deletion into a durable tombstone. The
    /// caller re-uploads it so old offline clients cannot later recreate it.
    @discardableResult
    func deletePlaylistFromRemote(id: String) -> Bool {
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
        guard let index = songIndexByID[updatedSong.id] else { return }
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
        persistSongChanges(upserts: [s])
    }

    /// Batch counterpart to `replaceSong`. Used by `MetadataBackfillService`
    /// to apply many metadata fills at once — running rebuildIndex /
    /// persistSnapshot once per batch instead of per song keeps the UI
    /// responsive when the backfill worker is at full speed (otherwise
    /// the artists/albums grouping is recomputed dozens of times a second).
    func replaceSongs(_ updatedSongs: [Song]) {
        guard !updatedSongs.isEmpty else { return }
        let originalSongs = songs
        var nextSongs = originalSongs
        let idToIndex = songIndexByID

        var lastApplied: Song?
        var appliedIDs: Set<String> = []
        var missedIDs: [String] = []
        var artworkChanges: [(songID: String, oldRef: String?, newRef: String?)] = []
        for updated in updatedSongs {
            guard let index = idToIndex[updated.id] else {
                missedIDs.append(updated.id)
                continue
            }
            let oldCoverRef = nextSongs[index].coverArtFileName
            var s = updated
            MusicLibrary.fillDerivedIDs(&s)
            nextSongs[index] = s
            lastApplied = s
            appliedIDs.insert(s.id)
            if oldCoverRef != s.coverArtFileName {
                artworkChanges.append((s.id, oldCoverRef, s.coverArtFileName))
            }
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
        lastReplacedSong = lastApplied
        lastReplacedSongIDs = appliedIDs
        songReplacementToken = UUID()
        if !artworkChanges.isEmpty {
            postArtworkInvalidations(artworkChanges)
        }
        invalidateSearchCaches()
        rebuildIndex()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        // Batch backfill may have surfaced enough metadata for a chunk of
        // pending identities to resolve at once.
        flushPendingIdentities()
        persistSongChanges(
            upserts: appliedIDs.compactMap { idToIndex[$0].map { nextSongs[$0] } }
        )
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

        var nextVisibleSongs = visibleSongs
        for update in visibleUpdates {
            nextVisibleSongs[update.visibleIndex] = update.song
        }

        // One observable array publication per batch. The dictionary is
        // observation-ignored and can be patched in place without copying all
        // 10K+ entries.
        songs = nextSongs
        visibleSongs = nextVisibleSongs
        for update in visibleUpdates {
            visibleSongByID[update.song.id] = update.song
        }
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
    private var rebuildIndexTask: Task<Void, Never>?
    private var rebuildIndexGeneration: Int = 0
    /// Collapse mutations published in the same run-loop burst before starting
    /// a full-library grouping/sort. More importantly, cancellation can happen
    /// while the task is still sleeping instead of after expensive work began.
    private static let rebuildIndexDebounce: Duration = .milliseconds(250)

    private func rebuildIndex() {
        rebuildIndexGeneration &+= 1
        let myGen = rebuildIndexGeneration
        let snapshot = songs
        let disabledSourceSnapshot = disabledSourceIDs
        let previousVisibleSongs = visibleSongs

        rebuildIndexTask?.cancel()
        rebuildIndexTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: Self.rebuildIndexDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let signature = MusicLibrary.derivedIndexSignature(for: snapshot)
            guard !Task.isCancelled,
                  let result = MusicLibrary.computeAlbumsAndArtistsCancellable(songs: snapshot)
            else { return }
            guard !Task.isCancelled else { return }
            let visibleCache = MusicLibrary.prepareVisibleCache(
                songs: snapshot,
                albums: result.albums,
                artists: result.artists,
                disabledSourceIDs: disabledSourceSnapshot,
                previousVisibleSongs: previousVisibleSongs
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                // generation 校验: 期间又有新的 rebuildIndex 调度过, 当前结果
                // 已经 stale, 丢弃。
                guard self.rebuildIndexGeneration == myGen,
                      self.disabledSourceIDs == disabledSourceSnapshot else { return }
                self.albums = result.albums
                self.artists = result.artists
                self.derivedIndexSignature = signature
                self.applyPreparedVisibleCache(visibleCache)
                self.persistDerivedIndexCache()
            }
        }
    }

    /// 启动 / 测试场景下需要"调用即生效"的同步重建。比异步版本贵 (会卡
    /// main actor 一下), 但只在 init / migration 等 UI 还没起来的路径用。
    private func rebuildIndexSync(precomputedSignature: String? = nil) {
        let result = MusicLibrary.computeAlbumsAndArtists(songs: songs)
        albums = result.albums
        artists = result.artists
        derivedIndexSignature = precomputedSignature
            ?? MusicLibrary.derivedIndexSignature(for: songs)
        rebuildVisibleCache()
    }

    /// tvOS 下载到新快照后重新从磁盘加载整库(songs/playlists 等)。
    func reloadFromDisk() { loadSnapshot(preferExternalSnapshot: true) }

    private func loadSnapshot(preferExternalSnapshot: Bool = false) {
        let loadStartedAt = ProcessInfo.processInfo.systemUptime
        let hasCompatibilitySnapshot = FileManager.default.fileExists(atPath: snapshotURL.path)
        let compatibilityFingerprint = hasCompatibilitySnapshot
            ? Self.snapshotFingerprint(at: snapshotURL)
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
        let startupCache = initialStoreState?.isAuthoritative == true
            ? loadStartupCache(
                songStoreRevision: initialStoreState?.contentRevision,
                snapshotFingerprint: compatibilityFingerprint
            )
            : nil

        var canonicalSongs: [Song]?
        var resolvedSnapshot: Snapshot?
        var snapshotByteCount = 0
        var canRefreshStartupCache = false
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
            if initialStoreState?.isAuthoritative == true, let songStore {
                do {
                    canonicalSongs = try songStore.loadSongs()
                } catch {
                    plog("⚠️ Incremental song store read failed; recovering from JSON: \(error.localizedDescription)")
                }
            }

            if !hasCompatibilitySnapshot {
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
                    resolvedSnapshot = decoded
                    canRefreshStartupCache = true
                    persistenceBlockedByCorruption = false
                } else {
                    let corruptURL = snapshotURL.deletingLastPathComponent()
                        .appendingPathComponent("library-cache.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                    try? FileManager.default.copyItem(at: snapshotURL, to: corruptURL)

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
        Self.restorePortableArtworkAssets(snapshot.artworkAssets)

        // Migrate the decoded value before publishing it. `songs` is backed by
        // an immutable observable reference, so mutating `songs[i]` would run
        // its setter once per item. With a 10K+ library that copied and
        // published the complete array thousands of times during cold launch.
        // Keeping the work local gives the array one copy-on-write mutation
        // and the observable model one final publication.
        var loadedSongs = canonicalSongs ?? snapshot.songs
        let shouldInspectLoadedSongs = preferExternalSnapshot
            || canonicalSongs == nil
            || (initialStoreState?.completedMigrationVersion ?? 0) < Self.loadedSongMigrationVersion
        let migration = shouldInspectLoadedSongs
            ? Self.migrateLoadedSongs(&loadedSongs)
            : (
                repairedTextCount: 0,
                filledDerivedIDCount: 0,
                correctedLegacyDTSDurationCount: 0,
                changedSongs: []
            )
        let migrationFinishedAt = ProcessInfo.processInfo.systemUptime
        if shouldInspectLoadedSongs, let songStore {
            do {
                if preferExternalSnapshot || canonicalSongs == nil {
                    try songStore.replaceAll(with: loadedSongs)
                } else if !migration.changedSongs.isEmpty {
                    try songStore.apply(upserts: migration.changedSongs)
                }
                try songStore.markMigrationCompleted(version: Self.loadedSongMigrationVersion)
            } catch {
                plog("⚠️ Incremental song store migration failed; JSON remains authoritative: \(error.localizedDescription)")
            }
        }
        songs = loadedSongs
        songIndexByID = Self.makeSongIndex(loadedSongs)
        allPlaylists = snapshot.playlists
        artworkOverridesByOwner = Dictionary(
            (snapshot.artworkOverrides ?? []).map { ($0.owner.storageKey, $0) },
            uniquingKeysWith: { local, remote in
                LibraryArtworkOverrideReconciliationPolicy.winner(
                    local: local,
                    remote: remote
                ) == .local ? local : remote
            }
        )
        mirrorPlaylistSuppressions = Dictionary(
            uniqueKeysWithValues: (snapshot.mirrorPlaylistSuppressions ?? []).map { ($0.id, $0) }
        )
        loadPlaylistDurabilityLedger()
        allSmartPlaylists = snapshot.smartPlaylists ?? []
        playlistSongIDs = snapshot.playlistSongIDs ?? [:]
        playlistCollectionRevision &+= 1
        artworkOverrideRevision &+= 1
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
        let cleanupFinishedAt = ProcessInfo.processInfo.systemUptime
        let usedDerivedIndexCache: Bool
        if let startupCache, migration.changedSongs.isEmpty {
            albums = startupCache.albums
            artists = startupCache.artists
            derivedIndexSignature = startupCache.derivedIndexSignature
            rebuildVisibleCache()
            usedDerivedIndexCache = true
        } else {
            let currentDerivedSignature = Self.derivedIndexSignature(for: loadedSongs)
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
                rebuildIndexSync(precomputedSignature: currentDerivedSignature)
                persistDerivedIndexCache()
                usedDerivedIndexCache = false
            }
        }
        let indexFinishedAt = ProcessInfo.processInfo.systemUptime

        if startupCache == nil, canRefreshStartupCache {
            let currentStoreRevision = try? songStore?.startupState().contentRevision
            scheduleStartupCacheWrite(
                snapshot: makeSnapshot(),
                songStoreRevision: currentStoreRevision,
                snapshotFingerprint: Self.snapshotFingerprint(at: snapshotURL)
            )
        }
        plog(String(
            format: "🚀 library load total=%.0fms read=%.0f decode=%.0f migrate=%.0f cleanup=%.0f derived=%.0f startupCache=%@ derivedCache=%@ bytes=%d songs=%d",
            (indexFinishedAt - loadStartedAt) * 1_000,
            (readFinishedAt - loadStartedAt) * 1_000,
            (decodeFinishedAt - readFinishedAt) * 1_000,
            (migrationFinishedAt - decodeFinishedAt) * 1_000,
            (cleanupFinishedAt - migrationFinishedAt) * 1_000,
            (indexFinishedAt - cleanupFinishedAt) * 1_000,
            startupCache == nil ? "miss" : "hit",
            usedDerivedIndexCache ? "hit" : "miss",
            snapshotByteCount,
            loadedSongs.count
        ))
        if migration.repairedTextCount > 0 {
            plog("📚 repaired legacy Chinese metadata text for \(migration.repairedTextCount) song(s)")
        }
        if migration.correctedLegacyDTSDurationCount > 0 {
            plog("📚 corrected legacy DTS duration for \(migration.correctedLegacyDTSDurationCount) song(s)")
        }
        if migration.repairedTextCount > 0
            || migration.filledDerivedIDCount > 0
            || migration.correctedLegacyDTSDurationCount > 0 {
            persistNow()
        }
    }

    private static func migrateLoadedSongs(
        _ songs: inout [Song]
    ) -> (
        repairedTextCount: Int,
        filledDerivedIDCount: Int,
        correctedLegacyDTSDurationCount: Int,
        changedSongs: [Song]
    ) {
        var repairedTextCount = 0
        var filledDerivedIDCount = 0
        var correctedLegacyDTSDurationCount = 0
        var changedSongs: [Song] = []

        for index in songs.indices {
            var song = songs[index]
            let repairedText = repairLegacyChineseMetadataText(in: &song)
            let correctedLegacyDTSDuration = !song.isCueTrack
                ? AudioDurationPolicy.correctedLegacyStoredDuration(
                    stored: song.duration,
                    fileSize: song.fileSize,
                    format: song.fileFormat
                )
                : nil
            var songWithExpectedDerivedIDs = song
            fillDerivedIDs(&songWithExpectedDerivedIDs)
            let needsDerivedIDs = song.artistID != songWithExpectedDerivedIDs.artistID
                || song.albumID != songWithExpectedDerivedIDs.albumID

            if let correctedLegacyDTSDuration {
                song.duration = correctedLegacyDTSDuration
            }
            if needsDerivedIDs {
                song.artistID = songWithExpectedDerivedIDs.artistID
                song.albumID = songWithExpectedDerivedIDs.albumID
            }
            if repairedText || needsDerivedIDs || correctedLegacyDTSDuration != nil {
                songs[index] = song
                changedSongs.append(song)
            }
            if repairedText { repairedTextCount += 1 }
            if needsDerivedIDs { filledDerivedIDCount += 1 }
            if correctedLegacyDTSDuration != nil { correctedLegacyDTSDurationCount += 1 }
        }

        return (
            repairedTextCount,
            filledDerivedIDCount,
            correctedLegacyDTSDurationCount,
            changedSongs
        )
    }

    private static func repairLegacyChineseMetadataText(in song: inout Song) -> Bool {
        var changed = false
        changed = repairLegacyChineseText(&song.title) || changed
        changed = repairLegacyChineseText(&song.artistName) || changed
        if var albumArtistName = song.albumArtistName,
           repairLegacyChineseText(&albumArtistName) {
            song.albumArtistName = albumArtistName
            changed = true
        }
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
    /// Incremental SQLite writes are serialized independently from the JSON
    /// compatibility snapshot. Scan cursor commits await this chain.
    private var songStoreWriteTask: Task<Int64?, Never>?
    /// Serializes off-main-actor snapshot writes. Each `persistNow` chains
    /// onto the previous write so the JSON encode + atomic write happen in
    /// order off the main thread, and the latest snapshot always wins.
    private var persistWriteTask: Task<Bool, Never>?
    private var derivedIndexCacheWriteTask: Task<Void, Never>?
    private var startupCacheWriteTask: Task<Void, Never>?

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

    private func loadStartupCache(
        songStoreRevision: Int64?,
        snapshotFingerprint: SnapshotFileFingerprint?
    ) -> StartupCache? {
        guard let data = try? Data(contentsOf: startupCacheURL),
              let cache = try? PropertyListDecoder().decode(StartupCache.self, from: data),
              cache.formatVersion == Self.startupCacheFormatVersion,
              cache.songStoreRevision == songStoreRevision,
              cache.snapshotFingerprint == snapshotFingerprint else {
            return nil
        }
        return cache
    }

    private func scheduleStartupCacheWrite(
        snapshot: Snapshot,
        songStoreRevision: Int64?,
        snapshotFingerprint: SnapshotFileFingerprint?
    ) {
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
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            // The cache is an accelerator only. Keep the durable SQLite/JSON
            // state untouched and simply rebuild on the next launch.
            plog("⚠️ Library startup cache write failed: \(error.localizedDescription)")
        }
    }

    private func loadDerivedIndexCache(matching signature: String) -> DerivedIndexCache? {
        guard let data = try? Data(contentsOf: derivedIndexCacheURL),
              let cache = try? PropertyListDecoder().decode(DerivedIndexCache.self, from: data),
              cache.signature == signature else {
            return nil
        }
        return cache
    }

    private func persistDerivedIndexCache() {
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

        if let songStore {
            let previous = songStoreWriteTask
            let recoverySnapshot = songs
            songStoreWriteTask = Task.detached(priority: .utility) {
                let previousSucceeded = await previous?.value != nil
                do {
                    if previous == nil || previousSucceeded {
                        return try songStore.apply(upserts: upserts, deletingIDs: deletingIDs)
                    } else {
                        // A failed earlier delta may have left unknown rows
                        // stale. Reconcile from the current immutable snapshot
                        // instead of committing a cursor over that gap.
                        return try songStore.replaceAll(with: recoverySnapshot)
                    }
                } catch {
                    plog("⛔ Incremental song persistence failed: \(error.localizedDescription)")
                    return nil
                }
            }
        }

        // The SQLite transaction is the durable local commit. Keep producing
        // the existing portable JSON for iCloud/TV, but coalesce ordinary
        // metadata batches instead of encoding a multi-thousand-song array
        // every two seconds. Destructive/user-visible mutations stay prompt.
        let delay: TimeInterval
        if needsPromptCompatibilitySnapshot || songStore == nil {
            delay = 2
        } else {
            delay = 30
        }
        persistSnapshot(after: delay)
    }

    private func persistSnapshot(after delay: TimeInterval = 2) {
        if isDeferringSceneTransitionPublications {
            deferredPersistRequested = true
            return
        }
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            persistTask = nil
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
        persistTask?.cancel()
        persistTask = nil
        _ = enqueueSnapshotWrite()
    }

    private func enqueueSnapshotWrite() -> Task<Bool, Never>? {
        guard !persistenceBlockedByCorruption else {
            plog("⛔ Library persistence skipped because the on-disk snapshot is corrupt")
            return nil
        }
        let snapshot = makeSnapshot()
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
            _ = await previous?.value
            let songStoreRevision = await pendingSongStoreWrite?.value ?? capturedStoreRevision
            guard Self.writeSnapshot(snapshot, to: url, backupURL: backupURL) else {
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
        return task
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            songs: songs,
            playlists: allPlaylists,
            artworkOverrides: allArtworkOverrides.isEmpty ? nil : allArtworkOverrides,
            artworkAssets: nil,
            mirrorPlaylistSuppressions: hiddenMirrorPlaylists.isEmpty ? nil : hiddenMirrorPlaylists,
            smartPlaylists: allSmartPlaylists.isEmpty ? nil : allSmartPlaylists,
            playlistSongIDs: playlistSongIDs,
            recentPlaybackSongIDs: recentPlaybackSongIDs,
            deletedSongIdentities: Array(deletedSongIdentities),
            pendingPlaylistIdentities: pendingPlaylistIdentities.isEmpty ? nil : pendingPlaylistIdentities,
            pendingHistoryIdentities: pendingHistoryIdentities.isEmpty ? nil : pendingHistoryIdentities
        )
    }

    /// Persist the current snapshot and wait until its atomic file replacement
    /// finishes. Explicit export/sync actions use this instead of racing an
    /// asynchronous `persistNow()` against an immediate file read.
    func persistNowAndWait() async -> Result<Void, AppleTVTransferFailure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        persistTask?.cancel()
        persistTask = nil
        guard await flushIncrementalSongStore() else {
            return .failure(.snapshotPreparationFailed)
        }
        guard let task = enqueueSnapshotWrite() else {
            return .failure(.snapshotPreparationFailed)
        }
        let succeeded = await task.value
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
        guard let songStoreWriteTask else { return true }
        guard await songStoreWriteTask.value == nil else { return true }
        guard let songStore else { return false }

        let recoverySnapshot = songs
        let recoveryTask = Task<Int64?, Never>.detached(priority: .utility) {
            do {
                return try songStore.replaceAll(with: recoverySnapshot)
            } catch {
                plog("⛔ Incremental song recovery failed: \(error.localizedDescription)")
                return nil
            }
        }
        let recoveredRevision = await recoveryTask.value
        guard let recoveredRevision else {
            plog("⛔ Incremental song persistence failed before library commit")
            return false
        }
        self.songStoreWriteTask = Task { recoveredRevision }
        return true
    }

    /// Encode + atomically write a snapshot. `nonisolated` so it runs off the
    /// main actor; uses a fresh encoder rather than sharing the main-actor one.
    private nonisolated static func writeSnapshot(
        _ snapshot: Snapshot,
        to url: URL,
        backupURL: URL
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            plog("⚠️ Library snapshot encoding failed: \(error.localizedDescription)")
            return false
        }
        let shouldPreserveCurrentAsBackup: Bool
        if let currentData = try? Data(contentsOf: url) {
            shouldPreserveCurrentAsBackup = isValidSnapshotData(currentData)
        } else {
            shouldPreserveCurrentAsBackup = false
        }
        do {
            try AtomicBackupFileWriter.write(
                data,
                to: url,
                backupURL: backupURL,
                preserveExistingAsBackup: shouldPreserveCurrentAsBackup
            )
            return true
        } catch {
            plog("⚠️ Library snapshot write failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func isValidSnapshotData(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Snapshot.self, from: data)) != nil
    }

    nonisolated static func isValidSnapshot(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isValidSnapshotData(data)
    }

    /// Adds bounded transport copies of active uploads to an otherwise normal
    /// library snapshot. The local canonical snapshot remains metadata-only;
    /// this augmented value is used solely by CloudKit/LAN transfer to tvOS.
    nonisolated static func portableSnapshotDataIncludingArtworkAssets(
        _ data: Data
    ) -> Data? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var snapshot = try? decoder.decode(Snapshot.self, from: data) else { return nil }

        let maximumEncodedSnapshotBytes = 60 * 1024 * 1024
        let availableEncodedBytes = max(0, maximumEncodedSnapshotBytes - data.count)
        let maximumRawArtworkBytes = min(24 * 1024 * 1024, availableEncodedBytes * 3 / 4)
        var usedBytes = 0
        var assets: [String: Data] = [:]
        let uploaded = (snapshot.artworkOverrides ?? [])
            .filter { $0.mode == .uploaded }
            .sorted { $0.updatedAt > $1.updatedAt }
        for value in uploaded {
            guard let contentID = value.uploadedContentID,
                  assets[contentID] == nil,
                  let artworkData = MetadataAssetStore.shared.customArtworkData(
                    contentID: contentID
                  ),
                  usedBytes <= maximumRawArtworkBytes - artworkData.count else {
                continue
            }
            assets[contentID] = artworkData
            usedBytes += artworkData.count
        }
        snapshot.artworkAssets = assets.isEmpty ? nil : assets

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(snapshot),
              encoded.count <= maximumEncodedSnapshotBytes else { return nil }
        return encoded
    }

    private nonisolated static func restorePortableArtworkAssets(
        _ assets: [String: Data]?
    ) {
        guard let assets else { return }
        for (contentID, data) in assets {
            _ = MetadataAssetStore.shared.storeCustomArtworkSync(
                data,
                expectedContentID: contentID
            )
        }
    }

    private func sortPlaylists() {
        allPlaylists.sort { $0.updatedAt > $1.updatedAt }
    }

    private func cleanPlaylistEntries() {
        for playlistID in playlistSongIDs.keys {
            playlistSongIDs[playlistID] = (playlistSongIDs[playlistID] ?? []).filter {
                songIndexByID[$0] != nil
            }
        }
    }

    private func cleanPlaybackHistoryEntries() {
        recentPlaybackSongIDs = recentPlaybackSongIDs.filter { songIndexByID[$0] != nil }
    }

    @discardableResult
    private func persistPlaylistDurabilityLedger() -> Bool {
        let ledger = PlaylistDurabilityLedger(
            playlists: allPlaylists.filter { !MirrorPlaylistIdentity.isMirrorPlaylist($0.id) },
            mirrorPlaylistSuppressions: hiddenMirrorPlaylists,
            artworkOverrides: allArtworkOverrides.isEmpty ? nil : allArtworkOverrides
        )
        do {
            let data = try encoder.encode(ledger)
            try data.write(to: playlistDurabilityURL, options: .atomic)
            return true
        } catch {
            plog("⛔ Playlist durability write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func loadPlaylistDurabilityLedger() {
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
            persistPlaylistDurabilityLedger()
        }
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
        if let identity = AlbumGroupingPolicy.identity(
            albumTitle: song.albumTitle,
            albumArtistName: song.albumArtistName,
            trackArtistName: song.artistName,
            unknownArtistName: unknownArtist
        ) {
            song.albumID = hashID("\(identity.artistName):\(identity.albumTitle)")
        } else {
            song.albumID = nil
        }
    }

    /// 后台 derive albums / artists 集合。纯函数 ── 给定 songs 数组, 算出
    /// 派生集合, 不操作 self。
    nonisolated static func computeAlbumsAndArtists(songs: [Song]) -> (albums: [Album], artists: [Artist]) {
        computeAlbumsAndArtists(songs: songs, cancellationCheck: { false })!
    }

    /// Task-aware counterpart used by the incremental rebuild worker. The old
    /// worker only checked cancellation after all filtering/grouping/sorting had
    /// completed, so every superseded task still consumed a full-library pass.
    private nonisolated static func computeAlbumsAndArtistsCancellable(
        songs: [Song]
    ) -> (albums: [Album], artists: [Artist])? {
        computeAlbumsAndArtists(songs: songs, cancellationCheck: { Task.isCancelled })
    }

    private nonisolated static func computeAlbumsAndArtists(
        songs: [Song],
        cancellationCheck: () -> Bool
    ) -> (albums: [Album], artists: [Artist])? {
        guard !cancellationCheck() else { return nil }
        let unknownArtist = String(localized: "unknown_artist")

        // Albums ── 只 group 有 albumTitle 的歌曲
        let songsWithAlbum = songs.compactMap { song -> (Song, AlbumGroupingIdentity)? in
            guard let identity = AlbumGroupingPolicy.identity(
                albumTitle: song.albumTitle,
                albumArtistName: song.albumArtistName,
                trackArtistName: song.artistName,
                unknownArtistName: unknownArtist
            ) else { return nil }
            return (song, identity)
        }
        guard !cancellationCheck() else { return nil }
        let albumGroups = Dictionary(grouping: songsWithAlbum) { entry in
            entry.1
        }
        guard !cancellationCheck() else { return nil }
        let albums = albumGroups.map { identity, entries -> Album in
            let groupedSongs = entries.map(\.0)
            return Album(
                id: hashID("\(identity.artistName):\(identity.albumTitle)"),
                title: identity.albumTitle,
                artistID: hashID(identity.artistName.lowercased()),
                artistName: identity.artistName,
                year: groupedSongs.first?.year,
                genre: groupedSongs.first?.genre,
                songCount: groupedSongs.count,
                totalDuration: groupedSongs.reduce(0) { $0 + $1.duration.sanitizedDuration },
                sourceID: groupedSongs.first?.sourceID
            )
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        guard !cancellationCheck() else { return nil }

        // Artists ── 全 songs 都参与 group
        let artistGroups = Dictionary(grouping: songs) { $0.artistName ?? unknownArtist }
        guard !cancellationCheck() else { return nil }
        let artists = artistGroups.map { name, songs -> Artist in
            let albumCount = Set(songs.compactMap(\.albumTitle)).count
            return Artist(
                id: hashID(name.lowercased()),
                name: name,
                albumCount: albumCount,
                songCount: songs.count
            )
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !cancellationCheck() else { return nil }

        return (albums, artists)
    }

    /// Stable digest of every value consumed by `computeAlbumsAndArtists`.
    /// The derived cache is only a launch accelerator; any metadata, ordering,
    /// duration, locale, or schema change makes the digest differ and falls
    /// back to a full rebuild.
    private nonisolated static func derivedIndexSignature(for songs: [Song]) -> String {
        var input = Data()
        input.reserveCapacity(max(128, songs.count * 96))
        appendStableString("derived-index-v2", to: &input)
        appendStableString(String(localized: "unknown_artist"), to: &input)

        for song in songs {
            appendStableString(song.artistName, to: &input)
            appendStableString(song.albumArtistName, to: &input)
            appendStableString(song.albumTitle, to: &input)
            appendStableInteger(song.year.map(Int64.init) ?? Int64.min, to: &input)
            appendStableString(song.genre, to: &input)
            appendStableInteger(song.duration.sanitizedDuration.bitPattern, to: &input)
            appendStableString(song.sourceID, to: &input)
        }

        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
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
    /// remains the interchange and recovery format; matching both the SQLite
    /// content revision and JSON file identity prevents this accelerator from
    /// ever overriding newer durable state.
    private struct StartupCache: Codable, Sendable {
        let formatVersion: Int
        let songStoreRevision: Int64?
        let snapshotFingerprint: SnapshotFileFingerprint?
        let snapshot: Snapshot
        let albums: [Album]
        let artists: [Artist]
        let derivedIndexSignature: String?
    }

    private struct Snapshot: Codable, Sendable {
        var songs: [Song]
        var playlists: [Playlist]
        var artworkOverrides: [LibraryArtworkOverride]? = nil
        /// Transport-only copies used by the Apple TV/LAN library snapshot.
        /// Normal local persistence always writes nil; images remain canonical
        /// in MetadataAssetStore's durable custom directory.
        var artworkAssets: [String: Data]? = nil
        var mirrorPlaylistSuppressions: [MirrorPlaylistSuppression]?
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
