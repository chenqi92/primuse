#if os(iOS)
import Foundation
import Observation
import PrimuseKit
import StoreKit

/// 已解锁样式的权益来源:向商店查询、发起解锁、恢复,并把结果交给 `SkinRuntime`。
///
/// `SkinRuntime` 只认一个集合(哪些 `unlockID` 已解锁),不知道它从哪来。来源集中在这里,
/// 以后换一种发放方式,界面与样式定义都不用动。
///
/// 目录里没有需要解锁的样式时,这里不会向商店发出任何请求。
@MainActor
@Observable
final class SkinUnlockStore {
    /// 详情页上要展示的解锁项,`label` 是商店给出的本地化标注。
    struct Offer: Equatable, Sendable {
        let unlockID: String
        let productID: String
        let label: String
    }

    enum Activity: Equatable, Sendable {
        case idle
        case working
        /// 已提交,等待批准(例如家人共享里需要家长同意)。批准后会经交易更新自动解锁。
        case pending
        case failed
    }

    private(set) var offers: [String: Offer] = [:]
    private(set) var activity: [String: Activity] = [:]
    private(set) var isLoadingOffers = false
    private(set) var isRestoring = false

    @ObservationIgnored private let runtime: SkinRuntime
    @ObservationIgnored private var products: [String: Product] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private let defaults: UserDefaults
    private static let developerUnlockedIDsKey = "primuse.skin.developerUnlockedIDs"
    #endif

    init(runtime: SkinRuntime, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        #if DEBUG
        self.defaults = defaults
        #endif
    }

    /// 要向商店查询的产品。目录里没有需要解锁的样式时为空,启动、刷新、加载解锁项、恢复都据此直接返回。
    var productIDs: [String] {
        SkinUnlockProductPolicy.productIDs(for: runtime.catalog)
    }

    /// 这条链路是不是休眠的:目录里没有需要解锁的样式,就一个请求都不向商店发。
    var isDormant: Bool { productIDs.isEmpty }

    func activity(for unlockID: String) -> Activity {
        activity[unlockID] ?? .idle
    }

    func offer(for skin: SkinDefinition) -> Offer? {
        skin.access.unlockID.flatMap { offers[$0] }
    }

    // MARK: - 启动

    /// 读取已有的权益,并在整个运行期间监听交易更新(别的设备上完成的解锁、批准、撤销)。
    func start() {
        guard updatesTask == nil, !productIDs.isEmpty else { return }
        updatesTask = Task { [weak self] in
            await self?.refreshEntitlements()
            for await update in StoreKit.Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
    }

    func refreshEntitlements() async {
        guard !productIDs.isEmpty else { return }
        var owned: Set<String> = []
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.revocationDate == nil else { continue }
            owned.insert(transaction.productID)
        }
        apply(ownedProductIDs: owned)
    }

    private func apply(ownedProductIDs: Set<String>) {
        var unlocked = SkinUnlockProductPolicy.unlockedIDs(
            ownedProductIDs: ownedProductIDs,
            catalog: runtime.catalog
        )
        #if DEBUG
        unlocked.formUnion(developerUnlockedIDs)
        #endif
        runtime.updateEntitlements(unlocked: unlocked)
    }

    // MARK: - 解锁项

    func loadOffers() async {
        let ids = productIDs
        guard !ids.isEmpty, !isLoadingOffers else { return }
        isLoadingOffers = true
        defer { isLoadingOffers = false }
        guard let loaded = try? await Product.products(for: ids) else { return }

        var productsByID: [String: Product] = [:]
        for product in loaded { productsByID[product.id] = product }
        products = productsByID

        var resolved: [String: Offer] = [:]
        for unlockID in SkinUnlockProductPolicy.unlockIDs(in: runtime.catalog) {
            let productID = SkinUnlockProductPolicy.productID(forUnlockID: unlockID)
            guard let product = productsByID[productID] else { continue }
            resolved[unlockID] = Offer(
                unlockID: unlockID,
                productID: productID,
                label: product.displayPrice
            )
        }
        offers = resolved
    }

    /// 发起解锁。返回 true 表示这套样式现在可以使用了。
    @discardableResult
    func unlock(_ skin: SkinDefinition) async -> Bool {
        guard let unlockID = skin.access.unlockID else { return true }
        if runtime.unlockedIDs.contains(unlockID) { return true }
        guard let offer = offers[unlockID], let product = products[offer.productID] else {
            activity[unlockID] = .failed
            return false
        }

        activity[unlockID] = .working
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    activity[unlockID] = .failed
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                activity[unlockID] = .idle
                return runtime.unlockedIDs.contains(unlockID)
            case .pending:
                activity[unlockID] = .pending
                return false
            case .userCancelled:
                activity[unlockID] = .idle
                return false
            @unknown default:
                activity[unlockID] = .idle
                return false
            }
        } catch {
            activity[unlockID] = .failed
            return false
        }
    }

    /// 恢复:换了设备或重装之后,把已有的解锁同步回来。
    func restore() async {
        guard !productIDs.isEmpty, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - 开发构建

    #if DEBUG
    private var developerUnlockedIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.developerUnlockedIDsKey) ?? [])
    }

    /// 开发构建里没有配置商店产品时,直接在本机解锁,便于在真机上核对样式。
    func developerUnlock(_ unlockID: String) {
        let unlocked = developerUnlockedIDs.union([unlockID])
        defaults.set(Array(unlocked).sorted(), forKey: Self.developerUnlockedIDsKey)
        runtime.updateEntitlements(unlocked: runtime.unlockedIDs.union(unlocked))
    }
    #endif
}
#endif
