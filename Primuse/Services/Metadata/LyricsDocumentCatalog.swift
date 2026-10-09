import Foundation
import PrimuseKit

/// What the lyric sources page knows about a song: every lyric file beside
/// it, the one the song reads, and the reads and switches the page performs.
///
/// Switching never touches a file. It records the pick
/// (`LyricsDocumentPinStore`), which every resolver honours, and puts the
/// picked file's lyrics into the song's cache so playback shows them now.
@MainActor
enum LyricsDocumentCatalog {
    struct Entry: Identifiable, Equatable, Sendable {
        let document: LyricsSidecarDocument
        let format: LyricsDocumentFormat?
        let isActive: Bool
        /// Whether the raw editor may write this file back. A read-only
        /// format on an ID-addressed drive has no address a save could use.
        let isEditable: Bool
        /// The machine-translated track that rides under an `-orig` subtitle.
        let translation: LyricsSidecarDocument?

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

        /// The same listing after the listener switched to `id`.
        func activating(_ id: String) -> Documents {
            Documents(
                entries: entries.map { entry in
                    Entry(
                        document: entry.document,
                        format: entry.format,
                        isActive: entry.id == id,
                        isEditable: entry.isEditable,
                        translation: entry.translation
                    )
                },
                canSwitch: canSwitch,
                usesLocalCopy: false,
                sourceIsWritable: sourceIsWritable
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
        if song.sourceID == AppleMusicLibraryIdentity.sourceID || PodcastPlaybackSong.isEpisode(song) {
            return .notFileBased
        }
        do {
            let connector = try await sourceManager.auxiliaryConnector(for: song)
            if let server = connector as? any ServerLyricsConnector,
               !server.serverLyricsCapabilities.supportsSiblingSidecarLookup {
                return .notFileBased
            }
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
                    modifiedDate: nil
                )]
            }
            let activeName = target.exists ? target.fileName : nil
            let sourceIsWritable = await sourceManager.supportsSidecarWriting(for: song)
            let opaqueAddresses = sourcesStore.source(id: song.sourceID)?.type
                .usesOpaqueDirectoryIdentifiers ?? false
            let baseName = target.songBaseName
                ?? ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let names = documents.map(\.name)
            let entries = documents.map { document in
                let format = LyricsDocumentFormat(fileName: document.name)
                let translation = LyricsSidecarSelectionPolicy.translationTrack(
                    forPrimary: document.name,
                    baseName: baseName,
                    names: names
                ).map { documents[$0] }
                return Entry(
                    document: document,
                    format: format,
                    isActive: activeName.map {
                        $0.caseInsensitiveCompare(document.name) == .orderedSame
                    } ?? false,
                    isEditable: sourceIsWritable
                        && format != nil
                        && (!opaqueAddresses || format?.isSerializable == true),
                    translation: translation
                )
            }
            let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            return .documents(Documents(
                entries: entries,
                canSwitch: !song.isCueTrack,
                usesLocalCopy: cached?.first?.documentIsLocalOverride == true,
                sourceIsWritable: sourceIsWritable
            ))
        } catch is CancellationError {
            return .unavailable(URLError(.cancelled).localizedDescription)
        } catch {
            return .unavailable(SourceErrorPresentation.userFacingDescription(error))
        }
    }

    // MARK: - Reading

    static func read(
        _ document: LyricsSidecarDocument,
        for song: Song,
        sourceManager: SourceManager
    ) async throws -> Content {
        guard document.size <= Int64(LyricsSidecarTargetPolicy.maximumContentByteCount) else {
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
        guard data.count == Int(document.size),
              let decoded = TextEncodingRepair.decodeTextFile(data) else {
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
        let content = try await read(entry.document, for: song, sourceManager: sourceManager)
        let lines = LyricsParser.parse(content.text)
        guard !lines.isEmpty else { throw CatalogError.noLyrics(entry.name) }
        try await show(lines, from: entry, for: song, sourceManager: sourceManager)
        LyricsDocumentPinStore.shared.pin(entry.name, forSongID: song.id)
    }

    /// Puts a file's parsed lyrics into the song's cache, which is what every
    /// player reads first. The listener asked for this file, so it replaces
    /// whatever is cached — a word-timed document, an edit kept only in
    /// Primuse — instead of yielding to it the way automatic reads do.
    static func show(
        _ lines: [LyricLine],
        from entry: Entry,
        for song: Song,
        sourceManager: SourceManager
    ) async throws {
        var lines = lines
        if let translation = entry.translation,
           let connector = try? await sourceManager.auxiliaryConnector(for: song) {
            lines = await LyricsLoader.mergingTranslationTrack(
                into: lines,
                track: (path: translation.path, fileName: translation.name, size: translation.size),
                connector: connector
            )
        }
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
                force: true
            ) {
                NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id)
                return
            }
        }
        throw CatalogError.cacheBusy
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
