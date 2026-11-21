import Foundation
import PrimuseKit

/// File-backed documents and retained source candidates share one selection list.
/// Only file-backed entries can write their original bytes back to the source.
@MainActor
enum LyricsDocumentCatalog {
    struct Entry: Identifiable, Equatable, Sendable {
        let document: LyricsSidecarDocument
        let format: LyricsDocumentFormat?
        let isActive: Bool
        /// Whether the raw editor may write this file back. A read-only
        /// format on an ID-addressed drive has no address a save could use.
        let isEditable: Bool
        let translation: LyricsSidecarTranslation?
        var candidate: LyricsSourceCollection.Candidate? = nil
        /// 「另存为新版本」留下的旧版本：它原来所在的文件已经换了内容，删它只从候选里拿掉。
        var isKeptVersion = false

        var id: String { document.path }
        var name: String { document.name }
    }

    struct Documents: Equatable, Sendable {
        let entries: [Entry]
        /// A CUE virtual track reads the file assigned to it.
        let canSwitch: Bool
        /// The song is showing an edit saved only in Primuse, not any file.
        let usesLocalCopy: Bool
        let sourceIsWritable: Bool
        var sourceError: String? = nil

        /// The same listing after the listener switched to `id`; nil marks
        /// no file as the one playback shows.
        func activating(_ id: String?) -> Documents {
            Documents(
                entries: entries.map { entry in
                    Entry(
                        document: entry.document,
                        format: entry.format,
                        isActive: entry.id == id,
                        isEditable: entry.isEditable,
                        translation: entry.translation,
                        candidate: entry.candidate,
                        isKeptVersion: entry.isKeptVersion
                    )
                },
                canSwitch: canSwitch,
                usesLocalCopy: id == nil ? usesLocalCopy : false,
                sourceIsWritable: sourceIsWritable,
                sourceError: sourceError
            )
        }
    }

    enum Listing: Equatable, Sendable {
        case documents(Documents)
        /// The song's lyrics do not come from files beside it: a media
        /// server's document, Apple Music, a podcast transcript.
        case notFileBased
        case unavailable(String)
    }

    /// One file as the raw editor opened it. `data` is what a save must find
    /// still on the source before it may write.
    struct Content: Equatable, Sendable {
        let text: String
        let data: Data
        let encoding: LyricsRawDocumentEncoding
    }

    enum CatalogError: LocalizedError {
        case tooLarge(String)
        case undecodable(String)
        case noLyrics(String)
        case cacheBusy

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name):
                return String(format: String(localized: "lyrics_sources_error_too_large %@"), name)
            case .undecodable(let name):
                return String(format: String(localized: "lyrics_sources_error_undecodable %@"), name)
            case .noLyrics(let name):
                return String(format: String(localized: "lyrics_sources_error_no_lyrics %@"), name)
            case .cacheBusy:
                return String(localized: "tag_editor_lyrics_verify_failed")
            }
        }
    }

    // MARK: - Listing

    static func load(
        for song: Song,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async -> Listing {
        let store = MetadataAssetStore.shared
        let sidecars = await loadSidecars(for: song, sourceManager: sourceManager, sourcesStore: sourcesStore)
        var cached = await store.cachedLyrics(forSongID: song.id)
        if cached == nil, case .notFileBased = sidecars {
            cached = await LyricsLoader.load(for: song, sourceManager: sourceManager, allowsAutomaticOnlineLyrics: false)
        }
        if let cached, !cached.isEmpty {
            await store.rememberLyricsCandidate(cached, forSongID: song.id)
        }
        if let embedded = await store.embeddedFallbackLyrics(forSongID: song.id),
           await !store.isHiddenLyricsVersion(embedded, forSongID: song.id) {
            await store.rememberLyricsCandidate(embedded, forSongID: song.id)
        }
        // 文件里不止一份原文时每一份都列出来：可以分别选用，也可以只删掉其中一份。
        if let alternatives = await store.embeddedLyricsAlternatives(forSongID: song.id) {
            let documents = await Task.detached(priority: .userInitiated) {
                alternatives.variants.compactMap { LyricsLoader.embeddedDocument(for: $0, in: alternatives) }
            }.value
            for document in documents {
                guard await !store.isHiddenLyricsVersion(document, forSongID: song.id) else { continue }
                await store.rememberLyricsCandidate(document, forSongID: song.id)
            }
        }
        var sources = await store.lyricsSourceCollection(forSongID: song.id)
        if case .notFileBased = sidecars,
           let type = sourcesStore.source(id: song.sourceID)?.type,
           !sources.candidates.contains(where: { $0.source?.kind == .server }),
           case .content(let text) = await LyricsLoader.readAuthoritativeSourceText(for: song, sourceManager: sourceManager) {
            let lines = LyricsDocumentSource.server(type.rawValue).stamped(LyricsParser.parse(text))
            if await !store.isHiddenLyricsVersion(lines, forSongID: song.id) {
                await store.rememberLyricsCandidate(lines, forSongID: song.id)
            }
            sources = await store.lyricsSourceCollection(forSongID: song.id)
        }
        let base: Documents
        if case .documents(let documents) = sidecars { base = documents }
        else { base = Documents(entries: [], canSwitch: !song.isCueTrack, usesLocalCopy: false, sourceIsWritable: false) }
        var entries = base.entries
        let current = sources.selected ?? sources.candidates.first(where: {
            guard let cached else { return false }
            return $0.source == LyricsDocumentSource.of(cached)
                && $0.lines.first?.documentIsLocalOverride == cached.first?.documentIsLocalOverride
                && LyricsDocumentFingerprint(lines: $0.lines) == LyricsDocumentFingerprint(lines: cached)
        })
        let hiddenIDs = await store.hiddenCandidateIDs(forSongID: song.id)
        for candidate in sources.candidates {
            // 歌词文件的那几份已经按文件列出来了；「另存为新版本」留下的旧版本例外，它原来的文件已经换了内容。
            if candidate.source?.kind == .file, !base.entries.isEmpty, candidate.id != sources.selectedID,
               candidate.lines.first?.documentIsLocalOverride != true, !sources.isKept(candidate.id) { continue }
            if hiddenIDs.contains(candidate.id) { continue }
            let kept = sources.isKept(candidate.id)
            let name = candidateName(candidate, kept: kept)
            entries.append(Entry(
                document: LyricsSidecarDocument(name: name, path: "candidate:" + candidate.id, size: 0, modifiedDate: nil),
                format: nil, isActive: candidate.id == current?.id, isEditable: false,
                translation: nil, candidate: candidate, isKeptVersion: kept
            ))
        }
        if entries.contains(where: { $0.candidate != nil && $0.isActive }) {
            entries = entries.map { entry in
                guard entry.candidate == nil else { return entry }
                return Entry(document: entry.document, format: entry.format, isActive: false,
                             isEditable: entry.isEditable, translation: entry.translation)
            }
        }
        let sourceError: String?
        if case .unavailable(let message) = sidecars { sourceError = message } else { sourceError = nil }
        return .documents(Documents(entries: entries, canSwitch: base.canSwitch,
                                    usesLocalCopy: false, sourceIsWritable: base.sourceIsWritable, sourceError: sourceError))
    }

    static func candidateName(_ candidate: LyricsSourceCollection.Candidate, kept: Bool = false) -> String {
        if kept { return String(localized: "lyrics_version_previous") }
        if candidate.lines.first?.documentIsLocalOverride == true {
            return String(localized: "lyrics_source_badge_local_edit")
        }
        if candidate.source?.kind == .transcript { return String(localized: "lyrics_sources_transcript") }
        return LyricsSourceBadge.resolve(candidate.lines)?.displayTitle ?? String(localized: "lyrics_sources_cached")
    }

    private static func loadSidecars(
        for song: Song, sourceManager: SourceManager, sourcesStore: SourcesStore
    ) async -> Listing {
        if song.sourceID == AppleMusicLibraryIdentity.sourceID || PodcastPlaybackSong.isEpisode(song) {
            return .notFileBased
        }
        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            if let server = connector as? any ServerLyricsConnector,
               !server.serverLyricsCapabilities.supportsSiblingSidecarLookup {
                return .notFileBased
            }
            // 几份歌词文件并存又没选过时, 「使用中」是按时间轴精度自动挑的那份。
            await LyricsLoader.refreshAutomaticDocumentPick(for: song, connector: connector)
            let target = try await LyricsLoader.lyricsSidecarTarget(
                for: song,
                connector: connector,
                request: .catalog(for: song)
            )
            var documents = target.documents
            if documents.isEmpty, target.exists, let path = target.existingPath {
                // CUE virtual tracks resolve one assigned file without a listing.
                documents = [LyricsSidecarDocument(
                    name: target.fileName,
                    path: path,
                    size: target.existingSize ?? 0,
                    modifiedDate: nil, translation: LyricsLoader.translationTrack(in: target)
                )]
            }
            let activeName = target.exists ? target.fileName : nil
            let sourceIsWritable = await sourceManager.supportsSidecarWriting(for: song)
            let opaqueAddresses = sourcesStore.source(id: song.sourceID)?.type
                .usesOpaqueDirectoryIdentifiers ?? false
            let entries = documents.map { document in
                let format = LyricsDocumentFormat(fileName: document.name)
                return Entry(
                    document: document,
                    format: format,
                    isActive: activeName.map {
                        $0.caseInsensitiveCompare(document.name) == .orderedSame
                    } ?? false,
                    isEditable: sourceIsWritable
                        && format != nil
                        && (!opaqueAddresses || format?.isSerializable == true),
                    translation: document.translation
                )
            }
            let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            let usesLocalCopy = cached?.first?.documentIsLocalOverride == true
            var listed = Documents(
                entries: entries,
                canSwitch: !song.isCueTrack,
                usesLocalCopy: usesLocalCopy,
                sourceIsWritable: sourceIsWritable
            )
            // 播放读的是缓存。缓存不是这份文件(早先存下的内嵌歌词、刮削到的歌词)时哪份都不标
            // 「使用中」, 点哪份都会换上; 否则点那一行什么也不做, 播放却还是别的歌词(#208)。
            // 缓存里一行都没有(播放没读到这份文件)也一样, 点了就换上。
            if !usesLocalCopy, !song.isCueTrack,
               let active = entries.first(where: \.isActive) {
                if let cached, !cached.isEmpty {
                    if let content = try? await read(active.document, for: song, sourceManager: sourceManager) {
                        var lines = LyricsParser.parse(content.text)
                        if let track = active.translation {
                            lines = await LyricsLoader.mergingTranslationTrack(into: lines, track: track, connector: connector)
                        }
                        if !lines.isEmpty, !EmbeddedLyricsPrecedencePolicy.sameDocument(cached, lines) {
                            listed = listed.activating(nil)
                        }
                    }
                } else {
                    listed = listed.activating(nil)
                }
            }
            return .documents(listed)
        } catch is CancellationError {
            return .unavailable(URLError(.cancelled).localizedDescription)
        } catch {
            return .unavailable(SourceErrorPresentation.userFacingDescription(error))
        }
    }

    // MARK: - Reading

    static func read(_ entry: Entry, for song: Song, sourceManager: SourceManager) async throws -> Content {
        guard let candidate = entry.candidate else {
            return try await read(entry.document, for: song, sourceManager: sourceManager)
        }
        let text = LyricsContentParser.serialize(candidate.lines)
        let data = Data(text.utf8)
        return Content(text: text, data: data, encoding: LyricsRawDocumentEncoding(original: data, decodedEncoding: .utf8))
    }

    /// - Parameter maximumBytes: 编辑器用默认的 4 MB;只为换上去显示时,有声内容的文字稿
    ///   可以更大(`maximumReadByteCount`)。
    static func read(
        _ document: LyricsSidecarDocument,
        for song: Song,
        sourceManager: SourceManager,
        maximumBytes: Int = LyricsSidecarTargetPolicy.maximumContentByteCount
    ) async throws -> Content {
        guard document.size <= Int64(maximumBytes) else {
            throw CatalogError.tooLarge(document.name)
        }
        guard document.size > 0 else {
            return Content(
                text: "",
                data: Data(),
                encoding: LyricsRawDocumentEncoding(original: Data(), decodedEncoding: .utf8)
            )
        }
        let connector = try await sourceManager.auxiliaryConnector(for: song)
        let data = try await connector.fetchRange(
            path: document.path,
            offset: 0,
            length: document.size,
            priority: .background
        )
        try Task.checkCancellation()
        guard data.count == Int(document.size) else {
            throw CatalogError.undecodable(document.name)
        }
        // 认编码要把整份文件试好几遍,大文件放到后台。
        guard let decoded = await Task.detached(priority: .userInitiated, operation: {
            TextEncodingRepair.decodeTextFile(data)
        }).value else {
            throw CatalogError.undecodable(document.name)
        }
        return Content(
            text: decoded.text,
            data: data,
            encoding: LyricsRawDocumentEncoding(original: data, decodedEncoding: decoded.encoding)
        )
    }

    /// Reads one file by name through a fresh listing: after a save, or an
    /// edit somewhere else, the size the page listed earlier is stale.
    static func readFresh(
        named fileName: String,
        for song: Song,
        sourceManager: SourceManager
    ) async throws -> Content {
        let connector = try await sourceManager.auxiliaryConnector(for: song)
        let target = try await LyricsLoader.lyricsSidecarTarget(
            for: song,
            connector: connector,
            request: .named(fileName)
        )
        guard target.exists,
              target.fileName.caseInsensitiveCompare(fileName) == .orderedSame,
              let path = target.existingPath else {
            throw SidecarWriteService.LyricsDocumentWriteError.documentMissing(fileName)
        }
        return try await read(
            LyricsSidecarDocument(
                name: target.fileName,
                path: path,
                size: target.existingSize ?? 0,
                modifiedDate: nil
            ),
            for: song,
            sourceManager: sourceManager
        )
    }

    // MARK: - Switching

    /// Makes `entry` the song's lyrics: records the pick and shows the file's
    /// lyrics now. The pick is only recorded once the file has been read and
    /// parsed, so a file that cannot be opened leaves everything as it was.
    static func activate(
        _ entry: Entry,
        for song: Song,
        sourceManager: SourceManager
    ) async throws {
        if let candidate = entry.candidate {
            guard await MetadataAssetStore.shared.selectLyricsCandidate(candidate.id, forSongID: song.id) else {
                throw CatalogError.cacheBusy
            }
            LyricsDocumentPinStore.shared.clearPin(forSongID: song.id)
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
            return
        }
        let content = try await read(
            entry.document,
            for: song,
            sourceManager: sourceManager,
            maximumBytes: LyricsSidecarTargetPolicy.maximumReadByteCount(for: song)
        )
        let text = content.text
        let name = entry.name
        let lines = await Task.detached(priority: .userInitiated) {
            LyricsParser.parseDocument(text, fileName: name)
        }.value
        guard !lines.isEmpty else { throw CatalogError.noLyrics(entry.name) }
        try await show(lines, from: entry, for: song, sourceManager: sourceManager)
        LyricsDocumentPinStore.shared.pin(entry.name, forSongID: song.id)
    }

    /// Puts a file's parsed lyrics into the song's cache, which is what every
    /// player reads first. The listener asked for this file, so it replaces
    /// whatever is cached — a word-timed document, an edit kept only in
    /// Primuse — instead of yielding to it the way automatic reads do.
    /// - Parameter previousVersion: 换下来的那份在来源候选里怎么记。改写正在用的文件时它被替换掉了
    ///   （`.forget`）；换用另一份文件时原来那份还是一个版本（`.remember`）。
    static func show(
        _ lines: [LyricLine],
        from entry: Entry,
        for song: Song,
        sourceManager: SourceManager,
        previousVersion: LyricsPreviousVersionHandling = .remember
    ) async throws {
        let lines = await withTranslationTrack(lines, from: entry, for: song, sourceManager: sourceManager)
        for attempt in 0..<3 {
            if attempt > 0 {
                // An automatic read may be writing the same song right now.
                try await Task.sleep(for: .milliseconds(200))
            }
            let snapshot = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            if await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                lines,
                forSongID: song.id,
                expectedFingerprint: snapshot.map(LyricsDocumentFingerprint.init(lines:)),
                force: true,
                origin: .user,
                previousVersion: previousVersion
            ) {
                NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
                return
            }
        }
        throw CatalogError.cacheBusy
    }

    /// 文件带着同时间轴的译文文件时把译文配上。
    private static func withTranslationTrack(
        _ lines: [LyricLine],
        from entry: Entry,
        for song: Song,
        sourceManager: SourceManager
    ) async -> [LyricLine] {
        guard let track = entry.translation,
              let connector = try? await sourceManager.auxiliaryConnector(for: song) else { return lines }
        return await LyricsLoader.mergingTranslationTrack(
            into: lines, track: track, connector: connector,
            maximumSize: LyricsSidecarTargetPolicy.maximumReadByteCount(for: song)
        )
    }

    // MARK: - Deleting one version

    /// 来源页「删除此版本」删的是什么。
    enum DeletionPlan: Equatable, Sendable {
        /// 只是 App 里记着的一份：从候选里去掉，不动任何文件。
        case forget
        /// 音频文件里的一份内嵌原文：只删内容完全相同的那一个字段，其他语言和译文保留。附上文件里的原文；
        /// nil 表示文件里只有这一份原文（不止一份时写入器不动文件）。
        case embeddedField(String?)
        /// 歌旁边的一个歌词文件：删掉这个文件。
        case file
        /// 源里删不掉（只读的音乐源、不能改写的格式、服务器给的歌词、嵌入设成关）。附上原因；改为在 Primuse 里隐藏。
        case readOnly(String)
    }

    /// 一份内嵌候选在音频文件里对应哪一个字段。
    private enum EmbeddedFieldLocation: Equatable {
        case text(String)
        case onlyOriginal
    }

    static func deletionPlan(
        for entry: Entry,
        in documents: Documents,
        song: Song,
        sourceManager: SourceManager
    ) async -> DeletionPlan {
        guard let candidate = entry.candidate else {
            return documents.sourceIsWritable
                ? .file
                : .readOnly(String(localized: "lyrics_version_delete_read_only_file"))
        }
        // 「另存为新版本」留下的旧版本只在 Primuse 里，删它不碰文件。
        if entry.isKeptVersion { return .forget }
        switch candidate.source?.kind {
        case .embedded:
            guard let location = await embeddedFieldLocation(for: candidate.lines, songID: song.id) else {
                return .forget
            }
            // 和正在用的那份是文件里的同一个字段：不删字段，只从列表里拿掉这一行。
            if !entry.isActive,
               let active = documents.entries.first(where: \.isActive)?.candidate,
               active.source?.kind == .embedded,
               let activeLocation = await embeddedFieldLocation(for: active.lines, songID: song.id),
               sameField(location, activeLocation) {
                return .forget
            }
            guard await sourceManager.lyricsEmbeddingMode(for: song) != .off else {
                return .readOnly(String(localized: "lyrics_version_delete_read_only_embed_off"))
            }
            guard await sourceManager.supportsEmbeddedTagWrite(for: song) else {
                return .readOnly(String(localized: "lyrics_version_delete_read_only_embedded"))
            }
            switch location {
            case .text(let text): return .embeddedField(text)
            case .onlyOriginal: return .embeddedField(nil)
            }
        case .server:
            return .readOnly(String(localized: "lyrics_version_delete_read_only_server"))
        case .appleMusic:
            return .readOnly(String(localized: "lyrics_version_delete_read_only_embedded"))
        case .file, .online, .transcript, nil:
            return .forget
        }
    }

    private static func sameField(_ lhs: EmbeddedFieldLocation, _ rhs: EmbeddedFieldLocation) -> Bool {
        switch (lhs, rhs) {
        case (.onlyOriginal, .onlyOriginal): return true
        case (.text(let left), .text(let right)): return EmbeddedLyricsFieldEditor.sameLyrics(left, right)
        default: return false
        }
    }

    /// 只认得出完全对得上的：文件里有好几份原文时按整份文档指纹对上记下的那一份；只有一份原文时
    /// 候选正是那份备用内嵌歌词或缓存里的内嵌歌词才算。认不出（文件里多半已经没有它了）为 nil。
    private static func embeddedFieldLocation(for lines: [LyricLine], songID: String) async -> EmbeddedFieldLocation? {
        let store = MetadataAssetStore.shared
        let target = MetadataAssetStore.lyricsFingerprint(lines)
        if let alternatives = await store.embeddedLyricsAlternatives(forSongID: songID) {
            let variant = await Task.detached(priority: .userInitiated) {
                LyricsLoader.embeddedVariant(matching: lines, in: alternatives)
            }.value
            return variant.map { .text($0.text) }
        }
        if let fallback = await store.embeddedFallbackLyrics(forSongID: songID),
           MetadataAssetStore.lyricsFingerprint(fallback) == target {
            return .onlyOriginal
        }
        if let cached = await store.cachedLyrics(forSongID: songID),
           LyricsDocumentSource.of(cached)?.kind == .embedded,
           MetadataAssetStore.lyricsFingerprint(cached) == target {
            return .onlyOriginal
        }
        return nil
    }

    /// 删掉正在用的那份之后该换上的：歌旁边的歌词文件优先，其次音频文件里现在还记着的内嵌原文，
    /// 再其次 App 记着的其他版本里最近的一份。刚删掉的那几份（按规整后的指纹）、隐藏的都不算。
    /// 只挑不写，调用方在歌词写入事务里写。一份都没有为 nil。
    static func remainingVersion(
        for song: Song,
        excluding excluded: Set<String>,
        sourceManager: SourceManager,
        sourcesStore: SourcesStore
    ) async -> [LyricLine]? {
        let store = MetadataAssetStore.shared
        guard case .documents(let documents) = await load(
            for: song,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        ) else { return nil }
        for file in documents.entries where file.candidate == nil {
            guard let content = try? await read(
                file.document,
                for: song,
                sourceManager: sourceManager,
                maximumBytes: LyricsSidecarTargetPolicy.maximumReadByteCount(for: song)
            ) else { continue }
            let text = content.text
            let name = file.name
            let parsed = await Task.detached(priority: .userInitiated) {
                LyricsParser.parseDocument(text, fileName: name)
            }.value
            guard !parsed.isEmpty else { continue }
            let lines = await withTranslationTrack(parsed, from: file, for: song, sourceManager: sourceManager)
            guard !excluded.contains(MetadataAssetStore.lyricsFingerprint(lines)),
                  !excluded.contains(MetadataAssetStore.lyricsFingerprint(parsed)),
                  await !store.isHiddenLyricsVersion(lines, forSongID: song.id) else { continue }
            return lines
        }
        let embeddedPrints = await store.embeddedDocumentFingerprints(forSongID: song.id)
        let candidates = documents.entries.compactMap(\.candidate).filter {
            !excluded.contains(MetadataAssetStore.lyricsFingerprint($0.lines))
        }
        if let embedded = candidates.first(where: {
            $0.source?.kind == .embedded && embeddedPrints.contains(MetadataAssetStore.lyricsFingerprint($0.lines))
        }) {
            return embedded.lines
        }
        return candidates.last(where: { $0.source?.kind != .embedded && $0.source?.kind != .file })?.lines
    }

    // MARK: - Messages

    /// What the raw editor says about text it cannot save; nil when it can.
    static func message(for outcome: LyricsRawDocumentPolicy.Outcome, fileName: String) -> String? {
        switch outcome {
        case .valid:
            return nil
        case .empty:
            return String(localized: "lyrics_sources_validation_empty")
        case .tooLarge:
            return String(format: String(localized: "lyrics_sources_error_too_large %@"), fileName)
        case .formatMismatch(let expected, _):
            return String(
                format: String(localized: "lyrics_sources_validation_mismatch %@"),
                familyName(expected)
            )
        case .unreadable:
            return String(localized: "lyrics_sources_validation_unreadable")
        }
    }

    private static func familyName(_ family: LyricsDocumentFormat.Family) -> String {
        switch family {
        case .lrc: return "LRC"
        case .ttml: return "TTML"
        case .wordTimed: return "LYS / YRC / QRC"
        case .subtitle: return "WebVTT / SRT"
        }
    }
}
