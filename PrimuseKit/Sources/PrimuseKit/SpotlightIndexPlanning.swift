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
/// committed. Query visibility is verified separately from these write acknowledgments.
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

/// Search availability and content freshness are independent: an old cover or
/// signature does not remove an item from search. Manifest-only counts are
/// estimates until a system query confirms visibility.
public struct SpotlightIndexCoverage: Equatable, Sendable {
    public let total: Int
    public let indexed: Int
    public let awaitingArtwork: Int
    public let awaitingUpdate: Int
    public let isVerified: Bool

    public init(total: Int, indexed: Int, awaitingArtwork: Int, awaitingUpdate: Int = 0, isVerified: Bool = false) {
        self.total = max(0, total)
        self.indexed = min(max(0, indexed), self.total)
        self.awaitingArtwork = min(max(0, awaitingArtwork), self.total - self.indexed)
        self.awaitingUpdate = min(max(0, awaitingUpdate), self.total - self.indexed - self.awaitingArtwork)
        self.isVerified = isVerified || self.total == 0
    }

    /// Confirmed by a query when `isVerified`; otherwise the current write estimate.
    public var searchable: Int { indexed + awaitingArtwork + awaitingUpdate }
    public var remaining: Int { total - searchable }
    public var isComplete: Bool { indexed == total && isVerified }
    public var fraction: Double { total > 0 ? Double(searchable) / Double(total) : 1 }

    /// - Parameters:
    ///   - wanted: the manifest the library wants (`SpotlightIndexPlan.nextManifest`).
    ///   - stored: what the index holds (the saved manifest or a checkpoint);
    ///     another schema version means the index is rebuilt and holds none.
    ///   - textOnlySuffix: what marks an item indexed without its cover.
    ///   - foundIdentifiers: identifiers returned by the system, if available.
    ///   - isVerified: false when identifiers include writes not yet queried.
    public static func measure(
        wanted: SpotlightIndexManifest,
        stored: SpotlightIndexManifest?,
        textOnlySuffix: String,
        foundIdentifiers: Set<String>? = nil,
        isVerified: Bool = true
    ) -> SpotlightIndexCoverage {
        let wantedSignatures = wanted.signaturesByIdentifier
        guard let stored, stored.schemaVersion == wanted.schemaVersion else {
            return SpotlightIndexCoverage(total: wantedSignatures.count, indexed: 0, awaitingArtwork: 0)
        }
        var indexed = 0
        var awaitingArtwork = 0
        var awaitingUpdate = 0
        for (identifier, signature) in wantedSignatures {
            let held = stored.signaturesByIdentifier[identifier] ?? ""
            if let foundIdentifiers {
                guard foundIdentifiers.contains(identifier) else { continue }
            } else if held.isEmpty {
                continue
            }
            if held == signature {
                indexed += 1
            } else if !textOnlySuffix.isEmpty, held == signature + textOnlySuffix {
                awaitingArtwork += 1
            } else {
                awaitingUpdate += 1
            }
        }
        return SpotlightIndexCoverage(
            total: wantedSignatures.count,
            indexed: indexed,
            awaitingArtwork: awaitingArtwork,
            awaitingUpdate: awaitingUpdate,
            isVerified: isVerified && foundIdentifiers != nil
        )
    }
}

/// 清单记着已经写进去、系统索引里却查不到的条目 (#346)。进度原来只拿 App 自己的清单算,
/// 系统那边丢了一部分时照样显示「都能搜到」。设置页打开时把 App 自己的条目从索引里查一遍,
/// 跟清单对上。
public enum SpotlightIndexVerification {
    public enum Outcome: Equatable, Sendable {
        case consistent
        /// 清单里有真签名、索引里查不到的条目。
        case missing(Set<String>)
        /// 清单里有东西却一条都没查到: 更像是这次查询本身没成, 不据此改清单。
        case inconclusive
    }

    public static func compare(
        manifest: SpotlightIndexManifest,
        found: Set<String>
    ) -> Outcome {
        let confirmed = manifest.signaturesByIdentifier.compactMap { identifier, signature in
            signature.isEmpty ? nil : identifier
        }
        guard !confirmed.isEmpty else { return .consistent }
        guard !found.isEmpty else { return .inconclusive }
        let missing = Set(confirmed).subtracting(found)
        return missing.isEmpty ? .consistent : .missing(missing)
    }

    /// 查不到的条目改回未确认, 下一轮计划会重新写它们。清单里没有的标识不加进去。
    public static func manifest(
        _ manifest: SpotlightIndexManifest,
        markingUnconfirmed identifiers: Set<String>
    ) -> SpotlightIndexManifest {
        var signatures = manifest.signaturesByIdentifier
        for identifier in identifiers where signatures[identifier] != nil {
            signatures[identifier] = SpotlightIndexCheckpoint.unconfirmedSignature
        }
        return SpotlightIndexManifest(
            schemaVersion: manifest.schemaVersion,
            signaturesByIdentifier: signatures
        )
    }
}
