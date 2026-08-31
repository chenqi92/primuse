import Foundation
import PrimuseKit

private actor LyricsWritebackMutationGate {
    private struct State {
        var isRunning = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var states: [String: State] = [:]

    func acquire(_ key: String) async {
        var state = states[key, default: State()]
        if !state.isRunning {
            state.isRunning = true
            states[key] = state
            return
        }
        await withCheckedContinuation { continuation in
            state.waiters.append(continuation)
            states[key] = state
        }
    }

    func release(_ key: String) {
        var state = states[key, default: State()]
        if state.waiters.isEmpty {
            states[key] = nil
        } else {
            let next = state.waiters.removeFirst()
            states[key] = state
            next.resume()
        }
    }
}

/// 歌词的加载与写回。原本整套逻辑锁在 `TagEditorView` 的私有作用域里，
/// 独立的歌词编辑入口没法复用；抽出来之后标签编辑器和歌词编辑器共用同一条链路，
/// 写回目标(sidecar / 媒体服务器 / 仅本地)的判定也只有一份实现。
@MainActor
enum LyricsWriteback {
    private static let mutationGate = LyricsWritebackMutationGate()
    /// 这首歌的歌词能写到哪。决定保存时走哪条路，也决定 UI 上那行状态提示。
    enum Mode: Equatable {
        /// 还在探测。
        case checking
        /// 写同目录的歌词 sidecar 文件（新文件默认 LRC，已有 TTML 保持 TTML）。
        case sidecar(SidecarWriteService.LyricsPreflightResult)
        /// 走媒体服务器的写回接口(Jellyfin 等)。
        case mediaServer
        /// 源不可写，只更新 Primuse 自己的库记录。`reason` 非空时明确说明
        /// 服务端为什么没有被修改。
        case localOnly(reason: String?)
        /// 探测失败或源明确不支持，附带原因。
        case unavailable(String)

        var isLocalStructuredOnly: Bool {
            if case .localOnly = self { return true }
            return false
        }

        func protectingSourceConflict(_ hasConflict: Bool) -> Self {
            guard hasConflict else { return self }
            switch self {
            case .sidecar:
                return .localOnly(reason: nil)
            case .mediaServer:
                return .unavailable(String(localized: "tag_editor_lyrics_server_unsupported"))
            case .checking, .localOnly, .unavailable:
                return self
            }
        }
    }

    // MARK: - 加载

    enum EditableSourceSnapshot: Equatable, Sendable {
        /// The connector could not prove whether a source document exists.
        /// External overwrite is refused unless sidecar preflight proves that
        /// the write creates a new file.
        case unknown
        case absent
        case content(String)
    }

    struct EditablePayload: Sendable {
        let text: String
        /// 只有在没有权威源文本、或源是需要先转换的 TTML 时提供。这样既不牺牲
        /// LRC 原始精度，也能保住嵌入字段里的语言/来源和同文字体系译文。
        let structuredLines: [LyricLine]?
        /// The source changed in a way that cannot safely reassign an authored
        /// translation. The cached document remains editable, but must not be
        /// written back over that newer source without conflict resolution.
        let hasSourceConflict: Bool
        let sourceSnapshot: EditableSourceSnapshot
        var cacheSnapshot: LyricsDocumentFingerprint?

        init(
            text: String,
            structuredLines: [LyricLine]?,
            hasSourceConflict: Bool = false,
            sourceSnapshot: EditableSourceSnapshot = .unknown,
            cacheSnapshot: LyricsDocumentFingerprint? = nil
        ) {
            self.text = text
            self.structuredLines = structuredLines
            self.hasSourceConflict = hasSourceConflict
            self.sourceSnapshot = sourceSnapshot
            self.cacheSnapshot = cacheSnapshot
        }
    }

    static func loadEditableText(
        for song: Song,
        sourceManager: SourceManager
    ) async -> String {
        await LyricsLoader.loadEditableText(for: song, sourceManager: sourceManager)
    }

    static func loadEditablePayload(
        for song: Song,
        sourceManager: SourceManager
    ) async -> EditablePayload {
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
        var payload = await makeEditablePayload(
            for: song,
            sourceManager: sourceManager,
            cached: cached
        )
        if let cached {
            payload.cacheSnapshot = LyricsDocumentFingerprint(lines: cached)
        } else if let latest = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id),
                  let payloadLines = payload.structuredLines,
                  LyricsDocumentFingerprint(lines: latest)
                    == LyricsDocumentFingerprint(lines: payloadLines) {
            // `LyricsLoader.load` may have populated Tier 1 while constructing
            // this payload. Record only the exact document the editor received.
            payload.cacheSnapshot = LyricsDocumentFingerprint(lines: latest)
        }
        return payload
    }

    private static func makeEditablePayload(
        for song: Song,
        sourceManager: SourceManager,
        cached: [LyricLine]?
    ) async -> EditablePayload {
        let authoritativeRead = await LyricsLoader.readAuthoritativeSourceText(
            for: song,
            sourceManager: sourceManager
        )
        let sourceText: String?
        let initialSourceSnapshot: EditableSourceSnapshot
        switch authoritativeRead {
        case .content(let content):
            sourceText = content
            initialSourceSnapshot = .content(normalizedSourceText(content))
        case .absent:
            let localSourceText = LyricsLoader.locallyMaterializedSourceText(
                for: song,
                sourceManager: sourceManager
            )
            sourceText = localSourceText
            // A non-override cache or a locally materialized sidecar may have
            // been populated by embedded/source scanning. Treat its durable
            // authority as unknown so clearing a no-op target cannot report a
            // deletion that the next scan immediately resurrects.
            let cacheIsExplicitLocalOverride = cached?.first?.documentIsLocalOverride == true
            initialSourceSnapshot = localSourceText == nil
                    && (cached == nil || cacheIsExplicitLocalOverride)
                ? .absent
                : .unknown
        case .unavailable:
            sourceText = LyricsLoader.locallyMaterializedSourceText(
                for: song,
                sourceManager: sourceManager
            )
            initialSourceSnapshot = .unknown
        }
        if let sourceText {
            let normalizedSource = sourceText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceSnapshot: EditableSourceSnapshot
            if case .content = initialSourceSnapshot {
                sourceSnapshot = .content(normalizedSource)
            } else {
                sourceSnapshot = initialSourceSnapshot
            }
            if let cached, cached.first?.documentIsLocalOverride == true {
                return EditablePayload(
                    text: LyricsContentParser.serialize(cached),
                    structuredLines: cached,
                    hasSourceConflict: true,
                    sourceSnapshot: sourceSnapshot
                )
            }
            if LyricsContentParser.isTTML(normalizedSource) {
                let sourceLines = LyricsContentParser.parse(normalizedSource)
                guard !sourceLines.isEmpty else {
                    if let cached {
                        return EditablePayload(
                            text: LyricsContentParser.serialize(cached),
                            structuredLines: cached,
                            hasSourceConflict: true,
                            sourceSnapshot: sourceSnapshot
                        )
                    }
                    return EditablePayload(
                        text: "",
                        structuredLines: nil,
                        hasSourceConflict: true,
                        sourceSnapshot: sourceSnapshot
                    )
                }
                if let cached {
                    guard let lines = LyricManualTranslationPolicy
                        .preservingStoredTranslations(
                            from: cached,
                            in: sourceLines
                        ) else {
                        return EditablePayload(
                            text: LyricsContentParser.serialize(cached),
                            structuredLines: cached,
                            hasSourceConflict: true,
                            sourceSnapshot: sourceSnapshot
                        )
                    }
                    return EditablePayload(
                        text: LyricsContentParser.serialize(lines),
                        structuredLines: lines,
                        sourceSnapshot: sourceSnapshot
                    )
                }
                return EditablePayload(
                    text: LyricsContentParser.serialize(sourceLines),
                    structuredLines: sourceLines,
                    sourceSnapshot: sourceSnapshot
                )
            }
            if let cached,
               normalized(LyricsContentParser.serialize(cached)) == normalizedSource {
                // Primuse 自己刚写过的双语 LRC 可能是英→法等同文字体系，保守
                // 解析器不会凭文本猜配对。源文本逐字一致时可安全复用结构缓存。
                return EditablePayload(
                    text: normalizedSource,
                    structuredLines: cached,
                    sourceSnapshot: sourceSnapshot
                )
            }
            if let cached {
                let sourceLines = LyricsContentParser.parseText(normalizedSource)
                if let merged = LyricManualTranslationPolicy.preservingStoredTranslations(
                    from: cached,
                    in: sourceLines
                ) {
                    // sidecar/TTML 是原文的权威时间线；缓存只补回容器
                    // 独立字段里的译文，不覆盖源文本的原文结构。
                    return EditablePayload(
                        text: normalizedSource,
                        structuredLines: merged,
                        sourceSnapshot: sourceSnapshot
                    )
                }
                // A source rewrite made a local/container-field translation
                // impossible to reassign without guessing. Keep the cached
                // editable document visible instead of hiding authored data.
                return EditablePayload(
                    text: LyricsContentParser.serialize(cached),
                    structuredLines: cached,
                    hasSourceConflict: true,
                    sourceSnapshot: sourceSnapshot
                )
            }
            return EditablePayload(
                text: normalizedSource,
                structuredLines: nil,
                sourceSnapshot: sourceSnapshot
            )
        }

        let lines: [LyricLine]
        if let cached {
            lines = cached
        } else {
            lines = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        }
        return EditablePayload(
            text: LyricsContentParser.serialize(lines),
            structuredLines: lines,
            sourceSnapshot: initialSourceSnapshot
        )
    }

    /// 探测写回目标。sidecar 优先 —— 能写文件就写文件，跨设备和换播放器都还在。
    static func resolveMode(
        for song: Song,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async -> Mode {
        if await sourceManager.supportsSidecarWriting(for: song) {
            do {
                let preflight = try await MusicScraperService.preflightLyricsWriteWithTimeout(
                    seconds: 10,
                    sourceManager: sourceManager,
                    for: song
                )
                return .sidecar(preflight)
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }

        let sourceType = sourcesStore.source(id: song.sourceID)?.type
        if sourceType == .jellyfin || sourceType == .emby || sourceType == .plex {
            do {
                let connector = try await sourceManager.connectorForSong(song)
                guard let server = connector as? any ServerLyricsConnector else {
                    return .unavailable(String(localized: "tag_editor_lyrics_server_unsupported"))
                }
                if server.serverLyricsCapabilities.canWrite,
                   connector is any MediaServerWritebackConnector {
                    return .mediaServer
                }
                if sourceType == .emby {
                    return .localOnly(
                        reason: String(localized: "tag_editor_lyrics_server_unsupported")
                    )
                }
                return .localOnly(reason: nil)
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }

        return .localOnly(reason: nil)
    }

    // MARK: - 保存

    /// 保存结果。`errorMessage` 非 nil 表示写回失败，调用方原样展示给用户。
    struct SaveOutcome {
        enum Persistence: Equatable {
            case sidecar
            case mediaServer
            case localOnly
        }

        var updatedSong: Song
        var errorMessage: String?
        var persistence: Persistence
        var cacheSnapshot: LyricsDocumentFingerprint?

        var succeeded: Bool { errorMessage == nil }

        init(
            updatedSong: Song,
            errorMessage: String?,
            persistence: Persistence = .localOnly,
            cacheSnapshot: LyricsDocumentFingerprint? = nil
        ) {
            self.updatedSong = updatedSong
            self.errorMessage = errorMessage
            self.persistence = persistence
            self.cacheSnapshot = cacheSnapshot
        }
    }

    /// 把编辑后的歌词文本落盘并更新库记录。
    ///
    /// `allowRemoval` 为 false 时，清空歌词会被拒绝 —— 删歌词是破坏性操作，
    /// 必须由调用方先向用户确认过。
    static func save(
        text: String,
        for song: Song,
        mode: Mode,
        allowRemoval: Bool,
        structuredLines: [LyricLine]? = nil,
        sourceSnapshot: EditableSourceSnapshot = .unknown,
        cacheSnapshot: LyricsDocumentFingerprint? = nil,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> SaveOutcome {
        let mutationKey = mutationKey(for: song, mode: mode)
        await mutationGate.acquire(mutationKey)
        let outcome = await performSave(
            text: text,
            for: song,
            mode: mode,
            allowRemoval: allowRemoval,
            structuredLines: structuredLines,
            sourceSnapshot: sourceSnapshot,
            cacheSnapshot: cacheSnapshot,
            sourceManager: sourceManager,
            library: library
        )
        await mutationGate.release(mutationKey)
        return outcome
    }

    private static func mutationKey(for song: Song, mode: Mode) -> String {
        switch mode {
        case .sidecar(let target):
            return song.sourceID + "\u{0}sidecar\u{0}" + target.targetPath
        case .mediaServer:
            return song.sourceID + "\u{0}server\u{0}" + song.filePath
        case .checking, .localOnly, .unavailable:
            return song.sourceID + "\u{0}cache\u{0}" + song.id
        }
    }

    private static func performSave(
        text: String,
        for song: Song,
        mode: Mode,
        allowRemoval: Bool,
        structuredLines: [LyricLine]?,
        sourceSnapshot: EditableSourceSnapshot,
        cacheSnapshot: LyricsDocumentFingerprint?,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> SaveOutcome {
        var updated = song
        let content = normalized(text)
        let requestedPersistence = persistence(for: mode)
        var savedPersistence = requestedPersistence
        var savedCacheSnapshot = cacheSnapshot

        if content.isEmpty {
            guard allowRemoval else {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_empty_error"),
                    persistence: requestedPersistence
                )
            }
            if case .localOnly = mode {
                // Clearing only Primuse's cache cannot suppress a scanned
                // embedded field or a confirmed-empty source's online
                // fallback. Without a durable tombstone, refuse to report a
                // deletion that the next load can immediately resurrect.
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: requestedPersistence
                )
            }
            if case .sidecar(let target) = mode,
               !target.replacesExistingFile {
                // Removing a sidecar that never existed cannot delete an
                // embedded, scanned, or cache-only authority, and there is no
                // durable tombstone today.
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: requestedPersistence
                )
            }
            guard await sourceStillMatches(
                sourceSnapshot,
                for: updated,
                mode: mode,
                sourceManager: sourceManager
            ) else {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: requestedPersistence
                )
            }
            let externalMutationToken: UUID?
            switch mode {
            case .sidecar, .mediaServer:
                externalMutationToken = await MetadataAssetStore.shared.beginLyricsMutation(
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot
                )
                guard externalMutationToken != nil else {
                    return SaveOutcome(
                        updatedSong: song,
                        errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                        persistence: requestedPersistence
                    )
                }
            case .checking, .localOnly, .unavailable:
                externalMutationToken = nil
            }
            if let error = await remove(for: updated, mode: mode, sourceManager: sourceManager) {
                if let externalMutationToken {
                    await MetadataAssetStore.shared.cancelLyricsMutation(
                        forSongID: song.id,
                        token: externalMutationToken
                    )
                }
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(
                        format: String(localized: "tag_editor_lyrics_write_failed"),
                        error
                    ),
                    persistence: requestedPersistence
                )
            }
            let cacheRemoved: Bool
            if let externalMutationToken {
                cacheRemoved = await MetadataAssetStore.shared.commitLyricsRemoval(
                    forSongID: song.id,
                    token: externalMutationToken
                )
            } else {
                cacheRemoved = await MetadataAssetStore.shared.invalidateLyricsCacheIfUnchanged(
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot
                )
            }
            guard cacheRemoved else {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: requestedPersistence
                )
            }
            savedCacheSnapshot = nil
            updated.lyricsFileName = nil
            updated.lyricsText = nil
        } else {
            let validation = LyricsContentParser.validateEditableText(content)
            guard validation.isValid else {
                let errorMessage: String
                if validation.lines.isEmpty {
                    errorMessage = String(localized: "tag_editor_lyrics_invalid_error")
                } else {
                    let lineNumbers = validation.issues
                        .map(\.lineNumber)
                        .reduce(into: [Int]()) { result, lineNumber in
                            if result.last != lineNumber { result.append(lineNumber) }
                        }
                        .map(String.init)
                        .joined(separator: ", ")
                    errorMessage = String(
                        format: String(localized: "tag_editor_lyrics_invalid_lines_format"),
                        lineNumbers
                    )
                }
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: errorMessage,
                    persistence: requestedPersistence
                )
            }
            let validatedLines = validatedStructuredLines(
                structuredLines,
                matching: validation.normalizedContent
            ) ?? validation.lines
            let staysLocal = requiresLocalStructuredPersistence(
                validatedLines,
                mode: mode
            )
            guard await sourceStillMatches(
                sourceSnapshot,
                for: updated,
                mode: mode,
                sourceManager: sourceManager
            ) else {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: requestedPersistence
                )
            }
            var writebackLines = staysLocal
                ? validatedLines
                : linesForPersistence(validatedLines, mode: mode)
            if staysLocal, case .mediaServer = mode {
                // Server revalidation treats the remote document as
                // authoritative. Without a durable local-override marker, a
                // nominally successful local fallback would be overwritten on
                // the next playback. Refuse this lossy boundary explicitly.
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_server_unsupported"),
                    persistence: requestedPersistence
                )
            }
            if staysLocal { savedPersistence = .localOnly }
            let savesLocally = savedPersistence == .localOnly
            if savesLocally {
                writebackLines = writebackLines.map(promotingLocalTranslationProvenance)
            }
            for index in writebackLines.indices {
                writebackLines[index].documentIsLocalOverride = savesLocally && index == 0
            }
            var externalMutationToken: UUID?
            if !staysLocal {
                externalMutationToken = await MetadataAssetStore.shared.beginLyricsMutation(
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot
                )
                guard externalMutationToken != nil else {
                    return SaveOutcome(
                        updatedSong: song,
                        errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                        persistence: requestedPersistence
                    )
                }
                if let error = await write(
                    writebackLines,
                    content: persistenceContent(
                        validation.normalizedContent,
                        lines: writebackLines,
                        mode: mode
                    ),
                    for: updated,
                    mode: mode,
                    sourceManager: sourceManager
                ) {
                    if let externalMutationToken {
                        await MetadataAssetStore.shared.cancelLyricsMutation(
                            forSongID: song.id,
                            token: externalMutationToken
                        )
                    }
                    return SaveOutcome(
                        updatedSong: song,
                        errorMessage: String(
                            format: String(localized: "tag_editor_lyrics_write_failed"),
                            error
                        ),
                        persistence: requestedPersistence
                    )
                }
            }
            let cacheStored: Bool
            if let externalMutationToken {
                cacheStored = await MetadataAssetStore.shared.commitLyricsMutation(
                    writebackLines,
                    forSongID: song.id,
                    token: externalMutationToken
                )
            } else {
                cacheStored = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                    writebackLines,
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot
                )
            }
            if cacheStored {
                savedCacheSnapshot = LyricsDocumentFingerprint(lines: writebackLines)
            } else {
                // A local-only document has no other durable copy. For an
                // external write, the source may already contain the update,
                // but source/cache divergence is still a partial failure and
                // must not be reported as an atomic success.
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: savedPersistence
                )
            }
            // LRC mirrors may intentionally yield to the richer local cache,
            // but an existing TTML document is itself word-level and must stay
            // addressable for later edits, deletion, and stale-cache refresh.
            updated.lyricsFileName = cacheStored
                ? (retainedTTMLReference(for: song, mode: mode)
                    ?? MetadataAssetStore.shared.expectedLyricsFileName(for: song.id))
                : song.lyricsFileName
            updated.lyricsText = writebackLines.map(\.text).joined(separator: "\n")
        }

        // Source/cache verification may await the network for many seconds.
        // Merge only the lyric fields into the latest library row so a tag,
        // artwork, favorite, or background refresh completed in that window
        // is not replaced by the editor's older Song snapshot.
        var committedSong = updated
        if var latestSong = library.songs.first(where: { $0.id == updated.id }) {
            latestSong.lyricsFileName = updated.lyricsFileName
            latestSong.lyricsText = updated.lyricsText
            library.replaceSong(latestSong)
            committedSong = latestSong
        }
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: committedSong.id)
        return SaveOutcome(
            updatedSong: committedSong,
            errorMessage: nil,
            persistence: savedPersistence,
            cacheSnapshot: savedCacheSnapshot
        )
    }

    // MARK: - 写 / 删

    private static func sourceStillMatches(
        _ expected: EditableSourceSnapshot,
        for song: Song,
        mode: Mode,
        sourceManager: SourceManager
    ) async -> Bool {
        switch mode {
        case .checking, .unavailable:
            return false
        case .localOnly:
            if case .unknown = expected { return true }
            let latestRead = await LyricsLoader.readAuthoritativeSourceText(
                for: song,
                sourceManager: sourceManager
            )
            switch (expected, latestRead) {
            case (.content(let expectedContent), .content(let latestSource)):
                return normalizedSourceText(latestSource) == expectedContent
            case (.absent, .absent):
                return true
            case (.unknown, _), (.content, .absent), (.content, .unavailable),
                 (.absent, .content), (.absent, .unavailable):
                return false
            }
        case .sidecar(let target):
            let latestRead = await LyricsLoader.readAuthoritativeSourceText(
                for: song,
                sourceManager: sourceManager
            )
            switch (expected, latestRead) {
            case (.content(let expected), .content(let latest)):
                return expected == normalizedSourceText(latest)
            case (.absent, .absent):
                return true
            case (.unknown, .absent):
                return !target.replacesExistingFile
            case (.unknown, .content), (.unknown, .unavailable),
                 (.absent, .content), (.absent, .unavailable),
                 (.content, .absent), (.content, .unavailable):
                return false
            }
        case .mediaServer:
            let latestRead = await LyricsLoader.readAuthoritativeSourceText(
                for: song,
                sourceManager: sourceManager
            )
            switch (expected, latestRead) {
            case (.content(let expected), .content(let latest)):
                return expected == normalizedSourceText(latest)
            case (.absent, .absent):
                return true
            case (.unknown, _), (.absent, .content), (.absent, .unavailable),
                 (.content, .absent), (.content, .unavailable):
                return false
            }
        }
    }

    private static func normalizedSourceText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 返回 nil 表示成功，否则是给用户看的错误原因。
    private static func write(
        _ lines: [LyricLine],
        content: String,
        for song: Song,
        mode: Mode,
        sourceManager: SourceManager
    ) async -> String? {
        switch mode {
        case .localOnly:
            return nil
        case .checking:
            return String(localized: "tag_editor_lyrics_writeback_checking")
        case .unavailable(let reason):
            return reason
        case .sidecar(let target):
            do {
                let result = try await MusicScraperService.writeSidecarWithTimeout(
                    seconds: 30,
                    sourceManager: sourceManager,
                    for: song,
                    coverData: nil,
                    lyricsLines: lines,
                    lyricsContent: content,
                    expectedLyricsTarget: target
                )
                if result.lyricsTargetChanged {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                guard result.lyricsWritten else {
                    return result.errors.joined(separator: "\n")
                }
                // 写完读回来比一次 —— 网盘/NAS 偶尔会吞掉写入还返回成功。
                guard await verifySidecarWrite(
                    content: content,
                    song: song,
                    sourceManager: sourceManager
                ) else {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        case .mediaServer:
            let result = await sourceManager.writeScrapedMetadataToMediaServer(
                original: song,
                updated: song,
                coverData: nil,
                lyricsLines: lines,
                lyricsContent: content
            )
            guard result.lyricsWritten else {
                return (result.errors + result.unsupported).joined(separator: "\n")
            }
            guard await verifyMediaServerWrite(
                expectedLines: lines,
                song: song,
                sourceManager: sourceManager
            ) else {
                return String(localized: "tag_editor_lyrics_verify_failed")
            }
            return nil
        }
    }

    private static func remove(
        for song: Song,
        mode: Mode,
        sourceManager: SourceManager
    ) async -> String? {
        switch mode {
        case .localOnly:
            return nil
        case .checking:
            return String(localized: "tag_editor_lyrics_writeback_checking")
        case .unavailable(let reason):
            return reason
        case .sidecar(let target):
            do {
                let result = try await MusicScraperService.removeLyricsSidecarWithTimeout(
                    seconds: 30,
                    sourceManager: sourceManager,
                    for: song,
                    expectedLyricsTarget: target
                )
                if result.lyricsTargetChanged {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                guard result.lyricsRemoved else {
                    return result.errors.joined(separator: "\n")
                }
                guard await verifySidecarRemoval(song: song, sourceManager: sourceManager) else {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        case .mediaServer:
            let result = await sourceManager.removeLyricsFromMediaServer(for: song)
            guard result.lyricsRemoved else {
                return (result.errors + result.unsupported).joined(separator: "\n")
            }
            guard await verifyMediaServerRemoval(song: song, sourceManager: sourceManager) else {
                return String(localized: "tag_editor_lyrics_verify_failed")
            }
            return nil
        }
    }

    // MARK: - 回读校验

    private static func verifySidecarWrite(
        content: String,
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        let readback = await LyricsLoader.readAuthoritativeSourceText(
            for: song,
            sourceManager: sourceManager
        )
        guard case .content(let text) = readback else { return false }
        return normalized(text) == normalized(content)
    }

    private static func verifyMediaServerWrite(
        expectedLines: [LyricLine],
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        guard let connector = try? await sourceManager.connectorForSong(song),
              let server = connector as? any ServerLyricsConnector,
              let readback = await server.fetchServerLyrics(for: song.filePath) else {
            return false
        }
        let parsedReadback = LyricsContentParser.parseText(readback)
        if LyricsContentParser.areSemanticallyEquivalent(expectedLines, parsedReadback) {
            return true
        }

        // 同文字体系的双语 LRC 不应靠启发式猜配对；按 literal 行序比较仍可
        // 校验服务端完整保存了原文、译文与各自复用的时间戳。
        return LyricsContentParser.areSemanticallyEquivalent(
            LyricsContentParser.parseText(
                LyricsContentParser.serialize(expectedLines),
                options: .literal
            ),
            LyricsContentParser.parseText(readback, options: .literal)
        )
    }

    private static func verifySidecarRemoval(
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        guard let preflight = try? await MusicScraperService.preflightLyricsWriteWithTimeout(
            seconds: 10,
            sourceManager: sourceManager,
            for: song
        ) else { return false }
        return !preflight.replacesExistingFile
    }

    private static func verifyMediaServerRemoval(
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        if case .absent = await LyricsLoader.readAuthoritativeSourceText(
            for: song,
            sourceManager: sourceManager
        ) {
            return true
        }
        return false
    }

    // MARK: - 工具

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsManualTranslations(_ lines: [LyricLine]) -> Bool {
        lines.contains { line in
            line.allManualTranslations.contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
                || containsManualTranslations(line.background ?? [])
        }
    }

    private static func promotingLocalTranslationProvenance(_ line: LyricLine) -> LyricLine {
        var result = line
        if var translation = result.manualTranslation,
           translation.source == .bilingualLRC {
            translation.source = .localEditor
            result.manualTranslation = translation
        }
        result.alternateManualTranslations = result.alternateManualTranslations.map { translation in
            guard translation.source == .bilingualLRC else { return translation }
            var local = translation
            local.source = .localEditor
            return local
        }
        result.background = result.background?.map(promotingLocalTranslationProvenance)
        return result
    }

    static func allowsStructuredOnlyTranslationEditing(
        for lines: [LyricLine]?,
        mode: Mode
    ) -> Bool {
        switch mode {
        case .localOnly:
            return true
        case .sidecar:
            guard let lines else { return isTTMLSidecar(mode) }
            return isTTMLSidecar(mode)
                || LyricsStructuredPersistencePolicy.requiresTTML(lines)
                || containsManualTranslations(lines)
                    && !LyricManualTranslationPolicy.canPersistAsBilingualLRC(lines)
                || lines.contains {
                    !$0.isSynchronized
                        || $0.isWordLevel
                        || $0.voice != .primary
                        || $0.background?.isEmpty == false
                }
        case .checking, .mediaServer, .unavailable:
            return false
        }
    }

    private static func validatedStructuredLines(
        _ candidate: [LyricLine]?,
        matching editableContent: String
    ) -> [LyricLine]? {
        guard let candidate, !candidate.isEmpty,
              normalized(LyricsContentParser.serialize(candidate))
                == normalized(editableContent) else { return nil }
        return candidate
    }

    private static func linesForPersistence(
        _ lines: [LyricLine],
        mode: Mode
    ) -> [LyricLine] {
        switch mode {
        case .sidecar, .mediaServer:
            return lines.map { line in
                guard var translation = line.manualTranslation else { return line }
                translation.source = .bilingualLRC
                var result = line
                result.manualTranslation = translation
                return result
            }
        case .checking, .localOnly, .unavailable:
            return lines
        }
    }

    private static func requiresBilingualLRCPersistence(_ mode: Mode) -> Bool {
        switch mode {
        case .sidecar, .mediaServer:
            return true
        case .checking, .localOnly, .unavailable:
            return false
        }
    }

    private static func requiresLocalStructuredPersistence(
        _ lines: [LyricLine],
        mode: Mode
    ) -> Bool {
        let translationsNeedLocalStorage: Bool
        if containsManualTranslations(lines), isTTMLSidecar(mode) {
            translationsNeedLocalStorage = true
        } else if containsManualTranslations(lines), requiresBilingualLRCPersistence(mode) {
            translationsNeedLocalStorage = !LyricManualTranslationPolicy
                .canPersistAsBilingualLRC(lines)
        } else {
            translationsNeedLocalStorage = false
        }
        let structureNeedsLocalStorage = LyricsStructuredPersistencePolicy.requiresTTML(lines)
            && !isTTMLSidecar(mode)
            && requiresBilingualLRCPersistence(mode)
        let metadataNeedsLocalStorage: Bool
        if case .mediaServer = mode {
            let supportedHeaders = Set([
                "ar", "al", "ti", "author", "by", "re", "length", "offset",
            ])
            metadataNeedsLocalStorage = (lines.first?.metadataLines ?? []).contains { header in
                let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                guard trimmed.first == "[",
                      let colon = trimmed.firstIndex(of: ":") else { return true }
                let start = trimmed.index(after: trimmed.startIndex)
                guard start <= colon else { return true }
                return !supportedHeaders.contains(trimmed[start..<colon].lowercased())
            }
        } else {
            metadataNeedsLocalStorage = false
        }
        return translationsNeedLocalStorage
            || structureNeedsLocalStorage
            || metadataNeedsLocalStorage
    }

    private static func isTTMLSidecar(_ mode: Mode) -> Bool {
        guard case .sidecar(let target) = mode else { return false }
        return (target.fileName as NSString).pathExtension
            .caseInsensitiveCompare("ttml") == .orderedSame
    }

    private static func persistenceContent(
        _ editableContent: String,
        lines: [LyricLine],
        mode: Mode
    ) -> String {
        guard case .sidecar(let target) = mode,
              (target.fileName as NSString).pathExtension
                .caseInsensitiveCompare("ttml") == .orderedSame else {
            return editableContent
        }
        return LyricsContentParser.serializeTTML(lines)
    }

    private static func retainedTTMLReference(for song: Song, mode: Mode) -> String? {
        guard case .sidecar(let target) = mode,
              (target.fileName as NSString).pathExtension
                .caseInsensitiveCompare("ttml") == .orderedSame,
              let reference = song.lyricsFileName,
              (reference as NSString).pathExtension.caseInsensitiveCompare("ttml") == .orderedSame else {
            return nil
        }
        return reference
    }

    private static func persistence(for mode: Mode) -> SaveOutcome.Persistence {
        switch mode {
        case .sidecar:
            return .sidecar
        case .mediaServer:
            return .mediaServer
        case .checking, .localOnly, .unavailable:
            return .localOnly
        }
    }
}
