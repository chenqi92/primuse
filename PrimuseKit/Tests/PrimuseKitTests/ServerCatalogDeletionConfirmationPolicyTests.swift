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

extension ServerCatalogDeletionConfirmationPolicyTests {
    private func plan(
        existing: Set<String>,
        authoritative: Set<String>,
        previousCounts: [String: Int] = [:],
        previousRevision: String? = nil,
        revision: String?,
        authority: CatalogDeletionAuthority
    ) -> ServerCatalogDeletionConfirmationPolicy.Plan {
        ServerCatalogDeletionConfirmationPolicy.plan(
            existingSongIDs: existing,
            authoritativeSongIDs: authoritative,
            previousMissingCounts: previousCounts,
            previousEvidenceRevision: previousRevision,
            currentRevision: revision,
            authority: authority
        )
    }

    /// Jellyfin and Emby verify a complete snapshot by item id, so deleting a
    /// track on the server must take effect on the very next scan.
    @Test func authoritativeSnapshotRemovesOnTheFirstWalk() {
        let result = plan(
            existing: ["a", "b", "c"],
            authoritative: ["a", "b"],
            revision: nil,
            authority: .authoritative
        )
        #expect(result.confirmedDeletionSongIDs == ["c"])
        #expect(result.pendingSongIDs.isEmpty)
        #expect(result.isMassDisappearance == false)
    }

    /// The one case an authoritative snapshot still may not decide alone: an
    /// unmounted library looks exactly like a bulk deletion.
    @Test func authoritativeSnapshotStillRepeatsASuspiciousLoss() {
        let existing = Set((0..<200).map { "song-\($0)" })
        let survivors = Set((0..<100).map { "song-\($0)" })
        let first = plan(
            existing: existing,
            authoritative: survivors,
            revision: nil,
            authority: .authoritative
        )
        #expect(first.isMassDisappearance)
        #expect(first.confirmedDeletionSongIDs.isEmpty)
        #expect(first.pendingSongIDs.count == 100)

        let second = plan(
            existing: existing,
            authoritative: survivors,
            previousCounts: first.missingCounts,
            revision: nil,
            authority: .authoritative
        )
        #expect(second.confirmedDeletionSongIDs.isEmpty)

        let third = plan(
            existing: existing,
            authoritative: survivors,
            previousCounts: second.missingCounts,
            revision: nil,
            authority: .authoritative
        )
        #expect(third.confirmedDeletionSongIDs.count == 100)
    }

    /// A compatibility or degraded listing may merge rows but never remove any,
    /// no matter how many times it repeats the same absence.
    @Test func neverAuthorityRemovesNothingEvenWhenRepeated() {
        var counts: [String: Int] = [:]
        for _ in 0..<5 {
            let result = plan(
                existing: ["a", "b"],
                authoritative: ["a"],
                previousCounts: counts,
                revision: nil,
                authority: .never
            )
            #expect(result.confirmedDeletionSongIDs.isEmpty)
            #expect(result.pendingSongIDs == ["b"])
            counts = result.missingCounts
        }
    }

    /// Subsonic 仍然要两票，只是票按完整走查算：同一次走查的重读不算，下一次走查算。
    @Test func confirmationRequiredNeedsTwoSeparateWalks() {
        let firstWalk = Policy.walkObservationRevision(catalogRevision: "r1", stageSessionID: "s1")
        let first = plan(
            existing: ["a", "b"],
            authoritative: ["a"],
            revision: firstWalk,
            authority: .confirmationRequired
        )
        #expect(first.confirmedDeletionSongIDs.isEmpty)

        let replayed = plan(
            existing: ["a", "b"],
            authoritative: ["a"],
            previousCounts: first.missingCounts,
            previousRevision: firstWalk,
            revision: firstWalk,
            authority: .confirmationRequired
        )
        #expect(replayed.confirmedDeletionSongIDs.isEmpty, "a re-read is the same observation")

        let nextWalk = plan(
            existing: ["a", "b"],
            authoritative: ["a"],
            previousCounts: replayed.missingCounts,
            previousRevision: firstWalk,
            revision: Policy.walkObservationRevision(catalogRevision: "r1", stageSessionID: "s2"),
            authority: .confirmationRequired
        )
        #expect(nextWalk.confirmedDeletionSongIDs == ["b"])
    }

    /// A row that came back clears its history under every authority.
    @Test func recoveredRowsClearTheirWitnessHistory() {
        for authority in [
            CatalogDeletionAuthority.authoritative,
            .confirmationRequired,
            .never,
        ] {
            let result = plan(
                existing: ["a", "b"],
                authoritative: ["a", "b"],
                previousCounts: ["b": 2],
                revision: "r9",
                authority: authority
            )
            #expect(result.confirmedDeletionSongIDs.isEmpty)
            #expect(result.missingCounts.isEmpty)
            #expect(result.evidenceRevision == "r9")
        }
    }

    @Test func witnessBarMatchesTheAuthority() {
        #expect(Policy.requiredWitnesses(for: .authoritative, isMassDisappearance: false) == 1)
        #expect(Policy.requiredWitnesses(for: .authoritative, isMassDisappearance: true) == 3)
        #expect(Policy.requiredWitnesses(for: .confirmationRequired, isMassDisappearance: false) == 2)
        #expect(Policy.requiredWitnesses(for: .confirmationRequired, isMassDisappearance: true) == 3)
        #expect(Policy.requiredWitnesses(for: .never, isMassDisappearance: false) == nil)
        #expect(Policy.requiredWitnesses(for: .never, isMassDisappearance: true) == nil)
    }
}

private typealias Policy = ServerCatalogDeletionConfirmationPolicy

/// #155：Navidrome 删了文件、服务端扫过一次之后 `lastScan` 就不再动。以前按它给证词去重，
/// 后面每次完整走查都被当成同一份证词的重读，缺席永远停在一票，歌一直删不掉。
struct ServerCatalogDeletionWalkEvidenceTests {
    private func walk(
        _ session: String,
        existing: Set<String>,
        authoritative: Set<String>,
        after previous: ServerCatalogDeletionConfirmationPolicy.Plan? = nil,
        serverRevision: String? = "2026-10-01T08:00:00Z|1200",
        authority: CatalogDeletionAuthority = .confirmationRequired
    ) -> ServerCatalogDeletionConfirmationPolicy.Plan {
        Policy.plan(
            existingSongIDs: existing,
            authoritativeSongIDs: authoritative,
            previousMissingCounts: previous?.missingCounts ?? [:],
            previousEvidenceRevision: previous?.evidenceRevision,
            currentRevision: Policy.walkObservationRevision(
                catalogRevision: serverRevision,
                stageSessionID: session
            ),
            authority: authority
        )
    }

    @Test func aLaterWalkUnderTheSameServerScanMarkerConfirmsTheDeletion() {
        let first = walk("s1", existing: ["a", "b", "c"], authoritative: ["a", "b"])
        #expect(first.confirmedDeletionSongIDs.isEmpty)
        #expect(first.pendingSongIDs == ["c"])

        let second = walk("s2", existing: ["a", "b", "c"], authoritative: ["a", "b"], after: first)
        #expect(second.confirmedDeletionSongIDs == ["c"])
        #expect(second.pendingSongIDs.isEmpty)
    }

    @Test func replayingTheSameWalkIsStillOneWitness() {
        // 提交到一半进程退出，重启后从同一个暂存会话把同一批页再提交一次。
        let first = walk("s1", existing: ["a", "b"], authoritative: ["a"])
        let replayed = walk("s1", existing: ["a", "b"], authoritative: ["a"], after: first)
        #expect(replayed.confirmedDeletionSongIDs.isEmpty)
        #expect(replayed.missingCounts == ["b": 1])
    }

    @Test func aServerWithoutAScanMarkerStillSeparatesWalks() {
        let first = walk("s1", existing: ["a", "b"], authoritative: ["a"], serverRevision: nil)
        let second = walk("s2", existing: ["a", "b"], authoritative: ["a"], after: first, serverRevision: nil)
        #expect(second.confirmedDeletionSongIDs == ["b"])
    }

    @Test func aMassDisappearanceUnderAStillMarkerIsRemovedOnTheThirdWalk() {
        let existing = Set((0..<200).map { "song-\($0)" })
        let survivors = Set((0..<100).map { "song-\($0)" })

        let first = walk("s1", existing: existing, authoritative: survivors)
        #expect(first.holdsMassDisappearance)

        let second = walk("s2", existing: existing, authoritative: survivors, after: first)
        #expect(second.confirmedDeletionSongIDs.isEmpty)
        #expect(second.holdsMassDisappearance)

        let third = walk("s3", existing: existing, authoritative: survivors, after: second)
        #expect(third.confirmedDeletionSongIDs.count == 100)
        // 这一轮把它们都删了，卡片上不能再挂「少了 0 首」。
        #expect(third.isMassDisappearance)
        #expect(!third.holdsMassDisappearance)
    }

    @Test func walkObservationsDifferPerSessionNotPerServerRevision() {
        let a = Policy.walkObservationRevision(catalogRevision: "r1", stageSessionID: "s1")
        #expect(a == Policy.walkObservationRevision(catalogRevision: "r1", stageSessionID: "s1"))
        #expect(a != Policy.walkObservationRevision(catalogRevision: "r1", stageSessionID: "s2"))
        // 旧版本存的是裸的服务端修订，升级后的第一次走查自然算新的一票。
        #expect(a != "r1")
    }
}
