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
    /// Rows this scan has produced that are not yet in the library. A file or
    /// NAS walk publishes its rows as it goes and the library persists them on
    /// its own schedule, so carrying the whole accumulated catalogue here would
    /// re-encode every song on every checkpoint write — and on a large library
    /// that grows the write interval until the checkpoint is barely written at
    /// all. Keeping only the tail keeps checkpoints small and frequent.
    /// Dedicated NAS walks still store their complete snapshot here.
    public var songs: [Song]
    /// Rows walked so far, kept separately now that `songs` may hold only the
    /// tail. Nil in checkpoints written by older builds.
    public var scannedSongCount: Int?
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
    /// Uncommitted, authoritative-page progress for a Subsonic search3
    /// catalogue. `songs` contains only the staged candidate rows and is never
    /// published to MusicLibrary until this state reaches the terminal page.
    public var subsonicCatalogState: SubsonicCatalogResumeState?
    /// Automatic lifecycle resume failures use a durable backoff. Explicit
    /// user scans bypass this timestamp, while background transitions avoid
    /// retrying the same unavailable source in a tight loop.
    public var automaticResumeFailureCount: Int
    public var automaticResumeAfter: Date?
    /// 用户取消后保留进度，只有再次手动扫描才恢复。
    public var isPausedByUser: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        phase: ScanCheckpointPhase,
        intent: ScanCheckpointIntent,
        directories: [String],
        songs: [Song],
        scannedSongCount: Int? = nil,
        totalCount: Int,
        currentFile: String,
        updatedAt: Date,
        scopeFingerprint: String? = nil,
        resolvedDirectories: [String]? = nil,
        directoryState: SourceScanResumeState? = nil,
        baselineCursors: [String: String]? = nil,
        baiduSnapshotState: BaiduSnapshotResumeState? = nil,
        baiduTelemetry: SourceSyncTelemetry? = nil,
        subsonicCatalogState: SubsonicCatalogResumeState? = nil,
        automaticResumeFailureCount: Int = 0,
        automaticResumeAfter: Date? = nil,
        isPausedByUser: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.intent = intent
        self.directories = directories
        self.songs = songs
        self.scannedSongCount = scannedSongCount
        self.totalCount = totalCount
        self.currentFile = currentFile
        self.updatedAt = updatedAt
        self.scopeFingerprint = scopeFingerprint
        self.resolvedDirectories = resolvedDirectories
        self.directoryState = directoryState
        self.baselineCursors = baselineCursors
        self.baiduSnapshotState = baiduSnapshotState
        self.baiduTelemetry = baiduTelemetry
        self.subsonicCatalogState = subsonicCatalogState
        self.automaticResumeFailureCount = automaticResumeFailureCount
        self.automaticResumeAfter = automaticResumeAfter
        self.isPausedByUser = isPausedByUser
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

    public func canAutomaticallyResume(at date: Date = Date()) -> Bool {
        !isPausedByUser && (automaticResumeAfter.map { $0.timeIntervalSinceReferenceDate <= date.timeIntervalSinceReferenceDate } ?? true)
    }

    public func recordingAutomaticResumeFailure(at date: Date = Date()) -> Self {
        var updated = self
        let failureCount = min(max(0, automaticResumeFailureCount) + 1, 8)
        let exponent = min(failureCount - 1, 6)
        let delay = min(6 * 60 * 60, 5 * 60 * (1 << exponent))
        updated.automaticResumeFailureCount = failureCount
        updated.automaticResumeAfter = date.addingTimeInterval(TimeInterval(delay))
        return updated
    }

    public func clearingAutomaticResumeFailure() -> Self {
        guard automaticResumeFailureCount != 0 || automaticResumeAfter != nil else {
            return self
        }
        var updated = self
        updated.automaticResumeFailureCount = 0
        updated.automaticResumeAfter = nil
        return updated
    }

    /// Earliest moment strictly after `date` at which one of `checkpoints`
    /// leaves its automatic-resume backoff. Nil when none of them is backing
    /// off, so lifecycle code can distinguish "resume now" from "wake later".
    public static func earliestAutomaticResumeDate<S: Sequence>(
        in checkpoints: S,
        after date: Date = Date()
    ) -> Date? where S.Element == ScanCheckpoint {
        var earliest: Date?
        for checkpoint in checkpoints {
            guard !checkpoint.isPausedByUser,
                  let resumeAfter = checkpoint.automaticResumeAfter, resumeAfter > date else { continue }
            earliest = earliest.map { min($0, resumeAfter) } ?? resumeAfter
        }
        return earliest
    }

    public func promotedToFullScan(at date: Date = Date()) -> Self {
        guard phase == .initial, intent != .fullScan else { return self }
        var promoted = self
        promoted.intent = .fullScan
        promoted.baiduSnapshotState = nil
        promoted.baiduTelemetry = nil
        promoted.subsonicCatalogState = nil
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
        case scannedSongCount
        case totalCount
        case currentFile
        case updatedAt
        case scopeFingerprint
        case resolvedDirectories
        case directoryState
        case baselineCursors
        case baiduSnapshotState
        case baiduTelemetry
        case subsonicCatalogState
        case automaticResumeFailureCount
        case automaticResumeAfter
        case isPausedByUser
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
        // Checkpoints from builds that stored the whole accumulated catalogue
        // have no separate count; their `songs` is that count.
        scannedSongCount = try container.decodeIfPresent(
            Int.self,
            forKey: .scannedSongCount
        )
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
        subsonicCatalogState = try container.decodeIfPresent(
            SubsonicCatalogResumeState.self,
            forKey: .subsonicCatalogState
        )
        automaticResumeFailureCount = try container.decodeIfPresent(
            Int.self,
            forKey: .automaticResumeFailureCount
        ) ?? 0
        automaticResumeAfter = try container.decodeIfPresent(
            Date.self,
            forKey: .automaticResumeAfter
        )
        isPausedByUser = try container.decodeIfPresent(Bool.self, forKey: .isPausedByUser) ?? false
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

/// Every checkpoint write re-encodes the complete accumulated song arrays of
/// all sources, so a large library turns a fixed ten-second cadence into
/// gigabytes of flash writes per hour of scanning. The interval therefore
/// grows with the payload that last reached disk while forced writes
/// (cancellation, completion) stay immediate.
public enum ScanCheckpointPersistencePolicy {
    public static let minimumInterval: TimeInterval = 10
    public static let maximumInterval: TimeInterval = 180
    /// Sustained checkpoint write budget while a scan is running.
    public static let bytesPerSecond: Double = 100 * 1024

    public static func interval(
        encodedByteCount: Int,
        maximumInterval: TimeInterval = ScanCheckpointPersistencePolicy.maximumInterval
    ) -> TimeInterval {
        guard encodedByteCount > 0 else { return minimumInterval }
        let ceiling = max(minimumInterval, maximumInterval)
        return min(ceiling, max(minimumInterval, Double(encodedByteCount) / bytesPerSecond))
    }
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
    /// Initial checkpoints may come from the backup file or from a partially
    /// recovered primary, so only a snapshot this store has written itself is
    /// known to match the primary file byte for byte.
    private var hasWrittenSnapshot = false
    /// 目录走查进度的段文件(`SourceScanResumeState` 的索引与歌曲 ID)。JSON 里只记清单,
    /// 每段只写一次;不再被主文件和备份引用的段在写完之后删掉。
    private let segmentStore: ScanResumeSegmentStore
    /// 上一份写成功(或启动时读到)的快照引用的段。写新快照时它会变成备份,段要留着。
    private var retainedSegmentIDs: Set<UUID>

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
        self.segmentStore = ScanResumeSegmentStore(directory: Self.segmentDirectory(for: checkpointURL))
        self.retainedSegmentIDs = Set(self.checkpoints.values.flatMap { $0.directoryState?.segmentIDs ?? [] })
    }

    public func snapshot() -> [String: ScanCheckpoint] {
        checkpoints
    }

    /// Writes `snapshot` and returns the encoded byte count. A snapshot equal
    /// to the one this store last wrote returns 0 without touching the file:
    /// the durable copy already matches, so re-encoding it would only cost
    /// flash writes. Loaded-but-unwritten state is always written once.
    @discardableResult
    public func replace(with snapshot: [String: ScanCheckpoint]) throws -> Int {
        guard !(hasWrittenSnapshot && snapshot == checkpoints) else { return 0 }
        let byteCount = try writeSegmented(snapshot)
        checkpoints = snapshot
        hasWrittenSnapshot = true
        return byteCount
    }

    public func upsert(_ checkpoint: ScanCheckpoint, for sourceID: String) throws {
        guard checkpoint.isUsable else {
            throw ScanCheckpointStoreError.invalidCheckpoint(sourceID)
        }
        var candidate = checkpoints
        candidate[sourceID] = checkpoint
        try writeSegmented(candidate)
        checkpoints = candidate
        hasWrittenSnapshot = true
    }

    public func remove(sourceID: String) throws {
        var candidate = checkpoints
        candidate[sourceID] = nil
        try writeSegmented(candidate)
        checkpoints = candidate
        hasWrittenSnapshot = true
    }

    /// 走查进度的段先写成文件,再原子替换 JSON;替换成功后删掉主文件与备份都不再引用的段。
    /// 返回这次实际写盘的字节数(JSON 加上新写的段文件),写入间隔按它放宽
    /// (`ScanCheckpointPersistencePolicy`),和以前整份内联 JSON 时一样受写盘预算约束。
    @discardableResult
    private func writeSegmented(_ snapshot: [String: ScanCheckpoint]) throws -> Int {
        segmentStore.beginPass()
        let byteCount = try Self.writeSnapshot(
            snapshot,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter,
            segmentStore: segmentStore
        )
        let referenced = segmentStore.endPass()
        let segmentBytes = segmentStore.bytesWrittenThisPass
        segmentStore.removeFiles(keeping: referenced.union(retainedSegmentIDs))
        retainedSegmentIDs = referenced
        return byteCount + segmentBytes
    }

    public nonisolated static func defaultBackupURL(for checkpointURL: URL) -> URL {
        checkpointURL.deletingPathExtension().appendingPathExtension("backup.json")
    }

    /// 走查进度段文件所在的目录(与断点文件同级)。
    public nonisolated static func segmentDirectory(for checkpointURL: URL) -> URL {
        checkpointURL.deletingPathExtension().appendingPathExtension("segments")
    }

    public nonisolated static func load(
        from checkpointURL: URL,
        backupURL: URL? = nil
    ) -> [String: ScanCheckpoint] {
        let resolvedBackupURL = backupURL ?? defaultBackupURL(for: checkpointURL)
        let segmentStore = ScanResumeSegmentStore(directory: segmentDirectory(for: checkpointURL))
        for candidateURL in [checkpointURL, resolvedBackupURL] {
            guard let data = try? Data(contentsOf: candidateURL),
                  let decoded = decodeRecoveringValidEntries(from: data, segmentStore: segmentStore) else {
                continue
            }
            return decoded
        }
        return [:]
    }

    /// 整份内联写出(走查进度不拆成段文件),格式与以前完全一样。
    @discardableResult
    public nonisolated static func writeSnapshot(
        _ checkpoints: [String: ScanCheckpoint],
        to checkpointURL: URL,
        backupURL: URL? = nil,
        atomicWriter: AtomicWriter = ScanCheckpointFileStore.defaultAtomicWriter
    ) throws -> Int {
        try writeSnapshot(
            checkpoints,
            to: checkpointURL,
            backupURL: backupURL,
            atomicWriter: atomicWriter,
            segmentStore: nil
        )
    }

    private nonisolated static func writeSnapshot(
        _ checkpoints: [String: ScanCheckpoint],
        to checkpointURL: URL,
        backupURL: URL?,
        atomicWriter: AtomicWriter,
        segmentStore: ScanResumeSegmentStore?
    ) throws -> Int {
        if let invalid = checkpoints.first(where: { !$0.value.isUsable }) {
            throw ScanCheckpointStoreError.invalidCheckpoint(invalid.key)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let segmentStore {
            encoder.userInfo[.scanResumeSegmentStore] = segmentStore
        }
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
        return data.count
    }

    private nonisolated static func decoder(segmentStore: ScanResumeSegmentStore? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let segmentStore {
            decoder.userInfo[.scanResumeSegmentStore] = segmentStore
        }
        return decoder
    }

    private nonisolated static func isTrustedSnapshotData(_ data: Data) -> Bool {
        guard let decoded = try? decoder().decode([String: ScanCheckpoint].self, from: data) else {
            return false
        }
        return decoded.values.allSatisfy(\.isUsable)
    }

    private nonisolated static func decodeRecoveringValidEntries(
        from data: Data,
        segmentStore: ScanResumeSegmentStore
    ) -> [String: ScanCheckpoint]? {
        if let decoded = try? decoder(segmentStore: segmentStore).decode([String: ScanCheckpoint].self, from: data) {
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
                  let entry = try? decoder(segmentStore: segmentStore).decode(
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

public struct SourceSyncStateWriteReceipt: Sendable, Equatable {
    public let sourceID: String
    public let mutationEpoch: UInt64
    public let sourceRevision: UInt64

    public init(sourceID: String, mutationEpoch: UInt64, sourceRevision: UInt64) {
        self.sourceID = sourceID
        self.mutationEpoch = mutationEpoch
        self.sourceRevision = sourceRevision
    }
}

/// Serializes per-source cursor/index mutations. Each caller contributes
/// only its source row, so concurrent scan completions cannot replace another
/// source's freshly committed state with an older one. While a write is in
/// flight, later mutations are folded into one follow-up flush; every caller
/// still waits until its revision (or a newer one) is durable before receiving
/// a receipt.
///
/// 落盘有两种去处:平常是每个源各自的文件(`SourceSyncStateDirectory`),一次
/// 提交只重写变了的那几个源;旧的整份 JSON 只在迁移没能完成的那次启动里继续写
/// (旧文件那时仍是权威,见 `SourceSyncStateDirectory.load`)。
public actor SourceSyncStateFileStore {
    public typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    private enum Destination {
        case legacySnapshot(URL)
        case directory(URL)
    }

    private struct SourceWrite: Sendable {
        let sourceID: String
        let state: SourceSyncState?
        let previous: SourceSyncStateDirectory.Record?
        let previousIndex: SourceSyncIndex?
    }

    private let destination: Destination
    private let atomicWriter: AtomicWriter?
    private var states: [String: SourceSyncState]
    private var mutationEpochs: [String: UInt64] = [:]
    private var sourceRevisions: [String: UInt64] = [:]
    private var persistenceRevision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    /// 旧格式:磁盘上已有一份解得开的整份快照。
    private var hasPersistedSnapshot: Bool
    /// 每源文件:磁盘上每个源现在的样子,以及那份索引文件里存的是哪份索引。
    private var records: [String: SourceSyncStateDirectory.Record] = [:]
    private var persistedIndexes: [String: SourceSyncIndex] = [:]
    /// 每源文件:还没落盘的源(状态变了,或者要删掉)。
    private var dirtySourceIDs: Set<String> = []
    private var persistenceTask: Task<Void, Error>?

    /// 旧格式:所有源写进 `url` 这一整份 JSON。
    public init(
        url: URL,
        initialStates: [String: SourceSyncState] = [:],
        initialSnapshotIsPersisted: Bool = false,
        atomicWriter: AtomicWriter? = nil
    ) {
        self.destination = .legacySnapshot(url)
        self.states = initialStates
        self.hasPersistedSnapshot = initialSnapshotIsPersisted
        self.atomicWriter = atomicWriter
    }

    /// 每个源各自的文件。`persistedRecords` 是启动时从目录里读到的那些源;
    /// 在 `initialStates` 里却没有记录的源,第一次 upsert 时即使内容没变也会写一次。
    public init(
        directory: URL,
        initialStates: [String: SourceSyncState] = [:],
        persistedRecords: [String: SourceSyncStateDirectory.Record] = [:],
        atomicWriter: AtomicWriter? = nil
    ) {
        self.destination = .directory(directory)
        self.states = initialStates
        self.hasPersistedSnapshot = true
        self.records = persistedRecords
        self.atomicWriter = atomicWriter
        for (sourceID, record) in persistedRecords where record.index != nil {
            if let index = initialStates[sourceID]?.index {
                persistedIndexes[sourceID] = index
            }
        }
    }

    /// An epoch is advanced synchronously by the source-change observer. A
    /// later-arriving write from the previous credential/configuration scope
    /// is rejected even if its network task suspended before cancellation.
    public func upsert(
        _ state: SourceSyncState,
        expectedMutationEpoch: UInt64
    ) async throws -> SourceSyncStateWriteReceipt? {
        let sourceID = state.sourceID
        let currentEpoch = mutationEpochs[sourceID, default: 0]
        guard expectedMutationEpoch >= currentEpoch else { return nil }

        let contentChanged = states[sourceID] != state
        if contentChanged {
            states[sourceID] = state
            markDirty(sourceID)
        } else if needsRepairWrite(sourceID) {
            markDirty(sourceID)
        }
        let revision = sourceRevisions[sourceID, default: 0] &+ 1
        mutationEpochs[sourceID] = expectedMutationEpoch
        sourceRevisions[sourceID] = revision
        try await persistLatestStateIfNeeded()
        return SourceSyncStateWriteReceipt(
            sourceID: sourceID,
            mutationEpoch: expectedMutationEpoch,
            sourceRevision: revision
        )
    }

    /// Removes stale cursor/topology state for a persisted source edit. If a
    /// new-scope write reaches the actor first, the equal delayed invalidation
    /// is a no-op and cannot erase that newer state.
    public func invalidate(
        sourceID: String,
        mutationEpoch: UInt64
    ) async throws -> SourceSyncStateWriteReceipt? {
        try await advanceMutationEpoch(
            sourceID: sourceID,
            mutationEpoch: mutationEpoch,
            discardingState: true
        )
    }

    /// A cancelled scan advances the write fence without discarding the last
    /// committed cursor. This prevents its suspended write from arriving after
    /// a replacement generation while retaining safe resume state.
    public func advanceMutationEpoch(
        sourceID: String,
        mutationEpoch: UInt64,
        discardingState: Bool = false
    ) async throws -> SourceSyncStateWriteReceipt? {
        let currentEpoch = mutationEpochs[sourceID, default: 0]
        guard mutationEpoch > currentEpoch else { return nil }

        if discardingState, states.removeValue(forKey: sourceID) != nil {
            markDirty(sourceID)
        } else if discardingState {
            switch destination {
            case .legacySnapshot:
                if !hasPersistedSnapshot, persistenceRevision == persistedRevision {
                    persistenceRevision &+= 1
                }
            case .directory:
                // 内存里没有、磁盘上却有(读的时候出过问题):一起删掉。
                if records[sourceID] != nil { markDirty(sourceID) }
            }
        }
        let revision = sourceRevisions[sourceID, default: 0] &+ 1
        mutationEpochs[sourceID] = mutationEpoch
        sourceRevisions[sourceID] = revision
        try await persistLatestStateIfNeeded()
        return SourceSyncStateWriteReceipt(
            sourceID: sourceID,
            mutationEpoch: mutationEpoch,
            sourceRevision: revision
        )
    }

    public func snapshot() -> [String: SourceSyncState] {
        states
    }

    /// Releases clean, already-persisted `SourceSyncIndex` buffers for idle sources
    /// when backed by per-source index files on disk.
    public func evictPersistedIndexes(for sourceIDs: Set<String>) {
        guard case .directory = destination,
              persistedRevision == persistenceRevision,
              persistenceTask == nil else { return }
        for sourceID in sourceIDs {
            guard !dirtySourceIDs.contains(sourceID),
                  records[sourceID]?.index != nil else { continue }
            states[sourceID]?.index = SourceSyncIndex()
            persistedIndexes[sourceID] = nil
        }
    }

    public func restorePersistedIndex(
        _ index: SourceSyncIndex,
        reference: SourceSyncStateDirectory.IndexReference,
        for sourceID: String
    ) {
        guard case .directory = destination,
              !dirtySourceIDs.contains(sourceID),
              records[sourceID]?.index == reference,
              states[sourceID]?.index.isEmpty == true else { return }
        states[sourceID]?.index = index
        persistedIndexes[sourceID] = index
    }

    private func markDirty(_ sourceID: String) {
        persistenceRevision &+= 1
        dirtySourceIDs.insert(sourceID)
    }

    /// 内容没变也要写一次的情况:磁盘上还没有它(启动时没读到可信的那一份)。
    private func needsRepairWrite(_ sourceID: String) -> Bool {
        switch destination {
        case .legacySnapshot:
            return !hasPersistedSnapshot && persistenceRevision == persistedRevision
        case .directory:
            return records[sourceID] == nil && !dirtySourceIDs.contains(sourceID)
        }
    }

    private func persistLatestStateIfNeeded() async throws {
        let requiredRevision = persistenceRevision
        while persistedRevision < requiredRevision {
            if persistenceTask == nil {
                persistenceTask = Task<Void, Error> { [self] in
                    try await flushLatestStates()
                }
            }
            try await persistenceTask?.value
        }
    }

    private func flushLatestStates() async throws {
        defer { persistenceTask = nil }
        await Task.yield()

        while persistedRevision < persistenceRevision {
            let revision = persistenceRevision
            switch destination {
            case .legacySnapshot(let url):
                let snapshot = states
                let atomicWriter = atomicWriter
                let writeTask = Task.detached(priority: .utility) {
                    if let atomicWriter {
                        var data = Data()
                        try Self.streamSnapshot(snapshot) { data.append($0) }
                        try atomicWriter(data, url)
                    } else {
                        try Self.writeSnapshot(snapshot, to: url)
                    }
                }
                try await writeTask.value
                hasPersistedSnapshot = true
            case .directory(let directory):
                try await flushDirtySources(to: directory)
            }
            persistedRevision = revision
            await Task.yield()
        }
    }

    /// 只写变了的源。中途失败时已经写完的源照常记下,失败的与还没轮到的留到下一次。
    private func flushDirtySources(to directory: URL) async throws {
        let pending = dirtySourceIDs
        dirtySourceIDs.removeAll()
        let work = pending.sorted().map { sourceID in
            SourceWrite(
                sourceID: sourceID,
                state: states[sourceID],
                previous: records[sourceID],
                previousIndex: persistedIndexes[sourceID]
            )
        }
        let atomicWriter = atomicWriter
        let writeTask = Task.detached(priority: .utility) {
            () -> (completed: [(String, SourceSyncStateDirectory.Record?)], failure: (any Error)?) in
            var completed: [(String, SourceSyncStateDirectory.Record?)] = []
            for item in work {
                do {
                    if let state = item.state {
                        let record = try SourceSyncStateDirectory.writeSource(
                            state,
                            previous: item.previous,
                            previousIndex: item.previousIndex,
                            in: directory,
                            writer: atomicWriter
                        )
                        completed.append((item.sourceID, record))
                    } else {
                        try SourceSyncStateDirectory.removeSource(item.sourceID, in: directory)
                        completed.append((item.sourceID, nil))
                    }
                } catch {
                    return (completed, error)
                }
            }
            return (completed, nil)
        }
        let outcome = await writeTask.value
        var finished = Set<String>()
        let statesByID = Dictionary(work.map { ($0.sourceID, $0.state) }, uniquingKeysWith: { first, _ in first })
        for (sourceID, record) in outcome.completed {
            finished.insert(sourceID)
            if let record {
                records[sourceID] = record
                if record.index != nil, let index = statesByID[sourceID]??.index {
                    persistedIndexes[sourceID] = index
                } else {
                    persistedIndexes[sourceID] = nil
                }
            } else {
                records[sourceID] = nil
                persistedIndexes[sourceID] = nil
            }
        }
        if let failure = outcome.failure {
            dirtySourceIDs.formUnion(pending.subtracting(finished))
            throw failure
        }
    }

    private nonisolated static func writeSnapshot(
        _ snapshot: [String: SourceSyncState], to url: URL
    ) throws {
        let manager = FileManager.default
        let replacement = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).replacement"
        )
        defer { try? manager.removeItem(at: replacement) }
        guard manager.createFile(
            atPath: replacement.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: replacement)
        do {
            try streamSnapshot(snapshot) { try handle.write(contentsOf: $0) }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: replacement)
        } else {
            try manager.moveItem(at: replacement, to: url)
        }
    }

    /// Keep the existing JSON format without building an encoder object tree
    /// for every source's entire hierarchy at once.
    nonisolated static func streamSnapshot(
        _ snapshot: [String: SourceSyncState], append: (Data) throws -> Void
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var buffer = Data()
        func emit(_ data: Data) throws {
            var remaining = data[...]
            while !remaining.isEmpty {
                let count = min(128 * 1024 - buffer.count, remaining.count)
                buffer.append(contentsOf: remaining.prefix(count))
                remaining = remaining.dropFirst(count)
                if buffer.count == 128 * 1024 {
                    try append(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        try emit(Data("{".utf8))
        for (sourceOffset, sourceID) in snapshot.keys.sorted().enumerated() {
            guard let state = snapshot[sourceID] else { continue }
            if sourceOffset > 0 { try emit(Data(",".utf8)) }
            try emit(encoder.encode(sourceID))
            try emit(Data(":".utf8))
            var metadata = state
            metadata.index = SourceSyncIndex()
            // Let Codable own the metadata schema, including future fields.
            guard var object = try JSONSerialization.jsonObject(
                with: encoder.encode(metadata)
            ) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
            object.removeValue(forKey: "index")
            var header = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            header.removeLast()
            try emit(header)
            try emit(Data(",\"index\":{".utf8))
            let keys = state.index.keys.sorted()
            for start in stride(from: 0, to: keys.count, by: 128) {
                try autoreleasepool {
                    var batch: [String: SourceSyncIndexedItem] = [:]
                    batch.reserveCapacity(128)
                    for key in keys[start..<min(start + 128, keys.count)] {
                        batch[key] = state.index[key]
                    }
                    var encoded = try encoder.encode(batch)
                    encoded.removeFirst()
                    encoded.removeLast()
                    if start > 0 { try emit(Data(",".utf8)) }
                    try emit(encoded)
                }
            }
            try emit(Data("}}".utf8))
        }
        try emit(Data("}".utf8))
        if !buffer.isEmpty { try append(buffer) }
    }
}
