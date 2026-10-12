import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music album completion")
struct AppleMusicAlbumCompletionPolicyTests {
    private typealias Slot = AppleMusicAlbumCompletionPolicy.Slot

    private func track(_ id: String, _ title: String, duration: TimeInterval = 200) -> AppleMusicTrackIdentity {
        AppleMusicTrackIdentity(itemID: id, title: title, artist: "Artist", album: "Album", duration: duration)
    }

    @Test("Library songs take their catalog position; the rest come from the catalog")
    func fillsMissingTracksInCatalogOrder() {
        let catalog = [track("c1", "One"), track("c2", "Two"), track("c3", "Three")]
        let library = [
            AppleMusicTrackIdentity(itemID: "i.2", alternateIDs: ["c2"], title: "Two", artist: "Artist"),
        ]
        #expect(AppleMusicAlbumCompletionPolicy.merge(catalogTracks: catalog, librarySongs: library)
            == [.catalog(0), .library(0), .catalog(2)])
    }

    @Test("Without a shared ID the library song is matched by title, artist and length")
    func matchesByMetadata() {
        let catalog = [track("c1", "One", duration: 180), track("c2", "Two", duration: 240)]
        let library = [track("i.9", "two", duration: 240.4)]
        #expect(AppleMusicAlbumCompletionPolicy.merge(catalogTracks: catalog, librarySongs: library)
            == [.catalog(0), .library(0)])
    }

    @Test("A library song is claimed once even if two catalog tracks resolve to it")
    func claimsLibrarySongOnce() {
        let catalog = [
            AppleMusicTrackIdentity(itemID: "c1", title: "One", artist: "Artist"),
            AppleMusicTrackIdentity(itemID: "c1-dup", alternateIDs: ["c1"], title: "One", artist: "Artist"),
        ]
        let library = [AppleMusicTrackIdentity(itemID: "i.1", alternateIDs: ["c1"], title: "One", artist: "Artist")]
        #expect(AppleMusicAlbumCompletionPolicy.merge(catalogTracks: catalog, librarySongs: library)
            == [.library(0), .catalog(1)])
    }

    @Test("Library songs the catalog does not list stay, after the album")
    func keepsUnmatchedLibrarySongs() {
        let catalog = [track("c1", "One")]
        let library = [
            AppleMusicTrackIdentity(itemID: "i.1", alternateIDs: ["c1"], title: "One", artist: "Artist"),
            AppleMusicTrackIdentity(itemID: "i.7", title: "Home Demo", artist: "Artist"),
        ]
        #expect(AppleMusicAlbumCompletionPolicy.merge(catalogTracks: catalog, librarySongs: library)
            == [.library(0), .library(1)])
    }

    @Test("Album titles match across edition notes, other albums do not")
    func albumTitleMatch() {
        #expect(AppleMusicAlbumCompletionPolicy.albumTitlesMatch("Album (Deluxe Edition)", "Album"))
        #expect(AppleMusicAlbumCompletionPolicy.albumTitlesMatch("范特西", "范特西"))
        #expect(!AppleMusicAlbumCompletionPolicy.albumTitlesMatch("Greatest Hits", "Album"))
    }
}

@Suite("Apple Music catalog album identity")
struct AppleMusicCatalogAlbumIdentityTests {
    @Test("The seed song survives the round trip")
    func roundTrip() {
        let id = AppleMusicCatalogAlbumIdentity.albumID(seedItemID: "1440857781")
        #expect(AppleMusicCatalogAlbumIdentity.seedItemID(fromAlbumID: id) == "1440857781")
        #expect(AppleMusicCatalogAlbumIdentity.isCatalogAlbum(id))
    }

    @Test("Library album IDs are not catalog albums")
    func libraryAlbumIsNotCatalog() {
        #expect(AppleMusicCatalogAlbumIdentity.seedItemID(fromAlbumID: "3f2a9c0d41b7e6a8") == nil)
        #expect(!AppleMusicCatalogAlbumIdentity.isCatalogAlbum(""))
    }

    @Test("A prefix without a seed is not a catalog album")
    func emptySeed() {
        #expect(AppleMusicCatalogAlbumIdentity.seedItemID(
            fromAlbumID: AppleMusicCatalogAlbumIdentity.albumID(seedItemID: "")
        ) == nil)
    }
}
