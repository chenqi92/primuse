import CryptoKit
import Foundation
import PrimuseKit

actor LocalFileSource: SongScanningConnector {
    let sourceID: String
    private let basePath: URL
    private let metadataService = MetadataService()
    private static let minimumReadableAudioBytes: Int64 = 1024
    /// macOS sandbox requires holding the security scope across the lifetime
    /// of the connector — the URL we resolved from the stored bookmark
    /// stops being readable the moment we release it.
    private let usesSecurityScope: Bool

    init(sourceID: String, basePath: URL) {
        self.sourceID = sourceID
        #if os(macOS)
        if let resolved = LocalBookmarkStore.resolve(sourceID: sourceID) {
            self.basePath = resolved
            self.usesSecurityScope = resolved.startAccessingSecurityScopedResource()
        } else {
            self.basePath = basePath
            self.usesSecurityScope = false
        }
        #elseif os(iOS)
        // 本地导入源的文件固定在 <当前沙箱>/Documents/LocalMusic。app 数据容器 UUID
        // 会随重装变化, 而持久化到源记录(并经 CloudKit 同步)的绝对 basePath 可能指向
        // 已不存在的旧容器, 导致 connect()/路径解析 pathNotFound、歌曲无法播放。对本地
        // 导入源始终按当前容器重算, 不信任存储的 basePath。
        // The normal Files-import source is identified by both its persisted
        // ID and its reserved Documents/LocalMusic root. Older/demo fixtures
        // may reuse the stored ID for a different local directory; forcing
        // those onto LocalMusic makes an otherwise valid source unreachable.
        let isManagedLocalImport = sourceID == LocalImportService.existingSourceID
            && (basePath.lastPathComponent == "LocalMusic"
                || basePath.path.contains("/Documents/LocalMusic"))
        if isManagedLocalImport {
            self.basePath = LocalImportService.musicDirectory
        } else if let rebased = PrimuseSandboxPathResolver.existingURL(
            forStoredAbsolutePath: basePath.path
        ) {
            self.basePath = rebased
        } else {
            self.basePath = basePath
        }
        self.usesSecurityScope = false
        #else
        self.basePath = basePath
        self.usesSecurityScope = false
        #endif
    }

    deinit {
        if usesSecurityScope {
            basePath.stopAccessingSecurityScopedResource()
        }
    }

    func connect() async throws {
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            throw SourceError.pathNotFound(basePath.path)
        }
    }

    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let directoryURL = try resolvedURL(for: path, allowRoot: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        )

        return try contents.map { url in
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return RemoteFileItem(
                name: url.lastPathComponent,
                path: relativePath(for: url),
                isDirectory: resourceValues.isDirectory ?? false,
                size: Int64(resourceValues.fileSize ?? 0),
                modifiedDate: resourceValues.contentModificationDate
            )
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func localURL(for path: String) async throws -> URL {
        let fileURL = try resolvedURL(for: path, allowRoot: true)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SourceError.fileNotFound(path)
        }
        return fileURL
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
        let startURL = try resolvedURL(for: path, allowRoot: true)
        return AsyncThrowingStream { continuation in
            Task {
                let enumerator = FileManager.default.enumerator(
                    at: startURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                while let url = enumerator?.nextObject() as? URL {
                    let ext = url.pathExtension.lowercased()
                    let isAudio = PrimuseConstants.supportedAudioExtensions.contains(ext)
                    // 独立 MV: 无同名音频的视频文件也成曲目; 有同名音频时
                    // 视频是那首歌的 sidecar, 不独立成曲。
                    let isStandaloneVideo = !isAudio
                        && PrimuseConstants.supportedMusicVideoExtensions.contains(ext)
                        && Self.hasSameNameAudioSibling(url) == false
                    guard isAudio || isStandaloneVideo else { continue }

                    // 扫描期间单个文件可能被删除/移动,或为 iCloud dataless
                    // 文件而无法读取属性 ── 跳过该文件继续枚举,不要让 resourceValues
                    // 抛错使 Task 提前结束 (那样 continuation 既不 finish 也不
                    // finish(throwing:),消费端 for-try-await 会永久挂起)。
                    guard let resourceValues = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey]
                    ) else { continue }

                    let item = RemoteFileItem(
                        name: url.lastPathComponent,
                        path: self.relativePath(for: url),
                        isDirectory: false,
                        size: Int64(resourceValues.fileSize ?? 0),
                        modifiedDate: resourceValues.contentModificationDate
                    )
                    continuation.yield(item)
                }
                continuation.finish()
            }
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        let files = try await scanAudioFiles(from: path)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await item in files {
                        try Task.checkCancellation()
                        if let scanned = try await self.buildScannedSong(from: item) {
                            continuation.yield(scanned)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func buildScannedSong(from item: RemoteFileItem) async throws -> ConnectorScannedSong? {
        guard item.size >= Self.minimumReadableAudioBytes else {
            plog("📥 LocalFileSource: skipping tiny local audio '\(item.name)' size=\(item.size)B")
            return nil
        }

        let fileURL = try await localURL(for: item.path)
        let songID = Self.generateID(sourceID: sourceID, path: item.path)
        let originalBaseName = ((item.name as NSString).lastPathComponent as NSString).deletingPathExtension
        let metadata = await metadataService.loadMetadata(
            for: fileURL,
            cacheKey: songID,
            allowOnlineFetch: false,
            fallbackTitle: originalBaseName
        )

        // 独立 MV 允许 duration=0(播放时 AVPlayer 回填), 音频解析不出时长
        // 才按不可读跳过。
        let ext = (item.name as NSString).pathExtension
        let isStandaloneVideo = PrimuseConstants.supportedMusicVideoExtensions.contains(ext.lowercased())
        guard isStandaloneVideo || metadata.duration > 0 else {
            plog("📥 LocalFileSource: skipping unreadable local audio '\(item.name)' size=\(item.size)B")
            return nil
        }

        let format = AudioFormat.from(fileExtension: ext) ?? .mp3
        let song = Song(
            id: songID,
            title: metadata.title,
            albumTitle: metadata.albumTitle,
            artistName: metadata.artist,
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
            coverArtFileName: metadata.coverArtFileName,
            lyricsFileName: metadata.lyricsFileName,
            mvPath: isStandaloneVideo
                ? item.path
                : sidecarPath(nextTo: item.path, named: metadata.mvPath),
            replayGainTrackGain: metadata.replayGainTrackGain,
            replayGainTrackPeak: metadata.replayGainTrackPeak,
            replayGainAlbumGain: metadata.replayGainAlbumGain,
            replayGainAlbumPeak: metadata.replayGainAlbumPeak
        )
        return ConnectorScannedSong(song: song, displayName: item.name)
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

    private func resolvedURL(for path: String, allowRoot: Bool) throws -> URL {
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

    private func relativePath(for url: URL) -> String {
        let base = basePath.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return "/" + url.lastPathComponent }
        let suffix = path.dropFirst(base.count)
        return suffix.hasPrefix("/") ? String(suffix) : "/" + suffix
    }

    private nonisolated static func generateID(sourceID: String, path: String) -> String {
        let input = "\(sourceID):\(path)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum SourceError: Error, LocalizedError {
    case pathNotFound(String)
    case fileNotFound(String)
    case connectionFailed(String)
    case authenticationFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path): return "Path not found: \(path)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .timeout: return "Connection timed out"
        }
    }
}
