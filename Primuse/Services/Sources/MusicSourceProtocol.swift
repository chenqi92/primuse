import Foundation
import ImageIO
import PrimuseKit

struct RemoteFileItem: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
    /// Sidecar files (cover.jpg, lyrics.lrc) discovered alongside this audio
    /// item during scan. Cloud connectors populate this from the parent
    /// directory listing so we don't need a fully-downloaded localURL to
    /// detect siblings.
    let sidecarHints: SidecarHints?
    /// Provider content fingerprint — md5 / etag / content_hash / fs_id+
    /// local_mtime. Powers re-scan replacement detection when both size
    /// and mtime are unreliable (Baidu/Aliyun/Dropbox/OneDrive listFiles
    /// often return nil for `modifiedDate`, and a same-size overwrite
    /// would otherwise be missed). Connectors leave this nil when the
    /// list API doesn't expose anything stable.
    let revision: String?
    /// Stable provider item identifier when the display path can change.
    let providerID: String?
    /// Provider-native parent path or folder ID.
    let parentPath: String?

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedDate: Date?,
        sidecarHints: SidecarHints? = nil,
        revision: String? = nil,
        providerID: String? = nil,
        parentPath: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.sidecarHints = sidecarHints
        self.revision = revision
        self.providerID = providerID
        self.parentPath = parentPath
    }
}

struct SidecarHints: Sendable {
    let coverPath: String?
    let lyricsPath: String?
    let mvPath: String?
    let snapshotFingerprint: String?
    /// True when these hints were derived from a complete sibling listing.
    /// This distinguishes "the connector did not inspect sidecars" from an
    /// authoritative observation that a previously referenced sidecar vanished.
    let isAuthoritative: Bool

    init(
        coverPath: String? = nil,
        lyricsPath: String? = nil,
        mvPath: String? = nil,
        snapshotFingerprint: String? = nil,
        isAuthoritative: Bool = false
    ) {
        self.coverPath = coverPath
        self.lyricsPath = lyricsPath
        self.mvPath = mvPath
        self.snapshotFingerprint = snapshotFingerprint
        self.isAuthoritative = isAuthoritative
    }

    var isEmpty: Bool {
        coverPath == nil && lyricsPath == nil && mvPath == nil
            && snapshotFingerprint == nil && !isAuthoritative
    }
}

struct ConnectorScannedSong: Sendable {
    let song: Song
    let displayName: String
    /// True only when this exact catalog item carried a non-placeholder title.
    /// A filename/ID fallback used to build `Song.title` does not qualify: those
    /// rows still need the bounded file-header title inspection.
    let titleMetadataInspected: Bool

    init(
        song: Song,
        displayName: String,
        titleMetadataInspected: Bool
    ) {
        self.song = song
        self.displayName = displayName
        self.titleMetadataInspected = titleMetadataInspected
    }
}

/// A CUE file plus the directory listing it came from. Keeping siblings here
/// is important for cloud providers whose `RemoteFileItem.path` is an opaque
/// item ID: FILE "album.dts" can still be resolved by name without inventing
/// a path from the CUE text.
struct RemoteCueSheetItem: Sendable {
    let item: RemoteFileItem
    let siblings: [RemoteFileItem]
}

enum SidecarHintResolver {
    /// 统一的扫描项判定: 音频文件返回带 sidecar hints 的 item; 无同名音频的
    /// 视频文件(mp4/m4v/mov)返回 mvPath 指向自身的 item —— 上层把它当曲目
    /// yield, 建出的 Song 即独立 MV(isStandaloneMusicVideo)。其余返回 nil。
    static func scannableItem(_ item: RemoteFileItem, siblings: [RemoteFileItem]) -> RemoteFileItem? {
        guard item.isDirectory == false else { return nil }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if PrimuseConstants.supportedAudioExtensions.contains(ext)
            || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
            return decoratedAudioItem(item, siblings: siblings)
        }
        if PrimuseConstants.supportedMusicVideoExtensions.contains(ext) {
            return standaloneVideoItem(item, siblings: siblings)
        }
        return nil
    }

    /// 无同名音频的视频文件独立成曲; 有同名音频时它是那首歌的 sidecar,
    /// 返回 nil 以免同一文件既挂 mvPath 又重复成曲。
    static func standaloneVideoItem(_ item: RemoteFileItem, siblings: [RemoteFileItem]) -> RemoteFileItem? {
        let basename = (item.name as NSString).deletingPathExtension
        let baseLower = basename.lowercased()
        let hasSameNameAudio = siblings.contains {
            guard $0.isDirectory == false else { return false }
            let siblingExt = ($0.name as NSString).pathExtension.lowercased()
            return (PrimuseConstants.supportedAudioExtensions.contains(siblingExt)
                || PrimuseConstants.supportedStreamDescriptorExtensions.contains(siblingExt))
                && ($0.name as NSString).deletingPathExtension.lowercased() == baseLower
        }
        guard hasSameNameAudio == false else { return nil }

        let nonAudio = siblings.filter {
            guard $0.isDirectory == false else { return false }
            let siblingExt = ($0.name as NSString).pathExtension.lowercased()
            return PrimuseConstants.supportedAudioExtensions.contains(siblingExt) == false
                && PrimuseConstants.supportedStreamDescriptorExtensions.contains(siblingExt) == false
        }
        let coverPath = item.sidecarHints?.coverPath
                ?? findSameNameCover(basename: basename, in: nonAudio)
                ?? findFolderCover(in: nonAudio)
        let lyricsPath = item.sidecarHints?.lyricsPath
                ?? findSameNameLyrics(basename: basename, in: nonAudio)
        let hints = SidecarHints(
            coverPath: coverPath,
            lyricsPath: lyricsPath,
            mvPath: item.path,
            snapshotFingerprint: snapshotFingerprint(
                selectedPaths: [coverPath, lyricsPath],
                siblings: siblings
            ),
            isAuthoritative: true
        )
        return RemoteFileItem(
            name: item.name,
            path: item.path,
            isDirectory: false,
            size: item.size,
            modifiedDate: item.modifiedDate,
            sidecarHints: hints,
            revision: item.revision,
            providerID: item.providerID,
            parentPath: item.parentPath
        )
    }

    static func decoratedAudioItem(_ item: RemoteFileItem, siblings: [RemoteFileItem]) -> RemoteFileItem {
        guard item.isDirectory == false else { return item }

        let basename = (item.name as NSString).deletingPathExtension
        let nonAudio = siblings.filter {
            guard $0.isDirectory == false else { return false }
            let ext = ($0.name as NSString).pathExtension.lowercased()
            return PrimuseConstants.supportedAudioExtensions.contains(ext) == false
                && PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) == false
        }

        let coverPath = item.sidecarHints?.coverPath
                ?? findSameNameCover(basename: basename, in: nonAudio)
                ?? findFolderCover(in: nonAudio)
        let lyricsPath = item.sidecarHints?.lyricsPath
                ?? findSameNameLyrics(basename: basename, in: nonAudio)
        let mvPath = item.sidecarHints?.mvPath
                ?? findSameNameMusicVideo(basename: basename, in: nonAudio)
        let hints = SidecarHints(
            coverPath: coverPath,
            lyricsPath: lyricsPath,
            mvPath: mvPath,
            snapshotFingerprint: snapshotFingerprint(
                selectedPaths: [coverPath, lyricsPath, mvPath],
                siblings: siblings
            ),
            isAuthoritative: true
        )
        guard hints.isEmpty == false else { return item }

        return RemoteFileItem(
            name: item.name,
            path: item.path,
            isDirectory: item.isDirectory,
            size: item.size,
            modifiedDate: item.modifiedDate,
            sidecarHints: hints,
            revision: item.revision,
            providerID: item.providerID,
            parentPath: item.parentPath
        )
    }

    private static func findSameNameCover(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedCoverExtensions {
            if let match = candidates.first(where: {
                let name = ($0.name as NSString).lowercased
                return name == "\(baseLower).\(ext)" || name == "\(baseLower)-cover.\(ext)"
            }) {
                return match.path
            }
        }
        return nil
    }

    private static func findFolderCover(in candidates: [RemoteFileItem]) -> String? {
        for name in PrimuseConstants.folderCoverNames {
            for ext in PrimuseConstants.supportedCoverExtensions {
                if let match = candidates.first(where: {
                    ($0.name as NSString).lowercased == "\(name).\(ext)"
                }) {
                    return match.path
                }
            }
        }
        return nil
    }

    private static func findSameNameLyrics(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedLyricsExtensions {
            if let match = candidates.first(where: {
                ($0.name as NSString).lowercased == "\(baseLower).\(ext)"
            }) {
                return match.path
            }
        }
        return nil
    }

    private static func findSameNameMusicVideo(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedMusicVideoExtensions {
            if let match = candidates.first(where: {
                ($0.name as NSString).lowercased == "\(baseLower).\(ext)"
            }) {
                return match.path
            }
        }
        return nil
    }

    /// A CUE edit can change virtual-track boundaries without changing the
    /// audio bytes. Include every CUE sibling conservatively; a change then
    /// reconciles this directory once instead of silently retaining stale
    /// segments. Selected cover/lyrics/video items carry their provider
    /// revision so same-path replacements are visible as well.
    private static func snapshotFingerprint(
        selectedPaths: [String?],
        siblings: [RemoteFileItem]
    ) -> String? {
        var paths = Set(selectedPaths.compactMap { $0 })
        for sibling in siblings where !sibling.isDirectory {
            if (sibling.name as NSString).pathExtension.lowercased() == "cue" {
                paths.insert(sibling.path)
            }
        }
        guard !paths.isEmpty else { return nil }

        let itemsByPath = Dictionary(
            siblings.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return paths.sorted().map { path in
            guard let item = itemsByPath[path] else { return "missing\u{1F}\(path)" }
            return [
                item.providerID ?? "path:\(path.lowercased())",
                path,
                item.revision ?? "",
                String(item.size),
                item.modifiedDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }
}

enum RangeFetchPriority: Sendable {
    case userInitiated
    case background
}

struct EmbeddedMetadataWritebackResult: Sendable, Equatable {
    let fileSize: Int64
    let modifiedDate: Date?
    let revision: String
    let fileSHA256: String
    let verification: EmbeddedMetadataVerification
}

enum EmbeddedMetadataWritebackSourceError: LocalizedError, Equatable {
    case unsupported
    case missingStrongRevision
    case conflict
    case invalidResponse
    case remoteVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This source does not support embedded metadata writeback."
        case .missingStrongRevision:
            return "The WebDAV server did not provide a strong ETag, so the file cannot be replaced safely."
        case .conflict:
            return "The WebDAV file changed while it was being edited. Scan again before retrying."
        case .invalidResponse:
            return "The WebDAV server returned an invalid writeback response."
        case .remoteVerificationFailed:
            return "The file downloaded after WebDAV writeback did not match the verified upload."
        }
    }
}

protocol MusicSourceConnector: Sendable {
    var sourceID: String { get }
    var supportsSidecarWriting: Bool { get }
    func connect() async throws
    func disconnect() async
    func listFiles(at path: String) async throws -> [RemoteFileItem]
    func localURL(for path: String) async throws -> URL
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error>
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error>
    func scanCueSheets(from path: String) async throws -> AsyncThrowingStream<RemoteCueSheetItem, Error>

    /// Returns a remote HTTP(S) URL that can be streamed directly by AVFoundation.
    /// Sources that support streaming (e.g. Synology) return the URL; others return nil.
    func streamingURL(for path: String) async throws -> URL?

    /// Returns a direct HTTP(S) URL for an image file (cover art sidecar).
    /// Used by CachedArtworkView to load covers without downloading to local cache.
    func imageURL(for path: String) async throws -> URL?

    /// Resolves and downloads one bounded artwork object inside the connector
    /// operation. Adaptive wrappers can therefore observe a failed image request
    /// and retry it on the alternate route instead of returning a stale LAN URL
    /// that fails later outside the router.
    func fetchArtworkData(for reference: String, maximumBytes: Int) async throws -> Data?

    /// Write data to a remote path. Used by sidecar file writing (cover art, lyrics).
    func writeFile(data: Data, to path: String) async throws
    func writeFile(
        data: Data,
        to path: String,
        priority: RangeFetchPriority
    ) async throws

    /// Rewrites selected embedded metadata in the media object and replaces it
    /// on the source with optimistic concurrency and a post-write byte check.
    func writeEmbeddedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?
    ) async throws -> EmbeddedMetadataWritebackResult

    /// Delete a remote file. Used by song deletion to remove the source audio
    /// file and safe same-name sidecars.
    func deleteFile(at path: String) async throws

    /// Delete several remote files in one source operation. Connectors whose
    /// provider exposes a batch API override this together with
    /// `preferredDeleteBatchSize`; the default preserves the existing serial
    /// behaviour for SMB/NFS/WebDAV and other stateful filesystems.
    func deleteFiles(at paths: [String]) async throws
    var preferredDeleteBatchSize: Int { get }

    /// Count audio files in a directory (recursive). Default implementation uses scanAudioFiles.
    func countAudioFiles(in path: String) async throws -> Int

    /// Fetch a byte range of a remote file. Playback and sparse caches require
    /// the returned bytes to match the requested window exactly.
    /// - Parameters:
    ///   - path: Remote path identifier (same as `localURL` accepts).
    ///   - offset: Starting byte offset. Negative values mean "from the end"
    ///     (e.g. `-262144` is the last 256KB) where the connector supports it.
    ///   - length: Number of bytes to fetch.
    /// Default implementation falls back to a full download via `localURL`,
    /// which is correct but slow — cloud connectors should override.
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data
    func fetchRange(
        path: String,
        offset: Int64,
        length: Int64,
        priority: RangeFetchPriority
    ) async throws -> Data

    /// Fetches a bounded byte window for tag, duration, CUE, or format
    /// inspection. Playback keeps using `fetchRange`, whose response validation
    /// must remain strict enough for sparse-cache writes.
    func fetchMetadataRange(path: String, offset: Int64, length: Int64) async throws -> Data

    /// 批量预热下载链接 / 元数据。给定一组 path, connector 提前 batch 拿
    /// (并 cache) 后续 fetchRange 需要的 dlink / CDN URL / 鉴权信息。
    ///
    /// 出现意义: 百度网盘 filemetas API 单次 fsids 数组最多 100 个, batch
    /// 后单次调用能换 100 首歌的 dlink, 1w 首库下省 99% API 配额。其他
    /// connector 不需要这个 (NAS 直连 / WebDAV 都没单 path 一次的限速)。
    ///
    /// 默认实现 noop, 不强制 connector 实现。失败不抛错 ── 仅是优化, 失败
    /// 时 backfill 仍能走 single-path 慢路径。
    func prefetchMetadata(paths: [String]) async
}

struct LyricsSidecarTarget: Sendable, Equatable {
    let targetPath: String
    let fileName: String
    let exists: Bool
}

protocol LyricsSidecarTargetResolving: MusicSourceConnector {
    func lyricsSidecarTarget(for song: Song) async throws -> LyricsSidecarTarget
}

extension MusicSourceConnector {
    var supportsSidecarWriting: Bool { false }
    var preferredDeleteBatchSize: Int { 1 }

    /// 默认 noop ── 大多数 connector 不需要预热, 单次 fetchRange 自带的
    /// metadata resolve 已经够。只有受限速 / batch API 收益高的源 (百度网盘)
    /// 才 override。
    func prefetchMetadata(paths: [String]) async {}

    func streamingURL(for path: String) async throws -> URL? { nil }
    func imageURL(for path: String) async throws -> URL? {
        // Default: use streamingURL as fallback (works for any file)
        try await streamingURL(for: path)
    }

    func fetchArtworkData(for reference: String, maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0 else { return nil }

        let data: Data
        if let url = try await imageURL(for: reference) {
            if url.isFileURL {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let size = values.fileSize,
                      size > 0,
                      size <= maximumBytes else {
                    throw SourceError.connectionFailed("Artwork file is empty or too large")
                }
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let result = try await TrustedHTTPTransport.data(
                    for: request,
                    session: SourceArtworkDataTransport.session,
                    maxBytes: maximumBytes
                )
                guard let http = result.1 as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      result.0.isEmpty == false else {
                    throw SourceError.connectionFailed("Artwork request returned an invalid response")
                }
                if let mimeType = http.mimeType?.lowercased(),
                   mimeType.hasPrefix("text/")
                    || mimeType.contains("json")
                    || mimeType.contains("xml") {
                    throw SourceError.connectionFailed("Artwork endpoint returned non-image data")
                }
                data = result.0
            }
        } else {
            // SMB/NFS and opaque cloud references do not expose a direct URL.
            // Keep this byte read inside the routed operation as well, otherwise
            // successful connection setup could hide a wrong same-address NAS.
            data = try await fetchRange(
                path: reference,
                offset: 0,
                length: Int64(maximumBytes),
                priority: .background
            )
        }

        guard data.isEmpty == false,
              data.count <= maximumBytes,
              SourceArtworkDataValidator.isRecognizedImage(data) else {
            throw SourceError.connectionFailed("Artwork endpoint returned invalid image data")
        }
        return data
    }

    func countAudioFiles(in path: String) async throws -> Int {
        var count = 0
        let stream = try await scanAudioFiles(from: path)
        for try await _ in stream { count += 1 }
        return count
    }

    /// Generic recursive CUE walk built on listFiles. Media-server connectors
    /// use their own SongScanningConnector path and never invoke this; file,
    /// NAS and cloud connectors gain CUE discovery without duplicating it in
    /// every protocol implementation.
    func scanCueSheets(from path: String) async throws -> AsyncThrowingStream<RemoteCueSheetItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var pendingDirectories = [path]
                    var visited: Set<String> = []
                    while let directory = pendingDirectories.popLast() {
                        try Task.checkCancellation()
                        guard visited.insert(directory).inserted else { continue }
                        let siblings = try await listFiles(at: directory)
                        for item in siblings {
                            if item.isDirectory {
                                pendingDirectories.append(item.path)
                            } else if PrimuseConstants.supportedCueSheetExtensions.contains(
                                (item.name as NSString).pathExtension.lowercased()
                            ) {
                                continuation.yield(RemoteCueSheetItem(item: item, siblings: siblings))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func writeFile(data: Data, to path: String) async throws {
        throw SourceError.connectionFailed("This source does not support file writing")
    }

    /// Connectors without independent I/O lanes preserve their existing write
    /// behaviour. Stateful connectors such as SMB override this overload so a
    /// sidecar upload cannot queue behind playback reads on the foreground lane.
    func writeFile(
        data: Data,
        to path: String,
        priority: RangeFetchPriority
    ) async throws {
        try await writeFile(data: data, to: path)
    }

    func writeEmbeddedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?
    ) async throws -> EmbeddedMetadataWritebackResult {
        throw EmbeddedMetadataWritebackSourceError.unsupported
    }

    func deleteFile(at path: String) async throws {
        throw SourceError.connectionFailed("This source does not support file deletion")
    }

    func deleteFiles(at paths: [String]) async throws {
        for path in paths {
            try await deleteFile(at: path)
        }
    }

    /// Default fallback: download the whole file via `localURL` then slice.
    /// Correct but slow. Cloud connectors override this with HTTP Range.
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0 else { return Data() }
        let url = try await localURL(for: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let actualOffset: UInt64
        if offset < 0 {
            actualOffset = UInt64(max(0, fileSize + offset))
        } else {
            guard SafeByteRange.exclusiveEnd(offset: offset, length: length) != nil else {
                return Data()
            }
            actualOffset = UInt64(offset)
        }
        try handle.seek(toOffset: actualOffset)
        return handle.readData(ofLength: Int(length))
    }

    func fetchRange(
        path: String,
        offset: Int64,
        length: Int64,
        priority: RangeFetchPriority
    ) async throws -> Data {
        try await fetchRange(path: path, offset: offset, length: length)
    }

    func fetchMetadataRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await fetchRange(
            path: path,
            offset: offset,
            length: length,
            priority: .background
        )
    }

    /// Reads a bounded stream descriptor without ever treating the wrapper as
    /// media. A fresh connector Range read is preferred so regenerated OpenList
    /// links are not hidden behind an old whole-file download cache.
    func readSTRMDescriptor(path: String, knownSize: Int64? = nil) async throws -> STRMDescriptor {
        if let knownSize, knownSize > Int64(STRMDescriptorParser.maximumByteCount) {
            throw STRMDescriptorError.tooLarge(
                actualByteCount: Int(clamping: knownSize),
                maximumByteCount: STRMDescriptorParser.maximumByteCount
            )
        }
        let requestedLength = max(
            1,
            min(knownSize ?? Int64(STRMDescriptorParser.maximumByteCount),
                Int64(STRMDescriptorParser.maximumByteCount))
        )
        let data = try await fetchMetadataRange(path: path, offset: 0, length: requestedLength)
        return try STRMDescriptorParser.parse(data)
    }
}

private enum SourceArtworkDataTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(
            configuration: configuration,
            delegate: SmartSSLDelegate(redirectPolicy: .media),
            delegateQueue: nil
        )
    }()
}

private enum SourceArtworkDataValidator {
    static func isRecognizedImage(_ data: Data) -> Bool {
        ArtworkImageCompatibility.isCompleteImage(data)
            && !ArtworkImageCompatibility.hasRedundantJPEGSampling(data)
    }
}

protocol SongScanningConnector: MusicSourceConnector {
    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error>
}

/// Resolves an OpenList `.strm` source-relative target against the connector's
/// configured WebDAV origin. Keeping this as a capability preserves the
/// behavior when WebDAV is wrapped by adaptive route selection.
protocol OpenListSTRMResolvingConnector: MusicSourceConnector {
    func openListSTRMURL(for reference: String) async throws -> URL?
}

/// Lets local and mounted-file connectors compare cheap fingerprints before
/// opening media for tag or FFmpeg inspection.
protocol ExistingSongAwareScanningConnector: SongScanningConnector {
    func scanSongs(
        from path: String,
        existingSongs: [Song]
    ) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error>
}

struct IncrementalSourceChanges: Sendable {
    var cursors: [String: String]
    var changedParentPaths: Set<String>
    var deletedStableKeys: Set<String>
    var requiresDeepScan: Bool
    var reconciledIndex: [String: SourceSyncIndexedItem]?
    var identityAliases: [String: String]?
    var rootIdentities: [SourceSyncRootIdentity]?
    var missingStableKeys: [String: Int]?
    var reconciliation: SourceSyncReconciliation?
    var telemetry: SourceSyncTelemetry?

    init(
        cursors: [String: String],
        changedParentPaths: Set<String> = [],
        deletedStableKeys: Set<String> = [],
        requiresDeepScan: Bool = false,
        reconciledIndex: [String: SourceSyncIndexedItem]? = nil,
        identityAliases: [String: String]? = nil,
        rootIdentities: [SourceSyncRootIdentity]? = nil,
        missingStableKeys: [String: Int]? = nil,
        reconciliation: SourceSyncReconciliation? = nil,
        telemetry: SourceSyncTelemetry? = nil
    ) {
        self.cursors = cursors
        self.changedParentPaths = changedParentPaths
        self.deletedStableKeys = deletedStableKeys
        self.requiresDeepScan = requiresDeepScan
        self.reconciledIndex = reconciledIndex
        self.identityAliases = identityAliases
        self.rootIdentities = rootIdentities
        self.missingStableKeys = missingStableKeys
        self.reconciliation = reconciliation
        self.telemetry = telemetry
    }
}

/// Native provider change feed. Implementations return directory scopes to
/// reconcile; they never mutate the library or persist a cursor themselves.
protocol IncrementalMusicSourceConnector: MusicSourceConnector {
    func initialChangeCursors(for roots: [String]) async throws -> [String: String]
    func changes(
        since cursors: [String: String],
        roots: [String],
        index: [String: SourceSyncIndexedItem]
    ) async throws -> IncrementalSourceChanges
}

/// Marker for connectors whose new songs should derive their local ID from a
/// provider-stable item ID. Existing rows still win through the migration
/// index, preserving every playlist/history/cache reference.
protocol StableProviderSongIdentityConnector: MusicSourceConnector {}

struct SourceRootResolution: Sendable {
    var effectiveRoots: [String]
    var identities: [SourceSyncRootIdentity]
}

enum SourceRootResolutionError: Error, Sendable {
    case requiresReselection(String)
}

protocol PersistentRootIdentityConnector: MusicSourceConnector {
    func resolveRootIdentities(
        configuredRoots: [String],
        previous: [SourceSyncRootIdentity]
    ) async throws -> SourceRootResolution
}

enum BaiduSnapshotExecutionError: Error, Sendable {
    case budgetExhausted(BaiduSnapshotBudgetStopReason, SourceSyncTelemetry)
    case snapshotRestartRequired(SourceSyncTelemetry)
    case reconciliationRequiresDeepScan(SourceSyncTelemetry)
}

/// Snapshot traversal is resumable but remains uncommitted until the complete
/// selected tree has been listed. This is intentionally not described as a
/// native provider delta feed: Baidu does not expose one.
protocol ResumableSnapshotMusicSourceConnector: MusicSourceConnector {
    /// A format marker for the last committed complete snapshot. This is not a
    /// provider cursor and must never be used to advertise native change-feed
    /// support or schedule background periodic synchronization.
    func initialSnapshotMarker(for roots: [String]) async throws -> [String: String]
    func snapshotChanges(
        from state: SourceSyncState,
        roots: [String],
        rootIdentities: [SourceSyncRootIdentity],
        resumeState: BaiduSnapshotResumeState?,
        budget: BaiduSnapshotRefreshBudget,
        progress: @escaping @Sendable (
            BaiduSnapshotResumeState,
            SourceSyncTelemetry
        ) async -> Void
    ) async throws -> IncrementalSourceChanges
}

/// Extends the same per-execution request/directory/deadline budget across the
/// authoritative directory reads that materialize a completed snapshot diff.
/// Without this phase, a bounded tree walk could still trigger an unbounded
/// second wave of list requests.
protocol SnapshotReconciliationBudgetConnector: MusicSourceConnector {
    func beginSnapshotReconciliationBudget(
        _ budget: BaiduSnapshotRefreshBudget,
        consumed: SourceSyncTelemetry?
    ) async
    func reserveSnapshotReconciliationDirectory() async throws
    func checkSnapshotReconciliationBudget() async throws
    func finishSnapshotReconciliationBudget() async -> SourceSyncTelemetry?
}

/// A song-scanning connector whose API supplies useful metadata on every
/// scan. Existing user-enriched rows are preserved, but missing or visibly
/// corrupted server fields may be refreshed without requiring file changes.
protocol RefreshingMetadataSongConnector: SongScanningConnector {}

struct MediaServerWritebackResult: Sendable {
    var metadataWritten = false
    var coverWritten = false
    var lyricsWritten = false
    var lyricsRemoved = false
    var unsupported: [String] = []
    var errors: [String] = []

    var succeeded: Bool {
        errors.isEmpty
    }
}

/// Native metadata writeback for media-server libraries. This is separate
/// from sidecar file writing because Jellyfin/Emby/Plex expose item APIs and
/// opaque IDs rather than writable source-directory paths.
protocol MediaServerWritebackConnector: MusicSourceConnector {
    func writeScrapedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String?
    ) async -> MediaServerWritebackResult

    func removeLyrics(for song: Song) async -> MediaServerWritebackResult
}

/// 服务端曲库源(Subsonic / Navidrome 等)向服务器回报播放的能力。
/// Navidrome 不把单纯的 stream 视为一次播放, 必须显式 scrobble 才会更新
/// 播放次数 / "最近播放" / 转发到服务端配置的 Last.fm·ListenBrainz。
/// - submission == false → "正在播放" (now playing, 不计入历史)
/// - submission == true  → "已播放" (计入播放次数 / 历史)
/// 失败不抛错 —— 回报是尽力而为, 失败不该影响播放。
protocol ServerScrobblingConnector: MusicSourceConnector {
    func scrobble(songPath: String, submission: Bool) async
}

/// 服务端上的一份用户歌单。`trackIDs` 是**服务端原生 item ID**(Subsonic 的
/// child id / Jellyfin 的 item id), 不是 Primuse 的 `Song.id` —— connector 不
/// 认识本地曲库, 由 `ServerPlaylistSyncService` 通过
/// `ServerPlaylistIdentity.serverItemID(fromFilePath:)` 建索引换算。
struct ServerPlaylist: Sendable {
    /// 服务端歌单 ID, 用来派生稳定的本地镜像歌单 ID。
    let id: String
    let name: String
    /// Source-owned playlist image reference. It remains source-relative or
    /// connector-rewritable so credentials and routes can be refreshed later.
    let coverArtReference: String?
    /// 服务端返回的曲目顺序, 保持原样。
    let trackIDs: [String]
    /// 服务端自报的曲目数(Subsonic `songCount`)。与 `trackIDs.count` 不一致
    /// 说明响应被截断; 用来区分"服务端歌单真的空了"和"这次没取到曲目",
    /// 后者不能清空已有镜像。
    let reportedTrackCount: Int?

    init(
        id: String,
        name: String,
        coverArtReference: String? = nil,
        trackIDs: [String],
        reportedTrackCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.coverArtReference = coverArtReference
        self.trackIDs = trackIDs
        self.reportedTrackCount = reportedTrackCount
    }
}

/// 一次服务端歌单同步所见到的完整快照。
///
/// `failedPlaylistIDs` 是已经出现在服务端歌单列表中、但本次无法完整取得曲目
/// 明细的歌单。调用方必须保留这些 ID 对应的现有本地镜像；只有既不在
/// `playlists`、也不在 `failedPlaylistIDs` 中的镜像，才可以视为已从服务端删除。
struct ServerPlaylistSnapshot: Sendable {
    let playlists: [ServerPlaylist]
    let failedPlaylistIDs: Set<String>

    init(playlists: [ServerPlaylist], failedPlaylistIDs: Set<String> = []) {
        self.playlists = playlists
        self.failedPlaylistIDs = failedPlaylistIDs
    }
}

/// 服务端曲库源暴露用户歌单的能力 (Subsonic getPlaylists/getPlaylist,
/// Jellyfin/Emby/Plex 的 playlist item API)。
///
/// 只读: Primuse 侧的编辑不回写服务端, 镜像歌单在下次扫描时被服务端内容覆盖。
protocol ServerPlaylistConnector: MusicSourceConnector {
    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot
}

/// One radio station exposed by a server library. `streamURL` is used for
/// credential-free internet-radio URLs. `sourcePlaybackPath` is used when the
/// connector must mint an authenticated URL at playback time (Jellyfin/Emby
/// Live TV); at least one of the two must be present.
struct ServerRadioStation: Sendable {
    let id: String
    let name: String
    let streamURL: String?
    let homepageURL: String?
    let coverArtReference: String?
    let sourcePlaybackPath: String?
    let streamFormat: RadioStreamFormat
    let bitRate: Int?

    init(
        id: String,
        name: String,
        streamURL: String? = nil,
        homepageURL: String? = nil,
        coverArtReference: String? = nil,
        sourcePlaybackPath: String? = nil,
        streamFormat: RadioStreamFormat = .automatic,
        bitRate: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homepageURL = homepageURL
        self.coverArtReference = coverArtReference
        self.sourcePlaybackPath = sourcePlaybackPath
        self.streamFormat = streamFormat
        self.bitRate = bitRate
    }
}

/// `nil` from the connector means the server does not implement a compatible
/// radio API. An empty non-nil snapshot is authoritative and removes stale
/// mirrors for that source.
struct ServerRadioStationSnapshot: Sendable {
    let stations: [ServerRadioStation]
    let failedStationIDs: Set<String>

    init(stations: [ServerRadioStation], failedStationIDs: Set<String> = []) {
        self.stations = stations
        self.failedStationIDs = failedStationIDs
    }
}

protocol ServerRadioConnector: MusicSourceConnector {
    func fetchServerRadioStations() async throws -> ServerRadioStationSnapshot?
}

/// Authenticated radio streams are resolved at the last possible moment so a
/// token or route-specific session URL never enters local/CloudKit snapshots.
protocol ServerRadioStreamResolvingConnector: MusicSourceConnector {
    func resolveServerRadioStream(stationID: String, forceRefresh: Bool) async throws -> URL
}

struct ServerLyricsCapabilities: Equatable, Sendable {
    let canRead: Bool
    let canWrite: Bool
    let canDelete: Bool
    /// `Song.filePath` 能否被当作真实文件路径并据此查找同目录 sidecar。
    let supportsSiblingSidecarLookup: Bool

    static let readOnlyDocument = ServerLyricsCapabilities(
        canRead: true,
        canWrite: false,
        canDelete: false,
        supportsSiblingSidecarLookup: false
    )

    static let unavailable = ServerLyricsCapabilities(
        canRead: false,
        canWrite: false,
        canDelete: false,
        supportsSiblingSidecarLookup: false
    )
}

/// 服务端直接提供歌词的能力 (Subsonic getLyricsBySongId / getLyrics，或
/// Emby 的文本字幕流)。返回 LRC 文本(带 `[mm:ss.xx]` 时间轴)或纯文本
/// (无时间轴), 交由 `LyricsParser` 统一解析; 没有歌词时返回 nil。
protocol ServerLyricsConnector: MusicSourceConnector {
    var serverLyricsCapabilities: ServerLyricsCapabilities { get }
    func fetchServerLyrics(for path: String) async -> String?
}

extension ServerLyricsConnector {
    var serverLyricsCapabilities: ServerLyricsCapabilities { .readOnlyDocument }
}

/// Implemented by connectors whose `Song.filePath` is an opaque provider
/// identifier rather than a human-readable path. Scraping can ask for the
/// real upstream filename when old rows have already persisted the opaque id
/// as `Song.title`.
protocol RemoteFileDisplayNameProviding: MusicSourceConnector {
    func displayName(for path: String) async throws -> String?
}

/// Implemented by cloud connectors whose identity is rooted in an OAuth
/// account (Baidu / Aliyun / Dropbox / OneDrive / Google Drive). Lets the
/// upper layer ask "which user does this token belong to" so multiple
/// MusicMount instances pointing at the same upstream account can be
/// coalesced under a single CloudAccount entity.
///
/// Local / NAS connectors (Synology, SMB, WebDAV, FTP, SFTP, NFS, S3,
/// MediaServer, UPnP) do NOT adopt this protocol — their identity is
/// already tied to host/credentials, no extra dedup hop needed.
protocol OAuthCloudSource: MusicSourceConnector {
    /// Stable account identifier issued by the OAuth provider. MUST be
    /// the same value across token refresh and across devices logged
    /// into the same account. Each connector documents which provider
    /// field it returns:
    /// - Baidu Pan: `uk` (from xpan/nas?method=uinfo)
    /// - Aliyun Drive: `id` (from oauth/users/info, OIDC sub)
    /// - Dropbox: `account_id` (from users/get_current_account)
    /// - OneDrive: `id` (from Microsoft Graph /me)
    /// - Google Drive: `sub` (from oauth2/v3/userinfo)
    func accountIdentifier() async throws -> String
}
