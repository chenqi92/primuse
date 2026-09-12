import Foundation

/// The account keeps a single `LibrarySnapshot` record, and every upload
/// replaces its library payload wholesale. That is fine for an explicit user
/// action ("push to Apple TV", "sync now"), but a background lifecycle upload
/// must never be the thing that empties it.
///
/// A freshly installed second device has iCloud sync on by default. CloudKit
/// delivers `MusicSource` and `Playlist` records long before the user scans
/// anything, which is already enough to write a valid `library-cache.json` with
/// zero songs. Sending that to the shared snapshot record wipes the catalogue
/// every other device — most visibly the Apple TV — bootstraps from, and the
/// device that owns the real library will not repair it until its own fingerprint
/// changes.
///
/// The first upload for an account is a different case: there is nothing to
/// destroy, and letting it through keeps the record (sources, radio stations,
/// credentials) in place for devices that never scan.
///
/// A device whose library is made only of local imports and the Apple Music
/// Library is a third case. Cloud-source filtering drops every one of its songs,
/// so its eligible count is permanently zero — refusing there would park the
/// account's snapshot (credentials, radio stations, sources, lyrics) forever
/// instead of protecting a catalogue that device never had.
public enum LibrarySnapshotUploadPolicy {
    /// Whether an automatic, lifecycle-triggered full-snapshot upload may
    /// proceed.
    ///
    /// - Parameters:
    ///   - eligibleSongCount: songs surviving cloud-source filtering in the
    ///     payload that is about to be uploaded.
    ///   - hasCloudEligibleSources: whether the payload's source list still
    ///     carries at least one cloud-sync-eligible source. `false` means the
    ///     zero count comes from the device's own local-only setup, not from a
    ///     library that has not been scanned yet.
    ///   - serverHasLibraryPayload: whether the account's existing snapshot
    ///     record already carries a library payload (`libraryGz` or `library`).
    /// - Returns: `false` only when a device that should have cloud-eligible
    ///   songs would overwrite a non-empty cloud snapshot with none.
    public static func automaticUploadAllowed(
        eligibleSongCount: Int,
        hasCloudEligibleSources: Bool,
        serverHasLibraryPayload: Bool
    ) -> Bool {
        guard eligibleSongCount <= 0 else { return true }
        guard hasCloudEligibleSources else { return true }
        return !serverHasLibraryPayload
    }
}
