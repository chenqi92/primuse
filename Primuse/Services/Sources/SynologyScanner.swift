import CryptoKit
import Foundation
import PrimuseKit

/// Scans a Synology NAS for audio files and extracts metadata
actor SynologyScanner {
    private let api: SynologyAPI
    private let sourceID: String

    init(api: SynologyAPI, sourceID: String) {
        self.api = api
        self.sourceID = sourceID
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
        // Every update contains the complete accumulated Song array. Match the
        // bounded ConnectorScanner behavior introduced for large libraries:
        // if persistence/UI is slower than the NAS walk, retain only the most
        // recent snapshot instead of an unbounded chain of copy-on-write arrays.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    // Remove redundant child directories when a parent is already selected
                    let dirs = Self.deduplicateDirectories(directories)

                    // Phase 1: Count total audio files
                    var totalCount = 0
                    for dir in dirs {
                        try Task.checkCancellation()
                        totalCount += await countAudioFiles(in: dir)
                    }

                    // Phase 2: Scan and extract metadata
                    var allSongs = existingSongs
                    // path → allSongs 下标。existing 条目下标全程稳定(替换原地、新增追加到
                    // 末尾), 用于 O(1) 比对/回填/替换, 避免 firstIndex 的 O(n²)。
                    let existingByPath = Dictionary(
                        existingSongs.enumerated()
                            .filter { !$0.element.isCueTrack }
                            .map { ($0.element.filePath, $0.offset) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let existingByID = Dictionary(
                        existingSongs.enumerated().map { ($0.element.id, $0.offset) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let initialCount = max(existingSongs.count, startingCount)
                    var count = totalCount > 0 ? min(initialCount, totalCount) : initialCount
                    var encounteredSongIDs: Set<String> = []
                    var hadDirectoryFailure = false

                    if !existingSongs.isEmpty {
                        continuation.yield(
                            ScanUpdate(scannedCount: count, totalCount: totalCount, currentFile: "", songs: allSongs)
                        )
                    }

                    for dir in dirs {
                        try Task.checkCancellation()
                        do {
                            try await scanDirectory(
                                path: dir, allSongs: &allSongs,
                                count: &count, totalCount: totalCount,
                                existingByPath: existingByPath,
                                existingByID: existingByID,
                                encounteredSongIDs: &encounteredSongIDs,
                                continuation: continuation
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            hadDirectoryFailure = true
                            // Log error but continue scanning remaining directories
                            plog("⚠️ Failed to scan directory \(dir): \(error.localizedDescription)")
                            continue
                        }
                    }

                    if !hadDirectoryFailure {
                        allSongs.removeAll { encounteredSongIDs.contains($0.id) == false }
                        count = allSongs.count
                    }

                    continuation.yield(ScanUpdate(scannedCount: count, totalCount: totalCount, currentFile: "", songs: allSongs))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Recursively count audio files without downloading metadata
    private func countAudioFiles(in path: String) async -> Int {
        if Task.isCancelled { return 0 }
        guard let items = try? await api.listDirectory(path: path) else { return 0 }
        let nameByLowercase = Dictionary(
            items.filter { $0.isDirectory == false }.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let cueTracksByAudioPath = await loadCueTracks(from: items)
        var count = 0
        for item in items {
            if Task.isCancelled { return count }
            if item.isDirectory {
                count += await countAudioFiles(in: item.path)
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                    count += cueTracksByAudioPath[item.path]?.count ?? 1
                } else if PrimuseConstants.supportedMusicVideoExtensions.contains(ext) {
                    let baseName = (item.name as NSString).deletingPathExtension
                    if Self.hasSameNameAudio(baseName: baseName, nameByLowercase: nameByLowercase) == false {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private func scanDirectory(
        path: String, allSongs: inout [Song], count: inout Int,
        totalCount: Int,
        existingByPath: [String: Int],
        existingByID: [String: Int],
        encounteredSongIDs: inout Set<String>,
        continuation: AsyncThrowingStream<ScanUpdate, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let items = try await api.listDirectory(path: path)

        // Build filename lookup tables for sidecar detection.
        let allNames = Set(items.map(\.name))
        let nameByLowercase = Dictionary(
            items.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let cueTracksByAudioPath = await loadCueTracks(from: items)
        let coverNames = PrimuseConstants.folderCoverNames  // cover.jpg, folder.jpg, etc.

        // Detect folder-level cover sidecar (e.g., cover.jpg in this directory).
        // A broad library root like /music/cover.jpg should not become every
        // flat-folder song's cover.
        let coverExts = ["jpg", "jpeg", "png", "webp"]
        var folderCoverPath: String?
        if !Self.isGenericMusicDirectory(path) {
            outer: for name in coverNames {
                for ext in coverExts {
                    let fileName = "\(name).\(ext)"
                    if allNames.contains(fileName) {
                        folderCoverPath = (path as NSString).appendingPathComponent(fileName)
                        break outer
                    }
                }
            }
        }

        for item in items {
            try Task.checkCancellation()
            if item.isDirectory {
                try await scanDirectory(
                    path: item.path, allSongs: &allSongs,
                    count: &count, totalCount: totalCount,
                    existingByPath: existingByPath,
                    existingByID: existingByID,
                    encounteredSongIDs: &encounteredSongIDs,
                    continuation: continuation
                )
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedMusicVideoExtensions.contains(ext) {
                    scanStandaloneVideo(
                        item: item, ext: ext,
                        allNames: allNames, nameByLowercase: nameByLowercase,
                        folderCoverPath: folderCoverPath,
                        allSongs: &allSongs, count: &count, totalCount: totalCount,
                        existingByPath: existingByPath,
                        encounteredSongIDs: &encounteredSongIDs,
                        continuation: continuation
                    )
                    continue
                }
                guard PrimuseConstants.supportedAudioExtensions.contains(ext) else { continue }
                if let descriptors = cueTracksByAudioPath[item.path], !descriptors.isEmpty {
                    let cueSongs = await buildCueSongs(from: item, descriptors: descriptors)
                    for var song in cueSongs {
                        encounteredSongIDs.insert(song.id)
                        count += 1
                        if let index = existingByID[song.id] {
                            song.dateAdded = allSongs[index].dateAdded
                            allSongs[index] = song
                        } else {
                            allSongs.append(song)
                        }
                    }
                    continuation.yield(ScanUpdate(
                        scannedCount: count,
                        totalCount: totalCount,
                        currentFile: item.name,
                        songs: allSongs
                    ))
                    continue
                }
                encounteredSongIDs.insert(generateID(sourceID: sourceID, path: item.path))

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

                let mvRef = Self.sameNameSidecarPath(
                    baseName: baseName,
                    extensions: PrimuseConstants.supportedMusicVideoExtensions,
                    in: parentDir,
                    nameByLowercase: nameByLowercase
                )

                // 已知文件: size + mtime 都没变才跳过。变了(远端同名覆盖)就往下重新
                // 解析并替换旧条目, 否则覆盖文件的新标签/封面/时长/大小永远刷不出来。
                if let idx = existingByPath[item.path] {
                    let existing = allSongs[idx]
                    let sizeSame = existing.fileSize == item.size
                    let mtimeSame: Bool
                    if let a = existing.lastModified, let b = item.modifiedTime {
                        mtimeSame = abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 1
                    } else {
                        // 任一侧缺 mtime 时退化为只比 size。
                        mtimeSame = true
                    }
                    if sizeSame && mtimeSame {
                        // 旧库迁移: existing 缺 mtime 而远端有 —— 廉价回填 mtime(不重新解析
                        // 元数据 / 不下载 header)。否则这首歌永远 lastModified=nil, 跳过路径也
                        // 走不到下方写入, 未来同名同大小覆盖永远检测不到。回填后随 addSongs
                        // 落库, 下次扫描即可做 size+mtime 指纹比对。
                        if existing.lastModified == nil, let remoteMtime = item.modifiedTime {
                            allSongs[idx].lastModified = remoteMtime
                        }
                        if let coverRef, allSongs[idx].coverArtFileName != coverRef {
                            allSongs[idx].coverArtFileName = coverRef
                        }
                        if let lyricsRef, allSongs[idx].lyricsFileName != lyricsRef {
                            allSongs[idx].lyricsFileName = lyricsRef
                        }
                        if let mvRef {
                            allSongs[idx].mvPath = mvRef
                        } else if Self.isSameNameMusicVideoSidecar(existing.mvPath, baseName: baseName, in: parentDir) {
                            allSongs[idx].mvPath = nil
                        }
                        continue
                    }
                }

                count += 1
                continuation.yield(ScanUpdate(
                    scannedCount: count, totalCount: totalCount, currentFile: item.name, songs: allSongs
                ))

                var song = await extractSongMetadata(item: item, ext: ext)

                // Priority: sidecar path > embedded/cached > nil。原地覆盖这两个
                // 字段即可, 不要用部分 init 重建 —— 那会把 lastModified/revision/
                // replayGain/pinyin 等未列出的字段全部丢成 nil, 导致远端同名覆盖文件
                // 重扫后检测不到变化(mtime/revision 两侧都 nil)而保留旧元数据。
                if let coverRef { song.coverArtFileName = coverRef }
                if let lyricsRef { song.lyricsFileName = lyricsRef }
                if let mvRef {
                    song.mvPath = mvRef
                } else if let idx = existingByPath[item.path],
                          !Self.isSameNameMusicVideoSidecar(allSongs[idx].mvPath, baseName: baseName, in: parentDir) {
                    song.mvPath = allSongs[idx].mvPath
                }
                // 记录 mtime 供下次重扫指纹比对; 保留原 dateAdded 不因重扫刷新排序。
                song.lastModified = item.modifiedTime
                if let idx = existingByPath[item.path] {
                    // 覆盖文件 id 基于路径不变, 原地替换旧条目; 保留原 dateAdded 不刷新排序。
                    song.dateAdded = allSongs[idx].dateAdded
                    allSongs[idx] = song
                } else {
                    allSongs.append(song)
                }

                // Yield with updated songs every 3 files
                if count % 3 == 0 {
                    continuation.yield(ScanUpdate(
                        scannedCount: count, totalCount: totalCount, currentFile: item.name, songs: allSongs
                    ))
                }
            }
        }
    }

    private struct CueTrackDescriptor: Sendable {
        let cuePath: String
        let albumTitle: String?
        let albumPerformer: String?
        let genre: String?
        let year: Int?
        let format: AudioFormat
        let track: CueTrack
    }

    private func loadCueTracks(
        from items: [SynologyAPI.FileItem]
    ) async -> [String: [CueTrackDescriptor]] {
        var result: [String: [CueTrackDescriptor]] = [:]
        let filesByName = Dictionary(
            items.filter { !$0.isDirectory }.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for cueItem in items where !cueItem.isDirectory
            && (cueItem.name as NSString).pathExtension.caseInsensitiveCompare("cue") == .orderedSame {
            let readSize = min(max(Int(clamping: cueItem.size), 64 * 1024), 1024 * 1024)
            guard let data = try? await api.downloadFileHead(path: cueItem.path, maxBytes: readSize),
                  let cue = CueSheetParser.parse(data: data) else {
                plog("⚠️ Synology CUE: unable to parse \(cueItem.name)")
                continue
            }

            for cueFile in cue.files {
                let referencedName = (cueFile.name.replacingOccurrences(of: "\\", with: "/") as NSString)
                    .lastPathComponent
                guard let audioItem = filesByName[referencedName.lowercased()] else {
                    plog("⚠️ Synology CUE: '\(cueItem.name)' references missing file '\(cueFile.name)'")
                    continue
                }
                let ext = (audioItem.name as NSString).pathExtension.lowercased()
                guard var format = AudioFormat.from(fileExtension: ext) else { continue }
                if ext == "dts" {
                    format = .dts
                } else if ext == "wav",
                          let prefix = try? await api.downloadFileHead(
                              path: audioItem.path,
                              maxBytes: min(Int(clamping: audioItem.size), 256 * 1024)
                          ),
                          FFmpegAudioDecoder.dataContainsDTSSync(prefix) {
                    format = .dts
                }

                for track in cueFile.tracks where track.type == "AUDIO" && track.startTime != nil {
                    result[audioItem.path, default: []].append(
                        CueTrackDescriptor(
                            cuePath: cueItem.path,
                            albumTitle: cue.title,
                            albumPerformer: cue.performer,
                            genre: cue.genre,
                            year: cue.year,
                            format: format,
                            track: track
                        )
                    )
                }
            }
        }
        return result
    }

    private func buildCueSongs(
        from item: SynologyAPI.FileItem,
        descriptors: [CueTrackDescriptor]
    ) async -> [Song] {
        let physical = await extractSongMetadata(
            item: item,
            ext: (item.name as NSString).pathExtension.lowercased()
        )
        return descriptors.compactMap { descriptor in
            guard let start = descriptor.track.startTime else { return nil }
            let end = descriptor.track.endTime
                ?? (physical.duration > start ? physical.duration : nil)
            let artist = descriptor.track.performer
                ?? descriptor.albumPerformer
                ?? physical.artistName
            let album = descriptor.albumTitle ?? physical.albumTitle
            var song = physical
            song.id = generateID(
                sourceID: sourceID,
                path: "\(item.path)#cue:\(descriptor.cuePath)#track:\(descriptor.track.number)"
            )
            song.title = descriptor.track.title
                ?? String(format: "Track %02d", descriptor.track.number)
            song.artistName = artist
            song.artistID = artist.map { generateID(sourceID: "artist", path: $0.lowercased()) }
            song.albumTitle = album
            song.albumID = album.map {
                generateID(sourceID: "album", path: "\(artist ?? ""):\($0.lowercased())")
            }
            song.trackNumber = descriptor.track.number
            song.duration = end.map { max(0, $0 - start) } ?? 0
            song.fileFormat = descriptor.format
            song.genre = descriptor.genre ?? physical.genre
            song.year = descriptor.year ?? physical.year
            song.cueSheetPath = descriptor.cuePath
            song.cueStartTime = start
            song.cueEndTime = end
            return song
        }
    }

    /// 独立 MV: 同目录没有同名音频的视频文件独立成曲, mvPath 指向自身
    /// (Song.isStandaloneMusicVideo)。不下载 header 解析 —— 视频的 moov
    /// 常在文件尾, 4MB 头不可靠; 时长由 MetadataBackfillService / 播放时
    /// AVPlayer 回填。
    private func scanStandaloneVideo(
        item: SynologyAPI.FileItem, ext: String,
        allNames: Set<String>, nameByLowercase: [String: String],
        folderCoverPath: String?,
        allSongs: inout [Song], count: inout Int, totalCount: Int,
        existingByPath: [String: Int],
        encounteredSongIDs: inout Set<String>,
        continuation: AsyncThrowingStream<ScanUpdate, Error>.Continuation
    ) {
        let baseName = (item.name as NSString).deletingPathExtension
        let parentDir = (item.path as NSString).deletingLastPathComponent

        // 有同名音频时它是那首歌的 sidecar, 不独立成曲。
        let hasSameNameAudio = Self.hasSameNameAudio(
            baseName: baseName,
            nameByLowercase: nameByLowercase
        )
        guard hasSameNameAudio == false else { return }
        encounteredSongIDs.insert(generateID(sourceID: sourceID, path: item.path))

        var coverRef: String?
        for coverExt in ["jpg", "jpeg", "png", "webp"] {
            let songCover = baseName + ".\(coverExt)"
            if allNames.contains(songCover) {
                coverRef = (parentDir as NSString).appendingPathComponent(songCover)
                break
            }
            let nameCover = baseName + "-cover.\(coverExt)"
            if allNames.contains(nameCover) {
                coverRef = (parentDir as NSString).appendingPathComponent(nameCover)
                break
            }
        }
        if coverRef == nil { coverRef = folderCoverPath }
        let lrcName = baseName + ".lrc"
        let hasLrc = allNames.contains(lrcName) || allNames.contains(baseName + ".LRC")
        let lyricsRef = hasLrc ? (parentDir as NSString).appendingPathComponent(lrcName) : nil

        if let idx = existingByPath[item.path] {
            let existing = allSongs[idx]
            let sizeSame = existing.fileSize == item.size
            let mtimeSame: Bool
            if let a = existing.lastModified, let b = item.modifiedTime {
                mtimeSame = abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 1
            } else {
                mtimeSame = true
            }
            if sizeSame && mtimeSame {
                if existing.lastModified == nil, let remoteMtime = item.modifiedTime {
                    allSongs[idx].lastModified = remoteMtime
                }
                if let coverRef, allSongs[idx].coverArtFileName != coverRef {
                    allSongs[idx].coverArtFileName = coverRef
                }
                if let lyricsRef, allSongs[idx].lyricsFileName != lyricsRef {
                    allSongs[idx].lyricsFileName = lyricsRef
                }
                return
            }
        }

        count += 1
        continuation.yield(ScanUpdate(
            scannedCount: count, totalCount: totalCount, currentFile: item.name, songs: allSongs
        ))

        let (_, parsedArtist) = parseFilename(baseName)
        var song = Song(
            id: generateID(sourceID: sourceID, path: item.path),
            title: baseName,
            artistName: parsedArtist,
            duration: 0,
            fileFormat: AudioFormat.from(fileExtension: ext) ?? .mp4,
            filePath: item.path,
            sourceID: sourceID,
            fileSize: item.size,
            lastModified: item.modifiedTime,
            coverArtFileName: coverRef,
            lyricsFileName: lyricsRef,
            mvPath: item.path
        )
        if let idx = existingByPath[item.path] {
            song.dateAdded = allSongs[idx].dateAdded
            allSongs[idx] = song
        } else {
            allSongs.append(song)
        }
    }

    private static func hasSameNameAudio(
        baseName: String,
        nameByLowercase: [String: String]
    ) -> Bool {
        PrimuseConstants.supportedAudioExtensions.contains {
            nameByLowercase["\(baseName).\($0)".lowercased()] != nil
        }
    }

    private static func sameNameSidecarPath(
        baseName: String,
        extensions: [String],
        in parentDir: String,
        nameByLowercase: [String: String]
    ) -> String? {
        for ext in extensions {
            let key = "\(baseName).\(ext)".lowercased()
            if let actualName = nameByLowercase[key] {
                return (parentDir as NSString).appendingPathComponent(actualName)
            }
        }
        return nil
    }

    private static func isSameNameMusicVideoSidecar(_ path: String?, baseName: String, in parentDir: String) -> Bool {
        guard let path, path.contains("://") == false else { return false }
        let nsPath = path as NSString
        guard nsPath.deletingLastPathComponent == parentDir else { return false }
        let fileName = nsPath.lastPathComponent as NSString
        let existingBase = fileName.deletingPathExtension
        let existingExt = fileName.pathExtension.lowercased()
        return existingBase.caseInsensitiveCompare(baseName) == .orderedSame
            && PrimuseConstants.supportedMusicVideoExtensions.contains(existingExt)
    }

    /// Download a bounded file prefix and extract metadata without creating a
    /// per-song temporary file. MP3 starts at 256 KB and expands for a declared
    /// large ID3 tag; other containers retain the historical 4 MB read because
    /// their cover art/container atoms may occur later. Every format remains
    /// hard-bounded at 4 MB.
    private func extractSongMetadata(item: SynologyAPI.FileItem, ext: String) async -> Song {
        var format = AudioFormat.from(fileExtension: ext) ?? .mp3
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
        var replayGainTrackGain: Double?
        var replayGainTrackPeak: Double?
        var replayGainAlbumGain: Double?
        var replayGainAlbumPeak: Double?

        // Download and parse one song at a time. SynologyScanner is an actor;
        // this await chain deliberately stays serial even when several source
        // scans or the three-worker metadata backfill are active elsewhere.
        do {
            let readSize = RemoteMetadataReadPolicy.initialReadSize(
                fileSize: item.size,
                fileExtension: ext
            )
            guard readSize > 0 else {
                return makeSong(id: songID, title: title, artist: artist, album: album,
                               trackNumber: trackNumber, duration: duration, format: format,
                               path: item.path, size: item.size, year: year, genre: genre,
                               sampleRate: sampleRate, bitRate: bitRate, bitDepth: bitDepth,
                               coverArtFileName: nil)
            }

            var data = try await api.downloadFileHead(path: item.path, maxBytes: readSize)
            if ext == "wav", FFmpegAudioDecoder.dataContainsDTSSync(data) {
                format = .dts
            }

            var embedded = await FileMetadataReader.read(from: data, fileExtension: ext)
            let metadataInsufficient = Self.metadataNeedsLargerPrefix(embedded, fileExtension: ext)
            if let expandedSize = RemoteMetadataReadPolicy.expandedReadSize(
                fileSize: item.size,
                currentByteCount: data.count,
                declaredID3ByteCount: FileMetadataReader.id3TagByteCount(in: data),
                metadataInsufficient: metadataInsufficient
            ) {
                data = try await api.downloadFileHead(path: item.path, maxBytes: expandedSize)
                if ext == "wav", FFmpegAudioDecoder.dataContainsDTSSync(data) {
                    format = .dts
                }
                embedded = await FileMetadataReader.read(from: data, fileExtension: ext)
            }

            if let value = embedded.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                artist = embedded.artist
            }
            if let value = embedded.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                album = embedded.albumTitle
            }
            trackNumber = embedded.trackNumber
            year = embedded.year
            genre = embedded.genre
            sampleRate = embedded.sampleRate
            bitRate = embedded.bitRate
            bitDepth = embedded.bitDepth
            embeddedCoverData = embedded.coverArtData
            embeddedLyricsText = embedded.lyricsText
            replayGainTrackGain = embedded.replayGainTrackGain
            replayGainTrackPeak = embedded.replayGainTrackPeak
            replayGainAlbumGain = embedded.replayGainAlbumGain
            replayGainAlbumPeak = embedded.replayGainAlbumPeak
            if let parsedDuration = embedded.duration,
               parsedDuration.isFinite, parsedDuration > 0 {
                duration = parsedDuration
            }

            if format == .mp3 {
                duration = RemoteMetadataReadPolicy.correctedMP3Duration(
                    parsed: duration,
                    fileSize: item.size,
                    bitRateKbps: bitRate,
                    providedByteCount: data.count
                )
            }

            // Estimate duration from file size and bitrate
            if duration == 0, let br = bitRate, br > 0 {
                duration = Double(item.size) * 8.0 / Double(br * 1000)
            }

            if format == .flac, bitRate == nil, duration > 0, item.size > 0 {
                bitRate = Int((Double(item.size) * 8.0 / duration / 1000.0).rounded())
            }

            // Last resort: estimate from file size using a format-aware
            // bitrate. Raw DTS is commonly 1,536 kbps; treating it like the
            // generic 192 kbps fallback inflates its duration by exactly 8x.
            if duration == 0 && item.size > 0 {
                duration = AudioDurationPolicy.fallbackEstimate(
                    fileSize: item.size,
                    format: format
                )
            }

        } catch {
            // Metadata extraction failed — still estimate duration from file size
            if duration == 0 && item.size > 0 {
                duration = AudioDurationPolicy.fallbackEstimate(
                    fileSize: item.size,
                    format: format
                )
            }
        }

        // Store embedded cover art and lyrics to asset store
        if let data = embeddedCoverData {
            coverArtFileName = await MetadataAssetStore.shared.storeCover(data, for: songID)
            plog("💾 Stored cover: \(coverArtFileName ?? "nil") for \(title)")
        }
        if let text = embeddedLyricsText {
            let lyrics = LyricsParser.parseText(text)
            if !lyrics.isEmpty {
                lyricsFileName = await MetadataAssetStore.shared.storeLyrics(lyrics, for: songID)
                plog("💾 Stored lyrics: \(lyricsFileName ?? "nil") for \(title)")
            }
        }
        plog("📦 Song built: \(title) | cover=\(coverArtFileName ?? "nil") | lyrics=\(lyricsFileName ?? "nil")")

        return makeSong(id: songID, title: title, artist: artist, album: album,
                        trackNumber: trackNumber, duration: duration, format: format,
                        path: item.path, size: item.size, year: year, genre: genre,
                        sampleRate: sampleRate, bitRate: bitRate, bitDepth: bitDepth,
                        coverArtFileName: coverArtFileName, lyricsFileName: lyricsFileName,
                        replayGainTrackGain: replayGainTrackGain,
                        replayGainTrackPeak: replayGainTrackPeak,
                        replayGainAlbumGain: replayGainAlbumGain,
                        replayGainAlbumPeak: replayGainAlbumPeak)
    }

    private func makeSong(
        id: String, title: String, artist: String?, album: String?,
        trackNumber: Int?, duration: TimeInterval, format: AudioFormat,
        path: String, size: Int64, year: Int?, genre: String?,
        sampleRate: Int?, bitRate: Int?, bitDepth: Int?,
        coverArtFileName: String?, lyricsFileName: String? = nil,
        replayGainTrackGain: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumGain: Double? = nil,
        replayGainAlbumPeak: Double? = nil
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
            lyricsFileName: lyricsFileName,
            replayGainTrackGain: replayGainTrackGain,
            replayGainTrackPeak: replayGainTrackPeak,
            replayGainAlbumGain: replayGainAlbumGain,
            replayGainAlbumPeak: replayGainAlbumPeak
        )
    }

    private static func metadataNeedsLargerPrefix(
        _ metadata: FileMetadataReader.Metadata,
        fileExtension: String
    ) -> Bool {
        let durationMissing = !(metadata.duration?.isFinite == true && (metadata.duration ?? 0) > 0)
        let containerMayNeedMoreHeader = ["m4a", "alac", "mp4", "m4v", "mov"]
            .contains(fileExtension.lowercased())
            && durationMissing
        let hasAnyMetadata = !durationMissing
            || metadata.sampleRate != nil
            || metadata.bitRate != nil
            || metadata.title?.isEmpty == false
            || metadata.artist?.isEmpty == false
            || metadata.albumTitle?.isEmpty == false
            || metadata.coverArtData != nil
            || metadata.lyricsText?.isEmpty == false
        return containerMayNeedMoreHeader || !hasAnyMetadata
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

    private nonisolated static func isGenericMusicDirectory(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["music", "音乐", "songs", "audio", "media", "downloads"].contains(name)
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
