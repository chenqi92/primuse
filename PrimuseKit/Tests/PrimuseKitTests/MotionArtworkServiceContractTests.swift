import Foundation
import Testing
@testable import PrimuseKit

struct MotionArtworkServiceContractTests {
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
