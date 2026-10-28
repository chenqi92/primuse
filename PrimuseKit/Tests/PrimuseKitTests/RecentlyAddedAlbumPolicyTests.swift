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

    private func song(_ id: String, albumID: String?, added: TimeInterval) -> Song {
        Song(id: id, title: id, albumID: albumID, duration: 180, fileFormat: .mp3,
             filePath: "\(id).mp3", sourceID: "source", dateAdded: Date(timeIntervalSince1970: added))
    }
}
