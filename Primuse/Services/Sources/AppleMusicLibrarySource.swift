#if os(macOS)
import Foundation
import CryptoKit
import iTunesLibrary
import PrimuseKit

/// Reads songs from the user's local Apple Music / iTunes library via
/// `iTunesLibrary.framework`. macOS-only — gated by the
/// `com.apple.security.assets.music.read-only` sandbox entitlement and the
/// `NSAppleMusicUsageDescription` privacy prompt (first `connect()` call
/// triggers the system prompt; user denial surfaces as `SourceError.connectionFailed`).
///
/// Stable identity strategy: the persistent ID Apple ships in the library
/// blob is treated as our `filePath`, so a moved-on-disk track keeps the
/// same Song row across rescans. `localURL(for:)` resolves the persistent
/// ID back to a file URL through an in-actor cache populated during scan.
actor AppleMusicLibrarySource: SongScanningConnector {
    let sourceID: String

    private var library: ITLibrary?
    /// persistentID (hex string) → on-disk URL, populated during scan so
    /// `localURL(for:)` can answer playback resolution without reopening
    /// the whole library every time.
    private var locationCache: [String: URL] = [:]

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func connect() async throws {
        if library != nil { return }
        do {
            library = try ITLibrary(apiVersion: "1.1", options: .lazyLoadData)
        } catch {
            throw SourceError.connectionFailed(
                "无法访问 Apple Music 资料库：\(error.localizedDescription)"
            )
        }
    }

    func disconnect() async {
        library = nil
        locationCache.removeAll()
    }

    // MARK: - SongScanningConnector

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        guard let library else {
            throw SourceError.connectionFailed("ITLibrary unavailable")
        }
        let items = library.allMediaItems
        let sourceID = self.sourceID

        return AsyncThrowingStream { continuation in
            Task {
                var skippedDRM = 0
                for item in items {
                    // Songs only — skip podcasts, audiobooks, video, voice memos, …
                    guard item.mediaKind == .kindSong else { continue }
                    // Cloud-only / missing items report nil location; can't play them.
                    guard let url = item.location, url.isFileURL else { continue }

                    let ext = url.pathExtension.lowercased()
                    // .m4p = FairPlay-DRM 加密的 Apple Music 订阅下载,只
                    // Apple 的 Music.app 能解密。任何第三方播放器 (包括我们)
                    // 都无法解码。直接 skip,免得歌曲出现在列表里却一播
                    // 就立刻跳过让用户困惑。
                    if ext == "m4p" {
                        skippedDRM += 1
                        continue
                    }

                    let pidKey = persistentKey(item.persistentID)
                    self.locationCache[pidKey] = url

                    let format = AudioFormat.from(fileExtension: ext) ?? .m4a
                    let displayName = item.title.isEmpty ? url.lastPathComponent : item.title

                    let song = Song(
                        id: songID(sourceID: sourceID, path: pidKey),
                        title: displayName,
                        albumTitle: item.album.title,
                        artistName: item.artist?.name ?? item.album.albumArtist,
                        trackNumber: item.trackNumber > 0 ? item.trackNumber : nil,
                        discNumber: item.album.discNumber > 0 ? item.album.discNumber : nil,
                        duration: TimeInterval(item.totalTime) / 1000.0,
                        fileFormat: format,
                        filePath: pidKey,
                        sourceID: sourceID,
                        fileSize: Int64(item.fileSize),
                        bitRate: item.bitrate > 0 ? item.bitrate : nil,
                        sampleRate: item.sampleRate > 0 ? item.sampleRate : nil,
                        genre: item.genre.isEmpty ? nil : item.genre,
                        year: item.year > 0 ? item.year : nil,
                        lastModified: item.modifiedDate,
                        dateAdded: item.addedDate ?? Date()
                    )
                    continuation.yield(ConnectorScannedSong(song: song, displayName: displayName))
                }
                if skippedDRM > 0 {
                    plog("🍏 Apple Music scan: skipped \(skippedDRM) DRM-protected (.m4p) tracks — only Apple Music.app can play those.")
                }
                continuation.finish()
            }
        }
    }

    // MARK: - MusicSourceConnector

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let stream = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await scanned in stream {
                        continuation.yield(
                            RemoteFileItem(
                                name: scanned.displayName,
                                path: scanned.song.filePath,
                                isDirectory: false,
                                size: scanned.song.fileSize,
                                modifiedDate: scanned.song.lastModified
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        // ITLibrary has no folder hierarchy — the user-facing browser uses
        // the indexed library tables directly. Listing returns empty so
        // generic browsers (ConnectorDirectoryBrowserView) degrade gracefully.
        return []
    }

    func localURL(for path: String) async throws -> URL {
        if let cached = locationCache[path] {
            return cached
        }
        // Cache miss (e.g. first play after relaunch, before a fresh scan).
        // Reopen the library and look up by persistent ID once.
        try await connect()
        guard let library else {
            throw SourceError.connectionFailed("ITLibrary unavailable")
        }
        for item in library.allMediaItems where persistentKey(item.persistentID) == path {
            guard let url = item.location, url.isFileURL else {
                throw SourceError.fileNotFound(path)
            }
            locationCache[path] = url
            return url
        }
        throw SourceError.fileNotFound(path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let url = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { handle.closeFile() }
                    let chunkSize = 64 * 1024
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

    func streamingURL(for path: String) async throws -> URL? {
        try await localURL(for: path)
    }

    func imageURL(for path: String) async throws -> URL? { nil }

    // MARK: - Helpers

    private nonisolated func persistentKey(_ id: NSNumber) -> String {
        String(format: "%016llx", id.uint64Value)
    }

    private nonisolated func songID(sourceID: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(sourceID):\(path)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
