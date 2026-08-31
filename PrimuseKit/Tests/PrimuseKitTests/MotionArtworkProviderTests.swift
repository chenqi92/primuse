import Foundation
import Testing
@testable import PrimuseKit

@Suite("Motion artwork provider")
struct MotionArtworkProviderTests {
    @Test("Lookup input preserves every provider-neutral identity field")
    func lookupInputCodableRoundTrip() throws {
        let input = MotionArtworkLookupInput(
            appleCatalogAlbumID: "1624945511",
            appleLibraryAlbumID: "i.aBcDeFg",
            upc: "00602445882142",
            isrcs: ["USUM72208968", "USUM72208969"],
            musicBrainzReleaseID: "b846a592-3f86-4c47-9b22-b73c55d43a8e",
            albumArtist: "Beyoncé",
            albumTitle: "Renaissance",
            releaseYear: 2022,
            trackCount: 16,
            storefront: "us"
        )

        #expect(try roundTrip(input) == input)
        requireSendable(MotionArtworkLookupInput.self)
    }

    @Test("Apple official capability is identity-only")
    func appleOfficialCapabilityBoundary() throws {
        let capabilities = MotionArtworkProviderCapabilities.appleMusicOfficial

        #expect(capabilities.contains(.identityResolution))
        #expect(!capabilities.contains(.motionArtworkRetrieval))
        #expect(try roundTrip(capabilities) == capabilities)
        requireSendable(MotionArtworkProviderCapabilities.self)
    }

    @Test("Only known Apple album ID namespaces become stable lookup IDs")
    func classifiesAppleAlbumIDsConservatively() {
        #expect(MotionArtworkAppleAlbumIdentifiers(rawAlbumID: " 1624945511 ")
            == .init(catalogID: "1624945511", libraryID: nil))
        #expect(MotionArtworkAppleAlbumIdentifiers(rawAlbumID: "l.library-album")
            == .init(catalogID: nil, libraryID: "l.library-album"))
        #expect(MotionArtworkAppleAlbumIdentifiers(rawAlbumID: "i.library-album")
            == .init(catalogID: nil, libraryID: "i.library-album"))
        #expect(MotionArtworkAppleAlbumIdentifiers(rawAlbumID: "opaque")
            == .init(catalogID: nil, libraryID: nil))
    }

    @Test("Motion asset URLs and preview metadata round-trip without App types")
    func assetCodableRoundTrip() throws {
        let asset = MotionArtworkAsset(
            providerIdentifier: "user.example",
            assetIdentifier: "album-motion-v3",
            kind: .video,
            assetURL: URL(string: "https://media.example/artwork/album.mp4")!,
            previewImageURL: URL(string: "https://media.example/artwork/album.jpg")!,
            mimeType: "video/mp4",
            pixelWidth: 1_200,
            pixelHeight: 1_200,
            duration: 18.5,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        #expect(try roundTrip(asset) == asset)
        requireSendable(MotionArtworkAsset.self)
    }

    @Test("Every lookup outcome is Codable and Sendable")
    func lookupResultCodableRoundTrip() throws {
        let candidate = makeCandidate(
            "candidate",
            catalogID: "1624945511",
            artist: "Artist",
            title: "Album"
        )
        let asset = MotionArtworkAsset(
            providerIdentifier: "user.example",
            kind: .animatedImage,
            assetURL: URL(string: "https://media.example/artwork/album.webp")!,
            previewImageURL: URL(string: "https://media.example/artwork/album.png")!
        )
        let results: [MotionArtworkLookupResult] = [
            .asset(asset),
            .notFound,
            .ambiguous([candidate]),
            .unsupported,
            .temporarilyUnavailable(retryAfter: Date(timeIntervalSince1970: 2_000_000_100)),
            .temporarilyUnavailable(retryAfter: nil),
        ]

        #expect(try roundTrip(results) == results)
        requireSendable(MotionArtworkLookupResult.self)
    }

    @Test("Exact catalog ID takes priority over a metadata-only candidate")
    func catalogIDTakesPriority() {
        let input = MotionArtworkLookupInput(
            appleCatalogAlbumID: "1624945511",
            albumArtist: "Expected Artist",
            albumTitle: "Expected Album"
        )
        let exactID = makeCandidate(
            "exact-id",
            catalogID: "1624945511",
            artist: "Different Artist",
            title: "Different Album"
        )
        let metadataOnly = makeCandidate(
            "metadata",
            artist: "Expected Artist",
            title: "Expected Album"
        )

        #expect(resolve(input, [metadataOnly, exactID]) == .matched(exactID))
    }

    @Test("Library ID, UPC, and MusicBrainz release ID remain separate stable namespaces")
    func stableIdentifierNamespacesMatchExactly() {
        let library = makeCandidate(
            "library",
            libraryID: "i.library-album",
            artist: "Wrong",
            title: "Wrong"
        )
        #expect(resolve(
            MotionArtworkLookupInput(appleLibraryAlbumID: "i.library-album"),
            [library]
        ) == .matched(library))

        let upc = makeCandidate("upc", upc: "00602445882142")
        #expect(resolve(
            MotionArtworkLookupInput(upc: "00602445882142"),
            [upc]
        ) == .matched(upc))

        let musicBrainz = makeCandidate(
            "musicbrainz",
            musicBrainzReleaseID: "B846A592-3F86-4C47-9B22-B73C55D43A8E"
        )
        #expect(resolve(
            MotionArtworkLookupInput(
                musicBrainzReleaseID: "b846a592-3f86-4c47-9b22-b73c55d43a8e"
            ),
            [musicBrainz]
        ) == .matched(musicBrainz))
    }

    @Test("Opaque Apple IDs do not receive fuzzy or case-insensitive matching")
    func appleIDsAreStrict() {
        let input = MotionArtworkLookupInput(appleCatalogAlbumID: "Catalog.ABC")
        let candidate = makeCandidate("candidate", catalogID: "catalog.abc")

        #expect(resolve(input, [candidate]) == .notFound)
    }

    @Test("ISRC sets compare as complete canonical sets")
    func isrcSetMatching() {
        let input = MotionArtworkLookupInput(
            isrcs: ["US-RC1-76-07839", "GBAYE6800011"]
        )
        let exactSet = makeCandidate(
            "exact-set",
            isrcs: ["GBAYE6800011", "usrc17607839"]
        )

        #expect(resolve(input, [exactSet]) == .matched(exactSet))
    }

    @Test("A partial ISRC overlap cannot identify an album")
    func rejectsPartialISRCOverlap() {
        let input = MotionArtworkLookupInput(
            isrcs: ["USRC17607839", "GBAYE6800011"],
            albumArtist: "Artist",
            albumTitle: "Album"
        )
        let partial = makeCandidate(
            "partial",
            isrcs: ["USRC17607839"],
            artist: "Artist",
            title: "Album"
        )

        #expect(resolve(input, [partial]) == .notFound)
    }

    @Test("Conflicting stable IDs reject an otherwise exact metadata match")
    func stableIdentifierConflictRejectsCandidate() {
        let input = MotionArtworkLookupInput(
            upc: "00602445882142",
            albumArtist: "Artist",
            albumTitle: "Album"
        )
        let conflicting = makeCandidate(
            "conflicting",
            upc: "602445882142",
            artist: "Artist",
            title: "Album"
        )

        #expect(resolve(input, [conflicting]) == .notFound)
    }

    @Test("Metadata fallback normalizes case, width, accents, punctuation, and whitespace")
    func normalizedArtistAndTitleFallback() {
        let input = MotionArtworkLookupInput(
            albumArtist: "Ｂｅｙｏｎｃé & JAY-Z",
            albumTitle: "Everything Is Love"
        )
        let candidate = makeCandidate(
            "metadata",
            artist: "beyonce jay z",
            title: "EVERYTHING-IS-LOVE"
        )

        #expect(resolve(input, [candidate]) == .matched(candidate))
    }

    @Test("Metadata fallback requires both album artist and title")
    func metadataFallbackRequiresArtistAndTitle() {
        let titleOnly = MotionArtworkLookupInput(albumTitle: "Album")
        let artistOnly = MotionArtworkLookupInput(albumArtist: "Artist")
        let candidate = makeCandidate("candidate", artist: "Artist", title: "Album")

        #expect(resolve(titleOnly, [candidate]) == .notFound)
        #expect(resolve(artistOnly, [candidate]) == .notFound)
    }

    @Test("Exact release year uniquely disambiguates normalized metadata matches")
    func releaseYearDisambiguates() {
        let input = MotionArtworkLookupInput(
            albumArtist: "Artist",
            albumTitle: "Album",
            releaseYear: 2024
        )
        let exactYear = makeCandidate(
            "exact-year",
            artist: "Artist",
            title: "Album",
            releaseYear: 2024
        )
        let unknownYear = makeCandidate(
            "unknown-year",
            artist: "Artist",
            title: "Album"
        )

        #expect(resolve(input, [unknownYear, exactYear]) == .matched(exactYear))
    }

    @Test("Exact track count uniquely disambiguates normalized metadata matches")
    func trackCountDisambiguates() {
        let input = MotionArtworkLookupInput(
            albumArtist: "Artist",
            albumTitle: "Album",
            trackCount: 12
        )
        let exactCount = makeCandidate(
            "exact-count",
            artist: "Artist",
            title: "Album",
            trackCount: 12
        )
        let unknownCount = makeCandidate(
            "unknown-count",
            artist: "Artist",
            title: "Album"
        )

        #expect(resolve(input, [unknownCount, exactCount]) == .matched(exactCount))
    }

    @Test("Metadata fallback rejects a sole candidate missing an input release year")
    func metadataFallbackRequiresProvidedReleaseYear() {
        let input = MotionArtworkLookupInput(
            albumArtist: "Artist",
            albumTitle: "Album",
            releaseYear: 2024
        )
        let missingYear = makeCandidate(
            "missing-year",
            artist: "Artist",
            title: "Album"
        )

        #expect(resolve(input, [missingYear]) == .notFound)
    }

    @Test("Metadata fallback rejects a sole candidate missing an input track count")
    func metadataFallbackRequiresProvidedTrackCount() {
        let input = MotionArtworkLookupInput(
            albumArtist: "Artist",
            albumTitle: "Album",
            trackCount: 12
        )
        let missingCount = makeCandidate(
            "missing-count",
            artist: "Artist",
            title: "Album"
        )

        #expect(resolve(input, [missingCount]) == .notFound)
    }

    @Test("Conflicting release year or track count rejects a candidate")
    func detailConflictsRejectCandidates() {
        let input = MotionArtworkLookupInput(
            appleCatalogAlbumID: "catalog",
            albumArtist: "Artist",
            albumTitle: "Album",
            releaseYear: 2024,
            trackCount: 12
        )
        let wrongYear = makeCandidate(
            "wrong-year",
            catalogID: "catalog",
            artist: "Artist",
            title: "Album",
            releaseYear: 2023,
            trackCount: 12
        )
        let wrongCount = makeCandidate(
            "wrong-count",
            catalogID: "catalog",
            artist: "Artist",
            title: "Album",
            releaseYear: 2024,
            trackCount: 11
        )

        #expect(resolve(input, [wrongYear, wrongCount]) == .notFound)
    }

    @Test("Storefront conflicts reject a candidate")
    func storefrontConflictRejectsCandidate() {
        let input = MotionArtworkLookupInput(
            appleCatalogAlbumID: "catalog",
            storefront: "us"
        )
        let candidate = makeCandidate(
            "candidate",
            catalogID: "catalog",
            storefront: "jp"
        )

        #expect(resolve(input, [candidate]) == .notFound)
    }

    @Test("Indistinguishable metadata candidates remain ambiguous")
    func ambiguousMetadataNeverGuesses() {
        let input = MotionArtworkLookupInput(
            albumArtist: "Artist",
            albumTitle: "Album",
            releaseYear: 2024,
            trackCount: 12
        )
        let first = makeCandidate(
            "first",
            artist: "Artist",
            title: "Album",
            releaseYear: 2024,
            trackCount: 12
        )
        let second = makeCandidate(
            "second",
            artist: "Artist",
            title: "Album",
            releaseYear: 2024,
            trackCount: 12
        )

        #expect(resolve(input, [first, second]) == .ambiguous([first, second]))
    }

    @Test("Duplicate stable-ID candidates remain ambiguous")
    func ambiguousStableIDNeverGuesses() {
        let input = MotionArtworkLookupInput(appleCatalogAlbumID: "catalog")
        let first = makeCandidate("first", catalogID: "catalog")
        let second = makeCandidate("second", catalogID: "catalog")

        #expect(resolve(input, [first, second]) == .ambiguous([first, second]))
    }

    @Test("Stable matches exclude metadata-only candidates from ambiguity")
    func stableMatchesDefineHigherPriorityTier() {
        let input = MotionArtworkLookupInput(
            appleCatalogAlbumID: "catalog",
            albumArtist: "Artist",
            albumTitle: "Album"
        )
        let exact = makeCandidate("exact", catalogID: "catalog")
        let metadataOne = makeCandidate("metadata-one", artist: "Artist", title: "Album")
        let metadataTwo = makeCandidate("metadata-two", artist: "Artist", title: "Album")

        #expect(resolve(input, [metadataOne, exact, metadataTwo]) == .matched(exact))
    }

    @Test("A stable lookup never falls back to a candidate that omits stable IDs")
    func stableLookupRequiresStableEcho() {
        let input = MotionArtworkLookupInput(
            appleCatalogAlbumID: "catalog",
            albumArtist: "Artist",
            albumTitle: "Album"
        )
        let metadataOnly = makeCandidate(
            "metadata-only",
            artist: "Artist",
            title: "Album"
        )

        #expect(resolve(input, [metadataOnly]) == .notFound)
    }

    @Test("A candidate matching more stable namespaces outranks a partial stable match")
    func strongestStableIdentityWins() {
        let input = MotionArtworkLookupInput(
            appleCatalogAlbumID: "catalog",
            upc: "123",
            albumArtist: "Artist",
            albumTitle: "Album"
        )
        let partial = makeCandidate(
            "partial",
            catalogID: "catalog",
            artist: "Artist",
            title: "Album",
            releaseYear: 2026
        )
        let complete = makeCandidate(
            "complete",
            catalogID: "catalog",
            upc: "123"
        )

        #expect(resolve(input, [partial, complete]) == .matched(complete))
    }

    @Test("Empty candidate set reports not found")
    func emptyCandidatesAreNotFound() {
        #expect(resolve(MotionArtworkLookupInput(), []) == .notFound)
    }

    private func resolve(
        _ input: MotionArtworkLookupInput,
        _ candidates: [MotionArtworkAlbumCandidate]
    ) -> MotionArtworkIdentityResolution {
        MotionArtworkCandidateMatcher.resolve(input, among: candidates)
    }

    private func makeCandidate(
        _ id: String,
        catalogID: String? = nil,
        libraryID: String? = nil,
        upc: String? = nil,
        isrcs: Set<String> = [],
        musicBrainzReleaseID: String? = nil,
        artist: String? = nil,
        title: String? = nil,
        releaseYear: Int? = nil,
        trackCount: Int? = nil,
        storefront: String? = nil
    ) -> MotionArtworkAlbumCandidate {
        MotionArtworkAlbumCandidate(
            id: id,
            identity: MotionArtworkLookupInput(
                appleCatalogAlbumID: catalogID,
                appleLibraryAlbumID: libraryID,
                upc: upc,
                isrcs: isrcs,
                musicBrainzReleaseID: musicBrainzReleaseID,
                albumArtist: artist,
                albumTitle: title,
                releaseYear: releaseYear,
                trackCount: trackCount,
                storefront: storefront
            )
        )
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    private func requireSendable<Value: Sendable>(_: Value.Type) {}
}
