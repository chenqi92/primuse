import Foundation

// MARK: - Profile

/// What one pass over the music library and the recent listening says about
/// this listener: how they file their music, whom and which albums they play,
/// what quality they reach for. The "for you" intents are built from it, on
/// the device or by an AI service that is handed a summary of it.
public struct ListeningProfile: Sendable {
    public struct Folder: Equatable, Sendable {
        public let scope: ListeningFolderScope
        public let name: String
        public let songCount: Int
        public let recentPlays: Int
        public let familyMask: UInt16
        /// The folder's most frequent artists, display names.
        public let topArtists: [String]
    }

    public struct Artist: Equatable, Sendable {
        public let key: String
        public let name: String
        public let songCount: Int
        public let recentPlays: Int
        public let playedSongs: Int
    }

    public struct Album: Equatable, Sendable {
        public let albumID: String
        public let title: String
        public let artistName: String
        public let artistKey: String
        public let year: Int?
        public let trackCount: Int
        public let familyMask: UInt16
        public let recentPlays: Int
        public let playedSongs: Int
    }

    /// Playable music songs.
    public let songCount: Int
    /// Recent plays of songs that are in the library.
    public let recentPlays: Int
    /// Folders the listener sorts music into by kind: siblings that each hold
    /// several albums by several artists. Shallowest first.
    public let folders: [Folder]
    /// Most played first (most songs before there is a history).
    public let artists: [Artist]
    /// Complete albums (four tracks or more).
    public let albums: [Album]
    public let losslessSongs: Int
    public let hiResSongs: Int
    public let losslessPlays: Int
    public let hiResPlays: Int
    /// Played over and over lately.
    public let rotationSongIDs: [String]
    public let familySongs: [ListeningGenreFamily: Int]
    public let familyPlays: [ListeningGenreFamily: Int]
    public let decadeSongs: [Int: Int]
    public let decadePlays: [Int: Int]

    public var hasListening: Bool { recentPlays >= ListeningIntentEngine.minimumRecentPlaysForRanking }

    public init(
        songCount: Int,
        recentPlays: Int,
        folders: [Folder],
        artists: [Artist],
        albums: [Album],
        losslessSongs: Int,
        hiResSongs: Int,
        losslessPlays: Int,
        hiResPlays: Int,
        rotationSongIDs: [String],
        familySongs: [ListeningGenreFamily: Int] = [:],
        familyPlays: [ListeningGenreFamily: Int] = [:],
        decadeSongs: [Int: Int] = [:],
        decadePlays: [Int: Int] = [:]
    ) {
        self.songCount = songCount
        self.recentPlays = recentPlays
        self.folders = folders
        self.artists = artists
        self.albums = albums
        self.losslessSongs = losslessSongs
        self.hiResSongs = hiResSongs
        self.losslessPlays = losslessPlays
        self.hiResPlays = hiResPlays
        self.rotationSongIDs = rotationSongIDs
        self.familySongs = familySongs
        self.familyPlays = familyPlays
        self.decadeSongs = decadeSongs
        self.decadePlays = decadePlays
    }
}

// MARK: - Building

public extension ListeningProfile {
    /// A folder counts as "a kind of music" from this many songs, albums and artists.
    static let folderMinimumSongs = 20
    static let folderMinimumAlbums = 3
    static let folderMinimumArtists = 3
    /// Folders at most this deep below the source root are looked at.
    static let folderMaximumDepth = 3
    /// "In rotation": this many recent plays, the last within this many days.
    static let rotationMinimumPlays = 4
    static let rotationRecentDays = 14
    static let rotationLimit = 300
    static let artistLimit = 60

    /// Nil when cancelled. Give it the music songs (no spoken word).
    static func build<Songs: Collection>(
        songs: Songs,
        history: ListeningHistoryIndex,
        isCancelled: () -> Bool = { false }
    ) -> ListeningProfile? where Songs.Element: ListeningSongTraits {
        var builder = Builder(history: history)
        var position = 0
        for song in songs {
            if position.isMultiple(of: 1_024), isCancelled() { return nil }
            position += 1
            builder.add(song)
        }
        guard !isCancelled() else { return nil }
        return builder.finish()
    }

    /// Stands for the parts of the profile an AI service would be told about;
    /// when it moves, the curated intents are worth asking for again. Counts
    /// are bucketed so ordinary listening does not churn it.
    var fingerprint: String {
        func bucket(_ value: Int) -> Int { value <= 0 ? 0 : Int(log2(Double(value))) }
        var parts: [String] = []
        parts.append("s\(bucket(songCount))")
        parts.append(contentsOf: folders.map { "f:\($0.scope.sourceID)/\($0.scope.path):\(bucket($0.songCount))" }.sorted())
        parts.append(contentsOf: artists.prefix(10).map { "a:\($0.key)" }.sorted())
        parts.append(contentsOf: albums.filter { $0.recentPlays > 0 }
            .sorted { $0.recentPlays > $1.recentPlays }
            .prefix(4).map { "b:\($0.albumID)" }.sorted())
        parts.append("q\(bucket(losslessSongs))/\(bucket(hiResSongs))")
        if hasListening {
            parts.append("p\(losslessPlays * 4 / max(recentPlays, 1))/\(hiResPlays * 4 / max(recentPlays, 1))")
        }
        let digest = ListeningSeededGenerator.seed(parts.joined(separator: "|"))
        return String(digest, radix: 36)
    }

    /// Albums like this one: overlapping genre families, close in time, by
    /// the same artist. At most two from the same artist so the queue is not
    /// just the discography.
    func similarAlbums(to albumID: String, limit: Int = 4) -> [Album] {
        guard limit > 0, let seed = albums.first(where: { $0.albumID == albumID }) else { return [] }
        let seedTitle = ListeningTextKey.folded(seed.title)
        let scored: [(album: Album, score: Double)] = albums.compactMap { album in
            guard album.albumID != seed.albumID,
                  ListeningTextKey.folded(album.title) != seedTitle else { return nil }
            let union = (album.familyMask | seed.familyMask).nonzeroBitCount
            let overlap = union == 0 ? 0 : Double((album.familyMask & seed.familyMask).nonzeroBitCount) / Double(union)
            let years: Double
            if let a = album.year, let b = seed.year, a > 0, b > 0 {
                years = max(0, 1 - Double(abs(a - b)) / 12)
            } else {
                years = 0.3
            }
            let sameArtist = !seed.artistKey.isEmpty && album.artistKey == seed.artistKey
            let score = 0.55 * overlap + 0.25 * years + (sameArtist ? 0.35 : 0)
            guard score >= 0.45, overlap > 0 || sameArtist else { return nil }
            return (album, score)
        }
        var picked: [Album] = []
        var sameArtistCount = 0
        for entry in scored.sorted(by: {
            if abs($0.score - $1.score) > 1e-9 { return $0.score > $1.score }
            if $0.album.recentPlays != $1.album.recentPlays { return $0.album.recentPlays > $1.album.recentPlays }
            return $0.album.trackCount > $1.album.trackCount
        }) {
            let sameArtist = !seed.artistKey.isEmpty && entry.album.artistKey == seed.artistKey
            if sameArtist {
                guard sameArtistCount < 2 else { continue }
                sameArtistCount += 1
            }
            picked.append(entry.album)
            if picked.count == limit { break }
        }
        return picked
    }
}

extension ListeningProfile {
    struct Builder {
        struct FolderTally {
            var songs = 0
            var plays = 0
            var familyMask: UInt16 = 0
            var albums: [String] = []
            var artists: [String: Int] = [:]
            var artistNames: [String: String] = [:]
        }

        struct ArtistTally {
            var name: String
            var songs = 0
            var plays = 0
            var playedSongs = 0
        }

        struct AlbumTally {
            var title: String
            var artistName: String
            var artistKey: String
            var year: Int?
            var tracks = 0
            var familyMask: UInt16 = 0
            var plays = 0
            var playedSongs = 0
        }

        let history: ListeningHistoryIndex
        let rotationSince: Date
        var genreMemo = ListeningGenreClassifier.Memo()
        var artistMemo = ListeningArtistKeyMemo()
        var artistNames: [String: String] = [:]
        var songCount = 0
        var recentPlays = 0
        var folders: [String: FolderTally] = [:]
        var folderScopes: [String: ListeningFolderScope] = [:]
        var sourceSongs: [String: Int] = [:]
        var artists: [String: ArtistTally] = [:]
        var albums: [String: AlbumTally] = [:]
        var albumOrder: [String] = []
        var losslessSongs = 0
        var hiResSongs = 0
        var losslessPlays = 0
        var hiResPlays = 0
        var rotation: [(id: String, plays: Int)] = []
        var familySongs: [ListeningGenreFamily: Int] = [:]
        var familyPlays: [ListeningGenreFamily: Int] = [:]
        var decadeSongs: [Int: Int] = [:]
        var decadePlays: [Int: Int] = [:]

        init(history: ListeningHistoryIndex) {
            self.history = history
            rotationSince = history.now.addingTimeInterval(-Double(ListeningProfile.rotationRecentDays) * 86_400)
        }

        mutating func add<Song: ListeningSongTraits>(_ song: Song) {
            guard song.isPlayable else { return }
            songCount += 1
            let plays = history.recentPlays > 0 ? history.recentPlayCounts[song.id] ?? 0 : 0
            recentPlays += plays
            let mask = genreMemo.mask(for: song.genre)
            for family in ListeningGenreFamily.allCases where mask & family.bit != 0 {
                familySongs[family, default: 0] += 1
                if plays > 0 { familyPlays[family, default: 0] += plays }
            }
            if let year = song.year, (1900...2100).contains(year) {
                decadeSongs[year / 10 * 10, default: 0] += 1
                if plays > 0 { decadePlays[year / 10 * 10, default: 0] += plays }
            }
            switch song.listeningQuality {
            case .hiRes:
                hiResSongs += 1
                losslessSongs += 1
                hiResPlays += plays
                losslessPlays += plays
            case .lossless:
                losslessSongs += 1
                losslessPlays += plays
            case .lossy:
                break
            }
            if plays >= ListeningProfile.rotationMinimumPlays,
               let last = history.lastPlayedAt[song.id], last >= rotationSince {
                rotation.append((song.id, plays))
            }

            let artistKey = artistMemo.key(for: song)
            if !artistKey.isEmpty {
                if artists[artistKey] == nil {
                    let raw = [song.artistName, song.albumArtistName]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty } ?? ""
                    artists[artistKey] = ArtistTally(name: SongDiscoveryMatching.primaryArtist(raw))
                }
                artists[artistKey]!.songs += 1
                if plays > 0 {
                    artists[artistKey]!.plays += plays
                    artists[artistKey]!.playedSongs += 1
                }
            }

            if let albumID = song.albumID, !albumID.isEmpty {
                if albums[albumID] == nil {
                    let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let artist = [song.albumArtistName, song.artistName]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty } ?? ""
                    albums[albumID] = AlbumTally(
                        title: title,
                        artistName: artist,
                        artistKey: artist.isEmpty ? "" : albumArtistKey(artist)
                    )
                    albumOrder.append(albumID)
                }
                albums[albumID]!.tracks += 1
                albums[albumID]!.familyMask |= mask
                if albums[albumID]!.year == nil, let year = song.year, year > 0 { albums[albumID]!.year = year }
                if plays > 0 {
                    albums[albumID]!.plays += plays
                    albums[albumID]!.playedSongs += 1
                }
            }

            addToFolders(song, plays: plays, mask: mask, artistKey: artistKey)
        }

        private mutating func albumArtistKey(_ name: String) -> String {
            if let key = artistNames[name] { return key }
            let key = SongDiscoveryMatching.artistKey(name)
            artistNames[name] = key
            return key
        }

        private mutating func addToFolders<Song: ListeningSongTraits>(
            _ song: Song,
            plays: Int,
            mask: UInt16,
            artistKey: String
        ) {
            let sourceID = song.sourceID
            guard !sourceID.isEmpty else { return }
            sourceSongs[sourceID, default: 0] += 1
            let components = song.filePath.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count >= 2 else { return }
            let depth = min(ListeningProfile.folderMaximumDepth, components.count - 1)
            let albumKey = song.albumID ?? ListeningTextKey.folded(song.albumTitle)
            var path = ""
            for level in 0..<depth {
                path = level == 0 ? String(components[0]) : path + "/" + components[level]
                let key = sourceID + "\u{1F}" + path
                if folderScopes[key] == nil {
                    folderScopes[key] = ListeningFolderScope(sourceID: sourceID, path: path)
                }
                var tally = folders[key] ?? FolderTally()
                tally.songs += 1
                tally.plays += plays
                tally.familyMask |= mask
                if !albumKey.isEmpty, tally.albums.count < ListeningProfile.folderMinimumAlbums,
                   !tally.albums.contains(albumKey) {
                    tally.albums.append(albumKey)
                }
                if !artistKey.isEmpty, tally.artists[artistKey] != nil || tally.artists.count < 12 {
                    tally.artists[artistKey, default: 0] += 1
                    if tally.artistNames[artistKey] == nil { tally.artistNames[artistKey] = artists[artistKey]?.name }
                }
                folders[key] = tally
            }
        }

        func finish() -> ListeningProfile {
            let hasListening = recentPlays >= ListeningIntentEngine.minimumRecentPlaysForRanking
            let artistList = artists.map { key, tally in
                Artist(key: key, name: tally.name, songCount: tally.songs, recentPlays: tally.plays, playedSongs: tally.playedSongs)
            }
            .filter { !$0.name.isEmpty }
            .sorted {
                if hasListening, $0.recentPlays != $1.recentPlays { return $0.recentPlays > $1.recentPlays }
                if $0.songCount != $1.songCount { return $0.songCount > $1.songCount }
                return $0.key < $1.key
            }
            let albumList = albumOrder.compactMap { albumID -> Album? in
                guard let tally = albums[albumID], tally.tracks >= AlbumCandidateIndex.minimumTrackCount,
                      !tally.title.isEmpty else { return nil }
                return Album(
                    albumID: albumID,
                    title: tally.title,
                    artistName: tally.artistName,
                    artistKey: tally.artistKey,
                    year: tally.year,
                    trackCount: tally.tracks,
                    familyMask: tally.familyMask,
                    recentPlays: tally.plays,
                    playedSongs: tally.playedSongs
                )
            }
            return ListeningProfile(
                songCount: songCount,
                recentPlays: recentPlays,
                folders: categoryFolders(recentPlays: recentPlays),
                artists: Array(artistList.prefix(ListeningProfile.artistLimit)),
                albums: albumList,
                losslessSongs: losslessSongs,
                hiResSongs: hiResSongs,
                losslessPlays: losslessPlays,
                hiResPlays: hiResPlays,
                rotationSongIDs: rotation
                    .sorted { $0.plays > $1.plays }
                    .prefix(ListeningProfile.rotationLimit)
                    .map(\.id),
                familySongs: familySongs,
                familyPlays: familyPlays,
                decadeSongs: decadeSongs,
                decadePlays: decadePlays
            )
        }

        /// Folders that read as "a kind of music": enough songs from several
        /// albums and artists, not the whole source, not a storage name, and
        /// either sitting next to another such folder (the listener sorts by
        /// kind at that level) or played a lot on its own. A folder inside
        /// another chosen one is left out.
        private func categoryFolders(recentPlays: Int) -> [Folder] {
            var candidates: [(key: String, tally: FolderTally, scope: ListeningFolderScope, name: String)] = []
            for (key, tally) in folders {
                guard let scope = folderScopes[key],
                      tally.songs >= ListeningProfile.folderMinimumSongs,
                      tally.albums.count >= ListeningProfile.folderMinimumAlbums,
                      tally.artists.count >= ListeningProfile.folderMinimumArtists else { continue }
                let sourceTotal = sourceSongs[scope.sourceID] ?? 0
                guard Double(tally.songs) <= Double(sourceTotal) * 0.9 else { continue }
                let rawName = scope.path.split(separator: "/").last.map(String.init) ?? scope.path
                guard let name = ListeningFolderNaming.displayName(rawName) else { continue }
                candidates.append((key, tally, scope, name))
            }
            var siblings: [String: Int] = [:]
            for candidate in candidates {
                siblings[parentKey(candidate.scope), default: 0] += 1
            }
            let chosen = candidates.filter { candidate in
                if siblings[parentKey(candidate.scope), default: 0] >= 2 { return true }
                return recentPlays >= ListeningIntentEngine.minimumRecentPlaysForRanking
                    && Double(candidate.tally.plays) >= Double(recentPlays) * 0.15
            }
            let chosenPaths = Set(chosen.map { $0.scope })
            let outermost = chosen.filter { candidate in
                var path = candidate.scope.path
                while let slash = path.lastIndex(of: "/") {
                    path = String(path[..<slash])
                    if chosenPaths.contains(ListeningFolderScope(sourceID: candidate.scope.sourceID, path: path)) {
                        return false
                    }
                }
                return true
            }
            return outermost
                .sorted {
                    if $0.tally.plays != $1.tally.plays { return $0.tally.plays > $1.tally.plays }
                    if $0.tally.songs != $1.tally.songs { return $0.tally.songs > $1.tally.songs }
                    return $0.key < $1.key
                }
                .map { candidate in
                    Folder(
                        scope: candidate.scope,
                        name: candidate.name,
                        songCount: candidate.tally.songs,
                        recentPlays: candidate.tally.plays,
                        familyMask: candidate.tally.familyMask,
                        topArtists: candidate.tally.artists
                            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                            .prefix(3)
                            .compactMap { candidate.tally.artistNames[$0.key] }
                    )
                }
        }

        private func parentKey(_ scope: ListeningFolderScope) -> String {
            let parent = scope.path.lastIndex(of: "/").map { String(scope.path[..<$0]) } ?? ""
            return scope.sourceID + "\u{1F}" + parent
        }
    }
}

/// Folder names worth showing as an intent: storage names ("Music",
/// "Downloads") say nothing about the music, and a leading "01-" is sorting,
/// not part of the name.
public enum ListeningFolderNaming {
    static let latinStorageNames: [String] = [
        "music", "musics", "my music", "mymusic", "songs", "song", "audio", "media", "mp3", "flac",
        "download", "downloads", "albums", "album", "artists", "artist", "library", "music library",
        "itunes", "itunes media", "itunes music", "cloudmusic", "netease", "qqmusic", "kugou", "kuwo",
        "other", "others", "misc", "new folder", "untitled folder", "share", "shared", "public", "home",
        "volume1", "volume2", "data", "files", "backup", "temp", "tmp", "inbox", "unsorted",
    ]
    // Folder names matched against the listener's folders; never shown.
    static let cjkStorageNames: [String] = ["音乐", "音樂", "歌曲", "我的音乐", "我的音樂", "下载", "下載", "专辑", "專輯", "歌手", "艺人", "藝人", "未分类", "未分類", "其他", "其它", "新建文件夹", "新建資料夾", "备份", "備份", "临时", "臨時"]
    static let storageNames = Set(latinStorageNames + cjkStorageNames)

    /// Nil when the name is only storage.
    public static func displayName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "01. Pop", "02-纯音乐", "[03] 儿歌": drop the sort number.
        let trimmed = name.drop { $0 == "[" || $0 == "(" || $0 == "（" || $0 == "【" }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
                .drop { "]).）】-_.、: ".contains($0) }
                .trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { name = rest }
        }
        guard !name.isEmpty, name.count <= 40 else { return nil }
        let folded = ListeningTextKey.folded(name)
        guard !storageNames.contains(folded) else { return nil }
        return name
    }
}

// MARK: - Personal intents

/// The "for you" intents the device works out on its own, from the profile.
/// They also serve as the fallback whenever no AI service can be asked.
public enum PersonalListeningIntentPolicy {
    public static let maximumIntents = 12
    public static let artistLimit = 4
    public static let albumLimit = 2
    public static let folderLimit = 6

    /// Plays needed before an artist or album counts as "yours".
    public static let artistMinimumPlays = 6
    public static let albumMinimumPlays = 8
    public static let minimumPlayedSongs = 3

    public static func intents(from profile: ListeningProfile) -> [ListeningIntent] {
        var result: [ListeningIntent] = []
        if let rotation = rotationIntent(profile) { result.append(rotation) }
        result.append(contentsOf: artistIntents(profile))
        result.append(contentsOf: albumIntents(profile))
        result.append(contentsOf: qualityIntents(profile))
        let room = max(0, maximumIntents - result.count)
        result.append(contentsOf: folderIntents(profile).prefix(min(folderLimit, room)))
        return Array(result.prefix(maximumIntents))
    }

    static func rotationIntent(_ profile: ListeningProfile) -> ListeningIntent? {
        guard profile.rotationSongIDs.count >= ListeningIntentEngine.minimumSongCount else { return nil }
        return ListeningIntent(
            id: "personal:rotation",
            source: .personal(id: "rotation"),
            category: .personal,
            symbolName: "repeat",
            titleKey: "listening_intent_personal_rotation",
            rule: ListeningIntentRule(songIDs: profile.rotationSongIDs)
        )
    }

    public static func artistIntent(_ artist: ListeningProfile.Artist) -> ListeningIntent {
        ListeningIntent(
            id: "personal:artist:" + artist.key,
            source: .personal(id: "artist:" + artist.key),
            category: .personal,
            symbolName: "music.mic",
            titleKey: nil,
            rule: ListeningIntentRule(artistKeys: [artist.key]),
            customTitle: artist.name
        )
    }

    static func artistIntents(_ profile: ListeningProfile) -> [ListeningIntent] {
        let minimum = ListeningIntentEngine.minimumSongCount
        let artists: [ListeningProfile.Artist]
        if profile.hasListening {
            artists = profile.artists.filter {
                $0.recentPlays >= artistMinimumPlays && $0.playedSongs >= minimumPlayedSongs && $0.songCount >= minimum
            }
        } else {
            // Before there is a history, what someone collected a lot of is
            // the best guess at what they like.
            artists = Array(profile.artists.filter {
                $0.songCount >= 40 && Double($0.songCount) >= Double(profile.songCount) * 0.05
            }.prefix(2))
        }
        return artists.prefix(artistLimit).map(artistIntent)
    }

    public static func albumLikeIntent(_ album: ListeningProfile.Album, profile: ListeningProfile) -> ListeningIntent? {
        let similar = profile.similarAlbums(to: album.albumID)
        guard similar.reduce(0, { $0 + $1.trackCount }) >= ListeningIntentEngine.minimumSongCount else { return nil }
        return ListeningIntent(
            id: "personal:albumLike:" + album.albumID,
            source: .personal(id: "albumLike:" + album.albumID),
            category: .personal,
            symbolName: "square.stack.fill",
            titleKey: "listening_intent_personal_albumLike %@",
            rule: ListeningIntentRule(albumIDs: similar.map(\.albumID)),
            playback: ListeningIntentPlayback(songLimit: 60, shuffles: false, playsAlbumsInSequence: true),
            titleArgument: album.title
        )
    }

    static func albumIntents(_ profile: ListeningProfile) -> [ListeningIntent] {
        guard profile.hasListening else { return [] }
        return profile.albums
            .filter { $0.recentPlays >= albumMinimumPlays && $0.playedSongs >= minimumPlayedSongs }
            .sorted { $0.recentPlays != $1.recentPlays ? $0.recentPlays > $1.recentPlays : $0.albumID < $1.albumID }
            .prefix(albumLimit * 2)
            .compactMap { albumLikeIntent($0, profile: profile) }
            .prefix(albumLimit)
            .map { $0 }
    }

    public static func qualityIntent(_ quality: ListeningAudioQuality) -> ListeningIntent {
        let isHiRes = quality == .hiRes
        return ListeningIntent(
            id: isHiRes ? "personal:hiRes" : "personal:lossless",
            source: .personal(id: isHiRes ? "hiRes" : "lossless"),
            category: .personal,
            symbolName: isHiRes ? "hifispeaker.fill" : "waveform",
            titleKey: isHiRes ? "listening_intent_personal_hiRes" : "listening_intent_personal_lossless",
            rule: ListeningIntentRule(minimumQuality: isHiRes ? .hiRes : .lossless)
        )
    }

    /// Lossless when most of the listening is lossless (or, before there is a
    /// history, a good part of the library is); hi-res likewise at a lower
    /// bar. Neither when it would be the whole library anyway.
    static func qualityIntents(_ profile: ListeningProfile) -> [ListeningIntent] {
        let minimum = ListeningIntentEngine.minimumSongCount
        let library = Double(max(profile.songCount, 1))
        func worthIt(songs: Int, plays: Int, playShare: Double, libraryShare: Double) -> Bool {
            guard songs >= minimum, Double(songs) < library * 0.95 else { return false }
            if profile.hasListening {
                return Double(plays) >= Double(profile.recentPlays) * playShare
            }
            return Double(songs) >= library * libraryShare
        }
        let hiRes = worthIt(songs: profile.hiResSongs, plays: profile.hiResPlays, playShare: 0.3, libraryShare: 0.2)
        var lossless = worthIt(songs: profile.losslessSongs, plays: profile.losslessPlays, playShare: 0.5, libraryShare: 0.3)
        // Nearly every lossless file is hi-res: one card says it.
        if hiRes, Double(profile.hiResSongs) >= Double(profile.losslessSongs) * 0.9 { lossless = false }
        var result: [ListeningIntent] = []
        if hiRes { result.append(qualityIntent(.hiRes)) }
        if lossless { result.append(qualityIntent(.lossless)) }
        return result
    }

    public static func folderIntent(_ folder: ListeningProfile.Folder) -> ListeningIntent {
        let key = folder.scope.sourceID + "/" + folder.scope.path
        return ListeningIntent(
            id: "personal:folder:" + key,
            source: .personal(id: "folder:" + key),
            category: .personal,
            symbolName: "folder.fill",
            titleKey: nil,
            rule: ListeningIntentRule(folders: [folder.scope]),
            customTitle: folder.name
        )
    }

    static func folderIntents(_ profile: ListeningProfile) -> [ListeningIntent] {
        profile.folders.map(folderIntent)
    }
}
