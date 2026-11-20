import CryptoKit
import Foundation

public enum SourceSyncMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case quick
    case deep
}

/// Device-local discovery state. Provider cursors are deliberately kept out of
/// MusicSource/CloudKit because they describe one device's committed snapshot.
public struct SourceSyncState: Codable, Sendable, Equatable {
    /// Version 2 adds indexed artist-image files. Existing cursors cannot
    /// discover images that were already present before the upgrade, so their
    /// next refresh intentionally performs one complete directory walk.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var sourceID: String
    public var scopeFingerprint: String
    /// Provider account and endpoint identity without the selected roots. It
    /// permits root-selection changes to reuse stable IDs while fencing an
    /// account switch even when a provider happens to reuse the same item ID.
    public var identityScopeFingerprint: String?
    public var cursors: [String: String]
    /// 已提交的条目索引,紧凑存放(见 `SourceSyncIndex`);语义与
    /// `[String: SourceSyncIndexedItem]` 相同,JSON 形状也相同。
    public var index: SourceSyncIndex
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
    /// Consecutive complete-catalogue misses for a server source whose snapshot
    /// is evidence rather than authority, keyed by `Song.id`. Driven by
    /// `ServerCatalogDeletionConfirmationPolicy`.
    public var missingCatalogSongIDs: [String: Int]
    /// 产生 `missingCatalogSongIDs` 最新一票的那次观察（完整走查记
    /// `ServerCatalogDeletionConfirmationPolicy.walkObservationRevision`）。同一次走查重读
    /// 不算第二票。旧版本记的是服务端扫描标记，升级后的第一次走查自然算新的一票。
    public var deletionEvidenceRevision: String?
    /// What a catalogue source needs to ask its server "what changed" next
    /// time. Written only by a pass that committed a complete, verified view of
    /// the catalogue, so an incremental answer is always measured against a
    /// known-good baseline. Nil for every other kind of source.
    public var catalogSyncMarker: ServerCatalogSyncMarker?
    public var lastTelemetry: SourceSyncTelemetry?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceID: String,
        scopeFingerprint: String,
        identityScopeFingerprint: String? = nil,
        cursors: [String: String] = [:],
        index: SourceSyncIndex = SourceSyncIndex(),
        pendingDirectories: [String] = [],
        scanEpoch: Int64 = 0,
        requiresDeepScan: Bool = false,
        lastFullScanAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        identityAliases: [String: String] = [:],
        rootIdentities: [SourceSyncRootIdentity] = [],
        reconciliation: SourceSyncReconciliation? = nil,
        missingStableKeys: [String: Int] = [:],
        missingCatalogSongIDs: [String: Int] = [:],
        deletionEvidenceRevision: String? = nil,
        catalogSyncMarker: ServerCatalogSyncMarker? = nil,
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
        self.missingCatalogSongIDs = missingCatalogSongIDs
        self.deletionEvidenceRevision = deletionEvidenceRevision
        self.catalogSyncMarker = catalogSyncMarker
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
        case missingCatalogSongIDs
        case deletionEvidenceRevision
        case catalogSyncMarker
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
            SourceSyncIndex.self,
            forKey: .index
        ) ?? SourceSyncIndex()
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
        // A reconciliation kind written by a newer build must not invalidate
        // the whole per-source state map: the worst honest outcome is losing
        // one pending notice, not forcing every source into a deep scan.
        reconciliation = try? container.decodeIfPresent(
            SourceSyncReconciliation.self,
            forKey: .reconciliation
        )
        missingStableKeys = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .missingStableKeys
        ) ?? [:]
        missingCatalogSongIDs = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .missingCatalogSongIDs
        ) ?? [:]
        deletionEvidenceRevision = try container.decodeIfPresent(
            String.self,
            forKey: .deletionEvidenceRevision
        )
        // A marker written by a newer build must not invalidate the whole
        // per-source state: losing it only costs one complete walk.
        catalogSyncMarker = try? container.decodeIfPresent(
            ServerCatalogSyncMarker.self,
            forKey: .catalogSyncMarker
        )
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

public extension Dictionary where Key == String, Value == SourceSyncIndexedItem {
    /// Every item inside a folder repeats that folder's path as its
    /// `parentPath`, and a decoded index gives each repetition its own string:
    /// for a server catalogue that is one copy per song (~80 bytes each, about
    /// 37 MB at 450K songs). Points the repetitions — and the folder's own
    /// `path` — at one shared string, and each item's `stableKey` at the
    /// dictionary key it is stored under (decoding gives those two separate
    /// copies as well, another ~37 MB). Values compare equal before and after.
    mutating func shareRepeatedFolderPaths() {
        var paths: [String: String] = [:]
        func shared(_ value: String) -> String {
            // Up to 15 UTF-8 bytes live inside the String itself.
            guard value.utf8.count > 15 else { return value }
            if let existing = paths[value] { return existing }
            paths[value] = value
            return value
        }
        var position = values.startIndex
        while position != values.endIndex {
            let key = keys[position]
            if values[position].stableKey == key {
                values[position].stableKey = key
            }
            if values[position].isDirectory {
                values[position].path = shared(values[position].path)
            }
            if let parent = values[position].parentPath {
                values[position].parentPath = shared(parent)
            }
            values.formIndex(after: &position)
        }
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
        /// A server catalogue lost an unusually large share of its rows in one
        /// pass. Removal is held back until extra witnesses agree.
        case serverCatalogMassDisappearance
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

/// Detects snapshots that cannot describe the provider's folder hierarchy:
/// legacy rows that stored provider item IDs without the corresponding
/// user-facing names, and sources whose committed topology was discarded
/// altogether. Reusing those snapshots for an incremental sync would keep the
/// folder browser permanently unable to reconstruct the hierarchy, so the next
/// scan must perform a complete walk once.
public enum SourceSyncFolderTopologyPolicy {
    public static func requiresRebuild(
        sourceType: MusicSourceType,
        state: SourceSyncState?
    ) -> Bool {
        if sourceType.isServerLibrary || sourceType == .upnp {
            guard let state else { return true }
            return !state.index.values.contains { item in
                item.isDirectory
                    && item.parentPath == nil
                    && item.stableKey.hasPrefix("hierarchy-root:")
            }
        }
        guard usesOpaqueProviderItemIDs(sourceType) else { return false }
        // 这类来源的 `Song.filePath` 是提供方的条目 ID，目录层级只存在于同步
        // 状态的目录行里。任何一次源配置变更都会丢弃整份同步状态，此后文件夹
        // 浏览就只剩一张平铺列表，且没有任何途径能把层级算回来 —— 资料库里
        // 还留着这个来源的歌时，得重走一次目录遍历把拓扑取回来。
        guard let state else { return true }
        // 空索引留给尚未扫描过的来源与原生增量游标：那不是丢失的拓扑，
        // 不值得为它强制一次整库遍历。
        guard !state.index.isEmpty else { return false }
        // 扫描中途失败时会留下一份「只够浏览」的部分层级，连同没走完的目录
        // 队列一起。有了它用户立刻能按文件夹浏览，但层级并不完整，所以仍要
        // 排进自动重建把剩下的目录走完。
        if !state.pendingDirectories.isEmpty { return true }
        return state.index.values.contains { $0.displayName == nil }
    }

    private static func usesOpaqueProviderItemIDs(_ sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .aliyunDrive, .googleDrive, .oneDrive, .drime, .pan115, .pan123, .guangya, .pcloud:
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
    /// A v1 checkpoint may have already skipped artist-image entries in
    /// completed directories. Restart once rather than commit an incomplete
    /// automatic-artwork catalogue.
    public static let currentSchemaVersion = 2
    /// 写进扫描断点时走查进度放在旁边的段文件里(见 `ScanResumeSegmentStore`),
    /// JSON 里只有清单和没封存的尾巴。旧版本读到这个版本号会当成不可用、从选中的
    /// 根目录重新走查,不会拿着半份索引续扫。读回来以后按 `currentSchemaVersion` 算。
    static let segmentedSchemaVersion = 3

    public var schemaVersion: Int
    public var pendingDirectories: [String]
    private var progress: Progress

    /// 走过的条目与歌曲 ID。群晖与电视的扫描器按字典/集合读写(`.plain`);
    /// 通用目录走查用 `SourceScanWalkLog`(`.walk`),每个目录交一次快照不必整份拷贝。
    private enum Progress: Sendable {
        case plain(index: [String: SourceSyncIndexedItem], songIDs: Set<String>)
        case walk(SourceScanWalkLog)
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        pendingDirectories: [String],
        encounteredSongIDs: Set<String> = [],
        index: [String: SourceSyncIndexedItem] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.pendingDirectories = pendingDirectories
        self.progress = .plain(index: index, songIDs: encounteredSongIDs)
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        pendingDirectories: [String],
        walkLog: SourceScanWalkLog
    ) {
        self.schemaVersion = schemaVersion
        self.pendingDirectories = pendingDirectories
        self.progress = .walk(walkLog)
    }

    public var isUsable: Bool {
        schemaVersion == Self.currentSchemaVersion
    }

    /// 走查进度里已封存的段(按字典存着的没有段)。
    var segmentIDs: [UUID] {
        if case .walk(let log) = progress { return log.segments.map(\.id) }
        return []
    }

    /// 走查进度,通用目录走查直接接着记。按字典存着的(群晖、电视、旧测试)现转一份。
    public var walkLog: SourceScanWalkLog {
        get {
            switch progress {
            case .walk(let log):
                return log
            case .plain(let index, let songIDs):
                return SourceScanWalkLog(index: index, songIDs: songIDs)
            }
        }
        set { progress = .walk(newValue) }
    }

    public var encounteredSongIDs: Set<String> {
        get {
            switch progress {
            case .plain(_, let songIDs): return songIDs
            case .walk(let log): return log.songIDSet()
            }
        }
        set {
            let index = takePlainProgress().index
            progress = .plain(index: index, songIDs: newValue)
        }
        _modify {
            let index: [String: SourceSyncIndexedItem]
            var songIDs: Set<String>
            (index, songIDs) = takePlainProgress()
            progress = .plain(index: [:], songIDs: [])
            defer { progress = .plain(index: index, songIDs: songIDs) }
            yield &songIDs
        }
    }

    public var index: [String: SourceSyncIndexedItem] {
        get {
            switch progress {
            case .plain(let index, _): return index
            case .walk(let log): return log.indexDictionary
            }
        }
        set {
            let songIDs = takePlainProgress().songIDs
            progress = .plain(index: newValue, songIDs: songIDs)
        }
        _modify {
            var index: [String: SourceSyncIndexedItem]
            let songIDs: Set<String>
            (index, songIDs) = takePlainProgress()
            // 先放掉自己这份引用,交出去改的那份才是唯一的,不会整份写时复制。
            progress = .plain(index: [:], songIDs: [])
            defer { progress = .plain(index: index, songIDs: songIDs) }
            yield &index
        }
    }

    private func takePlainProgress() -> (index: [String: SourceSyncIndexedItem], songIDs: Set<String>) {
        switch progress {
        case .plain(let index, let songIDs):
            return (index, songIDs)
        case .walk(let log):
            return (log.indexDictionary, log.songIDSet())
        }
    }

    // MARK: Equatable

    public static func == (lhs: SourceScanResumeState, rhs: SourceScanResumeState) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
              lhs.pendingDirectories == rhs.pendingDirectories else { return false }
        switch (lhs.progress, rhs.progress) {
        case let (.plain(lhsIndex, lhsSongs), .plain(rhsIndex, rhsSongs)):
            return lhsSongs == rhsSongs && lhsIndex == rhsIndex
        case let (.walk(lhsLog), .walk(rhsLog)):
            return lhsLog == rhsLog
        default:
            return lhs.walkLog == rhs.walkLog
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pendingDirectories
        case encounteredSongIDs
        case index
        case segments
        case shadowedKeys
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// 走查进度的索引部分按以前字典的 JSON 形状(以条目键为键的对象)编码。
    private struct WalkIndexEncoding: Encodable {
        let log: SourceScanWalkLog
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, item) in log {
                try container.encode(item, forKey: DynamicKey(stringValue: key))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch progress {
        case .plain(let index, let songIDs):
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(pendingDirectories, forKey: .pendingDirectories)
            try container.encode(songIDs, forKey: .encounteredSongIDs)
            try container.encode(index, forKey: .index)
        case .walk(let log):
            if let segmentStore = encoder.userInfo[.scanResumeSegmentStore] as? ScanResumeSegmentStore,
               schemaVersion == Self.currentSchemaVersion,
               !log.segments.isEmpty {
                let manifests = try log.segments.map { try segmentStore.store($0) }
                try container.encode(Self.segmentedSchemaVersion, forKey: .schemaVersion)
                try container.encode(pendingDirectories, forKey: .pendingDirectories)
                try container.encode(manifests, forKey: .segments)
                try container.encode(log.pendingSongIDs, forKey: .encounteredSongIDs)
                try container.encode(log.pendingIndex, forKey: .index)
                if !log.shadowedKeys.isEmpty {
                    try container.encode(log.shadowedKeys.sorted(), forKey: .shadowedKeys)
                }
            } else {
                // 与字典形式的 JSON 完全一样:歌曲 ID 是数组(可能有重复,读成集合时自然去重)。
                try container.encode(schemaVersion, forKey: .schemaVersion)
                try container.encode(pendingDirectories, forKey: .pendingDirectories)
                try container.encode(log.allSongIDs, forKey: .encounteredSongIDs)
                try container.encode(WalkIndexEncoding(log: log), forKey: .index)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pendingDirectories = try container.decode([String].self, forKey: .pendingDirectories)
        // 索引直接解成紧凑形式,歌曲 ID 按数组读,都不经过字典/集合。
        let tail = try container.decode(SourceSyncIndex.self, forKey: .index)
        let tailSongIDs = try container.decode([String].self, forKey: .encounteredSongIDs)
        guard let manifests = try container.decodeIfPresent(
            [ScanResumeSegmentManifest].self,
            forKey: .segments
        ) else {
            schemaVersion = decodedVersion
            progress = .walk(SourceScanWalkLog(index: tail, songIDs: tailSongIDs))
            return
        }
        let shadowed = try container.decodeIfPresent([String].self, forKey: .shadowedKeys) ?? []
        guard decodedVersion == Self.segmentedSchemaVersion,
              let segmentStore = decoder.userInfo[.scanResumeSegmentStore] as? ScanResumeSegmentStore,
              let segments = try? manifests.map({ try segmentStore.load($0) }) else {
            // 段文件缺了或对不上:这份走查进度不能用,按不可用处理(从根目录重新走查),
            // 断点里其余的东西照常保留。
            schemaVersion = -1
            progress = .walk(SourceScanWalkLog())
            return
        }
        schemaVersion = Self.currentSchemaVersion
        progress = .walk(SourceScanWalkLog(
            segments: segments,
            tail: tail,
            tailSongIDs: tailSongIDs,
            shadowedKeys: Set(shadowed)
        ))
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

public enum SourceScanLifecycleCompletion: Sendable, Equatable {
    case committedSnapshot
    case committedNoChanges
    case uncommitted
    case failed
    case cancelled
}

public enum SourceScanLifecyclePolicy {
    public static func shouldNotifySuccessfulScan(
        for completion: SourceScanLifecycleCompletion
    ) -> Bool {
        switch completion {
        case .committedSnapshot, .committedNoChanges:
            true
        case .uncommitted, .failed, .cancelled:
            false
        }
    }
}

/// Background cadence for opted-in provider-native change feeds. Directory
/// walks use the foreground refresh coordinator instead of background wakes.
public enum SourcePeriodicSyncPolicy {
    public static let interval: TimeInterval = 6 * 60 * 60

    /// Only providers with a durable native changes cursor qualify. A provider
    /// that must re-list selected directories is performing a scan even if it
    /// can reconcile the result incrementally afterward.
    public static func supportsAutomaticRefresh(_ sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .dropbox, .googleDrive, .oneDrive:
            true
        default:
            false
        }
    }

    public static func nextSyncDate(
        for state: SourceSyncState,
        interval: SourceAutomaticRefreshInterval = .sixHours,
        now: Date = Date()
    ) -> Date? {
        guard !state.requiresDeepScan, !state.cursors.isEmpty else { return nil }
        let baseline = state.lastSuccessfulSyncAt ?? state.lastFullScanAt ?? now
        return baseline.addingTimeInterval(interval.timeInterval)
    }

    public static func isDue(
        _ state: SourceSyncState,
        interval: SourceAutomaticRefreshInterval = .sixHours,
        now: Date = Date()
    ) -> Bool {
        guard let next = nextSyncDate(for: state, interval: interval, now: now) else { return false }
        return next.timeIntervalSinceReferenceDate <= now.timeIntervalSinceReferenceDate
    }
}

/// Selects opted-in local sources with a root this device can observe.
public enum LocalReferenceRefreshPolicy {
    public static let changeDebounce: TimeInterval = 1.5
    public static let busyRetryDelay: TimeInterval = 2

    public static func monitoredSourceIDs(
        in sources: [MusicSource],
        bookmarkedSourceIDs: Set<String>,
        additionalRootSourceIDs: Set<String> = [],
        automaticRefreshEnabledSourceIDs: Set<String>
    ) -> Set<String> {
        Set(sources.lazy.compactMap { source in
            guard source.type == .local,
                  source.isEnabled,
                  !source.isDeleted,
                  automaticRefreshEnabledSourceIDs.contains(source.id),
                  bookmarkedSourceIDs.contains(source.id) || additionalRootSourceIDs.contains(source.id) else {
                return nil
            }
            return source.id
        })
    }
}

// MARK: - Folder cover names

/// Which picture in a folder stands for everything in it (an album, a book).
/// After the fixed names (`PrimuseConstants.folderCoverNames`: cover, folder…)
/// come a picture named after the folder itself (`书名/书名.jpg`) and then one
/// named after the album or book title. Names compare loosely: case, full-width
/// characters and runs of spaces don't matter.
public enum FolderCoverNamePolicy {
    /// Broad library roots: a picture lying there is not every song's cover.
    public static let genericDirectoryNames: Set<String> = [
        "music", "\u{97F3}\u{4E50}", "songs", "audio", "media", "downloads",
    ]

    /// Characters a file name can't hold on common file systems; a title that
    /// carries them is saved with them swapped out or dropped.
    private static let fileNameIllegalCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")

    public static func isGenericDirectory(named name: String) -> Bool {
        genericDirectoryNames.contains(comparableName(name))
    }

    /// The form two names are compared in: compatibility-normalized (full-width
    /// letters and the ideographic space become their plain forms), lower-cased,
    /// whitespace runs collapsed, ends trimmed.
    public static func comparableName(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The names (without extension) a picture may carry to stand for the
    /// folder beyond the fixed ones, most specific first, in comparable form:
    /// the folder's own name (not for a broad library root), then the title as
    /// written and with the characters a file name can't hold swapped for `_`
    /// or dropped.
    public static func namedStems(folderName: String?, albumTitle: String?) -> [String] {
        probeStems(folderName: folderName, albumTitle: albumTitle).reduce(into: [String]()) { stems, stem in
            let comparable = comparableName(stem)
            if !comparable.isEmpty, !stems.contains(comparable) { stems.append(comparable) }
        }
    }

    /// The same names as written, for a folder that can only be probed name by
    /// name (a local disk, where names are case-sensitive).
    public static func probeStems(folderName: String?, albumTitle: String?) -> [String] {
        var stems: [String] = []
        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !PrimuseConstants.folderCoverNames.contains(comparableName(trimmed)),
                  !stems.contains(trimmed) else { return }
            stems.append(trimmed)
        }
        if let folderName {
            let decoded = folderName.contains("%") ? folderName.removingPercentEncoding : nil
            for name in [folderName, decoded].compactMap({ $0 }) where !isGenericDirectory(named: name) {
                add(name)
            }
        }
        if let albumTitle {
            if albumTitle.rangeOfCharacter(from: fileNameIllegalCharacters) == nil {
                add(albumTitle)
            } else {
                add(albumTitle.components(separatedBy: fileNameIllegalCharacters).joined(separator: "_"))
                add(albumTitle.components(separatedBy: fileNameIllegalCharacters).joined())
            }
        }
        return stems
    }

    /// Of the file names in a folder, the picture named after the folder or the
    /// title (`namedStems`), preferring the earlier name and then the cover
    /// extensions in their usual order. Nil when there is none.
    public static func namedCover(
        among fileNames: [String],
        folderName: String?,
        albumTitle: String? = nil
    ) -> String? {
        let stems = namedStems(folderName: folderName, albumTitle: albumTitle)
        guard !stems.isEmpty else { return nil }
        var best: (stemRank: Int, extensionRank: Int, name: String)?
        for name in fileNames {
            let file = name as NSString
            guard let extensionRank = PrimuseConstants.supportedCoverExtensions
                    .firstIndex(of: file.pathExtension.lowercased()),
                  let stemRank = stems.firstIndex(of: comparableName(file.deletingPathExtension))
            else { continue }
            if let current = best,
               (current.stemRank, current.extensionRank) <= (stemRank, extensionRank) { continue }
            best = (stemRank, extensionRank, name)
        }
        return best?.name
    }
}

// MARK: - Directory sidecar indexing

/// The minimal directory-entry surface needed to resolve covers, lyrics,
/// music videos and CUE dependencies without coupling PrimuseKit to a specific
/// cloud connector model.
public protocol SidecarDirectoryItem: Sendable {
    var sidecarName: String { get }
    var sidecarPath: String { get }
    var sidecarIsDirectory: Bool { get }
    var sidecarSize: Int64 { get }
    var sidecarModifiedDate: Date? { get }
    var sidecarRevision: String? { get }
    var sidecarProviderID: String? { get }
}

extension SidecarDirectoryItem {
    /// 这张图的版本签名(`SidecarCoverRevisionTracker`):内容换了它就变。
    public var sidecarRevisionSignature: String {
        SidecarCoverRevisionTracker.signature(
            providerID: sidecarProviderID,
            revision: sidecarRevision,
            size: sidecarSize,
            modifiedDate: sidecarModifiedDate
        )
    }
}

/// Immutable per-directory lookup data. It is built once per sibling listing;
/// every song in that directory then performs only a bounded number of
/// dictionary/set lookups instead of repeatedly filtering and scanning the
/// entire listing.
public struct SidecarDirectoryIndex<Item: SidecarDirectoryItem>: Sendable {
    private struct IndexedItem: Sendable {
        var item: Item
        var offset: Int
    }

    /// A language-tagged subtitle carries its tag with it: re-deriving it per
    /// song would run the tag check again for every song in the directory.
    private struct TaggedItem: Sendable {
        var item: Item
        var tag: String
        var stem: String
    }

    private let firstItemByLowercasedName: [String: IndexedItem]
    /// The directory's own name, read off the entries' paths, for a picture
    /// named after it (`FolderCoverNamePolicy`). Nil when the paths are opaque
    /// item IDs: every lookup of the same listing then agrees on the cover.
    private let folderName: String?
    /// Every picture in the directory, by file name, for the named-cover lookup.
    private let imageNames: [String]
    /// The picture named after the directory itself, worked out once.
    private let folderNamedCoverName: String?
    private var firstItemByPath: [String: Item]
    /// 分碟子文件夹自己没有封面图时,上一层专辑文件夹的那张(`inheriting(folderCover:)`)。
    private var inheritedFolderCover: Item?
    private let audioBasenames: Set<String>
    private let languageTaggedLyricsByBasename: [String: [TaggedItem]]
    private let preferredLanguages: [String]
    private let cueFingerprint: String?
    /// Lyric documents that are nobody's same-name sidecar: the only files a
    /// CUE virtual track can claim as its own (`CueTrackLyricsSidecarPolicy`).
    private let cueTrackLyricsCandidates: [Item]

    public let itemCount: Int
    /// One digest over every CUE per-track lyric candidate in the directory.
    /// Nil when there are none, so a directory without such files keeps the
    /// exact fingerprint it had before per-track lyrics were recognized.
    public let cueTrackLyricsFingerprint: String?

    public init(_ items: [Item], preferredLanguages: [String] = Locale.preferredLanguages) {
        var firstItemByLowercasedName: [String: IndexedItem] = [:]
        var imageNames: [String] = []
        var parentPaths: Set<String> = []
        var firstItemByPath: [String: Item] = [:]
        var audioBasenames: Set<String> = []
        var languageTaggedLyricsByBasename: [String: [TaggedItem]] = [:]
        var cuePaths: Set<String> = []
        var fileItems: [Item] = []

        firstItemByLowercasedName.reserveCapacity(items.count)
        firstItemByPath.reserveCapacity(items.count)

        for (offset, item) in items.enumerated() {
            if firstItemByPath[item.sidecarPath] == nil {
                firstItemByPath[item.sidecarPath] = item
            }
            guard !item.sidecarIsDirectory else { continue }
            fileItems.append(item)
            if parentPaths.count < 2 {
                parentPaths.insert((item.sidecarPath as NSString).deletingLastPathComponent)
            }

            let lowercasedName = item.sidecarName.lowercased()
            if firstItemByLowercasedName[lowercasedName] == nil {
                firstItemByLowercasedName[lowercasedName] = IndexedItem(
                    item: item,
                    offset: offset
                )
            }

            let fileName = item.sidecarName as NSString
            let fileExtension = fileName.pathExtension.lowercased()
            if PrimuseConstants.supportedAudioExtensions.contains(fileExtension)
                || PrimuseConstants.supportedStreamDescriptorExtensions.contains(fileExtension) {
                audioBasenames.insert(fileName.deletingPathExtension.lowercased())
            }
            if PrimuseConstants.supportedCueSheetExtensions.contains(fileExtension) {
                cuePaths.insert(item.sidecarPath)
            }
            if PrimuseConstants.supportedCoverExtensions.contains(fileExtension) {
                imageNames.append(item.sidecarName)
            }
            // Only the two subtitle extensions can carry a language suffix, so
            // this costs one set lookup for everything else in the directory.
            if LyricsSidecarSelectionPolicy.languageTaggedExtensions.contains(fileExtension),
               let components = LyricsSidecarSelectionPolicy
                .languageTaggedComponents(ofSidecarNamed: item.sidecarName) {
                languageTaggedLyricsByBasename[components.baseName.lowercased(), default: []]
                    .append(
                        TaggedItem(
                            item: item,
                            tag: components.tag,
                            stem: fileName.deletingPathExtension.lowercased()
                        )
                    )
            }
        }

        self.firstItemByLowercasedName = firstItemByLowercasedName
        self.imageNames = imageNames
        var resolvedFolderName: String?
        if parentPaths.count == 1, let parent = parentPaths.first, !parent.isEmpty {
            let name = (parent as NSString).lastPathComponent
            resolvedFolderName = name.isEmpty || name == "/" ? nil : name
        }
        self.folderName = resolvedFolderName
        folderNamedCoverName = imageNames.isEmpty ? nil : FolderCoverNamePolicy.namedCover(
            among: imageNames,
            folderName: resolvedFolderName
        )
        self.firstItemByPath = firstItemByPath
        inheritedFolderCover = nil
        self.audioBasenames = audioBasenames
        self.languageTaggedLyricsByBasename = languageTaggedLyricsByBasename
        self.preferredLanguages = preferredLanguages
        itemCount = items.count

        let cueComponents = cuePaths.sorted().map { path in
            Self.fingerprintComponent(
                for: path,
                item: firstItemByPath[path]
            )
        }
        if cueComponents.isEmpty {
            cueFingerprint = nil
        } else {
            let digest = SHA256.hash(
                data: Data(cueComponents.joined(separator: "\u{1E}").utf8)
            )
            cueFingerprint = digest.map { String(format: "%02x", $0) }.joined()
        }

        // Only directories that hold a CUE sheet can have per-track lyrics;
        // every other directory skips the name analysis entirely.
        let trackLyricsCandidates = cuePaths.isEmpty
            ? []
            : CueTrackLyricsSidecarPolicy
                .candidateIndices(in: fileItems.map(\.sidecarName))
                .map { fileItems[$0] }
        cueTrackLyricsCandidates = trackLyricsCandidates
        if trackLyricsCandidates.isEmpty {
            cueTrackLyricsFingerprint = nil
        } else {
            let components = trackLyricsCandidates
                .map { Self.fingerprintComponent(for: $0.sidecarPath, item: $0) }
                .sorted()
            let digest = SHA256.hash(
                data: Data(components.joined(separator: "\u{1E}").utf8)
            )
            cueTrackLyricsFingerprint = digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    public func item(atPath path: String) -> Item? {
        firstItemByPath[path]
    }

    /// 这个目录自己没有封面图时,把 `cover`(上一层专辑文件夹的封面)当作它的文件夹封面。
    /// 指纹和按路径取项都认得它,所以那张图换了,这个目录里的歌照样会重读。
    public func inheriting(folderCover cover: Item?) -> Self {
        guard let cover, folderCover() == nil else { return self }
        var copy = self
        copy.inheritedFolderCover = cover
        if copy.firstItemByPath[cover.sidecarPath] == nil {
            copy.firstItemByPath[cover.sidecarPath] = cover
        }
        return copy
    }

    /// Each CUE virtual track's own lyric document in this directory, keyed by
    /// track number. Tracks without one are absent; the caller falls back to
    /// the album-level `sameNameLyrics(basename:)` of the audio image.
    public func cueTrackLyrics(
        tracks: [CueTrackLyricsSidecarPolicy.Track],
        audioBasename: String,
        cueBasename: String?,
        cueImageCount: Int
    ) -> [Int: Item] {
        guard !cueTrackLyricsCandidates.isEmpty, !tracks.isEmpty else { return [:] }
        let assignments = CueTrackLyricsSidecarPolicy.assignments(
            tracks: tracks,
            audioBaseName: audioBasename,
            cueBaseName: cueBasename,
            candidateNames: cueTrackLyricsCandidates.map(\.sidecarName),
            cueImageCount: cueImageCount,
            preferredLanguages: preferredLanguages
        )
        return assignments.mapValues { cueTrackLyricsCandidates[$0] }
    }

    public func containsAudioOrStream(basename: String) -> Bool {
        audioBasenames.contains(basename.lowercased())
    }

    public func sameNameCover(basename: String) -> Item? {
        let base = basename.lowercased()
        for fileExtension in PrimuseConstants.supportedCoverExtensions {
            let exact = firstItemByLowercasedName["\(base).\(fileExtension)"]
            let suffixed = firstItemByLowercasedName["\(base)-cover.\(fileExtension)"]
            switch (exact, suffixed) {
            case let (exact?, suffixed?):
                // Preserve the old `first(where:)` result when both forms are
                // present with the same preferred extension.
                return exact.offset < suffixed.offset ? exact.item : suffixed.item
            case let (exact?, nil):
                return exact.item
            case let (nil, suffixed?):
                return suffixed.item
            case (nil, nil):
                continue
            }
        }
        return nil
    }

    /// The picture standing for the whole directory: one of the fixed names
    /// (cover, folder…), else one named after the directory itself, else the
    /// album folder's one for a disc subfolder (`inheriting(folderCover:)`).
    public func folderCover() -> Item? {
        for name in PrimuseConstants.folderCoverNames {
            for fileExtension in PrimuseConstants.supportedCoverExtensions {
                if let match = firstItemByLowercasedName["\(name).\(fileExtension)"] {
                    return match.item
                }
            }
        }
        return namedFolderCover() ?? inheritedFolderCover
    }

    /// A picture named after the directory or, when given, the album or book
    /// title (`FolderCoverNamePolicy`).
    public func namedFolderCover(albumTitle: String? = nil) -> Item? {
        let name: String?
        if albumTitle == nil {
            name = folderNamedCoverName
        } else if imageNames.isEmpty {
            name = nil
        } else {
            name = FolderCoverNamePolicy.namedCover(
                among: imageNames,
                folderName: folderName,
                albumTitle: albumTitle
            )
        }
        guard let name else { return nil }
        return firstItemByLowercasedName[name.lowercased()]?.item
    }

    public func sameNameLyrics(basename: String) -> Item? {
        let base = basename.lowercased()
        for fileExtension in PrimuseConstants.readableLyricsExtensions {
            if let match = firstItemByLowercasedName["\(base).\(fileExtension)"] {
                return match.item
            }
        }
        // Nothing carries the song's exact name, so the subtitle ecosystem's
        // `<base>.<lang>.vtt` naming is consulted — that is what yt-dlp writes
        // and what media-server users name their external subtitles.
        guard let tagged = languageTaggedLyricsByBasename[base] else { return nil }
        // `Track.it.vtt` beside `Track.it.flac` is that song's own exact-name
        // sidecar, not the Italian subtitle of `Track.flac`.
        let usable = tagged.filter { !audioBasenames.contains($0.stem) }
        guard let choice = LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: usable.map(\.tag),
            preferredLanguages: preferredLanguages
        ) else { return nil }
        return usable[choice].item
    }

    public func chineseLRCTranslation(forPrimary name: String) -> Item? {
        guard let companion = LyricsSidecarSelectionPolicy.chineseLRCName(forPrimary: name),
              !audioBasenames.contains((companion as NSString).deletingPathExtension.lowercased()) else { return nil }
        return firstItemByLowercasedName[companion.lowercased()]?.item
    }

    public func sameNameMusicVideo(basename: String) -> Item? {
        let base = basename.lowercased()
        for fileExtension in PrimuseConstants.supportedMusicVideoExtensions {
            if let match = firstItemByLowercasedName["\(base).\(fileExtension)"] {
                return match.item
            }
        }
        return nil
    }

    /// Selected sidecars retain the legacy component format. CUE entries are
    /// represented by one fixed-size digest shared by every song in the
    /// directory, so a CUE edit still invalidates all virtual tracks without
    /// re-concatenating every CUE component for every audio file.
    /// `includingCueTrackLyrics` is for CUE images and their virtual tracks:
    /// adding, editing or removing a per-track lyric file then invalidates
    /// them, while every other song keeps its previous fingerprint.
    public func snapshotFingerprint(
        selectedPaths: [String?],
        includingCueTrackLyrics: Bool = false
    ) -> String? {
        var paths = Set(selectedPaths.compactMap { $0 })
        for path in selectedPaths.compactMap({ $0 }) {
            if let item = firstItemByPath[path], let companion = chineseLRCTranslation(forPrimary: item.sidecarName) {
                paths.insert(companion.sidecarPath)
            }
        }
        var components = paths.sorted().map { path in
            Self.fingerprintComponent(
                for: path,
                item: firstItemByPath[path]
            )
        }
        if let cueFingerprint {
            components.append("cue-sha256-v2\u{1F}\(cueFingerprint)")
        }
        if includingCueTrackLyrics, let cueTrackLyricsFingerprint {
            components.append("cue-lyrics-sha256-v1\u{1F}\(cueTrackLyricsFingerprint)")
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "\u{1E}")
    }

    private static func fingerprintComponent(for path: String, item: Item?) -> String {
        guard let item else { return "missing\u{1F}\(path)" }
        return [
            item.sidecarProviderID ?? "path:\(path.lowercased())",
            path,
            item.sidecarRevision ?? "",
            String(item.sidecarSize),
            item.sidecarModifiedDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
        ].joined(separator: "\u{1F}")
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
    public var reconciledIndex: SourceSyncIndex
    public var changedParentPaths: Set<String>
    public var deletedStableKeys: Set<String>
    public var identityAliases: [String: String]
    public var missingStableKeys: [String: Int]
    public var reconciliation: SourceSyncReconciliation?

    public init(
        reconciledIndex: SourceSyncIndex,
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

    /// 上一份索引里的 `path:` 旧键条目。只在有条目需要按内容指纹认领时才用到。
    public typealias LegacyEntries = [(key: String, value: SourceSyncIndexedItem)]

    public static func legacyEntries<Index: SourceSyncIndexReading>(in index: Index) -> LegacyEntries {
        index.filter { $0.key.hasPrefix("path:") }
    }

    /// 已提交的索引直接以紧凑形式传进来,结果也是紧凑索引:对账结果就是这一轮快照里的
    /// 条目(沿用认领到的旧条目的歌曲 ID),加上旧索引里既没被认领、这轮也没出现、
    /// 又带着歌曲 ID 的条目(等第二次确认或交给扫描器删除)。与在旧索引的字典副本上
    /// 逐条改写的结果相同,只是不必把旧索引展开成字典。
    public static func plan(
        previousIndex: SourceSyncIndex,
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

        var reconciledCurrent: [(key: String, item: SourceSyncIndexedItem)] = []
        reconciledCurrent.reserveCapacity(currentByKey.count)
        var changedParents: Set<String> = []
        var deletedKeys: Set<String> = []
        var aliases = identityAliases
        var nextMissing = missingStableKeys
        var claimedPreviousKeys: Set<String> = []

        // 旧键条目与同路径替换的候选表都按需建一次:它们只取决于旧索引与这轮快照。
        var cachedLegacyEntries: LegacyEntries?
        func legacy() -> LegacyEntries {
            if let cachedLegacyEntries { return cachedLegacyEntries }
            let entries = legacyEntries(in: previousIndex)
            cachedLegacyEntries = entries
            return entries
        }
        var replacementCandidates: ReplacementCandidates?
        func candidates() -> ReplacementCandidates {
            if let replacementCandidates { return replacementCandidates }
            let built = ReplacementCandidates(previousIndex: previousIndex, currentByKey: currentByKey)
            replacementCandidates = built
            return built
        }

        for currentValue in currentByKey.values.sorted(by: { $0.stableKey < $1.stableKey }) {
            let match = migrationMatch(
                for: currentValue,
                previousIndex: previousIndex,
                legacyEntries: legacy(),
                aliases: aliases,
                claimedPreviousKeys: claimedPreviousKeys
            ) ?? exactStrongIdentityReplacementMatch(
                for: currentValue,
                previousIndex: previousIndex,
                candidates: candidates(),
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
                    if BaiduSnapshotIdentity.fsID(from: match.key) != nil {
                        insertLiveParent(
                            match.item.parentPath,
                            into: &changedParents,
                            live: liveDirectories
                        )
                        insertLiveParent(
                            current.parentPath,
                            into: &changedParents,
                            live: liveDirectories
                        )
                    }
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
            // 字典赋值会沿用已有那个键的写法。
            reconciledCurrent.append((previousIndex.storedKey(matching: current.stableKey) ?? current.stableKey, current))
        }

        var unresolved: Set<String> = []
        var retainedPrevious: [String] = []
        // 每个旧键各自处理、互不影响,遍历顺序无关;只取键,用到时才建条目。
        for key in previousIndex.keys {
            if claimedPreviousKeys.contains(key) || currentByKey[key] != nil {
                continue
            }
            guard let previous = previousIndex[key] else { continue }

            // Rows without a Song ID — directories (whose children are keyed
            // independently) and the artist-image files indexed for automatic
            // artist artwork — carry no user-owned identity. They are dropped
            // immediately without risking playlists or history, and never
            // held behind the song-deletion confirmation. A vanished image
            // re-lists its parent so the artwork catalogue follows.
            if previous.songIDs.isEmpty {
                nextMissing[key] = nil
                if !previous.isDirectory {
                    insertLiveParent(previous.parentPath, into: &changedParents, live: liveDirectories)
                }
                continue
            }

            retainedPrevious.append(key)
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

        var builder = SourceSyncIndex.Builder(minimumCapacity: reconciledCurrent.count + retainedPrevious.count)
        for key in retainedPrevious {
            if let previous = previousIndex[key] { builder.insert(previous, forKey: key) }
        }
        for (key, item) in reconciledCurrent {
            builder.insert(item, forKey: key)
        }

        let reconciliation = unresolved.isEmpty ? nil : SourceSyncReconciliation(
            kind: .baiduIdentityAndDeletionConfirmation,
            unresolvedStableKeys: Array(unresolved),
            detectedAt: now
        )
        return BaiduSnapshotDiffResult(
            reconciledIndex: builder.build(),
            changedParentPaths: changedParents,
            deletedStableKeys: deletedKeys,
            identityAliases: aliases,
            missingStableKeys: nextMissing,
            reconciliation: reconciliation
        )
    }

    /// Used by a user-selected deep scan that encounters a path-keyed legacy
    /// index before the first snapshot migration has completed.
    public static func migrationMatch<Index: SourceSyncIndexReading>(
        for current: SourceSyncIndexedItem,
        previousIndex: Index,
        claimedPreviousKeys: Set<String> = []
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        migrationMatch(
            for: current,
            previousIndex: previousIndex,
            legacyEntries: legacyEntries(in: previousIndex),
            aliases: [:],
            claimedPreviousKeys: claimedPreviousKeys
        )
    }

    /// 同上,旧键条目由调用方缓存(上一份索引在整次走查里不变)。
    public static func migrationMatch<Index: SourceSyncIndexReading>(
        for current: SourceSyncIndexedItem,
        previousIndex: Index,
        cachedLegacyEntries: () -> LegacyEntries,
        claimedPreviousKeys: Set<String> = []
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        migrationMatch(
            for: current,
            previousIndex: previousIndex,
            legacyEntries: cachedLegacyEntries(),
            aliases: [:],
            claimedPreviousKeys: claimedPreviousKeys
        )
    }

    private static func migrationMatch<Index: SourceSyncIndexReading>(
        for current: SourceSyncIndexedItem,
        previousIndex: Index,
        legacyEntries: @autoclosure () -> LegacyEntries,
        aliases: [String: String],
        claimedPreviousKeys: Set<String>
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        if let direct = previousIndex.item(forKey: current.stableKey),
           !claimedPreviousKeys.contains(current.stableKey) {
            return (current.stableKey, direct)
        }

        let exactPathKey = BaiduSnapshotIdentity.legacyPathKey(current.path)
        if let exact = previousIndex.item(forKey: exactPathKey),
           exact.path == current.path,
           !claimedPreviousKeys.contains(exactPathKey) {
            return (exactPathKey, exact)
        }

        if let aliasedKey = aliases.first(where: { $0.value == current.stableKey })?.key,
           let aliased = previousIndex.item(forKey: aliasedKey),
           !claimedPreviousKeys.contains(aliasedKey) {
            return (aliasedKey, aliased)
        }

        guard !current.isDirectory,
              let revision = normalizedRevision(current.revision) else {
            return nil
        }
        let candidates = legacyEntries().filter { key, item in
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

    /// 同路径替换认领要用到的两张表,一轮对账只建一次:这轮快照里每个文件路径出现了几次,
    /// 以及旧索引里这轮已经不在的、带歌曲 ID 的 fs_id 文件条目按路径分组的键。
    private struct ReplacementCandidates {
        var livePathCounts: [String: Int] = [:]
        var vanishedKeysByPath: [String: [String]] = [:]

        init(previousIndex: SourceSyncIndex, currentByKey: [String: SourceSyncIndexedItem]) {
            for item in currentByKey.values where !item.isDirectory {
                livePathCounts[item.path, default: 0] += 1
            }
            for key in previousIndex.keys
            where BaiduSnapshotIdentity.fsID(from: key) != nil && currentByKey[key] == nil {
                guard let item = previousIndex[key], !item.isDirectory, !item.songIDs.isEmpty else { continue }
                vanishedKeysByPath[item.path, default: []].append(key)
            }
        }
    }

    /// Baidu can replace a file in place and assign it a new fs_id. A complete
    /// snapshot proves that the old identity disappeared globally, so an
    /// otherwise unique file at the exact same path can inherit the existing
    /// Song ID. Ambiguous paths and directories remain fail-closed.
    private static func exactStrongIdentityReplacementMatch(
        for current: SourceSyncIndexedItem,
        previousIndex: SourceSyncIndex,
        candidates: @autoclosure () -> ReplacementCandidates,
        claimedPreviousKeys: Set<String>
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        guard !current.isDirectory,
              BaiduSnapshotIdentity.fsID(from: current.stableKey) != nil else {
            return nil
        }
        let tables = candidates()
        guard tables.livePathCounts[current.path] == 1 else { return nil }
        // 候选键已经排除了这轮快照里还在的键(当前条目自己的键也在其中)。
        let keys = (tables.vanishedKeysByPath[current.path] ?? []).filter {
            !claimedPreviousKeys.contains($0)
        }
        guard keys.count == 1, let key = keys.first, let item = previousIndex[key] else {
            return nil
        }
        return (key, item)
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

public enum BaiduSnapshotMissingDirectoryDisposition: Sendable, Equatable {
    case requiresRootReselection
    case discardStaleDescendant
}

public enum BaiduSnapshotMissingDirectoryPolicy {
    /// A selected root disappearing invalidates the user's configured scope.
    /// Descendants can legitimately disappear between the parent listing and
    /// their own paged listing, so they must not restart the whole snapshot.
    public static func disposition(
        missingDirectory: String,
        roots: [String]
    ) -> BaiduSnapshotMissingDirectoryDisposition {
        BaiduSnapshotRootPolicy.normalizedRoots(roots).contains(missingDirectory)
            ? .requiresRootReselection
            : .discardStaleDescendant
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
    /// Stable work estimate captured from the last committed index. A snapshot
    /// discovers new subdirectories lazily, so `visited + pending` alone is a
    /// moving, directory-only denominator and cannot represent whole-sync
    /// progress across relaunches.
    public var estimatedTotalCount: Int?
    public var createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        baselineScanEpoch: Int64,
        roots: [String],
        pendingDirectories: [String]? = nil,
        visitedDirectories: Set<String> = [],
        liveDirectories: Set<String>? = nil,
        snapshot: [String: SourceSyncIndexedItem] = [:],
        estimatedTotalCount: Int? = nil,
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
        self.estimatedTotalCount = estimatedTotalCount
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

public struct BaiduSnapshotProgress: Sendable, Equatable {
    public var completedCount: Int
    public var totalCount: Int

    public init(completedCount: Int, totalCount: Int) {
        self.completedCount = completedCount
        self.totalCount = totalCount
    }
}

public enum BaiduSnapshotProgressPolicy {
    /// One unit represents either a scannable file or one directory listing.
    /// Mature indexes contain both; legacy indexes still provide a useful file
    /// baseline, with selected roots accounting for the first listings.
    public static func estimatedTotalCount(
        previousIndex: some SourceSyncIndexContents,
        roots: [String]
    ) -> Int {
        previousIndex.count + BaiduSnapshotRootPolicy.normalizedRoots(roots).count
    }

    public static func progress(
        for state: BaiduSnapshotResumeState
    ) -> BaiduSnapshotProgress {
        let completedFiles = state.snapshot.values.lazy.filter { !$0.isDirectory }.count
        let rawCompleted = state.visitedDirectories.count + completedFiles
        let discoveredTotal = rawCompleted + state.pendingDirectories.count
        let total = max(state.estimatedTotalCount ?? 0, discoveredTotal)
        // When the queue is empty, missing entries from the previous snapshot
        // have also been checked. Count those expected units as completed so a
        // deletion-only refresh reaches the end instead of stopping below 100%.
        let completed = state.pendingDirectories.isEmpty
            ? total
            : min(rawCompleted, total)
        return BaiduSnapshotProgress(
            completedCount: completed,
            totalCount: total
        )
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

    /// Reconciliation runs only while a foreground scan remains alive and is
    /// cancelled by the app lifecycle. It must be allowed to finish in one
    /// pass because its partially rebuilt song/index result is not committed.
    public static let uninterruptedReconciliation = BaiduSnapshotRefreshBudget(
        maximumRequests: .max,
        maximumDirectories: .max,
        maximumDuration: .greatestFiniteMagnitude
    )
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

public enum BaiduSnapshotExecutionPolicy {
    /// Give the foreground scene time to finish layout, audio-session and
    /// navigation restoration before an interrupted tree snapshot resumes.
    public static let foregroundResumeDelay: TimeInterval = 2

    /// Automatic foreground work is deliberately a short durable slice. A
    /// user-initiated refresh may keep taking normal slices until it finishes;
    /// automatic work resumes from its checkpoint on a later activation.
    public static func refreshBudget(
        for context: BaiduSnapshotExecutionContext
    ) -> BaiduSnapshotRefreshBudget {
        switch context {
        case .userInitiatedForeground:
            BaiduSnapshotRefreshBudget()
        case .foregroundResume, .background:
            BaiduSnapshotRefreshBudget(
                maximumRequests: 64,
                maximumDirectories: 32,
                maximumDuration: 8
            )
        }
    }

    public static func shouldContinueImmediately(
        context: BaiduSnapshotExecutionContext
    ) -> Bool {
        context == .userInitiatedForeground
    }
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
    ) -> SourceSyncIndex {
        guard let state, state.matchesScope(
            sourceID: sourceID,
            scopeFingerprint: scopeFingerprint
        ) else {
            return SourceSyncIndex()
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
        currentSize: Int64,
        serverRekeyedSameObject: Bool = false
    ) -> SourceStableCacheTransitionDecision {
        guard previousPath != currentPath else { return .none }
        // The server only re-encoded the object's id (Navidrome 0.64); the
        // file itself was not touched. Catalogues without a content revision
        // still have to agree on the size.
        if serverRekeyedSameObject {
            return previousSize > 0 && previousSize == currentSize ? .migrate : .invalidate
        }
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

/// 只重扫一个文件夹时，在扫描索引里找这棵子树。索引里的 `path` / `parentPath` 是连接器
/// 列目录用的原始写法（路径型源是路径，ID 寻址网盘是条目 id），资料库「文件夹」页的节点
/// 用的是归一化后的身份路径，两者对不上，所以从文件夹里的一首歌出发沿父目录往上走。
public enum SourceSyncSubtreePolicy {
    /// Intersect a path-based folder request with the configured scan roots.
    /// An ancestor request must never expand the source's selected scope.
    public static func scopedPathRoots(_ requested: String, selectedRoots: [String]) -> Set<String> {
        func valid(_ path: String) -> String? {
            guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            return comparisonKey(path)
        }
        guard let requested = valid(requested) else { return [] }
        func contains(_ root: String, _ path: String) -> Bool {
            root == "/" || path == root || path.hasPrefix(root + "/")
        }
        return Set(selectedRoots.compactMap { root in
            guard let root = valid(root) else { return nil }
            if contains(root, requested) { return requested }
            if contains(requested, root) { return root }
            return nil
        })
    }

    /// Legacy Baidu rows retain full file paths even when their directory index
    /// is absent. Reconstruct only ancestry, without claiming a fresh listing.
    public static func restoringPathAncestors<Index: SourceSyncIndexContents>(
        in index: Index, selectedRoots: [String]
    ) -> Index {
        var result = index
        var known = Set(index.values.filter(\.isDirectory).map(\.path))
        let roots = Set(selectedRoots.map(comparisonKey))
        for entry in index.values {
            guard entry.path.hasPrefix("/") else { continue }
            var path = entry.parentPath ?? (entry.path as NSString).deletingLastPathComponent
            while path != "/", !path.isEmpty,
                  !roots.contains(path),
                  scopedPathRoots(path, selectedRoots: selectedRoots) == [path],
                  known.insert(path).inserted {
                let parent = (path as NSString).deletingLastPathComponent
                var key = BaiduSnapshotIdentity.legacyPathKey(path)
                if result[key] != nil { key += "#directory:\(path)" }
                result[key] = SourceSyncIndexedItem(
                    stableKey: key, path: path, parentPath: parent, isDirectory: true,
                    songIDs: [], size: 0, modifiedDate: nil, revision: nil, seenEpoch: entry.seenEpoch
                )
                path = parent
            }
        }
        return result
    }

    /// 这首歌所在目录再往上 `levelsAbove` 层的原始目录。走到索引里没有的目录就答 nil
    /// （扫描根本身不在索引里，只能作为最后一层的结果出现）。
    public static func directory(
        containingSongID songID: String,
        levelsAbove: Int,
        in index: some SourceSyncIndexContents
    ) -> String? {
        guard levelsAbove >= 0,
              let entry = index.values.first(where: { !$0.isDirectory && $0.songIDs.contains(songID) }),
              var directory = entry.parentPath, !directory.isEmpty else { return nil }
        guard levelsAbove > 0 else { return directory }
        let directoriesByPath = Dictionary(
            index.values.filter(\.isDirectory).map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for _ in 0..<levelsAbove {
            guard let folder = directoriesByPath[directory],
                  let parent = folder.parentPath, !parent.isEmpty,
                  parent != directory else { return nil }
            directory = parent
        }
        return directory
    }

    /// The first breadcrumb is the requested folder. Its ancestors establish coverage
    /// for ID-addressed providers, but must never become scan targets themselves.
    public static func directoryRoots(
        candidates: [String], selectedRoots: [String], sourceType: MusicSourceType
    ) -> Set<String> {
        guard let requested = candidates.first,
              !requested.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return [] }
        let ancestors = sourceType.usesOpaqueDirectoryIdentifiers ? Array(candidates.dropFirst().reversed()) : []
        let selection = SourceDirectorySelectionPolicy.selectionState(
            of: requested, in: selectedRoots, ancestors: ancestors, for: sourceType
        )
        switch selection {
        case .selected, .included:
            return [scanDirectory(requested, sourceType: sourceType)]
        case .unselected:
            return Set(selectedRoots.filter {
                SourceDirectorySelectionPolicy.covers(requested, $0, for: sourceType)
            }.map { scanDirectory($0, sourceType: sourceType) })
        }
    }

    public static func scanDirectory(_ path: String, sourceType: MusicSourceType) -> String {
        let path = sourceType.usesOpaqueDirectoryIdentifiers ? path : comparisonKey(path)
        return SourceDirectorySelectionPolicy.connectorPath(for: sourceType, browserPath: path)
    }

    private static func comparisonKey(_ path: String) -> String {
        var key = Substring(path)
        while key.count > 1, key.hasSuffix("/") { key = key.dropLast() }
        return String(key)
    }

    /// `root` 与索引里已知的、在它下面的全部目录（按父目录链判定，不比较路径前缀）。
    public static func knownDirectories(
        under root: String,
        in index: some SourceSyncIndexContents
    ) -> Set<String> {
        var childDirectories: [String: [String]] = [:]
        for entry in index.values where entry.isDirectory {
            guard let parent = entry.parentPath else { continue }
            childDirectories[parent, default: []].append(entry.path)
        }
        var result: Set<String> = [root]
        var pending = [root]
        while let current = pending.popLast() {
            for child in childDirectories[current] ?? [] where result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }
}
