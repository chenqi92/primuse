import Foundation

public enum RepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

public struct PlaybackState: Codable, Sendable {
    public var currentSongID: String?
    public var songTitle: String?
    public var artistName: String?
    public var albumTitle: String?
    public var fileFormat: String?
    public var coverArtData: Data? // small thumbnail < 100KB
    /// Filename of cover image stored in the App Group shared container (for Widget rendering)
    public var coverImageName: String?
    public var isPlaying: Bool
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var queueSongIDs: [String]
    /// Optional for backward-compatible decoding of snapshots written by
    /// versions before Internet radio support.
    public var playbackKind: PlaybackKind?
    public var radioStationID: String?
    /// Optional for backward-compatible decoding of snapshots written before
    /// the interactive desktop controls exposed repeat state.
    public var repeatMode: RepeatMode?
    /// Whether the current song is in the "Liked" system playlist. Optional so
    /// snapshots written before the lock-screen like button still decode.
    /// The widget can only render the heart, never resolve it — the library
    /// lives in the app sandbox, so the app has to publish it here.
    public var isLiked: Bool?
    /// Time at which `currentTime` was sampled. Optional so snapshots from
    /// older app versions continue to decode.
    public var updatedAt: Date?

    public init(
        currentSongID: String? = nil,
        songTitle: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        fileFormat: String? = nil,
        coverArtData: Data? = nil,
        coverImageName: String? = nil,
        isPlaying: Bool = false,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        queueSongIDs: [String] = [],
        playbackKind: PlaybackKind? = nil,
        radioStationID: String? = nil,
        repeatMode: RepeatMode? = nil,
        isLiked: Bool? = nil,
        updatedAt: Date? = nil
    ) {
        self.currentSongID = currentSongID
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.fileFormat = fileFormat
        self.coverArtData = coverArtData
        self.coverImageName = coverImageName
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.queueSongIDs = queueSongIDs
        self.playbackKind = playbackKind
        self.radioStationID = radioStationID
        self.repeatMode = repeatMode
        self.isLiked = isLiked
        self.updatedAt = updatedAt
    }

    public var isLiveStream: Bool { playbackKind == .liveRadio }

    public static func load() -> PlaybackState? {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = defaults.data(forKey: PrimuseConstants.playbackStateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PlaybackState.self, from: data)
    }

    public func save() {
        var snapshot = self
        if snapshot.updatedAt == nil {
            snapshot.updatedAt = Date()
        }
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: PrimuseConstants.playbackStateKey)
    }

    public static func clear() {
        UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier)?.removeObject(forKey: PrimuseConstants.playbackStateKey)
    }
}
