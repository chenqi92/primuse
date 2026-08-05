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
    public var cursors: [String: String]
    public var index: [String: SourceSyncIndexedItem]
    public var pendingDirectories: [String]
    public var scanEpoch: Int64
    public var requiresDeepScan: Bool
    public var lastFullScanAt: Date?
    public var lastSuccessfulSyncAt: Date?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceID: String,
        scopeFingerprint: String,
        cursors: [String: String] = [:],
        index: [String: SourceSyncIndexedItem] = [:],
        pendingDirectories: [String] = [],
        scanEpoch: Int64 = 0,
        requiresDeepScan: Bool = false,
        lastFullScanAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.scopeFingerprint = scopeFingerprint
        self.cursors = cursors
        self.index = index
        self.pendingDirectories = pendingDirectories
        self.scanEpoch = scanEpoch
        self.requiresDeepScan = requiresDeepScan
        self.lastFullScanAt = lastFullScanAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }

    public func isUsable(sourceID: String, scopeFingerprint: String) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && self.sourceID == sourceID
            && self.scopeFingerprint == scopeFingerprint
            && !requiresDeepScan
    }
}

public struct SourceSyncIndexedItem: Codable, Sendable, Equatable {
    public var stableKey: String
    public var path: String
    public var parentPath: String?
    public var isDirectory: Bool
    public var songIDs: [String]
    public var size: Int64
    public var modifiedDate: Date?
    public var revision: String?
    public var seenEpoch: Int64

    public init(
        stableKey: String,
        path: String,
        parentPath: String?,
        isDirectory: Bool,
        songIDs: [String] = [],
        size: Int64,
        modifiedDate: Date?,
        revision: String?,
        seenEpoch: Int64 = 0
    ) {
        self.stableKey = stableKey
        self.path = path
        self.parentPath = parentPath
        self.isDirectory = isDirectory
        self.songIDs = songIDs
        self.size = size
        self.modifiedDate = modifiedDate
        self.revision = revision
        self.seenEpoch = seenEpoch
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
