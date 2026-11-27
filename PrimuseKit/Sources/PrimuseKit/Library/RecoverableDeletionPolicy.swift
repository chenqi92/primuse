import Foundation

/// Keeps every recoverable-deletion surface aligned with the durable pruning
/// window used by playlists, music sources, and scraper configurations.
public enum RecoverableDeletionPolicy {
    public static let retentionDays = 30
    public static let retentionInterval: TimeInterval = TimeInterval(retentionDays * 24 * 60 * 60)

    public static func pruneThreshold(now: Date = Date()) -> Date {
        now.addingTimeInterval(-retentionInterval)
    }

    public static func daysRemaining(deletedAt: Date, now: Date = Date()) -> Int {
        let remaining = deletedAt
            .addingTimeInterval(retentionInterval)
            .timeIntervalSince(now)
        return max(0, Int(ceil(remaining / 86_400)))
    }
}
