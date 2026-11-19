import Foundation

/// 来源页卡片的几条排法:同类型的源挨着排、什么时候要带上账号才分得开、
/// 有几条线路时卡片上写哪一条。
public enum SourceCardPresentationPolicy {
    /// 同一分区里同类型的源挨着排:各类型按第一次出现的先后,同类型内部保持原来的顺序。
    public static func keepingSameTypeTogether(_ sources: [MusicSource]) -> [MusicSource] {
        var firstIndex: [MusicSourceType: Int] = [:]
        for (index, source) in sources.enumerated() where firstIndex[source.type] == nil {
            firstIndex[source.type] = index
        }
        return sources.enumerated().sorted { lhs, rhs in
            let lhsGroup = firstIndex[lhs.element.type] ?? lhs.offset
            let rhsGroup = firstIndex[rhs.element.type] ?? rhs.offset
            return lhsGroup != rhsGroup ? lhsGroup < rhsGroup : lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    /// 同类型、地址也一样的几个源(同一台 NAS 上的两个账号、同一个网盘的两个账号),
    /// 卡片上只看类型和地址分不开,要把账号带出来。
    public static func sourceIDsShowingAccount(_ sources: [MusicSource]) -> Set<String> {
        let groups = Dictionary(grouping: sources) { source in
            "\(source.type.rawValue)|\(source.connectionSummary ?? "")"
        }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }

    /// 卡片上写哪条线路:正在用的,其次上次连上的,再其次手动选定的,都没有时写第一条。
    public static func displayedRoute(
        candidates: [SourceConnectionCandidate],
        active: SourceConnectionCandidateKind?,
        lastSuccessful: SourceConnectionCandidateKind?,
        selected: SourceConnectionCandidateKind?
    ) -> SourceConnectionCandidate? {
        for kind in [active, lastSuccessful, selected].compactMap({ $0 }) {
            if let candidate = candidates.first(where: { $0.kind == kind }) {
                return candidate
            }
        }
        return candidates.first
    }
}
