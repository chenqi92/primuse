import CryptoKit
import Foundation

/// A source's strongest truthful server-side listening-statistics capability.
public enum ServerListeningStatsCapability: String, Codable, Equatable, Sendable {
    /// The service has no reliable read API for authoritative listening data.
    case unavailable
    /// The service exposes per-track cumulative counters and an optional last-played date.
    case aggregate
    /// The service exposes individual play timestamps and can fall back to cumulative counters.
    case eventHistoryWithAggregateFallback
}

public extension MusicSourceType {
    var serverListeningStatsCapability: ServerListeningStatsCapability {
        switch self {
        case .subsonic, .navidrome, .airsonic, .gonic,
             .jellyfin, .emby:
            return .aggregate
        case .plex:
            return .eventHistoryWithAggregateFallback
        case .synology, .qnap, .ugreen, .fnos,
             .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3,
             .fnMusic, .daoliyu,
             .baiduPan, .aliyunDrive, .googleDrive, .oneDrive,
             .dropbox, .drime, .pan115, .pan123,
             .appleMusic, .local, .appleMusicLibrary:
            return .unavailable
        }
    }
}

public enum ServerListeningStatsTemporalDetail: String, Codable, Equatable, Sendable {
    /// Only all-time per-track counters are known.
    case aggregate
    /// Each play has a server-provided timestamp.
    case events
}

public enum ServerListeningStatsDurationAvailability: String, Codable, Equatable, Sendable {
    /// The source does not expose the amount of audio actually listened to.
    case unavailable
    /// Each event includes an authoritative listened duration.
    case actual
}

public struct ServerListeningTrackAggregate: Codable, Equatable, Sendable {
    public let remoteTrackID: String
    public let title: String
    public let artist: String?
    public let album: String?
    public let playCount: Int
    public let lastPlayedAt: Date?

    public init(
        remoteTrackID: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        playCount: Int,
        lastPlayedAt: Date? = nil
    ) {
        self.remoteTrackID = remoteTrackID
        self.title = title
        self.artist = artist
        self.album = album
        self.playCount = max(0, playCount)
        self.lastPlayedAt = lastPlayedAt
    }
}

public struct ServerListeningEvent: Codable, Equatable, Sendable {
    public let id: String
    public let remoteTrackID: String
    public let title: String
    public let artist: String?
    public let album: String?
    public let playedAt: Date
    public let listenedSeconds: TimeInterval?

    public init(
        id: String,
        remoteTrackID: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        playedAt: Date,
        listenedSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.remoteTrackID = remoteTrackID
        self.title = title
        self.artist = artist
        self.album = album
        self.playedAt = playedAt
        self.listenedSeconds = listenedSeconds.map { max(0, $0) }
    }
}

/// A fully collected, account-scoped response returned by one connector.
public struct ServerListeningStatsPayload: Codable, Equatable, Sendable {
    public let accountFingerprint: String
    public let temporalDetail: ServerListeningStatsTemporalDetail
    public let durationAvailability: ServerListeningStatsDurationAvailability
    public let tracks: [ServerListeningTrackAggregate]
    public let events: [ServerListeningEvent]

    public init(
        accountFingerprint: String,
        temporalDetail: ServerListeningStatsTemporalDetail,
        durationAvailability: ServerListeningStatsDurationAvailability = .unavailable,
        tracks: [ServerListeningTrackAggregate] = [],
        events: [ServerListeningEvent] = []
    ) {
        self.accountFingerprint = accountFingerprint
        self.temporalDetail = temporalDetail
        self.durationAvailability = durationAvailability
        self.tracks = tracks
        self.events = events
    }

    public var isStructurallyValid: Bool {
        guard !accountFingerprint.isEmpty else { return false }
        switch temporalDetail {
        case .aggregate:
            return events.isEmpty && durationAvailability == .unavailable
        case .events:
            guard tracks.isEmpty else { return false }
            if durationAvailability == .actual {
                return events.allSatisfy { $0.listenedSeconds != nil }
            }
            return events.allSatisfy { $0.listenedSeconds == nil }
        }
    }
}

/// A cacheable server snapshot. The configuration and account fingerprints prevent
/// records from being reused across edited sources or different server accounts.
public struct ServerListeningStatsSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sourceID + ":" + configurationFingerprint }

    public let sourceID: String
    public let sourceType: MusicSourceType
    public let configurationFingerprint: String
    public let fetchedAt: Date
    public let payload: ServerListeningStatsPayload

    public init(
        sourceID: String,
        sourceType: MusicSourceType,
        configurationFingerprint: String,
        fetchedAt: Date,
        payload: ServerListeningStatsPayload
    ) {
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.configurationFingerprint = configurationFingerprint
        self.fetchedAt = fetchedAt
        self.payload = payload
    }

    public func isValid(for source: MusicSource) -> Bool {
        sourceID == source.id
            && sourceType == source.type
            && configurationFingerprint == ServerListeningStatsFingerprint.configuration(for: source)
            && payload.isStructurallyValid
            && source.type.serverListeningStatsCapability != .unavailable
            && capabilityAcceptsPayload
    }

    private var capabilityAcceptsPayload: Bool {
        switch sourceType.serverListeningStatsCapability {
        case .unavailable:
            return false
        case .aggregate:
            return payload.temporalDetail == .aggregate
        case .eventHistoryWithAggregateFallback:
            return true
        }
    }
}

public enum ServerListeningStatsRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case year
    case all

    public var id: String { rawValue }

    public func startDate(relativeTo now: Date, calendar: Calendar = .current) -> Date? {
        guard self != .all else { return nil }
        let days: Int
        switch self {
        case .week: days = 7
        case .month: days = 30
        case .year: days = 365
        case .all: return nil
        }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }
}

public struct ServerListeningStatsRankedItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case track
        case artist
        case album
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let playCount: Int
}

public struct ServerListeningStatsDailyCount: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let playCount: Int
}

public struct ServerListeningStatsPresentation: Equatable, Sendable {
    public let temporalDetail: ServerListeningStatsTemporalDetail
    public let appliedRange: ServerListeningStatsRange
    public let totalPlays: Int
    public let uniqueTracks: Int
    public let activeDays: Int?
    public let lastPlayedAt: Date?
    public let totalListenedSeconds: TimeInterval?
    public let dailyCounts: [ServerListeningStatsDailyCount]
    public let topTracks: [ServerListeningStatsRankedItem]
    public let topArtists: [ServerListeningStatsRankedItem]
    public let topAlbums: [ServerListeningStatsRankedItem]
}

public enum ServerListeningStatsPresentationBuilder {
    public static func build(
        payload: ServerListeningStatsPayload,
        range: ServerListeningStatsRange,
        now: Date = Date(),
        calendar: Calendar = .current,
        rankingLimit: Int = 20
    ) -> ServerListeningStatsPresentation? {
        guard payload.isStructurallyValid else { return nil }
        switch payload.temporalDetail {
        case .aggregate:
            return buildAggregate(payload: payload, rankingLimit: rankingLimit)
        case .events:
            return buildEvents(
                payload: payload,
                range: range,
                now: now,
                calendar: calendar,
                rankingLimit: rankingLimit
            )
        }
    }

    private static func buildAggregate(
        payload: ServerListeningStatsPayload,
        rankingLimit: Int
    ) -> ServerListeningStatsPresentation {
        let playedTracks = payload.tracks.filter { $0.playCount > 0 }
        return ServerListeningStatsPresentation(
            temporalDetail: .aggregate,
            appliedRange: .all,
            totalPlays: playedTracks.reduce(0) { $0 + $1.playCount },
            uniqueTracks: playedTracks.count,
            activeDays: nil,
            lastPlayedAt: playedTracks.compactMap(\.lastPlayedAt).max(),
            totalListenedSeconds: nil,
            dailyCounts: [],
            topTracks: rankedTracks(playedTracks, limit: rankingLimit),
            topArtists: rankedAggregates(
                playedTracks,
                kind: .artist,
                value: { $0.artist },
                limit: rankingLimit
            ),
            topAlbums: rankedAggregates(
                playedTracks,
                kind: .album,
                value: { $0.album },
                limit: rankingLimit
            )
        )
    }

    private static func buildEvents(
        payload: ServerListeningStatsPayload,
        range: ServerListeningStatsRange,
        now: Date,
        calendar: Calendar,
        rankingLimit: Int
    ) -> ServerListeningStatsPresentation {
        let start = range.startDate(relativeTo: now, calendar: calendar)
        let events = payload.events.filter { event in
            event.playedAt <= now && (start == nil || event.playedAt >= start!)
        }
        let days = Dictionary(grouping: events) { calendar.startOfDay(for: $0.playedAt) }
        let dailyCounts = days.map {
            ServerListeningStatsDailyCount(date: $0.key, playCount: $0.value.count)
        }.sorted { $0.date < $1.date }

        return ServerListeningStatsPresentation(
            temporalDetail: .events,
            appliedRange: range,
            totalPlays: events.count,
            uniqueTracks: Set(events.map(\.remoteTrackID)).count,
            activeDays: days.count,
            lastPlayedAt: events.map(\.playedAt).max(),
            totalListenedSeconds: payload.durationAvailability == .actual
                ? events.compactMap(\.listenedSeconds).reduce(0, +)
                : nil,
            dailyCounts: dailyCounts,
            topTracks: rankedEvents(
                events,
                kind: .track,
                key: { $0.remoteTrackID },
                title: { $0.title },
                subtitle: { joinedSubtitle($0.artist, $0.album) },
                limit: rankingLimit
            ),
            topArtists: rankedEvents(
                events,
                kind: .artist,
                key: { normalizedValue($0.artist) },
                title: { normalizedValue($0.artist) },
                subtitle: { _ in nil },
                limit: rankingLimit
            ),
            topAlbums: rankedEvents(
                events,
                kind: .album,
                key: { normalizedValue($0.album) },
                title: { normalizedValue($0.album) },
                subtitle: { $0.artist },
                limit: rankingLimit
            )
        )
    }

    private static func rankedTracks(
        _ tracks: [ServerListeningTrackAggregate],
        limit: Int
    ) -> [ServerListeningStatsRankedItem] {
        tracks.map {
            ServerListeningStatsRankedItem(
                id: $0.remoteTrackID,
                kind: .track,
                title: $0.title,
                subtitle: joinedSubtitle($0.artist, $0.album),
                playCount: $0.playCount
            )
        }
        .sorted(by: rankSort)
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func rankedAggregates(
        _ tracks: [ServerListeningTrackAggregate],
        kind: ServerListeningStatsRankedItem.Kind,
        value: (ServerListeningTrackAggregate) -> String?,
        limit: Int
    ) -> [ServerListeningStatsRankedItem] {
        let groups = Dictionary(grouping: tracks) { normalizedValue(value($0)) }
        return groups.map { key, values in
            ServerListeningStatsRankedItem(
                id: kind.rawValue + ":" + key,
                kind: kind,
                title: key,
                subtitle: nil,
                playCount: values.reduce(0) { $0 + $1.playCount }
            )
        }
        .sorted(by: rankSort)
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func rankedEvents(
        _ events: [ServerListeningEvent],
        kind: ServerListeningStatsRankedItem.Kind,
        key: (ServerListeningEvent) -> String,
        title: (ServerListeningEvent) -> String,
        subtitle: (ServerListeningEvent) -> String?,
        limit: Int
    ) -> [ServerListeningStatsRankedItem] {
        let groups = Dictionary(grouping: events, by: key)
        return groups.compactMap { groupKey, values in
            guard let exemplar = values.sorted(by: eventIdentitySort).first else { return nil }
            return ServerListeningStatsRankedItem(
                id: kind.rawValue + ":" + groupKey,
                kind: kind,
                title: title(exemplar),
                subtitle: subtitle(exemplar),
                playCount: values.count
            )
        }
        .sorted(by: rankSort)
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func rankSort(
        _ lhs: ServerListeningStatsRankedItem,
        _ rhs: ServerListeningStatsRankedItem
    ) -> Bool {
        if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func eventIdentitySort(
        _ lhs: ServerListeningEvent,
        _ rhs: ServerListeningEvent
    ) -> Bool {
        if lhs.playedAt != rhs.playedAt { return lhs.playedAt < rhs.playedAt }
        return lhs.id < rhs.id
    }

    private static func joinedSubtitle(_ artist: String?, _ album: String?) -> String? {
        let values = [artist, album].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func normalizedValue(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }
}

public enum ServerListeningStatsFingerprint {
    public static func configuration(for source: MusicSource) -> String {
        let connectionJSON: String
        if let configuration = source.connectionConfiguration,
           let data = try? sortedEncoder.encode(configuration) {
            connectionJSON = String(decoding: data, as: UTF8.self)
        } else {
            connectionJSON = ""
        }
        return hash(components: [
            source.id,
            source.type.rawValue,
            normalized(source.host),
            source.port.map(String.init) ?? "",
            source.useSsl ? "1" : "0",
            normalized(source.username),
            normalized(source.basePath),
            source.authType.rawValue,
            connectionJSON,
            source.modifiedAt.timeIntervalSince1970.description,
        ])
    }

    public static func account(
        service: String,
        endpoint: String,
        accountIdentifier: String
    ) -> String {
        hash(components: [
            normalized(service),
            normalized(endpoint),
            normalized(accountIdentifier),
        ])
    }

    public static func hash(components: [String]) -> String {
        let canonical = components.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
