import CryptoKit
import Foundation
import PrimuseKit

actor ConnectorScanner {
    private static let progressYieldStride = 20
    /// A re-scan that finds nothing new never advances `addedCount`, so a
    /// stride-only rule would leave the card frozen on its opening update for
    /// the whole walk. Time-based ticks keep a slow remote scan visibly alive.
    private static let progressHeartbeatInterval: TimeInterval = 1

    private let connector: any MusicSourceConnector
    private let sourceID: String
    private let metadataService = MetadataService()
    private var completedSyncIndex: [String: SourceSyncIndexedItem] = [:]
    private var completedReconciliation: SourceSyncReconciliation?
    private var completedMissingStableKeys: [String: Int] = [:]
    /// IDs returned by server-catalog scanners whose API already supplied the
    /// title and other useful metadata. ScanService drains this alongside scan
    /// snapshots so MetadataBackfillService does not repeat the same inspection
    /// with one Range request per song.
    private var pendingMetadataInspectedSongIDs: Set<String> = []
    /// Rows this scan added or refreshed since the last drain. ScanService
    /// publishes these on every intermediate flush instead of resubmitting the
    /// accumulated catalogue, which is what made a large library's scan spend
    /// its time re-merging rows it had already committed.
    private var pendingChangedSongs: [Song] = []
    /// Subsonic rows are keyed by the server id in their path; a server that
    /// re-encodes its ids (Navidrome 0.64) must not turn them into new songs.
    private let carriesServerSongIdentities: Bool
    /// 没变过的 .cue 和整轨 WAV 的 DTS 判定不再每轮重扫都下载。
    private let cueSheetCache: CueSheetScanCache
    /// 同账号别的设备读好标签的行(见 `PeerScanSeedStore`)。新文件、还没读过的行文件
    /// 没变时直接用它,不再生成要补读的裸行。
    private let peerSeeds: PeerScanSeedLookup?
    /// 本机已存着同一份封面内容时,让这首歌的封面指过去,返回封面引用名。
    private let peerCoverLinker: (@Sendable (_ songID: String, _ contentKey: String) -> String?)?
    /// 这次扫描用上的别的设备的行,ScanService 随扫描快照一起交给补读服务。
    private var pendingPeerSeedAdoptions: [PeerScanSeedAdoption] = []
    /// 文件夹封面图的版本账本,这次扫描第一次用到时才从盘上读。
    private var coverRevisions: SidecarCoverRevisionTracker?
    /// 封面图换过、这次扫描丢掉了缓存封面的歌,扫完一起让在屏封面重读。
    private var coverRefreshedSongs: [Song] = []
    /// 分碟子文件夹 → 上一层专辑文件夹的封面图(没有封面也记下,不再重复列目录)。
    private var discFolderParentCovers: [String: RemoteFileItem?] = [:]

    init(
        connector: any MusicSourceConnector,
        sourceID: String,
        carriesServerSongIdentities: Bool = false,
        peerSeeds: PeerScanSeedLookup? = nil,
        peerCoverLinker: (@Sendable (_ songID: String, _ contentKey: String) -> String?)? = nil
    ) {
        self.connector = connector
        self.sourceID = sourceID
        self.carriesServerSongIdentities = carriesServerSongIdentities
        self.cueSheetCache = CueSheetScanCache(directory: CueSheetScanCache.directory(sourceID: sourceID))
        self.peerSeeds = peerSeeds
        self.peerCoverLinker = peerCoverLinker
    }

    func syncIndexSnapshot() -> [String: SourceSyncIndexedItem] {
        completedSyncIndex
    }

    func syncReconciliationSnapshot() -> (
        reconciliation: SourceSyncReconciliation?,
        missingStableKeys: [String: Int]
    ) {
        (completedReconciliation, completedMissingStableKeys)
    }

    func takeMetadataInspectedSongIDs() -> Set<String> {
        let ids = pendingMetadataInspectedSongIDs
        pendingMetadataInspectedSongIDs.removeAll(keepingCapacity: true)
        return ids
    }

    func takePeerSeedAdoptions() -> [PeerScanSeedAdoption] {
        let adoptions = pendingPeerSeedAdoptions
        pendingPeerSeedAdoptions.removeAll(keepingCapacity: true)
        return adoptions
    }

    /// 别的设备读好的这一行能用就并到 `base` 上:文件和那台设备读的是同一份字节,
    /// 那一行也真是读文件得来的。`base` 是本机这次按列表生成的行,文件位置、大小、
    /// 修改时间和旁边的封面/歌词以它为准。用上了就记一笔交给补读服务。
    private func adoptingPeerSeed(onto base: Song) -> Song? {
        guard let peerSeeds,
              let seed = peerSeeds.seed(for: base.id),
              PeerScanSeedPolicy.fingerprintMatches(
                  size: base.fileSize,
                  modifiedDate: base.lastModified,
                  revision: base.revision,
                  seed: seed.song
              ) else { return nil }
        var adopted = PeerScanSeedPolicy.adopting(seed.song, onto: base)
        let cover: PeerScanSeedAdoption.Cover
        switch PeerScanSeedPolicy.coverDisposition(seed: seed, base: base) {
        case .sidecar:
            cover = .resolved
        case .content(let key):
            if let name = peerCoverLinker?(base.id, key) {
                adopted.coverArtFileName = name
                cover = .resolved
            } else {
                cover = .pending(key)
            }
        case .unknown:
            cover = .unknown
        }
        // 补读只为这些格式单独读封面。别的格式的封面原本是读时长时顺带存下的,
        // 拿别人的行省掉那次读取就没人再去读封面了,所以只在本机已经能指到封面时才用。
        if cover != .resolved,
           !MetadataBackfillEligibilityPolicy.embeddedArtworkFormats.contains(base.fileFormat) {
            return nil
        }
        pendingPeerSeedAdoptions.append(PeerScanSeedAdoption(
            songID: base.id,
            cover: cover,
            cachedLyrics: PeerScanSeedPolicy.hasCachedLyrics(seed.song)
        ))
        return adopted
    }

    /// 本机已有、但还没读过文件的行(扫描先生成的裸行)。
    private func adoptingPeerSeed(intoUnreadRow row: Song) -> Song? {
        guard row.duration <= 0, row.cueSheetPath == nil,
              let adopted = adoptingPeerSeed(onto: row) else { return nil }
        return SongUserMetadataPolicy.preservingUserEdits(from: row, in: adopted)
    }

    /// Drains the rows discovered since the previous call. Accumulating inside
    /// the actor keeps the delta complete even though the update stream only
    /// buffers the newest element and may drop the ones in between.
    func takePendingChangedSongs() -> [Song] {
        let rows = pendingChangedSongs
        pendingChangedSongs.removeAll(keepingCapacity: true)
        return rows
    }

    struct ScanUpdate: Sendable {
        /// Total songs known for this source after this scan run — existing
        /// (from prior runs) plus anything newly discovered. Drives the
        /// source-card "X songs" badge.
        var scannedCount: Int
        /// Songs the scan walk added this run. Stays 0 when re-scanning a
        /// source that hasn't gained any files. Drives the in-progress
        /// "新增 N 首" label so users can tell a no-op scan from a real one.
        var addedCount: Int
        /// New or refreshed rows observed during this run. Unlike addedCount,
        /// this advances when a server updates metadata for an existing song
        /// and lets ScanService publish that change before the full walk ends.
        var mutationCount: Int = 0
        var totalCount: Int
        var currentFile: String
        /// Every song known for this source after this update. Empty on
        /// progress-only updates; `carriesFullSnapshot` says which kind of
        /// update this is.
        var songs: [Song]
        /// False while the walk is only reporting progress. The accumulated
        /// snapshot then arrives with a later update — at the next directory
        /// boundary for a file walk, or with the terminal update for a
        /// catalogue — and the rows discovered in between are drained through
        /// `takePendingChangedSongs()`.
        var carriesFullSnapshot: Bool = true
        /// Present for generic file/NAS walks. ScanService persists it in the
        /// same checkpoint as `songs`, so an interrupted scan resumes at the
        /// next unfinished directory without making partial results authoritative.
        var resumeState: SourceScanResumeState? = nil
    }

    struct IncrementalResult: Sendable {
        var songs: [Song]
        var index: [String: SourceSyncIndexedItem]
        var changedCount: Int
    }

    private func uniqueSongIDsByPath(_ songs: [Song]) -> [String: String] {
        var result: [String: String] = [:]
        var ambiguous: Set<String> = []
        for song in songs where song.sourceID == sourceID && !song.isCueTrack {
            if result.updateValue(song.id, forKey: song.filePath) != nil { ambiguous.insert(song.filePath) }
        }
        for path in ambiguous { result.removeValue(forKey: path) }
        return result
    }

    /// Reconciles only provider directories named by a native change feed.
    /// Each directory listing is authoritative for that directory, while the
    /// rest of the source snapshot is carried forward unchanged.
    func reconcileChangedDirectories(
        _ directories: Set<String>,
        deletedStableKeys: Set<String>,
        existingSongs: [Song],
        existingIndex: [String: SourceSyncIndexedItem],
        scanEpoch: Int64,
        requiresCompleteListings: Bool = false,
        progress: (@Sendable (
            _ completedCount: Int,
            _ totalCount: Int,
            _ currentDirectory: String
        ) async -> Void)? = nil
    ) async throws -> IncrementalResult {
        defer { finishCoverRevisions() }
        try await connector.connect()
        var songsByID = Dictionary(
            existingSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingIDsByPath = uniqueSongIDsByPath(existingSongs)
        var index = existingIndex
        var changedCount = 0
        // Keep the pre-deletion identity baseline. If an item reappears between
        // the provider snapshot and the authoritative parent re-list, it must
        // recover its existing Song ID instead of being recreated.
        let reconciliationBaseline = existingIndex
        let confirmedDeletedDirectoryPaths = SourceSyncDirectoryPruningPolicy.confirmedDeletedDirectoryPaths(
            index: reconciliationBaseline,
            deletedKeys: deletedStableKeys
        )
        var observedStablePaths: [String: String] = [:]

        for key in deletedStableKeys {
            if let entry = index.removeValue(forKey: key) {
                for id in entry.songIDs { songsByID[id] = nil }
                changedCount += 1
            }
        }
        // The mutable index may already point at the new parent by the time the
        // old parent is reconciled (directory processing order is arbitrary).

        let orderedDirectories = directories.sorted()
        var completedDirectoryCount = 0
        for directory in orderedDirectories {
            try Task.checkCancellation()
            if requiresCompleteListings,
               let budgeted = connector as? any SnapshotReconciliationBudgetConnector {
                try await budgeted.reserveSnapshotReconciliationDirectory()
            }
            let oldEntries = reconciliationBaseline.filter { $0.value.parentPath == directory }
            let siblings: [RemoteFileItem]
            do {
                siblings = try await connector.listFiles(at: directory)
            } catch {
                if !requiresCompleteListings,
                   isMissingPathError(error),
                   confirmedDeletedDirectoryPaths.contains(directory) {
                    completedDirectoryCount += 1
                    await progress?(completedDirectoryCount, orderedDirectories.count, directory)
                    continue
                }
                let unconfirmedMissing = BaiduSnapshotDirectoryReconciliationPolicy
                    .unconfirmedMissingKeys(
                        expectedKeys: Set(oldEntries.keys),
                        listedKeys: [],
                        confirmedDeletedKeys: deletedStableKeys
                    )
                guard requiresCompleteListings,
                      isMissingPathError(error),
                      unconfirmedMissing.isEmpty else { throw error }
                // A moved directory's old path (or a directory whose children
                // were all confirmed deleted) may legitimately return -9.
                // Nothing unconfirmed is owned by that stale path anymore.
                completedDirectoryCount += 1
                await progress?(
                    completedDirectoryCount,
                    orderedDirectories.count,
                    directory
                )
                continue
            }
            if requiresCompleteListings,
               let budgeted = connector as? any SnapshotReconciliationBudgetConnector {
                try await budgeted.checkSnapshotReconciliationBudget()
            }
            let sidecarIndex = await directoryIndex(siblings, of: directory)
            var rebuiltStableKeys: Set<String> = []
            for (key, entry) in oldEntries {
                // If another changed directory already moved this stable key,
                // do not let the old-parent pass delete the replacement.
                guard index[key]?.parentPath == entry.parentPath else { continue }
                index[key] = nil
                for id in entry.songIDs { songsByID[id] = nil }
            }

            let cueTracks = try await loadCueTracks(from: siblings)
            for directoryItem in siblings where directoryItem.isDirectory {
                try validateStableIdentity(
                    for: directoryItem,
                    observedPaths: &observedStablePaths
                )
                let stableKey = directoryItem.providerID
                    ?? "path:\(directoryItem.path.lowercased())"
                rebuiltStableKeys.insert(stableKey)
                recordSyncItem(
                    directoryItem,
                    songIDs: [],
                    seenEpoch: scanEpoch,
                    in: &index
                )
            }
            for rawItem in siblings where !rawItem.isDirectory {
                try Task.checkCancellation()
                if SourceArtistArtworkCatalog.isSupportedCandidateFileName(rawItem.name) {
                    try validateStableIdentity(
                        for: rawItem,
                        observedPaths: &observedStablePaths
                    )
                    let stableKey = rawItem.providerID
                        ?? "path:\(rawItem.path.lowercased())"
                    rebuiltStableKeys.insert(stableKey)
                    recordSyncItem(
                        rawItem,
                        songIDs: [],
                        seenEpoch: scanEpoch,
                        in: &index
                    )
                    continue
                }
                guard let item = SidecarHintResolver.scannableItem(
                    rawItem,
                    index: sidecarIndex
                ) else { continue }
                try validateStableIdentity(
                    for: item,
                    observedPaths: &observedStablePaths
                )
                let stableKey = item.providerID ?? "path:\(item.path.lowercased())"
                rebuiltStableKeys.insert(stableKey)
                let oldEntry = reconciliationBaseline[stableKey]
                let ext = (item.name as NSString).pathExtension.lowercased()

                if PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
                    let preferredID = oldEntry?.songIDs.count == 1
                        ? oldEntry?.songIDs.first
                        : nil
                    let songID = preferredID ?? generatedSongID(for: item)
                    if let oldEntry,
                       let old = preferredID.flatMap({ id in existingSongs.first { $0.id == id } }),
                       Self.wrapperFingerprintMatches(oldEntry, item),
                       STRMRevision.wrapperMatches(
                           songRevision: old.revision,
                           wrapperRevision: item.revision,
                           wrapperSize: item.size,
                           wrapperModifiedDate: item.modifiedDate
                       ) {
                        var refreshed = old
                        refreshed.filePath = item.path
                        refreshed.lastModified = item.modifiedDate ?? old.lastModified
                        applySidecarHints(from: item, to: &refreshed)
                        refreshSuspiciousSourceTitle(in: &refreshed, from: item)
                        songsByID[old.id] = refreshed
                        recordSyncItem(item, songIDs: [old.id], seenEpoch: scanEpoch, in: &index)
                        continue
                    }
                    if let song = await buildSTRMSong(from: item, songID: songID) {
                        var replacement = song
                        if let old = preferredID.flatMap({ id in existingSongs.first { $0.id == id } }) {
                            replacement.dateAdded = old.dateAdded
                        }
                        songsByID[replacement.id] = replacement
                        recordSyncItem(item, songIDs: [replacement.id], seenEpoch: scanEpoch, in: &index)
                        changedCount += 1
                    } else if let oldEntry {
                        // Preserve a previously valid row on transient wrapper
                        // read failures; the uncommitted cursor will replay it.
                        index[stableKey] = oldEntry
                        for id in oldEntry.songIDs {
                            if let old = existingSongs.first(where: { $0.id == id }) {
                                songsByID[id] = old
                            }
                        }
                    }
                    continue
                }

                if let descriptors = cueTracks[item.path], !descriptors.isEmpty {
                    let cueImage = SidecarHintResolver.cueImageItem(item, index: sidecarIndex)
                    var cueSongs = buildCueSongs(
                        from: cueImage,
                        descriptors: descriptors,
                        sidecarIndex: sidecarIndex,
                        cueImageCount: cueTracks.count
                    )
                    if let oldEntry {
                        reuseCueSongIdentities(
                            in: &cueSongs,
                            priorSongIDs: oldEntry.songIDs,
                            existingByID: Dictionary(
                                existingSongs.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first }
                            )
                        )
                    }
                    for song in cueSongs {
                        if let existing = existingSongs.first(where: { $0.id == song.id }) {
                            songsByID[song.id] = carriedOverCueTrack(existing: existing, rebuilt: song, cueImage: cueImage)
                        } else {
                            songsByID[song.id] = song
                        }
                    }
                    recordSyncItem(
                        cueImage,
                        songIDs: cueSongs.map(\.id),
                        seenEpoch: scanEpoch,
                        in: &index
                    )
                    changedCount += 1
                    continue
                }

                let preferredID = (oldEntry?.songIDs.count == 1 ? oldEntry?.songIDs.first : nil)
                    ?? existingIDsByPath[item.path]
                let songID = preferredID ?? generatedSongID(for: item)
                let incoming = buildBareSong(from: item, songID: songID)
                if var old = preferredID.flatMap({ id in existingSongs.first { $0.id == id } }) {
                    // `incoming` is a bare row named after the file; the stored
                    // row's title, album and track came from its tags. Only the
                    // file itself decides whether those tags still stand.
                    if !Self.fileIdentityChanged(existing: old, item: item) {
                        old.filePath = item.path
                        old.fileSize = item.size
                        old.lastModified = item.modifiedDate ?? old.lastModified
                        old.revision = item.revision ?? old.revision
                        applySidecarHints(from: item, to: &old)
                        refreshSuspiciousSourceTitle(in: &old, from: item)
                        if let adopted = adoptingPeerSeed(intoUnreadRow: old) {
                            old = adopted
                            changedCount += 1
                        }
                        songsByID[old.id] = old
                    } else {
                        var replacement = incoming
                        replacement.dateAdded = old.dateAdded
                        replacement = SongUserMetadataPolicy.preservingUserEdits(
                            from: old,
                            in: replacement
                        )
                        songsByID[replacement.id] = replacement
                        changedCount += 1
                    }
                } else {
                    songsByID[incoming.id] = adoptingPeerSeed(onto: incoming) ?? incoming
                    changedCount += 1
                }
                recordSyncItem(item, songIDs: [songID], seenEpoch: scanEpoch, in: &index)
            }

            if requiresCompleteListings,
               let budgeted = connector as? any SnapshotReconciliationBudgetConnector {
                try await budgeted.checkSnapshotReconciliationBudget()
            }

            if requiresCompleteListings {
                let unconfirmedMissing = BaiduSnapshotDirectoryReconciliationPolicy
                    .unconfirmedMissingKeys(
                        expectedKeys: Set(oldEntries.keys),
                        listedKeys: rebuiltStableKeys,
                        confirmedDeletedKeys: deletedStableKeys
                    )
                guard unconfirmedMissing.isEmpty else {
                    throw ConnectorSnapshotReconciliationError.incompleteDirectory(
                        directory,
                        unconfirmedMissing.sorted()
                    )
                }
            }

            changedCount += oldEntries.keys.filter {
                !rebuiltStableKeys.contains($0) && index[$0] == nil
            }.count
            completedDirectoryCount += 1
            if completedDirectoryCount.isMultiple(of: 5)
                || completedDirectoryCount == orderedDirectories.count {
                await progress?(
                    completedDirectoryCount,
                    orderedDirectories.count,
                    directory
                )
            }
        }

        let orphanedKeys = SourceSyncDirectoryPruningPolicy.orphanedDescendantKeys(
            baseline: reconciliationBaseline,
            current: index
        )
        for key in orphanedKeys {
            guard let entry = index.removeValue(forKey: key) else { continue }
            for id in entry.songIDs { songsByID[id] = nil }
        }
        changedCount += orphanedKeys.count

        var remaining = songsByID
        var orderedSongs: [Song] = []
        orderedSongs.reserveCapacity(remaining.count)
        for song in existingSongs {
            if let current = remaining.removeValue(forKey: song.id) {
                orderedSongs.append(current)
            }
        }
        orderedSongs.append(contentsOf: remaining.values.sorted {
            if $0.filePath == $1.filePath { return $0.id < $1.id }
            return $0.filePath < $1.filePath
        })
        return IncrementalResult(
            songs: orderedSongs,
            index: index,
            changedCount: changedCount
        )
    }

    func scan(
        directories: [String],
        existingSongs: [Song] = [],
        startingCount: Int = 0,
        resumeState: SourceScanResumeState? = nil,
        identityIndex: [String: SourceSyncIndexedItem] = [:],
        identityMissingStableKeys: [String: Int] = [:],
        scanEpoch: Int64 = 0
    ) -> AsyncThrowingStream<ScanUpdate, Error> {
        completedSyncIndex = [:]
        completedReconciliation = nil
        completedMissingStableKeys = [:]
        pendingMetadataInspectedSongIDs.removeAll(keepingCapacity: true)
        pendingChangedSongs.removeAll(keepingCapacity: true)
        // 只有终态那一条带完整快照, 中途全是进度。带上累积数组的那一条会被
        // 流缓冲和消费端各持有一份引用, 于是紧接着的 append 必然触发整份写时
        // 复制 —— 每 20 首一次, 7 万首的库里就是 O(n²)。中途新增/刷新的行改
        // 由 takePendingChangedSongs() 取, 累积在 actor 里, 所以
        // `.bufferingNewest(1)` 丢掉中间更新也不会丢行。
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                defer { finishCoverRevisions() }
                do {
                    plog("🔍 ConnectorScanner.scan source=\(sourceID) dirs=\(directories)")
                    try await connector.connect()
                    plog("🔍 ConnectorScanner.scan connected")
                    // Remove redundant child directories when a parent is already selected
                    let dirs = SynologyScanner.deduplicateDirectories(directories)
                    let selectedRoots = Set(dirs)

                    // Single-pass scan. Total count is unknown until we finish walking
                    // the tree — UI shows scannedCount as an indeterminate counter
                    // rather than X/Y. Skipping the prior Phase1 countAudioFiles pass
                    // avoids walking every directory twice (saved ~50% list-API time
                    // on large cloud trees).
                    let totalCount = 0
                    var allSongs = existingSongs
                    let existingIDsByPath = uniqueSongIDsByPath(existingSongs)
                    var existingByID: [String: Song] = [:]
                    existingByID.reserveCapacity(existingSongs.count)
                    for song in existingSongs { existingByID[song.id] = song }
                    var allSongIndexByID: [String: Int] = [:]
                    allSongIndexByID.reserveCapacity(existingSongs.count)
                    for (i, song) in allSongs.enumerated() { allSongIndexByID[song.id] = i }
                    let initialCount = max(existingSongs.count, startingCount)
                    var scannedCount = totalCount > 0 ? min(initialCount, totalCount) : initialCount
                    var addedCount = 0
                    var mutationCount = 0
                    // 每一处改动都经过这里登记。ScanService 的中间 flush 因此可以
                    // 只提交增量: 原本每 1.5 s 把整份累积目录再交给 addSongs 一次,
                    // 7 万首的库等于一遍遍重跑整库准入判定与索引合并, 全在主线程上。
                    // 行内容没变就什么都不算 —— 重扫时绝大多数行都走这一支。
                    func recordRow(_ song: Song, for songID: String) {
                        guard existingByID[songID] != song else { return }
                        existingByID[songID] = song
                        pendingChangedSongs.append(song)
                        mutationCount += 1
                    }
                    let usableResumeState = resumeState?.isUsable == true ? resumeState : nil
                    var encounteredSongIDs = usableResumeState?.encounteredSongIDs ?? []
                    let identityBaseline = identityIndex.merging(
                        usableResumeState?.index ?? [:],
                        uniquingKeysWith: { _, resumed in resumed }
                    )
                    var hadDirectoryFailure = false
                    var successfulDirectoryCount = 0
                    var firstDirectoryError: Error?
                    var syncIndex = usableResumeState?.index ?? [:]
                    var claimedIdentityKeys: Set<String> = []
                    var observedStablePaths = Dictionary(
                        uniqueKeysWithValues: syncIndex.map { ($0.key, $0.value.path) }
                    )
                    var preferredProviderHierarchies: [String: [SourceSyncIndexedItem]] = [:]
                    var lastProgressYieldAt = Date()
                    let songIDsByServerSongID: [String: String] = carriesServerSongIdentities
                        ? SubsonicSongIdentityCarryPolicy.songIDsByServerSongID(existingSongs) {
                            NavidromeCanonicalIDPolicy.canonicalID($0)
                        }
                        : [:]

                    if !existingSongs.isEmpty {
                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
                                addedCount: addedCount,
                                mutationCount: mutationCount,
                                totalCount: totalCount,
                                currentFile: "",
                                songs: allSongs
                            )
                        )
                    }

                    if let songConnector = connector as? any SongScanningConnector {
                        for directory in dirs {
                            try Task.checkCancellation()
                            do {
                                let stream: AsyncThrowingStream<ConnectorScannedSong, Error>
                                if let fingerprintAware = songConnector as? any ExistingSongAwareScanningConnector {
                                    stream = try await fingerprintAware.scanSongs(
                                        from: directory,
                                        existingSongs: existingSongs
                                    )
                                } else {
                                    stream = try await songConnector.scanSongs(from: directory)
                                }

                                for try await streamedSong in stream {
                                    try Task.checkCancellation()
                                    let scannedSong = songIDsByServerSongID.isEmpty
                                        ? streamedSong
                                        : streamedSong.carryingSongIdentity(
                                            isExistingSongID: { existingByID[$0] != nil },
                                            songIDsByServerSongID: songIDsByServerSongID
                                        )
                                    encounteredSongIDs.insert(scannedSong.song.id)
                                    if !scannedSong.providerHierarchyItems.isEmpty {
                                        let existing = preferredProviderHierarchies[
                                            scannedSong.song.id
                                        ]
                                        if existing == nil
                                            || ConnectorProviderHierarchySelectionPolicy.prefers(
                                                candidate: scannedSong.providerHierarchyItems,
                                                over: existing ?? []
                                            ) {
                                            preferredProviderHierarchies[scannedSong.song.id] =
                                                scannedSong.providerHierarchyItems
                                        }
                                    }
                                    if scannedSong.titleMetadataInspected {
                                        pendingMetadataInspectedSongIDs.insert(scannedSong.song.id)
                                    }
                                    if Date().timeIntervalSince(lastProgressYieldAt)
                                        >= Self.progressHeartbeatInterval {
                                        lastProgressYieldAt = Date()
                                        continuation.yield(
                                            ScanUpdate(
                                                scannedCount: scannedCount,
                                                addedCount: addedCount,
                                                mutationCount: mutationCount,
                                                totalCount: totalCount,
                                                currentFile: scannedSong.displayName,
                                                songs: [],
                                                carriesFullSnapshot: false
                                            )
                                        )
                                    }
                                    if let existing = existingByID[scannedSong.song.id] {
                                        // Same path can either be the same file (skip) or
                                        // a remote replacement (refresh). Decide on size
                                        // first since lastModified isn't always populated.
                                        if !songContentChanged(existing: existing, incoming: scannedSong.song) {
                                            if connector is any RefreshingMetadataSongConnector {
                                                let refreshed = refreshServerMetadata(
                                                    existing: existing,
                                                    incoming: scannedSong.song
                                                )
                                                if refreshed != existing,
                                                   let idx = allSongIndexByID[scannedSong.song.id] {
                                                    allSongs[idx] = refreshed
                                                    recordRow(refreshed, for: scannedSong.song.id)
                                                }
                                            }
                                            continue
                                        }
                                        // Replaced — overwrite the entry already in
                                        // allSongs so the next library flush sees the
                                        // fresh size/mtime/sidecars instead of merging
                                        // back to stale metadata.
                                        var replacement = SongUserMetadataPolicy.preservingUserEdits(
                                            from: existing,
                                            in: scannedSong.song
                                        )
                                        if connector is any RefreshingMetadataSongConnector {
                                            replacement = ServerSongCatalogMergePolicy.mergingAddedDates(
                                                existing: existing, incoming: scannedSong.song, into: replacement
                                            )
                                        }
                                        if let idx = allSongIndexByID[scannedSong.song.id] {
                                            allSongs[idx] = replacement
                                        }
                                        recordRow(replacement, for: scannedSong.song.id)
                                        continue
                                    }

                                    scannedCount += 1
                                    addedCount += 1
                                    allSongs.append(scannedSong.song)
                                    allSongIndexByID[scannedSong.song.id] = allSongs.count - 1
                                    recordRow(scannedSong.song, for: scannedSong.song.id)

                                    // Server-side song scanners can enumerate
                                    // thousands of tracks faster than the UI can
                                    // persist a full snapshot. Coalesce progress
                                    // just like the generic file scanner below.
                                    if mutationCount.isMultiple(of: Self.progressYieldStride) {
                                        lastProgressYieldAt = Date()
                                        continuation.yield(
                                            ScanUpdate(
                                                scannedCount: scannedCount,
                                                addedCount: addedCount,
                                                mutationCount: mutationCount,
                                                totalCount: totalCount,
                                                currentFile: scannedSong.displayName,
                                                songs: [],
                                                carriesFullSnapshot: false
                                            )
                                        )
                                    }
                                }
                                successfulDirectoryCount += 1
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                hadDirectoryFailure = true
                                if firstDirectoryError == nil {
                                    firstDirectoryError = error
                                }
                                plog("⚠️ Failed to scan directory \(directory): \(error)")
                                continue
                            }
                        }

                        if successfulDirectoryCount == 0, let firstDirectoryError {
                            throw firstDirectoryError
                        }

                        if !hadDirectoryFailure {
                            allSongs.removeAll { encounteredSongIDs.contains($0.id) == false }
                            scannedCount = allSongs.count
                        }

                        for hierarchy in preferredProviderHierarchies.values {
                            for item in hierarchy {
                                syncIndex[item.stableKey] = item
                            }
                        }

                        completedSyncIndex = syncIndex

                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
                                addedCount: addedCount,
                                mutationCount: mutationCount,
                                totalCount: totalCount,
                                currentFile: "",
                                songs: allSongs
                            )
                        )
                        if let firstDirectoryError {
                            continuation.finish(throwing: firstDirectoryError)
                        } else {
                            continuation.finish()
                        }
                        return
                    }

                    // Walk each remote directory once. The same authoritative
                    // sibling listing drives CUE expansion, audio discovery,
                    // covers, lyrics and MV sidecars. The explicit queue is
                    // checkpointed after every directory, so interruption does
                    // not restart enumeration at the selected root.
                    var pendingSet: Set<String> = []
                    let initialPending = usableResumeState?.pendingDirectories ?? dirs
                    var pendingDirectories = initialPending.filter {
                        pendingSet.insert($0).inserted
                    }
                    var visitedDirectories: Set<String> = []
                    var failedDirectories: [String] = []
                    // 等过 Retry-After 仍被限流时停下这一轮: 再往下列只会把剩下的目录全撞成失败。
                    var rateLimitStopError: Error?

                    continuation.yield(
                        ScanUpdate(
                            scannedCount: scannedCount,
                            addedCount: addedCount,
                            mutationCount: mutationCount,
                            totalCount: totalCount,
                            currentFile: pendingDirectories.last ?? "",
                            songs: [],
                            carriesFullSnapshot: false,
                            resumeState: SourceScanResumeState(
                                pendingDirectories: pendingDirectories,
                                encounteredSongIDs: encounteredSongIDs,
                                index: syncIndex
                            )
                        )
                    )

                    directoryWalk: while let directory = pendingDirectories.popLast() {
                        pendingSet.remove(directory)
                        guard visitedDirectories.insert(directory).inserted else { continue }
                        try Task.checkCancellation()

                        let inFlightResumeState = SourceScanResumeState(
                            pendingDirectories: pendingDirectories + [directory] + failedDirectories,
                            encounteredSongIDs: encounteredSongIDs,
                            index: syncIndex
                        )
                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
                                addedCount: addedCount,
                                mutationCount: mutationCount,
                                totalCount: totalCount,
                                currentFile: directory,
                                songs: [],
                                carriesFullSnapshot: false,
                                resumeState: inFlightResumeState
                            )
                        )

                        do {
                            let previouslyObservedPaths = Self.previouslyObservedChildPaths(
                                in: directory,
                                identityIndex: identityBaseline,
                                existingSongs: existingSongs
                            )
                            let siblings: [RemoteFileItem]
                            if let confirming = connector as?
                                any DestructiveDirectoryListingConfirmingConnector {
                                siblings = try await confirming.listFiles(
                                    at: directory,
                                    confirmingPreviouslyObservedPaths: previouslyObservedPaths
                                )
                            } else {
                                siblings = try await connector.listFiles(at: directory)
                            }
                            let sidecarIndex = await directoryIndex(siblings, of: directory)
                            for directoryItem in siblings where directoryItem.isDirectory {
                                try validateStableIdentity(
                                    for: directoryItem,
                                    observedPaths: &observedStablePaths
                                )
                                recordSyncItem(
                                    directoryItem,
                                    songIDs: [],
                                    seenEpoch: scanEpoch,
                                    in: &syncIndex
                                )
                            }
                            let cueTracksByAudioPath = try await loadCueTracks(from: siblings)
                            for rawItem in siblings where !rawItem.isDirectory {
                                if SourceArtistArtworkCatalog.isSupportedCandidateFileName(rawItem.name) {
                                    try validateStableIdentity(
                                        for: rawItem,
                                        observedPaths: &observedStablePaths
                                    )
                                    recordSyncItem(
                                        rawItem,
                                        songIDs: [],
                                        seenEpoch: scanEpoch,
                                        in: &syncIndex
                                    )
                                    continue
                                }
                                guard let item = SidecarHintResolver.scannableItem(
                                    rawItem,
                                    index: sidecarIndex
                                ) else { continue }
                                try Task.checkCancellation()

                                if Date().timeIntervalSince(lastProgressYieldAt) >= Self.progressHeartbeatInterval {
                                    lastProgressYieldAt = Date()
                                    continuation.yield(
                                        ScanUpdate(
                                            scannedCount: scannedCount,
                                            addedCount: addedCount,
                                            mutationCount: mutationCount,
                                            totalCount: totalCount,
                                            currentFile: item.name,
                                            songs: [],
                                            carriesFullSnapshot: false
                                        )
                                    )
                                }

                                try validateStableIdentity(
                                    for: item,
                                    observedPaths: &observedStablePaths
                                )
                                let stableKey = item.providerID ?? "path:\(item.path.lowercased())"
                                let identityMatch = identityMatch(
                                    for: item,
                                    stableKey: stableKey,
                                    baseline: identityBaseline,
                                    claimedKeys: claimedIdentityKeys
                                )
                                let priorEntry = identityMatch?.item
                                if let identityKey = identityMatch?.key {
                                    claimedIdentityKeys.insert(identityKey)
                                }
                                let preferredSongID: String? = {
                                    guard priorEntry?.songIDs.count == 1,
                                          let candidate = priorEntry?.songIDs.first,
                                          existingByID[candidate] != nil else { return existingIDsByPath[item.path] }
                                    return candidate
                                }()
                                let songID = preferredSongID ?? generatedSongID(for: item)

                                if PrimuseConstants.supportedStreamDescriptorExtensions.contains(
                                    (item.name as NSString).pathExtension.lowercased()
                                ) {
                                    encounteredSongIDs.insert(songID)
                                    if let existing = existingByID[songID],
                                       STRMRevision.wrapperMatches(
                                           songRevision: existing.revision,
                                           wrapperRevision: item.revision,
                                           wrapperSize: item.size,
                                           wrapperModifiedDate: item.modifiedDate
                                       ) {
                                        recordSyncItem(
                                            item,
                                            songIDs: [songID],
                                            seenEpoch: scanEpoch,
                                            in: &syncIndex
                                        )
                                        if let idx = allSongIndexByID[songID] {
                                            var refreshed = existing
                                            refreshed.filePath = item.path
                                            refreshed.lastModified = item.modifiedDate ?? existing.lastModified
                                            applySidecarHints(from: item, to: &refreshed)
                                            refreshSuspiciousSourceTitle(in: &refreshed, from: item)
                                            allSongs[idx] = refreshed
                                            recordRow(refreshed, for: songID)
                                        }
                                        continue
                                    }
                                    guard let descriptorSong = await buildSTRMSong(from: item, songID: songID) else {
                                        // Keep an existing row when a transient read or a
                                        // temporarily malformed regenerated descriptor is
                                        // encountered. A deep scan must never turn that
                                        // read failure into an inferred deletion.
                                        if existingByID[songID] != nil {
                                            recordSyncItem(
                                                item,
                                                songIDs: [songID],
                                                seenEpoch: scanEpoch,
                                                in: &syncIndex
                                            )
                                        }
                                        continue
                                    }
                                    recordSyncItem(
                                        item,
                                        songIDs: [songID],
                                        seenEpoch: scanEpoch,
                                        in: &syncIndex
                                    )
                                    if let existing = existingByID[songID] {
                                        if songContentChanged(existing: existing, incoming: descriptorSong),
                                           let idx = allSongIndexByID[songID] {
                                            var replacement = descriptorSong
                                            replacement.dateAdded = existing.dateAdded
                                            replacement = SongUserMetadataPolicy.preservingUserEdits(
                                                from: existing,
                                                in: replacement
                                            )
                                            allSongs[idx] = replacement
                                            recordRow(replacement, for: songID)
                                        } else if let idx = allSongIndexByID[songID] {
                                            var refreshed = existing
                                            refreshed.filePath = descriptorSong.filePath
                                            refreshed.lastModified = descriptorSong.lastModified ?? existing.lastModified
                                            applySidecarHints(from: item, to: &refreshed)
                                            allSongs[idx] = refreshed
                                            recordRow(refreshed, for: songID)
                                        }
                                    } else {
                                        allSongs.append(descriptorSong)
                                        allSongIndexByID[songID] = allSongs.count - 1
                                        recordRow(descriptorSong, for: songID)
                                        scannedCount += 1
                                        addedCount += 1
                                    }
                                    continue
                                }

                                if let descriptors = cueTracksByAudioPath[item.path], !descriptors.isEmpty {
                                    let cueImage = SidecarHintResolver.cueImageItem(item, index: sidecarIndex)
                                    var cueSongs = buildCueSongs(
                                        from: cueImage,
                                        descriptors: descriptors,
                                        sidecarIndex: sidecarIndex,
                                        cueImageCount: cueTracksByAudioPath.count
                                    )
                                    if let priorEntry {
                                        reuseCueSongIdentities(
                                            in: &cueSongs,
                                            priorSongIDs: priorEntry.songIDs,
                                            existingByID: existingByID
                                        )
                                    }
                                    recordSyncItem(
                                        cueImage,
                                        songIDs: cueSongs.map(\.id),
                                        seenEpoch: scanEpoch,
                                        in: &syncIndex
                                    )
                                    for cueSong in cueSongs {
                                        encounteredSongIDs.insert(cueSong.id)
                                        if let existing = existingByID[cueSong.id] {
                                            if let index = allSongIndexByID[cueSong.id] {
                                                let carried = carriedOverCueTrack(
                                                    existing: existing,
                                                    rebuilt: cueSong,
                                                    cueImage: cueImage
                                                )
                                                allSongs[index] = carried
                                                recordRow(carried, for: cueSong.id)
                                            }
                                            continue
                                        }
                                        allSongs.append(cueSong)
                                        allSongIndexByID[cueSong.id] = allSongs.count - 1
                                        recordRow(cueSong, for: cueSong.id)
                                        scannedCount += 1
                                        addedCount += 1
                                    }
                                    continue
                                }

                                encounteredSongIDs.insert(songID)
                                recordSyncItem(
                                    item,
                                    songIDs: [songID],
                                    seenEpoch: scanEpoch,
                                    in: &syncIndex
                                )

                                if let existing = existingByID[songID] {
                                    // Same path can either be unchanged (skip) or a
                                    // remote replacement (emit fresh bare song so
                                    // backfill re-runs against new bytes). Compare
                                    // size, mtime, AND provider revision — Baidu /
                                    // Aliyun / Dropbox listFiles return nil mtime
                                    // and a same-size overwrite would slip past the
                                    // first two checks.
                                    if !Self.fileIdentityChanged(existing: existing, item: item) {
                                        if let idx = allSongIndexByID[songID] {
                                            var refreshed = existing
                                            refreshed.filePath = item.path
                                            if item.size > 0 { refreshed.fileSize = item.size }
                                            refreshed.lastModified = item.modifiedDate ?? existing.lastModified
                                            refreshed.revision = item.revision ?? existing.revision
                                            applySidecarHints(from: item, to: &refreshed)
                                            refreshSuspiciousSourceTitle(in: &refreshed, from: item)
                                            if let repairedDuration = AudioDurationPolicy.repairedStoredDTSDuration(
                                                stored: refreshed.duration,
                                                fileSize: refreshed.fileSize,
                                                bitRateKbps: refreshed.bitRate,
                                                fileExtension: (refreshed.filePath as NSString).pathExtension,
                                                format: refreshed.fileFormat
                                            ) {
                                                refreshed.duration = repairedDuration
                                            }
                                            if let adopted = adoptingPeerSeed(intoUnreadRow: refreshed) {
                                                refreshed = adopted
                                            }
                                            allSongs[idx] = refreshed
                                            recordRow(refreshed, for: songID)
                                        }
                                        continue
                                    }
                                    let refreshed = buildBareSong(from: item, songID: songID)
                                    if let idx = allSongIndexByID[songID] {
                                        var replacement = refreshed
                                        replacement.dateAdded = existing.dateAdded
                                        replacement = SongUserMetadataPolicy.preservingUserEdits(
                                            from: existing,
                                            in: replacement
                                        )
                                        allSongs[idx] = replacement
                                        recordRow(replacement, for: songID)
                                    }
                                    continue
                                }

                                let bareSong = buildBareSong(from: item, songID: songID)
                                let newSong = adoptingPeerSeed(onto: bareSong) ?? bareSong
                                allSongs.append(newSong)
                                allSongIndexByID[songID] = allSongs.count - 1
                                recordRow(newSong, for: songID)
                                scannedCount += 1
                                addedCount += 1

                                // Yield progress every 20 items — yielding on every
                                // file made the SwiftUI publisher chain the bottleneck
                                // when scanning fast cloud listings.
                                //
                                // 不带累积数组: 这一条的 resume 状态把正在走的目录
                                // 原样排回队列, checkpoint 要的本来就是上一个走完的
                                // 目录那份快照。附上整份 allSongs 只会让下一次
                                // append 触发整份写时复制。
                                if addedCount % Self.progressYieldStride == 0 {
                                    continuation.yield(
                                        ScanUpdate(
                                            scannedCount: scannedCount,
                                            addedCount: addedCount,
                                            mutationCount: mutationCount,
                                            totalCount: totalCount,
                                            currentFile: item.name,
                                            songs: [],
                                            carriesFullSnapshot: false,
                                            resumeState: SourceScanResumeState(
                                                pendingDirectories: pendingDirectories + [directory] + failedDirectories,
                                                encounteredSongIDs: encounteredSongIDs,
                                                index: syncIndex
                                            )
                                        )
                                    )
                                }
                            }

                            for child in siblings
                                .filter(\.isDirectory)
                                .map(\.path)
                                .sorted()
                                .reversed()
                            where !visitedDirectories.contains(child)
                                && !failedDirectories.contains(child)
                                && pendingSet.insert(child).inserted {
                                pendingDirectories.append(child)
                            }
                            successfulDirectoryCount += 1

                            continuation.yield(
                                ScanUpdate(
                                    scannedCount: scannedCount,
                                    addedCount: addedCount,
                                    mutationCount: mutationCount,
                                    totalCount: totalCount,
                                    currentFile: "",
                                    songs: [],
                                    carriesFullSnapshot: false,
                                    resumeState: SourceScanResumeState(
                                        pendingDirectories: pendingDirectories + failedDirectories,
                                        encounteredSongIDs: encounteredSongIDs,
                                        index: syncIndex
                                    )
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            let disposition = ScanDirectoryFailurePolicy.disposition(
                                isMissingPath: Self.isMissingPathError(error),
                                isSelectedRoot: selectedRoots.contains(directory)
                            )
                            switch disposition {
                            case .failMissingRoot:
                                // Do not write the missing root back into the
                                // resume queue. ScanService clears the stale
                                // checkpoint and keeps the existing library
                                // snapshot until the user selects a new root.
                                plog("⚠️ Selected scan root no longer exists: \(directory)")
                                throw error
                            case .discardMissingChild:
                                // A child captured by an older checkpoint may
                                // have been moved or deleted. Dropping it lets
                                // the rest of the tree finish and prevents an
                                // endless Continue Scan loop on the same path.
                                // Preserve its previously-committed subtree in
                                // this scan result: absence of a listing is not
                                // authoritative enough to delete user library
                                // rows. A later parent listing/change feed can
                                // reconcile a real move or deletion safely.
                                let preserved = Self.indexedSubtree(
                                    rootedAt: directory,
                                    in: identityBaseline
                                )
                                for (key, entry) in preserved {
                                    syncIndex[key] = entry
                                    encounteredSongIDs.formUnion(entry.songIDs)
                                }
                                // Source edits and older libraries can leave
                                // the identity index empty or incomplete.
                                // Those rows still need the same protection.
                                for song in existingSongs where Self.immediateChildPath(
                                    descendant: song.filePath, of: directory
                                ) != nil {
                                    encounteredSongIDs.insert(song.id)
                                }
                                plog("↷ Dropped stale child directory from scan checkpoint: \(directory)")
                                continuation.yield(
                                    ScanUpdate(
                                        scannedCount: scannedCount,
                                        addedCount: addedCount,
                                        mutationCount: mutationCount,
                                        totalCount: totalCount,
                                        currentFile: "",
                                        songs: [],
                                        carriesFullSnapshot: false,
                                        resumeState: SourceScanResumeState(
                                            pendingDirectories: pendingDirectories + failedDirectories,
                                            encounteredSongIDs: encounteredSongIDs,
                                            index: syncIndex
                                        )
                                    )
                                )
                                continue
                            case .retainForResume:
                                break
                            }
                            hadDirectoryFailure = true
                            if firstDirectoryError == nil {
                                firstDirectoryError = error
                            }
                            if !failedDirectories.contains(directory) {
                                failedDirectories.append(directory)
                            }
                            plog("⚠️ Failed to scan directory \(directory): \(error)")
                            continuation.yield(
                                ScanUpdate(
                                    scannedCount: scannedCount,
                                    addedCount: addedCount,
                                    mutationCount: mutationCount,
                                    totalCount: totalCount,
                                    currentFile: directory,
                                    songs: [],
                                    carriesFullSnapshot: false,
                                    resumeState: SourceScanResumeState(
                                        pendingDirectories: pendingDirectories + failedDirectories,
                                        encounteredSongIDs: encounteredSongIDs,
                                        index: syncIndex
                                    )
                                )
                            )
                            let sharedCooldown = (error as? HTTPResponseFailure).map {
                                $0.isRateLimited || $0.statusCode == 429 ||
                                    ($0.retryAfter.map { $0.isFinite && $0 >= 0 } ?? false)
                            } ?? false
                            if (error as? RemoteDirectoryHTTPStatusError)?.isRateLimited == true || sharedCooldown {
                                rateLimitStopError = error
                                plog("⏸ Directory listings remain rate limited; stopping with \(pendingDirectories.count + failedDirectories.count) directories left for Continue Scan")
                                break directoryWalk
                            }
                        }
                    }

                    if successfulDirectoryCount == 0, let stopError = rateLimitStopError ?? firstDirectoryError {
                        throw stopError
                    }

                    if connector is any StableProviderSongIdentityConnector {
                        let unresolvedLegacy = identityBaseline.filter { key, entry in
                            key.hasPrefix("path:")
                                && !claimedIdentityKeys.contains(key)
                                && !entry.songIDs.isEmpty
                        }
                        if !unresolvedLegacy.isEmpty {
                            for (key, entry) in unresolvedLegacy {
                                let observations = (identityMissingStableKeys[key] ?? 0) + 1
                                guard observations < BaiduSnapshotDiffPolicy
                                    .deletionConfirmationCount else { continue }
                                syncIndex[key] = entry
                                encounteredSongIDs.formUnion(entry.songIDs)
                                completedMissingStableKeys[key] = observations
                            }
                            if !completedMissingStableKeys.isEmpty {
                                completedReconciliation = SourceSyncReconciliation(
                                    kind: .baiduIdentityAndDeletionConfirmation,
                                    unresolvedStableKeys: Array(completedMissingStableKeys.keys),
                                    detectedAt: Date()
                                )
                            }
                        }
                    }

                    if !hadDirectoryFailure {
                        allSongs.removeAll { encounteredSongIDs.contains($0.id) == false }
                        scannedCount = allSongs.count
                    }

                    completedSyncIndex = syncIndex

                    // 终态快照: completeScan 的删除对账就是拿这一份和资料库比。
                    continuation.yield(
                        ScanUpdate(
                            scannedCount: scannedCount,
                            addedCount: addedCount,
                            mutationCount: mutationCount,
                            totalCount: totalCount,
                            currentFile: "",
                            songs: allSongs,
                            resumeState: SourceScanResumeState(
                                pendingDirectories: pendingDirectories + failedDirectories,
                                encounteredSongIDs: encounteredSongIDs,
                                index: syncIndex
                            )
                        )
                    )
                    if let stopError = rateLimitStopError ?? firstDirectoryError {
                        continuation.finish(throwing: stopError)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private nonisolated static func isMissingPathError(_ error: Error) -> Bool {
        switch error {
        case CloudDriveError.fileNotFound,
             SourceError.pathNotFound,
             SourceError.fileNotFound:
            return true
        default:
            return false
        }
    }

    private nonisolated static func indexedSubtree(
        rootedAt rootPath: String,
        in index: [String: SourceSyncIndexedItem]
    ) -> [String: SourceSyncIndexedItem] {
        var knownPaths: Set<String> = [rootPath]
        var result: [String: SourceSyncIndexedItem] = [:]
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for (key, entry) in index where result[key] == nil {
                guard entry.path == rootPath
                        || entry.parentPath.map(knownPaths.contains) == true else {
                    continue
                }
                result[key] = entry
                if entry.isDirectory, knownPaths.insert(entry.path).inserted {
                    madeProgress = true
                }
            }
        }
        return result
    }

    private struct CueTrackDescriptor: Sendable {
        let cuePath: String
        /// Listed name of the sheet; `cuePath` is an opaque ID on some providers.
        let cueName: String
        let albumTitle: String?
        let albumPerformer: String?
        let genre: String?
        let year: Int?
        let format: AudioFormat
        let track: CueTrack
    }

    private func loadCueTracks(from siblings: [RemoteFileItem]) async throws -> [String: [CueTrackDescriptor]] {
        var result: [String: [CueTrackDescriptor]] = [:]
        for cueItem in siblings where !cueItem.isDirectory
            && PrimuseConstants.supportedCueSheetExtensions.contains(
                (cueItem.name as NSString).pathExtension.lowercased()
            ) {
            let data = try await cueSheetData(for: cueItem)
            guard let cue = CueSheetParser.parse(data: data) else {
                plog("⚠️ CUE: unable to parse \(cueItem.name)")
                continue
            }
            for cueFile in cue.files {
                let referencedName = (cueFile.name.replacingOccurrences(of: "\\", with: "/") as NSString)
                    .lastPathComponent
                guard let audioItem = siblings.first(where: {
                    !$0.isDirectory && $0.name.caseInsensitiveCompare(referencedName) == .orderedSame
                }), var format = AudioFormat.from(
                    fileExtension: (audioItem.name as NSString).pathExtension.lowercased()
                ) else { continue }
                if (audioItem.name as NSString).pathExtension.lowercased() == "wav",
                   await wavContainsDTS(audioItem) {
                    format = .dts
                }
                for track in cueFile.tracks where track.type == "AUDIO" && track.startTime != nil {
                    result[audioItem.path, default: []].append(CueTrackDescriptor(
                        cuePath: cueItem.path,
                        cueName: cueItem.name,
                        albumTitle: cue.title,
                        albumPerformer: cue.performer,
                        genre: cue.genre,
                        year: cue.year,
                        format: format,
                        track: track
                    ))
                }
            }
        }
        return result
    }

    private func cueSheetData(for item: RemoteFileItem) async throws -> Data {
        let version = CueSheetScanCache.FileVersion(
            size: item.size,
            modifiedDate: item.modifiedDate,
            revision: item.revision
        )
        if let cached = await cueSheetCache.sheet(path: item.path, version: version) {
            return cached
        }
        let requestedLength = min(max(item.size, 64 * 1024), Int64(CueSheetScanCache.maximumSheetBytes))
        let data = try await connector.fetchMetadataRange(
            path: item.path,
            offset: 0,
            length: requestedLength
        )
        await cueSheetCache.storeSheet(data, path: item.path, version: version, requestedLength: requestedLength)
        return data
    }

    private func wavContainsDTS(_ item: RemoteFileItem) async -> Bool {
        let version = CueSheetScanCache.FileVersion(
            size: item.size,
            modifiedDate: item.modifiedDate,
            revision: item.revision
        )
        if let cached = await cueSheetCache.wavIsDTS(path: item.path, version: version) {
            return cached
        }
        let requestedLength: Int64 = 256 * 1024
        guard let prefix = try? await connector.fetchMetadataRange(
            path: item.path,
            offset: 0,
            length: requestedLength
        ) else { return false }
        let isDTS = FFmpegAudioDecoder.dataContainsDTSSync(prefix)
        await cueSheetCache.storeWAVIsDTS(
            isDTS,
            path: item.path,
            version: version,
            prefixByteCount: prefix.count,
            requestedLength: requestedLength
        )
        return isDTS
    }

    private func buildCueSongs(
        from item: RemoteFileItem,
        descriptors: [CueTrackDescriptor],
        sidecarIndex: SidecarHintResolver.DirectoryIndex,
        cueImageCount: Int
    ) -> [Song] {
        // 每一轨先认自己的分轨歌词,整轨同名的那份(提示里带的)只在没有时兜底。
        let audioBasename = (item.name as NSString).deletingPathExtension
        var trackLyricsBySheet: [String: [Int: RemoteFileItem]] = [:]
        for (cuePath, sheetDescriptors) in Dictionary(grouping: descriptors, by: \.cuePath) {
            trackLyricsBySheet[cuePath] = sidecarIndex.cueTrackLyrics(
                tracks: sheetDescriptors.map { descriptor in
                    CueTrackLyricsSidecarPolicy.Track(
                        number: descriptor.track.number,
                        title: descriptor.track.title,
                        performer: descriptor.track.performer ?? descriptor.albumPerformer
                    )
                },
                audioBasename: audioBasename,
                cueBasename: (sheetDescriptors[0].cueName as NSString).deletingPathExtension,
                cueImageCount: cueImageCount
            )
        }
        return descriptors.compactMap { descriptor in
            guard let start = descriptor.track.startTime else { return nil }
            let inferredContainerDuration = descriptor.format == .dts
                ? AudioDurationPolicy.provisionalStandaloneDTSDuration(
                    fileSize: item.size,
                    fileExtension: (item.name as NSString).pathExtension
                )
                : nil
            let end = descriptor.track.endTime
                ?? inferredContainerDuration.flatMap { $0 > start ? $0 : nil }
            let artist = descriptor.track.performer ?? descriptor.albumPerformer
            let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: descriptor.albumPerformer,
                trackArtistName: artist
            )
            let artistID = artist.map { hash($0.lowercased()) }
            let albumID: String? = if let albumArtist, let album = descriptor.albumTitle {
                hash("\(albumArtist.lowercased()):\(album.lowercased())")
            } else {
                nil
            }
            let fallbackTitle = String(
                format: String(localized: "cue_track_title_format"),
                descriptor.track.number
            )
            let itemIdentity = SourceSongIdentityMaterialPolicy.itemIdentity(
                path: item.path,
                providerID: item.providerID,
                usesStableProviderIdentity: connector
                    is any StableProviderSongIdentityConnector
            )
            let songID = hash(
                "\(sourceID):\(itemIdentity)#cue:\(descriptor.cuePath)#track:\(descriptor.track.number)"
            )
            return Song(
                id: songID,
                title: descriptor.track.title ?? fallbackTitle,
                albumID: albumID,
                artistID: artistID,
                albumTitle: descriptor.albumTitle,
                artistName: artist,
                albumArtistName: albumArtist,
                trackNumber: descriptor.track.number,
                duration: end.map { max(0, $0 - start) } ?? 0,
                fileFormat: descriptor.format,
                filePath: item.path,
                sourceID: sourceID,
                fileSize: item.size,
                genre: descriptor.genre,
                year: descriptor.year,
                lastModified: item.modifiedDate,
                coverArtFileName: item.sidecarHints?.coverPath,
                lyricsFileName: trackLyricsBySheet[descriptor.cuePath]?[descriptor.track.number]?.path
                    ?? item.sidecarHints?.lyricsPath,
                mvPath: item.sidecarHints?.mvPath,
                cueSheetPath: descriptor.cuePath,
                cueStartTime: start,
                cueEndTime: end,
                revision: item.revision
            )
        }
    }

    private func reuseCueSongIdentities(
        in incoming: inout [Song],
        priorSongIDs: [String],
        existingByID: [String: Song]
    ) {
        let priorSongs = priorSongIDs.compactMap { existingByID[$0] }
        let grouped = Dictionary(grouping: priorSongs) { $0.trackNumber }
        for index in incoming.indices {
            guard let trackNumber = incoming[index].trackNumber,
                  let matches = grouped[trackNumber],
                  matches.count == 1,
                  let existing = matches.first else { continue }
            incoming[index].id = existing.id
            incoming[index].dateAdded = existing.dateAdded
        }
    }

    /// A CUE track already in the library, met again in a listing of its
    /// image. While the image and the track's cue entry are unchanged the row
    /// keeps what was read into it and only follows the image's path,
    /// identity and sidecars; otherwise the rebuilt track replaces it.
    private func carriedOverCueTrack(existing: Song, rebuilt cueSong: Song, cueImage: RemoteFileItem) -> Song {
        if songContentChanged(existing: existing, incoming: cueSong) {
            var replacement = cueSong
            replacement.dateAdded = existing.dateAdded
            return SongUserMetadataPolicy.preservingUserEdits(from: existing, in: replacement)
        }
        var refreshed = existing
        refreshed.filePath = cueSong.filePath
        refreshed.fileSize = cueSong.fileSize
        refreshed.lastModified = cueSong.lastModified ?? existing.lastModified
        refreshed.revision = cueSong.revision ?? existing.revision
        applySidecarHints(from: cueImage, to: &refreshed)
        // 整轨的提示只带整张专辑的同名歌词;每一轨按自己挑出的分轨歌词对账。
        refreshed.lyricsFileName = SourceSidecarReferencePolicy.reconciledReference(
            existing: existing.lyricsFileName,
            incoming: cueSong.lyricsFileName,
            currentParentPath: cueImage.parentPath ?? (cueImage.path as NSString).deletingLastPathComponent,
            authoritative: cueImage.sidecarHints?.isAuthoritative == true
        )
        refreshed.cueSheetPath = cueSong.cueSheetPath
        refreshed.cueStartTime = cueSong.cueStartTime
        refreshed.cueEndTime = cueSong.cueEndTime
        return refreshed
    }

    /// Whether the file at a stored row's path was replaced: its size,
    /// modification time or provider revision differ, or the listing reports
    /// one of the latter two for the first time. The tags read into the row
    /// never count — a bare row built from the file name never matches them.
    private static func fileIdentityChanged(existing: Song, item: RemoteFileItem) -> Bool {
        let sizeChanged = item.size > 0 && existing.fileSize > 0 && item.size != existing.fileSize
        let mtimeChanged: Bool = {
            guard let a = item.modifiedDate, let b = existing.lastModified else { return false }
            return a != b
        }()
        let revisionChanged: Bool = {
            guard let a = item.revision, let b = existing.revision else { return false }
            return a != b
        }()
        let revisionAdded = item.revision != nil && existing.revision == nil
        let mtimeAdded = item.modifiedDate != nil && existing.lastModified == nil
        return sizeChanged || mtimeChanged || revisionChanged || revisionAdded || mtimeAdded
    }

    private func songContentChanged(existing: Song, incoming: Song) -> Bool {
        let sizeChanged = incoming.fileSize > 0
            && existing.fileSize > 0
            && incoming.fileSize != existing.fileSize
        let mtimeChanged: Bool = {
            guard let a = incoming.lastModified, let b = existing.lastModified else { return false }
            return a != b
        }()
        let revisionChanged: Bool = {
            guard let a = incoming.revision, let b = existing.revision else { return false }
            return a != b
        }()
        // First-time fingerprint/mtime backfill — not a content change,
        // but still needs to flow through addSongs so the merge path
        // refreshes existing.revision / existing.lastModified. Without
        // this, a connector that newly surfaces revision would see its
        // updates dropped at the scanner boundary and never reach the
        // library, leaving same-size overwrite detection permanently
        // blind on existing rows.
        let revisionAdded = incoming.revision != nil && existing.revision == nil
        let mtimeAdded = incoming.lastModified != nil && existing.lastModified == nil
        let cueChanged = existing.cueStartTime != incoming.cueStartTime
            || existing.cueEndTime != incoming.cueEndTime
            || existing.title != incoming.title
            || existing.artistName != incoming.artistName
            || existing.albumArtistName != incoming.albumArtistName
            || existing.albumTitle != incoming.albumTitle
            || existing.trackNumber != incoming.trackNumber
            // 扫描按扩展名猜格式, 回填按文件签名修正格式 —— 两者对同一份字节
            // 给出不同答案是常态。见 AudioFormat.describeSameBytes。
            || !AudioFormat.describeSameBytes(existing.fileFormat, incoming.fileFormat)
        return sizeChanged || mtimeChanged || revisionChanged || revisionAdded || mtimeAdded
            || cueChanged
    }

    private func refreshServerMetadata(existing: Song, incoming: Song) -> Song {
        if existing.userMetadataEditedAt != nil {
            var refreshed = SongUserMetadataPolicy.preservingUserEdits(
                from: existing,
                in: incoming
            )
            if refreshed.duration <= 0 { refreshed.duration = incoming.duration }
            if refreshed.fileSize <= 0 { refreshed.fileSize = incoming.fileSize }
            if refreshed.bitRate == nil { refreshed.bitRate = incoming.bitRate }
            if refreshed.sampleRate == nil { refreshed.sampleRate = incoming.sampleRate }
            if refreshed.bitDepth == nil { refreshed.bitDepth = incoming.bitDepth }
            if refreshed.audioCodec == nil { refreshed.audioCodec = existing.audioCodec }
            return ServerSongCatalogMergePolicy.mergingAddedDates(
                existing: existing, incoming: incoming, into: refreshed
            )
        }

        var refreshed = existing
        // The server owns the location: a carried row keeps its song ID while
        // the id in its path follows the server.
        if !incoming.filePath.isEmpty { refreshed.filePath = incoming.filePath }

        if existing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || MediaMetadataTextRepair.isSuspicious(existing.title) {
            refreshed.title = incoming.title
        }
        if (existing.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.artistName)),
           existing.artistName != incoming.artistName
            || existing.sourceArtistNames != incoming.sourceArtistNames {
            refreshed.artistName = incoming.artistName
            refreshed.sourceArtistNames = incoming.sourceArtistNames
            refreshed.artistID = incoming.artistID
        }
        if (existing.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.albumTitle)),
           existing.albumTitle != incoming.albumTitle {
            refreshed.albumTitle = incoming.albumTitle
            refreshed.albumID = incoming.albumID
        }
        // 一个只是回退成曲目艺术家的旧值不是服务端给过的答案, 必须让这次
        // 列表里真正的专辑艺术家覆盖它 —— 否则同一张专辑会一直按各自的曲目
        // 艺术家散成多张同名专辑。
        if (existing.albumArtistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.albumArtistName)
            || AlbumGroupingPolicy.isTrackArtistFallback(
                albumArtistName: existing.albumArtistName,
                trackArtistName: existing.artistName
            )),
           existing.albumArtistName != incoming.albumArtistName {
            refreshed.albumArtistName = incoming.albumArtistName
            refreshed.albumID = incoming.albumID
        }
        if existing.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.genre) {
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
        if refreshed.audioCodec == nil { refreshed.audioCodec = incoming.audioCodec }
        if refreshed.coverArtFileName == nil { refreshed.coverArtFileName = incoming.coverArtFileName }

        return ServerSongCatalogMergePolicy.mergingAddedDates(
            existing: existing, incoming: incoming, into: refreshed
        )
    }

    /// Applies the three-state sidecar result from a complete directory
    /// listing. Nil from a non-authoritative connector means "unknown"; nil
    /// from an authoritative listing can clear only a provider path in the
    /// currently listed directory. Local cache names and sidecars that still
    /// live in an old directory after an audio-only move are retained.
    private func applySidecarHints(from item: RemoteFileItem, to song: inout Song) {
        guard let hints = item.sidecarHints else { return }
        let parent = item.parentPath ?? (item.path as NSString).deletingLastPathComponent
        song.coverArtFileName = SourceSidecarReferencePolicy.reconciledReference(
            existing: song.coverArtFileName,
            incoming: hints.coverPath,
            currentParentPath: parent,
            authoritative: hints.isAuthoritative,
            preserveExisting: song.userMetadataEditedAt != nil
        )
        song.lyricsFileName = SourceSidecarReferencePolicy.reconciledReference(
            existing: song.lyricsFileName,
            incoming: hints.lyricsPath,
            currentParentPath: parent,
            authoritative: hints.isAuthoritative
        )
        song.mvPath = SourceSidecarReferencePolicy.reconciledReference(
            existing: song.mvPath,
            incoming: hints.mvPath,
            currentParentPath: parent,
            authoritative: hints.isAuthoritative
        )
        observeCoverRevision(hints: hints, song: song)
    }

    /// 封面直接指着文件夹里那张图的歌:图原地换了内容(路径不变)时丢掉本机缓存的封面,
    /// 否则界面先读缓存,会一直显示换之前的图。
    private func observeCoverRevision(hints: SidecarHints, song: Song) {
        guard let coverPath = hints.coverPath,
              song.coverArtFileName == coverPath,
              let signature = hints.coverSignature else { return }
        let store = MetadataAssetStore.shared
        var tracker = coverRevisions
            ?? SidecarCoverRevisionTracker(signatures: store.sidecarCoverRevisions(sourceID: sourceID))
        let observation = tracker.observe(coverPath: coverPath, signature: signature)
        coverRevisions = tracker
        let isStale: Bool
        switch observation {
        case .unchanged:
            return
        case .changed:
            isStale = true
        case .firstSeen:
            isStale = SidecarCoverRevisionTracker.cacheIsStale(
                cachedAt: store.coverCacheDate(forSongID: song.id),
                fileModifiedAt: hints.coverModifiedDate
            )
        }
        guard isStale else { return }
        store.invalidateCoverCacheSync(forSongID: song.id)
        coverRefreshedSongs.append(song)
    }

    /// 一个目录的旁挂文件索引。分碟子文件夹(CD1、Disc 2)自己没有封面图时带上上一层专辑
    /// 文件夹的那张;上一层这次已经列过就直接用,否则(续扫、只同步变了的目录)按路径列一次。
    private func directoryIndex(
        _ siblings: [RemoteFileItem],
        of directory: String
    ) async -> SidecarHintResolver.DirectoryIndex {
        let index = SidecarHintResolver.DirectoryIndex(siblings)
        let ownCover = index.folderCover()
        // 「音乐」这类整个曲库的根目录里那张图不是哪张专辑的封面。
        if !FolderCoverNamePolicy.isGenericDirectory(named: (directory as NSString).lastPathComponent) {
            for child in siblings where child.isDirectory && DiscFolderPolicy.isDiscFolderName(child.name) {
                discFolderParentCovers[child.path] = .some(ownCover)
            }
        }
        guard ownCover == nil else { return index }
        if let known = discFolderParentCovers[directory] {
            return index.inheriting(folderCover: known)
        }
        guard let parent = DiscFolderPolicy.parentDirectory(ofDiscFolder: directory),
              !FolderCoverNamePolicy.isGenericDirectory(named: (parent as NSString).lastPathComponent)
        else { return index }
        let parentCover = (try? await connector.listFiles(at: parent))
            .flatMap { SidecarHintResolver.DirectoryIndex($0).folderCover() }
        discFolderParentCovers[directory] = .some(parentCover)
        return index.inheriting(folderCover: parentCover)
    }

    private func finishCoverRevisions() {
        if let tracker = coverRevisions, tracker.hasChanges {
            MetadataAssetStore.shared.storeSidecarCoverRevisions(tracker.signatures, sourceID: sourceID)
        }
        coverRevisions = nil
        discFolderParentCovers = [:]
        let songs = coverRefreshedSongs
        coverRefreshedSongs = []
        guard !songs.isEmpty else { return }
        plog("🖼️ folder cover replaced, dropped cached covers songs=\(songs.count) source=\(sourceID)")
        Task { @MainActor in CachedArtworkView.invalidateCache(forSongs: songs) }
    }

    private struct SidecarRefs {
        var coverPath: String?   // e.g. /Music/Album/cover.jpg
        var lyricsPath: String?  // e.g. /Music/Album/song.lrc
        var mvPath: String?      // e.g. /Music/Album/song.mp4
    }

    /// Detect sidecar files (cover art, lyrics, MV) by checking the local file's directory.
    private func detectSidecarRefs(for item: RemoteFileItem, localURL: URL) -> SidecarRefs {
        var refs = SidecarRefs()

        // Cover art sidecar
        // 引用按「源里同一目录」拼出来,只认和音频同目录的那张。
        if let coverURL = SidecarMetadataLoader.findCoverArt(for: localURL),
           coverURL.deletingLastPathComponent().path == localURL.deletingLastPathComponent().path {
            let parentDir = (item.path as NSString).deletingLastPathComponent
            refs.coverPath = (parentDir as NSString).appendingPathComponent(coverURL.lastPathComponent)
        }

        // Lyrics sidecar
        if let lyricsURL = SidecarMetadataLoader.findLyrics(for: localURL) {
            let parentDir = (item.path as NSString).deletingLastPathComponent
            refs.lyricsPath = (parentDir as NSString).appendingPathComponent(lyricsURL.lastPathComponent)
        }

        // Music video sidecar
        if let mvURL = SidecarMetadataLoader.findMusicVideo(for: localURL) {
            let parentDir = (item.path as NSString).deletingLastPathComponent
            refs.mvPath = (parentDir as NSString).appendingPathComponent(mvURL.lastPathComponent)
        }

        return refs
    }

    /// Build a Song with no audio-byte reads. DTS carried in a `.wav` file is
    /// identified by the shared metadata pass, or by the mandatory remote WAV
    /// probe immediately before playback; reading the same 256 KB here made
    /// every new WAV pay for the header twice.
    private func buildBareSong(from item: RemoteFileItem, songID: String) -> Song {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let format = AudioFormat.from(fileExtension: ext) ?? .mp3
        let fileBaseName = sourceTitle(from: item)
        let provisionalDuration = format == .dts
            ? AudioDurationPolicy.provisionalStandaloneDTSDuration(
                fileSize: item.size,
                fileExtension: ext
              ) ?? 0
            : 0
        return Song(
            id: songID,
            title: fileBaseName,
            albumID: nil,
            artistID: nil,
            albumTitle: nil,
            artistName: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: provisionalDuration,
            fileFormat: format,
            filePath: item.path,
            sourceID: sourceID,
            fileSize: item.size,
            bitRate: nil,
            sampleRate: nil,
            bitDepth: nil,
            genre: nil,
            year: nil,
            lastModified: item.modifiedDate,
            dateAdded: Date(),
            coverArtFileName: item.sidecarHints?.coverPath,
            lyricsFileName: item.sidecarHints?.lyricsPath,
            mvPath: item.sidecarHints?.mvPath,
            revision: item.revision
        )
    }

    /// `server_filename` and the final component of `path` are independent
    /// fields in cloud-list JSON. Prefer a clean value, repair only reversible
    /// mojibake, and keep the provider path itself byte-for-byte untouched.
    private func sourceTitle(from item: RemoteFileItem) -> String {
        let listedName = (item.name as NSString).deletingPathExtension
        let listedExtension = (item.name as NSString).pathExtension
        let pathComponent = (item.path as NSString).lastPathComponent
        let pathExtension = (pathComponent as NSString).pathExtension
        let pathName: String?
        if !listedExtension.isEmpty,
           listedExtension.caseInsensitiveCompare(pathExtension) == .orderedSame {
            pathName = (pathComponent as NSString).deletingPathExtension
        } else {
            // Some providers put an opaque file ID in `path`; it must never
            // replace a damaged display name just because the ID is ASCII.
            pathName = nil
        }
        return MediaMetadataTextRepair.preferred(
            embedded: listedName,
            fromFileName: pathName
        ) ?? listedName
    }

    private func refreshSuspiciousSourceTitle(
        in song: inout Song,
        from item: RemoteFileItem
    ) {
        guard song.userMetadataEditedAt == nil, !song.isCueTrack else { return }
        let fileStem = sourceTitle(from: item)
        if let corrected = MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: song.title,
            artist: song.artistName,
            fileStem: fileStem
        ) {
            if let artist = MetadataTitleResolutionPolicy.artistCorrectingDuplicatedArtist(
                title: song.title,
                artist: song.artistName,
                fileStem: fileStem
            ) {
                // The album artist fell back to the same polluted track
                // artist, so it moves with it to keep the album together.
                if song.albumArtistName == song.artistName {
                    song.albumArtistName = artist
                    if let album = song.albumTitle {
                        song.albumID = hash("\(artist.lowercased()):\(album.lowercased())")
                    }
                }
                song.artistName = artist
                song.artistID = hash(artist.lowercased())
                song.sourceArtistNames = [artist]
                song.artistPinyin = nil
            }
            song.title = corrected
            song.titlePinyin = nil
            return
        }
        guard MediaMetadataTextRepair.isSuspicious(song.title) else { return }
        let candidate = sourceTitle(from: item)
        guard !MediaMetadataTextRepair.isSuspicious(candidate) else { return }
        song.title = candidate
        song.titlePinyin = nil
    }

    private func buildSTRMSong(from item: RemoteFileItem, songID: String) async -> Song? {
        do {
            let descriptor = try await connector.readSTRMDescriptor(
                path: item.path,
                knownSize: item.size > 0 ? item.size : nil
            )
            let fileBaseName = (item.name as NSString).deletingPathExtension
            let fallbackTitle = MediaMetadataTextRepair.fileNameTitle(from: fileBaseName) ?? fileBaseName
            let fallbackArtist = MediaMetadataTextRepair.fileNameArtist(from: fileBaseName)
            return Song(
                id: songID,
                title: descriptor.title ?? fallbackTitle,
                artistName: descriptor.artist ?? fallbackArtist,
                duration: descriptor.duration ?? 0,
                fileFormat: descriptor.format,
                filePath: item.path,
                sourceID: sourceID,
                // Wrapper bytes are not media bytes. Unknown runtime media
                // length deliberately keeps sparse Range streaming disabled.
                fileSize: 0,
                lastModified: item.modifiedDate,
                coverArtFileName: item.sidecarHints?.coverPath,
                lyricsFileName: item.sidecarHints?.lyricsPath,
                mvPath: item.sidecarHints?.mvPath,
                revision: STRMRevision.songRevision(
                    wrapperRevision: item.revision,
                    wrapperSize: item.size,
                    wrapperModifiedDate: item.modifiedDate,
                    contentRevision: descriptor.contentRevision
                )
            )
        } catch {
            plog("⚠️ STRM descriptor skipped: \(item.name) (\(error.localizedDescription))")
            return nil
        }
    }

    private func buildSong(
        from item: RemoteFileItem,
        metadata: MetadataService.SongMetadata,
        songID: String,
        sidecarRefs: SidecarRefs = SidecarRefs()
    ) -> Song {
        let artistID = metadata.artist.map { hash("\($0.lowercased())") }
        let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: metadata.albumArtist,
            trackArtistName: metadata.artist
        )
        let albumID: String? = if let albumArtist, let album = metadata.albumTitle {
            hash("\(albumArtist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        let format = AudioFormat.from(fileExtension: (item.name as NSString).pathExtension) ?? .mp3

        // Priority: sidecar path > embedded/cached > nil
        let coverRef = sidecarRefs.coverPath ?? metadata.coverArtFileName
        let lyricsRef = sidecarRefs.lyricsPath ?? metadata.lyricsFileName
        let mvRef = sidecarRefs.mvPath ?? item.sidecarHints?.mvPath ?? metadata.mvPath

        return Song(
            id: songID,
            title: metadata.title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: metadata.albumTitle,
            artistName: metadata.artist,
            sourceArtistNames: metadata.sourceArtistNames,
            albumArtistName: albumArtist,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            fileFormat: format,
            filePath: item.path,
            sourceID: sourceID,
            fileSize: item.size,
            bitRate: metadata.bitRate,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            genre: metadata.genre,
            year: metadata.year,
            lastModified: item.modifiedDate,
            dateAdded: Date(),
            coverArtFileName: coverRef,
            lyricsFileName: lyricsRef,
            mvPath: mvRef,
            replayGainTrackGain: metadata.replayGainTrackGain,
            replayGainTrackPeak: metadata.replayGainTrackPeak,
            replayGainAlbumGain: metadata.replayGainAlbumGain,
            replayGainAlbumPeak: metadata.replayGainAlbumPeak,
            revision: item.revision,
            audioCodec: ContainerAudioCodecPolicy.storedCodec(metadata.audioCodec, container: format),
            contentMetadata: metadata.contentMetadata
        )
    }

    private func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func recordSyncItem(
        _ item: RemoteFileItem,
        songIDs: [String],
        seenEpoch: Int64 = 0,
        in index: inout [String: SourceSyncIndexedItem]
    ) {
        let stableKey = item.providerID ?? "path:\(item.path.lowercased())"
        let parent = item.parentPath ?? {
            let value = (item.path as NSString).deletingLastPathComponent
            return value.isEmpty || value == "." ? "/" : value
        }()
        index[stableKey] = SourceSyncIndexedItem(
            stableKey: stableKey,
            path: item.path,
            displayName: item.name,
            parentPath: parent,
            isDirectory: item.isDirectory,
            songIDs: songIDs,
            size: item.size,
            modifiedDate: item.modifiedDate,
            revision: item.revision,
            sidecarFingerprint: item.sidecarHints?.snapshotFingerprint,
            seenEpoch: seenEpoch
        )
    }

    nonisolated static func previouslyObservedChildPaths(
        in directory: String,
        identityIndex: [String: SourceSyncIndexedItem],
        existingSongs: [Song]
    ) -> Set<String> {
        var paths = Set(identityIndex.values.compactMap { item in
            immediateChildPath(descendant: item.path, of: directory)
        })
        for song in existingSongs {
            if let path = immediateChildPath(descendant: song.filePath, of: directory) {
                paths.insert(path)
            }
        }
        return paths
    }

    private nonisolated static func immediateChildPath(
        descendant: String,
        of directory: String
    ) -> String? {
        var base = directory
        while base.count > 1, base.hasSuffix("/") {
            base.removeLast()
        }
        if base.isEmpty { base = "/" }
        let prefix = base == "/" ? "/" : "\(base)/"
        let candidate = descendant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count > prefix.count,
              candidate.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let suffix = candidate.dropFirst(prefix.count)
        guard let component = suffix.split(separator: "/", omittingEmptySubsequences: true).first else {
            return nil
        }
        return prefix + component
    }

    private func generatedSongID(for item: RemoteFileItem) -> String {
        let material = SourceSongIdentityMaterialPolicy.itemIdentity(
            path: item.path,
            providerID: item.providerID,
            usesStableProviderIdentity: connector
                is any StableProviderSongIdentityConnector
        )
        return hash("\(sourceID):\(material)")
    }

    private func identityMatch(
        for item: RemoteFileItem,
        stableKey: String,
        baseline: [String: SourceSyncIndexedItem],
        claimedKeys: Set<String>
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        if let direct = baseline[stableKey], !claimedKeys.contains(stableKey) {
            return (stableKey, direct)
        }
        guard connector is any StableProviderSongIdentityConnector else { return nil }
        let probe = SourceSyncIndexedItem(
            stableKey: stableKey,
            path: item.path,
            displayName: item.name,
            parentPath: item.parentPath,
            isDirectory: item.isDirectory,
            size: item.size,
            modifiedDate: item.modifiedDate,
            revision: item.revision,
            sidecarFingerprint: item.sidecarHints?.snapshotFingerprint
        )
        return BaiduSnapshotDiffPolicy.migrationMatch(
            for: probe,
            previousIndex: baseline,
            claimedPreviousKeys: claimedKeys
        )
    }

    private func validateStableIdentity(
        for item: RemoteFileItem,
        observedPaths: inout [String: String]
    ) throws {
        guard connector is any StableProviderSongIdentityConnector,
              let stableKey = item.providerID else { return }
        if observedPaths[stableKey] != nil {
            throw BaiduSnapshotDiffError.duplicateStableKey(stableKey)
        }
        observedPaths[stableKey] = item.path
    }

    private func isMissingPathError(_ error: Error) -> Bool {
        switch error {
        case CloudDriveError.fileNotFound,
             SourceError.pathNotFound,
             SourceError.fileNotFound:
            return true
        default:
            return false
        }
    }

    private nonisolated static func wrapperFingerprintMatches(
        _ indexed: SourceSyncIndexedItem,
        _ item: RemoteFileItem
    ) -> Bool {
        if let lhs = indexed.revision, let rhs = item.revision {
            return lhs == rhs
        }
        guard indexed.size == item.size else { return false }
        if let lhs = indexed.modifiedDate, let rhs = item.modifiedDate {
            return lhs == rhs
        }
        return indexed.revision == nil && item.revision == nil
            && indexed.modifiedDate == nil && item.modifiedDate == nil
    }
}

private enum ConnectorSnapshotReconciliationError: Error {
    case incompleteDirectory(String, [String])
}
