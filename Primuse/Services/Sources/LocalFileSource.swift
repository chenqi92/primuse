import CryptoKit
import Darwin
import Foundation
import PrimuseKit

/// What re-checking one song's file against the library found.
enum LocalFileRefreshOutcome: Sendable {
    case updated(Song)
    case unchanged
    /// The file is exactly as this app last wrote it; the writer updates the library.
    case ownWrite
    case deferred(LocalFileReadDeferral)
}

actor LocalFileSource: ExistingSongAwareScanningConnector, EmbeddedMetadataWritebackAdapter, PathFileRenameConnector {
    /// 扫描把同名封面、歌词、MV 文件的指纹并进 Song.revision(`localCompositeRevision`)。
    static let revisionFoldsSidecarFingerprints = true

    let sourceID: String
    nonisolated let supportsSidecarWriting: Bool
    /// 能改目录结构(改名、移动、删文件夹):只有选的都是文件夹时。单独添加的文件补授权了所在
    /// 文件夹,能写的也只是它旁边的歌词、封面文件,不是这个开关。
    nonisolated let supportsDirectoryMutation: Bool
    private var basePath: URL
    private var hasCheckedPendingRewrites = false
    private var referenceRoots: [LocalReferenceRoot] = []
    private var referenceBookmarksUnavailable = false
    private var hasResolvedReferenceRoots = false
    private var cachedPathResolver: PathResolver?
    /// Embedded tags and sidecars this connector just wrote (see `isOwnWrite`).
    private var ownWrites = LocalOwnWriteLedger()
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
        /// 单独添加的文件另外授权过的所在文件夹;没有时只能改这个文件本身。
        var folderURL: URL? = nil
        var folderUsesSecurityScope = false
    }

    /// Maps files back to source paths with the roots canonicalised once.
    ///
    /// Canonicalising a path costs an existence check plus a symlink walk over
    /// every component, and the mapping used to repeat that for the entry and
    /// for each root it was compared with — four walks per directory entry.
    /// Listing a folder of 1,200 songs spent nine tenths of its time there,
    /// and every track change (sidecar lyric lookup) and launch reconciliation
    /// lists that folder. An entry listed from a canonical directory is
    /// already canonical unless it is itself a symlink, so only symlinks walk.
    private struct PathResolver: Sendable {
        struct Root: Sendable {
            let virtualPathComponent: String?
            let canonicalPath: String
        }

        let roots: [Root]
        let canonicalBasePath: String

        func relativePath(for url: URL) -> String {
            relativePath(
                canonicalPath: LocalFileSource.canonicalURL(url).path,
                lastPathComponent: url.lastPathComponent
            )
        }

        /// `parentIsCanonical` comes from one check per listed directory.
        func relativePath(
            forListedEntry url: URL,
            parentIsCanonical: Bool,
            isSymbolicLink: Bool?
        ) -> String {
            guard parentIsCanonical, isSymbolicLink == false else {
                return relativePath(for: url)
            }
            return relativePath(
                canonicalPath: url.standardizedFileURL.path,
                lastPathComponent: url.lastPathComponent
            )
        }

        private func relativePath(canonicalPath path: String, lastPathComponent: String) -> String {
            for root in roots where Self.isPath(path, inside: root.canonicalPath) {
                let suffix = path.dropFirst(root.canonicalPath.count)
                let rootPrefix = root.virtualPathComponent.map { "/\($0)" } ?? ""
                if suffix.isEmpty { return rootPrefix.isEmpty ? "/" : rootPrefix }
                let childPath = suffix.hasPrefix("/") ? String(suffix) : "/" + suffix
                return rootPrefix + childPath
            }
            guard Self.isPath(path, inside: canonicalBasePath) else {
                return "/" + lastPathComponent
            }
            let suffix = path.dropFirst(canonicalBasePath.count)
            return suffix.isEmpty ? "/" : (suffix.hasPrefix("/") ? String(suffix) : "/" + suffix)
        }

        private static func isPath(_ path: String, inside rootPath: String) -> Bool {
            if path == rootPath { return true }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return path.hasPrefix(prefix)
        }
    }

    init(sourceID: String, basePath: URL) {
        self.sourceID = sourceID
        var resolvedBasePath = basePath
        #if os(iOS) || os(macOS)
        self.supportsSidecarWriting = LocalBookmarkStore.supportsSidecarWriting(sourceID: sourceID)
        self.supportsDirectoryMutation = LocalBookmarkStore.referencesAreAllDirectories(sourceID: sourceID)
        #else
        self.supportsSidecarWriting = true
        self.supportsDirectoryMutation = true
        #endif
        #if os(iOS)
        let hasBookmarks = LocalBookmarkStore.hasReferences(sourceID: sourceID)
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
        if !hasBookmarks, isManagedLocalImport {
            resolvedBasePath = LocalImportService.musicDirectory
        } else if let rebased = PrimuseSandboxPathResolver.existingURL(
            forStoredAbsolutePath: basePath.path
        ), !hasBookmarks {
            resolvedBasePath = rebased
        }
        #endif

        self.basePath = resolvedBasePath
    }

    private func resolveReferenceRootsIfNeeded() {
        guard !hasResolvedReferenceRoots else { return }
        hasResolvedReferenceRoots = true
        #if os(iOS) || os(macOS)
        // Actor-isolated I/O: constructing a connector on the UI thread never
        // waits for ScopedBookmarkAgent or an unavailable network volume.
        if let references = LocalBookmarkStore.resolveReferences(sourceID: sourceID) {
            referenceBookmarksUnavailable = references.isEmpty
            referenceRoots = references.map { reference in
                let folderURL = reference.isDirectory ? nil : reference.folderURL
                return LocalReferenceRoot(
                    virtualPathComponent: reference.virtualPathComponent,
                    url: reference.url,
                    isDirectory: reference.isDirectory,
                    usesSecurityScope: reference.url.startAccessingSecurityScopedResource(),
                    folderURL: folderURL,
                    folderUsesSecurityScope: folderURL?.startAccessingSecurityScopedResource() ?? false
                )
            }
            if referenceRoots.count == 1, referenceRoots[0].virtualPathComponent == nil {
                basePath = referenceRoots[0].url
            }
        }
        #endif
    }

    deinit {
        for root in referenceRoots where root.usesSecurityScope {
            root.url.stopAccessingSecurityScopedResource()
        }
        for root in referenceRoots where root.folderUsesSecurityScope {
            root.folderURL?.stopAccessingSecurityScopedResource()
        }
    }

    func connect() async throws {
        resolveReferenceRootsIfNeeded()
        if referenceBookmarksUnavailable {
            throw SourceError.credentialUnavailable(
                String(localized: "local_reference_permission_missing")
            )
        }
        if !hasCheckedPendingRewrites {
            // 上次原地改写失败、放回也没成的文件:这个源一被用到就先试着放回。
            hasCheckedPendingRewrites = true
            await Self.restorePendingRewrites(sourceID: sourceID)
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

    func canRenameFile(at path: String) async -> Bool {
        guard supportsDirectoryMutation,
              let url = try? renameURL(for: path),
              !isIndividuallyReferencedFile(url),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    func renameFileState(at path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let url = try renameURL(for: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SourceError.fileNotFound(path) }
        return EmbeddedMetadataRemoteFileState(fileSize: Int64(values.fileSize ?? 0),
            modifiedDate: values.contentModificationDate, revision: nil)
    }

    func moveFileWithoutReplacing(from: String, to: String, expected: EmbeddedMetadataRemoteFileState) async throws {
        guard await canRenameFile(at: from),
              (from as NSString).deletingLastPathComponent == (to as NSString).deletingLastPathComponent else {
            throw SongFileRenameError.unsupported
        }
        let source = try renameURL(for: from)
        let destination = try renameURL(for: to)
        guard expected.matches(try await renameFileState(at: from)) else { throw EmbeddedMetadataWritebackSourceError.conflict }
        let status = source.path.withCString { fromPath in
            destination.path.withCString { toPath in
                renameatx_np(AT_FDCWD, fromPath, AT_FDCWD, toPath, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // 改名是 Primuse 自己做的：新路径上的变动通知不再重读标签。
        noteOwnWrite(at: destination, path: to)
    }

    private func renameURL(for path: String) throws -> URL {
        let resolved = try resolvedURL(for: path, allowRoot: false)
        let parent = try resolvedURL(for: (path as NSString).deletingLastPathComponent, allowRoot: true)
        let candidate = parent.appendingPathComponent((path as NSString).lastPathComponent).standardizedFileURL
        guard candidate.path == resolved.path else { throw SongFileRenameError.unsupported }
        return candidate
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if isVirtualReferenceRoot(path) {
            let roots = try referenceRoots.map { root in
                try Self.remoteFileItem(for: root.url, path: virtualPath(for: root))
            }
            let listedNames = Set(roots.map { $0.name.lowercased() }
                + referenceRoots.compactMap { $0.virtualPathComponent?.lowercased() })
            let siblings = await Self.listGrantedSiblings(grantedSiblingFolders(), excluding: listedNames)
            return (roots + siblings).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        let directoryURL = try resolvedURL(for: path, allowRoot: true)
        return try await Self.listDirectory(directoryURL, paths: pathResolver())
    }

    /// Runs off the actor: playback resolves every track through `connect()`
    /// and `localURL(for:)`, and must not queue behind a directory listing.
    @concurrent
    private nonisolated static func listDirectory(
        _ directoryURL: URL,
        paths: PathResolver
    ) async throws -> [RemoteFileItem] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
            ]
        )
        let parentIsCanonical = isCanonical(directoryURL)
        return try contents.map { url in
            let isSymbolicLink = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
            return try remoteFileItem(
                for: url,
                path: paths.relativePath(
                    forListedEntry: url,
                    parentIsCanonical: parentIsCanonical,
                    isSymbolicLink: isSymbolicLink
                )
            )
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func localURL(for path: String) async throws -> URL {
        let fileURL = try resolvedURL(for: path, allowRoot: true)
        // 被系统腾出空间的 iCloud 云盘文件在原路径上可能不存在(只剩 `.名字.icloud`
        // 占位),照样交出原路径,由播放层先把它下载回来。
        guard FileManager.default.fileExists(atPath: fileURL.path)
                || UbiquitousPlaybackFile.isEvictedPlaceholder(fileURL) else {
            throw SourceError.fileNotFound(path)
        }
        return fileURL
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let probe = try writebackProbe(for: path)
        return try await Self.detachedWritebackState(probe)
    }

    func refreshedLocalSong(_ song: Song, notified: Bool) async throws -> Song? {
        if case .updated(let updated) = try await refreshLocalSong(song, notified: notified) { return updated }
        return nil
    }

    /// 改写音频文件之前:还没下到这台设备的 iCloud 云盘文件先下载、等它落地。只在写回时做,
    /// 改名、探测这些只读属性的操作不会因此整首下载。
    func prepareForMetadataWriteback(at path: String) async throws {
        let url = try resolvedURL(for: path, allowRoot: false)
        try await Self.downloadForWritebackIfNeeded(url)
    }

    /// A visible row needs only the attributes of its own file. A presenter
    /// notification can force a read on providers that preserve all dates.
    /// A file that is still downloading, being written or briefly missing is
    /// reported as deferred so the caller can look again later.
    func refreshLocalSong(_ song: Song, notified: Bool) async throws -> LocalFileRefreshOutcome {
        guard song.sourceID == sourceID, !song.isCueTrack, !song.isDiscImageTrack, !song.isStreamDescriptor else { return .unchanged }
        let url: URL
        do {
            url = try resolvedURL(for: song.filePath, allowRoot: false)
        } catch SourceError.credentialUnavailable(_) {
            return .deferred(.inaccessible)
        } catch {
            return .deferred(.missing)
        }
        if !ownWrites.isEmpty, ownWrites.isOwnWrite(Self.fileIdentity(at: url), for: song.filePath) { return .ownWrite }
        let observation: LocalAudioObservation
        do {
            observation = try LocalAudioObservation(url)
        } catch {
            return .deferred(Self.unavailableReason(for: url, error: error))
        }
        if let deferral = observation.deferral { return .deferred(deferral) }
        let sameSizeAndDate = Self.localRevision(size: song.fileSize, modifiedDate: song.lastModified)
            == Self.localRevision(size: observation.size, modifiedDate: observation.modified)
        let existingBase = song.revision?.components(separatedBy: "|").first
        let sidecars = SidecarHints(
            coverPath: song.coverArtFileName.flatMap { $0.hasPrefix("/") ? $0 : nil },
            lyricsPath: song.lyricsFileName.flatMap { $0.hasPrefix("/") ? $0 : nil },
            mvPath: song.referencedMusicVideoPath
        )
        let revision: String
        if sameSizeAndDate, let existingBase, existingBase.hasPrefix("local:") {
            revision = Self.stampedRevision(existingBase, changed: observation.changed)
        } else {
            // Structural/sidecar events reconcile their folder separately. For
            // one changed audio file, stat only the sidecars belonging to it.
            let siblings = [sidecars.coverPath, sidecars.lyricsPath, sidecars.mvPath].compactMap { path -> String? in
                guard let path, path != song.filePath, path.hasPrefix("/"),
                      let url = try? resolvedURL(for: path, allowRoot: false) else { return nil }
                return (try? Self.remoteFileItem(for: url, path: path))?.revision
            }
            let audioRevision = Self.localRevision(size: observation.size, modifiedDate: observation.modified)
            revision = Self.stampedRevision(Self.compositeRevision([audioRevision] + siblings), changed: observation.changed)
        }
        guard notified || !sameSizeAndDate || !EmbeddedMetadataRemoteFileState.revisionMatches(song, current: revision) else { return .unchanged }
        let item = RemoteFileItem(name: url.lastPathComponent, path: song.filePath, isDirectory: false,
                                  size: observation.size, modifiedDate: observation.modified,
                                  sidecarHints: sidecars, revision: revision)
        do {
            if let updated = try await readUpdatedSong(song, item: item, url: url, observation: observation) {
                return .updated(updated)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The file went away during the read; classified below.
        }
        // Tell a file that moved under the read from one with nothing readable in it.
        guard let after = try? LocalAudioObservation(url) else { return .deferred(.missing) }
        if let deferral = after.deferral { return .deferred(deferral) }
        return .deferred(after == observation ? .unreadable : .changing)
    }

    /// True while the file at `path` is exactly as this connector last wrote it.
    func isOwnWrite(_ path: String) -> Bool {
        guard !ownWrites.isEmpty, let url = try? resolvedURL(for: path, allowRoot: false) else { return false }
        return ownWrites.isOwnWrite(Self.fileIdentity(at: url), for: path)
    }

    private func noteOwnWrite(at url: URL, path: String) {
        guard let identity = Self.fileIdentity(at: url) else { return }
        ownWrites.record(identity, for: path)
    }

    nonisolated static func fileIdentity(at url: URL) -> LocalFileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        func nanoseconds(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
        return LocalFileIdentity(
            device: UInt64(UInt32(bitPattern: info.st_dev)),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedNanoseconds: nanoseconds(info.st_mtimespec),
            changedNanoseconds: nanoseconds(info.st_ctimespec)
        )
    }

    private nonisolated static func unavailableReason(for url: URL, error: Error) -> LocalFileReadDeferral {
        if UbiquitousPlaybackFile.isEvictedPlaceholder(url) { return .notDownloaded }
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix: Int?
        if let underlying, underlying.domain == NSPOSIXErrorDomain {
            posix = underlying.code
        } else if nsError.domain == NSPOSIXErrorDomain {
            posix = nsError.code
        } else {
            posix = nil
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return .inaccessible
        }
        if let posix, posix == Int(EACCES) || posix == Int(EPERM) { return .inaccessible }
        return .missing
    }

    private struct LocalAudioObservation: Equatable {
        let size: Int64
        let modified: Date?
        let changed: Date?
        let deferral: LocalFileReadDeferral?

        var isReadable: Bool { deferral == nil }

        init(_ url: URL) throws {
            // URLs from directory listings cache their resource values.
            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey,
                .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            ])
            size = Int64(values.fileSize ?? 0)
            modified = values.contentModificationDate
            changed = values.attributeModificationDate
            if values.isRegularFile != true {
                deferral = .missing
            } else if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                deferral = values.ubiquitousItemIsDownloading == true ? .downloading : .notDownloaded
            } else if values.ubiquitousItemDownloadingStatus == .downloaded {
                deferral = values.ubiquitousItemIsDownloading == true ? .downloading : .outdated
            } else if size < LocalFileSource.minimumReadableAudioBytes {
                deferral = .changing
            } else {
                deferral = nil
            }
        }
    }

    private func readUpdatedSong(_ existing: Song, item: RemoteFileItem, url: URL,
                                 observation: LocalAudioObservation) async throws -> Song? {
        guard observation.isReadable, observation.size == item.size, observation.modified == item.modifiedDate,
              let baseRevision = item.revision?.components(separatedBy: "|").first,
              Self.stampedRevision(baseRevision, changed: observation.changed) == item.revision,
              var base = buildBareScannedSong(from: item)?.song else { return nil }
        base.id = existing.id
        base.dateAdded = existing.dateAdded
        base.lyricsText = existing.lyricsText
        base.artistArtworkFileName = existing.artistArtworkFileName
        let previousLyrics = await MetadataAssetStore.shared.cachedLyrics(forSongID: existing.id)
            .map(LyricsDocumentFingerprint.init(lines:))
        var metadata = await metadataService.loadMetadata(
            for: url, allowOnlineFetch: false, fallbackTitle: base.title, discoverSidecars: false
        )
        if !metadata.hasTechnicalProperties, Self.ffmpegMetadataProbeExtensions.contains(url.pathExtension.lowercased()),
           let info = try? await ffmpegDecoder.fileInfo(for: url), info.duration > 0 {
            metadata.duration = info.duration
            metadata.sampleRate = info.sampleRate.finiteInt()
            metadata.bitDepth = info.bitDepth
            metadata.bitRate = info.bitRate
            metadata.hasTechnicalProperties = true
        }
        try Task.checkCancellation()
        guard try LocalAudioObservation(url) == observation,
              metadata.hasEmbeddedDescriptiveMetadata || metadata.hasTechnicalProperties else { return nil }
        if base.coverArtFileName != nil || StoredArtworkOrigin.preservesLocalChoice(existing.coverArtFileName) {
            metadata.coverArtData = nil
        }
        if base.lyricsFileName == nil, let previousLyrics, let lyrics = metadata.lyrics {
            await MetadataAssetStore.shared.reconcileEmbeddedSource(
                lyrics, alternatives: metadata.embeddedLyricsAlternatives, forSongID: existing.id, expected: previousLyrics
            )
        }
        metadata = await metadataService.storingEmbeddedAssets(in: metadata, cacheKey: existing.id,
                                                               storesLyrics: base.lyricsFileName == nil)
        let updated = MetadataBackfillService.mergeSong(bare: base, metadata: metadata,
                                                       restrictsToBareRows: true, sourceFileName: item.name)
        return SongUserMetadataPolicy.preservingUserEdits(from: existing, in: updated)
    }

    /// What a writeback state check needs from the actor; the sibling listing
    /// itself then runs without it.
    private struct WritebackProbe: Sendable {
        let path: String
        let fileURL: URL
        let isIndividuallyReferenced: Bool
        let paths: PathResolver
    }

    private func writebackProbe(for path: String) throws -> WritebackProbe {
        let fileURL = try resolvedURL(for: path, allowRoot: false)
        return WritebackProbe(
            path: path,
            fileURL: fileURL,
            isIndividuallyReferenced: isIndividuallyReferencedFile(fileURL),
            paths: pathResolver()
        )
    }

    @concurrent
    private nonisolated static func detachedWritebackState(
        _ probe: WritebackProbe
    ) async throws -> EmbeddedMetadataRemoteFileState {
        try writebackState(probe)
    }

    private nonisolated static func writebackState(
        _ probe: WritebackProbe
    ) throws -> EmbeddedMetadataRemoteFileState {
        let values = try probe.fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .attributeModificationDateKey,
        ])
        guard values.isRegularFile == true else { throw SourceError.fileNotFound(probe.path) }
        let size = Int64(values.fileSize ?? 0)
        let revision = try localCompositeRevision(
            for: probe.fileURL,
            size: size,
            modifiedDate: values.contentModificationDate,
            isIndividuallyReferenced: probe.isIndividuallyReferenced,
            paths: probe.paths
        )
        return EmbeddedMetadataRemoteFileState(
            fileSize: size,
            modifiedDate: values.contentModificationDate,
            revision: revision.map { stampedRevision($0, changed: values.attributeModificationDate) },
            isLocalFileRevision: true
        )
    }

    /// Local scans intentionally fold same-name cover/lyrics/MV revisions into
    /// Song.revision. Reproduce that exact fingerprint for writeback conflict
    /// checks so an unchanged audio file with sidecars is not reported as a
    /// false conflict, while a concurrently changed sidecar still blocks the
    /// transaction.
    private nonisolated static func localCompositeRevision(
        for fileURL: URL,
        size: Int64,
        modifiedDate: Date?,
        isIndividuallyReferenced: Bool,
        paths: PathResolver
    ) throws -> String? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        let siblingURLs: [URL]
        let parentIsCanonical: Bool
        if isIndividuallyReferenced {
            siblingURLs = [fileURL]
            parentIsCanonical = false
        } else {
            let directoryURL = fileURL.deletingLastPathComponent()
            siblingURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            parentIsCanonical = isCanonical(directoryURL)
        }
        let siblings: [RemoteFileItem] = siblingURLs.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            let siblingSize = Int64(values.fileSize ?? 0)
            return RemoteFileItem(
                name: url.lastPathComponent,
                path: paths.relativePath(
                    forListedEntry: url,
                    parentIsCanonical: parentIsCanonical,
                    isSymbolicLink: values.isSymbolicLink
                ),
                isDirectory: false,
                size: siblingSize,
                modifiedDate: values.contentModificationDate,
                revision: Self.localRevision(
                    size: siblingSize,
                    modifiedDate: values.contentModificationDate
                )
            )
        }
        let targetPath = paths.relativePath(for: fileURL)
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
        // Checked on the actor, so no other write through this connector can
        // land between the conflict check and the replacement.
        let current = try Self.writebackState(writebackProbe(for: path))
        guard expected.matches(current) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        let individuallyReferenced = isIndividuallyReferencedFile(destination)
        // 单独添加的文件一律原地改写:旁边可能建不了临时文件,换文件还会让它自己的书签失效。
        // 文件夹确定不能新建文件的也一样。
        if individuallyReferenced || Self.definiteFolderAccess(of: destination) == .notWritable {
            try rewriteInPlace(destination, with: localURL, path: path, refreshesBookmark: individuallyReferenced)
            return
        }

        let stagingURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).primuse-writeback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        do {
            try FileManager.default.copyItem(at: localURL, to: stagingURL)
        } catch where MetadataWriteFailurePolicy.denial(error) != nil {
            // 文件夹里不让新建文件(File Provider 目录常见),目标文件本身还可能写得进:改走原地改写。
            plog("Writeback: staging beside the file was refused, rewriting in place: \(error.localizedDescription)")
            try rewriteInPlace(destination, with: localURL, path: path, refreshesBookmark: false)
            return
        }
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: stagingURL,
            backupItemName: nil,
            options: []
        )
        noteOwnWrite(at: destination, path: path)
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

        let authorizedRoots = referenceRoots.isEmpty
            ? [basePath]
            : referenceRoots.filter(\.isDirectory).map(\.url) + referenceRoots.compactMap(\.folderURL)
        guard authorizedRoots.contains(where: { Self.contains(parent, inside: $0) }) else {
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
        noteOwnWrite(at: destination, path: path)
    }

    func canMutateDirectories() async -> Bool { supportsDirectoryMutation }

    func renameDirectory(at path: String, to newPath: String) async throws {
        guard supportsDirectoryMutation,
              (path as NSString).deletingLastPathComponent == (newPath as NSString).deletingLastPathComponent,
              !isVirtualReferenceRoot((path as NSString).deletingLastPathComponent) else {
            throw SourceFolderMutationError.unsupported
        }
        let source = try renameURL(for: path)
        let destination = try renameURL(for: newPath)
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw SourceError.fileNotFound(path)
        }
        let status = source.path.withCString { fromPath in
            destination.path.withCString { toPath in
                renameatx_np(AT_FDCWD, fromPath, AT_FDCWD, toPath, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            if errno == EEXIST { throw SourceFolderMutationError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func moveItem(at path: String, to newPath: String, isDirectory: Bool) async throws {
        guard supportsDirectoryMutation,
              !isVirtualReferenceRoot((path as NSString).deletingLastPathComponent) else {
            throw SourceFolderMutationError.unsupported
        }
        let source = try resolvedURL(for: path, allowRoot: false)
        let destination = try resolvedURL(for: newPath, allowRoot: false)
        guard !isIndividuallyReferencedFile(source) else { throw SourceFolderMutationError.unsupported }
        let status = source.path.withCString { fromPath in
            destination.path.withCString { toPath in
                renameatx_np(AT_FDCWD, fromPath, AT_FDCWD, toPath, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            if errno == EEXIST { throw SourceFolderMutationError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func copyFileWithoutReplacing(at path: String, to newPath: String) async throws {
        guard supportsDirectoryMutation else { throw SourceFolderMutationError.unsupported }
        let source = try resolvedURL(for: path, allowRoot: false)
        let destination = try resolvedURL(for: newPath, allowRoot: false)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".primuse-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let status = renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL))
        guard status == 0 else {
            if errno == EEXIST { throw SourceFolderMutationError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func deleteDirectory(at path: String) async throws {
        guard supportsDirectoryMutation,
              !isVirtualReferenceRoot((path as NSString).deletingLastPathComponent) else {
            throw SourceFolderMutationError.unsupported
        }
        let url = try resolvedURL(for: path, allowRoot: false)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw SourceError.fileNotFound(path)
        }
        try FileManager.default.removeItem(at: url)
    }

    func deleteFile(at path: String) async throws {
        let fileURL = try resolvedURL(for: path, allowRoot: false)
        // fileExists also returns false when a parent is inaccessible. Only
        // the mutation's actual error can distinguish missing from denied.
        try FileManager.default.removeItem(at: fileURL)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let fileURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            // Detached: an inherited actor context would read the whole file
            // while every other call on this connector waits.
            Task.detached {
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }

                    let chunkSize = 64 * 1024 // 64 KB
                    while true {
                        let data = try handle.read(upToCount: chunkSize) ?? Data()
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
        let inventory = try await Self.buildScanInventory(
            startURLs: scanStartURLs(for: path),
            paths: pathResolver()
        )
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
        let inventory = try await Self.buildScanInventory(
            startURLs: scanStartURLs(for: path),
            paths: pathResolver()
        )
        let cueTracksByAudioPath = try await loadCueTracks(from: inventory.cueURLs)
        var cueImageCountByDirectory: [String: Int] = [:]
        for audioPath in cueTracksByAudioPath.keys {
            cueImageCountByDirectory[(audioPath as NSString).deletingLastPathComponent, default: 0] += 1
        }
        var existingCueOffsetsByPath: [String: [Int]] = [:]
        if !cueTracksByAudioPath.isEmpty {
            for offset in existingSongs.indices where existingSongs[offset].isCueTrack {
                let path = existingSongs[offset].filePath
                guard cueTracksByAudioPath[path] != nil else { continue }
                existingCueOffsetsByPath[path, default: []].append(offset)
            }
        }
        let existingByID = Dictionary(
            existingSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingIDsByPath = Dictionary(
            existingSongs.filter { !$0.isCueTrack }.map { ($0.filePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingPathsByID = existingByID.mapValues(\.filePath)
        let songIDsByPath = Dictionary(inventory.items.map { item in
            let id = existingIDsByPath[item.path] ?? PathSongIdentityPolicy.unoccupiedID(
                generatedID: Self.generateID(sourceID: sourceID, path: item.path),
                path: item.path,
                existingPathsByID: existingPathsByID,
                collisionID: { Self.generateID(sourceID: sourceID, path: "\(item.path):file-rename:\($0)") }
            )
            return (item.path, id)
        }, uniquingKeysWith: { first, _ in first })
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
            let id = songIDsByPath[item.path]!
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
                        let physicalID = songIDsByPath[item.path]!

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
                                refreshed.mvPath = item.sidecarHints?.mvPath ?? existing.referencedMusicVideoPath
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
                            let directory = (item.path as NSString).deletingLastPathComponent
                            let trackLyrics = Self.cueTrackLyrics(
                                for: item,
                                descriptors: descriptors,
                                index: inventory.cueDirectoryIndexes[directory],
                                cueImageCount: cueImageCountByDirectory[directory] ?? 1
                            )
                            // 分轨歌词的版本也算进来:后来补进目录的分轨歌词要让这张
                            // 整轨重建;没有分轨歌词时和以前的版本完全一样。
                            let expectedRevision = Self.cueRevision(
                                audioRevision: item.revision,
                                cueRevisions: descriptors.map(\.cueRevision)
                                    + trackLyrics.values.flatMap(\.values).compactMap(\.revision)
                            )
                            let existingTracks = (existingCueOffsetsByPath[item.path] ?? []).map { existingSongs[$0] }
                            if ext != "iso", existingTracks.count == descriptors.count,
                               existingTracks.allSatisfy({ $0.revision == expectedRevision }),
                               Set(existingTracks.map(\.id)) == Set(descriptors.map {
                                   $0.songID(sourceID: self.sourceID, audioPath: item.path)
                               }) {
                                // 能读 CUE 增益之前扫进来的分轨,重扫时也把 CUE 里记的回放增益补上。
                                let descriptorsByID = Dictionary(
                                    descriptors.map { ($0.songID(sourceID: self.sourceID, audioPath: item.path), $0) },
                                    uniquingKeysWith: { first, _ in first }
                                )
                                for var track in existingTracks {
                                    if let descriptor = descriptorsByID[track.id] {
                                        track.applyReplayGain(from: descriptor.track)
                                    }
                                    continuation.yield(ConnectorScannedSong(
                                        song: track,
                                        displayName: track.title,
                                        titleMetadataInspected: false
                                    ))
                                }
                                continue
                            }
                            let tracks = try await self.buildCueSongs(
                                from: item,
                                descriptors: descriptors,
                                trackLyrics: trackLyrics,
                                combinedRevision: expectedRevision
                            )
                            let priorByID = Dictionary(existingTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                            for track in tracks {
                                var song = track.song
                                if let existing = priorByID[song.id] {
                                    song = SongUserMetadataPolicy.preservingUserEdits(from: existing, in: song)
                                    song.dateAdded = existing.dateAdded
                                }
                                continuation.yield(ConnectorScannedSong(
                                    song: song, displayName: song.title,
                                    titleMetadataInspected: track.titleMetadataInspected
                                ))
                            }
                            continue
                        }

                        if ext == "iso" { continue }
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
                        if let existing = existingByID[physicalID] {
                            let url = try self.resolvedURL(for: item.path, allowRoot: false)
                            if let observation = try? LocalAudioObservation(url),
                               let updated = try? await self.readUpdatedSong(existing, item: item, url: url, observation: observation) {
                                continuation.yield(ConnectorScannedSong(song: updated, displayName: item.name,
                                                                        titleMetadataInspected: true))
                            } else {
                                try Task.checkCancellation()
                                // Keep the last readable version while a provider is replacing or downloading the file.
                                continuation.yield(ConnectorScannedSong(song: existing, displayName: item.name,
                                                                        titleMetadataInspected: false))
                            }
                        } else if let scanned = self.buildBareScannedSong(from: item) {
                            continuation.yield(scanned.carryingSongIdentity(physicalID))
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
        /// Sibling indexes of the directories that hold a CUE sheet, keyed by
        /// the source-relative directory, for per-track lyric lookup.
        var cueDirectoryIndexes: [String: SidecarHintResolver.DirectoryIndex] = [:]
    }

    private func scanStartURLs(for path: String) throws -> [URL] {
        isVirtualReferenceRoot(path)
            ? referenceRoots.map(\.url)
            : [try resolvedURL(for: path, allowRoot: true)]
    }

    /// One filesystem enumeration gathers audio, STRM, CUE, covers, lyrics and
    /// MV candidates. Directory-local sibling decoration is applied afterward,
    /// so no second recursive walk is needed. Runs off the actor: a launch
    /// reconciliation walks the whole tree while the person is already
    /// changing tracks, and playback resolves each one through this actor.
    @concurrent
    private nonisolated static func buildScanInventory(
        startURLs: [URL],
        paths: PathResolver
    ) async throws -> LocalScanInventory {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            .isSymbolicLinkKey, .attributeModificationDateKey,
        ]
        var filesByParent: [String: [RemoteFileItem]] = [:]
        var attributeDates: [String: Date] = [:]
        var cueURLsByPath: [String: URL] = [:]
        // Directories whose listed path is already canonical. The walk starts
        // at a canonical root and reaches a directory before its contents, so
        // a non-symlink directory inside a member is one too.
        var canonicalDirectories: Set<String> = []

        func recordFile(_ url: URL, values: URLResourceValues?) throws {
            try Task.checkCancellation()
            guard let values, values.isRegularFile == true else { return }
            let size = Int64(values.fileSize ?? 0)
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            let item = RemoteFileItem(
                name: url.lastPathComponent,
                path: paths.relativePath(
                    forListedEntry: url,
                    parentIsCanonical: canonicalDirectories.contains(parentPath),
                    isSymbolicLink: values.isSymbolicLink
                ),
                isDirectory: false,
                size: size,
                modifiedDate: values.contentModificationDate,
                revision: Self.localRevision(size: size, modifiedDate: values.contentModificationDate)
            )
            filesByParent[parentPath, default: []].append(item)
            attributeDates[item.path] = values.attributeModificationDate
            if PrimuseConstants.supportedVirtualTrackExtensions.contains(url.pathExtension.lowercased()) {
                cueURLsByPath[item.path] = url
            }
        }

        for startURL in startURLs {
            try Task.checkCancellation()
            let values = try startURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true {
                try recordFile(startURL, values: try? startURL.resourceValues(forKeys: keys))
                continue
            }
            guard values.isDirectory == true else {
                throw SourceError.connectionFailed(
                    "Local source root is not a readable file or folder: \(startURL.path)"
                )
            }
            let enumerationRoot = canonicalURL(startURL)
            canonicalDirectories.insert(enumerationRoot.path)
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: enumerationRoot,
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
                let entryValues = try? url.resourceValues(forKeys: keys)
                if entryValues?.isDirectory == true,
                   entryValues?.isSymbolicLink == false,
                   canonicalDirectories.contains(
                       url.deletingLastPathComponent().standardizedFileURL.path
                   ) {
                    canonicalDirectories.insert(url.standardizedFileURL.path)
                }
                try recordFile(url, values: entryValues)
            }
            if let enumerationError { throw enumerationError }
        }

        var scannable: [RemoteFileItem] = []
        var cueDirectoryIndexes: [String: SidecarHintResolver.DirectoryIndex] = [:]
        for (parentPath, siblings) in filesByParent {
            let byPath = Dictionary(siblings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let sidecarIndex = SidecarHintResolver.DirectoryIndex(siblings)
                .inheriting(folderCover: Self.albumFolderCover(aboveDiscFolder: parentPath, in: filesByParent))
            if let first = siblings.first,
               siblings.contains(where: {
                   PrimuseConstants.supportedVirtualTrackExtensions.contains(
                       ($0.name as NSString).pathExtension.lowercased()
                   )
               }) {
                cueDirectoryIndexes[(first.path as NSString).deletingLastPathComponent] = sidecarIndex
            }
            for item in siblings {
                guard let decorated = SidecarHintResolver.scannableItem(
                    item,
                    index: sidecarIndex
                ) else { continue }
                let sidecarRevisions = [
                    decorated.sidecarHints?.coverPath,
                    decorated.sidecarHints?.lyricsPath,
                    decorated.sidecarHints?.mvPath,
                ].compactMap { $0 }.compactMap { (byPath[$0] ?? sidecarIndex.item(atPath: $0))?.revision }
                let revision = Self.compositeRevision([decorated.revision].compactMap { $0 } + sidecarRevisions)
                scannable.append(RemoteFileItem(
                    name: decorated.name,
                    path: decorated.path,
                    isDirectory: false,
                    size: decorated.size,
                    modifiedDate: decorated.modifiedDate,
                    sidecarHints: decorated.sidecarHints,
                    revision: Self.stampedRevision(revision, changed: attributeDates[item.path])
                ))
            }
        }
        scannable.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
        return LocalScanInventory(
            items: scannable,
            cueURLs: cueURLsByPath.values.sorted { $0.path < $1.path },
            cueDirectoryIndexes: cueDirectoryIndexes
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
            && !EmbeddedMediaTrackInventory.isStemFileName(item.name)
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
        refreshed.contentMetadata = SongContentMetadata.merging(previous: existing.contentMetadata, incoming: metadata.contentMetadata)
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
        let cueName: String
        let cueRevision: String
        let albumTitle: String?
        let albumPerformer: String?
        let genre: String?
        let year: Int?
        let format: AudioFormat
        let track: CueTrack

        func songID(sourceID: String, audioPath: String) -> String {
            LocalFileSource.generateID(sourceID: sourceID, path: "\(audioPath)#cue:\(cuePath)#track:\(track.identityKey)")
        }
    }

    /// Parse local CUE sheets up front so a referenced album image is emitted
    /// as virtual tracks and never duplicated as one whole-file library row.
    private func loadCueTracks(from cueURLs: [URL]) async throws -> [String: [CueTrackDescriptor]] {
        var result: [String: [CueTrackDescriptor]] = [:]

        var externalSheets: [URL: [ISOAlbumMetadataPolicy.Sidecar]] = [:]
        let ordered = cueURLs.sorted { $0.pathExtension.lowercased() < $1.pathExtension.lowercased() }
        for cueURL in ordered {
            try Task.checkCancellation()
            guard let values = try? cueURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            ), values.isRegularFile == true else { continue }
            let cue: CueSheet
            if cueURL.pathExtension.lowercased() == "iso" {
                guard let parsed = try await ISOAudioReader.localSheet(url: cueURL) else { continue }
                cue = ISOAlbumMetadataPolicy.merging(
                    parsed, imageFileName: cueURL.lastPathComponent,
                    sidecars: externalSheets[cueURL.deletingLastPathComponent(), default: []]
                )
            } else {
                guard (values.fileSize ?? 0) <= 1024 * 1024,
                      let data = try? Data(contentsOf: cueURL, options: .mappedIfSafe),
                      let parsed = CueSheetParser.parse(data: data) else { continue }
                cue = parsed
                externalSheets[cueURL.deletingLastPathComponent(), default: []]
                    .append(.init(name: cueURL.lastPathComponent, sheet: parsed))
            }

            for cueFile in cue.filesForScanning(sheetFileName: cueURL.lastPathComponent) {
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
                    let identity = CueTrackIdentity(sheet: cue, track: track)
                    result[audioPath, default: []].append(
                        CueTrackDescriptor(
                            cuePath: relativePath(for: cueURL),
                            cueName: cueURL.lastPathComponent,
                            cueRevision: cueRevision,
                            albumTitle: identity.albumTitle,
                            albumPerformer: identity.albumArtist,
                            genre: identity.genre,
                            year: identity.year,
                            format: track.isoAudioTrack?.format ?? format,
                            track: track
                        )
                    )
                }
            }
        }
        return result
    }

    /// Each CUE sheet's per-track lyric files beside `item`, keyed by the
    /// sheet's relative path and then by track number.
    private nonisolated static func cueTrackLyrics(
        for item: RemoteFileItem,
        descriptors: [CueTrackDescriptor],
        index: SidecarHintResolver.DirectoryIndex?,
        cueImageCount: Int
    ) -> [String: [Int: RemoteFileItem]] {
        guard let index else { return [:] }
        let audioBasename = (item.name as NSString).deletingPathExtension
        var result: [String: [Int: RemoteFileItem]] = [:]
        for (cuePath, sheetDescriptors) in Dictionary(grouping: descriptors, by: \.cuePath) {
            let lyrics = index.cueTrackLyrics(
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
            if !lyrics.isEmpty { result[cuePath] = lyrics }
        }
        return result
    }

    private func buildCueSongs(
        from item: RemoteFileItem,
        descriptors: [CueTrackDescriptor],
        trackLyrics: [String: [Int: RemoteFileItem]],
        combinedRevision: String
    ) async throws -> [ConnectorScannedSong] {
        let fileURL = try await localURL(for: item.path)
        let physicalID = Self.generateID(sourceID: sourceID, path: item.path)
        let fallbackTitle = ((item.name as NSString).lastPathComponent as NSString).deletingPathExtension
        let metadata = fileURL.pathExtension.lowercased() == "iso"
            ? MetadataService.SongMetadata(title: fallbackTitle)
            : await metadataService.loadMetadata(
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
        let ffmpegInfo = needsFFmpegProbe && ext != "iso" ? try? await ffmpegDecoder.fileInfo(for: fileURL) : nil
        let physicalDuration = Self.preferredPositive(ffmpegInfo?.duration, fallback: metadata.duration)

        return descriptors.compactMap { descriptor in
            guard let start = descriptor.track.startTime else { return nil }
            let end = descriptor.track.endTime ?? (physicalDuration > start ? physicalDuration : nil)
            let artist = descriptor.track.performer ?? descriptor.albumPerformer ?? metadata.artist
            let album = descriptor.track.isoAudioTrack?.albumTitle ?? descriptor.albumTitle ?? metadata.albumTitle
            let albumArtist = AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: descriptor.albumPerformer ?? metadata.albumArtist,
                trackArtistName: artist
            )
            let trackID = descriptor.songID(sourceID: sourceID, audioPath: item.path)
            var song = Song(
                id: trackID,
                title: descriptor.track.title ?? String(
                    format: String(localized: "cue_track_title_format"),
                    descriptor.track.number
                ),
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
                sampleRate: descriptor.track.isoAudioTrack?.sampleRate ?? (descriptor.format == .sacdISO ? 2_822_400 : nil) ?? Self.preferredPositiveInt(
                    ffmpegInfo.map { Int($0.sampleRate) },
                    fallback: metadata.sampleRate
                ),
                bitDepth: descriptor.track.isoAudioTrack?.bitDepth ?? (descriptor.format == .sacdISO ? 1 : nil) ?? Self.preferredPositiveInt(
                    ffmpegInfo?.bitDepth,
                    fallback: metadata.bitDepth
                ),
                genre: descriptor.genre ?? metadata.genre,
                year: descriptor.year ?? metadata.year,
                lastModified: item.modifiedDate,
                coverArtFileName: item.sidecarHints?.coverPath ?? metadata.coverArtFileName,
                // 分轨自己的歌词优先;整轨同名歌词和整轨内嵌歌词都是整张专辑的,
                // 只在这一轨没有自己的歌词文件时兜底。
                lyricsFileName: trackLyrics[descriptor.cuePath]?[descriptor.track.number]?.path
                    ?? item.sidecarHints?.lyricsPath
                    ?? metadata.lyricsFileName,
                mvPath: item.sidecarHints?.mvPath ?? sidecarPath(nextTo: item.path, named: metadata.mvPath),
                cueSheetPath: descriptor.cuePath,
                cueStartTime: start,
                cueEndTime: end,
                sacdTrackNumber: descriptor.format == .sacdISO ? descriptor.track.number : nil,
                isoAudioTrack: descriptor.track.isoAudioTrack,
                revision: combinedRevision,
                audioCodec: ContainerAudioCodecPolicy.storedCodec(
                    metadata.audioCodec, container: descriptor.format
                ),
                effectiveBitDepth: metadata.effectiveBitDepth,
                contentMetadata: metadata.contentMetadata
            )
            // 整轨文件的增益标签是整张的;CUE 里逐轨记的才是这一轨的。
            song.applySACDMetadata(from: descriptor.track)
            song.applyReplayGain(from: descriptor.track)
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

    private nonisolated static func remoteFileItem(for url: URL, path: String) throws -> RemoteFileItem {
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
        resolveReferenceRootsIfNeeded()
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
        resolveReferenceRootsIfNeeded()
        guard !referenceBookmarksUnavailable else {
            throw SourceError.credentialUnavailable(String(localized: "local_reference_permission_missing"))
        }
        if !referenceRoots.isEmpty {
            return try resolvedReferenceURL(for: path, allowRoot: allowRoot)
        }
        if path.hasPrefix("/"),
           let migratedURL = PrimuseSandboxPathResolver.existingURL(
               forStoredAbsolutePath: path
           ) {
            let standardizedURL = Self.canonicalURL(migratedURL)
            let standardizedBase = Self.canonicalURL(basePath)
            let basePrefix = standardizedBase.path.hasSuffix("/")
                ? standardizedBase.path
                : standardizedBase.path + "/"
            if (allowRoot && standardizedURL.path == standardizedBase.path)
                || standardizedURL.path.hasPrefix(basePrefix) {
                return standardizedURL
            }
        }

        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = Self.canonicalURL(Self.canonicalURL(basePath).appendingPathComponent(relativePath))
        let baseStandardized = Self.canonicalURL(basePath)
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
                    return Self.canonicalURL(root.url)
                }
                let prefix = component + "/"
                guard relativePath.hasPrefix(prefix) else { continue }
                remainder = String(relativePath.dropFirst(prefix.count))
            } else {
                if relativePath.isEmpty {
                    guard allowRoot else { throw SourceError.fileNotFound(path) }
                    return Self.canonicalURL(root.url)
                }
                remainder = relativePath
            }

            guard root.isDirectory else { throw SourceError.fileNotFound(path) }
            let candidate = Self.canonicalURL(Self.canonicalURL(root.url).appendingPathComponent(remainder))
            guard Self.contains(candidate, inside: root.url) else {
                throw SourceError.connectionFailed("Refusing to access outside source root: \(path)")
            }
            return candidate
        }
        if let sibling = grantedSiblingURL(named: relativePath) { return sibling }
        throw SourceError.fileNotFound(path)
    }

    // MARK: - 单独添加的文件:补授权的所在文件夹

    /// 旁边文件能用的扩展名:歌词、封面、MV,和 `SidecarHintResolver` 认的一致。音频不在里面:
    /// 用户没添加的歌不会因为授权了文件夹就出现在源里,也写不到、删不到。
    private static let grantedSiblingExtensions: Set<String> = {
        var allowed = Set(PrimuseConstants.supportedCoverExtensions)
        allowed.formUnion(PrimuseConstants.readableLyricsExtensions)
        allowed.formUnion(PrimuseConstants.supportedMusicVideoExtensions)
        return allowed
            .subtracting(PrimuseConstants.supportedAudioExtensions)
            .subtracting(PrimuseConstants.supportedStreamDescriptorExtensions)
    }()

    /// 单独添加的文件在虚拟根目录下叫 `/<文件名>`,它旁边的歌词文件、封面文件按同样的名字规则叫
    /// `/<文件名去扩展名>.lrc`、`/<文件名去扩展名>-cover.jpg`。授权过所在文件夹的,把这些名字
    /// 对到真实文件夹里;同名重复的文件(虚拟名带 「(2)」)换回真实的文件名主干。
    private func grantedSiblingURL(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"),
              Self.grantedSiblingExtensions.contains((name as NSString).pathExtension.lowercased()),
              let match = grantedSiblingRoot(forVirtualName: name) else { return nil }
        let realName = match.realStem + name.dropFirst(match.virtualStem.count)
        let candidate = Self.canonicalURL(
            Self.canonicalURL(match.root.url).deletingLastPathComponent().appendingPathComponent(realName)
        )
        guard let folder = match.root.folderURL, Self.contains(candidate, inside: folder) else { return nil }
        return candidate
    }

    private struct GrantedSiblingRoot {
        let root: LocalReferenceRoot
        let virtualStem: String
        let realStem: String
    }

    /// 名字主干最长的那个匹配:`Song Remix.lrc` 归 `Song Remix.flac`,不归 `Song.flac`。
    private func grantedSiblingRoot(forVirtualName name: String) -> GrantedSiblingRoot? {
        resolveReferenceRootsIfNeeded()
        var best: GrantedSiblingRoot?
        for root in referenceRoots where !root.isDirectory && root.folderURL != nil {
            guard let component = root.virtualPathComponent, component != name else { continue }
            let virtualStem = (component as NSString).deletingPathExtension
            guard Self.isSidecarName(name, ofStem: virtualStem),
                  virtualStem.count > (best?.virtualStem.count ?? -1) else { continue }
            best = GrantedSiblingRoot(
                root: root,
                virtualStem: virtualStem,
                realStem: root.url.deletingPathExtension().lastPathComponent
            )
        }
        return best
    }

    /// 旁边文件的命名:主干后面紧跟 `.`(`.lrc`、`.zh.lrc`)或 `-`(`-cover.jpg`)。
    private nonisolated static func isSidecarName(_ name: String, ofStem stem: String) -> Bool {
        guard !stem.isEmpty, name.count > stem.count, name.hasPrefix(stem) else { return false }
        let next = name[name.index(name.startIndex, offsetBy: stem.count)]
        return next == "." || next == "-"
    }

    private struct GrantedSiblingStem: Sendable {
        let virtualStem: String
        let realStem: String
        let audioName: String
    }

    private struct GrantedSiblingFolder: Sendable {
        let directory: URL
        let stems: [GrantedSiblingStem]
    }

    /// 授权过文件夹的单独文件,按所在目录归在一起:同一个目录只列一次。
    private func grantedSiblingFolders() -> [GrantedSiblingFolder] {
        var order: [String] = []
        var folders: [String: (directory: URL, stems: [GrantedSiblingStem])] = [:]
        for root in referenceRoots where !root.isDirectory && root.folderURL != nil {
            guard let component = root.virtualPathComponent else { continue }
            let directory = root.url.deletingLastPathComponent()
            let key = directory.standardizedFileURL.path
            let stem = GrantedSiblingStem(
                virtualStem: (component as NSString).deletingPathExtension,
                realStem: root.url.deletingPathExtension().lastPathComponent,
                audioName: root.url.lastPathComponent
            )
            if folders[key] == nil {
                order.append(key)
                folders[key] = (directory, [])
            }
            folders[key]?.stems.append(stem)
        }
        return order.compactMap { key in
            folders[key].map { GrantedSiblingFolder(directory: $0.directory, stems: $0.stems) }
        }
    }

    /// 虚拟根目录列表里补上授权过文件夹的单独文件旁边的歌词、封面、MV 文件,读歌词和保存前的
    /// 检查才看得见。列目录不占着连接器:播放取文件地址走的也是它。
    @concurrent
    private nonisolated static func listGrantedSiblings(
        _ folders: [GrantedSiblingFolder],
        excluding listed: Set<String>
    ) async -> [RemoteFileItem] {
        var items: [RemoteFileItem] = []
        var seen = listed
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.directory.path) else {
                continue
            }
            for realName in names {
                guard grantedSiblingExtensions.contains((realName as NSString).pathExtension.lowercased()) else {
                    continue
                }
                let owners = folder.stems.filter {
                    $0.audioName != realName && isSidecarName(realName, ofStem: $0.realStem)
                }
                guard let owner = owners.max(by: { $0.realStem.count < $1.realStem.count }) else { continue }
                let virtualName = owner.virtualStem + realName.dropFirst(owner.realStem.count)
                let url = folder.directory.appendingPathComponent(realName)
                guard seen.insert(virtualName.lowercased()).inserted,
                      let values = try? url.resourceValues(forKeys: [
                          .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                      ]), values.isDirectory != true else { continue }
                let size = Int64(values.fileSize ?? 0)
                items.append(RemoteFileItem(
                    name: virtualName,
                    path: "/" + virtualName,
                    isDirectory: false,
                    size: size,
                    modifiedDate: values.contentModificationDate,
                    revision: localRevision(size: size, modifiedDate: values.contentModificationDate)
                ))
            }
        }
        return items
    }

    /// 单独添加、没有补授权所在文件夹的文件:只能改它本身。
    private func lacksFolderAccess(_ url: URL) -> Bool {
        referenceRoots.contains {
            !$0.isDirectory && $0.folderURL == nil && Self.canonicalURL($0.url) == Self.canonicalURL(url)
        }
    }

    /// 授权所在文件夹之后,让这个连接器接着用上新授权:只给还没有文件夹授权的单独文件补上,
    /// 不动已经在用的访问权限,同一个源正在播放的歌不受影响。
    func reloadFolderGrants() {
        #if os(iOS) || os(macOS)
        resolveReferenceRootsIfNeeded()
        guard let references = LocalBookmarkStore.resolveReferences(sourceID: sourceID, refreshStaleBookmarks: false),
              !references.isEmpty else { return }
        var added = 0
        for index in referenceRoots.indices where !referenceRoots[index].isDirectory
            && referenceRoots[index].folderURL == nil {
            guard let match = references.first(where: {
                      $0.virtualPathComponent == referenceRoots[index].virtualPathComponent
                  }),
                  let folderURL = match.folderURL else { continue }
            referenceRoots[index].folderURL = folderURL
            referenceRoots[index].folderUsesSecurityScope = folderURL.startAccessingSecurityScopedResource()
            added += 1
        }
        if added > 0 {
            plog("📁 Local reference connector picked up folder access source=\(sourceID.prefix(8)) files=\(added)")
        }
        #endif
    }

    // MARK: - 保存位置探测

    /// 音频文件和所在文件夹现在能不能写。只读文件系统属性,不碰文件内容。
    func saveLocationAccess(for path: String) async -> SaveLocationAccess {
        guard let url = try? resolvedURL(for: path, allowRoot: false) else { return .unknown }
        return await Self.probeSaveLocation(url, lacksFolderAccess: lacksFolderAccess(url))
    }

    private static let accessKeys: Set<URLResourceKey> = [
        .isWritableKey, .volumeIsReadOnlyKey, .volumeIsLocalKey, .isUbiquitousItemKey,
    ]

    /// 结论确定才算数:网络卷、iCloud 云盘和其它 File Provider 目录报的写权限不可靠,一律当「不知道」,
    /// 照常试着写,写失败再按失败处理。原来能写进文件的,不会因为探测变成只存 Primuse。
    private nonisolated static func definiteAccess(_ values: URLResourceValues?, path: String) -> SaveLocationPolicy.Access {
        guard let values else { return .unknown }
        if values.volumeIsReadOnly == true { return .readOnlyVolume }
        guard let writable = values.isWritable else { return .unknown }
        if writable { return .writable }
        let uncertain = values.volumeIsLocal == false
            || values.isUbiquitousItem == true
            || isFileProviderPath(path)
        return uncertain ? .unknown : .notWritable
    }

    private nonisolated static func isFileProviderPath(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/")
            || path.contains("/Library/CloudStorage/")
            || path.contains("/File Provider Storage/")
    }

    /// 歌曲所在的文件夹能不能新建文件。确定不能时才是 `.notWritable`。
    private nonisolated static func definiteFolderAccess(of file: URL) -> SaveLocationPolicy.Access {
        let folder = URL(fileURLWithPath: file.deletingLastPathComponent().path)
        return definiteAccess(try? folder.resourceValues(forKeys: accessKeys), path: folder.path)
    }

    @concurrent
    private nonisolated static func probeSaveLocation(_ url: URL, lacksFolderAccess: Bool) async -> SaveLocationAccess {
        var access = SaveLocationAccess()
        // 每次新建 URL,不吃上一次缓存的属性值。
        let file = URL(fileURLWithPath: url.path)
        let values = try? file.resourceValues(forKeys: accessKeys.union([.ubiquitousItemHasUnresolvedConflictsKey]))
        access.hasICloudConflict = values?.ubiquitousItemHasUnresolvedConflicts == true
        // 还没下到这台设备的 iCloud 文件(旧式占位)读不到属性:写之前会先下载,不算不能写。
        access.audioFile = definiteAccess(values, path: file.path)
        if lacksFolderAccess {
            access.folder = .noAccess
        } else {
            access.folder = definiteFolderAccess(of: file)
        }
        if access.audioFile == .readOnlyVolume, access.folder != .noAccess {
            access.folder = .readOnlyVolume
        }
        return access
    }

    // MARK: - 写回前先把 iCloud 文件下到本机

    /// 还没下到这台设备的 iCloud 云盘文件,改写之前要先下载并等它落地(最多 3 分钟),不能当成只读。
    /// 没网时立刻失败;超时按下载失败报,不当成马上能重试的网络抖动。
    @concurrent
    private nonisolated static func downloadForWritebackIfNeeded(_ url: URL) async throws {
        guard await UbiquitousPlaybackFile.needsDownload(url) else { return }
        plog("☁️ Writeback: file is not on this device yet, downloading before the write name=\(url.lastPathComponent)")
        let started = Date()
        do {
            try await AsyncOperationTimeout.run(seconds: 180) {
                try await UbiquitousPlaybackFile.download(
                    url,
                    isOffline: { @MainActor in
                        NetworkMonitor.shared.hasDeterminedPath && !NetworkMonitor.shared.isReachable
                    },
                    isCurrent: { true }
                )
            }
            plog("☁️ Writeback: download finished in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch let error as UbiquitousPlaybackFile.DownloadError {
            plog("⚠️ Writeback: iCloud download failed (\(error.failure)) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            plog("⚠️ Writeback: iCloud download did not finish in time: \(error.localizedDescription)")
            throw UbiquitousPlaybackFile.DownloadError(failure: .timedOut, underlyingDescription: error.localizedDescription)
        }
    }

    // MARK: - 原地改写

    /// 原地改写一个音频文件(做法和失败时怎么保住原文件见 `InPlaceFileRewrite`)。
    private func rewriteInPlace(_ destination: URL, with source: URL, path: String, refreshesBookmark: Bool) throws {
        try InPlaceFileRewrite.rewrite(destination, with: source, sourceID: sourceID)
        #if os(iOS) || os(macOS)
        if refreshesBookmark {
            LocalBookmarkStore.refreshFileBookmark(sourceID: sourceID, fileURL: destination)
        }
        #endif
        // 和换文件那条路一样记下：这次改写引起的文件变动通知不再重读标签。
        noteOwnWrite(at: destination, path: path)
    }

    @concurrent
    private nonisolated static func restorePendingRewrites(sourceID: String) async {
        InPlaceFileRewrite.restorePending(sourceID: sourceID)
    }

    private func relativePath(for url: URL) -> String {
        pathResolver().relativePath(for: url)
    }

    private func pathResolver() -> PathResolver {
        resolveReferenceRootsIfNeeded()
        if let cachedPathResolver { return cachedPathResolver }
        let resolver = PathResolver(
            roots: referenceRoots.map { root in
                PathResolver.Root(
                    virtualPathComponent: root.virtualPathComponent,
                    canonicalPath: Self.canonicalURL(root.url).path
                )
            },
            canonicalBasePath: Self.canonicalURL(basePath).path
        )
        // A root that is not there yet (an unmounted volume) canonicalises
        // differently once it appears, so only a complete answer is kept.
        let rootsExist = resolver.roots.allSatisfy {
            FileManager.default.fileExists(atPath: $0.canonicalPath)
        } && FileManager.default.fileExists(atPath: resolver.canonicalBasePath)
        if rootsExist { cachedPathResolver = resolver }
        return resolver
    }

    private nonisolated static func isCanonical(_ url: URL) -> Bool {
        canonicalURL(url).path == url.standardizedFileURL.path
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
            !$0.isDirectory && Self.canonicalURL($0.url) == Self.canonicalURL(url)
        }
    }

    /// Foundation may resolve /private/var only for an existing file. Resolve
    /// the nearest existing ancestor first so a new sidecar has the same root
    /// identity as its audio file; directory symlinks still participate in the
    /// boundary check, including when the final child does not exist yet.
    private nonisolated static func canonicalURL(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while ancestor.path != "/",
              !FileManager.default.fileExists(atPath: ancestor.path) {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private nonisolated static func contains(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = canonicalURL(candidate).path
        let rootPath = canonicalURL(root).path
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

    nonisolated static func generateID(sourceID: String, path: String) -> String {
        let input = "\(sourceID):\(path)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func localRevision(size: Int64, modifiedDate: Date?) -> String {
        let milliseconds = modifiedDate.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? -1
        return "local:\(size):\(milliseconds)"
    }

    /// 分碟子文件夹(CD1、Disc 2)自己没有封面图时用的上一层专辑文件夹的封面图。
    private static func albumFolderCover(
        aboveDiscFolder directory: String,
        in filesByParent: [String: [RemoteFileItem]]
    ) -> RemoteFileItem? {
        guard let parent = DiscFolderPolicy.parentDirectory(ofDiscFolder: directory),
              !FolderCoverNamePolicy.isGenericDirectory(named: (parent as NSString).lastPathComponent),
              let siblings = filesByParent[parent] else { return nil }
        return SidecarHintResolver.DirectoryIndex(siblings).folderCover()
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
        if item.revision != nil, existing.revision != nil {
            return EmbeddedMetadataRemoteFileState.revisionMatches(existing, current: item.revision)
        }
        if let revision = item.revision, revision.contains("|"),
           !EmbeddedMetadataRemoteFileState.revisionMatches(existing, current: revision) { return false }
        guard existing.fileSize == item.size else { return false }
        if let lhs = existing.lastModified, let rhs = item.modifiedDate {
            return abs(lhs.timeIntervalSince(rhs)) < 0.001
        }
        return true
    }

    private nonisolated static func stampedRevision(_ base: String, changed: Date?) -> String {
        guard let changed else { return base }
        return base + "|" + String(changed.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
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

extension LocalFileSource: SaveLocationProbing {}

/// 本机文件夹引用里那些放在 iCloud 云盘、还没下到这台设备的歌:起播前读状态、请求下载、
/// 等到能读(#170)。判定规则见 `UbiquitousPlaybackDownloadPolicy`。
enum UbiquitousPlaybackFile {
    struct DownloadError: LocalizedError, Sendable {
        let failure: UbiquitousPlaybackDownloadPolicy.Failure
        let underlyingDescription: String?

        var errorDescription: String? {
            switch failure {
            case .offline:
                String(localized: "playback_icloud_error_offline")
            case .downloadError, .neverStarted, .timedOut:
                String(localized: "playback_icloud_error_download")
            }
        }
    }

    private struct Snapshot: Sendable {
        var status: UbiquitousPlaybackDownloadPolicy.Status
        var isDownloading: Bool
        var downloadErrorText: String?
    }

    /// 旧式 iCloud 占位:原文件不在,同目录下有 `.名字.icloud`。
    nonisolated static func isEvictedPlaceholder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// 这个文件要不要先从 iCloud 下载。普通本地文件、读不到状态时都是 false。
    @concurrent
    nonisolated static func needsDownload(_ url: URL) async -> Bool {
        guard url.isFileURL else { return false }
        return UbiquitousPlaybackDownloadPolicy.needsDownload(snapshot(of: url).status)
    }

    /// 读这个文件要不要走网络:还没下到本机的 iCloud 云盘文件,或者放在网络卷上(Mac 上
    /// 挂载的 SMB 之类)。后台补资料在不能联网时先问这里。读不到属性时按本机文件算。
    @concurrent
    nonisolated static func readingNeedsNetwork(_ url: URL) async -> Bool {
        guard url.isFileURL else { return false }
        if UbiquitousPlaybackDownloadPolicy.needsDownload(snapshot(of: url).status) { return true }
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == false
    }

    /// 请求下载并等到文件可读。`isCurrent` 为 false(已经换了别的歌)时以取消结束。
    @concurrent
    nonisolated static func download(
        _ url: URL,
        isOffline: @escaping @Sendable () async -> Bool,
        isCurrent: @escaping @Sendable () async -> Bool
    ) async throws {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // 请求本身失败也接着看状态:文件可能已经在下了。
            plog("☁️ iCloud download request failed for '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
        var monitor = UbiquitousPlaybackDownloadPolicy.Monitor(
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        while true {
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            let current = snapshot(of: url)
            let verdict = monitor.observe(
                status: current.status,
                isDownloading: current.isDownloading,
                hasDownloadError: current.downloadErrorText != nil,
                isOffline: await isOffline(),
                at: ProcessInfo.processInfo.systemUptime
            )
            switch verdict {
            case .ready:
                return
            case .waiting:
                try await Task.sleep(for: UbiquitousPlaybackDownloadPolicy.pollInterval)
            case .failed(let failure):
                throw DownloadError(failure: failure, underlyingDescription: current.downloadErrorText)
            }
        }
    }

    /// 只在后台用:读的是文件提供方的状态,每次新建 URL,不吃上一次缓存的属性值。
    private nonisolated static func snapshot(of url: URL) -> Snapshot {
        let fresh = URL(fileURLWithPath: url.path)
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey,
        ]
        guard let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            // 只有旧式占位文件时 Foundation 也可能成功返回一组空属性。
            let evicted = !FileManager.default.fileExists(atPath: fresh.path) && isEvictedPlaceholder(fresh)
            return Snapshot(status: evicted ? .notDownloaded : .notUbiquitous, isDownloading: false, downloadErrorText: nil)
        }
        let status: UbiquitousPlaybackDownloadPolicy.Status
        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current): status = .current
        case .some(.downloaded): status = .downloaded
        case .some(.notDownloaded): status = .notDownloaded
        default: status = .notUbiquitous
        }
        return Snapshot(
            status: status,
            isDownloading: values.ubiquitousItemIsDownloading == true,
            downloadErrorText: values.ubiquitousItemDownloadingError?.localizedDescription
        )
    }
}

/// 只拿到文件本身的权限(单独添加的文件),或者文件夹里不让新建文件时,改写音频文件的做法:
/// 协调写入,从头覆盖,最后截断到新长度并落盘,不先把文件截成 0。
///
/// 任何一步出错都不丢用户的原文件:
/// - 写之前先看空间,新内容和备份都放得下才动手,不够就报错,文件不动。
/// - 备份放在 Application Support 下的专用目录(不是临时目录、不是缓存),写完并回读核对通过才删。
/// - 写入或核对失败就从备份放回,放回后再核对一次。
/// - 放回也失败:备份留着,记一笔待恢复(文件书签、备份、原来的大小与修改时间),报错说清楚;
///   下次用到这个音乐源时自动放回。
enum InPlaceFileRewrite {
    /// 测试用:模拟写到一半出错、放回也出错、空间不够。
    struct FaultInjection: Sendable {
        var failWriteAfterBytes: Int64?
        var failRestore: Bool
        var availableCapacity: Int64?

        init(failWriteAfterBytes: Int64? = nil, failRestore: Bool = false, availableCapacity: Int64? = nil) {
            self.failWriteAfterBytes = failWriteAfterBytes
            self.failRestore = failRestore
            self.availableCapacity = availableCapacity
        }
    }

    enum Failure: LocalizedError, Equatable {
        /// 空间不够,文件没动。
        case insufficientSpace(needed: Int64, available: Int64)
        /// 写的时候出错,原文件已经放回并核对过。
        case restored(detail: String)
        /// 写的时候出错,放回也没成;备份留着,下次自动放回。
        case backupKept(detail: String)

        var errorDescription: String? {
            switch self {
            case .insufficientSpace(let needed, let available):
                return String(
                    format: String(localized: "save_location_rewrite_no_space_format"),
                    ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: max(0, available), countStyle: .file)
                )
            case .restored:
                return String(localized: "save_location_rewrite_restored")
            case .backupKept:
                return String(localized: "save_location_rewrite_backup_kept")
            }
        }
    }

    /// 放回失败时记下的一笔。
    struct PendingRestore: Codable, Sendable, Equatable {
        let id: String
        let sourceID: String
        let filePath: String
        let fileBookmark: Data?
        let backupFileName: String
        let originalSize: Int64
        let originalModified: Date?
        let originalSHA256: String
        /// 出错之后文件的样子:之后又变了,说明别处已经放上了新的完整版本,不去覆盖。
        let damagedSize: Int64?
        let damagedModified: Date?
        let createdAt: Date
    }

    static var defaultBackupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WritebackBackups", isDirectory: true)
    }

    private static let lock = NSLock()

    static func rewrite(
        _ destination: URL,
        with source: URL,
        sourceID: String,
        backupDirectory: URL = defaultBackupDirectory,
        faults: FaultInjection = FaultInjection()
    ) throws {
        let newSize = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        plog("Rewrite in place: begin name=\(destination.lastPathComponent) bytes=\(newSize)")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var outcome: Result<Void, any Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: destination,
            options: [],
            error: &coordinationError
        ) { url in
            outcome = Result {
                try rewriteCoordinated(
                    url,
                    with: source,
                    newSize: newSize,
                    sourceID: sourceID,
                    backupDirectory: backupDirectory,
                    faults: faults
                )
            }
        }
        if let coordinationError {
            plog("⚠️ Rewrite in place: coordination failed, file untouched: \(coordinationError.localizedDescription)")
            throw coordinationError
        }
        try outcome.get()
    }

    private static func rewriteCoordinated(
        _ url: URL,
        with source: URL,
        newSize: Int64,
        sourceID: String,
        backupDirectory: URL,
        faults: FaultInjection
    ) throws {
        let fileManager = FileManager.default
        let original = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let originalSize = Int64(original.fileSize ?? 0)
        if let free = faults.availableCapacity ?? availableCapacity(at: url.deletingLastPathComponent()),
           free < newSize {
            plog("⚠️ Rewrite in place: not enough space beside the file need=\(newSize) free=\(free), file untouched")
            throw Failure.insufficientSpace(needed: newSize, available: free)
        }
        if let free = faults.availableCapacity ?? availableCapacity(at: backupDirectory), free < originalSize {
            plog("⚠️ Rewrite in place: not enough space for the backup need=\(originalSize) free=\(free), file untouched")
            throw Failure.insufficientSpace(needed: originalSize, available: free)
        }
        let backupName = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "bak" : url.pathExtension)
        let backup = backupDirectory.appendingPathComponent(backupName)
        try fileManager.copyItem(at: url, to: backup)
        let originalSHA = try SHA256FileDigest.hexDigest(at: backup)
        let expectedSHA = try SHA256FileDigest.hexDigest(at: source)
        plog("Rewrite in place: backup made bytes=\(originalSize)")
        do {
            try overwrite(url, with: source, length: newSize, failAfterBytes: faults.failWriteAfterBytes)
            guard try SHA256FileDigest.hexDigest(at: url) == expectedSHA else {
                throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
            }
            try? fileManager.removeItem(at: backup)
            plog("Rewrite in place: written and read back, backup removed")
        } catch {
            plog("⚠️ Rewrite in place: write failed, putting the original back: \(error.localizedDescription)")
            do {
                if faults.failRestore { throw CocoaError(.fileWriteUnknown) }
                try overwrite(url, with: backup, length: originalSize, failAfterBytes: nil)
                guard try SHA256FileDigest.hexDigest(at: url) == originalSHA else {
                    throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
                }
                try? fileManager.removeItem(at: backup)
                plog("Rewrite in place: original put back and read back")
            } catch let restoreError {
                let damaged = try? URL(fileURLWithPath: url.path)
                    .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                record(PendingRestore(
                    id: UUID().uuidString,
                    sourceID: sourceID,
                    filePath: url.path,
                    fileBookmark: fileBookmark(for: url),
                    backupFileName: backupName,
                    originalSize: originalSize,
                    originalModified: original.contentModificationDate,
                    originalSHA256: originalSHA,
                    damagedSize: damaged?.fileSize.map(Int64.init),
                    damagedModified: damaged?.contentModificationDate,
                    createdAt: Date()
                ), in: backupDirectory)
                plog("⚠️ Rewrite in place: putting the original back failed (\(restoreError.localizedDescription)); "
                    + "backup kept name=\(backupName), will restore on next access")
                throw Failure.backupKept(detail: restoreError.localizedDescription)
            }
            throw Failure.restored(detail: error.localizedDescription)
        }
    }

    /// 从头覆盖,写完截断到新长度,再落盘。
    private static func overwrite(_ url: URL, with source: URL, length: Int64, failAfterBytes: Int64?) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.seek(toOffset: 0)
        var written: Int64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            if let limit = failAfterBytes, written + Int64(chunk.count) > limit {
                let room = Int(max(0, limit - written))
                if room > 0 { try output.write(contentsOf: chunk.prefix(room)) }
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try output.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
        try output.truncate(atOffset: UInt64(max(0, length)))
        try output.synchronize()
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    private static func fileBookmark(for url: URL) -> Data? {
        #if os(macOS)
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    // MARK: 待恢复记录

    private static func pendingURL(in directory: URL) -> URL {
        directory.appendingPathComponent("pending-restores.json")
    }

    static func pendingRestores(in directory: URL = defaultBackupDirectory) -> [PendingRestore] {
        lock.withLock { load(directory) }
    }

    private static func load(_ directory: URL) -> [PendingRestore] {
        guard let data = try? Data(contentsOf: pendingURL(in: directory)) else { return [] }
        return (try? JSONDecoder().decode([PendingRestore].self, from: data)) ?? []
    }

    private static func save(_ entries: [PendingRestore], in directory: URL) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: pendingURL(in: directory))
        } else if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: pendingURL(in: directory), options: .atomic)
        }
    }

    private static func record(_ entry: PendingRestore, in directory: URL) {
        lock.withLock {
            var entries = load(directory)
            entries.append(entry)
            save(entries, in: directory)
        }
    }

    /// 放回上次没放回的原文件。文件在那之后又被别处换过,说明已经有了新的完整版本:不覆盖它,备份删掉。
    /// 找不到文件(卷没挂上、权限还没恢复)就留着下次再试。返回放回了几个。
    @discardableResult
    static func restorePending(sourceID: String, backupDirectory: URL = defaultBackupDirectory) -> Int {
        let entries = pendingRestores(in: backupDirectory).filter { $0.sourceID == sourceID }
        guard !entries.isEmpty else { return 0 }
        var finished: Set<String> = []
        var restored = 0
        for entry in entries {
            let backup = backupDirectory.appendingPathComponent(entry.backupFileName)
            guard FileManager.default.fileExists(atPath: backup.path) else {
                finished.insert(entry.id)
                continue
            }
            let url = resolvedURL(entry)
            guard FileManager.default.fileExists(atPath: url.path) else {
                plog("Rewrite restore: file not reachable yet, keeping the backup name=\(entry.backupFileName)")
                continue
            }
            let current = try? URL(fileURLWithPath: url.path)
                .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let unchangedSinceFailure = current?.fileSize.map(Int64.init) == entry.damagedSize
                && sameDate(current?.contentModificationDate, entry.damagedModified)
            guard unchangedSinceFailure else {
                plog("Rewrite restore: file changed since the failure, keeping it and dropping the backup")
                try? FileManager.default.removeItem(at: backup)
                finished.insert(entry.id)
                continue
            }
            var restoreError: (any Error)?
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url,
                options: [],
                error: &coordinationError
            ) { target in
                do {
                    try overwrite(target, with: backup, length: entry.originalSize, failAfterBytes: nil)
                    guard try SHA256FileDigest.hexDigest(at: target) == entry.originalSHA256 else {
                        throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
                    }
                } catch {
                    restoreError = error
                }
            }
            if let coordinationError {
                plog("⚠️ Rewrite restore: coordination failed, will retry: \(coordinationError.localizedDescription)")
                continue
            }
            if let restoreError {
                plog("⚠️ Rewrite restore: putting the original back failed, will retry: \(restoreError.localizedDescription)")
                continue
            }
            try? FileManager.default.removeItem(at: backup)
            finished.insert(entry.id)
            restored += 1
            plog("Rewrite restore: original put back name=\(url.lastPathComponent)")
        }
        if !finished.isEmpty {
            lock.withLock {
                save(load(backupDirectory).filter { !finished.contains($0.id) }, in: backupDirectory)
            }
        }
        return restored
    }

    private static func resolvedURL(_ entry: PendingRestore) -> URL {
        if let data = entry.fileBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: LocalBookmarkStore.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        return URL(fileURLWithPath: entry.filePath)
    }

    private static func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < 0.001
        default: return false
        }
    }
}
