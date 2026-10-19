import Foundation

/// 「我喜欢」里的本地播客单集（自己的文件标成播客）怎么分出去。
///
/// 点心照旧记进「我喜欢」这一份成员（iCloud 同步、服务端星标都不变），只是把它当歌单用时
/// （列表、首数、播放与随机、封面、Siri、CarPlay、电视）不算这些单集；它们和订阅播客喜欢的单集
/// 一起列在「喜欢的单集」里。成员按点心先后追加，没有单独的喜欢时间。
public enum LikedSongsPodcastSplitPolicy {
    /// 当歌单用的成员：去掉本地播客单集，其余照原顺序。
    public static func music(
        _ memberIDs: [String],
        isLocalPodcast: (String) -> Bool
    ) -> [String] {
        memberIDs.filter { !isLocalPodcast($0) }
    }

    /// 喜欢的本地播客单集，最近点心的在前。
    public static func podcastsNewestFirst(
        _ memberIDs: [String],
        isLocalPodcast: (String) -> Bool
    ) -> [String] {
        memberIDs.reversed().filter(isLocalPodcast)
    }

    /// 整体替换「我喜欢」（拖动排序、把队列存进来）时的新成员：界面上看不见的本地播客单集
    /// 不算被删掉，照原先的先后接在后面，免得一次重排就把它们取消喜欢了。
    public static func replacement(
        _ newIDs: [String],
        keeping storedIDs: [String],
        isLocalPodcast: (String) -> Bool
    ) -> [String] {
        let listed = Set(newIDs)
        let kept = storedIDs.filter { isLocalPodcast($0) && !listed.contains($0) }
        return kept.isEmpty ? newIDs : newIDs + kept
    }
}
