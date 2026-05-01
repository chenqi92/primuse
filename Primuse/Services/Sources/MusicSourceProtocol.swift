import Foundation
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

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedDate: Date?,
        sidecarHints: SidecarHints? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.sidecarHints = sidecarHints
    }
}

struct SidecarHints: Sendable {
    let coverPath: String?
    let lyricsPath: String?
}

struct ConnectorScannedSong: Sendable {
    let song: Song
    let displayName: String
}

protocol MusicSourceConnector: Sendable {
    var sourceID: String { get }
    func connect() async throws
    func disconnect() async
    func listFiles(at path: String) async throws -> [RemoteFileItem]
    func localURL(for path: String) async throws -> URL
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error>
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error>

    /// Returns a remote HTTP(S) URL that can be streamed directly by AVFoundation.
    /// Sources that support streaming (e.g. Synology) return the URL; others return nil.
    func streamingURL(for path: String) async throws -> URL?

    /// Returns a direct HTTP(S) URL for an image file (cover art sidecar).
    /// Used by CachedArtworkView to load covers without downloading to local cache.
    func imageURL(for path: String) async throws -> URL?

    /// Write data to a remote path. Used by sidecar file writing (cover art, lyrics).
    func writeFile(data: Data, to path: String) async throws

    /// Count audio files in a directory (recursive). Default implementation uses scanAudioFiles.
    func countAudioFiles(in path: String) async throws -> Int

    /// Fetch a byte range of a remote file. Used by `MetadataBackfillService`
    /// to read just the ID3/Vorbis/moov header (typically the first 256KB)
    /// instead of downloading the whole audio file.
    /// - Parameters:
    ///   - path: Remote path identifier (same as `localURL` accepts).
    ///   - offset: Starting byte offset. Negative values mean "from the end"
    ///     (e.g. `-262144` is the last 256KB) where the connector supports it.
    ///   - length: Number of bytes to fetch.
    /// Default implementation falls back to a full download via `localURL`,
    /// which is correct but slow — cloud connectors should override.
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data
}

extension MusicSourceConnector {
    func streamingURL(for path: String) async throws -> URL? { nil }
    func imageURL(for path: String) async throws -> URL? {
        // Default: use streamingURL as fallback (works for any file)
        try await streamingURL(for: path)
    }

    func countAudioFiles(in path: String) async throws -> Int {
        var count = 0
        let stream = try await scanAudioFiles(from: path)
        for try await _ in stream { count += 1 }
        return count
    }

    func writeFile(data: Data, to path: String) async throws {
        throw SourceError.connectionFailed("This source does not support file writing")
    }

    /// Default fallback: download the whole file via `localURL` then slice.
    /// Correct but slow. Cloud connectors override this with HTTP Range.
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try await localURL(for: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let actualOffset: UInt64
        if offset < 0 {
            actualOffset = UInt64(max(0, fileSize + offset))
        } else {
            actualOffset = UInt64(offset)
        }
        try handle.seek(toOffset: actualOffset)
        return handle.readData(ofLength: Int(length))
    }
}

protocol SongScanningConnector: MusicSourceConnector {
    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error>
}
