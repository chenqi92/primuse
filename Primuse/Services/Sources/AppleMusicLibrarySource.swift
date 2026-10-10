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
actor AppleMusicLibrarySource: ExistingSongAwareScanningConnector {
    let sourceID: String

    private var library: ITLibrary?
    /// persistentID (hex string) → on-disk URL, populated during scan so
    /// `localURL(for:)` can answer playback resolution without reopening
    /// the whole library every time.
    private var locationCache: [String: AppleMusicLocalAsset] = [:]

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func connect() async throws {
        if library != nil { return }
        do {
            library = try ITLibrary(apiVersion: "1.1", options: .lazyLoadData)
        } catch {
            throw SourceError.connectionFailed(
                String(
                    format: String(localized: "apple_music_library_access_failed_format"),
                    error.localizedDescription
                )
            )
        }
    }

    func disconnect() async {
        library = nil
        locationCache.removeAll()
    }

    // MARK: - SongScanningConnector

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await scanSongs(from: path, existingSongs: [])
    }

    func scanSongs(
        from path: String,
        existingSongs: [Song]
    ) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        guard let library else {
            throw AppleMusicLocalAssetError.libraryUnavailable
        }
        // A retained ITLibrary snapshot otherwise keeps importing files that
        // Music.app has removed or replaced since the previous scan.
        guard library.reloadData() else { throw AppleMusicLocalAssetError.libraryUnavailable }
        let items = library.allMediaItems
        let sourceID = self.sourceID
        let existingByPath = Dictionary(
            existingSongs.filter { $0.sourceID == sourceID }.map { ($0.filePath, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        locationCache.removeAll(keepingCapacity: true)

        return AsyncThrowingStream { continuation in
            Task {
                var skipped: [AppleMusicLocalAssetError: Int] = [:]
                var retainedUnavailableCount = 0
                for item in items {
                    // Songs only — skip podcasts, audiobooks, video, voice memos, …
                    guard item.mediaKind == .kindSong else { continue }
                    let pidKey = persistentKey(item.persistentID)
                    let asset = Self.localAsset(for: item)
                    let url: URL
                    do {
                        url = try asset.validatedURL()
                    } catch let reason as AppleMusicLocalAssetError {
                        skipped[reason, default: 0] += 1
                        // An unmounted disk or a revoked permission must not
                        // erase an existing song's library and playlist identity.
                        if reason == .unavailable || reason == .unreadable,
                           let existing = existingByPath[pidKey] {
                            retainedUnavailableCount += 1
                            continuation.yield(ConnectorScannedSong(
                                song: existing,
                                displayName: existing.title,
                                titleMetadataInspected: false
                            ))
                        }
                        continue
                    } catch {
                        continue
                    }

                    self.locationCache[pidKey] = asset

                    let format = AudioFormat.from(fileExtension: url.pathExtension) ?? .m4a
                    let displayName = item.title.isEmpty ? url.lastPathComponent : item.title

                    let song = Song(
                        id: songID(sourceID: sourceID, path: pidKey),
                        title: displayName,
                        albumTitle: item.album.title,
                        artistName: item.artist?.name ?? item.album.albumArtist,
                        albumArtistName: AlbumGroupingPolicy.resolvedAlbumArtistName(
                            albumArtistName: item.album.albumArtist,
                            trackArtistName: item.artist?.name
                        ),
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
                    continuation.yield(ConnectorScannedSong(
                        song: song,
                        displayName: displayName,
                        titleMetadataInspected: false
                    ))
                }
                if !skipped.isEmpty {
                    let summary = skipped.sorted { $0.key.rawValue < $1.key.rawValue }
                        .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
                    plog("Apple Music local asset validation: \(summary) retainedUnavailable=\(retainedUnavailableCount)")
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
            if let url = try? cached.validatedURL() { return url }
            locationCache.removeValue(forKey: path)
        }
        // Cache miss (e.g. first play after relaunch, before a fresh scan).
        // Reopen the library and look up by persistent ID once.
        try await connect()
        guard let library else {
            throw AppleMusicLocalAssetError.libraryUnavailable
        }
        guard library.reloadData() else { throw AppleMusicLocalAssetError.libraryUnavailable }
        for item in library.allMediaItems where persistentKey(item.persistentID) == path {
            let asset = Self.localAsset(for: item)
            let url = try asset.validatedURL()
            locationCache[path] = asset
            return url
        }
        throw AppleMusicLocalAssetError.unavailable
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let url = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let chunkSize = 64 * 1024
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

    func streamingURL(for path: String) async throws -> URL? {
        try await localURL(for: path)
    }

    func imageURL(for path: String) async throws -> URL? { nil }

    // MARK: - Helpers

    nonisolated static func localAsset(for item: ITLibMediaItem) -> AppleMusicLocalAsset {
        AppleMusicLocalAsset(
            url: item.location,
            isSong: item.mediaKind == .kindSong,
            isFileLocation: item.locationType == .file,
            isProtected: item.isDRMProtected
        )
    }

    private nonisolated func persistentKey(_ id: NSNumber) -> String {
        String(format: "%016llx", id.uint64Value)
    }

    private nonisolated func songID(sourceID: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(sourceID):\(path)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
