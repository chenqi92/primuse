import ActivityKit
import Foundation

public struct PlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isPlaying: Bool
        public var elapsedTime: TimeInterval
        public var nextSongTitle: String?

        public init(isPlaying: Bool, elapsedTime: TimeInterval, nextSongTitle: String? = nil) {
            self.isPlaying = isPlaying
            self.elapsedTime = elapsedTime
            self.nextSongTitle = nextSongTitle
        }
    }

    public var songTitle: String
    public var artistName: String
    public var albumTitle: String
    public var duration: TimeInterval
    /// Filename of cover image stored in the App Group shared container.
    /// The widget extension loads this from the shared container at render time.
    public var coverImageName: String?

    public init(songTitle: String, artistName: String, albumTitle: String, duration: TimeInterval, coverImageName: String? = nil) {
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.duration = duration
        self.coverImageName = coverImageName
    }
}
