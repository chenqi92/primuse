import Foundation
import Observation
import PrimuseKit

/// 首次订阅的结果。
struct RadioSubscriptionSubscribeResult: Sendable {
    let subscriptionID: String
    /// 这个地址本来就订阅过：没有新建，改为在后台刷新一次。
    let alreadySubscribed: Bool
    let summary: RadioSubscriptionRefreshSummary?
    let addedStationIDs: [String]
}

/// 一次刷新的结果。界面据此给行内反馈，不弹一堆 alert。
enum RadioSubscriptionRefreshOutcome: Equatable, Sendable {
    case success(RadioSubscriptionRefreshSummary)
    case failure(String)
    /// 清单地址是明文 http，而这台设备还没有(或不再)信任这个主机。
    /// 后台刷新只记错误；用户手动刷新时界面可以借此再问一次。
    case permissionRequired(host: String)
    case cancelled
}

/// 电台清单订阅的刷新与管理。
///
/// - 下载 → 解析 → 按 `RadioSubscriptionMergePolicy` 合并 → 一次写回电台库。
/// - 失败只记状态，不动电台；成功才把 `lastRefreshedAt` 写回订阅定义(跨设备同步)。
/// - 单飞：同一份订阅同时只有一个刷新在跑，后来的调用等同一个结果。
/// - 自动刷新：启动后等一会儿、以及每次回到前台时，按
///   `RadioSubscriptionRefreshSchedule` 把到期的订阅逐个串行刷新。
@MainActor
@Observable
final class RadioSubscriptionService {
    static let shared = RadioSubscriptionService()

    /// 正在刷新的订阅。界面据此显示进度。
    private(set) var refreshingIDs: Set<String> = []

    @ObservationIgnored private var inFlight: [String: (token: UUID, task: Task<RadioSubscriptionRefreshOutcome, Never>)] = [:]
    @ObservationIgnored private var dueRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var dueRefreshToken: UUID?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// 启动后的等待结束之前，回到前台的触发一律不算数 —— 冷启动时「变为活跃」
    /// 的通知会先于这里到来，那时正是最不该抢网络的时候。
    @ObservationIgnored private var automaticRefreshAllowed = false

    private var subscriptions: RadioSubscriptionsStore { .shared }
    private var stationsStore: RadioStationsStore { AppServices.shared.radioStationsStore }

    func isRefreshing(_ id: String) -> Bool {
        refreshingIDs.contains(id)
    }

    // MARK: - 订阅

    /// 用批量添加页**已经取回的**候选直接做首轮合并，不再下载一遍。
    ///
    /// 同一个地址已经订阅过(id 相同)时不重复建，按一次手动刷新处理。
    /// 清单里一个可用条目都没有时返回 nil，什么都不改。
    @discardableResult
    func subscribe(
        listURL: String,
        name: String? = nil,
        candidates: [RadioImportCandidate],
        excludedEntryKeys: Set<String>,
        usesListGroupsAsFolders: Bool
    ) -> RadioSubscriptionSubscribeResult? {
        let now = Date()
        guard var subscription = RadioSubscription.make(
            listURL: listURL,
            name: name,
            usesListGroupsAsFolders: usesListGroupsAsFolders,
            now: now
        ) else { return nil }

        if subscriptions.subscription(id: subscription.id) != nil {
            let id = subscription.id
            Task { _ = await self.refresh(id: id) }
            return RadioSubscriptionSubscribeResult(
                subscriptionID: id,
                alreadySubscribed: true,
                summary: nil,
                addedStationIDs: []
            )
        }

        let plan: RadioSubscriptionRefreshPlan
        do {
            plan = try RadioSubscriptionMergePolicy.merge(
                subscription: subscription,
                candidates: candidates,
                stations: stationsStore.allStations,
                newlyExcludedEntryKeys: excludedEntryKeys,
                now: now
            )
        } catch {
            plog("📻 Radio subscription \(Self.logLabel(subscription)) not created: \(error)")
            return nil
        }

        subscription.lastRefreshedAt = now
        subscriptions.add(
            subscription,
            summary: plan.summary,
            heldRemovalStationIDs: plan.heldRemovalStationIDs,
            now: now
        )
        stationsStore.applySubscriptionChanges(plan.changes)
        discoverLogos(for: plan.addedStationIDs)
        plog("📻 Radio subscription \(Self.logLabel(subscription)) created: \(Self.logSummary(plan.summary))")
        return RadioSubscriptionSubscribeResult(
            subscriptionID: subscription.id,
            alreadySubscribed: false,
            summary: plan.summary,
            addedStationIDs: plan.addedStationIDs
        )
    }

    // MARK: - 刷新

    /// 刷新一份订阅。手动「立即更新」直接调它，不受自动刷新的时间限制。
    @discardableResult
    func refresh(id: String, confirmingHeldRemovals: Bool = false) async -> RadioSubscriptionRefreshOutcome {
        if let running = inFlight[id] {
            return await running.task.value
        }
        guard subscriptions.subscription(id: id) != nil else { return .cancelled }

        let token = UUID()
        let task = Task { @MainActor [weak self] () -> RadioSubscriptionRefreshOutcome in
            guard let self else { return .cancelled }
            let outcome = await self.performRefresh(id: id, confirmingHeldRemovals: confirmingHeldRemovals)
            // 只清理自己那一轮：等待期间可能已经被取消、又开了新的一轮。
            if self.inFlight[id]?.token == token {
                self.inFlight[id] = nil
                self.refreshingIDs.remove(id)
            }
            return outcome
        }
        inFlight[id] = (token, task)
        refreshingIDs.insert(id)
        return await task.value
    }

    func cancelRefresh(id: String) {
        guard let running = inFlight.removeValue(forKey: id) else { return }
        running.task.cancel()
        refreshingIDs.remove(id)
    }

    private func performRefresh(
        id: String,
        confirmingHeldRemovals: Bool
    ) async -> RadioSubscriptionRefreshOutcome {
        guard let subscription = subscriptions.subscription(id: id) else { return .cancelled }
        let startedAt = Date()
        subscriptions.updateStatus(id: id) { $0.lastAttemptAt = startedAt }

        do {
            let text = try await RadioPlaylistDownloader.fetch(subscription.listURL)
            try Task.checkCancellation()
            // 下载期间订阅可能被取消、或者改了设置 —— 一律以现在的定义为准。
            guard let current = subscriptions.subscription(id: id) else { return .cancelled }
            let now = Date()
            let plan = try RadioSubscriptionMergePolicy.merge(
                subscription: current,
                candidates: RadioImportParser.parse(text, existing: []),
                stations: stationsStore.allStations,
                confirmsHeldRemovals: confirmingHeldRemovals,
                now: now
            )
            stationsStore.applySubscriptionChanges(plan.changes)
            discoverLogos(for: plan.addedStationIDs)
            subscriptions.update(id: id, touchesDefinition: false) { $0.lastRefreshedAt = now }
            subscriptions.updateStatus(id: id) { status in
                status.lastSuccessAt = now
                status.consecutiveFailures = 0
                status.lastErrorMessage = nil
                status.lastSummary = plan.summary
                status.heldRemovalStationIDs = plan.heldRemovalStationIDs
            }
            plog("📻 Radio subscription \(Self.logLabel(current)) refreshed: \(Self.logSummary(plan.summary))")
            return .success(plan.summary)
        } catch is CancellationError {
            return .cancelled
        } catch let error as TrustedHTTPTransportError {
            switch error {
            case .permissionRequired(let host):
                // 后台刷新不弹框，只记下来；用户在管理页手动更新时再问。
                recordFailure(
                    id: id,
                    message: String(
                        format: String(localized: "radio_subscription_error_permission %@"),
                        host
                    ),
                    subscription: subscription
                )
                return .permissionRequired(host: host)
            }
        } catch RadioSubscriptionMergeError.emptyList {
            let message = String(localized: "radio_subscription_error_empty")
            recordFailure(id: id, message: message, subscription: subscription)
            return .failure(message)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return .cancelled
            }
            let message = error.localizedDescription
            recordFailure(id: id, message: message, subscription: subscription)
            return .failure(message)
        }
    }

    private func recordFailure(id: String, message: String, subscription: RadioSubscription) {
        subscriptions.updateStatus(id: id) { status in
            status.consecutiveFailures += 1
            status.lastErrorMessage = message
        }
        plog("⚠️ Radio subscription \(Self.logLabel(subscription)) refresh failed: \(message)")
    }

    // MARK: - 自动刷新

    /// 启动流程里调一次。等一会儿再开始，别和启动抢网络。
    func startAfterLaunch(delay: Duration = .seconds(10)) {
        guard launchTask == nil else { return }
        launchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.automaticRefreshAllowed = true
            self.refreshDueSubscriptions()
        }
    }

    /// 回到前台时调。按 `RadioSubscriptionRefreshSchedule` 逐个串行刷新到期的订阅。
    func refreshDueSubscriptions() {
        guard automaticRefreshAllowed, dueRefreshTask == nil else { return }
        let due = dueSubscriptionIDs(now: Date())
        guard !due.isEmpty else { return }
        let token = UUID()
        dueRefreshToken = token
        dueRefreshTask = Task { [weak self] in
            for id in due {
                guard let self, !Task.isCancelled else { break }
                // 排队期间可能已经被手动刷新过，或者订阅被取消了，到点再判一次。
                guard self.dueSubscriptionIDs(now: Date()).contains(id) else { continue }
                _ = await self.refresh(id: id)
            }
            // 被取消之后可能已经开了新的一轮，那一轮的句柄不能被这里清掉。
            if self?.dueRefreshToken == token {
                self?.dueRefreshTask = nil
            }
        }
    }

    /// 进后台时调(iOS)。挂起中的下载多半会以网络错误收场，与其记成一次失败
    /// 再退避，不如现在就取消，回到前台时按到期规则重新来。
    func suspendForBackground() {
        dueRefreshTask?.cancel()
        dueRefreshTask = nil
        dueRefreshToken = nil
        for id in Array(inFlight.keys) {
            cancelRefresh(id: id)
        }
    }

    private func dueSubscriptionIDs(now: Date) -> [String] {
        subscriptions.subscriptions
            .filter {
                RadioSubscriptionRefreshSchedule.isDue(
                    subscription: $0,
                    status: subscriptions.status(for: $0.id),
                    now: now
                )
            }
            .map(\.id)
    }

    // MARK: - 管理

    /// 安全阀扣下的移除：`remove` 为真时带确认重新合并一遍(重新下载 —— 清单这期间
    /// 恢复了的话自然什么都不删)；否则把扣下的电台脱离订阅，变成用户自己的。
    @discardableResult
    func resolveHeldRemovals(id: String, remove: Bool) async -> RadioSubscriptionRefreshOutcome? {
        if remove {
            return await refresh(id: id, confirmingHeldRemovals: true)
        }
        let held = subscriptions.status(for: id).heldRemovalStationIDs
        stationsStore.applySubscriptionChanges(RadioSubscriptionMergePolicy.releasing(
            stationIDs: held,
            fromSubscription: id,
            stations: stationsStore.allStations
        ))
        subscriptions.updateStatus(id: id) { status in
            status.heldRemovalStationIDs = []
            if var summary = status.lastSummary {
                summary.kept += summary.held
                summary.held = 0
                status.lastSummary = summary
            }
        }
        return nil
    }

    func unsubscribe(id: String, keepStations: Bool) {
        cancelRefresh(id: id)
        stationsStore.unsubscribe(subscriptionID: id, keepStations: keepStations)
        subscriptions.remove(id: id)
        plog("📻 Radio subscription \(id) removed, keepStations=\(keepStations)")
    }

    func rename(id: String, to rawName: String) {
        let name = RadioStationValidation.normalizedName(rawName)
        guard !name.isEmpty else { return }
        subscriptions.update(id: id) { $0.name = name }
    }

    func setAutoUpdates(id: String, _ enabled: Bool) {
        subscriptions.update(id: id) { $0.autoUpdates = enabled }
    }

    func setUsesListGroupsAsFolders(id: String, _ enabled: Bool) {
        subscriptions.update(id: id) { $0.usesListGroupsAsFolders = enabled }
    }

    // MARK: - 内部

    private func discoverLogos(for stationIDs: [String]) {
        let stations = stationIDs.compactMap { stationsStore.station(id: $0) }
        guard !stations.isEmpty else { return }
        RadioLogoDiscoveryService.shared.discoverIfNeeded(for: stations)
    }

    /// 日志里只写名字和 host —— 清单地址的查询串里可能带 token。
    private static func logLabel(_ subscription: RadioSubscription) -> String {
        "'\(subscription.name)' @\(subscription.displayHost)"
    }

    private static func logSummary(_ summary: RadioSubscriptionRefreshSummary) -> String {
        "+\(summary.added) ~\(summary.updated) -\(summary.removed) kept \(summary.kept)"
            + " held \(summary.held) excluded \(summary.skippedExcluded)"
            + " inLibrary \(summary.skippedAlreadyInLibrary) of \(summary.totalEntries)"
            + (summary.truncated ? " (truncated)" : "")
    }
}
