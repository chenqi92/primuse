import Foundation

/// The listening-stats CloudKit record carries the whole history as one
/// compressed blob, and the record is rebuilt synchronously whenever the sync
/// engine asks for a batch. Encoding it ahead of time — in the throttled flush
/// task, which already owns a multi-minute budget — keeps that rebuild cheap,
/// but only while the cached blob still describes the store it was made from.
///
/// The store carries a monotonic revision that is bumped on every mutation, so
/// freshness is an equality check and nothing else: a cache made at revision R
/// is usable exactly while the store is still at R. Anything else (a play
/// recorded meanwhile, a remote merge, a clear) makes the blob stale, and the
/// caller must fall back to encoding from live state. Correctness therefore
/// never depends on the cache being present or warm.
public enum ListeningStatsPayloadCache {
    /// Whether a payload encoded at `cachedRevision` may still be sent for a
    /// store currently at `currentRevision`.
    public static func isUsable(cachedRevision: Int, currentRevision: Int) -> Bool {
        cachedRevision == currentRevision
    }
}
