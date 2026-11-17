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

    @Test func playbackQueueKeepsAlbumOrderAndOnlyTheLatestBatchOfEachAlbum() {
        let day: TimeInterval = 24 * 60 * 60
        let newest = [song("n1", albumID: "newest", added: 10 * day), song("n2", albumID: "newest", added: 10 * day + 5)]
        // 一年前的专辑今天补了一首:只放补进来的那首,原来那几首不跟着进队列。
        let refreshed = [song("r1", albumID: "refreshed", added: 1), song("r2", albumID: "refreshed", added: 9 * day),
                         song("r3", albumID: "refreshed", added: 2)]
        let older = [song("o1", albumID: "older", added: 5 * day), song("o2", albumID: "older", added: 5 * day - 60)]
        let queue = RecentlyAddedAlbumPolicy.playbackQueue(albumSongs: [newest, refreshed, [], older])
        #expect(queue.map(\.id) == ["n1", "n2", "r2", "o1", "o2"])
    }

    @Test func playbackQueueIncludesTheExactBatchBoundary() {
        let cutoff: TimeInterval = 500_000
        let window: TimeInterval = 86_400
        let songs = [
            song("before", albumID: "album", added: cutoff - 0.001),
            song("boundary", albumID: "album", added: cutoff),
            song("after", albumID: "album", added: cutoff + 0.001),
            song("latest", albumID: "album", added: cutoff + window)
        ]
        let queue = RecentlyAddedAlbumPolicy.playbackQueue(albumSongs: [songs], batchWindow: window)
        #expect(queue.map(\.id) == ["boundary", "after", "latest"])
    }

    @Test func playbackQueueStopsAtTheLimitWithoutReadingLaterAlbums() {
        let first = (1...3).map { song("a\($0)", albumID: "a", added: 100) }
        let second = (1...3).map { song("b\($0)", albumID: "b", added: 50) }
        var requested: [String] = []
        let albums = [first, second, [song("c1", albumID: "c", added: 10)]].lazy.map { songs -> [Song] in
            requested.append(songs.first?.albumID ?? "")
            return songs
        }
        let queue = RecentlyAddedAlbumPolicy.playbackQueue(albumSongs: albums, limit: 4)
        #expect(queue.map(\.id) == ["a1", "a2", "a3", "b1"])
        #expect(requested == ["a", "b"])
        let empty = RecentlyAddedAlbumPolicy.playbackQueue(albumSongs: [first], limit: 0)
        #expect(empty.isEmpty)
    }

    @Test func playbackQueueUsesServerAlbumDatesForTheBatch() {
        var early = song("early", albumID: "album", added: 1)
        early.serverAlbumDateAdded = Date(timeIntervalSince1970: 500_000)
        var late = song("late", albumID: "album", added: 400_000)
        late.serverAlbumDateAdded = Date(timeIntervalSince1970: 500_000)
        let queue = RecentlyAddedAlbumPolicy.playbackQueue(albumSongs: [[early, late]])
        #expect(queue.map(\.id) == ["early", "late"])
    }

    private func song(_ id: String, albumID: String?, added: TimeInterval) -> Song {
        Song(id: id, title: id, albumID: albumID, duration: 180, fileFormat: .mp3,
             filePath: "\(id).mp3", sourceID: "source", dateAdded: Date(timeIntervalSince1970: added))
    }
}
