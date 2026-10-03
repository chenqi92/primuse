import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album artist browsing")
struct AlbumArtistBrowsingTests {
    @Test("Unknown or missing preference falls back to all artists")
    func modeResolution() {
        #expect(ArtistBrowseMode.resolved(nil) == .allArtists)
        #expect(ArtistBrowseMode.resolved("bogus") == .allArtists)
        #expect(ArtistBrowseMode.resolved("albumArtists") == .albumArtists)
    }

    @Test("Each album counts once under its album artist; guests on a compilation drop out")
    func compilationGuestsDropOut() {
        let trackArtists = [
            artist("a-adele", "Adele", albums: 0, songs: 9, thumbnail: "adele.jpg"),
            artist("b-guest", "Guest", albums: 0, songs: 1),
            artist("j-jay", "周杰伦", albums: 2, songs: 21),
        ]
        let albums = [
            album("hits", title: "Hits", artistID: "v-various", artistName: "Various Artists", songs: 15),
            album("fantasy", title: "范特西", artistID: "j-jay", artistName: "周杰伦", songs: 10),
            album("25", title: "25", artistID: "a-adele", artistName: "Adele", songs: 11),
            album("yhm", title: "叶惠美", artistID: "j-jay", artistName: "周杰伦", songs: 11),
        ]

        let index = AlbumArtistIndexBuilder.build(
            albums: albums,
            trackArtists: trackArtists,
            trackArtistsByID: Dictionary(uniqueKeysWithValues: trackArtists.map { ($0.id, $0) })
        )

        #expect(index.artists.map(\.name) == ["Adele", "Various Artists", "周杰伦"])
        let jay = index.artists.first { $0.id == "j-jay" }
        #expect(jay?.albumCount == 2)
        #expect(jay?.songCount == 21)
        #expect(index.artists.first { $0.id == "a-adele" }?.thumbnailPath == "adele.jpg")
        #expect(index.artists.first { $0.id == "v-various" }?.songCount == 15)
        #expect(index.albumIDsByAlbumOnlyArtistID == ["v-various": ["hits"]])
    }

    @Test("A shared artist keeps the track artist's spelling so the list matches the artist page")
    func sharedArtistKeepsTrackSpelling() {
        let trackArtists = [artist("x", "The Beatles", albums: 1, songs: 12)]
        let albums = [album("abbey", title: "Abbey Road", artistID: "x", artistName: "the beatles", songs: 17)]

        let index = AlbumArtistIndexBuilder.build(
            albums: albums,
            trackArtists: trackArtists,
            trackArtistsByID: ["x": trackArtists[0]]
        )

        #expect(index.artists.map(\.name) == ["The Beatles"])
        #expect(index.artists.first?.songCount == 17)
        #expect(index.albumIDsByAlbumOnlyArtistID.isEmpty)
    }

    @Test("Album-only artists are merged into the existing order without disturbing it")
    func albumOnlyArtistsMergeIntoOrder() {
        let trackArtists = [
            artist("1", "Abba", albums: 1, songs: 1),
            artist("2", "Coldplay", albums: 1, songs: 1),
            artist("3", "Muse", albums: 1, songs: 1),
        ]
        let albums = [
            album("m", title: "M", artistID: "3", artistName: "Muse", songs: 1),
            album("z", title: "Z", artistID: "9", artistName: "Zed & Friends", songs: 2),
            album("a", title: "A", artistID: "1", artistName: "Abba", songs: 1),
            album("b", title: "B", artistID: "8", artistName: "Blur & Gorillaz", songs: 3),
            album("b2", title: "B2", artistID: "8", artistName: "Blur & Gorillaz", songs: 4),
            album("c", title: "C", artistID: "2", artistName: "Coldplay", songs: 1),
        ]

        let index = AlbumArtistIndexBuilder.build(
            albums: albums,
            trackArtists: trackArtists,
            trackArtistsByID: Dictionary(uniqueKeysWithValues: trackArtists.map { ($0.id, $0) })
        )

        #expect(index.artists.map(\.name) == ["Abba", "Blur & Gorillaz", "Coldplay", "Muse", "Zed & Friends"])
        #expect(index.artists.first { $0.id == "8" }?.albumCount == 2)
        #expect(index.artists.first { $0.id == "8" }?.songCount == 7)
        #expect(index.albumIDsByAlbumOnlyArtistID["8"] == ["b", "b2"])
    }

    @Test("Track artists without an album of their own are left out")
    func trackArtistsWithoutAlbumsAreLeftOut() {
        let trackArtists = [artist("1", "Solo", albums: 0, songs: 3)]
        let index = AlbumArtistIndexBuilder.build(
            albums: [album("x", title: "X", artistID: nil, artistName: nil, songs: 3)],
            trackArtists: trackArtists,
            trackArtistsByID: ["1": trackArtists[0]]
        )
        #expect(index.artists.isEmpty)
        #expect(index.albumIDsByAlbumOnlyArtistID.isEmpty)
    }

    private func artist(_ id: String, _ name: String, albums: Int, songs: Int, thumbnail: String? = nil) -> Artist {
        Artist(id: id, name: name, albumCount: albums, songCount: songs, thumbnailPath: thumbnail)
    }

    private func album(_ id: String, title: String, artistID: String?, artistName: String?, songs: Int) -> Album {
        Album(id: id, title: title, artistID: artistID, artistName: artistName, songCount: songs)
    }
}
