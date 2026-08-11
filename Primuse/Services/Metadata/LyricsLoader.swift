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
    /// Loads the closest available representation of the original editable
    /// document. Source text wins so LRC/ELRC metadata and blank lines survive
    /// editing; cached line models remain the offline fallback.
    static func loadEditableText(for song: Song, sourceManager: SourceManager) async -> String {
        if let sourceText = await loadSourceText(for: song, sourceManager: sourceManager) {
            return normalizedEditableText(sourceText)
        }
        return LyricsContentParser.serialize(await load(for: song, sourceManager: sourceManager))
    }

    /// Fetches only the authoritative source document. This deliberately does
    /// not fall back to local caches so callers can use it for conflict checks
    /// and post-write readback verification.
    static func loadSourceText(for song: Song, sourceManager: SourceManager) async -> String? {
        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            guard !Task.isCancelled else { return nil }

            if let server = connector as? ServerLyricsConnector {
                let capabilities = server.serverLyricsCapabilities
                if capabilities.canRead,
                   let raw = await server.fetchServerLyrics(for: song.filePath),
                   !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return raw
                }
                if !capabilities.supportsSiblingSidecarLookup {
                    return locallyMaterializedSourceText(for: song, sourceManager: sourceManager)
                }
            }

            let songDir = (song.filePath as NSString).deletingLastPathComponent
            let baseName = ((song.filePath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            let lrcPath: String
            if let ref = song.lyricsFileName, ref.contains("/") {
                lrcPath = ref
            } else {
                lrcPath = (songDir as NSString).appendingPathComponent("\(baseName).lrc")
            }
            let data = try await connector.fetchRange(
                path: lrcPath,
                offset: 0,
                length: 256 * 1024,
                priority: .background
            )
            guard !Task.isCancelled,
                  let raw = String(data: data, encoding: .utf8),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return raw
        } catch {
            // Fall through to a locally materialized source sidecar. This is
            // the authoritative document for local/imported sources and an
            // offline best effort for remote sources.
        }

        return locallyMaterializedSourceText(for: song, sourceManager: sourceManager)
    }

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
            if let server = connector as? ServerLyricsConnector {
                let capabilities = server.serverLyricsCapabilities
                if capabilities.canRead,
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
                if let online = await AppServices.shared.scraperService.fetchOnlineLyrics(
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

                // Media-server item IDs are opaque identifiers, not directory
                // paths. Never turn `/items/{id}` into a sibling `.lrc` fetch.
                if !capabilities.supportsSiblingSidecarLookup {
                    return []
                }
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

    private static func locallyMaterializedSourceText(
        for song: Song,
        sourceManager: SourceManager
    ) -> String? {
        guard let cachedAudioURL = sourceManager.cachedURL(for: song),
              let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
              let text = try? String(contentsOf: lrcURL, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func normalizedEditableText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
