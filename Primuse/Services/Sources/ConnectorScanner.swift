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

    init(connector: any MusicSourceConnector, sourceID: String) {
        self.connector = connector
        self.sourceID = sourceID
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

    struct ScanUpdate: Sendable {
        /// Total songs known for this source after this scan run — existing
        /// (from prior runs) plus anything newly discovered. Drives the
        /// source-card "X songs" badge.
        var scannedCount: Int
        /// Songs the scan walk added this run. Stays 0 when re-scanning a
        /// source that hasn't gained any files. Drives the in-progress
        /// "新增 N 首" label so users can tell a no-op scan from a real one.
        var addedCount: Int
        var totalCount: Int
        var currentFile: String
        var songs: [Song]
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

    /// Reconciles only provider directories named by a native change feed.
    /// Each directory listing is authoritative for that directory, while the
    /// rest of the source snapshot is carried forward unchanged.
    func reconcileChangedDirectories(
        _ directories: Set<String>,
        deletedStableKeys: Set<String>,
        existingSongs: [Song],
        existingIndex: [String: SourceSyncIndexedItem],
        scanEpoch: Int64,
        requiresCompleteListings: Bool = false
    ) async throws -> IncrementalResult {
        try await connector.connect()
        var songsByID = Dictionary(
            existingSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var index = existingIndex
        var changedCount = 0
        // Keep the pre-deletion identity baseline. If an item reappears between
        // the provider snapshot and the authoritative parent re-list, it must
        // recover its existing Song ID instead of being recreated.
        let reconciliationBaseline = existingIndex
        var observedStablePaths: [String: String] = [:]

        for key in deletedStableKeys {
            if let entry = index.removeValue(forKey: key) {
                for id in entry.songIDs { songsByID[id] = nil }
                changedCount += 1
            }
        }
        // The mutable index may already point at the new parent by the time the
        // old parent is reconciled (directory processing order is arbitrary).

        for directory in directories.sorted() {
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
                continue
            }
            if requiresCompleteListings,
               let budgeted = connector as? any SnapshotReconciliationBudgetConnector {
                try await budgeted.checkSnapshotReconciliationBudget()
            }
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
                guard let item = SidecarHintResolver.scannableItem(rawItem, siblings: siblings) else { continue }
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
                    var cueSongs = buildCueSongs(from: item, descriptors: descriptors)
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
                            songsByID[song.id] = SongUserMetadataPolicy.preservingUserEdits(
                                from: existing,
                                in: song
                            )
                        } else {
                            songsByID[song.id] = song
                        }
                    }
                    recordSyncItem(
                        item,
                        songIDs: cueSongs.map(\.id),
                        seenEpoch: scanEpoch,
                        in: &index
                    )
                    changedCount += 1
                    continue
                }

                let preferredID = oldEntry?.songIDs.count == 1
                    ? oldEntry?.songIDs.first
                    : nil
                let songID = preferredID ?? generatedSongID(for: item)
                let incoming = await buildBareSong(from: item, songID: songID)
                if var old = preferredID.flatMap({ id in existingSongs.first { $0.id == id } }) {
                    if !songContentChanged(existing: old, incoming: incoming) {
                        old.filePath = item.path
                        old.fileSize = item.size
                        old.lastModified = item.modifiedDate ?? old.lastModified
                        old.revision = item.revision ?? old.revision
                        applySidecarHints(from: item, to: &old)
                        refreshSuspiciousSourceTitle(in: &old, from: item)
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
                    songsByID[incoming.id] = incoming
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
        }

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
        // Each update carries the complete song snapshot. An unbounded stream
        // retains every pending snapshot when a fast remote listing outruns the
        // consumer, and subsequent appends then copy those shared arrays. Keep
        // only the newest pending snapshot; the final yield below still carries
        // the complete scan result.
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
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
                    var existingByID: [String: Song] = [:]
                    existingByID.reserveCapacity(existingSongs.count)
                    for song in existingSongs { existingByID[song.id] = song }
                    var allSongIndexByID: [String: Int] = [:]
                    allSongIndexByID.reserveCapacity(existingSongs.count)
                    for (i, song) in allSongs.enumerated() { allSongIndexByID[song.id] = i }
                    let initialCount = max(existingSongs.count, startingCount)
                    var scannedCount = totalCount > 0 ? min(initialCount, totalCount) : initialCount
                    var addedCount = 0
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
                    var lastProgressYieldAt = Date()

                    if !existingSongs.isEmpty {
                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
                                addedCount: addedCount,
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

                                for try await scannedSong in stream {
                                    try Task.checkCancellation()
                                    encounteredSongIDs.insert(scannedSong.song.id)
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
                                                totalCount: totalCount,
                                                currentFile: scannedSong.displayName,
                                                songs: allSongs
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
                                                    existingByID[scannedSong.song.id] = refreshed
                                                }
                                            }
                                            continue
                                        }
                                        // Replaced — overwrite the entry already in
                                        // allSongs so the next library flush sees the
                                        // fresh size/mtime/sidecars instead of merging
                                        // back to stale metadata.
                                        let replacement = SongUserMetadataPolicy.preservingUserEdits(
                                            from: existing,
                                            in: scannedSong.song
                                        )
                                        if let idx = allSongIndexByID[scannedSong.song.id] {
                                            allSongs[idx] = replacement
                                        }
                                        existingByID[scannedSong.song.id] = replacement
                                        continue
                                    }

                                    scannedCount += 1
                                    addedCount += 1
                                    allSongs.append(scannedSong.song)
                                    allSongIndexByID[scannedSong.song.id] = allSongs.count - 1
                                    existingByID[scannedSong.song.id] = scannedSong.song

                                    // Server-side song scanners can enumerate
                                    // thousands of tracks faster than the UI can
                                    // persist a full snapshot. Coalesce progress
                                    // just like the generic file scanner below.
                                    if addedCount % Self.progressYieldStride == 0 {
                                        lastProgressYieldAt = Date()
                                        continuation.yield(
                                            ScanUpdate(
                                                scannedCount: scannedCount,
                                                addedCount: addedCount,
                                                totalCount: totalCount,
                                                currentFile: scannedSong.displayName,
                                                songs: allSongs
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

                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
                                addedCount: addedCount,
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

                    continuation.yield(
                        ScanUpdate(
                            scannedCount: scannedCount,
                            addedCount: addedCount,
                            totalCount: totalCount,
                            currentFile: pendingDirectories.last ?? "",
                            songs: allSongs,
                            resumeState: SourceScanResumeState(
                                pendingDirectories: pendingDirectories,
                                encounteredSongIDs: encounteredSongIDs,
                                index: syncIndex
                            )
                        )
                    )

                    while let directory = pendingDirectories.popLast() {
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
                                totalCount: totalCount,
                                currentFile: directory,
                                songs: allSongs,
                                resumeState: inFlightResumeState
                            )
                        )

                        do {
                            let siblings = try await connector.listFiles(at: directory)
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
                                guard let item = SidecarHintResolver.scannableItem(
                                    rawItem,
                                    siblings: siblings
                                ) else { continue }
                                try Task.checkCancellation()

                                if Date().timeIntervalSince(lastProgressYieldAt) >= Self.progressHeartbeatInterval {
                                    lastProgressYieldAt = Date()
                                    continuation.yield(
                                        ScanUpdate(
                                            scannedCount: scannedCount,
                                            addedCount: addedCount,
                                            totalCount: totalCount,
                                            currentFile: item.name,
                                            songs: allSongs
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
                                          existingByID[candidate] != nil else { return nil }
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
                                            existingByID[songID] = refreshed
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
                                            existingByID[songID] = replacement
                                        } else if let idx = allSongIndexByID[songID] {
                                            var refreshed = existing
                                            refreshed.filePath = descriptorSong.filePath
                                            refreshed.lastModified = descriptorSong.lastModified ?? existing.lastModified
                                            applySidecarHints(from: item, to: &refreshed)
                                            allSongs[idx] = refreshed
                                            existingByID[songID] = refreshed
                                        }
                                    } else {
                                        allSongs.append(descriptorSong)
                                        allSongIndexByID[songID] = allSongs.count - 1
                                        existingByID[songID] = descriptorSong
                                        scannedCount += 1
                                        addedCount += 1
                                    }
                                    continue
                                }

                                if let descriptors = cueTracksByAudioPath[item.path], !descriptors.isEmpty {
                                    var cueSongs = buildCueSongs(from: item, descriptors: descriptors)
                                    if let priorEntry {
                                        reuseCueSongIdentities(
                                            in: &cueSongs,
                                            priorSongIDs: priorEntry.songIDs,
                                            existingByID: existingByID
                                        )
                                    }
                                    recordSyncItem(
                                        item,
                                        songIDs: cueSongs.map(\.id),
                                        seenEpoch: scanEpoch,
                                        in: &syncIndex
                                    )
                                    for cueSong in cueSongs {
                                        encounteredSongIDs.insert(cueSong.id)
                                        if let existing = existingByID[cueSong.id] {
                                            if songContentChanged(existing: existing, incoming: cueSong),
                                               let index = allSongIndexByID[cueSong.id] {
                                                var replacement = cueSong
                                                replacement.dateAdded = existing.dateAdded
                                                replacement = SongUserMetadataPolicy.preservingUserEdits(
                                                    from: existing,
                                                    in: replacement
                                                )
                                                allSongs[index] = replacement
                                                existingByID[cueSong.id] = replacement
                                            } else if let index = allSongIndexByID[cueSong.id] {
                                                var refreshed = existing
                                                refreshed.filePath = cueSong.filePath
                                                refreshed.fileSize = cueSong.fileSize
                                                refreshed.lastModified = cueSong.lastModified ?? existing.lastModified
                                                refreshed.revision = cueSong.revision ?? existing.revision
                                                applySidecarHints(from: item, to: &refreshed)
                                                refreshed.cueSheetPath = cueSong.cueSheetPath
                                                refreshed.cueStartTime = cueSong.cueStartTime
                                                refreshed.cueEndTime = cueSong.cueEndTime
                                                allSongs[index] = refreshed
                                                existingByID[cueSong.id] = refreshed
                                            }
                                            continue
                                        }
                                        allSongs.append(cueSong)
                                        allSongIndexByID[cueSong.id] = allSongs.count - 1
                                        existingByID[cueSong.id] = cueSong
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
                                    if !(sizeChanged || mtimeChanged || revisionChanged || revisionAdded || mtimeAdded) {
                                        if let idx = allSongIndexByID[songID] {
                                            var refreshed = existing
                                            refreshed.filePath = item.path
                                            if item.size > 0 { refreshed.fileSize = item.size }
                                            refreshed.lastModified = item.modifiedDate ?? existing.lastModified
                                            refreshed.revision = item.revision ?? existing.revision
                                            applySidecarHints(from: item, to: &refreshed)
                                            refreshSuspiciousSourceTitle(in: &refreshed, from: item)
                                            allSongs[idx] = refreshed
                                            existingByID[songID] = refreshed
                                        }
                                        continue
                                    }
                                    let refreshed = await buildBareSong(from: item, songID: songID)
                                    if let idx = allSongIndexByID[songID] {
                                        var replacement = refreshed
                                        replacement.dateAdded = existing.dateAdded
                                        replacement = SongUserMetadataPolicy.preservingUserEdits(
                                            from: existing,
                                            in: replacement
                                        )
                                        allSongs[idx] = replacement
                                        existingByID[songID] = replacement
                                    }
                                    continue
                                }

                                let newSong = await buildBareSong(from: item, songID: songID)
                                allSongs.append(newSong)
                                allSongIndexByID[songID] = allSongs.count - 1
                                existingByID[songID] = newSong
                                scannedCount += 1
                                addedCount += 1

                                // Yield progress every 20 items — yielding on every
                                // file made the SwiftUI publisher chain the bottleneck
                                // when scanning fast cloud listings.
                                if addedCount % Self.progressYieldStride == 0 {
                                    continuation.yield(
                                        ScanUpdate(
                                            scannedCount: scannedCount,
                                            addedCount: addedCount,
                                            totalCount: totalCount,
                                            currentFile: item.name,
                                            songs: allSongs,
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
                                plog("↷ Dropped stale child directory from scan checkpoint: \(directory)")
                                continuation.yield(
                                    ScanUpdate(
                                        scannedCount: scannedCount,
                                        addedCount: addedCount,
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
                                    totalCount: totalCount,
                                    currentFile: directory,
                                    songs: allSongs,
                                    resumeState: SourceScanResumeState(
                                        pendingDirectories: pendingDirectories + failedDirectories,
                                        encounteredSongIDs: encounteredSongIDs,
                                        index: syncIndex
                                    )
                                )
                            )
                        }
                    }

                    if successfulDirectoryCount == 0, let firstDirectoryError {
                        throw firstDirectoryError
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

                    continuation.yield(
                        ScanUpdate(
                            scannedCount: scannedCount,
                            addedCount: addedCount,
                            totalCount: totalCount,
                            currentFile: "",
                            songs: allSongs,
                            resumeState: SourceScanResumeState(
                                pendingDirectories: failedDirectories,
                                encounteredSongIDs: encounteredSongIDs,
                                index: syncIndex
                            )
                        )
                    )
                    if let firstDirectoryError {
                        continuation.finish(throwing: firstDirectoryError)
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
            let requestedLength = min(max(cueItem.size, 64 * 1024), Int64(1024 * 1024))
            let data = try await connector.fetchMetadataRange(
                path: cueItem.path,
                offset: 0,
                length: requestedLength
            )
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
                   let prefix = try? await connector.fetchMetadataRange(
                       path: audioItem.path,
                       offset: 0,
                       length: 256 * 1024
                   ), FFmpegAudioDecoder.dataContainsDTSSync(prefix) {
                    format = .dts
                }
                for track in cueFile.tracks where track.type == "AUDIO" && track.startTime != nil {
                    result[audioItem.path, default: []].append(CueTrackDescriptor(
                        cuePath: cueItem.path,
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

    private func buildCueSongs(
        from item: RemoteFileItem,
        descriptors: [CueTrackDescriptor]
    ) -> [Song] {
        descriptors.compactMap { descriptor in
            guard let start = descriptor.track.startTime else { return nil }
            let end = descriptor.track.endTime
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
            let fallbackTitle = String(format: "Track %02d", descriptor.track.number)
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
                lyricsFileName: item.sidecarHints?.lyricsPath,
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
            || existing.fileFormat != incoming.fileFormat
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
            return refreshed
        }

        var refreshed = existing

        if existing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || MediaMetadataTextRepair.isSuspicious(existing.title) {
            refreshed.title = incoming.title
        }
        if existing.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.artistName) {
            refreshed.artistName = incoming.artistName
            refreshed.artistID = incoming.artistID
        }
        if existing.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.albumTitle) {
            refreshed.albumTitle = incoming.albumTitle
            refreshed.albumID = incoming.albumID
        }
        if existing.albumArtistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.albumArtistName) {
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
        if refreshed.coverArtFileName == nil { refreshed.coverArtFileName = incoming.coverArtFileName }

        return refreshed
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
        if let coverURL = SidecarMetadataLoader.findCoverArt(for: localURL) {
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

    /// Build a Song with no metadata extraction — title is the filename, all
    /// metadata fields (artist, album, duration, bitRate, etc.) are nil. The
    /// MetadataBackfillService is responsible for filling these in later by
    /// reading just the file's header via HTTP Range.
    private func buildBareSong(from item: RemoteFileItem, songID: String) async -> Song {
        let ext = (item.name as NSString).pathExtension.lowercased()
        var format = AudioFormat.from(fileExtension: ext) ?? .mp3
        // DTS-CD commonly uses a .wav container even though its payload is a
        // DTS bitstream. Mark it before playback so remote URLs take the safe
        // full-download DTS path instead of being rendered as PCM noise.
        if ext == "wav",
           let prefix = try? await connector.fetchMetadataRange(
               path: item.path,
               offset: 0,
               length: 256 * 1024
           ),
           FFmpegAudioDecoder.dataContainsDTSSync(prefix) {
            format = .dts
        }
        let fileBaseName = sourceTitle(from: item)
        return Song(
            id: songID,
            title: fileBaseName,
            albumID: nil,
            artistID: nil,
            albumTitle: nil,
            artistName: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: 0,  // 0 = not yet extracted; backfill service watches for this
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
        guard song.userMetadataEditedAt == nil,
              MediaMetadataTextRepair.isSuspicious(song.title) else {
            return
        }
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
            revision: item.revision
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
