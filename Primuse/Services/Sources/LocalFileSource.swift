import CryptoKit
import Foundation
import PrimuseKit

actor LocalFileSource: ExistingSongAwareScanningConnector, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting: Bool
    private let basePath: URL
    private let referenceRoots: [LocalReferenceRoot]
    private let referenceBookmarksUnavailable: Bool
    private let metadataService = MetadataService()
    private let ffmpegDecoder = FFmpegAudioDecoder()
    /// Native metadata readers are fast and remain the default for large
    /// libraries, including folders backed by a network-mounted volume.
    /// Probe only formats that actually use the FFmpeg compatibility path;
    /// ordinary FLAC/M4A/MP4 rows keep their native metadata unless it is
    /// missing, avoiding a second file open for every scan item.
    private static let ffmpegMetadataProbeExtensions =
        FFmpegAudioDecoder.preferredExtensions
    private static let minimumReadableAudioBytes: Int64 = 1024
    private static let metadataTitleRepairVersion = "v2026_08_formatSpecificTitles"
    /// Sandboxed local references require holding every resolved security scope
    /// for the connector lifetime. A virtual path component is present for
    /// individual files and multi-root selections; one folder keeps `/` as its
    /// root for compatibility with existing macOS sources.
    private struct LocalReferenceRoot: Sendable {
        let virtualPathComponent: String?
        let url: URL
        let isDirectory: Bool
        let usesSecurityScope: Bool
    }

    init(sourceID: String, basePath: URL) {
        self.sourceID = sourceID
        var resolvedBasePath = basePath
        var resolvedRoots: [LocalReferenceRoot] = []
        var bookmarksUnavailable = false

        #if os(iOS) || os(macOS)
        if let references = LocalBookmarkStore.resolveReferences(sourceID: sourceID) {
            if references.isEmpty {
                bookmarksUnavailable = true
            } else {
                resolvedRoots = references.map { reference in
                    LocalReferenceRoot(
                        virtualPathComponent: reference.virtualPathComponent,
                        url: reference.url,
                        isDirectory: reference.isDirectory,
                        usesSecurityScope: reference.url.startAccessingSecurityScopedResource()
                    )
                }
                if resolvedRoots.count == 1,
                   resolvedRoots[0].virtualPathComponent == nil {
                    resolvedBasePath = resolvedRoots[0].url
                }
            }
        }
        #endif

        #if os(iOS)
        // 本地导入源的文件固定在 <当前沙箱>/Documents/LocalMusic。app 数据容器 UUID
        // 会随重装变化, 而持久化到源记录(旧版本还可能经 CloudKit 同步)的绝对 basePath
        // 可能指向已不存在的旧容器, 导致 connect()/路径解析 pathNotFound、歌曲无法播放。
        // 对本地导入源始终按当前容器重算, 不信任存储的 basePath。
        // The normal Files-import source is identified by both its persisted
        // ID and its reserved Documents/LocalMusic root. Older/demo fixtures
        // may reuse the stored ID for a different local directory; forcing
        // those onto LocalMusic makes an otherwise valid source unreachable.
        let isManagedLocalImport = sourceID == LocalImportService.existingSourceID
            && (basePath.lastPathComponent == "LocalMusic"
                || basePath.path.contains("/Documents/LocalMusic"))
        if resolvedRoots.isEmpty, !bookmarksUnavailable, isManagedLocalImport {
            resolvedBasePath = LocalImportService.musicDirectory
        } else if let rebased = PrimuseSandboxPathResolver.existingURL(
            forStoredAbsolutePath: basePath.path
        ), resolvedRoots.isEmpty, !bookmarksUnavailable {
            resolvedBasePath = rebased
        }
        #endif

        self.basePath = resolvedBasePath
        self.referenceRoots = resolvedRoots
        self.referenceBookmarksUnavailable = bookmarksUnavailable
        self.supportsSidecarWriting = resolvedRoots.isEmpty
            || resolvedRoots.allSatisfy(\.isDirectory)
    }

    deinit {
        for root in referenceRoots where root.usesSecurityScope {
            root.url.stopAccessingSecurityScopedResource()
        }
    }

    func connect() async throws {
        if referenceBookmarksUnavailable {
            throw SourceError.credentialUnavailable(
                String(localized: "local_reference_permission_missing")
            )
        }
        if !referenceRoots.isEmpty {
            for root in referenceRoots where !FileManager.default.fileExists(atPath: root.url.path) {
                throw SourceError.pathNotFound(root.url.path)
            }
            return
        }
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            throw SourceError.pathNotFound(basePath.path)
        }
    }

    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if isVirtualReferenceRoot(path) {
            return try referenceRoots.map { root in
                try remoteFileItem(for: root.url, path: virtualPath(for: root))
            }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        let directoryURL = try resolvedURL(for: path, allowRoot: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        )

        return try contents.map { url in
            try remoteFileItem(for: url, path: relativePath(for: url))
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func localURL(for path: String) async throws -> URL {
        let fileURL = try resolvedURL(for: path, allowRoot: true)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SourceError.fileNotFound(path)
        }
        return fileURL
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let fileURL = try resolvedURL(for: path, allowRoot: false)
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true else { throw SourceError.fileNotFound(path) }
        let size = Int64(values.fileSize ?? 0)
        let revision = try localCompositeRevision(
            for: fileURL,
            size: size,
            modifiedDate: values.contentModificationDate
        )
        return EmbeddedMetadataRemoteFileState(
            fileSize: size,
            modifiedDate: values.contentModificationDate,
            revision: revision
        )
    }

    /// Local scans intentionally fold same-name cover/lyrics/MV revisions into
    /// Song.revision. Reproduce that exact fingerprint for writeback conflict
    /// checks so an unchanged audio file with sidecars is not reported as a
    /// false conflict, while a concurrently changed sidecar still blocks the
    /// transaction.
    private func localCompositeRevision(
        for fileURL: URL,
        size: Int64,
        modifiedDate: Date?
    ) throws -> String? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let siblingURLs: [URL]
        if isIndividuallyReferencedFile(fileURL) {
            siblingURLs = [fileURL]
        } else {
            siblingURLs = try FileManager.default.contentsOfDirectory(
                at: fileURL.deletingLastPathComponent(),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        }
        let siblings: [RemoteFileItem] = siblingURLs.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            let siblingSize = Int64(values.fileSize ?? 0)
            return RemoteFileItem(
                name: url.lastPathComponent,
                path: relativePath(for: url),
                isDirectory: false,
                size: siblingSize,
                modifiedDate: values.contentModificationDate,
                revision: Self.localRevision(
                    size: siblingSize,
                    modifiedDate: values.contentModificationDate
                )
            )
        }
        let targetPath = relativePath(for: fileURL)
        guard let item = siblings.first(where: { $0.path == targetPath }) else {
            throw SourceError.fileNotFound(targetPath)
        }
        let index = SidecarHintResolver.DirectoryIndex(siblings)
        guard let decorated = SidecarHintResolver.scannableItem(item, index: index) else {
            throw SourceError.fileNotFound(targetPath)
        }
        let revisionsByPath = Dictionary(
            siblings.map { ($0.path, $0.revision) },
            uniquingKeysWith: { first, _ in first }
        )
        let sidecarRevisions = [
            decorated.sidecarHints?.coverPath,
            decorated.sidecarHints?.lyricsPath,
            decorated.sidecarHints?.mvPath,
        ].compactMap { $0 }.compactMap { revisionsByPath[$0] ?? nil }
        let audioRevision = Self.localRevision(size: size, modifiedDate: modifiedDate)
        return Self.compositeRevision([audioRevision].compactMap { $0 } + sidecarRevisions)
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        let destination = try resolvedURL(for: path, allowRoot: false)
        let current = try await metadataWritebackState(for: path)
        guard expected.matches(current) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }

        let stagingURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).primuse-writeback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try FileManager.default.copyItem(at: localURL, to: stagingURL)
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: stagingURL,
            backupItemName: nil,
            options: []
        )
    }

    func writeFile(data: Data, to path: String) async throws {
        let destination = try resolvedURL(for: path, allowRoot: false)
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw SourceError.pathNotFound(parent.path)
        }

        let resolvedBase = basePath.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let basePrefix = resolvedBase.path.hasSuffix("/")
            ? resolvedBase.path
            : resolvedBase.path + "/"
        guard resolvedParent.path == resolvedBase.path
                || resolvedParent.path.hasPrefix(basePrefix) else {
            throw SourceError.connectionFailed("Refusing to write outside source root: \(path)")
        }

        let stagingURL = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).primuse-sidecar-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try data.write(to: stagingURL, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destination)
        }
    }

    func deleteFile(at path: String) async throws {
        let fileURL = try resolvedURL(for: path, allowRoot: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SourceError.fileNotFound(path)
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let fileURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { handle.closeFile() }

                    let chunkSize = 64 * 1024 // 64 KB
                    while true {
                        let data = handle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let inventory = try buildScanInventory(from: path)
        return AsyncThrowingStream { continuation in
            Task {
                for item in inventory.items { continuation.yield(item) }
                continuation.finish()
            }
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await scanSongs(from: path, existingSongs: [])
    }

    func scanSongs(
        from path: String,
        existingSongs: [Song]
    ) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        let inventory = try buildScanInventory(from: path)
        let cueTracksByAudioPath = try await loadCueTracks(from: inventory.cueURLs)
        let existingByID = Dictionary(
            existingSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let titleRepairKey = Self.metadataTitleRepairKey(sourceID: sourceID, path: path)
        // Finish a new or previously interrupted import before running the
        // one-time legacy-title repair. Otherwise every already-committed row
        // is parsed again before discovery can reach the still-missing files.
        let hasUnseenRegularFiles = inventory.items.contains { item in
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard !PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext),
                  cueTracksByAudioPath[item.path]?.isEmpty != false else {
                return false
            }
            let id = Self.generateID(sourceID: sourceID, path: item.path)
            return existingByID[id] == nil
        }
        let shouldRepairFileNameTitles = !hasUnseenRegularFiles
            && !UserDefaults.standard.bool(forKey: titleRepairKey)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for item in inventory.items {
                        try Task.checkCancellation()
                        let ext = (item.name as NSString).pathExtension.lowercased()
                        let physicalID = Self.generateID(sourceID: self.sourceID, path: item.path)

                        if PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
                            if let existing = existingByID[physicalID],
                               STRMRevision.wrapperMatches(
                                   songRevision: existing.revision,
                                   wrapperRevision: item.revision,
                                   wrapperSize: item.size,
                                   wrapperModifiedDate: item.modifiedDate
                               ) {
                                var refreshed = existing
                                refreshed.lastModified = item.modifiedDate ?? existing.lastModified
                                refreshed.coverArtFileName = item.sidecarHints?.coverPath ?? existing.coverArtFileName
                                refreshed.lyricsFileName = item.sidecarHints?.lyricsPath ?? existing.lyricsFileName
                                refreshed.mvPath = item.sidecarHints?.mvPath ?? existing.mvPath
                                continuation.yield(ConnectorScannedSong(
                                    song: refreshed,
                                    displayName: item.name,
                                    titleMetadataInspected: false
                                ))
                            } else if let scanned = try await self.buildSTRMSong(from: item) {
                                continuation.yield(scanned)
                            }
                            continue
                        }

                        if let descriptors = cueTracksByAudioPath[item.path], !descriptors.isEmpty {
                            let expectedRevision = Self.cueRevision(
                                audioRevision: item.revision,
                                cueRevisions: descriptors.map(\.cueRevision)
                            )
                            let existingTracks = existingSongs.filter {
                                $0.filePath == item.path && $0.isCueTrack
                            }
                            if !existingTracks.isEmpty,
                               existingTracks.allSatisfy({
                                   $0.revision == expectedRevision
                               }) {
                                for track in existingTracks {
                                    continuation.yield(ConnectorScannedSong(
                                        song: track,
                                        displayName: track.title,
                                        titleMetadataInspected: false
                                    ))
                                }
                                continue
                            }
                            let tracks = try await self.buildCueSongs(from: item, descriptors: descriptors)
                            for track in tracks { continuation.yield(track) }
                            continue
                        }

                        if let existing = existingByID[physicalID],
                           Self.fingerprintMatches(existing: existing, item: item) {
                            if shouldRepairFileNameTitles,
                               MetadataTitleResolutionPolicy.shouldReinspectFileNameFallback(
                                currentTitle: existing.title,
                                filePath: item.name,
                                userEdited: existing.userMetadataEditedAt != nil,
                                isCueTrack: existing.isCueTrack
                               ) {
                                let refreshed = try await self.buildTitleRefreshedSong(
                                    from: item,
                                    existing: existing
                                )
                                continuation.yield(refreshed)
                                continue
                            }
                            var refreshed = existing
                            if refreshed.revision == nil { refreshed.revision = item.revision }
                            if refreshed.lastModified == nil { refreshed.lastModified = item.modifiedDate }
                            continuation.yield(ConnectorScannedSong(
                                song: refreshed,
                                displayName: item.name,
                                titleMetadataInspected: false
                            ))
                            continue
                        }
                        if let scanned = self.buildBareScannedSong(from: item) {
                            continuation.yield(scanned)
                        }
                    }
                    if shouldRepairFileNameTitles {
                        UserDefaults.standard.set(true, forKey: titleRepairKey)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private struct LocalScanInventory: Sendable {
        var items: [RemoteFileItem]
        var cueURLs: [URL]
    }

    /// One filesystem enumeration gathers audio, STRM, CUE, covers, lyrics and
    /// MV candidates. Directory-local sibling decoration is applied afterward,
    /// so no second recursive walk is needed.
    private func buildScanInventory(from path: String) throws -> LocalScanInventory {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        var filesByParent: [String: [RemoteFileItem]] = [:]
        var cueURLsByPath: [String: URL] = [:]

        func recordFile(_ url: URL) throws {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return }
            let size = Int64(values.fileSize ?? 0)
            let item = RemoteFileItem(
                name: url.lastPathComponent,
                path: relativePath(for: url),
                isDirectory: false,
                size: size,
                modifiedDate: values.contentModificationDate,
                revision: Self.localRevision(size: size, modifiedDate: values.contentModificationDate)
            )
            filesByParent[url.deletingLastPathComponent().standardizedFileURL.path, default: []].append(item)
            if PrimuseConstants.supportedCueSheetExtensions.contains(url.pathExtension.lowercased()) {
                cueURLsByPath[item.path] = url
            }
        }

        let startURLs = isVirtualReferenceRoot(path)
            ? referenceRoots.map(\.url)
            : [try resolvedURL(for: path, allowRoot: true)]
        for startURL in startURLs {
            try Task.checkCancellation()
            let values = try startURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true {
                try recordFile(startURL)
                continue
            }
            guard values.isDirectory == true else {
                throw SourceError.connectionFailed(
                    "Local source root is not a readable file or folder: \(startURL.path)"
                )
            }
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: startURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw SourceError.connectionFailed(
                    "Unable to enumerate local source root: \(startURL.path)"
                )
            }
            while let url = enumerator.nextObject() as? URL {
                try recordFile(url)
            }
            if let enumerationError { throw enumerationError }
        }

        var scannable: [RemoteFileItem] = []
        for siblings in filesByParent.values {
            let byPath = Dictionary(siblings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let sidecarIndex = SidecarHintResolver.DirectoryIndex(siblings)
            for item in siblings {
                guard let decorated = SidecarHintResolver.scannableItem(
                    item,
                    index: sidecarIndex
                ) else { continue }
                let sidecarRevisions = [
                    decorated.sidecarHints?.coverPath,
                    decorated.sidecarHints?.lyricsPath,
                    decorated.sidecarHints?.mvPath,
                ].compactMap { $0 }.compactMap { byPath[$0]?.revision }
                let revision = Self.compositeRevision([decorated.revision].compactMap { $0 } + sidecarRevisions)
                scannable.append(RemoteFileItem(
                    name: decorated.name,
                    path: decorated.path,
                    isDirectory: false,
                    size: decorated.size,
                    modifiedDate: decorated.modifiedDate,
                    sidecarHints: decorated.sidecarHints,
                    revision: revision
                ))
            }
        }
        scannable.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
        return LocalScanInventory(
            items: scannable,
            cueURLs: cueURLsByPath.values.sorted { $0.path < $1.path }
        )
    }

    /// Keep discovery limited to the directory inventory. Reading tags and
    /// duration here made a local source fundamentally slower than every
    /// file-oriented remote source, especially when a macOS folder lives on
    /// an SMB-mounted volume. The shared metadata backfill pipeline performs
    /// the bounded, concurrent header reads after these rows are committed.
    private func buildBareScannedSong(from item: RemoteFileItem) -> ConnectorScannedSong? {
        guard item.size >= Self.minimumReadableAudioBytes else {
            plog("📥 LocalFileSource: skipping tiny local audio '\(item.name)' size=\(item.size)B")
            return nil
        }

        let songID = Self.generateID(sourceID: sourceID, path: item.path)
        let ext = (item.name as NSString).pathExtension.lowercased()
        let baseName = ((item.name as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let title = MediaMetadataTextRepair.fileNameTitle(from: baseName) ?? baseName
        let format = AudioFormat.from(fileExtension: ext) ?? .mp3
        let isStandaloneVideo = PrimuseConstants.supportedMusicVideoExtensions.contains(ext)
        let song = Song(
            id: songID,
            title: title,
            duration: 0,
            fileFormat: format,
            filePath: item.path,
            sourceID: sourceID,
            fileSize: item.size,
            lastModified: item.modifiedDate,
            coverArtFileName: item.sidecarHints?.coverPath,
            lyricsFileName: item.sidecarHints?.lyricsPath,
            mvPath: isStandaloneVideo
                ? item.path
                : item.sidecarHints?.mvPath,
            revision: item.revision
        )
        return ConnectorScannedSong(
            song: song,
            displayName: item.name,
            titleMetadataInspected: false
        )
    }

    private func buildTitleRefreshedSong(
        from item: RemoteFileItem,
        existing: Song
    ) async throws -> ConnectorScannedSong {
        let fileURL = try await localURL(for: item.path)
        let originalBaseName = ((item.name as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let metadata = await metadataService.loadMetadata(
            for: fileURL,
            cacheKey: existing.id,
            allowOnlineFetch: false,
            fallbackTitle: originalBaseName,
            discoverSidecars: false
        )
        var refreshed = existing
        if refreshed.revision == nil { refreshed.revision = item.revision }
        if refreshed.lastModified == nil { refreshed.lastModified = item.modifiedDate }
        if let embeddedTitle = metadata.embeddedTitle,
           embeddedTitle.compare(
            existing.title,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
           ) != .orderedSame {
            refreshed.title = embeddedTitle
            refreshed.titlePinyin = nil
        }
        return ConnectorScannedSong(
            song: refreshed,
            displayName: item.name,
            titleMetadataInspected: true
        )
    }

    private func buildSTRMSong(from item: RemoteFileItem) async throws -> ConnectorScannedSong? {
        let descriptorURL = try await localURL(for: item.path)
        guard item.size <= Int64(STRMDescriptorParser.maximumByteCount) else {
            plog("⚠️ Local STRM descriptor is too large: \(item.name)")
            return nil
        }
        let data = try Data(contentsOf: descriptorURL, options: .mappedIfSafe)
        let descriptor: STRMDescriptor
        do {
            descriptor = try STRMDescriptorParser.parse(data)
        } catch {
            plog("⚠️ Local STRM descriptor skipped: \(item.name) (\(error.localizedDescription))")
            return nil
        }
        let songID = Self.generateID(sourceID: sourceID, path: item.path)
        let baseName = (item.name as NSString).deletingPathExtension
        let song = Song(
            id: songID,
            title: descriptor.title ?? MediaMetadataTextRepair.fileNameTitle(from: baseName) ?? baseName,
            artistName: descriptor.artist ?? MediaMetadataTextRepair.fileNameArtist(from: baseName),
            duration: descriptor.duration ?? 0,
            fileFormat: descriptor.format,
            filePath: item.path,
            sourceID: sourceID,
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
        return ConnectorScannedSong(
            song: song,
            displayName: item.name,
            titleMetadataInspected: false
        )
    }

    private struct CueTrackDescriptor: Sendable {
        let cuePath: String
        let cueRevision: String
        let albumTitle: String?
        let albumPerformer: String?
        let genre: String?
        let year: Int?
        let format: AudioFormat
        let track: CueTrack
    }

    /// Parse local CUE sheets up front so a referenced album image is emitted
    /// as virtual tracks and never duplicated as one whole-file library row.
    private func loadCueTracks(from cueURLs: [URL]) async throws -> [String: [CueTrackDescriptor]] {
        var result: [String: [CueTrackDescriptor]] = [:]

        for cueURL in cueURLs {
            try Task.checkCancellation()
            guard cueURL.pathExtension.caseInsensitiveCompare("cue") == .orderedSame,
                  let values = try? cueURL.resourceValues(
                      forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                  ),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 1024 * 1024,
                  let data = try? Data(contentsOf: cueURL, options: .mappedIfSafe),
                  let cue = CueSheetParser.parse(data: data) else {
                continue
            }

            for cueFile in cue.files {
                let referencedPath = cueFile.name.replacingOccurrences(of: "\\", with: "/")
                let candidate = cueURL.deletingLastPathComponent()
                    .appendingPathComponent(referencedPath)
                    .standardizedFileURL
                guard isAccessibleReference(candidate, relativeTo: cueURL),
                      FileManager.default.fileExists(atPath: candidate.path) else {
                    plog("⚠️ CUE: '\(cueURL.lastPathComponent)' references missing file '\(cueFile.name)'")
                    continue
                }
                let ext = candidate.pathExtension.lowercased()
                guard var format = AudioFormat.from(fileExtension: ext) else { continue }
                let isDTSWAV = ext == "wav"
                    ? (try? await ffmpegDecoder.canDecodeAsync(url: candidate)) ?? false
                    : false
                if ext == "dts" || isDTSWAV {
                    format = .dts
                }
                let audioPath = relativePath(for: candidate)
                let cueRevision = Self.localRevision(
                    size: Int64(values.fileSize ?? 0),
                    modifiedDate: values.contentModificationDate
                )
                for track in cueFile.tracks where track.type == "AUDIO" && track.startTime != nil {
                    result[audioPath, default: []].append(
                        CueTrackDescriptor(
                            cuePath: relativePath(for: cueURL),
                            cueRevision: cueRevision,
                            albumTitle: cue.title,
                            albumPerformer: cue.performer,
                            genre: cue.genre,
                            year: cue.year,
                            format: format,
                            track: track
                        )
                    )
                }
            }
        }
        return result
    }

    private func buildCueSongs(
        from item: RemoteFileItem,
        descriptors: [CueTrackDescriptor]
    ) async throws -> [ConnectorScannedSong] {
        let fileURL = try await localURL(for: item.path)
        let physicalID = Self.generateID(sourceID: sourceID, path: item.path)
        let fallbackTitle = ((item.name as NSString).lastPathComponent as NSString).deletingPathExtension
        let metadata = await metadataService.loadMetadata(
            for: fileURL,
            cacheKey: physicalID,
            allowOnlineFetch: false,
            fallbackTitle: fallbackTitle,
            discoverSidecars: false
        )
        let ext = fileURL.pathExtension.lowercased()
        let needsFFmpegProbe = Self.ffmpegMetadataProbeExtensions.contains(ext) || descriptors.contains {
            FileFormatRouter.decoder(for: $0.format) is FFmpegAudioDecoder
        }
        let ffmpegInfo = needsFFmpegProbe ? try? await ffmpegDecoder.fileInfo(for: fileURL) : nil
        let physicalDuration = Self.preferredPositive(ffmpegInfo?.duration, fallback: metadata.duration)
        let combinedRevision = Self.cueRevision(
            audioRevision: item.revision,
            cueRevisions: descriptors.map(\.cueRevision)
        )

        return descriptors.compactMap { descriptor in
            guard let start = descriptor.track.startTime else { return nil }
            let end = descriptor.track.endTime ?? (physicalDuration > start ? physicalDuration : nil)
            let artist = descriptor.track.performer ?? descriptor.albumPerformer ?? metadata.artist
            let album = descriptor.albumTitle ?? metadata.albumTitle
            let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: descriptor.albumPerformer ?? metadata.albumArtist,
                trackArtistName: artist
            )
            let trackID = Self.generateID(
                sourceID: sourceID,
                path: "\(item.path)#cue:\(descriptor.cuePath)#track:\(descriptor.track.number)"
            )
            let song = Song(
                id: trackID,
                title: descriptor.track.title ?? String(format: "Track %02d", descriptor.track.number),
                albumID: album.map {
                    Self.generateID(sourceID: "album", path: "\(albumArtist ?? ""):\($0)")
                },
                artistID: artist.map { Self.generateID(sourceID: "artist", path: $0) },
                albumTitle: album,
                artistName: artist,
                sourceArtistNames: descriptor.track.performer == nil
                    && descriptor.albumPerformer == nil
                    ? metadata.sourceArtistNames
                    : nil,
                albumArtistName: albumArtist,
                trackNumber: descriptor.track.number,
                duration: end.map { max(0, $0 - start) } ?? 0,
                fileFormat: descriptor.format,
                filePath: item.path,
                sourceID: sourceID,
                fileSize: item.size,
                bitRate: ffmpegInfo?.bitRate ?? metadata.bitRate,
                sampleRate: Self.preferredPositiveInt(
                    ffmpegInfo.map { Int($0.sampleRate) },
                    fallback: metadata.sampleRate
                ),
                bitDepth: Self.preferredPositiveInt(
                    ffmpegInfo?.bitDepth,
                    fallback: metadata.bitDepth
                ),
                genre: descriptor.genre ?? metadata.genre,
                year: descriptor.year ?? metadata.year,
                lastModified: item.modifiedDate,
                coverArtFileName: item.sidecarHints?.coverPath ?? metadata.coverArtFileName,
                lyricsFileName: item.sidecarHints?.lyricsPath ?? metadata.lyricsFileName,
                mvPath: item.sidecarHints?.mvPath ?? sidecarPath(nextTo: item.path, named: metadata.mvPath),
                cueSheetPath: descriptor.cuePath,
                cueStartTime: start,
                cueEndTime: end,
                revision: combinedRevision
            )
            return ConnectorScannedSong(
                song: song,
                displayName: song.title,
                titleMetadataInspected: false
            )
        }
    }

    /// 同目录存在任一同名音频文件时, 该视频是 sidecar 而非独立 MV。
    private static func hasSameNameAudioSibling(_ url: URL) -> Bool {
        let base = url.deletingPathExtension()
        for ext in PrimuseConstants.supportedAudioExtensions {
            if FileManager.default.fileExists(atPath: base.appendingPathExtension(ext).path) {
                return true
            }
        }
        return false
    }

    private func sidecarPath(nextTo filePath: String, named sidecarName: String?) -> String? {
        guard let sidecarName, sidecarName.contains("/") == false else { return sidecarName }
        let parentDir = (filePath as NSString).deletingLastPathComponent
        return (parentDir as NSString).appendingPathComponent(sidecarName)
    }

    private func remoteFileItem(for url: URL, path: String) throws -> RemoteFileItem {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        let size = Int64(values.fileSize ?? 0)
        return RemoteFileItem(
            name: url.lastPathComponent,
            path: path,
            isDirectory: values.isDirectory ?? false,
            size: size,
            modifiedDate: values.contentModificationDate,
            revision: Self.localRevision(size: size, modifiedDate: values.contentModificationDate)
        )
    }

    private func isVirtualReferenceRoot(_ path: String) -> Bool {
        guard !referenceRoots.isEmpty,
              path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            return false
        }
        return referenceRoots.count > 1 || referenceRoots[0].virtualPathComponent != nil
    }

    private func virtualPath(for root: LocalReferenceRoot) -> String {
        root.virtualPathComponent.map { "/\($0)" } ?? "/"
    }

    private func resolvedURL(for path: String, allowRoot: Bool) throws -> URL {
        if !referenceRoots.isEmpty {
            return try resolvedReferenceURL(for: path, allowRoot: allowRoot)
        }
        if path.hasPrefix("/"),
           let migratedURL = PrimuseSandboxPathResolver.existingURL(
               forStoredAbsolutePath: path
           ) {
            let standardizedURL = migratedURL.standardizedFileURL
            let standardizedBase = basePath.standardizedFileURL
            let basePrefix = standardizedBase.path.hasSuffix("/")
                ? standardizedBase.path
                : standardizedBase.path + "/"
            if (allowRoot && standardizedURL.path == standardizedBase.path)
                || standardizedURL.path.hasPrefix(basePrefix) {
                return standardizedURL
            }
        }

        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = (relativePath.isEmpty ? basePath : basePath.appendingPathComponent(relativePath)).standardizedFileURL
        let baseStandardized = basePath.standardizedFileURL
        if allowRoot, fileURL.path == baseStandardized.path {
            return fileURL
        }
        let basePrefix = baseStandardized.path.hasSuffix("/") ? baseStandardized.path : baseStandardized.path + "/"
        guard fileURL.path.hasPrefix(basePrefix) else {
            throw SourceError.connectionFailed("Refusing to access outside source root: \(path)")
        }
        return fileURL
    }

    private func resolvedReferenceURL(for path: String, allowRoot: Bool) throws -> URL {
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for root in referenceRoots {
            let remainder: String
            if let component = root.virtualPathComponent {
                if relativePath == component {
                    guard allowRoot || !root.isDirectory else {
                        throw SourceError.fileNotFound(path)
                    }
                    return root.url.standardizedFileURL
                }
                let prefix = component + "/"
                guard relativePath.hasPrefix(prefix) else { continue }
                remainder = String(relativePath.dropFirst(prefix.count))
            } else {
                if relativePath.isEmpty {
                    guard allowRoot else { throw SourceError.fileNotFound(path) }
                    return root.url.standardizedFileURL
                }
                remainder = relativePath
            }

            guard root.isDirectory else { throw SourceError.fileNotFound(path) }
            let candidate = root.url.appendingPathComponent(remainder).standardizedFileURL
            guard Self.contains(candidate, inside: root.url) else {
                throw SourceError.connectionFailed("Refusing to access outside source root: \(path)")
            }
            return candidate
        }
        throw SourceError.fileNotFound(path)
    }

    private func relativePath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        for root in referenceRoots where Self.contains(standardized, inside: root.url) {
            let rootPath = root.url.standardizedFileURL.path
            let suffix = standardized.path.dropFirst(rootPath.count)
            let rootPrefix = root.virtualPathComponent.map { "/\($0)" } ?? ""
            if suffix.isEmpty { return rootPrefix.isEmpty ? "/" : rootPrefix }
            let childPath = suffix.hasPrefix("/") ? String(suffix) : "/" + suffix
            return rootPrefix + childPath
        }

        let standardizedBase = basePath.standardizedFileURL
        guard Self.contains(standardized, inside: standardizedBase) else {
            return "/" + url.lastPathComponent
        }
        let suffix = standardized.path.dropFirst(standardizedBase.path.count)
        return suffix.isEmpty ? "/" : (suffix.hasPrefix("/") ? String(suffix) : "/" + suffix)
    }

    private func isAccessibleReference(_ candidate: URL, relativeTo sourceURL: URL) -> Bool {
        if referenceRoots.isEmpty {
            return Self.contains(sourceURL, inside: basePath)
                && Self.contains(candidate, inside: basePath)
        }
        guard let root = referenceRoots.first(where: {
            Self.contains(sourceURL, inside: $0.url)
        }), root.isDirectory else { return false }
        return Self.contains(candidate, inside: root.url)
    }

    private func isIndividuallyReferencedFile(_ url: URL) -> Bool {
        referenceRoots.contains {
            !$0.isDirectory && $0.url.standardizedFileURL == url.standardizedFileURL
        }
    }

    private nonisolated static func contains(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if candidatePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private nonisolated static func preferredPositive(
        _ candidate: TimeInterval?,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard let candidate, candidate.isFinite, candidate > 0 else { return fallback }
        return candidate
    }

    private nonisolated static func preferredPositiveInt(
        _ candidate: Int?,
        fallback: Int?
    ) -> Int? {
        guard let candidate, candidate > 0 else { return fallback }
        return candidate
    }

    private nonisolated static func generateID(sourceID: String, path: String) -> String {
        let input = "\(sourceID):\(path)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func localRevision(size: Int64, modifiedDate: Date?) -> String {
        let milliseconds = modifiedDate.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? -1
        return "local:\(size):\(milliseconds)"
    }

    private nonisolated static func compositeRevision(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.sorted().joined(separator: "|").utf8))
        return "local:\(digest.prefix(16).map { String(format: "%02x", $0) }.joined())"
    }

    private nonisolated static func cueRevision(
        audioRevision: String?,
        cueRevisions: [String]
    ) -> String {
        compositeRevision([audioRevision].compactMap { $0 } + cueRevisions)
    }

    private nonisolated static func fingerprintMatches(existing: Song, item: RemoteFileItem) -> Bool {
        if let revision = item.revision, let existingRevision = existing.revision {
            return revision == existingRevision
        }
        guard existing.fileSize == item.size else { return false }
        if let lhs = existing.lastModified, let rhs = item.modifiedDate {
            return abs(lhs.timeIntervalSince(rhs)) < 0.001
        }
        return true
    }

    private nonisolated static func metadataTitleRepairKey(
        sourceID: String,
        path: String
    ) -> String {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map {
            String(format: "%02x", $0)
        }.joined()
        return "primuse.localMetadataTitleRepair.\(metadataTitleRepairVersion).\(sourceID).\(digest)"
    }
}

enum SourceError: Error, LocalizedError, Sendable {
    case pathNotFound(String)
    case fileNotFound(String)
    case connectionFailed(String)
    case credentialUnavailable(String)
    case authenticationFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return String(format: String(localized: "error_path_not_found %@"), path)
        case .fileNotFound(let path):
            return String(format: String(localized: "error_file_not_found %@"), path)
        case .connectionFailed(let message):
            return String(format: String(localized: "error_connection_failed %@"), message)
        case .credentialUnavailable(let msg): return msg
        case .authenticationFailed:
            return String(localized: "error_authentication_failed")
        case .timeout:
            return String(localized: "error_connection_timeout")
        }
    }
}

/// A route reached the service but cannot proceed without user action (for
/// example a rejected password, account lock or required password change).
/// Adaptive routing must not repeat that login against every saved endpoint.
struct SourceConnectionTerminalError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
