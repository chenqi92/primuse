import Foundation

/// 状态展示行集合的廉价指纹。对账在后台线程上逐条折叠出一个 64 位摘要,
/// 主 actor 只比较这一个值, 取代成千上万条带标题/路径字符串的展示行字典
/// 相等比较。摘要相同即视为界面没有变化, 因此不推进 `statusRevision`,
/// 也就不会在一次没有用户可见变化的 flush 里重新渲染状态界面。
///
/// 顺序敏感: 展示行按歌曲数组顺序生成, 顺序变化本身就是界面变化。
/// 来源集合用异或折叠, 与遍历顺序无关(集合本身是无序的)。
public struct MetadataBackfillStatusSignature: Equatable, Sendable {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    private var ordered: UInt64 = MetadataBackfillStatusSignature.offsetBasis
    private var unordered: UInt64 = 0
    private var itemCount: Int = 0

    public init() {}

    public mutating func combine(item: MetadataBackfillStatusDisplayItem, sourceID: String) {
        var hasher = Hasher()
        hasher.combine(sourceID)
        hasher.combine(item.songID)
        hasher.combine(item.title)
        hasher.combine(item.artistName)
        hasher.combine(item.filePath)
        hasher.combine(item.fileFormat)
        hasher.combine(item.hasMissingDuration)
        hasher.combine(item.state)
        hasher.combine(item.workReasons.rawValue)
        hasher.combine(item.diagnostic?.state)
        hasher.combine(item.diagnostic?.reason)
        hasher.combine(item.diagnostic?.attemptCount)
        hasher.combine(item.diagnostic?.lastAttemptAt)
        hasher.combine(item.attemptCount)
        ordered = (ordered ^ UInt64(bitPattern: Int64(hasher.finalize())))
            &* MetadataBackfillStatusSignature.prime
        itemCount += 1
    }

    /// 记录"这个来源有一份快照"(哪怕是空的), 使来源增删同样被视为变化。
    public mutating func combine(sourceID: String) {
        var hasher = Hasher()
        hasher.combine(sourceID)
        unordered ^= UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
