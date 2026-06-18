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
                    guard PrimuseConstants.supportedAudioExtensions.contains(ext) else { continue }

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

        guard metadata.duration > 0 else {
            plog("📥 LocalFileSource: skipping unreadable local audio '\(item.name)' size=\(item.size)B")
            return nil
        }

        let format = AudioFormat.from(fileExtension: (item.name as NSString).pathExtension) ?? .mp3
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
            replayGainTrackGain: metadata.replayGainTrackGain,
            replayGainTrackPeak: metadata.replayGainTrackPeak,
            replayGainAlbumGain: metadata.replayGainAlbumGain,
            replayGainAlbumPeak: metadata.replayGainAlbumPeak
        )
        return ConnectorScannedSong(song: song, displayName: item.name)
    }

    private func resolvedURL(for path: String, allowRoot: Bool) throws -> URL {
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
