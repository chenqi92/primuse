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

    /// Identity of the bytes a source exposes, independent of the route used
    /// to reach them. Adding or editing an alternate address (public endpoint,
    /// vendor remote) reaches the same account and the same content root, so
    /// it must not be mistaken for a credential rotation that invalidates
    /// trusted offline bytes.
    ///
    /// Deliberately excluded: host, port, TLS, remote-access mode and vendor
    /// identifier. Deliberately included: the content root, because a new path
    /// prefix really does change which files a song identifier resolves to.
    public static func credentialScope(for source: MusicSource) -> String {
        let components: [String] = [
            source.id,
            source.type.rawValue,
            source.cloudAccountID ?? "",
            source.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            source.shareName ?? "",
            source.exportPath ?? "",
            contentRoot(for: source),
        ]
        let digest = SHA256.hash(
            data: Data(components.joined(separator: "\u{1E}").utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The legacy `basePath` and an endpoint's `pathPrefix` are the same value
    /// viewed through two storage layouts. Reading it through
    /// `effectiveConnectionConfiguration` keeps the answer stable when a source
    /// is upgraded from legacy host fields to an explicit multi-route
    /// configuration by the very edit that adds the second address.
    private static func contentRoot(for source: MusicSource) -> String {
        guard source.type.supportsEndpointSpecificPath,
              let configuration = source.effectiveConnectionConfiguration else {
            return source.basePath ?? ""
        }
        let endpoint = configuration.localEndpoint ?? configuration.publicEndpoint
        return endpoint?.normalized.pathPrefix ?? ""
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
/// stable remote file follows the server's catalogue fields — a retag on the
/// server rarely changes size or mtime, so a changed value is itself the
/// signal — while lyrics, replay gain and local artwork stay intact. A real
/// content replacement adopts the new row. Explicit user edits win both ways.
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
        // Background enrichment only fills what the server leaves empty and
        // explicit edits are stamped, so an unstamped row's text is the
        // server's own and may follow it.
        let followsServerCatalog = existing.userMetadataEditedAt == nil
        // A placeholder title ("Unknown") is what the backfill replaces from
        // the file header; the server repeating it must not undo that.
        if followsServerCatalog,
           adoptsServerText(
               existing: existing.title,
               incoming: incoming.title,
               isUsable: { ServerCatalogMetadataInspectionPolicy.hasUsableTitle($0) }
           ) {
            refreshed.title = incoming.title
            if refreshed.title != existing.title { refreshed.titlePinyin = nil }
        }
        if followsServerCatalog,
           adoptsServerText(existing: existing.artistName, incoming: incoming.artistName) {
            refreshed.artistName = incoming.artistName
            refreshed.sourceArtistNames = incoming.sourceArtistNames
            if refreshed.artistName != existing.artistName { refreshed.artistPinyin = nil }
        }
        if followsServerCatalog,
           adoptsServerText(existing: existing.albumTitle, incoming: incoming.albumTitle) {
            refreshed.albumTitle = incoming.albumTitle
            if refreshed.albumTitle != existing.albumTitle { refreshed.albumPinyin = nil }
        }
        if followsServerCatalog,
           adoptsServerText(
               existing: existing.albumArtistName,
               incoming: incoming.albumArtistName
           ) {
            refreshed.albumArtistName = incoming.albumArtistName
        }
        if followsServerCatalog,
           adoptsServerText(existing: existing.genre, incoming: incoming.genre) {
            refreshed.genre = incoming.genre
        }
        refreshed.trackNumber = catalogNumber(
            existing: existing.trackNumber,
            incoming: incoming.trackNumber,
            followsServer: followsServerCatalog
        )
        refreshed.discNumber = catalogNumber(
            existing: existing.discNumber,
            incoming: incoming.discNumber,
            followsServer: followsServerCatalog
        )
        refreshed.year = catalogNumber(
            existing: existing.year,
            incoming: incoming.year,
            followsServer: followsServerCatalog
        )
        if refreshed.duration <= 0 { refreshed.duration = incoming.duration }
        if refreshed.fileSize <= 0 { refreshed.fileSize = incoming.fileSize }
        if refreshed.bitRate == nil { refreshed.bitRate = incoming.bitRate }
        if refreshed.sampleRate == nil { refreshed.sampleRate = incoming.sampleRate }
        if refreshed.bitDepth == nil { refreshed.bitDepth = incoming.bitDepth }
        if refreshed.revision == nil { refreshed.revision = incoming.revision }
        if refreshed.lastModified == nil { refreshed.lastModified = incoming.lastModified }
        // Account-scoped server statistics can change while the media object
        // itself remains byte-for-byte identical. Always adopt the latest
        // catalogue value instead of treating it as device enrichment.
        refreshed.serverPlayCount = incoming.serverPlayCount
        if !incoming.filePath.isEmpty { refreshed.filePath = incoming.filePath }
        if refreshed.coverArtFileName == nil {
            refreshed.coverArtFileName = incoming.coverArtFileName
        } else if followsServerCatalog,
                  let reference = incoming.coverArtFileName,
                  isServerArtworkReference(reference),
                  isServerArtworkReference(existing.coverArtFileName) {
            // A server reference names the server's current artwork. A local
            // scrape or pick is a bare cache file name and stays.
            refreshed.coverArtFileName = reference
        }
        return refreshed
    }

    /// Server references are paths or URLs; artwork cached on this device is
    /// referenced by a bare file name.
    public static func isServerArtworkReference(_ reference: String?) -> Bool {
        reference?.contains("/") == true
    }

    /// Missing or garbled text is always replaced; otherwise a usable server
    /// value that differs wins.
    private static func adoptsServerText(
        existing: String?,
        incoming: String?,
        isUsable: (String) -> Bool = { !MediaMetadataTextRepair.isSuspicious($0) }
    ) -> Bool {
        if existing?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing) {
            return true
        }
        guard let incoming,
              !incoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isUsable(incoming) else { return false }
        return incoming != existing
    }

    private static func catalogNumber(
        existing: Int?,
        incoming: Int?,
        followsServer: Bool
    ) -> Int? {
        guard let existing else { return incoming }
        guard followsServer, let incoming, incoming > 0 else { return existing }
        return incoming
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
        // 扫描按扩展名猜格式, 回填按文件签名修正格式 —— 两者对同一份字节给出
        // 不同答案是常态, 不是文件被换过。见 AudioFormat.describeSameBytes。
        let formatChanged = !AudioFormat.describeSameBytes(
            existing.fileFormat,
            incoming.fileFormat
        )
        return sizeChanged || modifiedChanged || revisionChanged
            || formatChanged || cueChanged
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

/// Which sources can be checked for server-side changes without behaving like
/// a scan.
///
/// The bar is a single read-only request that answers "did anything change?".
/// A source that can only answer by re-listing its catalogue is performing a
/// scan, however incrementally it reconciles afterwards, and must stay behind
/// an explicit user action.
public enum ServerCatalogAutoRefreshPolicy {
    /// Minimum spacing between two status probes for one source.
    public static let checkCooldown: TimeInterval = 15 * 60

    /// Subsonic-family servers expose `getScanStatus`: one request, a scan flag,
    /// an item count and a last-scan timestamp. Every member of the family is
    /// served by the same connector, so the capability is family-wide rather
    /// than Navidrome-only.
    public static func supportsStatusProbe(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily
    }

    /// `startScan` is a server mutation, so it stays opt-in per source. Servers
    /// that do not implement it, and non-admin accounts, answer with a
    /// capability result rather than an error, which the caller treats as
    /// "fall back to the read-only path".
    public static func supportsServerScanRequest(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily
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
