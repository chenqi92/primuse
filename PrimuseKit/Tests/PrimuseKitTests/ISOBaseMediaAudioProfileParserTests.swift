import Foundation
import Testing
@testable import PrimuseKit

@Suite("ISO Base Media audio profiles")
struct ISOBaseMediaAudioProfileParserTests {
    @Test("Routes multichannel AAC through the system media pipeline")
    func multichannelAAC() {
        let profiles = ISOBaseMediaAudioProfileParser.parseMetadataFile(
            mediaFile(codec: "mp4a", channels: 6)
        )
        #expect(profiles == [ISOBaseMediaAudioProfile(codecFourCC: "mp4a", channelCount: 6)])
        #expect(profiles.first?.prefersSystemMediaPlayback == true)
    }

    @Test("Keeps ordinary stereo AAC and ALAC on the established decoder")
    func stereoCodecs() {
        for codec in ["mp4a", "alac"] {
            let profile = ISOBaseMediaAudioProfileParser.parseMetadataFile(
                mediaFile(codec: codec, channels: 2)
            ).first
            #expect(profile?.prefersSystemMediaPlayback == false)
        }
    }

    @Test("Routes Dolby sample entries even when the base header reports stereo")
    func dolbyCodecs() {
        for codec in ["ac-3", "ec-3"] {
            let profile = ISOBaseMediaAudioProfileParser.parseMetadataFile(
                mediaFile(codec: codec, channels: 2)
            ).first
            #expect(profile?.prefersSystemMediaPlayback == true)
        }
    }

    @Test("Reads the real channel count from QuickTime sound description v2")
    func quickTimeV2ChannelCount() {
        let stereo = ISOBaseMediaAudioProfileParser.parseMetadataFile(
            mediaFile(codec: "mp4a", channels: 2, soundDescriptionVersion: 2)
        ).first
        let surround = ISOBaseMediaAudioProfileParser.parseMetadataFile(
            mediaFile(codec: "mp4a", channels: 6, soundDescriptionVersion: 2)
        ).first

        #expect(stereo?.channelCount == 2)
        #expect(stereo?.prefersSystemMediaPlayback == false)
        #expect(surround?.channelCount == 6)
        #expect(surround?.prefersSystemMediaPlayback == true)
    }

    @Test("Ignores video tracks and truncated atoms")
    func rejectsUnusableContainers() {
        #expect(ISOBaseMediaAudioProfileParser.parseMetadataFile(
            mediaFile(codec: "mp4a", channels: 6, handler: "vide")
        ).isEmpty)
        #expect(ISOBaseMediaAudioProfileParser.parseMetadataFile(
            Data([0, 0, 0, 32]) + Data("moov".utf8)
        ).isEmpty)
    }

    @Test("Playback requests only the missing end of a large front moov")
    func remoteFrontMovie() async throws {
        let seed = mediaFile(codec: "mp4a", channels: 6)
        let ftyp = seed.prefix(20)
        let moov = atom("moov", payload: atom("free", payload: Data(repeating: 0, count: 400_000)) + seed.dropFirst(28))
        let file = ftyp + moov + atom("mdat", payload: Data(repeating: 0, count: 1_100_000))
        let source = RangeSource(file)
        let profiles = try await ISOBaseMediaAudioProfileParser.readRemote(fileSize: Int64(file.count)) { offset, length in
            try await source.fetch(offset, length)
        }
        #expect(profiles.first?.channelCount == 6)
        #expect(await source.offsets == [0, 262_144])
        #expect(await source.bytesRead == Int64(ftyp.count + moov.count))
    }

    @Test("An mdat points to the small trailing audio description")
    func remoteTrailingMovie() async throws {
        let seed = mediaFile(codec: "alac", channels: 2)
        let moov = seed.dropFirst(20)
        let file = seed.prefix(20) + atom("mdat", payload: Data(repeating: 0, count: 900_000)) + moov
        let source = RangeSource(file)
        let profiles = try await ISOBaseMediaAudioProfileParser.readRemote(fileSize: Int64(file.count)) { offset, length in
            try await source.fetch(offset, length)
        }
        #expect(profiles.first?.codecFourCC == "alac")
        #expect(profiles.first?.prefersSystemMediaPlayback == false)
        #expect(await source.offsets == [0, -Int64(moov.count)])
    }

    @Test("Sources without suffix support can still return a trailing audio description through the prefix")
    func suffixUnsupported() async throws {
        let seed = mediaFile(codec: "ec-3", channels: 6)
        let file = seed.prefix(20) + atom("mdat", payload: Data(repeating: 0, count: 400_000)) + seed.dropFirst(20)
        let source = RangeSource(file, rejectsSuffix: true)
        let profiles = try await ISOBaseMediaAudioProfileParser.readRemote(fileSize: Int64(file.count)) { offset, length in
            try await source.fetch(offset, length)
        }
        #expect(profiles.first?.codecFourCC == "ec-3")
        #expect(await source.offsets == [0, -Int64(seed.count - 20), 262_144])
    }

    private actor RangeSource {
        let data: Data
        let rejectsSuffix: Bool
        private(set) var offsets: [Int64] = []
        private(set) var bytesRead: Int64 = 0

        init(_ data: Data, rejectsSuffix: Bool = false) {
            self.data = data
            self.rejectsSuffix = rejectsSuffix
        }

        func fetch(_ offset: Int64, _ length: Int64) throws -> Data {
            offsets.append(offset)
            if rejectsSuffix && offset < 0 { throw MetadataRangeReadError.suffixRangeUnsupported }
            bytesRead += length
            let start = offset < 0 ? data.count + Int(offset) : Int(offset)
            return data.subdata(in: start..<(start + Int(length)))
        }
    }

    private func mediaFile(
        codec: String,
        channels: UInt16,
        handler: String = "soun",
        soundDescriptionVersion: UInt16 = 0
    ) -> Data {
        var sampleEntryPayload = Data(repeating: 0, count: 8)
        appendUInt16(soundDescriptionVersion, to: &sampleEntryPayload)
        sampleEntryPayload += Data(repeating: 0, count: 6)
        if soundDescriptionVersion == 2 {
            appendUInt16(3, to: &sampleEntryPayload)
            sampleEntryPayload += Data(repeating: 0, count: 22)
            appendUInt32(UInt32(channels), to: &sampleEntryPayload)
            sampleEntryPayload += Data(repeating: 0, count: 20)
        } else {
            appendUInt16(channels, to: &sampleEntryPayload)
            sampleEntryPayload += Data(repeating: 0, count: 10)
        }
        let sampleEntry = atom(codec, payload: sampleEntryPayload)
        let stsd = atom(
            "stsd",
            payload: Data(repeating: 0, count: 4) + bigEndian(UInt32(1)) + sampleEntry
        )
        let stbl = atom("stbl", payload: stsd)
        let minf = atom("minf", payload: stbl)
        let hdlr = atom(
            "hdlr",
            payload: Data(repeating: 0, count: 8) + Data(handler.utf8) + Data(repeating: 0, count: 12)
        )
        let mdia = atom("mdia", payload: hdlr + minf)
        let trak = atom("trak", payload: mdia)
        let mvhd = atom("mvhd", payload: Data(repeating: 0, count: 24))
        return atom("ftyp", payload: Data("M4A \0\0\0\0M4A ".utf8))
            + atom("moov", payload: mvhd + trak)
    }

    private func atom(_ type: String, payload: Data) -> Data {
        bigEndian(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }

    private func bigEndian(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
