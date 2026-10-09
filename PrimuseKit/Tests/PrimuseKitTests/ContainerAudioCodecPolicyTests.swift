import Foundation
import Testing
@testable import PrimuseKit

@Suite("Codec inside M4A containers")
struct ContainerAudioCodecPolicyTests {
    @Test("ALAC in M4A is lossless, and Hi-Res from 24 bit or 88.2 kHz")
    func alacQuality() {
        #expect(song(.m4a, codec: .alac, sampleRate: 44_100, bitDepth: 16).audioQuality == .lossless)
        #expect(song(.m4a, codec: .alac, sampleRate: 96_000, bitDepth: 24).audioQuality == .hiRes)
        #expect(song(.m4a, codec: .alac, sampleRate: 44_100, bitDepth: 24).audioQuality == .hiRes)
        #expect(song(.m4a, codec: .alac).codecFormat.displayName == "ALAC")
        #expect(song(.m4a, codec: .alac).detailedFormatName == "ALAC (M4A)")
        #expect(song(.flac).detailedFormatName == "FLAC")
        #expect(song(.m4a).detailedFormatName == "M4A")
    }

    @Test("AAC in M4A stays lossy even when a reader reports 16 bit")
    func aacQuality() {
        let aac = song(.m4a, codec: .aac, sampleRate: 44_100, bitDepth: 16)
        #expect(aac.audioQuality == .standard)
        #expect(aac.codecFormat.displayName == "AAC")
    }

    @Test("An unread M4A claims nothing")
    func unknownCodec() {
        let unread = song(.m4a, sampleRate: 96_000, bitDepth: 24)
        #expect(unread.audioQuality == .standard)
        #expect(unread.codecFormat == .m4a)
    }

    @Test("Only containers that hold several codecs use the codec")
    func singleCodecContainersIgnoreCodec() {
        #expect(song(.flac, codec: .aac, sampleRate: 44_100, bitDepth: 16).audioQuality == .lossless)
        #expect(song(.mp3, codec: .alac).codecFormat == .mp3)
        #expect(ContainerAudioCodecPolicy.storedCodec(.alac, container: .m4a) == .alac)
        #expect(ContainerAudioCodecPolicy.storedCodec(.alac, container: .mp4) == .alac)
        #expect(ContainerAudioCodecPolicy.storedCodec(.alac, container: .flac) == nil)
    }

    @Test("A read that finds no known codec still counts as read")
    func inspectedMarker() {
        #expect(ContainerAudioCodecPolicy.isUnread(format: .m4a, audioCodec: nil))
        #expect(!ContainerAudioCodecPolicy.isUnread(format: .flac, audioCodec: nil))

        let marker = ContainerAudioCodecPolicy.inspectedCodec(nil, container: .m4a)
        #expect(marker == .m4a)
        #expect(!ContainerAudioCodecPolicy.isUnread(format: .m4a, audioCodec: marker))
        #expect(ContainerAudioCodecPolicy.inspectedCodec(.alac, container: .m4a) == .alac)
        #expect(ContainerAudioCodecPolicy.inspectedCodec(nil, container: .flac) == nil)

        // 记成容器本身的歌照旧按容器显示, 不冒充任何编码。
        let inspected = song(.m4a, codec: marker, sampleRate: 96_000, bitDepth: 24)
        #expect(inspected.audioQuality == .standard)
        #expect(inspected.detailedFormatName == "M4A")
    }

    @Test("Maps MP4 sample entries")
    func sampleEntries() {
        #expect(ContainerAudioCodecPolicy.codec(sampleEntry: "alac") == .alac)
        #expect(ContainerAudioCodecPolicy.codec(sampleEntry: "mp4a") == .aac)
        #expect(ContainerAudioCodecPolicy.codec(sampleEntry: "fLaC") == .flac)
        #expect(ContainerAudioCodecPolicy.codec(sampleEntry: "ec-3") == .eac3)
        #expect(ContainerAudioCodecPolicy.codec(sampleEntry: "enca") == nil)
    }

    @Test("Maps Core Audio format IDs")
    func coreAudioIDs() {
        let fourCC = ContainerAudioCodecPolicy.fourCC
        #expect(ContainerAudioCodecPolicy.codec(coreAudioFormatID: fourCC("alac")) == .alac)
        #expect(ContainerAudioCodecPolicy.codec(coreAudioFormatID: fourCC("aac ")) == .aac)
        #expect(ContainerAudioCodecPolicy.codec(coreAudioFormatID: fourCC("aach")) == .aac)
        #expect(ContainerAudioCodecPolicy.codec(coreAudioFormatID: fourCC("lpcm")) == .pcm)
        #expect(ContainerAudioCodecPolicy.codec(coreAudioFormatID: fourCC("ima4")) == nil)
    }

    @Test("Maps media server codec names")
    func serverNames() {
        #expect(ContainerAudioCodecPolicy.codec(named: "ALAC") == .alac)
        #expect(ContainerAudioCodecPolicy.codec(named: " aac ") == .aac)
        #expect(ContainerAudioCodecPolicy.codec(named: "pcm_s16le") == .pcm)
        #expect(ContainerAudioCodecPolicy.codec(named: "mjpeg") == nil)
        #expect(ContainerAudioCodecPolicy.codec(named: nil) == nil)
    }

    @Test("The codec survives JSON and an unknown value decodes as unknown")
    func coding() throws {
        let encoded = try JSONEncoder().encode(song(.m4a, codec: .alac))
        #expect(try JSONDecoder().decode(Song.self, from: encoded).audioCodec == .alac)

        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["audioCodec"] = "codec-from-a-newer-build"
        let future = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Song.self, from: future)
        #expect(decoded.audioCodec == nil)
        #expect(decoded.fileFormat == .m4a)
    }

    private func song(
        _ format: AudioFormat,
        codec: AudioFormat? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil
    ) -> Song {
        Song(
            id: "song",
            title: "Song",
            fileFormat: format,
            filePath: "song.\(format.rawValue)",
            sourceID: "source",
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            dateAdded: Date(timeIntervalSince1970: 0),
            audioCodec: codec
        )
    }
}
