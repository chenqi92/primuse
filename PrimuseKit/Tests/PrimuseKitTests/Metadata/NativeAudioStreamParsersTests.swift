import Foundation
import Testing
@testable import PrimuseKit

@Suite("Native MP3 / M4A stream parsers")
struct NativeAudioStreamParsersTests {
    // MARK: MP3

    /// MPEG-1 Layer III, 128 kbps, 44.1 kHz, joint stereo: 417 字节一帧。
    private func frame(padding: Bool = false, payload: Data = Data()) -> Data {
        var bytes = Data([0xFF, 0xFB, padding ? 0x92 : 0x90, 0x64])
        let length = 417 + (padding ? 1 : 0)
        bytes.append(payload.prefix(length - 4))
        bytes.append(Data(repeating: 0, count: max(0, length - bytes.count)))
        return bytes
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private func id3(size: Int) -> Data {
        var header = Data("ID3".utf8) + Data([3, 0, 0])
        header.append(contentsOf: [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
                                   UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
        return header + Data(repeating: 0, count: size)
    }

    @Test func xingHeaderGivesExactDurationAndAverageBitRate() throws {
        // Xing 在 4 字节帧头 + 32 字节边信息之后。
        let xing = Data(repeating: 0, count: 32) + Data("Xing".utf8) + be32(0x3) + be32(1_000) + be32(417_000)
        var data = id3(size: 600)
        data.append(frame(payload: xing))
        for _ in 0..<5 { data.append(frame()) }
        let info = try #require(MPEGAudioStreamParser.parse(data, audioStart: 610))
        #expect(info.frameOffset == 610)
        #expect(info.sampleRate == 44_100)
        #expect(info.frameCount == 1_000)
        let duration = try #require(info.exactDuration)
        #expect(abs(duration - 1_000 * 1_152 / 44_100.0) < 0.000_1)
        #expect(info.headerAverageBitRateKbps == 128)
        #expect(info.scannedAverageBitRateKbps == nil)
    }

    @Test func vbriHeaderIsRecognized() throws {
        var vbri = Data(repeating: 0, count: 32) + Data("VBRI".utf8)
        vbri.append(Data([0, 1, 0, 0, 0, 50]))
        vbri.append(be32(208_500))
        vbri.append(be32(500))
        var data = frame(payload: vbri)
        data.append(frame())
        let info = try #require(MPEGAudioStreamParser.parse(data, audioStart: 0))
        #expect(info.frameCount == 500)
        #expect(info.streamByteCount == 208_500)
    }

    @Test func constantBitRateWithoutHeaderAveragesTheScannedFrames() throws {
        var data = Data()
        for index in 0..<40 { data.append(frame(padding: index % 3 == 0)) }
        let info = try #require(MPEGAudioStreamParser.parse(data, audioStart: 0))
        #expect(info.frameCount == nil)
        #expect(info.exactDuration == nil)
        let average = try #require(info.scannedAverageBitRateKbps)
        #expect(abs(average - 128) < 1)
    }

    @Test func unconfirmedSyncWordsAreNotTreatedAsAudio() {
        // 封面数据里碰巧出现一个帧头, 后面接的不是帧。
        var data = Data(repeating: 0x11, count: 100) + Data([0xFF, 0xFB, 0x90, 0x64])
        data.append(Data(repeating: 0x22, count: 2_000))
        #expect(MPEGAudioStreamParser.parse(data, audioStart: 0) == nil)
        // Layer II 不收。
        var layerTwo = Data()
        for _ in 0..<3 { layerTwo.append(Data([0xFF, 0xFD, 0x90, 0x64]) + Data(repeating: 0, count: 413)) }
        #expect(MPEGAudioStreamParser.parse(layerTwo, audioStart: 0) == nil)
    }

    // MARK: M4A

    private func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(8 + payload.count)) + Data(type.data(using: .isoLatin1)!) + payload
    }

    private func fullBox(_ type: String, _ payload: Data) -> Data {
        box(type, Data([0, 0, 0, 0]) + payload)
    }

    private func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }

    private func dataAtom(type: UInt32, _ value: Data) -> Data {
        box("data", be32(type) + be32(0) + value)
    }

    private func textItem(_ type: String, _ values: String...) -> Data {
        box(type, values.reduce(Data()) { $0 + dataAtom(type: 1, Data($1.utf8)) })
    }

    private func esds(audioSpecificConfig: [UInt8]) -> Data {
        let specific = Data([0x05, UInt8(audioSpecificConfig.count)] + audioSpecificConfig)
        let decoderBody = Data([0x40, 0x15, 0, 0, 0]) + be32(256_000) + be32(256_000) + specific
        let decoder = Data([0x04, UInt8(decoderBody.count)]) + decoderBody
        let esBody = Data([0, 0, 0]) + decoder + Data([0x06, 0x01, 0x02])
        return fullBox("esds", Data([0x03, UInt8(esBody.count)]) + esBody)
    }

    private func audioSampleEntry(_ codec: String, rate: UInt32, child: Data) -> Data {
        var fields = Data(repeating: 0, count: 6) + be16(1)
        fields += be16(0) + be16(0) + be32(0)
        fields += be16(2) + be16(16) + be16(0) + be16(0)
        fields += be32(rate << 16)
        return box(codec, fields + child)
    }

    private func movie(
        sampleEntry: Data,
        sampleSizes: [UInt32] = Array(repeating: 1_000, count: 100),
        extraTracks: Int = 0,
        udta: Data? = nil,
        extraMovieChildren: Data = Data()
    ) -> Data {
        let mvhd = fullBox("mvhd", be32(0) + be32(0) + be32(44_100) + be32(44_100 * 120) + Data(repeating: 0, count: 80))
        let mdhd = fullBox("mdhd", be32(0) + be32(0) + be32(44_100) + be32(44_100 * 120) + be32(0))
        let hdlr = fullBox("hdlr", be32(0) + Data("soun".utf8) + Data(repeating: 0, count: 13))
        let stsd = fullBox("stsd", be32(1) + sampleEntry)
        let stsz = fullBox("stsz", be32(0) + be32(UInt32(sampleSizes.count)) + sampleSizes.reduce(Data()) { $0 + be32($1) })
        let stbl = box("stbl", stsd + stsz)
        let trak = box("trak", box("mdia", mdhd + hdlr + box("minf", stbl)))
        var children = mvhd + trak
        for _ in 0..<extraTracks { children += trak }
        if let udta { children += udta }
        children += extraMovieChildren
        return box("ftyp", Data("M4A ".utf8) + be32(0)) + box("moov", children)
    }

    private func iTunesTags(_ items: Data) -> Data {
        let hdlr = fullBox("hdlr", be32(0) + Data("mdir".utf8) + Data("appl".utf8) + Data(repeating: 0, count: 9))
        return box("udta", fullBox("meta", hdlr + box("ilst", items)) + box("free", Data(count: 16)))
    }

    private let aacLC441: [UInt8] = [0x12, 0x10]

    @Test func aacMovieReportsAudioPropertiesAndITunesTags() throws {
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let items = textItem("\u{A9}nam", "晴天")
            + textItem("\u{A9}ART", "周杰伦", "Lara")
            + textItem("aART", "周杰伦")
            + textItem("\u{A9}alb", "叶惠美")
            + textItem("\u{A9}day", "2003-07-31")
            + box("trkn", dataAtom(type: 0, Data([0, 0, 0, 3, 0, 11, 0, 0])))
            + box("disk", dataAtom(type: 0, Data([0, 0, 0, 1, 0, 2])))
            + box("gnre", dataAtom(type: 0, Data([0, 14])))
            + box("covr", dataAtom(type: 13, cover))
            + textItem("\u{A9}lyr", "[00:01.00]故事的小黄花")
        let data = movie(
            sampleEntry: audioSampleEntry("mp4a", rate: 44_100, child: esds(audioSpecificConfig: aacLC441)),
            udta: iTunesTags(items)
        )
        let parsed = try #require(ISOBaseMediaNativeMetadataParser.parse(data))
        #expect(parsed.duration == 120)
        #expect(parsed.codecFourCC == "mp4a")
        #expect(parsed.sampleRate == 44_100)
        #expect(parsed.channelCount == 2)
        #expect(parsed.bitDepth == nil)
        // 100 个样本 × 1000 字节 / 120 秒。
        #expect(parsed.averageBitRate == Int((100_000.0 * 8 / 120).rounded()))
        #expect(parsed.titles == ["晴天"])
        #expect(parsed.artists == ["周杰伦", "Lara"])
        #expect(parsed.albumArtist == "周杰伦")
        #expect(parsed.albumTitle == "叶惠美")
        #expect(parsed.releaseDate == "2003-07-31")
        #expect(parsed.trackNumber == 3)
        #expect(parsed.discNumber == 1)
        #expect(parsed.predefinedGenreCode == 14)
        #expect(parsed.coverArtData == cover)
        #expect(parsed.lyrics == "[00:01.00]故事的小黄花")
    }

    @Test func alacMovieReadsSourceBitDepthAndRateFromItsCookie() throws {
        var config = be32(4_096) + Data([0, 24, 40, 10, 14, 2]) + be16(255)
        config += be32(0) + be32(0) + be32(96_000)
        let entry = audioSampleEntry("alac", rate: 0, child: fullBox("alac", config))
        let parsed = try #require(ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: entry)))
        #expect(parsed.codecFourCC == "alac")
        #expect(parsed.bitDepth == 24)
        #expect(parsed.sampleRate == 96_000)
        #expect(parsed.channelCount == 2)
    }

    /// Packs AudioSpecificConfig fields (value, bit width) into bytes.
    private func asc(_ fields: [(Int, Int)]) -> [UInt8] {
        var bits: [Int] = []
        for (value, width) in fields {
            for shift in stride(from: width - 1, through: 0, by: -1) { bits.append((value >> shift) & 1) }
        }
        while bits.count % 8 != 0 { bits.append(0) }
        return stride(from: 0, to: bits.count, by: 8).map { start in
            UInt8(bits[start..<start + 8].reduce(0) { $0 << 1 | $1 })
        }
    }

    private func parsedAAC(_ config: [UInt8], declaredRate: UInt32) -> ISOBaseMediaNativeMetadata? {
        let entry = audioSampleEntry("mp4a", rate: declaredRate, child: esds(audioSpecificConfig: config))
        return ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: entry))
    }

    /// HE-AAC reports the AAC core's rate, as AVFoundation does (checked
    /// against it on files from afconvert and FFmpeg's AudioToolbox encoder).
    @Test func heAACThatDeclaresSBRReportsTheCoreRateAndDecodedChannels() throws {
        // Hierarchical: AOT 5, core 22.05 kHz stereo, SBR to 44.1 kHz, core LC.
        let explicit = try #require(parsedAAC([0x2B, 0x92, 0x08, 0x00], declaredRate: 22_050))
        #expect(explicit.sampleRate == 22_050)
        #expect(explicit.channelCount == 2)
        #expect(explicit.codecFourCC == "mp4a")
        // HE-AAC v2: AOT 29, mono 24 kHz core, SBR to 48 kHz, PS makes it stereo.
        let v2 = try #require(parsedAAC(asc([(29, 5), (6, 4), (1, 4), (3, 4), (2, 5), (0, 3)]), declaredRate: 48_000))
        #expect(v2.sampleRate == 24_000)
        #expect(v2.channelCount == 2)
        // Backward compatible: an LC config, then sync extension 0x2B7 with SBR present.
        let compatible = try #require(parsedAAC(
            asc([(2, 5), (6, 4), (2, 4), (0, 3), (0x2B7, 11), (5, 5), (1, 1), (3, 4)]), declaredRate: 24_000))
        #expect(compatible.sampleRate == 24_000)
        #expect(compatible.channelCount == 2)
        // ...and 0x548 with PS present on a mono core.
        let compatiblePS = try #require(parsedAAC(
            asc([(2, 5), (6, 4), (1, 4), (0, 3), (0x2B7, 11), (5, 5), (1, 1), (3, 4), (0x548, 11), (1, 1)]),
            declaredRate: 48_000))
        #expect(compatiblePS.sampleRate == 24_000)
        #expect(compatiblePS.channelCount == 2)
        // A sync extension that says SBR is absent makes a low-rate LC plain LC
        // (FFmpeg's own encoder writes this).
        let plain = try #require(parsedAAC(
            asc([(2, 5), (7, 4), (2, 4), (0, 3), (0x2B7, 11), (5, 5), (0, 1)]), declaredRate: 22_050))
        #expect(plain.sampleRate == 22_050)
        #expect(plain.channelCount == 2)
        // Apple's encoders: 22.05 kHz stereo core, SBR to 44.1 kHz (afconvert -d aach) ...
        let apple = try #require(parsedAAC([0x13, 0x90, 0x56, 0xE5, 0xA0], declaredRate: 44_100))
        #expect(apple.sampleRate == 22_050)
        #expect(apple.channelCount == 2)
        // ... and HE-AAC v2, mono core plus PS (afconvert -d aacp).
        let appleV2 = try #require(parsedAAC([0x13, 0x88, 0x56, 0xE5, 0xA5, 0x48, 0x80], declaredRate: 44_100))
        #expect(appleV2.sampleRate == 22_050)
        #expect(appleV2.channelCount == 2)
        // A sample entry rate that matches neither the core nor the output rate.
        #expect(parsedAAC([0x2B, 0x92, 0x08, 0x00], declaredRate: 32_000) == nil)
    }

    @Test func aacChannelConfigurationSevenIsSevenPointOne() throws {
        let surround = try #require(parsedAAC(asc([(2, 5), (3, 4), (7, 4), (0, 3)]), declaredRate: 48_000))
        #expect(surround.channelCount == 8)
        // A program config element (configuration 0) is left to AVFoundation.
        #expect(parsedAAC(asc([(2, 5), (3, 4), (0, 4), (0, 3)]), declaredRate: 48_000) == nil)
    }

    @Test func structuresAVFoundationInterpretsDifferentlyAreLeftToIt() {
        let lc = audioSampleEntry("mp4a", rate: 44_100, child: esds(audioSpecificConfig: aacLC441))
        #expect(ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: lc)) != nil)
        // 22.05 kHz 又没明说 SBR 的 LC 可能是隐式 SBR。
        let lowRate = audioSampleEntry("mp4a", rate: 22_050, child: esds(audioSpecificConfig: [0x13, 0x90]))
        #expect(ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: lowRate)) == nil)
        // 两条音轨。
        #expect(ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: lc, extraTracks: 1)) == nil)
        // 分片 MP4。
        #expect(ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: lc, extraMovieChildren: box("mvex", Data()))) == nil)
        // QuickTime 的 udta 文本条目。
        let quickTime = box("udta", textItem("\u{A9}nam", "Title"))
        #expect(ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: lc, udta: quickTime)) == nil)
        // mdta 键表。
        let hdlr = fullBox("hdlr", be32(0) + Data("mdta".utf8) + Data(repeating: 0, count: 13))
        let keyed = box("udta", fullBox("meta", hdlr + fullBox("keys", be32(0))))
        #expect(ISOBaseMediaNativeMetadataParser.parse(movie(sampleEntry: lc, udta: keyed)) == nil)
        // 截断的 moov。
        let complete = movie(sampleEntry: lc)
        #expect(ISOBaseMediaNativeMetadataParser.parse(complete.prefix(complete.count - 10)) == nil)
    }
}
