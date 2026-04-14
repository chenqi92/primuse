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
    public var coverArtData: Data? // small thumbnail < 100KB
    /// Filename of cover image stored in the App Group shared container (for Widget rendering)
    public var coverImageName: String?
    public var isPlaying: Bool
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var queueSongIDs: [String]

    public init(
        currentSongID: String? = nil,
        songTitle: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        coverArtData: Data? = nil,
        coverImageName: String? = nil,
        isPlaying: Bool = false,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        queueSongIDs: [String] = []
    ) {
        self.currentSongID = currentSongID
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.coverArtData = coverArtData
        self.coverImageName = coverImageName
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.queueSongIDs = queueSongIDs
    }

    public static func load() -> PlaybackState? {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = defaults.data(forKey: PrimuseConstants.playbackStateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PlaybackState.self, from: data)
    }

    public func save() {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              let data = try? JSONEncoder().encode(self) else {
            return
        }
        defaults.set(data, forKey: PrimuseConstants.playbackStateKey)
    }
}
