import Foundation
import Testing
@testable import PrimuseKit

@Suite("Recently added albums")
struct RecentlyAddedAlbumPolicyTests {
    @Test func serverAlbumDatesOverrideScanOrderAndLaterTrackAdditions() {
        let albums = [Album(id: "old", title: "Old"), Album(id: "new", title: "New")]
        var old = song("later-track", albumID: "old", added: 1_000)
        old.serverDateAdded = Date(timeIntervalSince1970: 100)
        old.serverAlbumDateAdded = Date(timeIntervalSince1970: 10)
        var new = song("new-track", albumID: "new", added: 500)
        new.serverDateAdded = Date(timeIntervalSince1970: 50)
        new.serverAlbumDateAdded = Date(timeIntervalSince1970: 50)
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: [old, new]).map(\.id) == ["new", "old"])
        old.serverAlbumDateAdded = nil
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: [new, old]).map(\.id) == ["old", "new"])
    }

    @Test func sortsWholeAlbumsByTheirNewestTrack() {
        let albums = [Album(id: "older", title: "Older"), Album(id: "newer", title: "Newer")]
        let songs = [song("one", albumID: "newer", added: 1),
                     song("two", albumID: "older", added: 10),
                     song("three", albumID: "newer", added: 20)]
        let result = RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs)
        #expect(result.map(\.id) == ["newer", "older"])
    }

    @Test func equalDatesHaveStableOrderAndSameTitlesKeepTheirIdentities() {
        let albums = [Album(id: "b", title: "Greatest Hits", artistName: "Singer B"),
                      Album(id: "a", title: "Greatest Hits", artistName: "Singer A")]
        let songs = [song("one", albumID: "b", added: 10), song("two", albumID: "a", added: 10)]
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs).map(\.id) == ["a", "b"])
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums.reversed(), songs: songs.reversed()).map(\.id) == ["a", "b"])
    }

    @Test func excludesAlbumsOutsideTheVisibleInputAndKeepsUnknownDatesLast() {
        let albums = [Album(id: "undated", title: "Undated"), Album(id: "visible", title: "Visible")]
        let songs = [song("hidden-track", albumID: "hidden", added: 100),
                     song("visible-track", albumID: "visible", added: 1),
                     song("no-album", albumID: nil, added: 200)]
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs).map(\.id) == ["visible", "undated"])
    }

    @Test func appliesLimitToAlbumsAfterSorting() {
        let albums = [Album(id: "a", title: "A"), Album(id: "b", title: "B")]
        let songs = [song("one", albumID: "a", added: 10), song("two", albumID: "b", added: 20)]
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs, limit: 1).map(\.id) == ["b"])
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs, limit: 0).isEmpty)
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs, limit: -1).isEmpty)
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs, limit: 20).count == 2)
    }

    @Test func previewFilterKeepsOrdinarySinglesAndUsesOnlyLibraryDatesForMixedAlbums() {
        let albums = ["preview", "mixed", "normal", "unknown"].map { Album(id: $0, title: $0, songCount: 1) }
        var preview = song("preview-track", albumID: "preview", added: 500)
        preview.isExternal = true
        preview.fileFormat = .flac
        var mixedPreview = song("mixed-preview", albumID: "mixed", added: 400)
        mixedPreview.isExternal = true
        let mixedLibrary = song("mixed-library", albumID: "mixed", added: 10)
        var normal = song("normal-track", albumID: "normal", added: 100)
        normal.fileFormat = .m4a
        normal.isExternal = false
        var unknown = song("unknown-track", albumID: "unknown", added: 50)
        unknown.fileFormat = .m4a
        let songs = [preview, mixedPreview, mixedLibrary, normal, unknown]
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs, includingExternalSongs: false)
            .map(\.id) == ["normal", "unknown", "mixed"])
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs, limit: 2, includingExternalSongs: false)
            .map(\.id) == ["normal", "unknown"])
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs, includingExternalSongs: true)
            .map(\.id) == ["preview", "mixed", "normal", "unknown"])
        #expect(songs.first?.isExternal == true)
        #expect(songs.count == 5)
    }

    @Test func filteringPreservesTheCallersExistingDateOrder() {
        var laterTrack = song("later-track", albumID: "old-album", added: 100)
        laterTrack.serverAlbumDateAdded = Date(timeIntervalSince1970: 1)
        let newerAlbum = song("newer-album-track", albumID: "newer-album", added: 50)
        var preview = song("preview-track", albumID: "preview", added: 200)
        preview.isExternal = true
        let songs = [laterTrack, newerAlbum, preview]
        let albums = ["old-album", "newer-album", "preview"].map { Album(id: $0, title: $0) }
        var index = RecentlyAddedAlbumPolicy.Index(includingExternalSongs: false)
        for song in songs { index.add(song, addedDate: song.dateAdded) }
        #expect(index.sorted(albums: albums).map(\.id) == ["old-album", "newer-album"])
    }

    @Test func externalStatusPersistsAndFormalImportRestoresTheAlbum() throws {
        var preview = song("track", albumID: "album", added: 10)
        preview.isExternal = true
        preview.lyricsText = "Silver clouds above a quiet road"
        preview.userMetadataEditedAt = Date(timeIntervalSince1970: 20)
        let albums = [Album(id: "album", title: "Night journey")]
        let data = try JSONEncoder().encode(preview)
        let restored = try JSONDecoder().decode(Song.self, from: data)
        #expect(restored.isExternal == true)
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: [restored], includingExternalSongs: false).isEmpty)
        var imported = preview
        imported.isExternal = false
        #expect(SourceCatalogSnapshotPolicy.hasChanges(existing: [preview], candidate: [imported]))
        imported.serverDateAdded = Date(timeIntervalSince1970: 100)
        let merged = ServerSongCatalogMergePolicy.merged(existing: restored, incoming: imported)
        #expect(merged.isExternal == false)
        #expect(merged.lyricsText == preview.lyricsText)
        #expect(merged.userMetadataEditedAt == preview.userMetadataEditedAt)
        #expect(RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: [merged], includingExternalSongs: false).map(\.id) == ["album"])
        #expect(try PropertyListDecoder().decode(Song.self, from: PropertyListEncoder().encode(merged)).isExternal == false)
        var unclassified = imported
        unclassified.isExternal = nil
        #expect(ServerSongCatalogMergePolicy.merged(existing: restored, incoming: unclassified).isExternal == true)
        #expect(try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(unclassified)).isExternal == nil)
    }

    private func song(_ id: String, albumID: String?, added: TimeInterval) -> Song {
        Song(id: id, title: id, albumID: albumID, duration: 180, fileFormat: .mp3,
             filePath: "\(id).mp3", sourceID: "source", dateAdded: Date(timeIntervalSince1970: added))
    }
}
