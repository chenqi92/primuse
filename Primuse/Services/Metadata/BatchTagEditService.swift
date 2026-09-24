import Foundation
import PrimuseKit

/// Applies a reviewed set of tag changes to many songs at once.
///
/// Every song goes through the same write path as the single-song tag editor
/// (`SourceManager.writeTagMetadata`), so embedded files, media-server APIs
/// and sidecars behave exactly as they do one at a time. The library is
/// published once at the end: a publish costs as much as the whole library,
/// whether it carries one song or five hundred.
enum BatchTagEditService {
    struct Outcome {
        /// Library rows as they are now, for the songs that were changed.
        var applied: [Song] = []
        /// The same songs before the change, for undo.
        var originals: [Song] = []
        var failures: [Failure] = []
        /// Per-song notes from the write-back (a field the source cannot
        /// store, a partial media-server write).
        var notices: [String] = []
        var coverChanged = false
    }

    /// One successful write: the row as it is now, a note from the source,
    /// and what the file held before (embedded writes only).
    struct Written: Sendable {
        let song: Song
        let notice: String?
        let previousFileTags: EmbeddedMetadataVerification?
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
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        let pending = changes.filter {
            coverData != nil || SongUserMetadataPolicy.editableFieldsChanged(from: $0.original, to: $0.updated)
        }
        guard !pending.isEmpty else { return outcome }
        onProgress(0, pending.count)

        var results: [Int: Result<Written, Failure>] = [:]
        var done = 0
        // Chunks of `concurrency` songs in flight. Each write is main-actor
        // work that spends its time awaiting the network, so the chunk
        // overlaps those waits without a task group.
        var start = 0
        while start < pending.count {
            let end = min(start + concurrency, pending.count)
            var inFlight: [(index: Int, task: Task<Result<Written, Failure>, Never>)] = []
            for index in start..<end {
                let change = pending[index]
                inFlight.append((index, Task { @MainActor in
                    await write(change, coverData: coverData, sourceManager: sourceManager)
                }))
            }
            for item in inFlight {
                results[item.index] = await item.task.value
                done += 1
                onProgress(done, pending.count)
            }
            start = end
        }

        var published: [Song] = []
        for index in pending.indices {
            switch results[index] {
            case .success(let written)?:
                published.append(written.song)
                outcome.originals.append(Self.undoTarget(
                    original: pending[index].original,
                    updated: pending[index].updated,
                    fileBefore: written.previousFileTags
                ))
                if let notice = written.notice { outcome.notices.append("\(written.song.title): \(notice)") }
            case .failure(let failure)?:
                outcome.failures.append(failure)
            case nil:
                break
            }
        }
        guard !published.isEmpty else { return outcome }

        if let coverData {
            outcome.coverChanged = true
            for index in published.indices {
                let songID = published[index].id
                if let fileName = await MetadataAssetStore.shared.storeCover(coverData, for: songID) {
                    published[index].coverArtFileName = fileName
                }
            }
        }

        library.replaceSongs(published)
        for song in published {
            player.syncSongMetadata(song)
        }
        if outcome.coverChanged {
            for (original, song) in zip(outcome.originals, published) {
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
        outcome.applied = published
        return outcome
    }

    @MainActor
    private static func write(
        _ change: (original: Song, updated: Song),
        coverData: Data?,
        sourceManager: SourceManager
    ) async -> Result<Written, Failure> {
        var updated = change.updated
        updated.userMetadataEditedAt = Date()
        do {
            let report = try await sourceManager.writeTagMetadata(
                original: change.original,
                updated: updated,
                coverData: coverData
            )
            if report.shouldAbortLocalSave {
                return .failure(Failure(
                    title: change.original.title,
                    message: report.issueMessage
                        ?? String(localized: "metadata_writeback_error_invalid_state")
                ))
            }
            return .success(Written(
                song: report.updatedSong,
                notice: report.issueMessage,
                previousFileTags: report.previousFileTags
            ))
        } catch {
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
        updated.albumArtistName = AlbumGroupingPolicy.updatedAlbumArtistName(
            existingAlbumArtistName: song.albumArtistName,
            previousTrackArtistName: song.artistName,
            updatedTrackArtistName: updated.artistName
        )
        return updated
    }

    static func cleanupSong(_ song: Song) -> TagCleanupSong {
        TagCleanupSong(
            id: song.id,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            genre: song.genre,
            year: song.year,
            trackNumber: song.trackNumber,
            discNumber: song.discNumber,
            fileName: song.filePath
        )
    }
}
