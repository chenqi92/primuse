import Foundation

// Shared App Group snapshots powering the secondary home-screen widgets
// (lyrics / listening stats / music sources / year-in-review). The main app
// computes these and writes them; the WidgetKit extension only reads.
//
// All four mirror the PlaybackState.load()/save() pattern but go through a
// shared codable helper to cut boilerplate.

enum WidgetSharedStore {
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let defaults, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Widget settings (sync gate + refresh cadence)

public enum WidgetRefreshMode: String, Codable, Sendable, CaseIterable {
    case adaptive
    case minute
    case fiveMinutes
    case manual

    /// Timeline reload interval. `nil` = no scheduled refresh (manual only —
    /// the widget still updates whenever the app pushes + reloads timelines).
    public var interval: TimeInterval? {
        switch self {
        case .adaptive:    return 15 * 60
        case .minute:      return 60
        case .fiveMinutes: return 5 * 60
        case .manual:      return nil
        }
    }
}

public enum WidgetSettings {
    /// Defaults to `true` when never set, so widgets get data out of the box.
    public static func syncEnabled() -> Bool {
        guard let defaults = WidgetSharedStore.defaults,
              defaults.object(forKey: PrimuseConstants.widgetSyncEnabledKey) != nil
        else { return true }
        return defaults.bool(forKey: PrimuseConstants.widgetSyncEnabledKey)
    }

    public static func widgetEnabled(_ key: String) -> Bool {
        guard let defaults = WidgetSharedStore.defaults,
              defaults.object(forKey: key) != nil else {
            return true
        }
        return defaults.bool(forKey: key)
    }

    public static func sharedDataScope() -> String {
        WidgetSharedStore.defaults?.string(forKey: PrimuseConstants.widgetSharedDataScopeKey)
            ?? "titleArtistCoverProgressLyrics"
    }

    public static func clickableInteractionEnabled() -> Bool {
        guard let defaults = WidgetSharedStore.defaults,
              defaults.object(forKey: PrimuseConstants.widgetClickableInteractionKey) != nil else {
            return true
        }
        return defaults.bool(forKey: PrimuseConstants.widgetClickableInteractionKey)
    }

    public static func refreshMode() -> WidgetRefreshMode {
        guard let raw = WidgetSharedStore.defaults?.string(forKey: PrimuseConstants.widgetRefreshModeKey),
              let mode = WidgetRefreshMode(rawValue: raw)
        else { return .adaptive }
        return mode
    }

    /// Convenience for TimelineProvider.getTimeline — the next scheduled reload
    /// date for the current refresh mode, or `nil` for manual.
    public static func nextRefreshDate(from now: Date = Date()) -> Date? {
        guard let interval = refreshMode().interval else { return nil }
        return now.addingTimeInterval(interval)
    }
}

// MARK: - Lyrics

/// Trimmed lyric line for the widget — drops syllable/voice detail (the widget
/// only renders plain centered lines) to keep the App Group payload small.
public struct WidgetLyricLine: Codable, Sendable, Hashable {
    public var time: TimeInterval
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

public struct LyricsSnapshot: Codable, Sendable {
    public var songID: String
    public var title: String
    public var artist: String
    public var coverImageName: String?
    public var lines: [WidgetLyricLine]
    /// Index of the line that was current when this snapshot was written.
    public var anchorIndex: Int
    public var isPlaying: Bool
    public var updatedAt: Date

    public init(songID: String, title: String, artist: String, coverImageName: String?,
                lines: [WidgetLyricLine], anchorIndex: Int, isPlaying: Bool, updatedAt: Date = Date()) {
        self.songID = songID
        self.title = title
        self.artist = artist
        self.coverImageName = coverImageName
        self.lines = lines
        self.anchorIndex = anchorIndex
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
    }

    public static func load() -> LyricsSnapshot? {
        WidgetSharedStore.load(LyricsSnapshot.self, key: PrimuseConstants.lyricsSnapshotKey)
    }

    public func save() {
        WidgetSharedStore.save(self, key: PrimuseConstants.lyricsSnapshotKey)
    }

    public static func clear() {
        WidgetSharedStore.defaults?.removeObject(forKey: PrimuseConstants.lyricsSnapshotKey)
    }
}

// MARK: - Listening stats

public struct ListeningStatsSnapshot: Codable, Sendable {
    public var totalPlays: Int
    public var totalSeconds: TimeInterval
    /// Per-day play counts for the last 30 days, oldest → newest.
    public var dailyCounts: [Int]
    public var topSongTitle: String?
    public var topSongArtist: String?
    public var updatedAt: Date

    public init(totalPlays: Int, totalSeconds: TimeInterval, dailyCounts: [Int],
                topSongTitle: String?, topSongArtist: String?, updatedAt: Date = Date()) {
        self.totalPlays = totalPlays
        self.totalSeconds = totalSeconds
        self.dailyCounts = dailyCounts
        self.topSongTitle = topSongTitle
        self.topSongArtist = topSongArtist
        self.updatedAt = updatedAt
    }

    public var totalHours: Int { Int((totalSeconds / 3600).rounded()) }

    public static func load() -> ListeningStatsSnapshot? {
        WidgetSharedStore.load(ListeningStatsSnapshot.self, key: PrimuseConstants.listeningStatsKey)
    }

    public func save() {
        WidgetSharedStore.save(self, key: PrimuseConstants.listeningStatsKey)
    }

    public static func clear() {
        WidgetSharedStore.defaults?.removeObject(forKey: PrimuseConstants.listeningStatsKey)
    }
}

// MARK: - Music sources

public enum WidgetSourceStatus: String, Codable, Sendable {
    case online
    case scanning
    case attention
    case disabled
}

public struct WidgetSourceEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var iconName: String
    public var songCount: Int
    public var status: WidgetSourceStatus

    public init(id: String, name: String, iconName: String, songCount: Int, status: WidgetSourceStatus) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.songCount = songCount
        self.status = status
    }
}

public struct SourcesSnapshot: Codable, Sendable {
    public var totalIndexed: Int
    public var sources: [WidgetSourceEntry]
    public var updatedAt: Date

    public init(totalIndexed: Int, sources: [WidgetSourceEntry], updatedAt: Date = Date()) {
        self.totalIndexed = totalIndexed
        self.sources = sources
        self.updatedAt = updatedAt
    }

    public var sourceCount: Int { sources.count }

    public static func load() -> SourcesSnapshot? {
        WidgetSharedStore.load(SourcesSnapshot.self, key: PrimuseConstants.sourcesSnapshotKey)
    }

    public func save() {
        WidgetSharedStore.save(self, key: PrimuseConstants.sourcesSnapshotKey)
    }

    public static func clear() {
        WidgetSharedStore.defaults?.removeObject(forKey: PrimuseConstants.sourcesSnapshotKey)
    }
}

// MARK: - Year in review (Wrapped)

public struct WrappedSnapshot: Codable, Sendable {
    public var year: Int
    public var totalHours: Int
    public var topArtist: String?
    public var topSong: String?
    public var updatedAt: Date

    public init(year: Int, totalHours: Int, topArtist: String?, topSong: String?, updatedAt: Date = Date()) {
        self.year = year
        self.totalHours = totalHours
        self.topArtist = topArtist
        self.topSong = topSong
        self.updatedAt = updatedAt
    }

    public static func load() -> WrappedSnapshot? {
        WidgetSharedStore.load(WrappedSnapshot.self, key: PrimuseConstants.wrappedSnapshotKey)
    }

    public func save() {
        WidgetSharedStore.save(self, key: PrimuseConstants.wrappedSnapshotKey)
    }

    public static func clear() {
        WidgetSharedStore.defaults?.removeObject(forKey: PrimuseConstants.wrappedSnapshotKey)
    }
}
