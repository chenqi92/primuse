import Foundation

/// Decides whether a manual "next" command is allowed to start another
/// decode. A one-song, repeat-off queue has no successor; treating modulo 1
/// as an advance only downloads and restarts the same remote file.
public enum ManualQueueAdvancePolicy {
    public static func shouldAdvance(
        queueCount: Int,
        repeatMode: RepeatMode,
        shuffleEnabled: Bool,
        hasSuccessor: Bool
    ) -> Bool {
        guard queueCount > 0 else { return false }
        guard queueCount == 1, repeatMode == .off else { return true }
        return shuffleEnabled && hasSuccessor
    }
}

public enum QueueAdvanceContext: Equatable, Sendable {
    case userInitiated
    case sourceFailureRecovery
}

/// Adjacent copies of the same recording are normally hidden from a manual
/// "next" action. During source-failure recovery, however, an identical song
/// from another provider is the fallback and must remain eligible.
public enum QueueAdjacentDuplicatePolicy {
    public static func shouldSkipCandidate(
        queueCount: Int,
        currentTitle: String,
        currentArtist: String?,
        candidateTitle: String,
        candidateArtist: String?,
        context: QueueAdvanceContext
    ) -> Bool {
        guard context == .userInitiated, queueCount > 2 else { return false }
        return currentTitle == candidateTitle && currentArtist == candidateArtist
    }
}

/// A source-wide authentication or connection failure makes every immediately
/// following entry from that source unavailable. Those entries can be skipped
/// without attempting more requests, while the first different provider stays
/// eligible so a mixed-source queue can continue playing.
public enum SourceFailureAdvancePolicy {
    public static func shouldSkipCandidate(
        failedSourceID: String,
        candidateSourceID: String
    ) -> Bool {
        failedSourceID == candidateSourceID
    }
}
