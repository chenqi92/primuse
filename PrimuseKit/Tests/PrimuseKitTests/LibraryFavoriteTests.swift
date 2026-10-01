import Foundation
import Testing
@testable import PrimuseKit

struct LibraryFavoriteTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func keyIgnoresCaseWidthDiacriticsAndSpacing() {
        let a = LibraryFavoriteKey.id(kind: .album, albumTitle: "Café  Blue", artistName: "Ｈｉｒｏ")
        let b = LibraryFavoriteKey.id(kind: .album, albumTitle: " cafe blue", artistName: "hiro ")
        #expect(a == b)
        #expect(a.hasPrefix("album-") && a.count == "album-".count + 32)
        #expect(LibraryFavoriteKey.id(kind: .artist, albumTitle: "", artistName: "Hiro")
            != LibraryFavoriteKey.id(kind: .album, albumTitle: "", artistName: "Hiro"))
        #expect(LibraryFavoriteKey.id(kind: .album, albumTitle: "A", artistName: "B")
            != LibraryFavoriteKey.id(kind: .album, albumTitle: "B", artistName: "A"))
    }

    @Test func unknownArtistInAnyLanguageMatchesTheEmptyArtist() {
        let empty = LibraryFavoriteKey.id(kind: .album, albumTitle: "Demo", artistName: "")
        let chinese = LibraryFavoriteKey.id(kind: .album, albumTitle: "Demo", artistName: "未知艺术家", unknownArtistName: "未知艺术家")
        let english = LibraryFavoriteKey.id(kind: .album, albumTitle: "Demo", artistName: "Unknown Artist", unknownArtistName: "Unknown Artist")
        #expect(empty == chinese && chinese == english)
    }

    @Test func artistFavoritesIgnoreAnyAlbumTitle() {
        let entry = LibraryFavorite(kind: .artist, albumTitle: "ignored", artistName: "Hiro", likedAt: t0)
        #expect(entry.albumTitle.isEmpty)
        #expect(entry.id == LibraryFavoriteKey.id(kind: .artist, albumTitle: "", artistName: "Hiro"))
    }

    @Test func togglingWritesATombstoneAndLikingAgainRevivesIt() throws {
        var ledger = LibraryFavoriteLedger()
        let likedChange = ledger.set(kind: .album, albumTitle: "X", artistName: "Y", liked: true, at: t0)
        let liked = try #require(likedChange)
        #expect(ledger.isLiked(liked.id))
        let repeated = ledger.set(kind: .album, albumTitle: "X", artistName: "Y", liked: true, at: t0)
        #expect(repeated == nil)
        let unlikedChange = ledger.set(kind: .album, albumTitle: "x", artistName: "y", liked: false, at: t0)
        let unliked = try #require(unlikedChange)
        #expect(unliked.id == liked.id && unliked.deletedAt != nil)
        #expect(unliked.modifiedAt > liked.modifiedAt)
        #expect(!ledger.isLiked(liked.id))
        #expect(ledger.active(.album).isEmpty)
        let againChange = ledger.set(kind: .album, albumTitle: "X", artistName: "Y", liked: true, at: t0.addingTimeInterval(5))
        let again = try #require(againChange)
        #expect(again.deletedAt == nil && again.likedAt == t0.addingTimeInterval(5))
        #expect(ledger.active(.album).map(\.id) == [liked.id])
    }

    @Test func remoteChangesFollowTheNewerEdit() {
        var ledger = LibraryFavoriteLedger()
        ledger.set(kind: .artist, albumTitle: "", artistName: "Hiro", liked: true, at: t0)
        let id = LibraryFavoriteKey.id(kind: .artist, albumTitle: "", artistName: "Hiro")
        let staleTombstone = LibraryFavorite(kind: .artist, albumTitle: "", artistName: "Hiro",
                                             likedAt: t0, modifiedAt: t0.addingTimeInterval(-10), deletedAt: t0)
        let staleApplied = ledger.applyRemote(staleTombstone)
        #expect(!staleApplied)
        #expect(ledger.isLiked(id))
        let freshTombstone = LibraryFavorite(kind: .artist, albumTitle: "", artistName: "Hiro",
                                             likedAt: t0, modifiedAt: t0.addingTimeInterval(10), deletedAt: t0.addingTimeInterval(10))
        let freshApplied = ledger.applyRemote(freshTombstone)
        #expect(freshApplied)
        #expect(!ledger.isLiked(id))
    }

    @Test func activeListIsNewestFirstAndTombstonesPrune() {
        var ledger = LibraryFavoriteLedger()
        ledger.set(kind: .album, albumTitle: "Old", artistName: "A", liked: true, at: t0)
        ledger.set(kind: .album, albumTitle: "New", artistName: "A", liked: true, at: t0.addingTimeInterval(60))
        ledger.set(kind: .album, albumTitle: "Gone", artistName: "A", liked: true, at: t0)
        ledger.set(kind: .album, albumTitle: "Gone", artistName: "A", liked: false, at: t0.addingTimeInterval(1))
        #expect(ledger.active(.album).map(\.albumTitle) == ["New", "Old"])
        let pruned = ledger.pruneTombstones(before: t0.addingTimeInterval(100))
        #expect(pruned == [LibraryFavoriteKey.id(kind: .album, albumTitle: "Gone", artistName: "A")])
        #expect(ledger.entries.count == 2)
    }

    @Test func ledgerRoundTripsThroughJSON() throws {
        var ledger = LibraryFavoriteLedger()
        ledger.set(kind: .album, albumTitle: "X", artistName: "", liked: true, at: t0)
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(LibraryFavoriteLedger.self, from: data) == ledger)
    }
}
