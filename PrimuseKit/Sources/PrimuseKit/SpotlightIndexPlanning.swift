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
/// latest library snapshot. Upserts keep the order of the current records, so
/// the caller decides which items become searchable first.
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
        var orderedIdentifiers: [String] = []
        orderedIdentifiers.reserveCapacity(currentRecords.count)
        for record in currentRecords {
            if currentSignatures.updateValue(record.signature, forKey: record.identifier) == nil {
                orderedIdentifiers.append(record.identifier)
            }
        }

        let nextManifest = SpotlightIndexManifest(
            schemaVersion: schemaVersion,
            signaturesByIdentifier: currentSignatures
        )
        let requiresFullRebuild = forceFullRebuild
            || previousManifest?.schemaVersion != schemaVersion

        if requiresFullRebuild {
            return SpotlightIndexPlan(
                identifiersToUpsert: orderedIdentifiers,
                identifiersToDelete: [],
                requiresFullRebuild: true,
                nextManifest: nextManifest
            )
        }

        let previousSignatures = previousManifest?.signaturesByIdentifier ?? [:]
        let identifiersToUpsert = orderedIdentifiers.filter { identifier in
            previousSignatures[identifier] != currentSignatures[identifier]
        }
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

/// The manifest an interrupted synchronization leaves behind, so the next run
/// continues where this one stopped instead of rebuilding from nothing.
///
/// Every item the plan touches is first recorded as unconfirmed: whatever
/// happens to it in the index before the next checkpoint, a later plan upserts
/// it again if it is still in the library and deletes it otherwise. An item
/// moves to its real signature only after the batch carrying it has been
/// committed, so the manifest never claims more than the index holds.
public struct SpotlightIndexCheckpoint: Equatable, Sendable {
    /// No real signature is empty, so an unconfirmed item never matches.
    public static let unconfirmedSignature = ""

    public let schemaVersion: Int
    public private(set) var signaturesByIdentifier: [String: String]

    public init(plan: SpotlightIndexPlan, previousManifest: SpotlightIndexManifest?) {
        var signatures = plan.requiresFullRebuild
            ? [:]
            : previousManifest?.signaturesByIdentifier ?? [:]
        for identifier in plan.identifiersToUpsert {
            signatures[identifier] = Self.unconfirmedSignature
        }
        for identifier in plan.identifiersToDelete {
            signatures[identifier] = Self.unconfirmedSignature
        }
        schemaVersion = plan.nextManifest.schemaVersion
        signaturesByIdentifier = signatures
    }

    public var manifest: SpotlightIndexManifest {
        SpotlightIndexManifest(
            schemaVersion: schemaVersion,
            signaturesByIdentifier: signaturesByIdentifier
        )
    }

    /// Records committed upserts. A signature other than the one the plan
    /// wants (an item indexed without its thumbnail, say) keeps it due for the
    /// next run.
    public mutating func confirmIndexed(_ signatures: [String: String]) {
        for (identifier, signature) in signatures {
            signaturesByIdentifier[identifier] = signature
        }
    }

    public mutating func confirmDeleted(_ identifiers: some Sequence<String>) {
        for identifier in identifiers {
            signaturesByIdentifier.removeValue(forKey: identifier)
        }
    }
}
