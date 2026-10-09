import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension CoverEmbeddingMode {
    var settingsTitle: String {
        switch self {
        case .off: return String(localized: "cover_embed_mode_off")
        case .alongside: return String(localized: "cover_embed_mode_alongside")
        case .embedOnly: return String(localized: "cover_embed_mode_embed_only")
        }
    }

    /// 选到这一档之前要让用户看到的代价。
    var confirmationMessage: String {
        let common = String(localized: "cover_embed_confirm_message")
        guard self == .embedOnly else { return common }
        return common + "\n" + String(localized: "cover_embed_confirm_message_embed_only")
    }
}

/// Writes sidecar files (cover art, lyrics) alongside source audio files on NAS/remote storage.
/// - Cover: `<basename>-cover.jpg` next to the audio file
/// - Lyrics: `<basename>.lrc` by default; an existing `.ttml` remains TTML.
///   A read-only document such as `<basename>.vtt` or `<basename>.lys` is
///   never replaced — the save creates `<basename>.ttml` beside it (`.lrc`
///   beside an `.elrc`), and the content is serialized for that target.
actor SidecarWriteService {
    static let shared = SidecarWriteService()
    private init() {}

    struct WriteResult: Sendable {
        struct VerifiedLyricsWrite: Sendable, Equatable {
            let target: LyricsPreflightResult
            let content: String
        }

        var coverWritten: Bool = false
        var lyricsWritten: Bool = false
        var lyricsRemoved: Bool = false
        var lyricsTargetChanged: Bool = false
        /// Issued only after the connector has proved the write at the exact
        /// preflight target. Callers must use this receipt instead of resolving
        /// the old `Song` again through an unrelated cache/read route.
        var verifiedLyricsWrite: VerifiedLyricsWrite?
        var coverError: String?
        var lyricsError: String?
        /// Every remote path a write or delete was sent to, verified or not:
        /// an upload can commit before its readback fails. The caller hands
        /// these to the source's read connector, which caches links of its own.
        var touchedRemotePaths: [String] = []
        /// A credential/permission failure applies to the whole source, not
        /// only this asset. Batch scraping uses this to stop the remaining
        /// queued writes while keeping the locally cached metadata.
        var sourceUnavailable: Bool = false
        var errors: [String] = []
    }

    struct LyricsPreflightResult: Sendable, Equatable {
        let targetPath: String
        let fileName: String
        let containerPath: String
        let replacesExistingFile: Bool
        let existingPath: String?
        let existingSize: Int64?
        /// A lyrics document of any kind sits beside the song, including a
        /// read-only one (`.vtt`, `.srt`, `.lys`) that a save writes a new file
        /// next to instead of replacing. `replacesExistingFile` is false then.
        let hasLyricsDocument: Bool

        init(document: LyricsSidecarTarget, write: LyricsSidecarTarget) {
            targetPath = write.targetPath
            fileName = write.fileName
            containerPath = write.containerPath
            replacesExistingFile = write.exists
            existingPath = write.existingPath
            existingSize = write.existingSize
            hasLyricsDocument = document.exists
        }
    }

    /// Non-mutating source/file preflight used by the editor before enabling
    /// remote writeback. A successful directory listing proves current
    /// authentication and target reachability; the provider still performs
    /// the definitive ACL check when `writeFile` executes.
    func preflightLyricsWrite(
        for song: Song,
        using connector: any MusicSourceConnector
    ) async throws -> LyricsPreflightResult {
        guard connector.supportsSidecarWriting else {
            throw SourceError.connectionFailed("Source does not support sidecar writing")
        }
        let targets = try await lyricsTargets(for: song, using: connector)
        return LyricsPreflightResult(document: targets.document, write: targets.write)
    }

    /// Write sidecar files for a song after scraping.
    /// - Parameters:
    ///   - song: The song with updated metadata
    ///   - connector: The source connector with write capability
    ///   - coverData: JPEG cover art data to write (optional)
    ///   - lyricsLines: Parsed lyric lines, serialized in the target's format (optional)
    ///   - createsLyricsFile: false in embed-only mode. A lyrics document that
    ///     already sits beside the song is still updated; none is created.
    ///   - createsCoverFile: the same for the cover file.
    func writeSidecars(
        for song: Song,
        using connector: any MusicSourceConnector,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String? = nil,
        expectedLyricsTarget: LyricsPreflightResult? = nil,
        createsLyricsFile: Bool = true,
        createsCoverFile: Bool = true
    ) async -> WriteResult {
        var result = WriteResult()
        guard connector.supportsSidecarWriting else {
            result.errors.append("Source does not support sidecar writing")
            return result
        }
        let songDir = (song.filePath as NSString).deletingLastPathComponent
        let songBaseName = (song.filePath as NSString).lastPathComponent
        let baseNameNoExt = (songBaseName as NSString).deletingPathExtension

        // 1. Write <basename>-cover.jpg next to audio file
        let coverFileName = "\(baseNameNoExt)-cover.jpg"
        var writesCover = coverData?.isEmpty == false
        if writesCover, !createsCoverFile {
            writesCover = await coverFileExists(named: coverFileName, beside: song, using: connector)
            if !writesCover {
                plog("📁 Sidecar: embed-only mode, no cover file created beside \(songBaseName)")
            }
        }
        if writesCover, let coverData {
            let jpegData: Data = recompressJPEG(coverData) ?? coverData

            let coverPath = (songDir as NSString).appendingPathComponent(coverFileName)
            do {
                result.touchedRemotePaths.append(coverPath)
                try await connector.writeFile(
                    data: jpegData,
                    to: coverPath,
                    priority: .background
                )
                try await connector.verifySidecarWrite(data: jpegData, at: coverPath)
                result.coverWritten = true
                plog("📁 Sidecar: \(coverFileName) written to \(songDir)")
            } catch {
                result.coverError = error.localizedDescription
                result.errors.append("Cover: \(SourceErrorPresentation.userFacingDescription(error))")
                result.sourceUnavailable = Self.isSourceUnavailable(error)
                // Never pass user-controlled paths or remote error descriptions
                // to NSLog as the format string. A '%' in either value makes
                // NSLog read a non-existent variadic argument and can crash.
                plog("⚠️ Sidecar: Failed to write \(coverFileName): \(error)")
            }
        }

        // 2. Write the lyrics sidecar next to the audio file. New documents
        // default to LRC; an existing writable sidecar keeps its extension.
        if !result.sourceUnavailable, let lyricsLines, !lyricsLines.isEmpty {
            do {
                let targets = try await lyricsTargets(for: song, using: connector)
                let target = targets.write
                guard createsLyricsFile || targets.document.exists else {
                    plog("📝 Sidecar: embed-only mode, no lyrics file created beside \(songBaseName)")
                    return result
                }
                // The file's format follows the target, not the caller: the
                // scraper hands over lines, and serializing them as LRC into
                // an existing or replacement `.ttml` would leave TTML readers
                // with a file they cannot open.
                let sidecarContent = Self.lyricsSidecarContent(
                    for: target,
                    lines: lyricsLines,
                    editedText: lyricsContent
                )
                guard let sidecarData = sidecarContent.data(using: .utf8),
                      !sidecarData.isEmpty,
                      sidecarData.count <= LyricsSidecarTargetPolicy.maximumContentByteCount else {
                    let error = EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
                    result.lyricsError = error.localizedDescription
                    result.errors.append("Lyrics: \(SourceErrorPresentation.userFacingDescription(error))")
                    return result
                }
                let currentPreflight = LyricsPreflightResult(
                    document: targets.document,
                    write: target
                )
                guard expectedLyricsTarget == nil
                        || expectedLyricsTarget == currentPreflight else {
                    result.lyricsTargetChanged = true
                    return result
                }
                result.touchedRemotePaths.append(target.targetPath)
                let receipt = try await connector.writeLyricsSidecar(
                    data: sidecarData,
                    target: target,
                    priority: .background
                )
                if receipt.writtenPath != target.targetPath {
                    result.touchedRemotePaths.append(receipt.writtenPath)
                }
                let verifiedContent = try verifyLyricsSidecarWrite(
                    data: sidecarData,
                    content: sidecarContent,
                    target: target,
                    receipt: receipt
                )
                result.verifiedLyricsWrite = .init(
                    target: currentPreflight,
                    content: verifiedContent
                )
                result.lyricsWritten = true
                plog("📁 Sidecar: \(target.fileName) written to \(songDir)")
            } catch {
                result.lyricsError = error.localizedDescription
                result.errors.append("Lyrics: \(SourceErrorPresentation.userFacingDescription(error))")
                result.sourceUnavailable = Self.isSourceUnavailable(error)
                plog("⚠️ Sidecar: Failed to write lyrics: \(error)")
            }
        }

        return result
    }

    /// Whether the cover file a save would write is already there. Only
    /// path-addressed songs can be checked by name; a song stored under an
    /// opaque provider ID gets no new file in embed-only mode, and a listing
    /// that fails counts as "not there" — the embedded picture is the save.
    private func coverFileExists(
        named fileName: String,
        beside song: Song,
        using connector: any MusicSourceConnector
    ) async -> Bool {
        guard MusicScraperService.sidecarReferencePath(for: song, suffix: "-cover.jpg") != nil else {
            return false
        }
        let directory = (song.filePath as NSString).deletingLastPathComponent
        do {
            let items = try await connector.listFiles(at: directory.isEmpty ? "/" : directory)
            return items.contains { item in
                !item.isDirectory
                    && item.name.compare(fileName, options: .caseInsensitive) == .orderedSame
            }
        } catch {
            plog("⚠️ Sidecar: could not list \(directory) to look for \(fileName): \(error)")
            return false
        }
    }

    func removeLyrics(
        for song: Song,
        using connector: any MusicSourceConnector,
        expectedLyricsTarget: LyricsPreflightResult? = nil
    ) async -> WriteResult {
        var result = WriteResult()
        guard connector.supportsSidecarWriting else {
            result.errors.append("Source does not support sidecar writing")
            return result
        }

        do {
            let targets = try await lyricsTargets(for: song, using: connector)
            let target = targets.write
            let currentPreflight = LyricsPreflightResult(
                document: targets.document,
                write: target
            )
            guard expectedLyricsTarget == nil
                    || expectedLyricsTarget == currentPreflight else {
                result.lyricsTargetChanged = true
                return result
            }
            guard target.exists else {
                result.lyricsRemoved = true
                return result
            }
            guard let existingPath = target.existingPath else {
                throw SourceError.fileNotFound(target.fileName)
            }
            result.touchedRemotePaths.append(existingPath)
            try await connector.deleteFile(at: existingPath)
            result.lyricsRemoved = true
            plog("📁 Sidecar: \(target.fileName) removed")
        } catch {
            result.lyricsError = error.localizedDescription
            result.errors.append("Lyrics: \(SourceErrorPresentation.userFacingDescription(error))")
            result.sourceUnavailable = Self.isSourceUnavailable(error)
            plog("⚠️ Sidecar: Failed to remove lyrics: \(error)")
        }
        return result
    }

    /// What goes into the sidecar. A TTML target takes TTML: the editor hands
    /// over TTML text for one already, and lines from the scraper are
    /// serialized into it. Any other target takes the editor's text verbatim
    /// when it is LRC — it may carry headers the model does not keep — and
    /// LRC serialized from the lines otherwise.
    private nonisolated static func lyricsSidecarContent(
        for target: LyricsSidecarTarget,
        lines: [LyricLine],
        editedText: String?
    ) -> String {
        let edited = editedText?.trimmingCharacters(in: .newlines)
        let targetIsTTML = (target.fileName as NSString).pathExtension
            .caseInsensitiveCompare("ttml") == .orderedSame
        if targetIsTTML {
            if let edited, LyricsContentParser.isTTML(edited) { return edited }
            return LyricsContentParser.serializeTTML(lines)
        }
        if let edited, !edited.isEmpty,
           !LyricsContentParser.isTTML(edited),
           !LyricsContentParser.isSubtitleDocument(edited) {
            return edited
        }
        return LyricsContentParser.serialize(lines)
    }

    /// The single funnel for every lyric mutation. Preflight, write and remove
    /// all go through it, so they agree on the target — writeback compares the
    /// preflight result for equality before it acts.
    /// `document` is what sits beside the song now; `write` is where a save
    /// goes, which differs for a read-only document.
    private func lyricsTargets(
        for song: Song,
        using connector: any MusicSourceConnector
    ) async throws -> (document: LyricsSidecarTarget, write: LyricsSidecarTarget) {
        let document = try await Self.resolveTarget(
            for: song,
            using: connector,
            request: .current(for: song)
        )
        let write = try LyricsSidecarTargetPolicy.writeTarget(for: document)
        // A picked read-only document is saved as a new file beside it — but
        // that name can already be taken by another of the song's sources,
        // which the default ranking would have picked instead. Never write
        // over it; the save stays in Primuse.
        if document.separateWritePath == nil,
           write.fileName.caseInsensitiveCompare(document.fileName) != .orderedSame,
           document.documents.contains(where: {
               $0.name.caseInsensitiveCompare(write.fileName) == .orderedSame
           }) {
            throw LyricsSidecarReplacementCollision(
                documentName: document.fileName,
                replacementName: write.fileName
            )
        }
        return (document, write)
    }

    private static func resolveTarget(
        for song: Song,
        using connector: any MusicSourceConnector,
        request: LyricsDocumentRequest
    ) async throws -> LyricsSidecarTarget {
        if let resolver = connector as? any LyricsSidecarTargetResolving {
            return try await resolver.lyricsSidecarTarget(for: song, request: request)
        }
        return try await LyricsSidecarTargetPolicy.resolve(
            for: song,
            using: connector,
            request: request
        )
    }

    enum LyricsDocumentWriteError: LocalizedError, Equatable {
        /// The file is not in the song's folder any more, or the name now
        /// resolves to a different file.
        case documentMissing(String)
        /// Someone changed the file after the editor opened it.
        case changedElsewhere(String)

        var errorDescription: String? {
            switch self {
            case .documentMissing(let name):
                return String(format: String(localized: "lyrics_sources_document_missing %@"), name)
            case .changedElsewhere(let name):
                return String(format: String(localized: "lyrics_sources_document_changed %@"), name)
            }
        }
    }

    /// The address of one named lyric file of the song, for the raw editor's
    /// save. Throws when the name no longer resolves to an existing file.
    func lyricsDocumentTarget(
        named fileName: String,
        for song: Song,
        using connector: any MusicSourceConnector
    ) async throws -> LyricsSidecarTarget {
        guard connector.supportsSidecarWriting else {
            throw SourceError.connectionFailed("Source does not support sidecar writing")
        }
        let target = try await Self.resolveTarget(for: song, using: connector, request: .named(fileName))
        guard target.exists,
              target.separateWritePath == nil,
              target.fileName.caseInsensitiveCompare(fileName) == .orderedSame,
              target.existingPath != nil else {
            throw LyricsDocumentWriteError.documentMissing(fileName)
        }
        return target
    }

    /// Writes the raw editor's bytes over one lyric file, whatever its
    /// format: the listener typed the document, so nothing is serialized and
    /// a `.yrc` stays a `.yrc`. The file must still hold the bytes the editor
    /// opened; the write is read back byte for byte.
    func writeLyricsDocument(
        _ data: Data,
        to target: LyricsSidecarTarget,
        expecting originalData: Data,
        using connector: any MusicSourceConnector
    ) async throws -> LyricsSidecarWriteReceipt {
        guard !data.isEmpty, data.count <= LyricsSidecarTargetPolicy.maximumContentByteCount,
              let existingPath = target.existingPath else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        // A listing that knows the size answers most edits elsewhere for free.
        let listedSize = target.existingSize ?? 0
        if listedSize > 0, listedSize != Int64(originalData.count) {
            throw LyricsDocumentWriteError.changedElsewhere(target.fileName)
        }
        let current = try await connector.fetchRange(
            path: existingPath,
            offset: 0,
            length: Int64(originalData.count) + (listedSize > 0 ? 0 : 1),
            priority: .background
        )
        guard current == originalData else {
            throw LyricsDocumentWriteError.changedElsewhere(target.fileName)
        }
        let receipt = try await connector.writeLyricsSidecar(
            data: data,
            target: target,
            priority: .background
        )
        guard receipt.requestedTargetPath == target.targetPath,
              receipt.fileName.caseInsensitiveCompare(target.fileName) == .orderedSame,
              receipt.readback == data else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        plog("📁 Sidecar: \(target.fileName) rewritten from the raw editor")
        return receipt
    }

    private func verifyLyricsSidecarWrite(
        data: Data,
        content: String,
        target: LyricsSidecarTarget,
        receipt: LyricsSidecarWriteReceipt
    ) throws -> String {
        guard receipt.requestedTargetPath == target.targetPath,
              receipt.fileName.caseInsensitiveCompare(target.fileName) == .orderedSame,
              receipt.containerPath == target.containerPath,
              !receipt.writtenPath.isEmpty,
              receipt.remoteSize == Int64(receipt.readback.count),
              receipt.remoteSize > 0,
              receipt.remoteSize <= Int64(LyricsSidecarTargetPolicy.maximumContentByteCount),
              let readbackContent = String(data: receipt.readback, encoding: .utf8),
              LyricsContentParser.areContentsSemanticallyEquivalent(
                content,
                readbackContent
              ) else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        if receipt.readback == data { return content }
        return readbackContent
    }

    private nonisolated static func isSourceUnavailable(_ error: Error) -> Bool {
        guard let sourceError = error as? SourceError else { return false }
        if case .authenticationFailed = sourceError {
            return true
        }
        return false
    }

    /// The picture that goes into an audio file: a bounded JPEG — the one
    /// format every tag reader takes — made the same way as the covers the
    /// library syncs (long side up to 1200 pixels, orientation applied, the
    /// inconsistent-EXIF trap of #104 avoided). A cover that already is such a
    /// JPEG goes in unchanged. Nil when the blob cannot be decoded.
    nonisolated static func embeddableCoverData(_ data: Data) -> Data? {
        LibraryArtworkImageProcessor.isReusablePortableJPEG(data)
            ? data
            : LibraryArtworkImageProcessor.process(data)
    }

    /// Re-encodes an arbitrary image blob (PNG, HEIC, JPEG…) as JPEG at
    /// quality 0.85 so sidecars are uniform on disk. Returns nil if the
    /// blob isn't a recognized image — caller falls back to the original.
    private func recompressJPEG(_ data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.85)
        #else
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #endif
    }
}
