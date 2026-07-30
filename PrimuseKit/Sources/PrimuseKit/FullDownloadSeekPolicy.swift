/// Decides how a full-download playback path should react when a seekable
/// local file is not available yet.
///
/// A user scrub must leave the currently playing node untouched. Recovery is
/// different: the system has already stopped that node, so silently rejecting
/// the seek would make every subsequent play command a no-op.
public enum FullDownloadSeekDecision: Sendable, Equatable {
    case proceed
    case keepCurrentPlayback
    case restartCurrentSong
}

public enum FullDownloadSeekPolicy {
    public static func decision(
        hasSeekableFile: Bool,
        isInterruptionRecovery: Bool
    ) -> FullDownloadSeekDecision {
        if hasSeekableFile {
            return .proceed
        }
        return isInterruptionRecovery ? .restartCurrentSong : .keepCurrentPlayback
    }
}
