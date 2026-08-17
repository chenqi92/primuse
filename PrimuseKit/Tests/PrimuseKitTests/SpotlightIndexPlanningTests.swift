import Testing
@testable import PrimuseKit

@Suite("Spotlight incremental index planning")
struct SpotlightIndexPlanningTests {
    @Test("A missing manifest builds the complete index")
    func initialBuild() {
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: [record("song:b", "2"), record("song:a", "1")],
            previousManifest: nil,
            schemaVersion: 1
        )

        #expect(plan.requiresFullRebuild)
        #expect(plan.identifiersToUpsert == ["song:a", "song:b"])
        #expect(plan.identifiersToDelete.isEmpty)
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
