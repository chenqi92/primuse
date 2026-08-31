import Foundation

/// Versioned JSON contract for a service explicitly configured by the user.
/// Primuse does not ship an Apple Music Motion Artwork endpoint and never
/// probes private Apple web fields; a compatible service may lawfully provide
/// an animated-image rendition for an album identity. Dates on the wire use
/// RFC 3339 / ISO 8601 strings in UTC, with optional fractional seconds.
public struct MotionArtworkServiceRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let input: MotionArtworkLookupInput
    public let acceptedKinds: [MotionArtworkAssetKind]
    public let acceptedMIMETypes: [String]

    public init(input: MotionArtworkLookupInput) {
        schemaVersion = Self.currentSchemaVersion
        self.input = input
        acceptedKinds = [.animatedImage]
        acceptedMIMETypes = MotionArtworkServiceResolver.supportedAnimatedImageMIMETypes.sorted()
    }
}

public struct MotionArtworkServiceCandidate: Codable, Equatable, Sendable {
    public let album: MotionArtworkAlbumCandidate
    public let assets: [MotionArtworkAsset]

    public init(album: MotionArtworkAlbumCandidate, assets: [MotionArtworkAsset]) {
        self.album = album
        self.assets = assets
    }
}

public struct MotionArtworkServiceResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let candidates: [MotionArtworkServiceCandidate]

    public init(
        schemaVersion: Int = MotionArtworkServiceRequest.currentSchemaVersion,
        candidates: [MotionArtworkServiceCandidate]
    ) {
        self.schemaVersion = schemaVersion
        self.candidates = candidates
    }
}

public enum MotionArtworkServiceResolver {
    public static let supportedAnimatedImageMIMETypes: Set<String> = [
        "image/apng",
        "image/gif",
        "image/png",
        "image/webp",
    ]

    public static func resolve(
        input: MotionArtworkLookupInput,
        response: MotionArtworkServiceResponse,
        now: Date = Date()
    ) -> MotionArtworkLookupResult {
        guard response.schemaVersion == MotionArtworkServiceRequest.currentSchemaVersion else {
            return .unsupported
        }

        let identityResolution = MotionArtworkCandidateMatcher.resolve(
            input,
            among: response.candidates.map(\.album)
        )
        switch identityResolution {
        case .notFound:
            return .notFound
        case .ambiguous(let candidates):
            return .ambiguous(candidates)
        case .matched(let album):
            guard let entry = response.candidates.first(where: { $0.album == album }) else {
                return .notFound
            }
            guard let asset = preferredAsset(in: entry.assets, now: now) else {
                return .unsupported
            }
            return .asset(asset)
        }
    }

    public static func preferredAsset(
        in assets: [MotionArtworkAsset],
        now: Date = Date()
    ) -> MotionArtworkAsset? {
        assets
            .filter { asset in
                guard asset.kind == .animatedImage,
                      !asset.providerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      isSafeRemoteURL(asset.assetURL),
                      asset.expiresAt.map({ $0 > now }) ?? true else {
                    return false
                }
                if let mimeType = normalizedMIMEType(asset.mimeType) {
                    return supportedAnimatedImageMIMETypes.contains(mimeType)
                }
                return true
            }
            .sorted(by: assetIsPreferred)
            .first
    }

    public static func isSafeRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            return false
        }
        return true
    }

    private static func normalizedMIMEType(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func assetIsPreferred(
        _ lhs: MotionArtworkAsset,
        _ rhs: MotionArtworkAsset
    ) -> Bool {
        let left = assetRank(lhs)
        let right = assetRank(rhs)
        if left.squareRank != right.squareRank { return left.squareRank > right.squareRank }
        if left.pixelArea != right.pixelArea { return left.pixelArea > right.pixelArea }
        return stableAssetKey(lhs) < stableAssetKey(rhs)
    }

    private static func assetRank(
        _ asset: MotionArtworkAsset
    ) -> (squareRank: Int, pixelArea: Int64) {
        guard let width = asset.pixelWidth,
              let height = asset.pixelHeight,
              width > 0,
              height > 0,
              width <= ArtworkAnimationLimits.default.maximumDimension,
              height <= ArtworkAnimationLimits.default.maximumDimension else {
            return (0, 0)
        }
        let ratio = Double(width) / Double(height)
        let squareRank = abs(ratio - 1) < 0.001 ? 2 : (0.9...1.1).contains(ratio) ? 1 : 0
        return (squareRank, Int64(width) * Int64(height))
    }

    private static func stableAssetKey(_ asset: MotionArtworkAsset) -> String {
        [
            asset.providerIdentifier,
            asset.assetIdentifier ?? "",
            asset.assetURL.absoluteString,
        ].joined(separator: "\u{1F}")
    }
}
