import Foundation

public enum SourceCatalogSnapshotPolicy {
    /// Compares authoritative snapshots without exposing pagination order.
    /// Duplicate IDs fail closed so malformed snapshots never become a no-op.
    public static func hasChanges(existing: [Song], candidate: [Song]) -> Bool {
        guard existing.count == candidate.count else { return true }

        var existingByID: [String: Song] = [:]
        existingByID.reserveCapacity(existing.count)
        for song in existing {
            guard existingByID.updateValue(song, forKey: song.id) == nil else {
                return true
            }
        }

        var candidateIDs = Set<String>()
        candidateIDs.reserveCapacity(candidate.count)
        for song in candidate {
            guard candidateIDs.insert(song.id).inserted,
                  existingByID[song.id] == song else {
                return true
            }
        }
        return false
    }
}

public enum ServerCatalogRefreshDecision: Sendable, Equatable {
    case deferWhileScanning
    case refresh
    case noChanges
}

public enum ServerCatalogRefreshPolicy {
    /// Decides whether a read-only server status warrants rebuilding the local
    /// catalogue. On first use, the source's persisted successful-scan time is
    /// the migration baseline, avoiding an unconditional upgrade-time scan.
    /// `itemCount` is only a stable total after Navidrome finishes scanning;
    /// while a scan is active the same field is a progress counter.
    public static func decision(
        serverIsScanning: Bool,
        lastAppliedServerScanAt: Date?,
        lastAppliedItemCount: Int64?,
        serverLastScanAt: Date?,
        serverItemCount: Int64?,
        localLastScannedAt: Date?,
        localSongCount: Int
    ) -> ServerCatalogRefreshDecision {
        guard !serverIsScanning else { return .deferWhileScanning }

        let baselineScanAt = lastAppliedServerScanAt ?? localLastScannedAt
        if let lastAppliedServerScanAt {
            guard let serverLastScanAt else { return .refresh }
            if abs(serverLastScanAt.timeIntervalSince(lastAppliedServerScanAt)) > 1 {
                return .refresh
            }
        } else if let serverLastScanAt {
            guard let localLastScannedAt else { return .refresh }
            if serverLastScanAt.timeIntervalSince(localLastScannedAt) > 1 {
                return .refresh
            }
        }

        if let serverItemCount {
            return serverItemCount != (lastAppliedItemCount ?? Int64(localSongCount))
                ? .refresh
                : .noChanges
        }
        return baselineScanAt == nil ? .refresh : .noChanges
    }
}

public enum AutomaticOfflineDownloadDeferralReason: Sendable, Equatable {
    case applicationInactive
    case networkUndetermined
    case networkUnavailable
    case expensiveNetwork
    case constrainedNetwork
    case lowPower
    case thermalPressure
    case insufficientDiskSpace
    case playbackBuffering
}

public enum AutomaticOfflineDownloadEligibility: Sendable, Equatable {
    case allowed
    case deferred(AutomaticOfflineDownloadDeferralReason)
}

public enum AutomaticOfflineDownloadPolicy {
    public static let minimumFreeDiskBytes: Int64 = 512 * 1_024 * 1_024
    public static let diskHeadroomBytes: Int64 = 256 * 1_024 * 1_024

    public static func eligibility(
        applicationIsActive: Bool,
        hasDeterminedNetwork: Bool,
        isReachable: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isLowPowerModeEnabled: Bool,
        hasSeriousThermalPressure: Bool,
        availableDiskBytes: Int64,
        expectedDownloadBytes: Int64,
        isPlaybackBuffering: Bool
    ) -> AutomaticOfflineDownloadEligibility {
        guard applicationIsActive else { return .deferred(.applicationInactive) }
        guard hasDeterminedNetwork else { return .deferred(.networkUndetermined) }
        guard isReachable else { return .deferred(.networkUnavailable) }
        guard !isExpensive else { return .deferred(.expensiveNetwork) }
        guard !isConstrained else { return .deferred(.constrainedNetwork) }
        guard !isLowPowerModeEnabled else { return .deferred(.lowPower) }
        guard !hasSeriousThermalPressure else { return .deferred(.thermalPressure) }
        let requiredDiskBytes = max(
            minimumFreeDiskBytes,
            max(expectedDownloadBytes, 0) + diskHeadroomBytes
        )
        guard availableDiskBytes >= requiredDiskBytes else {
            return .deferred(.insufficientDiskSpace)
        }
        guard !isPlaybackBuffering else { return .deferred(.playbackBuffering) }
        return .allowed
    }

    public static func requiredSongIDs(
        desiredSignatures: [String: String],
        completedSignatures: [String: String],
        missingSongIDs: Set<String>
    ) -> Set<String> {
        Set(desiredSignatures.compactMap { songID, signature in
            completedSignatures[songID] != signature || missingSongIDs.contains(songID)
                ? songID
                : nil
        })
    }

    /// An ordinary playback cache has no automatic provenance and may be
    /// adopted on first enable. A cache or partial transfer previously owned
    /// by this queue is reusable only for the exact same source/content
    /// signature, preventing account switches from adopting stale bytes.
    public static func canAdoptExistingFile(
        desiredSignature: String,
        completedSignature: String?,
        lastKnownSignature: String?
    ) -> Bool {
        guard let provenance = completedSignature ?? lastKnownSignature else {
            return true
        }
        return provenance == desiredSignature
    }

    public static func requiresContentRefresh(
        desiredSignature: String,
        completedSignature: String?,
        lastKnownSignature: String?
    ) -> Bool {
        guard let provenance = completedSignature ?? lastKnownSignature else {
            return false
        }
        return provenance != desiredSignature
    }
}
