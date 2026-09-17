import Foundation
import Testing
@testable import PrimuseKit

@Suite("Skin unlock products")
struct SkinUnlockProductPolicyTests {
    private let catalog = SkinCatalog.all + SkinCatalog.lab

    @Test("解锁项与产品标识可以互相换算")
    func identifiersRoundTrip() {
        let productID = SkinUnlockProductPolicy.productID(forUnlockID: "skin.midnight")
        #expect(productID == "com.welape.yuanyin.skin.midnight")
        #expect(SkinUnlockProductPolicy.unlockID(forProductID: productID) == "skin.midnight")
        #expect(SkinUnlockProductPolicy.unlockID(forProductID: "org.example.skin.midnight") == nil)
        #expect(SkinUnlockProductPolicy.unlockID(forProductID: SkinUnlockProductPolicy.productPrefix) == nil)
    }

    @Test("目录里没有需要解锁的样式时,一个产品都不查")
    func includedOnlyCatalogNeverTouchesTheStore() {
        #expect(SkinUnlockProductPolicy.productIDs(for: SkinCatalog.all).isEmpty)
        #expect(SkinUnlockProductPolicy.unlockedIDs(ownedProductIDs: ["anything"], catalog: SkinCatalog.all).isEmpty)
    }

    @Test("有需要解锁的样式时,查它自己的产品和全部解锁那一项")
    func unlockableCatalogQueriesItsProducts() {
        let productIDs = SkinUnlockProductPolicy.productIDs(for: catalog)
        #expect(productIDs == ["com.welape.yuanyin.skin.midnight", "com.welape.yuanyin.skin.all"])
        #expect(Set(productIDs).count == productIDs.count)
        #expect(SkinUnlockProductPolicy.productIDs(for: catalog, allAccessProductID: nil) == ["com.welape.yuanyin.skin.midnight"])
    }

    @Test("拥有的产品换算成已解锁的项,不认识的产品被忽略")
    func ownedProductsBecomeUnlockedIDs() {
        #expect(SkinUnlockProductPolicy.unlockedIDs(ownedProductIDs: [], catalog: catalog).isEmpty)
        #expect(
            SkinUnlockProductPolicy.unlockedIDs(
                ownedProductIDs: ["com.welape.yuanyin.skin.midnight", "com.welape.yuanyin.skin.from-the-future"],
                catalog: catalog
            ) == ["skin.midnight"]
        )
        #expect(
            SkinUnlockProductPolicy.unlockedIDs(
                ownedProductIDs: ["com.welape.yuanyin.skin.all"],
                catalog: catalog
            ) == ["skin.midnight"]
        )
    }

    @Test("换算结果交给选择规则后,样式从待解锁变为可用")
    func unlockedIDsFeedTheSelectionPolicy() {
        let unlocked = SkinUnlockProductPolicy.unlockedIDs(
            ownedProductIDs: ["com.welape.yuanyin.skin.midnight"],
            catalog: catalog
        )
        #expect(SkinSelectionPolicy.availability(of: SkinCatalog.midnight, unlocked: []) == .locked)
        #expect(SkinSelectionPolicy.availability(of: SkinCatalog.midnight, unlocked: unlocked) == .unlocked)
        #expect(
            SkinSelectionPolicy.effectiveSkinID(
                requested: SkinCatalog.midnight.id,
                catalog: catalog,
                unlocked: unlocked
            ) == SkinCatalog.midnight.id
        )
    }
}
