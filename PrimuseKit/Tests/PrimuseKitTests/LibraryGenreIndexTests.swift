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
