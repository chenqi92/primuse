import Foundation
import Testing
@testable import PrimuseKit

@Suite("Skin immersive companions exist")
struct ImmersiveCompanionCatalogTests {
    @Test("配套全屏效果都在受支持的效果表里")
    func companionStagesExist() {
        let known = Set(ImmersivePresentationFallbackPolicy.supportedEffectRawValues)
        let issues = SkinValidationPolicy.catalogIssues(knownImmersiveStageIDs: known)
        #expect(issues.isEmpty, "\(issues)")
    }
}
