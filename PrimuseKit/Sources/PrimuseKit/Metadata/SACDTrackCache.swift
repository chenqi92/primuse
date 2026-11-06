import CryptoKit
import Foundation

/// Extracted tracks live with the source's other disposable files, so source removal and storage cleanup own them.
public actor SACDTrackCache {
    public static let shared = SACDTrackCache()

    public nonisolated static func cachedURL(song: Song, scope: String) -> URL? {
        guard song.isSACDTrack else { return nil }
        let url = targetURL(song: song, scope: scope)
        return isCompleteFile(at: url) ? url : nil
    }

    private nonisolated static func targetURL(song: Song, scope: String) -> URL {
        let identity = ["2", scope, song.sourceID, song.filePath, String(song.sacdTrackNumber ?? 0), String(song.fileSize),
                        song.revision ?? "", String(song.lastModified?.timeIntervalSince1970 ?? 0)]
            .joined(separator: "\u{0}")
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = CueSheetScanCache.directory(sourceID: song.sourceID)
            .deletingLastPathComponent().appendingPathComponent("sacd", isDirectory: true)
        return directory.appendingPathComponent(name).appendingPathExtension("dff")
    }

    private nonisolated static func isCompleteFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 16,
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 16), header.count == 16,
              header.prefix(4) == Data("FRM8".utf8), header.suffix(4) == Data("DSD ".utf8) else { return false }
        let declaredSize = header[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return declaredSize == UInt64(size - 12)
    }

    public func materialize(song: Song, scope: String, read: SACDISOReader.Read) async throws -> URL {
        try Task.checkCancellation()
        guard song.isSACDTrack, let number = song.sacdTrackNumber else { throw SACDISOReader.Failure.missingTrack }
        let target = Self.targetURL(song: song, scope: scope)
        if let cached = Self.cachedURL(song: song, scope: scope) { return cached }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        let disc = try await SACDISOReader.open(size: song.fileSize, read: read)
        try await SACDISOReader.extract(disc: disc, trackNumber: number, to: staging, read: read)
        try Task.checkCancellation()
        // Concurrent callers may finish the same immutable version while this call awaits Range reads.
        if !Self.isCompleteFile(at: target) {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staging, to: target)
        }
        return target
    }
}
