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
        var totalCount: Int
        var currentFile: String
        var songs: [Song]
    }

    func scan(
        directories: [String],
        existingSongs: [Song] = [],
        startingCount: Int = 0
    ) -> AsyncThrowingStream<ScanUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Remove redundant child directories when a parent is already selected
                let dirs = Self.deduplicateDirectories(directories)

                // Phase 1: Count total audio files
                var totalCount = 0
                for dir in dirs {
                    totalCount += await countAudioFiles(in: dir)
                }

                // Phase 2: Scan and extract metadata
                var allSongs = existingSongs
                let existingPaths = Set(existingSongs.map(\.filePath))
                let initialCount = max(existingSongs.count, startingCount)
                var count = totalCount > 0 ? min(initialCount, totalCount) : initialCount
                var encounteredPaths: Set<String> = []
                var hadDirectoryFailure = false

                if !existingSongs.isEmpty {
                    continuation.yield(
                        ScanUpdate(scannedCount: count, totalCount: totalCount, currentFile: "", songs: allSongs)
                    )
                }

                for dir in dirs {
                    do {
                        try await scanDirectory(
                            path: dir, allSongs: &allSongs,
                            count: &count, totalCount: totalCount,
                            existingPaths: existingPaths,
                            encounteredPaths: &encounteredPaths,
                            continuation: continuation
                        )
                    } catch {
                        hadDirectoryFailure = true
                        // Log error but continue scanning remaining directories
                        NSLog("⚠️ Failed to scan directory \(dir): \(error.localizedDescription)")
                        continue
                    }
                }

                if !hadDirectoryFailure {
                    allSongs.removeAll { encounteredPaths.contains($0.filePath) == false }
                    count = allSongs.count
                }

                continuation.yield(ScanUpdate(scannedCount: count, totalCount: totalCount, currentFile: "", songs: allSongs))
                continuation.finish()
                cleanup()
            }
        }
    }

    /// Recursively count audio files without downloading metadata
    private func countAudioFiles(in path: String) async -> Int {
        guard let items = try? await api.listDirectory(path: path) else { return 0 }
        var count = 0
        for item in items {
            if item.isDirectory {
                count += await countAudioFiles(in: item.path)
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                    count += 1
                }
            }
        }
        return count
    }

    private func scanDirectory(
        path: String, allSongs: inout [Song], count: inout Int,
        totalCount: Int,
        existingPaths: Set<String>,
        encounteredPaths: inout Set<String>,
        continuation: AsyncThrowingStream<ScanUpdate, Error>.Continuation
    ) async throws {
        let items = try await api.listDirectory(path: path)

        // Build a set of filenames for sidecar detection
        let allNames = Set(items.map(\.name))
        let coverNames = PrimuseConstants.folderCoverNames  // cover.jpg, folder.jpg, etc.

        // Detect folder-level cover sidecar (e.g., cover.jpg in this directory)
        let coverExts = ["jpg", "jpeg", "png", "webp"]
        var folderCoverPath: String?
        outer: for name in coverNames {
            for ext in coverExts {
                let fileName = "\(name).\(ext)"
                if allNames.contains(fileName) {
                    folderCoverPath = (path as NSString).appendingPathComponent(fileName)
                    break outer
                }
            }
        }

        for item in items {
            if item.isDirectory {
                try await scanDirectory(
                    path: item.path, allSongs: &allSongs,
                    count: &count, totalCount: totalCount,
                    existingPaths: existingPaths,
                    encounteredPaths: &encounteredPaths,
                    continuation: continuation
                )
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                guard PrimuseConstants.supportedAudioExtensions.contains(ext) else { continue }
                encounteredPaths.insert(item.path)
                guard existingPaths.contains(item.path) == false else { continue }

                // Detect sidecar files by name (no download needed)
                let baseName = (item.name as NSString).deletingPathExtension
                let parentDir = (item.path as NSString).deletingLastPathComponent

                // Lyrics sidecar: song.lrc
                let lrcName = baseName + ".lrc"
                let hasLrc = allNames.contains(lrcName) || allNames.contains(baseName + ".LRC")
                let lyricsRef = hasLrc ? (parentDir as NSString).appendingPathComponent(lrcName) : nil

                // Cover sidecar: song.jpg → song-cover.jpg → folder-level cover.jpg
                var coverRef: String?
                for coverExt in ["jpg", "jpeg", "png", "webp"] {
                    // Priority 1: same-name (song.jpg)
                    let songCover = baseName + ".\(coverExt)"
                    if allNames.contains(songCover) {
                        coverRef = (parentDir as NSString).appendingPathComponent(songCover)
                        break
                    }
                    // Priority 2: name-cover pattern (song-cover.jpg)
                    let nameCover = baseName + "-cover.\(coverExt)"
                    if allNames.contains(nameCover) {
                        coverRef = (parentDir as NSString).appendingPathComponent(nameCover)
                        break
                    }
                }
                if coverRef == nil { coverRef = folderCoverPath }

                count += 1
                continuation.yield(ScanUpdate(
                    scannedCount: count, totalCount: totalCount, currentFile: item.name, songs: allSongs
                ))

                var song = await extractSongMetadata(item: item, ext: ext)

                // Priority: sidecar path > embedded/cached > nil
                song = Song(
                    id: song.id, title: song.title, albumID: song.albumID, artistID: song.artistID,
                    albumTitle: song.albumTitle, artistName: song.artistName,
                    trackNumber: song.trackNumber, discNumber: song.discNumber,
                    duration: song.duration, fileFormat: song.fileFormat,
                    filePath: song.filePath, sourceID: song.sourceID,
                    fileSize: song.fileSize, bitRate: song.bitRate,
                    sampleRate: song.sampleRate, bitDepth: song.bitDepth,
                    genre: song.genre, year: song.year,
                    dateAdded: song.dateAdded,
                    coverArtFileName: coverRef ?? song.coverArtFileName,
                    lyricsFileName: lyricsRef ?? song.lyricsFileName
                )

                allSongs.append(song)

                // Yield with updated songs every 3 files
                if count % 3 == 0 {
                    continuation.yield(ScanUpdate(
                        scannedCount: count, totalCount: totalCount, currentFile: item.name, songs: allSongs
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

        // Title always comes from filename (more reliable than embedded metadata)
        let fileBaseName = (item.name as NSString).deletingPathExtension
        let (_, parsedArtist) = parseFilename(fileBaseName)

        // Don't use generic folder names as album title
        let genericFolders: Set<String> = ["music", "音乐", "Music", "songs", "Songs", "audio", "Audio", "media", "Media", "downloads", "Downloads"]

        let title = fileBaseName
        var artist = parsedArtist
        var album: String? = genericFolders.contains(albumFromPath) ? nil : albumFromPath
        var trackNumber: Int?
        var duration: TimeInterval = 0
        var year: Int?
        var genre: String?
        var sampleRate: Int?
        var bitRate: Int?
        var bitDepth: Int?
        var coverArtFileName: String?
        var lyricsFileName: String?
        var embeddedCoverData: Data?
        var embeddedLyricsText: String?

        // Try to download file header and parse with AVFoundation
        do {
            // Download first 4MB (enough for ID3/FLAC/MP4 metadata + cover art)
            let readSize = min(Int(item.size), 4 * 1024 * 1024)
            guard readSize > 0 else {
                return makeSong(id: songID, title: title, artist: artist, album: album,
                               trackNumber: trackNumber, duration: duration, format: format,
                               path: item.path, size: item.size, year: year, genre: genre,
                               sampleRate: sampleRate, bitRate: bitRate, bitDepth: bitDepth,
                               coverArtFileName: nil)
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

            // Metadata tags
            if let items = try? await asset.load(.metadata) {
                NSLog("📋 Metadata items count: \(items.count) for \(item.name), keys: \(items.compactMap { $0.commonKey?.rawValue })")
                for meta in items {
                    guard let key = meta.commonKey?.rawValue else { continue }
                    let value = try? await meta.load(.value)

                    switch key {
                    case AVMetadataKey.commonKeyTitle.rawValue:
                        break // Title always from filename
                    case AVMetadataKey.commonKeyArtist.rawValue:
                        if let v = value as? String, !v.isEmpty { artist = v }
                    case AVMetadataKey.commonKeyAlbumName.rawValue:
                        if let v = value as? String, !v.isEmpty { album = v }
                    case AVMetadataKey.commonKeyArtwork.rawValue:
                        if let data = value as? Data {
                            embeddedCoverData = data
                            NSLog("🎨 Embedded cover art found: \(data.count) bytes for \(item.name)")
                        } else {
                            NSLog("🎨 Artwork key exists but value is not Data: \(type(of: value as Any)) for \(item.name)")
                        }
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
                    case .id3MetadataUnsynchronizedLyric:
                        if let text = value as? String, !text.isEmpty {
                            embeddedLyricsText = text
                            NSLog("📝 Embedded USLT lyrics found: \(text.prefix(50))... for \(item.name)")
                        }
                    case .iTunesMetadataLyrics:
                        if let text = value as? String, !text.isEmpty, embeddedLyricsText == nil {
                            embeddedLyricsText = text
                            NSLog("📝 Embedded iTunes lyrics found: \(text.prefix(50))... for \(item.name)")
                        }
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

            // Estimate duration from file size and bitrate
            if duration == 0, let br = bitRate, br > 0 {
                duration = Double(item.size) * 8.0 / Double(br * 1000)
            }

            // Last resort: estimate from file size assuming common bitrate
            if duration == 0 && item.size > 0 {
                let assumedBitrate: Double = ext == "flac" ? 900_000 : 192_000 // bps
                duration = Double(item.size) * 8.0 / assumedBitrate
            }

        } catch {
            // Metadata extraction failed — still estimate duration from file size
            if duration == 0 && item.size > 0 {
                let assumedBitrate: Double = ext == "flac" ? 900_000 : 192_000
                duration = Double(item.size) * 8.0 / assumedBitrate
            }
        }

        // Store embedded cover art and lyrics to asset store
        if let data = embeddedCoverData {
            coverArtFileName = await MetadataAssetStore.shared.storeCover(data, for: songID)
            NSLog("💾 Stored cover: \(coverArtFileName ?? "nil") for \(title)")
        }
        if let text = embeddedLyricsText {
            let lyrics = LyricsParser.parseText(text)
            if !lyrics.isEmpty {
                lyricsFileName = await MetadataAssetStore.shared.storeLyrics(lyrics, for: songID)
                NSLog("💾 Stored lyrics: \(lyricsFileName ?? "nil") for \(title)")
            }
        }
        NSLog("📦 Song built: \(title) | cover=\(coverArtFileName ?? "nil") | lyrics=\(lyricsFileName ?? "nil")")

        return makeSong(id: songID, title: title, artist: artist, album: album,
                        trackNumber: trackNumber, duration: duration, format: format,
                        path: item.path, size: item.size, year: year, genre: genre,
                        sampleRate: sampleRate, bitRate: bitRate, bitDepth: bitDepth,
                        coverArtFileName: coverArtFileName, lyricsFileName: lyricsFileName)
    }

    private func makeSong(
        id: String, title: String, artist: String?, album: String?,
        trackNumber: Int?, duration: TimeInterval, format: AudioFormat,
        path: String, size: Int64, year: Int?, genre: String?,
        sampleRate: Int?, bitRate: Int?, bitDepth: Int?,
        coverArtFileName: String?, lyricsFileName: String? = nil
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
            dateAdded: Date(),
            coverArtFileName: coverArtFileName,
            lyricsFileName: lyricsFileName
        )
    }

    /// Download .lrc file from NAS, parse it, store to MetadataAssetStore
    private func downloadAndParseLrc(path: String, songID: String) async -> String? {
        do {
            let data = try await api.downloadFileHead(path: path, maxBytes: 512 * 1024) // .lrc files are small
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return nil
            }

            // Parse LRC format: [mm:ss.xx]text
            var lines: [LyricLine] = []
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("[") else { continue }

                // Extract all timestamps and text
                var timestamps: [TimeInterval] = []
                var remaining = line[line.startIndex...]

                while remaining.hasPrefix("[") {
                    guard let closeBracket = remaining.firstIndex(of: "]") else { break }
                    let tag = remaining[remaining.index(after: remaining.startIndex)..<closeBracket]

                    // Parse mm:ss.xx or mm:ss
                    let parts = tag.split(separator: ":")
                    if parts.count == 2,
                       let minutes = Double(parts[0]),
                       let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")) {
                        timestamps.append(minutes * 60 + seconds)
                    }

                    remaining = remaining[remaining.index(after: closeBracket)...]
                }

                let text = String(remaining).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }

                for ts in timestamps {
                    lines.append(LyricLine(timestamp: ts, text: text))
                }
            }

            guard !lines.isEmpty else { return nil }

            // Sort by timestamp
            lines.sort { $0.timestamp < $1.timestamp }

            // Store to MetadataAssetStore
            return await MetadataAssetStore.shared.storeLyrics(lines, for: songID)
        } catch {
            return nil
        }
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

    /// Remove child directories when a parent directory is already in the list.
    /// e.g. ["/test", "/test/music"] → ["/test"] (parent already covers child via recursion)
    static func deduplicateDirectories(_ directories: [String]) -> [String] {
        let sorted = directories.sorted()
        var result: [String] = []
        for dir in sorted {
            let isChildOfExisting = result.contains { parent in
                dir.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
            }
            if !isChildOfExisting {
                result.append(dir)
            }
        }
        return result
    }
}
