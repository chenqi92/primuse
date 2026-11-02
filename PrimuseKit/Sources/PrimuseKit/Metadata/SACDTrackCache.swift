import CryptoKit
import Foundation

/// Extracted tracks live with the source's other disposable files, so source removal and storage cleanup own them.
public actor SACDTrackCache {
    public static let shared = SACDTrackCache()

    public nonisolated static func cachedURL(song: Song) -> URL? {
        let url = targetURL(song: song)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated static func targetURL(song: Song) -> URL {
        let identity = [song.sourceID, song.filePath, String(song.sacdTrackNumber ?? 0), String(song.fileSize),
                        song.revision ?? "", String(song.lastModified?.timeIntervalSince1970 ?? 0)]
            .joined(separator: "\u{0}")
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = CueSheetScanCache.directory(sourceID: song.sourceID)
            .deletingLastPathComponent().appendingPathComponent("sacd", isDirectory: true)
        return directory.appendingPathComponent(name).appendingPathExtension("dff")
    }

    public func materialize(song: Song, read: SACDISOReader.Read) async throws -> URL {
        guard song.isSACDTrack, let number = song.sacdTrackNumber else { throw SACDISOReader.Failure.missingTrack }
        let target = Self.targetURL(song: song)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        let disc = try await SACDISOReader.open(size: song.fileSize, read: read)
        try await SACDISOReader.extract(disc: disc, trackNumber: number, to: staging, read: read)
        try Task.checkCancellation()
        // Concurrent callers may finish the same immutable version while this call awaits Range reads.
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: staging, to: target)
        }
        return target
    }
}
