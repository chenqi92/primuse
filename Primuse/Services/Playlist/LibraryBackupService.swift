import Foundation
import Observation
import PrimuseKit

/// 评分、评论、「我喜欢」和自建歌单的整份备份(看板 PRIM-38)。文件格式在 Kit
/// `LibraryUserDataBackup`, 恢复时每一项落到哪里在 `LibraryUserDataRestorePolicy`;
/// 这里只管从曲库取数、把备份里的歌对到曲库、照计划写回去。
///
/// 对歌和换了 id 的歌找回标记是同一套规则(`CarriedSongMarksPolicy.select`): 先认导出那台
/// 设备上的歌曲 id, 再按标题、歌手、专辑、时长认唯一的一首; 拿不准的不认, 评分和喜欢交给
/// 待找回的账本, 歌单里留置灰占位, 以后扫到了自动补上。
@MainActor
enum LibraryBackupService {
    struct Restore: Sendable {
        let backup: LibraryUserDataBackup
        let plan: LibraryUserDataRestorePolicy.Plan
    }

    struct Outcome: Sendable {
        var ratings = 0
        var liked = 0
        var playlists = 0
        var waiting = 0
    }

    // MARK: - 导出

    static func makeBackup(library: MusicLibrary, sourcesStore: SourcesStore) -> LibraryUserDataBackup {
        let sourceNames = Dictionary(
            sourcesStore.allSources.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        var tracks: [LibraryUserDataBackup.Track] = []
        var keyBySongID: [String: String] = [:]
        var keyByPendingID: [String: String] = [:]

        func trackKey(forSongID id: String) -> String? {
            if let key = keyBySongID[id] { return key }
            guard let song = library.storedSong(id: id) else { return nil }
            let key = "t\(tracks.count + 1)"
            tracks.append(LibraryUserDataBackup.Track(
                key: key,
                songID: song.id,
                title: song.title,
                artists: PlaylistEntryMatcher.artists(of: song),
                album: song.albumTitle,
                duration: song.duration > 0 ? song.duration : nil,
                trackNumber: song.trackNumber,
                discNumber: song.discNumber,
                fileName: CarriedSongMarks.fileName(fromPath: song.filePath),
                fileSize: song.fileSize > 0 ? song.fileSize : nil,
                sourceName: sourceNames[song.sourceID]
            ))
            keyBySongID[id] = key
            return key
        }

        func memberTrackKey(_ id: String) -> String? {
            guard PlaylistPendingEntry.isPendingID(id) else { return trackKey(forSongID: id) }
            if let key = keyByPendingID[id] { return key }
            guard let entry = library.pendingEntry(id: id) else { return nil }
            let key = "t\(tracks.count + 1)"
            tracks.append(LibraryUserDataBackup.Track(
                key: key,
                title: entry.title,
                artists: entry.artists,
                album: entry.album,
                duration: entry.duration
            ))
            keyByPendingID[id] = key
            return key
        }

        var ratings: [LibraryUserDataBackup.Rating] = []
        for review in library.allLibraryReviews where review.subject.kind == .song && !review.isDeleted {
            let rating = LibraryReviewPreferences.normalizedRating(review.rating)
            let comment = review.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rating != nil || !comment.isEmpty,
                  let key = trackKey(forSongID: review.subject.entityID) else { continue }
            ratings.append(LibraryUserDataBackup.Rating(
                track: key,
                rating: rating,
                comment: comment.isEmpty ? nil : comment,
                ratedAt: review.updatedAt
            ))
        }

        let liked = library.rawSongIDs(forPlaylist: MusicLibrary.likedSongsPlaylistID).compactMap(memberTrackKey)

        let playlists = library.playlistImportMergeTargets.map { playlist in
            LibraryUserDataBackup.PlaylistRecord(
                id: playlist.id,
                name: playlist.name,
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt,
                tracks: library.rawSongIDs(forPlaylist: playlist.id).compactMap(memberTrackKey)
            )
        }

        // 换了 id、还在等的那些: 曲库里已经没有这首, 只有记下的元数据。一起带上,
        // 重装或换设备以后照样能找回。
        var waitingLiked: [String] = []
        for entry in library.carriedSongMarksList() {
            let key = "t\(tracks.count + 1)"
            tracks.append(LibraryUserDataBackup.Track(
                key: key,
                songID: entry.id.hasPrefix("backup:") ? nil : entry.id,
                title: entry.title,
                artists: entry.artists,
                album: entry.album,
                duration: entry.duration,
                fileName: entry.fileName,
                fileSize: entry.fileSize
            ))
            if entry.rating != nil || !(entry.comment ?? "").isEmpty {
                ratings.append(LibraryUserDataBackup.Rating(
                    track: key, rating: entry.rating, comment: entry.comment, ratedAt: entry.createdAt
                ))
            }
            if entry.liked { waitingLiked.append(key) }
        }

        return LibraryUserDataBackup(
            tracks: tracks,
            ratings: ratings,
            liked: liked + waitingLiked,
            playlists: playlists
        )
    }

    /// 写到临时目录, 交给系统分享面板(iOS)或存储面板(Mac)。
    static func exportFile(library: MusicLibrary, sourcesStore: SourcesStore) throws -> URL {
        let backup = makeBackup(library: library, sourcesStore: sourcesStore)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Primuse-Backup-\(formatter.string(from: Date())).json")
        try? FileManager.default.removeItem(at: url)
        try backup.encoded().write(to: url, options: .atomic)
        return url
    }

    // MARK: - 恢复

    /// 读文件、对曲库, 得出预览用的计划。整库匹配在后台跑。
    static func prepareRestore(data: Data, library: MusicLibrary) async throws -> Restore {
        let backup = try await Task.detached(priority: .userInitiated) {
            try LibraryUserDataBackup.decode(data)
        }.value

        var resolutions: [String: String] = [:]
        var unresolved: [CarriedSongMarks] = []
        for track in backup.tracks {
            if let id = track.songID, library.storedSong(id: id) != nil {
                resolutions[track.key] = id
                continue
            }
            // 匹配只认 id 往回映射, 用 `Track.key` 当条目 id, 和真的歌曲 id 撞不上。
            unresolved.append(CarriedSongMarks(
                id: "backup-key:\(track.key)",
                title: track.title,
                artists: track.artists,
                album: track.album,
                duration: track.duration,
                fileSize: track.fileSize,
                fileName: track.fileName,
                origin: .backup
            ))
        }
        if !unresolved.isEmpty {
            let candidates = library.visibleSongs
            let cache = library.playlistEntryMatchKeyCache
            let matched = await Task.detached(priority: .userInitiated) {
                MusicLibrary.matchCarriedMarks(unresolved, against: candidates, keyCache: cache)
            }.value
            for (entryID, songID) in matched {
                resolutions[String(entryID.dropFirst("backup-key:".count))] = songID
            }
        }

        var localRatings: [String: (rating: Int?, comment: String)] = [:]
        for songID in Set(resolutions.values) {
            if let review = library.libraryReview(for: .song(songID)) {
                localRatings[songID] = (review.rating, review.comment)
            }
        }
        let local = LibraryUserDataRestorePolicy.LocalState(
            ratings: localRatings,
            likedSongIDs: Set(library.rawSongIDs(forPlaylist: MusicLibrary.likedSongsPlaylistID)),
            playlists: library.playlistImportMergeTargets.map { (id: $0.id, name: $0.name) }
        )
        return Restore(
            backup: backup,
            plan: LibraryUserDataRestorePolicy.plan(backup, resolutions: resolutions, local: local)
        )
    }

    @discardableResult
    static func apply(
        _ restore: Restore,
        overwritingConflicts: Bool,
        library: MusicLibrary
    ) -> Outcome {
        let plan = restore.plan
        var outcome = Outcome()
        var reviews = plan.reviewWrites
        if overwritingConflicts { reviews += plan.conflictWrites }
        for write in reviews {
            library.updateLibraryReview(for: .song(write.songID), rating: write.rating, comment: write.comment)
        }
        outcome.ratings = Set(reviews.map(\.songID)).count

        if !plan.likedToAdd.isEmpty {
            library.likeSongs(plan.likedToAdd)
            outcome.liked = plan.likedToAdd.count
        }

        let writes = plan.playlistWrites.map { write -> MusicLibrary.PlaylistImportWrite in
            let members = write.members.map { member -> MusicLibrary.PlaylistImportMember in
                switch member {
                case .song(let id):
                    return .song(id)
                case .pending(let track):
                    return .pending(PlaylistPendingEntry(
                        title: track.title,
                        artists: track.artists,
                        album: track.album,
                        duration: track.duration,
                        origin: "backup"
                    ))
                }
            }
            switch write.target {
            case .existing(let id): return .merge(members: members, playlistID: id)
            case .new(let name): return .newPlaylist(name: name, members: members)
            }
        }
        if !writes.isEmpty {
            library.importPlaylists(writes)
            outcome.playlists = writes.count
        }

        if !plan.waiting.isEmpty { library.addCarriedSongMarks(plan.waiting) }
        outcome.waiting = plan.unmatchedTrackCount
        plog("💾 Library backup restored: reviews=\(outcome.ratings) liked=\(outcome.liked) playlists=\(outcome.playlists) waiting=\(plan.waiting.count)")
        return outcome
    }
}

/// 设置页上「备份与恢复」那几颗键的流程: 导出、选文件、预览、执行、结果提示。
/// iPhone/iPad 与 Mac 各自只画界面, 状态都在这里。
@MainActor
@Observable
final class LibraryBackupFlow {
    struct ExportedFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var isWorking = false
    /// 非 nil 时弹出恢复前的预览。
    var pendingRestore: LibraryBackupService.Restore?
    /// iOS 交给分享面板的文件。
    var exportedFile: ExportedFile?
    var notice: Notice?

    func export(library: MusicLibrary, sourcesStore: SourcesStore) {
        do {
            let url = try LibraryBackupService.exportFile(library: library, sourcesStore: sourcesStore)
            #if os(macOS)
            try PlaylistExporter.presentSavePanel(for: url)
            #else
            exportedFile = ExportedFile(url: url)
            #endif
        } catch {
            notice = Notice(
                title: String(localized: "library_backup_export_failed"),
                message: error.localizedDescription
            )
        }
    }

    func importFile(_ result: Result<[URL], Error>, library: MusicLibrary) {
        guard !isWorking else { return }
        let data: Data
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                data = try Data(contentsOf: url)
            } catch {
                notice = Self.readFailure(error.localizedDescription)
                return
            }
        case .failure(let error):
            notice = Self.readFailure(error.localizedDescription)
            return
        }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let restore = try await LibraryBackupService.prepareRestore(data: data, library: library)
                if restore.plan.hasChanges {
                    pendingRestore = restore
                } else {
                    notice = Notice(
                        title: String(localized: "library_backup_restore_title"),
                        message: String(localized: "library_backup_restore_nothing")
                    )
                }
            } catch LibraryUserDataBackup.DecodeError.newerVersion {
                notice = Self.readFailure(String(localized: "library_backup_error_newer"))
            } catch LibraryUserDataBackup.DecodeError.notABackup {
                notice = Self.readFailure(String(localized: "library_backup_error_not_backup"))
            } catch {
                notice = Self.readFailure(error.localizedDescription)
            }
        }
    }

    func confirmRestore(overwritingConflicts: Bool, library: MusicLibrary) {
        guard let restore = pendingRestore else { return }
        pendingRestore = nil
        let outcome = LibraryBackupService.apply(restore, overwritingConflicts: overwritingConflicts, library: library)
        var message = String(
            format: String(localized: "library_backup_restored_format"),
            outcome.ratings, outcome.liked, outcome.playlists
        )
        if outcome.waiting > 0 {
            message += "\n" + String(format: String(localized: "library_backup_restored_waiting_format"), outcome.waiting)
        }
        notice = Notice(title: String(localized: "library_backup_restored_title"), message: message)
    }

    /// 预览里的几行: 评分能补上几首、几首和本机冲突、红心、歌单、曲库里还没有的。
    func previewMessage(for restore: LibraryBackupService.Restore) -> String {
        let plan = restore.plan
        var lines: [String] = []
        let newPlaylists = plan.playlistWrites.filter {
            if case .new = $0.target { return true }
            return false
        }.count
        if plan.restoresRatingCount > 0 {
            lines.append(String(format: String(localized: "library_backup_preview_ratings_format"), plan.restoresRatingCount))
        }
        if !plan.conflicts.isEmpty {
            lines.append(String(format: String(localized: "library_backup_preview_conflicts_format"), plan.conflicts.count))
        }
        if !plan.likedToAdd.isEmpty {
            lines.append(String(format: String(localized: "library_backup_preview_liked_format"), plan.likedToAdd.count))
        }
        if !plan.playlistWrites.isEmpty {
            lines.append(String(
                format: String(localized: "library_backup_preview_playlists_format"),
                plan.playlistWrites.count, newPlaylists
            ))
        }
        if plan.unmatchedTrackCount > 0 {
            lines.append(String(format: String(localized: "library_backup_preview_waiting_format"), plan.unmatchedTrackCount))
        }
        return lines.joined(separator: "\n")
    }

    private static func readFailure(_ message: String) -> Notice {
        Notice(title: String(localized: "library_backup_error_title"), message: message)
    }
}
