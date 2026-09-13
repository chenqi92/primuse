import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata format inspection policy")
struct MetadataInspectionPolicyTests {
    @Test("WAV DTS probes preserve the bounded byte search")
    func boundedWaveSignatureSearch() {
        let limit = 64 * 1024
        var wave = Data(repeating: 0x55, count: limit + 4)
        wave.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        wave.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        let started = ContinuousClock.now
        for _ in 0..<12 {
            #expect(AudioFileSignaturePolicy.inspect(wave) == .riffWave)
        }
        print("WAV signature benchmark: 12 prefixes elapsed=\(ContinuousClock.now - started)")
        for pattern: [UInt8] in [[0x7F, 0xFE, 0x80, 0x01], [0xFE, 0x7F, 0x01, 0x80],
                                [0x1F, 0xFF, 0xE8, 0x00], [0xFF, 0x1F, 0x00, 0xE8]] {
            for offset in [13, limit - 4, limit - 3, limit] {
                var candidate = wave
                candidate.replaceSubrange(offset..<(offset + 4), with: pattern)
                #expect(AudioFileSignaturePolicy.inspect(candidate)
                        == (offset <= limit - 4 ? .dtsInWave : .riffWave))
            }
        }
    }

    @Test("Every declared import format has an explicit inspection route")
    func allDeclaredFormatsHaveInspectionRoute() {
        #expect(PrimuseConstants.supportedAudioExtensions.count == 44)
        for fileExtension in PrimuseConstants.supportedAudioExtensions {
            #expect(AudioFormat.from(fileExtension: fileExtension) != nil)
            let parserExtension = RemoteMetadataInspectionPolicy.parserFileExtension(
                declaredFileExtension: fileExtension,
                signature: .unknown
            )
            #expect(!parserExtension.isEmpty)
            #expect(RemoteMetadataInspectionPolicy.tailStrategy(
                fileExtension: parserExtension,
                isExplicitReread: true
            ) != .none)
        }
    }

    @Test("Automatic reads use format-defined tails and explicit reads cover raw streams")
    func tailStrategiesAreBoundedAndExplicit() {
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "m4a",
            isExplicitReread: false
        ) == .isoBaseMedia)
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "mp3",
            isExplicitReread: false
        ) == .mp3ID3)
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "tak",
            isExplicitReread: false
        ) == .apeV2)
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "wav",
            isExplicitReread: false
        ) == .containerID3)
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "dts",
            isExplicitReread: false
        ) == .none)
        #expect(RemoteMetadataInspectionPolicy.tailStrategy(
            fileExtension: "dts",
            isExplicitReread: true
        ) == .genericEOF)
    }

    @Test("Byte signatures override misleading extensions conservatively")
    func signaturesSelectParser() {
        let dts = Data([0x7F, 0xFE, 0x80, 0x01, 0, 0, 0, 0])
        #expect(AudioFileSignaturePolicy.inspect(dts) == .dts)
        #expect(RemoteMetadataInspectionPolicy.parserFileExtension(
            declaredFileExtension: "mp3",
            signature: .dts
        ) == "dts")

        let leadingID3 = Data([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 0]) + dts
        #expect(AudioFileSignaturePolicy.inspect(leadingID3) == .dts)

        var wave = Data("RIFF".utf8)
        wave.append(Data(repeating: 0, count: 4))
        wave.append(Data("WAVEfmt ".utf8))
        wave.append(dts)
        #expect(AudioFileSignaturePolicy.inspect(wave) == .dtsInWave)

        #expect(AudioFileSignaturePolicy.inspect(Data("fLaC".utf8)) == .flac)
        #expect(AudioFileSignaturePolicy.inspect(
            Data([0, 0, 0, 24]) + Data("ftypM4A ".utf8)
        ) == .isoBaseMedia)
        var mpegFrames = Data(repeating: 0, count: 834)
        mpegFrames.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        mpegFrames.replaceSubrange(417..<421, with: [0xFF, 0xFB, 0x90, 0x64])
        #expect(AudioFileSignaturePolicy.inspect(mpegFrames) == .mpegAudio)
        #expect(AudioFileSignaturePolicy.inspect(
            Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0xA5, count: 1024)
        ) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(Data(repeating: 0, count: 4 * 1024)) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(Data(repeating: 0xA5, count: 128)) == .unknown)
    }

    @Test("Legacy and elementary-stream signatures map to their metadata families")
    func legacyAndElementarySignatures() {
        #expect(AudioFileSignaturePolicy.inspect(Data("ADIF".utf8)) == .adifAAC)
        #expect(AudioFileSignaturePolicy.inspect(Data(".snd".utf8)) == .au)
        #expect(AudioFileSignaturePolicy.inspect(Data("caff".utf8)) == .caf)
        #expect(AudioFileSignaturePolicy.inspect(Data("MPCK".utf8)) == .musepack)
        #expect(AudioFileSignaturePolicy.inspect(Data("ajkg".utf8)) == .shorten)
        let omaHeader = Data([0x45, 0x41, 0x33, 0, 0, 96])
        #expect(AudioFileSignaturePolicy.inspect(omaHeader) == .atrac)
        let ea3MetadataHeader = Data([0x65, 0x61, 0x33, 3, 0, 0, 0, 0, 0, 0])
        #expect(AudioFileSignaturePolicy.inspect(ea3MetadataHeader + omaHeader) == .atrac)
        #expect(AudioFileSignaturePolicy.inspect(Data([0xEA, 0x03, 0, 0])) == .unknown)
        var trueHD = Data(repeating: 0, count: 32)
        trueHD.replaceSubrange(0..<2, with: [0, 16])
        trueHD.replaceSubrange(4..<8, with: [0xF8, 0x72, 0x6F, 0xBA])
        #expect(AudioFileSignaturePolicy.inspect(trueHD) == .trueHD)
        var mlp = trueHD
        mlp[7] = 0xBB
        #expect(AudioFileSignaturePolicy.inspect(mlp) == .mlp)
        #expect(AudioFileSignaturePolicy.inspect(
            Data([0xF8, 0x72, 0x6F, 0xBA])
        ) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(
            Data([0x0B, 0x77, 0, 0, 0, 0x58])
        ) == .eac3)
        #expect(AudioFileSignaturePolicy.inspect(
            Data([0x0B, 0x77, 0, 0, 0, 0x40])
        ) == .ac3)
    }

    @Test("Reliable identity survives filename fallback and embedded tags stay authoritative")
    func identityPriorityAndReversibility() {
        let reliable = MetadataIdentityFallbackPolicy.resolve(
            existing: "服务端可靠标题",
            embedded: nil,
            filenameInference: "文件名标题",
            rawFileStem: "歌手 - 文件名标题",
            isCueTrack: false,
            userEdited: false
        )
        #expect(reliable.value == "服务端可靠标题")
        #expect(reliable.source == .existing)

        let inferred = MetadataIdentityFallbackPolicy.resolve(
            existing: "歌手 - 文件名标题",
            embedded: nil,
            filenameInference: "文件名标题",
            rawFileStem: "歌手 - 文件名标题",
            isCueTrack: false,
            userEdited: false
        )
        #expect(inferred.value == "文件名标题")
        #expect(inferred.source == .filenameInference)

        let embedded = MetadataIdentityFallbackPolicy.resolve(
            existing: inferred.value,
            embedded: "内嵌标题",
            filenameInference: "文件名标题",
            rawFileStem: "歌手 - 文件名标题",
            isCueTrack: false,
            userEdited: false
        )
        #expect(embedded.value == "内嵌标题")
        #expect(embedded.source == .embedded)

        let cue = MetadataIdentityFallbackPolicy.resolve(
            existing: "CUE 分轨标题",
            embedded: "整轨镜像标题",
            filenameInference: "文件名标题",
            rawFileStem: "整轨镜像",
            isCueTrack: true,
            userEdited: false
        )
        #expect(cue.value == "CUE 分轨标题")
        #expect(cue.source == .cueSheet)
    }

    @Test("Completion semantics keep descriptive tags separate from technical properties")
    func completionKindsRemainDisjoint() {
        #expect(Set(MetadataReadCompletionKind.allCases) == Set([
            .embeddedTags,
            .sidecarMetadata,
            .filenameInference,
            .technicalProperties,
            .verifiedNoMetadata,
        ]))
    }

    @Test("Unknown readable bytes cannot unlock filename inference")
    func filenameInferenceRequiresAudioEvidence() {
        #expect(!MetadataReadEvidencePolicy.hasVerifiedAudioFile(
            signature: .unknown,
            hasTechnicalProperties: false
        ))
        #expect(MetadataReadEvidencePolicy.hasVerifiedAudioFile(
            signature: .dts,
            hasTechnicalProperties: false
        ))
        #expect(MetadataReadEvidencePolicy.hasVerifiedAudioFile(
            signature: .unknown,
            hasTechnicalProperties: true
        ))
    }

    @Test("Complete reads reject unknown media bytes independently of sidecars")
    func completeReadRequiresAudioEvidence() {
        #expect(MetadataReadEvidencePolicy.completeReadIsUnrecognizedAudio(
            providedByteCount: 3_276_513,
            expectedFileByteCount: 3_276_513,
            hasCompleteFileAccess: false,
            signature: .unknown,
            hasTechnicalProperties: false
        ))
        #expect(!MetadataReadEvidencePolicy.completeReadIsUnrecognizedAudio(
            providedByteCount: 256 * 1024,
            expectedFileByteCount: 3_276_513,
            hasCompleteFileAccess: false,
            signature: .unknown,
            hasTechnicalProperties: false
        ))
        #expect(MetadataReadEvidencePolicy.completeReadIsUnrecognizedAudio(
            providedByteCount: 0,
            expectedFileByteCount: 0,
            hasCompleteFileAccess: true,
            signature: .unknown,
            hasTechnicalProperties: false
        ))
        #expect(!MetadataReadEvidencePolicy.completeReadIsUnrecognizedAudio(
            providedByteCount: 3_276_513,
            expectedFileByteCount: 3_276_513,
            hasCompleteFileAccess: false,
            signature: .mpegAudio,
            hasTechnicalProperties: false
        ))
        #expect(!MetadataReadEvidencePolicy.completeReadIsUnrecognizedAudio(
            providedByteCount: 3_276_513,
            expectedFileByteCount: 3_276_513,
            hasCompleteFileAccess: false,
            signature: .unknown,
            hasTechnicalProperties: true
        ))
    }

    // MARK: - MPEG 帧探测

    /// 按规范合成真实 MPEG 帧头, 用来锁住"扩展名是 .mp3 却被判成不是音频"的回归。
    private struct MPEGSpec {
        var versionBits: Int   // 3=MPEG1, 2=MPEG2, 0=MPEG2.5
        var layerBits: Int     // 3=Layer I, 2=Layer II, 1=Layer III
        var bitRateIndex: Int
        var sampleRateIndex: Int
        var padding: Int = 0
    }

    private func mpegFrame(_ spec: MPEGSpec) -> Data {
        let mpeg1LayerI = [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
        let mpeg1LayerII = [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
        let mpeg1LayerIII = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let mpeg2LayerI = [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
        let mpeg2Other = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let isMPEG1 = spec.versionBits == 3
        let table: [Int] = switch (isMPEG1, spec.layerBits) {
        case (true, 3): mpeg1LayerI
        case (true, 2): mpeg1LayerII
        case (true, 1): mpeg1LayerIII
        case (false, 3): mpeg2LayerI
        default: mpeg2Other
        }
        let base = [44_100, 48_000, 32_000][spec.sampleRateIndex]
        let sampleRate = switch spec.versionBits {
        case 3: base
        case 2: base / 2
        default: base / 4
        }
        let bitsPerSecond = table[spec.bitRateIndex - 1] * 1_000
        let byteCount: Int
        if spec.layerBits == 3 {
            byteCount = (12 * bitsPerSecond / sampleRate + spec.padding) * 4
        } else if isMPEG1 || spec.layerBits == 2 {
            byteCount = 144 * bitsPerSecond / sampleRate + spec.padding
        } else {
            byteCount = 72 * bitsPerSecond / sampleRate + spec.padding
        }
        var frame = Data([
            0xFF,
            UInt8(0xE0 | (spec.versionBits << 3) | (spec.layerBits << 1) | 1),
            UInt8((spec.bitRateIndex << 4) | (spec.sampleRateIndex << 2) | (spec.padding << 1)),
            0x00
        ])
        frame.append(Data(repeating: 0x5A, count: max(0, byteCount - 4)))
        return frame
    }

    private func mpegStream(_ spec: MPEGSpec, frames: Int = 6) -> Data {
        var data = Data()
        for _ in 0..<frames { data.append(mpegFrame(spec)) }
        return data
    }

    private func id3v2(payloadByteCount: Int) -> Data {
        var data = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        data.append(contentsOf: [
            UInt8((payloadByteCount >> 21) & 0x7F), UInt8((payloadByteCount >> 14) & 0x7F),
            UInt8((payloadByteCount >> 7) & 0x7F), UInt8(payloadByteCount & 0x7F)
        ])
        data.append(Data(repeating: 0x00, count: payloadByteCount))
        return data
    }

    /// Layer I 与 Layer II 同样是 MPEG 音频。只认 Layer III 会让用 .mp3 扩展名
    /// 保存的 Layer II 文件被判成"内容不是可识别的音频数据"。
    @Test("Every MPEG version and layer is recognised as audio")
    func mpegVersionsAndLayersAreAudio() {
        let specs: [MPEGSpec] = [
            .init(versionBits: 3, layerBits: 1, bitRateIndex: 9, sampleRateIndex: 0),
            .init(versionBits: 3, layerBits: 1, bitRateIndex: 14, sampleRateIndex: 1),
            .init(versionBits: 3, layerBits: 2, bitRateIndex: 8, sampleRateIndex: 0),
            .init(versionBits: 3, layerBits: 3, bitRateIndex: 6, sampleRateIndex: 0),
            .init(versionBits: 2, layerBits: 1, bitRateIndex: 8, sampleRateIndex: 0),
            .init(versionBits: 2, layerBits: 2, bitRateIndex: 8, sampleRateIndex: 0),
            .init(versionBits: 2, layerBits: 3, bitRateIndex: 4, sampleRateIndex: 0),
            .init(versionBits: 0, layerBits: 1, bitRateIndex: 4, sampleRateIndex: 0),
            .init(versionBits: 0, layerBits: 2, bitRateIndex: 4, sampleRateIndex: 0),
            .init(versionBits: 3, layerBits: 1, bitRateIndex: 9, sampleRateIndex: 0, padding: 1)
        ]
        for spec in specs {
            #expect(AudioFileSignaturePolicy.inspect(mpegStream(spec)) == .mpegAudio)
        }
        // VBR: 相邻帧比特率不同, 但版本/层级/采样率一致。
        var vbr = Data()
        for index in [9, 12, 7, 14] {
            vbr.append(mpegFrame(.init(versionBits: 3, layerBits: 1, bitRateIndex: index, sampleRateIndex: 0)))
        }
        #expect(AudioFileSignaturePolicy.inspect(vbr) == .mpegAudio)
    }

    /// 第一帧不一定紧贴 ID3 标签: 转码/改标签的工具常在中间留下大段填充。
    /// 原来 4 KiB 的搜索窗口会把这类正常 .mp3 判成不是音频。
    @Test("A first frame beyond the old 4 KiB window is still found")
    func mpegFrameFoundAfterLeadingPadding() {
        let spec = MPEGSpec(versionBits: 3, layerBits: 1, bitRateIndex: 9, sampleRateIndex: 0)
        for junkByteCount in [16, 4_096, 8_192, 32_768, 64 * 1024] {
            let data = Data(repeating: 0x00, count: junkByteCount) + mpegStream(spec)
            #expect(AudioFileSignaturePolicy.inspect(data) == .mpegAudio)
        }
        for paddingByteCount in [0, 3_000, 10_000, 40_000] {
            let data = id3v2(payloadByteCount: 1_024)
                + Data(repeating: 0x00, count: paddingByteCount)
                + mpegStream(spec)
            #expect(AudioFileSignaturePolicy.inspect(data) == .mpegAudio)
        }
        for tagByteCount in [64, 1_024, 8_192, 200_000] {
            #expect(AudioFileSignaturePolicy.inspect(
                id3v2(payloadByteCount: tagByteCount) + mpegStream(spec)) == .mpegAudio)
        }
    }

    /// 放宽搜索窗口不能把非音频认成音频。
    @Test("Widening the frame search keeps non-audio unrecognised")
    func widenedSearchStillRejectsNonAudio() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextByte() -> UInt8 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        for trial in 0..<20 {
            state = 0x9E37_79B9_7F4A_7C15 &+ UInt64(trial) &* 0x0123_4567
            let noise = Data((0..<131_072).map { _ in nextByte() })
            #expect(AudioFileSignaturePolicy.inspect(noise) == .unknown)
        }
        #expect(AudioFileSignaturePolicy.inspect(Data(repeating: 0xFF, count: 131_072)) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(
            Data((0..<131_072).map { UInt8($0 % 2 == 0 ? 0xFF : 0xFB) })) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(
            Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x11, count: 131_072)) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(
            Data(#"{"errno":-6,"request_id":1}"#.utf8)
                + Data(repeating: 0x20, count: 131_072)) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(
            Data("<!DOCTYPE html><html><head><title>404</title>".utf8)
                + Data(repeating: 0x20, count: 8_192)) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(Data(repeating: 0, count: 131_072)) == .unknown)
        #expect(AudioFileSignaturePolicy.inspect(Data()) == .unknown)
    }

}
