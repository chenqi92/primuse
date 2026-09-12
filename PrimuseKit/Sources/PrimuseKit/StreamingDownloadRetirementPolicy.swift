import Foundation

/// Retiring a full-download preparation hands the retired song's streaming
/// session to a retirement task, which finalizes it once the download and its
/// PCM pump have unwound. A caller that also finalizes the same song would
/// finalize it before that termination, so it must skip it — and it must
/// never finalize the item it is about to play.
public enum StreamingDownloadRetirementPolicy {
    /// - Parameters:
    ///   - previousSongID: the selection being replaced, if any.
    ///   - newSongID: the selection being published, or `nil` when playback is
    ///     stopping or being suspended rather than replaced.
    ///   - retiredSongID: the song whose retirement task owns the finalize,
    ///     as returned by the retirement call.
    public static func shouldFinalizePreviousSession(
        previousSongID: String?,
        newSongID: String?,
        retiredSongID: String?
    ) -> Bool {
        guard let previousSongID else { return false }
        guard previousSongID != newSongID else { return false }
        return previousSongID != retiredSongID
    }
}
