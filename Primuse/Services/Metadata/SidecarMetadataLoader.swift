import Foundation
import os
import PrimuseKit

enum SidecarMetadataLoader {
    /// Finds cover art file that matches the audio file name
    /// e.g., song.flac → song.jpg, song.png
    /// Also checks folder-level covers: cover.jpg, folder.jpg, album.jpg, then a
    /// picture named after the folder or, when known, the album / book title
    /// (`FolderCoverNamePolicy`).
    static func findCoverArt(for audioURL: URL, albumTitle: String? = nil) -> URL? {
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

        // Priority 4: a picture named after the folder (书名/书名.jpg), then after
        // the album or book title. Probed name by name: no directory listing here.
        let stems = FolderCoverNamePolicy.probeStems(
            folderName: directory.lastPathComponent,
            albumTitle: albumTitle
        )
        for stem in stems {
            for ext in PrimuseConstants.supportedCoverExtensions {
                let coverURL = directory.appendingPathComponent("\(stem).\(ext)")
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    return coverURL
                }
            }
        }

        // Priority 5: a disc subfolder (CD1, Disc 2) borrows the album folder's cover.
        let album = directory.deletingLastPathComponent()
        guard DiscFolderPolicy.isDiscFolderName(directory.lastPathComponent),
              album.path != directory.path,
              !FolderCoverNamePolicy.isGenericDirectory(named: album.lastPathComponent) else { return nil }
        let albumStems = PrimuseConstants.folderCoverNames + FolderCoverNamePolicy.probeStems(
            folderName: album.lastPathComponent,
            albumTitle: albumTitle
        )
        for stem in albumStems {
            for ext in PrimuseConstants.supportedCoverExtensions {
                let coverURL = album.appendingPathComponent("\(stem).\(ext)")
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    return coverURL
                }
            }
        }
        return nil
    }

    /// Finds lyrics file that matches the audio file name
    /// e.g., song.flac → song.lrc
    ///
    /// A bounded number of `fileExists` probes, so a bulk loop may call it
    /// once per song. The language-tagged names live in
    /// `findLanguageTaggedLyrics(for:index:)` because those need the whole
    /// directory.
    static func findLyrics(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent

        for ext in PrimuseConstants.readableLyricsExtensions {
            let lyricsURL = directory.appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: lyricsURL.path) {
                return lyricsURL
            }
        }

        return nil
    }

    /// Finds `<base>.<lang>.vtt` / `.srt` — what yt-dlp writes and what media
    /// server users name their external subtitles. Only ever called after
    /// `findLyrics(for:)` came back empty.
    /// - Parameter index: the caller's per-directory index. It is required on
    ///   purpose: answering this needs the whole directory, and a caller that
    ///   could omit it would list the folder once per song. The playback-time
    ///   lookups stay on `findLyrics(for:)` for the same reason — they look
    ///   into the audio cache, one flat directory per source whose generated
    ///   names can never carry a language suffix.
    static func findLanguageTaggedLyrics(
        for audioURL: URL,
        index: LanguageTaggedLyricsIndex
    ) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        guard let name = index.bestMatch(baseName: baseName) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Finds a same-name music video sidecar.
    /// e.g., song.flac -> song.mp4 / song.m4v / song.mov
    static func findMusicVideo(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent

        for ext in PrimuseConstants.supportedMusicVideoExtensions {
            let videoURL = directory.appendingPathComponent("\(baseName).\(ext)")
            if videoURL != audioURL, !EmbeddedMediaTrackInventory.isStemFileName(videoURL.lastPathComponent),
               FileManager.default.fileExists(atPath: videoURL.path) {
                return videoURL
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
        return loadLyrics(at: lyricsURL)
    }

    private struct DirectoryLyricsIndex {
        let directory: URL
        let modified: Date
        let index: LanguageTaggedLyricsIndex
    }

    private static let lastDirectory = OSAllocatedUnfairLock<DirectoryLyricsIndex?>(initialState: nil)

    /// A scan reads many songs from one directory. Reuse its names until the directory changes.
    private static func lyricsIndex(in directory: URL) -> LanguageTaggedLyricsIndex? {
        let modified = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let modified, let cached = lastDirectory.withLock({ $0 }),
           cached.directory == directory, cached.modified == modified { return cached.index }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let index = LanguageTaggedLyricsIndex(fileNames: names)
        if let modified {
            lastDirectory.withLock { $0 = DirectoryLyricsIndex(directory: directory, modified: modified, index: index) }
        }
        return index
    }

    static func loadLyrics(at url: URL) -> [LyricLine]? {
        guard let primary = try? LyricsParser.parse(from: url) else { return nil }
        let name = url.lastPathComponent
        let directory = url.deletingLastPathComponent()
        guard LyricsSidecarSelectionPolicy.chineseLRCName(forPrimary: name) != nil,
              let index = lyricsIndex(in: directory),
              let companion = index.translationTrack(forPrimary: name, baseName: url.deletingPathExtension().lastPathComponent)
        else { return primary }
        let translationURL = directory.appendingPathComponent(companion)
        guard let values = try? translationURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= LyricsSidecarTargetPolicy.maximumContentByteCount,
              let translation = try? LyricsParser.parse(from: translationURL) else { return primary }
        return LyricsTranslationTrackPolicy.merging(primary: primary, translation: translation, companionFileName: companion) ?? primary
    }
}
