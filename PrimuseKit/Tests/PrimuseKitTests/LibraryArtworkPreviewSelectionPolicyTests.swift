import Testing
@testable import PrimuseKit

@Suite("Library artwork preview selection")
struct LibraryArtworkPreviewSelectionPolicyTests {
    @Test("Artwork hints fill every preview slot before placeholders")
    func prefersArtworkHints() {
        let candidates = [
            candidate("blank-a"),
            candidate("covered-a", hasArtwork: true),
            candidate("blank-b"),
            candidate("covered-b", hasArtwork: true),
            candidate("covered-c", hasArtwork: true),
            candidate("blank-c"),
        ]

        let selected = LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: candidates,
            maximumCount: 3,
            randomSeed: "visit-a"
        )

        #expect(Set(selected) == ["covered-a", "covered-b", "covered-c"])
    }

    @Test("Items without hints fill remaining preview slots")
    func fillsRemainingSlots() {
        let selected = LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: [
                candidate("blank-a"),
                candidate("covered", hasArtwork: true),
                candidate("blank-b"),
            ],
            maximumCount: 3,
            randomSeed: "visit-b"
        )

        #expect(selected.count == 3)
        #expect(selected.first == "covered")
        #expect(Set(selected) == ["covered", "blank-a", "blank-b"])
    }

    @Test("A duplicate keeps its strongest hint and appears once")
    func mergesDuplicateHints() {
        let selected = LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: [
                candidate("same"),
                candidate("fallback"),
                candidate("same", hasArtwork: true),
                candidate(""),
            ],
            maximumCount: 3,
            randomSeed: "visit-c"
        )

        #expect(selected == ["same", "fallback"])
    }

    @Test("A visit seed is stable while later visits may choose another sample")
    func seededRandomness() {
        let candidates = (0..<10).map {
            candidate("covered-\($0)", hasArtwork: true)
        }
        let first = LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: candidates,
            maximumCount: 3,
            randomSeed: "same-visit"
        )
        let repeated = LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: Array(candidates.reversed()),
            maximumCount: 3,
            randomSeed: "same-visit"
        )
        let visitSamples = Set((0..<12).map { visit in
            LibraryArtworkPreviewSelectionPolicy.selectedIDs(
                from: candidates,
                maximumCount: 3,
                randomSeed: "visit-\(visit)"
            ).joined(separator: ",")
        })

        #expect(first == repeated)
        #expect(visitSamples.count > 1)
    }

    @Test("Non-positive limits select nothing")
    func handlesEmptyLimit() {
        #expect(LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: [candidate("covered", hasArtwork: true)],
            maximumCount: 0,
            randomSeed: "visit"
        ).isEmpty)
    }

    private func candidate(
        _ id: String,
        hasArtwork: Bool = false
    ) -> LibraryArtworkPreviewCandidate {
        LibraryArtworkPreviewCandidate(id: id, hasArtworkHint: hasArtwork)
    }
}
