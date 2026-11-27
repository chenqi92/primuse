import Foundation

public enum AudioCacheLimitPolicy {
    public static let unlimitedBytes: Int64 = 0
    public static let bytesPerGiB: Int64 = 1_073_741_824
    public static let defaultBytes: Int64 = 2 * bytesPerGiB
    public static let selectableBytes: [Int64] = [
        unlimitedBytes,
        bytesPerGiB,
        2 * bytesPerGiB,
        5 * bytesPerGiB,
        10 * bytesPerGiB,
        20 * bytesPerGiB,
    ]

    /// Keeps a legacy or cross-device custom limit visible until the user
    /// explicitly chooses one of the standard whole-GiB options.
    public static func options(including currentBytes: Int64) -> [Int64] {
        guard currentBytes > unlimitedBytes,
              !selectableBytes.contains(currentBytes) else {
            return selectableBytes
        }
        return [unlimitedBytes]
            + (Array(selectableBytes.dropFirst()) + [currentBytes]).sorted()
    }

    /// A zero or negative limit means the user opted out of automatic LRU
    /// eviction. Audio caching remains enabled and continues to use disk space.
    public static func evictionTarget(
        limitBytes: Int64,
        reserveBytes: Int64
    ) -> Int64? {
        guard limitBytes > unlimitedBytes else { return nil }
        let reserve = reserveBytes > 0 ? reserveBytes : 10_485_760
        return max(0, limitBytes - reserve)
    }
}
