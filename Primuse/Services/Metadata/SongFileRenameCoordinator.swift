import Foundation
import PrimuseKit

struct SongFileRenameResult: Sendable {
    var song: Song
    var notice: String?
}

enum SongFileRenameError: LocalizedError {
    case unsupported
    case busy
    case plan(AudioFileRenamePlan.Failure)
    case partial(SongFileRenameResult, String)

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "song_file_rename_unsupported")
        case .busy: String(localized: "song_file_rename_busy")
        case .plan(let failure):
            switch failure {
            case .invalidName: String(localized: "song_file_rename_invalid")
            case .collision: String(localized: "song_file_rename_collision")
            case .cue: String(localized: "song_file_rename_cue")
            case .sharedSidecars: String(localized: "song_file_rename_shared")
            case .missingFile: String(localized: "metadata_writeback_error_conflict")
            }
        case .partial(_, let message): message
        }
    }
}

enum PathSongIdentityPolicy {
    /// A renamed track retains its ID. A new file placed at its old path
    /// must not reuse that ID and merge into the renamed track.
    static func unoccupiedID(
        generatedID: String,
        path: String,
        existingPathsByID: [String: String],
        collisionID: (Int) -> String
    ) -> String {
        var candidate = generatedID
        var ordinal = 0
        while let occupiedPath = existingPathsByID[candidate], occupiedPath != path {
            ordinal += 1
            candidate = collisionID(ordinal)
        }
        return candidate
    }
}

protocol PathFileRenameConnector: EmbeddedMetadataWritebackAdapter {
    func canRenameFile(at path: String) async -> Bool
    func renameFileState(at path: String) async throws -> EmbeddedMetadataRemoteFileState
    /// Must refuse an occupied destination, including when another client
    /// creates it after the directory preflight. Never retry a lost response.
    func moveFileWithoutReplacing(from: String, to: String, expected: EmbeddedMetadataRemoteFileState) async throws
}

extension PathFileRenameConnector {
    func canRenameFile(at path: String) async -> Bool { true }
    func renameFileState(at path: String) async throws -> EmbeddedMetadataRemoteFileState {
        try await metadataWritebackState(for: path)
    }
}

extension MusicSourceConnector {
    func canRenameSongFile(_ song: Song) async -> Bool {
        guard !song.isCueTrack, !song.isStreamDescriptor,
              let connector = self as? any PathFileRenameConnector else { return false }
        return await connector.canRenameFile(at: song.filePath)
    }

    func renameSongFile(_ song: Song, stem: String) async throws -> SongFileRenameResult {
        guard await canRenameSongFile(song), let connector = self as? any PathFileRenameConnector else {
            throw SongFileRenameError.unsupported
        }
        return try await SongFileRenameCoordinator.rename(song, stem: stem, using: connector)
    }
}

enum SongFileRenameCoordinator {
    static func rename(_ song: Song, stem: String, using connector: any PathFileRenameConnector) async throws -> SongFileRenameResult {
        let directory = (song.filePath as NSString).deletingLastPathComponent
        let entries = try await connector.listFiles(at: directory)
        let plan: AudioFileRenamePlan
        do {
            plan = try AudioFileRenamePlan(audioPath: song.filePath, stem: stem, entries: entries.map {
                .init(name: $0.name, path: $0.path, isDirectory: $0.isDirectory)
            })
        } catch let failure as AudioFileRenamePlan.Failure {
            throw SongFileRenameError.plan(failure)
        }
        guard !plan.moves.isEmpty else { return SongFileRenameResult(song: song) }
        let originalState = try await connector.metadataWritebackState(for: song.filePath)
        guard originalState.matchesScannedSong(song) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        var states: [String: EmbeddedMetadataRemoteFileState] = [:]
        for move in plan.moves {
            let state = try await connector.renameFileState(at: move.from)
            guard state.hasReliableConflictGuard else { throw EmbeddedMetadataWritebackSourceError.conflict }
            states[move.from] = state
        }
        var completed: [AudioFileRenamePlan.Move] = []
        do {
            for move in plan.moves {
                try Task.checkCancellation()
                do {
                    try await connector.moveFileWithoutReplacing(from: move.from, to: move.to, expected: states[move.from]!)
                    completed.append(move)
                } catch {
                    // A server may commit MOVE and lose its reply. Reconcile
                    // the same directory before deciding which moves to undo.
                    if let listing = try? await connector.listFiles(at: directory),
                       !listing.contains(where: { $0.path == move.from }),
                       listing.contains(where: { $0.path == move.to }),
                       let state = try? await connector.renameFileState(at: move.to),
                       state.matches(states[move.from]!) {
                        completed.append(move)
                    }
                    throw error
                }
            }
        } catch {
            let rollbackMoves = completed
            let rollbackStates = states
            let remaining = await Task {
                var remaining = rollbackMoves
                for move in rollbackMoves.reversed() {
                    do {
                        try await connector.moveFileWithoutReplacing(from: move.to, to: move.from, expected: rollbackStates[move.from]!)
                        remaining.removeAll { $0 == move }
                    } catch {
                        if let listing = try? await connector.listFiles(at: directory),
                           listing.contains(where: { $0.path == move.from }),
                           !listing.contains(where: { $0.path == move.to }),
                           let state = try? await connector.renameFileState(at: move.from),
                           state.matches(rollbackStates[move.from]!) {
                            remaining.removeAll { $0 == move }
                        }
                    }
                }
                return remaining
            }.value
            if remaining.isEmpty { throw error }
            var result = result(for: song, moves: remaining)
            result.notice = String(localized: "song_file_rename_partial") + "\n" + error.localizedDescription
            throw SongFileRenameError.partial(result, result.notice!)
        }
        var result = result(for: song, moves: completed)
        for move in completed {
            await connector.invalidateMetadataWritebackCache(for: move.from)
            await connector.invalidateMetadataWritebackCache(for: move.to)
        }
        if let state = try? await connector.metadataWritebackState(for: result.song.filePath) {
            result.song.fileSize = state.fileSize
            result.song.lastModified = state.modifiedDate
            result.song.revision = state.revision
        } else {
            result.notice = String(localized: "song_file_rename_readback")
        }
        return result
    }

    private static func result(for song: Song, moves: [AudioFileRenamePlan.Move]) -> SongFileRenameResult {
        let paths = Dictionary(uniqueKeysWithValues: moves.map { ($0.from, $0.to) })
        var updated = song
        updated.filePath = paths[song.filePath] ?? song.filePath
        updated.lyricsFileName = song.lyricsFileName.map { paths[$0] ?? $0 }
        updated.coverArtFileName = song.coverArtFileName.map { paths[$0] ?? $0 }
        updated.mvPath = song.mvPath.map { paths[$0] ?? $0 }
        updated.revision = nil
        return SongFileRenameResult(song: updated)
    }
}

#if !os(tvOS)
extension SourceManager {
    func canRenameSongFile(_ song: Song) async -> Bool {
        guard let connector = try? await connectorForSong(song) else { return false }
        return await connector.canRenameSongFile(song)
    }

    func validateSongFileRename(_ song: Song, stem: String) async throws {
        let connector = try await connectorForSong(song)
        guard await connector.canRenameSongFile(song) else { throw SongFileRenameError.unsupported }
        let entries = try await connector.listFiles(at: (song.filePath as NSString).deletingLastPathComponent)
        do {
            _ = try AudioFileRenamePlan(audioPath: song.filePath, stem: stem, entries: entries.map {
                .init(name: $0.name, path: $0.path, isDirectory: $0.isDirectory)
            })
        } catch let failure as AudioFileRenamePlan.Failure { throw SongFileRenameError.plan(failure) }
    }

    func renameSongFile(_ song: Song, stem: String) async throws -> SongFileRenameResult {
        let connector = try await connectorForSong(song)
        guard let persist = metadataFileReplacementHandler else { throw SongFileRenameError.unsupported }
        try await prepareFileRenameHandler?(song.sourceID)
        let finishPlayback = try prepareFileRenamePlayback?(song)
        var playbackSong = song
        defer { finishPlayback?(playbackSong) }
        let result: SongFileRenameResult
        do {
            result = try await connector.renameSongFile(song, stem: stem)
        } catch SongFileRenameError.partial(let partial, let message) {
            playbackSong = partial.song
            deleteAudioCache(for: song)
            try? await persist(song, partial.song)
            throw SongFileRenameError.partial(partial, message)
        }
        playbackSong = result.song
        deleteAudioCache(for: song)
        do {
            try await persist(song, result.song)
        } catch {
            throw SongFileRenameError.partial(result,
                String(localized: "song_file_rename_partial") + "\n" + error.localizedDescription)
        }
        return result
    }
}

extension AudioPlayerService {
    func prepareForSourceFileRename(_ song: Song) throws -> (Song) -> Void {
        let isCurrent = currentSong?.id == song.id
        guard !isCurrent || (!isCastingMode && !isCrossfading) else { throw SongFileRenameError.busy }
        let wasPlaying = isCurrent && (isPlaying || isLoading)
        discardPreparedStart(reason: "source file rename")
        invalidatePreparedQueueSuccessor()
        if isCurrent { suspendPlaybackPreservingSelection(reason: "source file rename") }
        let generation = playbackAdvancePolicy.generation
        return { [weak self] updated in
            guard let self else { return }
            let stillCurrent = self.currentSong?.id == song.id
            let resumedDuringRename = stillCurrent && (self.isPlaying || self.isLoading)
            let shouldResume = stillCurrent && !self.isCastingMode
                && (resumedDuringRename || (wasPlaying && self.playbackAdvancePolicy.generation == generation))
            if resumedDuringRename && !self.isCastingMode {
                self.suspendPlaybackPreservingSelection(reason: "source file rename completed")
            }
            self.syncSongMetadata(updated)
            for index in self.queueEntries.indices where self.queueEntries[index].song.id == updated.id {
                self.queueEntries[index].song.filePath = updated.filePath
                self.queueEntries[index].song.lyricsFileName = updated.lyricsFileName
                self.queueEntries[index].song.coverArtFileName = updated.coverArtFileName
                self.queueEntries[index].song.mvPath = updated.mvPath
                self.queueEntries[index].song.revision = updated.revision
                self.queueEntries[index].song.fileSize = updated.fileSize
                self.queueEntries[index].song.lastModified = updated.lastModified
            }
            if shouldResume { self.resume() }
        }
    }
}
#endif
