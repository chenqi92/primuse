import CryptoKit
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

extension SaveLocationPolicy.Remedy {
    /// 解决办法的按钮文字。
    var title: String {
        switch self {
        case .grantFolderAccess: return String(localized: "save_location_action_grant_folder")
        case .embedThisSong: return String(localized: "save_location_action_embed_song")
        case .embedAllSongs: return String(localized: "save_location_action_embed_all")
        }
    }

    /// 改成嵌入音频文件:只这首「只嵌入」;全部改成「歌词文件并嵌入」,文件夹里的歌照样有歌词文件,
    /// 单独添加的文件只嵌入。授权文件夹要走选择器,不在这里。
    @MainActor
    func applyEmbedding(for songID: String) {
        switch self {
        case .embedThisSong:
            EmbeddedLyricsCopyPolicy.setMode(.embedOnly, forSongID: songID)
        case .embedAllSongs:
            EmbeddedLyricsCopyPolicy.setMode(.alongside)
        case .grantFolderAccess:
            return
        }
        plog("Lyrics save location remedy songID=\(songID.prefix(8)) remedy=\(rawValue)")
    }
}

extension LyricsEmbeddingMode {
    var settingsTitle: String {
        switch self {
        case .off: return String(localized: "lyrics_embed_mode_off")
        case .alongside: return String(localized: "lyrics_embed_mode_alongside")
        case .embedOnly: return String(localized: "lyrics_embed_mode_embed_only")
        }
    }

    /// 选到这一档之前要让用户看到的代价。
    var confirmationMessage: String {
        let common = String(localized: "lyrics_embed_confirm_message")
        guard self == .embedOnly else { return common }
        return common + "\n" + String(localized: "lyrics_embed_confirm_message_embed_only")
    }
}

/// 歌词的加载与写回。原本整套逻辑锁在 `TagEditorView` 的私有作用域里，
/// 独立的歌词编辑入口没法复用；抽出来之后标签编辑器和歌词编辑器共用同一条链路，
/// 写回目标(sidecar / 媒体服务器 / 仅本地)的判定也只有一份实现。
@MainActor
enum LyricsWriteback {
    private static let mutationGate = LyricsWritebackMutationGate()
    /// 这首歌的歌词能写到哪。决定保存时走哪条路，也决定 UI 上那行状态提示。
    enum Mode: Equatable, Sendable {
        /// 还在探测。
        case checking
        /// 写同目录的歌词 sidecar 文件（新文件默认 LRC，已有 TTML 保持 TTML；
        /// 旁边是 .vtt/.lys 这类只读文档时另存 TTML，不改写它）。
        case sidecar(SidecarWriteService.LyricsPreflightResult)
        /// 走媒体服务器的写回接口(Jellyfin 等)。
        case mediaServer
        /// 源不可写，只更新 Primuse 自己的库记录。`reason` 非空时明确说明
        /// 服务端为什么没有被修改。
        case localOnly(reason: String?)
        /// 探测失败或源明确不支持，附带原因。
        case unavailable(String)
        /// 这次没连上(超时、连接被占满)，但源本身可能是可写的。
        /// 与 `unavailable` 分开，是因为给用户的话完全不同：一个该去查权限，
        /// 一个只需要过会儿再试。
        case temporarilyUnavailable(String)

        var isLocalStructuredOnly: Bool {
            if case .localOnly = self { return true }
            return false
        }

        func protectingSourceConflict(_ hasConflict: Bool) -> Self {
            guard hasConflict else { return self }
            switch self {
            case .sidecar:
                return .localOnly(reason: String(localized: "save_location_lyrics_source_conflict"))
            case .mediaServer:
                return .unavailable(String(localized: "tag_editor_lyrics_server_unsupported"))
            case .checking, .localOnly, .unavailable, .temporarilyUnavailable:
                return self
            }
        }
    }

    /// 这首歌这次保存落在哪里、为什么。`mode` 交给 `save`;`notice` 是写回目标那一行的说明,
    /// 开头先说落在哪里;`plan.remedies` 是能一键解决的办法(授权所在文件夹、改成嵌入)。
    struct Target: Sendable, Equatable {
        var mode: Mode
        var plan: SaveLocationPolicy.Plan
        var notice: String
        var hasICloudConflict = false

        static let checking = Target(
            mode: .checking,
            plan: SaveLocationPolicy.Plan(destination: .undetermined),
            notice: String(localized: "tag_editor_lyrics_writeback_checking")
        )

        /// 说明加上 iCloud 冲突版本的提醒。
        var fullNotice: String {
            guard hasICloudConflict else { return notice }
            return notice + "\n" + String(localized: "save_location_icloud_conflict")
        }

        func protectingSourceConflict(_ hasConflict: Bool) -> Target {
            let protected = mode.protectingSourceConflict(hasConflict)
            guard protected != mode else { return self }
            var target = self
            target.mode = protected
            switch protected {
            case .localOnly(let reason):
                target.plan = SaveLocationPolicy.Plan(destination: .primuseOnly)
                target.notice = reason ?? notice
            case .unavailable(let reason):
                target.plan = SaveLocationPolicy.Plan(destination: .undetermined, reason: .unavailable)
                target.notice = String(format: String(localized: "tag_editor_lyrics_writeback_unavailable"), reason)
            case .checking, .sidecar, .mediaServer, .temporarilyUnavailable:
                break
            }
            return target
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

        var playbackLines: [LyricLine] {
            if let structuredLines, !structuredLines.isEmpty { return structuredLines }
            return LyricsContentParser.parseText(text)
        }

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
        let opened = AppServices.shared.musicLibrary.storedSong(id: song.id) ?? song
        let openedFile = await openedAudioFile(for: song, sourceManager: sourceManager)
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
        // 编辑器打开这一刻固定住目标和要换掉的那一份内嵌原文：之后播放切到哪一首、外层怎么刷新、
        // 自动路径把缓存换成了什么，保存都只写这一首、这个文件、这个字段。
        let anchor = await embeddedReplacementAnchor(forSongID: song.id)
        let playbackLines = payload.playbackLines
        let editedVersion: [LyricLine]
        // 重新解析旁车文本会丢失文件来源标记。同一份原文另存时保留原候选，避免再生成一份无来源的副本。
        if let cached, LyricsDocumentSource.of(cached)?.kind == .file,
           LyricsDocumentSource.of(playbackLines) == nil,
           LyricsDocumentFingerprint(lines: playbackLines) == payload.cacheSnapshot {
            editedVersion = cached
        } else {
            editedVersion = playbackLines
        }
        openEditSession(
            EditSession(target: EditTarget(opened), openedFile: openedFile, anchor: anchor, editedVersion: editedVersion),
            key: editSessionKey(songID: song.id, cacheSnapshot: payload.cacheSnapshot)
        )
        return payload
    }

    private static func makeEditablePayload(
        for song: Song,
        sourceManager: SourceManager,
        cached: [LyricLine]?
    ) async -> EditablePayload {
        if await MetadataAssetStore.shared.hasUserClearedLyrics(forSongID: song.id) {
            // 用户清空过：编辑器从空白开始，不把文件里隐藏起来的那份又摆出来。
            // 源的快照照常记，保存时核对它有没有被别处改过。
            let snapshot: EditableSourceSnapshot
            switch await LyricsLoader.readAuthoritativeSourceText(for: song, sourceManager: sourceManager) {
            case .content(let content):
                snapshot = .content(normalizedSourceText(content))
            case .absent:
                snapshot = LyricsLoader.locallyMaterializedSourceText(for: song, sourceManager: sourceManager) == nil
                    ? .absent
                    : .unknown
            case .unavailable:
                snapshot = .unknown
            }
            return EditablePayload(text: "", structuredLines: nil, sourceSnapshot: snapshot)
        }
        if let cached, await LyricsLoader.prefersCachedDocument(for: song) {
            return EditablePayload(text: LyricsContentParser.serialize(cached), structuredLines: cached)
        }
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
            // 服务端把 GBK / Big5 歌词当 UTF-8 解坏了: 编辑器里放还原过的缓存, 不放乱码。
            // 快照仍是服务端那份原文, 保存时照常核对它有没有被别处改过。
            if LossyDecodedLyricsRepair.isDamaged(normalizedSource) {
                return EditablePayload(
                    text: cached.map { LyricsContentParser.serialize($0) } ?? "",
                    structuredLines: cached,
                    sourceSnapshot: sourceSnapshot
                )
            }
            // 字幕文档、毫秒逐字文档（.lys/.yrc/.qrc）、带 `[tt]` 伴随行的 LRC 和 TTML
            // 一样不能直接进编辑器：源码是 cue 或逐字标记，必须先经共享模型转成 LRC/ELRC 文本。
            if LyricsContentParser.isTTML(normalizedSource)
                || LyricsContentParser.isSubtitleDocument(normalizedSource)
                || WordTimedLyricsParser.detect(normalizedSource) != nil
                || LRCWordTimingCompanion.containsCompanionRows(normalizedSource) {
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
            // 编辑器只读源里真实存在的歌词：不做 Tier4 在线兜底，否则要多等一轮网络请求，
            // 且在线歌词会被预填成用户编辑。
            lines = await LyricsLoader.load(
                for: song,
                sourceManager: sourceManager,
                allowsAutomaticOnlineLyrics: false
            )
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
        await resolveTarget(for: song, sourceManager: sourceManager, sourcesStore: sourcesStore).mode
    }

    /// 探测写回目标,并说明这次落在哪里、为什么。几件事分开探测:是不是在用 Primuse 里的那一份、
    /// 这类音乐源收不收、音频文件和所在文件夹能不能写、这次连不连得上(`SaveLocationPolicy`)。
    static func resolveTarget(
        for song: Song,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        respectsCachedVersion: Bool = true
    ) async -> Target {
        let requested = EmbeddedLyricsCopyPolicy.mode(forSongID: song.id)
        let previouslyCleared = await MetadataAssetStore.shared.hasUserClearedLyrics(forSongID: song.id)
        if respectsCachedVersion, !previouslyCleared, await LyricsLoader.prefersCachedDocument(for: song) {
            return makeTarget(
                SaveLocationPolicy.lyricsPlan(.init(usesPrimuseVersion: true), requested: requested),
                preflight: nil
            )
        }
        let sourceType = sourcesStore.source(id: song.sourceID)?.type
        if await sourceManager.supportsSidecarWriting(for: song) {
            let access = await sourceManager.saveLocationAccess(for: song)
            let canEmbed = sourceType.map {
                EmbeddedLyricsCopyPolicy.canEmbed(
                    sourceType: $0,
                    format: song.fileFormat,
                    isCueTrack: song.isCueTrack,
                    isStreamDescriptor: song.isStreamDescriptor
                )
            } ?? false
            let facts = SaveLocationPolicy.Facts(
                source: .files,
                audioFile: access.audioFile,
                folder: access.folder,
                canEmbed: canEmbed
            )
            // 旁边的文件写不了时先按设置算一遍:不嵌入就只能存在 Primuse,不必再去列目录。
            if !access.folder.allowsAttempt {
                let plan = SaveLocationPolicy.lyricsPlan(facts, requested: requested)
                guard plan.destination == .audioFile else {
                    logResolution(plan, access: access, song: song)
                    return makeTarget(plan, preflight: nil, hasICloudConflict: access.hasICloudConflict)
                }
            }
            do {
                // 全库扫描期间音乐源的连接预算已被占住，预检要排队。
                // 十秒对内网 NAS 在扫描中的响应来说不够，而这是用户主动发起的
                // 一次操作，多等一会儿远好过误报成不可写。
                let preflight: SidecarWriteService.LyricsPreflightResult
                if access.folder.allowsAttempt {
                    preflight = try await MusicScraperService.preflightLyricsWriteWithTimeout(
                        seconds: 20,
                        sourceManager: sourceManager,
                        for: song
                    )
                } else {
                    // 只嵌入:看一眼旁边有没有歌词文件,不要求能写。
                    preflight = try await AsyncOperationTimeout.run(seconds: 20) {
                        let connector = try await sourceManager.sidecarWriteConnector(for: song)
                        return try await SidecarWriteService.shared.preflightEmbeddedLyricsWrite(
                            for: song,
                            using: connector
                        )
                    }
                }
                if previouslyCleared, preflight.replacesExistingFile {
                    return makeTarget(
                        SaveLocationPolicy.lyricsPlan(.init(usesPrimuseVersion: true), requested: requested),
                        preflight: nil
                    )
                }
                var plan = SaveLocationPolicy.lyricsPlan(
                    facts,
                    requested: requested,
                    lyricsDocumentExists: preflight.hasLyricsDocument
                )
                if !access.folder.allowsAttempt, preflight.hasLyricsDocument {
                    // 旁边已经有歌词文件、只嵌入时它也要跟着更新,可文件夹写不了:这次只能存在 Primuse。
                    plan = SaveLocationPolicy.Plan(
                        destination: .primuseOnly,
                        reason: access.folder == .noAccess ? .noFolderAccess : .folderNotWritable,
                        remedies: access.folder == .noAccess ? [.grantFolderAccess] : []
                    )
                }
                logResolution(plan, access: access, song: song)
                return makeTarget(plan, preflight: preflight, hasICloudConflict: access.hasICloudConflict)
            } catch let collision as LyricsSidecarReplacementCollision {
                // The picked file cannot be serialized and its replacement
                // name is another of the song's sources: keep the edit here
                // rather than overwrite that file.
                return Target(
                    mode: .localOnly(reason: collision.localizedDescription),
                    plan: SaveLocationPolicy.Plan(destination: .primuseOnly),
                    notice: collision.localizedDescription
                )
            } catch {
                return unreachableTarget(error)
            }
        }

        if sourceType == .jellyfin || sourceType == .emby || sourceType == .plex {
            do {
                let connector = try await sourceManager.connectorForSong(song)
                guard let server = connector as? any ServerLyricsConnector else {
                    let reason = String(localized: "tag_editor_lyrics_server_unsupported")
                    return Target(
                        mode: .unavailable(reason),
                        plan: SaveLocationPolicy.Plan(destination: .undetermined, reason: .unavailable),
                        notice: String(format: String(localized: "tag_editor_lyrics_writeback_unavailable"), reason)
                    )
                }
                let writes = server.serverLyricsCapabilities.canWrite && connector is any MediaServerWritebackConnector
                return makeTarget(
                    SaveLocationPolicy.lyricsPlan(.init(source: .mediaServer(writesLyrics: writes)), requested: requested),
                    preflight: nil
                )
            } catch {
                return unreachableTarget(error)
            }
        }

        return makeTarget(SaveLocationPolicy.lyricsPlan(.init(source: .readOnly), requested: requested), preflight: nil)
    }

    private static func unreachableTarget(_ error: any Error) -> Target {
        let description = SourceErrorPresentation.userFacingDescription(error)
        if SourceWriteProbeFailure.isTransient(error) {
            return Target(
                mode: .temporarilyUnavailable(description),
                plan: SaveLocationPolicy.Plan(destination: .undetermined, reason: .temporarilyUnreachable),
                notice: String(format: String(localized: "tag_editor_lyrics_writeback_retry"), description)
            )
        }
        return Target(
            mode: .unavailable(description),
            plan: SaveLocationPolicy.Plan(destination: .undetermined, reason: .unavailable),
            notice: String(format: String(localized: "tag_editor_lyrics_writeback_unavailable"), description)
        )
    }

    /// 判定依据记一行,诊断日志里能看出这次为什么落在这里。
    private static func logResolution(_ plan: SaveLocationPolicy.Plan, access: SaveLocationAccess, song: Song) {
        guard plan.reason != .none else { return }
        plog("Lyrics save location songID=\(song.id.prefix(8)) destination=\(plan.destination.rawValue) "
            + "reason=\(plan.reason.rawValue) audio=\(access.audioFile.rawValue) folder=\(access.folder.rawValue) "
            + "embed=\(plan.embeddingMode.rawValue) iCloudConflict=\(access.hasICloudConflict)")
    }

    /// 一个判定落成 `Mode` 和说明。只存在 Primuse 的,说明同时作为 `.localOnly` 的原因。
    private static func makeTarget(
        _ plan: SaveLocationPolicy.Plan,
        preflight: SidecarWriteService.LyricsPreflightResult?,
        hasICloudConflict: Bool = false
    ) -> Target {
        let notice = noticeText(for: plan, preflight: preflight)
        let mode: Mode
        switch plan.destination {
        case .lyricsFile, .lyricsFileAndAudioFile, .audioFile:
            if let preflight {
                mode = .sidecar(preflight)
            } else {
                mode = .localOnly(reason: notice)
            }
        case .mediaServer:
            mode = .mediaServer
        case .primuseOnly:
            mode = .localOnly(reason: notice)
        case .undetermined:
            mode = .unavailable(notice)
        }
        return Target(mode: mode, plan: plan, notice: notice, hasICloudConflict: hasICloudConflict)
    }

    /// 每种情况一条说明,开头先说这次落在哪里,后面才是原因和怎么解决。
    static func noticeText(
        for plan: SaveLocationPolicy.Plan,
        preflight: SidecarWriteService.LyricsPreflightResult?
    ) -> String {
        let fileName = preflight?.fileName ?? ""
        let replaces = preflight?.replacesExistingFile == true
        var parts: [String] = []
        switch plan.destination {
        case .lyricsFile:
            let template: String = replaces
                ? String(localized: "save_location_lyrics_file_replace %@")
                : String(localized: "save_location_lyrics_file_new %@")
            parts.append(String(format: template, fileName))
        case .lyricsFileAndAudioFile:
            let template: String = replaces
                ? String(localized: "save_location_lyrics_file_and_audio_replace %@")
                : String(localized: "save_location_lyrics_file_and_audio_new %@")
            parts.append(String(format: template, fileName))
        case .audioFile:
            parts.append(String(localized: "save_location_lyrics_audio"))
        case .mediaServer:
            parts.append(String(localized: "save_location_lyrics_server"))
        case .primuseOnly, .undetermined:
            break
        }
        switch plan.reason {
        case .none, .temporarilyUnreachable, .unavailable:
            break
        case .usesPrimuseVersion:
            parts.append(String(localized: "save_location_primuse_version"))
        case .readOnlySource:
            parts.append(String(localized: "save_location_lyrics_read_only_source"))
        case .serverTakesNoLyrics:
            parts.append(String(localized: "save_location_server_takes_no_lyrics"))
        case .noFolderAccess:
            parts.append(String(localized: "save_location_lyrics_no_folder_access"))
        case .noFolderAccessEmbedsOnly:
            parts.append(String(localized: "save_location_lyrics_no_folder_embeds_only"))
        case .folderNotWritable:
            parts.append(String(localized: "save_location_lyrics_folder_not_writable"))
        case .folderNotWritableEmbedsOnly:
            parts.append(String(localized: "save_location_lyrics_folder_not_writable_embeds_only"))
        case .audioFileNotWritable:
            if plan.destination == .primuseOnly {
                parts.append(String(localized: "save_location_lyrics_audio_not_writable"))
            } else {
                parts.append(String(localized: "save_location_lyrics_audio_not_writable_embed_part"))
            }
        case .readOnlyVolume:
            parts.append(String(localized: "save_location_read_only_volume"))
        case .formatCannotEmbed:
            parts.append(String(localized: "save_location_lyrics_format_cannot_embed"))
        }
        if let hint = remedyHint(plan.remedies) { parts.append(hint) }
        return joinedSentences(parts)
    }

    /// 句子接起来:以全角句号、问号、叹号、引号收尾的(中文、日文)直接接,其他语言隔一个空格。
    nonisolated static func joinedSentences(_ parts: [String]) -> String {
        parts.reduce(into: "") { result, part in
            guard !part.isEmpty else { return }
            if let last = result.last, !"。！？」）".contains(last) { result.append(" ") }
            result.append(part)
        }
    }

    private static func remedyHint(_ remedies: [SaveLocationPolicy.Remedy]) -> String? {
        let grant = remedies.contains(.grantFolderAccess)
        let embed = remedies.contains(.embedThisSong)
        switch (grant, embed) {
        case (true, true): return String(localized: "save_location_hint_grant_or_embed")
        case (true, false): return String(localized: "save_location_hint_grant")
        case (false, true): return String(localized: "save_location_hint_embed")
        case (false, false): return nil
        }
    }

    /// 保存完只存在 Primuse 时给用户的话:落在哪里、为什么、之后会不会自动写进文件。
    /// `requested` 是保存时交出去的写回目标;它不是只存在 Primuse,说明是写的时候被拒绝了。
    static func keptLocallyMessage(requested target: Target) -> String {
        guard case .localOnly = target.mode else {
            return String(localized: "save_location_lyrics_refused") + "\n" + joinedSentences([
                String(localized: "save_location_lyrics_not_rewritten"),
                String(localized: "save_location_lyrics_save_again"),
            ])
        }
        switch target.plan.reason {
        case .usesPrimuseVersion, .readOnlySource, .serverTakesNoLyrics:
            // 本来就只在 Primuse:没有要解决的,也不提「之后」。
            return target.notice
        case .noFolderAccess, .folderNotWritable, .audioFileNotWritable, .readOnlyVolume:
            return target.notice + "\n" + joinedSentences([
                String(localized: "save_location_lyrics_not_rewritten"),
                String(localized: "save_location_lyrics_save_again"),
            ])
        case .none, .noFolderAccessEmbedsOnly, .folderNotWritableEmbedsOnly, .formatCannotEmbed,
             .temporarilyUnreachable, .unavailable:
            return target.notice + "\n" + String(localized: "save_location_lyrics_not_rewritten")
        }
    }

    /// 来源现在的样子,和编辑器打开时拍的快照同一种写法。授权了所在文件夹之后,原来看不见的
    /// 歌词文件也看得见了,继续保存之前要重拍一次,否则保存会当成来源被别处改过。
    static func currentSourceSnapshot(for song: Song, sourceManager: SourceManager) async -> EditableSourceSnapshot {
        switch await LyricsLoader.readAuthoritativeSourceText(for: song, sourceManager: sourceManager) {
        case .content(let text):
            return .content(text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        case .absent:
            return .absent
        case .unavailable:
            return .unknown
        }
    }

    // MARK: - 保存

    /// 保存结果。`errorMessage` 非 nil 表示写回失败，调用方原样展示给用户。
    struct SaveOutcome {
        enum Persistence: Equatable {
            case sidecar
            /// 「只嵌入」：歌词只进了音频文件，没有歌词文件。
            case embedded
            case mediaServer
            case localOnly
        }

        var updatedSong: Song
        var errorMessage: String?
        var persistence: Persistence
        var cacheSnapshot: LyricsDocumentFingerprint?
        /// 「歌词文件并嵌入音频」时，嵌入的那份没写成的原因。歌词文件已经存好，
        /// 这里失败不回滚保存，只交给调用方提示。「只嵌入」时嵌入就是这次保存本身，
        /// 失败走 `errorMessage`。
        var embeddedCopyError: String?
        /// Only a definite rejected write, before remote verification, can
        /// enter the existing local-override transaction.
        var allowsLocalFallback = false
        /// The source acknowledged the change and passed readback, but the cache transaction failed.
        var sourceWriteVerifiedBeforeCacheFailure = false
        /// 存成功了，但有一句需要用户知道的话（比如文件里的歌词删不掉，只在 Primuse 里隐藏了）。
        /// 取值见 `lyrics_version_hidden_in_primuse`、`lyrics_version_sidecar_deleted_embedded_hidden`、
        /// `lyrics_version_embedded_remaining`。
        var notice: String?
        /// 歌词在别处有更新，这次没有覆盖。界面可以给两个选择：再存一次（用草稿覆盖），或者只存在本机。
        var changedElsewhere = false
        /// 编辑器手里的快照在哪一步对不上了。只在这里决定能不能拿新快照重试。
        var staleSnapshot: StaleSnapshot?

        enum StaleSnapshot: String, Equatable {
            /// 源里的歌词（歌词文件、服务器）和打开编辑器时不一样了。
            case source
            /// 本机歌词缓存和打开编辑器时不一样了。
            case cache
        }

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
        guard !Task.isCancelled else { return cancelledSave(for: song, mode: mode) }
        let mutationKey = mutationKey(for: song, mode: mode)
        await mutationGate.acquire(mutationKey)
        let action = normalized(text).isEmpty ? "clear" : "save"
        let touchesAudioFile: Bool
        if case .sidecar = mode {
            touchesAudioFile = await sourceManager.lyricsEmbeddingMode(for: song) != .off
        } else {
            touchesAudioFile = false
        }
        let sessionKey = editSessionKey(songID: song.id, cacheSnapshot: cacheSnapshot)
        // 要换掉的那一份按编辑器打开时定位的来；没有打开记录（直接调用的保存）就现在定位一次，重试也沿用它。
        let embeddedAnchor: EmbeddedAnchor?
        if touchesAudioFile {
            if let anchor = editSessions[sessionKey]?.anchor {
                embeddedAnchor = anchor
            } else {
                embeddedAnchor = await embeddedReplacementAnchor(forSongID: song.id)
            }
        } else {
            embeddedAnchor = nil
        }
        if let refusal = verifyEditTarget(
            for: song,
            library: library,
            sessionKey: sessionKey,
            anchor: embeddedAnchor,
            touchesAudioFile: touchesAudioFile
        ) {
            await mutationGate.release(mutationKey)
            logLyricsMutation(action, stage: "refused", song: song, destination: destinationName(for: mode))
            return SaveOutcome(updatedSong: song, errorMessage: refusal, persistence: persistence(for: mode))
        }
        var song = song
        if touchesAudioFile, let verified = library.storedSong(id: song.id), EditTarget(song).isSameLocation(as: verified) {
            song.fileSize = verified.fileSize
            song.lastModified = verified.lastModified
            song.revision = verified.revision
        }
        logLyricsMutation(
            action,
            stage: "before",
            song: song,
            destination: destinationName(for: mode),
            draftText: action == "clear" ? "" : text,
            draftLines: structuredLines
        )
        let previousVersion: LyricsPreviousVersionHandling = newVersionRequests.contains(song.id)
            ? .keep
            : .forget
        let draft = draftIdentity(text: text, structuredLines: structuredLines)
        let openedFile = editSessions[sessionKey]?.openedFile
        var effectiveMode = mode
        var effectiveSourceSnapshot = sourceSnapshot
        var effectiveCacheSnapshot = cacheSnapshot
        if let confirmed = confirmedOverwrites.removeValue(forKey: song.id), confirmed.draft == draft {
            // 用户看过「歌词在别处有更新」又点了一次保存：用那时重新读到的快照，草稿覆盖新的那份。
            plog("📝 lyrics save overwrites the newer version songID=\(song.id.prefix(8))")
            effectiveMode = confirmed.mode
            effectiveSourceSnapshot = confirmed.sourceSnapshot
            effectiveCacheSnapshot = confirmed.cacheSnapshot
        }
        var outcome = await performSave(
            text: text,
            for: song,
            mode: effectiveMode,
            allowRemoval: allowRemoval,
            structuredLines: structuredLines,
            sourceSnapshot: effectiveSourceSnapshot,
            cacheSnapshot: effectiveCacheSnapshot,
            previousVersion: previousVersion,
            embeddedAnchor: embeddedAnchor,
            openedFile: openedFile,
            sourceManager: sourceManager,
            library: library
        )
        if let stale = outcome.staleSnapshot, !Task.isCancelled {
            outcome = await recoverFromStaleSnapshot(
                stale,
                failure: outcome,
                draft: draft,
                text: text,
                for: song,
                mode: effectiveMode,
                allowRemoval: allowRemoval,
                structuredLines: structuredLines,
                sourceSnapshot: effectiveSourceSnapshot,
                previousVersion: previousVersion,
                editedVersion: editSessions[sessionKey]?.editedVersion,
                embeddedAnchor: embeddedAnchor,
                openedFile: openedFile,
                sourceManager: sourceManager,
                library: library
            )
        }
        if outcome.allowsLocalFallback, !normalized(text).isEmpty, !Task.isCancelled {
            outcome = await performSave(
                text: text, for: song,
                mode: .localOnly(reason: MetadataWriteFailurePolicy.localSaveNotice),
                allowRemoval: false, structuredLines: structuredLines,
                sourceSnapshot: effectiveSourceSnapshot, cacheSnapshot: effectiveCacheSnapshot,
                previousVersion: previousVersion,
                embeddedAnchor: nil,
                sourceManager: sourceManager, library: library
            )
        }
        await mutationGate.release(mutationKey)
        if outcome.succeeded {
            newVersionRequests.remove(song.id)
            editSessions[sessionKey] = nil
        }
        logLyricsMutation(
            action,
            stage: outcome.succeeded ? "after" : "failed",
            song: outcome.updatedSong,
            destination: destinationName(for: outcome.persistence),
            lines: await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
        )
        if outcome.errorMessage == nil, let structuredLines,
           LyricsDocumentSource.of(structuredLines)?.kind == .transcript {
            await MetadataAssetStore.shared.rememberLyricsCandidate(structuredLines, forSongID: song.id)
        }
        return outcome
    }

    // MARK: - 另存为新版本、快照过期后的重试

    /// 编辑器「另存为新版本」：下一次保存这首歌时，被换下来的旧版本留在来源列表里。保存成功后作废。
    private static var newVersionRequests: Set<String> = []

    static func requestNewVersion(forSongID songID: String) {
        newVersionRequests.insert(songID)
    }

    static func cancelNewVersionRequest(forSongID songID: String) {
        newVersionRequests.remove(songID)
    }

    private struct ConfirmedOverwrite {
        let draft: String
        let mode: Mode
        let sourceSnapshot: EditableSourceSnapshot
        let cacheSnapshot: LyricsDocumentFingerprint?
    }

    /// 告诉过用户「歌词在别处有更新」的那几首：同一份草稿再保存一次，就按那时重新读到的快照覆盖。
    private static var confirmedOverwrites: [String: ConfirmedOverwrite] = [:]

    private static func draftIdentity(text: String, structuredLines: [LyricLine]?) -> String {
        normalized(text) + "\u{1F}" + (structuredLines.map { LyricsDocumentFingerprint(lines: $0).rawValue } ?? "")
    }

    /// 编辑器打开后缓存或源变了。重新读一遍源和缓存：
    /// - 只是自动路径动了缓存（按设置重挑内嵌原文、核对歌词文件、后台补全），或者别处存进去的正好就是
    ///   这份草稿：拿新快照直接再存一次，用户看不出来。要换掉的内嵌原文仍是编辑器打开时定位的那一份。
    /// - 源里的歌词被改过、缓存是用户在别处保存的另一份、或者重新探测出源和本机有冲突：不覆盖，告诉用户
    ///   「歌词在别处有更新」，草稿留在编辑器里。用户再点一次保存就用草稿覆盖；界面也可以给「只存在本机」。
    private static func recoverFromStaleSnapshot(
        _ stale: SaveOutcome.StaleSnapshot,
        failure: SaveOutcome,
        draft: String,
        text: String,
        for song: Song,
        mode: Mode,
        allowRemoval: Bool,
        structuredLines: [LyricLine]?,
        sourceSnapshot: EditableSourceSnapshot,
        previousVersion: LyricsPreviousVersionHandling,
        editedVersion: [LyricLine]?,
        embeddedAnchor: EmbeddedAnchor?,
        openedFile: OpenedAudioFile? = nil,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> SaveOutcome {
        let store = MetadataAssetStore.shared
        let cached = await store.cachedLyrics(forSongID: song.id)
        let cacheSnapshot = cached.map(LyricsDocumentFingerprint.init(lines:))
        guard !Task.isCancelled else { return failure }
        var retryMode = mode
        var retrySource = sourceSnapshot
        let changedByUser: Bool
        let alreadySaved: Bool
        switch stale {
        case .source:
            retrySource = await currentSourceSnapshot(for: song, sourceManager: sourceManager)
            if case .sidecar(let original) = mode {
                let refreshed = await resolveTarget(
                    for: song, sourceManager: sourceManager, sourcesStore: AppServices.shared.sourcesStore,
                    respectsCachedVersion: false
                )
                guard case .sidecar(let target) = refreshed.mode, target.targetPath == original.targetPath else {
                    return failure
                }
                retryMode = refreshed.mode
            }
            changedByUser = true
            switch retrySource {
            case .content(let content): alreadySaved = normalized(content) == normalized(text)
            case .absent: alreadySaved = normalized(text).isEmpty
            case .unknown: return failure
            }
        case .cache:
            let choice = await store.userLyricsChoice(forSongID: song.id)
            let versions = await store.lyricsVersionPreferences(forSongID: song.id)
            changedByUser = choice?.isCleared == true || versions?.cleared == true || versions?.selectedID != nil
                || LyricsUserChoicePolicy.pins(choice, currentFingerprint: cacheSnapshot?.rawValue)
            alreadySaved = normalized(cached.map { LyricsContentParser.serialize($0) } ?? "") == normalized(text)
        }
        func changedElsewhere(from outcome: SaveOutcome) -> SaveOutcome {
            confirmedOverwrites[song.id] = ConfirmedOverwrite(
                draft: draft,
                mode: retryMode,
                sourceSnapshot: retrySource,
                cacheSnapshot: cacheSnapshot
            )
            plog("📝 lyrics save found a newer version songID=\(song.id.prefix(8)) stale=\(stale.rawValue)")
            var result = outcome
            result.staleSnapshot = nil
            result.changedElsewhere = true
            result.errorMessage = String(localized: "lyrics_version_changed_elsewhere")
            return result
        }
        guard !(changedByUser && !alreadySaved) else {
            return changedElsewhere(from: failure)
        }
        plog("📝 lyrics save retries with a fresh snapshot songID=\(song.id.prefix(8)) stale=\(stale.rawValue)")
        let retried = await performSave(
            text: text,
            for: song,
            mode: retryMode,
            allowRemoval: allowRemoval,
            structuredLines: structuredLines,
            sourceSnapshot: retrySource,
            cacheSnapshot: cacheSnapshot,
            previousVersion: previousVersion,
            editedVersion: stale == .cache && !changedByUser ? editedVersion : nil,
            embeddedAnchor: embeddedAnchor,
            openedFile: openedFile,
            sourceManager: sourceManager,
            library: library
        )
        // 重读之后又被抢先了一次：不再自己重试，交给用户。
        return retried.staleSnapshot == nil ? retried : changedElsewhere(from: retried)
    }

    private static func staleFailure(
        for song: Song,
        persistence: SaveOutcome.Persistence,
        _ kind: SaveOutcome.StaleSnapshot
    ) -> SaveOutcome {
        var outcome = SaveOutcome(
            updatedSong: song,
            errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
            persistence: persistence
        )
        outcome.staleSnapshot = kind
        return outcome
    }

    private static func cancelledSave(for song: Song, mode: Mode) -> SaveOutcome {
        SaveOutcome(
            updatedSong: song,
            errorMessage: URLError(.cancelled).localizedDescription,
            persistence: persistence(for: mode)
        )
    }

    private static func mutationKey(for song: Song, mode: Mode) -> String {
        switch mode {
        case .sidecar(let target):
            return song.sourceID + "\u{0}sidecar\u{0}" + target.targetPath
        case .mediaServer:
            return song.sourceID + "\u{0}server\u{0}" + song.filePath
        case .checking, .localOnly, .unavailable, .temporarilyUnavailable:
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
        previousVersion: LyricsPreviousVersionHandling,
        editedVersion: [LyricLine]? = nil,
        embeddedAnchor: EmbeddedAnchor?,
        openedFile: OpenedAudioFile? = nil,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> SaveOutcome {
        guard !Task.isCancelled else { return cancelledSave(for: song, mode: mode) }
        var updated = song
        let content = normalized(text)
        let requestedPersistence = persistence(for: mode)
        var savedPersistence = requestedPersistence
        var savedCacheSnapshot = cacheSnapshot
        var embeddedCopy = EmbeddedCopyResult.notAttempted
        var clearNotice: String?
        // 嵌入只跟着「写歌词文件」这条路走：媒体服务器和只读源本来就碰不到音频文件。
        let embeddingMode: LyricsEmbeddingMode
        let lyricsDocumentExists: Bool
        if case .sidecar(let target) = mode {
            embeddingMode = await sourceManager.lyricsEmbeddingMode(for: song)
            lyricsDocumentExists = target.hasLyricsDocument
        } else {
            embeddingMode = .off
            lyricsDocumentExists = false
        }

        if content.isEmpty {
            guard allowRemoval else {
                return SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_empty_error"),
                    persistence: requestedPersistence
                )
            }
            // 旁边没有任何歌词文档、又开了嵌入时，歌词就在音频文件里：删的是嵌入的那份。
            let removesEmbeddedLyrics = embeddingMode != .off && !lyricsDocumentExists
            // 源写不了（只存在本机），或者旁边本来就没有歌词文件、又没开嵌入：文件里没有能删的，
            // 只在 Primuse 里清空，记下「用户清空了」，之后自动路径不会再把歌词填回来。
            var clearsOnlyInPrimuse = false
            if case .localOnly = mode { clearsOnlyInPrimuse = true }
            if case .sidecar(let target) = mode,
               !target.replacesExistingFile,
               !removesEmbeddedLyrics {
                clearsOnlyInPrimuse = true
            }
            if clearsOnlyInPrimuse {
                return await clearOnlyInPrimuse(
                    for: song,
                    persistence: requestedPersistence,
                    cacheSnapshot: cacheSnapshot,
                    library: library
                )
            }
            guard await sourceStillMatches(
                sourceSnapshot,
                for: updated,
                mode: mode,
                sourceManager: sourceManager
            ) else {
                return staleFailure(for: song, persistence: requestedPersistence, .source)
            }
            let externalMutationToken: UUID?
            guard !Task.isCancelled else { return cancelledSave(for: song, mode: mode) }
            switch mode {
            case .sidecar, .mediaServer:
                externalMutationToken = await MetadataAssetStore.shared.beginLyricsMutation(
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot
                )
                guard externalMutationToken != nil else {
                    return staleFailure(for: song, persistence: requestedPersistence, .cache)
                }
            case .checking, .localOnly, .unavailable, .temporarilyUnavailable:
                externalMutationToken = nil
            }
            if Task.isCancelled {
                if let externalMutationToken {
                    await MetadataAssetStore.shared.cancelLyricsMutation(
                        forSongID: song.id,
                        token: externalMutationToken
                    )
                }
                return cancelledSave(for: song, mode: mode)
            }
            let removalError: String?
            if removesEmbeddedLyrics {
                // 清空：删掉文件里全部原文字段（译文保留），读回来确认；删不掉的如实说。
                let write = await writeEmbeddedField(
                    .removeAllOriginals,
                    for: updated,
                    openedFile: openedFile,
                    sourceManager: sourceManager,
                    library: library
                )
                embeddedCopy = write.copy
                removalError = embeddedCopy.failureReason
                savedPersistence = .embedded
                if case .written = embeddedCopy, case .done(let result, let remaining)? = write.report {
                    await MetadataAssetStore.shared.updateEmbeddedLyricsRecords(
                        forSongID: song.id,
                        result: result,
                        anchor: nil,
                        text: nil
                    )
                    if remaining { clearNotice = String(localized: "lyrics_version_embedded_remaining") }
                }
            } else {
                removalError = await remove(for: updated, mode: mode, sourceManager: sourceManager)
            }
            if let error = removalError {
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
                recordReplacedAudioFile(embeddedCopy, songID: song.id, library: library)
                if externalMutationToken == nil {
                    return staleFailure(for: song, persistence: requestedPersistence, .cache)
                }
                var failure = SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: savedPersistence
                )
                failure.sourceWriteVerifiedBeforeCacheFailure = true
                return failure
            }
            savedCacheSnapshot = nil
            updated.lyricsFileName = nil
            updated.lyricsText = nil
            let keptEmbeddedLyrics = await MetadataAssetStore.shared.embeddedFallbackLyrics(forSongID: song.id)
            if !removesEmbeddedLyrics, embeddingMode == .off, keptEmbeddedLyrics != nil {
                // 歌词文件删了，音频文件里自带的那份没开嵌入、不能动：它只在 Primuse 里隐藏。
                clearNotice = String(localized: "lyrics_version_sidecar_deleted_embedded_hidden")
            }
            if case .sidecar(let target) = mode, !removesEmbeddedLyrics {
                LyricsDocumentPinStore.shared.forgetFile(named: target.fileName, forSongID: song.id)
            }
            if !removesEmbeddedLyrics, embeddingMode != .off {
                // 歌词文件删掉了，嵌入的那份也要删，否则下次扫描会把它读回来。
                let write = await writeEmbeddedField(
                    .removeAllOriginals,
                    for: updated,
                    openedFile: openedFile,
                    sourceManager: sourceManager,
                    library: library
                )
                embeddedCopy = write.copy
                if case .written = embeddedCopy, case .done(let result, let remaining)? = write.report {
                    await MetadataAssetStore.shared.updateEmbeddedLyricsRecords(
                        forSongID: song.id,
                        result: result,
                        anchor: nil,
                        text: nil
                    )
                    if remaining { clearNotice = String(localized: "lyrics_version_embedded_remaining") }
                }
            }
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
                return staleFailure(for: song, persistence: requestedPersistence, .source)
            }
            guard !Task.isCancelled else { return cancelledSave(for: song, mode: mode) }
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
            // 「只嵌入」且旁边还没有歌词文档：不新建歌词文件，音频文件就是这次保存的去处。
            let skipsLyricsFile = !staysLocal && EmbeddedLyricsCopyPolicy.skipsLyricsFile(
                embeddingMode,
                lyricsDocumentExists: lyricsDocumentExists
            )
            if skipsLyricsFile { savedPersistence = .embedded }
            let savesLocally = savedPersistence == .localOnly
            if savesLocally {
                writebackLines = writebackLines.map(promotingLocalTranslationProvenance)
            }
            for index in writebackLines.indices {
                writebackLines[index].documentIsLocalOverride = savesLocally && index == 0
            }
            // 存进了哪个文件,播放页的来源标签就照它写(#357);只存在本机时标「本机修改」,不用另记。
            if !savesLocally {
                if skipsLyricsFile {
                    writebackLines = LyricsDocumentSource.embedded.stamped(writebackLines)
                } else if case .sidecar(let target) = mode {
                    writebackLines = LyricsDocumentSource.file(target.fileName).stamped(writebackLines)
                }
            }
            // 要换掉的那一份内嵌原文已经在编辑器打开时定位好了；写进去的格式跟着它（逐字的写逐字、TTML 写 TTML）。
            let embedText = Self.embeddedText(for: writebackLines, anchor: embeddedAnchor)
            let replaceOperation = EmbeddedLyricsFieldEditor.Operation.replace(
                text: embedText,
                anchor: embeddedAnchor?.text
            )
            var externalMutationToken: UUID?
            if !staysLocal {
                externalMutationToken = await MetadataAssetStore.shared.beginLyricsMutation(
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot
                )
                guard externalMutationToken != nil else {
                    return staleFailure(for: song, persistence: requestedPersistence, .cache)
                }
                if Task.isCancelled {
                    if let externalMutationToken {
                        await MetadataAssetStore.shared.cancelLyricsMutation(
                            forSongID: song.id,
                            token: externalMutationToken
                        )
                    }
                    return cancelledSave(for: song, mode: mode)
                }
                // Once the source write starts, finish its cache transaction
                // even if the presenting view has since been dismissed.
                let writeError: WriteFailure?
                if skipsLyricsFile {
                    let write = await writeEmbeddedField(
                        replaceOperation,
                        for: updated,
                        openedFile: openedFile,
                        sourceManager: sourceManager,
                        library: library
                    )
                    embeddedCopy = write.copy
                    writeError = embeddedCopy.failureReason.map {
                        WriteFailure($0, allowsLocalSave: embeddedCopy.allowsLocalSave)
                    }
                    if case .written = embeddedCopy, case .done(let result, _)? = write.report {
                        await MetadataAssetStore.shared.updateEmbeddedLyricsRecords(
                            forSongID: song.id,
                            result: result,
                            anchor: embeddedAnchor?.text,
                            text: embedText
                        )
                    }
                } else {
                    writeError = await write(
                        writebackLines,
                        content: persistenceContent(
                            validation.normalizedContent,
                            lines: writebackLines,
                            mode: mode
                        ),
                        for: updated,
                        mode: mode,
                        sourceManager: sourceManager
                    )
                }
                if let error = writeError {
                    if let externalMutationToken {
                        await MetadataAssetStore.shared.cancelLyricsMutation(
                            forSongID: song.id,
                            token: externalMutationToken
                        )
                    }
                    var failure = SaveOutcome(
                        updatedSong: song,
                        errorMessage: String(
                            format: String(localized: "tag_editor_lyrics_write_failed"),
                            error.message
                        ),
                        persistence: requestedPersistence
                    )
                    failure.allowsLocalFallback = error.allowsLocalSave
                    return failure
                }
            }
            // 用户保存的这一份就是这首歌正在用的版本，自动路径从此不能把它换掉；
            // 被替换下来的旧版本不再留在来源候选里（另存为新版本时留着）。
            let cacheStored: Bool
            if let externalMutationToken {
                cacheStored = await MetadataAssetStore.shared.commitLyricsMutation(
                    writebackLines,
                    forSongID: song.id,
                    token: externalMutationToken,
                    origin: .user,
                    previousVersion: previousVersion,
                    replacingEditedVersion: editedVersion
                )
            } else {
                cacheStored = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                    writebackLines,
                    forSongID: song.id,
                    expectedFingerprint: cacheSnapshot,
                    origin: .user,
                    previousVersion: previousVersion,
                    replacingEditedVersion: editedVersion
                )
            }
            if !staysLocal, !skipsLyricsFile, case .sidecar(let target) = mode {
                // A picked `.yrc` is saved as the `.ttml` beside it; from now on
                // the song reads what was just saved.
                LyricsDocumentPinStore.shared.followSave(toFileName: target.fileName, forSongID: song.id)
            }
            if cacheStored {
                // 按读回来的那份记：缓存读出来时会规整一遍，下次保存比的是读回来的指纹。
                savedCacheSnapshot = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
                    .map(LyricsDocumentFingerprint.init(lines:))
                    ?? LyricsDocumentFingerprint(lines: writebackLines)
                // 记下写进源的那份：之后从源读回它不算「别处更新」，读到别的才会换掉用户保存的这份。
                if !staysLocal {
                    let sourceLines: [LyricLine]
                    if skipsLyricsFile {
                        sourceLines = LyricsContentParser.parseText(embedText)
                    } else if case .sidecar(let target) = mode {
                        sourceLines = LyricsParser.parseDocument(
                            persistenceContent(validation.normalizedContent, lines: writebackLines, mode: mode),
                            fileName: target.fileName
                        )
                    } else {
                        sourceLines = LyricsContentParser.parseText(validation.normalizedContent)
                    }
                    await MetadataAssetStore.shared.noteSavedSourceDocument(sourceLines, forSongID: song.id)
                }
            } else {
                // A local-only document has no other durable copy. For an
                // external write, the source may already contain the update,
                // but source/cache divergence is still a partial failure and
                // must not be reported as an atomic success.
                recordReplacedAudioFile(embeddedCopy, songID: song.id, library: library)
                if externalMutationToken == nil {
                    return staleFailure(for: song, persistence: savedPersistence, .cache)
                }
                var failure = SaveOutcome(
                    updatedSong: song,
                    errorMessage: String(localized: "tag_editor_lyrics_verify_failed"),
                    persistence: savedPersistence
                )
                failure.sourceWriteVerifiedBeforeCacheFailure = true
                return failure
            }
            // LRC mirrors may intentionally yield to the richer local cache,
            // but an existing TTML document is itself word-level and must stay
            // addressable for later edits, deletion, and stale-cache refresh.
            // 没写歌词文件时，记下的 .ttml 位置指向的是一个并不存在的文件，不能沿用。
            let retainedReference = skipsLyricsFile
                ? nil
                : retainedTTMLReference(for: song, mode: mode)
            updated.lyricsFileName = cacheStored
                ? (retainedReference
                    ?? MetadataAssetStore.shared.expectedLyricsFileName(for: song.id))
                : song.lyricsFileName
            updated.lyricsText = writebackLines.map(\.text).joined(separator: "\n")
            if !staysLocal, !skipsLyricsFile, embeddingMode != .off {
                let write = await writeEmbeddedField(
                    replaceOperation,
                    for: updated,
                    openedFile: openedFile,
                    sourceManager: sourceManager,
                    library: library
                )
                embeddedCopy = write.copy
                if case .written = embeddedCopy, case .done(let result, _)? = write.report {
                    await MetadataAssetStore.shared.updateEmbeddedLyricsRecords(
                        forSongID: song.id,
                        result: result,
                        anchor: embeddedAnchor?.text,
                        text: embedText
                    )
                }
            }
        }

        // Source/cache verification may await the network for many seconds.
        // Merge only the lyric fields into the latest library row so a tag,
        // artwork, favorite, or background refresh completed in that window
        // is not replaced by the editor's older Song snapshot.
        // 刮削会把封面 / 歌词指针先排进资料库的合批窗口 (updateAssetReferences),
        // 窗口内读到的还是旧行。整行替换之前先把窗口里的补丁落地, 否则这里
        // 读到的旧封面会被原样写回去, 调用方拿到的 committedSong 也是旧值。
        library.flushPendingAssetReferencePatches()
        var committedSong = updated
        if case .written(let identity) = embeddedCopy {
            identity.apply(to: &committedSong)
        }
        if var latestSong = library.storedSong(id: updated.id) {
            latestSong.lyricsFileName = updated.lyricsFileName
            latestSong.lyricsText = updated.lyricsText
            if case .written(let identity) = embeddedCopy {
                // 音频文件被整体替换过，库里记的大小、修改时间和版本要跟上，
                // 否则下次扫描会把它当成被别人改过的文件。
                identity.apply(to: &latestSong)
            }
            library.replaceSong(latestSong)
            committedSong = latestSong
        }
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: committedSong.id)
        var outcome = SaveOutcome(
            updatedSong: committedSong,
            errorMessage: nil,
            persistence: savedPersistence,
            cacheSnapshot: savedCacheSnapshot
        )
        if case .failed(let reason, _) = embeddedCopy {
            outcome.embeddedCopyError = reason
        }
        outcome.notice = clearNotice
        return outcome
    }

    /// 只在 Primuse 里清空：删本机缓存、记下「用户清空了」，音频文件和歌词文件都不动。
    /// 文件里自带的歌词还在时如实告诉用户：已在 Primuse 里隐藏，文件里的歌词没有动。
    private static func clearOnlyInPrimuse(
        for song: Song,
        persistence: SaveOutcome.Persistence,
        cacheSnapshot: LyricsDocumentFingerprint?,
        library: MusicLibrary
    ) async -> SaveOutcome {
        let store = MetadataAssetStore.shared
        let cached = await store.cachedLyrics(forSongID: song.id)
        let cachedKind = cached.flatMap { LyricsDocumentSource.of($0)?.kind }
        let embeddedFallback = await store.embeddedFallbackLyrics(forSongID: song.id)
        let embeddedAlternatives = await store.embeddedLyricsAlternatives(forSongID: song.id)
        let hasEmbeddedRecord = embeddedFallback != nil || embeddedAlternatives != nil
        let fileKeepsLyrics = hasEmbeddedRecord
            || cachedKind == .file || cachedKind == .embedded || cachedKind == .server
            || cachedKind == .appleMusic
        guard await store.invalidateLyricsCacheIfUnchanged(
            forSongID: song.id,
            expectedFingerprint: cacheSnapshot,
            marksCleared: true
        ) else {
            return staleFailure(for: song, persistence: persistence, .cache)
        }
        library.flushPendingAssetReferencePatches()
        var committed = song
        committed.lyricsText = nil
        if var latest = library.storedSong(id: song.id) {
            // 文件还在，引用照旧留着：用户以后在来源页选回它时还找得到。
            latest.lyricsText = nil
            library.replaceSong(latest)
            committed = latest
        }
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
        var outcome = SaveOutcome(
            updatedSong: committed,
            errorMessage: nil,
            persistence: fileKeepsLyrics ? .localOnly : persistence
        )
        if fileKeepsLyrics {
            outcome.notice = String(localized: "lyrics_version_hidden_in_primuse")
        }
        return outcome
    }

    // MARK: - 嵌入音频文件的随身副本

    private struct EmbeddedFileIdentity: Sendable {
        let filePath: String
        let fileSize: Int64
        let lastModified: Date?
        let revision: String?

        func apply(to song: inout Song) {
            song.filePath = filePath
            song.fileSize = fileSize
            song.lastModified = lastModified
            song.revision = revision
        }
    }

    private enum EmbeddedCopyResult: Sendable {
        /// 没开嵌入，或者这首歌的来源 / 格式不参与嵌入。
        case notAttempted
        case written(EmbeddedFileIdentity)
        case failed(String, allowsLocalSave: Bool = false)

        var failureReason: String? {
            if case .failed(let reason, _) = self { return reason }
            return nil
        }

        var allowsLocalSave: Bool {
            if case .failed(_, let allowed) = self { return allowed }
            return false
        }
    }

    /// 音频文件已经换成了新版本，之后的步骤却失败了：库里记的文件身份仍要跟上，
    /// 否则下一次写入会把刚写过的文件当成被别处改过而拒绝。
    private static func recordReplacedAudioFile(
        _ result: EmbeddedCopyResult,
        songID: String,
        library: MusicLibrary
    ) {
        guard case .written(let identity) = result else { return }
        library.flushPendingAssetReferencePatches()
        guard var latest = library.storedSong(id: songID) else { return }
        identity.apply(to: &latest)
        library.replaceSong(latest)
    }

    /// 把歌词写进(或移出)音频文件。要整首下载、改写、替换、回读，所以只在用户选了
    /// 嵌入、且这首歌的来源和格式支持时由调用方发起。
    private static func writeEmbeddedCopy(
        _ edit: EmbeddedLyricsEdit,
        for song: Song,
        openedFile: OpenedAudioFile? = nil,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> EmbeddedCopyResult {
        // 保存开始后，资料库重读也可能发现别处换过文件。只接续本次已确认的文件或 Primuse 自己的写入。
        var target = song
        if let openedFile {
            guard let captured = openedFile.target(for: library.storedSong(id: song.id) ?? song) else {
                return .failed(String(localized: "lyrics_version_target_moved"))
            }
            target = captured
        } else if let latest = library.storedSong(id: song.id) {
            guard EditTarget(song).isSameLocation(as: latest) else {
                return .failed(String(localized: "lyrics_version_target_moved"))
            }
            guard EditTarget(song).isSameFile(as: latest) || ownAudioWrites[song.id]?.isSameFile(as: latest) == true else {
                return .failed(String(localized: "lyrics_version_target_changed"))
            }
            target.fileSize = latest.fileSize
            target.lastModified = latest.lastModified
            target.revision = latest.revision
        }
        do {
            let written = try await sourceManager.writeEmbeddedLyrics(edit, for: target)
            recordOwnAudioWrite(written)
            return .written(EmbeddedFileIdentity(
                filePath: written.filePath,
                fileSize: written.fileSize,
                lastModified: written.lastModified,
                revision: written.revision
            ))
        } catch {
            plog("⚠️ Embedded lyrics copy failed for songID=\(song.id): \(error.localizedDescription)")
            return .failed(error.localizedDescription,
                           allowsLocalSave: MetadataWriteFailurePolicy.allowsLocalSave(error))
        }
    }

    /// 嵌入字段里各家播放器都认的只有行级 LRC 文本，逐字标记会被原样显示成乱码。
    /// 所以这份副本去掉逐字时间轴，保留每行时间戳、同时间戳的译文行和文件头；
    /// 逐字数据仍然只在歌词文件和本地缓存里。
    nonisolated static func embeddedCopyContent(_ lines: [LyricLine]) -> String {
        LyricsContentParser.serialize(lines.map { line in
            var lineLevel = line
            lineLevel.syllables = nil
            return lineLevel
        })
    }

    /// 写进音频文件时要换掉的那一份内嵌原文，以及它是什么格式。
    struct EmbeddedAnchor: Sendable, Equatable {
        /// 文件里正在用的那份原文（读标签时记下的原样文字）。nil 表示认不出：
        /// 写入器只在文件里只有一份原文时换它，否则只在没有默认字段时补一个。
        let text: String?
        let isWordLevel: Bool
        let isTTML: Bool
    }

    /// 定位要换掉的那一份：
    /// - 缓存里是内嵌歌词：按整份文档指纹对上记下的那几份原文中的一份；用户保存过的、对不上时用上次写进去的那份；
    /// - 缓存是歌词文件、在线歌词（同时嵌入或另选过）：文件里正在显示的那份，就是按设置挑出来的那份；
    /// - 文件里只有一份原文（没有记录）：不给文字，交给写入器按「唯一那一份」处理。
    /// 解析放在后台做。必须在缓存换成新内容之前取。
    static func embeddedReplacementAnchor(forSongID songID: String) async -> EmbeddedAnchor {
        let store = MetadataAssetStore.shared
        let alternatives = await store.embeddedLyricsAlternatives(forSongID: songID)
        let cached = await store.cachedLyrics(forSongID: songID)
        let pinned = await store.isUserPinned(forSongID: songID)
        let priority = EmbeddedLyricsVariantPriority.current()
        return await Task.detached(priority: .userInitiated) {
            resolveEmbeddedAnchor(alternatives: alternatives, cached: cached, pinned: pinned, priority: priority)
        }.value
    }

    nonisolated static func resolveEmbeddedAnchor(
        alternatives: EmbeddedLyricsAlternatives?,
        cached: [LyricLine]?,
        pinned: Bool,
        priority: EmbeddedLyricsVariantPriority
    ) -> EmbeddedAnchor {
        let cachedIsEmbedded = cached.map { LyricsDocumentSource.of($0)?.kind == .embedded } ?? false
        func anchor(_ text: String?) -> EmbeddedAnchor {
            guard let text else {
                let wordLevel = cachedIsEmbedded && cached.map { LyricsTimingLevel(lines: $0) == .word } == true
                return EmbeddedAnchor(text: nil, isWordLevel: wordLevel, isTTML: false)
            }
            return EmbeddedAnchor(
                text: text,
                isWordLevel: LyricsTimingLevel(lines: LyricsContentParser.parseText(text)) == .word,
                isTTML: LyricsContentParser.isTTML(text)
            )
        }
        guard let alternatives else { return anchor(nil) }
        if cachedIsEmbedded, let cached {
            if let variant = LyricsLoader.embeddedVariant(matching: cached, in: alternatives) {
                return anchor(variant.text)
            }
            if pinned, let inUse = alternatives.inUseText,
               alternatives.variants.contains(where: { EmbeddedLyricsFieldEditor.sameLyrics($0.text, inUse) }) {
                return anchor(inUse)
            }
            return anchor(nil)
        }
        return anchor(EmbeddedLyricsVariantPolicy.preferred(in: alternatives.variants, priority: priority)?.text)
    }

    /// 写进音频文件的文字。被换掉的那份是逐字或 TTML、而这次的歌词也带逐字时间时照原格式写，
    /// 不把文件里的逐字时间降成逐行；其余情况写各家播放器都认的行级 LRC。
    nonisolated static func embeddedText(for lines: [LyricLine], anchor: EmbeddedAnchor?) -> String {
        if let anchor, lines.contains(where: \.isWordLevel) {
            if anchor.isTTML { return LyricsContentParser.serializeTTML(lines) }
            if anchor.isWordLevel { return LyricsContentParser.serialize(lines) }
        }
        return embeddedCopyContent(lines)
    }

    private struct EmbeddedFieldWrite {
        let copy: EmbeddedCopyResult
        let report: EmbeddedLyricsFieldReport?
    }

    /// 按字段改写音频文件里的歌词，连同写入器的回报一起交回。
    private static func writeEmbeddedField(
        _ operation: EmbeddedLyricsFieldEditor.Operation,
        for song: Song,
        openedFile: OpenedAudioFile? = nil,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> EmbeddedFieldWrite {
        let request = EmbeddedLyricsFieldRequest(operation)
        let copy = await writeEmbeddedCopy(.field(request), for: song, openedFile: openedFile, sourceManager: sourceManager, library: library)
        return EmbeddedFieldWrite(copy: copy, report: EmbeddedLyricsFieldReports.take(request.id))
    }

    // MARK: - 歌词来源页：按原文改写一个文件

    struct DocumentSaveOutcome {
        var errorMessage: String?
        /// The file changed after the editor opened it; reopen before editing.
        var changedElsewhere = false
        /// The file was saved but the audio file's embedded copy was not.
        var embeddedCopyError: String?
        /// The library row after the save, for the caller's `onSave`.
        var updatedSong: Song?

        var succeeded: Bool { errorMessage == nil }
    }

    /// Writes the raw editor's text over one of the song's lyric files, in
    /// that file's own format and encoding. Nothing else beside the song is
    /// touched. When it is the file the song reads, the song shows the new
    /// text at once, and the audio file's embedded copy follows if the
    /// listener embeds lyrics.
    static func saveDocument(
        _ entry: LyricsDocumentCatalog.Entry,
        text: String,
        original: LyricsDocumentCatalog.Content,
        for song: Song,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> DocumentSaveOutcome {
        let validation = LyricsRawDocumentPolicy.validate(text, fileName: entry.name)
        if let message = LyricsDocumentCatalog.message(for: validation.outcome, fileName: entry.name) {
            return DocumentSaveOutcome(errorMessage: message)
        }
        let key = song.sourceID + "\u{0}document\u{0}" + song.id + "\u{0}" + entry.name.lowercased()
        await mutationGate.acquire(key)
        let embeds = await sourceManager.lyricsEmbeddingMode(for: song) != .off
        let touchesAudioFile = entry.isActive && embeds
        if let refusal = verifyEditTarget(
            for: song,
            library: library,
            sessionKey: song.id + "\u{1F}document\u{1F}" + entry.name.lowercased(),
            anchor: nil,
            touchesAudioFile: touchesAudioFile
        ) {
            await mutationGate.release(key)
            logLyricsMutation("save-document", stage: "refused", song: song, destination: "file", lines: nil)
            return DocumentSaveOutcome(errorMessage: refusal)
        }
        logLyricsMutation("save-document", stage: "before", song: song, destination: "file", lines: validation.lines)
        let outcome = await performDocumentSave(
            entry,
            lines: validation.lines,
            data: original.encoding.data(for: text),
            original: original,
            for: song,
            sourceManager: sourceManager,
            library: library
        )
        await mutationGate.release(key)
        logLyricsMutation(
            "save-document",
            stage: outcome.succeeded ? "after" : "failed",
            song: outcome.updatedSong ?? song,
            destination: "file",
            lines: await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
        )
        return outcome
    }

    private static func performDocumentSave(
        _ entry: LyricsDocumentCatalog.Entry,
        lines: [LyricLine],
        data: Data,
        original: LyricsDocumentCatalog.Content,
        for song: Song,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> DocumentSaveOutcome {
        do {
            _ = try await MusicScraperService.replaceLyricsDocumentWithTimeout(
                seconds: 30,
                sourceManager: sourceManager,
                for: song,
                named: entry.name,
                data: data,
                expecting: original.data
            )
        } catch let error as SidecarWriteService.LyricsDocumentWriteError {
            var outcome = DocumentSaveOutcome(errorMessage: error.localizedDescription)
            if case .changedElsewhere = error { outcome.changedElsewhere = true }
            return outcome
        } catch {
            return DocumentSaveOutcome(errorMessage: String(
                format: String(localized: "tag_editor_lyrics_write_failed"),
                SourceErrorPresentation.userFacingDescription(error)
            ))
        }

        var outcome = DocumentSaveOutcome()
        if entry.isActive {
            let embeds = await sourceManager.lyricsEmbeddingMode(for: song) != .off
            let embeddedAnchor: EmbeddedAnchor? = embeds ? await embeddedReplacementAnchor(forSongID: song.id) : nil
            do {
                // 改写的就是正在用的那份文件：改之前的内容被替换掉了，不再留在来源候选里。
                try await LyricsDocumentCatalog.show(
                    lines,
                    from: entry,
                    for: song,
                    sourceManager: sourceManager,
                    previousVersion: .forget
                )
            } catch {
                // The file is saved; the song only shows it after its next read.
                plog("⚠️ Lyrics document saved but not cached for songID=\(song.id): \(error.localizedDescription)")
            }
            if embeds {
                let text = embeddedText(for: lines, anchor: embeddedAnchor)
                let write = await writeEmbeddedField(
                    .replace(text: text, anchor: embeddedAnchor?.text),
                    for: song,
                    sourceManager: sourceManager,
                    library: library
                )
                if case .written = write.copy, case .done(let result, _)? = write.report {
                    await MetadataAssetStore.shared.updateEmbeddedLyricsRecords(
                        forSongID: song.id,
                        result: result,
                        anchor: embeddedAnchor?.text,
                        text: text
                    )
                }
                recordReplacedAudioFile(write.copy, songID: song.id, library: library)
                outcome.embeddedCopyError = write.copy.failureReason
            }
        }
        library.flushPendingAssetReferencePatches()
        outcome.updatedSong = library.song(id: song.id) ?? song
        return outcome
    }

    // MARK: - 编辑目标的锁定与写入记录

    /// 编辑器打开时这首歌在资料库里的样子。保存时核对音乐源和文件路径；要改音频文件时再核对文件身份
    /// （大小、revision 相同，修改时间差在 2 秒内）。
    struct EditTarget: Equatable, Sendable {
        let songID: String
        let sourceID: String
        let filePath: String
        let fileSize: Int64
        let lastModified: Date?
        let revision: String?

        init(_ song: Song) {
            songID = song.id
            sourceID = song.sourceID
            filePath = song.filePath
            fileSize = song.fileSize
            lastModified = song.lastModified
            revision = song.revision
        }

        func isSameLocation(as song: Song) -> Bool {
            sourceID == song.sourceID && filePath == song.filePath
        }

        func isSameFile(as song: Song) -> Bool {
            guard isSameLocation(as: song), fileSize == song.fileSize, revision == song.revision else {
                return false
            }
            // 文件系统、监听重读和写入结果给的修改时间精度不一样，差两秒以内算同一个。
            guard let lastModified, let other = song.lastModified else { return true }
            return abs(lastModified.timeIntervalSince(other)) <= 2
        }
    }

    struct OpenedAudioFile: Equatable, Sendable {
        let identity: EditTarget
        let ownWriteAtOpening: EditTarget?

        @MainActor
        func target(for song: Song) -> Song? {
            guard identity.songID == song.id, identity.isSameLocation(as: song) else { return nil }
            if let own = ownAudioWrites[song.id], own != ownWriteAtOpening, own.isSameFile(as: song) {
                return song
            }
            var target = song
            target.fileSize = identity.fileSize
            target.lastModified = identity.lastModified
            target.revision = identity.revision
            return target
        }
    }

    static func openedAudioFile(for song: Song, sourceManager: SourceManager) async -> OpenedAudioFile? {
        let own = ownAudioWrites[song.id]
        guard let current = await sourceManager.localLyricsEditingIdentity(for: song) else { return nil }
        return OpenedAudioFile(identity: EditTarget(current), ownWriteAtOpening: own)
    }

    /// 一次编辑：打开时固定住的目标和要换掉的那一份内嵌原文。按「歌曲 + 打开时的缓存指纹」记，
    /// 保存成功后作废；同一首歌开了两个编辑器各是各的。
    private struct EditSession {
        var target: EditTarget
        var openedFile: OpenedAudioFile?
        let anchor: EmbeddedAnchor?
        var editedVersion: [LyricLine]?
    }

    private static var editSessions: [String: EditSession] = [:]
    /// Primuse 自己刚改写过的音频文件（嵌入歌词、改标签、嵌封面换了文件身份）：同一次编辑接着保存不算「被别处改过」。
    private static var ownAudioWrites: [String: EditTarget] = [:]

    private static func editSessionKey(songID: String, cacheSnapshot: LyricsDocumentFingerprint?) -> String {
        songID + "\u{1F}" + (cacheSnapshot?.rawValue ?? "-")
    }

    private static func openEditSession(_ session: EditSession, key: String) {
        if editSessions.count > 64 { editSessions.removeAll() }
        editSessions[key] = session
    }

    /// 标签、封面、歌词写进音频文件成功后记一笔。写回协调器以外改了音频文件的地方（标签编辑器、
    /// 封面嵌入）也调它，编辑器接着保存歌词时就不会被自己的锁拦下。
    static func recordOwnAudioWrite(_ song: Song) {
        if ownAudioWrites.count > 256 { ownAudioWrites.removeAll() }
        ownAudioWrites[song.id] = EditTarget(song)
    }

    /// 保存前再核对一次目标：音乐源和文件路径没变；要写音频文件时文件还是打开时那一个
    /// （或者是 Primuse 自己刚写过的那一个，或者传进来的这首已经就是资料库里现在的样子）。
    /// 对不上就拒绝并说明，不写任何文件；用户确认还是这首歌、再保存一次就按现在的文件写。
    /// 资料库里查不到的歌（文件夹浏览直接播放、插件在线歌曲）按传进来的这首写。
    private static func verifyEditTarget(
        for song: Song,
        library: MusicLibrary,
        sessionKey: String,
        anchor: EmbeddedAnchor?,
        touchesAudioFile: Bool
    ) -> String? {
        if PodcastPlaybackSong.isEpisode(song) || song.sourceID == AppleMusicLibraryIdentity.sourceID {
            return nil
        }
        guard let stored = library.storedSong(id: song.id) else { return nil }
        var accepted = [editSessions[sessionKey]?.target ?? EditTarget(song)]
        if let openedFile = editSessions[sessionKey]?.openedFile { accepted.append(openedFile.identity) }
        if let own = ownAudioWrites[song.id] { accepted.append(own) }
        func relock() {
            openEditSession(
                EditSession(target: EditTarget(stored), openedFile: editSessions[sessionKey]?.openedFile,
                            anchor: editSessions[sessionKey]?.anchor ?? anchor,
                            editedVersion: editSessions[sessionKey]?.editedVersion),
                key: sessionKey
            )
        }
        guard stored.sourceID == song.sourceID,
              accepted.contains(where: { $0.isSameLocation(as: stored) }) else {
            plog("📝 lyrics target refused songID=\(song.id.prefix(8)) reason=moved opened=\(shortHash(song.filePath)) now=\(shortHash(stored.filePath))")
            relock()
            return String(localized: "lyrics_version_target_moved")
        }
        guard touchesAudioFile else { return nil }
        guard accepted.contains(where: { $0.isSameFile(as: stored) }) else {
            plog("📝 lyrics target refused songID=\(song.id.prefix(8)) reason=file-changed size=\(song.fileSize)->\(stored.fileSize)")
            relock()
            return String(localized: "lyrics_version_target_changed")
        }
        return nil
    }

    /// 每次保存、清空、删除版本记一行：歌曲 id 前 8 位、文件名哈希前 8 位、写入去处、行数、内容指纹前 8 位。
    /// 不记歌词正文。写前一行、写后回读一行，两首歌的前后指纹对得上就能判断有没有写错目标。
    /// 解析和算指纹放在后台，上千行的文字稿也不卡界面。
    private static func logLyricsMutation(
        _ action: String,
        stage: String,
        song: Song,
        destination: String,
        lines: [LyricLine]? = nil,
        draftText: String? = nil,
        draftLines: [LyricLine]? = nil
    ) {
        let songID = String(song.id.prefix(8))
        let fileName = (song.filePath as NSString).lastPathComponent
        Task.detached(priority: .utility) {
            let resolved: [LyricLine]?
            if let lines {
                resolved = lines
            } else if let draftText {
                let normalizedDraft = draftText.replacingOccurrences(of: "\r\n", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resolved = normalizedDraft.isEmpty ? [] : (draftLines ?? LyricsContentParser.parseText(normalizedDraft))
            } else {
                resolved = nil
            }
            let fingerprint = resolved.map {
                $0.isEmpty ? "empty" : String(MetadataAssetStore.lyricsFingerprint($0).prefix(8))
            } ?? "-"
            plog("📝 lyrics \(action) \(stage) songID=\(songID) file=\(shortHash(fileName)) dest=\(destination) lines=\(resolved?.count ?? 0) fp=\(fingerprint)")
        }
    }

    nonisolated private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func destinationName(for mode: Mode) -> String {
        switch mode {
        case .sidecar: return "file"
        case .mediaServer: return "server"
        case .localOnly, .checking, .unavailable, .temporarilyUnavailable: return "local"
        }
    }

    private static func destinationName(for persistence: SaveOutcome.Persistence) -> String {
        switch persistence {
        case .sidecar: return "file"
        case .embedded: return "embedded"
        case .mediaServer: return "server"
        case .localOnly: return "local"
        }
    }

    // MARK: - 歌词来源页：删除此版本

    struct VersionDeletionOutcome {
        var errorMessage: String?
        /// 删好了，有一句需要用户知道的话（只在 Primuse 里隐藏了）。
        var notice: String?
        /// 删的是正在用的那份、而且一份都不剩：等同于清空。
        var cleared = false
        /// 文件在列出来之后被别处改过：重新列一次再删。
        var changedElsewhere = false
        var updatedSong: Song?

        var succeeded: Bool { errorMessage == nil }
    }

    /// 删掉这一版歌词：App 里记着的候选只从候选里去掉；音频文件里的一份内嵌原文只删内容完全相同的那一个字段；
    /// 旁边的歌词文件删掉这个文件（文件还得是列出来时那样，删完回读确认）；源里删不掉的在 Primuse 里隐藏。
    /// 删的是正在用的那份时换上剩下里最合适的一份（不钉住），一份不剩就等同于清空。
    static func deleteVersion(
        _ entry: LyricsDocumentCatalog.Entry,
        plan: LyricsDocumentCatalog.DeletionPlan,
        expecting original: LyricsDocumentCatalog.Content?,
        for song: Song,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        library: MusicLibrary
    ) async -> VersionDeletionOutcome {
        let key = song.sourceID + "\u{0}version\u{0}" + song.id
        await mutationGate.acquire(key)
        let destination: String
        switch plan {
        case .forget: destination = "local"
        case .embeddedField: destination = "embedded"
        case .file: destination = "file"
        case .serverVersion: destination = "server"
        case .readOnly: destination = "hidden"
        }
        let versionLines: [LyricLine]? = entry.candidate?.lines
            ?? original.map { LyricsParser.parseDocument($0.text, fileName: entry.name) }
        if let refusal = verifyEditTarget(
            for: song,
            library: library,
            sessionKey: song.id + "\u{1F}version",
            anchor: nil,
            touchesAudioFile: destination == "embedded"
        ) {
            await mutationGate.release(key)
            logLyricsMutation("delete-version", stage: "refused", song: song, destination: destination)
            return VersionDeletionOutcome(errorMessage: refusal)
        }
        logLyricsMutation("delete-version", stage: "before", song: song, destination: destination, lines: versionLines)
        let outcome = await performVersionDeletion(
            entry,
            plan: plan,
            versionLines: versionLines,
            expecting: original,
            for: song,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore,
            library: library
        )
        await mutationGate.release(key)
        logLyricsMutation(
            "delete-version",
            stage: outcome.succeeded ? "after" : "failed",
            song: outcome.updatedSong ?? song,
            destination: destination,
            lines: await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
        )
        return outcome
    }

    private static func performVersionDeletion(
        _ entry: LyricsDocumentCatalog.Entry,
        plan: LyricsDocumentCatalog.DeletionPlan,
        versionLines: [LyricLine]?,
        expecting original: LyricsDocumentCatalog.Content?,
        for song: Song,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        library: MusicLibrary
    ) async -> VersionDeletionOutcome {
        let store = MetadataAssetStore.shared
        var outcome = VersionDeletionOutcome()
        if entry.isEmbedded || entry.serverText != nil || entry.cachedOnly {
            let hides: Bool
            if case .readOnly = plan { hides = true } else { hides = false }
            do {
                try await LyricsDocumentCatalog.remove(
                    [entry], for: song, sourceManager: sourceManager, hidingOnly: hides,
                    sourcesStore: sourcesStore, library: library
                )
                if hides { outcome.notice = String(localized: "lyrics_version_hidden_in_primuse") }
                outcome.cleared = await store.hasUserClearedLyrics(forSongID: song.id)
                outcome.updatedSong = library.storedSong(id: song.id)
            } catch {
                outcome.errorMessage = error.localizedDescription
                if case SidecarWriteService.LyricsDocumentWriteError.changedElsewhere = error { outcome.changedElsewhere = true }
            }
            return outcome
        }
        var deleted = Set<String>()
        if let versionLines, !versionLines.isEmpty { deleted.insert(MetadataAssetStore.lyricsFingerprint(versionLines)) }
        func hide(_ notice: String) async -> Bool {
            guard let versionLines, !versionLines.isEmpty else { return false }
            await store.hideLyricsVersion(versionLines, forSongID: song.id)
            outcome.notice = notice
            return true
        }
        switch plan {
        case .serverVersion:
            outcome.errorMessage = String(localized: "tag_editor_lyrics_verify_failed")
            return outcome
        case .forget:
            if let candidate = entry.candidate {
                await store.removeLyricsCandidate(candidate.id, forSongID: song.id)
            }
        case .readOnly:
            guard await hide(String(localized: "lyrics_version_hidden_in_primuse")) else {
                outcome.errorMessage = String(localized: "tag_editor_lyrics_verify_failed")
                return outcome
            }
        case .embeddedField(let text):
            let write = await writeEmbeddedField(
                .removeOne(text),
                for: song,
                sourceManager: sourceManager,
                library: library
            )
            if case .written = write.copy, case .done(let result, _)? = write.report {
                await store.updateEmbeddedLyricsRecords(forSongID: song.id, result: result, anchor: text, text: nil)
                recordReplacedAudioFile(write.copy, songID: song.id, library: library)
                if let candidate = entry.candidate {
                    await store.removeLyricsCandidate(candidate.id, forSongID: song.id)
                }
            } else if write.report == .notLocated || write.copy.allowsLocalSave {
                // 认不准是哪一个字段、或者没有写权限：文件没动，改为在 Primuse 里隐藏并说明原因。
                let notice = write.report == .notLocated
                    ? String(localized: "lyrics_version_delete_hidden_not_located")
                    : String(localized: "lyrics_version_delete_hidden_no_permission")
                guard await hide(notice) else {
                    outcome.errorMessage = write.copy.failureReason ?? String(localized: "tag_editor_lyrics_verify_failed")
                    return outcome
                }
            } else {
                outcome.errorMessage = String(
                    format: String(localized: "tag_editor_lyrics_write_failed"),
                    write.copy.failureReason ?? String(localized: "tag_editor_lyrics_verify_failed")
                )
                return outcome
            }
        case .file:
            if let failure = await deleteLyricsDocument(
                named: entry.name,
                expecting: original?.data,
                for: song,
                sourceManager: sourceManager
            ) {
                return failure
            }
            LyricsDocumentPinStore.shared.forgetFile(named: entry.name, forSongID: song.id)
            // 每次写缓存都会把文件的内容记成候选：文件删了，这些候选也拿掉，免得又被换回来。
            if let versionLines, !versionLines.isEmpty {
                await store.forgetLyricsVersion(versionLines, forSongID: song.id)
            }
        }
        if entry.isActive {
            // 「拿掉正在用的 → 换上剩下的 / 标清空」在歌词写入事务里做完，自动加载插不进来。
            let current = await store.cachedLyrics(forSongID: song.id)
            if let current, !current.isEmpty { deleted.insert(MetadataAssetStore.lyricsFingerprint(current)) }
            guard let token = await store.beginLyricsMutation(
                forSongID: song.id,
                expectedFingerprint: current.map(LyricsDocumentFingerprint.init(lines:))
            ) else {
                outcome.errorMessage = String(localized: "tag_editor_lyrics_verify_failed")
                return outcome
            }
            let replacement = await LyricsDocumentCatalog.remainingVersion(
                for: song,
                excluding: deleted,
                sourceManager: sourceManager,
                sourcesStore: sourcesStore
            )
            let committed: Bool
            if let replacement {
                committed = await store.commitLyricsMutation(
                    replacement,
                    forSongID: song.id,
                    token: token,
                    origin: .automatic,
                    previousVersion: .forget
                )
            } else {
                committed = await store.commitLyricsRemoval(forSongID: song.id, token: token)
                outcome.cleared = committed
            }
            guard committed else {
                await store.cancelLyricsMutation(forSongID: song.id, token: token)
                outcome.errorMessage = String(localized: "tag_editor_lyrics_verify_failed")
                return outcome
            }
        }
        library.flushPendingAssetReferencePatches()
        if outcome.cleared, var latest = library.storedSong(id: song.id) {
            latest.lyricsText = nil
            library.replaceSong(latest)
        }
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
        outcome.updatedSong = library.song(id: song.id) ?? song
        return outcome
    }

    /// 删掉歌旁边的一个歌词文件：删之前确认它还是列出来时那样，删完回读确认它不在了。
    private static func deleteLyricsDocument(
        named fileName: String,
        expecting originalData: Data?,
        for song: Song,
        sourceManager: SourceManager
    ) async -> VersionDeletionOutcome? {
        var failure = VersionDeletionOutcome()
        let deletedPath: String
        do {
            deletedPath = try await AsyncOperationTimeout.run(seconds: 30) {
                let connector = try await sourceManager.sidecarWriteConnector(for: song)
                let target = try await SidecarWriteService.shared.lyricsDocumentTarget(
                    named: fileName,
                    for: song,
                    using: connector
                )
                guard let path = target.existingPath else {
                    throw SidecarWriteService.LyricsDocumentWriteError.documentMissing(fileName)
                }
                if let originalData {
                    let size = target.existingSize ?? Int64(originalData.count)
                    guard size == Int64(originalData.count) else {
                        throw SidecarWriteService.LyricsDocumentWriteError.changedElsewhere(fileName)
                    }
                    let current = try await connector.fetchRange(path: path, offset: 0, length: size)
                    guard current == originalData else {
                        throw SidecarWriteService.LyricsDocumentWriteError.changedElsewhere(fileName)
                    }
                }
                try await connector.deleteFile(at: path)
                return path
            }
        } catch let error as SidecarWriteService.LyricsDocumentWriteError {
            failure.errorMessage = error.localizedDescription
            if case .changedElsewhere = error { failure.changedElsewhere = true }
            return failure
        } catch {
            failure.errorMessage = String(
                format: String(localized: "tag_editor_lyrics_write_failed"),
                SourceErrorPresentation.userFacingDescription(error)
            )
            return failure
        }
        await sourceManager.invalidateReadCachesAfterSidecarWrite(for: song, paths: [deletedPath])
        await sourceManager.invalidateDownloadCacheAfterSidecarWrite(for: song)
        // 按 ID 寻址的网盘删除先回成功、列目录过一会儿才跟上：等一小段再确认。
        for delay in [0, 250, 750, 1_500, 3_000] {
            if delay > 0 {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { break }
            }
            if let exists = try? await MusicScraperService.lyricsDocumentExistsWithTimeout(
                seconds: 5,
                sourceManager: sourceManager,
                for: song,
                named: fileName
            ), !exists {
                return nil
            }
        }
        failure.errorMessage = String(localized: "tag_editor_lyrics_verify_failed")
        return failure
    }

    // MARK: - 写 / 删

    private static func sourceStillMatches(
        _ expected: EditableSourceSnapshot,
        for song: Song,
        mode: Mode,
        sourceManager: SourceManager
    ) async -> Bool {
        switch mode {
        case .checking, .unavailable, .temporarilyUnavailable:
            return false
        case .localOnly:
            if case .unknown = expected { return true }
            // A hidden read-only document may still exist when its local replacement is created.
            if case .absent = expected,
               await MetadataAssetStore.shared.hasUserClearedLyrics(forSongID: song.id) { return true }
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

    private struct WriteFailure {
        let message: String
        let allowsLocalSave: Bool
        init(_ message: String, allowsLocalSave: Bool = false) {
            self.message = message
            self.allowsLocalSave = allowsLocalSave
        }
    }

    /// Retain the permission result until the local cache transaction commits.
    private static func write(
        _ lines: [LyricLine],
        content: String,
        for song: Song,
        mode: Mode,
        sourceManager: SourceManager
    ) async -> WriteFailure? {
        switch mode {
        case .localOnly:
            return nil
        case .checking:
            return WriteFailure(String(localized: "tag_editor_lyrics_writeback_checking"))
        case .unavailable(let reason):
            return WriteFailure(reason)
        case .temporarilyUnavailable(let reason):
            return WriteFailure(String(
                format: String(localized: "tag_editor_lyrics_writeback_retry"),
                reason
            ))
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
                    return WriteFailure(String(localized: "tag_editor_lyrics_verify_failed"))
                }
                guard result.lyricsWritten else {
                    return WriteFailure(result.errors.joined(separator: "\n"),
                                        allowsLocalSave: result.lyricsWriteDenied)
                }
                guard let verified = result.verifiedLyricsWrite,
                      verified.target == target,
                      LyricsContentParser.areContentsSemanticallyEquivalent(
                        content,
                        verified.content
                      ) else {
                    return WriteFailure(String(localized: "tag_editor_lyrics_verify_failed"))
                }
                return nil
            } catch {
                return WriteFailure(SourceErrorPresentation.userFacingDescription(error),
                                    allowsLocalSave: MetadataWriteFailurePolicy.allowsLocalSave(error))
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
                return WriteFailure((result.errors + result.unsupported).joined(separator: "\n"))
            }
            guard await verifyMediaServerWrite(
                expectedContent: content,
                song: song,
                sourceManager: sourceManager
            ) else {
                return WriteFailure(String(localized: "tag_editor_lyrics_verify_failed"))
            }
            return nil
        }
    }

    static func replaceServerVersion(for song: Song, expecting original: String, with text: String?,
                                     sourceManager: SourceManager) async throws {
        let connector = try await sourceManager.auxiliaryConnector(for: song)
        guard let server = connector as? any ServerLyricsConnector,
              text == nil ? server.serverLyricsCapabilities.canDelete : server.serverLyricsCapabilities.canWrite,
              case .content(let current) = await server.readServerLyrics(for: song.filePath),
              current == original else {
            throw SidecarWriteService.LyricsDocumentWriteError.changedElsewhere(song.title)
        }
        if let text {
            if let failure = await write(LyricsParser.parse(text), content: text, for: song, mode: .mediaServer,
                                         sourceManager: sourceManager) {
                throw SourceError.connectionFailed(failure.message)
            }
        } else if let error = await remove(for: song, mode: .mediaServer, sourceManager: sourceManager) {
            throw SourceError.connectionFailed(error)
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
        case .temporarilyUnavailable(let reason):
            return String(
                format: String(localized: "tag_editor_lyrics_writeback_retry"),
                reason
            )
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
                guard await verifySidecarRemoval(
                    song: song,
                    removedFileName: target.fileName,
                    sourceManager: sourceManager
                ) else {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                return nil
            } catch {
                return SourceErrorPresentation.userFacingDescription(error)
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

    private static func verifyMediaServerWrite(
        expectedContent: String,
        song: Song,
        sourceManager: SourceManager
    ) async -> Bool {
        guard let connector = try? await sourceManager.connectorForSong(song),
              let server = connector as? any ServerLyricsConnector,
              let readback = await server.fetchServerLyrics(for: song.filePath) else {
            return false
        }
        return LyricsContentParser.areContentsSemanticallyEquivalent(
            expectedContent,
            readback
        )
    }

    private static func verifySidecarRemoval(
        song: Song,
        removedFileName: String,
        sourceManager: SourceManager
    ) async -> Bool {
        // ID-backed cloud providers can acknowledge deletion before their
        // directory listing converges. Treat the delete response as provisional
        // and retry the authoritative target lookup for a bounded interval.
        for delay in [0, 250, 750, 1_500, 3_000, 5_000] {
            if delay > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return false
                }
            }
            if let preflight = try? await MusicScraperService.preflightLyricsWriteWithTimeout(
                seconds: 5,
                sourceManager: sourceManager,
                for: song
            ), !preflight.replacesExistingFile {
                return true
            }
            // A song with several lyric files keeps the others: the next one
            // becomes current, so "nothing to replace" never comes. The file
            // that was deleted being gone is the proof then.
            if let exists = try? await MusicScraperService.lyricsDocumentExistsWithTimeout(
                seconds: 5,
                sourceManager: sourceManager,
                for: song,
                named: removedFileName
            ), !exists {
                return true
            }
        }
        return false
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
        case .checking, .mediaServer, .unavailable, .temporarilyUnavailable:
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
        case .checking, .localOnly, .unavailable, .temporarilyUnavailable:
            return lines
        }
    }

    private static func requiresBilingualLRCPersistence(_ mode: Mode) -> Bool {
        switch mode {
        case .sidecar, .mediaServer:
            return true
        case .checking, .localOnly, .unavailable, .temporarilyUnavailable:
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
            // 整份 .vtt/.srt 粘贴进来能通过校验，但落盘的必须是 LRC 文本：
            // .lrc 文件和媒体服务器的歌词字段里都不该出现 cue 标记。
            if LyricsContentParser.isSubtitleDocument(editableContent) {
                return LyricsContentParser.serialize(lines)
            }
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
        case .checking, .localOnly, .unavailable, .temporarilyUnavailable:
            return .localOnly
        }
    }
}
