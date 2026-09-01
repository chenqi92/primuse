import Foundation

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
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.url != nil else {
            throw ServerMediaSharingError.unsafePublicURL
        }

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
            "password", "authorization", "access_token", "api_key", "apikey",
        ]
        let hasSubsonicPassword = queryNames.contains("p")
        let hasSubsonicTokenPair = queryNames.contains("t") && queryNames.contains("s")
        let hasSubsonicUserAuth = queryNames.contains("u")
            && (hasSubsonicPassword || hasSubsonicTokenPair)
        guard queryNames.isDisjoint(with: alwaysSensitive),
              !hasSubsonicPassword,
              !hasSubsonicTokenPair,
              !hasSubsonicUserAuth else {
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
