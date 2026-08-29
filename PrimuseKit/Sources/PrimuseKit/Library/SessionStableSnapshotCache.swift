import Foundation

public struct SessionStableSnapshotBuild: Equatable, Sendable {
    public let revision: String
    public let generation: UInt64
    public let randomSeed: String
}

/// A process-local cache for view snapshots that should survive navigation but
/// never survive an app relaunch. Revisions invalidate stale content while a
/// manual refresh rotates the seed and rejects every older in-flight build.
public struct SessionStableSnapshotCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let revision: String
        let value: Value
    }

    private let sessionSeed: String
    private var refreshGeneration: UInt64 = 0
    private var buildGeneration: UInt64 = 0
    private var entry: Entry?

    public init(sessionSeed: String = UUID().uuidString) {
        self.sessionSeed = sessionSeed
    }

    public func cachedValue(for revision: String) -> Value? {
        guard entry?.revision == revision else { return nil }
        return entry?.value
    }

    public mutating func beginBuild(for revision: String) -> SessionStableSnapshotBuild {
        buildGeneration &+= 1
        return SessionStableSnapshotBuild(
            revision: revision,
            generation: buildGeneration,
            randomSeed: "\(sessionSeed)#\(refreshGeneration)"
        )
    }

    public func isCurrentBuild(_ build: SessionStableSnapshotBuild) -> Bool {
        build.generation == buildGeneration
    }

    @discardableResult
    public mutating func commit(
        _ value: Value,
        for build: SessionStableSnapshotBuild
    ) -> Bool {
        guard build.generation == buildGeneration else { return false }
        entry = Entry(revision: build.revision, value: value)
        return true
    }

    public mutating func invalidateForManualRefresh() {
        refreshGeneration &+= 1
        buildGeneration &+= 1
        entry = nil
    }
}
