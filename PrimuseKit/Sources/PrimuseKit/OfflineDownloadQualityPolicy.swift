import Foundation

/// 一份离线副本该怎么存。
public enum OfflineCompactionPlan: Sendable, Equatable {
    /// 保留下载下来的原文件。
    case keepOriginal
    /// 在本机转成这个码率的 AAC，转好后只留转换后的副本。
    case compact(bitRateKbps: Int)
}

/// 精简副本是从哪份原文件转出来的。写在副本自己的扩展属性里，随文件一起
/// 移动、隔离、删除，不需要另一本账去和磁盘对齐。
public struct OfflineCompactArtifactRecord: Sendable, Equatable {
    /// 转换时原文件的字节数。
    public let originalByteCount: Int64
    public let bitRateKbps: Int

    public init(originalByteCount: Int64, bitRateKbps: Int) {
        self.originalByteCount = originalByteCount
        self.bitRateKbps = bitRateKbps
    }

    public var serialized: String {
        "1 \(originalByteCount) \(bitRateKbps)"
    }

    public init?(serialized: String) {
        let fields = serialized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        guard fields.count == 3,
              fields[0] == "1",
              let originalByteCount = Int64(fields[1]),
              originalByteCount > 0,
              let bitRateKbps = Int(fields[2]),
              bitRateKbps > 0 else { return nil }
        self.originalByteCount = originalByteCount
        self.bitRateKbps = bitRateKbps
    }

    /// 副本能不能代表资料库里这首歌现在的内容。
    ///
    /// 口径与原文件缓存的完整性校验完全一致(实际大小不低于期望的 95%):
    /// 那条规则会认的原文件, 由它转出的副本也认; 服务器上的文件换了、原文件
    /// 缓存会被判不完整的时候, 副本同样作废。期望大小未知时不校验。
    public func matches(expectedOriginalByteCount expected: Int64) -> Bool {
        guard expected > 0 else { return true }
        return originalByteCount >= Int64(Double(expected) * 0.95)
    }
}

/// 「离线缓存音质」的全部判定。纯函数，只依赖 Foundation。
///
/// 离线下载仍然先完整下载原文件(网盘、WebDAV、NAS 都没有服务端转码),
/// 下载完在本机解码、编码成 AAC, 校验通过后删掉原文件, 只留转换后的副本。
/// 判定故意保守: 拿不准就保留原文件 —— 多占一点空间, 也不要把用户的
/// 文件换成一份放不完整的副本。
public enum OfflineDownloadQualityPolicy {
    /// 精简副本与原文件缓存放在同一目录, 文件名是原文件缓存名加这个后缀,
    /// 因此属于同一组缓存文件, 一起加锁、清理、迁移。
    public static let compactFileSuffix = ".compact.m4a"

    /// 副本扩展属性的名字, 内容见 `OfflineCompactArtifactRecord.serialized`。
    public static let compactRecordAttributeName = "com.welape.primuse.offline-compact"

    /// 有损原文件至少要比目标码率高出这么多才转: 再次有损编码会损失音质,
    /// 省不下多少空间时不值得。
    public static let minimumLossyBitRateRatio = 1.25

    /// 转出来的副本必须小于原文件的这个比例才保留, 否则留原文件。
    public static let maximumCompactSizeRatio = 0.9

    // MARK: - 路径

    public static func compactRelativePath(forCanonical path: String) -> String {
        path + compactFileSuffix
    }

    /// 精简副本的路径换回它所属的原文件缓存路径; 不是副本时返回 nil。
    public static func canonicalRelativePath(forCompact path: String) -> String? {
        guard path.hasSuffix(compactFileSuffix),
              path.count > compactFileSuffix.count else { return nil }
        return String(path.dropLast(compactFileSuffix.count))
    }

    public static func isCompactPath(_ path: String) -> Bool {
        canonicalRelativePath(forCompact: path) != nil
    }

    // MARK: - 要不要转

    /// - Parameters:
    ///   - sourceBitRateKbps: 资料库里的码率(kbps), 可能缺失。
    ///   - fileSize: 原文件字节数; 码率缺失时用它和时长估算。
    ///   - duration: 时长(秒)。整轨 CUE 的分轨传分轨时长 —— 它和整张专辑
    ///     的文件大小对不上, 所以那种情况只认资料库里的码率。
    public static func plan(
        preference: StreamQualityPreference,
        format: AudioFormat,
        isStreamDescriptor: Bool,
        isStandaloneMusicVideo: Bool,
        isCueTrack: Bool,
        sourceBitRateKbps: Int?,
        fileSize: Int64,
        duration: Double
    ) -> OfflineCompactionPlan {
        guard let target = preference.targetBitRateKbps, target > 0 else {
            return .keepOriginal
        }
        // STRM 描述符下载下来的是外部地址的内容, 格式无从得知; MV 是视频;
        // 模块音乐本身只有几十 KB。
        guard !isStreamDescriptor,
              !isStandaloneMusicVideo,
              !format.isTrackerModule,
              format != .m4v,
              format != .mov else {
            return .keepOriginal
        }
        if format.isLossless {
            return .compact(bitRateKbps: target)
        }
        let measured: Int?
        if let sourceBitRateKbps, sourceBitRateKbps > 0 {
            measured = sourceBitRateKbps
        } else if isCueTrack {
            measured = nil
        } else {
            measured = AdaptiveStreamQualityPolicy.effectiveSourceBitRateKbps(
                sourceBitRateKbps: nil,
                fileSize: fileSize,
                duration: duration
            )
        }
        guard let measured,
              Double(measured) >= Double(target) * minimumLossyBitRateRatio else {
            return .keepOriginal
        }
        return .compact(bitRateKbps: target)
    }

    // MARK: - 编码参数

    /// AAC 编码器接受的采样率。
    public static let encoderSampleRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000,
    ]

    /// 高于 48 kHz 的源(含 DSD)按所属家族降到 44.1 / 48 kHz,
    /// 其余不在列表里的采样率升到 44.1 kHz。
    public static func encoderSampleRate(sourceSampleRate: Double) -> Double {
        guard sourceSampleRate.isFinite, sourceSampleRate > 0 else { return 44_100 }
        if let exact = encoderSampleRates.first(where: { abs($0 - sourceSampleRate) < 0.5 }) {
            return exact
        }
        if sourceSampleRate > 48_000 {
            let remainder = sourceSampleRate.truncatingRemainder(dividingBy: 44_100)
            if remainder < 0.5 || 44_100 - remainder < 0.5 {
                return 44_100
            }
            return 48_000
        }
        return 44_100
    }

    /// 多声道源保留原文件 —— 缩混成立体声会改变它的听感, 不该悄悄发生。
    public static func encoderChannelCount(sourceChannelCount: Int) -> Int? {
        switch sourceChannelCount {
        case 1, 2:
            return sourceChannelCount
        default:
            return nil
        }
    }

    /// 实际交给编码器的码率(bps)。
    ///
    /// 目标码率按立体声给; 单声道减半。`applicableBitRates` 是编码器对这组
    /// 采样率 / 声道数报出来的可用码率, 取不超过请求值的最大一档, 都超过时
    /// 取最小一档; 拿不到列表时原样返回请求值。
    public static func encoderBitRate(
        targetKbps: Int,
        channelCount: Int,
        applicableBitRates: [Int]
    ) -> Int {
        let requested = channelCount <= 1
            ? max(32_000, targetKbps * 1_000 / 2)
            : targetKbps * 1_000
        let available = applicableBitRates.filter { $0 > 0 }.sorted()
        guard !available.isEmpty else { return requested }
        if let fitting = available.last(where: { $0 <= requested }) {
            return fitting
        }
        return available[0]
    }

    // MARK: - 校验

    /// 解码 / 编码出来的时长与原文件差不多才算完整。解码器碰到坏文件可能
    /// 提前结束而不报错, 那样的副本绝不能顶替原文件。
    public static func durationIsComplete(
        expectedDuration: Double,
        actualDuration: Double
    ) -> Bool {
        guard expectedDuration.isFinite, expectedDuration > 0,
              actualDuration.isFinite, actualDuration > 0 else { return false }
        let tolerance = max(1.0, expectedDuration * 0.01)
        return abs(actualDuration - expectedDuration) <= tolerance
    }

    public static func compactIsWorthKeeping(
        originalByteCount: Int64,
        compactByteCount: Int64
    ) -> Bool {
        guard originalByteCount > 0, compactByteCount > 0 else { return false }
        return Double(compactByteCount) < Double(originalByteCount) * maximumCompactSizeRatio
    }
}
