import Testing
@testable import PrimuseKit

@Suite("Skin bases")
struct SkinBaseTests {
    @Test("经典是标签栏基座,极简是无标签栏基座")
    func shippedSkinsDeclareTheirBase() {
        #expect(SkinCatalog.classic.base == .classic)
        #expect(SkinCatalog.minimal.base == .minimal)
    }

    @Test("实验样式都建在某一套基座上,且与导航插槽一致")
    func labSkinsFollowTheirNavigationSlot() {
        for skin in SkinCatalog.all + SkinCatalog.lab {
            let expected: SkinBase = skin.navigationHeader == .minimal ? .minimal : .classic
            #expect(skin.base == expected)
        }
    }
}
