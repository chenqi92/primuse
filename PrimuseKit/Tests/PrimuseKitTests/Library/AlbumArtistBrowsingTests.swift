import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album artist browsing")
struct AlbumArtistBrowsingTests {
    @Test("Singles, EPs and untagged one-song albums do not make an album artist")
    func singleOnlyAlbumArtistsDropOut() {
        let full = AlbumArtistReleaseFilter.countsAsFullRelease
        #expect(full([.album], false, 10))
        #expect(!full([.singleEP], false, 4))
        // Nothing in the tags or title said what it is, and it holds one song.
        #expect(!full([.album], false, 1))
        #expect(full([.live], false, 1))
        #expect(full([.singleEP, .live], false, 2))
        // A manual choice wins in both directions.
        #expect(full([.album], true, 1))
        #expect(!full([.singleEP], true, 12))

        let artists = [
            artist("a", "Full", albums: 2, songs: 12),
            artist("b", "Guest", albums: 1, songs: 1),
            artist("c", "None", albums: 0, songs: 0),
        ]
        let kept = AlbumArtistReleaseFilter.artists(
            artists,
            albumIDsByArtistID: ["a": ["lp", "duet"], "b": ["duet"]],
            isFullRelease: { $0 == "lp" }
        )
        #expect(kept.map(\.id) == ["a"])
    }

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
        // The artist page lists the 12 songs they perform, not the album's 17.
        #expect(index.artists.first?.songCount == 12)
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

    @Test("Artist page albums split into releases and appearances, newest first")
    func artistAlbumShelvesPartition() {
        let albums = [
            Album(id: "old", title: "Debut", artistID: "jay", artistName: "Jay", year: 2000, songCount: 10),
            Album(id: "credited", title: "Duets", artistID: "pair", artistName: "Jay & Kim", year: 2010, songCount: 8),
            Album(id: "named", title: "Live 2", artistID: "other-id", artistName: " ＪＡＹ ", year: 2010, songCount: 12),
            Album(id: "named-10", title: "Live 10", artistID: "other-id", artistName: "jay", year: 2010, songCount: 12),
            Album(id: "undated", title: "Demos", artistID: "jay", artistName: "Jay", songCount: 3),
            Album(id: "hits", title: "Hits", artistID: "various", artistName: "Various Artists", year: 2015, songCount: 20),
            Album(id: "unrelated", title: "Other", artistID: "kim", artistName: "Kim", year: 2020, songCount: 9),
        ]
        let partition = ArtistAlbumShelfPolicy.partition(
            albums: albums,
            artistID: "jay",
            displayName: "Jay",
            songAlbumIDs: ["old", "hits"],
            isCredited: { $0.id == "credited" }
        )
        // 同一年按标题的自然顺序；没写年份的排最后。
        #expect(partition.releases.map(\.id) == ["credited", "named", "named-10", "old", "undated"])
        #expect(partition.appearsOn.map(\.id) == ["hits"])
        #expect(partition.albumCount == 6)

        let shelves = ArtistAlbumShelfPolicy.releaseShelves(partition.releases) { album in
            switch album.id {
            case "named", "named-10": return [.album, .live]
            case "undated": return [.singleEP]
            default: return [.album]
            }
        }
        #expect(shelves.map(\.category) == [.album, .singleEP, .live])
        #expect(shelves[0].albums.map(\.id) == ["credited", "named", "named-10", "old"])
        #expect(shelves[1].albums.map(\.id) == ["undated"])
        #expect(shelves[2].albums.map(\.id) == ["named", "named-10"])
        let none = ArtistAlbumShelfPolicy.releaseShelves([]) { _ in [.album] }
        #expect(none.isEmpty)
    }

    @Test("#470: structured multi-album-artist collaborations appear under Albums for every album artist while guests stay in Appears on")
    func structuredMultiAlbumArtistsAssignToEveryCreditedArtist() throws {
        let songs = [
            Song(
                id: "track-1", title: "Palmen aus Plastik",
                albumTitle: "Palmen aus Plastik 2",
                artistName: "Bonez MC • RAF Camora",
                sourceArtistNames: ["Bonez MC", "RAF Camora"],
                albumArtistName: "Bonez MC • RAF Camora",
                trackNumber: 1, duration: 180, fileFormat: .m4a,
                filePath: "/songs/1.m4a", sourceID: "navidrome",
                sourceAlbumArtistNames: ["Bonez MC", "RAF Camora"]
            ),
            Song(
                id: "track-2", title: "Solo Cut",
                albumTitle: "Palmen aus Plastik 2",
                artistName: "Bonez MC",
                albumArtistName: "Bonez MC • RAF Camora",
                trackNumber: 2, duration: 190, fileFormat: .m4a,
                filePath: "/songs/2.m4a", sourceID: "navidrome",
                sourceAlbumArtistNames: ["Bonez MC", "RAF Camora"]
            ),
            Song(
                id: "track-3", title: "Guest Feature",
                albumTitle: "Palmen aus Plastik 2",
                artistName: "Bonez MC • RAF Camora • Gzuz",
                sourceArtistNames: ["Bonez MC", "RAF Camora", "Gzuz"],
                albumArtistName: "Bonez MC • RAF Camora",
                trackNumber: 3, duration: 200, fileFormat: .m4a,
                filePath: "/songs/3.m4a", sourceID: "navidrome",
                sourceAlbumArtistNames: ["Bonez MC", "RAF Camora"]
            ),
        ]

        let derived = LibraryGroupingReference.computeAlbumsAndArtists(
            songs: songs,
            configuration: .defaultValue,
            unknownArtist: "Unknown Artist"
        )
        // Different track participants on the same album still stay grouped into one album.
        #expect(derived.albums.count == 1)
        let jointAlbum = try #require(derived.albums.first)
        #expect(jointAlbum.songCount == 3)
        #expect(jointAlbum.artistName == "Bonez MC • RAF Camora")
        #expect(jointAlbum.sourceArtistNames == ["Bonez MC", "RAF Camora"])

        let artistsByID = Dictionary(uniqueKeysWithValues: derived.artists.map { ($0.id, $0) })
        let index = AlbumArtistIndexBuilder.build(
            albums: derived.albums,
            trackArtists: derived.artists,
            trackArtistsByID: artistsByID,
            configuration: .defaultValue,
            artistID: { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)) }
        )
        #expect(Set(index.artists.map(\.name)) == ["Bonez MC", "RAF Camora"])
        #expect(index.albumIDsByAlbumOnlyArtistID.isEmpty)

        let bonezID = LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey("Bonez MC"))
        let rafID = LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey("RAF Camora"))
        let gzuzID = LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey("Gzuz"))

        let bonezPartition = ArtistAlbumShelfPolicy.partition(
            albums: derived.albums, artistID: bonezID, displayName: "Bonez MC",
            songAlbumIDs: [jointAlbum.id],
            isCredited: { index.albumIDsByArtistID[bonezID]?.contains($0.id) == true }
        )
        let rafPartition = ArtistAlbumShelfPolicy.partition(
            albums: derived.albums, artistID: rafID, displayName: "RAF Camora",
            songAlbumIDs: [jointAlbum.id],
            isCredited: { index.albumIDsByArtistID[rafID]?.contains($0.id) == true }
        )
        let gzuzPartition = ArtistAlbumShelfPolicy.partition(
            albums: derived.albums, artistID: gzuzID, displayName: "Gzuz",
            songAlbumIDs: [jointAlbum.id],
            isCredited: { index.albumIDsByArtistID[gzuzID]?.contains($0.id) == true }
        )

        #expect(bonezPartition.releases.map(\.id) == [jointAlbum.id])
        #expect(bonezPartition.appearsOn.isEmpty)
        #expect(rafPartition.releases.map(\.id) == [jointAlbum.id])
        #expect(rafPartition.appearsOn.isEmpty)
        #expect(gzuzPartition.releases.isEmpty)
        #expect(gzuzPartition.appearsOn.map(\.id) == [jointAlbum.id])
    }

    @Test("Inferred album grouping preserves multi-participant albums without leaking overridden source album artists")
    func inferredAlbumArtistDoesNotPromoteGuestSourceAlbumArtists() throws {
        let songs = [
            Song(
                id: "ost-1", title: "Theme",
                albumTitle: "Game OST",
                artistName: "Composer A",
                albumArtistName: "Various Artists",
                trackNumber: 1, duration: 120, fileFormat: .flac,
                filePath: "/ost/1.flac", sourceID: "local"
            ),
            Song(
                id: "ost-2", title: "Collab Track",
                albumTitle: "Game OST",
                artistName: "Composer B & Composer C",
                sourceArtistNames: ["Composer B", "Composer C"],
                albumArtistName: "Composer B & Composer C",
                trackNumber: 2, duration: 130, fileFormat: .flac,
                filePath: "/ost/2.flac", sourceID: "local",
                sourceAlbumArtistNames: ["Composer B", "Composer C"]
            ),
        ]
        // Folder authority infers "Various Artists" for ost-2 (since ost-1 has the sole explicit album artist).
        let otherFolder = Song(
            id: "other-1", title: "Other",
            albumTitle: "Other", artistName: "Other",
            duration: 60, fileFormat: .flac,
            filePath: "/other/1.flac", sourceID: "local"
        )
        let derived = LibraryGroupingReference.computeAlbumsAndArtists(
            songs: songs + [otherFolder],
            configuration: .defaultValue,
            unknownArtist: "Unknown Artist"
        )
        let ost = try #require(derived.albums.first { $0.title == "Game OST" })
        #expect(ost.songCount == 2)
        #expect(ost.artistName == "Various Artists")
        #expect(ost.sourceArtistNames == nil)
    }

    @Test("Legacy bullet display fallback only splits known track artists and never splits Chinese middle dots")
    func legacyBulletDisplayFallbackProtectsChineseMidDotAndUnknownGroups() {
        let bonez = artist("bonez", "Bonez MC", albums: 0, songs: 3)
        let raf = artist("raf", "RAF Camora", albums: 0, songs: 3)
        let lennon = artist("lennon", "约翰·列侬", albums: 1, songs: 4)
        let trackArtists = [bonez, raf, lennon]
        let byID = Dictionary(uniqueKeysWithValues: trackArtists.map { ($0.id, $0) })

        let albums = [
            album("joint", title: "Palmen aus Plastik", artistID: "bonez • raf", artistName: "Bonez MC • RAF Camora", songs: 10),
            album("unknown-pair", title: "Mystery", artistID: "bonez • ghost", artistName: "Bonez MC • Ghost", songs: 5),
            album("lennon-lp", title: "Imagine", artistID: "lennon", artistName: "约翰·列侬", songs: 4),
            album("lennon-album-only", title: "Anthology", artistID: "约翰·列侬", artistName: "约翰·列侬", songs: 2),
        ]

        let index = AlbumArtistIndexBuilder.build(
            albums: albums,
            trackArtists: trackArtists,
            trackArtistsByID: byID,
            configuration: .defaultValue,
            artistID: { name in
                switch name {
                case "Bonez MC": return "bonez"
                case "RAF Camora": return "raf"
                case "约翰·列侬": return "lennon"
                default: return ArtistIdentityPolicy.groupingKey(name)
                }
            }
        )
        #expect(index.albumIDsByArtistID["bonez"] == ["joint"])
        #expect(index.albumIDsByArtistID["raf"] == ["joint"])
        #expect(index.albumIDsByArtistID["bonez • raf"] == nil)
        #expect(index.albumIDsByAlbumOnlyArtistID["bonez • ghost"] == ["unknown-pair"])
        #expect(index.albumIDsByArtistID["lennon"] == ["lennon-lp"])
    }

    private func album(_ id: String, title: String, artistID: String?, artistName: String?, songs: Int) -> Album {
        Album(id: id, title: title, artistID: artistID, artistName: artistName, songCount: songs)
    }
}
