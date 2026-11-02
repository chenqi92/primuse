import Foundation

public enum MotionArtworkServiceSource: String, CaseIterable, Sendable {
    case m8tec
    case custom

    public static func resolved(_ value: String, customEndpoint: String) -> Self {
        Self(rawValue: value) ?? (customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .m8tec : .custom)
    }
}

/// The public API returns an Apple CDN HLS playlist. Apple's artwork renditions
/// use byte ranges into one MP4, which can be cached once and looped locally.
public enum M8tecMotionArtwork {
    public static let endpoint = URL(string: "https://artwork.m8tec.top/api/v1/artwork/search")!
    public static let maximumVideoBytes = 32 * 1024 * 1024

    public enum ParseError: Error, Equatable, Sendable {
        case unsupportedPlaylist
        case invalidURL
        case mismatchedAlbum
    }

    public struct Response: Decodable, Sendable {
        public let url: URL?
        public let artist: String?
        public let album: String?

        public func artworkURL(matching input: MotionArtworkLookupInput) throws -> URL? {
            // A catalog-ID request already identifies the edition. Metadata
            // searches must not substitute another artist or a deluxe edition.
            if M8tecMotionArtwork.catalogID(input) == nil {
                guard M8tecMotionArtwork.normalized(artist) == M8tecMotionArtwork.normalized(input.albumArtist),
                      M8tecMotionArtwork.normalized(album) == M8tecMotionArtwork.normalized(input.albumTitle) else {
                    throw ParseError.mismatchedAlbum
                }
            }
            guard let url else { return nil }
            guard M8tecMotionArtwork.isAllowedMediaURL(url) else { throw ParseError.invalidURL }
            return url
        }
    }

    public static func requestURL(for input: MotionArtworkLookupInput) -> URL? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if let id = catalogID(input) {
            let region = input.storefront?.lowercased() ?? "us"
            let storefront = region.count == 2 && region.utf8.allSatisfy({ (97...122).contains($0) }) ? region : "us"
            components.path = "/api/v1/artwork/url"
            components.queryItems = [URLQueryItem(name: "url", value: "https://music.apple.com/\(storefront)/album/\(id)")]
        } else {
            guard let artist = input.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty,
                  let album = input.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty else { return nil }
            components.queryItems = [URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "album", value: album)]
        }
        return components.url
    }

    public static func isAllowedMediaURL(_ url: URL) -> Bool {
        guard MotionArtworkServiceResolver.isSafeRemoteURL(url), url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com")
            || host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
    }

    public static func preferredPlaylist(in text: String, relativeTo baseURL: URL) throws -> URL {
        let lines = try playlistLines(text)
        guard lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) else { return baseURL }
        var candidates: [(url: URL, side: Int, bandwidth: Int, avc: Bool)] = []
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            let attributes = attributes(in: lines[index])
            let dimensions = (attributes["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
            guard dimensions.count == 2, dimensions[0] > 0, dimensions[1] > 0,
                  max(dimensions[0], dimensions[1]) <= 1080,
                  abs(Double(dimensions[0]) / Double(dimensions[1]) - 1) < 0.1,
                  let bandwidth = Int(attributes["BANDWIDTH"] ?? ""), bandwidth > 0, bandwidth <= 8_000_000,
                  attributes["VIDEO-RANGE"].map({ $0 == "SDR" }) ?? true,
                  let codecs = attributes["CODECS"],
                  codecs.hasPrefix("avc1") || codecs.hasPrefix("hvc1"),
                  index + 1 < lines.count, !lines[index + 1].hasPrefix("#") else { continue }
            let url = try mediaURL(lines[index + 1], relativeTo: baseURL)
            candidates.append((url, max(dimensions[0], dimensions[1]), bandwidth, codecs.hasPrefix("avc1")))
        }
        // A 960-pixel cover is sufficient for the player, with 1080 as a
        // fallback when the provider offers no smaller rendition.
        let bounded = candidates.filter { $0.side <= 960 }
        let preferred = (bounded.isEmpty ? candidates : bounded).sorted {
            if $0.avc != $1.avc { return $0.avc }
            if $0.side != $1.side { return $0.side > $1.side }
            return $0.bandwidth < $1.bandwidth
        }
        guard let first = preferred.first else { throw ParseError.unsupportedPlaylist }
        return first.url
    }

    public static func videoURL(in text: String, relativeTo baseURL: URL) throws -> URL {
        let lines = try playlistLines(text)
        guard lines.contains("#EXT-X-ENDLIST"),
              !lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
              !lines.contains(where: { $0.hasPrefix("#EXT-X-KEY:") && attributes(in: $0)["METHOD"] != "NONE" }) else {
            throw ParseError.unsupportedPlaylist
        }
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap {
            $0.dropFirst(8).split(separator: ",", maxSplits: 1).first.flatMap { Double($0) }
        }
        guard !durations.isEmpty, durations.count <= 120,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }),
              durations.reduce(0, +) <= 60 else { throw ParseError.unsupportedPlaylist }
        let references = lines.filter { !$0.hasPrefix("#") }
        guard references.count == durations.count else { throw ParseError.unsupportedPlaylist }
        let urls = try Set(references.map { try mediaURL($0, relativeTo: baseURL) })
        guard urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "mp4" else {
            throw ParseError.unsupportedPlaylist
        }
        for line in lines where line.hasPrefix("#EXT-X-MAP:") {
            guard let reference = attributes(in: line)["URI"],
                  try mediaURL(reference, relativeTo: baseURL) == url else { throw ParseError.unsupportedPlaylist }
        }
        return url
    }

    public static func isMP4(_ data: Data) -> Bool {
        data.count >= 12 && data[data.startIndex + 4..<data.startIndex + 8].elementsEqual("ftyp".utf8)
    }

    private static func catalogID(_ input: MotionArtworkLookupInput) -> String? {
        MotionArtworkAppleAlbumIdentifiers(rawAlbumID: input.appleCatalogAlbumID).catalogID
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func mediaURL(_ reference: String, relativeTo baseURL: URL) throws -> URL {
        guard let url = URL(string: reference, relativeTo: baseURL)?.absoluteURL,
              isAllowedMediaURL(url) else { throw ParseError.invalidURL }
        return url
    }

    private static func playlistLines(_ text: String) throws -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { throw ParseError.unsupportedPlaylist }
        return lines
    }

    private static func attributes(in line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var parts: [String] = [], part = "", quoted = false
        for character in line[line.index(after: colon)...] {
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted { parts.append(part); part = "" } else { part.append(character) }
        }
        parts.append(part)
        var result: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return result
    }
}

/// Versioned JSON contract for a custom service configured by the user.
/// A compatible service provides an animated-image rendition for an album
/// identity. Dates on the wire use
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
