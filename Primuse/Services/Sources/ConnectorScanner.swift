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
                do {
                    try await connector.connect()

                    // Remove redundant child directories when a parent is already selected
                    let dirs = SynologyScanner.deduplicateDirectories(directories)

                    // Phase 1: Count total audio files
                    var totalCount = 0
                    for directory in dirs {
                        totalCount += (try? await connector.countAudioFiles(in: directory)) ?? 0
                    }

                    // Phase 2: Scan and extract metadata
                    var allSongs = existingSongs
                    let existingPaths = Set(existingSongs.map(\.filePath))
                    let initialCount = max(existingSongs.count, startingCount)
                    var scannedCount = totalCount > 0 ? min(initialCount, totalCount) : initialCount
                    var encounteredPaths: Set<String> = []
                    var hadDirectoryFailure = false

                    if !existingSongs.isEmpty {
                        continuation.yield(
                            ScanUpdate(
                                scannedCount: scannedCount,
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
                                    guard existingPaths.contains(scannedSong.song.filePath) == false else { continue }

                                    scannedCount += 1
                                    allSongs.append(scannedSong.song)

                                    continuation.yield(
                                        ScanUpdate(
                                            scannedCount: scannedCount,
                                            totalCount: totalCount,
                                            currentFile: scannedSong.displayName,
                                            songs: allSongs
                                        )
                                    )
                                }
                            } catch {
                                hadDirectoryFailure = true
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
                                totalCount: totalCount,
                                currentFile: "",
                                songs: allSongs
                            )
                        )
                        continuation.finish()
                        return
                    }

                    for directory in dirs {
                        do {
                            let stream = try await connector.scanAudioFiles(from: directory)

                            for try await item in stream {
                                encounteredPaths.insert(item.path)
                                guard existingPaths.contains(item.path) == false else { continue }

                                scannedCount += 1
                                continuation.yield(
                                    ScanUpdate(
                                        scannedCount: scannedCount,
                                        totalCount: totalCount,
                                        currentFile: item.name,
                                        songs: allSongs
                                    )
                                )

                                let localURL = try await connector.localURL(for: item.path)
                                let songID = hash("\(sourceID):\(item.path)")
                                // Extract metadata and cache embedded cover/lyrics to disk
                                let metadata = await metadataService.loadMetadata(
                                    for: localURL,
                                    cacheKey: songID,
                                    allowOnlineFetch: false
                                )
                                // Detect sidecar references on source
                                let sidecarRefs = detectSidecarRefs(for: item, localURL: localURL)
                                allSongs.append(buildSong(from: item, metadata: metadata, songID: songID, sidecarRefs: sidecarRefs))

                                if scannedCount % 3 == 0 {
                                    continuation.yield(
                                        ScanUpdate(
                                            scannedCount: scannedCount,
                                            totalCount: totalCount,
                                            currentFile: item.name,
                                            songs: allSongs
                                        )
                                    )
                                }
                            }
                        } catch {
                            hadDirectoryFailure = true
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
            lyricsFileName: lyricsRef
        )
    }

    private func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
