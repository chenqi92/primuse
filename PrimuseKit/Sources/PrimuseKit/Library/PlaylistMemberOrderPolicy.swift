import Foundation

/// 用户歌单（含「我喜欢」）里的歌怎么换先后。
///
/// 歌单存的是一串成员 id：除了列表上看得见的歌，还有置灰的占位、停用源里暂时看不见的歌，
/// 「我喜欢」里还有分出去显示的本地播客单集。换先后只动用户动的那几首，其余成员都留着、
/// 彼此先后不变。顺序随歌单记录同步到别的设备（各设备的歌曲 id 不同，按顺序对上），
/// 所以置顶就是把歌放到这串 id 的最前面，不另记一份「已置顶」。
public enum PlaylistMemberOrderPolicy {
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
