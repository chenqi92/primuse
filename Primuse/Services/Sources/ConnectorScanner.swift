import CryptoKit
import Foundation
import PrimuseKit

actor ConnectorScanner {
    private static let progressYieldStride = 20

    private let connector: any MusicSourceConnector
    private let sourceID: String
    private let metadataService = MetadataService()

    init(connector: any MusicSourceConnector, sourceID: String) {
        self.connector = connector
        self.sourceID = sourceID
    }

    struct ScanUpdate: Sendable {
        /// Total songs known for this source after this scan run — existing
        /// (from prior runs) plus anything newly discovered. Drives the
        /// source-card "X songs" badge.
        var scannedCount: Int
        /// Songs the scan walk added this run. Stays 0 when re-scanning a
        /// source that hasn't gained any files. Drives the in-progress
        /// "新增 N 首" label so users can tell a no-op scan from a real one.
        var addedCount: Int
        var totalCount: Int
        var currentFile: String
        var songs: [Song]
    }

    func scan(
        directories: [String],
        existingSongs: [Song] = [],
        startingCount: Int = 0
    ) -> AsyncThrowingStream<ScanUpdate, Error> {
        // Each update carries the complete song snapshot. An unbounded stream
        // retains every pending snapshot when a fast remote listing outruns the
        // consumer, and subsequent appends then copy those shared arrays. Keep
        // only the newest pending snapshot; the final yield below still carries
        // the complete scan result.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    plog("🔍 ConnectorScanner.scan source=\(sourceID) dirs=\(directories)")
                    try await connector.connect()
                    plog("🔍 ConnectorScanner.scan connected")

                    // Remove redundant child directories when a parent is already selected
                    let dirs = SynologyScanner.deduplicateDirectories(directories)

                    // Single-pass scan. Total count is unknown until we finish walking
                    // the tree — UI shows scannedCount as an indeterminate counter
                    // rather than X/Y. Skipping the prior Phase1 countAudioFiles pass
                    // avoids walking every directory twice (saved ~50% list-API time
                    // on large cloud trees).
                    let totalCount = 0
                    var allSongs = existingSongs
                    var existingByID: [String: Song] = [:]
                    existingByID.reserveCapacity(existingSongs.count)
                    for song in existingSongs { existingByID[song.id] = song }
                    var allSongIndexByID: [String: Int] = [:]
                    allSongIndexByID.reserveCapacity(existingSongs.count)
                    for (i, song) in allSongs.enumerated() { allSongIndexByID[song.id] = i }
                    let initialCount = max(existingSongs.count, startingCount)
                    var scannedCount = totalCount > 0 ? min(initialCount, totalCount) : initialCount
                    var addedCount = 0
                    var encounteredSongIDs: Set<String> = []
                    var hadDirectoryFailure = false
                    var successfulDirectoryCount = 0
                    var firstDirectoryError: Error?

                    if !existingSongs.isEmpty {
                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
                                addedCount: addedCount,
                                totalCount: totalCount,
                                currentFile: "",
                                songs: allSongs
                            )
                        )
                    }

                    if let songConnector = connector as? any SongScanningConnector {
                        for directory in dirs {
                            try Task.checkCancellation()
                            do {
                                let stream = try await songConnector.scanSongs(from: directory)

                                for try await scannedSong in stream {
                                    try Task.checkCancellation()
                                    encounteredSongIDs.insert(scannedSong.song.id)
                                    if let existing = existingByID[scannedSong.song.id] {
                                        // Same path can either be the same file (skip) or
                                        // a remote replacement (refresh). Decide on size
                                        // first since lastModified isn't always populated.
                                        if !songContentChanged(existing: existing, incoming: scannedSong.song) {
                                            if connector is any RefreshingMetadataSongConnector {
                                                let refreshed = refreshServerMetadata(
                                                    existing: existing,
                                                    incoming: scannedSong.song
                                                )
                                                if refreshed != existing,
                                                   let idx = allSongIndexByID[scannedSong.song.id] {
                                                    allSongs[idx] = refreshed
                                                    existingByID[scannedSong.song.id] = refreshed
                                                }
                                            }
                                            continue
                                        }
                                        // Replaced — overwrite the entry already in
                                        // allSongs so the next library flush sees the
                                        // fresh size/mtime/sidecars instead of merging
                                        // back to stale metadata.
                                        if let idx = allSongIndexByID[scannedSong.song.id] {
                                            allSongs[idx] = scannedSong.song
                                        }
                                        existingByID[scannedSong.song.id] = scannedSong.song
                                        continue
                                    }

                                    scannedCount += 1
                                    addedCount += 1
                                    allSongs.append(scannedSong.song)
                                    allSongIndexByID[scannedSong.song.id] = allSongs.count - 1

                                    // Server-side song scanners can enumerate
                                    // thousands of tracks faster than the UI can
                                    // persist a full snapshot. Coalesce progress
                                    // just like the generic file scanner below.
                                    if addedCount % Self.progressYieldStride == 0 {
                                        continuation.yield(
                                            ScanUpdate(
                                                scannedCount: scannedCount,
                                                addedCount: addedCount,
                                                totalCount: totalCount,
                                                currentFile: scannedSong.displayName,
                                                songs: allSongs
                                            )
                                        )
                                    }
                                }
                                successfulDirectoryCount += 1
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                hadDirectoryFailure = true
                                if firstDirectoryError == nil {
                                    firstDirectoryError = error
                                }
                                plog("⚠️ Failed to scan directory \(directory): \(error)")
                                continue
                            }
                        }

                        if successfulDirectoryCount == 0, let firstDirectoryError {
                            throw firstDirectoryError
                        }

                        if !hadDirectoryFailure {
                            allSongs.removeAll { encounteredSongIDs.contains($0.id) == false }
                            scannedCount = allSongs.count
                        }

                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
                                addedCount: addedCount,
                                totalCount: totalCount,
                                currentFile: "",
                                songs: allSongs
                            )
                        )
                        continuation.finish()
                        return
                    }

                    // Parse CUE sheets before walking audio so referenced image
                    // files can be replaced by virtual tracks instead of also
                    // appearing as one duplicate whole-album song.
                    var cueTracksByAudioPath: [String: [CueTrackDescriptor]] = [:]
                    for directory in dirs {
                        let parsed = await loadCueTracks(in: directory)
                        for (path, tracks) in parsed {
                            cueTracksByAudioPath[path, default: []].append(contentsOf: tracks)
                        }
                    }

                    // Phase A: walk the tree, build "bare" Songs (filename + path
                    // + size + sidecar hints from sibling listing). Skip the full
                    // file download + ID3 extraction — that work is deferred to
                    // MetadataBackfillService which fetches just the first 256KB
                    // via HTTP Range. This drops scan time from minutes (and 11GB
                    // of egress on a 2200-song cloud library) to seconds.
                    for directory in dirs {
                        try Task.checkCancellation()
                        do {
                            let stream = try await connector.scanAudioFiles(from: directory)

                            for try await item in stream {
                                try Task.checkCancellation()
                                let songID = hash("\(sourceID):\(item.path)")

                                if let descriptors = cueTracksByAudioPath[item.path], !descriptors.isEmpty {
                                    for cueSong in buildCueSongs(from: item, descriptors: descriptors) {
                                        encounteredSongIDs.insert(cueSong.id)
                                        if let existing = existingByID[cueSong.id] {
                                            if songContentChanged(existing: existing, incoming: cueSong),
                                               let index = allSongIndexByID[cueSong.id] {
                                                allSongs[index] = cueSong
                                                existingByID[cueSong.id] = cueSong
                                            }
                                            continue
                                        }
                                        allSongs.append(cueSong)
                                        allSongIndexByID[cueSong.id] = allSongs.count - 1
                                        existingByID[cueSong.id] = cueSong
                                        scannedCount += 1
                                        addedCount += 1
                                    }
                                    continue
                                }

                                encounteredSongIDs.insert(songID)

                                if let existing = existingByID[songID] {
                                    // Same path can either be unchanged (skip) or a
                                    // remote replacement (emit fresh bare song so
                                    // backfill re-runs against new bytes). Compare
                                    // size, mtime, AND provider revision — Baidu /
                                    // Aliyun / Dropbox listFiles return nil mtime
                                    // and a same-size overwrite would slip past the
                                    // first two checks.
                                    let sizeChanged = item.size > 0 && existing.fileSize > 0 && item.size != existing.fileSize
                                    let mtimeChanged: Bool = {
                                        guard let a = item.modifiedDate, let b = existing.lastModified else { return false }
                                        return a != b
                                    }()
                                    let revisionChanged: Bool = {
                                        guard let a = item.revision, let b = existing.revision else { return false }
                                        return a != b
                                    }()
                                    // First-time backfill of a fingerprint that
                                    // didn't exist before (user upgraded to a
                                    // build that reads md5/etag, or to a
                                    // connector that surfaces mtime). NOT a
                                    // content change — feed it through the
                                    // library merge path so revision/mtime
                                    // sticks for next scan, but no cache
                                    // invalidation and no failed-set clear.
                                    let revisionAdded = item.revision != nil && existing.revision == nil
                                    let mtimeAdded = item.modifiedDate != nil && existing.lastModified == nil
                                    let sidecarChanged = item.sidecarHints?.coverPath.map { $0 != existing.coverArtFileName } ?? false
                                        || item.sidecarHints?.lyricsPath.map { $0 != existing.lyricsFileName } ?? false
                                        || item.sidecarHints?.mvPath.map { $0 != existing.mvPath } ?? false
                                    if !(sizeChanged || mtimeChanged || revisionChanged || revisionAdded || mtimeAdded || sidecarChanged) {
                                        continue
                                    }
                                    let refreshed = await buildBareSong(from: item, songID: songID)
                                    if let idx = allSongIndexByID[songID] {
                                        allSongs[idx] = refreshed
                                    }
                                    existingByID[songID] = refreshed
                                    continue
                                }

                                allSongs.append(await buildBareSong(from: item, songID: songID))
                                allSongIndexByID[songID] = allSongs.count - 1
                                scannedCount += 1
                                addedCount += 1

                                // Yield progress every 20 items — yielding on every
                                // file made the SwiftUI publisher chain the bottleneck
                                // when scanning fast cloud listings.
                                if addedCount % Self.progressYieldStride == 0 {
                                    continuation.yield(
                                        ScanUpdate(
                                            scannedCount: scannedCount,
                                            addedCount: addedCount,
                                            totalCount: totalCount,
                                            currentFile: item.name,
                                            songs: allSongs
                                        )
                                    )
                                }
                            }
                            successfulDirectoryCount += 1
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            hadDirectoryFailure = true
                            if firstDirectoryError == nil {
                                firstDirectoryError = error
                            }
                            plog("⚠️ Failed to scan directory \(directory): \(error)")
                            continue
                        }
                    }

                    if successfulDirectoryCount == 0, let firstDirectoryError {
                        throw firstDirectoryError
                    }

                    if !hadDirectoryFailure {
                        allSongs.removeAll { encounteredSongIDs.contains($0.id) == false }
                        scannedCount = allSongs.count
                    }

                    continuation.yield(
                        ScanUpdate(
                            scannedCount: scannedCount,
                            addedCount: addedCount,
                            totalCount: totalCount,
                            currentFile: "",
                            songs: allSongs
                        )
                    )
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

    private struct CueTrackDescriptor: Sendable {
        let cuePath: String
        let albumTitle: String?
        let albumPerformer: String?
        let genre: String?
        let year: Int?
        let format: AudioFormat
        let track: CueTrack
    }

    private func loadCueTracks(in root: String) async -> [String: [CueTrackDescriptor]] {
        var result: [String: [CueTrackDescriptor]] = [:]
        var dtsDetectionCache: [String: Bool] = [:]
        do {
            let stream = try await connector.scanCueSheets(from: root)
            for try await remoteCue in stream {
                try Task.checkCancellation()
                let requestedLength = min(
                    max(remoteCue.item.size, 64 * 1024),
                    Int64(1024 * 1024)
                )
                guard let data = try? await connector.fetchRange(
                    path: remoteCue.item.path,
                    offset: 0,
                    length: requestedLength
                ),
                let cue = CueSheetParser.parse(data: data) else {
                    plog("⚠️ CUE: unable to parse \(remoteCue.item.name)")
                    continue
                }

                for cueFile in cue.files {
                    let referencedName = (cueFile.name.replacingOccurrences(of: "\\", with: "/") as NSString)
                        .lastPathComponent
                    guard let audioItem = remoteCue.siblings.first(where: {
                        !$0.isDirectory && $0.name.caseInsensitiveCompare(referencedName) == .orderedSame
                    }) else {
                        plog("⚠️ CUE: '\(remoteCue.item.name)' references missing file '\(cueFile.name)'")
                        continue
                    }

                    let ext = (audioItem.name as NSString).pathExtension.lowercased()
                    guard var format = AudioFormat.from(fileExtension: ext) else { continue }
                    if ext == "wav" {
                        let isDTS: Bool
                        if let cached = dtsDetectionCache[audioItem.path] {
                            isDTS = cached
                        } else {
                            let prefix = try? await connector.fetchRange(
                                path: audioItem.path,
                                offset: 0,
                                length: 256 * 1024
                            )
                            isDTS = prefix.map(FFmpegAudioDecoder.dataContainsDTSSync) ?? false
                            dtsDetectionCache[audioItem.path] = isDTS
                        }
                        if isDTS { format = .dts }
                    }

                    for track in cueFile.tracks where track.type == "AUDIO" && track.startTime != nil {
                        result[audioItem.path, default: []].append(
                            CueTrackDescriptor(
                                cuePath: remoteCue.item.path,
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
        } catch is CancellationError {
            return result
        } catch {
            // CUE discovery is additive. A provider that cannot list/read CUE
            // files must not make its ordinary audio scan fail.
            plog("⚠️ CUE discovery skipped for \(root): \(error.localizedDescription)")
        }
        return result
    }

    private func buildCueSongs(
        from item: RemoteFileItem,
        descriptors: [CueTrackDescriptor]
    ) -> [Song] {
        descriptors.compactMap { descriptor in
            guard let start = descriptor.track.startTime else { return nil }
            let end = descriptor.track.endTime
            let artist = descriptor.track.performer ?? descriptor.albumPerformer
            let artistID = artist.map { hash($0.lowercased()) }
            let albumID: String? = if let artist, let album = descriptor.albumTitle {
                hash("\(artist.lowercased()):\(album.lowercased())")
            } else {
                nil
            }
            let fallbackTitle = String(format: "Track %02d", descriptor.track.number)
            let songID = hash(
                "\(sourceID):\(item.path)#cue:\(descriptor.cuePath)#track:\(descriptor.track.number)"
            )
            return Song(
                id: songID,
                title: descriptor.track.title ?? fallbackTitle,
                albumID: albumID,
                artistID: artistID,
                albumTitle: descriptor.albumTitle,
                artistName: artist,
                trackNumber: descriptor.track.number,
                duration: end.map { max(0, $0 - start) } ?? 0,
                fileFormat: descriptor.format,
                filePath: item.path,
                sourceID: sourceID,
                fileSize: item.size,
                genre: descriptor.genre,
                year: descriptor.year,
                lastModified: item.modifiedDate,
                coverArtFileName: item.sidecarHints?.coverPath,
                lyricsFileName: item.sidecarHints?.lyricsPath,
                mvPath: item.sidecarHints?.mvPath,
                cueSheetPath: descriptor.cuePath,
                cueStartTime: start,
                cueEndTime: end,
                revision: item.revision
            )
        }
    }

    private func songContentChanged(existing: Song, incoming: Song) -> Bool {
        let sizeChanged = incoming.fileSize > 0
            && existing.fileSize > 0
            && incoming.fileSize != existing.fileSize
        let mtimeChanged: Bool = {
            guard let a = incoming.lastModified, let b = existing.lastModified else { return false }
            return a != b
        }()
        let revisionChanged: Bool = {
            guard let a = incoming.revision, let b = existing.revision else { return false }
            return a != b
        }()
        let sidecarChanged = incoming.coverArtFileName.map { $0 != existing.coverArtFileName } ?? false
            || incoming.lyricsFileName.map { $0 != existing.lyricsFileName } ?? false
            || incoming.mvPath.map { $0 != existing.mvPath } ?? false
        // First-time fingerprint/mtime backfill — not a content change,
        // but still needs to flow through addSongs so the merge path
        // refreshes existing.revision / existing.lastModified. Without
        // this, a connector that newly surfaces revision would see its
        // updates dropped at the scanner boundary and never reach the
        // library, leaving same-size overwrite detection permanently
        // blind on existing rows.
        let revisionAdded = incoming.revision != nil && existing.revision == nil
        let mtimeAdded = incoming.lastModified != nil && existing.lastModified == nil
        let cueChanged = existing.cueSheetPath != incoming.cueSheetPath
            || existing.cueStartTime != incoming.cueStartTime
            || existing.cueEndTime != incoming.cueEndTime
            || existing.title != incoming.title
            || existing.artistName != incoming.artistName
            || existing.albumTitle != incoming.albumTitle
            || existing.trackNumber != incoming.trackNumber
            || existing.fileFormat != incoming.fileFormat
        return sizeChanged || mtimeChanged || revisionChanged || revisionAdded || mtimeAdded
            || sidecarChanged || cueChanged
    }

    private func refreshServerMetadata(existing: Song, incoming: Song) -> Song {
        var refreshed = existing

        if existing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || MediaMetadataTextRepair.isSuspicious(existing.title) {
            refreshed.title = incoming.title
        }
        if existing.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.artistName) {
            refreshed.artistName = incoming.artistName
            refreshed.artistID = incoming.artistID
        }
        if existing.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.albumTitle) {
            refreshed.albumTitle = incoming.albumTitle
            refreshed.albumID = incoming.albumID
        }
        if existing.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || MediaMetadataTextRepair.isSuspicious(existing.genre) {
            refreshed.genre = incoming.genre
        }

        if refreshed.trackNumber == nil { refreshed.trackNumber = incoming.trackNumber }
        if refreshed.discNumber == nil { refreshed.discNumber = incoming.discNumber }
        if refreshed.year == nil { refreshed.year = incoming.year }
        if refreshed.duration <= 0 { refreshed.duration = incoming.duration }
        if refreshed.fileSize <= 0 { refreshed.fileSize = incoming.fileSize }
        if refreshed.bitRate == nil { refreshed.bitRate = incoming.bitRate }
        if refreshed.sampleRate == nil { refreshed.sampleRate = incoming.sampleRate }
        if refreshed.bitDepth == nil { refreshed.bitDepth = incoming.bitDepth }
        if refreshed.coverArtFileName == nil { refreshed.coverArtFileName = incoming.coverArtFileName }

        return refreshed
    }

    private struct SidecarRefs {
        var coverPath: String?   // e.g. /Music/Album/cover.jpg
        var lyricsPath: String?  // e.g. /Music/Album/song.lrc
        var mvPath: String?      // e.g. /Music/Album/song.mp4
    }

    /// Detect sidecar files (cover art, lyrics, MV) by checking the local file's directory.
    private func detectSidecarRefs(for item: RemoteFileItem, localURL: URL) -> SidecarRefs {
        var refs = SidecarRefs()

        // Cover art sidecar
        if let coverURL = SidecarMetadataLoader.findCoverArt(for: localURL) {
            let parentDir = (item.path as NSString).deletingLastPathComponent
            refs.coverPath = (parentDir as NSString).appendingPathComponent(coverURL.lastPathComponent)
        }

        // Lyrics sidecar
        if let lyricsURL = SidecarMetadataLoader.findLyrics(for: localURL) {
            let parentDir = (item.path as NSString).deletingLastPathComponent
            refs.lyricsPath = (parentDir as NSString).appendingPathComponent(lyricsURL.lastPathComponent)
        }

        // Music video sidecar
        if let mvURL = SidecarMetadataLoader.findMusicVideo(for: localURL) {
            let parentDir = (item.path as NSString).deletingLastPathComponent
            refs.mvPath = (parentDir as NSString).appendingPathComponent(mvURL.lastPathComponent)
        }

        return refs
    }

    /// Build a Song with no metadata extraction — title is the filename, all
    /// metadata fields (artist, album, duration, bitRate, etc.) are nil. The
    /// MetadataBackfillService is responsible for filling these in later by
    /// reading just the file's header via HTTP Range.
    private func buildBareSong(from item: RemoteFileItem, songID: String) async -> Song {
        let ext = (item.name as NSString).pathExtension.lowercased()
        var format = AudioFormat.from(fileExtension: ext) ?? .mp3
        // DTS-CD commonly uses a .wav container even though its payload is a
        // DTS bitstream. Mark it before playback so remote URLs take the safe
        // full-download DTS path instead of being rendered as PCM noise.
        if ext == "wav",
           let prefix = try? await connector.fetchRange(
               path: item.path,
               offset: 0,
               length: 256 * 1024
           ),
           FFmpegAudioDecoder.dataContainsDTSSync(prefix) {
            format = .dts
        }
        let fileBaseName = (item.name as NSString).deletingPathExtension
        return Song(
            id: songID,
            title: fileBaseName,
            albumID: nil,
            artistID: nil,
            albumTitle: nil,
            artistName: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: 0,  // 0 = not yet extracted; backfill service watches for this
            fileFormat: format,
            filePath: item.path,
            sourceID: sourceID,
            fileSize: item.size,
            bitRate: nil,
            sampleRate: nil,
            bitDepth: nil,
            genre: nil,
            year: nil,
            lastModified: item.modifiedDate,
            dateAdded: Date(),
            coverArtFileName: item.sidecarHints?.coverPath,
            lyricsFileName: item.sidecarHints?.lyricsPath,
            mvPath: item.sidecarHints?.mvPath,
            revision: item.revision
        )
    }

    private func buildSong(
        from item: RemoteFileItem,
        metadata: MetadataService.SongMetadata,
        songID: String,
        sidecarRefs: SidecarRefs = SidecarRefs()
    ) -> Song {
        let artistID = metadata.artist.map { hash("\($0.lowercased())") }
        let albumID: String? = if let artist = metadata.artist, let album = metadata.albumTitle {
            hash("\(artist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        let format = AudioFormat.from(fileExtension: (item.name as NSString).pathExtension) ?? .mp3

        // Priority: sidecar path > embedded/cached > nil
        let coverRef = sidecarRefs.coverPath ?? metadata.coverArtFileName
        let lyricsRef = sidecarRefs.lyricsPath ?? metadata.lyricsFileName
        let mvRef = sidecarRefs.mvPath ?? item.sidecarHints?.mvPath ?? metadata.mvPath

        return Song(
            id: songID,
            title: metadata.title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: metadata.albumTitle,
            artistName: metadata.artist,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            fileFormat: format,
            filePath: item.path,
            sourceID: sourceID,
            fileSize: item.size,
            bitRate: metadata.bitRate,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            genre: metadata.genre,
            year: metadata.year,
            lastModified: item.modifiedDate,
            dateAdded: Date(),
            coverArtFileName: coverRef,
            lyricsFileName: lyricsRef,
            mvPath: mvRef,
            replayGainTrackGain: metadata.replayGainTrackGain,
            replayGainTrackPeak: metadata.replayGainTrackPeak,
            replayGainAlbumGain: metadata.replayGainAlbumGain,
            replayGainAlbumPeak: metadata.replayGainAlbumPeak,
            revision: item.revision
        )
    }

    private func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
