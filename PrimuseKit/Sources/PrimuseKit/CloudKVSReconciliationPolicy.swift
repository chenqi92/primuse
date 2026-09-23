import Foundation

/// 决定一个走 iCloud 键值存储(NSUbiquitousKeyValueStore)的设置键, 在本机副本和
/// 云端副本之间该往哪边走。
///
/// 每个键旁边各带一份「修订号 + 写入者」: 修订号是 Lamport 式的时间戳(每次编辑
/// 都越过本机与当时看得到的云端修订号, 且不落后于墙钟), 写入者是设备 id, 修订号
/// 相同时按写入者字典序打破平局。同步关着的时候本机编辑照样记账(只涨修订号,
/// 不推云端), 这样再打开开关时才分得清「本机在关着的时候改过」和「本机从没改过」。
///
/// 修订号 0 表示这一边从来没有写过这个键: 新装设备的默认值绝不能推上云端去
/// 覆盖别的设备; 云端没有这个键也不能当成删除来拉。
public enum CloudKVSReconciliationPolicy {
    public struct Version: Equatable, Sendable {
        public var revision: Double
        public var writer: String

        public init(revision: Double, writer: String) {
            self.revision = revision
            self.writer = writer
        }

        public static let unset = Version(revision: 0, writer: "")
    }

    public enum Action: Equatable, Sendable {
        /// 云端更新: 把云端值(或云端的删除)拉到本机。
        case pull
        /// 本机更新且本机有值: 把本机值连同本机修订号推到云端。
        case pushValue
        /// 本机更新但本机没有值: 本机在关着同步时删掉了它, 把删除推到云端。
        case pushDeletion
        /// 两边一致, 或者哪边都没写过。
        case keep
    }

    /// 键值存储自己报的变更原因。
    public enum ExternalChangeReason: Equatable, Sendable {
        /// 别的设备写了。
        case serverChange
        /// 装好后第一次从 iCloud 拉到全量: 系统会用云端值覆盖本机在此之前的写入,
        /// 本机副本也要跟着以云端为准, 修订号比较对这一次不适用。
        case initialSync
        /// 超出配额, 本机写入被拒。
        case quotaViolation
        /// 换了 iCloud 账号: 存储里现在是新账号的值, 旧账号留下的本机修订号不能
        /// 再拿来和它比大小。
        case accountChange
        case unknown

        public init(rawChangeReason: Int?) {
            switch rawChangeReason {
            case 0: self = .serverChange
            case 1: self = .initialSync
            case 2: self = .quotaViolation
            case 3: self = .accountChange
            default: self = .unknown
            }
        }
    }

    public static func isNewer(_ candidate: Version, than current: Version) -> Bool {
        candidate.revision > current.revision
            || (candidate.revision == current.revision && candidate.writer > current.writer)
    }

    /// 一次本机编辑该拿到的修订号。
    public static func nextRevision(now: TimeInterval, local: Double, remote: Double) -> Double {
        max(now, max(local, remote)) + 1
    }

    /// 启动、打开开关、或收到一条普通变更时, 一个键该怎么走。
    public static func catchUpAction(
        local: Version,
        hasLocalValue: Bool,
        remote: Version
    ) -> Action {
        if remote.revision > 0, isNewer(remote, than: local) {
            return .pull
        }
        if local.revision > 0, isNewer(local, than: remote) {
            return hasLocalValue ? .pushValue : .pushDeletion
        }
        return .keep
    }

    /// 这个原因下, 云端来的值是否不比修订号、直接以云端为准。
    public static func appliesRemoteUnconditionally(_ reason: ExternalChangeReason) -> Bool {
        switch reason {
        case .initialSync, .accountChange: return true
        case .serverChange, .quotaViolation, .unknown: return false
        }
    }

    /// 这个原因下, 本机记着的修订号是否已经没有意义, 要清零。
    public static func resetsLocalRevisions(_ reason: ExternalChangeReason) -> Bool {
        reason == .accountChange
    }

    /// 这个原因下有没有值可以应用(配额超限只是本机写入被拒, 云端什么都没变)。
    public static func carriesRemoteValues(_ reason: ExternalChangeReason) -> Bool {
        reason != .quotaViolation
    }
}
