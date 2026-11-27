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

    /// 卡片上展示的精简连接地址（去掉协议前缀与默认 80/443 端口），随当前激活线路联动。
    public static func compactAddress(
        for source: MusicSource,
        displayedRoute: SourceConnectionCandidate?
    ) -> String? {
        switch source.type {
        case .local, .appleMusic, .appleMusicLibrary:
            return nil
        default:
            break
        }
        if let route = displayedRoute {
            if let endpoint = route.endpoint {
                return compactEndpointDescription(endpoint)
            }
            if let identifier = route.vendorIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !identifier.isEmpty {
                return identifier
            }
        }
        if let host = source.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            if let port = source.port, port > 0 {
                return compactEndpointDescription(
                    SourceConnectionEndpoint(
                        host: host,
                        port: port,
                        useSsl: source.useSsl,
                        pathPrefix: source.basePath
                    )
                )
            }
            return compactRawAddress(host, pathPrefix: source.basePath)
        }
        if let summary = source.connectionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return compactRawAddress(summary, pathPrefix: nil)
        }
        return nil
    }

    public static func compactEndpointDescription(_ endpoint: SourceConnectionEndpoint) -> String {
        let normalized = endpoint.normalized
        let hostPart = normalized.urlHost
        let isDefaultPort = (normalized.useSsl && normalized.port == 443)
            || (!normalized.useSsl && normalized.port == 80)
            || normalized.port <= 0
        let portSuffix = isDefaultPort ? "" : ":\(normalized.port)"
        let path = normalized.pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathSuffix = trimmedPath.isEmpty ? "" : "/\(trimmedPath)"
        return "\(hostPart)\(portSuffix)\(pathSuffix)"
    }

    private static func compactRawAddress(_ raw: String, pathPrefix: String?) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()
        let isHTTPS = lower.hasPrefix("https://")
        let isHTTP = lower.hasPrefix("http://")
        if isHTTPS {
            cleaned.removeFirst("https://".count)
        } else if isHTTP {
            cleaned.removeFirst("http://".count)
        }
        while cleaned.count > 1, cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        if isHTTPS, cleaned.hasSuffix(":443") {
            cleaned.removeLast(":443".count)
        } else if isHTTP, cleaned.hasSuffix(":80") {
            cleaned.removeLast(":80".count)
        }
        if let pathPrefix {
            let trimmedPath = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmedPath.isEmpty, !cleaned.hasSuffix("/\(trimmedPath)") {
                cleaned += "/\(trimmedPath)"
            }
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
