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
    public var isDeleted: Bool
    public var deletedAt: Date?

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
        isDeleted: Bool = false,
        deletedAt: Date? = nil
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
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
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
            filePath: streamURL,
            sourceID: Self.playbackSourceID,
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
}
