import Foundation

public enum WordLyricsDiscoveryPreferences {
    public static let enabledKey = "playerExploresWordLyrics"
    public static let showsActivityKey = "playerShowsActivityStatus"
    public static let enabledByDefault = false
    public static let showsActivityByDefault = true
}

public enum WordLyricsDiscoveryPolicy {
    public static func shouldExplore(
        enabled: Bool,
        isPlaying: Bool,
        isSpokenWord: Bool,
        isPinned: Bool,
        lyrics: [LyricLine]
    ) -> Bool {
        enabled && isPlaying && !isSpokenWord && !isPinned
            && lyrics.first?.documentIsLocalOverride != true
            && LyricsTimingLevel(lines: lyrics) < .word
    }
}

/// Only completed searches enter the cooldown; switching songs must not consume a retry.
public struct WordLyricsDiscoveryAttempts: Sendable {
    private var completed: [String: Date] = [:]
    public static let cooldown: TimeInterval = 6 * 60 * 60

    public init() {}

    public func allows(_ songID: String, now: Date = Date()) -> Bool {
        completed[songID].map { now.timeIntervalSince($0) >= Self.cooldown } ?? true
    }

    public mutating func finish(_ songID: String, now: Date = Date()) {
        completed[songID] = now
        if completed.count > 2048 {
            completed = completed.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        }
    }
}
