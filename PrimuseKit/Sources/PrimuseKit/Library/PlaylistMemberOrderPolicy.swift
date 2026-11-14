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
