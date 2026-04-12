import CryptoKit
import Foundation
import PrimuseKit

struct ScanProgress: Sendable {
    let sourceID: String
    let sourceName: String
    let filesScanned: Int
    let totalFiles: Int?
    let currentFile: String
    let phase: Phase

    enum Phase: Sendable {
        case discovering
        case scanning
        case complete
        case failed(String)
    }
}

actor LibraryScanner {
    private let database: LibraryDatabase
    private let metadataService: MetadataService

    init(database: LibraryDatabase, metadataService: MetadataService) {
        self.database = database
        self.metadataService = metadataService
    }

    func scan(
        source: MusicSource,
        connector: any MusicSourceConnector
    ) -> AsyncThrowingStream<ScanProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await connector.connect()

                    continuation.yield(ScanProgress(
                        sourceID: source.id,
                        sourceName: source.name,
                        filesScanned: 0,
                        totalFiles: nil,
                        currentFile: "",
                        phase: .discovering
                    ))

                    let audioFiles = try await connector.scanAudioFiles(from: "/")
                    var scannedCount = 0

                    for try await file in audioFiles {
                        scannedCount += 1

                        continuation.yield(ScanProgress(
                            sourceID: source.id,
                            sourceName: source.name,
                            filesScanned: scannedCount,
                            totalFiles: nil,
                            currentFile: file.name,
                            phase: .scanning
                        ))

                        let localURL = try await connector.localURL(for: file.path)
                        let songID = generateID(sourceID: source.id, path: file.path)
                        let metadata = await metadataService.loadMetadata(
                            for: localURL,
                            cacheKey: songID,
                            allowOnlineFetch: false
                        )
                        let artistID = metadata.artist.map { generateArtistID(name: $0) }
                        let albumID: String? = if let album = metadata.albumTitle, let artist = metadata.artist {
                            generateAlbumID(artist: artist, album: album)
                        } else {
                            nil
                        }

                        let format = AudioFormat.from(fileExtension: (file.name as NSString).pathExtension) ?? .mp3

                        let song = Song(
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
                            filePath: file.path,
                            sourceID: source.id,
                            fileSize: file.size,
                            bitRate: metadata.bitRate,
                            sampleRate: metadata.sampleRate,
                            bitDepth: metadata.bitDepth,
                            genre: metadata.genre,
                            year: metadata.year,
                            lastModified: file.modifiedDate,
                            coverArtFileName: metadata.coverArtFileName,
                            lyricsFileName: metadata.lyricsFileName
                        )

                        try await database.saveSong(song)

                        // Upsert artist
                        if let artistID, let artistName = metadata.artist {
                            let artist = Artist(id: artistID, name: artistName)
                            try await database.saveArtist(artist)
                        }

                        // Upsert album
                        if let albumID, let albumTitle = metadata.albumTitle {
                            let album = Album(
                                id: albumID,
                                title: albumTitle,
                                artistID: artistID,
                                artistName: metadata.artist,
                                year: metadata.year,
                                genre: metadata.genre,
                                sourceID: source.id
                            )
                            try await database.saveAlbum(album)
                        }
                    }

                    continuation.yield(ScanProgress(
                        sourceID: source.id,
                        sourceName: source.name,
                        filesScanned: scannedCount,
                        totalFiles: scannedCount,
                        currentFile: "",
                        phase: .complete
                    ))

                    continuation.finish()
                } catch {
                    continuation.yield(ScanProgress(
                        sourceID: source.id,
                        sourceName: source.name,
                        filesScanned: 0,
                        totalFiles: nil,
                        currentFile: "",
                        phase: .failed(error.localizedDescription)
                    ))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func generateID(sourceID: String, path: String) -> String {
        let input = "\(sourceID):\(path)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func generateArtistID(name: String) -> String {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = SHA256.hash(data: Data(normalized.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func generateAlbumID(artist: String, album: String) -> String {
        let input = "\(artist.lowercased()):\(album.lowercased())"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
