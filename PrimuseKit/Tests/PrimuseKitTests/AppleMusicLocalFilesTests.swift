import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music imported files")
struct AppleMusicLocalFilesTests {
    private func fourCC(_ code: String) -> UInt32 {
        AppleMusicLocalFileDetailsPolicy.fourCC(code)
    }

    @Test("Codec IDs map to the formats Primuse shows")
    func mapsCodecIDs() {
        let policy = AppleMusicLocalFileDetailsPolicy.self
        #expect(policy.format(codecID: fourCC("aac "), fileExtension: "m4a") == .aac)
        #expect(policy.format(codecID: fourCC("aach"), fileExtension: "m4a") == .aac)
        #expect(policy.format(codecID: fourCC("alac"), fileExtension: "m4a") == .alac)
        #expect(policy.format(codecID: fourCC(".mp3"), fileExtension: "mp3") == .mp3)
        #expect(policy.format(codecID: fourCC("lpcm"), fileExtension: "wav") == .wav)
        #expect(policy.format(codecID: fourCC("lpcm"), fileExtension: "aiff") == .aiff)
    }

    @Test("MPEG-4 audio stays open until the asset is inspected")
    func leavesMPEG4SeedOpen() {
        let policy = AppleMusicLocalFileDetailsPolicy.self
        #expect(policy.seedFormat(fileExtension: "m4a") == nil)
        #expect(policy.seedFormat(fileExtension: "M4A") == nil)
        #expect(policy.seedFormat(fileExtension: "mp3") == .mp3)
        #expect(policy.seedFormat(fileExtension: "wav") == .wav)
        // An unknown codec in an MPEG-4 file must not be relabelled as M4A.
        #expect(policy.format(codecID: fourCC("zzzz"), fileExtension: "m4a") == nil)
    }

    @Test("Bit depth is reported only where the codec carries one")
    func reportsBitDepth() {
        let policy = AppleMusicLocalFileDetailsPolicy.self
        #expect(policy.bitDepth(codecID: fourCC("alac"), bitsPerChannel: 0, formatFlags: 1) == 16)
        #expect(policy.bitDepth(codecID: fourCC("alac"), bitsPerChannel: 0, formatFlags: 3) == 24)
        #expect(policy.bitDepth(codecID: fourCC("lpcm"), bitsPerChannel: 24, formatFlags: 0) == 24)
        #expect(policy.bitDepth(codecID: fourCC("aac "), bitsPerChannel: 0, formatFlags: 0) == nil)
        #expect(policy.bitDepth(codecID: fourCC(".mp3"), bitsPerChannel: 16, formatFlags: 0) == nil)
    }

    @Test("Bit rate falls back when AVFoundation reports no data rate")
    func fallsBackForBitRate() {
        let policy = AppleMusicLocalFileDetailsPolicy.self
        #expect(policy.bitRate(
            estimatedDataRate: 256_000, codecID: fourCC("aac "), sampleRate: 44_100,
            channels: 2, bitsPerChannel: 0, sampleDataLength: nil, duration: nil
        ) == 256)
        // AVFoundation reports 0 for every PCM file (measured on WAV and AIFF).
        #expect(policy.bitRate(
            estimatedDataRate: 0, codecID: fourCC("lpcm"), sampleRate: 44_100,
            channels: 2, bitsPerChannel: 16, sampleDataLength: nil, duration: nil
        ) == 1_411)
        #expect(policy.bitRate(
            estimatedDataRate: 0, codecID: fourCC("lpcm"), sampleRate: 96_000,
            channels: 2, bitsPerChannel: 24, sampleDataLength: nil, duration: nil
        ) == 4_608)
        #expect(policy.bitRate(
            estimatedDataRate: 0, codecID: fourCC(".mp3"), sampleRate: 44_100,
            channels: 2, bitsPerChannel: 0, sampleDataLength: 4_000_000, duration: 250
        ) == 128)
        #expect(policy.bitRate(
            estimatedDataRate: nil, codecID: fourCC(".mp3"), sampleRate: 44_100,
            channels: 2, bitsPerChannel: 0, sampleDataLength: nil, duration: 250
        ) == nil)
    }

    @Test("The SYLT payload AVFoundation returns parses as timed lyrics")
    func parsesAVFoundationSYLTPayload() {
        // `AVMetadataItem.dataValue` for id3/SYLT, as returned on macOS 27.
        var payload = Data([3]) + Data("chi".utf8) + Data([2, 1, 0])
        for (text, milliseconds) in [("Line one", 1_000), ("\nLine two", 3_000), ("\nLine three", 5_000)] {
            payload += Data(text.utf8) + Data([0])
            payload += Data([0, 0, UInt8(milliseconds >> 8), UInt8(milliseconds & 0xFF)])
        }
        #expect(payload.count == 50)
        let frame = ID3SynchronizedLyricsParser.parse(payload)
        let lines = LyricsContentParser.parseText(frame?.text ?? "")
        #expect(lines.map(\.text) == ["Line one", "Line two", "Line three"])
        #expect(lines.map(\.timestamp) == [1, 3, 5])
        let allSynchronized = lines.allSatisfy { $0.isSynchronized }
        #expect(allSynchronized)
    }

    @Test("File details replace MusicKit's placeholder and keep what is unknown")
    func appliesDetails() {
        let song = Song(
            id: "song",
            title: "Title",
            fileFormat: .aac,
            filePath: "i.abc",
            sourceID: AppleMusicLibraryIdentity.sourceID,
            fileSize: 0,
            bitRate: nil,
            sampleRate: nil,
            bitDepth: nil
        )
        let applied = AppleMusicLocalFileDetailsPolicy.applying(
            AppleMusicLocalFileDetails(fileFormat: .alac, sampleRate: 96_000, bitDepth: 24),
            to: song
        )
        #expect(applied.fileFormat == .alac)
        #expect(applied.sampleRate == 96_000)
        #expect(applied.bitDepth == 24)
        #expect(applied.bitRate == nil)
        #expect(applied.fileSize == 0)

        let seedOnly = AppleMusicLocalFileDetailsPolicy.applying(AppleMusicLocalFileDetails(), to: song)
        #expect(seedOnly.fileFormat == .aac)
    }

    @Test("Probed values win over the library database, which still fills gaps")
    func overlaysProbedDetails() {
        let library = AppleMusicLocalFileDetails(bitRate: 256, sampleRate: 44_100, fileSize: 9_000_000)
        let merged = library.overlaying(
            AppleMusicLocalFileDetails(fileFormat: .aac, bitRate: 262, isProbed: true)
        )
        #expect(merged.fileFormat == .aac)
        #expect(merged.bitRate == 262)
        #expect(merged.sampleRate == 44_100)
        #expect(merged.fileSize == 9_000_000)
        #expect(merged.isProbed)
    }

    @Test("A persistent ID in any MusicKit representation finds the file")
    func matchesPersistentIDAliases() {
        let index = AppleMusicLocalFileMatchIndex([
            file(0xFB24_11D6_0916_F0E2, "Song", "Artist", "Album", 200),
        ])
        #expect(index.persistentID(forIdentifiers: ["-350135260054884126"]) == 0xFB24_11D6_0916_F0E2)
        #expect(index.persistentID(forIdentifiers: ["i.abc", "fb2411d60916f0e2"]) == 0xFB24_11D6_0916_F0E2)
        #expect(index.persistentID(forIdentifiers: ["i.abc"]) == nil)
    }

    @Test("Metadata matching needs title, artist and duration to agree")
    func matchesMetadataStrictly() {
        let index = AppleMusicLocalFileMatchIndex([
            file(1, "晴天", "周杰伦", "叶惠美", 269.4),
            file(2, "晴天", "Cover Band", "Covers", 269.0),
        ])
        #expect(index.persistentID(title: "晴天", artist: "周杰伦", album: nil, duration: 270.5) == 1)
        #expect(index.persistentID(title: " 晴天 ", artist: "周杰伦", album: "叶惠美", duration: 269) == 1)
        // Duration disagrees: a different recording.
        #expect(index.persistentID(title: "晴天", artist: "周杰伦", album: nil, duration: 240) == nil)
        // Title alone never decides.
        #expect(index.persistentID(title: "晴天", artist: nil, album: nil, duration: 269) == nil)
        #expect(index.persistentID(title: "晴天", artist: "Someone", album: nil, duration: 269) == nil)
        #expect(index.persistentID(title: "晴天", artist: "周杰伦", album: nil, duration: nil) == nil)
    }

    @Test("Duplicate imports resolve by album or not at all")
    func resolvesDuplicatesByAlbum() {
        let index = AppleMusicLocalFileMatchIndex([
            file(1, "Song", "Artist", "Album", 200),
            file(2, "Song", "Artist", "Greatest Hits", 200.5),
        ])
        #expect(index.persistentID(title: "Song", artist: "Artist", album: "Greatest Hits", duration: 200) == 2)
        #expect(index.persistentID(title: "Song", artist: "Artist", album: nil, duration: 200) == nil)
        #expect(index.persistentID(title: "Song", artist: "Artist", album: "Live", duration: 200) == nil)
    }

    private func file(
        _ persistentID: UInt64,
        _ title: String,
        _ artist: String?,
        _ album: String?,
        _ duration: TimeInterval?
    ) -> AppleMusicImportedFile {
        AppleMusicImportedFile(
            persistentID: persistentID,
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }
}
