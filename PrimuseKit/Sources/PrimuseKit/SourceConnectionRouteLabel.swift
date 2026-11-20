import Foundation

/// 音乐源一条线路的叫法。从预设里挑,不让人自己输入:存的是 rawValue,
/// 每台设备按自己的语言显示,也不会出现一长串手打的名字把卡片撑开。
public enum SourceConnectionRouteLabel: String, CaseIterable, Codable, Sendable, Identifiable {
    case lan
    case internet
    // 网络与连接
    case dataHog
    case lightSpeed
    case zenLoading
    case whenever
    case mayVanish
    case offlineLifeline
    // 来源与归属
    case homeCellar
    case godfathersStash
    case freeloaded
    case cloudFoster
    case inMyPocket
    case rentedTurf
    // 音质与听感
    case goldenEars
    case masterVault
    case justNoise
    case cyberVinyl
    case backgroundSnack
    // 曲库整洁度
    case moveInReady
    case bareShell
    case cyberBazaar
    case digSite
    case headphonesOnly
    // 使用场景
    case grindFuel
    case slackerSupply
    case carRave
    case trafficCalm
    case lateNightFeels
    case preWorkout

    public var id: String { rawValue }

    public var localizationKey: String { "source_route_label_" + rawValue }

    /// 内网直连、公网直连两个默认叫法不归哪一类,排在最前面。
    public var category: Category? {
        switch self {
        case .lan, .internet: nil
        case .dataHog, .lightSpeed, .zenLoading, .whenever, .mayVanish, .offlineLifeline: .network
        case .homeCellar, .godfathersStash, .freeloaded, .cloudFoster, .inMyPocket, .rentedTurf: .ownership
        case .goldenEars, .masterVault, .justNoise, .cyberVinyl, .backgroundSnack: .quality
        case .moveInReady, .bareShell, .cyberBazaar, .digSite, .headphonesOnly: .tidiness
        case .grindFuel, .slackerSupply, .carRave, .trafficCalm, .lateNightFeels, .preWorkout: .scene
        }
    }

    public var systemImage: String {
        switch self {
        case .lan: "wifi"
        case .internet: "globe"
        case .dataHog: "antenna.radiowaves.left.and.right"
        case .lightSpeed: "bolt.fill"
        case .zenLoading: "hourglass"
        case .whenever: "dice.fill"
        case .mayVanish: "figure.run"
        case .offlineLifeline: "airplane"
        case .homeCellar: "house.fill"
        case .godfathersStash: "crown.fill"
        case .freeloaded: "gift.fill"
        case .cloudFoster: "cloud.fill"
        case .inMyPocket: "iphone"
        case .rentedTurf: "building.columns.fill"
        case .goldenEars: "ear.fill"
        case .masterVault: "archivebox.fill"
        case .justNoise: "speaker.wave.2.fill"
        case .cyberVinyl: "opticaldisc"
        case .backgroundSnack: "fork.knife"
        case .moveInReady: "sparkles"
        case .bareShell: "hammer.fill"
        case .cyberBazaar: "bag.fill"
        case .digSite: "magnifyingglass"
        case .headphonesOnly: "headphones"
        case .grindFuel: "laptopcomputer"
        case .slackerSupply: "fish.fill"
        case .carRave: "car.fill"
        case .trafficCalm: "tortoise.fill"
        case .lateNightFeels: "moon.stars.fill"
        case .preWorkout: "flame.fill"
        }
    }

    /// 改名菜单里的分组。
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case network
        case ownership
        case quality
        case tidiness
        case scene

        public var id: String { rawValue }
        public var localizationKey: String { "source_route_category_" + rawValue }

        public var labels: [SourceConnectionRouteLabel] {
            SourceConnectionRouteLabel.allCases.filter { $0.category == self }
        }
    }
}

/// 线路叫什么、点一下换到哪一条。
public enum SourceConnectionRouteNamingPolicy {
    /// 没起过名字时:内网地址叫「内网」,公网地址叫「公网」。厂商中转(QuickConnect、FN Connect)
    /// 和另加的线路返回 nil,由界面写厂商名或「线路 N」。
    public static func defaultLabel(for kind: SourceConnectionCandidateKind) -> SourceConnectionRouteLabel? {
        switch kind {
        case .localAddress: .lan
        case .publicAddress: .internet
        case .vendorRemote, .alternative: nil
        }
    }

    /// 起过名字用起的名字,没起过用默认叫法。
    public static func label(
        for kind: SourceConnectionCandidateKind,
        custom: SourceConnectionRouteLabel?
    ) -> SourceConnectionRouteLabel? {
        custom ?? defaultLabel(for: kind)
    }

    /// 卡片上点一下线路:换到这条之后的那一条,最后一条之后回到第一条。
    /// 只有一条(或一条也没有)时没有可换的,返回 nil。
    public static func nextRoute(
        after current: SourceConnectionCandidateKind?,
        in candidates: [SourceConnectionCandidate]
    ) -> SourceConnectionCandidateKind? {
        guard candidates.count > 1 else { return nil }
        guard let current, let index = candidates.firstIndex(where: { $0.kind == current }) else {
            return candidates.first?.kind
        }
        return candidates[(index + 1) % candidates.count].kind
    }
}

/// 各源各条线路起的名字,整份是一段 JSON。只存改过的;挑回默认叫法时删掉那一条。
public struct SourceConnectionRouteLabels: Codable, Equatable, Sendable {
    public static let storageKey = "primuse_source_route_labels_v1"

    /// 源 ID → 线路(`SourceConnectionCandidateKind.rawValue`)→ 名字(`SourceConnectionRouteLabel.rawValue`)。
    public private(set) var labels: [String: [String: String]]

    public init(labels: [String: [String: String]] = [:]) {
        self.labels = labels
    }

    /// 新版本加的名字旧版本认不出来时当作没起过名字,不让整份读不出来。
    public func label(sourceID: String, kind: SourceConnectionCandidateKind) -> SourceConnectionRouteLabel? {
        labels[sourceID]?[kind.rawValue].flatMap(SourceConnectionRouteLabel.init(rawValue:))
    }

    public mutating func setLabel(
        _ label: SourceConnectionRouteLabel?,
        sourceID: String,
        kind: SourceConnectionCandidateKind
    ) {
        var routes = labels[sourceID] ?? [:]
        if let label, label != SourceConnectionRouteNamingPolicy.defaultLabel(for: kind) {
            routes[kind.rawValue] = label.rawValue
        } else {
            routes.removeValue(forKey: kind.rawValue)
        }
        labels[sourceID] = routes.isEmpty ? nil : routes
    }

    public mutating func removeSource(_ sourceID: String) {
        labels.removeValue(forKey: sourceID)
    }

    public static func decode(_ data: Data?) -> Self {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}
