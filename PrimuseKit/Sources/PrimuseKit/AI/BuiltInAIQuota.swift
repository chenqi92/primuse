import Foundation

/// 内置 AI 的额度:每个功能今天和本月用了多少、上限多少、还剩多少,以及活动加量
/// 或内测套餐多给了多少。
///
/// 中转在每次功能调用的回复里(`usage.quota`)和额度不足的拒绝里(`error.quota`)
/// 给出这个功能扣完之后的数字,用量接口一次给出全部功能。设置页先用用量接口铺满,
/// 之后每次调用的回复把对应那一行换成最新的,不用另外再问。
public struct BuiltInAIQuotaCounter: Equatable, Sendable {
    public var used: Int
    public var limit: Int
    public var remaining: Int
    /// 什么时候重置:每天是下一个 UTC 零点,每月是这个周期结束。
    public var resetsAt: Date?
    /// 没有活动加量或内测套餐时的上限;只在被提高时有。
    public var baseLimit: Int?

    public init(used: Int, limit: Int, remaining: Int? = nil, resetsAt: Date? = nil, baseLimit: Int? = nil) {
        self.used = max(0, used)
        self.limit = max(0, limit)
        self.remaining = max(0, remaining ?? limit - used)
        self.resetsAt = resetsAt
        self.baseLimit = baseLimit.flatMap { $0 < limit ? max(0, $0) : nil }
    }

    /// 加量或内测多给的次数。
    public var bonus: Int {
        baseLimit.map { max(0, limit - $0) } ?? 0
    }

    public var isExhausted: Bool {
        limit > 0 && remaining == 0
    }

    public var fractionUsed: Double {
        limit > 0 ? min(1, Double(used) / Double(limit)) : 0
    }
}

/// 当前额度从哪来。
public enum BuiltInAIPlanSource: String, Equatable, Sendable {
    case free = "free_installation"
    case subscription = "app_store_subscription"
    case grant = "manual"
    case testflight
    case unknown

    init(wire: String?) {
        self = wire.flatMap(BuiltInAIPlanSource.init(rawValue:)) ?? .unknown
    }
}

/// 把上限提高了的东西:限时加量(活动),或 TestFlight 内测套餐。
public struct BuiltInAIQuotaBonus: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case boost
        case testflight
        case other
    }

    public var kind: Kind
    public var displayName: String
    /// 限时加量的结束时间;内测套餐没有。
    public var endsAt: Date?

    public init(kind: Kind, displayName: String, endsAt: Date? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.endsAt = endsAt
    }
}

/// 一次功能调用之后,这个功能还剩多少。
public struct BuiltInAIFeatureQuota: Equatable, Sendable {
    public var feature: String
    public var planID: String?
    public var source: BuiltInAIPlanSource
    public var today: BuiltInAIQuotaCounter?
    public var totalToday: BuiltInAIQuotaCounter?
    public var creditsToday: BuiltInAIQuotaCounter?
    /// 只在套餐给这个功能设了每月上限时有。
    public var month: BuiltInAIQuotaCounter?
    public var totalMonth: BuiltInAIQuotaCounter?
    public var bonuses: [BuiltInAIQuotaBonus]

    public init(
        feature: String,
        planID: String? = nil,
        source: BuiltInAIPlanSource = .unknown,
        today: BuiltInAIQuotaCounter? = nil,
        totalToday: BuiltInAIQuotaCounter? = nil,
        creditsToday: BuiltInAIQuotaCounter? = nil,
        month: BuiltInAIQuotaCounter? = nil,
        totalMonth: BuiltInAIQuotaCounter? = nil,
        bonuses: [BuiltInAIQuotaBonus] = []
    ) {
        self.feature = feature
        self.planID = planID
        self.source = source
        self.today = today
        self.totalToday = totalToday
        self.creditsToday = creditsToday
        self.month = month
        self.totalMonth = totalMonth
        self.bonuses = bonuses
    }

    /// `usage.quota` 或 `error.quota` 的 JSON;认不出就是 nil,不影响回复本身。
    public static func decode(_ data: Data) -> BuiltInAIFeatureQuota? {
        try? JSONDecoder().decode(BuiltInAIFeatureQuota.self, from: data)
    }
}

extension BuiltInAIFeatureQuota: Decodable {
    public init(from decoder: any Decoder) throws {
        let wire = try WireFeatureQuota(from: decoder)
        guard !wire.feature.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "feature missing"))
        }
        self.init(
            feature: wire.feature,
            planID: wire.planID,
            source: BuiltInAIPlanSource(wire: wire.source),
            today: wire.today?.counter(),
            totalToday: wire.totalToday?.counter(),
            creditsToday: wire.creditsToday?.counter(),
            month: wire.month?.counter(),
            totalMonth: wire.totalMonth?.counter(),
            bonuses: (wire.bonuses ?? []).compactMap { $0.bonus() }
        )
    }
}

/// 用量接口回复里的 `data`,原样留着,要显示时再换成 `BuiltInAIQuotaOverview`。
public struct BuiltInAIUsageReport: Decodable, Sendable {
    fileprivate let wire: WireUsage

    public init(from decoder: any Decoder) throws {
        wire = try WireUsage(from: decoder)
    }

    public func overview(at date: Date) -> BuiltInAIQuotaOverview {
        BuiltInAIQuotaOverview(report: wire, at: date)
    }
}

/// 用量接口给出的全部额度,再叠上之后每次调用回复里的最新数字。
public struct BuiltInAIQuotaOverview: Equatable, Sendable {
    public struct Feature: Equatable, Sendable, Identifiable {
        public var id: String
        /// 中转给的名字(后台建的自定义接口);内置功能由 App 自己命名。
        public var name: String?
        public var today: BuiltInAIQuotaCounter
        public var month: BuiltInAIQuotaCounter?
        public var bonuses: [BuiltInAIQuotaBonus]

        public init(
            id: String,
            name: String? = nil,
            today: BuiltInAIQuotaCounter,
            month: BuiltInAIQuotaCounter? = nil,
            bonuses: [BuiltInAIQuotaBonus] = []
        ) {
            self.id = id
            self.name = name
            self.today = today
            self.month = month
            self.bonuses = bonuses
        }
    }

    public var planID: String?
    public var planName: String?
    public var source: BuiltInAIPlanSource
    /// 订阅、授予的套餐什么时候到期;免费额度没有。
    public var planExpiresAt: Date?
    /// 今天所有功能合计。
    public var today: BuiltInAIQuotaCounter?
    public var credits: BuiltInAIQuotaCounter?
    /// 本月所有功能合计;套餐没设月上限时为 nil。
    public var month: BuiltInAIQuotaCounter?
    public var bonuses: [BuiltInAIQuotaBonus]
    public var features: [Feature]
    public var updatedAt: Date

    public init(
        planID: String? = nil,
        planName: String? = nil,
        source: BuiltInAIPlanSource = .unknown,
        planExpiresAt: Date? = nil,
        today: BuiltInAIQuotaCounter? = nil,
        credits: BuiltInAIQuotaCounter? = nil,
        month: BuiltInAIQuotaCounter? = nil,
        bonuses: [BuiltInAIQuotaBonus] = [],
        features: [Feature] = [],
        updatedAt: Date
    ) {
        self.planID = planID
        self.planName = planName
        self.source = source
        self.planExpiresAt = planExpiresAt
        self.today = today
        self.credits = credits
        self.month = month
        self.bonuses = bonuses
        self.features = features
        self.updatedAt = updatedAt
    }

    /// 只有一次调用的回复时,先用它这一行开个头。
    public init(quota: BuiltInAIFeatureQuota, at date: Date) {
        self.init(updatedAt: date)
        self = applying(quota, at: date)
    }

    /// 用量接口回复里的 `data`。早于额度反馈的中转只给每个功能的已用和上限,
    /// 剩余照算,加量从套餐的 `boost.base` 推出来。
    public static func decode(usageData data: Data, at date: Date) -> BuiltInAIQuotaOverview? {
        (try? JSONDecoder().decode(BuiltInAIUsageReport.self, from: data))?.overview(at: date)
    }

    fileprivate init(report wire: WireUsage, at date: Date) {
        let boost = wire.plan?.boost
        let boostBonus = boost.map {
            BuiltInAIQuotaBonus(kind: .boost, displayName: $0.displayName ?? "", endsAt: $0.endsAt.map(Date.init(timeIntervalSince1970:)))
        }
        let bonuses = wire.today?.bonuses.map { $0.compactMap { $0.bonus() } }
            ?? (boostBonus.map { [$0] } ?? [])
        let dayEnds = wire.today?.resetsAt.map(Date.init(timeIntervalSince1970:))
        let monthEnds = wire.period?.endsAt.map(Date.init(timeIntervalSince1970:))
        let paused = Set(boost?.pausedFeatures ?? [])
        let features: [Feature] = (wire.today?.features ?? [:]).map { id, counter in
            // An older relay has no base on the row: the boost's own figure stands in.
            let base = counter.baseLimit
                ?? (paused.contains(id) ? nil : boost?.base?.features?[id])
            let rowBonuses = counter.bonuses.map { $0.compactMap { $0.bonus() } }
                ?? bonuses.filter { $0.kind != .boost || !paused.contains(id) }
            return Feature(
                id: id,
                name: counter.name,
                today: counter.counter(fallbackResetsAt: dayEnds, fallbackBase: base),
                month: wire.period?.features?[id]?.counter(fallbackResetsAt: monthEnds),
                bonuses: rowBonuses
            )
        }
        .sorted { $0.id < $1.id }
        let today = wire.today.flatMap { today -> BuiltInAIQuotaCounter? in
            guard let limit = today.requestLimit else { return nil }
            return BuiltInAIQuotaCounter(
                used: today.requests ?? 0,
                limit: limit,
                remaining: today.remaining,
                resetsAt: dayEnds,
                baseLimit: today.baseRequestLimit ?? boost?.base?.dailyRequestLimit
            )
        }
        let credits = wire.today.flatMap { today -> BuiltInAIQuotaCounter? in
            guard let limit = today.creditLimit else { return nil }
            return BuiltInAIQuotaCounter(
                used: Int(today.credits ?? 0),
                limit: Int(limit),
                remaining: today.creditsRemaining.map { Int($0) },
                resetsAt: dayEnds,
                baseLimit: today.baseCreditLimit.map { Int($0) } ?? boost?.base?.dailyCredits.map { Int($0) }
            )
        }
        let month = wire.period.flatMap { period -> BuiltInAIQuotaCounter? in
            guard let limit = period.requestLimit else { return nil }
            return BuiltInAIQuotaCounter(
                used: period.requests ?? 0,
                limit: limit,
                remaining: period.remaining,
                resetsAt: monthEnds
            )
        }
        self.init(
            planID: wire.plan?.id,
            planName: wire.plan?.displayName,
            source: BuiltInAIPlanSource(wire: wire.plan?.source),
            planExpiresAt: wire.plan?.expiresAt.map(Date.init(timeIntervalSince1970:)),
            today: today,
            credits: credits,
            month: month,
            bonuses: bonuses,
            features: features,
            updatedAt: date
        )
    }

    /// 换上一次调用之后的最新数字:这一行、今天和本月的合计。
    public func applying(_ quota: BuiltInAIFeatureQuota, at date: Date) -> BuiltInAIQuotaOverview {
        var next = self
        next.updatedAt = date
        next.planID = quota.planID ?? planID
        if quota.source != .unknown { next.source = quota.source }
        if let total = quota.totalToday { next.today = total }
        if let credits = quota.creditsToday { next.credits = credits }
        if let month = quota.totalMonth { next.month = month }
        if let today = quota.today {
            if let index = next.features.firstIndex(where: { $0.id == quota.feature }) {
                next.features[index].today = today
                next.features[index].month = quota.month ?? next.features[index].month
                next.features[index].bonuses = quota.bonuses
            } else {
                next.features.append(Feature(id: quota.feature, today: today, month: quota.month, bonuses: quota.bonuses))
            }
        }
        return next
    }

    /// 过了重置时间,今天的数字已经不作数,要重新问。
    public func isStale(now: Date) -> Bool {
        let resets = today?.resetsAt ?? features.compactMap(\.today.resetsAt).min()
        return resets.map { now >= $0 } ?? false
    }

    /// 按 App 认识的顺序排,认不出的(自定义接口)排在后面、按名字排。
    public func orderedFeatures(preferredOrder: [String]) -> [Feature] {
        let rank = Dictionary(uniqueKeysWithValues: preferredOrder.enumerated().map { ($1, $0) })
        return features.sorted { left, right in
            switch (rank[left.id], rank[right.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (left.name ?? left.id) < (right.name ?? right.id)
            }
        }
    }
}

// MARK: - Wire format

private struct WireCounter: Decodable, Sendable {
    var requests: Int?
    var limit: Int?
    var remaining: Int?
    var resetsAt: Double?
    var baseLimit: Int?
    var name: String?
    var bonuses: [WireBonus]?

    enum CodingKeys: String, CodingKey {
        case requests
        case limit
        case remaining
        case resetsAt = "resets_at"
        case baseLimit = "base_limit"
        case name
        case bonuses
    }

    func counter(fallbackResetsAt: Date? = nil, fallbackBase: Int? = nil) -> BuiltInAIQuotaCounter {
        BuiltInAIQuotaCounter(
            used: requests ?? 0,
            limit: limit ?? 0,
            remaining: remaining,
            resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:)) ?? fallbackResetsAt,
            baseLimit: baseLimit ?? fallbackBase
        )
    }
}

private struct WireBonus: Decodable, Sendable {
    var kind: String
    var displayName: String?
    var endsAt: Double?

    enum CodingKeys: String, CodingKey {
        case kind
        case displayName = "display_name"
        case endsAt = "ends_at"
    }

    func bonus() -> BuiltInAIQuotaBonus? {
        BuiltInAIQuotaBonus(
            kind: BuiltInAIQuotaBonus.Kind(rawValue: kind) ?? .other,
            displayName: displayName ?? "",
            endsAt: endsAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private struct WireFeatureQuota: Decodable, Sendable {
    var feature: String
    var planID: String?
    var source: String?
    var today: WireCounter?
    var totalToday: WireCounter?
    var creditsToday: WireCounter?
    var month: WireCounter?
    var totalMonth: WireCounter?
    var bonuses: [WireBonus]?

    enum CodingKeys: String, CodingKey {
        case feature
        case planID = "plan_id"
        case source
        case today
        case totalToday = "total_today"
        case creditsToday = "credits_today"
        case month
        case totalMonth = "total_month"
        case bonuses
    }
}

private struct WireUsage: Decodable, Sendable {
    struct Plan: Decodable, Sendable {
        struct Boost: Decodable, Sendable {
            struct Base: Decodable, Sendable {
                var dailyRequestLimit: Int?
                var dailyCredits: Double?
                var features: [String: Int]?

                enum CodingKeys: String, CodingKey {
                    case dailyRequestLimit = "daily_request_limit"
                    case dailyCredits = "daily_credits"
                    case features
                }
            }

            var displayName: String?
            var endsAt: Double?
            var pausedFeatures: [String]?
            var base: Base?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case endsAt = "ends_at"
                case pausedFeatures = "paused_features"
                case base
            }
        }

        var id: String?
        var displayName: String?
        var source: String?
        var expiresAt: Double?
        var boost: Boost?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case source
            case expiresAt = "expires_at"
            case boost
        }
    }

    struct Today: Decodable, Sendable {
        var resetsAt: Double?
        var requests: Int?
        var requestLimit: Int?
        var remaining: Int?
        var baseRequestLimit: Int?
        var credits: Double?
        var creditLimit: Double?
        var creditsRemaining: Double?
        var baseCreditLimit: Double?
        var bonuses: [WireBonus]?
        var features: [String: WireCounter]?

        enum CodingKeys: String, CodingKey {
            case resetsAt = "resets_at"
            case requests
            case requestLimit = "request_limit"
            case remaining
            case baseRequestLimit = "base_request_limit"
            case credits
            case creditLimit = "credit_limit"
            case creditsRemaining = "credits_remaining"
            case baseCreditLimit = "base_credit_limit"
            case bonuses
            case features
        }
    }

    struct Period: Decodable, Sendable {
        var endsAt: Double?
        var requests: Int?
        var requestLimit: Int?
        var remaining: Int?
        var features: [String: WireCounter]?

        enum CodingKeys: String, CodingKey {
            case endsAt = "ends_at"
            case requests
            case requestLimit = "request_limit"
            case remaining
            case features
        }
    }

    var plan: Plan?
    var today: Today?
    var period: Period?
}
