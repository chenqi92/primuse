import Foundation

public enum SourceSyncMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case quick
    case deep
}

/// Device-local discovery state. Provider cursors are deliberately kept out of
/// MusicSource/CloudKit because they describe one device's committed snapshot.
public struct SourceSyncState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sourceID: String
    public var scopeFingerprint: String
    /// Provider account and endpoint identity without the selected roots. It
    /// permits root-selection changes to reuse stable IDs while fencing an
    /// account switch even when a provider happens to reuse the same item ID.
    public var identityScopeFingerprint: String?
    public var cursors: [String: String]
    public var index: [String: SourceSyncIndexedItem]
    public var pendingDirectories: [String]
    public var scanEpoch: Int64
    public var requiresDeepScan: Bool
    public var lastFullScanAt: Date?
    public var lastSuccessfulSyncAt: Date?
    /// Legacy-key aliases retained while a path-keyed library transitions to
    /// provider-stable identities. The map is scoped by `sourceID`, just like
    /// the index itself; provider-wide key namespacing is therefore unnecessary.
    public var identityAliases: [String: String]
    /// Stable identities for user-selected roots. `configuredPath` remains the
    /// scope input while `currentPath` can follow a provider-side rename.
    public var rootIdentities: [SourceSyncRootIdentity]
    /// Non-nil while a complete snapshot has observations that are not yet
    /// authoritative enough to delete. A later explicit foreground refresh
    /// must confirm the same absence before pruning.
    public var reconciliation: SourceSyncReconciliation?
    /// Consecutive complete-snapshot misses. Missing entries are deliberately
    /// retained on their first observation to protect against eventual
    /// consistency and identity-migration ambiguity.
    public var missingStableKeys: [String: Int]
    public var lastTelemetry: SourceSyncTelemetry?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceID: String,
        scopeFingerprint: String,
        identityScopeFingerprint: String? = nil,
        cursors: [String: String] = [:],
        index: [String: SourceSyncIndexedItem] = [:],
        pendingDirectories: [String] = [],
        scanEpoch: Int64 = 0,
        requiresDeepScan: Bool = false,
        lastFullScanAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        identityAliases: [String: String] = [:],
        rootIdentities: [SourceSyncRootIdentity] = [],
        reconciliation: SourceSyncReconciliation? = nil,
        missingStableKeys: [String: Int] = [:],
        lastTelemetry: SourceSyncTelemetry? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.scopeFingerprint = scopeFingerprint
        self.identityScopeFingerprint = identityScopeFingerprint
        self.cursors = cursors
        self.index = index
        self.pendingDirectories = pendingDirectories
        self.scanEpoch = scanEpoch
        self.requiresDeepScan = requiresDeepScan
        self.lastFullScanAt = lastFullScanAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.identityAliases = identityAliases
        self.rootIdentities = rootIdentities
        self.reconciliation = reconciliation
        self.missingStableKeys = missingStableKeys
        self.lastTelemetry = lastTelemetry
    }

    public func isUsable(sourceID: String, scopeFingerprint: String) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && self.sourceID == sourceID
            && self.scopeFingerprint == scopeFingerprint
            && !requiresDeepScan
    }

    public func matchesScope(sourceID: String, scopeFingerprint: String) -> Bool {
        self.sourceID == sourceID && self.scopeFingerprint == scopeFingerprint
    }

    public func matchesIdentityScope(
        sourceID: String,
        identityScopeFingerprint: String
    ) -> Bool {
        self.sourceID == sourceID
            && self.identityScopeFingerprint == identityScopeFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceID
        case scopeFingerprint
        case identityScopeFingerprint
        case cursors
        case index
        case pendingDirectories
        case scanEpoch
        case requiresDeepScan
        case lastFullScanAt
        case lastSuccessfulSyncAt
        case identityAliases
        case rootIdentities
        case reconciliation
        case missingStableKeys
        case lastTelemetry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        sourceID = try container.decode(String.self, forKey: .sourceID)
        scopeFingerprint = try container.decode(String.self, forKey: .scopeFingerprint)
        identityScopeFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .identityScopeFingerprint
        )
        cursors = try container.decodeIfPresent([String: String].self, forKey: .cursors) ?? [:]
        index = try container.decodeIfPresent(
            [String: SourceSyncIndexedItem].self,
            forKey: .index
        ) ?? [:]
        pendingDirectories = try container.decodeIfPresent(
            [String].self,
            forKey: .pendingDirectories
        ) ?? []
        scanEpoch = try container.decodeIfPresent(Int64.self, forKey: .scanEpoch) ?? 0
        requiresDeepScan = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresDeepScan
        ) ?? false
        lastFullScanAt = try container.decodeIfPresent(Date.self, forKey: .lastFullScanAt)
        lastSuccessfulSyncAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastSuccessfulSyncAt
        )
        identityAliases = try container.decodeIfPresent(
            [String: String].self,
            forKey: .identityAliases
        ) ?? [:]
        rootIdentities = try container.decodeIfPresent(
            [SourceSyncRootIdentity].self,
            forKey: .rootIdentities
        ) ?? []
        reconciliation = try container.decodeIfPresent(
            SourceSyncReconciliation.self,
            forKey: .reconciliation
        )
        missingStableKeys = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .missingStableKeys
        ) ?? [:]
        lastTelemetry = try container.decodeIfPresent(
            SourceSyncTelemetry.self,
            forKey: .lastTelemetry
        )
    }
}

public struct SourceSyncIndexedItem: Codable, Sendable, Equatable {
    public var stableKey: String
    public var path: String
    /// Provider-supplied user-facing name. `path` can be an opaque Drive item
    /// identifier and must never be used as a folder label.
    public var displayName: String?
    public var parentPath: String?
    public var isDirectory: Bool
    public var songIDs: [String]
    public var size: Int64
    public var modifiedDate: Date?
    public var revision: String?
    /// Deterministic fingerprint of the selected cover/lyrics/video/CUE
    /// sidecars. Sidecars are not songs, but their independent changes must
    /// still invalidate the owning audio entry during a snapshot diff.
    public var sidecarFingerprint: String?
    public var seenEpoch: Int64

    public init(
        stableKey: String,
        path: String,
        displayName: String? = nil,
        parentPath: String?,
        isDirectory: Bool,
        songIDs: [String] = [],
        size: Int64,
        modifiedDate: Date?,
        revision: String?,
        sidecarFingerprint: String? = nil,
        seenEpoch: Int64 = 0
    ) {
        self.stableKey = stableKey
        self.path = path
        self.displayName = displayName
        self.parentPath = parentPath
        self.isDirectory = isDirectory
        self.songIDs = songIDs
        self.size = size
        self.modifiedDate = modifiedDate
        self.revision = revision
        self.sidecarFingerprint = sidecarFingerprint
        self.seenEpoch = seenEpoch
    }
}

public struct SourceSyncRootIdentity: Codable, Sendable, Equatable, Hashable {
    public var configuredPath: String
    public var currentPath: String
    public var stableKey: String?

    public init(configuredPath: String, currentPath: String, stableKey: String?) {
        self.configuredPath = configuredPath
        self.currentPath = currentPath
        self.stableKey = stableKey
    }
}

public struct SourceSyncReconciliation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case baiduIdentityAndDeletionConfirmation
    }

    public var kind: Kind
    public var unresolvedStableKeys: [String]
    public var detectedAt: Date

    public init(kind: Kind, unresolvedStableKeys: [String], detectedAt: Date) {
        self.kind = kind
        self.unresolvedStableKeys = unresolvedStableKeys.sorted()
        self.detectedAt = detectedAt
    }
}

public struct SourceSyncTelemetry: Codable, Sendable, Equatable {
    public var requestCount: Int
    public var directoryCount: Int
    public var rateLimitRetryCount: Int
    public var elapsed: TimeInterval
    public var resumed: Bool
    public var budgetExhausted: Bool
    public var stopReason: BaiduSnapshotBudgetStopReason?

    public init(
        requestCount: Int = 0,
        directoryCount: Int = 0,
        rateLimitRetryCount: Int = 0,
        elapsed: TimeInterval = 0,
        resumed: Bool = false,
        budgetExhausted: Bool = false,
        stopReason: BaiduSnapshotBudgetStopReason? = nil
    ) {
        self.requestCount = requestCount
        self.directoryCount = directoryCount
        self.rateLimitRetryCount = rateLimitRetryCount
        self.elapsed = elapsed
        self.resumed = resumed
        self.budgetExhausted = budgetExhausted
        self.stopReason = stopReason
    }
}

/// Detects legacy snapshots that stored provider item IDs without the
/// corresponding user-facing names. Reusing those snapshots for an
/// incremental sync would keep the folder browser permanently unable to
/// reconstruct the provider hierarchy, so the next user-initiated scan must
/// perform a complete walk once.
public enum SourceSyncFolderTopologyPolicy {
    public static func requiresRebuild(
        sourceType: MusicSourceType,
        state: SourceSyncState
    ) -> Bool {
        guard usesOpaqueProviderItemIDs(sourceType), !state.index.isEmpty else {
            return false
        }
        return state.index.values.contains { $0.displayName == nil }
    }

    private static func usesOpaqueProviderItemIDs(_ sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .aliyunDrive, .googleDrive, .oneDrive, .drime, .pan115, .pan123:
            return true
        default:
            return false
        }
    }
}

/// Uncommitted progress for a generic directory walk. This lives in the scan
/// checkpoint rather than the committed sync state: a cancelled or partially
/// failed walk must never advance provider cursors or become authoritative for
/// deletion, but it can safely resume from the remaining directory queue.
public struct SourceScanResumeState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var pendingDirectories: [String]
    public var encounteredSongIDs: Set<String>
    public var index: [String: SourceSyncIndexedItem]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        pendingDirectories: [String],
        encounteredSongIDs: Set<String> = [],
        index: [String: SourceSyncIndexedItem] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.pendingDirectories = pendingDirectories
        self.encounteredSongIDs = encounteredSongIDs
        self.index = index
    }

    public var isUsable: Bool {
        schemaVersion == Self.currentSchemaVersion
    }
}

/// Pure commit policy used by ScanService and regression tests.
public enum SourceSyncCommitPolicy {
    public static func shouldAdvanceCursor(
        libraryPersistenceSucceeded: Bool,
        scanCompleted: Bool,
        hadPartialFailure: Bool
    ) -> Bool {
        libraryPersistenceSucceeded && scanCompleted && !hadPartialFailure
    }

    public static func shouldPruneUnseenEntries(
        scanCompleted: Bool,
        hadPartialFailure: Bool
    ) -> Bool {
        scanCompleted && !hadPartialFailure
    }
}

/// Energy-conscious cadence for provider-native change feeds. Directory-walk
/// sources deliberately do not use this policy because a background wake must
/// never turn into an unrequested NAS-wide traversal.
public enum SourcePeriodicSyncPolicy {
    public static let interval: TimeInterval = 6 * 60 * 60

    public static func nextSyncDate(
        for state: SourceSyncState,
        now: Date = Date()
    ) -> Date? {
        guard !state.requiresDeepScan, !state.cursors.isEmpty else { return nil }
        let baseline = state.lastSuccessfulSyncAt ?? state.lastFullScanAt ?? now
        return baseline.addingTimeInterval(interval)
    }

    public static func isDue(
        _ state: SourceSyncState,
        now: Date = Date()
    ) -> Bool {
        guard let next = nextSyncDate(for: state, now: now) else { return false }
        return next <= now
    }
}

// MARK: - Baidu snapshot synchronization

public enum BaiduSnapshotIdentity {
    public static let cursorKey = "baiduSnapshot"
    public static let cursorVersion = "fsid-sidecar-v1"

    public static func stableKey(fsID: Int64) -> String {
        "baidu:\(fsID)"
    }

    public static func fsID(from stableKey: String) -> Int64? {
        guard stableKey.hasPrefix("baidu:") else { return nil }
        return Int64(stableKey.dropFirst("baidu:".count))
    }

    public static func legacyPathKey(_ path: String) -> String {
        "path:\(path.lowercased())"
    }

}

public enum BaiduSnapshotPaginationError: Error, Sendable, Equatable {
    case invalidPageCount(Int)
    case offsetOverflow
}

public enum BaiduSnapshotPaginationPolicy {
    /// A directory is complete only after a successfully decoded short page.
    /// Full pages must advance by exactly the requested limit; malformed or
    /// oversized pages fail closed instead of becoming deletion evidence.
    public static func nextOffset(
        currentOffset: Int,
        decodedItemCount: Int,
        pageSize: Int
    ) throws -> Int? {
        guard currentOffset >= 0,
              pageSize > 0,
              decodedItemCount >= 0,
              decodedItemCount <= pageSize else {
            throw BaiduSnapshotPaginationError.invalidPageCount(decodedItemCount)
        }
        guard decodedItemCount == pageSize else { return nil }
        let (next, overflow) = currentOffset.addingReportingOverflow(pageSize)
        guard !overflow else { throw BaiduSnapshotPaginationError.offsetOverflow }
        return next
    }
}

public enum BaiduSnapshotRootPolicy {
    public static func normalizedRoots(_ roots: [String]) -> [String] {
        let normalized = Set(roots.map { value -> String in
            var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty { return "/" }
            if !path.hasPrefix("/") { path = "/" + path }
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        })
        let ordered = normalized.sorted {
            if $0.count == $1.count { return $0 < $1 }
            return $0.count < $1.count
        }
        var result: [String] = []
        for path in ordered {
            let nested = result.contains { parent in
                parent == "/" || path.hasPrefix(parent + "/")
            }
            if !nested { result.append(path) }
        }
        return result.sorted()
    }
}

public struct BaiduSnapshotDiffResult: Sendable, Equatable {
    public var reconciledIndex: [String: SourceSyncIndexedItem]
    public var changedParentPaths: Set<String>
    public var deletedStableKeys: Set<String>
    public var identityAliases: [String: String]
    public var missingStableKeys: [String: Int]
    public var reconciliation: SourceSyncReconciliation?

    public init(
        reconciledIndex: [String: SourceSyncIndexedItem],
        changedParentPaths: Set<String>,
        deletedStableKeys: Set<String>,
        identityAliases: [String: String],
        missingStableKeys: [String: Int],
        reconciliation: SourceSyncReconciliation?
    ) {
        self.reconciledIndex = reconciledIndex
        self.changedParentPaths = changedParentPaths
        self.deletedStableKeys = deletedStableKeys
        self.identityAliases = identityAliases
        self.missingStableKeys = missingStableKeys
        self.reconciliation = reconciliation
    }
}

public enum BaiduSnapshotDiffError: Error, Sendable, Equatable {
    case duplicateStableKey(String)
    case missingStableIdentity(String)
}

/// Pure migration and snapshot-diff policy. It deliberately requires two
/// complete observations before deleting an indexed song. The first absence is
/// persisted as reconciliation work, so an eventually-consistent or otherwise
/// incomplete-looking tree can never prune the library in one refresh.
public enum BaiduSnapshotDiffPolicy {
    public static let deletionConfirmationCount = 2

    public static func plan(
        previousIndex: [String: SourceSyncIndexedItem],
        currentItems: [SourceSyncIndexedItem],
        liveDirectories: Set<String>,
        identityAliases: [String: String] = [:],
        missingStableKeys: [String: Int] = [:],
        now: Date = Date()
    ) throws -> BaiduSnapshotDiffResult {
        var currentByKey: [String: SourceSyncIndexedItem] = [:]
        currentByKey.reserveCapacity(currentItems.count)
        for item in currentItems {
            guard BaiduSnapshotIdentity.fsID(from: item.stableKey) != nil else {
                throw BaiduSnapshotDiffError.missingStableIdentity(item.path)
            }
            guard currentByKey.updateValue(item, forKey: item.stableKey) == nil else {
                throw BaiduSnapshotDiffError.duplicateStableKey(item.stableKey)
            }
        }

        var reconciledIndex = previousIndex
        var changedParents: Set<String> = []
        var deletedKeys: Set<String> = []
        var aliases = identityAliases
        var nextMissing = missingStableKeys
        var claimedPreviousKeys: Set<String> = []

        let legacyEntries = previousIndex.filter { key, _ in
            key.hasPrefix("path:")
        }

        for currentValue in currentByKey.values.sorted(by: { $0.stableKey < $1.stableKey }) {
            let match = migrationMatch(
                for: currentValue,
                previousIndex: previousIndex,
                legacyEntries: legacyEntries,
                aliases: aliases,
                claimedPreviousKeys: claimedPreviousKeys
            )

            var current = currentValue
            if let match {
                claimedPreviousKeys.insert(match.key)
                current.songIDs = match.item.songIDs
                current.seenEpoch = max(current.seenEpoch, match.item.seenEpoch)
                nextMissing[match.key] = nil
                nextMissing[current.stableKey] = nil
                if match.key != current.stableKey {
                    aliases[match.key] = current.stableKey
                    reconciledIndex[match.key] = nil
                }
                if entryChanged(previous: match.item, current: current) {
                    insertLiveParent(match.item.parentPath, into: &changedParents, live: liveDirectories)
                    insertLiveParent(current.parentPath, into: &changedParents, live: liveDirectories)
                    if current.isDirectory, current.path != match.item.path {
                        insertLiveParent(current.path, into: &changedParents, live: liveDirectories)
                    }
                }
            } else {
                insertLiveParent(current.parentPath, into: &changedParents, live: liveDirectories)
                if current.isDirectory {
                    insertLiveParent(current.path, into: &changedParents, live: liveDirectories)
                }
            }
            reconciledIndex[current.stableKey] = current
        }

        var unresolved: Set<String> = []
        for (key, previous) in previousIndex.sorted(by: { $0.key < $1.key }) {
            if claimedPreviousKeys.contains(key) || currentByKey[key] != nil {
                continue
            }

            // Directory rows have no user-owned song identity. Their children
            // are independently keyed, so stale path-only topology can be
            // dropped immediately without risking playlists or history.
            if previous.isDirectory, previous.songIDs.isEmpty {
                reconciledIndex[key] = nil
                nextMissing[key] = nil
                continue
            }

            let observations = (missingStableKeys[key] ?? 0) + 1
            if observations >= deletionConfirmationCount {
                // Keep the row in the reconciliation baseline until
                // ConnectorScanner consumes its song IDs and removes it.
                deletedKeys.insert(key)
                nextMissing[key] = nil
                insertLiveParent(previous.parentPath, into: &changedParents, live: liveDirectories)
            } else {
                nextMissing[key] = observations
                unresolved.insert(key)
            }
        }

        let reconciliation = unresolved.isEmpty ? nil : SourceSyncReconciliation(
            kind: .baiduIdentityAndDeletionConfirmation,
            unresolvedStableKeys: Array(unresolved),
            detectedAt: now
        )
        return BaiduSnapshotDiffResult(
            reconciledIndex: reconciledIndex,
            changedParentPaths: changedParents,
            deletedStableKeys: deletedKeys,
            identityAliases: aliases,
            missingStableKeys: nextMissing,
            reconciliation: reconciliation
        )
    }

    /// Used by a user-selected deep scan that encounters a path-keyed legacy
    /// index before the first snapshot migration has completed.
    public static func migrationMatch(
        for current: SourceSyncIndexedItem,
        previousIndex: [String: SourceSyncIndexedItem],
        claimedPreviousKeys: Set<String> = []
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        migrationMatch(
            for: current,
            previousIndex: previousIndex,
            legacyEntries: previousIndex.filter { $0.key.hasPrefix("path:") },
            aliases: [:],
            claimedPreviousKeys: claimedPreviousKeys
        )
    }

    private static func migrationMatch(
        for current: SourceSyncIndexedItem,
        previousIndex: [String: SourceSyncIndexedItem],
        legacyEntries: [String: SourceSyncIndexedItem],
        aliases: [String: String],
        claimedPreviousKeys: Set<String>
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        if let direct = previousIndex[current.stableKey],
           !claimedPreviousKeys.contains(current.stableKey) {
            return (current.stableKey, direct)
        }

        let exactPathKey = BaiduSnapshotIdentity.legacyPathKey(current.path)
        if let exact = previousIndex[exactPathKey],
           exact.path == current.path,
           !claimedPreviousKeys.contains(exactPathKey) {
            return (exactPathKey, exact)
        }

        if let aliasedKey = aliases.first(where: { $0.value == current.stableKey })?.key,
           let aliased = previousIndex[aliasedKey],
           !claimedPreviousKeys.contains(aliasedKey) {
            return (aliasedKey, aliased)
        }

        guard !current.isDirectory,
              let revision = normalizedRevision(current.revision) else {
            return nil
        }
        let candidates = legacyEntries.filter { key, item in
            !claimedPreviousKeys.contains(key)
                && !item.isDirectory
                && normalizedRevision(item.revision) == revision
                && item.size == current.size
                && !item.songIDs.isEmpty
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }
        return (candidate.key, candidate.value)
    }

    private static func entryChanged(
        previous: SourceSyncIndexedItem,
        current: SourceSyncIndexedItem
    ) -> Bool {
        previous.path != current.path
            || previous.parentPath != current.parentPath
            || previous.displayName != current.displayName
            || previous.isDirectory != current.isDirectory
            || previous.size != current.size
            || previous.modifiedDate != current.modifiedDate
            || normalizedRevision(previous.revision) != normalizedRevision(current.revision)
            || previous.sidecarFingerprint != current.sidecarFingerprint
    }

    private static func normalizedRevision(_ revision: String?) -> String? {
        guard let value = revision?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }

    private static func insertLiveParent(
        _ path: String?,
        into result: inout Set<String>,
        live: Set<String>
    ) {
        guard let path, live.contains(path) else { return }
        result.insert(path)
    }
}

public enum BaiduSnapshotDirectoryReconciliationPolicy {
    /// A post-snapshot directory read may omit only keys whose deletion was
    /// already confirmed by the complete snapshot policy. Any other omission
    /// means the provider tree changed between phases (or the listing was not
    /// complete), so the caller must abort without committing state.
    public static func unconfirmedMissingKeys(
        expectedKeys: Set<String>,
        listedKeys: Set<String>,
        confirmedDeletedKeys: Set<String>
    ) -> Set<String> {
        expectedKeys.subtracting(listedKeys).subtracting(confirmedDeletedKeys)
    }
}

public struct BaiduSnapshotResumeState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    /// Long enough to survive termination and several user-driven budget
    /// slices. Deletions still require a second complete snapshot, so resuming
    /// a traversal never turns an old partial tree into an immediate prune.
    public static let maximumAge: TimeInterval = 24 * 60 * 60

    public var schemaVersion: Int
    public var baselineScanEpoch: Int64
    public var roots: [String]
    public var pendingDirectories: [String]
    public var visitedDirectories: Set<String>
    public var liveDirectories: Set<String>
    public var snapshot: [String: SourceSyncIndexedItem]
    public var createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        baselineScanEpoch: Int64,
        roots: [String],
        pendingDirectories: [String]? = nil,
        visitedDirectories: Set<String> = [],
        liveDirectories: Set<String>? = nil,
        snapshot: [String: SourceSyncIndexedItem] = [:],
        createdAt: Date = Date()
    ) {
        let normalizedRoots = BaiduSnapshotRootPolicy.normalizedRoots(roots)
        self.schemaVersion = schemaVersion
        self.baselineScanEpoch = baselineScanEpoch
        self.roots = normalizedRoots
        self.pendingDirectories = pendingDirectories ?? normalizedRoots
        self.visitedDirectories = visitedDirectories
        self.liveDirectories = liveDirectories ?? Set(normalizedRoots)
        self.snapshot = snapshot
        self.createdAt = createdAt
    }

    public func isUsable(
        baselineScanEpoch: Int64,
        roots: [String],
        now: Date = Date()
    ) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && self.baselineScanEpoch == baselineScanEpoch
            && self.roots == BaiduSnapshotRootPolicy.normalizedRoots(roots)
            && now.timeIntervalSince(createdAt) >= 0
            && now.timeIntervalSince(createdAt) <= Self.maximumAge
    }
}

public struct BaiduSnapshotRefreshBudget: Sendable, Equatable {
    public var maximumRequests: Int
    public var maximumDirectories: Int
    public var maximumDuration: TimeInterval

    public init(
        maximumRequests: Int = 320,
        maximumDirectories: Int = 160,
        maximumDuration: TimeInterval = 45
    ) {
        self.maximumRequests = maximumRequests
        self.maximumDirectories = maximumDirectories
        self.maximumDuration = maximumDuration
    }
}

public enum BaiduSnapshotBudgetStopReason: String, Codable, Sendable, Equatable {
    case requests
    case directories
    case duration
}

public enum BaiduSnapshotBudgetDecision: Sendable, Equatable {
    case allow
    case stop(BaiduSnapshotBudgetStopReason)
}

public enum BaiduSnapshotBudgetPolicy {
    public static func decision(
        budget: BaiduSnapshotRefreshBudget,
        requestCount: Int,
        directoryCount: Int,
        elapsed: TimeInterval,
        reservingRequest: Bool = false,
        reservingDirectory: Bool = false
    ) -> BaiduSnapshotBudgetDecision {
        if elapsed >= budget.maximumDuration { return .stop(.duration) }
        if requestCount + (reservingRequest ? 1 : 0) > budget.maximumRequests {
            return .stop(.requests)
        }
        if directoryCount + (reservingDirectory ? 1 : 0) > budget.maximumDirectories {
            return .stop(.directories)
        }
        return .allow
    }
}

public enum BaiduSnapshotExecutionContext: Sendable, Equatable {
    case userInitiatedForeground
    case foregroundResume
    case background
}

public enum BaiduSnapshotRefreshDeferralReason: Sendable, Equatable {
    case backgroundTraversalDisabled
    case networkUnavailable
    case expensiveNetwork
    case constrainedNetwork
    case lowPower
    case thermalPressure
}

public enum BaiduSnapshotRefreshEligibility: Sendable, Equatable {
    case allowed
    case deferred(BaiduSnapshotRefreshDeferralReason)
}

public enum BaiduSnapshotRefreshPolicy {
    public static func eligibility(
        context: BaiduSnapshotExecutionContext,
        hasDeterminedNetwork: Bool,
        isReachable: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isLowPowerModeEnabled: Bool,
        hasSeriousThermalPressure: Bool
    ) -> BaiduSnapshotRefreshEligibility {
        guard context != .background else {
            return .deferred(.backgroundTraversalDisabled)
        }
        if hasDeterminedNetwork, !isReachable {
            return .deferred(.networkUnavailable)
        }
        if context != .userInitiatedForeground, isExpensive {
            return .deferred(.expensiveNetwork)
        }
        if isConstrained { return .deferred(.constrainedNetwork) }
        if context == .foregroundResume, isLowPowerModeEnabled {
            return .deferred(.lowPower)
        }
        if hasSeriousThermalPressure { return .deferred(.thermalPressure) }
        return .allowed
    }
}

public enum BaiduRootRelocationDecision: Sendable, Equatable {
    case use(path: String, stableKey: String?)
    case requiresReselection
}

public enum BaiduRootRelocationPolicy {
    public static func decision(
        configuredPath: String,
        previousIdentity: SourceSyncRootIdentity?,
        listedStableKey: String?,
        metadataPathForPreviousStableKey: String?
    ) -> BaiduRootRelocationDecision {
        if configuredPath == "/" {
            return .use(path: "/", stableKey: nil)
        }
        if let stableKey = previousIdentity?.stableKey,
           let relocatedPath = metadataPathForPreviousStableKey,
           !relocatedPath.isEmpty {
            return .use(path: relocatedPath, stableKey: stableKey)
        }
        if let stableKey = previousIdentity?.stableKey {
            if listedStableKey == stableKey {
                return .use(path: configuredPath, stableKey: stableKey)
            }
            // A different object can appear at the old path after the selected
            // root is moved. Never silently retarget the source to that object.
            return .requiresReselection
        }
        if let listedStableKey {
            return .use(path: configuredPath, stableKey: listedStableKey)
        }
        return .requiresReselection
    }
}

public enum SourceSyncIdentityReusePolicy {
    public static func reusableIndex(
        from state: SourceSyncState?,
        sourceID: String,
        scopeFingerprint: String
    ) -> [String: SourceSyncIndexedItem] {
        guard let state, state.matchesScope(
            sourceID: sourceID,
            scopeFingerprint: scopeFingerprint
        ) else {
            return [:]
        }
        return state.index
    }
}

public enum SourceSidecarReferencePolicy {
    /// Reconciles the three observable states of a sidecar lookup: not
    /// inspected, present, and authoritatively absent. Only an absolute
    /// provider path in the directory just listed may be cleared; app-owned
    /// cache names and still-valid references in an old directory survive.
    public static func reconciledReference(
        existing: String?,
        incoming: String?,
        currentParentPath: String,
        authoritative: Bool,
        preserveExisting: Bool = false
    ) -> String? {
        if preserveExisting { return existing }
        if let incoming { return incoming }
        guard authoritative,
              let existing,
              existing.hasPrefix("/"),
              !existing.contains("://") else {
            return existing
        }
        let existingParent = (existing as NSString).deletingLastPathComponent
        return normalized(existingParent) == normalized(currentParentPath)
            ? nil
            : existing
    }

    private static func normalized(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

public enum SourceSongIdentityMaterialPolicy {
    /// Existing providers keep their historical path material. Opting into a
    /// provider ID is explicit per connector, so adding Baidu `fs_id` cannot
    /// silently re-key Google Drive, OneDrive, Dropbox, Aliyun, Drime, 115, or
    /// 123 songs.
    public static func itemIdentity(
        path: String,
        providerID: String?,
        usesStableProviderIdentity: Bool
    ) -> String {
        guard usesStableProviderIdentity,
              let providerID,
              !providerID.isEmpty else { return path }
        return "provider:\(providerID)"
    }
}

public enum SourceStableCacheTransitionDecision: Sendable, Equatable {
    case none
    case migrate
    case invalidate
}

public enum SourceStableCacheTransitionPolicy {
    /// Path-keyed audio caches can follow a stable provider item only when the
    /// provider gives strong evidence that the bytes are unchanged. Unknown or
    /// changed content is invalidated instead of risking playback of stale
    /// bytes after an in-place overwrite or move-and-replace operation.
    public static func decision(
        previousPath: String,
        currentPath: String,
        previousRevision: String?,
        currentRevision: String?,
        previousSize: Int64,
        currentSize: Int64
    ) -> SourceStableCacheTransitionDecision {
        guard previousPath != currentPath else { return .none }
        guard let previousRevision = normalized(previousRevision),
              let currentRevision = normalized(currentRevision),
              previousRevision == currentRevision else {
            return .invalidate
        }
        if previousSize > 0, currentSize > 0, previousSize != currentSize {
            return .invalidate
        }
        return .migrate
    }

    private static func normalized(_ revision: String?) -> String? {
        guard let value = revision?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }
}

public enum SourceStableCacheFileMigration {
    /// Moves one completed path-keyed cache object and removes transfer
    /// fragments that cannot be resumed with the provider's new path. The
    /// operation is idempotent so a repeated library notification can safely
    /// repair the cache manifest after the file has already moved.
    @discardableResult
    public static func migrateCompletedFile(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Int64? {
        guard source != destination else { return fileSize(at: destination, fileManager: fileManager) }
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        for base in [source, destination] {
            for suffix in [".partial", ".partial.prewarmed", ".offline"] {
                try? fileManager.removeItem(at: URL(fileURLWithPath: base.path + suffix))
            }
        }
        return fileSize(at: destination, fileManager: fileManager)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64? {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
            ?? attributes[.size] as? Int64
    }
}
