import Foundation
import PrimuseKit

/// Same three-tier strategy as `NowPlayingView.loadLyrics()`, lifted into a
/// reusable helper so the desktop lyrics window can share it without
/// duplicating the (already non-trivial) sidecar / aux-connector logic.
///
/// Tier 1: in-process disk cache via `MetadataAssetStore`
/// Tier 2: a supported lyrics sidecar next to the locally cached audio file
/// Tier 3: fetch the source lyrics sidecar via an auxiliary connector
@MainActor
enum LyricsLoader {
    private static let sourceRefreshCoordinator = LyricsSourceRefreshCoordinator()

    /// Revalidates only against the source server's own lyrics document. It
    /// never enters the title-based online scraping path used by ordinary
    /// first-load fallback, so an explicit source reload cannot mis-attribute
    /// another song's lyrics.
    static func refreshFromSource(
        for song: Song,
        sourceType: MusicSourceType?,
        sourceManager: SourceManager,
        cachedDocument: [LyricLine]? = nil,
        trigger: LyricsSourceRefreshTrigger
    ) async -> LyricsSourceRefreshResult {
        guard LyricsAuthoritativeSourcePolicy.supportsServerDocument(sourceType) else {
            return .unsupported
        }

        let connector: any MusicSourceConnector
        do {
            connector = try await sourceManager.auxiliaryConnector(for: song)
        } catch {
            return .failedPreservingCache
        }
        guard let server = connector as? any ServerLyricsConnector,
              server.serverLyricsCapabilities.canRead else {
            return .unsupported
        }

        return await refreshFromResolvedServer(
            for: song,
            server: server,
            cachedDocument: cachedDocument,
            trigger: trigger
        )
    }

    /// Routes every server-document fetch, including ordinary cache misses,
    /// through the same per-source/song single-flight coordinator.
    static func refreshFromResolvedServer(
        for song: Song,
        server: any ServerLyricsConnector,
        cachedDocument: [LyricLine]? = nil,
        trigger: LyricsSourceRefreshTrigger
    ) async -> LyricsSourceRefreshResult {
        guard server.serverLyricsCapabilities.canRead else { return .unsupported }

        let currentDocument: [LyricLine]?
        if let cachedDocument {
            currentDocument = cachedDocument
        } else {
            currentDocument = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
        }
        let songID = song.id
        let sourcePath = song.filePath
        let capturedFingerprint = currentDocument.map {
            LyricsDocumentFingerprint(lines: $0)
        }

        return await sourceRefreshCoordinator.refresh(
            key: LyricsSourceRefreshKey(sourceID: song.sourceID, songID: songID),
            currentDocument: currentDocument,
            trigger: trigger,
            fetch: {
                guard let raw = await server.fetchServerLyrics(for: sourcePath),
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let parsed = LyricsParser.parseText(raw)
                return parsed.isEmpty ? nil : parsed
            },
            replace: { lines in
                let latest = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID)
                let latestFingerprint = latest.map {
                    LyricsDocumentFingerprint(lines: $0)
                }
                guard latestFingerprint == capturedFingerprint else {
                    return false
                }
                let wrote = await MetadataAssetStore.shared.cacheLyrics(
                    lines,
                    forSongID: songID,
                    force: trigger != .automatic
                )
                if wrote {
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .primuseLyricsDidChange,
                            object: songID
                        )
                    }
                }
                return wrote
            }
        )
    }

    /// Loads the closest available representation of the original editable
    /// document. Source text wins so LRC/ELRC metadata and blank lines survive
    /// editing; cached line models remain the offline fallback.
    static func loadEditableText(for song: Song, sourceManager: SourceManager) async -> String {
        if let sourceText = await loadSourceText(for: song, sourceManager: sourceManager) {
            let normalized = normalizedEditableText(sourceText)
            if LyricsContentParser.isTTML(normalized) {
                // The editor is intentionally LRC/ELRC-oriented. Converting
                // TTML to the shared model keeps XML markup out of lyric rows;
                // LyricsWriteback serializes it back to TTML when appropriate.
                return LyricsContentParser.serialize(LyricsContentParser.parse(normalized))
            }
            return normalized
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

            let lyricsPath = try await lyricsSourcePath(for: song, connector: connector)
            let data = try await connector.fetchRange(
                path: lyricsPath,
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

    static func load(
        for song: Song,
        sourceManager: SourceManager,
        sourceType: MusicSourceType? = nil
    ) async -> [LyricLine] {
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) {
            guard !Task.isCancelled else { return [] }
            logLoaded(cached, song: song, tier: "Tier1a")
            scheduleAutomaticSourceRefresh(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: cached
            )
            return cached
        }
        if let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            guard !Task.isCancelled else { return [] }
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            guard !Task.isCancelled else { return [] }
            logLoaded(cached, song: song, tier: "Tier1b")
            scheduleAutomaticSourceRefresh(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: cached
            )
            return cached
        }

        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            guard !Task.isCancelled else { return [] }
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            guard !Task.isCancelled else { return [] }
            logLoaded(parsed, song: song, tier: "Tier2")
            scheduleAutomaticSourceRefresh(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: parsed
            )
            return parsed
        }

        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            guard !Task.isCancelled else { return [] }

            // Tier 2.5: 服务端歌词 (Subsonic getLyricsBySongId 等)。服务端不是
            // "同目录 .lrc" 模型, 走 connector 的 ServerLyricsConnector 能力。
            if let server = connector as? ServerLyricsConnector {
                let capabilities = server.serverLyricsCapabilities
                let sourceResult = await refreshFromResolvedServer(
                    for: song,
                    server: server,
                    trigger: .initial
                )
                guard !Task.isCancelled else { return [] }
                if case let .updated(parsed) = sourceResult {
                    logLoaded(parsed, song: song, tier: "Tier2c-server")
                    return parsed
                }
                if sourceResult == .unchanged,
                   let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) {
                    logLoaded(cached, song: song, tier: "Tier2c-server-shared")
                    return cached
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

            let lyricsPath = try await lyricsSourcePath(for: song, connector: connector)
            let lyricsData = try await connector.fetchRange(
                path: lyricsPath,
                offset: 0,
                length: 256 * 1024,
                priority: .background
            )
            guard !Task.isCancelled else { return [] }
            guard let lyricsContent = String(data: lyricsData, encoding: .utf8) else {
                return []
            }
            let parsed = LyricsParser.parse(lyricsContent)
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

    private static func scheduleAutomaticSourceRefresh(
        for song: Song,
        sourceType: MusicSourceType?,
        sourceManager: SourceManager,
        cachedDocument: [LyricLine]
    ) {
        guard LyricsAuthoritativeSourcePolicy.supportsServerDocument(sourceType) else { return }
        Task { @MainActor in
            _ = await refreshFromSource(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: cachedDocument,
                trigger: .automatic
            )
        }
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

    private static func lyricsSourcePath(
        for song: Song,
        connector: any MusicSourceConnector
    ) async throws -> String {
        if let resolver = connector as? any LyricsSidecarTargetResolving {
            return try await resolver.lyricsSidecarTarget(for: song).targetPath
        }
        let songDir = (song.filePath as NSString).deletingLastPathComponent
        let baseName = ((song.filePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        if let ref = song.lyricsFileName, ref.contains("/") {
            return ref
        }
        return (songDir as NSString).appendingPathComponent("\(baseName).lrc")
    }
}
