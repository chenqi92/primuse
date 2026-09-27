import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library genre index")
struct LibraryGenreIndexTests {
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
        artwork: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: id,
            albumID: albumID,
            duration: 180,
            fileFormat: .mp3,
            filePath: "\(id).mp3",
            sourceID: "source",
            genre: genre,
            year: year,
            coverArtFileName: artwork
        )
    }
}
