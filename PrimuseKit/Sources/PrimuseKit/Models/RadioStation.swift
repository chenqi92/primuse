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

/// The source-backed half of a radio artwork request. Keeping this mapping in
/// PrimuseKit prevents individual screens from quietly dropping the source
/// provenance that is required to resolve server-mirrored station logos.
public struct RadioStationArtworkRemoteRequest: Hashable, Sendable {
    public let coverReference: String
    public let songID: String
    public let sourceID: String?
    public let filePath: String?
    public let fileFormat: AudioFormat

    public init(
        coverReference: String,
        songID: String,
        sourceID: String?,
        filePath: String?,
        fileFormat: AudioFormat
    ) {
        self.coverReference = coverReference
        self.songID = songID
        self.sourceID = sourceID
        self.filePath = filePath
        self.fileFormat = fileFormat
    }

    /// A versioned request discriminator prevents a late fetch for an older
    /// reference from being reused after the same station receives a new logo.
    public var cacheDiscriminator: String {
        let material = [
            songID,
            coverReference,
            sourceID ?? "",
            filePath ?? "",
            fileFormat.rawValue,
        ].joined(separator: "\u{1F}")
        return "\(songID)#artwork-\(String(Self.stableHash(material), radix: 16))"
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

public enum RadioStationArtworkCandidate: Hashable, Sendable {
    case inline(Data)
    case cachedOrSource(RadioStationArtworkRemoteRequest)
}

public struct RadioStationArtworkResolutionIdentity: Hashable, Sendable {
    public let stationID: String
    public let candidates: [RadioStationArtworkCandidate]

    public init(stationID: String, candidates: [RadioStationArtworkCandidate]) {
        self.stationID = stationID
        self.candidates = candidates
    }
}

public struct RadioStationArtworkResolutionPlan: Hashable, Sendable {
    public let identity: RadioStationArtworkResolutionIdentity
    public let candidates: [RadioStationArtworkCandidate]

    public init(
        identity: RadioStationArtworkResolutionIdentity,
        candidates: [RadioStationArtworkCandidate]
    ) {
        self.identity = identity
        self.candidates = candidates
    }

    public var usesPlaceholderOnly: Bool { candidates.isEmpty }
}

/// Platform-neutral priority and fallback policy shared by every radio artwork
/// surface. Inline bytes are preferred, but a corrupt inline image must still
/// be allowed to fall through to the station's cached/source reference.
public enum RadioStationArtworkResolutionPolicy {
    public static func makePlan(for station: RadioStation) -> RadioStationArtworkResolutionPlan {
        var candidates: [RadioStationArtworkCandidate] = []
        if let data = station.logoData, !data.isEmpty {
            candidates.append(.inline(data))
        }
        if let reference = cleaned(station.logoFileName) {
            candidates.append(.cachedOrSource(RadioStationArtworkRemoteRequest(
                coverReference: reference,
                songID: station.playbackSong.id,
                sourceID: station.sourceID,
                filePath: station.sourcePlaybackPath ?? station.streamURL,
                fileFormat: station.streamFormat.audioFormat
            )))
        }
        return RadioStationArtworkResolutionPlan(
            identity: RadioStationArtworkResolutionIdentity(
                stationID: station.id,
                candidates: candidates
            ),
            candidates: candidates
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct RadioStationArtworkResolution<Value> {
    public let candidate: RadioStationArtworkCandidate
    public let value: Value

    public init(candidate: RadioStationArtworkCandidate, value: Value) {
        self.candidate = candidate
        self.value = value
    }
}

extension RadioStationArtworkResolution: Sendable where Value: Sendable {}

public enum RadioStationArtworkResolver {
    public static func resolve<Value>(
        plan: RadioStationArtworkResolutionPlan,
        isolation: isolated (any Actor)? = #isolation,
        using load: (RadioStationArtworkCandidate) async -> Value?
    ) async -> RadioStationArtworkResolution<Value>? {
        for candidate in plan.candidates {
            if Task.isCancelled { return nil }
            if let value = await load(candidate) {
                if Task.isCancelled { return nil }
                return RadioStationArtworkResolution(candidate: candidate, value: value)
            }
        }
        return nil
    }
}

public enum RadioStationArtworkResultPolicy {
    public static func shouldApply(
        completedIdentity: RadioStationArtworkResolutionIdentity,
        displayedIdentity: RadioStationArtworkResolutionIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && completedIdentity == displayedIdentity
    }
}

public enum RadioStationArtworkCacheRevisionPolicy {
    public static func shouldReloadAfterInvalidation(
        invalidatesAll: Bool,
        invalidatedTokens: [String],
        request: RadioStationArtworkRemoteRequest?
    ) -> Bool {
        if invalidatesAll { return request != nil }
        guard let request else { return false }
        let localTokens = Set([request.songID, request.coverReference])
        return invalidatedTokens.contains { localTokens.contains($0) }
    }

    public static func shouldReloadAfterCaching(
        cachedSongID: String?,
        request: RadioStationArtworkRemoteRequest?,
        hasResolvedImage: Bool
    ) -> Bool {
        guard let request else { return false }
        return ArtworkCacheReloadPolicy.shouldReload(
            cachedSongID: cachedSongID,
            displayedSongID: request.songID,
            hasResolvedImage: hasResolvedImage
        )
    }
}

public struct RadioStationArtworkGridLayout: Equatable, Sendable {
    public struct Measurement: Equatable, Sendable {
        public let columnCount: Int
        public let itemWidth: Double

        public init(columnCount: Int, itemWidth: Double) {
            self.columnCount = columnCount
            self.itemWidth = itemWidth
        }
    }

    public let minimumItemWidth: Double
    public let maximumItemWidth: Double
    public let spacing: Double
    public let horizontalPadding: Double

    public init(
        minimumItemWidth: Double = 150,
        maximumItemWidth: Double = 220,
        spacing: Double = 14,
        horizontalPadding: Double = 20
    ) {
        self.minimumItemWidth = max(minimumItemWidth, 1)
        self.maximumItemWidth = max(maximumItemWidth, self.minimumItemWidth)
        self.spacing = max(spacing, 0)
        self.horizontalPadding = max(horizontalPadding, 0)
    }

    public func measure(containerWidth: Double) -> Measurement {
        let availableWidth = max(containerWidth - (horizontalPadding * 2), minimumItemWidth)
        let fittedColumns = Int((availableWidth + spacing) / (minimumItemWidth + spacing))
        let columnCount = max(fittedColumns, 1)
        let distributedWidth = (
            availableWidth - (Double(columnCount - 1) * spacing)
        ) / Double(columnCount)
        return Measurement(
            columnCount: columnCount,
            itemWidth: min(max(distributedWidth, minimumItemWidth), maximumItemWidth)
        )
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
