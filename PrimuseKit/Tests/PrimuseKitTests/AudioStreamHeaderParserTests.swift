import Foundation
import Testing
@testable import PrimuseKit

@Suite("Codec from container headers")
struct AudioStreamHeaderParserTests {
    @Test("WMA Lossless is told apart from lossy WMA")
    func asf() {
        let lossless = AudioStreamHeaderParser.parse(asfFile(formatTag: 0x0163, bits: 24), container: .wma)
        #expect(lossless == AudioStreamHeaderInfo(codec: .wmaLossless, sampleRate: 96_000, bitDepth: 24, channelCount: 2))
        #expect(AudioFormat.wmaLossless.isLossless)

        let lossy = AudioStreamHeaderParser.parse(asfFile(formatTag: 0x0161, bits: 16), container: .wma)
        #expect(lossy?.codec == .wma)
        #expect(lossy?.bitDepth == nil)

        #expect(AudioStreamHeaderParser.parse(Data(repeating: 0, count: 200), container: .wma) == nil)
    }

    @Test("WavPack hybrid mode counts as lossy")
    func wavPack() {
        let lossless = AudioStreamHeaderParser.parse(wavPackFile(hybrid: false), container: .wv)
        #expect(lossless == AudioStreamHeaderInfo(codec: .wv, sampleRate: 96_000, bitDepth: 24))

        let hybrid = AudioStreamHeaderParser.parse(wavPackFile(hybrid: true), container: .wv)
        #expect(hybrid?.codec == .wavpackHybrid)
        #expect(hybrid?.bitDepth == nil)
        #expect(AudioFormat.wavpackHybrid.isLossless == false)
    }

    @Test("CAF reads its desc chunk")
    func caf() {
        let alac = AudioStreamHeaderParser.parse(cafFile(formatID: "alac", flags: 3, bits: 0), container: .caf)
        #expect(alac == AudioStreamHeaderInfo(codec: .alac, sampleRate: 44_100, bitDepth: 24, channelCount: 2))

        let aac = AudioStreamHeaderParser.parse(cafFile(formatID: "aac ", flags: 0, bits: 0), container: .caf)
        #expect(aac?.codec == .aac)

        let pcm = AudioStreamHeaderParser.parse(cafFile(formatID: "lpcm", flags: 0, bits: 16), container: .caf)
        #expect(pcm?.codec == .pcm)
        #expect(pcm?.bitDepth == 16)
    }

    @Test("Matroska and WebM report the audio track's codec")
    func matroska() {
        let flac = AudioStreamHeaderParser.parse(matroskaFile(codecID: "A_FLAC", bitDepth: 24), container: .mka)
        #expect(flac == AudioStreamHeaderInfo(codec: .flac, sampleRate: 96_000, bitDepth: 24, channelCount: 2))

        let opus = AudioStreamHeaderParser.parse(matroskaFile(codecID: "A_OPUS", bitDepth: 16), container: .webm)
        #expect(opus?.codec == .opus)
        #expect(opus?.bitDepth == nil)

        #expect(AudioStreamHeaderParser.matroskaCodec("A_AAC/MPEG4/LC") == .aac)
        #expect(AudioStreamHeaderParser.matroskaCodec("A_PCM/INT/LIT") == .pcm)
        #expect(AudioStreamHeaderParser.matroskaCodec("A_MS/ACM") == nil)
    }

    @Test("Songs judge quality by the header codec")
    func songQuality() {
        let wma = song(.wma, codec: .wmaLossless, sampleRate: 44_100, bitDepth: 16)
        #expect(wma.audioQuality == .lossless)
        #expect(wma.detailedFormatName == "WMA Lossless")

        let hybrid = song(.wv, codec: .wavpackHybrid, sampleRate: 44_100, bitDepth: 16)
        #expect(hybrid.audioQuality == .standard)
        #expect(hybrid.detailedFormatName == "WavPack Hybrid")

        let mka = song(.mka, codec: .flac, sampleRate: 96_000, bitDepth: 24)
        #expect(mka.audioQuality == .hiRes)
        #expect(mka.detailedFormatName == "FLAC (Matroska)")

        let cafAAC = song(.caf, codec: .aac, sampleRate: 44_100)
        #expect(cafAAC.audioQuality == .standard)

        // 读过但认不出:CAF 仍按容器算无损,MKA 仍不声明。
        #expect(song(.caf, codec: .caf).audioQuality == .lossless)
        #expect(song(.mka, codec: .mka).audioQuality == .standard)
    }

    @Test("Codec-only values never come back as a file format")
    func codecOnlyValues() {
        #expect(AudioFormat.from(fileExtension: "pcm") == nil)
        #expect(AudioFormat.from(fileExtension: "wma-lossless") == nil)
        #expect(AudioFormat.allCases.filter(\.isCodecOnly) == [.pcm, .wmaLossless, .wavpackHybrid])
        #expect(ContainerAudioCodecPolicy.codec(named: "wmalossless") == .wmaLossless)
        #expect(ContainerAudioCodecPolicy.codec(named: "pcm_s24le") == .pcm)
        #expect(ContainerAudioCodecPolicy.codec(sampleEntry: "sowt") == .pcm)
    }

    // MARK: - FLAC

    @Test("A zero-padded 24-bit FLAC is 16 bits in fact")
    func paddedFLAC() {
        let frames = flacFrames(count: 10, wastedBits: 8)
        let result = FLACEffectiveBitDepthParser.effectiveBitDepth(frames: frames, declaredBitDepth: 24)
        #expect(result?.effectiveBitDepth == 16)
        #expect(result?.inspectedFrames == 10)
    }

    @Test("A genuine 24-bit FLAC stays 24 bits")
    func genuineFLAC() {
        var frames = flacFrames(count: 9, wastedBits: 8)
        frames.append(flacFrames(count: 1, wastedBits: 0, firstNumber: 9))
        #expect(FLACEffectiveBitDepthParser.effectiveBitDepth(frames: frames, declaredBitDepth: 24)?
            .effectiveBitDepth == 24)
    }

    @Test("Silence, mid/side frames and too few frames prove nothing")
    func insufficientEvidence() {
        // 常量子帧(静音)不报 wasted bits,不能拿来否定补零。
        var frames = flacFrames(count: 8, wastedBits: 8)
        frames.append(flacFrames(count: 3, wastedBits: 0, firstNumber: 8, subframeType: 0))
        #expect(FLACEffectiveBitDepthParser.effectiveBitDepth(frames: frames, declaredBitDepth: 24)?
            .effectiveBitDepth == 16)

        #expect(FLACEffectiveBitDepthParser.effectiveBitDepth(
            frames: flacFrames(count: 10, wastedBits: 8, channelAssignment: 10),
            declaredBitDepth: 24
        ) == nil)
        #expect(FLACEffectiveBitDepthParser.effectiveBitDepth(
            frames: flacFrames(count: 3, wastedBits: 8),
            declaredBitDepth: 24
        ) == nil)
    }

    @Test("A frame header with a bad CRC is not a frame")
    func badCRC() {
        var frames = flacFrames(count: 10, wastedBits: 8)
        // 在补零的帧之间混进一个帧头 CRC 不对、子帧报 0 wasted 的假同步。
        frames.append(contentsOf: [0xFF, 0xF8, 0xC9, 0x1C, 0x0A, 0x00, 0x14])
        #expect(FLACEffectiveBitDepthParser.effectiveBitDepth(frames: frames, declaredBitDepth: 24)?
            .effectiveBitDepth == 16)
    }

    @Test("A padded 24-bit FLAC is graded by its real bit depth")
    func paddedQuality() {
        var padded = song(.flac, codec: nil, sampleRate: 44_100, bitDepth: 24)
        padded.effectiveBitDepth = 16
        #expect(padded.qualityBitDepth == 16)
        #expect(padded.audioQuality == .lossless)
        #expect(padded.formattedBitDepth == "16 bit")

        // 采样率本身够 Hi-Res 时,补零不影响档位。
        var highRate = song(.flac, codec: nil, sampleRate: 96_000, bitDepth: 24)
        highRate.effectiveBitDepth = 16
        #expect(highRate.audioQuality == .hiRes)

        var genuine = song(.flac, codec: nil, sampleRate: 44_100, bitDepth: 24)
        genuine.effectiveBitDepth = 24
        #expect(genuine.qualityBitDepth == 24)
        #expect(genuine.audioQuality == .hiRes)
        #expect(genuine.formattedBitDepthDetail == "24 bit")
    }

    @Test("Only unchecked FLAC above 16 bits needs the frame check")
    func bitDepthInspection() {
        #expect(FLACEffectiveBitDepthParser.needsInspection(format: .flac, bitDepth: 24, effectiveBitDepth: nil))
        #expect(!FLACEffectiveBitDepthParser.needsInspection(format: .flac, bitDepth: 16, effectiveBitDepth: nil))
        #expect(!FLACEffectiveBitDepthParser.needsInspection(format: .flac, bitDepth: 24, effectiveBitDepth: 24))
        #expect(!FLACEffectiveBitDepthParser.needsInspection(format: .wav, bitDepth: 24, effectiveBitDepth: nil))
        // 查不出也记成标称位深,不再重读。
        #expect(FLACEffectiveBitDepthParser.inspectedBitDepth(nil, declared: 24) == 24)
        #expect(FLACEffectiveBitDepthParser.inspectedBitDepth(16, declared: 24) == 16)
        #expect(FLACEffectiveBitDepthParser.inspectedBitDepth(nil, declared: 16) == nil)
    }

    @Test("The audio offset follows the metadata block chain")
    func audioOffset() {
        var file = Data("fLaC".utf8)
        file.append(contentsOf: [0x00, 0x00, 0x00, 0x22]); file.append(Data(count: 34))
        file.append(contentsOf: [0x86, 0x00, 0x01, 0x00]); file.append(Data(count: 256))
        #expect(FLACEffectiveBitDepthParser.audioOffset(in: file) == .offset(4 + 38 + 260))

        // 图片块很大时只要有块头就能算出位置,不用读完整张图。
        var big = Data("fLaC".utf8)
        big.append(contentsOf: [0x00, 0x00, 0x00, 0x22]); big.append(Data(count: 34))
        big.append(contentsOf: [0x06, 0x10, 0x00, 0x00])
        #expect(FLACEffectiveBitDepthParser.audioOffset(in: big) == .needsHeader(at: 4 + 38 + 4 + 0x100000))

        var tagged = Data("ID3".utf8)
        tagged.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A])
        tagged.append(Data(count: 10))
        tagged.append(file)
        #expect(FLACEffectiveBitDepthParser.audioOffset(in: tagged) == .offset(20 + 4 + 38 + 260))

        #expect(FLACEffectiveBitDepthParser.audioOffset(in: Data("OggS0000".utf8)) == .invalid)
    }

    // MARK: - Fixtures

    private func song(
        _ format: AudioFormat,
        codec: AudioFormat?,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil
    ) -> Song {
        Song(
            id: "s", title: "s", fileFormat: format, filePath: "s.\(format.rawValue)", sourceID: "x",
            sampleRate: sampleRate, bitDepth: bitDepth, dateAdded: Date(timeIntervalSince1970: 0),
            audioCodec: codec
        )
    }

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private func le64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private func be32(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    private func be64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    private func asfFile(formatTag: Int, bits: Int) -> Data {
        let header: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]
        let streamProperties: [UInt8] = [0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
        let audioMedia: [UInt8] = [0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]
        // 前面先放一个无关对象,确认解析器按大小跳过。
        var other = [UInt8](repeating: 0x11, count: 16) + le64(40)
        other += [UInt8](repeating: 0, count: 16)
        var waveFormat = le16(formatTag) + le16(2) + le32(96_000) + le32(96_000 * 6) + le16(6) + le16(bits) + le16(0)
        waveFormat += [UInt8](repeating: 0, count: 0)
        var payload = audioMedia + [UInt8](repeating: 0, count: 16) + le64(0)
        payload += le32(waveFormat.count) + le32(0) + le16(1) + le32(0)
        payload += waveFormat
        let stream = streamProperties + le64(24 + payload.count) + payload
        let total = 30 + other.count + stream.count
        var file = header + le64(total) + le32(2) + [0x01, 0x02]
        file += other
        file += stream
        return Data(file)
    }

    private func wavPackFile(hybrid: Bool) -> Data {
        var flags: UInt32 = 0x2                     // 3 字节一个样本(24 bit)
        flags |= 13 << 23                            // 96 kHz
        if hybrid { flags |= 0x8 }
        var block: [UInt8] = Array("wvpk".utf8) + le32(200) + le16(0x410) + [0, 0]
        block += le32(100_000) + le32(0) + le32(4096) + le32(Int(flags)) + le32(0)
        block += [UInt8](repeating: 0, count: 200)
        return Data(block)
    }

    private func cafFile(formatID: String, flags: UInt32, bits: UInt32) -> Data {
        var file: [UInt8] = Array("caff".utf8) + [0x00, 0x01, 0x00, 0x00]
        file += Array("desc".utf8) + be64(32)
        file += be64(Double(44_100).bitPattern)
        file += be32(ContainerAudioCodecPolicy.fourCC(formatID))
        file += be32(flags) + be32(0) + be32(4096) + be32(2) + be32(bits)
        file += Array("data".utf8) + be64(UInt64.max) + [UInt8](repeating: 0, count: 64)
        return Data(file)
    }

    private func ebml(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        precondition(payload.count < 0x4000)
        let size: [UInt8] = payload.count < 0x7F
            ? [0x80 | UInt8(payload.count)]
            : [0x40 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        return id + size + payload
    }

    private func matroskaFile(codecID: String, bitDepth: Int) -> Data {
        let header = ebml([0x1A, 0x45, 0xDF, 0xA3], ebml([0x42, 0x82], Array("matroska".utf8)))
        let audio = ebml([0xE1],
            ebml([0xB5], be64(Double(96_000).bitPattern))
            + ebml([0x9F], [0x02])
            + ebml([0x62, 0x64], [UInt8(bitDepth)]))
        let videoTrack = ebml([0xAE], ebml([0x83], [0x01]) + ebml([0x86], Array("V_MJPEG".utf8)))
        let audioTrack = ebml([0xAE], ebml([0x83], [0x02]) + ebml([0x86], Array(codecID.utf8)) + audio)
        let tracks = ebml([0x16, 0x54, 0xAE, 0x6B], videoTrack + audioTrack)
        let info = ebml([0x15, 0x49, 0xA9, 0x66], [UInt8](repeating: 0x00, count: 20))
        // Segment 的大小写成「未知」(全 1),直播式的文件就是这样。
        let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            + info + tracks + [0x1F, 0x43, 0xB6, 0x75, 0x81, 0x00]
        return Data(header + segment)
    }

    private func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    /// 24 bit、44.1 kHz、4096 样本一帧的帧序列。每帧只写帧头和第一个子帧头,后面跟一段填充。
    private func flacFrames(
        count: Int,
        wastedBits: Int,
        firstNumber: Int = 0,
        channelAssignment: UInt8 = 1,
        subframeType: UInt8 = 10
    ) -> Data {
        var data = Data()
        for index in 0..<count {
            var header: [UInt8] = [0xFF, 0xF8, 0xC9, (channelAssignment << 4) | (6 << 1), UInt8(firstNumber + index)]
            header.append(crc8(header))
            var subframe: [UInt8] = [(subframeType << 1) | (wastedBits > 0 ? 1 : 0)]
            if wastedBits > 0 {
                // k-1 个 0 再跟一个 1。
                let zeros = wastedBits - 1
                var bits = [UInt8](repeating: 0, count: zeros) + [1]
                while bits.count % 8 != 0 { bits.append(0) }
                for start in stride(from: 0, to: bits.count, by: 8) {
                    subframe.append(bits[start..<(start + 8)].reduce(0) { ($0 << 1) | $1 })
                }
            }
            data.append(contentsOf: header + subframe)
            data.append(Data(repeating: 0x55, count: 300))
        }
        return data
    }
}
