import Foundation

public struct SpotlightIndexRecoveryRequest: Codable, Equatable, Sendable {
    public let revision: UUID
    public let allItems: Bool
    public let identifiers: Set<String>
}

/// System requests are acknowledged only after this journal is durable. A
/// completed run may clear its own revision, never a newer request's work.
public final class SpotlightIndexRecoveryJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var pending: SpotlightIndexRecoveryRequest?
    public let recoveredUnreadableState: Bool

    public init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                pending = try JSONDecoder().decode(SpotlightIndexRecoveryRequest.self, from: Data(contentsOf: url))
                recoveredUnreadableState = false
            } catch {
                pending = SpotlightIndexRecoveryRequest(revision: UUID(), allItems: true, identifiers: [])
                recoveredUnreadableState = true
            }
        } else {
            pending = nil
            recoveredUnreadableState = false
        }
    }

    public var request: SpotlightIndexRecoveryRequest? { lock.withLock { pending } }

    @discardableResult
    public func record(identifiers: Set<String>?) throws -> SpotlightIndexRecoveryRequest {
        try lock.withLock {
            let allItems = pending?.allItems == true || identifiers == nil
            let next = SpotlightIndexRecoveryRequest(
                revision: UUID(), allItems: allItems,
                identifiers: (pending?.identifiers ?? []).union(identifiers ?? [])
            )
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            pending = next
            return next
        }
    }

    @discardableResult
    public func complete(revision: UUID) throws -> Bool {
        try lock.withLock {
            guard let pending else { return true }
            guard pending.revision == revision else { return false }
            try FileManager.default.removeItem(at: url)
            self.pending = nil
            return true
        }
    }
}
