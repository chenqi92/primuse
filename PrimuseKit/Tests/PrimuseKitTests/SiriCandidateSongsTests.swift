import Testing
@testable import PrimuseKit

/// `SiriMediaSearchResolver.candidateSongs`:把流式挑出的候选交给各个解析入口,结果与交整库相同。
/// 随机曲库带同名歌、大小写与变音符号的写法、错字、没有专辑 / 艺人 id 的歌、合辑、斜杠分隔的流派、
/// 不能放的歌与拼音;随机请求覆盖各种类、各档歌名匹配与点了 id 的请求。
@Suite("Siri candidate songs")
struct SiriCandidateSongsTests {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
        mutating func pick<T>(_ values: [T]) -> T { values[int(values.count)] }
        mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
    }

    private static let titles = ["晴天", "Love Story", "love story", "Lové Story", "夜曲", "Yesterday", "Yesterdays",
                                 "Hello", "Hello Again", "七里香", "Mikham", "Jazz", "Jazz FM", "Blue Bird", "Blue"]
    private static let artists = ["周杰伦", "Taylor Swift", "taylor swift", "The Beatles", "Beatles", "Adele", "告五人"]
    private static let albums = ["叶惠美", "Fearless", "fearless", "Abbey Road", "25", "Hello", "Love"]
    private static let genres = ["Pop", "Rock/Pop", "Jazz", "Mandopop", "Rock", "R&B"]
    private static let pinyin = ["qing tian", "ye qu", "zhou jie lun", "ye hui mei", nil, nil]

    private static func library(seed: UInt64) -> [Song] {
        var random = Generator(state: seed)
        return (0..<160).map { index in
            let artist = random.chance(90) ? random.pick(artists) : nil
            let album = random.chance(85) ? random.pick(albums) : nil
            var title = random.pick(titles)
            if random.chance(10) { title += " (Live)" }
            var song = Song(
                id: "song-\(seed)-\(index)",
                title: title,
                albumID: album.flatMap { name in random.chance(85) ? "album-\(name.lowercased())-\(random.int(3))" : nil },
                artistID: artist.flatMap { name in random.chance(85) ? "artist-\(name.lowercased())" : nil },
                albumTitle: album,
                artistName: artist,
                trackNumber: random.int(12) + 1,
                discNumber: random.chance(20) ? 2 : 1,
                duration: random.chance(8) ? 0 : 180,
                fileFormat: random.chance(30) ? .mp3 : .flac,
                filePath: random.chance(8) ? "" : "/\(index).flac",
                sourceID: "source",
                genre: random.chance(85) ? random.pick(genres) : nil
            )
            song.titlePinyin = random.pick(pinyin)
            song.artistPinyin = random.pick(pinyin)
            song.albumPinyin = random.pick(pinyin)
            return song
        }
    }

    private static func mutated(_ name: String, _ random: inout Generator) -> String {
        switch random.int(5) {
        case 0: return name
        case 1: return String(name.prefix(max(1, name.count - 2)))
        case 2: return name.uppercased()
        case 3: return "play " + name
        default:
            var characters = Array(name)
            if characters.count > 3 { characters[characters.count / 2] = "x" }
            return String(characters)
        }
    }

    private static func query(_ random: inout Generator) -> SiriMediaSearchQuery {
        let kind = random.pick([SiriMediaSearchKind.song, .album, .artist, .genre, .music, .music, .playlist])
        func maybe(_ values: [String], _ percent: Int) -> String? {
            guard random.chance(percent) else { return nil }
            let name = random.pick(values)
            return mutated(name, &random)
        }
        return SiriMediaSearchQuery(
            kind: kind,
            mediaName: maybe(titles + albums + artists + genres, 60),
            artistName: maybe(artists, 30),
            albumName: maybe(albums, 25),
            genreNames: random.chance(15) ? [random.pick(genres)] : []
        )
    }

    private static func identifiers(_ songs: [Song], _ random: inout Generator) -> [String] {
        guard random.chance(25) else { return [] }
        let song = random.pick(songs)
        var ids: [String] = []
        switch random.int(5) {
        case 0: ids.append(SiriMediaIdentifier.namespaced(song.id, as: "song"))
        case 1: ids.append(SiriMediaIdentifier.namespaced(song.albumID ?? "none", as: "album"))
        case 2: ids.append(SiriMediaIdentifier.namespaced(song.artistID ?? "none", as: "artist"))
        case 3: ids.append(SiriMediaIdentifier.namespaced(random.pick(genres), as: "genre"))
        default: ids.append(song.id)
        }
        if random.chance(30) { ids.append(SiriMediaIdentifier.namespaced("missing", as: "song")) }
        return ids
    }

    private static func summary(_ resolution: SiriMediaSearchResolution?) -> String {
        guard let resolution else { return "nil" }
        return "q=\(resolution.queue.map(\.id)) c=\(resolution.candidates.map(\.id)) d=\(resolution.needsDisambiguation)"
    }

    private static func summary(_ target: SiriUntypedRequestResolver.Target?) -> String {
        switch target {
        case nil: return "nil"
        case .songs(let resolution)?: return "songs " + summary(resolution)
        case .spokenWordItems(let resolution)?: return "spoken " + summary(resolution)
        case .radio(let station)?: return "radio \(station.selected.id)"
        case .book(let book)?: return "book \(book.selected.id)"
        }
    }

    @Test("Candidates give every resolver entry point the same answer as the whole library", arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func candidatesMatchTheWholeLibrary(seed: UInt64) throws {
        let songs = Self.library(seed: seed)
        let spoken = Array(Self.library(seed: seed &+ 100).prefix(20))
        var random = Generator(state: seed &* 31)
        var passes = 0
        var answered = 0
        for step in 0..<250 {
            let query = Self.query(&random)
            let ids = Self.identifiers(songs, &random)
            let candidates = try SiriMediaSearchResolver.candidateSongs(query: query, resolvedItemIDs: ids) { body in
                passes += 1
                for song in songs { try body(song) }
            }
            let allPlayable = candidates.allSatisfy(\.isPlayable)
            #expect(allPlayable)
            for tiers in [SiriSongMatchTiers.strictThenRelaxed, .strictOnly, .relaxedOnly] {
                let whole = SiriMediaSearchResolver.resolve(query: query, resolvedItemIDs: ids, songs: songs, songMatching: tiers)
                let narrowed = SiriMediaSearchResolver.resolve(query: query, resolvedItemIDs: ids, songs: candidates, songMatching: tiers)
                #expect(Self.summary(whole) == Self.summary(narrowed), "step \(step) \(query) ids=\(ids) tiers=\(tiers)")
                if tiers == .strictThenRelaxed, whole != nil { answered += 1 }
            }
            guard ids.isEmpty else { continue }
            let preferring = SiriMediaSearchResolver.resolvePreferringMusic(query: query, musicSongs: songs, spokenWordSongs: spoken)
            let preferringNarrowed = SiriMediaSearchResolver.resolvePreferringMusic(
                query: query, musicSongs: candidates, spokenWordSongs: spoken
            )
            #expect(Self.summary(preferring) == Self.summary(preferringNarrowed), "step \(step) \(query)")
            let untyped = SiriUntypedRequestResolver.resolve(query: query, songs: songs, radioItems: [], spokenWordSongs: spoken)
            let untypedNarrowed = SiriUntypedRequestResolver.resolve(
                query: query, songs: candidates, radioItems: [], spokenWordSongs: spoken
            )
            #expect(Self.summary(untyped) == Self.summary(untypedNarrowed), "step \(step) \(query)")
        }
        // 不是每个请求都要走曲库(歌单这类直接没有候选),但要有足够多的请求真的找到了歌。
        #expect(passes > 100)
        #expect(answered > 60, "answered \(answered) of 250")
    }

    @Test("A named request keeps only the songs that can match")
    func namedRequestsStayNarrow() throws {
        let songs = Self.library(seed: 9)
        let query = SiriMediaSearchQuery(kind: .song, mediaName: "七里香")
        let candidates = try SiriMediaSearchResolver.candidateSongs(query: query) { body in
            for song in songs { try body(song) }
        }
        #expect(!candidates.isEmpty)
        #expect(candidates.count < songs.count / 3)
        let allNamed = candidates.allSatisfy { $0.title.contains("七里香") }
        #expect(allNamed)

        let album = SiriMediaSearchQuery(kind: .album, albumName: "Abbey Road")
        var passes = 0
        let albumSongs = try SiriMediaSearchResolver.candidateSongs(query: album) { body in
            passes += 1
            for song in songs { try body(song) }
        }
        #expect(passes == 2, "albums: one pass for the groups, one for their songs")
        #expect(!albumSongs.isEmpty)
        let allOnTheAlbum = albumSongs.allSatisfy { $0.albumTitle == "Abbey Road" }
        #expect(allOnTheAlbum)

        let everything = try SiriMediaSearchResolver.candidateSongs(query: SiriMediaSearchQuery(kind: .music)) { body in
            for song in songs { try body(song) }
        }
        #expect(everything.map(\.id) == songs.filter(\.isPlayable).map(\.id))
    }
}
