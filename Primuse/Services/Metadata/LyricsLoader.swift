import Foundation
import PrimuseKit

/// Same three-tier strategy as `NowPlayingView.loadLyrics()`, lifted into a
/// reusable helper so the desktop lyrics window can share it without
/// duplicating the (already non-trivial) sidecar / aux-connector logic.
///
/// Tier 1: in-process disk cache via `MetadataAssetStore`
/// Tier 2: sidecar `.lrc` next to the locally cached audio file
/// Tier 3: fetch `.lrc` from the source via an auxiliary connector
@MainActor
enum LyricsLoader {
    static func load(for song: Song, sourceManager: SourceManager) async -> [LyricLine] {
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) {
            return cached
        }
        if let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            return cached
        }

        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            return parsed
        }

        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            let songDir = (song.filePath as NSString).deletingLastPathComponent
            let baseName = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let lrcPath: String
            if let ref = song.lyricsFileName, ref.contains("/") {
                lrcPath = ref
            } else {
                lrcPath = (songDir as NSString).appendingPathComponent("\(baseName).lrc")
            }
            let lrcLocalURL = try await connector.localURL(for: lrcPath)
            let parsed = try LyricsParser.parse(from: lrcLocalURL)
            if !parsed.isEmpty {
                await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
                return parsed
            }
        } catch {
            // No .lrc — quietly return empty.
        }
        return []
    }
}
