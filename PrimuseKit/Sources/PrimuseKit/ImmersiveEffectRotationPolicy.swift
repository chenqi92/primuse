import Foundation

/// 全屏效果自动轮换（#312）：隔一段时间或每换一首歌，把全屏画面换成另一种效果，像 ampcast 的可视化器那样轮着放。
/// 只换眼前显示的这一种，用户选定的效果（三端同步的那项设置）不动。只存本机、不进云同步：
/// 电视上开着轮换，手机未必想要。
public enum ImmersiveEffectRotationMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case perSong
    case minutes1
    case minutes2
    case minutes5
    case minutes10

    public static let storageKey = "primuse.immersiveEffectRotation"
    public static let defaultValue = ImmersiveEffectRotationMode.off

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }

    public var isEnabled: Bool { self != .off }

    /// 定时换的分钟数；关和每首歌换时为 nil。
    public var minutes: Int? {
        switch self {
        case .off, .perSong: nil
        case .minutes1: 1
        case .minutes2: 2
        case .minutes5: 5
        case .minutes10: 10
        }
    }

    /// 定时换的间隔（秒）。只在播放、全屏页在前台时计时，暂停后从头算。
    public var interval: TimeInterval? {
        minutes.map { TimeInterval($0 * 60) }
    }
}

/// 轮换在哪些效果里挑。默认只挑跟声音动的那几种，最接近「可视化器」；也可以所有全屏效果一起轮。
public enum ImmersiveEffectRotationScope: String, CaseIterable, Identifiable, Sendable {
    case audioReactive
    case all

    public static let storageKey = "primuse.immersiveEffectRotationScope"
    public static let defaultValue = ImmersiveEffectRotationScope.audioReactive

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }
}

/// 下一种放什么：把候选洗一遍挨个放，一轮放完再洗，所以不会刚换走又换回来；眼前这一种永远不在候选里，
/// 新一轮的第一个也就不会是刚放的那个。候选变了（改了轮换范围）时，剩下没放的里不在新候选里的直接丢掉。
public struct ImmersiveEffectRotationQueue: Equatable, Sendable {
    private var pending: [String] = []

    public init() {}

    public mutating func next(after current: String, pool: [String]) -> String? {
        var generator = SystemRandomNumberGenerator()
        return next(after: current, pool: pool, using: &generator)
    }

    public mutating func next<Generator: RandomNumberGenerator>(
        after current: String,
        pool: [String],
        using generator: inout Generator
    ) -> String? {
        var seen = Set<String>()
        let candidates = pool.filter { $0 != current && seen.insert($0).inserted }
        guard !candidates.isEmpty else { return nil }
        let allowed = Set(candidates)
        pending.removeAll { !allowed.contains($0) }
        if pending.isEmpty {
            pending = candidates.shuffled(using: &generator)
        }
        return pending.removeFirst()
    }
}
