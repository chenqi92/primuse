import Darwin
import Foundation
import PrimuseKit

/// Durable credential epochs shared by every target that persists or publishes
/// a `MusicSource`. Keeping this outside `SourceManager` lets tvOS publish the
/// same security-scoped identity without compiling the iOS/macOS connector graph.
enum MusicSourceSecurityRevision {
    private struct PersistedState: Codable {
        var revisionsBySourceID: [String: UInt64] = [:]
        var pendingRevisionsBySourceID: [String: UInt64] = [:]
        var cacheNamespacesBySourceID: [String: String] = [:]

        private enum CodingKeys: String, CodingKey {
            case revisionsBySourceID
            case pendingRevisionsBySourceID
            case cacheNamespacesBySourceID
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            revisionsBySourceID = try container.decodeIfPresent(
                [String: UInt64].self,
                forKey: .revisionsBySourceID
            ) ?? [:]
            pendingRevisionsBySourceID = try container.decodeIfPresent(
                [String: UInt64].self,
                forKey: .pendingRevisionsBySourceID
            ) ?? [:]
            cacheNamespacesBySourceID = try container.decodeIfPresent(
                [String: String].self,
                forKey: .cacheNamespacesBySourceID
            ) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(revisionsBySourceID, forKey: .revisionsBySourceID)
            if !pendingRevisionsBySourceID.isEmpty {
                try container.encode(
                    pendingRevisionsBySourceID,
                    forKey: .pendingRevisionsBySourceID
                )
            }
            if !cacheNamespacesBySourceID.isEmpty {
                try container.encode(
                    cacheNamespacesBySourceID,
                    forKey: .cacheNamespacesBySourceID
                )
            }
        }

        func effectiveRevision(for sourceID: String) -> UInt64 {
            pendingRevisionsBySourceID[sourceID]
                ?? revisionsBySourceID[sourceID]
                ?? 0
        }
    }

    private static let stateFileName = "source_security_revisions.json"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedState: PersistedState?
    private static let unavailableRevision = UUID().uuidString

    private static var stateURL: URL {
        #if os(tvOS)
        let root = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let root = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return root.appendingPathComponent(stateFileName)
    }

    static func revision(for sourceID: String) -> UInt64? {
        try? lock.withLock {
            try loadStateIfNeeded().effectiveRevision(for: sourceID)
        }
    }

    static func hasPendingChange(for sourceID: String) -> Bool {
        lock.withLock {
            do {
                return try loadStateIfNeeded().pendingRevisionsBySourceID[sourceID] != nil
            } catch {
                return true
            }
        }
    }

    static func cacheNamespace(for sourceID: String) -> String {
        lock.withLock {
            do {
                return try loadStateIfNeeded().cacheNamespacesBySourceID[sourceID]
                    ?? "unavailable-\(unavailableRevision)"
            } catch {
                return "unavailable-\(unavailableRevision)"
            }
        }
    }

    static func registerCacheNamespace(
        sourceID: String,
        scopedFingerprint: String
    ) throws {
        try lock.withLock {
            var state = try loadStateIfNeeded()
            let namespace = cacheNamespace(scopedFingerprint: scopedFingerprint)
            guard state.cacheNamespacesBySourceID[sourceID] != namespace else {
                return
            }
            state.cacheNamespacesBySourceID[sourceID] = namespace
            try persistDurably(state)
            cachedState = state
        }
    }

    static func cacheNamespace(scopedFingerprint: String) -> String {
        "s\(scopedFingerprint)"
    }

    @discardableResult
    static func prepareChange(for sourceID: String) throws -> UInt64 {
        try lock.withLock {
            var state = try loadStateIfNeeded()
            let current = max(
                state.revisionsBySourceID[sourceID] ?? 0,
                state.pendingRevisionsBySourceID[sourceID] ?? 0
            )
            let incremented = current.addingReportingOverflow(1)
            guard !incremented.overflow, incremented.partialValue != 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            let next = incremented.partialValue
            state.pendingRevisionsBySourceID[sourceID] = next
            try persistDurably(state)
            cachedState = state
            return next
        }
    }

    @discardableResult
    static func commitChange(for sourceID: String) throws -> UInt64 {
        try lock.withLock {
            var state = try loadStateIfNeeded()
            guard let pending = state.pendingRevisionsBySourceID[sourceID] else {
                return state.revisionsBySourceID[sourceID] ?? 0
            }
            state.revisionsBySourceID[sourceID] = pending
            state.pendingRevisionsBySourceID.removeValue(forKey: sourceID)
            try persistDurably(state)
            cachedState = state
            return pending
        }
    }

    static func abortChange(for sourceID: String) throws {
        try lock.withLock {
            var state = try loadStateIfNeeded()
            guard state.pendingRevisionsBySourceID.removeValue(forKey: sourceID) != nil else {
                return
            }
            try persistDurably(state)
            cachedState = state
        }
    }

    static func scopedFingerprint(
        for source: MusicSource,
        revision explicitRevision: UInt64? = nil
    ) -> String {
        let revisionIdentity: String
        if let explicitRevision {
            revisionIdentity = String(explicitRevision)
        } else {
            revisionIdentity = lock.withLock {
                do {
                    return String(
                        try loadStateIfNeeded().effectiveRevision(for: source.id)
                    )
                } catch {
                    // A missing/corrupt/unreadable state must never collapse to
                    // a previously trusted epoch. A per-process fail-closed
                    // value makes existing durable provenance mismatch.
                    return "unavailable-\(unavailableRevision)"
                }
            }
        }
        return MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revisionIdentity: revisionIdentity
        )
    }

    #if DEBUG
    static func reloadPersistedStateForTesting() {
        lock.withLock { cachedState = nil }
    }
    #endif

    private static func loadStateIfNeeded() throws -> PersistedState {
        if let cachedState { return cachedState }
        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let state = PersistedState()
            cachedState = state
            return state
        }
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        cachedState = state
        return state
    }

    private static func persistDurably(_ state: PersistedState) throws {
        let url = stateURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        try synchronizeFileSystemObject(at: url, fullSync: true)
        try synchronizeFileSystemObject(at: directory, fullSync: false)
    }

    private static func synchronizeFileSystemObject(
        at url: URL,
        fullSync: Bool
    ) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }

        if fullSync, Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
