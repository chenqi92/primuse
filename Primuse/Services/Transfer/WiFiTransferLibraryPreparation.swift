#if os(iOS) || os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import PrimuseKit

@MainActor
enum WiFiTransferLibraryPreparation {
    struct Version: Equatable {
        let path: String
        let size: Int64
        let revision: String?
        let sourceScope: String

        init?(song: Song, source: MusicSource) {
            guard source.isEnabled, !source.isDeleted,
                  !MusicSourceSecurityRevision.hasPendingChange(for: source.id),
                  WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: source.type) == nil else { return nil }
            path = song.filePath
            size = song.fileSize
            revision = song.revision
            sourceScope = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        }
    }

    struct Result {
        let selection: WiFiTransferSelection
        let songFiles: [String: Set<String>]
        let failures: [String: String]
        let warnings: [String]
        let versions: [String: Version]
    }

    static func prepare(
        songIDs: [String], library: MusicLibrary, sources: SourcesStore, sourceManager: SourceManager,
        progress: @escaping @MainActor @Sendable (String, Int, Int, Int64, Int64) -> Void
    ) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-library-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ownershipTransferred = false
        defer { if !ownershipTransferred { try? FileManager.default.removeItem(at: directory) } }
        var failures: [String: String] = [:]
        var warnings: [String] = []
        var songDirectories: [String: URL] = [:]
        var versions: [String: Version] = [:]
        for (index, id) in songIDs.enumerated() {
            try Task.checkCancellation()
            guard let song = library.visibleSong(id: id),
                  let source = sources.source(id: song.sourceID), source.isEnabled, !source.isDeleted else {
                failures[id] = WiFiTransferText.string("librarySourceUnavailable")
                continue
            }
            if let reason = WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: source.type) {
                failures[id] = song.title + ": " + WiFiTransferText.string(reason)
                continue
            }
            let sourceScope = MusicSourceSecurityRevision.scopedFingerprint(for: source)
            let folder = directory.appendingPathComponent(WiFiTransferFilePreparation.safeComponent(song.title) + " - " + String(UUID().uuidString.prefix(8)))
            let audio = folder.appendingPathComponent(WiFiTransferFilePreparation.fileName(for: song))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                progress(song.title, index, songIDs.count, 0, song.fileSize)
                let report: @Sendable (Int64) async -> Void = { bytes in
                    await progress(song.title, index, songIDs.count, bytes, song.fileSize)
                }
                if source.type == .local || source.type == .appleMusicLibrary {
                    let connector = try await sourceManager.connectorForSong(song)
                    let url = try await connector.localURL(for: song.filePath)
                    let selection = try await WiFiTransferSelection.prepare([url])
                    guard let file = selection.files.first, selection.files.count == 1,
                          song.fileSize <= 0 || file.size == song.fileSize else { throw WiFiTransferError.invalidRequest }
                    try WiFiTransferFilePreparation.checkSpace(at: folder, additionalBytes: file.size * 2)
                    let copy = try await WiFiTransferSelection.stage(file, in: folder)
                    try FileManager.default.moveItem(at: copy, to: audio)
                    await report(file.size)
                } else if try await copyCompleteCache(song: song, to: audio, sourceManager: sourceManager) == false {
                    let connector = try await sourceManager.connectorForSong(song)
                    // Reserve room for the completed export and the sender's coordinated upload copy.
                    try WiFiTransferFilePreparation.checkSpace(at: folder, additionalBytes: song.fileSize * 2)
                    try await WiFiTransferFilePreparation.download(to: audio, size: song.fileSize, read: { offset, length in
                        try await connector.fetchRange(path: song.filePath, offset: offset, length: length, priority: .background)
                    }, progress: report)
                } else {
                    await report(song.fileSize)
                }
                try Task.checkCancellation()
                guard let latest = library.visibleSong(id: id), latest.filePath == song.filePath,
                      latest.fileSize == song.fileSize, latest.revision == song.revision,
                      let latestSource = sources.source(id: source.id), latestSource.isEnabled, !latestSource.isDeleted,
                      MusicSourceSecurityRevision.scopedFingerprint(for: latestSource) == sourceScope,
                      !MusicSourceSecurityRevision.hasPendingChange(for: source.id) else {
                    throw PreparationError.sourceChanged
                }
                let sidecarWarnings = try await prepareSidecars(song: song, sourceType: source.type, audio: audio, sourceManager: sourceManager)
                try Task.checkCancellation()
                guard let finalSong = library.visibleSong(id: id), finalSong.filePath == song.filePath,
                      finalSong.fileSize == song.fileSize, finalSong.revision == song.revision,
                      let finalSource = sources.source(id: source.id), finalSource.isEnabled, !finalSource.isDeleted,
                      MusicSourceSecurityRevision.scopedFingerprint(for: finalSource) == sourceScope,
                      !MusicSourceSecurityRevision.hasPendingChange(for: source.id) else {
                    throw PreparationError.sourceChanged
                }
                warnings.append(contentsOf: sidecarWarnings)
                songDirectories[id] = folder
                versions[id] = Version(song: finalSong, source: finalSource)
                progress(song.title, index, songIDs.count, song.fileSize, song.fileSize)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if Task.isCancelled { throw CancellationError() }
                failures[id] = song.title + ": " + WiFiTransferText.error(error)
            }
        }
        try Task.checkCancellation()
        let selection = try await WiFiTransferSelection.prepareTemporaryDirectory(directory)
        ownershipTransferred = true
        let songFiles = songDirectories.mapValues { folder in
            Set(selection.files.filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path }.map(\.id))
        }
        return Result(selection: selection, songFiles: songFiles, failures: failures, warnings: warnings, versions: versions)
    }

    private static func copyCompleteCache(song: Song, to destination: URL, sourceManager: SourceManager) async throws -> Bool {
        guard let candidate = await sourceManager.cachedURLForBackgroundRead(for: song),
              let lease = await AudioCacheManager.shared.acquirePathFamilyLease(path: "\(song.sourceID)/\(candidate.lastPathComponent)") else { return false }
        do {
            guard WiFiTransferFilePreparation.isCompleteCache(candidate, expectedSize: song.fileSize) else {
                await AudioCacheManager.shared.releasePathFamilyLease(lease)
                return false
            }
            try WiFiTransferFilePreparation.checkSpace(at: destination.deletingLastPathComponent(), additionalBytes: song.fileSize * 2)
            let copy = try await WiFiTransferSelection.stage(.init(url: candidate, path: destination.lastPathComponent, size: song.fileSize),
                                                           in: destination.deletingLastPathComponent())
            try FileManager.default.moveItem(at: copy, to: destination)
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            return true
        } catch {
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            if Task.isCancelled { throw CancellationError() }
            return false
        }
    }

    private static func prepareSidecars(song: Song, sourceType: MusicSourceType, audio: URL, sourceManager: SourceManager) async throws -> [String] {
        var warnings: [String] = []
        let stem = audio.deletingPathExtension()
        var lyrics = await LyricsLoader.loadSourceText(for: song, sourceManager: sourceManager)
        try Task.checkCancellation()
        if lyrics == nil, let lines = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !lines.isEmpty {
            lyrics = LyricsContentParser.serialize(lines)
        }
        if lyrics == nil, song.lyricsFileName != nil {
            warnings.append(song.title + ": " + WiFiTransferText.string("libraryLyricsUnavailable"))
        }
        try Task.checkCancellation()
        if let lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fileExtension = lyrics.contains("<tt") ? "ttml" : "lrc"
            do { try Data(lyrics.utf8).write(to: stem.appendingPathExtension(fileExtension), options: .atomic) }
            catch { warnings.append(song.title + ": " + WiFiTransferText.string("libraryLyricsUnavailable")) }
        }
        var cover: Data?
        var coverReadFailed = false
        do { cover = try await sourceCover(song: song, sourceType: sourceType, sourceManager: sourceManager) }
        catch { coverReadFailed = true }
        try Task.checkCancellation()
        if cover == nil { cover = await MetadataAssetStore.shared.cachedCoverData(forSongID: song.id) }
        if cover == nil { cover = await MetadataAssetStore.shared.coverData(named: song.coverArtFileName) }
        if cover == nil, let reference = song.coverArtFileName, !reference.isEmpty {
            cover = await sourceManager.artworkData(for: reference, sourceID: song.sourceID, maximumBytes: 20 * 1024 * 1024)
        }
        try Task.checkCancellation()
        if let cover, !cover.isEmpty {
            if let image = CGImageSourceCreateWithData(cover as CFData, nil),
               let identifier = CGImageSourceGetType(image),
               let fileExtension = UTType(identifier as String)?.preferredFilenameExtension,
               PrimuseConstants.supportedCoverExtensions.contains(fileExtension) {
                do { try cover.write(to: stem.appendingPathExtension(fileExtension), options: .atomic) }
                catch { warnings.append(song.title + ": " + WiFiTransferText.string("libraryCoverUnavailable")) }
            } else {
                warnings.append(song.title + ": " + WiFiTransferText.string("libraryCoverUnavailable"))
            }
        } else if song.coverArtFileName != nil || coverReadFailed {
            warnings.append(song.title + ": " + WiFiTransferText.string("libraryCoverUnavailable"))
        }
        return warnings
    }

    private static func sourceCover(song: Song, sourceType: MusicSourceType, sourceManager: SourceManager) async throws -> Data? {
        let connector = try await sourceManager.auxiliaryConnector(for: song)
        let container: String
        let basename: String
        switch sourceType {
        case .local, .synology, .qnap, .webdav, .smb, .ftp, .sftp, .s3, .dropbox, .baiduPan:
            let directory = (song.filePath as NSString).deletingLastPathComponent
            container = directory.isEmpty ? "/" : directory
            basename = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        default:
            guard let resolver = connector as? any LyricsSidecarTargetResolving else { return nil }
            // ID-backed providers resolve the real parent; slicing an opaque song ID cannot do so.
            let target = try await resolver.lyricsSidecarTarget(for: song)
            container = target.containerPath
            basename = (target.fileName as NSString).deletingPathExtension
        }
        let items = try await connector.listFiles(at: container)
        try Task.checkCancellation()
        let audioName = items.first { !$0.isDirectory && $0.path == song.filePath }?.name
        let index = SidecarHintResolver.DirectoryIndex(items)
        guard let item = index.sameNameCover(basename: audioName.map { ($0 as NSString).deletingPathExtension } ?? basename)
            ?? index.folderCover() else { return nil }
        guard !item.isDirectory, item.size > 0, item.size <= 20 * 1024 * 1024 else {
            throw WiFiTransferError.invalidRequest
        }
        let data = try await connector.fetchRange(path: item.path, offset: 0, length: item.size, priority: .background)
        guard data.count == item.size else { throw WiFiTransferError.invalidRequest }
        return data
    }

    enum PreparationError: LocalizedError {
        case sourceChanged
        var errorDescription: String? { WiFiTransferText.string("librarySourceChanged") }
    }
}
#endif
