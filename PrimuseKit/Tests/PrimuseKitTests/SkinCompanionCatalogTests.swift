import Foundation
import Testing
@testable import PrimuseKit

/// 皮肤声明的配套必须真实存在。写错一个 id 不会崩,只会让那款海报永远不出现 ——
/// 这种缺陷肉眼走查发现不了。
@Suite("Skin companions exist in their catalogs")
struct SkinCompanionCatalogTests {
    @Test("配套海报都在歌词海报目录里")
    func companionPostersExist() {
        let known = Set(LyricPosterStyleCatalog.builtInDescriptors.map(\.id.rawValue))
        let issues = SkinValidationPolicy.catalogIssues(knownLyricPosterStyleIDs: known)
        #expect(issues.isEmpty, "\(issues)")
        #expect(known.contains("deep_sea"))
    }

    @Test("极简带来的海报排在内置款式之后,不打乱原有顺序")
    func companionPosterKeepsExistingOrder() {
        let descriptors = LyricPosterStyleCatalog.builtInDescriptors
        let deepSea = descriptors.first { $0.id == .deepSea }
        #expect(deepSea != nil)
        #expect(deepSea?.requiresArtwork == false)
        #expect(deepSea?.order == descriptors.map(\.order).max())
    }
}
