import CryptoKit
import Foundation

public enum MusicSourceScopeFingerprint {
    /// Canonical account and endpoint identity shared by scanning, server-scan
    /// coordination and durable offline provenance. Credentials are excluded;
    /// every route that can change the upstream byte namespace is included.
    public static func make(
        for source: MusicSource,
        directories: [String]? = nil,
        includeSourceID: Bool = false
    ) -> String {
        var components: [String] = []
        if includeSourceID { components.append(source.id) }
        components.append(contentsOf: [
            source.type.rawValue,
            source.cloudAccountID ?? "",
            source.username?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "",
            source.connectionConfiguration != nil && source.type.supportsEndpointSpecificPath
                ? ""
                : (source.basePath ?? ""),
            source.shareName ?? "",
            source.exportPath ?? "",
        ])
        if let configuration = source.connectionConfiguration {
            for endpoint in [configuration.localEndpoint, configuration.publicEndpoint] {
                let normalized = endpoint?.normalized
                components.append(normalized?.host.lowercased() ?? "")
                components.append(normalized?.port.description ?? "")
                components.append(normalized?.useSsl == true ? "tls" : "plain")
                components.append(normalized?.pathPrefix ?? "")
            }
            components.append(configuration.remoteAccessMode.rawValue)
            components.append(configuration.vendorIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } else {
            components.append(source.host?.lowercased() ?? "")
            components.append(source.port.map(String.init) ?? "")
            components.append(source.useSsl ? "tls" : "plain")
        }
        if let directories {
            components.append(directories.sorted().joined(separator: "\u{1F}"))
        }
        let digest = SHA256.hash(
            data: Data(components.joined(separator: "\u{1E}").utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

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

/// Stable identity for Synology File Station rows. Dedicated and generic
/// scanners must use the same value so an in-flight metadata result cannot be
/// applied after a same-path, same-size file was replaced.
public enum SynologyFileRevisionPolicy {
    public static func revision(size: Int64, modifiedDate: Date?) -> String? {
        guard let modifiedDate else { return nil }
        return "synology:\(size):\(Int64(modifiedDate.timeIntervalSince1970))"
    }
}

/// Reconciles a full-metadata server row with device-local enrichment. A
/// stable remote file refreshes only missing/suspicious server fields, keeping
/// lyrics, replay gain, pinyin and sidecar caches intact. A real content
/// replacement adopts the new row while preserving explicit user edits.
public enum ServerSongCatalogMergePolicy {
    public static func mergedSnapshot(
        existing: [Song],
        candidate: [Song]
    ) -> [Song] {
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return candidate.map { incoming in
            guard let existing = existingByID[incoming.id] else { return incoming }
            var merged = merged(existing: existing, incoming: incoming)
            merged.dateAdded = existing.dateAdded
            return merged
        }
    }

    public static func merged(existing: Song, incoming: Song) -> Song {
        guard !contentChanged(existing: existing, incoming: incoming) else {
            return SongUserMetadataPolicy.preservingUserEdits(
                from: existing,
                in: incoming
            )
        }
        var refreshed = existing
        let canRefreshCatalogText = existing.userMetadataEditedAt == nil
        if canRefreshCatalogText && (
            existing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || MediaMetadataTextRepair.isSuspicious(existing.title)
        ) {
            refreshed.title = incoming.title
        }
        if canRefreshCatalogText && (
            existing.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || MediaMetadataTextRepair.isSuspicious(existing.artistName)
        ) {
            refreshed.artistName = incoming.artistName
            refreshed.sourceArtistNames = incoming.sourceArtistNames
        }
        if canRefreshCatalogText && (
            existing.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || MediaMetadataTextRepair.isSuspicious(existing.albumTitle)
        ) {
            refreshed.albumTitle = incoming.albumTitle
        }
        if canRefreshCatalogText && (
            existing.albumArtistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                != false
                || MediaMetadataTextRepair.isSuspicious(existing.albumArtistName)
        ) {
            refreshed.albumArtistName = incoming.albumArtistName
        }
        if canRefreshCatalogText && (
            existing.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || MediaMetadataTextRepair.isSuspicious(existing.genre)
        ) {
            refreshed.genre = incoming.genre
        }
        if refreshed.trackNumber == nil { refreshed.trackNumber = incoming.trackNumber }
        if refreshed.discNumber == nil { refreshed.discNumber = incoming.discNumber }
        if refreshed.year == nil { refreshed.year = incoming.year }
        if refreshed.duration <= 0 { refreshed.duration = incoming.duration }
        if refreshed.fileSize <= 0 { refreshed.fileSize = incoming.fileSize }
        if refreshed.bitRate == nil { refreshed.bitRate = incoming.bitRate }
        if refreshed.sampleRate == nil { refreshed.sampleRate = incoming.sampleRate }
        if refreshed.bitDepth == nil { refreshed.bitDepth = incoming.bitDepth }
        if refreshed.revision == nil { refreshed.revision = incoming.revision }
        if refreshed.lastModified == nil { refreshed.lastModified = incoming.lastModified }
        if !incoming.filePath.isEmpty { refreshed.filePath = incoming.filePath }
        if refreshed.coverArtFileName == nil {
            refreshed.coverArtFileName = incoming.coverArtFileName
        }
        return refreshed
    }

    public static func contentChanged(existing: Song, incoming: Song) -> Bool {
        let sizeChanged = incoming.fileSize > 0
            && existing.fileSize > 0
            && incoming.fileSize != existing.fileSize
        let modifiedChanged: Bool = {
            guard let incomingDate = incoming.lastModified,
                  let existingDate = existing.lastModified else { return false }
            return incomingDate != existingDate
        }()
        let revisionChanged: Bool = {
            guard let incomingRevision = incoming.revision,
                  let existingRevision = existing.revision else { return false }
            return incomingRevision != existingRevision
        }()
        let cueChanged = existing.cueSheetPath != incoming.cueSheetPath
            || existing.cueStartTime != incoming.cueStartTime
            || existing.cueEndTime != incoming.cueEndTime
        return sizeChanged || modifiedChanged || revisionChanged
            || existing.fileFormat != incoming.fileFormat || cueChanged
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
    case playbackActive
    case playbackBuffering
}

public enum AutomaticOfflineDownloadEligibility: Sendable, Equatable {
    case allowed
    case deferred(AutomaticOfflineDownloadDeferralReason)
}

public enum AutomaticOfflineDownloadPolicy {
    public static let minimumFreeDiskBytes: Int64 = 512 * 1_024 * 1_024
    public static let diskHeadroomBytes: Int64 = 256 * 1_024 * 1_024

    public static func supportsSourceType(_ sourceType: MusicSourceType) -> Bool {
        sourceType != .appleMusic
    }

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
        isPlaybackActive: Bool = false,
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
        guard !isPlaybackActive else { return .deferred(.playbackActive) }
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
        lastKnownSignature: String?,
        provenanceIsTrusted: Bool = false
    ) -> Bool {
        guard let provenance = completedSignature ?? lastKnownSignature else {
            return provenanceIsTrusted
        }
        return provenance == desiredSignature
    }

    public static func retryDelay(
        attemptCount: Int,
        authenticationRequired: Bool
    ) -> TimeInterval {
        let exponent = min(max(attemptCount, 1) - 1, 7)
        let transferBackoff = min(30 * (1 << exponent), 3_600)
        return TimeInterval(authenticationRequired ? max(transferBackoff, 900) : transferBackoff)
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
