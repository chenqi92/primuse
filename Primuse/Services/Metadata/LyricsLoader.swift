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
            guard !Task.isCancelled else { return [] }
            logLoaded(cached, song: song, tier: "Tier1a")
            return cached
        }
        if let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            guard !Task.isCancelled else { return [] }
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            guard !Task.isCancelled else { return [] }
            logLoaded(cached, song: song, tier: "Tier1b")
            return cached
        }

        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            guard !Task.isCancelled else { return [] }
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            guard !Task.isCancelled else { return [] }
            logLoaded(parsed, song: song, tier: "Tier2")
            return parsed
        }

        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            guard !Task.isCancelled else { return [] }

            // Tier 2.5: 服务端歌词 (Subsonic getLyricsBySongId 等)。服务端不是
            // "同目录 .lrc" 模型, 走 connector 的 ServerLyricsConnector 能力。
            if let server = connector as? ServerLyricsConnector,
               let raw = await server.fetchServerLyrics(for: song.filePath) {
                guard !Task.isCancelled else { return [] }
                let parsed = LyricsParser.parseText(raw)
                if !parsed.isEmpty {
                    await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
                    guard !Task.isCancelled else { return [] }
                    logLoaded(parsed, song: song, tier: "Tier2c-server")
                    return parsed
                }
            }

            // A server-side lyrics miss (notably Airsonic's external provider
            // returning 404) should not stop the desktop/watch lyrics path.
            // Reuse the title-safe online scraper and keep the result in the
            // read-only local metadata overlay keyed by this song ID.
            if connector is ServerLyricsConnector,
               let online = await AppServices.shared.scraperService.fetchOnlineLyrics(
                   title: song.title,
                   artist: song.artistName,
                   album: song.albumTitle,
                   duration: song.duration > 0 ? song.duration : nil
               ), !online.isEmpty {
                guard !Task.isCancelled else { return [] }
                _ = await MetadataAssetStore.shared.cacheLyrics(
                    online,
                    forSongID: song.id,
                    force: true
                )
                guard !Task.isCancelled else { return [] }
                logLoaded(online, song: song, tier: "Tier2d-online")
                return online
            }

            let songDir = (song.filePath as NSString).deletingLastPathComponent
            let baseName = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let lrcPath: String
            if let ref = song.lyricsFileName, ref.contains("/") {
                lrcPath = ref
            } else {
                lrcPath = (songDir as NSString).appendingPathComponent("\(baseName).lrc")
            }
            let lrcData = try await connector.fetchRange(
                path: lrcPath,
                offset: 0,
                length: 256 * 1024,
                priority: .background
            )
            guard !Task.isCancelled else { return [] }
            guard let lrcContent = String(data: lrcData, encoding: .utf8) else {
                return []
            }
            let parsed = LyricsParser.parse(lrcContent)
            if !parsed.isEmpty {
                await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
                guard !Task.isCancelled else { return [] }
                logLoaded(parsed, song: song, tier: "Tier3")
                return parsed
            }
        } catch {
            guard !Task.isCancelled else { return [] }
            // No .lrc — quietly return empty.
        }
        plog("📜 LyricsLoader '\(song.title)' empty")
        return []
    }

    private static func logLoaded(_ lines: [LyricLine], song: Song, tier: String) {
        let wordLevelCount = lines.filter { $0.isWordLevel }.count
        plog("📜 LyricsLoader '\(song.title)' \(tier) lines=\(lines.count) wordLevelLines=\(wordLevelCount) firstSyllables=\(lines.first?.syllables?.count ?? -1)")
    }
}
