import AVFoundation
import Foundation
import PrimuseKit
#if os(iOS)
import MediaPlayer
#endif

/// A file the user imported into Music.app, as the platform media library
/// reports it: `file://` from iTunesLibrary on macOS, `ipod-library://` from
/// MPMediaLibrary on iOS.
struct AppleMusicLocalFile: Sendable {
    let identity: AppleMusicImportedFile
    let assetURL: URL
    /// What the library database knows without opening the file.
    let libraryDetails: AppleMusicLocalFileDetails

    var persistentID: UInt64 { identity.persistentID }
}

/// Reads what MusicKit does not expose for imported files: their embedded
/// lyrics and their real audio properties.
enum AppleMusicLocalFileReader {
    /// A file that cannot be opened right now (an unmounted volume, a file
    /// Music.app is still copying) stays unprobed, so the next sync retries it.
    @concurrent
    static func probeDetails(of file: AppleMusicLocalFile) async -> AppleMusicLocalFileDetails {
        let fileExtension = file.assetURL.pathExtension
        let asset = AVURLAsset(url: file.assetURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let description = try? await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return file.libraryDetails }

        var probed = AppleMusicLocalFileDetails(isProbed: true)
        probed.fileFormat = AppleMusicLocalFileDetailsPolicy.format(
            codecID: basic.mFormatID,
            fileExtension: fileExtension
        )
        if basic.mSampleRate.isFinite, basic.mSampleRate > 0 {
            probed.sampleRate = Int(basic.mSampleRate.rounded())
        }
        probed.bitDepth = AppleMusicLocalFileDetailsPolicy.bitDepth(
            codecID: basic.mFormatID,
            bitsPerChannel: basic.mBitsPerChannel,
            formatFlags: basic.mFormatFlags
        )
        let dataRate = try? await track.load(.estimatedDataRate)
        let needsSampleBytes = !(dataRate.map { $0.isFinite && $0 > 0 } ?? false)
        let sampleDataLength = needsSampleBytes ? try? await track.load(.totalSampleDataLength) : nil
        let duration = needsSampleBytes
            ? (try? await asset.load(.duration)).map(CMTimeGetSeconds)
            : nil
        probed.bitRate = AppleMusicLocalFileDetailsPolicy.bitRate(
            estimatedDataRate: dataRate,
            codecID: basic.mFormatID,
            sampleRate: basic.mSampleRate,
            channels: basic.mChannelsPerFrame,
            bitsPerChannel: basic.mBitsPerChannel,
            sampleDataLength: sampleDataLength,
            duration: duration
        )
        return file.libraryDetails.overlaying(probed)
    }

    /// Embedded lyrics, including authored translations. On iOS the media
    /// database's own lyrics field is the fallback when the asset carries none
    /// that AVFoundation can see.
    @concurrent
    static func lyrics(of file: AppleMusicLocalFile) async -> [LyricLine]? {
        let metadata = file.assetURL.isFileURL
            ? await FileMetadataReader.read(from: file.assetURL)
            : await FileMetadataReader.readAssetMetadata(at: file.assetURL)
        if let lines = FileMetadataReader.parsedEmbeddedLyrics(from: metadata), !lines.isEmpty {
            return lines
        }
        #if os(iOS)
        if let text = mediaLibraryLyrics(persistentID: file.persistentID) {
            let lines = LyricsParser.parse(text)
            if !lines.isEmpty { return lines }
        }
        #endif
        return nil
    }

    #if os(iOS)
    private static func mediaLibraryLyrics(persistentID: UInt64) -> String? {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        ))
        let text = query.items?.first?.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
    #endif
}

/// Probed details survive relaunches so a sync can show real formats at once
/// instead of reopening every imported file. Keyed by persistent ID; a file
/// replaced in Music.app gets a new ID and is probed again.
struct AppleMusicLocalFileDetailsStore {
    private let url: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("apple-music-local-files.json")
    }

    func load() -> [UInt64: AppleMusicLocalFileDetails] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: AppleMusicLocalFileDetails].self, from: data)
        else { return [:] }
        var details: [UInt64: AppleMusicLocalFileDetails] = [:]
        for (key, value) in stored {
            if let persistentID = UInt64(key) { details[persistentID] = value }
        }
        return details
    }

    func save(_ details: [UInt64: AppleMusicLocalFileDetails]) {
        let stored = Dictionary(uniqueKeysWithValues: details.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
