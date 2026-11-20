import Foundation

/// 用户歌单（含「我喜欢」）里的歌怎么换先后。
///
/// 歌单存的是一串成员 id：除了列表上看得见的歌，还有置灰的占位、停用源里暂时看不见的歌，
/// 「我喜欢」里还有分出去显示的本地播客单集。换先后只动用户动的那几首，其余成员都留着、
/// 彼此先后不变。顺序随歌单记录同步到别的设备（各设备的歌曲 id 不同，按顺序对上）。
/// 置顶另记在歌单记录上、不挪成员（见 `PlaylistPinnedSongsPolicy`）。
public enum PlaylistMemberOrderPolicy {
    /// 尚未扫到的歌曲用原身份填回保留的位置，避免转发同步记录时被挪到末尾。
    public static func syncIdentities(
        _ members: [SongIdentity],
        pending: [SongIdentity]
    ) -> [SongIdentity] {
        let pendingByID = Dictionary(pending.map { ($0.songID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return (members + pending).compactMap { identity in
            guard seen.insert(identity.songID).inserted else { return nil }
            return pendingByID[identity.songID] ?? identity
        }
    }

    /// 置顶：选中的成员移到最前面，彼此保持在歌单里原来的先后，其余成员照原顺序跟在后面。
    /// 不是成员的 id 忽略。
    public static func movingToTop<S: Sequence<String>>(_ memberIDs: [String], selected: S) -> [String] {
        let selectedIDs = Set(selected)
        guard !selectedIDs.isEmpty else { return memberIDs }
        var top: [String] = []
        var rest: [String] = []
        rest.reserveCapacity(memberIDs.count)
        for id in memberIDs {
            if selectedIDs.contains(id) {
                top.append(id)
            } else {
                rest.append(id)
            }
        }
        return top + rest
    }

    /// 重排面板只列看得见的歌：排好的顺序依次填回这些歌原来占的位置，没列出来的成员原位不动，
    /// 不会因为一次重排就从歌单里消失。`listedOrder` 里不是成员的 id 忽略。
    public static func reordered(_ memberIDs: [String], listedOrder: [String]) -> [String] {
        let members = Set(memberIDs)
        var listedIDs = Set<String>()
        let listed = listedOrder.filter { members.contains($0) && listedIDs.insert($0).inserted }
        guard !listed.isEmpty else { return memberIDs }
        var next = listed.makeIterator()
        return memberIDs.compactMap { id in
            listedIDs.contains(id) ? next.next() : id
        }
    }

    /// 一个音乐源的收藏同步回来时「我喜欢」的新成员：这个源里仍收藏着的歌留在原位（置顶过的
    /// 照旧在前面），服务端已取消的拿掉，新收藏的按服务端给的先后接在最后；别的源和本地的成员不动。
    /// `authoritative` 只含这个源的歌。
    public static func syncingSourceMembers(
        _ memberIDs: [String],
        authoritative: [String],
        isFromSource: (String) -> Bool
    ) -> [String] {
        let kept = Set(authoritative)
        var result = memberIDs.filter { !isFromSource($0) || kept.contains($0) }
        var present = Set(result)
        for id in authoritative where present.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}

/// 歌单里置顶的歌(#412)。
///
/// 置顶记在歌单记录上(`Playlist.pinnedSongIDs`,最近置顶的在最前),不改成员的先后:
/// 歌单顺序和「添加日期」照旧按成员原来的先后,取消置顶的歌就回到它在所选排序里的位置。
/// 不管选的是哪种排序,置顶的歌都排在最上面,彼此按置顶的先后;其余的照所选排序。
/// 各设备的歌曲 id 不同,收到别的设备的歌单记录时借成员身份表把置顶翻成本机 id(`translated`)。
public enum PlaylistPinnedSongsPolicy {
    /// 眼下有效的置顶:还在歌单里的,去重,按置顶先后。
    public static func effective(_ pinned: [String], memberIDs: Set<String>) -> [String] {
        guard !pinned.isEmpty else { return [] }
        var seen = Set<String>()
        return pinned.filter { memberIDs.contains($0) && seen.insert($0).inserted }
    }

    /// 置顶这几首:按它们在歌单里的先后排在置顶的最前面(和以前把歌挪到最前面一样,
    /// 最近置顶的在最上面),原先置顶的跟在后面。不是成员的 id 忽略,已经不在歌单里的旧置顶顺手清掉。
    public static func pinning<S: Sequence<String>>(
        _ selected: S,
        pinned: [String],
        memberIDs: [String]
    ) -> [String] {
        let members = Set(memberIDs)
        let selectedIDs = Set(selected).intersection(members)
        let kept = effective(pinned, memberIDs: members)
        guard !selectedIDs.isEmpty else { return kept }
        var seen = Set<String>()
        let top = memberIDs.filter { selectedIDs.contains($0) && seen.insert($0).inserted }
        return top + kept.filter { !selectedIDs.contains($0) }
    }

    /// 取消置顶:拿掉这几首,其余置顶的先后不变。
    public static func unpinning<S: Sequence<String>>(_ selected: S, pinned: [String]) -> [String] {
        let removed = Set(selected)
        guard !removed.isEmpty else { return pinned }
        return pinned.filter { !removed.contains($0) }
    }

    /// 置顶的提到最前面、按置顶先后,其余保持 `ordered` 里原来的先后。`ordered` 是按所选排序
    /// 排好的一列(可以是歌、条目或 id);里面没有置顶的歌时原样返回,不拷贝。
    public static func pinnedFirst<Element>(
        _ ordered: [Element],
        pinned: [String],
        id: (Element) -> String
    ) -> [Element] {
        guard !pinned.isEmpty, !ordered.isEmpty else { return ordered }
        var rank: [String: Int] = [:]
        for (index, songID) in pinned.enumerated() where rank[songID] == nil {
            rank[songID] = index
        }
        var top = [Element?](repeating: nil, count: pinned.count)
        var rest: [Element] = []
        rest.reserveCapacity(ordered.count)
        var found = 0
        for element in ordered {
            if let index = rank[id(element)], top[index] == nil {
                top[index] = element
                found += 1
            } else {
                rest.append(element)
            }
        }
        guard found > 0 else { return ordered }
        return top.compactMap { $0 } + rest
    }

    /// 重排面板「完成」:面板里能拖动置顶的歌彼此的先后,置顶的先后就照面板走;
    /// 面板没列出来的置顶原位留着。
    public static func reordered(_ pinned: [String], listedOrder: [String]) -> [String] {
        PlaylistMemberOrderPolicy.reordered(pinned, listedOrder: listedOrder)
    }

    /// 重排面板「完成」时成员表只按没置顶的那些重排:置顶的歌留在成员表原来的位置,
    /// 取消置顶时才回得去。
    public static func unpinnedListedOrder(_ listedOrder: [String], pinned: [String]) -> [String] {
        guard !pinned.isEmpty else { return listedOrder }
        let pinnedIDs = Set(pinned)
        return listedOrder.filter { !pinnedIDs.contains($0) }
    }

    /// 别的设备记的置顶翻成本机 id。`localIDs` 是对方的歌曲 id → 本机的成员 id;
    /// 对不上的拿掉,翻完重复的只留第一次。
    public static func translated(_ pinned: [String], localIDs: [String: String]) -> [String] {
        var seen = Set<String>()
        return pinned.compactMap { remoteID in
            guard let localID = localIDs[remoteID], seen.insert(localID).inserted else { return nil }
            return localID
        }
    }
}

/// 服务器上的歌单换先后后整份写回(#449)。
///
/// 镜像歌单里一首歌只占一行, 服务器上的歌单却可能有重复项, 也可能有本机列表里看不见的条目
/// (停用源里对上的歌、只在本机隐藏的歌)。写回时交给服务器的永远是它眼下明细的一个排列:
/// 一项不多、一项不少, 重复项也一个不丢; 只挪用户在面板里排过的那几行。
public enum ServerPlaylistReorderPolicy {
    /// 一串服务器曲目 id 的多重集摘要: 不看先后, 重复项按次数算。镜像落地时记下, 重排前拿来
    /// 和服务器眼下的明细比, 不用为每张歌单在内存里留一整份 id。
    public struct TrackMultiset: Equatable, Sendable {
        public let count: Int
        private let sum: UInt64
        private let squareSum: UInt64

        public init<S: Sequence<String>>(_ trackIDs: S) {
            var count = 0
            var sum: UInt64 = 0
            var squareSum: UInt64 = 0
            for id in trackIDs {
                // FNV-1a: 跨进程稳定, 不受 Swift 每次启动随机化的 Hasher 影响。
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for byte in id.utf8 {
                    hash ^= UInt64(byte)
                    hash &*= 0x0000_0100_0000_01b3
                }
                count += 1
                sum &+= hash
                squareSum &+= hash &* hash
            }
            self.count = count
            self.sum = sum
            self.squareSum = squareSum
        }
    }

    /// `lhs` 是不是 `rhs` 换了先后(多重集相同)。
    public static func isPermutation(_ lhs: [String], of rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var remaining: [String: Int] = [:]
        for id in rhs { remaining[id, default: 0] += 1 }
        for id in lhs {
            guard let count = remaining[id], count > 0 else { return false }
            remaining[id] = count - 1
        }
        return true
    }

    /// 排序依据的本机镜像和服务器眼下的明细是不是同一份内容(先后不算)。
    /// - Parameters:
    ///   - serverTrackIDs: 服务器眼下的明细。
    ///   - serverMemberIDs: 这份明细每一项在镜像里对应的成员, 与 `serverTrackIDs` 逐位对应。
    ///   - recorded: 上次落地镜像时记下的服务器明细摘要; 没记过(冷启动后还没同步过)为 nil, 只比成员。
    ///   - mirrorMemberIDs: 镜像眼下的成员。
    public static func serverMatchesMirror(
        serverTrackIDs: [String],
        serverMemberIDs: [String],
        recorded: TrackMultiset?,
        mirrorMemberIDs: [String]
    ) -> Bool {
        guard serverMemberIDs.count == serverTrackIDs.count else { return false }
        if let recorded, recorded != TrackMultiset(serverTrackIDs) { return false }
        return Set(serverMemberIDs) == Set(mirrorMemberIDs)
    }

    /// 按面板里排好的先后重排服务器明细, 返回原下标的新排列; 先后不用变时返回 nil。
    ///
    /// `memberIDs` 与服务器明细逐位对应(同一首重复出现就重复), `listedOrder` 是面板里列出来的
    /// 成员的新先后。列出来的成员第一次出现的那一项依次填回这些项原来占的位置, 没列出来的原位不动;
    /// 同一首其余的重复项也留在原位, 只有落在这首新位置前面的跟到它后面 —— 按第一次出现去重后,
    /// 先后要和面板里排的一样。
    public static func reorderedPositions(memberIDs: [String], listedOrder: [String]) -> [Int]? {
        var firstPosition: [String: Int] = [:]
        for (offset, id) in memberIDs.enumerated() where firstPosition[id] == nil {
            firstPosition[id] = offset
        }
        var listedIDs = Set<String>()
        let listed = listedOrder.filter { firstPosition[$0] != nil && listedIDs.insert($0).inserted }
        guard !listed.isEmpty else { return nil }

        var filled = Array(memberIDs.indices)
        let slots = listed.compactMap { firstPosition[$0] }.sorted()
        for (slot, id) in zip(slots, listed) {
            if let position = firstPosition[id] { filled[slot] = position }
        }

        var placed = Set<String>()
        var waiting: [String: [Int]] = [:]
        var result: [Int] = []
        result.reserveCapacity(memberIDs.count)
        for position in filled {
            let id = memberIDs[position]
            if firstPosition[id] == position {
                result.append(position)
                placed.insert(id)
                if let extras = waiting.removeValue(forKey: id) { result.append(contentsOf: extras) }
            } else if placed.contains(id) {
                result.append(position)
            } else {
                waiting[id, default: []].append(position)
            }
        }
        return result.elementsEqual(memberIDs.indices) ? nil : result
    }

    /// `updatePlaylist` 的一步: 同一个请求里先按下标删掉这几项, 再把它们按新先后加到末尾。
    public struct MoveToEndStep: Equatable, Sendable {
        /// 这一步之前明细里的下标, 从大到小。
        public let removedIndices: [Int]
        public let appendedIDs: [String]
        /// 这一步做完后服务器上应有的明细, 拿来核对回读。
        public let expectedTrackIDs: [String]
    }

    /// 只能「按下标删、往末尾加」的服务器上, 从 `current` 排成 `target` 的步骤。每一步删掉的和
    /// 加回的是同一批, 中途停下也一首不丢; 开头已经按新先后排好的那一段不动。
    /// `target` 不是 `current` 的排列、或 `batchSize` 不是正数时返回 nil。
    public static func moveToEndSteps(from current: [String], to target: [String], batchSize: Int) -> [MoveToEndStep]? {
        guard batchSize > 0, isPermutation(target, of: current) else { return nil }
        // 能原地留下的: 新先后开头那一段, 只要它在 current 里按顺序出现(不必挨着)。
        var keptCount = 0
        var entries: [(id: String, settled: Bool)] = []
        entries.reserveCapacity(current.count)
        for id in current {
            let settled = keptCount < target.count && target[keptCount] == id
            if settled { keptCount += 1 }
            entries.append((id: id, settled: settled))
        }
        var steps: [MoveToEndStep] = []
        var offset = keptCount
        while offset < target.count {
            let batch = Array(target[offset..<min(offset + batchSize, target.count)])
            var movable: [String: [Int]] = [:]
            for (index, entry) in entries.enumerated() where !entry.settled {
                movable[entry.id, default: []].append(index)
            }
            var removed = Set<Int>()
            for id in batch {
                guard var indices = movable[id], !indices.isEmpty else { return nil }
                removed.insert(indices.removeFirst())
                movable[id] = indices
            }
            entries = entries.indices.filter { !removed.contains($0) }.map { entries[$0] }
            entries.append(contentsOf: batch.map { (id: $0, settled: true) })
            steps.append(MoveToEndStep(
                removedIndices: removed.sorted(by: >),
                appendedIDs: batch,
                expectedTrackIDs: entries.map(\.id)
            ))
            offset += batch.count
        }
        return entries.map(\.id) == target ? steps : nil
    }
}
