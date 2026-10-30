import XCTest
@testable import PrimuseKit

final class SubsonicArtworkPolicyTests: XCTestCase {
    func testCacheSeparatesSourceCoverRevisionAndResolution() {
        func key(_ source: String = "server", _ reference: String = "subsonic-cover/mf-song_v1", _ pixels: Int = 192) -> String? {
            SubsonicArtworkPolicy.cacheID(sourceID: source, reference: reference, maximumPixels: pixels)
        }
        XCTAssertNotNil(key())
        XCTAssertEqual(key(), key("server", "subsonic-cover/mf-song_v1", 384))
        XCTAssertNotEqual(key(), key("other"))
        XCTAssertNotEqual(key(), key("server", "subsonic-cover/mf-song_v2"))
        XCTAssertNotEqual(key(), key("server", "subsonic-cover/mf-song_v1", 768))
        XCTAssertEqual(key("server", "subsonic-cover/mf-song_v1", 768), key("server", "subsonic-cover/mf-song_v1", 1536))
    }

    func testLegacyURLUsesOnlyCoverIDWithoutPersistingCredentialsOrHost() throws {
        let reference = "https://private.invalid/base/rest/getCoverArt.view?id=mf-song_v1&u=private-user&t=private-token&s=private-salt&size=480"
        let key = try XCTUnwrap(SubsonicArtworkPolicy.cacheID(sourceID: "server", reference: reference, maximumPixels: 1536))
        XCTAssertEqual(key, SubsonicArtworkPolicy.cacheID(sourceID: "server", reference: "subsonic-cover/mf-song_v1", maximumPixels: 1536))
        XCTAssertFalse(key.contains("private"))
    }

    func testExplicitLocalAndScrapedReferencesKeepTheirOwnCachePath() {
        for reference in [nil, "", "subsonic-cover/", "cover.jpg", "/album/cover.jpg", "https://cdn.invalid/cover.jpg", "subsonic-artist/artist"] as [String?] {
            XCTAssertNil(SubsonicArtworkPolicy.cacheID(sourceID: "server", reference: reference, maximumPixels: 1536))
        }
        XCTAssertNil(SubsonicArtworkPolicy.cacheID(sourceID: nil, reference: "subsonic-cover/id", maximumPixels: 1536))
    }
    func testProvenanceSeparatesAutomaticAssetsFromSelectionsAndLegacyFiles() {
        let hash = String(repeating: "a", count: 64)
        for origin in StoredArtworkOrigin.allCases {
            let reference = origin.rawValue + "-" + hash + ".jpg"
            XCTAssertEqual(StoredArtworkOrigin.resolve(reference), origin)
            XCTAssertEqual(StoredArtworkOrigin.preservesLocalChoice(reference), origin == .selected)
            XCTAssertEqual(SourceArtworkPolicy.shouldAdoptServerReference(existing: reference, incoming: "subsonic-cover/new"), origin != .selected)
        }
        XCTAssertTrue(StoredArtworkOrigin.preservesLocalChoice("legacy.jpg"))
        XCTAssertFalse(SourceArtworkPolicy.shouldAdoptServerReference(existing: "legacy.jpg", incoming: "subsonic-cover/new"))
    }

    func testTextEditAndContentReplacementDoNotFreezeServerArtwork() {
        var existing = Song(id: "song", title: "My title", fileFormat: .flac, filePath: "/song.flac", sourceID: "server", coverArtFileName: "subsonic-cover/old")
        existing.userMetadataEditedAt = Date()
        var incoming = existing
        incoming.title = "Server title"
        incoming.coverArtFileName = "subsonic-cover/new"
        incoming.revision = "new-file"
        existing.revision = "old-file"
        let merged = ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.title, "My title")
        XCTAssertEqual(merged.coverArtFileName, "subsonic-cover/new")
        existing.userMetadataEditedAt = nil
        existing.coverArtFileName = "selected-" + String(repeating: "a", count: 64) + ".jpg"
        XCTAssertEqual(ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming).coverArtFileName, existing.coverArtFileName)
        existing.coverArtFileName = "embedded-" + String(repeating: "a", count: 64) + ".jpg"
        XCTAssertEqual(ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming).coverArtFileName, incoming.coverArtFileName)
    }

    func testOtherServersSeparateImageVersionsAndDiscardCredentials() throws {
        let reference = "https://nas.invalid/Items/album/Images/Primary?tag=v1&api_key=secret"
        let first = try XCTUnwrap(SourceArtworkPolicy.cacheID(sourceID: "server", reference: reference, maximumPixels: 480))
        XCTAssertFalse(first.contains("secret"))
        XCTAssertNotEqual(first, SourceArtworkPolicy.cacheID(sourceID: "server", reference: reference.replacingOccurrences(of: "v1", with: "v2"), maximumPixels: 480))
        XCTAssertNotEqual(first, SourceArtworkPolicy.cacheID(sourceID: "server", reference: reference, maximumPixels: 1536))
        XCTAssertNotEqual(
            SourceArtworkPolicy.cacheID(sourceID: "server", reference: "https://cdn.invalid/cover?t=1", maximumPixels: 480),
            SourceArtworkPolicy.cacheID(sourceID: "server", reference: "https://cdn.invalid/cover?t=2", maximumPixels: 480)
        )
        let url = SourceArtworkPolicy.resizedMediaServerURL(try XCTUnwrap(URL(string: reference + "&maxWidth=480")), maximumPixels: 1536)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "maxWidth" })?.value, "1536")
        XCTAssertEqual(query?.first(where: { $0.name == "tag" })?.value, "v1")
    }

}
