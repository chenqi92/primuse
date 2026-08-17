import Foundation

/// A compact, deterministic description of one item managed by Primuse's
/// Core Spotlight index. The signature contains only fields exposed to
/// Spotlight, so unrelated library mutations do not cause redundant updates.
public struct SpotlightIndexRecord: Codable, Equatable, Sendable {
    public let identifier: String
    public let signature: String

    public init(identifier: String, signature: String) {
        self.identifier = identifier
        self.signature = signature
    }
}

/// The last library state successfully committed to Core Spotlight.
public struct SpotlightIndexManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let signaturesByIdentifier: [String: String]

    public init(schemaVersion: Int, signaturesByIdentifier: [String: String]) {
        self.schemaVersion = schemaVersion
        self.signaturesByIdentifier = signaturesByIdentifier
    }
}

/// The minimal set of mutations needed to converge a Spotlight index with the
/// latest library snapshot.
public struct SpotlightIndexPlan: Equatable, Sendable {
    public let identifiersToUpsert: [String]
    public let identifiersToDelete: [String]
    public let requiresFullRebuild: Bool
    public let nextManifest: SpotlightIndexManifest

    public var isEmpty: Bool {
        identifiersToUpsert.isEmpty && identifiersToDelete.isEmpty
    }

    public init(
        identifiersToUpsert: [String],
        identifiersToDelete: [String],
        requiresFullRebuild: Bool,
        nextManifest: SpotlightIndexManifest
    ) {
        self.identifiersToUpsert = identifiersToUpsert
        self.identifiersToDelete = identifiersToDelete
        self.requiresFullRebuild = requiresFullRebuild
        self.nextManifest = nextManifest
    }
}

public enum SpotlightIndexPlanner {
    public static func makePlan(
        currentRecords: [SpotlightIndexRecord],
        previousManifest: SpotlightIndexManifest?,
        schemaVersion: Int,
        forceFullRebuild: Bool = false
    ) -> SpotlightIndexPlan {
        var currentSignatures: [String: String] = [:]
        currentSignatures.reserveCapacity(currentRecords.count)
        for record in currentRecords {
            currentSignatures[record.identifier] = record.signature
        }

        let nextManifest = SpotlightIndexManifest(
            schemaVersion: schemaVersion,
            signaturesByIdentifier: currentSignatures
        )
        let requiresFullRebuild = forceFullRebuild
            || previousManifest?.schemaVersion != schemaVersion

        if requiresFullRebuild {
            return SpotlightIndexPlan(
                identifiersToUpsert: currentSignatures.keys.sorted(),
                identifiersToDelete: [],
                requiresFullRebuild: true,
                nextManifest: nextManifest
            )
        }

        let previousSignatures = previousManifest?.signaturesByIdentifier ?? [:]
        let identifiersToUpsert = currentSignatures.compactMap { identifier, signature in
            previousSignatures[identifier] == signature ? nil : identifier
        }.sorted()
        let identifiersToDelete = previousSignatures.keys.filter {
            currentSignatures[$0] == nil
        }.sorted()

        return SpotlightIndexPlan(
            identifiersToUpsert: identifiersToUpsert,
            identifiersToDelete: identifiersToDelete,
            requiresFullRebuild: false,
            nextManifest: nextManifest
        )
    }
}
