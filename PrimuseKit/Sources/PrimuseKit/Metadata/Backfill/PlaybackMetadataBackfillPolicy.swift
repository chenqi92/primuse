import Foundation

/// Bounds the opportunistic tag read started by WebDAV playback. This path is
/// intentionally separate from the whole-library worker: one playback request
/// owns at most one in-flight file read, retries only transient failures, and
/// never spends retry budget when a track switch cancels the work.
public enum PlaybackMetadataBackfillPolicy {
    public static let maximumAttemptsPerPlayback = 3

    public static func shouldStart(
        sourceType: MusicSourceType,
        hasMissingMetadata: Bool,
        isCueTrack: Bool,
        isStreamDescriptor: Bool,
        isAlreadyReading: Bool,
        completedForCurrentFile: Bool,
        failedAttemptCount: Int
    ) -> Bool {
        (sourceType == .webdav || sourceType == .infiniCloud)
            && hasMissingMetadata
            && !isCueTrack
            && !isStreamDescriptor
            && !isAlreadyReading
            && !completedForCurrentFile
            && failedAttemptCount < maximumAttemptsPerPlayback
    }

    /// Playback retries are deliberately sparse so metadata traffic cannot
    /// starve the audio stream on a slow WebDAV server.
    public static func retryDelay(afterFailedAttempt failedAttemptCount: Int) -> TimeInterval? {
        switch failedAttemptCount {
        case 1: 2
        case 2: 8
        default: nil
        }
    }

    public static func shouldCountFailure(
        isCancellation: Bool,
        isTransient: Bool
    ) -> Bool {
        !isCancellation && isTransient
    }

    /// tvOS does not persist the richer per-field inspection markers owned by
    /// `MetadataBackfillService`, so it uses core catalogue fields as the
    /// initial signal and remembers a verified read for the current file.
    public static func hasMissingCoreMetadata(
        title: String,
        artistName: String?,
        albumTitle: String?,
        duration: TimeInterval
    ) -> Bool {
        duration <= 0
            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}
