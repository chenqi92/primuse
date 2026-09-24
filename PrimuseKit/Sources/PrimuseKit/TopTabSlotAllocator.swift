import Foundation

/// 顶部 tab 外壳里「哪几页常驻」的分配表。
///
/// 系统的 TabView 在 iPhone 上超过五个标签就会把后面的收进「更多」,被选中的页面会被
/// 套进「更多」自带的导航栈;而顶部 tab 条的项目(首页、电台与资料库各分类)动辄十个以上。
/// 所以外壳只开固定几个标签当「槽位」,页面按最近使用轮流住进去:切回仍住在槽位里的页面,
/// 滚动位置和推入的详情页都还在;槽位不够时,让最久没用的那一页让出位置(它的状态随之丢掉)。
public struct TopTabSlotAllocator<Page: Hashable & Sendable>: Sendable, Equatable {
    /// 同时常驻的页面数。不能超过 5,否则系统标签栏会出现「更多」。
    public let capacity: Int
    /// 每个槽位住着哪一页;没住人的槽位是 nil。
    public private(set) var pages: [Page?]
    /// 当前显示的槽位。
    public private(set) var selectedSlot: Int = 0
    private var lastUse: [UInt64]
    private var clock: UInt64 = 0

    public init(capacity: Int = 5) {
        let capacity = max(1, capacity)
        self.capacity = capacity
        self.pages = Array(repeating: nil, count: capacity)
        self.lastUse = Array(repeating: 0, count: capacity)
    }

    public var selectedPage: Page? { pages[selectedSlot] }

    public func slot(of page: Page) -> Int? {
        pages.firstIndex(of: page)
    }

    /// 切到这一页并返回它住的槽位。已经常驻就原地切过去;否则先占空槽位,
    /// 没有空槽位就换掉最久没用的那一页 —— 正在显示的那一页永远不会被换掉。
    @discardableResult
    public mutating func select(_ page: Page) -> Int {
        clock &+= 1
        let slot: Int
        if let existing = self.slot(of: page) {
            slot = existing
        } else if let empty = pages.firstIndex(where: { $0 == nil }) {
            slot = empty
        } else {
            let candidates = pages.indices.filter { $0 != selectedSlot }
            slot = candidates.min { lastUse[$0] < lastUse[$1] } ?? selectedSlot
        }
        pages[slot] = page
        lastUse[slot] = clock
        selectedSlot = slot
        return slot
    }

    /// 只留下仍然可去的页面(用户在资料库设置里隐藏了某个分类时)。
    /// 返回当前显示的那一页是否被清掉了 —— 是的话调用方要另选一页。
    @discardableResult
    public mutating func retain(_ reachable: Set<Page>) -> Bool {
        var clearedSelection = false
        for index in pages.indices {
            guard let page = pages[index], !reachable.contains(page) else { continue }
            pages[index] = nil
            lastUse[index] = 0
            if index == selectedSlot { clearedSelection = true }
        }
        return clearedSelection
    }
}
