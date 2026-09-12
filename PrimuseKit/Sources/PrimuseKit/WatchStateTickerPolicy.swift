import Foundation

/// Decides whether the iPhone→Watch state ticker should keep polling.
///
/// The ticker exists to advance the lyric line and the elapsed-time anchor
/// while audio is moving. While playback is paused or idle neither changes on
/// its own, so the ticker suspends: the paused/idle snapshot is pushed once on
/// the transition into that state, and every other update (reachability
/// changes, queue edits, seeks, song changes, watch-state changes) is already
/// pushed by its own event. Nothing is lost, the process just stops waking up
/// twice a second for the rest of its life.
public enum WatchStateTickerPolicy {
    public static func shouldRunTicker(
        isPlaying: Bool,
        isLoading: Bool,
        hasCurrentSong: Bool
    ) -> Bool {
        isPlaying || isLoading
    }
}
