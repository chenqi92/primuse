#if os(iOS)
import ActivityKit
import Foundation

public struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public let songID: String
        public let title: String
        public let artist: String
        public let lyric: String
        public let isPlaying: Bool

        public init(songID: String, title: String, artist: String, lyric: String, isPlaying: Bool) {
            self.songID = songID
            self.title = title
            self.artist = artist
            self.lyric = lyric
            self.isPlaying = isPlaying
        }
    }

    public let sessionID: UUID

    public init(sessionID: UUID = UUID()) {
        self.sessionID = sessionID
    }
}
#endif
