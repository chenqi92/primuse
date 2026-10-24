import Testing
@testable import PrimuseKit

@Suite("Spotlight incremental index planning")
struct SpotlightIndexPlanningTests {
    @Test("A missing manifest builds the complete index in record order")
    func initialBuild() {
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:b", "2"), record("song:a", "1")],
            previousManifest: nil,
            schemaVersion: 1
        )

        #expect(plan.requiresFullRebuild)
        #expect(plan.identifiersToUpsert == ["song:b", "song:a"])
        #expect(plan.identifiersToDelete.isEmpty)
    }

    @Test("Upserts follow the record order the caller prioritised, once each")
    func upsertOrder() {
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [
                record("song:recent", "1"),
                record("album:x", "2"),
                record("song:old", "3"),
                record("song:recent", "1"),
            ],
            previousManifest: manifest(["song:kept": "9"]),
            schemaVersion: 1
        )

        #expect(plan.identifiersToUpsert == ["song:recent", "album:x", "song:old"])
        #expect(plan.identifiersToDelete == ["song:kept"])
    }

    @Test("An unchanged library performs no Spotlight work")
    func unchangedLibrary() {
        let previous = manifest(["song:a": "1", "album:b": "2"])
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("album:b", "2"), record("song:a", "1")],
            previousManifest: previous,
            schemaVersion: 1
        )

        #expect(!plan.requiresFullRebuild)
        #expect(plan.isEmpty)
        #expect(plan.nextManifest == previous)
    }

    @Test("Changed, inserted, and deleted items form a minimal plan")
    func incrementalChanges() {
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:a", "changed"), record("song:c", "new")],
            previousManifest: manifest(["song:a": "old", "song:b": "removed"]),
            schemaVersion: 1
        )

        #expect(!plan.requiresFullRebuild)
        #expect(plan.identifiersToUpsert == ["song:a", "song:c"])
        #expect(plan.identifiersToDelete == ["song:b"])
    }

    @Test("An index schema change uses the recovery rebuild path")
    func schemaMigration() {
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:a", "1")],
            previousManifest: manifest(["song:a": "1"], schemaVersion: 1),
            schemaVersion: 2
        )

        #expect(plan.requiresFullRebuild)
        #expect(plan.identifiersToUpsert == ["song:a"])
        #expect(plan.identifiersToDelete.isEmpty)
    }

    @Test("A client-state mismatch can force index recovery")
    func forcedRecovery() {
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:a", "1")],
            previousManifest: manifest(["song:a": "1"]),
            schemaVersion: 1,
            forceFullRebuild: true
        )

        #expect(plan.requiresFullRebuild)
        #expect(plan.identifiersToUpsert == ["song:a"])
    }

    @Test("An interrupted rebuild resumes from its checkpoint instead of starting over")
    func interruptedRebuildResumes() {
        let records = [record("song:a", "1"), record("song:b", "2"), record("song:c", "3")]
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: records,
            previousManifest: nil,
            schemaVersion: 2
        )
        var checkpoint = SpotlightIndexCheckpoint(plan: plan, previousManifest: nil)
        #expect(checkpoint.manifest.signaturesByIdentifier == ["song:a": "", "song:b": "", "song:c": ""])

        checkpoint.confirmIndexed(["song:a": "1"])
        let resumed = SpotlightIndexPlanner.makePlan(
            currentRecords: records,
            previousManifest: checkpoint.manifest,
            schemaVersion: 2
        )

        #expect(!resumed.requiresFullRebuild)
        #expect(resumed.identifiersToUpsert == ["song:b", "song:c"])
        #expect(resumed.identifiersToDelete.isEmpty)
    }

    @Test("Items touched before a checkpoint are reconciled whatever the index holds")
    func unconfirmedItemsAreReconciled() {
        let previous = manifest(["song:a": "1", "song:b": "2", "song:gone": "3"])
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:a", "1"), record("song:b", "changed"), record("song:new", "4")],
            previousManifest: previous,
            schemaVersion: 1
        )
        let checkpoint = SpotlightIndexCheckpoint(plan: plan, previousManifest: previous)

        #expect(checkpoint.manifest.signaturesByIdentifier == [
            "song:a": "1", "song:b": "", "song:new": "", "song:gone": "",
        ])

        // The deleted song is back with its old signature, and the changed one
        // reverted: neither may be skipped as if the index still held it.
        let next = SpotlightIndexPlanner.makePlan(
            currentRecords: [
                record("song:a", "1"), record("song:b", "2"), record("song:gone", "3"),
            ],
            previousManifest: checkpoint.manifest,
            schemaVersion: 1
        )
        #expect(next.identifiersToUpsert == ["song:b", "song:gone"])
        #expect(next.identifiersToDelete == ["song:new"])
    }

    @Test("A partial confirmation keeps the item due for the next run")
    func degradedConfirmation() {
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:a", "full")],
            previousManifest: nil,
            schemaVersion: 1
        )
        var checkpoint = SpotlightIndexCheckpoint(plan: plan, previousManifest: nil)
        checkpoint.confirmIndexed(["song:a": "full~text"])
        checkpoint.confirmDeleted(["song:never-there"])

        let next = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:a", "full")],
            previousManifest: checkpoint.manifest,
            schemaVersion: 1
        )
        #expect(next.identifiersToUpsert == ["song:a"])

        checkpoint.confirmIndexed(["song:a": "full"])
        #expect(checkpoint.manifest == plan.nextManifest)
    }

    private func record(_ identifier: String, _ signature: String) -> SpotlightIndexRecord {
        SpotlightIndexRecord(identifier: identifier, signature: signature)
    }

    private func manifest(
        _ signatures: [String: String],
        schemaVersion: Int = 1
    ) -> SpotlightIndexManifest {
        SpotlightIndexManifest(
            schemaVersion: schemaVersion,
            signaturesByIdentifier: signatures
        )
    }
}
