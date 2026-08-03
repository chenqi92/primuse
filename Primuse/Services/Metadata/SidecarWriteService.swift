import Foundation
import PrimuseKit
#if os(iOS)
#if os(iOS)
import UIKit
#endif
#else
import AppKit
#endif

/// Writes sidecar files (cover art, lyrics) alongside source audio files on NAS/remote storage.
/// - Cover: `<basename>-cover.jpg` next to the audio file
/// - Lyrics: `<basename>.lrc` next to the audio file
actor SidecarWriteService {
    static let shared = SidecarWriteService()
    private init() {}

    struct WriteResult: Sendable {
        var coverWritten: Bool = false
        var lyricsWritten: Bool = false
        var lyricsRemoved: Bool = false
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
        let target = Self.lyricsTargetPath(for: song)
        let directory = (target as NSString).deletingLastPathComponent
        let items = try await connector.listFiles(at: directory.isEmpty ? "/" : directory)
        let targetName = (target as NSString).lastPathComponent
        let exists = items.contains { !$0.isDirectory && $0.name.caseInsensitiveCompare(targetName) == .orderedSame }
        return LyricsPreflightResult(
            targetPath: target,
            fileName: targetName,
            replacesExistingFile: exists
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
                result.coverWritten = true
                plog("📁 Sidecar: \(coverFileName) written to \(songDir)")
            } catch {
                result.errors.append("Cover: \(error.localizedDescription)")
                result.sourceUnavailable = Self.isSourceUnavailable(error)
                // Never pass user-controlled paths or remote error descriptions
                // to NSLog as the format string. A '%' in either value makes
                // NSLog read a non-existent variadic argument and can crash.
                plog("⚠️ Sidecar: Failed to write \(coverFileName): \(error)")
            }
        }

        // 2. Write <basename>.lrc next to audio file
        if !result.sourceUnavailable, let lyricsLines, !lyricsLines.isEmpty {
            let lrcContent = lyricsContent?.trimmingCharacters(in: .newlines)
                ?? LyricsContentParser.serialize(lyricsLines)
            if let lrcData = lrcContent.data(using: .utf8) {
                let lrcPath = Self.lyricsTargetPath(for: song)
                do {
                    try await connector.writeFile(
                        data: lrcData,
                        to: lrcPath,
                        priority: .background
                    )
                    result.lyricsWritten = true
                    plog("📁 Sidecar: \(baseNameNoExt).lrc written to \(songDir)")
                } catch {
                    result.errors.append("Lyrics: \(error.localizedDescription)")
                    result.sourceUnavailable = Self.isSourceUnavailable(error)
                    plog("⚠️ Sidecar: Failed to write .lrc: \(error)")
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

        let target = Self.lyricsTargetPath(for: song)
        let directory = (target as NSString).deletingLastPathComponent
        let targetName = (target as NSString).lastPathComponent
        do {
            let items = try await connector.listFiles(at: directory.isEmpty ? "/" : directory)
            guard items.contains(where: {
                !$0.isDirectory && $0.name.caseInsensitiveCompare(targetName) == .orderedSame
            }) else {
                result.lyricsRemoved = true
                return result
            }
            try await connector.deleteFile(at: target)
            result.lyricsRemoved = true
            plog("📁 Sidecar: \(targetName) removed from \(directory)")
        } catch {
            result.errors.append("Lyrics: \(error.localizedDescription)")
            result.sourceUnavailable = Self.isSourceUnavailable(error)
            plog("⚠️ Sidecar: Failed to remove \(targetName): \(error)")
        }
        return result
    }

    private nonisolated static func lyricsTargetPath(for song: Song) -> String {
        let songDir = (song.filePath as NSString).deletingLastPathComponent
        let songBase = ((song.filePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension

        if let ref = song.lyricsFileName, ref.contains("/") {
            let refDir = (ref as NSString).deletingLastPathComponent
            let refName = (ref as NSString).lastPathComponent
            let refBase = (refName as NSString).deletingPathExtension
            let refExtension = (refName as NSString).pathExtension
            if refDir == songDir,
               refBase.caseInsensitiveCompare(songBase) == .orderedSame,
               refExtension.caseInsensitiveCompare("lrc") == .orderedSame {
                return ref
            }
        }
        return (songDir as NSString).appendingPathComponent("\(songBase).lrc")
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
