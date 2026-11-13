import Foundation
import Observation
import PrimuseKit

/// Applies a reviewed set of tag changes to many songs at once.
///
/// Every song goes through the same write path as the single-song tag editor
/// (`SourceManager.writeTagMetadata`), so embedded files, media-server APIs
/// and sidecars behave exactly as they do one at a time. Long-running merges
/// publish completed writes in batches so closing the sheet does not defer
/// every local change until the last remote file finishes.
enum BatchTagEditService {
    struct Outcome {
        /// Library rows as they are now, for the songs that were changed.
        var applied: [Song] = []
        /// The same songs before the change, for undo.
        var originals: [Song] = []
        var failures: [Failure] = []
        /// Per-song notes from the write-back (a field the source cannot
        /// store, a partial media-server write).
        var noticeEntries: [Notice] = []
        var coverChanged = false
        /// Songs whose change is in the library but not in the file: the
        /// source refused it, the connection dropped, or the source never
        /// takes these tags. Listed so the listener can see which files
        /// still carry the old tags and write them again.
        var localOnlyWrites: [LocalOnlyWrite] = []
        var wasCancelled = false

        /// The notes as "title: note" lines.
        var notices: [String] { noticeEntries.map(\.text) }

        var localOnlySongIDs: Set<String> { Set(localOnlyWrites.map(\.songID)) }

        /// The notes of songs that are not already listed in
        /// `localOnlyWrites`, where the same note is shown as the reason.
        var noticesOutsideLocalOnly: [String] {
            let listed = localOnlySongIDs
            return noticeEntries.filter { !listed.contains($0.songID) }.map(\.text)
        }

        /// Folds a retry of the local-only songs back in. Songs the retry
        /// wrote leave the list; songs still kept only in Primuse stay with
        /// the new reason; songs the retry did not reach (stopped, removed
        /// from the library, nothing left to write) stay as they were.
        /// Undo targets stay this run's, and `applied` is only refreshed in
        /// place, so nothing is counted twice. A retry keeps local edits on
        /// failure, so it has no failures to add.
        /// Returns how many songs the retry wrote to their files.
        @discardableResult
        mutating func mergeRetry(_ retry: Outcome) -> Int {
            var stillLocal: [String: LocalOnlyWrite] = [:]
            for entry in retry.localOnlyWrites { stillLocal[entry.songID] = entry }
            let reached = Set(retry.applied.map(\.id))
            var remaining: [LocalOnlyWrite] = []
            var written = 0
            for entry in localOnlyWrites {
                if var again = stillLocal[entry.songID] {
                    again.original = entry.original
                    remaining.append(again)
                } else if reached.contains(entry.songID) {
                    written += 1
                } else {
                    remaining.append(entry)
                }
            }
            localOnlyWrites = remaining

            noticeEntries.removeAll { reached.contains($0.songID) }
            noticeEntries.append(contentsOf: retry.noticeEntries)

            var refreshed: [String: Song] = [:]
            for song in retry.applied { refreshed[song.id] = song }
            if !refreshed.isEmpty {
                applied = applied.map { refreshed[$0.id] ?? $0 }
            }
            return written
        }
    }

    /// A note from the write-back for one song.
    struct Notice: Sendable {
        let songID: String
        /// "title: note", as shown in the write-back report.
        let text: String
    }

    /// A song whose change was saved in Primuse but not written to its file.
    struct LocalOnlyWrite: Identifiable, Sendable {
        let songID: String
        let title: String
        let artist: String?
        let sourceID: String
        let filePath: String
        /// What the source or the write reported; nil when the source never
        /// takes these tags and said nothing more.
        let reason: String?
        /// Writing again could succeed: the source refused or failed this
        /// time. A field the source never takes, or a cover (a retry does
        /// not send it again), would come back the same.
        let canRetry: Bool
        /// The library row before the edit; a retry writes from its tags.
        var original: Song

        var id: String { songID }
    }

    /// One successful write: the row as it is now, a note from the source,
    /// and what the file held before (embedded writes only).
    struct Written: Sendable {
        let song: Song
        let notice: String?
        let previousFileTags: EmbeddedMetadataVerification?
        var isLocalOnly = false
        var canRetry = false
    }

    struct Failure: Identifiable, Error, Sendable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// How many songs are written at once. Embedded write-back downloads,
    /// rewrites and uploads a whole file per song; more than a few in flight
    /// only competes for the same connection.
    static let concurrency = 3

    @MainActor
    static func apply(
        _ changes: [(original: Song, updated: Song)],
        coverData: Data?,
        sourceManager: SourceManager,
        library: MusicLibrary,
        player: AudioPlayerService,
        keepsLocalEditsOnWriteFailure: Bool = false,
        publishesIncrementally: Bool = false,
        shouldCancel: @escaping @MainActor () -> Bool = { false },
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        let pending = await Task.detached(priority: .utility) {
            changes.filter {
                coverData != nil || SongUserMetadataPolicy.editableFieldsChanged(from: $0.original, to: $0.updated)
            }
        }.value
        guard !pending.isEmpty else {
            outcome.wasCancelled = shouldCancel() || Task.isCancelled
            return outcome
        }
        onProgress(0, pending.count)

        // A stop request drains the writes already in flight. Cancelling a
        // replacement halfway through could leave its remote state uncertain.
        await withTaskGroup(of: (Int, Result<Written, Failure>).self) { group in
            var nextIndex = 0
            var done = 0
            var results: [Int: Result<Written, Failure>] = [:]
            var lastPublish = ContinuousClock.now

            while nextIndex < min(concurrency, pending.count), !shouldCancel(), !Task.isCancelled {
                let index = nextIndex
                let change = pending[index]
                group.addTask {
                    (index, await write(change, coverData: coverData, sourceManager: sourceManager,
                                        keepsLocalEditsOnWriteFailure: keepsLocalEditsOnWriteFailure))
                }
                nextIndex += 1
            }
            while let (index, result) = await group.next() {
                results[index] = result
                done += 1
                onProgress(done, pending.count)
                if nextIndex < pending.count, !shouldCancel(), !Task.isCancelled {
                    let index = nextIndex
                    let change = pending[index]
                    group.addTask {
                        (index, await write(change, coverData: coverData, sourceManager: sourceManager,
                                            keepsLocalEditsOnWriteFailure: keepsLocalEditsOnWriteFailure))
                    }
                    nextIndex += 1
                }
                if publishesIncrementally,
                   results.count >= 24 || lastPublish.duration(to: .now) >= .seconds(3) {
                    await publish(results, pending: pending, coverData: coverData,
                                  keepsLocalEditsOnWriteFailure: keepsLocalEditsOnWriteFailure,
                                  library: library, player: player, maintenance: .deferredIncremental, outcome: &outcome)
                    results.removeAll(keepingCapacity: true)
                    lastPublish = .now
                }
            }
            await publish(results, pending: pending, coverData: coverData,
                          keepsLocalEditsOnWriteFailure: keepsLocalEditsOnWriteFailure,
                          library: library, player: player, maintenance: .immediate, outcome: &outcome)
            outcome.wasCancelled = nextIndex < pending.count || shouldCancel() || Task.isCancelled
        }
        if publishesIncrementally { library.flushDeferredLibraryMaintenance(force: true) }
        return outcome
    }

    /// Writes songs whose change was kept only in Primuse to their files
    /// again: from the tags they had before the edit to the row the library
    /// holds now, so a later edit of the same song goes along. A failure
    /// leaves the library row as it is. Merge the result into the run it
    /// came from with `Outcome.mergeRetry`.
    @MainActor
    static func retryLocalOnlyWrites(
        _ entries: [LocalOnlyWrite],
        sourceManager: SourceManager,
        library: MusicLibrary,
        player: AudioPlayerService,
        shouldCancel: @escaping @MainActor () -> Bool = { false },
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async -> Outcome {
        let changes = entries.compactMap { entry -> (original: Song, updated: Song)? in
            guard let current = library.storedSong(id: entry.songID) ?? library.song(id: entry.songID) else {
                return nil
            }
            return (original: retryBase(before: entry.original, current: current), updated: current)
        }
        let outcome = await apply(
            changes,
            coverData: nil,
            sourceManager: sourceManager,
            library: library,
            player: player,
            keepsLocalEditsOnWriteFailure: true,
            shouldCancel: shouldCancel,
            onProgress: onProgress
        )
        let reached = Set(outcome.applied.map(\.id))
        let stillLocal = outcome.localOnlySongIDs
        plog("Batch tag write retry songs=\(entries.count) written=\(reached.subtracting(stillLocal).count) stillLocalOnly=\(stillLocal.count) cancelled=\(outcome.wasCancelled)")
        return outcome
    }

    /// The row a retry writes from: the tags before the edit, on the file
    /// the library knows now. A failed write can still have moved or
    /// re-versioned the file, and the write checks against this identity.
    static func retryBase(before: Song, current: Song) -> Song {
        var base = current
        base.title = before.title
        base.artistName = before.artistName
        base.sourceArtistNames = before.sourceArtistNames
        base.albumTitle = before.albumTitle
        base.albumArtistName = before.albumArtistName
        base.genre = before.genre
        base.year = before.year
        base.trackNumber = before.trackNumber
        base.discNumber = before.discNumber
        return base
    }

    @MainActor
    private static func publish(
        _ results: [Int: Result<Written, Failure>],
        pending: [(original: Song, updated: Song)],
        coverData: Data?,
        keepsLocalEditsOnWriteFailure: Bool,
        library: MusicLibrary,
        player: AudioPlayerService,
        maintenance: LibraryMaintenanceDisposition,
        outcome: inout Outcome
    ) async {
        var published: [Song] = []
        let originalsStart = outcome.originals.count
        for index in results.keys.sorted() {
            switch results[index] {
            case .success(let written)?:
                var song = written.song
                if keepsLocalEditsOnWriteFailure {
                    guard var current = library.song(id: song.id) else { continue }
                    let original = pending[index].original
                    if original.artistName != song.artistName || original.sourceArtistNames != song.sourceArtistNames {
                        current.artistName = song.artistName
                        current.sourceArtistNames = song.sourceArtistNames
                    }
                    if original.albumArtistName != song.albumArtistName { current.albumArtistName = song.albumArtistName }
                    current.userMetadataEditedAt = song.userMetadataEditedAt
                    if song.filePath != original.filePath { current.filePath = song.filePath }
                    if song.revision != original.revision { current.revision = song.revision }
                    if song.fileSize != original.fileSize { current.fileSize = song.fileSize }
                    if song.lastModified != original.lastModified { current.lastModified = song.lastModified }
                    song = current
                }
                published.append(song)
                if written.isLocalOnly {
                    outcome.localOnlyWrites.append(LocalOnlyWrite(
                        songID: song.id,
                        title: song.title,
                        artist: song.artistName,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        reason: written.notice,
                        canRetry: written.canRetry,
                        original: pending[index].original
                    ))
                    // One line per file, so a diagnostic report says which
                    // files still carry the old tags and why.
                    let reason = written.notice.map {
                        $0.replacingOccurrences(of: "\n", with: " | ")
                    } ?? "source does not take these tags"
                    plog("Batch tag write kept only in Primuse songID=\(song.id) sourceID=\(song.sourceID) retryable=\(written.canRetry) reason=\(reason)")
                }
                outcome.originals.append(Self.undoTarget(
                    original: pending[index].original,
                    updated: pending[index].updated,
                    fileBefore: written.previousFileTags
                ))
                if let notice = written.notice {
                    outcome.noticeEntries.append(Notice(songID: song.id, text: "\(written.song.title): \(notice)"))
                }
            case .failure(let failure)?:
                outcome.failures.append(failure)
            case nil:
                break
            }
        }
        guard !published.isEmpty else { return }

        if let coverData {
            outcome.coverChanged = true
            for index in published.indices {
                let songID = published[index].id
                if let fileName = await MetadataAssetStore.shared.storeAttributedCover(coverData, songID: songID, origin: .selected) {
                    published[index].coverArtFileName = fileName
                }
            }
        }

        library.replaceSongs(published, maintenance: maintenance)
        if coverData != nil {
            SongTagEditStore.shared.recordUserChosenCovers(songIDs: published.map(\.id))
        }
        for song in published {
            player.syncSongMetadata(song)
        }
        if outcome.coverChanged {
            for (original, song) in zip(outcome.originals.dropFirst(originalsStart), published) {
                CachedArtworkView.invalidateCache(for: song.id)
                if let oldRef = original.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
                if let newRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: newRef)
                }
            }
            player.forceRefreshNowPlayingArtwork()
        }
        outcome.applied.append(contentsOf: published)
    }

    @MainActor
    private static func write(
        _ change: (original: Song, updated: Song),
        coverData: Data?,
        sourceManager: SourceManager,
        keepsLocalEditsOnWriteFailure: Bool
    ) async -> Result<Written, Failure> {
        var updated = change.updated
        updated.userMetadataEditedAt = Date()
        do {
            let report = try await sourceManager.writeTagMetadata(
                original: change.original,
                updated: updated,
                coverData: coverData
            )
            if report.shouldAbortLocalSave && !keepsLocalEditsOnWriteFailure {
                return .failure(Failure(
                    title: change.original.title,
                    message: report.issueMessage
                        ?? String(localized: "metadata_writeback_error_invalid_state")
                ))
            }
            var saved = report.updatedSong
            if keepsLocalEditsOnWriteFailure, let relocated = report.replacementAfterFailedVerification {
                saved.filePath = relocated.filePath
                saved.fileSize = relocated.fileSize
                saved.revision = relocated.revision
                saved.lastModified = relocated.lastModified
            }
            let keptLocal = report.fields.filter {
                switch $0.disposition {
                case .localOnly, .failed, .unsupported: true
                case .unchanged, .written: false
                }
            }
            let onlyLocal = !keptLocal.isEmpty
            // A refused or failed tag may go through next time (permission
            // fixed, connection back). A tag the source never takes comes
            // back the same, and a retry does not send the cover again.
            let deniedThisTime = report.localSaveNotice != nil
            let canRetry = !keptLocal.contains { $0.field == .cover } && keptLocal.contains {
                switch $0.disposition {
                case .failed: true
                case .localOnly: deniedThisTime
                case .unsupported, .unchanged, .written: false
                }
            }
            return .success(Written(
                song: saved,
                notice: report.issueMessage,
                previousFileTags: report.previousFileTags,
                isLocalOnly: onlyLocal,
                canRetry: canRetry
            ))
        } catch {
            if keepsLocalEditsOnWriteFailure {
                return .success(Written(song: updated, notice: error.localizedDescription, previousFileTags: nil,
                                        isLocalOnly: true, canRetry: coverData == nil))
            }
            return .failure(Failure(title: change.original.title, message: error.localizedDescription))
        }
    }

    /// What undo writes back for one song: the library row before the edit,
    /// with each changed field taken from the file itself when the write
    /// reported it. A row can lag its file (tags not read yet), and undo
    /// must restore the file, not the gap.
    static func undoTarget(
        original: Song,
        updated: Song,
        fileBefore: EmbeddedMetadataVerification?
    ) -> Song {
        guard let before = fileBefore else { return original }
        var target = original
        let changed = TagMetadataWritebackField.changedFields(from: original, to: updated, includesCover: false)
        if changed.contains(.title), let title = before.title { target.title = title }
        if changed.contains(.artist) { target.artistName = before.artist }
        if changed.contains(.albumArtist) { target.albumArtistName = before.albumArtist }
        if changed.contains(.album) { target.albumTitle = before.albumTitle }
        if changed.contains(.genre) { target.genre = before.genre }
        if changed.contains(.year) { target.year = before.year }
        if changed.contains(.trackNumber) { target.trackNumber = before.trackNumber }
        if changed.contains(.discNumber) { target.discNumber = before.discNumber }
        return target
    }

    /// Builds the updated row for one song from the switched-on proposals.
    static func song(_ song: Song, applying proposals: [TagCleanupProposal]) -> Song {
        var updated = song
        for proposal in proposals where proposal.songID == song.id {
            let value = proposal.newValue
            switch proposal.field {
            case .title:
                if let value, !value.isEmpty { updated.title = value }
            case .artist:
                updated.artistName = value
                if updated.artistName != song.artistName { updated.sourceArtistNames = nil }
            case .albumArtist:
                updated.albumArtistName = value
            case .album:
                updated.albumTitle = value
            case .genre:
                updated.genre = value
            case .year:
                updated.year = value.flatMap { Int($0) }
            case .trackNumber:
                updated.trackNumber = value.flatMap { Int($0) }
            case .discNumber:
                updated.discNumber = value.flatMap { Int($0) }
            }
        }
        if updated.artistName != song.artistName,
           !proposals.contains(where: { $0.songID == song.id && $0.field == .albumArtist }) {
            updated.albumArtistName = AlbumGroupingPolicy.updatedAlbumArtistName(
                existingAlbumArtistName: song.albumArtistName,
                previousTrackArtistName: song.artistName,
                updatedTrackArtistName: updated.artistName
            )
        }
        return updated
    }

    static func cleanupSong(_ song: Song) -> TagCleanupSong {
        TagCleanupSong(
            id: song.id,
            title: song.title,
            artist: song.artistName,
            albumArtist: song.albumArtistName,
            album: song.albumTitle,
            genre: song.genre,
            year: song.year,
            trackNumber: song.trackNumber,
            discNumber: song.discNumber,
            fileName: song.filePath
        )
    }
}


@MainActor
@Observable
final class ArtistMergeService {
    static let shared = ArtistMergeService()

    private(set) var isRunning = false
    private(set) var cancellationRequested = false
    private(set) var canonicalName = ""
    private(set) var progress = (done: 0, total: 0)
    private(set) var outcome: BatchTagEditService.Outcome?
    /// The run is writing the local-only songs of `outcome` again.
    private(set) var isRetryingWrites = false
    /// Songs the retries of this merge have written to their files.
    private(set) var rewrittenCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    @discardableResult
    func start(
        songIDs: [String], names: Set<String>, canonicalName: String,
        library: MusicLibrary, sourceManager: SourceManager, player: AudioPlayerService
    ) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        cancellationRequested = false
        outcome = nil
        rewrittenCount = 0
        self.canonicalName = canonicalName
        progress = (0, songIDs.count)
        let songs = songIDs.compactMap { library.song(id: $0) }
        let configuration = library.artistNameConfiguration
        plog("Artist merge started songs=\(songs.count)")
        task = Task {
            let changes = await Task.detached(priority: .utility) {
                songs.map { original in
                    (original: original, updated: ArtistMergePolicy.applying(
                        to: original, names: names, canonicalName: canonicalName, configuration: configuration))
                }
            }.value
            outcome = await BatchTagEditService.apply(
                changes, coverData: nil, sourceManager: sourceManager, library: library, player: player,
                keepsLocalEditsOnWriteFailure: true, publishesIncrementally: true,
                shouldCancel: { self.cancellationRequested }
            ) { done, total in
                self.progress = (done, total)
            }
            plog("Artist merge finished applied=\(outcome?.applied.count ?? 0) localOnly=\(outcome?.localOnlySongIDs.count ?? 0) cancelled=\(outcome?.wasCancelled ?? false)")
            isRunning = false
            task = nil
        }
        return true
    }

    /// Writes the songs the merge kept only in Primuse to their files again.
    /// Runs here rather than in the sheet, so closing it does not stop the
    /// retry; the result is folded into `outcome`.
    @discardableResult
    func retryLocalOnlyWrites(
        library: MusicLibrary, sourceManager: SourceManager, player: AudioPlayerService
    ) -> Bool {
        guard !isRunning, let entries = outcome?.localOnlyWrites.filter(\.canRetry), !entries.isEmpty else {
            return false
        }
        isRunning = true
        isRetryingWrites = true
        cancellationRequested = false
        // The banner keeps showing how far the merge itself got.
        let mergeProgress = progress
        progress = (0, entries.count)
        plog("Artist merge retry started songs=\(entries.count)")
        task = Task {
            let retry = await BatchTagEditService.retryLocalOnlyWrites(
                entries, sourceManager: sourceManager, library: library, player: player,
                shouldCancel: { self.cancellationRequested }
            ) { done, total in
                self.progress = (done, total)
            }
            if var merged = outcome {
                rewrittenCount += merged.mergeRetry(retry)
                outcome = merged
            }
            plog("Artist merge retry finished localOnly=\(outcome?.localOnlyWrites.count ?? 0) rewritten=\(rewrittenCount)")
            progress = mergeProgress
            isRetryingWrites = false
            isRunning = false
            task = nil
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        plog("Artist merge stop requested done=\(progress.done) total=\(progress.total)")
    }

    func clearResult() {
        guard !isRunning else { return }
        outcome = nil
        rewrittenCount = 0
    }
}
