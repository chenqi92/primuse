import Foundation

/// 收藏区的顺序。
///
/// 存下来的顺序只决定「怎么排」，不全决定「有没有」：专辑与艺人收没收藏以喜欢的账本为准
/// （会经 iCloud、服务端同步过来），目录以首页目录的置顶列表为准，歌单就看存下来的这一份。
/// 显示时存着的顺序里已经不再收藏的跳过；收藏着却还没排进顺序的（另一台设备点的、服务端带回来的）
/// 和新收藏一样排在最前。
public enum FavoriteCollectionOrderPolicy {
    /// 新收藏插进去的位置：最前；开头是 `anchor`（「我喜欢」）时排在它后面。
    public static func insertionIndex(
        in pins: [QuickAccessPinReference],
        anchor: QuickAccessPinReference?
    ) -> Int {
        guard let anchor, pins.first == anchor else { return 0 }
        return 1
    }

    /// 把一批新收藏按给定顺序放到最前（`added[0]` 排第一）。已经在列表里的先拿出来再放，
    /// 不会出现两份。
    public static func inserting(
        _ added: [QuickAccessPinReference],
        into pins: [QuickAccessPinReference],
        anchor: QuickAccessPinReference?
    ) -> [QuickAccessPinReference] {
        var seen = Set<QuickAccessPinReference>()
        let moving = added.filter { seen.insert($0).inserted }
        guard !moving.isEmpty else { return pins }
        var result = pins.filter { !seen.contains($0) }
        result.insert(contentsOf: moving, at: insertionIndex(in: result, anchor: anchor))
        return result
    }

    /// 显示顺序：`stored` 里仍收藏着的照原顺序，`collectedButUnordered` 里还没在 `stored` 中的
    /// 按给定顺序排到最前。
    public static func merged(
        stored: [QuickAccessPinReference],
        isCollected: (QuickAccessPinReference) -> Bool,
        collectedButUnordered: [QuickAccessPinReference],
        anchor: QuickAccessPinReference?
    ) -> [QuickAccessPinReference] {
        var seen = Set<QuickAccessPinReference>()
        let kept = stored.filter { seen.insert($0).inserted && isCollected($0) }
        let unordered = collectedButUnordered.filter { seen.insert($0).inserted }
        return inserting(unordered, into: kept, anchor: anchor)
    }
}
