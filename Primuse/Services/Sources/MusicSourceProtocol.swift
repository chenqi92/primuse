import CryptoKit
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

extension RemoteFileItem: SidecarDirectoryItem {
    var sidecarName: String { name }
    var sidecarPath: String { path }
    var sidecarIsDirectory: Bool { isDirectory }
    var sidecarSize: Int64 { size }
    var sidecarModifiedDate: Date? { modifiedDate }
    var sidecarRevision: String? { revision }
    var sidecarProviderID: String? { providerID }
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
    /// Provider-native folder topology kept separate from `Song.filePath`.
    /// Server catalogues use opaque playback paths, so interpreting those IDs
    /// as filesystem paths would either flatten the library or expose internal
    /// identifiers. These committed index rows rebuild the visible hierarchy
    /// without changing song identity or playback routing.
    let providerHierarchyItems: [SourceSyncIndexedItem]

    init(
        song: Song,
        displayName: String,
        titleMetadataInspected: Bool,
        folderLocation: ConnectorLibraryFolderLocation? = nil
    ) {
        self.song = song
        self.displayName = displayName
        self.titleMetadataInspected = titleMetadataInspected
        self.providerHierarchyItems = folderLocation.map {
            ConnectorLibraryFolderHierarchy.indexedItems(
                for: song,
                displayName: displayName,
                location: $0
            )
        } ?? []
    }
}

struct ConnectorLibraryFolderComponent: Sendable, Equatable {
    let stableID: String
    let displayName: String

    init(stableID: String, displayName: String) {
        self.stableID = stableID
        self.displayName = displayName
    }
}

struct ConnectorLibraryFolderLocation: Sendable, Equatable {
    let rootStableID: String
    let rootDisplayName: String?
    let components: [ConnectorLibraryFolderComponent]

    init(
        rootStableID: String,
        rootDisplayName: String?,
        components: [ConnectorLibraryFolderComponent]
    ) {
        self.rootStableID = rootStableID
        self.rootDisplayName = rootDisplayName
        self.components = components
    }
}

/// A provider may expose the same audio item below several selected roots or
/// virtual containers. Prefer the most specific placement and use only stable
/// identities as a tie-breaker so scan order cannot move songs between roots.
enum ConnectorProviderHierarchySelectionPolicy {
    static func prefers(
        candidate: [SourceSyncIndexedItem],
        over existing: [SourceSyncIndexedItem]
    ) -> Bool {
        let candidateDepth = folderDepth(candidate)
        let existingDepth = folderDepth(existing)
        if candidateDepth != existingDepth {
            return candidateDepth > existingDepth
        }
        let candidateIdentity = stableIdentity(candidate)
        let existingIdentity = stableIdentity(existing)
        if candidateIdentity != existingIdentity {
            return candidateIdentity < existingIdentity
        }
        return displayIdentity(candidate) < displayIdentity(existing)
    }

    private static func folderDepth(_ items: [SourceSyncIndexedItem]) -> Int {
        items.lazy.filter { $0.isDirectory && $0.parentPath != nil }.count
    }

    private static func stableIdentity(_ items: [SourceSyncIndexedItem]) -> String {
        items.map(\.stableKey).joined(separator: "\u{1F}")
    }

    private static func displayIdentity(_ items: [SourceSyncIndexedItem]) -> String {
        items.compactMap(\.displayName).joined(separator: "\u{1F}")
    }
}

/// Turns provider metadata into a credential-free hierarchy snapshot. Physical
/// paths are accepted only when they are relative to a provider-declared
/// library root; otherwise the connector's own artist/album taxonomy is used.
/// This lets every server keep its native scraping model without leaking a NAS
/// mount prefix or forcing a single Primuse filename convention onto it.
enum ConnectorLibraryFolderHierarchy {
    private struct RelativeFolderResolution {
        let matchedRootIdentity: String?
        let components: [String]
    }

    static func location(
        rootStableID: String,
        rootDisplayName: String?,
        providerFilePath: String?,
        declaredLibraryRoots: [String] = [],
        acceptsProviderRelativePath: Bool = false,
        fallbackComponents: [ConnectorLibraryFolderComponent]
    ) -> ConnectorLibraryFolderLocation {
        let pathResolution = providerFilePath.flatMap {
            relativeFolderComponents(
                filePath: $0,
                declaredLibraryRoots: declaredLibraryRoots,
                acceptsProviderRelativePath: acceptsProviderRelativePath
            )
        }
        let components: [ConnectorLibraryFolderComponent]
        if let pathResolution, !pathResolution.components.isEmpty {
            let rootIdentity = pathResolution.matchedRootIdentity ?? "provider-relative"
            components = pathResolution.components.enumerated().map { offset, name in
                ConnectorLibraryFolderComponent(
                    stableID: "\(rootIdentity):path:\(pathResolution.components.prefix(offset + 1).joined(separator: "/"))",
                    displayName: name
                )
            }
        } else {
            components = sanitizedFallbackComponents(fallbackComponents)
        }
        return ConnectorLibraryFolderLocation(
            rootStableID: rootStableID,
            rootDisplayName: safeDisplayName(rootDisplayName),
            components: components
        )
    }

    static func stableNameIdentity(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        return digest(normalized)
    }

    static func indexedItems(
        for song: Song,
        displayName: String,
        location: ConnectorLibraryFolderLocation
    ) -> [SourceSyncIndexedItem] {
        let rootPath = "server-root:\(digest(location.rootStableID))"
        var items = [
            SourceSyncIndexedItem(
                stableKey: "hierarchy-root:\(rootPath)",
                path: rootPath,
                displayName: safeDisplayName(location.rootDisplayName),
                parentPath: nil,
                isDirectory: true,
                size: 0,
                modifiedDate: nil,
                revision: nil
            ),
        ]
        var parentPath = rootPath
        var identity = location.rootStableID
        for component in location.components {
            guard let displayName = safeDisplayName(component.displayName) else { continue }
            identity += "\u{1F}\(component.stableID)"
            let folderPath = "server-folder:\(digest(identity))"
            items.append(
                SourceSyncIndexedItem(
                    stableKey: "hierarchy-folder:\(folderPath)",
                    path: folderPath,
                    displayName: displayName,
                    parentPath: parentPath,
                    isDirectory: true,
                    size: 0,
                    modifiedDate: nil,
                    revision: nil
                )
            )
            parentPath = folderPath
        }
        items.append(
            SourceSyncIndexedItem(
                stableKey: "hierarchy-song:\(song.id)",
                path: song.filePath,
                displayName: safeDisplayName(displayName),
                parentPath: parentPath,
                isDirectory: false,
                songIDs: [song.id],
                size: song.fileSize,
                modifiedDate: song.lastModified,
                revision: song.revision
            )
        )
        return items
    }

    private static func relativeFolderComponents(
        filePath: String,
        declaredLibraryRoots: [String],
        acceptsProviderRelativePath: Bool
    ) -> RelativeFolderResolution? {
        let rawPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pathPassesSafetyInspection(rawPath) else { return nil }
        let normalizedPath = normalizedSeparators(filePath)
        guard !normalizedPath.isEmpty else { return nil }

        let relativePath: String?
        let matchedRoot = declaredLibraryRoots
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(pathPassesSafetyInspection)
            .map(normalizedSeparators)
            .filter { !$0.isEmpty && isAbsolutePath($0) }
            .sorted(by: { $0.count > $1.count })
            .first(where: { isPath(normalizedPath, inside: $0) })
        let matchedRootIdentity: String?
        if let matchedRoot {
            let root = trimmedTrailingSeparators(matchedRoot)
            relativePath = String(normalizedPath.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let canonicalRoot = isWindowsAbsolutePath(root) || isUNCAbsolutePath(root)
                ? root.lowercased()
                : root
            matchedRootIdentity = "provider-root:\(digest(canonicalRoot))"
        } else if acceptsProviderRelativePath, !isAbsolutePath(normalizedPath) {
            relativePath = normalizedPath
            matchedRootIdentity = nil
        } else {
            relativePath = nil
            matchedRootIdentity = nil
        }

        guard let relativePath else { return nil }
        let rawComponents = relativePath.split(separator: "/").map(String.init)
        guard rawComponents.count > 1 else {
            return RelativeFolderResolution(
                matchedRootIdentity: matchedRootIdentity,
                components: []
            )
        }
        var folders: [String] = []
        for component in rawComponents.dropLast() {
            guard let name = safeDisplayName(component) else { return nil }
            folders.append(name)
        }
        return RelativeFolderResolution(
            matchedRootIdentity: matchedRootIdentity,
            components: folders
        )
    }

    private static func sanitizedFallbackComponents(
        _ components: [ConnectorLibraryFolderComponent]
    ) -> [ConnectorLibraryFolderComponent] {
        var result: [ConnectorLibraryFolderComponent] = []
        var seen = Set<String>()
        for component in components {
            guard let name = safeDisplayName(component.displayName),
                  !isPlaceholder(name),
                  seen.insert("\(component.stableID)\u{1F}\(name)").inserted else { continue }
            result.append(
                ConnectorLibraryFolderComponent(
                    stableID: component.stableID,
                    displayName: name
                )
            )
        }
        return result
    }

    private static func safeDisplayName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        guard value != ".",
              value != "..",
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return value
    }

    private static func pathPassesSafetyInspection(_ value: String) -> Bool {
        let inspected = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inspected.isEmpty,
              !containsPercentEncodedByte(inspected),
              !inspected.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        let separatorsNormalized = inspected.replacingOccurrences(of: "\\", with: "/")
        guard !separatorsNormalized.contains("://") else { return false }
        return !separatorsNormalized.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == "." || $0 == ".." }
    }

    private static func containsPercentEncodedByte(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 3 else { return false }
        for index in 0..<(bytes.count - 2) where bytes[index] == 0x25 {
            if isHexadecimalByte(bytes[index + 1]), isHexadecimalByte(bytes[index + 2]) {
                return true
            }
        }
        return false
    }

    private static func isHexadecimalByte(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x46).contains(value)
            || (0x61...0x66).contains(value)
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "unknown"
            || normalized == "[unknown artist]"
            || normalized == "[unknown album]"
    }

    private static func normalizedSeparators(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let hasUNCPrefix = value.hasPrefix("//")
        if hasUNCPrefix {
            value.removeFirst(2)
            while value.hasPrefix("/") { value.removeFirst() }
        }
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        return hasUNCPrefix ? "//" + value : value
    }

    private static func trimmedTrailingSeparators(_ path: String) -> String {
        var value = path
        while value.count > 1,
              value.hasSuffix("/"),
              !isWindowsVolumeRoot(value) {
            value.removeLast()
        }
        return value
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        let root = trimmedTrailingSeparators(root)
        guard !root.isEmpty else { return false }
        if root == "/" { return path.hasPrefix("/") && !isUNCAbsolutePath(path) }
        if isWindowsVolumeRoot(root) {
            return path.lowercased().hasPrefix(root.lowercased())
        }
        let isWindowsPath = isWindowsAbsolutePath(path) && isWindowsAbsolutePath(root)
        let isUNCPath = isUNCAbsolutePath(path) && isUNCAbsolutePath(root)
        let lhs = isWindowsPath || isUNCPath ? path.lowercased() : path
        let rhs = isWindowsPath || isUNCPath ? root.lowercased() : root
        return lhs == rhs || lhs.hasPrefix(rhs + "/")
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("//") { return isUNCAbsolutePath(path) }
        if path.hasPrefix("/") { return true }
        return isWindowsAbsolutePath(path)
    }

    private static func isUNCAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("//") else { return false }
        let components = path.dropFirst(2).split(separator: "/")
        return components.count >= 2
    }

    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
        let prefix = Array(path.prefix(3))
        return prefix.count == 3
            && prefix[0].isLetter
            && prefix[1] == ":"
            && prefix[2] == "/"
    }

    private static func isWindowsVolumeRoot(_ path: String) -> Bool {
        isWindowsAbsolutePath(path) && path.count == 3
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
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
    typealias DirectoryIndex = SidecarDirectoryIndex<RemoteFileItem>

    /// 统一的扫描项判定: 音频文件返回带 sidecar hints 的 item; 无同名音频的
    /// 视频文件(mp4/m4v/mov)返回 mvPath 指向自身的 item —— 上层把它当曲目
    /// yield, 建出的 Song 即独立 MV(isStandaloneMusicVideo)。其余返回 nil。
    static func scannableItem(_ item: RemoteFileItem, index: DirectoryIndex) -> RemoteFileItem? {
        guard item.isDirectory == false else { return nil }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if PrimuseConstants.supportedAudioExtensions.contains(ext)
            || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
            return decoratedAudioItem(item, index: index)
        }
        if PrimuseConstants.supportedMusicVideoExtensions.contains(ext) {
            return standaloneVideoItem(item, index: index)
        }
        return nil
    }

    /// 无同名音频的视频文件独立成曲; 有同名音频时它是那首歌的 sidecar,
    /// 返回 nil 以免同一文件既挂 mvPath 又重复成曲。
    private static func standaloneVideoItem(
        _ item: RemoteFileItem,
        index: DirectoryIndex
    ) -> RemoteFileItem? {
        let basename = (item.name as NSString).deletingPathExtension
        guard !index.containsAudioOrStream(basename: basename) else { return nil }

        let coverPath = item.sidecarHints?.coverPath
                ?? index.sameNameCover(basename: basename)?.path
                ?? index.folderCover()?.path
        let lyricsPath = item.sidecarHints?.lyricsPath
                ?? index.sameNameLyrics(basename: basename)?.path
        let hints = SidecarHints(
            coverPath: coverPath,
            lyricsPath: lyricsPath,
            mvPath: item.path,
            snapshotFingerprint: index.snapshotFingerprint(
                selectedPaths: [coverPath, lyricsPath]
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

    private static func decoratedAudioItem(
        _ item: RemoteFileItem,
        index: DirectoryIndex
    ) -> RemoteFileItem {
        guard item.isDirectory == false else { return item }

        let basename = (item.name as NSString).deletingPathExtension
        let coverPath = item.sidecarHints?.coverPath
                ?? index.sameNameCover(basename: basename)?.path
                ?? index.folderCover()?.path
        let lyricsPath = item.sidecarHints?.lyricsPath
                ?? index.sameNameLyrics(basename: basename)?.path
        let mvPath = item.sidecarHints?.mvPath
                ?? index.sameNameMusicVideo(basename: basename)?.path
        let hints = SidecarHints(
            coverPath: coverPath,
            lyricsPath: lyricsPath,
            mvPath: mvPath,
            snapshotFingerprint: index.snapshotFingerprint(
                selectedPaths: [coverPath, lyricsPath, mvPath]
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
}

enum RangeFetchPriority: Sendable {
    case userInitiated
    case background
}

struct EmbeddedMetadataWritebackResult: Sendable, Equatable {
    let fileSize: Int64
    let modifiedDate: Date?
    /// Provider-native revision after replacement. Filesystems that do not
    /// expose a durable revision token leave this nil and rely on size/mtime
    /// conflict checks plus the mandatory byte-for-byte remote readback.
    let revision: String?
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
            return String(localized: "metadata_writeback_error_unsupported")
        case .missingStrongRevision:
            return String(localized: "metadata_writeback_error_missing_revision")
        case .conflict:
            return String(localized: "metadata_writeback_error_conflict")
        case .invalidResponse:
            return String(localized: "metadata_writeback_error_invalid_state")
        case .remoteVerificationFailed:
            return String(localized: "metadata_writeback_error_remote_verification")
        }
    }
}

enum ArtworkFetchPurpose: Sendable {
    case thumbnail
    case originalAnimation
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

    /// Returns an unmodified source artwork URL when the source exposes one.
    /// A nil result deliberately falls back to `imageURL(for:)`; connectors
    /// whose thumbnail endpoint transforms images should override this.
    func originalArtworkURL(for path: String) async throws -> URL?

    /// Resolves and downloads one bounded artwork object inside the connector
    /// operation. Adaptive wrappers can therefore observe a failed image request
    /// and retry it on the alternate route instead of returning a stale LAN URL
    /// that fails later outside the router.
    func fetchArtworkData(
        for reference: String,
        maximumBytes: Int,
        purpose: ArtworkFetchPurpose
    ) async throws -> Data?

    /// Write data to a remote path. Used by sidecar file writing (cover art, lyrics).
    func writeFile(data: Data, to path: String) async throws
    func writeFile(
        data: Data,
        to path: String,
        priority: RangeFetchPriority
    ) async throws
    /// Confirms that a completed sidecar upload resolves to the exact bytes
    /// requested by the caller. Path-addressed connectors use the shared
    /// readback implementation; opaque-ID providers may verify inside
    /// `writeFile` and acknowledge that verification here.
    func verifySidecarWrite(data: Data, at path: String) async throws

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

struct RemoteDirectoryHTTPStatusError: Error, LocalizedError, Sendable {
    let service: String
    let statusCode: Int

    var errorDescription: String? {
        PMString("error.remoteDirectory.http", service, String(statusCode))
    }
}

enum RemoteDirectoryTransportErrorPolicy {
    static func isRetryable(_ error: Error) -> Bool {
        if OperationCancellationPolicy.isCancellation(error) { return false }
        if let status = error as? RemoteDirectoryHTTPStatusError {
            return CloudHTTPRetryPolicy.shouldRetry(statusCode: status.statusCode)
        }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .connectionFailed, .timeout:
                return true
            case .authenticationFailed, .credentialUnavailable, .pathNotFound, .fileNotFound:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: nsError.code)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return [
                Int(ECONNRESET), Int(EPIPE), Int(ENOTCONN), Int(ETIMEDOUT),
                Int(ENETRESET), Int(ECONNABORTED),
            ].contains(nsError.code)
        }
        return false
    }
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

    func originalArtworkURL(for path: String) async throws -> URL? { nil }

    func fetchArtworkData(
        for reference: String,
        maximumBytes: Int,
        purpose: ArtworkFetchPurpose
    ) async throws -> Data? {
        guard maximumBytes > 0 else { return nil }

        let data: Data
        let originalURL = purpose == .originalAnimation
            ? try await originalArtworkURL(for: reference)
            : nil
        let resolvedURL: URL?
        if let originalURL {
            resolvedURL = originalURL
        } else {
            resolvedURL = try await imageURL(for: reference)
        }
        if let url = resolvedURL {
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

    func verifySidecarWrite(data: Data, at path: String) async throws {
        guard !data.isEmpty else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        let readback = try await fetchRange(
            path: path,
            offset: 0,
            length: Int64(data.count),
            priority: .background
        )
        guard readback == data else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
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

struct ServerCatalogScanStatus: Sendable, Equatable {
    let isScanning: Bool
    let itemCount: Int64?
    let lastCompletedScanAt: Date?
}

enum ServerCatalogScanRequestResult: Sendable, Equatable {
    case accepted(ServerCatalogScanStatus)
    case unsupported
    case permissionDenied
}

/// Read-only server state used to decide whether an authoritative local
/// catalogue refresh is necessary. This capability never starts a server scan.
protocol ServerCatalogChangeDetectingConnector: MusicSourceConnector {
    func fetchServerCatalogScanStatus() async throws -> ServerCatalogScanStatus
}

/// Explicit, opt-in server mutation used only by Navidrome's launch refresh.
/// Unsupported implementations and non-admin accounts return a capability
/// result so local catalogue refresh can continue without surfacing a false
/// credential failure.
protocol ServerCatalogScanRequestingConnector: MusicSourceConnector {
    func requestServerCatalogScan() async throws -> ServerCatalogScanRequestResult
}

/// Resolves an OpenList `.strm` source-relative target against the connector's
/// configured WebDAV origin. Keeping this as a capability preserves the
/// behavior when WebDAV is wrapped by adaptive route selection.
protocol OpenListSTRMResolvingConnector: MusicSourceConnector {
    func openListSTRMURL(for reference: String) async throws -> URL?
    func localOpenListSTRMURL(for reference: String) async throws -> URL
    /// Downloads into a temporary file while enforcing `maximumBytes` during
    /// transport. The caller owns and must remove or move the returned URL.
    func downloadBoundedOpenListSTRM(
        for reference: String,
        maximumBytes: Int64
    ) async throws -> URL
    func fetchOpenListSTRMMetadataRange(
        for reference: String,
        offset: Int64,
        length: Int64
    ) async throws -> Data
}

/// Lets local and mounted-file connectors compare cheap fingerprints before
/// opening media for tag or FFmpeg inspection.
protocol ExistingSongAwareScanningConnector: SongScanningConnector {
    func scanSongs(
        from path: String,
        existingSongs: [Song]
    ) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error>
}

enum PagedSongCatalogError: Error, Sendable, Equatable {
    case unavailable
    case snapshotChangedDuringPagination
}

struct PagedSongCatalogPage: Sendable {
    let songs: [ConnectorScannedSong]
    /// Includes non-audio rows that occupy the server's offset window, so
    /// duplicate/moving-page detection remains aligned with `nextOffset`.
    let itemIDs: [String]
    let nextOffset: Int?
}

/// Authoritative catalogue pages that can be staged without publishing a
/// partial source snapshot. The caller persists `resumeState` only together
/// with all songs returned through that page.
protocol ResumablePagedSongCatalogConnector: MusicSourceConnector {
    func stableSongCatalogRevision() async throws -> String?
    func songCatalogPage(from path: String, offset: Int) async throws -> PagedSongCatalogPage
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

/// Tracks provider requests across the authoritative directory reads that
/// materialize a completed snapshot diff. This phase must finish atomically;
/// the app lifecycle cancels it and the completed snapshot remains resumable.
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
    var fieldResults: [TagMetadataFieldWritebackResult] = []

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

enum ServerListeningStatsConnectorError: LocalizedError, Equatable, Sendable {
    case invalidSnapshot
    case accountAmbiguous
    case historyChangedDuringPagination

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            return String(localized: "stats_server_error_invalid_snapshot")
        case .accountAmbiguous:
            return String(localized: "stats_server_error_account_ambiguous")
        case .historyChangedDuringPagination:
            return String(localized: "stats_server_error_history_changed")
        }
    }
}

/// A read-only, fully collected listening snapshot for one authenticated server account.
/// Connectors must not return partial pages and must never merge local playback history.
protocol ServerListeningStatsConnector: MusicSourceConnector {
    func fetchServerListeningStats() async throws -> ServerListeningStatsPayload
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

/// Authoritative favorite item IDs for one media-server account. Favorites are
/// user data rather than ordinary playlists, so mutations must round-trip to
/// the server and return a refreshed snapshot before the local liked state is
/// considered confirmed.
struct ServerFavoriteSnapshot: Sendable {
    let itemIDs: [String]

    init(itemIDs: [String]) {
        self.itemIDs = itemIDs
    }
}

/// Server-side favorite annotations exposed independently from playlists.
/// Emby uses its user-item API; Navidrome/Subsonic use star/unstar with a song
/// `id`. The mutation returns a fresh authoritative snapshot so callers can
/// recover from stale UI state and verify that the server accepted the value.
protocol ServerFavoriteConnector: MusicSourceConnector {
    func fetchServerFavorites() async throws -> ServerFavoriteSnapshot
    func setServerFavorite(itemID: String, isFavorite: Bool) async throws -> ServerFavoriteSnapshot
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
enum ServerLyricsReadResult: Sendable {
    case content(String)
    case absent
    case unavailable
}

protocol ServerLyricsConnector: MusicSourceConnector {
    var serverLyricsCapabilities: ServerLyricsCapabilities { get }
    func fetchServerLyrics(for path: String) async -> String?
    func readServerLyrics(for path: String) async -> ServerLyricsReadResult
}

extension ServerLyricsConnector {
    var serverLyricsCapabilities: ServerLyricsCapabilities { .readOnlyDocument }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        if let content = await fetchServerLyrics(for: path) {
            return .content(content)
        }
        // Legacy connectors expose absence and transport errors through the
        // same optional. Keep that state conservative until they opt into the
        // three-state API.
        return .unavailable
    }
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
