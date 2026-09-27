import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// The recommendation engine now scores over an interned feature index instead
/// of per-song string copies. Its output must stay identical to the string
/// implementation it replaced, kept verbatim below as the reference.
final class MusicDiscoveryEngineEquivalenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeLibrary(count: Int) -> [Song] {
        let artists: [String?] = ["周杰伦", "Adele", "adele ", "Beyoncé", "BEYONCE", nil, "", "林俊杰", "Queen", "  "]
        let albums: [String?] = ["叶惠美", "25", "Dangerously in Love", nil, "", "Greatest Hits", "范特西", "Night"]
        let genres: [String?] = ["Pop", "pop", "Rock", nil, "", "Mandopop", "R&B"]
        let titles = ["Dream", "晴天", "Hello", "dream", "Crazy in Love", "江南", "Bohemian Rhapsody", "Dream"]
        return (0..<count).map { index in
            Song(
                // Every 997th id repeats its predecessor: duplicate ids exist in real libraries.
                id: String(format: "song-%05d", index % 997 == 0 && index > 0 ? index - 1 : index),
                title: titles[index % titles.count],
                albumID: index % 5 == 0 ? "album-\((index / 7) % 40)" : nil,
                artistID: index % 11 == 0 ? "artist-\(index % 13)" : (index % 17 == 0 ? " " : nil),
                albumTitle: albums[(index / 3) % albums.count],
                artistName: artists[index % artists.count],
                duration: index % 23 == 0 ? 0 : Double(20 + (index * 37) % 400),
                fileFormat: .flac,
                filePath: index % 29 == 0 ? "" : "Music/Folder\(index % 9)/Sub\(index % 4)/\(index).flac",
                sourceID: index % 3 == 0 ? "source-a" : "source-b",
                genre: genres[index % genres.count],
                year: index % 6 == 0 ? nil : 1990 + (index * 7) % 30,
                dateAdded: now.addingTimeInterval(-Double((index * 7919) % (90 * 86_400))),
                coverArtFileName: index % 4 == 0 ? nil : (index % 9 == 0 ? "" : "cover-\(index).jpg")
            )
        }
    }

    private func assertSame(
        _ lhs: [MusicDiscoveryResult],
        _ rhs: [MusicDiscoveryResult],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.map(\.song.id), rhs.map(\.song.id), message, file: file, line: line)
        XCTAssertEqual(lhs.map(\.score), rhs.map(\.score), message, file: file, line: line)
        XCTAssertEqual(lhs.map(\.reasons), rhs.map(\.reasons), message, file: file, line: line)
    }

    func testRecommendationsMatchTheStringImplementation() {
        let songs = makeLibrary(count: 3_000)
        let playable = songs.filteredPlayable()
        let seedSets: [[String]] = [
            [], ["song-00010"], ["song-00004", "song-00123", "song-00456", "song-02999"], ["missing"],
        ]
        let weekIDs = Set(playable.prefix(40).map(\.id))
        let monthIDs = Set(playable.prefix(300).map(\.id))
        let topArtists: Set<String> = ["adele", "周杰伦", "nobody"]
        for seeds in seedSets {
            for limit in [0, 1, 6, 12, 40] {
                // The engine now skips unplayable songs itself; the old one was
                // always handed the pre-filtered list.
                let current = MusicDiscoveryEngine.RecommendationInput(
                    songs: songs, recentWeekIDs: weekIDs, recentMonthIDs: monthIDs,
                    topArtists: topArtists, seedIDs: seeds, now: now
                )
                let legacy = MusicDiscoveryEngine.RecommendationInput(
                    songs: playable, recentWeekIDs: weekIDs, recentMonthIDs: monthIDs,
                    topArtists: topArtists, seedIDs: seeds, now: now
                )
                assertSame(
                    MusicDiscoveryEngine.dailyRecommendations(from: current, limit: limit),
                    LegacyMusicDiscoveryEngine.dailyRecommendations(from: legacy, limit: limit),
                    "seeds=\(seeds) limit=\(limit)"
                )
            }
        }
    }

    func testCachedIndexFollowsTheLibraryRevision() {
        let first = makeLibrary(count: 800)
        let second = Array(makeLibrary(count: 1_200).reversed())
        for (revision, songs) in [(UInt64(90_001), first), (90_001, first), (90_002, second)] {
            let input = MusicDiscoveryEngine.RecommendationInput(
                songs: songs, recentWeekIDs: [], recentMonthIDs: [], topArtists: [],
                seedIDs: ["song-00010"], now: now, libraryRevision: revision
            )
            let legacy = MusicDiscoveryEngine.RecommendationInput(
                songs: songs.filteredPlayable(), recentWeekIDs: [], recentMonthIDs: [], topArtists: [],
                seedIDs: ["song-00010"], now: now
            )
            assertSame(
                MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 12),
                LegacyMusicDiscoveryEngine.dailyRecommendations(from: legacy, limit: 12),
                "revision=\(revision)"
            )
        }
    }

    func testSimilarSongsAndRadioMatchTheStringImplementation() {
        let songs = makeLibrary(count: 2_000)
        let recent = Set(songs.prefix(200).map(\.id))
        var outsider = songs[40]
        outsider.id = "outside-library"
        outsider.albumTitle = "Unknown Album"
        outsider.filePath = "Elsewhere/x.flac"
        let fallbacks = songs.filteredPlayable().suffix(20).map {
            MusicDiscoveryResult(song: $0, score: 1, reasons: [.libraryPick])
        }
        for seed in [songs[10], songs[33], songs[1_500], outsider] {
            for limit in [1, 8, 30] {
                assertSame(
                    MusicDiscoveryEngine.similarSongs(to: seed, songs: songs, recentIDs: recent, limit: limit),
                    LegacyMusicDiscoveryEngine.similarSongs(to: seed, songs: songs, recentIDs: recent, limit: limit),
                    "similar seed=\(seed.id) limit=\(limit)"
                )
            }
            for limit in [1, 12, 48] {
                assertSame(
                    MusicDiscoveryEngine.songRadio(
                        from: seed, songs: songs, recentMonthIDs: recent,
                        fallbacks: fallbacks, limit: limit, now: now
                    ),
                    LegacyMusicDiscoveryEngine.songRadio(
                        from: seed, songs: songs, recentMonthIDs: recent,
                        fallbacks: fallbacks, limit: limit, now: now
                    ),
                    "radio seed=\(seed.id) limit=\(limit)"
                )
            }
        }
    }
}

/// Verbatim copy of the string-based engine before the feature index.
private enum LegacyMusicDiscoveryEngine {
    static func similarSongs(
        to seed: Song,
        songs: [Song],
        recentIDs: Set<String>,
        limit: Int
    ) -> [MusicDiscoveryResult] {
        return songs
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

    static func songRadio(
        from seed: Song,
        songs: [Song],
        recentMonthIDs: Set<String>,
        fallbacks: [MusicDiscoveryResult],
        limit: Int,
        now: Date
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
        let candidates = songs.filteredPlayable()
        let features = candidates.map { NormalizedSong(song: $0) }
        let seedFeature = NormalizedSong(song: seed)

        var output = [
            MusicDiscoveryResult(song: seed, score: .greatestFiniteMagnitude, reasons: [.libraryPick])
        ]
        var usedIDs: Set<String> = [seed.id]
        var cursor = seedFeature

        // Fallback recommendations don't depend on the moving cursor, so build
        // them once and just skip already-used songs as the queue grows.

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

    static func recommendations(
        from input: MusicDiscoveryEngine.RecommendationInput,
        limit: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [MusicDiscoveryResult] {
        let songs = input.songs
        guard !songs.isEmpty, !isCancelled() else { return [] }

        // 10K+ 曲库里，推荐算法的热点不是打分本身，而是内层循环反复做
        // String.folding / 路径拆分。先把每首歌的比较特征归一化一次，
        // 后续 candidate × seed 只做普通值比较。
        var normalizedSongs: [NormalizedSong] = []
        normalizedSongs.reserveCapacity(songs.count)
        for (index, song) in songs.enumerated() {
            if index.isMultiple(of: 128), isCancelled() { return [] }
            normalizedSongs.append(NormalizedSong(song: song))
        }
        guard !isCancelled() else { return [] }
        // 种子最多二十几首; 只为它们建索引, 别把整库(连同每首歌的整份拷贝)
        // 再装进一个字典 —— 二十多万首时这一步就是几百 MB 的瞬时占用。
        let seedIDSet = Set(input.seedIDs)
        var seedsByID: [String: NormalizedSong] = [:]
        for normalizedSong in normalizedSongs where seedIDSet.contains(normalizedSong.song.id) {
            if seedsByID[normalizedSong.song.id] == nil { seedsByID[normalizedSong.song.id] = normalizedSong }
        }
        let seeds = input.seedIDs.compactMap { seedsByID[$0] }

        guard !seeds.isEmpty else {
            return coldStartRecommendations(
                from: songs,
                excluding: [],
                limit: limit,
                now: input.now,
                isCancelled: isCancelled
            )
        }

        var results: [MusicDiscoveryResult] = []
        for (index, candidate) in normalizedSongs.enumerated() {
            if index.isMultiple(of: 128), isCancelled() { return [] }
            let song = candidate.song
            guard !input.recentWeekIDs.contains(song.id) else { continue }

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

            guard score >= 16 else { continue }
            if reasons.isEmpty { reasons = [.libraryPick] }
            results.append(MusicDiscoveryResult(song: song, score: score, reasons: reasons))
        }

        guard !isCancelled() else { return [] }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.song.dateAdded > rhs.song.dateAdded
        }
        guard !isCancelled() else { return [] }

        var ranked = uniqued(results)
        // 目标最多 4 位艺人, 数够就停; 也不必先把整库过滤复制一遍。
        let artistCountCap = min(4, max(0, limit))
        var availableArtists = Set<String>()
        for song in songs where availableArtists.count < artistCountCap {
            guard !input.recentWeekIDs.contains(song.id) else { continue }
            availableArtists.insert(artistIdentity(song))
        }
        let targetArtistCount = min(artistCountCap, availableArtists.count)
        let rankedArtistCount = Set(ranked.map { artistIdentity($0.song) }).count
        if ranked.count < limit || rankedArtistCount < targetArtistCount {
            let excluded = Set(ranked.map(\.song.id)).union(input.recentWeekIDs)
            ranked.append(contentsOf: coldStartRecommendations(
                from: songs,
                excluding: excluded,
                limit: max(limit * 2, limit - ranked.count),
                now: input.now,
                isCancelled: isCancelled
            ))
        }
        guard !isCancelled() else { return [] }
        return diversifiedRecommendations(ranked, limit: limit)
    }

    static func dailyRecommendations(
        from input: MusicDiscoveryEngine.RecommendationInput,
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

    struct NormalizedSong {
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
            folder = LegacyMusicDiscoveryEngine.parentFolder(song.filePath)
        }

        /// Pre-normalize for `nonEmptyEqual`, which treats empty results as
        /// non-matching. nil here means "won't ever match" — keeps the equality
        /// checks branch-free in the hot loop.
        static func normEmptyable(_ text: String?) -> String? {
            guard let text else { return nil }
            let value = LegacyMusicDiscoveryEngine.normalized(text)
            return value.isEmpty ? nil : value
        }
    }

    /// Same scoring as `similarity(between:and:)` but over pre-normalized
    /// features so no `String.folding` runs in `songRadio`'s inner loop.
    static func similarity(between seed: NormalizedSong, and candidate: NormalizedSong) -> Match {
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
    static func normEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs == rhs
    }

    struct Match {
        var score: Double
        var reasons: [MusicDiscoveryReason]
    }

    static func similarity(between seed: Song, and candidate: Song) -> Match {
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

    static func coldStartRecommendations(
        from songs: [Song],
        excluding excludedIDs: Set<String>,
        limit: Int,
        now: Date,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [MusicDiscoveryResult] {
        var ranked: [MusicDiscoveryResult] = []
        ranked.reserveCapacity(songs.count)
        for (index, song) in songs.enumerated() where !excludedIDs.contains(song.id) {
            if index.isMultiple(of: 128), isCancelled() { return [] }
            var score = song.coverArtFileName?.isEmpty == false ? 12.0 : 0.0
            score += max(0, 10 - now.timeIntervalSince(song.dateAdded) / (7 * 24 * 60 * 60))
            if song.artistName?.isEmpty == false { score += 3 }
            if song.albumTitle?.isEmpty == false { score += 3 }
            if song.genre?.isEmpty == false { score += 2 }
            score += stableNoise(song.id)

            let reason: MusicDiscoveryReason = now.timeIntervalSince(song.dateAdded) <= 30 * 24 * 60 * 60
                ? .newToLibrary
                : .libraryPick
            ranked.append(MusicDiscoveryResult(song: song, score: score, reasons: [reason]))
        }
        guard !isCancelled() else { return [] }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.song.dateAdded > rhs.song.dateAdded
        }
        guard !isCancelled() else { return [] }
        return diversifiedRecommendations(ranked, limit: limit)
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

    static func uniqued(_ results: [MusicDiscoveryResult]) -> [MusicDiscoveryResult] {
        var seen = Set<String>()
        var output: [MusicDiscoveryResult] = []
        for result in results where seen.insert(result.song.id).inserted {
            output.append(result)
        }
        return output
    }

    static func artistIdentity(_ song: Song) -> String {
        if let artistID = song.artistID, !normalized(artistID).isEmpty {
            return "id:\(normalized(artistID))"
        }
        if let artistName = song.artistName, !normalized(artistName).isEmpty {
            return "name:\(normalized(artistName))"
        }
        return "song:\(song.id)"
    }

    static func albumIdentity(_ song: Song, artistKey: String) -> String {
        if let albumID = song.albumID, !normalized(albumID).isEmpty {
            return "id:\(normalized(albumID))"
        }
        if let albumTitle = song.albumTitle, !normalized(albumTitle).isEmpty {
            return "title:\(artistKey):\(normalized(albumTitle))"
        }
        return "song:\(song.id)"
    }

    static func nonEmptyEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = normalized(lhs)
        return !left.isEmpty && left == normalized(rhs)
    }

    // `nonisolated` — pure string helpers with no actor state. Lets the
    // `NormalizedSong` feature cache pre-fold strings without hopping the
    // main actor (and keeps the door open for a future detached radio build).
    static func parentFolder(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        guard folder != "." else { return "" }
        return normalized(folder)
    }

    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func append(_ reason: MusicDiscoveryReason, to reasons: inout [MusicDiscoveryReason]) {
        if !reasons.contains(reason) { reasons.append(reason) }
    }

    static func stableNoise(_ id: String) -> Double {
        let sum = id.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 }
        return Double(sum) / 997.0
    }

    static func stableDailyNoise(_ id: String, now: Date) -> Double {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        let mixed = "\(id):\(day)"
        let sum = mixed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }
        return Double(sum) / 997.0
    }
}
