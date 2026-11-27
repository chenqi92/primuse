import Foundation

/// 扫描读到的服务端评分要不要写回本机(#172)。评分:1…5,0 = 未评分。
public enum ServerRatingImportPolicy {
    public enum Decision: Equatable, Sendable {
        /// 不动(本机有待上传的改动,或服务端自上次同步以来没变)。
        case keep
        /// 两边已经一致,只记下基线。
        case recordBaseline
        /// 服务端在别的客户端被改过:采纳它。
        case adopt
    }

    /// - Parameters:
    ///   - baseline: 上次和服务端同步时双方一致的值;从没同步过为 nil。
    ///   - local: 本机现在的评分。
    public static func decision(
        observed: Int,
        baseline: Int?,
        local: Int,
        hasPendingLocalEdit: Bool
    ) -> Decision {
        // 本机改了还没发出去:以本机为准,冲突交给上传时的基线比对。
        guard !hasPendingLocalEdit else { return .keep }
        if observed == local { return baseline == observed ? .keep : .recordBaseline }
        if let baseline {
            // 服务端仍是上次同步时的值,是本机这边后来变了(比如别的设备经 iCloud
            // 带来的改动还没上传),不能拿旧值盖回去。
            return baseline == observed ? .keep : .adopt
        }
        // 从没同步过:只在本机还没评分时采纳。两边都有不同的评分时说不清谁新,
        // 留着本机的,下一次本机改动上传时再对齐。
        return local == 0 && observed > 0 ? .adopt : .keep
    }
}
