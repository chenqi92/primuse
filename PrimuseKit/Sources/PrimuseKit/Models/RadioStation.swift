import Foundation

public enum PlaybackKind: String, Codable, Sendable, Hashable {
    case track
    case liveRadio
}

public struct PlaybackPresentationCapabilities: Equatable, Sendable {
    public let canSeek: Bool
    public let supportsQueue: Bool
    public let supportsLyrics: Bool
    public let supportsLibraryActions: Bool
    public let supportsMetadataActions: Bool
    public let supportsPlaybackRate: Bool
    public let supportsShuffleAndRepeat: Bool

    public static let track = PlaybackPresentationCapabilities(
        canSeek: true,
        supportsQueue: true,
        supportsLyrics: true,
        supportsLibraryActions: true,
        supportsMetadataActions: true,
        supportsPlaybackRate: true,
        supportsShuffleAndRepeat: true
    )

    public static let liveRadio = PlaybackPresentationCapabilities(
        canSeek: false,
        supportsQueue: false,
        supportsLyrics: false,
        supportsLibraryActions: false,
        supportsMetadataActions: false,
        supportsPlaybackRate: false,
        supportsShuffleAndRepeat: false
    )

    public static func capabilities(for kind: PlaybackKind) -> Self {
        switch kind {
        case .track: return .track
        case .liveRadio: return .liveRadio
        }
    }
}

public enum RadioStreamFormat: String, Codable, CaseIterable, Sendable, Hashable {
    case automatic
    case mp3
    case aac
    case flac
    case hls

    public var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .flac: return "FLAC"
        case .hls: return "HLS"
        }
    }

    public var audioFormat: AudioFormat {
        switch self {
        case .automatic, .mp3, .hls: return .mp3
        case .aac: return .aac
        case .flac: return .flac
        }
    }

    public static func inferred(from url: URL, mimeType: String? = nil) -> Self {
        let mime = mimeType?.lowercased() ?? ""
        let path = url.path.lowercased()
        let pathExtension = url.pathExtension.lowercased()
        if mime.contains("mpegurl") || mime.contains("x-mpegurl") || pathExtension == "m3u8" {
            return .hls
        }
        if mime.contains("flac") || pathExtension == "flac" || path.contains("flac") {
            return .flac
        }
        if mime.contains("aac") || mime.contains("aacp") || ["aac", "m4a"].contains(pathExtension)
            || path.contains("aac") {
            return .aac
        }
        if mime.contains("mpeg") || pathExtension == "mp3" || path.contains("mp3") {
            return .mp3
        }
        return .automatic
    }
}

public struct RadioStation: Codable, Identifiable, Hashable, Sendable {
    public static let playbackSourceID = "primuse.live-radio"

    public var id: String
    public var name: String
    public var streamURL: String
    public var logoData: Data?
    public var logoFileName: String?
    public var streamFormat: RadioStreamFormat
    public var bitRate: Int?
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastPlayedAt: Date?
    public var sortOrder: Int?
    public var isDeleted: Bool
    public var deletedAt: Date?
    /// Music-source provenance for a read-only server mirror. These fields are
    /// optional so snapshots created before server radio synchronization keep
    /// decoding through synthesized `Codable` defaults.
    public var sourceID: String?
    public var serverStationID: String?
    public var sourceName: String?
    /// Opaque source-owned playback path. When present, the app resolves a
    /// fresh authenticated URL through the source connector instead of
    /// persisting a credential-bearing URL in this value type.
    public var sourcePlaybackPath: String?
    public var homepageURL: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        streamURL: String,
        logoData: Data? = nil,
        logoFileName: String? = nil,
        streamFormat: RadioStreamFormat = .automatic,
        bitRate: Int? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        sortOrder: Int? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        sourceID: String? = nil,
        serverStationID: String? = nil,
        sourceName: String? = nil,
        sourcePlaybackPath: String? = nil,
        homepageURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.logoData = logoData
        self.logoFileName = logoFileName
        self.streamFormat = streamFormat
        self.bitRate = bitRate
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastPlayedAt = lastPlayedAt
        self.sortOrder = sortOrder
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.sourceID = sourceID
        self.serverStationID = serverStationID
        self.sourceName = sourceName
        self.sourcePlaybackPath = sourcePlaybackPath
        self.homepageURL = homepageURL
    }

    public var isServerMirror: Bool {
        sourceID?.isEmpty == false && serverStationID?.isEmpty == false
    }

    public var requiresSourceStreamResolution: Bool {
        isServerMirror && sourcePlaybackPath?.isEmpty == false
    }

    public var displayEndpoint: String {
        if let sourceName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceName.isEmpty {
            return sourceName
        }
        return streamURL
    }

    public var url: URL? {
        guard let url = URL(string: streamURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }

    public var playbackSong: Song {
        Song(
            id: "radio:\(id)",
            title: name,
            artistName: playbackSubtitle,
            duration: 0,
            fileFormat: streamFormat.audioFormat,
            filePath: sourcePlaybackPath ?? streamURL,
            sourceID: sourceID ?? Self.playbackSourceID,
            fileSize: 0,
            bitRate: bitRate,
            dateAdded: createdAt,
            coverArtFileName: logoFileName
        )
    }

    public var playbackSubtitle: String {
        var parts: [String] = []
        if streamFormat != .automatic { parts.append(streamFormat.displayName) }
        if let bitRate, bitRate > 0 { parts.append("\(bitRate / 1_000) kbps") }
        return parts.isEmpty ? "LIVE" : parts.joined(separator: " · ")
    }
}

public enum RadioStationOrdering {
    public static func sorted(_ stations: [RadioStation]) -> [RadioStation] {
        stations.sorted { lhs, rhs in
            switch (lhs.sortOrder, rhs.sortOrder) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                if lhs.lastPlayedAt != rhs.lastPlayedAt {
                    return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
                }
            default:
                break
            }

            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

public enum RadioStationValidation {
    public static let maximumLogoBytes = 750 * 1_024

    public static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url.absoluteString
    }

    public static func isValid(name: String, urlString: String) -> Bool {
        !normalizedName(name).isEmpty && normalizedURLString(urlString) != nil
    }

    /// Server-backed stations may intentionally omit a direct URL because an
    /// authenticated, route-aware URL is minted only when playback starts.
    public static func hasValidPlaybackReference(_ station: RadioStation) -> Bool {
        guard !normalizedName(station.name).isEmpty else { return false }
        if station.requiresSourceStreamResolution {
            return true
        }
        return normalizedURLString(station.streamURL) != nil
    }

    public static func hasConsistentServerIdentity(_ station: RadioStation) -> Bool {
        guard station.isServerMirror else { return true }
        guard let sourceID = station.sourceID,
              let serverStationID = station.serverStationID else { return false }
        return station.id == ServerRadioStationIdentity.stationID(
            sourceID: sourceID,
            serverStationID: serverStationID
        )
    }
}
