import CryptoKit
import Foundation

/// An immutable selector inside an ISO. Extents are resolved again before playback
/// so stale library metadata cannot turn into reads from a replaced image.
public struct ISOAudioTrack: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, dvdAudio }
    public var kind: Kind
    public var path: String
    public var title: Int?
    public var track: Int?
    public var format: AudioFormat
    public var byteCount: Int64
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var duration: Double?
    public var albumTitle: String?
    public var albumArtist: String?
    public var key: String { "\(kind.rawValue):\(path):\(title ?? 0):\(track ?? 0)" }

    public init(kind: Kind = .file, path: String, title: Int? = nil, track: Int? = nil,
                format: AudioFormat, byteCount: Int64, sampleRate: Int? = nil,
                bitDepth: Int? = nil, duration: Double? = nil, albumTitle: String? = nil, albumArtist: String? = nil) {
        self.kind = kind; self.path = path; self.title = title; self.track = track
        self.format = format; self.byteCount = byteCount; self.sampleRate = sampleRate
        self.bitDepth = bitDepth; self.duration = duration; self.albumTitle = albumTitle; self.albumArtist = albumArtist
    }
}

public enum ISOAudioReader {
    public typealias Read = SACDISOReader.Read

    public static func localSheet(url: URL) async throws -> CueSheet? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        return try await sheet(fileName: url.lastPathComponent, size: Int64(size)) { offset, length in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: Int(length)) ?? Data()
        }
    }

    public static func sheet(fileName: String, size: Int64, read: @escaping Read) async throws -> CueSheet? {
        var hasFileSystem = false
        if size <= 0 || size >= 17 * 2048 {
            let header = try await read(16 * 2048, 2048)
            if header.count >= 6 {
                hasFileSystem = ["CD001", "BEA01", "NSR02", "NSR03"].contains {
                    header[1..<6] == Data($0.utf8)
                }
            }
        }
        if !hasFileSystem, let sacd = try await SACDISOReader.sheet(fileName: fileName, size: size, read: read) { return sacd }
        let files: [DiscImageFileSystem.File]
        do { files = try await DiscImageFileSystem.files(size: size, read: read) }
        catch DiscImageFileSystem.Failure.unrecognized { return nil }
        let dvd = try await DVDAudioReader.tracks(files: files, read: read)
        let album = (fileName as NSString).deletingPathExtension
        if !dvd.isEmpty { return CueSheet(title: album, files: [CueFile(name: fileName, type: "DVD-AUDIO", tracks: dvd)]) }
        var tracks: [CueTrack] = []
        for file in files {
            let ext = (file.path as NSString).pathExtension.lowercased()
            guard PrimuseConstants.supportedAudioExtensions.contains(ext),
                  let format = AudioFormat.from(fileExtension: ext), format != .sacdISO,
                  ![AudioFormat.mp4, .m4v, .mov].contains(format), file.size > 0 else { continue }
            let head = try await DiscImageFileSystem.read(file, offset: 0, length: min(file.size, 256 * 1024), using: read)
            var tags = EmbeddedTagMetadataParser.parse(head: head, fileExtension: ext) ?? EmbeddedTagMetadata()
            if let id3 = ID3TextMetadataParser.parse(head) {
                tags.title = tags.title ?? id3.title
                tags.artist = tags.artist ?? id3.artist
                tags.albumTitle = tags.albumTitle ?? id3.albumTitle
                tags.albumArtist = tags.albumArtist ?? id3.albumArtist
            }
            let info = technicalInfo(head, format: format, size: file.size)
            let selector = ISOAudioTrack(path: file.path, format: format, byteCount: file.size,
                                        sampleRate: info?.sampleRate, bitDepth: info?.bitDepth, duration: info?.duration,
                                        albumTitle: tags.albumTitle, albumArtist: tags.albumArtist)
            tracks.append(CueTrack(number: tracks.count + 1, type: "AUDIO",
                                   title: tags.title ?? ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                   performer: tags.artist, startTime: 0, endTime: info?.duration, isoAudioTrack: selector))
        }
        guard !tracks.isEmpty else { return nil }
        return CueSheet(title: album, files: [CueFile(name: fileName, type: "DATA-ISO", tracks: tracks)])
    }

    public static func extract(track: ISOAudioTrack, size: Int64, to url: URL, read: @escaping Read) async throws {
        let files = try await DiscImageFileSystem.files(size: size, read: read)
        if track.kind == .dvdAudio {
            try await DVDAudioReader.extract(track: track, files: files, to: url, read: read)
            return
        }
        guard let file = files.first(where: { $0.path == track.path }), file.size == track.byteCount else {
            throw DiscImageFileSystem.Failure.missingFile
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at: url) } }
        var offset: Int64 = 0
        while offset < file.size {
            let data = try await DiscImageFileSystem.read(file, offset: offset, length: min(256 * 1024, file.size - offset), using: read)
            try output.write(contentsOf: data); offset += Int64(data.count)
        }
        try Task.checkCancellation()
        try output.synchronize()
        complete = true
    }

    private static func technicalInfo(_ data: Data, format: AudioFormat, size: Int64) -> AudioStreamHeaderInfo? {
        if format == .flac, data.count >= 42, data.prefix(4) == Data("fLaC".utf8), data[4] & 127 == 0 {
            let rate = Int(data[18]) << 12 | Int(data[19]) << 4 | Int(data[20] >> 4)
            let bits = (Int(data[20] & 1) << 4 | Int(data[21] >> 4)) + 1
            let samples = (Int64(data[21] & 15) << 32) | ((try? ISOBytes.be(data, 22, 4)) ?? 0)
            return .init(codec: .flac, sampleRate: rate, bitDepth: bits,
                         duration: rate > 0 && samples > 0 ? Double(samples) / Double(rate) : nil)
        }
        if format == .wav, data.count >= 44, data[8..<12] == Data("WAVE".utf8) {
            var cursor = 12, rate: Int?, bits: Int?, byteRate: Int64?
            while cursor + 8 <= data.count {
                guard let count = try? ISOBytes.le(data, cursor + 4, 4) else { break }
                let id = data[cursor..<(cursor + 4)]
                if id == Data("fmt ".utf8), count >= 16, cursor + 24 <= data.count {
                    rate = Int((try? ISOBytes.le(data, cursor + 12, 4)) ?? 0)
                    byteRate = try? ISOBytes.le(data, cursor + 16, 4)
                    bits = Int((try? ISOBytes.le(data, cursor + 22, 2)) ?? 0)
                }
                if id == Data("data".utf8), let byteRate, byteRate > 0 {
                    return .init(codec: .pcm, sampleRate: rate, bitDepth: bits,
                                 duration: Double(min(count, size - Int64(cursor + 8))) / Double(byteRate))
                }
                guard count <= data.count else { break }
                cursor += 8 + Int(count) + Int(count & 1)
            }
        }
        return AudioStreamHeaderParser.parse(data, container: format)
    }
}

public actor ISOAudioTrackCache {
    public static let shared = ISOAudioTrackCache()
    private nonisolated static func target(song: Song, scope: String) -> URL {
        let fields = [scope, song.sourceID, song.filePath, song.isoAudioTrack.map { $0.kind == .dvdAudio ? "dvdAudio:\($0.path):\($0.title ?? 0)" : $0.key } ?? "", song.fileFormat.rawValue,
                      String(song.fileSize), song.revision ?? "", String(song.lastModified?.timeIntervalSince1970 ?? 0)]
        let hash = SHA256.hash(data: Data(fields.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
        return CueSheetScanCache.directory(sourceID: song.sourceID).deletingLastPathComponent()
            .appendingPathComponent("iso", isDirectory: true).appendingPathComponent(hash).appendingPathExtension(song.fileFormat.rawValue)
    }
    public nonisolated static func cachedURL(song: Song, scope: String) -> URL? {
        if song.isSACDTrack { return SACDTrackCache.cachedURL(song: song, scope: scope) }
        guard song.isoAudioTrack != nil else { return nil }
        let url = target(song: song, scope: scope)
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, let size = attributes.fileSize, size > 0,
              let receipt = try? Data(contentsOf: url.appendingPathExtension("complete")),
              String(data: receipt, encoding: .utf8) == String(size) else { return nil }
        return url
    }
    public func materialize(song: Song, scope: String, read: @escaping SACDISOReader.Read) async throws -> URL {
        if song.isSACDTrack { return try await SACDTrackCache.shared.materialize(song: song, scope: scope, read: read) }
        try Task.checkCancellation()
        guard let track = song.isoAudioTrack else { throw DiscImageFileSystem.Failure.missingFile }
        if let url = Self.cachedURL(song: song, scope: scope) { return url }
        let target = Self.target(song: song, scope: scope)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await ISOAudioReader.extract(track: track, size: song.fileSize, to: staging, read: read)
        try Task.checkCancellation()
        let count = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard count > 0 else { throw DiscImageFileSystem.Failure.truncated }
        if Self.cachedURL(song: song, scope: scope) == nil {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staging, to: target)
            try Data(String(count).utf8).write(to: target.appendingPathExtension("complete"), options: .atomic)
        }
        return target
    }
}
