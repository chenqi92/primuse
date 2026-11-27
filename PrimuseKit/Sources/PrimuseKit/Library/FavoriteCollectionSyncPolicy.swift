import Foundation

// MARK: - 收藏的 iCloud 同步

/// 收藏区经 iCloud 键值存储同步的那一份，由 `FavoriteCollectionSyncPolicy` 合并。
///
/// - 收没收藏只记歌单（含「我喜欢」）、有声书和目录：专辑与艺人看喜欢的账本，那本账自己经 CloudKit 同步。
///   每条带着收藏或取消的时刻，取消留墓碑，另一台设备上的旧列表带不回来。
/// - 顺序记整份收藏区（专辑、艺人也在里面），首页「目录」区块的顺序另记一份。整份取新排的那份。
///
/// 编码用短键：整份和别的设置共用键值存储的 1 MB。
public struct FavoriteCollectionSyncState: Codable, Equatable, Sendable {
    /// 一条收藏：收着还是已经取消（墓碑），以及那一刻（1970 年起的秒）。
    public struct Membership: Codable, Equatable, Sendable {
        public var isCollected: Bool
        public var stamp: Double

        public init(isCollected: Bool, stamp: Double) {
            self.isCollected = isCollected
            self.stamp = stamp
        }

        private enum CodingKeys: String, CodingKey {
            case isCollected = "c"
            case stamp = "t"
        }
    }

    /// 一份顺序（收藏条目的 `QuickAccessPinReference.id`）和排定它的时刻。
    public struct Order: Codable, Equatable, Sendable {
        public var ids: [String]
        public var stamp: Double

        public init(ids: [String], stamp: Double) {
            self.ids = ids
            self.stamp = stamp
        }

        private enum CodingKeys: String, CodingKey {
            case ids = "i"
            case stamp = "t"
        }
    }

    public var members: [String: Membership]
    public var order: Order?
    public var folderOrder: Order?

    public init(members: [String: Membership] = [:], order: Order? = nil, folderOrder: Order? = nil) {
        self.members = members
        self.order = order
        self.folderOrder = folderOrder
    }

    public static let empty = FavoriteCollectionSyncState()

    private enum CodingKeys: String, CodingKey {
        case members = "m"
        case order = "o"
        case folderOrder = "f"
    }

    public init(from decoder: Decoder) throws {
        // 每一段都可以没有：以后的版本可能拿掉一段，旧版本也要读得出剩下的。
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = try container.decodeIfPresent([String: Membership].self, forKey: .members) ?? [:]
        order = try container.decodeIfPresent(Order.self, forKey: .order)
        folderOrder = try container.decodeIfPresent(Order.self, forKey: .folderOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !members.isEmpty { try container.encode(members, forKey: .members) }
        try container.encodeIfPresent(order, forKey: .order)
        try container.encodeIfPresent(folderOrder, forKey: .folderOrder)
    }
}

/// 收藏区在几台设备之间怎么合。
///
/// 每条收藏是独立的 last-writer-wins 寄存器，顺序是整份的寄存器，所以合并满足交换、结合、幂等：
/// 几台设备的副本按什么次序碰面都收敛到同一份，合进一份没有新东西的副本什么都不变（两台设备
/// 才不会来回推）。云端那份里没有某条不等于取消 —— 只有墓碑才拿掉收藏，第一次同步只会取并集。
public enum FavoriteCollectionSyncPolicy {
    /// 墓碑过了这么久就忘掉。离线更久的设备可能把那条收藏带回来；不忘的话这份只会越长越大。
    public static let tombstoneLifetime: TimeInterval = 120 * 24 * 60 * 60

    /// 推上去的顺序最多这么多条（专辑、艺人也算在里面）。多出来的排在最后，别的设备上按「还没排进
    /// 顺序的收藏」插到前面。
    public static let maximumOrderLength = 2000

    /// 一次编辑至少比它要盖过的那一刻晚这么多：设备的时钟慢了，编辑也照样是新的。
    static let stampStep = 0.001

    /// 歌单、有声书、目录：收没收藏由这一份决定。专辑与艺人只排顺序。
    public static func tracksMembership(_ id: String) -> Bool {
        guard let kind = QuickAccessPinReference(id: id)?.kind else { return false }
        switch kind {
        case .playlist, .book, .folder: return true
        case .album, .artist: return false
        }
    }

    static func isFolder(_ id: String) -> Bool {
        QuickAccessPinReference(id: id)?.kind == .folder
    }

    // MARK: 第一次

    /// 这台设备第一次参与同步时手上的收藏，都记在时刻 0 上：比任何一台设备真正收藏、取消的
    /// 那一刻都早。两台设备第一次碰面时各自的收藏取并集，谁也冲不掉谁；之后哪台设备真的取消了，
    /// 墓碑都比它们新。
    ///
    /// `removed` 是能确定已经被拿掉的：「我喜欢」默认就在收藏里，不在了就是用户拿掉的，记成
    /// 时刻 0 的墓碑 —— 同一时刻墓碑赢，新装设备默认带着的「我喜欢」顶不回来。
    /// `localOnly` 是只在这台设备上有意义的收藏（见 `recording`），不记。
    public static func initialState(
        collected: Set<String>,
        removed: Set<String>,
        order: [String],
        folderOrder: [String]?,
        localOnly: Set<String>
    ) -> FavoriteCollectionSyncState {
        var state = recording(
            .empty,
            collected: collected,
            localOnly: localOnly,
            order: order,
            folderOrder: folderOrder,
            now: 0
        )
        for id in removed where tracksMembership(id) && state.members[id] == nil {
            state.members[id] = .init(isCollected: false, stamp: 0)
        }
        return state
    }

    // MARK: 本机的改动

    /// 把这台设备现在的收藏记进状态。
    /// - Parameters:
    ///   - collected: 这台设备收藏着的歌单、有声书、目录（`QuickAccessPinReference.id`），包括在这台
    ///     设备上对不上、只是跟着同步留着的那些。
    ///   - localOnly: 只在这台设备上有意义的（本机音乐源里的目录与书）。还没进同步的不记、不排进
    ///     顺序；已经在同步里的照常同步，判定变了也不会因此当成取消。
    ///   - order: 用户自己排过、收藏或取消过时传这时的整份收藏顺序；`nil` 表示顺序不算这台设备排的
    ///     （跟着喜欢自动挪的、服务端带回来的），不换新时刻。
    ///   - folderOrder: 同上，首页「目录」区块的顺序。
    public static func recording(
        _ state: FavoriteCollectionSyncState,
        collected: Set<String>,
        localOnly: Set<String>,
        order: [String]?,
        folderOrder: [String]?,
        now: Double
    ) -> FavoriteCollectionSyncState {
        var next = state
        for id in collected.sorted() where tracksMembership(id) {
            let existing = next.members[id]
            guard existing?.isCollected != true else { continue }
            guard existing != nil || !localOnly.contains(id) else { continue }
            next.members[id] = .init(isCollected: true, stamp: nextStamp(after: existing?.stamp, now: now))
        }
        for (id, member) in state.members where member.isCollected && !collected.contains(id) {
            next.members[id] = .init(isCollected: false, stamp: nextStamp(after: member.stamp, now: now))
        }

        func isShared(_ id: String) -> Bool {
            next.members[id] != nil || !localOnly.contains(id)
        }
        if let order {
            let ids = deduplicated(order.filter(isShared))
            if ids != state.order?.ids {
                next.order = .init(ids: ids, stamp: nextStamp(after: state.order?.stamp, now: now))
            }
        }
        if let folderOrder {
            let ids = deduplicated(folderOrder.filter(isShared))
            if ids != state.folderOrder?.ids {
                next.folderOrder = .init(ids: ids, stamp: nextStamp(after: state.folderOrder?.stamp, now: now))
            }
        }
        return next
    }

    static func nextStamp(after previous: Double?, now: Double) -> Double {
        guard let previous else { return now }
        return max(now, previous + stampStep)
    }

    // MARK: 合并

    public static func merge(
        _ lhs: FavoriteCollectionSyncState,
        _ rhs: FavoriteCollectionSyncState
    ) -> FavoriteCollectionSyncState {
        var members = lhs.members
        for (id, incoming) in rhs.members {
            members[id] = members[id].map { winner($0, incoming) } ?? incoming
        }
        return FavoriteCollectionSyncState(
            members: members,
            order: winner(lhs.order, rhs.order),
            folderOrder: winner(lhs.folderOrder, rhs.folderOrder)
        )
    }

    /// 新的赢。同一时刻墓碑赢：第一次碰面的那批都在 0 上，拿掉「我喜欢」的那台设备记下的墓碑
    /// 要盖过新装设备默认带着的那一条。
    static func winner(
        _ lhs: FavoriteCollectionSyncState.Membership,
        _ rhs: FavoriteCollectionSyncState.Membership
    ) -> FavoriteCollectionSyncState.Membership {
        if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp ? lhs : rhs }
        return lhs.isCollected ? rhs : lhs
    }

    /// 新排的赢。同一时刻（两台设备第一次碰面，都在 0 上）条目多的赢：新装设备只有一个「我喜欢」，
    /// 不该把另一台排了几十条的顺序换掉。再一样就按内容定，每台设备挑得一样。
    static func winner(
        _ lhs: FavoriteCollectionSyncState.Order?,
        _ rhs: FavoriteCollectionSyncState.Order?
    ) -> FavoriteCollectionSyncState.Order? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp ? lhs : rhs }
        if lhs.ids.count != rhs.ids.count { return lhs.ids.count > rhs.ids.count ? lhs : rhs }
        return lhs.ids.lexicographicallyPrecedes(rhs.ids) ? lhs : rhs
    }

    // MARK: 落回本机

    /// 合好的状态落回本机的收藏顺序（`QuickAccessPinReference.id`）。
    /// - 照合好的顺序排；歌单、有声书、目录只留收藏着的，专辑与艺人照留（收没收藏看喜欢的账本，
    ///   显示时再筛）。
    /// - 收藏着却不在顺序里的（别的设备刚收藏、还没排进去）排到最前，最近收藏的在前；开头是
    ///   `anchor`（「我喜欢」）时排它后面。
    /// - 不在同步里的（只在这台设备上有意义的）按它们在 `current` 里的相对位置插回去。
    public static func liveOrder(
        _ state: FavoriteCollectionSyncState,
        current: [String],
        anchor: String?
    ) -> [String] {
        let kept = current.filter { tracksMembership($0) && state.members[$0] == nil }
        var seen = Set(kept)
        var result: [String] = []
        for id in state.order?.ids ?? current {
            guard seen.insert(id).inserted else { continue }
            if tracksMembership(id), state.members[id]?.isCollected != true { continue }
            result.append(id)
        }
        let unordered = newestFirst(state.members.filter { $0.value.isCollected && !seen.contains($0.key) })
        let index = anchor != nil && result.first == anchor ? 1 : 0
        result.insert(contentsOf: unordered, at: index)
        return reinserting(kept, from: current, into: result)
    }

    /// 首页「目录」区块的顺序（`QuickAccessPinReference.id`）。`current` 为 `nil` 表示这台设备从没
    /// 收藏过目录（首页在自动推荐）；同步里也没有目录时原样返回，别把自动推荐变成「一个都不收藏」。
    public static func liveFolderOrder(
        _ state: FavoriteCollectionSyncState,
        current: [String]?
    ) -> [String]? {
        let folderMembers = state.members.filter { isFolder($0.key) }
        guard state.folderOrder != nil || !folderMembers.isEmpty else { return current }
        let currentIDs = current ?? []
        let kept = currentIDs.filter { state.members[$0] == nil }
        var seen = Set(kept)
        var result: [String] = []
        for id in state.folderOrder?.ids ?? currentIDs {
            guard seen.insert(id).inserted, isFolder(id), state.members[id]?.isCollected == true else { continue }
            result.append(id)
        }
        let unordered = newestFirst(folderMembers.filter { $0.value.isCollected && !seen.contains($0.key) })
        result.insert(contentsOf: unordered, at: 0)
        return reinserting(kept, from: currentIDs, into: result)
    }

    private static func newestFirst(_ members: [String: FavoriteCollectionSyncState.Membership]) -> [String] {
        members.sorted { lhs, rhs in
            lhs.value.stamp != rhs.value.stamp ? lhs.value.stamp > rhs.value.stamp : lhs.key < rhs.key
        }.map(\.key)
    }

    /// 把 `kept` 插回 `merged`：每条跟在它在 `current` 里前面最近的、`merged` 里也有的那条后面，
    /// 前面没有这样的就排在最前。
    public static func reinserting(_ kept: [String], from current: [String], into merged: [String]) -> [String] {
        guard !kept.isEmpty else { return merged }
        let keptSet = Set(kept)
        let present = Set(merged)
        var leading: [String] = []
        var following: [String: [String]] = [:]
        var previous: String?
        for id in current {
            if keptSet.contains(id) {
                if let previous {
                    following[previous, default: []].append(id)
                } else {
                    leading.append(id)
                }
            } else if present.contains(id) {
                previous = id
            }
        }
        var result = leading
        for id in merged {
            result.append(id)
            result.append(contentsOf: following[id] ?? [])
        }
        return deduplicated(result)
    }

    private static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: 存与推

    /// 这台设备留着的：过期的墓碑忘掉。时刻 0 的墓碑（第一次同步时记下的「我喜欢」被拿掉）一直留着，
    /// 不然新装设备默认带着的「我喜欢」过几个月又会回来。
    public static func retained(_ state: FavoriteCollectionSyncState, now: Double) -> FavoriteCollectionSyncState {
        let cutoff = now - tombstoneLifetime
        var next = state
        next.members = state.members.filter { $0.value.isCollected || $0.value.stamp == 0 || $0.value.stamp >= cutoff }
        return next
    }

    /// 推上云端的那份：忘掉过期墓碑，顺序限在前 `maximumOrderLength` 条。同一份状态总推出同一份，
    /// 设备才分得清云端是不是已经是它。墓碑不按条数截：截掉的墓碑会被别的设备当成「还收藏着」推回来，
    /// 两台设备就会来回推。
    public static func uploadState(_ state: FavoriteCollectionSyncState, now: Double) -> FavoriteCollectionSyncState {
        var next = retained(state, now: now)
        if let order = next.order, order.ids.count > maximumOrderLength {
            next.order = .init(ids: Array(order.ids.prefix(maximumOrderLength)), stamp: order.stamp)
        }
        if let order = next.folderOrder, order.ids.count > maximumOrderLength {
            next.folderOrder = .init(ids: Array(order.ids.prefix(maximumOrderLength)), stamp: order.stamp)
        }
        return next
    }

    /// 合好之后要推上去的那份；云端已经是同一份时为 `nil`。云端那份也按同一时刻整理过再比：
    /// 两台设备的时钟差一点，一台已经忘掉的墓碑另一台还推着，按原样比就会来回推。
    public static func upload(
        _ merged: FavoriteCollectionSyncState,
        over remote: FavoriteCollectionSyncState?,
        now: Double
    ) -> FavoriteCollectionSyncState? {
        let upload = uploadState(merged, now: now)
        if let remote, uploadState(remote, now: now) == upload { return nil }
        return upload
    }

    public static func encode(_ state: FavoriteCollectionSyncState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(state)
    }

    public static func decode(_ data: Data?) -> FavoriteCollectionSyncState? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(FavoriteCollectionSyncState.self, from: data)
    }
}
