import CryptoKit
import Foundation
import PrimuseKit

actor ConnectorScanner {
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
        AsyncThrowingStream { continuation in
            Task {
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
                    var existingByPath: [String: Song] = [:]
                    existingByPath.reserveCapacity(existingSongs.count)
                    for song in existingSongs { existingByPath[song.filePath] = song }
                    var allSongIndexByPath: [String: Int] = [:]
                    allSongIndexByPath.reserveCapacity(existingSongs.count)
                    for (i, song) in allSongs.enumerated() { allSongIndexByPath[song.filePath] = i }
                    let initialCount = max(existingSongs.count, startingCount)
                    var scannedCount = totalCount > 0 ? min(initialCount, totalCount) : initialCount
                    var addedCount = 0
                    var encounteredPaths: Set<String> = []
                    var hadDirectoryFailure = false

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
                            do {
                                let stream = try await songConnector.scanSongs(from: directory)

                                for try await scannedSong in stream {
                                    encounteredPaths.insert(scannedSong.song.filePath)
                                    if let existing = existingByPath[scannedSong.song.filePath] {
                                        // Same path can either be the same file (skip) or
                                        // a remote replacement (refresh). Decide on size
                                        // first since lastModified isn't always populated.
                                        if !songContentChanged(existing: existing, incoming: scannedSong.song) {
                                            continue
                                        }
                                        // Replaced — overwrite the entry already in
                                        // allSongs so the next library flush sees the
                                        // fresh size/mtime/sidecars instead of merging
                                        // back to stale metadata.
                                        if let idx = allSongIndexByPath[scannedSong.song.filePath] {
                                            allSongs[idx] = scannedSong.song
                                        }
                                        existingByPath[scannedSong.song.filePath] = scannedSong.song
                                        continue
                                    }

                                    scannedCount += 1
                                    addedCount += 1
                                    allSongs.append(scannedSong.song)
                                    allSongIndexByPath[scannedSong.song.filePath] = allSongs.count - 1

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
                            } catch {
                                hadDirectoryFailure = true
                                plog("⚠️ Failed to scan directory \(directory): \(error)")
                                NSLog("⚠️ Failed to scan directory \(directory): \(error.localizedDescription)")
                                continue
                            }
                        }

                        if !hadDirectoryFailure {
                            allSongs.removeAll { encounteredPaths.contains($0.filePath) == false }
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

                    // Phase A: walk the tree, build "bare" Songs (filename + path
                    // + size + sidecar hints from sibling listing). Skip the full
                    // file download + ID3 extraction — that work is deferred to
                    // MetadataBackfillService which fetches just the first 256KB
                    // via HTTP Range. This drops scan time from minutes (and 11GB
                    // of egress on a 2200-song cloud library) to seconds.
                    for directory in dirs {
                        do {
                            let stream = try await connector.scanAudioFiles(from: directory)

                            for try await item in stream {
                                encounteredPaths.insert(item.path)
                                let songID = hash("\(sourceID):\(item.path)")

                                if let existing = existingByPath[item.path] {
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
                                    if !(sizeChanged || mtimeChanged || revisionChanged || revisionAdded || mtimeAdded) {
                                        continue
                                    }
                                    let refreshed = buildBareSong(from: item, songID: songID)
                                    if let idx = allSongIndexByPath[item.path] {
                                        allSongs[idx] = refreshed
                                    }
                                    existingByPath[item.path] = refreshed
                                    continue
                                }

                                allSongs.append(buildBareSong(from: item, songID: songID))
                                allSongIndexByPath[item.path] = allSongs.count - 1
                                scannedCount += 1
                                addedCount += 1

                                // Yield progress every 20 items — yielding on every
                                // file made the SwiftUI publisher chain the bottleneck
                                // when scanning fast cloud listings.
                                if addedCount % 20 == 0 {
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
                        } catch {
                            hadDirectoryFailure = true
                            plog("⚠️ Failed to scan directory \(directory): \(error)")
                            NSLog("⚠️ Failed to scan directory \(directory): \(error.localizedDescription)")
                            continue
                        }
                    }

                    if !hadDirectoryFailure {
                        allSongs.removeAll { encounteredPaths.contains($0.filePath) == false }
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
        // First-time fingerprint/mtime backfill — not a content change,
        // but still needs to flow through addSongs so the merge path
        // refreshes existing.revision / existing.lastModified. Without
        // this, a connector that newly surfaces revision would see its
        // updates dropped at the scanner boundary and never reach the
        // library, leaving same-size overwrite detection permanently
        // blind on existing rows.
        let revisionAdded = incoming.revision != nil && existing.revision == nil
        let mtimeAdded = incoming.lastModified != nil && existing.lastModified == nil
        return sizeChanged || mtimeChanged || revisionChanged || revisionAdded || mtimeAdded
    }

    private struct SidecarRefs {
        var coverPath: String?   // e.g. /Music/Album/cover.jpg
        var lyricsPath: String?  // e.g. /Music/Album/song.lrc
    }

    /// Detect sidecar files (cover art, lyrics) by checking the local file's directory.
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

        return refs
    }

    /// Build a Song with no metadata extraction — title is the filename, all
    /// metadata fields (artist, album, duration, bitRate, etc.) are nil. The
    /// MetadataBackfillService is responsible for filling these in later by
    /// reading just the file's header via HTTP Range.
    private func buildBareSong(from item: RemoteFileItem, songID: String) -> Song {
        let format = AudioFormat.from(fileExtension: (item.name as NSString).pathExtension) ?? .mp3
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

        // Title always from filename (more reliable than embedded metadata)
        let fileBaseName = (item.name as NSString).deletingPathExtension

        // Priority: sidecar path > embedded/cached > nil
        let coverRef = sidecarRefs.coverPath ?? metadata.coverArtFileName
        let lyricsRef = sidecarRefs.lyricsPath ?? metadata.lyricsFileName

        return Song(
            id: songID,
            title: fileBaseName,
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
            revision: item.revision
        )
    }

    private func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
