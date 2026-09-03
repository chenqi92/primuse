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
            containerPath: target.containerPath,
            replacesExistingFile: target.exists,
            existingPath: target.existingPath,
            existingSize: target.existingSize
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
        lyricsContent: String? = nil,
        expectedLyricsTarget: LyricsPreflightResult? = nil
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
                guard !sidecarData.isEmpty,
                      sidecarData.count <= LyricsSidecarTargetPolicy.maximumContentByteCount else {
                    let error = EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
                    result.lyricsError = error.localizedDescription
                    result.errors.append("Lyrics: \(error.localizedDescription)")
                    return result
                }
                do {
                    let target = try await lyricsTarget(for: song, using: connector)
                    let currentPreflight = LyricsPreflightResult(
                        targetPath: target.targetPath,
                        fileName: target.fileName,
                        containerPath: target.containerPath,
                        replacesExistingFile: target.exists,
                        existingPath: target.existingPath,
                        existingSize: target.existingSize
                    )
                    guard expectedLyricsTarget == nil
                            || expectedLyricsTarget == currentPreflight else {
                        result.lyricsTargetChanged = true
                        return result
                    }
                    let receipt = try await connector.writeLyricsSidecar(
                        data: sidecarData,
                        target: target,
                        priority: .background
                    )
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
        using connector: any MusicSourceConnector,
        expectedLyricsTarget: LyricsPreflightResult? = nil
    ) async -> WriteResult {
        var result = WriteResult()
        guard connector.supportsSidecarWriting else {
            result.errors.append("Source does not support sidecar writing")
            return result
        }

        do {
            let target = try await lyricsTarget(for: song, using: connector)
            let currentPreflight = LyricsPreflightResult(
                targetPath: target.targetPath,
                fileName: target.fileName,
                containerPath: target.containerPath,
                replacesExistingFile: target.exists,
                existingPath: target.existingPath,
                existingSize: target.existingSize
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
            try await connector.deleteFile(at: existingPath)
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

    private func lyricsTarget(
        for song: Song,
        using connector: any MusicSourceConnector
    ) async throws -> LyricsSidecarTarget {
        if let resolver = connector as? any LyricsSidecarTargetResolving {
            return try await resolver.lyricsSidecarTarget(for: song)
        }
        return try await LyricsSidecarTargetPolicy.resolve(for: song, using: connector)
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
