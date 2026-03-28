import AVFoundation
import CryptoKit
import Foundation
import PrimuseKit

/// Scans a Synology NAS for audio files and extracts metadata
actor SynologyScanner {
    private let api: SynologyAPI
    private let sourceID: String
    private let tempDir: URL

    init(api: SynologyAPI, sourceID: String) {
        self.api = api
        self.sourceID = sourceID
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_scan_\(sourceID)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDir = dir
    }

    struct ScanUpdate: Sendable {
        var scannedCount: Int
        var currentFile: String
        var songs: [Song]
    }

    func scan(directories: [String]) -> AsyncThrowingStream<ScanUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var allSongs: [Song] = []
                var count = 0

                for dir in directories {
                    do {
                        try await scanDirectory(
                            path: dir, allSongs: &allSongs,
                            count: &count, continuation: continuation
                        )
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                continuation.yield(ScanUpdate(scannedCount: count, currentFile: "", songs: allSongs))
                continuation.finish()
                cleanup()
            }
        }
    }

    private func scanDirectory(
        path: String, allSongs: inout [Song], count: inout Int,
        continuation: AsyncThrowingStream<ScanUpdate, Error>.Continuation
    ) async throws {
        let items = try await api.listDirectory(path: path)

        for item in items {
            if item.isDirectory {
                try await scanDirectory(
                    path: item.path, allSongs: &allSongs,
                    count: &count, continuation: continuation
                )
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                guard PrimuseConstants.supportedAudioExtensions.contains(ext) else { continue }

                count += 1
                continuation.yield(ScanUpdate(
                    scannedCount: count, currentFile: item.name, songs: allSongs
                ))

                let song = await extractSongMetadata(item: item, ext: ext)
                allSongs.append(song)

                // Yield with updated songs every 3 files
                if count % 3 == 0 {
                    continuation.yield(ScanUpdate(
                        scannedCount: count, currentFile: item.name, songs: allSongs
                    ))
                }
            }
        }
    }

    /// Download file header and extract metadata using AVFoundation
    private func extractSongMetadata(item: SynologyAPI.FileItem, ext: String) async -> Song {
        let format = AudioFormat.from(fileExtension: ext) ?? .mp3
        let songID = generateID(sourceID: sourceID, path: item.path)
        let parentDir = (item.path as NSString).deletingLastPathComponent
        let albumFromPath = (parentDir as NSString).lastPathComponent

        // Defaults from filename
        let (parsedTitle, parsedArtist) = parseFilename((item.name as NSString).deletingPathExtension)

        var title = parsedTitle
        var artist = parsedArtist
        var album: String? = albumFromPath
        var trackNumber: Int?
        var duration: TimeInterval = 0
        var year: Int?
        var genre: String?
        var sampleRate: Int?
        var bitRate: Int?
        var bitDepth: Int?

        // Try to download file header and parse with AVFoundation
        do {
            // Download first 4MB (enough for ID3/FLAC/MP4 metadata + cover art)
            let readSize = min(Int(item.size), 4 * 1024 * 1024)
            guard readSize > 0 else {
                return makeSong(id: songID, title: title, artist: artist, album: album,
                               trackNumber: trackNumber, duration: duration, format: format,
                               path: item.path, size: item.size, year: year, genre: genre,
                               sampleRate: sampleRate, bitRate: bitRate, bitDepth: bitDepth)
            }

            let data = try await api.downloadFileHead(path: item.path, maxBytes: readSize)

            // Write to temp file for AVFoundation to read
            let tempFile = tempDir.appendingPathComponent("\(songID).\(ext)")
            try data.write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            // Parse with AVFoundation
            let asset = AVURLAsset(url: tempFile)

            // Duration
            if let dur = try? await asset.load(.duration) {
                let secs = CMTimeGetSeconds(dur)
                if secs.isFinite && secs > 0 {
                    duration = secs
                }
            }

            // If duration is 0 and we only downloaded partial, estimate from bitrate
            if duration == 0 && item.size > Int64(readSize) {
                // Will try to get from metadata
            }

            // Metadata tags
            if let items = try? await asset.load(.metadata) {
                for meta in items {
                    guard let key = meta.commonKey?.rawValue else { continue }
                    let value = try? await meta.load(.value)

                    switch key {
                    case AVMetadataKey.commonKeyTitle.rawValue:
                        if let v = value as? String, !v.isEmpty { title = v }
                    case AVMetadataKey.commonKeyArtist.rawValue:
                        if let v = value as? String, !v.isEmpty { artist = v }
                    case AVMetadataKey.commonKeyAlbumName.rawValue:
                        if let v = value as? String, !v.isEmpty { album = v }
                    default: break
                    }
                }

                // Format-specific metadata
                for meta in items {
                    guard let identifier = meta.identifier else { continue }
                    let value = try? await meta.load(.value)

                    switch identifier {
                    case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber:
                        if let s = value as? String {
                            trackNumber = Int(s.split(separator: "/").first.map(String.init) ?? "")
                        } else if let n = value as? Int { trackNumber = n }
                    case .id3MetadataYear, .id3MetadataRecordingTime:
                        if let s = value as? String { year = Int(String(s.prefix(4))) }
                    case .id3MetadataContentType:
                        genre = value as? String
                    default: break
                    }
                }
            }

            // Audio track details
            if let tracks = try? await asset.load(.tracks) {
                for track in tracks where track.mediaType == .audio {
                    if let descs = try? await track.load(.formatDescriptions) {
                        for desc in descs {
                            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                                if basic.mSampleRate > 0 { sampleRate = Int(basic.mSampleRate) }
                                if basic.mBitsPerChannel > 0 { bitDepth = Int(basic.mBitsPerChannel) }
                            }
                        }
                    }
                    if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                        bitRate = Int(rate / 1000)
                    }
                }
            }

            // Estimate duration from file size and bitrate for partial downloads
            if duration == 0, let br = bitRate, br > 0 {
                duration = Double(item.size) * 8.0 / Double(br * 1000)
            }

        } catch {
            // Metadata extraction failed, use filename-based defaults
        }

        return makeSong(id: songID, title: title, artist: artist, album: album,
                        trackNumber: trackNumber, duration: duration, format: format,
                        path: item.path, size: item.size, year: year, genre: genre,
                        sampleRate: sampleRate, bitRate: bitRate, bitDepth: bitDepth)
    }

    private func makeSong(
        id: String, title: String, artist: String?, album: String?,
        trackNumber: Int?, duration: TimeInterval, format: AudioFormat,
        path: String, size: Int64, year: Int?, genre: String?,
        sampleRate: Int?, bitRate: Int?, bitDepth: Int?
    ) -> Song {
        let artistID = artist.map { generateID(sourceID: "", path: $0.lowercased()) }
        let albumID: String? = if let a = album, let ar = artist {
            generateID(sourceID: "", path: "\(ar.lowercased()):\(a.lowercased())")
        } else { nil }

        return Song(
            id: id, title: title, albumID: albumID, artistID: artistID,
            albumTitle: album, artistName: artist,
            trackNumber: trackNumber, duration: duration,
            fileFormat: format, filePath: path, sourceID: sourceID,
            fileSize: size, bitRate: bitRate, sampleRate: sampleRate,
            bitDepth: bitDepth, genre: genre, year: year,
            dateAdded: Date()
        )
    }

    private func parseFilename(_ name: String) -> (title: String, artist: String?) {
        if let range = name.range(of: " - ") {
            let before = String(name[name.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if before.allSatisfy(\.isNumber) { return (after, nil) }
            return (after, before)
        }
        if let dot = name.range(of: ". ") {
            let before = String(name[name.startIndex..<dot.lowerBound])
            if before.allSatisfy(\.isNumber) {
                return (String(name[dot.upperBound...]).trimmingCharacters(in: .whitespaces), nil)
            }
        }
        return (name, nil)
    }

    private func generateID(sourceID: String, path: String) -> String {
        let hash = SHA256.hash(data: Data("\(sourceID):\(path)".utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
