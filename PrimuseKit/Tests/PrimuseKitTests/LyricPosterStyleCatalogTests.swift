import Foundation
import Testing
@testable import PrimuseKit

struct LyricPosterStyleCatalogTests {
    @Test func styleIdentifiersAndDisplayOrderAreUnique() {
        let descriptors = LyricPosterStyleCatalog.builtInDescriptors
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.order)).count == descriptors.count)
        #expect(Set(descriptors.map(\.nameKey)).count == descriptors.count)
        for descriptor in descriptors {
            #expect(descriptor.supportedCanvases.contains(descriptor.preferredCanvas))
        }
    }

    @Test func artworkDependentStylesDisappearWhenACoverIsMissing() {
        let withArtwork = LyricPosterStyleCatalog.availableDescriptors(hasArtwork: true)
        let withoutArtwork = LyricPosterStyleCatalog.availableDescriptors(hasArtwork: false)
        #expect(withArtwork.count > withoutArtwork.count)
        #expect(!withoutArtwork.contains { $0.requiresArtwork })
        // A song with no cover must still have something to share.
        #expect(!withoutArtwork.isEmpty)
        #expect(withArtwork.map(\.order) == withArtwork.map(\.order).sorted())
    }

    @Test func storedPreferencesSurviveOnlyWhileTheyStayUsable() {
        let usable = LyricPosterStyleCatalog.resolvedDescriptor(
            preferred: .vinyl,
            hasArtwork: true
        )
        #expect(usable?.id == .vinyl)

        // The same preference on a coverless song falls back instead of
        // rendering an empty record sleeve.
        let fallback = LyricPosterStyleCatalog.resolvedDescriptor(
            preferred: .vinyl,
            hasArtwork: false
        )
        #expect(fallback != nil)
        #expect(fallback?.requiresArtwork == false)

        let unknown = LyricPosterStyleCatalog.resolvedDescriptor(
            preferred: LyricPosterStyleID("removed_in_a_later_build"),
            hasArtwork: true
        )
        #expect(unknown?.id == LyricPosterStyleCatalog.builtInDescriptors.first?.id)
    }

    @Test func motionExportsOnlyOfferStylesThatCanAnimate() {
        let stillOnly = LyricPosterStyleDescriptor(
            id: LyricPosterStyleID("still_only"),
            nameKey: "k",
            symbolName: "photo",
            supportsMotion: false,
            order: 99
        )
        let descriptors = LyricPosterStyleCatalog.builtInDescriptors + [stillOnly]

        let motion = LyricPosterStyleCatalog.availableDescriptors(
            in: descriptors,
            hasArtwork: true,
            requiresMotion: true
        )
        #expect(!motion.contains { $0.id == stillOnly.id })

        let resolved = LyricPosterStyleCatalog.resolvedDescriptor(
            preferred: stillOnly.id,
            in: descriptors,
            hasArtwork: true,
            requiresMotion: true
        )
        #expect(resolved?.supportsMotion == true)
    }

    @Test func canvasSelectionHonorsWhatAStyleSupports() {
        let squareOnly = LyricPosterStyleDescriptor(
            id: LyricPosterStyleID("square_only"),
            nameKey: "k",
            symbolName: "square",
            preferredCanvas: .square,
            supportedCanvases: [.square],
            order: 0
        )
        #expect(squareOnly.canvas(preferring: .story) == .square)
        #expect(squareOnly.canvas(preferring: nil) == .square)

        let flexible = LyricPosterStyleCatalog.builtInDescriptors[0]
        #expect(flexible.canvas(preferring: .story) == .story)
    }

    @Test func canvasSizesMatchTheirAdvertisedAspect() {
        #expect(LyricPosterCanvas.square.aspectRatio == 1)
        #expect(abs(LyricPosterCanvas.portrait.aspectRatio - 4.0 / 5.0) < 0.0001)
        #expect(abs(LyricPosterCanvas.story.aspectRatio - 9.0 / 16.0) < 0.0001)
    }
}
