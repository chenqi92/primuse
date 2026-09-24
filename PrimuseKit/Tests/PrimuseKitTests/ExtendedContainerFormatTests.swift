import Foundation
import Testing
@testable import PrimuseKit

struct ExtendedContainerFormatTests {
    @Test("New extensions map to a format and are scanned")
    func extensionsMapToFormats() {
        let expected: [String: AudioFormat] = [
            "mka": .mka, "webm": .webm, "weba": .webm,
            "mp2": .mp2, "mpa": .mp2, "mp1": .mp2, "m2a": .mp2,
            "w64": .w64, "rf64": .rf64, "bw64": .rf64, "ra": .ra,
            "m4r": .m4a, "aifc": .aiff, "bwf": .wav,
        ]
        for (fileExtension, format) in expected {
            #expect(AudioFormat.from(fileExtension: fileExtension.uppercased()) == format)
            #expect(PrimuseConstants.supportedAudioExtensions.contains(fileExtension))
        }
        // Video containers stay out: `.mp4` for the reason documented on the
        // whitelist, `.mkv`/`.rm` because they are overwhelmingly video.
        for excluded in ["mp4", "mkv", "rm", "3gp"] {
            #expect(!PrimuseConstants.supportedAudioExtensions.contains(excluded))
        }
    }

    @Test("FFmpeg-only containers route to FFmpeg and never to AVPlayer")
    func containersRouteToFFmpeg() {
        for format in [AudioFormat.mka, .webm, .mp2, .w64, .rf64, .ra] {
            #expect(format.requiresFFmpeg)
            #expect(format.prefersFFmpegDecoder)
            #expect(format.avPlayerContentType == nil)
            #expect(TVLocalDecoder(format: format) == .ffmpeg)
            #expect(!MediaRelaySourcePolicy.contentType(for: format).isEmpty)
        }
        #expect(AudioFormat.w64.isLossless)
        #expect(AudioFormat.rf64.isLossless)
        #expect(!AudioFormat.mka.isLossless)
        #expect(!AudioFormat.mp2.isLossless)
    }

    @Test("Container signatures are recognised from the first bytes")
    func containerSignatures() {
        let matroska = Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81])
        #expect(AudioFileSignaturePolicy.inspect(matroska) == .matroska)
        #expect(RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: "webm",
            signature: .matroska
        ) == "mka")

        for magic in ["RF64", "BW64"] {
            var rf64 = Data(magic.utf8)
            rf64.append(Data(repeating: 0xFF, count: 4))
            rf64.append(Data("WAVEds64".utf8))
            #expect(AudioFileSignaturePolicy.inspect(rf64) == .rf64)
        }

        var wave64 = Data([
            0x72, 0x69, 0x66, 0x66, 0x2E, 0x91, 0xCF, 0x11,
            0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00,
        ])
        wave64.append(Data(repeating: 0, count: 8))
        wave64.append(Data([
            0x77, 0x61, 0x76, 0x65, 0xF3, 0xAC, 0xD3, 0x11,
            0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A,
        ]))
        #expect(AudioFileSignaturePolicy.inspect(wave64) == .wave64)
        // A GUID prefix without the `wave` GUID is not claimed.
        #expect(AudioFileSignaturePolicy.inspect(wave64.prefix(24)) == .unknown)

        #expect(AudioFileSignaturePolicy.inspect(Data(".RMF".utf8) + Data(count: 8)) == .realMedia)
        #expect(AudioFileSignaturePolicy.inspect(Data([0x2E, 0x72, 0x61, 0xFD, 0, 4])) == .realMedia)

        var aifc = Data("FORM".utf8)
        aifc.append(Data(repeating: 0, count: 4))
        aifc.append(Data("AIFC".utf8))
        #expect(AudioFileSignaturePolicy.inspect(aifc) == .aiff)
    }

    @Test("Aliases pick their container's tail strategy before any byte is read")
    func aliasTailStrategies() {
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "m4r",
            isExplicitReread: false
        ) == .isoBaseMedia)
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "AIFC",
            isExplicitReread: false
        ) == .containerID3)
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "bwf",
            isExplicitReread: false
        ) == .containerID3)
    }

    @Test("FFmpeg's Matroska tag spelling maps onto song fields")
    func ffmpegMatroskaTags() throws {
        // Exactly what FFmpeg 8 reports for a file muxed with
        // `-metadata title=… album_artist=… track=3/12 disc=1/2`.
        let tags: [(key: String, value: String)] = [
            ("title", "T1"), ("DISC", "1/2"), ("ARTIST", "A1"),
            ("ALBUM", "AL1"), ("ALBUM_ARTIST", "AA1"), ("GENRE", "G1"),
            ("DATE", "2019"), ("track", "3/12"), ("ENCODER", "Lavf62.3.100"),
            ("DURATION", "00:00:03.000000000"),
        ]
        let parsed = try #require(EmbeddedTagMetadataParser.parseContainerTags(tags))
        #expect(parsed.title == "T1")
        #expect(parsed.artist == "A1")
        #expect(parsed.albumTitle == "AL1")
        #expect(parsed.albumArtist == "AA1")
        #expect(parsed.genre == "G1")
        #expect(parsed.year == 2019)
        #expect(parsed.trackNumber == 3)
        #expect(parsed.discNumber == 1)
    }

    @Test("Matroska target-scoped keys keep album and track fields apart")
    func matroskaTargetScopedTags() throws {
        let tags: [(key: String, value: String)] = [
            ("ALBUM/TITLE", "The Album"),
            ("ALBUM/ARTIST", "Album Artist"),
            ("ALBUM/DATE_RELEASED", "2021-05-07"),
            ("ALBUM/TOTAL_PARTS", "12"),
            ("PART/PART_NUMBER", "2"),
            ("TRACK/TITLE", "The Song"),
            ("TRACK/ARTIST", "Song Artist"),
            ("TRACK/PART_NUMBER", "7"),
        ]
        let parsed = try #require(EmbeddedTagMetadataParser.parseContainerTags(tags))
        #expect(parsed.title == "The Song")
        #expect(parsed.artist == "Song Artist")
        #expect(parsed.albumTitle == "The Album")
        #expect(parsed.albumArtist == "Album Artist")
        #expect(parsed.year == 2021)
        #expect(parsed.trackNumber == 7)
        #expect(parsed.discNumber == 2)
    }

    @Test("Attached pictures must be images; empty tags yield nothing")
    func coverAndEmptyTags() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])
        let withCover = try #require(EmbeddedTagMetadataParser.parseContainerTags(
            [],
            coverArtData: jpeg
        ))
        #expect(withCover.coverArtData == jpeg)
        #expect(EmbeddedTagMetadataParser.parseContainerTags(
            [("title", "  "), ("ENCODER", "Lavf")],
            coverArtData: Data("not an image".utf8)
        ) == nil)
        // A repeated container/stream value is not a second artist.
        let repeated = try #require(EmbeddedTagMetadataParser.parseContainerTags(
            [("ARTIST", "A1"), ("artist", "A1")]
        ))
        #expect(repeated.artists == ["A1"])
    }
}
