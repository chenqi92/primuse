import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata format inspection policy")
struct MetadataInspectionPolicyTests {
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
}
