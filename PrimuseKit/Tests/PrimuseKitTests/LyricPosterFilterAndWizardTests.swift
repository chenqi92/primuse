import Foundation
import Testing
@testable import PrimuseKit

struct LyricPosterFilterCatalogTests {
    @Test func identifiersAndOrderAreUniqueAndTheFirstOneIsTheOriginal() {
        let all = LyricPosterFilterCatalog.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.order)).count == all.count)
        #expect(Set(all.map(\.nameKey)).count == all.count)
        #expect(all.map(\.order) == all.map(\.order).sorted())
        #expect(all.first?.id == .original)
    }

    @Test func onlyTheOriginalSkipsTheImagePipeline() {
        #expect(LyricPosterFilterCatalog.spec(for: .original).isIdentity)
        for spec in LyricPosterFilterCatalog.all where spec.id != .original {
            #expect(!spec.isIdentity)
        }
    }

    @Test func parametersStayInsideSaneRanges() {
        for spec in LyricPosterFilterCatalog.all {
            #expect(spec.saturation >= 0 && spec.saturation <= 2)
            #expect(spec.contrast > 0 && spec.contrast <= 2)
            #expect(spec.brightness >= -0.5 && spec.brightness <= 0.5)
            #expect(spec.sepiaIntensity >= 0 && spec.sepiaIntensity <= 1)
            #expect(spec.vignette >= 0 && spec.vignette <= 1)
            #expect(spec.grain >= 0 && spec.grain <= 1)
        }
        // 黑白就该是真的没有颜色。
        #expect(LyricPosterFilterCatalog.spec(for: .mono).saturation == 0)
    }

    @Test func unknownStoredFilterFallsBackToTheOriginal() {
        #expect(LyricPosterFilterCatalog.resolved(preferred: nil).id == .original)
        #expect(
            LyricPosterFilterCatalog.resolved(
                preferred: LyricPosterFilterID("removed_later")
            ).id == .original
        )
        #expect(LyricPosterFilterCatalog.resolved(preferred: .sepia).id == .sepia)
    }
}

struct LyricPosterWizardPolicyTests {
    @Test func onlyTheLineStepBlocksProgress() {
        #expect(!LyricPosterWizardPolicy.canAdvance(from: .lines, selectionCount: 0))
        #expect(LyricPosterWizardPolicy.canAdvance(from: .lines, selectionCount: 1))
        // 不想写感想、不想挑风格的人都不该被拦住。
        #expect(LyricPosterWizardPolicy.canAdvance(from: .note, selectionCount: 0))
        #expect(LyricPosterWizardPolicy.canAdvance(from: .style, selectionCount: 0))
        #expect(LyricPosterWizardPolicy.canAdvance(from: .export, selectionCount: 0))
    }

    @Test func stepsWalkForwardAndBackAndStopAtTheEnds() {
        #expect(LyricPosterWizardPolicy.previous(before: .lines) == nil)
        #expect(LyricPosterWizardPolicy.next(after: .lines) == .note)
        #expect(LyricPosterWizardPolicy.next(after: .note) == .style)
        #expect(LyricPosterWizardPolicy.next(after: .style) == .export)
        #expect(LyricPosterWizardPolicy.next(after: .export) == nil)
        #expect(LyricPosterWizardPolicy.previous(before: .export) == .style)
        #expect(LyricPosterWizardPolicy.isLast(.export))
        #expect(!LyricPosterWizardPolicy.isLast(.style))
    }

    @Test func progressReachesFullOnTheLastStep() {
        #expect(LyricPosterWizardPolicy.progress(at: .export) == 1)
        #expect(LyricPosterWizardPolicy.progress(at: .lines) > 0)
        let values = LyricPosterWizardPolicy.steps.map { LyricPosterWizardPolicy.progress(at: $0) }
        #expect(values == values.sorted())
        #expect(Set(LyricPosterWizardPolicy.steps.map(\.titleKey)).count == values.count)
    }
}
