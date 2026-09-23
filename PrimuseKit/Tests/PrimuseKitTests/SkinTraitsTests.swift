import Foundation
import Testing
@testable import PrimuseKit

@Suite("Skin traits")
struct SkinTraitsTests {
    @Test("随 App 提供的样式都用默认取向:详情页染封面色,浮层是玻璃")
    func shippedSkinsUseStandardTraits() {
        for skin in SkinCatalog.all {
            #expect(skin.traits == .standard)
            #expect(skin.traits.collectionBackdrop == .artworkTint)
            #expect(skin.traits.chromeMaterial == .glass)
        }
    }

    @Test("没有特征位的旧样式数据按默认取向解码")
    func legacyPayloadWithoutTraitsDecodes() throws {
        let data = try JSONEncoder().encode(SkinCatalog.minimal)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "traits")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SkinDefinition.self, from: legacy)
        #expect(decoded.traits == .standard)
        #expect(decoded.id == SkinCatalog.minimal.id)
    }

    @Test("非默认的特征位能 JSON 往返")
    func customTraitsRoundTrip() throws {
        let base = SkinCatalog.minimal
        let custom = SkinDefinition(
            id: "trait-probe",
            nameKey: base.nameKey,
            descriptionKey: base.descriptionKey,
            appearance: base.appearance,
            pageBackground: base.pageBackground,
            access: base.access,
            colors: base.colors,
            metrics: base.metrics,
            typography: base.typography,
            motion: base.motion,
            slots: base.slots,
            companions: base.companions,
            traits: SkinTraits(collectionBackdrop: .skinCanvas, chromeMaterial: .solid)
        )
        let decoded = try JSONDecoder().decode(SkinDefinition.self, from: JSONEncoder().encode(custom))
        #expect(decoded == custom)
        #expect(decoded.traits.collectionBackdrop == .skinCanvas)
        #expect(decoded.traits.chromeMaterial == .solid)
    }
}
