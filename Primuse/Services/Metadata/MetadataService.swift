import Foundation
import PrimuseKit

actor MetadataService {
    private let onlineService = OnlineMetadataService()
    private let assetStore = MetadataAssetStore.shared

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
    func loadMetadata(for url: URL, cacheKey: String? = nil) async -> SongMetadata {
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

        if let cacheKey {
            if let coverArtData = result.coverArtData {
                result.coverArtFileName = await assetStore.storeCover(coverArtData, for: cacheKey)
            }
            if let lyrics = result.lyrics {
                result.lyricsFileName = await assetStore.storeLyrics(lyrics, for: cacheKey)
            }
        }

        return result
    }

    private func fetchOnlineMetadata(for result: inout SongMetadata) async {
        let settings = ScraperSettings.load()
        var matchedRecording: OnlineMetadataService.MusicBrainzRecording?

        if settings.musicBrainzMetadataEnabled {
            matchedRecording = try? await onlineService.searchRecording(
                title: result.title,
                artist: result.artist,
                album: result.albumTitle
            )

            if let recording = matchedRecording {
                if result.artist == nil {
                    result.artist = recording.primaryArtistName
                }
                if result.albumTitle == nil {
                    result.albumTitle = recording.releases?.first?.title
                }
                if result.year == nil {
                    result.year = recording.releaseYear
                }
                if result.genre == nil || result.genre?.isEmpty == true {
                    result.genre = recording.tags?
                        .compactMap(\.name)
                        .prefix(3)
                        .joined(separator: ", ")
                }
            }
        }

        // Fetch lyrics from LRCLIB
        if settings.lrclibLyricsEnabled, result.lyrics == nil, let artist = result.artist {
            result.lyrics = try? await onlineService.fetchLyrics(
                title: result.title,
                artist: artist,
                album: result.albumTitle,
                duration: result.duration
            )
        }

        // Fetch cover art from MusicBrainz + Cover Art Archive
        if settings.musicBrainzCoverEnabled, result.coverArtData == nil {
            if let releaseID = matchedRecording?.releases?.first?.id {
                result.coverArtData = try? await onlineService.fetchCoverArt(releaseID: releaseID)
            } else if let album = result.albumTitle, let artist = result.artist,
                      let release = try? await onlineService.searchMusicBrainz(artist: artist, album: album) {
                result.coverArtData = try? await onlineService.fetchCoverArt(releaseID: release.id)
            }
        }
    }
}
