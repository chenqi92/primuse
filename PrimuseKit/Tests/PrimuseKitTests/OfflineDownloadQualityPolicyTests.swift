import Foundation
import Testing
@testable import PrimuseKit

@Suite("Offline Download Quality Policy")
struct OfflineDownloadQualityPolicyTests {

    private func plan(
        _ preference: StreamQualityPreference,
        format: AudioFormat = .flac,
        isStreamDescriptor: Bool = false,
        isStandaloneMusicVideo: Bool = false,
        isCueTrack: Bool = false,
        bitRate: Int? = 1000,
        fileSize: Int64 = 30 * 1024 * 1024,
        duration: Double = 240
    ) -> OfflineCompactionPlan {
        OfflineDownloadQualityPolicy.plan(
            preference: preference,
            format: format,
            isStreamDescriptor: isStreamDescriptor,
            isStandaloneMusicVideo: isStandaloneMusicVideo,
            isCueTrack: isCueTrack,
            sourceBitRateKbps: bitRate,
            fileSize: fileSize,
            duration: duration
        )
    }

    // MARK: - 要不要转

    @Test("原始音质永远保留原文件")
    func originalKeepsEverything() {
        for format in [AudioFormat.flac, .wav, .ape, .dsf, .mp3, .m4a] {
            #expect(plan(.original, format: format) == .keepOriginal)
        }
    }

    @Test("无损格式按所选码率转换，与码率信息无关")
    func losslessAlwaysCompacts() {
        for format in [AudioFormat.flac, .alac, .wav, .aiff, .ape, .wv, .dsf, .dff, .tak] {
            #expect(plan(.kbps192, format: format, bitRate: nil, fileSize: 0, duration: 0)
                == .compact(bitRateKbps: 192))
        }
        #expect(plan(.kbps320) == .compact(bitRateKbps: 320))
        #expect(plan(.kbps128) == .compact(bitRateKbps: 128))
    }

    @Test("整轨 CUE 的无损映像同样转换")
    func losslessCueImageCompacts() {
        #expect(plan(.kbps192, format: .flac, isCueTrack: true, bitRate: nil) == .compact(bitRateKbps: 192))
    }

    @Test("有损原文件只在明显高于目标码率时才转")
    func lossyNeedsHeadroom() {
        #expect(plan(.kbps192, format: .mp3, bitRate: 320) == .compact(bitRateKbps: 192))
        #expect(plan(.kbps192, format: .mp3, bitRate: 240) == .compact(bitRateKbps: 192))
        #expect(plan(.kbps192, format: .mp3, bitRate: 239) == .keepOriginal)
        #expect(plan(.kbps192, format: .mp3, bitRate: 192) == .keepOriginal)
        #expect(plan(.kbps320, format: .mp3, bitRate: 320) == .keepOriginal)
        #expect(plan(.kbps128, format: .m4a, bitRate: 256) == .compact(bitRateKbps: 128))
    }

    @Test("ALAC 装在 m4a 里时按码率认出来")
    func alacInsideM4ACompacts() {
        #expect(plan(.kbps192, format: .m4a, bitRate: 900) == .compact(bitRateKbps: 192))
    }

    @Test("有损原文件缺码率时按大小与时长估算")
    func lossyEstimatesFromSize() {
        // 10 MB / 240 s ≈ 350 kbps
        #expect(plan(.kbps192, format: .mp3, bitRate: nil, fileSize: 10_500_000, duration: 240)
            == .compact(bitRateKbps: 192))
        // 4 MB / 240 s ≈ 133 kbps
        #expect(plan(.kbps192, format: .mp3, bitRate: nil, fileSize: 4_000_000, duration: 240)
            == .keepOriginal)
        #expect(plan(.kbps192, format: .mp3, bitRate: nil, fileSize: 0, duration: 240) == .keepOriginal)
        #expect(plan(.kbps192, format: .mp3, bitRate: nil, fileSize: 10_500_000, duration: 0) == .keepOriginal)
    }

    @Test("有损整轨 CUE 缺码率时不按分轨时长估算")
    func lossyCueWithoutBitRateKeepsOriginal() {
        // 整张专辑 100 MB 配一条 4 分钟的分轨, 估出来的码率是假的。
        #expect(plan(.kbps128, format: .mp3, isCueTrack: true, bitRate: nil,
                     fileSize: 100_000_000, duration: 240) == .keepOriginal)
        #expect(plan(.kbps128, format: .mp3, isCueTrack: true, bitRate: 320) == .compact(bitRateKbps: 128))
    }

    @Test("STRM、MV 与模块音乐保留原文件")
    func specialItemsKeepOriginal() {
        #expect(plan(.kbps128, isStreamDescriptor: true) == .keepOriginal)
        #expect(plan(.kbps128, isStandaloneMusicVideo: true) == .keepOriginal)
        #expect(plan(.kbps128, format: .m4v, bitRate: 5000) == .keepOriginal)
        #expect(plan(.kbps128, format: .mov, bitRate: 5000) == .keepOriginal)
        #expect(plan(.kbps128, format: .xm, bitRate: 5000) == .keepOriginal)
    }

    // MARK: - 路径

    @Test("副本路径与原文件路径互相换算")
    func compactPathRoundTrip() {
        let canonical = "source-1/0a1b2c.flac"
        let compact = OfflineDownloadQualityPolicy.compactRelativePath(forCanonical: canonical)
        #expect(compact == "source-1/0a1b2c.flac.compact.m4a")
        #expect(OfflineDownloadQualityPolicy.canonicalRelativePath(forCompact: compact) == canonical)
        #expect(OfflineDownloadQualityPolicy.isCompactPath(compact))
        #expect(!OfflineDownloadQualityPolicy.isCompactPath(canonical))
        #expect(OfflineDownloadQualityPolicy.canonicalRelativePath(forCompact: canonical) == nil)
        #expect(OfflineDownloadQualityPolicy.canonicalRelativePath(forCompact: ".compact.m4a") == nil)
    }

    // MARK: - 副本记录

    @Test("副本记录序列化往返")
    func recordRoundTrip() {
        let record = OfflineCompactArtifactRecord(originalByteCount: 31_457_280, bitRateKbps: 192)
        #expect(OfflineCompactArtifactRecord(serialized: record.serialized) == record)
        #expect(OfflineCompactArtifactRecord(serialized: record.serialized + "\n") == record)
        #expect(OfflineCompactArtifactRecord(serialized: "") == nil)
        #expect(OfflineCompactArtifactRecord(serialized: "2 100 192") == nil)
        #expect(OfflineCompactArtifactRecord(serialized: "1 0 192") == nil)
        #expect(OfflineCompactArtifactRecord(serialized: "1 100 0") == nil)
        #expect(OfflineCompactArtifactRecord(serialized: "1 abc 192") == nil)
    }

    @Test("副本只在原文件缓存同样会被认可时才算数")
    func recordMatchesLikeOriginalCacheCheck() {
        let record = OfflineCompactArtifactRecord(originalByteCount: 1_000_000, bitRateKbps: 192)
        #expect(record.matches(expectedOriginalByteCount: 0))
        #expect(record.matches(expectedOriginalByteCount: 1_000_000))
        #expect(record.matches(expectedOriginalByteCount: 1_050_000))
        #expect(record.matches(expectedOriginalByteCount: 900_000))
        // 服务器上换成了大得多的文件: 原文件缓存会被判不完整, 副本同样作废。
        #expect(!record.matches(expectedOriginalByteCount: 1_100_000))
    }

    // MARK: - 编码参数

    @Test("采样率落到 AAC 支持的档位")
    func encoderSampleRates() {
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 44_100) == 44_100)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 48_000) == 48_000)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 32_000) == 32_000)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 88_200) == 44_100)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 176_400) == 44_100)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 96_000) == 48_000)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 192_000) == 48_000)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 384_000) == 48_000)
        // DSD64 / DSD128
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 2_822_400) == 44_100)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 5_644_800) == 44_100)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 37_800) == 44_100)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: 0) == 44_100)
        #expect(OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: .nan) == 44_100)
    }

    @Test("多声道保留原文件")
    func encoderChannels() {
        #expect(OfflineDownloadQualityPolicy.encoderChannelCount(sourceChannelCount: 1) == 1)
        #expect(OfflineDownloadQualityPolicy.encoderChannelCount(sourceChannelCount: 2) == 2)
        #expect(OfflineDownloadQualityPolicy.encoderChannelCount(sourceChannelCount: 6) == nil)
        #expect(OfflineDownloadQualityPolicy.encoderChannelCount(sourceChannelCount: 0) == nil)
    }

    @Test("码率按编码器给的档位取不超过请求的最大一档")
    func encoderBitRates() {
        let stereo = [64_000, 96_000, 128_000, 160_000, 192_000, 256_000, 320_000]
        #expect(OfflineDownloadQualityPolicy.encoderBitRate(targetKbps: 192, channelCount: 2, applicableBitRates: stereo) == 192_000)
        #expect(OfflineDownloadQualityPolicy.encoderBitRate(targetKbps: 320, channelCount: 2, applicableBitRates: [64_000, 128_000, 256_000]) == 256_000)
        #expect(OfflineDownloadQualityPolicy.encoderBitRate(targetKbps: 128, channelCount: 2, applicableBitRates: [160_000, 192_000]) == 160_000)
        #expect(OfflineDownloadQualityPolicy.encoderBitRate(targetKbps: 192, channelCount: 2, applicableBitRates: []) == 192_000)
        // 单声道减半
        #expect(OfflineDownloadQualityPolicy.encoderBitRate(targetKbps: 192, channelCount: 1, applicableBitRates: []) == 96_000)
        #expect(OfflineDownloadQualityPolicy.encoderBitRate(targetKbps: 128, channelCount: 1, applicableBitRates: stereo) == 64_000)
    }

    // MARK: - 校验

    @Test("时长差超过 1 秒或 1% 视为不完整")
    func durationCompleteness() {
        #expect(OfflineDownloadQualityPolicy.durationIsComplete(expectedDuration: 240, actualDuration: 240.05))
        #expect(OfflineDownloadQualityPolicy.durationIsComplete(expectedDuration: 240, actualDuration: 239.2))
        #expect(!OfflineDownloadQualityPolicy.durationIsComplete(expectedDuration: 240, actualDuration: 230))
        // 一张 60 分钟的 CUE 映像允许 36 秒以内的出入
        #expect(OfflineDownloadQualityPolicy.durationIsComplete(expectedDuration: 3600, actualDuration: 3580))
        #expect(!OfflineDownloadQualityPolicy.durationIsComplete(expectedDuration: 3600, actualDuration: 3500))
        #expect(!OfflineDownloadQualityPolicy.durationIsComplete(expectedDuration: 0, actualDuration: 10))
        #expect(!OfflineDownloadQualityPolicy.durationIsComplete(expectedDuration: 240, actualDuration: 0))
    }

    @Test("副本没有明显变小就保留原文件")
    func sizeReduction() {
        #expect(OfflineDownloadQualityPolicy.compactIsWorthKeeping(originalByteCount: 30_000_000, compactByteCount: 6_000_000))
        #expect(!OfflineDownloadQualityPolicy.compactIsWorthKeeping(originalByteCount: 10_000_000, compactByteCount: 9_500_000))
        #expect(!OfflineDownloadQualityPolicy.compactIsWorthKeeping(originalByteCount: 0, compactByteCount: 100))
        #expect(!OfflineDownloadQualityPolicy.compactIsWorthKeeping(originalByteCount: 100, compactByteCount: 0))
    }
}
