public enum LocalPlaybackResumeAction: Equatable, Sendable {
    case restartCurrentSong
    case recoverFromInterruption
    case resumePreparedAudio
}

/// A selected queue row is not proof that the local audio engine has decoded
/// and scheduled audio. Retrying after URL/authentication failure must rebuild
/// the pipeline instead of marking an empty player node as playing.
public enum LocalPlaybackResumePolicy {
    public static func action(
        isAtTrackEnd: Bool,
        needsRecovery: Bool,
        hasPreparedAudio: Bool
    ) -> LocalPlaybackResumeAction {
        if isAtTrackEnd {
            return .restartCurrentSong
        }
        if needsRecovery {
            return .recoverFromInterruption
        }
        return hasPreparedAudio ? .resumePreparedAudio : .restartCurrentSong
    }
}
