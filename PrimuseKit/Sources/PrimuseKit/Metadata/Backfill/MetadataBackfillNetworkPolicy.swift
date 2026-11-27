import Foundation

public enum MetadataBackfillNetworkPolicy {
    public static func allowedSourceIDs(
        networkIsBlocked: Bool,
        offlineReadableSourceIDs: Set<String>
    ) -> Set<String>? {
        networkIsBlocked ? offlineReadableSourceIDs : nil
    }

    /// Mixed work should wake without requiring network so sandbox rows can
    /// drain. A later request requires network after only remote rows remain.
    public static func backgroundWakeRequiresNetwork(
        hasPendingWork: Bool,
        pendingSourceIDs: Set<String>,
        offlineReadableSourceIDs: Set<String>
    ) -> Bool {
        hasPendingWork
            && pendingSourceIDs.isDisjoint(with: offlineReadableSourceIDs)
    }

    /// 同一个判定, 但调用方只拿得到上一次对账缓存下来的每源剩余数。
    ///
    /// 队列被标脏之后 (扫描每发布一批歌就会标一次, 而对账已经推到主 actor
    /// 之外) 那份缓存可能还没跟上: `pendingSourceIDs` 可能是空集或上一轮的
    /// 集合, 空集与任何集合都 disjoint, 上面的判定会直接回答"需要网络"——
    /// 于是只剩沙盒行要读的设备也会被要求联网才唤醒。这里在不遍历资料库的
    /// 前提下给一个保守答案: 只要还有一个可回填的源不是"离线可读", 就按需要
    /// 网络申请; 全是离线可读 (或根本没有可回填的源) 时就不要求网络, 让本地
    /// 行能在没有网络的设备上被唤醒。缓存是新的 (队列不脏) 时行为不变。
    ///
    /// - Parameters:
    ///   - queueNeedsReconcile: 队列被标脏 / 已对账代次落后于变更代次,
    ///     也就是缓存的每源剩余数可能已经过期。
    ///   - backfillableSourceIDs: 当前参与回填的全部源。
    public static func backgroundWakeRequiresNetworkFromCachedCounts(
        queueNeedsReconcile: Bool,
        hasPendingWork: Bool,
        pendingSourceIDs: Set<String>,
        backfillableSourceIDs: Set<String>,
        offlineReadableSourceIDs: Set<String>
    ) -> Bool {
        guard hasPendingWork else { return false }
        guard queueNeedsReconcile else {
            return backgroundWakeRequiresNetwork(
                hasPendingWork: true,
                pendingSourceIDs: pendingSourceIDs,
                offlineReadableSourceIDs: offlineReadableSourceIDs
            )
        }
        return !backfillableSourceIDs.subtracting(offlineReadableSourceIDs).isEmpty
    }
}
