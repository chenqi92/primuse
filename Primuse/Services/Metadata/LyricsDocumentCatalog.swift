import Foundation
import CryptoKit
import PrimuseKit

/// File-backed documents and retained source candidates share one selection list.
/// Only file-backed entries can write their original bytes back to the source.
@MainActor
enum LyricsDocumentCatalog {
    struct Entry: Identifiable, Equatable, Sendable {
        var document: LyricsSidecarDocument
        let format: LyricsDocumentFormat?
        var isActive: Bool
        /// Whether the raw editor may write this file back. A read-only
        /// format on an ID-addressed drive has no address a save could use.
        let isEditable: Bool
        let translation: LyricsSidecarTranslation?
        var candidate: LyricsSourceCollection.Candidate? = nil
        /// 「另存为新版本」留下的旧版本：它原来所在的文件已经换了内容，删它只从候选里拿掉。
        var isKeptVersion = false
        var embeddedID: String?
        var embeddedText: String?
        var embeddedLanguage: String?
        var openedAudioFile: LyricsWriteback.OpenedAudioFile?
        var serverText: String?
        var serverType: String?
        var serverCanDelete = false
        var localEdit: LyricsVersionPreferences.LocalEdit?
        var cachedOnly = false

        var isEmbedded: Bool { embeddedID != nil }
        var isPhysicallyWritable: Bool { isEditable && candidate == nil && !cachedOnly }
        var isPhysicallyRemovable: Bool { serverText == nil ? isPhysicallyWritable : serverCanDelete }
        var sourceKind: LyricsDocumentSource.Kind? {
            if serverText != nil { return .server }
            if cachedOnly { return LyricsDocumentSource.of(localEdit?.lines ?? [])?.kind }
            if let candidate { return candidate.source?.kind }
            return isEmbedded ? .embedded : .file
        }
        var languageCode: String? {
            embeddedLanguage ?? LyricsSidecarSelectionPolicy.versionLanguageComponents(ofSidecarNamed: name)?.tag
                ?? (localEdit?.lines ?? candidate?.lines)?.first(where: { $0.languageCode != nil })?.languageCode
        }
        var formatLabel: String? {
            if let edit = localEdit { return Self.formatName(edit.text) }
            if let format { return format.label }
            let text = embeddedText ?? serverText
            guard let text else {
                if let lines = candidate?.lines { return LyricsTimingLevel(lines: lines) == .plain ? "TXT" : nil }
                return nil
            }
            return Self.formatName(text)
        }

        fileprivate static func formatName(_ text: String) -> String {
            switch EmbeddedLyricsContentFormat.detect(text, timing: LyricsTimingLevel(lines: LyricsParser.parse(text))) {
            case .plainText: return "TXT"
            case .webVTT: return "VTT"
            case .subRip: return "SRT"
            case .substationAlpha: return "ASS"
            case let other: return other.rawValue.uppercased()
            }
        }

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
                    var copy = entry
                    copy.isActive = entry.id == id
                    return copy
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
        var serverEntry: Entry?
        if case .notFileBased = sidecars, let type = sourcesStore.source(id: song.sourceID)?.type,
           type.isServerLibrary,
           let connector = try? await sourceManager.auxiliaryConnector(for: song),
           let server = connector as? any ServerLyricsConnector, server.serverLyricsCapabilities.canRead,
           case .content(let text) = await server.readServerLyrics(for: song.filePath) {
            let lines = LyricsDocumentSource.server(type.rawValue).stamped(LyricsParser.parse(text))
            if !lines.isEmpty, await !store.isHiddenLyricsVersion(lines, forSongID: song.id) {
                let capabilities = server.serverLyricsCapabilities
                serverEntry = Entry(document: .init(name: type.rawValue, path: "server-current:" + type.rawValue,
                                                    size: Int64(text.utf8.count), modifiedDate: nil),
                                    format: LyricsDocumentFormat(rawValue: Entry.formatName(text).lowercased()),
                                    isActive: cached.map { LyricsDocumentSource.of($0)?.kind == .server
                                        && EmbeddedLyricsPrecedencePolicy.sameDocument(lines, $0) } ?? false,
                                    isEditable: capabilities.canWrite, translation: nil, serverText: text,
                                    serverType: type.rawValue, serverCanDelete: capabilities.canDelete)
                await store.rememberLyricsCandidate(lines, forSongID: song.id)
                sources = await store.lyricsSourceCollection(forSongID: song.id)
            }
        }
        let base: Documents
        if case .documents(let documents) = sidecars { base = documents }
        else { base = Documents(entries: [], canSwitch: !song.isCueTrack, usesLocalCopy: false, sourceIsWritable: false) }
        var entries = base.entries
        if let serverEntry { entries.append(serverEntry) }
        var choices = await MetadataAssetStore.shared.lyricsVersionPreferences(forSongID: song.id) ?? .init()
        var listingError: String?
        var enumeratedEmbedded = false
        if shouldReadEmbedded(song, type: sourcesStore.source(id: song.sourceID)?.type) {
            do {
                let writable = await sourceManager.supportsEmbeddedTagWrite(for: song)
                let openedFile = writable ? await LyricsWriteback.openedAudioFile(for: song, sourceManager: sourceManager) : nil
                let bytes = try await sourceManager.editorEmbeddedFileData(for: song)
                try Task.checkCancellation()
                let ext = song.fileFormat.rawValue
                let physical = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedLyricsArchive.entries(in: bytes, fileExtension: ext)
                }.value
                if let old = cached, LyricsDocumentSource.of(old)?.kind == .embedded,
                   old.first?.documentIsLocalOverride != true,
                   !physical.contains(where: { EmbeddedLyricsPrecedencePolicy.sameDocument(old, LyricsParser.parse($0.text)) }) {
                    let metadata = await FileMetadataReader.RangeReadSession().read(from: bytes, fileExtension: ext)
                    if let current = FileMetadataReader.parsedEmbeddedLyrics(from: metadata) {
                        await store.reconcileEmbeddedSource(current, alternatives: metadata.embeddedLyricsAlternatives,
                                                            forSongID: song.id, expected: LyricsDocumentFingerprint(lines: old))
                        cached = await store.cachedLyrics(forSongID: song.id)
                        choices = await store.lyricsVersionPreferences(forSongID: song.id) ?? .init()
                        sources = await store.lyricsSourceCollection(forSongID: song.id)
                    }
                }
                enumeratedEmbedded = true
                var foundActive = false
                let embedded = physical.map { record in
                    let formatName = Entry.formatName(record.text)
                    let lines = LyricsParser.parse(record.text)
                    let active = !foundActive && cached.map {
                        LyricsDocumentSource.of($0)?.kind == .embedded && EmbeddedLyricsPrecedencePolicy.sameDocument($0, lines)
                    } == true
                    foundActive = foundActive || active
                    return Entry(document: .init(name: record.fieldName, path: "embedded:" + record.id,
                                                 size: Int64(record.text.utf8.count), modifiedDate: nil),
                                 format: LyricsDocumentFormat(rawValue: formatName.lowercased()),
                                 isActive: active, isEditable: writable, translation: nil,
                                 embeddedID: record.id, embeddedText: record.text, embeddedLanguage: record.languageCode,
                                 openedAudioFile: openedFile)
                }
                entries.append(contentsOf: embedded)
            } catch { listingError = SourceErrorPresentation.userFacingDescription(error) }
        }
        if !enumeratedEmbedded,
           let snapshot = await MetadataAssetStore.shared.embeddedLyricsAlternatives(forSongID: song.id) {
            var values = snapshot.variants.map { ($0.text, $0.languageCode) }
            if let translation = snapshot.translatedLyricsText {
                values.append((translation, snapshot.translatedLyricsLanguageCode))
            }
            for (language, text) in snapshot.languageTaggedLyrics.sorted(by: { $0.key < $1.key })
                + snapshot.languageTaggedTranslations.sorted(by: { $0.key < $1.key }) {
                values.append((text, language))
            }
            var seen = Set<String>()
            for (text, language) in values {
                let key = SHA256.hash(data: Data(((language ?? "") + "\u{0}" + text).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                guard seen.insert(key).inserted else { continue }
                let format = Entry.formatName(text)
                entries.append(Entry(document: .init(name: format, path: "embedded-snapshot:" + key,
                                                     size: Int64(text.utf8.count), modifiedDate: nil),
                                     format: LyricsDocumentFormat(rawValue: format.lowercased()),
                                     isActive: cached.map { LyricsDocumentSource.of($0)?.kind == .embedded
                                        && EmbeddedLyricsPrecedencePolicy.sameDocument($0, LyricsParser.parse(text)) } == true,
                                     isEditable: false, translation: nil, embeddedID: key,
                                     embeddedText: text, embeddedLanguage: language))
            }
        }
        let current = sources.selected ?? sources.candidates.first(where: {
            guard let cached else { return false }
            return $0.source == LyricsDocumentSource.of(cached)
                && $0.lines.first?.documentIsLocalOverride == cached.first?.documentIsLocalOverride
                && LyricsDocumentFingerprint(lines: $0.lines) == LyricsDocumentFingerprint(lines: cached)
        })
        let hiddenIDs = await store.hiddenCandidateIDs(forSongID: song.id)
        let cleared = await store.hasUserClearedLyrics(forSongID: song.id)
        for candidate in sources.candidates {
            // 歌词文件的那几份已经按文件列出来了；「另存为新版本」留下的旧版本例外，它原来的文件已经换了内容。
            let kept = sources.isKept(candidate.id)
            if !kept, let serverText = serverEntry?.serverText, candidate.source?.kind == .server,
               candidate.lines.first?.documentIsLocalOverride != true,
               EmbeddedLyricsPrecedencePolicy.sameDocument(LyricsParser.parse(serverText), candidate.lines) { continue }
            if !kept, candidate.lines.first?.documentIsLocalOverride == true,
               choices.edits.values.contains(where: { LyricsDocumentFingerprint(lines: $0.lines) == LyricsDocumentFingerprint(lines: candidate.lines) }) { continue }
            if !kept, candidate.source?.kind == .embedded, candidate.lines.first?.documentIsLocalOverride != true,
               (enumeratedEmbedded && candidate.id != sources.selectedID && candidate.id != current?.id ||
                entries.contains(where: { entry in
                    entry.embeddedText.map { EmbeddedLyricsPrecedencePolicy.sameDocument(LyricsParser.parse($0), candidate.lines) } ?? false
                })) { continue }
            if candidate.source?.kind == .file, !base.entries.isEmpty, candidate.id != sources.selectedID,
               candidate.lines.first?.documentIsLocalOverride != true, !sources.isKept(candidate.id) { continue }
            if hiddenIDs.contains(candidate.id) { continue }
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
                var copy = entry
                copy.isActive = false
                return copy
            }
        }
        for (id, edit) in choices.edits.sorted(by: { $0.key < $1.key }) where !entries.contains(where: { $0.id == id }) {
            entries.append(Entry(document: .init(name: edit.displayName, path: id, size: Int64(edit.text.utf8.count), modifiedDate: nil),
                                 format: nil, isActive: false, isEditable: false, translation: nil, localEdit: edit, cachedOnly: true))
        }
        let hiddenFingerprints = Set(await store.userLyricsChoice(forSongID: song.id)?.hiddenFingerprints ?? [])
        entries.removeAll { entry in
            if choices.hiddenIDs.contains(entry.id) || entry.candidate.map({ !choices.permits($0.lines) }) == true { return true }
            guard !hiddenFingerprints.isEmpty, let text = entry.embeddedText else { return false }
            return hiddenFingerprints.contains(MetadataAssetStore.lyricsFingerprint(LyricsParser.parse(text)))
        }
        for index in entries.indices {
            entries[index].localEdit = choices.edits[entries[index].id]
            if cleared { entries[index].isActive = false }
            else if let id = choices.selectedID { entries[index].isActive = entries[index].id == id }
        }
        if let firstActive = entries.firstIndex(where: \.isActive) {
            for index in entries.indices where index != firstActive { entries[index].isActive = false }
        }
        let sourceError: String?
        if case .unavailable(let message) = sidecars { sourceError = message } else { sourceError = listingError }
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

    private static func shouldReadEmbedded(_ song: Song, type: MusicSourceType?) -> Bool {
        guard AudioMetadataWritebackPolicy.embeddedFormats.contains(song.fileFormat) || song.fileFormat == .alac,
              !song.isCueTrack, !song.isStreamDescriptor,
              song.sourceID != AppleMusicLibraryIdentity.sourceID, !PodcastPlaybackSong.isEpisode(song),
              let type else { return false }
        return type == .local || type.supportsEmbeddedMetadataBackfill
    }

    private static func embeddedEntries(
        for song: Song, sourceManager: SourceManager
    ) async throws -> [EmbeddedLyricsArchive.Entry] {
        let bytes = try await sourceManager.editorEmbeddedFileData(for: song)
        try Task.checkCancellation()
        let ext = song.fileFormat.rawValue
        return try await Task.detached(priority: .userInitiated) {
            try EmbeddedLyricsArchive.entries(in: bytes, fileExtension: ext)
        }.value
    }

    static func read(_ entry: Entry, for song: Song, sourceManager: SourceManager) async throws -> Content {
        if let edit = entry.localEdit { return textContent(edit.text) }
        if let text = entry.embeddedText { return textContent(text) }
        if let text = entry.serverText { return textContent(text) }
        guard let candidate = entry.candidate else {
            return try await read(entry.document, for: song, sourceManager: sourceManager)
        }
        let text = LyricsContentParser.serialize(candidate.lines)
        return textContent(text)
    }

    private static func textContent(_ text: String) -> Content {
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
        guard mutatingSongIDs.insert(song.id).inserted else { throw CatalogError.cacheBusy }
        defer { mutatingSongIDs.remove(song.id) }
        try await applySelection(entry, for: song, sourceManager: sourceManager)
    }

    private static func applySelection(_ entry: Entry, for song: Song, sourceManager: SourceManager) async throws {
        let lines = try await Self.lines(for: entry, song: song, sourceManager: sourceManager)
        guard !lines.isEmpty else { throw CatalogError.noLyrics(entry.name) }
        var choices = await MetadataAssetStore.shared.lyricsVersionPreferences(forSongID: song.id) ?? .init()
        choices.cleared = false
        choices.hiddenIDs.remove(entry.id)
        choices.removedDocuments.remove(LyricsVersionPreferences.documentKey(lines))
        let tracksFile = entry.sourceKind == .file && entry.candidate == nil && !entry.cachedOnly && entry.localEdit == nil
        choices.selectedID = tracksFile ? nil : entry.id
        choices.selectedLines = tracksFile ? [] : lines
        try await MetadataAssetStore.shared.chooseLyricsVersion(choices, lines: lines,
            candidateID: entry.localEdit == nil ? entry.candidate?.id : nil, forSongID: song.id)
        if tracksFile {
            LyricsDocumentPinStore.shared.pin(entry.name, forSongID: song.id)
        } else {
            LyricsDocumentPinStore.shared.clearPin(forSongID: song.id)
        }
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
    }

    private static func lines(for entry: Entry, song: Song, sourceManager: SourceManager) async throws -> [LyricLine] {
        if let edit = entry.localEdit { return edit.lines }
        if let candidate = entry.candidate { return candidate.lines }
        if let text = entry.embeddedText {
            return LyricsDocumentSource.embedded.stamped(LyricsParser.parse(text))
        }
        if let text = entry.serverText, let type = entry.serverType {
            return LyricsDocumentSource.server(type).stamped(LyricsParser.parse(text))
        }
        let content = try await read(entry.document, for: song, sourceManager: sourceManager,
                                     maximumBytes: LyricsSidecarTargetPolicy.maximumReadByteCount(for: song))
        var parsed = LyricsParser.parseDocument(content.text, fileName: entry.name)
        if let translation = entry.translation {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            parsed = await LyricsLoader.mergingTranslationTrack(into: parsed, track: translation, connector: connector,
                          maximumSize: LyricsSidecarTargetPolicy.maximumReadByteCount(for: song))
        }
        return parsed
    }

    private static var mutatingSongIDs = Set<String>()

    static func save(_ text: String, entry: Entry, original: Content, for song: Song, sourceManager: SourceManager,
                     library: MusicLibrary? = nil) async throws {
        let validation = LyricsRawDocumentPolicy.validate(text, fileName: entry.isEmbedded ? "" : entry.name)
        guard validation.outcome.isValid else { throw CatalogError.noLyrics(entry.name) }
        try await saveVersion(text: text, parsed: validation.lines, entry: entry, original: original, song: song,
                              sourceManager: sourceManager, keepsLocalCopy: false, library: library)
    }

    enum VersionSaveMode {
        case replace, keep, keepAndSelect
    }

    static func saveEditedLines(_ lines: [LyricLine], text: String, entry: Entry, original: Content,
                                for song: Song, sourceManager: SourceManager, library: MusicLibrary? = nil,
                                mode: VersionSaveMode = .replace) async throws {
        guard !lines.isEmpty else { throw CatalogError.noLyrics(entry.name) }
        let document: String
        var keepLocalCopy = false
        let rich = LyricsStructuredPersistencePolicy.requiresTTML(lines)
        let translated = lines.contains { !$0.allManualTranslations.isEmpty }
        switch entry.formatLabel?.uppercased() {
        case "TTML":
            document = LyricsContentParser.serializeTTML(lines)
            keepLocalCopy = translated && !EmbeddedLyricsPrecedencePolicy.sameDocument(LyricsParser.parse(document), lines)
        case "LRC", "ELRC":
            keepLocalCopy = rich || (translated && !LyricManualTranslationPolicy.canPersistAsBilingualLRC(lines))
            document = keepLocalCopy ? LyricsContentParser.serializeTTML(lines) : text
        case "TXT" where LyricsTimingLevel(lines: lines) == .plain && !rich && !translated:
            document = lines.map(\.text).joined(separator: "\n")
        default:
            document = LyricsContentParser.serializeTTML(lines)
            keepLocalCopy = true
        }
        try await saveVersion(text: document, parsed: lines, entry: entry, original: original, song: song,
                              sourceManager: sourceManager, keepsLocalCopy: keepLocalCopy, library: library, mode: mode)
    }

    private static func saveVersion(text: String, parsed: [LyricLine], entry: Entry, original: Content,
                                    song: Song, sourceManager: SourceManager, keepsLocalCopy: Bool, library: MusicLibrary?,
                                    mode: VersionSaveMode = .replace) async throws {
        guard mutatingSongIDs.insert(song.id).inserted else { throw CatalogError.cacheBusy }
        defer { mutatingSongIDs.remove(song.id) }
        var choices = await MetadataAssetStore.shared.lyricsVersionPreferences(forSongID: song.id) ?? .init()
        let isActive: Bool
        if mode == .keepAndSelect { isActive = true }
        else if let selected = choices.selectedID { isActive = selected == entry.id }
        else if let selectedFile = LyricsDocumentPinStore.shared.pinnedFileName(forSongID: song.id) {
            isActive = entry.sourceKind == .file && selectedFile.caseInsensitiveCompare(entry.name) == .orderedSame
        } else { isActive = entry.isActive }
        let currentEdit = choices.edits[entry.id]
        if let currentEdit, currentEdit.text != original.text { throw changed(entry) }
        let previous: [LyricLine]?
        if mode != .replace {
            let current = try await read(entry, for: song, sourceManager: sourceManager)
            guard current.data == original.data else { throw changed(entry) }
            let opened = try await Self.lines(for: entry, song: song, sourceManager: sourceManager)
            if !opened.isEmpty, LyricsDocumentFingerprint(lines: opened) != LyricsDocumentFingerprint(lines: parsed) {
                // 先确认旧正文能存入候选，再覆盖源文件。源写入失败时不把它标成已另存的版本。
                guard await MetadataAssetStore.shared.rememberLyricsCandidate(opened, forSongID: song.id) != nil else {
                    throw CatalogError.cacheBusy
                }
                previous = opened
            } else {
                previous = nil
            }
        } else {
            previous = nil
        }
        var id = entry.id
        var lines = parsed
        if keepsLocalCopy || !entry.isPhysicallyWritable || currentEdit != nil {
            if currentEdit == nil && previous == nil {
                let current = try await read(entry, for: song, sourceManager: sourceManager)
                guard current.data == original.data else { throw changed(entry) }
            }
            if !lines.isEmpty { lines[0].documentIsLocalOverride = true }
            if previous != nil, entry.candidate != nil { id = "edit:" + UUID().uuidString }
            choices.edits[id] = .init(text: text, lines: lines, displayName: entry.name)
        } else if let embeddedID = entry.embeddedID {
            let library = library ?? AppServices.shared.musicLibrary
            let latest = library.storedSong(id: song.id) ?? song
            guard LyricsWriteback.EditTarget(song).isSameLocation(as: latest) else { throw changed(entry) }
            let target: Song
            if let opened = entry.openedAudioFile {
                guard let captured = opened.target(for: latest) else { throw changed(entry) }
                target = captured
            } else {
                target = latest
            }
            let entries = try await embeddedEntries(for: target, sourceManager: sourceManager)
            guard let position = entries.firstIndex(where: { $0.id == embeddedID }),
                  entries[position].text == original.text else { throw changed(entry) }
            let updated = try await writeEmbedded([embeddedID: text], for: target, sourceManager: sourceManager, library: library)
            let verified = try await embeddedEntries(for: updated, sourceManager: sourceManager)
            guard entries.count == verified.count, verified.indices.contains(position) else {
                throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
            }
            let rendered = verified[position].text
            let isSynced = ["SYLT", "SLT"].contains(verified[position].fieldName)
            guard isSynced ? EmbeddedLyricsVariantPolicy.sameSynchronizedCues(text, rendered) : rendered == text else {
                throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
            }
            choices.remapVersions(Self.embeddedIdentityMap(from: entries, to: verified))
            id = "embedded:" + verified[position].id
            lines = LyricsDocumentSource.embedded.stamped(lines)
            if previous == nil, !verified.contains(where: { $0.text == original.text }) {
                let previous = LyricsDocumentSource.embedded.stamped(LyricsParser.parse(original.text))
                choices.removedDocuments.formUnion(try await MetadataAssetStore.shared.discardLyricsVersionCopies(previous, forSongID: song.id))
            }
        } else if entry.serverText != nil, let type = entry.serverType {
            try await LyricsWriteback.replaceServerVersion(for: song, expecting: original.text, with: text,
                                                         sourceManager: sourceManager)
            lines = LyricsDocumentSource.server(type).stamped(lines)
        } else {
            _ = try await MusicScraperService.replaceLyricsDocumentWithTimeout(
                seconds: 30, sourceManager: sourceManager, for: song, named: entry.name,
                data: original.encoding.data(for: text), expecting: original.data
            )
            lines = LyricsDocumentSource.file(entry.name).stamped(lines)
        }
        if let previous {
            guard await MetadataAssetStore.shared.rememberLyricsCandidate(previous, forSongID: song.id,
                                                                          keepingVersion: true) != nil else {
                throw CatalogError.cacheBusy
            }
            choices.removedDocuments.remove(LyricsVersionPreferences.documentKey(previous))
        }
        choices.cleared = false
        choices.removedDocuments.remove(LyricsVersionPreferences.documentKey(lines))
        if isActive {
            let tracksFile = entry.sourceKind == .file && entry.isPhysicallyWritable && choices.edits[id] == nil
            choices.selectedID = tracksFile ? nil : id
            choices.selectedLines = tracksFile ? [] : lines
        }
        if isActive {
            try await MetadataAssetStore.shared.chooseLyricsVersion(choices, lines: lines, forSongID: song.id)
            if mode == .keepAndSelect {
                if choices.selectedID == nil { LyricsDocumentPinStore.shared.pin(entry.name, forSongID: song.id) }
                else { LyricsDocumentPinStore.shared.clearPin(forSongID: song.id) }
            }
        } else {
            try await MetadataAssetStore.shared.setLyricsVersionPreferences(choices, forSongID: song.id)
        }
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
    }

    private static func changed(_ entry: Entry) -> SidecarWriteService.LyricsDocumentWriteError {
        .changedElsewhere(entry.name)
    }

    private static func embeddedIdentityMap(from old: [EmbeddedLyricsArchive.Entry],
                                            to new: [EmbeddedLyricsArchive.Entry]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(old, new).map { ("embedded:" + $0.id, "embedded:" + $1.id) })
    }

    private static func writeEmbedded(_ edits: [String: String?], for song: Song,
                                      sourceManager: SourceManager, library: MusicLibrary) async throws -> Song {
        let written = try await sourceManager.writeEmbeddedLyrics(.ordered(edits), for: song)
        library.flushPendingAssetReferencePatches()
        if var latest = library.storedSong(id: song.id) {
            latest.filePath = written.filePath
            latest.fileSize = written.fileSize
            latest.lastModified = written.lastModified
            latest.revision = written.revision
            library.replaceSong(latest)
        }
        return written
    }

    static func remove(_ entries: [Entry], for song: Song, sourceManager: SourceManager, removeAll: Bool = false,
                       hidingOnly: Bool = false,
                       sourcesStore: SourcesStore? = nil, library: MusicLibrary? = nil) async throws {
        guard mutatingSongIDs.insert(song.id).inserted else { throw CatalogError.cacheBusy }
        defer { mutatingSongIDs.remove(song.id) }
        let library = library ?? AppServices.shared.musicLibrary
        var currentSong = library.storedSong(id: song.id) ?? song
        guard case .documents(let listing) = await load(for: currentSong, sourceManager: sourceManager,
                                                        sourcesStore: sourcesStore ?? AppServices.shared.sourcesStore) else { throw CatalogError.cacheBusy }
        let ids = Set(entries.map(\.id))
        if removeAll, listing.sourceError != nil || Set(listing.entries.map(\.id)) != ids {
            throw CatalogError.cacheBusy
        }
        let selected = listing.entries.filter { ids.contains($0.id) }
        if let missing = entries.first(where: { previous in !selected.contains(where: { $0.id == previous.id }) }) {
            throw changed(missing)
        }
        for entry in selected {
            if let previous = entries.first(where: { $0.id == entry.id }),
               previous.document != entry.document || previous.serverText != entry.serverText || previous.localEdit != entry.localEdit {
                throw changed(entry)
            }
        }
        var choices = await MetadataAssetStore.shared.lyricsVersionPreferences(forSongID: song.id) ?? .init()
        var removedActive = false
        var remainingIDs: [String: String] = [:]
        let physical = selected.filter { !hidingOnly && $0.isEmbedded && $0.isPhysicallyWritable }
        let retainedEmbeddedTexts = Set(listing.entries.filter { !ids.contains($0.id) }.compactMap(\.embeddedText))
        func record(_ entry: Entry, lines: [LyricLine]) async throws {
            removedActive = removedActive || (choices.selectedID.map { $0 == entry.id } ?? entry.isActive)
            if hidingOnly || !entry.isPhysicallyRemovable { choices.hiddenIDs.insert(entry.id) }
            if !lines.isEmpty && !(entry.embeddedText.map(retainedEmbeddedTexts.contains) ?? false) {
                choices.removedDocuments.formUnion(try await MetadataAssetStore.shared.discardLyricsVersionCopies(lines, forSongID: song.id))
            }
            choices.edits[entry.id] = nil
            if choices.selectedID == entry.id { choices.selectedID = nil; choices.selectedLines = [] }
            if entry.sourceKind == .file { LyricsDocumentPinStore.shared.forgetFile(named: entry.name, forSongID: song.id) }
            try await MetadataAssetStore.shared.setLyricsVersionPreferences(choices, forSongID: song.id)
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
        }
        if !physical.isEmpty {
            guard LyricsWriteback.EditTarget(song).isSameLocation(as: currentSong) else { throw changed(physical[0]) }
            let openedEntries = entries.filter { entry in physical.contains { $0.id == entry.id } }
            let openedTargets = try openedEntries.compactMap { entry -> Song? in
                guard let opened = entry.openedAudioFile else { return nil }
                guard let target = opened.target(for: currentSong) else { throw changed(entry) }
                return target
            }
            if let target = openedTargets.first {
                guard openedTargets.allSatisfy({ LyricsWriteback.EditTarget(target).isSameFile(as: $0) }) else {
                    throw changed(physical[0])
                }
                currentSong = target
            }
            let edits = Dictionary(uniqueKeysWithValues: physical.compactMap(\.embeddedID).map { ($0, nil as String?) })
            let before = try await embeddedEntries(for: currentSong, sourceManager: sourceManager)
            let surviving = before.filter { !edits.keys.contains($0.id) }
            currentSong = try await writeEmbedded(edits, for: currentSong, sourceManager: sourceManager, library: library)
            let after = try await embeddedEntries(for: currentSong, sourceManager: sourceManager)
            guard after.count == surviving.count, zip(surviving, after).allSatisfy({
                $0.text == $1.text && $0.fieldName == $1.fieldName && $0.languageCode == $1.languageCode
            }) else { throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed }
            for entry in physical {
                try await record(entry, lines: LyricsDocumentSource.embedded.stamped(LyricsParser.parse(entry.embeddedText ?? "")))
            }
            remainingIDs = embeddedIdentityMap(from: surviving, to: after)
            choices.remapVersions(remainingIDs)
            try await MetadataAssetStore.shared.setLyricsVersionPreferences(choices, forSongID: song.id)
        }
        for entry in selected where !physical.contains(where: { $0.id == entry.id }) {
            let parsed: [LyricLine]
            if !hidingOnly, entry.isPhysicallyRemovable, let original = entry.serverText {
                parsed = LyricsDocumentSource.server(entry.serverType ?? "").stamped(LyricsParser.parse(original))
                try await LyricsWriteback.replaceServerVersion(for: currentSong, expecting: original, with: nil,
                                                             sourceManager: sourceManager)
            } else if !hidingOnly, entry.isPhysicallyRemovable {
                let snapshot = try await read(entry.document, for: currentSong, sourceManager: sourceManager,
                                              maximumBytes: LyricsSidecarTargetPolicy.maximumReadByteCount(for: currentSong))
                parsed = LyricsParser.parseDocument(snapshot.text, fileName: entry.name)
                try await removeSidecar(entry, expecting: snapshot.data, for: currentSong, sourceManager: sourceManager)
            } else {
                parsed = try await lines(for: entry, song: currentSong, sourceManager: sourceManager)
            }
            try await record(entry, lines: parsed)
        }
        if removeAll || (!selected.isEmpty && ids.count == listing.entries.count && listing.sourceError == nil) {
            choices.cleared = true
            choices.selectedID = nil
            choices.selectedLines = []
            try await MetadataAssetStore.shared.setLyricsVersionPreferences(choices, forSongID: song.id)
            _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id)
            LyricsDocumentPinStore.shared.clearPin(forSongID: song.id)
        } else if removedActive {
            let latest = library.storedSong(id: song.id) ?? song
            if var next = listing.entries.first(where: { !ids.contains($0.id) }) {
                if let new = remainingIDs[next.id], new != next.id {
                    next.embeddedID = String(new.dropFirst("embedded:".count))
                    next.document = .init(name: next.name, path: new, size: next.document.size, modifiedDate: nil)
                }
                try await applySelection(next, for: latest, sourceManager: sourceManager)
            } else {
                choices.cleared = true
                try await MetadataAssetStore.shared.setLyricsVersionPreferences(choices, forSongID: song.id)
                _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id)
            }
        }
        if choices.cleared {
            library.flushPendingAssetReferencePatches()
            if var latest = library.storedSong(id: song.id) {
                latest.lyricsFileName = nil
                latest.lyricsText = nil
                library.replaceSong(latest)
            }
        }
        NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
    }

    private static func removeSidecar(_ entry: Entry, expecting bytes: Data, for song: Song, sourceManager: SourceManager) async throws {
        let connector = try await sourceManager.sidecarWriteConnector(for: song)
        let target = try await LyricsLoader.lyricsSidecarTarget(for: song, connector: connector, request: .named(entry.name))
        guard target.fileName == entry.name, target.existingPath == entry.document.path,
              target.existingSize == nil || target.existingSize == entry.document.size else { throw changed(entry) }
        let files = try await connector.listFiles(at: target.containerPath)
        guard let item = files.first(where: { $0.path == entry.document.path && $0.name == entry.name && !$0.isDirectory }),
              item.size == entry.document.size, entry.document.modifiedDate == nil || item.modifiedDate == entry.document.modifiedDate else {
            throw changed(entry)
        }
        guard try await connector.fetchRange(path: item.path, offset: 0, length: Int64(bytes.count),
                                             priority: .background) == bytes else { throw changed(entry) }
        try await connector.deleteFile(at: item.path)
        await sourceManager.invalidateReadCachesAfterSidecarWrite(for: song, paths: [item.path])
        for delay in [0, 250, 750, 1_500, 3_000] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            let refreshed = try await connector.listFiles(at: target.containerPath)
            if !refreshed.contains(where: { $0.path == item.path || $0.name == item.name }) { return }
        }
        throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
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
        case serverVersion
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
        if entry.isKeptVersion || entry.cachedOnly { return .forget }
        if entry.isEmbedded {
            guard entry.isPhysicallyRemovable else {
                return .readOnly(String(localized: "lyrics_version_delete_read_only_embedded"))
            }
            guard await sourceManager.lyricsEmbeddingMode(for: song) != .off else {
                return .readOnly(String(localized: "lyrics_version_delete_read_only_embed_off"))
            }
            return .embeddedField(entry.embeddedText)
        }
        if entry.serverText != nil {
            return entry.serverCanDelete ? .serverVersion : .readOnly(String(localized: "lyrics_version_delete_read_only_server"))
        }
        guard let candidate = entry.candidate else {
            return documents.sourceIsWritable
                ? .file
                : .readOnly(String(localized: "lyrics_version_delete_read_only_file"))
        }
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
