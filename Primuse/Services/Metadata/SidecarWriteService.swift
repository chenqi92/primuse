import Foundation
import PrimuseKit
import UIKit

/// Writes sidecar files (cover art, lyrics) alongside source audio files on NAS/remote storage.
/// - Cover: `cover.jpg` in the album directory (shared by all songs in the same folder)
/// - Lyrics: `<basename>.lrc` next to the audio file
actor SidecarWriteService {
    static let shared = SidecarWriteService()
    private init() {}

    struct WriteResult: Sendable {
        var coverWritten: Bool = false
        var lyricsWritten: Bool = false
        var errors: [String] = []
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
        lyricsLines: [LyricLine]?
    ) async -> WriteResult {
        var result = WriteResult()
        let songDir = (song.filePath as NSString).deletingLastPathComponent
        let songBaseName = (song.filePath as NSString).lastPathComponent
        let baseNameNoExt = (songBaseName as NSString).deletingPathExtension

        // 1. Write <basename>-cover.jpg next to audio file
        if let coverData, !coverData.isEmpty {
            let jpegData: Data
            if let image = UIImage(data: coverData),
               let compressed = image.jpegData(compressionQuality: 0.85) {
                jpegData = compressed
            } else {
                jpegData = coverData
            }

            let coverFileName = "\(baseNameNoExt)-cover.jpg"
            let coverPath = (songDir as NSString).appendingPathComponent(coverFileName)
            do {
                try await connector.writeFile(data: jpegData, to: coverPath)
                result.coverWritten = true
                NSLog("📁 Sidecar: \(coverFileName) written to \(songDir)")
            } catch {
                result.errors.append("Cover: \(error.localizedDescription)")
                NSLog("⚠️ Sidecar: Failed to write \(coverFileName): \(error)")
            }
        }

        // 2. Write <basename>.lrc next to audio file
        if let lyricsLines, !lyricsLines.isEmpty {
            let lrcContent = lyricsLinesToLRC(lyricsLines)
            if let lrcData = lrcContent.data(using: .utf8) {
                let lrcPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt).lrc")
                do {
                    try await connector.writeFile(data: lrcData, to: lrcPath)
                    result.lyricsWritten = true
                    NSLog("📁 Sidecar: \(baseNameNoExt).lrc written to \(songDir)")
                } catch {
                    result.errors.append("Lyrics: \(error.localizedDescription)")
                    NSLog("⚠️ Sidecar: Failed to write .lrc: \(error)")
                }
            }
        }

        return result
    }

    /// Convert parsed LyricLines back to standard LRC format
    private func lyricsLinesToLRC(_ lines: [LyricLine]) -> String {
        var output = ""
        for line in lines {
            let totalSeconds = line.timestamp
            let minutes = Int(totalSeconds) / 60
            let seconds = totalSeconds - Double(minutes * 60)
            output += String(format: "[%02d:%05.2f]%@\n", minutes, seconds, line.text)
        }
        return output
    }
}
