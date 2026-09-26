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

    enum AuthoritativeSourceRead: Sendable {
        case content(String)
        case absent
        case unavailable
    }

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
        guard currentDocument?.first?.documentIsLocalOverride != true else {
            return .failedPreservingCache
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
                let raw: String
                switch await server.readServerLyrics(for: sourcePath) {
                case .content(let content):
                    raw = content
                case .absent:
                    return nil
                case .unavailable:
                    throw SourceError.connectionFailed("Lyrics source unavailable")
                }
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let parsed = LyricsParser.parseText(raw)
                return parsed.isEmpty ? nil : parsed
            },
            replace: { lines in
                let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                    lines,
                    forSongID: songID,
                    expectedFingerprint: capturedFingerprint,
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
            if LyricsContentParser.isTTML(normalized)
                || LyricsContentParser.isSubtitleDocument(normalized) {
                // The editor is intentionally LRC/ELRC-oriented. Converting
                // TTML and subtitle documents to the shared model keeps their
                // markup out of lyric rows; LyricsWriteback serializes it back
                // to TTML when appropriate, and a save of a read-only subtitle
                // document lands in a new `.lrc` beside it.
                return LyricsContentParser.serialize(LyricsContentParser.parse(normalized))
            }
            return normalized
        }
        return LyricsContentParser.serialize(await load(for: song, sourceManager: sourceManager))
    }

    /// Fetches only the authoritative source document. This deliberately does
    /// not expose transport failures as absence. Callers doing conflict checks
    /// or post-write verification must use `readAuthoritativeSourceText`
    /// directly instead of accepting the local materialized fallback.
    static func loadSourceText(for song: Song, sourceManager: SourceManager) async -> String? {
        switch await readAuthoritativeSourceText(for: song, sourceManager: sourceManager) {
        case .content(let content):
            return content
        case .absent, .unavailable:
            return locallyMaterializedSourceText(for: song, sourceManager: sourceManager)
        }
    }

    static func readAuthoritativeSourceText(
        for song: Song,
        sourceManager: SourceManager
    ) async -> AuthoritativeSourceRead {
        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            guard !Task.isCancelled else { return .unavailable }

            if let server = connector as? ServerLyricsConnector {
                let capabilities = server.serverLyricsCapabilities
                if capabilities.canRead {
                    switch await server.readServerLyrics(for: song.filePath) {
                    case .content(let raw)
                        where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        return .content(raw)
                    case .absent where !capabilities.supportsSiblingSidecarLookup:
                        return .absent
                    case .unavailable where !capabilities.supportsSiblingSidecarLookup:
                        return .unavailable
                    case .content, .absent, .unavailable:
                        break
                    }
                }
                if !capabilities.supportsSiblingSidecarLookup {
                    // The current connector API returns nil both for a missing
                    // document and for transport/authentication failures.
                    return .unavailable
                }
            }

            guard let lyricsFile = try await authoritativeLyricsFile(
                for: song,
                connector: connector
            ) else { return .absent }
            let data = try await connector.fetchRange(
                path: lyricsFile.path,
                offset: 0,
                length: lyricsFile.size,
                priority: .background
            )
            guard !Task.isCancelled,
                  data.count == Int(lyricsFile.size),
                  let raw = String(data: data, encoding: .utf8),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable
            }
            return .content(raw)
        } catch let error as SourceError {
            switch error {
            case .pathNotFound, .fileNotFound:
                return .absent
            case .connectionFailed, .credentialUnavailable, .authenticationFailed, .timeout:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    /// - Parameter allowsAutomaticOnlineLyrics: 普通源确实没有歌词时是否允许 Tier4 自动在线兜底。
    ///   播放类调用保持默认；歌词编辑器打开时传 false，免得多等一轮网络请求、把在线歌词预填成用户编辑。
    static func load(
        for song: Song,
        sourceManager: SourceManager,
        sourceType: MusicSourceType? = nil,
        allowsAutomaticOnlineLyrics: Bool = true
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
            let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                cached,
                forSongID: song.id,
                expectedFingerprint: nil,
                force: false
            )
            guard !Task.isCancelled else { return [] }
            let resolved = wrote
                ? cached
                : await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) ?? cached
            logLoaded(resolved, song: song, tier: "Tier1b")
            scheduleAutomaticSourceRefresh(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: resolved
            )
            return resolved
        }

        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            guard !Task.isCancelled else { return [] }
            let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                parsed,
                forSongID: song.id,
                expectedFingerprint: nil,
                force: false
            )
            guard !Task.isCancelled else { return [] }
            let resolved = wrote
                ? parsed
                : await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) ?? parsed
            logLoaded(resolved, song: song, tier: "Tier2")
            scheduleAutomaticSourceRefresh(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: resolved
            )
            return resolved
        }

        // 连接器已解析且不是服务端曲库源时才为 true：只有这种情况下「源里没有歌词」
        // 才是可信结论，可以进入 Tier4 在线兜底。连不上源不算。
        var resolvedPlainSource = false
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

                if sourceResult == .failedPreservingCache,
                   let latest = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) {
                    // A concurrent editor/scraper write won the CAS while the
                    // server request was in flight. Never route that conflict
                    // into an online fallback that could overwrite the winner.
                    return latest
                }

                // Only a confirmed source miss (not a transport/CAS failure)
                // may enter the title-based online fallback.
                if sourceResult == .emptyPreservingCache {
                    let onlineCacheSnapshot = await MetadataAssetStore.shared
                        .cachedLyrics(forSongID: song.id)
                    if allowsAutomaticOnlineLyrics(for: song),
                       let online = await AppServices.shared.scraperService.fetchOnlineLyrics(
                        title: song.title,
                        artist: song.artistName,
                        album: song.albumTitle,
                        duration: song.duration > 0 ? song.duration : nil
                    ), !online.isEmpty {
                    guard !Task.isCancelled else { return [] }
                    let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                        online,
                        forSongID: song.id,
                        expectedFingerprint: onlineCacheSnapshot.map(
                            LyricsDocumentFingerprint.init(lines:)
                        ),
                        force: false
                    )
                    guard !Task.isCancelled else { return [] }
                    guard wrote else {
                        return await MetadataAssetStore.shared.cachedLyrics(
                            forSongID: song.id
                        ) ?? []
                    }
                    logLoaded(online, song: song, tier: "Tier2d-online")
                    return online
                    }
                }

                // Media-server item IDs are opaque identifiers, not directory
                // paths. Never turn `/items/{id}` into a sibling `.lrc` fetch.
                if !capabilities.supportsSiblingSidecarLookup {
                    return []
                }
            }

            let isPlainSource = allowsAutomaticOnlineLyrics && !(connector is ServerLyricsConnector)
            resolvedPlainSource = isPlainSource

            guard let lyricsFile = try await authoritativeLyricsFile(
                for: song,
                connector: connector
            ) else {
                if isPlainSource { return await automaticOnlineFallback(for: song) }
                return []
            }
            let cacheSnapshot = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            let lyricsData = try await connector.fetchRange(
                path: lyricsFile.path,
                offset: 0,
                length: lyricsFile.size,
                priority: .background
            )
            guard !Task.isCancelled,
                  lyricsData.count == Int(lyricsFile.size) else { return [] }
            guard let lyricsContent = String(data: lyricsData, encoding: .utf8) else {
                if isPlainSource { return await automaticOnlineFallback(for: song) }
                return []
            }
            var parsed = LyricsParser.parse(lyricsContent)
            if !parsed.isEmpty {
                if let translation = lyricsFile.translation {
                    // The `-orig` track stays the sung line; its companion
                    // becomes the translation under each of those lines.
                    parsed = await mergingTranslationTrack(
                        into: parsed,
                        track: translation,
                        connector: connector
                    )
                    guard !Task.isCancelled else { return [] }
                }
                let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                    parsed,
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot.map(
                        LyricsDocumentFingerprint.init(lines:)
                    ),
                    force: false
                )
                guard !Task.isCancelled else { return [] }
                guard wrote else {
                    return await MetadataAssetStore.shared.cachedLyrics(
                        forSongID: song.id
                    ) ?? []
                }
                logLoaded(parsed, song: song, tier: "Tier3")
                return parsed
            }
        } catch {
            guard !Task.isCancelled else { return [] }
            // No .lrc — quietly return empty (after the Tier4 online attempt below).
        }
        if resolvedPlainSource {
            return await automaticOnlineFallback(for: song)
        }
        plog("📜 LyricsLoader '\(song.title)' empty")
        return []
    }

    /// 普通源确实没有歌词时的最后一站：Tier4 在线兜底，拿不到就按原样返回空。
    private static func automaticOnlineFallback(for song: Song) async -> [LyricLine] {
        if let online = await automaticOnlineLyrics(for: song, expectedFingerprint: nil) {
            guard !Task.isCancelled else { return [] }
            logLoaded(online, song: song, tier: "Tier4-online")
            return online
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

    static func locallyMaterializedSourceText(
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

    /// A subtitle track that translates the document being loaded.
    typealias TranslationTrack = (path: String, fileName: String, size: Int64)

    private struct AuthoritativeLyricsFile: Sendable {
        let path: String
        let size: Int64
        let translation: TranslationTrack?
    }

    private static func authoritativeLyricsFile(
        for song: Song,
        connector: any MusicSourceConnector
    ) async throws -> AuthoritativeLyricsFile? {
        let target = try await lyricsSidecarTarget(for: song, connector: connector)
        guard target.exists, let existingPath = target.existingPath else { return nil }
        let translation = translationTrack(in: target)
        let maximumSize = Int64(LyricsSidecarTargetPolicy.maximumContentByteCount)
        if let size = target.existingSize, size > 0, size <= maximumSize {
            return AuthoritativeLyricsFile(
                path: existingPath,
                size: size,
                translation: translation
            )
        }
        let matches = try await connector.listFiles(at: target.containerPath).filter {
            !$0.isDirectory
                && $0.path == existingPath
                && $0.name.caseInsensitiveCompare(target.fileName) == .orderedSame
        }
        guard matches.count == 1,
              let item = matches.first,
              item.size > 0,
              item.size <= maximumSize else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        return AuthoritativeLyricsFile(
            path: item.path,
            size: item.size,
            translation: translation
        )
    }

    private static func lyricsSidecarTarget(
        for song: Song,
        connector: any MusicSourceConnector
    ) async throws -> LyricsSidecarTarget {
        if let resolver = connector as? any LyricsSidecarTargetResolving {
            return try await resolver.lyricsSidecarTarget(for: song)
        }
        return try await LyricsSidecarTargetPolicy.resolve(for: song, using: connector)
    }

    private static func translationTrack(in target: LyricsSidecarTarget) -> TranslationTrack? {
        guard let path = target.translationPath,
              let fileName = target.translationFileName,
              let size = target.translationSize else { return nil }
        return (path, fileName, size)
    }

    /// The companion track of the song's current document, for a caller that
    /// fetched that document by name and has no listing of its own. Resolving
    /// it costs a directory listing, so the caller decides first — by the
    /// document's own name — whether one can exist at all.
    static func translationTrack(
        for song: Song,
        connector: any MusicSourceConnector
    ) async -> TranslationTrack? {
        guard let target = try? await lyricsSidecarTarget(for: song, connector: connector),
              target.exists else { return nil }
        return translationTrack(in: target)
    }

    /// Attaches a translation track to the lines that were just parsed.
    /// A companion that is too large, unreachable or not the same timeline is
    /// simply not attached: the original track is the song's document either
    /// way.
    static func mergingTranslationTrack(
        into primary: [LyricLine],
        track: TranslationTrack,
        connector: any MusicSourceConnector
    ) async -> [LyricLine] {
        guard track.size > 0,
              track.size <= Int64(LyricsSidecarTargetPolicy.maximumContentByteCount) else {
            return primary
        }
        let data: Data
        do {
            data = try await connector.fetchRange(
                path: track.path,
                offset: 0,
                length: track.size,
                priority: .background
            )
        } catch {
            return primary
        }
        guard data.count == Int(track.size),
              let content = String(data: data, encoding: .utf8) else { return primary }
        let translation = LyricsParser.parse(content)
        guard !translation.isEmpty else { return primary }
        let languageCode = LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: track.fileName)
            .flatMap { LyricsSidecarSelectionPolicy.translationLanguageCode(forTag: $0.tag) }
        return LyricsTranslationTrackPolicy.merging(
            primary: primary,
            translation: translation,
            languageCode: languageCode
        ) ?? primary
    }
}

// MARK: - Tier4: 普通源的自动在线歌词兜底

/// 同一进程内，每首歌 6 小时只自动问一次在线歌词，避免没歌词的歌每次播放都打一轮网络请求。手动刮削不经过这里。
actor AutomaticOnlineLyricsLedger {
    static let shared = AutomaticOnlineLyricsLedger()

    private static let cooldown: TimeInterval = 6 * 60 * 60
    private static let pruneThreshold = 2048

    private var lastAttempt: [String: Date] = [:]

    /// 最近 6 小时没问过就登记并返回 true；问过返回 false。
    func shouldAttempt(songID: String) -> Bool {
        let now = Date()
        if let previous = lastAttempt[songID],
           now.timeIntervalSince(previous) < Self.cooldown {
            return false
        }
        lastAttempt[songID] = now
        if lastAttempt.count > Self.pruneThreshold {
            lastAttempt = lastAttempt.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        }
        return true
    }
}

extension LyricsLoader {
    /// 在线歌词源按「标题+艺人」找歌词，有声内容的标题是「第 12 集」「Chapter 3」
    /// 这类章节名，搜到的只会是同名歌曲的歌词，和正在讲的内容毫无关系。所以有声
    /// 内容只认源里自带的（同目录 .lrc/.vtt/.srt、内嵌、服务端），自动在线查找
    /// 一律不走；用户在刮削页手动搜仍然可以。
    static func allowsAutomaticOnlineLyrics(for song: Song) -> Bool {
        !SpokenWordStore.shared.isSpokenWord(song)
    }

    /// Tier4：本地/网盘等普通源确实没有歌词时，按启用顺序向在线歌词源取一次并写入缓存。
    /// 开关关、没有启用的歌词源、台账说最近问过、任务被取消 → nil。
    static func automaticOnlineLyrics(
        for song: Song,
        expectedFingerprint: LyricsDocumentFingerprint?
    ) async -> [LyricLine]? {
        guard !Task.isCancelled else { return nil }
        guard allowsAutomaticOnlineLyrics(for: song) else { return nil }
        let settings = ScraperSettings.load()
        guard settings.autoFetchOnlineLyrics else { return nil }
        let hasLyricsServers = !LyricsAPIServerSettings.load().servers.isEmpty
        let hasUsableLyricsSource = settings.enabledSources.contains { config in
            guard config.type.supportsLyrics else { return false }
            // 歌词服务器源开着但一个地址都没填，等于没有。
            if config.type == .lyricsServer { return hasLyricsServers }
            return true
        }
        guard hasUsableLyricsSource else { return nil }
        guard await AutomaticOnlineLyricsLedger.shared.shouldAttempt(songID: song.id) else { return nil }
        guard !Task.isCancelled else { return nil }

        guard let online = await AppServices.shared.scraperService.fetchOnlineLyrics(
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            duration: song.duration > 0 ? song.duration : nil
        ), !online.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }

        let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
            online,
            forSongID: song.id,
            expectedFingerprint: expectedFingerprint,
            force: false
        )
        if wrote { return online }
        // 并发的编辑/刮削写入赢了：以最新缓存为准，不覆盖它。
        guard let latest = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id),
              !latest.isEmpty
        else { return nil }
        return latest
    }
}
