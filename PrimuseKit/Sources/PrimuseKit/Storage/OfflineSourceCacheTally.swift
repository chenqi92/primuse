import Foundation

/// 整源缓存一轮下来的计数(#313)。分子分母用同一把尺子:每首都按资料库记的文件大小算,下完的、失败的
/// 都算处理过(否则一首下不了的会让进度条永远到不了头),正在下的那几首按各自的进度折算。开始前就缓存过的歌
/// 也在这一轮里,一开始就会很快算成下完,和「N/M 首」对得上。实际文件比记的小(转成了精简副本)也不影响进度。
public struct OfflineSourceCacheTally: Equatable, Sendable {
    public private(set) var totalCount: Int
    /// 记得到大小的那些歌加起来多大。
    public private(set) var knownBytes: Int64
    /// 资料库里没记大小的歌有几首。
    public private(set) var unknownCount: Int
    public private(set) var completedCount = 0
    public private(set) var failedCount = 0
    public private(set) var completedKnownBytes: Int64 = 0
    public private(set) var failedKnownBytes: Int64 = 0
    /// 用户在这一轮里点了停止。
    public private(set) var wasCancelled = false

    /// - Parameter sizes: 这一轮每首歌在资料库里记的文件大小,没记的给 0。
    public init(sizes: [Int64]) {
        totalCount = sizes.count
        knownBytes = sizes.reduce(0) { $0 + max($1, 0) }
        unknownCount = sizes.filter { $0 <= 0 }.count
    }

    public var handledCount: Int { completedCount + failedCount }

    public mutating func record(size: Int64, completed: Bool) {
        guard handledCount < totalCount else { return }
        if completed {
            completedCount += 1
            completedKnownBytes += max(size, 0)
        } else {
            failedCount += 1
            failedKnownBytes += max(size, 0)
        }
    }

    public mutating func markCancelled() {
        wasCancelled = true
    }

    /// 已下完的字节加上正在下的部分。
    public func downloadedBytes(inFlightBytes: Int64) -> Int64 {
        min(knownBytes, completedKnownBytes + max(inFlightBytes, 0))
    }

    /// 还没处理的字节:去掉下完的、失败的和正在下的部分。
    public func remainingBytes(inFlightBytes: Int64) -> Int64 {
        max(0, knownBytes - completedKnownBytes - failedKnownBytes - max(inFlightBytes, 0))
    }

    /// 0…1;一首都没记大小时按首数算,一首都没有时为 nil。
    public func fraction(inFlightBytes: Int64) -> Double? {
        if knownBytes > 0 {
            let handled = completedKnownBytes + failedKnownBytes + max(inFlightBytes, 0)
            return min(1, max(0, Double(handled) / Double(knownBytes)))
        }
        guard totalCount > 0 else { return nil }
        return min(1, max(0, Double(handledCount) / Double(totalCount)))
    }
}
