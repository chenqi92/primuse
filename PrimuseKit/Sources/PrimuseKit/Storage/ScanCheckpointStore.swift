import Foundation

public enum ScanCheckpointPhase: String, Codable, Sendable {
    /// The scan intent is durable, but no protocol response has produced
    /// authoritative progress yet.
    case initial
    case scanning
}

public enum ScanCheckpointIntent: String, Codable, Sendable {
    case automatic
    case fullScan
    case quickOnly
}

/// Device-local, uncommitted scan progress. The file intentionally remains a
/// dictionary keyed by source ID so checkpoints written by earlier builds can
/// still be decoded.
public struct ScanCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var phase: ScanCheckpointPhase
    public var intent: ScanCheckpointIntent
    public var directories: [String]
    public var songs: [Song]
    public var totalCount: Int
    public var currentFile: String
    public var updatedAt: Date
    /// Account/provider/root scope that produced this progress. Older
    /// checkpoints decode as nil and are restarted before network I/O rather
    /// than being resumed against a possibly different cloud account.
    public var scopeFingerprint: String?
    /// Provider-resolved roots used by the in-progress queue. This can differ
    /// from `directories` when a stable Baidu root was renamed or moved.
    public var resolvedDirectories: [String]?
    /// Nil for checkpoints written by older builds; those safely restart from
    /// the selected roots.
    public var directoryState: SourceScanResumeState?
    /// Provider cursors captured before a deep scan remain uncommitted until
    /// both the resumed walk and the library snapshot succeed.
    public var baselineCursors: [String: String]?
    /// Uncommitted Baidu snapshot traversal. It is intentionally separate from
    /// `directoryState`: completing only part of a provider tree must never
    /// become authoritative for deletion, but the remaining queue can resume.
    public var baiduSnapshotState: BaiduSnapshotResumeState?
    public var baiduTelemetry: SourceSyncTelemetry?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        phase: ScanCheckpointPhase,
        intent: ScanCheckpointIntent,
        directories: [String],
        songs: [Song],
        totalCount: Int,
        currentFile: String,
        updatedAt: Date,
        scopeFingerprint: String? = nil,
        resolvedDirectories: [String]? = nil,
        directoryState: SourceScanResumeState? = nil,
        baselineCursors: [String: String]? = nil,
        baiduSnapshotState: BaiduSnapshotResumeState? = nil,
        baiduTelemetry: SourceSyncTelemetry? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.intent = intent
        self.directories = directories
        self.songs = songs
        self.totalCount = totalCount
        self.currentFile = currentFile
        self.updatedAt = updatedAt
        self.scopeFingerprint = scopeFingerprint
        self.resolvedDirectories = resolvedDirectories
        self.directoryState = directoryState
        self.baselineCursors = baselineCursors
        self.baiduSnapshotState = baiduSnapshotState
        self.baiduTelemetry = baiduTelemetry
    }

    public var isUsable: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !directories.isEmpty
            && totalCount >= 0
    }

    /// Only a pre-progress automatic/quick intent or an explicitly resumable
    /// snapshot may use stateful refresh. A full/deep scan must remain a full
    /// walk after a cold launch.
    public var permitsStatefulRefresh: Bool {
        (phase == .initial && intent != .fullScan)
            || (baiduSnapshotState != nil && intent != .fullScan)
    }

    public var isQuickOnly: Bool {
        phase == .initial && intent == .quickOnly
    }

    public func promotedToFullScan(at date: Date = Date()) -> Self {
        guard phase == .initial, intent != .fullScan else { return self }
        var promoted = self
        promoted.intent = .fullScan
        promoted.baiduSnapshotState = nil
        promoted.baiduTelemetry = nil
        promoted.updatedAt = date
        return promoted
    }

    /// A directory captured by an uncommitted provider snapshot can be moved
    /// before a cold resume. Restart the snapshot from its stable roots instead
    /// of retrying the stale path or promoting partial evidence to a deep scan.
    public func restartingSnapshotTraversal(
        telemetry: SourceSyncTelemetry,
        at date: Date = Date()
    ) -> Self {
        var restarted = self
        restarted.phase = .initial
        restarted.currentFile = ""
        restarted.resolvedDirectories = nil
        restarted.baiduSnapshotState = nil
        restarted.baiduTelemetry = telemetry
        restarted.updatedAt = date
        return restarted
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case phase
        case intent
        case directories
        case songs
        case totalCount
        case currentFile
        case updatedAt
        case scopeFingerprint
        case resolvedDirectories
        case directoryState
        case baselineCursors
        case baiduSnapshotState
        case baiduTelemetry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        // A legacy entry could only have been written after scanning had
        // produced progress, so never reinterpret it as a quick-sync intent.
        phase = try container.decodeIfPresent(ScanCheckpointPhase.self, forKey: .phase)
            ?? .scanning
        intent = try container.decodeIfPresent(ScanCheckpointIntent.self, forKey: .intent)
            ?? .fullScan
        directories = try container.decode([String].self, forKey: .directories)
        songs = try container.decode([Song].self, forKey: .songs)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
        currentFile = try container.decode(String.self, forKey: .currentFile)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        scopeFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .scopeFingerprint
        )
        resolvedDirectories = try container.decodeIfPresent(
            [String].self,
            forKey: .resolvedDirectories
        )
        directoryState = try container.decodeIfPresent(
            SourceScanResumeState.self,
            forKey: .directoryState
        )
        baselineCursors = try container.decodeIfPresent(
            [String: String].self,
            forKey: .baselineCursors
        )
        baiduSnapshotState = try container.decodeIfPresent(
            BaiduSnapshotResumeState.self,
            forKey: .baiduSnapshotState
        )
        baiduTelemetry = try container.decodeIfPresent(
            SourceSyncTelemetry.self,
            forKey: .baiduTelemetry
        )
    }
}

public enum ScanCheckpointPreparationPolicy {
    /// Preserves real progress for the same directory scope. Otherwise creates
    /// a restartable intent whose root queue is known before network I/O.
    public static func preparingCheckpoint(
        existing: ScanCheckpoint?,
        directories: [String],
        mode: SourceSyncMode,
        scopeFingerprint: String? = nil,
        now: Date = Date()
    ) -> ScanCheckpoint {
        if let existing,
           existing.isUsable,
           existing.directories == directories,
           scopeFingerprint == nil || existing.scopeFingerprint == scopeFingerprint {
            return existing
        }

        let intent: ScanCheckpointIntent
        switch mode {
        case .automatic:
            intent = .automatic
        case .quick:
            intent = .quickOnly
        case .deep:
            intent = .fullScan
        }
        return ScanCheckpoint(
            phase: .initial,
            intent: intent,
            directories: directories,
            songs: [],
            totalCount: 0,
            currentFile: "",
            updatedAt: now,
            scopeFingerprint: scopeFingerprint,
            directoryState: SourceScanResumeState(pendingDirectories: directories)
        )
    }
}

public enum ScanCheckpointSourceDisposition: Equatable, Sendable {
    case resume
    case retain
    case discard
}

public enum ScanCheckpointSourcePolicy {
    /// Missing and deleted sources cannot become live again from device-local
    /// progress. Disabled sources retain an explicit user-resumable checkpoint
    /// but are never launched automatically.
    public static func disposition(
        sourceExists: Bool,
        isEnabled: Bool,
        isDeleted: Bool
    ) -> ScanCheckpointSourceDisposition {
        guard sourceExists, !isDeleted else { return .discard }
        return isEnabled ? .resume : .retain
    }
}

public enum ScanCheckpointStoreError: Error, Equatable {
    case invalidCheckpoint(String)
}

/// Serial checkpoint mutations plus a recoverable atomic JSON snapshot. The
/// previous readable destination is retained as a backup until the next valid
/// replacement succeeds.
public actor ScanCheckpointFileStore {
    public typealias AtomicWriter = @Sendable (
        _ data: Data,
        _ destinationURL: URL,
        _ backupURL: URL,
        _ preserveExistingAsBackup: Bool
    ) throws -> Void

    public static let defaultAtomicWriter: AtomicWriter = {
        data, destinationURL, backupURL, preserveExistingAsBackup in
        try AtomicBackupFileWriter.write(
            data,
            to: destinationURL,
            backupURL: backupURL,
            preserveExistingAsBackup: preserveExistingAsBackup
        )
    }

    private let checkpointURL: URL
    private let backupURL: URL
    private let atomicWriter: AtomicWriter
    private var checkpoints: [String: ScanCheckpoint]

    public init(
        checkpointURL: URL,
        backupURL: URL? = nil,
        initialCheckpoints: [String: ScanCheckpoint]? = nil,
        atomicWriter: @escaping AtomicWriter = ScanCheckpointFileStore.defaultAtomicWriter
    ) {
        let resolvedBackupURL = backupURL ?? Self.defaultBackupURL(for: checkpointURL)
        self.checkpointURL = checkpointURL
        self.backupURL = resolvedBackupURL
        self.atomicWriter = atomicWriter
        self.checkpoints = initialCheckpoints ?? Self.load(
            from: checkpointURL,
            backupURL: resolvedBackupURL
        )
    }

    public func snapshot() -> [String: ScanCheckpoint] {
        checkpoints
    }

    public func replace(with snapshot: [String: ScanCheckpoint]) throws {
        try Self.writeSnapshot(
            snapshot,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter
        )
        checkpoints = snapshot
    }

    public func upsert(_ checkpoint: ScanCheckpoint, for sourceID: String) throws {
        guard checkpoint.isUsable else {
            throw ScanCheckpointStoreError.invalidCheckpoint(sourceID)
        }
        var candidate = checkpoints
        candidate[sourceID] = checkpoint
        try Self.writeSnapshot(
            candidate,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter
        )
        checkpoints = candidate
    }

    public func remove(sourceID: String) throws {
        var candidate = checkpoints
        candidate[sourceID] = nil
        try Self.writeSnapshot(
            candidate,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter
        )
        checkpoints = candidate
    }

    public nonisolated static func defaultBackupURL(for checkpointURL: URL) -> URL {
        checkpointURL.deletingPathExtension().appendingPathExtension("backup.json")
    }

    public nonisolated static func load(
        from checkpointURL: URL,
        backupURL: URL? = nil
    ) -> [String: ScanCheckpoint] {
        let resolvedBackupURL = backupURL ?? defaultBackupURL(for: checkpointURL)
        for candidateURL in [checkpointURL, resolvedBackupURL] {
            guard let data = try? Data(contentsOf: candidateURL),
                  let decoded = decodeRecoveringValidEntries(from: data) else {
                continue
            }
            return decoded
        }
        return [:]
    }

    public nonisolated static func writeSnapshot(
        _ checkpoints: [String: ScanCheckpoint],
        to checkpointURL: URL,
        backupURL: URL? = nil,
        atomicWriter: AtomicWriter = ScanCheckpointFileStore.defaultAtomicWriter
    ) throws {
        if let invalid = checkpoints.first(where: { !$0.value.isUsable }) {
            throw ScanCheckpointStoreError.invalidCheckpoint(invalid.key)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoints)
        let resolvedBackupURL = backupURL ?? defaultBackupURL(for: checkpointURL)
        let preserveExistingAsBackup: Bool
        if let currentData = try? Data(contentsOf: checkpointURL) {
            preserveExistingAsBackup = isTrustedSnapshotData(currentData)
        } else {
            preserveExistingAsBackup = false
        }
        try atomicWriter(
            data,
            checkpointURL,
            resolvedBackupURL,
            preserveExistingAsBackup
        )
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private nonisolated static func isTrustedSnapshotData(_ data: Data) -> Bool {
        guard let decoded = try? decoder().decode([String: ScanCheckpoint].self, from: data) else {
            return false
        }
        return decoded.values.allSatisfy(\.isUsable)
    }

    private nonisolated static func decodeRecoveringValidEntries(
        from data: Data
    ) -> [String: ScanCheckpoint]? {
        if let decoded = try? decoder().decode([String: ScanCheckpoint].self, from: data) {
            return decoded.filter { $0.value.isUsable }
        }

        // A single malformed source entry must not erase unrelated sources.
        // If the root JSON object itself is truncated, loading falls through
        // to the previous atomic backup instead.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rawEntries = object as? [String: Any] else {
            return nil
        }
        var recovered: [String: ScanCheckpoint] = [:]
        for (sourceID, rawEntry) in rawEntries {
            guard JSONSerialization.isValidJSONObject([sourceID: rawEntry]),
                  let entryData = try? JSONSerialization.data(
                    withJSONObject: [sourceID: rawEntry]
                  ),
                  let entry = try? decoder().decode(
                    [String: ScanCheckpoint].self,
                    from: entryData
                  )[sourceID],
                  entry.isUsable else {
                continue
            }
            recovered[sourceID] = entry
        }
        return recovered
    }
}
