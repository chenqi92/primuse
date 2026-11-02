import Foundation
import Testing
@testable import PrimuseKit

struct MotionArtworkServiceContractTests {
    @Test func sourceMigrationPreservesConfiguredServices() {
        #expect(MotionArtworkServiceSource.resolved("", customEndpoint: "") == .m8tec)
        #expect(MotionArtworkServiceSource.resolved("", customEndpoint: "https://my.example/lookup") == .custom)
        #expect(MotionArtworkServiceSource.resolved("m8tec", customEndpoint: "https://my.example/lookup") == .m8tec)
        #expect(MotionArtworkServiceSource.resolved("custom", customEndpoint: "") == .custom)
    }

    @Test func publicRequestEncodesMetadataAndUsesOnlyPublicCatalogIDs() throws {
        let metadata = MotionArtworkLookupInput(appleLibraryAlbumID: "l.private", upc: "private-upc", albumArtist: "A&B + C", albumTitle: "Album / #1")
        let url = try #require(M8tecMotionArtwork.requestURL(for: metadata))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query == [URLQueryItem(name: "artist", value: "A&B + C"), URLQueryItem(name: "album", value: "Album / #1")])
        let catalog = try #require(M8tecMotionArtwork.requestURL(for: .init(appleCatalogAlbumID: "12345", storefront: "cn")))
        #expect(catalog.path == "/api/v1/artwork/url")
        #expect(URLComponents(url: catalog, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "https://music.apple.com/cn/album/12345")
        #expect(M8tecMotionArtwork.requestURL(for: .init(appleCatalogAlbumID: "l.private")) == nil)
    }

    @Test func publicResponseRequiresTheSameArtistAndEdition() throws {
        let data = Data(#"{"url":"https://mvod.itunes.apple.com/cover.m3u8","artist":"example artist","album":"Example Album"}"#.utf8)
        let response = try JSONDecoder().decode(M8tecMotionArtwork.Response.self, from: data)
        #expect(try response.artworkURL(matching: input()) != nil)
        #expect(throws: M8tecMotionArtwork.ParseError.mismatchedAlbum) {
            try response.artworkURL(matching: .init(albumArtist: "Someone Else", albumTitle: "Example Album"))
        }
        #expect(throws: M8tecMotionArtwork.ParseError.mismatchedAlbum) {
            try response.artworkURL(matching: .init(albumArtist: "Example Artist", albumTitle: "Example Album (Deluxe)"))
        }
    }

    @Test func publicMediaIsRestrictedToHTTPSAppleCDNs() {
        for value in ["https://mvod.itunes.apple.com/art.mp4", "https://a1.mzstatic.com/art.mp4"] {
            #expect(M8tecMotionArtwork.isAllowedMediaURL(URL(string: value)!))
        }
        for value in ["http://mvod.itunes.apple.com/art.mp4", "https://mvod.itunes.apple.com.evil.test/art.mp4", "https://localhost/art.mp4", "https://127.0.0.1/art.mp4", "https://user@mvod.itunes.apple.com/art.mp4", "https://mvod.itunes.apple.com:8080/art.mp4", "file:///tmp/art.mp4"] {
            #expect(!M8tecMotionArtwork.isAllowedMediaURL(URL(string: value)!))
        }
    }

    @Test func selectsBoundedSquareAVCRenditionWithLowerBandwidth() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:RESOLUTION=2160x2160,BANDWIDTH=15000000,CODECS="avc1.64001f"
        huge.m3u8
        #EXT-X-STREAM-INF:RESOLUTION=960x960,BANDWIDTH=4000000,CODECS="avc1.64001f"
        high.m3u8
        #EXT-X-STREAM-INF:RESOLUTION=960x960,BANDWIDTH=3000000,CODECS="avc1.64001f"
        chosen.m3u8
        #EXT-X-STREAM-INF:RESOLUTION=1080x1080,BANDWIDTH=2000000,CODECS="hvc1.2"
        hevc.m3u8
        #EXT-X-STREAM-INF:RESOLUTION=360x640,BANDWIDTH=1000000,CODECS="avc1.64001f"
        tall.m3u8
        """
        #expect(try M8tecMotionArtwork.preferredPlaylist(in: text, relativeTo: mediaBase).lastPathComponent == "chosen.m3u8")
    }

    @Test func resolvesByteRangesIntoOneCacheableMP4() throws {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="clip.mp4",BYTERANGE="900@0"
        #EXTINF:3.0,
        #EXT-X-BYTERANGE:1000@900
        clip.mp4
        #EXTINF:3.0,
        #EXT-X-BYTERANGE:1000@1900
        clip.mp4
        #EXT-X-ENDLIST
        """
        #expect(try M8tecMotionArtwork.videoURL(in: text, relativeTo: mediaBase).absoluteString == "https://mvod.itunes.apple.com/art/clip.mp4")
        #expect(throws: M8tecMotionArtwork.ParseError.unsupportedPlaylist) {
            try M8tecMotionArtwork.videoURL(in: text.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""), relativeTo: mediaBase)
        }
        #expect(throws: M8tecMotionArtwork.ParseError.invalidURL) {
            try M8tecMotionArtwork.videoURL(in: text.replacingOccurrences(of: "clip.mp4", with: "https://localhost/private.mp4"), relativeTo: mediaBase)
        }
    }

    @Test func rejectsEncryptedUnboundedMalformedAndSplitMedia() {
        let invalid = [
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:3,\nclip.mp4",
            "#EXTINF:61,\nclip.mp4",
            "#EXTINF:,\nclip.mp4",
            "#EXTINF:nan,\nclip.mp4",
            "#EXTINF:3,\nfirst.mp4\n#EXTINF:3,\nsecond.mp4",
            "#EXT-X-MAP:URI=\"other.mp4\"\n#EXTINF:3,\nclip.mp4",
        ]
        for body in invalid {
            #expect(throws: M8tecMotionArtwork.ParseError.unsupportedPlaylist) {
                try M8tecMotionArtwork.videoURL(in: "#EXTM3U\n" + body + "\n#EXT-X-ENDLIST", relativeTo: mediaBase)
            }
        }
    }

    private var mediaBase: URL { URL(string: "https://mvod.itunes.apple.com/art/main.m3u8")! }

    @Test func requestAdvertisesOnlySupportedAnimatedImages() {
        let request = MotionArtworkServiceRequest(input: input())

        #expect(request.schemaVersion == 1)
        #expect(request.acceptedKinds == [.animatedImage])
        #expect(Set(request.acceptedMIMETypes) == [
            "image/apng", "image/gif", "image/png", "image/webp",
        ])
    }

    @Test func resolvesMatchedSquareAnimatedImage() throws {
        let album = MotionArtworkAlbumCandidate(id: "album", identity: input(upc: "123"))
        let portrait = asset(id: "portrait", width: 900, height: 1_200)
        let square = asset(id: "square", width: 1_200, height: 1_200)
        let response = MotionArtworkServiceResponse(candidates: [
            .init(album: album, assets: [portrait, square]),
        ])

        let result = MotionArtworkServiceResolver.resolve(
            input: input(upc: "123"),
            response: response
        )
        guard case .asset(let resolved) = result else {
            Issue.record("Expected an asset")
            return
        }
        #expect(resolved.assetIdentifier == "square")
    }

    @Test func neverGuessesBetweenAmbiguousAlbums() {
        let first = MotionArtworkAlbumCandidate(id: "one", identity: input())
        let second = MotionArtworkAlbumCandidate(id: "two", identity: input())
        let response = MotionArtworkServiceResponse(candidates: [
            .init(album: first, assets: [asset(id: "one")]),
            .init(album: second, assets: [asset(id: "two")]),
        ])

        let result = MotionArtworkServiceResolver.resolve(input: input(), response: response)
        guard case .ambiguous(let candidates) = result else {
            Issue.record("Expected an ambiguous result")
            return
        }
        #expect(Set(candidates.map(\.id)) == ["one", "two"])
    }

    @Test func rejectsVideoExpiredUnsafeAndUnsupportedAssets() {
        let now = Date(timeIntervalSince1970: 100)
        let values = [
            asset(id: "video", kind: .video),
            asset(id: "expired", expiresAt: Date(timeIntervalSince1970: 99)),
            asset(id: "file", url: URL(fileURLWithPath: "/tmp/art.gif")),
            asset(id: "svg", mimeType: "image/svg+xml"),
        ]

        #expect(MotionArtworkServiceResolver.preferredAsset(in: values, now: now) == nil)
    }

    @Test func rejectsUnknownSchemaAndAcceptsMIMEParameters() {
        let album = MotionArtworkAlbumCandidate(id: "album", identity: input())
        let parameterized = asset(id: "gif", mimeType: "image/gif; charset=binary")
        let unsupported = MotionArtworkServiceResponse(
            schemaVersion: 2,
            candidates: [.init(album: album, assets: [parameterized])]
        )
        #expect(MotionArtworkServiceResolver.resolve(input: input(), response: unsupported) == .unsupported)
        #expect(MotionArtworkServiceResolver.preferredAsset(in: [parameterized]) != nil)
    }

    private func input(upc: String? = nil) -> MotionArtworkLookupInput {
        MotionArtworkLookupInput(
            upc: upc,
            albumArtist: "Example Artist",
            albumTitle: "Example Album",
            releaseYear: 2026,
            trackCount: 10
        )
    }

    private func asset(
        id: String,
        kind: MotionArtworkAssetKind = .animatedImage,
        url: URL = URL(string: "https://art.example.test/cover.gif")!,
        mimeType: String? = "image/gif",
        width: Int? = 1_000,
        height: Int? = 1_000,
        expiresAt: Date? = nil
    ) -> MotionArtworkAsset {
        MotionArtworkAsset(
            providerIdentifier: "configured-service",
            assetIdentifier: id,
            kind: kind,
            assetURL: url,
            mimeType: mimeType,
            pixelWidth: width,
            pixelHeight: height,
            expiresAt: expiresAt
        )
    }
}
