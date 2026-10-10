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
                || LyricsContentParser.isSubtitleDocument(normalized)
                || WordTimedLyricsParser.detect(normalized) != nil {
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
                connector: connector,
                evaluatesTimingFirst: true
            ) else { return .absent }
            let data = try await connector.fetchRange(
                path: lyricsFile.path,
                offset: 0,
                length: lyricsFile.size,
                priority: .background
            )
            guard !Task.isCancelled,
                  data.count == Int(lyricsFile.size),
                  let raw = LyricsParser.decodeText(data, label: (lyricsFile.path as NSString).lastPathComponent),
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
            if !LyricsAuthoritativeSourcePolicy.supportsServerDocument(sourceType) {
                Task { @MainActor in
                    _ = await recheckSourceDocument(
                        for: song,
                        sourceManager: sourceManager,
                        cachedDocument: cached
                    )
                }
            }
            return cached
        }
        let isPinned = readsPinnedDocument(song)
        if !isPinned,
           let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
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

        // 播客单集不在任何音乐源里:文字只来自 feed 里的 `<podcast:transcript>`。
        if PodcastPlaybackSong.isEpisode(song) {
            return await PodcastTranscriptLoader.lines(for: song)
        }

        // Apple Music: 只有用户导入 Music.app 的本机文件读得到歌词 (内嵌标签)。
        if song.sourceID == AppleMusicLibraryIdentity.sourceID {
            if let embedded = await AppServices.shared.appleMusicLibrary.fetchLyrics(for: song),
               !embedded.isEmpty {
                guard !Task.isCancelled else { return [] }
                let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                    embedded,
                    forSongID: song.id,
                    expectedFingerprint: nil,
                    force: false
                )
                guard !Task.isCancelled else { return [] }
                let resolved = wrote
                    ? embedded
                    : await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) ?? embedded
                logLoaded(resolved, song: song, tier: "AppleMusic-embedded")
                return resolved
            }
            guard !Task.isCancelled else { return [] }
        }

        if !isPinned,
           usesAudioCacheSidecar(for: song),
           let cachedAudioURL = sourceManager.cachedURL(for: song),
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
                    if songAcceptsAutomaticOnlineLyrics(song),
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
            guard let lyricsContent = LyricsParser.decodeText(lyricsData, label: (lyricsFile.path as NSString).lastPathComponent) else {
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
                let displayed = parsed
                Task { @MainActor in
                    _ = await upgradeToTimingPreferredDocument(
                        for: song,
                        connector: connector,
                        displayed: displayed,
                        displayedFileName: lyricsFile.fileName,
                        documents: lyricsFile.documents,
                        baseName: lyricsFile.songBaseName
                    )
                }
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
        if let embedded = await embeddedFallbackLyrics(for: song) {
            return embedded
        }
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

    /// 已经核对过源里歌词文件的歌。每首歌每次启动只核对一次。
    private static var sourceDocumentRecheckKeys: Set<String> = []

    /// 缓存命中后每首歌每次启动核对一次源里的歌词文件:
    /// - 缓存还不是逐字的(没时间轴的多半是早先存下的内嵌歌词): 读歌旁边当前那份歌词文件
    ///   (几份并存时按时间轴精度自动挑), 时间轴更细就换掉缓存;
    /// - 歌旁边一份歌词文件都没有了, 而读标签时留着这首的内嵌歌词: 换回内嵌歌词。
    /// 换了就通知各处歌词视图, 并把新歌词返回给调用方。
    static func recheckSourceDocument(
        for song: Song,
        sourceManager: SourceManager,
        cachedDocument: [LyricLine]
    ) async -> [LyricLine]? {
        guard !song.isCueTrack,
              !song.isStreamDescriptor,
              !PodcastPlaybackSong.isEpisode(song),
              song.sourceID != AppleMusicLibraryIdentity.sourceID,
              !cachedDocument.isEmpty,
              cachedDocument.first?.documentIsLocalOverride != true else {
            return nil
        }
        let recheckKey = "\(song.sourceID)\u{1F}\(song.id)"
        guard !sourceDocumentRecheckKeys.contains(recheckKey) else { return nil }
        let embedded = await MetadataAssetStore.shared.embeddedFallbackLyrics(forSongID: song.id)
        // 没时间轴的缓存按歌上的歌词引用只核对一次; 留着内嵌备用的歌(旁边有过歌词文件)
        // 每次启动都看一眼那份文件还在不在。
        let reference = song.lyricsFileName ?? ""
        let checkedReference = await MetadataAssetStore.shared.sourceRecheckReference(forSongID: song.id)
        let rechecksPlainCache = EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: cachedDocument)
            && checkedReference != reference
        guard rechecksPlainCache || embedded != nil,
              sourceDocumentRecheckKeys.insert(recheckKey).inserted else { return nil }
        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            guard !(connector is ServerLyricsConnector) else { return nil }
            let replacement: [LyricLine]
            let forced: Bool
            let lyricsFile = try await authoritativeLyricsFile(
                for: song,
                connector: connector,
                evaluatesTimingFirst: true
            )
            if lyricsFile == nil {
                // 列过目录, 确实一份歌词文件都没有。
                await MetadataAssetStore.shared.recordSourceRecheck(reference: reference, forSongID: song.id)
            }
            if let lyricsFile {
                let data = try await connector.fetchRange(
                    path: lyricsFile.path,
                    offset: 0,
                    length: lyricsFile.size,
                    priority: .background
                )
                guard !Task.isCancelled,
                      data.count == Int(lyricsFile.size),
                      let text = LyricsParser.decodeText(
                        data,
                        label: (lyricsFile.path as NSString).lastPathComponent
                      ) else { return nil }
                await MetadataAssetStore.shared.recordSourceRecheck(reference: reference, forSongID: song.id)
                var parsed = LyricsParser.parse(text)
                guard EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(
                    cached: cachedDocument,
                    with: parsed
                ) else { return nil }
                if let translation = lyricsFile.translation {
                    parsed = await mergingTranslationTrack(
                        into: parsed,
                        track: translation,
                        connector: connector
                    )
                }
                replacement = parsed
                forced = false
            } else if let embedded,
                      LyricsDocumentFingerprint(lines: embedded)
                        != LyricsDocumentFingerprint(lines: cachedDocument) {
                // 歌词文件被删了: 缓存里是那份文件留下的, 不分时间轴粗细都换回内嵌歌词。
                replacement = embedded
                forced = true
            } else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                replacement,
                forSongID: song.id,
                expectedFingerprint: LyricsDocumentFingerprint(lines: cachedDocument),
                force: forced
            )
            guard wrote else { return nil }
            logLoaded(replacement, song: song, tier: forced ? "embedded-after-sidecar-removed" : "Tier3-recheck")
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
            return replacement
        } catch {
            plog("📜 LyricsLoader '\(song.title)' sidecar recheck skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// 读标签时因为歌旁边有歌词文件而没进缓存的内嵌歌词。源里读不到歌词文件时先用它,
    /// 再去在线找; 用上了就写进缓存, 下次直接命中。
    static func embeddedFallbackLyrics(for song: Song) async -> [LyricLine]? {
        guard let embedded = await MetadataAssetStore.shared.embeddedFallbackLyrics(forSongID: song.id),
              !Task.isCancelled else { return nil }
        let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
            embedded,
            forSongID: song.id,
            expectedFingerprint: nil,
            force: false
        )
        guard !Task.isCancelled else { return nil }
        let resolved = wrote
            ? embedded
            : await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) ?? embedded
        logLoaded(resolved, song: song, tier: "embedded-fallback")
        return resolved
    }

    /// 同一首歌旁边有几份歌词文件、又没有人选定时, 每次启动比一次各份的时间轴精度,
    /// 把最细的那份记成自动选定(`LyricsDocumentPinStore.effectiveFileName`), 播放、
    /// 歌词来源页、编辑器与保存都按它读。这里自己列一次目录, 给不赶时间的调用方用。
    static func refreshAutomaticDocumentPick(
        for song: Song,
        connector: any MusicSourceConnector
    ) async {
        guard needsAutomaticDocumentPick(for: song, connector: connector),
              let target = try? await lyricsSidecarTarget(
                for: song,
                connector: connector,
                request: .catalog(pinned: nil)
              ) else { return }
        _ = await evaluateAutomaticDocumentPick(
            for: song,
            documents: target.documents,
            baseName: target.songBaseName,
            connector: connector
        )
    }

    /// 歌词已经按当前那份显示出来以后在后台比: 有时间轴更细的另一份就换上它,
    /// 写进缓存并通知各处歌词视图。已经是逐字的不比。`documents` 为 nil 时自己列目录。
    static func upgradeToTimingPreferredDocument(
        for song: Song,
        connector: any MusicSourceConnector,
        displayed: [LyricLine],
        displayedFileName: String? = nil,
        documents: [LyricsSidecarDocument]? = nil,
        baseName: String? = nil
    ) async -> [LyricLine]? {
        guard LyricsTimingLevel(lines: displayed) < .word,
              needsAutomaticDocumentPick(for: song, connector: connector) else { return nil }
        let listedDocuments: [LyricsSidecarDocument]
        let listedBaseName: String?
        if let documents {
            listedDocuments = documents
            listedBaseName = baseName
        } else {
            guard let target = try? await lyricsSidecarTarget(
                for: song,
                connector: connector,
                request: .catalog(pinned: nil)
            ) else { return nil }
            listedDocuments = target.documents
            listedBaseName = target.songBaseName
        }
        guard let pick = await evaluateAutomaticDocumentPick(
            for: song,
            documents: listedDocuments,
            baseName: listedBaseName,
            connector: connector
        ),
              displayedFileName.map({ pick.name.caseInsensitiveCompare($0) != .orderedSame }) ?? true,
              EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: displayed, with: pick.lines),
              !Task.isCancelled else { return nil }
        let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
            pick.lines,
            forSongID: song.id,
            expectedFingerprint: LyricsDocumentFingerprint(lines: displayed),
            force: false
        )
        guard wrote else { return nil }
        logLoaded(pick.lines, song: song, tier: "Tier3-timing-upgrade")
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
        return pick.lines
    }

    private static func needsAutomaticDocumentPick(
        for song: Song,
        connector: any MusicSourceConnector
    ) -> Bool {
        let store = LyricsDocumentPinStore.shared
        return !song.isCueTrack
            && store.pinnedFileName(forSongID: song.id) == nil
            && !store.hasEvaluatedAutomaticPick(forSongID: song.id)
            && !(connector is ServerLyricsConnector)
    }

    /// 只有一份时不读任何文件就下结论; 几份并存才逐份读来比。选了别的就把那份的歌词
    /// 一起返回, 调用方不用再读一遍。
    private static func evaluateAutomaticDocumentPick(
        for song: Song,
        documents: [LyricsSidecarDocument],
        baseName: String?,
        connector: any MusicSourceConnector
    ) async -> (name: String, lines: [LyricLine])? {
        let store = LyricsDocumentPinStore.shared
        guard documents.count > 1 else {
            store.setAutomaticPick(nil, forSongID: song.id)
            return nil
        }
        var parsedDocuments: [[LyricLine]?] = []
        for (index, document) in documents.enumerated() {
            parsedDocuments.append(index < maximumComparedDocumentCount
                ? await readDocument(document, connector: connector)
                : nil)
        }
        let levels = parsedDocuments.map { $0.map(LyricsTimingLevel.init(lines:)) }
        // 一份都没读到(多半是网络), 这次不下结论, 下次再比。
        guard !Task.isCancelled, levels.contains(where: { $0 != nil }) else { return nil }
        let preferred = LyricsSidecarSelectionPolicy.timingPreferredDocument(
            baseName: baseName
                ?? ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension,
            names: documents.map(\.name),
            levels: levels
        )
        store.setAutomaticPick(preferred.map { documents[$0].name }, forSongID: song.id)
        guard let preferred, let lines = parsedDocuments[preferred] else { return nil }
        plog("📜 LyricsLoader '\(song.title)' prefers \(documents[preferred].name) by timing")
        return (documents[preferred].name, lines)
    }

    private static let maximumComparedDocumentCount = 6

    private static func readDocument(
        _ document: LyricsSidecarDocument,
        connector: any MusicSourceConnector
    ) async -> [LyricLine]? {
        guard document.size > 0,
              document.size <= Int64(LyricsSidecarTargetPolicy.maximumContentByteCount),
              let data = try? await connector.fetchRange(
                path: document.path,
                offset: 0,
                length: document.size,
                priority: .background
              ),
              let text = LyricsParser.decodeText(data, label: document.name) else { return nil }
        let lines = LyricsParser.parse(text)
        return lines.isEmpty ? nil : lines
    }

    private static func logLoaded(_ lines: [LyricLine], song: Song, tier: String) {
        let wordLevelCount = lines.filter { $0.isWordLevel }.count
        plog("📜 LyricsLoader '\(song.title)' \(tier) lines=\(lines.count) wordLevelLines=\(wordLevelCount) firstSyllables=\(lines.first?.syllables?.count ?? -1)")
    }

    /// The audio cache holds one file per image, named after it, so a lyrics
    /// file beside it can only be the image's album-wide document. A CUE
    /// virtual track the scanner matched to its own lyric file must read
    /// that file from the source instead.
    nonisolated static func usesAudioCacheSidecar(for song: Song) -> Bool {
        !(song.isCueTrack
            && CueTrackLyricsSidecarPolicy.referencesTrackDocument(
                song.lyricsFileName,
                audioPath: song.filePath
            ))
    }

    static func locallyMaterializedSourceText(
        for song: Song,
        sourceManager: SourceManager
    ) -> String? {
        guard !readsPinnedDocument(song),
              usesAudioCacheSidecar(for: song),
              let cachedAudioURL = sourceManager.cachedURL(for: song),
              let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
              let data = try? Data(contentsOf: lrcURL),
              let text = LyricsParser.decodeText(data, label: lrcURL.lastPathComponent),
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
        let fileName: String
        /// 这次列目录看到的这首歌的全部歌词文件; 后台比时间轴时直接用, 不再列一次。
        let documents: [LyricsSidecarDocument]
        let songBaseName: String?
    }

    /// - Parameter evaluatesTimingFirst: 编辑器、后台核对这类不赶时间的读取先比完各份
    ///   歌词文件的时间轴再读; 播放不等, 先读当前那份, 比较放到后台。
    private static func authoritativeLyricsFile(
        for song: Song,
        connector: any MusicSourceConnector,
        evaluatesTimingFirst: Bool = false
    ) async throws -> AuthoritativeLyricsFile? {
        if evaluatesTimingFirst {
            await refreshAutomaticDocumentPick(for: song, connector: connector)
        }
        let target: LyricsSidecarTarget
        do {
            target = try await lyricsSidecarTarget(for: song, connector: connector)
        } catch EmbeddedMetadataWritebackSourceError.conflict {
            // 两份可写文件、还没比过时间轴: 先读歌词来源页标「使用中」的那份, 不让播放空等。
            target = try await lyricsSidecarTarget(
                for: song,
                connector: connector,
                request: .catalog(for: song)
            )
        }
        guard target.exists, let existingPath = target.existingPath else { return nil }
        let translation = translationTrack(in: target)
        let maximumSize = Int64(LyricsSidecarTargetPolicy.maximumContentByteCount)
        if let size = target.existingSize, size > 0, size <= maximumSize {
            return AuthoritativeLyricsFile(
                path: existingPath,
                size: size,
                translation: translation,
                fileName: target.fileName,
                documents: target.documents,
                songBaseName: target.songBaseName
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
            translation: translation,
            fileName: target.fileName,
            documents: target.documents,
            songBaseName: target.songBaseName
        )
    }

    static func lyricsSidecarTarget(
        for song: Song,
        connector: any MusicSourceConnector,
        request: LyricsDocumentRequest? = nil
    ) async throws -> LyricsSidecarTarget {
        let request = request ?? .current(for: song)
        if let resolver = connector as? any LyricsSidecarTargetResolving {
            return try await resolver.lyricsSidecarTarget(for: song, request: request)
        }
        return try await LyricsSidecarTargetPolicy.resolve(
            for: song,
            using: connector,
            request: request
        )
    }

    /// The file the listener picked on the lyric sources page, for a caller
    /// that otherwise fetches the scanner's remembered `lyricsFileName`. Nil
    /// for a song without a pin, or when the pinned file is gone and the
    /// default ranking took over — the caller's own path is right then.
    static func pinnedDocumentFile(
        for song: Song,
        connector: any MusicSourceConnector
    ) async throws -> (path: String, fileName: String)? {
        guard let pinned = LyricsDocumentPinStore.shared.effectiveFileName(forSongID: song.id),
              !song.isCueTrack else { return nil }
        let target = try await lyricsSidecarTarget(for: song, connector: connector)
        guard target.exists,
              let path = target.existingPath,
              target.fileName.caseInsensitiveCompare(pinned) == .orderedSame else { return nil }
        return (path, target.fileName)
    }

    /// A song with a picked lyric file reads it from the source. The
    /// shortcuts that read a remembered cache file or the first same-name
    /// file next to a cached copy know nothing of the pick.
    nonisolated static func readsPinnedDocument(_ song: Song) -> Bool {
        !song.isCueTrack
            && LyricsDocumentPinStore.shared.effectiveFileName(forSongID: song.id) != nil
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
              let content = LyricsParser.decodeText(data, label: track.fileName) else { return primary }
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

// 台账 `AutomaticOnlineLyricsLedger` 与开关门槛 `AutomaticOnlineLyricsGate` 在
// AutomaticOnlineLyricsLedger.swift,Apple TV 播放时的在线兜底共用同一份。

extension LyricsLoader {
    /// 在线歌词源按「标题+艺人」找歌词，有声内容的标题是「第 12 集」「Chapter 3」
    /// 这类章节名，搜到的只会是同名歌曲的歌词，和正在讲的内容毫无关系。所以有声
    /// 内容只认源里自带的（同目录 .lrc/.vtt/.srt、内嵌、服务端），自动在线查找
    /// 一律不走；用户在刮削页手动搜仍然可以。
    static func songAcceptsAutomaticOnlineLyrics(_ song: Song) -> Bool {
        !SpokenWordStore.shared.isSpokenWord(song)
    }

    /// Tier4：本地/网盘等普通源确实没有歌词时，按启用顺序向在线歌词源取一次并写入缓存。
    /// 开关关、没有启用的歌词源、台账说最近问过、任务被取消 → nil。
    static func automaticOnlineLyrics(
        for song: Song,
        expectedFingerprint: LyricsDocumentFingerprint?
    ) async -> [LyricLine]? {
        guard !Task.isCancelled else { return nil }
        guard songAcceptsAutomaticOnlineLyrics(song) else { return nil }
        guard AutomaticOnlineLyricsGate.allowsAutomaticFetch(settings: ScraperSettings.load()) else {
            return nil
        }
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
