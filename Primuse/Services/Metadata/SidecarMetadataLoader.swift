import Foundation
import PrimuseKit

enum SidecarMetadataLoader {
    /// Finds cover art file that matches the audio file name
    /// e.g., song.flac → song.jpg, song.png
    /// Also checks folder-level covers: cover.jpg, folder.jpg, album.jpg
    static func findCoverArt(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent

        // Priority 1: same-name covers (song.jpg, song.png)
        for ext in PrimuseConstants.supportedCoverExtensions {
            let coverURL = directory.appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: coverURL.path) {
                return coverURL
            }
        }

        // Priority 2: name-cover pattern (song-cover.jpg) — common in foobar2000/MusicBee
        for ext in PrimuseConstants.supportedCoverExtensions {
            let coverURL = directory.appendingPathComponent("\(baseName)-cover.\(ext)")
            if FileManager.default.fileExists(atPath: coverURL.path) {
                return coverURL
            }
        }

        // Priority 3: folder-level covers (cover.jpg, folder.jpg, album.jpg)
        for name in PrimuseConstants.folderCoverNames {
            for ext in PrimuseConstants.supportedCoverExtensions {
                let coverURL = directory.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    return coverURL
                }
            }
        }

        return nil
    }

    /// Finds lyrics file that matches the audio file name
    /// e.g., song.flac → song.lrc
    static func findLyrics(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent

        for ext in PrimuseConstants.supportedLyricsExtensions {
            let lyricsURL = directory.appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: lyricsURL.path) {
                return lyricsURL
            }
        }

        return nil
    }

    /// Loads cover art data for a given audio file
    static func loadCoverArt(for audioURL: URL) -> Data? {
        guard let coverURL = findCoverArt(for: audioURL) else { return nil }
        return try? Data(contentsOf: coverURL)
    }

    /// Loads and parses lyrics for a given audio file
    static func loadLyrics(for audioURL: URL) -> [LyricLine]? {
        guard let lyricsURL = findLyrics(for: audioURL) else { return nil }
        return try? LyricsParser.parse(from: lyricsURL)
    }
}
