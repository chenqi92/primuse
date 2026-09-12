import Foundation

/// A scan result is admitted into the library unless the user tombstoned that
/// identity globally or excluded it on this device only. Both ledgers are keyed
/// by a canonical identity — the source's account identity when one exists, the
/// mount UUID otherwise — so re-authorising the same upstream account on a fresh
/// source UUID does not silently resurrect a deleted row.
///
/// The prefix comes from a precomputed `[sourceID: String]` map rather than a
/// per-song closure: an intermediate scan flush re-passes the whole accumulated
/// catalogue, and resolving the prefix per song per pass turned the admission
/// check into a linear source-table scan for every incoming row.
public enum LibrarySongAdmissionPolicy {
    /// `"<identity prefix>:<file path>"`, falling back to the raw source ID
    /// when the source has no account identity.
    public nonisolated static func identityKey(
        prefix: String?,
        sourceID: String,
        filePath: String
    ) -> String {
        "\(prefix ?? sourceID):\(filePath)"
    }

    /// Neither ledger can reject anything when both are empty, which is the
    /// steady state of a library that has never deleted a song. Callers use
    /// this to skip key construction entirely for a whole batch.
    public nonisolated static func hasAdmissionFilters(
        tombstones: Set<String>,
        deviceExclusions: Set<String>
    ) -> Bool {
        !tombstones.isEmpty || !deviceExclusions.isEmpty
    }

    /// One identity key answers all three membership questions.
    ///
    /// The raw `"<sourceID>:<filePath>"` shape is accepted for device-local
    /// exclusions on purpose: the ledger records the account-prefixed key, but a
    /// snapshot load runs before the account resolver is installed, so the same
    /// song computes the raw form on that side of the load-order window. It is
    /// only consulted when the prefixed key differs and already missed.
    public nonisolated static func isBlocked(
        sourceID: String,
        filePath: String,
        prefixes: [String: String],
        tombstones: Set<String>,
        deviceExclusions: Set<String>
    ) -> Bool {
        guard hasAdmissionFilters(tombstones: tombstones, deviceExclusions: deviceExclusions) else {
            return false
        }
        let prefix = prefixes[sourceID]
        let key = identityKey(prefix: prefix, sourceID: sourceID, filePath: filePath)
        if tombstones.contains(key) { return true }
        if deviceExclusions.contains(key) { return true }
        guard let prefix, prefix != sourceID else { return false }
        return deviceExclusions.contains(
            identityKey(prefix: nil, sourceID: sourceID, filePath: filePath)
        )
    }
}
