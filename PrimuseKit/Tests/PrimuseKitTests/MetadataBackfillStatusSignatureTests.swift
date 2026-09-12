import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata backfill status signature")
struct MetadataBackfillStatusSignatureTests {
    @Test("Identical status rows produce identical signatures")
    func equalContentMatches() {
        #expect(makeSignature(items: [makeItem(), makeItem(songID: "s2", title: "Two")])
            == makeSignature(items: [makeItem(), makeItem(songID: "s2", title: "Two")]))
    }

    @Test("A changed row field changes the signature")
    func changedFieldsDiffer() {
        let base = makeSignature(items: [makeItem()])

        #expect(makeSignature(items: [makeItem(title: "Renamed")]) != base)
        #expect(makeSignature(items: [makeItem(state: .unreadableTags)]) != base)
        #expect(makeSignature(items: [makeItem(attemptCount: 3)]) != base)
        #expect(makeSignature(items: [makeItem(artistName: nil)]) != base)
        #expect(makeSignature(items: [makeItem(diagnostic: makeDiagnostic())]) != base)
    }

    @Test("Row order and row count are part of the signature")
    func orderAndCountMatter() {
        let first = makeItem()
        let second = makeItem(songID: "s2", title: "Two")

        #expect(makeSignature(items: [first, second]) != makeSignature(items: [second, first]))
        #expect(makeSignature(items: [first]) != makeSignature(items: [first, second]))
    }

    @Test("A source with no rows still participates, order independently")
    func emptySourcesParticipate() {
        #expect(makeSignature(sourceIDs: ["src", "other"], items: [])
            == makeSignature(sourceIDs: ["other", "src"], items: []))
        #expect(makeSignature(sourceIDs: ["src"], items: [])
            != makeSignature(sourceIDs: ["src", "other"], items: []))
    }

    @Test("The same rows under a different source are a different signature")
    func sourceIdentityMatters() {
        #expect(makeSignature(sourceIDs: ["src"], items: [makeItem()], itemSourceID: "src")
            != makeSignature(sourceIDs: ["other"], items: [makeItem()], itemSourceID: "other"))
    }

    private func makeSignature(
        sourceIDs: [String] = ["src"],
        items: [MetadataBackfillStatusDisplayItem],
        itemSourceID: String = "src"
    ) -> MetadataBackfillStatusSignature {
        var signature = MetadataBackfillStatusSignature()
        for sourceID in sourceIDs {
            signature.combine(sourceID: sourceID)
        }
        for item in items {
            signature.combine(item: item, sourceID: itemSourceID)
        }
        return signature
    }

    private func makeDiagnostic() -> MetadataBackfillDiagnosticRecord {
        MetadataBackfillDiagnosticRecord(
            state: .retryPending,
            reason: "timeout",
            attemptCount: 2,
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeItem(
        songID: String = "s1",
        title: String = "One",
        artistName: String? = "Artist",
        state: MetadataBackfillItemState = .pendingInspection,
        diagnostic: MetadataBackfillDiagnosticRecord? = nil,
        attemptCount: Int = 0
    ) -> MetadataBackfillStatusDisplayItem {
        MetadataBackfillStatusDisplayItem(
            songID: songID,
            title: title,
            artistName: artistName,
            filePath: "/music/\(songID).flac",
            fileFormat: "FLAC",
            hasMissingDuration: false,
            state: state,
            workReasons: [.duration, .artwork],
            diagnostic: diagnostic,
            attemptCount: attemptCount
        )
    }
}
