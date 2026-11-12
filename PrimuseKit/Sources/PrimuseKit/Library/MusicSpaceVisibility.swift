import Foundation

/// 「音乐」这一类在界面上开不开:设置 › 资料库里的「音乐」开关,和资料库分类里电台、有声书、播客的
/// 开关是同一种,只是一次管一整类。
///
/// 只收入口,不动内容:关掉后资料库与侧栏不再列音乐的分类(收藏、歌曲、专辑、艺术家、流派、目录、
/// 发行年代、歌单、智能推荐、听歌统计),搜索不列音乐的结果,首页顶部切换没有「音乐」那一颗,
/// 极简顶栏没有「音乐」那一格。曲库、扫描、正在放的队列、播放页里去专辑和艺人的跳转都照旧;
/// 各分类自己的开关与顺序原样留着,重新打开后一切照旧。首页上的区块仍照首页编辑里的开关走,
/// 和电台、有声书在资料库里收起后首页那一块照旧一样。
///
/// 音乐和别的几类可以全关:首页一直在。极简顶栏只剩首页时不再摆分段,经典标签栏里没有东西可放的
/// 「资料库」收起来,打开 App 就落在首页。
public enum MusicSpaceVisibility {
    /// 随 iCloud 同步,和资料库分类的显隐一起。
    public static let storageKey = "primuse.library.showsMusic.v1"
    public static let defaultValue = true

    /// 资料库分类里自成一类、不跟音乐开关走的几个(按分类的 rawValue)。新加的分类默认算音乐。
    public static let otherSpaceSectionNames: Set<String> = ["radio", "spokenWord", "podcasts", "ambient"]

    public static func isMusicSection(named name: String) -> Bool {
        !otherSpaceSectionNames.contains(name)
    }

    /// 实际摆出来的分类:音乐关着时拿掉音乐的分类,其余顺序不变。
    public static func visibleSections<Section>(
        _ sections: [Section],
        showsMusic: Bool,
        name: (Section) -> String
    ) -> [Section] {
        showsMusic ? sections : sections.filter { !isMusicSection(named: name($0)) }
    }

    /// 搜索结果里属于音乐的块:除了电台、有声、环境音,其余都是从曲库与 Apple Music 搜出来的
    /// 歌、专辑、艺人、歌单和目录。
    public static func isMusicResult(_ section: SearchResultSection) -> Bool {
        switch section {
        case .radio, .spokenWord, .ambient: false
        default: true
        }
    }

    /// 音乐关着时当作收起的搜索结果块;用户在「调整搜索结果」里自己关掉的照旧算在内。
    public static func hiddenResults(
        _ hidden: Set<SearchResultSection>,
        showsMusic: Bool
    ) -> Set<SearchResultSection> {
        guard !showsMusic else { return hidden }
        return hidden.union(SearchResultSection.allCases.filter(isMusicResult))
    }

    /// 首页顶部切换里的某一颗能不能出现。只管音乐那一颗,别的交回调用方原来的判定。
    public static func isSpaceShown(_ space: ListeningSpace, showsMusic: Bool) -> Bool {
        space != .music || showsMusic
    }

    /// 极简顶栏摆不摆「首页」。音乐关着时首页是打开 App 落脚的地方,不跟「显示首页」开关走,
    /// 否则电台、有声也都收起时顶栏上一格都没有。
    public static func showsHomeTab(userChoice: Bool, showsMusic: Bool) -> Bool {
        userChoice || !showsMusic
    }

    /// 设置页的列表只列出一部分(音乐关着时不列音乐的分类)时拖动一行。
    ///
    /// 下标相对列出来的那几行;只在它们占的位置之间重排,没列出来的原地不动 —— 再打开音乐时,
    /// 音乐的分类还在原来的位置上。`listed` 里不在 `order` 中的项不参与。
    public static func reordering<Item: Hashable>(
        _ order: [Item],
        listed: [Item],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [Item] {
        let listedSet = Set(listed)
        let slots = order.indices.filter { listedSet.contains(order[$0]) }
        var moved = slots.map { order[$0] }
        let validSource = source.filter { moved.indices.contains($0) }
        guard !validSource.isEmpty else { return order }
        let clampedDestination = min(max(destination, 0), moved.count)
        let picked = validSource.map { moved[$0] }
        let insertionIndex = clampedDestination - validSource.filter { $0 < clampedDestination }.count
        for index in validSource.reversed() {
            moved.remove(at: index)
        }
        moved.insert(contentsOf: picked, at: insertionIndex)

        var result = order
        for (slot, item) in zip(slots, moved) {
            result[slot] = item
        }
        return result
    }
}
