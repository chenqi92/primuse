import Foundation

/// 歌单列表的显示顺序规则。
///
/// 歌单此前固定按最近更新倒序排列,用户排不了 —— 随便往哪个歌单里加一首歌,
/// 它就跳到最前面。现在每个歌单带一个手动位次:`sortOrder == 0` 表示"还没排过",
/// 排过序的从 1 开始。没排过的排在排过的前面(组内仍按最近更新在前),于是
/// 新建或新同步进来的歌单总是出现在最上面,而用户排好的顺序不会被一次更新打乱。
///
/// 全部歌单都是 0 时,这套规则退化成原来的"最近更新在前",所以升级上来的用户
/// 在动手排序之前看到的顺序完全没变。
public enum PlaylistManualOrderPolicy {
    /// 还没排过序的位次。比任何排定位次都小,因此排在最前面。
    public static let unordered = 0

    /// 排序用的比较键。只取顺序真正依赖的两个字段,方便在任何层复用与测试。
    public struct OrderKey: Sendable, Equatable {
        public let sortOrder: Int
        public let updatedAt: Date

        public init(sortOrder: Int, updatedAt: Date) {
            self.sortOrder = sortOrder
            self.updatedAt = updatedAt
        }
    }

    /// 把用户拖出来的顺序转成位次表,从 1 开始。重复 id 只认第一次出现的位置。
    public static func sortOrders(forOrderedIDs ids: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(ids.count)
        var next = 1
        for id in ids where result[id] == nil {
            result[id] = next
            next += 1
        }
        return result
    }

    /// 位次小的在前;位次相同(含都没排过)时最近更新的在前。
    public static func isOrderedBefore(_ lhs: OrderKey, _ rhs: OrderKey) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.updatedAt > rhs.updatedAt
    }

    /// 重排是否真的改变了顺序。没变就不写库,免得白白推一次 iCloud 同步。
    public static func orderChanged(
        currentOrderedIDs: [String],
        newOrderedIDs: [String],
        currentSortOrders: [String: Int]
    ) -> Bool {
        if currentOrderedIDs != newOrderedIDs { return true }
        // 顺序看着一样,但如果还有歌单没排过序,写一次位次才能把这个顺序钉住。
        let expected = sortOrders(forOrderedIDs: newOrderedIDs)
        return expected.contains { currentSortOrders[$0.key] != $0.value }
    }
}
