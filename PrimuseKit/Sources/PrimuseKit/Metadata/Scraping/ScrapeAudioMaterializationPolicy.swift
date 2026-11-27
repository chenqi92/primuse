import Foundation

/// Prevents metadata scraping from materializing an entire remote audio file
/// merely to establish a search identity. Range-capable sources already feed
/// embedded tags through metadata backfill; formats that require a complete
/// local file should only download that file when the user actually plays or
/// explicitly caches it.
public enum ScrapeAudioMaterializationPolicy {
    public static func shouldResolvePlaybackURL(
        sourceSupportsRangeStreaming: Bool,
        formatRequiresCompleteLocalFile: Bool
    ) -> Bool {
        !(sourceSupportsRangeStreaming && formatRequiresCompleteLocalFile)
    }
}
