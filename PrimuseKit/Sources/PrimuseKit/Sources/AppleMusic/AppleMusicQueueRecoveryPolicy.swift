import Foundation

/// Recovery rules for MusicKit queue startup. `MPMusicPlayerControllerErrorDomain`
/// is intentionally treated as an opaque system-player failure because Apple does
/// not publish stable meanings for its numeric codes. A multi-item queue can still
/// contain an unresolved entry even when the selected song is playable. A single
/// item can also fail while the system player recovers, so retry it once after a
/// short delay. Network, authorization and subscription failures
/// stay on their original error path instead of being duplicated.
public enum AppleMusicQueueRecoveryPolicy {
    public static let musicPlayerErrorDomain = "MPMusicPlayerControllerErrorDomain"
    public static let retryDelay: Duration = .milliseconds(750)

    public static func shouldRetryWithStartingItemOnly(
        errorDomain: String,
        queueItemCount: Int
    ) -> Bool {
        errorDomain == musicPlayerErrorDomain && queueItemCount > 0
    }

    /// Error 2 is a known MusicKit quirk only when `play()` itself reports it.
    /// A failure from `prepareToPlay()` means the queue never became ready and
    /// must not be projected as successful playback.
    public static func shouldTreatAsStarted(
        errorDomain: String,
        errorCode: Int,
        failedWhilePlaying: Bool
    ) -> Bool {
        errorDomain == musicPlayerErrorDomain
            && errorCode == 2
            && failedWhilePlaying
    }

    /// Resume keeps the existing queue and position. Recheck ownership after
    /// each suspension so a pause or native transition cannot resume an old entry.
    @MainActor
    public static func resumePlayback(
        hasCurrentEntry: Bool,
        canContinue: () -> Bool,
        isPlaying: () -> Bool,
        play: () async throws -> Void,
        prepare: () async throws -> Void,
        restorePosition: () -> Void,
        onRetry: (any Error) -> Void,
        waitBeforeRetry: () async throws -> Void = { try await Task.sleep(for: retryDelay) }
    ) async throws {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard canContinue() else { throw CancellationError() }
        }
        try checkCurrent()
        do {
            try await play()
        } catch {
            try checkCurrent()
            if isPlaying() { return }
            guard hasCurrentEntry,
                  shouldRetryWithStartingItemOnly(
                    errorDomain: (error as NSError).domain,
                    queueItemCount: 1
                  ) else { throw error }
            onRetry(error)
            try await waitBeforeRetry()
            try checkCurrent()
            if isPlaying() { return }
            try await prepare()
            try checkCurrent()
            if isPlaying() { return }
            restorePosition()
            try await play()
        }
        try checkCurrent()
    }
}
