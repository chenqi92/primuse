import Foundation
import Testing
@testable import PrimuseKit

@Suite("Song radio mixes similar songs instead of replaying one album")
struct SongRadioMixTests {
    /// id → (album, artist):「a1-3」= 专辑 a1 的第 3 首,艺人取专辑名第一个字母。
    private func album(_ id: String) -> String? {
        id.split(separator: "-").first.map(String.init)
    }

    private func artist(_ id: String) -> String? {
        id.first.map { String($0) }
    }

    @Test("A local ranking led by the seed's album keeps only one more track of it")
    func capsTheSeedsAlbum() {
        let ranking = ["a1-2", "a1-3", "a1-4", "a1-5", "a2-1", "a2-2", "b1-1", "c1-1", "d1-1"]
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [ranking],
            limit: 6,
            album: album,
            artist: artist
        )
        #expect(result.filter { $0.hasPrefix("a1-") }.count == 1)
        #expect(Set(result) == ["a1-2", "a2-1", "a2-2", "b1-1", "c1-1", "d1-1"])
    }

    @Test("Other artists are capped lower than the seed's own artist")
    func capsOtherArtists() {
        let ranking = ["b1-1", "b1-2", "b2-1", "b2-2", "b3-1", "b3-2", "c1-1"]
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [ranking],
            limit: 4,
            limits: .init(perAlbum: 2, perArtist: 3, seedArtist: 6),
            album: album,
            artist: artist
        )
        #expect(result.filter { $0.hasPrefix("b") }.count == 3)
        #expect(result.contains("c1-1"))
    }

    @Test("Sources take turns, so Last.fm picks and local picks are mixed")
    func interleavesSources() {
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [["b1-1", "c1-1"], ["d1-1", "e1-1"]],
            limit: 4,
            album: { _ in nil },
            artist: { _ in nil }
        )
        #expect(result == ["b1-1", "d1-1", "c1-1", "e1-1"])
    }

    @Test("Songs seen in an earlier source, the seed and excluded songs are skipped")
    func skipsDuplicatesAndExcluded() {
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [["a1-1", "b1-1", "x1-1"], ["b1-1", "c1-1"]],
            excluding: ["x1-1"],
            limit: 10,
            album: { _ in nil },
            artist: { _ in nil }
        )
        #expect(result.sorted() == ["b1-1", "c1-1"])
    }

    @Test("Fallback songs fill the radio before capped songs are let back in")
    func fallbackBeforeHeldBack() {
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [["a1-2", "a1-3", "a1-4"]],
            fallback: ["f1-1"],
            limit: 4,
            album: album,
            artist: artist
        )
        #expect(result.count == 4)
        #expect(Array(result.prefix(2)).sorted() == ["a1-2", "f1-1"])
        #expect(Set(result.suffix(2)) == ["a1-3", "a1-4"])
    }

    @Test("When caps leave the radio short, other artists come back before the seed's album")
    func relaxedFillPrefersOtherArtists() {
        let ranking = ["a1-2", "a1-3", "a1-4", "a2-1", "a2-2", "a2-3", "b1-1", "b1-2", "b1-3"]
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [ranking],
            limit: 8,
            album: album,
            artist: artist
        )
        // 限量收下 a1-2、a2-1、a2-2、b1-1、b1-2;补位先 b1-3,再 a2-3,最后才回到种子专辑。
        #expect(Set(result) == ["a1-2", "a2-1", "a2-2", "b1-1", "b1-2", "b1-3", "a2-3", "a1-3"])
    }

    @Test("A one-artist library still yields a full radio")
    func smallLibraryStillFills() {
        let ranking = (2...20).map { "a1-\($0)" }
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [ranking],
            limit: 12,
            album: album,
            artist: artist
        )
        #expect(result.count == 12)
        #expect(Set(result).count == 12)
    }

    @Test("The same artist is not played twice in a row when another is close by")
    func spacesOutArtists() {
        let ranking = ["a2-1", "a3-1", "a4-1", "b1-1", "c1-1", "d1-1"]
        let result = SongRadioMixPolicy.compose(
            seedID: "a1-1",
            sources: [ranking],
            limit: 6,
            album: album,
            artist: artist
        )
        #expect(result.count == 6)
        // 种子是 a,第一首就不该还是 a。
        #expect(artist(result[0]) != "a")
        for (lhs, rhs) in zip(result, result.dropFirst()) {
            #expect(artist(lhs) != artist(rhs))
        }
    }

    @Test("Spacing keeps the order when no other artist is near")
    func spacingKeepsOrderWhenStuck() {
        let ids = ["a1-1", "a1-2", "a1-3"]
        #expect(SongRadioMixPolicy.spacedOut(ids, after: "a", artist: artist) == ids)
    }

    @Test("Zero limit yields nothing")
    func zeroLimit() {
        #expect(SongRadioMixPolicy.compose(
            seedID: "a", sources: [["b"]], limit: 0, album: { _ in nil }, artist: { _ in nil }
        ).isEmpty)
    }
}

@Suite("Song radio groups albums and artists by name")
struct SongRadioGroupingTests {
    @Test("Featured and co-credited artists count as the first artist")
    func primaryArtist() {
        let key = SongRadioGrouping.artistKey("周杰伦")
        #expect(key != nil)
        #expect(SongRadioGrouping.artistKey("周杰伦 feat. 费玉清") == key)
        #expect(SongRadioGrouping.artistKey("周杰伦/费玉清") == key)
        #expect(SongRadioGrouping.artistKey("周杰伦、费玉清") == key)
        #expect(SongRadioGrouping.artistKey("  ") == nil)
        #expect(SongRadioGrouping.artistKey(nil) == nil)
    }

    @Test("A compilation title is not one album across artists")
    func albumKeyIncludesOwner() {
        let adele = SongRadioGrouping.albumKey(album: "Greatest Hits", albumArtist: nil, artist: "Adele")
        let queen = SongRadioGrouping.albumKey(album: "Greatest Hits", albumArtist: nil, artist: "Queen")
        #expect(adele != nil)
        #expect(adele != queen)
        let viaAlbumArtist = SongRadioGrouping.albumKey(album: "Hits", albumArtist: "Various", artist: "Adele")
        let other = SongRadioGrouping.albumKey(album: "Hits", albumArtist: "Various", artist: "Queen")
        #expect(viaAlbumArtist == other)
        #expect(SongRadioGrouping.albumKey(album: "", albumArtist: nil, artist: "Adele") == nil)
    }
}

@Suite("Last.fm similar tracks are matched to library songs")
struct SimilarTrackLibraryMatcherTests {
    private let library: [SimilarTrackLibraryMatcher.LibrarySong] = [
        .init(id: "s1", title: "晴天", artist: "周杰伦"),
        .init(id: "s2", title: "七里香 (Live)", artist: "周杰伦/费玉清"),
        .init(id: "s3", title: "江南", artist: "林俊杰"),
        .init(id: "s4", title: "Hello - Remastered", artist: "ADELE"),
        .init(id: "s5", title: "一千年以后", artist: "林俊杰"),
        .init(id: "s6", title: "她说", artist: "林俊杰"),
        .init(id: "s7", title: "无关", artist: nil),
        .init(id: "s8", title: "Someone Like You", artist: "Adele feat. Someone"),
    ]

    @Test("Version notes, case, co-credits and traditional script still match")
    func matchesTracks() {
        let result = SimilarTrackLibraryMatcher.match(
            tracks: [
                .init(title: "七里香", artist: "周杰倫"),
                .init(title: "Hello", artist: "Adele"),
                .init(title: "江南", artist: "林俊傑"),
                .init(title: "不存在", artist: "林俊杰"),
                .init(title: "晴天", artist: "Someone Else"),
            ],
            artists: [],
            songs: library
        )
        #expect(result.trackSongIDs == ["s2", "s4", "s3", nil, nil])
    }

    @Test("Similar artists bring several of their songs, in the given order")
    func artistSongs() {
        let result = SimilarTrackLibraryMatcher.match(
            tracks: [],
            artists: ["林俊傑", "Adele", "Nobody"],
            songs: library,
            songsPerArtist: 2,
            ordering: { id in id == "s6" ? 0 : 1 }
        )
        #expect(result.artistSongIDs == [["s6", "s3"], ["s4", "s8"], []])
        #expect(SimilarTrackLibraryMatcher.interleaved(result.artistSongIDs) == ["s6", "s4", "s3", "s8"])
    }

    @Test("Nothing to look up returns empty slots")
    func emptyRequest() {
        let result = SimilarTrackLibraryMatcher.match(tracks: [], artists: [], songs: library)
        #expect(result.trackSongIDs.isEmpty)
        #expect(result.artistSongIDs.isEmpty)
    }
}
