import Foundation

public enum LegacyAudioCacheMigrationDecision: Equatable, Sendable {
    /// Nothing to do for this song right now, and nothing worth remembering.
    case skip
    /// The legacy file unambiguously belongs to this song and can be adopted.
    case move
    /// The legacy file cannot be attributed to this song. It stays on disk and
    /// the probe is remembered so the ambiguity is not re-measured per call.
    case rejectAndRemember
}

/// Pre-hash cache files are adopted only when exactly one song can own them and
/// the byte count matches the library's expectation. A rejection is a stable
/// fact about (source, legacy name) until the source scope or the song's
/// location changes, so it is remembered instead of rescanned on every cache
/// URL resolution.
public enum LegacyAudioCacheMigrationPolicy {
    /// Legacy adoption tolerates small sidecar/tag rewrites: 1 % of the
    /// expected size, never less than 4 KB.
    public static func sizeTolerance(expectedSize: Int64) -> Int64 {
        max(Int64(4 * 1024), expectedSize / 100)
    }

    public static func decision(
        destinationExists: Bool,
        legacyExists: Bool,
        matchCount: Int,
        legacyByteCount: Int64?,
        expectedSize: Int64,
        alreadyResolved: Bool
    ) -> LegacyAudioCacheMigrationDecision {
        if alreadyResolved { return .skip }
        if destinationExists { return .skip }
        if !legacyExists { return .skip }
        guard matchCount == 1 else { return .rejectAndRemember }
        guard expectedSize > 0, let legacyByteCount else { return .move }
        let tolerance = sizeTolerance(expectedSize: expectedSize)
        return abs(legacyByteCount - expectedSize) <= tolerance ? .move : .rejectAndRemember
    }
}
