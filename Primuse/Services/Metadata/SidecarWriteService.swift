import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Writes sidecar files (cover art, lyrics) alongside source audio files on NAS/remote storage.
/// - Cover: `<basename>-cover.jpg` next to the audio file
/// - Lyrics: `<basename>.lrc` by default; an existing `.ttml` remains TTML
actor SidecarWriteService {
    static let shared = SidecarWriteService()
    private init() {}

    struct WriteResult: Sendable {
        var coverWritten: Bool = false
        var lyricsWritten: Bool = false
        var lyricsRemoved: Bool = false
        var coverError: String?
        var lyricsError: String?
        /// A credential/permission failure applies to the whole source, not
        /// only this asset. Batch scraping uses this to stop the remaining
        /// queued writes while keeping the locally cached metadata.
        var sourceUnavailable: Bool = false
        var errors: [String] = []
    }

    struct LyricsPreflightResult: Sendable, Equatable {
        let targetPath: String
        let fileName: String
        let replacesExistingFile: Bool
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
        let target = try await lyricsTarget(for: song, using: connector)
        return LyricsPreflightResult(
            targetPath: target.targetPath,
            fileName: target.fileName,
            replacesExistingFile: target.exists
        )
    }

    /// Write sidecar files for a song after scraping.
    /// - Parameters:
    ///   - song: The song with updated metadata
    ///   - connector: The source connector with write capability
    ///   - coverData: JPEG cover art data to write (optional)
    ///   - lyricsLines: Parsed lyric lines to write as .lrc (optional)
    func writeSidecars(
        for song: Song,
        using connector: any MusicSourceConnector,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String? = nil
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
        if let coverData, !coverData.isEmpty {
            let jpegData: Data = recompressJPEG(coverData) ?? coverData

            let coverFileName = "\(baseNameNoExt)-cover.jpg"
            let coverPath = (songDir as NSString).appendingPathComponent(coverFileName)
            do {
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
                result.errors.append("Cover: \(error.localizedDescription)")
                result.sourceUnavailable = Self.isSourceUnavailable(error)
                // Never pass user-controlled paths or remote error descriptions
                // to NSLog as the format string. A '%' in either value makes
                // NSLog read a non-existent variadic argument and can crash.
                plog("⚠️ Sidecar: Failed to write \(coverFileName): \(error)")
            }
        }

        // 2. Write the lyrics sidecar next to the audio file. New documents
        // default to LRC; an existing supported sidecar keeps its extension.
        if !result.sourceUnavailable, let lyricsLines, !lyricsLines.isEmpty {
            let sidecarContent = lyricsContent?.trimmingCharacters(in: .newlines)
                ?? LyricsContentParser.serialize(lyricsLines)
            if let sidecarData = sidecarContent.data(using: .utf8) {
                do {
                    let target = try await lyricsTarget(for: song, using: connector)
                    try await connector.writeFile(
                        data: sidecarData,
                        to: target.targetPath,
                        priority: .background
                    )
                    try await connector.verifySidecarWrite(
                        data: sidecarData,
                        at: target.targetPath
                    )
                    result.lyricsWritten = true
                    plog("📁 Sidecar: \(target.fileName) written to \(songDir)")
                } catch {
                    result.lyricsError = error.localizedDescription
                    result.errors.append("Lyrics: \(error.localizedDescription)")
                    result.sourceUnavailable = Self.isSourceUnavailable(error)
                    plog("⚠️ Sidecar: Failed to write lyrics: \(error)")
                }
            }
        }

        return result
    }

    func removeLyrics(
        for song: Song,
        using connector: any MusicSourceConnector
    ) async -> WriteResult {
        var result = WriteResult()
        guard connector.supportsSidecarWriting else {
            result.errors.append("Source does not support sidecar writing")
            return result
        }

        do {
            let target = try await lyricsTarget(for: song, using: connector)
            guard target.exists else {
                result.lyricsRemoved = true
                return result
            }
            try await connector.deleteFile(at: target.targetPath)
            result.lyricsRemoved = true
            plog("📁 Sidecar: \(target.fileName) removed")
        } catch {
            result.lyricsError = error.localizedDescription
            result.errors.append("Lyrics: \(error.localizedDescription)")
            result.sourceUnavailable = Self.isSourceUnavailable(error)
            plog("⚠️ Sidecar: Failed to remove lyrics: \(error)")
        }
        return result
    }

    private nonisolated static func lyricsTargetPath(for song: Song) -> String {
        let songDir = (song.filePath as NSString).deletingLastPathComponent
        let songBase = ((song.filePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension

        if let ref = song.lyricsFileName, !ref.isEmpty {
            let resolvedRef = ref.contains("/")
                ? ref
                : (songDir as NSString).appendingPathComponent(ref)
            let refDir = (resolvedRef as NSString).deletingLastPathComponent
            let refName = (resolvedRef as NSString).lastPathComponent
            let refBase = (refName as NSString).deletingPathExtension
            let refExtension = (refName as NSString).pathExtension.lowercased()
            if refDir == songDir,
               refBase.caseInsensitiveCompare(songBase) == .orderedSame,
               PrimuseConstants.supportedLyricsExtensions.contains(refExtension) {
                return resolvedRef
            }
        }
        return (songDir as NSString).appendingPathComponent("\(songBase).lrc")
    }

    private func lyricsTarget(
        for song: Song,
        using connector: any MusicSourceConnector
    ) async throws -> LyricsSidecarTarget {
        if let resolver = connector as? any LyricsSidecarTargetResolving {
            return try await resolver.lyricsSidecarTarget(for: song)
        }

        let targetPath = Self.lyricsTargetPath(for: song)
        let directory = (targetPath as NSString).deletingLastPathComponent
        let fileName = (targetPath as NSString).lastPathComponent
        let items = try await connector.listFiles(at: directory.isEmpty ? "/" : directory)
        return LyricsSidecarTarget(
            targetPath: targetPath,
            fileName: fileName,
            exists: items.contains {
                !$0.isDirectory && $0.name.caseInsensitiveCompare(fileName) == .orderedSame
            }
        )
    }

    private nonisolated static func isSourceUnavailable(_ error: Error) -> Bool {
        guard let sourceError = error as? SourceError else { return false }
        if case .authenticationFailed = sourceError {
            return true
        }
        return false
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
