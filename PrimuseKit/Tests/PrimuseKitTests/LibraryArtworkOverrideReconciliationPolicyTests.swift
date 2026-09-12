import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library artwork override reconciliation outcome")
struct LibraryArtworkOverrideReconciliationPolicyTests {
    private let owner = LibraryArtworkOwner(kind: .album, id: "album-1")

    private func override(
        revision: Int64 = 1,
        writer: String = "phone",
        operation: String = "op-1",
        updatedAt: TimeInterval = 1_000
    ) -> LibraryArtworkOverride {
        LibraryArtworkOverride(
            owner: owner,
            mode: .automatic,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            syncRevision: revision,
            syncWriterID: writer,
            syncOperationID: operation
        )
    }

    @Test("A higher revision wins on either side")
    func revisionTakesPrecedence() {
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(revision: 4),
            remote: override(revision: 3)
        ) == .localWins)
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(revision: 3),
            remote: override(revision: 4)
        ) == .remoteWins)
    }

    @Test("Equal revisions break the tie on the writer identifier")
    func writerBreaksRevisionTie() {
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(writer: "phone"),
            remote: override(writer: "mac")
        ) == .localWins)
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(writer: "mac"),
            remote: override(writer: "phone")
        ) == .remoteWins)
    }

    @Test("Equal writers break the tie on the operation identifier")
    func operationBreaksWriterTie() {
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(operation: "op-2"),
            remote: override(operation: "op-1")
        ) == .localWins)
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(operation: "op-1"),
            remote: override(operation: "op-2")
        ) == .remoteWins)
    }

    @Test("Legacy values without a logical clock compare on updatedAt")
    func updatedAtBreaksLegacyTie() {
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(revision: 0, writer: "", operation: "", updatedAt: 2_000),
            remote: override(revision: 0, writer: "", operation: "", updatedAt: 1_000)
        ) == .localWins)
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(revision: 0, writer: "", operation: "", updatedAt: 1_000),
            remote: override(revision: 0, writer: "", operation: "", updatedAt: 2_000)
        ) == .remoteWins)
        // 有逻辑时钟时 updatedAt 不参与比较。
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: override(updatedAt: 1_000),
            remote: override(updatedAt: 9_000)
        ) == .equivalent)
    }

    @Test("Identical values are equivalent while winner still reports local")
    func identicalValuesAreEquivalent() {
        let local = override()
        let remote = override()
        #expect(LibraryArtworkOverrideReconciliationPolicy.outcome(
            local: local,
            remote: remote
        ) == .equivalent)
        #expect(LibraryArtworkOverrideReconciliationPolicy.winner(
            local: local,
            remote: remote
        ) == .local)
    }

    @Test("winner keeps its existing mapping for decided conflicts")
    func winnerMatchesOutcome() {
        #expect(LibraryArtworkOverrideReconciliationPolicy.winner(
            local: override(revision: 4),
            remote: override(revision: 3)
        ) == .local)
        #expect(LibraryArtworkOverrideReconciliationPolicy.winner(
            local: override(revision: 3),
            remote: override(revision: 4)
        ) == .remote)
    }
}
