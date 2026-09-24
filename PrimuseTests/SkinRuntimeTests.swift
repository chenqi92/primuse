import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 界面皮肤的运行时:从旧「极简模式」开关迁移、切换皮肤时镜像导航方式、不可用时回落、解锁链路。
/// 这些路径都发生在用户看不见的地方,而且只在升级那一次启动里走一遍,靠手测覆盖不到。
@MainActor
final class SkinRuntimeTests: XCTestCase {
    /// 测试里自己定义的一套待解锁皮肤。正式目录里只有随 App 提供的经典与极简,
    /// 解锁链路要靠它来走;它只换了一个 id,不会出现在任何构建里。
    private static let lockedFixture = SkinDefinition(
        id: "fixture-locked",
        nameKey: "skin.classic.name",
        descriptionKey: "skin.classic.description",
        appearance: .adaptive,
        pageBackground: .system,
        access: .unlockable(unlockID: "skin.fixture-locked"),
        colors: SkinCatalog.classic.colors,
        metrics: SkinCatalog.classic.metrics,
        typography: SkinCatalog.classic.typography,
        motion: SkinCatalog.classic.motion,
        shell: .tabBar
    )

    private static var catalogWithLockedFixture: [SkinDefinition] { SkinCatalog.all + [lockedFixture] }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SkinRuntimeTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testFreshInstallStartsOnClassic() {
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.classicID)
        XCTAssertEqual(defaults.string(forKey: SkinRuntime.selectedSkinKey), SkinCatalog.classicID)
        XCTAssertEqual(
            defaults.string(forKey: AppNavigationMode.storageKey),
            AppNavigationMode.standard.rawValue
        )
    }

    func testLegacyMinimalModeLandsOnTheMinimalSkin() {
        defaults.set(AppNavigationMode.minimal.rawValue, forKey: AppNavigationMode.storageKey)
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.minimalID)
        XCTAssertEqual(runtime.preferredSkinID, SkinCatalog.minimalID)
        XCTAssertEqual(defaults.string(forKey: SkinRuntime.selectedSkinKey), SkinCatalog.minimalID)
    }

    func testAnExplicitSkinChoiceIsNotOverwrittenByTheLegacyToggle() {
        defaults.set(SkinCatalog.classicID, forKey: SkinRuntime.selectedSkinKey)
        defaults.set(AppNavigationMode.minimal.rawValue, forKey: AppNavigationMode.storageKey)
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.classicID)
        // 旧开关被镜像回皮肤决定的导航方式。
        XCTAssertEqual(
            defaults.string(forKey: AppNavigationMode.storageKey),
            AppNavigationMode.standard.rawValue
        )
    }

    func testSelectingASkinMirrorsTheNavigationMode() {
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertTrue(runtime.select(SkinCatalog.minimalID))
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.minimalID)
        XCTAssertEqual(
            AppNavigationMode.resolve(defaults.string(forKey: AppNavigationMode.storageKey) ?? ""),
            .minimal
        )

        XCTAssertTrue(runtime.select(SkinCatalog.classicID))
        XCTAssertEqual(
            AppNavigationMode.resolve(defaults.string(forKey: AppNavigationMode.storageKey) ?? ""),
            .standard
        )
    }

    func testUnknownSkinIsRefusedAndTheCurrentOneStays() {
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertTrue(runtime.select(SkinCatalog.minimalID))
        XCTAssertFalse(runtime.select("from-a-future-build"))
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.minimalID)
        XCTAssertEqual(runtime.preferredSkinID, SkinCatalog.minimalID)
    }

    func testASyncedSkinThisBuildDoesNotHaveFallsBackToClassicButKeepsTheChoice() {
        defaults.set("from-a-future-build", forKey: SkinRuntime.selectedSkinKey)
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.classicID)
        XCTAssertEqual(runtime.preferredSkinID, "from-a-future-build")
        XCTAssertNil(runtime.enforcedColorScheme)
    }

    func testBuiltInSkinsFollowTheSystemAppearance() {
        let runtime = SkinRuntime(defaults: defaults)
        for skinID in [SkinCatalog.classicID, SkinCatalog.minimalID] {
            XCTAssertTrue(runtime.select(skinID))
            XCTAssertNil(runtime.enforcedColorScheme, "\(skinID) 不该锁定深浅色")
        }
    }

    // MARK: - 随皮肤的全屏效果

    func testTheMinimalSkinBringsItsOwnFullscreenEffectUntilTheUserPicksOne() {
        let runtime = SkinRuntime(defaults: defaults)
        // 经典没有建议的效果,全屏仍是原生播放页。
        XCTAssertEqual(runtime.effectiveFullscreenEffect(stored: .native, userSelected: false), .native)

        XCTAssertTrue(runtime.select(SkinCatalog.minimalID))
        XCTAssertEqual(runtime.effectiveFullscreenEffect(stored: .native, userSelected: false), .coverMosaic)
        // 亲手选回原生,或者已经在用别的效果,都不被皮肤覆盖。
        XCTAssertEqual(runtime.effectiveFullscreenEffect(stored: .native, userSelected: true), .native)
        XCTAssertEqual(runtime.effectiveFullscreenEffect(stored: .vinylDeck, userSelected: false), .vinylDeck)
    }

    func testEveryCompanionEffectIsARealEffect() {
        for skin in SkinCatalog.all {
            for styleID in skin.companions.immersiveStageIDs {
                XCTAssertNotNil(FullscreenPlayerEffect(rawValue: styleID), "\(skin.id) 声明了不存在的全屏效果 \(styleID)")
                XCTAssertEqual(FullscreenPlayerEffect(rawValue: styleID)?.rawValue, styleID)
            }
        }
        XCTAssertEqual(
            Set(FullscreenPlayerEffect.allCases.map(\.rawValue)),
            Set(ImmersivePresentationFallbackPolicy.supportedEffectRawValues)
        )
    }

    func testCompanionEffectsStayListedWhileTheirSkinIsUsable() {
        // 极简随 App 提供,它带来的效果对所有人可见,而且排在「封面驱动」这一组的最后(新效果只能追加)。
        _ = SkinRuntime(defaults: defaults)
        XCTAssertTrue(FullscreenPlayerEffect.coverMosaic.isAvailable)
        XCTAssertEqual(FullscreenEffectCollection.coverReactive.effects.last, .coverMosaic)
        XCTAssertEqual(FullscreenPlayerEffect.allCases.last, .coverMosaic)
        XCTAssertEqual(FullscreenPlayerEffect.particleBloom.advanced(by: 1), .coverMosaic)
    }

    func testEffectsOwnedOnlyByALockedSkinAreHiddenUntilItIsUnlocked() {
        let locked = SkinDefinition(
            id: "neon",
            nameKey: "k",
            descriptionKey: "k",
            access: .unlockable(unlockID: "skin.neon"),
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            shell: .tabBar,
            companions: SkinCompanions(immersiveStageIDs: ["vinylDeck"])
        )
        defer { FullscreenEffectAvailability.update(catalog: SkinCatalog.all, unlocked: []) }

        FullscreenEffectAvailability.update(catalog: SkinCatalog.all + [locked], unlocked: [])
        XCTAssertFalse(FullscreenPlayerEffect.vinylDeck.isAvailable)
        XCTAssertFalse(FullscreenEffectCollection.coverReactive.effects.contains(.vinylDeck))
        XCTAssertTrue(FullscreenPlayerEffect.coverFlow.isAvailable)

        FullscreenEffectAvailability.update(catalog: SkinCatalog.all + [locked], unlocked: ["skin.neon"])
        XCTAssertTrue(FullscreenPlayerEffect.vinylDeck.isAvailable)
    }

    // MARK: - 目录与解锁链路

    func testTheCatalogIsTheShippingCatalogInEveryBuild() {
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertEqual(runtime.catalog.map(\.id), SkinCatalog.all.map(\.id))
        XCTAssertTrue(runtime.catalog.allSatisfy { runtime.availability(of: $0) != .locked })
    }

    /// 正式目录里没有需要解锁的皮肤,权益来源一个请求都不向商店发(启动、刷新、加载解锁项、恢复都直接返回)。
    func testTheUnlockStoreStaysDormantWithoutLockedSkins() async {
        let runtime = SkinRuntime(defaults: defaults)
        let store = SkinUnlockStore(runtime: runtime, defaults: defaults)
        XCTAssertTrue(store.isDormant)
        XCTAssertTrue(store.productIDs.isEmpty)
        await store.refreshEntitlements()
        await store.loadOffers()
        XCTAssertTrue(store.offers.isEmpty)
        XCTAssertEqual(runtime.unlockedIDs, [])
    }

    func testTheUnlockStoreWakesUpOnceTheCatalogHasALockedSkin() {
        let runtime = SkinRuntime(defaults: defaults, catalog: Self.catalogWithLockedFixture)
        defer { FullscreenEffectAvailability.update(catalog: SkinCatalog.all, unlocked: []) }
        let store = SkinUnlockStore(runtime: runtime, defaults: defaults)
        XCTAssertFalse(store.isDormant)
        XCTAssertEqual(
            store.productIDs,
            ["com.welape.yuanyin.skin.fixture-locked", SkinUnlockProductPolicy.allAccessProductID]
        )
    }

    func testALockedSkinIsRefusedUntilUnlockedAndComesBackAfterARevocation() {
        let runtime = SkinRuntime(defaults: defaults, catalog: Self.catalogWithLockedFixture)
        defer { FullscreenEffectAvailability.update(catalog: SkinCatalog.all, unlocked: []) }
        let fixture = Self.lockedFixture

        XCTAssertEqual(runtime.availability(of: fixture), .locked)
        XCTAssertFalse(runtime.select(fixture.id))
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.classicID)

        runtime.updateEntitlements(unlocked: ["skin.fixture-locked"])
        XCTAssertEqual(runtime.availability(of: fixture), .unlocked)
        XCTAssertTrue(runtime.select(fixture.id))
        XCTAssertEqual(runtime.activeSkin.id, fixture.id)

        // 权益失效:界面退回经典,但用户的选择留着。
        runtime.updateEntitlements(unlocked: [])
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.classicID)
        XCTAssertEqual(runtime.preferredSkinID, fixture.id)

        // 恢复之后不必再选一次。
        runtime.updateEntitlements(unlocked: ["skin.fixture-locked"])
        XCTAssertEqual(runtime.activeSkin.id, fixture.id)
        XCTAssertEqual(
            defaults.stringArray(forKey: SkinRuntime.unlockedIDsKey),
            ["skin.fixture-locked"]
        )
    }

    /// 同步过来一个本机目录里没有的待解锁皮肤(比如测试夹具的 id):当成来自更新版本的皮肤,回落到经典。
    func testALockedSkinOutsideTheCatalogFallsBack() {
        defaults.set(Self.lockedFixture.id, forKey: SkinRuntime.selectedSkinKey)
        let runtime = SkinRuntime(defaults: defaults)
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.classicID)
        XCTAssertEqual(runtime.preferredSkinID, Self.lockedFixture.id)
        runtime.updateEntitlements(unlocked: ["skin.fixture-locked"])
        XCTAssertEqual(runtime.activeSkin.id, SkinCatalog.classicID)
    }
}
