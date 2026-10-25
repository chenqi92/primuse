import Foundation

/// 封面与歌词那份持久化数据的空间上限(#346)。只约束封面:每天的文件整理超过上限时先删最久没动过的封面
/// (本机源的内嵌封面不删),歌词很小不算在内。0 是不限。和音频缓存的上限一样在存储管理里选。
public enum ArtworkStoreLimitPolicy {
    public static let unlimitedBytes: Int64 = 0
    public static let bytesPerMiB: Int64 = 1_048_576
    public static let bytesPerGiB: Int64 = 1_073_741_824
    public static let defaultBytes: Int64 = 500 * bytesPerMiB
    public static let selectableBytes: [Int64] = [
        unlimitedBytes,
        500 * bytesPerMiB,
        bytesPerGiB,
        2 * bytesPerGiB,
        5 * bytesPerGiB,
        10 * bytesPerGiB,
    ]
    /// 本机封面太少、算不出像样的平均大小时,按一张这么大估。
    public static let fallbackAverageBytes: Int64 = 150 * 1024
    /// 平均大小至少要这么多张封面才算数。
    public static let minimumSampleCount = 20
    /// 建议的上限比预计大小多留的余量。
    public static let suggestionHeadroom = 1.2

    /// 设置里存的值;没存过是默认,负数当不限。
    public static func resolved(_ stored: Int64?) -> Int64 {
        guard let stored else { return defaultBytes }
        return max(unlimitedBytes, stored)
    }

    /// 选项里一直带着当前值(别的版本或别处设下的非标准值),直到用户换成标准的一档。
    public static func options(including currentBytes: Int64) -> [Int64] {
        guard currentBytes > unlimitedBytes, !selectableBytes.contains(currentBytes) else {
            return selectableBytes
        }
        return [unlimitedBytes] + (Array(selectableBytes.dropFirst()) + [currentBytes]).sorted()
    }

    /// 一次性下载完封面大概会占多大:已经存着的,加上要下载的张数乘本机封面的平均大小。
    public static func projectedBytes(existingBytes: Int64, existingCount: Int, additionalCount: Int) -> Int64 {
        let existing = max(0, existingBytes)
        let average = existingCount >= minimumSampleCount
            ? max(1, existing / Int64(existingCount))
            : fallbackAverageBytes
        return existing + Int64(max(0, additionalCount)) * average
    }

    /// 预计会超过上限时建议调到的一档:装得下预计大小再留两成余量的最小一档,都装不下就不限。
    /// 不限、或预计装得下时返回 nil。
    public static func suggestedLimit(projectedBytes: Int64, currentLimit: Int64) -> Int64? {
        guard currentLimit > unlimitedBytes, projectedBytes > currentLimit else { return nil }
        let wanted = Int64((Double(projectedBytes) * suggestionHeadroom).rounded(.up))
        return selectableBytes.first { $0 > unlimitedBytes && $0 >= wanted } ?? unlimitedBytes
    }
}
