import Foundation
import Observation
import PrimuseKit

/// 电台清单订阅的定义，以及每台设备自己的刷新状态。
///
/// - 定义(`RadioSubscription`)存 UserDefaults，经 `CloudKVSSync` 镜像到 iCloud 键值存储。
///   体积很小，受「设置」同步开关控制 —— 关掉时订阅只在本机；电台本身照常经
///   CloudKit 同步，别的设备只是看不到订阅管理，不会出错。
/// - 刷新状态(`RadioSubscriptionRefreshStatus`)另存一个本机键，不同步：退避、错误、
///   待确认的移除都是这台设备自己的事。
///
/// 电台里挂着本机不认识的 `subscriptionID`(别的设备订阅了、定义还没同步过来，
/// 或者这边关了设置同步)也没关系：它们照常显示为订阅电台，只是本机没法管理。
@MainActor
@Observable
final class RadioSubscriptionsStore {
    static let shared = RadioSubscriptionsStore()

    static let storageKey = CloudKVSKey.radioSubscriptions
    static let statusStorageKey = "primuse_radio_subscription_status_v1"

    private(set) var subscriptions: [RadioSubscription] = []
    private(set) var statuses: [String: RadioSubscriptionRefreshStatus] = [:]

    private let defaults: UserDefaults
    private let syncsThroughICloud: Bool

    init(defaults: UserDefaults = .standard, syncsThroughICloud: Bool? = nil) {
        self.defaults = defaults
        self.syncsThroughICloud = syncsThroughICloud ?? (defaults === UserDefaults.standard)
        subscriptions = Self.loadSubscriptions(from: defaults)
        statuses = Self.loadStatuses(from: defaults)
        reconcileStatuses()
        if self.syncsThroughICloud {
            CloudKVSSync.shared.register(key: Self.storageKey) { [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    // MARK: - 读取

    func subscription(id: String?) -> RadioSubscription? {
        guard let id else { return nil }
        return subscriptions.first { $0.id == id }
    }

    func status(for id: String) -> RadioSubscriptionRefreshStatus {
        statuses[id] ?? RadioSubscriptionRefreshStatus()
    }

    /// 名称排序后的订阅，列表页用。
    var sortedSubscriptions: [RadioSubscription] {
        subscriptions.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// 有订阅上次刷新失败，或者有等用户确认的移除。
    var needsAttention: Bool {
        subscriptions.contains { subscription in
            let status = status(for: subscription.id)
            return status.hasFailure || !status.heldRemovalStationIDs.isEmpty
        }
    }

    /// 所有订阅里最近一次成功刷新的时间(任意设备)。
    var latestRefreshDate: Date? {
        subscriptions.compactMap { subscription in
            [subscription.lastRefreshedAt, status(for: subscription.id).lastSuccessAt]
                .compactMap { $0 }
                .max()
        }.max()
    }

    // MARK: - 写入

    /// 本机新建的订阅。首轮合并的结果一并记进本机状态。
    func add(
        _ subscription: RadioSubscription,
        summary: RadioSubscriptionRefreshSummary?,
        heldRemovalStationIDs: [String],
        now: Date = Date()
    ) {
        guard self.subscription(id: subscription.id) == nil else { return }
        subscriptions.append(subscription)
        statuses[subscription.id] = RadioSubscriptionRefreshStatus(
            firstSeenAt: now,
            createdLocally: true,
            lastAttemptAt: now,
            lastSuccessAt: summary == nil ? nil : now,
            lastSummary: summary,
            heldRemovalStationIDs: heldRemovalStationIDs
        )
        persistSubscriptions()
        persistStatuses()
    }

    func remove(id: String) {
        let kept = subscriptions.filter { $0.id != id }
        guard kept.count != subscriptions.count else { return }
        subscriptions = kept
        statuses.removeValue(forKey: id)
        persistSubscriptions()
        persistStatuses()
    }

    /// 改订阅定义。`touchesDefinition` 为假时不动 `modifiedAt` —— 写回
    /// `lastRefreshedAt` 这种事不算用户改了订阅。
    func update(
        id: String,
        touchesDefinition: Bool = true,
        mutate: (inout RadioSubscription) -> Void
    ) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        var next = subscriptions[index]
        mutate(&next)
        next.id = subscriptions[index].id
        guard next != subscriptions[index] else { return }
        if touchesDefinition { next.modifiedAt = Date() }
        subscriptions[index] = next
        persistSubscriptions()
    }

    func updateStatus(id: String, mutate: (inout RadioSubscriptionRefreshStatus) -> Void) {
        guard subscription(id: id) != nil else { return }
        var next = status(for: id)
        mutate(&next)
        guard next != statuses[id] else { return }
        statuses[id] = next
        persistStatuses()
    }

    // MARK: - 同步

    /// 别的设备改了订阅列表。
    private func reloadFromDefaults() {
        let incoming = Self.loadSubscriptions(from: defaults)
        guard incoming != subscriptions else { return }
        subscriptions = incoming
        reconcileStatuses()
    }

    /// 让本机状态和定义对齐：新出现的订阅(从别的设备同步来的)记下第一次见到的
    /// 时间，用于首次自动刷新的宽限；已经不存在的订阅，本机状态随之清理。
    private func reconcileStatuses(now: Date = Date()) {
        let ids = Set(subscriptions.map(\.id))
        var next = statuses.filter { ids.contains($0.key) }
        for id in ids where next[id] == nil {
            next[id] = RadioSubscriptionRefreshStatus(firstSeenAt: now, createdLocally: false)
        }
        guard next != statuses else { return }
        statuses = next
        persistStatuses()
    }

    private func persistSubscriptions() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        defaults.set(data, forKey: Self.storageKey)
        if syncsThroughICloud {
            CloudKVSSync.shared.markChanged(key: Self.storageKey)
        }
    }

    private func persistStatuses() {
        guard let data = try? JSONEncoder().encode(statuses) else { return }
        defaults.set(data, forKey: Self.statusStorageKey)
    }

    private static func loadSubscriptions(from defaults: UserDefaults) -> [RadioSubscription] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RadioSubscription].self, from: data) else {
            return []
        }
        // 同一个 id 只留第一份：两台设备各自订阅同一个地址得到的是同一个 id。
        var seen = Set<String>()
        return decoded.filter { seen.insert($0.id).inserted }
    }

    private static func loadStatuses(
        from defaults: UserDefaults
    ) -> [String: RadioSubscriptionRefreshStatus] {
        guard let data = defaults.data(forKey: statusStorageKey),
              let decoded = try? JSONDecoder().decode(
                  [String: RadioSubscriptionRefreshStatus].self,
                  from: data
              ) else {
            return [:]
        }
        return decoded
    }
}
