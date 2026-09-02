import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ServerMediaShareSelectionKind: String, Codable, Hashable, Sendable {
    case song
    case album
    case artist
    case playlist
    case selection
}

public struct ServerMediaShareTarget: Identifiable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let kind: ServerMediaShareSelectionKind
    public let title: String
    public let itemIDs: [String]

    public init(
        sourceID: String,
        kind: ServerMediaShareSelectionKind,
        title: String,
        itemIDs: [String]
    ) {
        self.sourceID = sourceID
        self.kind = kind
        self.title = title
        self.itemIDs = itemIDs
    }

    public var id: String {
        ([sourceID, kind.rawValue] + itemIDs).joined(separator: "\u{0}")
    }
}

public struct ServerMediaSharingFeatures: Equatable, Sendable {
    public let supportsDescription: Bool
    public let supportsExpiration: Bool
    public let supportsMultipleItems: Bool
    public let supportsPasswordProtection: Bool

    public init(
        supportsDescription: Bool,
        supportsExpiration: Bool,
        supportsMultipleItems: Bool,
        supportsPasswordProtection: Bool
    ) {
        self.supportsDescription = supportsDescription
        self.supportsExpiration = supportsExpiration
        self.supportsMultipleItems = supportsMultipleItems
        self.supportsPasswordProtection = supportsPasswordProtection
    }

    /// OpenSubsonic `createShare` has description, expiration and repeated
    /// item IDs, but the standard deliberately defines no password field.
    public static let openSubsonic = ServerMediaSharingFeatures(
        supportsDescription: true,
        supportsExpiration: true,
        supportsMultipleItems: true,
        supportsPasswordProtection: false
    )
}

public enum ServerMediaSharingAvailability: Equatable, Sendable {
    case available(ServerMediaSharingFeatures)
    case unsupported
    case permissionDenied
}

public enum ServerMediaSharingError: Error, Equatable, LocalizedError, Sendable {
    case unsupported
    case permissionDenied
    case invalidTarget
    case invalidExpiration
    case unsafePublicURL
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return PMString("serverShare.error.unsupported")
        case .permissionDenied:
            return PMString("serverShare.error.permissionDenied")
        case .invalidTarget:
            return PMString("serverShare.error.invalidTarget")
        case .invalidExpiration:
            return PMString("serverShare.error.invalidExpiration")
        case .unsafePublicURL:
            return PMString("serverShare.error.unsafeURL")
        case .malformedResponse:
            return PMString("serverShare.error.malformedResponse")
        }
    }
}

/// Converts library selections to the only IDs safe to send to OpenSubsonic.
/// Album, artist and playlist IDs inside Primuse are local identities, so every
/// aggregate is represented by its member songs' connector-owned IDs instead.
public enum ServerMediaShareTargetPolicy {
    public static func supports(_ sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .subsonic, .navidrome, .airsonic, .gonic:
            return true
        default:
            return false
        }
    }

    public static func makeTarget(
        kind: ServerMediaShareSelectionKind,
        title: String,
        songs: [Song],
        source: MusicSource
    ) throws -> ServerMediaShareTarget {
        guard supports(source.type), !songs.isEmpty else {
            throw ServerMediaSharingError.invalidTarget
        }

        var seenItemIDs = Set<String>()
        var itemIDs: [String] = []
        itemIDs.reserveCapacity(songs.count)
        for song in songs {
            guard song.sourceID == source.id,
                  let itemID = songID(
                    fromConnectorPath: song.filePath,
                    sourceType: source.type
                  ) else {
                throw ServerMediaSharingError.invalidTarget
            }
            if seenItemIDs.insert(itemID).inserted {
                itemIDs.append(itemID)
            }
        }
        guard !itemIDs.isEmpty else { throw ServerMediaSharingError.invalidTarget }

        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerMediaShareTarget(
            sourceID: source.id,
            kind: kind,
            title: cleanedTitle,
            itemIDs: itemIDs
        )
    }

    public static func songID(
        fromConnectorPath filePath: String,
        sourceType: MusicSourceType
    ) -> String? {
        guard supports(sourceType), filePath.hasPrefix("/songs/") else { return nil }
        let fileName = String(filePath.dropFirst("/songs/".count))
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.hasPrefix("."),
              !fileName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }

        let itemID = (fileName as NSString).deletingPathExtension
        guard !itemID.isEmpty, itemID != ".", itemID != ".." else { return nil }
        return itemID
    }
}

/// The relay receives media bytes only. A source URL, connector credential,
/// signed download URL, or local path is never part of its request model.
public enum MediaRelaySourcePolicy {
    public static func supports(song: Song, sourceType: MusicSourceType) -> Bool {
        guard song.fileSize > 0,
              song.cueSheetPath?.isEmpty != false,
              !song.isStreamDescriptor,
              sourceType != .appleMusic,
              !sourceType.isAwaitingPublicAPI else {
            return false
        }
        return true
    }

    public static func suggestedFileName(for song: Song) -> String {
        let cleanedTitle = song.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "/" || scalar == "\\" || scalar == ":" {
                    return "_"
                }
                return Character(String(scalar))
            }
        var title = String(cleanedTitle)
        if title.isEmpty || title == "." || title == ".." {
            title = "Primuse Media"
        }
        title = String(title.prefix(160))
        return "\(title).\(song.fileFormat.rawValue)"
    }

    public static func contentType(for format: AudioFormat) -> String {
        switch format {
        case .mp3: return "audio/mpeg"
        case .aac: return "audio/aac"
        case .m4a, .mp4, .alac: return "audio/mp4"
        case .m4v: return "video/x-m4v"
        case .mov: return "video/quicktime"
        case .flac: return "audio/flac"
        case .wav: return "audio/wav"
        case .aiff, .aif: return "audio/aiff"
        case .au: return "audio/basic"
        case .caf: return "audio/x-caf"
        case .ape: return "audio/ape"
        case .dsf: return "audio/dsf"
        case .dff: return "audio/dff"
        case .ogg: return "audio/ogg"
        case .opus: return "audio/opus"
        case .wma: return "audio/x-ms-wma"
        case .wv: return "audio/wavpack"
        case .dts: return "audio/vnd.dts"
        case .ac3: return "audio/ac3"
        case .eac3: return "audio/eac3"
        case .mlp: return "audio/vnd.dolby.mlp"
        case .truehd: return "audio/true-hd"
        case .amr: return "audio/amr"
        case .atrac: return "audio/atrac"
        case .tak: return "audio/x-tak"
        case .tta: return "audio/x-tta"
        case .mpc: return "audio/musepack"
        case .shn: return "audio/x-shorten"
        case .speex: return "audio/speex"
        case .qoa: return "audio/qoa"
        }
    }
}

public enum PublicShareURLPolicy {
    public static func validatePublicHost(_ rawHost: String) throws {
        var host = rawHost.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty,
              !host.contains("%"),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".lan"),
              !host.hasSuffix(".internal"),
              !host.hasSuffix(".home.arpa") else {
            throw ServerMediaSharingError.unsafePublicURL
        }

        #if canImport(Darwin)
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            guard isPublicIPv4(value) else {
                throw ServerMediaSharingError.unsafePublicURL
            }
            return
        }

        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            guard isPublicIPv6(bytes) else {
                throw ServerMediaSharingError.unsafePublicURL
            }
            return
        }
        #endif

        // Reject single-label intranet names and alternate numeric forms such
        // as 2130706433, 0177.0.0.1, or 0x7f000001.
        if !host.contains(".") || isAlternateNumericHost(host) {
            throw ServerMediaSharingError.unsafePublicURL
        }
    }

    private static func isAlternateNumericHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            if label.hasPrefix("0x") {
                let digits = label.dropFirst(2)
                return !digits.isEmpty && digits.unicodeScalars.allSatisfy {
                    CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                }
            }
            return !label.isEmpty && label.unicodeScalars.allSatisfy {
                CharacterSet.decimalDigits.contains($0)
            }
        }
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)
        let third = UInt8((value >> 8) & 0xff)
        switch first {
        case 0, 10, 127:
            return false
        case 100:
            return !(64...127).contains(second)
        case 169:
            return second != 254
        case 172:
            return !(16...31).contains(second)
        case 192:
            if second == 168 || second == 0 || (second == 88 && third == 99) {
                return false
            }
            return true
        case 198:
            return !(18...19).contains(second) && !(second == 51 && third == 100)
        case 203:
            return !(second == 0 && third == 113)
        case 224...255:
            return false
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false
        }
        if bytes[0...9].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            let value = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isPublicIPv4(value)
        }
        return true
    }
}

public struct ServerMediaShareRequest: Equatable, Sendable {
    public let itemIDs: [String]
    public let description: String?
    public let expiresAt: Date?

    public init(
        itemIDs: [String],
        description: String? = nil,
        expiresAt: Date? = nil
    ) throws {
        var seenItemIDs = Set<String>()
        var normalizedItemIDs: [String] = []
        normalizedItemIDs.reserveCapacity(itemIDs.count)
        for itemID in itemIDs {
            guard !itemID.isEmpty,
                  !itemID.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw ServerMediaSharingError.invalidTarget
            }
            if seenItemIDs.insert(itemID).inserted {
                normalizedItemIDs.append(itemID)
            }
        }
        guard !normalizedItemIDs.isEmpty else {
            throw ServerMediaSharingError.invalidTarget
        }

        let cleanedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.itemIDs = normalizedItemIDs
        self.description = cleanedDescription?.isEmpty == false ? cleanedDescription : nil
        self.expiresAt = expiresAt
    }
}

public enum OpenSubsonicMediaShareCodec {
    private static let int64ExclusiveUpperBound = 9_223_372_036_854_775_808.0

    public static func epochMilliseconds(from date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= -int64ExclusiveUpperBound,
              milliseconds < int64ExclusiveUpperBound else {
            throw ServerMediaSharingError.invalidExpiration
        }
        return Int64(milliseconds.rounded(.towardZero))
    }

    public static func queryItems(
        for request: ServerMediaShareRequest
    ) throws -> [URLQueryItem] {
        var items = request.itemIDs.map { URLQueryItem(name: "id", value: $0) }
        if let description = request.description {
            items.append(URLQueryItem(name: "description", value: description))
        }
        if let expiresAt = request.expiresAt {
            items.append(URLQueryItem(
                name: "expires",
                value: String(try epochMilliseconds(from: expiresAt))
            ))
        }
        return items
    }

    public static func decodeResponse(_ data: Data) throws -> OpenSubsonicMediaShareResponse {
        let normalized: Data
        do {
            normalized = try SubsonicResponseCompatibility.normalizedJSONData(data)
        } catch {
            throw ServerMediaSharingError.malformedResponse
        }
        do {
            return try JSONDecoder().decode(ResponseEnvelope.self, from: normalized).response
        } catch {
            if let sharingError = mediaSharingError(from: error) {
                throw sharingError
            }
            throw ServerMediaSharingError.malformedResponse
        }
    }

    /// `JSONDecoder` may wrap errors thrown by a nested `Decodable` value in a
    /// `DecodingError.Context`. Recover the domain error so callers can keep a
    /// security rejection distinct from an ordinary malformed response.
    public static func mediaSharingError(
        from error: Error
    ) -> ServerMediaSharingError? {
        if let sharingError = error as? ServerMediaSharingError {
            return sharingError
        }
        guard let decodingError = error as? DecodingError else { return nil }
        let underlyingError: Error?
        switch decodingError {
        case .dataCorrupted(let context):
            underlyingError = context.underlyingError
        case .keyNotFound(_, let context):
            underlyingError = context.underlyingError
        case .typeMismatch(_, let context):
            underlyingError = context.underlyingError
        case .valueNotFound(_, let context):
            underlyingError = context.underlyingError
        @unknown default:
            underlyingError = nil
        }
        return underlyingError.flatMap(mediaSharingError(from:))
    }

    private struct ResponseEnvelope: Decodable {
        let response: OpenSubsonicMediaShareResponse

        enum CodingKeys: String, CodingKey {
            case response = "subsonic-response"
        }
    }
}

public struct OpenSubsonicMediaShareResponse: Decodable, Sendable {
    public let status: String
    public let error: OpenSubsonicMediaShareAPIError?
    public let shares: OpenSubsonicMediaShareList?
}

public struct OpenSubsonicMediaShareAPIError: Decodable, Equatable, Sendable {
    public let code: Int
    public let message: String?
}

public struct OpenSubsonicMediaShareList: Decodable, Equatable, Sendable {
    public let values: [ServerMediaShare]

    private enum CodingKeys: String, CodingKey {
        case share
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if !container.contains(.share)
            || (try? container.decodeNil(forKey: .share)) == true {
            self.values = []
            return
        }

        do {
            self.values = try container.decode([ServerMediaShare].self, forKey: .share)
            return
        } catch {
            if OpenSubsonicMediaShareCodec.mediaSharingError(from: error) != nil {
                throw error
            }
        }

        do {
            self.values = [try container.decode(ServerMediaShare.self, forKey: .share)]
        } catch {
            if OpenSubsonicMediaShareCodec.mediaSharingError(from: error) != nil {
                throw error
            }
            throw ServerMediaSharingError.malformedResponse
        }
    }
}

public struct ServerMediaShare: Decodable, Equatable, Hashable, Sendable {
    public let id: String
    /// The exact server-returned text. Share sheets use this rather than
    /// rebuilding a URL so a public IPv6 host, port and base path stay intact.
    public let publicURLString: String
    public let description: String?
    public let username: String?
    public let createdAt: Date?
    public let expiresAt: Date?
    public let lastVisitedAt: Date?
    public let visitCount: Int?

    public var publicURL: URL {
        // Initialization and decoding both pass through the same validator.
        URL(string: publicURLString)!
    }

    public init(
        id: String,
        publicURLString: String,
        description: String? = nil,
        username: String? = nil,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        lastVisitedAt: Date? = nil,
        visitCount: Int? = nil
    ) throws {
        guard !id.isEmpty else { throw ServerMediaSharingError.malformedResponse }
        try Self.validatePublicURL(publicURLString)
        self.id = id
        self.publicURLString = publicURLString
        self.description = description
        self.username = username
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case description
        case username
        case created
        case expires
        case lastVisited
        case visitCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(FlexibleString.self, forKey: .id).value
        let publicURLString = try container.decode(String.self, forKey: .url)
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        let username = try container.decodeIfPresent(String.self, forKey: .username)
        let created = try container.decodeIfPresent(String.self, forKey: .created)
        let expires = try container.decodeIfPresent(String.self, forKey: .expires)
        let lastVisited = try container.decodeIfPresent(String.self, forKey: .lastVisited)
        let visitCount = try container.decodeIfPresent(FlexibleInteger.self, forKey: .visitCount)?.value

        do {
            try self.init(
                id: id,
                publicURLString: publicURLString,
                description: description,
                username: username,
                createdAt: created.flatMap(Self.parseDate),
                expiresAt: expires.flatMap(Self.parseDate),
                lastVisitedAt: lastVisited.flatMap(Self.parseDate),
                visitCount: visitCount
            )
        } catch let sharingError as ServerMediaSharingError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.url],
                debugDescription: "Rejected invalid server public share data",
                underlyingError: sharingError
            ))
        }
    }

    public static func validatePublicURL(_ rawValue: String) throws {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              !rawValue.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.url != nil else {
            throw ServerMediaSharingError.unsafePublicURL
        }
        try PublicShareURLPolicy.validatePublicHost(host)

        let pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
        if pathComponents.count >= 2,
           pathComponents[pathComponents.count - 2] == "rest",
           ["stream", "stream.view", "download", "download.view"]
            .contains(pathComponents.last ?? "") {
            throw ServerMediaSharingError.unsafePublicURL
        }

        let queryNames = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        let alwaysSensitive: Set<String> = [
            "password", "authorization", "access_token", "refresh_token",
            "oauth_token", "api_key", "apikey", "auth_token", "signature",
            "sig", "sid", "_sid", "x-plex-token", "x-emby-token",
        ]
        let hasSignedCloudQuery = queryNames.contains(where: {
            $0.hasPrefix("x-amz-") || $0.hasPrefix("x-goog-")
        })
        let hasSubsonicPassword = queryNames.contains("p")
        let hasSubsonicTokenPair = queryNames.contains("t") && queryNames.contains("s")
        let hasSubsonicUserAuth = queryNames.contains("u")
            && (hasSubsonicPassword || hasSubsonicTokenPair)
        guard queryNames.isDisjoint(with: alwaysSensitive),
              !hasSubsonicPassword,
              !hasSubsonicTokenPair,
              !hasSubsonicUserAuth,
              !hasSignedCloudQuery else {
            throw ServerMediaSharingError.unsafePublicURL
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(Int64.self) {
            self.value = String(value)
        } else {
            throw ServerMediaSharingError.malformedResponse
        }
    }
}

private struct FlexibleInteger: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let value = try? container.decode(String.self),
                  let integer = Int(value) {
            self.value = integer
        } else {
            throw ServerMediaSharingError.malformedResponse
        }
    }
}
