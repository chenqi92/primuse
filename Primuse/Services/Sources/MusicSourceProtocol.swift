import Foundation
import PrimuseKit

struct RemoteFileItem: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
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
}

protocol SongScanningConnector: MusicSourceConnector {
    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error>
}
