import Foundation

public struct MotionArtworkLookupInput: Codable, Hashable, Sendable {
    public let appleCatalogAlbumID: String?
    public let appleLibraryAlbumID: String?
    public let upc: String?
    public let isrcs: Set<String>
    public let musicBrainzReleaseID: String?
    public let albumArtist: String?
    public let albumTitle: String?
    public let releaseYear: Int?
    public let trackCount: Int?
    public let storefront: String?

    public init(
        appleCatalogAlbumID: String? = nil,
        appleLibraryAlbumID: String? = nil,
        upc: String? = nil,
        isrcs: Set<String> = [],
        musicBrainzReleaseID: String? = nil,
        albumArtist: String? = nil,
        albumTitle: String? = nil,
        releaseYear: Int? = nil,
        trackCount: Int? = nil,
        storefront: String? = nil
    ) {
        self.appleCatalogAlbumID = appleCatalogAlbumID
        self.appleLibraryAlbumID = appleLibraryAlbumID
        self.upc = upc
        self.isrcs = isrcs
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.albumArtist = albumArtist
        self.albumTitle = albumTitle
        self.releaseYear = releaseYear
        self.trackCount = trackCount
        self.storefront = storefront
    }
}

/// Conservatively classifies only Apple album-ID shapes whose namespace is
/// known. Unknown opaque values are deliberately omitted so a provider falls
/// back to album metadata instead of receiving a mislabeled stable ID.
public struct MotionArtworkAppleAlbumIdentifiers: Equatable, Sendable {
    public let catalogID: String?
    public let libraryID: String?

    public init(catalogID: String?, libraryID: String?) {
        self.catalogID = catalogID
        self.libraryID = libraryID
    }

    public init(rawAlbumID: String?) {
        guard let rawAlbumID else {
            catalogID = nil
            libraryID = nil
            return
        }
        let value = rawAlbumID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            catalogID = nil
            libraryID = nil
            return
        }

        if value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            catalogID = value
            libraryID = nil
        } else if value.hasPrefix("i.") || value.hasPrefix("l.") {
            catalogID = nil
            libraryID = value
        } else {
            catalogID = nil
            libraryID = nil
        }
    }
}

public struct MotionArtworkAlbumCandidate: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let identity: MotionArtworkLookupInput

    public init(id: String, identity: MotionArtworkLookupInput) {
        self.id = id
        self.identity = identity
    }
}

public enum MotionArtworkProviderCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case identityResolution
    case motionArtworkRetrieval
}

public struct MotionArtworkProviderCapabilities: Codable, Hashable, Sendable {
    public let supported: Set<MotionArtworkProviderCapability>

    public init(supported: Set<MotionArtworkProviderCapability>) {
        self.supported = supported
    }

    public func contains(_ capability: MotionArtworkProviderCapability) -> Bool {
        supported.contains(capability)
    }

    /// Public Apple Music APIs support album identity resolution, but do not
    /// expose Apple Music Motion Artwork assets to third-party apps.
    public static let appleMusicOfficial = MotionArtworkProviderCapabilities(
        supported: [.identityResolution]
    )

    public static let identityAndMotionArtwork = MotionArtworkProviderCapabilities(
        supported: [.identityResolution, .motionArtworkRetrieval]
    )
}

public enum MotionArtworkAssetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case video
    case animatedImage
}

public struct MotionArtworkAsset: Codable, Hashable, Sendable {
    public let providerIdentifier: String
    public let assetIdentifier: String?
    public let kind: MotionArtworkAssetKind
    public let assetURL: URL
    public let previewImageURL: URL?
    public let mimeType: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let duration: TimeInterval?
    public let expiresAt: Date?

    public init(
        providerIdentifier: String,
        assetIdentifier: String? = nil,
        kind: MotionArtworkAssetKind,
        assetURL: URL,
        previewImageURL: URL? = nil,
        mimeType: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: TimeInterval? = nil,
        expiresAt: Date? = nil
    ) {
        self.providerIdentifier = providerIdentifier
        self.assetIdentifier = assetIdentifier
        self.kind = kind
        self.assetURL = assetURL
        self.previewImageURL = previewImageURL
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.expiresAt = expiresAt
    }
}

public enum MotionArtworkIdentityResolution: Codable, Hashable, Sendable {
    case matched(MotionArtworkAlbumCandidate)
    case notFound
    case ambiguous([MotionArtworkAlbumCandidate])
}

public enum MotionArtworkLookupResult: Codable, Hashable, Sendable {
    case asset(MotionArtworkAsset)
    case notFound
    case ambiguous([MotionArtworkAlbumCandidate])
    case unsupported
    case temporarilyUnavailable(retryAfter: Date?)
}

public protocol MotionArtworkProvider: Sendable {
    var identifier: String { get }
    var capabilities: MotionArtworkProviderCapabilities { get }

    func resolveIdentity(
        for input: MotionArtworkLookupInput
    ) async -> MotionArtworkIdentityResolution

    func motionArtwork(
        for candidate: MotionArtworkAlbumCandidate
    ) async -> MotionArtworkLookupResult
}

public enum MotionArtworkCandidateMatcher {
    public static func resolve(
        _ input: MotionArtworkLookupInput,
        among candidates: [MotionArtworkAlbumCandidate]
    ) -> MotionArtworkIdentityResolution {
        let assessed = candidates.compactMap { candidate -> AssessedCandidate? in
            guard storefrontsAreCompatible(input.storefront, candidate.identity.storefront),
                  let detailScore = detailScore(input, candidate.identity),
                  let stableMatchCount = stableMatchCount(input, candidate.identity) else {
                return nil
            }
            return AssessedCandidate(
                candidate: candidate,
                stableMatchCount: stableMatchCount,
                detailScore: detailScore
            )
        }

        let stableMatches = assessed.filter { $0.stableMatchCount > 0 }
        if !stableMatches.isEmpty {
            return selectCandidate(from: stableMatches)
        }

        // Once the caller has a stable identity, accepting a candidate that
        // omits every stable namespace would silently weaken the lookup to a
        // title search. Missing identifiers therefore remain a miss; metadata
        // fallback is reserved for inputs that genuinely have no stable ID.
        guard !hasStableIdentifier(input) else { return .notFound }
        let metadataCandidates = assessed.filter {
            $0.stableMatchCount == 0 && metadataMatches(input, $0.candidate.identity)
        }
        return selectCandidate(from: metadataCandidates)
    }

    private static func hasStableIdentifier(_ input: MotionArtworkLookupInput) -> Bool {
        [
            input.appleCatalogAlbumID,
            input.appleLibraryAlbumID,
            input.upc,
            input.musicBrainzReleaseID,
        ].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } || input.isrcs.contains { value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private struct AssessedCandidate {
        let candidate: MotionArtworkAlbumCandidate
        let stableMatchCount: Int
        let detailScore: Int
    }

    private static func selectCandidate(
        from candidates: [AssessedCandidate]
    ) -> MotionArtworkIdentityResolution {
        guard !candidates.isEmpty else { return .notFound }
        guard candidates.count > 1 else { return .matched(candidates[0].candidate) }

        let highestStableMatchCount = candidates.map(\.stableMatchCount).max() ?? 0
        let strongestStableMatches = candidates.filter {
            $0.stableMatchCount == highestStableMatchCount
        }
        guard strongestStableMatches.count > 1 else {
            return .matched(strongestStableMatches[0].candidate)
        }

        let highestDetailScore = strongestStableMatches.map(\.detailScore).max() ?? 0
        if highestDetailScore > 0 {
            let best = strongestStableMatches.filter { $0.detailScore == highestDetailScore }
            if best.count == 1, let match = best.first {
                return .matched(match.candidate)
            }
        }

        return .ambiguous(strongestStableMatches.map(\.candidate))
    }

    /// Returns `nil` when two identities provide conflicting values for the
    /// same stable identifier. Missing values are not conflicts.
    private static func stableMatchCount(
        _ input: MotionArtworkLookupInput,
        _ candidate: MotionArtworkLookupInput
    ) -> Int? {
        let identifierPairs: [(String?, String?, (String?) -> String?)] = [
            (input.appleCatalogAlbumID, candidate.appleCatalogAlbumID, normalizedOpaqueID),
            (input.appleLibraryAlbumID, candidate.appleLibraryAlbumID, normalizedOpaqueID),
            (input.upc, candidate.upc, normalizedOpaqueID),
            (
                input.musicBrainzReleaseID,
                candidate.musicBrainzReleaseID,
                normalizedCaseInsensitiveID
            ),
        ]

        var matchCount = 0
        for (inputValue, candidateValue, normalize) in identifierPairs {
            guard let inputValue = normalize(inputValue),
                  let candidateValue = normalize(candidateValue) else {
                continue
            }
            guard inputValue == candidateValue else { return nil }
            matchCount += 1
        }

        let inputISRCs = normalizedISRCs(input.isrcs)
        let candidateISRCs = normalizedISRCs(candidate.isrcs)
        if !inputISRCs.isEmpty, !candidateISRCs.isEmpty {
            guard inputISRCs == candidateISRCs else { return nil }
            matchCount += 1
        }

        return matchCount
    }

    /// Release year and track count are exact disambiguators. An explicit
    /// conflict disqualifies a candidate instead of reducing a fuzzy score.
    private static func detailScore(
        _ input: MotionArtworkLookupInput,
        _ candidate: MotionArtworkLookupInput
    ) -> Int? {
        var score = 0

        if let inputYear = input.releaseYear, let candidateYear = candidate.releaseYear {
            guard inputYear == candidateYear else { return nil }
            score += 1
        }

        if let inputTrackCount = input.trackCount,
           let candidateTrackCount = candidate.trackCount {
            guard inputTrackCount == candidateTrackCount else { return nil }
            score += 1
        }

        return score
    }

    private static func metadataMatches(
        _ input: MotionArtworkLookupInput,
        _ candidate: MotionArtworkLookupInput
    ) -> Bool {
        let inputArtist = normalizedMetadata(input.albumArtist)
        let inputTitle = normalizedMetadata(input.albumTitle)
        guard !inputArtist.isEmpty, !inputTitle.isEmpty else { return false }

        if let inputYear = input.releaseYear {
            guard candidate.releaseYear == inputYear else { return false }
        }

        if let inputTrackCount = input.trackCount {
            guard candidate.trackCount == inputTrackCount else { return false }
        }

        return inputArtist == normalizedMetadata(candidate.albumArtist)
            && inputTitle == normalizedMetadata(candidate.albumTitle)
    }

    private static func storefrontsAreCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedCaseInsensitiveID(lhs),
              let rhs = normalizedCaseInsensitiveID(rhs) else {
            return true
        }
        return lhs == rhs
    }

    private static func normalizedOpaqueID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedCaseInsensitiveID(_ value: String?) -> String? {
        normalizedOpaqueID(value)?.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizedISRCs(_ values: Set<String>) -> Set<String> {
        Set(values.compactMap { value in
            let folded = value.uppercased(with: Locale(identifier: "en_US_POSIX"))
            let scalars = folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            let normalized = String(String.UnicodeScalarView(scalars))
            return normalized.isEmpty ? nil : normalized
        })
    }

    private static func normalizedMetadata(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        return String(String.UnicodeScalarView(scalars))
    }
}
