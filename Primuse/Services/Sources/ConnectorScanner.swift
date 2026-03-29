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

    func scan(directories: [String]) -> AsyncThrowingStream<ScanUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await connector.connect()

                    // Phase 1: Count total audio files
                    var totalCount = 0
                    for directory in directories {
                        totalCount += (try? await connector.countAudioFiles(in: directory)) ?? 0
                    }

                    // Phase 2: Scan and extract metadata
                    var allSongs: [Song] = []
                    var scannedCount = 0

                    if let songConnector = connector as? any SongScanningConnector {
                        for directory in directories {
                            let stream = try await songConnector.scanSongs(from: directory)

                            for try await scannedSong in stream {
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

                    for directory in directories {
                        let stream = try await connector.scanAudioFiles(from: directory)

                        for try await item in stream {
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
                            let metadata = await metadataService.loadMetadata(for: localURL, cacheKey: songID)
                            allSongs.append(buildSong(from: item, metadata: metadata, songID: songID))

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

    private func buildSong(
        from item: RemoteFileItem,
        metadata: MetadataService.SongMetadata,
        songID: String
    ) -> Song {
        let artistID = metadata.artist.map { hash("\($0.lowercased())") }
        let albumID: String? = if let artist = metadata.artist, let album = metadata.albumTitle {
            hash("\(artist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        let format = AudioFormat.from(fileExtension: (item.name as NSString).pathExtension) ?? .mp3

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
            coverArtFileName: metadata.coverArtFileName,
            lyricsFileName: metadata.lyricsFileName
        )
    }

    private func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
