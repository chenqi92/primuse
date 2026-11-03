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
            trackArtistsByID: Dictionary(uniqueKeysWithValues: trackArtists.map { ($0.id, $0) }),
            configuration: .defaultValue,
            artistID: ArtistIdentityPolicy.groupingKey
        )

        #expect(index.artists.count == 3)
        #expect(Set(index.artists.map(\.name)) == Set(["Adele", "Various Artists", "周杰伦"]))
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
            trackArtistsByID: ["x": trackArtists[0]],
            configuration: .defaultValue,
            artistID: ArtistIdentityPolicy.groupingKey
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
            trackArtistsByID: Dictionary(uniqueKeysWithValues: trackArtists.map { ($0.id, $0) }),
            configuration: .defaultValue,
            artistID: ArtistIdentityPolicy.groupingKey
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
            trackArtistsByID: ["1": trackArtists[0]],
            configuration: .defaultValue,
            artistID: ArtistIdentityPolicy.groupingKey
        )
        #expect(index.artists.isEmpty)
        #expect(index.albumIDsByAlbumOnlyArtistID.isEmpty)
    }

    private func artist(_ id: String, _ name: String, albums: Int, songs: Int, thumbnail: String? = nil) -> Artist {
        Artist(id: id, name: name, albumCount: albums, songCount: songs, thumbnailPath: thumbnail)
    }

    @Test("Collaborations share albums between credited artists without a synthetic group")
    func collaborationsUseIndividualCredits() throws {
        let artists = [
            artist("a", "A", albums: 1, songs: 5, thumbnail: "a.jpg"),
            artist("b", "B", albums: 0, songs: 3)
        ]
        let collaboration = album("duet", title: "Duet", artistID: "a-and-b", artistName: "A & B", songs: 1)
        let albums = [
            album("solo", title: "Solo", artistID: "a", artistName: "A", songs: 2),
            collaboration,
            collaboration,
            album("second", title: "Second", artistID: "repeated", artistName: "A / a & B", songs: 2)
        ]
        let index = AlbumArtistIndexBuilder.build(
            albums: albums, trackArtists: artists,
            trackArtistsByID: Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) }),
            configuration: .init(separators: ["&", "/"], protectedNames: [], displaySeparator: " / "),
            artistID: ArtistIdentityPolicy.groupingKey
        )
        #expect(index.artists.map(\.name) == ["A", "B"])
        let a = try #require(index.artists.first { $0.id == "a" })
        let b = try #require(index.artists.first { $0.id == "b" })
        #expect(a.albumCount == 3 && a.songCount == 5 && a.thumbnailPath == "a.jpg")
        #expect(b.albumCount == 2 && b.songCount == 3)
        #expect(index.albumIDsByArtistID["a"] == ["solo", "duet", "second"])
        #expect(index.albumIDsByArtistID["b"] == ["duet", "second"])
        #expect(index.albumIDsByAlbumOnlyArtistID.isEmpty)
    }

    @Test("Album-only collaborators retain album lookup and full-width matching")
    func albumOnlyCollaboratorsKeepTheirAlbums() {
        let index = AlbumArtistIndexBuilder.build(
            albums: [album("duet", title: "Duet", artistID: "group", artistName: "A＆B", songs: 4)],
            trackArtists: [], trackArtistsByID: [:],
            configuration: .init(separators: ["&"], protectedNames: [], displaySeparator: " / "),
            artistID: ArtistIdentityPolicy.groupingKey
        )
        #expect(index.artists.map(\.name) == ["A", "B"])
        #expect(index.artists.allSatisfy { $0.albumCount == 1 && $0.songCount == 4 })
        #expect(index.albumIDsByAlbumOnlyArtistID == ["a": ["duet"], "b": ["duet"]])
    }

    @Test("Protected names and source-backed groups remain single artists")
    func genuineGroupsKeepTheirIdentity() {
        let knownGroup = artist("native-band", "Simon & Garfunkel", albums: 1, songs: 3)
        let index = AlbumArtistIndexBuilder.build(
            albums: [
                album("native", title: "Native", artistID: knownGroup.id, artistName: knownGroup.name, songs: 3),
                album("protected", title: "Protected", artistID: "acdc", artistName: "AC/DC", songs: 2),
                album("compilation", title: "Compilation", artistID: "various", artistName: "Various Artists", songs: 8)
            ],
            trackArtists: [knownGroup], trackArtistsByID: [knownGroup.id: knownGroup],
            configuration: .init(separators: ["&", "/"], protectedNames: ["AC/DC"], displaySeparator: " / "),
            artistID: ArtistIdentityPolicy.groupingKey
        )
        #expect(Set(index.artists.map(\.name)) == ["AC/DC", "Simon & Garfunkel", "Various Artists"])
        #expect(index.albumIDsByAlbumOnlyArtistID == ["acdc": ["protected"], "various": ["compilation"]])
    }

    private func album(_ id: String, title: String, artistID: String?, artistName: String?, songs: Int) -> Album {
        Album(id: id, title: title, artistID: artistID, artistName: artistName, songCount: songs)
    }
}
