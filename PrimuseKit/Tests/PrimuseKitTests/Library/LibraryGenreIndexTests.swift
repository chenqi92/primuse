import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library genre index")
struct LibraryGenreIndexTests {
    @Test("Every repeated embedded genre survives song persistence and indexes the album")
    func indexesRepeatedGenresAfterSongRoundTrip() throws {
        let metadata = EmbeddedTagMetadataParser.metadata(fromTagValues: [
            "GENRE": ["J-Pop", "Vocaloid"],
        ])
        let songs = (1...16).map {
            song("track-\($0)", genre: metadata.genre, albumID: "evils-kingdom")
        }
        let restored = try JSONDecoder().decode([Song].self, from: JSONEncoder().encode(songs))
        let index = LibraryGenreIndexBuilder.build(from: restored)

        #expect(Set(index.genres.map(\.name)) == ["J-Pop", "Vocaloid"])
        for id in ["j-pop", "vocaloid"] {
            #expect(index.songIDsByGenreID[id] == songs.map(\.id))
            #expect(index.albumIDsByGenreID[id] == ["evils-kingdom"])
            #expect(index.genres.first { $0.id == id }?.songCount == 16)
            #expect(index.genres.first { $0.id == id }?.albumCount == 1)
        }
    }

    @Test("Slashes, commas and bars stay part of a genre name unless the user opted in")
    func keepsCompoundNamesByDefault() {
        let raw = "Hip-hop/Rap, Soul | Funk"
        #expect(GenreTagValues.names(in: raw) == [raw])
        #expect(GenreTagValues.names(in: raw, alsoSplitting: []) == [raw])
        #expect(GenreTagValues.joined(["R&B/Soul", "Pop"]) == "R&B/Soul; Pop")
    }

    @Test("Each opted-in separator splits only at its own characters")
    func splitsAtChosenSeparators() {
        #expect(GenreTagValues.names(in: "Hip-hop/Rap", alsoSplitting: .slash) == ["Hip-hop", "Rap"])
        #expect(GenreTagValues.names(in: "Pop／Rock; Jazz", alsoSplitting: .slash) == ["Pop", "Rock", "Jazz"])
        #expect(GenreTagValues.names(in: "Rock, Pop、民谣，流行", alsoSplitting: .comma) == ["Rock", "Pop", "民谣", "流行"])
        #expect(GenreTagValues.names(in: "Rock|Pop\\Jazz", alsoSplitting: .bar) == ["Rock", "Pop", "Jazz"])
        #expect(GenreTagValues.names(in: "Hip-hop/Rap, Soul", alsoSplitting: .comma) == ["Hip-hop/Rap", "Soul"])
        #expect(GenreTagValues.names(in: "R&B / Soul / r&b", alsoSplitting: [.slash, .comma, .bar]) == ["R&B", "Soul"])
        #expect(GenreTagValues.names(in: "Drum & Bass", alsoSplitting: [.slash, .comma, .bar]) == ["Drum & Bass"])
    }

    @Test("An opted-in separator files a song under every part and merges with existing genres")
    func indexSplitsAtChosenSeparators() {
        let songs = [
            song("a", genre: "Hip-hop/Rap", albumID: "one"),
            song("b", genre: "rap", albumID: "two"),
            song("c", genre: "Hip-Hop", albumID: "two"),
        ]
        let plain = LibraryGenreIndexBuilder.build(from: songs, alsoSplitting: [])
        #expect(plain.genres.map(\.id) == ["hip-hop", "hip-hop/rap", "rap"])

        let split = LibraryGenreIndexBuilder.build(from: songs, alsoSplitting: .slash)
        #expect(split.genres.map(\.id) == ["hip-hop", "rap"])
        #expect(split.songIDsByGenreID["hip-hop"] == ["a", "c"])
        #expect(split.songIDsByGenreID["rap"] == ["a", "b"])
        #expect(split.albumIDsByGenreID["rap"] == ["one", "two"])
    }

    @Test("Explicit genre separators do not duplicate membership or counts")
    func indexesDistinctGenreNames() {
        let index = LibraryGenreIndexBuilder.build(from: [
            song("a", genre: " J-Pop ； Vocaloid; VOCALOID\0ＶＯＣＡＬＯＩＤ; ", albumID: "one"),
            song("b", genre: "Vócaloid; J-Pop", albumID: "one"),
            song("c", genre: " ; \0 ; ", albumID: "two"),
            song("d", genre: "Vocaloid", albumID: "two"),
        ])

        #expect(index.genres.map(\.name) == ["J-Pop", "Vocaloid"])
        #expect(index.songIDsByGenreID["j-pop"] == ["a", "b"])
        #expect(index.songIDsByGenreID["vocaloid"] == ["a", "b", "d"])
        #expect(index.albumIDsByGenreID["vocaloid"] == ["one", "two"])
        #expect(index.genres.first { $0.id == "vocaloid" }?.songCount == 3)
        #expect(index.genres.first { $0.id == "vocaloid" }?.albumCount == 2)
        #expect(index.genres.first { $0.id == "vocaloid" }?.representativeSongIDs == ["a", "d", "b"])
    }

    @Test("ID3 genre references and NUL-separated values become genre names")
    func normalizesID3GenreFrames() {
        #expect(ID3GenreNames.standard.count == 192)
        #expect(ID3GenreNames.names(fromTCON: "(17)") == ["Rock"])
        #expect(ID3GenreNames.names(fromTCON: "(17)(13)") == ["Rock", "Pop"])
        #expect(ID3GenreNames.names(fromTCON: "(17)Rock") == ["Rock"])
        #expect(ID3GenreNames.names(fromTCON: "(4)Eurodisco") == ["Disco", "Eurodisco"])
        #expect(ID3GenreNames.names(fromTCON: "(RX)(CR)") == ["Remix", "Cover"])
        #expect(ID3GenreNames.names(fromTCON: "17") == ["Rock"])
        #expect(ID3GenreNames.names(fromTCON: "Rock\0Pop\0rock") == ["Rock", "Pop"])
        #expect(ID3GenreNames.names(fromTCON: "((Live) Sessions") == ["(Live) Sessions"])
        #expect(ID3GenreNames.names(fromTCON: "(Live) Rock") == ["(Live) Rock"])
        #expect(ID3GenreNames.names(fromTCON: "(999)") == ["(999)"])
        #expect(ID3GenreNames.names(fromTCON: "2000") == ["2000"])
        #expect(ID3GenreNames.normalizedTCON("(17)\0流行") == "Rock; 流行")
        #expect(ID3GenreNames.normalizedTCON(" \0 ") == nil)
        #expect(ID3GenreNames.name(forMP4GenreCode: 18) == "Rock")
        #expect(ID3GenreNames.name(forMP4GenreCode: 0) == nil)
    }

    @Test("ID3 slash convention splits combinations but keeps known compound genre names")
    func splitsID3SlashCombinations() {
        #expect(GenreSlashConvention.split("Rock/Pop") == ["Rock", "Pop"])
        #expect(GenreSlashConvention.split("流行/摇滚 / 电子") == ["流行", "摇滚", "电子"])
        #expect(GenreSlashConvention.split("R&B/Soul") == ["R&B/Soul"])
        #expect(GenreSlashConvention.split("Hip Hop / Rap") == ["Hip Hop / Rap"])
        #expect(GenreSlashConvention.split("Rock/Hip-Hop/Rap") == ["Rock", "Hip-Hop/Rap"])
        #expect(GenreSlashConvention.split("Singer/Songwriter/Folk") == ["Singer/Songwriter", "Folk"])
        #expect(GenreSlashConvention.split("Breaks / Breakbeat / UK Bass") == ["Breaks / Breakbeat / UK Bass"])
        #expect(GenreSlashConvention.split("嘻哈/说唱") == ["嘻哈/说唱"])
        #expect(GenreSlashConvention.split("Pop／Rock") == ["Pop／Rock"])
        #expect(GenreSlashConvention.split("Techno (Peak Time / Driving)") == ["Techno (Peak Time / Driving)"])
        #expect(GenreSlashConvention.split("N/A") == ["N/A"])
        #expect(GenreSlashConvention.split("Rock/") == ["Rock"])
        #expect(GenreSlashConvention.split("Drum & Bass") == ["Drum & Bass"])
        #expect(GenreSlashConvention.isProtected(" hip-hop/rap "))
        #expect(!GenreSlashConvention.isProtected("Rock/Pop"))

        #expect(GenreSlashConvention.applies(to: .mp3))
        #expect(GenreSlashConvention.applies(to: .aiff))
        #expect(!GenreSlashConvention.applies(to: .flac))
        #expect(!GenreSlashConvention.applies(to: .m4a))
        #expect(!GenreSlashConvention.applies(to: nil))
    }

    @Test("The user's slash switch still wins over the format convention")
    func userSlashSwitchOverridesConvention() {
        #expect(GenreTagValues.names(in: "Rock/Pop; R&B/Soul", alsoSplitting: [], slashConvention: true)
            == ["Rock", "Pop", "R&B/Soul"])
        #expect(GenreTagValues.names(in: "R&B/Soul", alsoSplitting: .slash, slashConvention: true) == ["R&B", "Soul"])
        #expect(GenreTagValues.names(in: "Rock/Pop", alsoSplitting: [], slashConvention: false) == ["Rock/Pop"])
        #expect(GenreTagValues.names(in: "流行；摇滚") == ["流行", "摇滚"])
        #expect(GenreTagValues.primary(in: "流行；摇滚") == "流行")
        #expect(GenreTagValues.primary(in: " 摇滚 ") == " 摇滚 ")
    }

    @Test("ID3 formats follow the slash convention in the genre index; other formats keep the name")
    func indexAppliesSlashConventionPerFormat() {
        let songs = [
            song("a", genre: "Rock/Pop", albumID: "one"),
            song("b", genre: "Rock/Pop", albumID: "two", format: .flac),
            song("c", genre: "R&B/Soul", albumID: "three"),
        ]
        let index = LibraryGenreIndexBuilder.build(from: songs, alsoSplitting: [])
        #expect(index.genres.map(\.id) == ["pop", "r&b/soul", "rock", "rock/pop"])
        #expect(index.songIDsByGenreID["rock"] == ["a"])
        #expect(index.songIDsByGenreID["rock/pop"] == ["b"])

        let everySlash = LibraryGenreIndexBuilder.build(from: songs, alsoSplitting: .slash)
        #expect(everySlash.genres.map(\.id) == ["pop", "r&b", "rock", "soul"])
        #expect(everySlash.songIDsByGenreID["rock"] == ["a", "b"])
    }

    @Test("The genre page hint counts unsplit separators the user has not enabled")
    func countsUnsplitSeparatorNames() {
        let names = ["Rock/Pop", "R&B/Soul", "Folk, World", "Jazz", "Pop|Dance"]
        #expect(GenreSeparatorHint.unsplitNameCount(in: names, enabled: []) == 3)
        #expect(GenreSeparatorHint.unsplitNameCount(in: names, enabled: [.slash, .comma]) == 1)
        #expect(GenreSeparatorHint.shouldHint(unsplitCount: 3, totalCount: 30))
        #expect(!GenreSeparatorHint.shouldHint(unsplitCount: 3, totalCount: 31))
        #expect(!GenreSeparatorHint.shouldHint(unsplitCount: 2, totalCount: 4))
    }

    @Test("Single-genre comparisons use the first of several genres")
    func primaryGenreIsTheFirstLabel() {
        #expect(GenreTagValues.primary(in: "J-Pop; Vocaloid") == "J-Pop")
        #expect(GenreTagValues.primary(in: "J-Pop；Vocaloid") == "J-Pop")
        #expect(GenreTagValues.primary(in: " ; Vocaloid\0J-Pop") == "Vocaloid")
        #expect(GenreTagValues.primary(in: "R&B/Soul") == "R&B/Soul")
        #expect(GenreTagValues.primary(in: "Rock, Live") == "Rock, Live")
        #expect(GenreTagValues.primary(in: " ; ") == nil)
        #expect(GenreTagValues.primary(in: nil) == nil)
    }

    @Test("Server genre arrays decode leniently and join when there are several")
    func serverGenreListDecodesLeniently() throws {
        func decode(_ json: String) throws -> ServerGenreList {
            try JSONDecoder().decode(ServerGenreList.self, from: Data(json.utf8))
        }
        #expect(try decode(#"[{"name":"Rock"},{"name":"Pop"},{"name":"rock"}]"#).genre(fallback: "Rock") == "Rock; Pop")
        #expect(try decode(#"["J-Pop","Vocaloid"]"#).genre(fallback: nil) == "J-Pop; Vocaloid")
        #expect(try decode(#"[{"name":"Rock"}]"#).genre(fallback: "Rock (Live)") == "Rock (Live)")
        #expect(try decode(#"[{"name":"Rock"}]"#).genre(fallback: nil) == "Rock")
        #expect(try decode(#""Rock""#).names.isEmpty)
        #expect(try decode(#"[{"id":1}]"#).genre(fallback: "Jazz") == "Jazz")

        struct Child: Decodable { let genre: String?; let genres: ServerGenreList? }
        let child = try JSONDecoder().decode(Child.self, from: Data(#"{"genre":"Rock","genres":{"bad":true}}"#.utf8))
        #expect(child.genres?.genre(fallback: child.genre) == "Rock")
    }

    @Test("Equivalent labels share a category")
    func normalizesEquivalentLabels() {
        let index = LibraryGenreIndexBuilder.build(from: [
            song("a", genre: "  Pop  ", albumID: "one"),
            song("b", genre: "pop", albumID: "two"),
            song("c", genre: "ＰＯＰ", albumID: "two"),
        ])

        #expect(index.genres.count == 1)
        #expect(index.genres.first?.name == "Pop")
        #expect(index.genres.first?.songCount == 3)
        #expect(index.genres.first?.albumCount == 2)
    }

    @Test("Punctuation remains part of the label")
    func preservesCompoundLabels() {
        let index = LibraryGenreIndexBuilder.build(from: [
            song("a", genre: "R&B/Soul"),
            song("b", genre: "Rock, Live"),
        ])

        #expect(Set(index.genres.map(\.name)) == ["R&B/Soul", "Rock, Live"])
        #expect(index.genres.count == 2)
    }

    @Test("Missing labels are ignored")
    func ignoresMissingLabels() {
        let index = LibraryGenreIndexBuilder.build(from: [
            song("a", genre: nil),
            song("b", genre: "  \n "),
        ])

        #expect(index.genres.isEmpty)
        #expect(index.songIDsByGenreID.isEmpty)
    }

    @Test("Representative songs prefer artwork and distinct albums")
    func selectsRepresentativeSongs() {
        let index = LibraryGenreIndexBuilder.build(from: [
            song("blank", genre: "Jazz", albumID: "a", year: 2026),
            song("older", genre: "Jazz", albumID: "b", year: 2020, artwork: "b.jpg"),
            song("newer", genre: "Jazz", albumID: "c", year: 2025, artwork: "c.jpg"),
            song("same-album", genre: "Jazz", albumID: "c", year: 2026, artwork: "d.jpg"),
        ])

        let genre = index.genres.first
        #expect(genre?.albumCount == 3)
        #expect(genre?.representativeSongIDs == ["same-album", "older", "blank"])
    }

    @Test("Large categories preserve song order and first-seen albums")
    func indexesLargeCategory() {
        let songs = (0..<18_810).map { index in
            song(
                String(format: "%05d", index),
                genre: index.isMultiple(of: 2) ? " Pop " : "ＰＯＰ",
                albumID: "album-\(index % 240)",
                year: 2000 + index % 25,
                artwork: index.isMultiple(of: 10) ? "cover.jpg" : nil
            )
        }
        let started = ContinuousClock.now
        let index = LibraryGenreIndexBuilder.build(from: songs)
        print("Large genre index: \(started.duration(to: .now))")

        #expect(index.genres.count == 1)
        #expect(index.genres.first?.name == "Pop")
        #expect(index.genres.first?.songCount == songs.count)
        #expect(index.genres.first?.albumCount == 240)
        #expect(index.songIDsByGenreID["pop"] == songs.map(\.id))
        #expect(index.albumIDsByGenreID["pop"] == (0..<240).map { "album-\($0)" })
        #expect(index.genres.first?.representativeSongIDs == ["00020", "00070", "00120"])
    }

    @Test("Linear representative selection matches the full-sort reference")
    func representativeSelectionMatchesReference() {
        var generator = SplitMix64(seed: 0x5EED)
        for trial in 0..<400 {
            let count = Int(generator.next() % 40)
            let albumPool = Int(generator.next() % 6)
            let rawSongs = (0..<count).map { _ in
                let albumRoll = albumPool == 0 ? 0 : Int(generator.next() % UInt64(albumPool + 1))
                return song(
                    // 故意允许重复 id, 覆盖补位时的去重。
                    "id-\(generator.next() % 30)",
                    genre: "Jazz",
                    albumID: albumRoll == 0 ? (generator.next() % 2 == 0 ? nil : "  ") : "album-\(albumRoll)",
                    year: generator.next() % 3 == 0 ? nil : 2000 + Int(generator.next() % 4),
                    artwork: generator.next() % 3 == 0 ? "cover.jpg" : (generator.next() % 2 == 0 ? "" : nil)
                )
            }
            // 同 id 同排名的两首在旧实现里先后不定, 结果本就不唯一, 不参与比较。
            var rankKeys = Set<String>()
            let songs = rawSongs.filter { song in
                rankKeys.insert("\(song.id)|\(song.coverArtFileName?.isEmpty == false)|\(song.year ?? -1)").inserted
            }
            let expected = songs.isEmpty ? nil : referenceRepresentativeSongIDs(songs)
            let actual = LibraryGenreIndexBuilder.build(from: songs).genres.first?.representativeSongIDs
            #expect(actual == expected, "trial \(trial)")
        }
    }

    /// 改成线性挑选之前的实现, 原样保留作对照。
    private func referenceRepresentativeSongIDs(_ songs: [Song]) -> [String] {
        let ranked = songs.sorted { lhs, rhs in
            let lhsHasArtwork = lhs.coverArtFileName?.isEmpty == false
            let rhsHasArtwork = rhs.coverArtFileName?.isEmpty == false
            if lhsHasArtwork != rhsHasArtwork { return lhsHasArtwork }

            let lhsYear = lhs.year ?? Int.min
            let rhsYear = rhs.year ?? Int.min
            if lhsYear != rhsYear { return lhsYear > rhsYear }
            return lhs.id < rhs.id
        }

        var selected: [Song] = []
        var selectedIDs = Set<String>()
        var selectedAlbumIDs = Set<String>()

        for song in ranked {
            guard selected.count < 3 else { break }
            let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let albumID, !albumID.isEmpty,
                  selectedAlbumIDs.insert(albumID).inserted else { continue }
            selected.append(song)
            selectedIDs.insert(song.id)
        }

        if selected.count < 3 {
            for song in ranked where selectedIDs.insert(song.id).inserted {
                selected.append(song)
                if selected.count == 3 { break }
            }
        }
        return selected.map(\.id)
    }

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func song(
        _ id: String,
        genre: String?,
        albumID: String? = nil,
        year: Int? = nil,
        artwork: String? = nil,
        format: AudioFormat = .mp3
    ) -> Song {
        Song(
            id: id,
            title: id,
            albumID: albumID,
            duration: 180,
            fileFormat: format,
            filePath: "\(id).mp3",
            sourceID: "source",
            genre: genre,
            year: year,
            coverArtFileName: artwork
        )
    }
}
