import Foundation
import PrimuseKit

actor MetadataService {
    private let onlineService = OnlineMetadataService()

    struct SongMetadata {
        var title: String
        var artist: String?
        var albumTitle: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var genre: String?
        var duration: TimeInterval
        var sampleRate: Int?
        var bitRate: Int?
        var bitDepth: Int?
        var coverArtData: Data?
        var coverArtFileName: String?
        var lyricsFileName: String?
        var lyrics: [LyricLine]?
    }

    /// Load metadata with priority: sidecar → embedded → online
    func loadMetadata(for url: URL) async -> SongMetadata {
        // 1. Read embedded metadata
        let embedded = await FileMetadataReader.read(from: url)

        var result = SongMetadata(
            title: embedded.title ?? url.deletingPathExtension().lastPathComponent,
            artist: embedded.artist,
            albumTitle: embedded.albumTitle,
            trackNumber: embedded.trackNumber,
            discNumber: embedded.discNumber,
            year: embedded.year,
            genre: embedded.genre,
            duration: embedded.duration ?? 0,
            sampleRate: embedded.sampleRate,
            bitRate: embedded.bitRate,
            bitDepth: embedded.bitDepth,
            coverArtData: embedded.coverArtData
        )

        // 2. Check sidecar files (higher priority for cover & lyrics)
        if let coverURL = SidecarMetadataLoader.findCoverArt(for: url) {
            result.coverArtFileName = coverURL.lastPathComponent
            if let data = try? Data(contentsOf: coverURL) {
                result.coverArtData = data
            }
        }

        if let lyricsURL = SidecarMetadataLoader.findLyrics(for: url) {
            result.lyricsFileName = lyricsURL.lastPathComponent
            result.lyrics = try? LyricsParser.parse(from: lyricsURL)
        }

        // 3. Try online sources as fallback
        if result.coverArtData == nil || result.lyrics == nil {
            await fetchOnlineMetadata(for: &result)
        }

        return result
    }

    private func fetchOnlineMetadata(for result: inout SongMetadata) async {
        guard let artist = result.artist else { return }

        // Fetch lyrics from LRCLIB
        if result.lyrics == nil {
            result.lyrics = try? await onlineService.fetchLyrics(
                title: result.title,
                artist: artist,
                album: result.albumTitle,
                duration: result.duration
            )
        }

        // Fetch cover art from MusicBrainz + Cover Art Archive
        if result.coverArtData == nil, let album = result.albumTitle {
            if let release = try? await onlineService.searchMusicBrainz(artist: artist, album: album) {
                result.coverArtData = try? await onlineService.fetchCoverArt(releaseID: release.id)
            }
        }
    }
}
