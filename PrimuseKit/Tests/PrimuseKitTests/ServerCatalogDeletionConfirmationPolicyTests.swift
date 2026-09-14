import Foundation
import Testing
@testable import PrimuseKit

struct ServerCatalogDeletionConfirmationPolicyTests {
    private func plan(
        existing: Set<String>,
        authoritative: Set<String>,
        previousCounts: [String: Int] = [:],
        previousRevision: String? = nil,
        revision: String?
    ) -> ServerCatalogDeletionConfirmationPolicy.Plan {
        ServerCatalogDeletionConfirmationPolicy.plan(
            existingSongIDs: existing,
            authoritativeSongIDs: authoritative,
            previousMissingCounts: previousCounts,
            previousEvidenceRevision: previousRevision,
            currentRevision: revision
        )
    }

    @Test func oneCompleteSnapshotOnlyWitnessesTheAbsence() {
        let first = plan(
            existing: ["a", "b", "c"],
            authoritative: ["a", "b"],
            revision: "r1"
        )
        #expect(first.confirmedDeletionSongIDs.isEmpty)
        #expect(first.pendingSongIDs == ["c"])
        #expect(first.missingCounts == ["c": 1])
        #expect(first.evidenceRevision == "r1")
    }

    @Test func aSecondWitnessUnderANewRevisionConfirmsTheDeletion() {
        let second = plan(
            existing: ["a", "b", "c"],
            authoritative: ["a", "b"],
            previousCounts: ["c": 1],
            previousRevision: "r1",
            revision: "r2"
        )
        #expect(second.confirmedDeletionSongIDs == ["c"])
        #expect(second.pendingSongIDs.isEmpty)
    }

    @Test func rereadingTheSameRevisionIsNotASecondWitness() {
        // A retry loop re-reads the identical catalogue. Counting it again
        // would let one scan delete rows on its own.
        let repeated = plan(
            existing: ["a", "b", "c"],
            authoritative: ["a", "b"],
            previousCounts: ["c": 1],
            previousRevision: "r1",
            revision: "r1"
        )
        #expect(repeated.confirmedDeletionSongIDs.isEmpty)
        #expect(repeated.missingCounts == ["c": 1])
    }

    @Test func aServerWithoutAScanMarkerStillConfirmsAfterTwoWalks() {
        let first = plan(existing: ["a", "b"], authoritative: ["a"], revision: nil)
        #expect(first.confirmedDeletionSongIDs.isEmpty)
        let second = plan(
            existing: ["a", "b"],
            authoritative: ["a"],
            previousCounts: first.missingCounts,
            previousRevision: nil,
            revision: nil
        )
        #expect(second.confirmedDeletionSongIDs == ["b"])
    }

    @Test func aRowThatComesBackClearsItsHistory() {
        let restored = plan(
            existing: ["a", "b"],
            authoritative: ["a", "b"],
            previousCounts: ["b": 1],
            previousRevision: "r1",
            revision: "r2"
        )
        #expect(restored.missingCounts.isEmpty)
        #expect(restored.confirmedDeletionSongIDs.isEmpty)
        #expect(restored.evidenceRevision == "r2")
    }

    @Test func aMassDisappearanceNeedsAnExtraWitness() {
        // A permission change or a server re-index can hide most of an account's
        // catalogue without moving the scan marker.
        let existing = Set((0..<200).map { "s\($0)" })
        let surviving = Set((0..<100).map { "s\($0)" })
        var counts: [String: Int] = [:]
        var revisions = ["r1", "r2", "r3"]
        var confirmed = Set<String>()
        var sawMassDisappearance = false
        var previousRevision: String?
        for revision in revisions {
            let result = plan(
                existing: existing,
                authoritative: surviving,
                previousCounts: counts,
                previousRevision: previousRevision,
                revision: revision
            )
            counts = result.missingCounts
            confirmed = result.confirmedDeletionSongIDs
            sawMassDisappearance = sawMassDisappearance || result.isMassDisappearance
            previousRevision = revision
            if revision == "r2" {
                // Two witnesses would be enough for an ordinary edit; a
                // suspicious pass has to wait for a third.
                #expect(result.confirmedDeletionSongIDs.isEmpty)
            }
        }
        revisions.removeAll()
        #expect(sawMassDisappearance)
        #expect(confirmed.count == 100)
    }

    @Test func aSmallLibraryLosingMostRowsIsNotTreatedAsAMassDisappearance() {
        // 3 of 4 rows is a large share but a plausible ordinary edit.
        let result = plan(
            existing: ["a", "b", "c", "d"],
            authoritative: ["a"],
            revision: "r1"
        )
        #expect(!result.isMassDisappearance)
    }

    @Test func retainedSetRemovesExactlyTheConfirmedRows() {
        let retained = ServerCatalogDeletionConfirmationPolicy.retainedAuthoritativeSongIDs(
            existingSongIDs: ["a", "b", "c", "d"],
            authoritativeSongIDs: ["a", "b", "e"],
            confirmedDeletionSongIDs: ["c"]
        )
        // `d` is still gathering witnesses, so the prune must not touch it.
        #expect(retained == ["a", "b", "d", "e"])
    }
}
