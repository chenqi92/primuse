import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ServerListeningStatsServiceTests: XCTestCase {
    func testSnapshotStoreSeparatesSourcesAndConfigurations() async throws {
        try await withSnapshotStore { store, _ in
            let first = makeSource(id: "first", username: "alice")
            let second = makeSource(id: "second", username: "alice")
            let firstSnapshot = makeSnapshot(
                source: first,
                account: "account-a",
                fetchedAt: Date(timeIntervalSince1970: 100)
            )

            try await store.save(firstSnapshot)
            let loadedFirst = await store.load(for: first)
            let loadedSecond = await store.load(for: second)
            XCTAssertEqual(loadedFirst?.snapshot, firstSnapshot)
            XCTAssertNil(loadedSecond)

            var edited = first
            edited.username = "bob"
            let loadedEditedBeforeSave = await store.load(for: edited)
            XCTAssertNil(loadedEditedBeforeSave)

            let editedSnapshot = makeSnapshot(
                source: edited,
                account: "account-b",
                fetchedAt: Date(timeIntervalSince1970: 200)
            )
            try await store.save(editedSnapshot)
            let loadedOldConfiguration = await store.load(for: first)
            let loadedEdited = await store.load(for: edited)
            XCTAssertNil(loadedOldConfiguration)
            XCTAssertEqual(loadedEdited?.snapshot, editedSnapshot)
        }
    }

    func testSnapshotStoreRecoversLastTrustedBackup() async throws {
        try await withSnapshotStore { store, directoryURL in
            let source = makeSource()
            let first = makeSnapshot(
                source: source,
                account: "account-a",
                fetchedAt: Date(timeIntervalSince1970: 100)
            )
            let second = makeSnapshot(
                source: source,
                account: "account-a",
                fetchedAt: Date(timeIntervalSince1970: 200)
            )
            try await store.save(first)
            try await store.save(second)

            try Data("not-json".utf8).write(
                to: directoryURL.appendingPathComponent(
                    ServerListeningStatsSnapshotStore.fileName
                )
            )
            let loaded = await store.load(for: source)
            let recovered = try XCTUnwrap(loaded)
            XCTAssertEqual(recovered.snapshot, first)
            XCTAssertTrue(recovered.recoveredFromBackup)
        }
    }

    func testOfflineRefreshKeepsExpiredSnapshotAndMarksItStale() async throws {
        try await withSnapshotStore { store, _ in
            let now = Date(timeIntervalSince1970: 500_000)
            let source = makeSource()
            let cached = makeSnapshot(
                source: source,
                account: "account-a",
                fetchedAt: now.addingTimeInterval(
                    -ServerListeningStatsService.freshnessInterval - 1
                )
            )
            try await store.save(cached)
            let service = ServerListeningStatsService(
                snapshotStore: store,
                now: { now },
                fetchPayload: { _ in throw FixtureError.offline }
            )

            await service.activate(source: source)

            XCTAssertEqual(service.snapshot, cached)
            XCTAssertTrue(service.staleReasons.contains(.expired))
            XCTAssertTrue(service.staleReasons.contains(.refreshFailed))
            XCTAssertNotNil(service.errorMessage)
            XCTAssertFalse(service.isRefreshing)
        }
    }

    func testFutureDatedSnapshotIsMarkedForClockChange() async throws {
        try await withSnapshotStore { store, _ in
            let now = Date(timeIntervalSince1970: 500_000)
            let source = makeSource()
            try await store.save(makeSnapshot(
                source: source,
                account: "account-a",
                fetchedAt: now.addingTimeInterval(
                    ServerListeningStatsService.futureClockTolerance + 1
                )
            ))
            let service = ServerListeningStatsService(
                snapshotStore: store,
                now: { now },
                fetchPayload: { _ in throw FixtureError.offline }
            )

            await service.activate(source: source)

            XCTAssertTrue(service.staleReasons.contains(.clockChanged))
            XCTAssertTrue(service.staleReasons.contains(.refreshFailed))
        }
    }

    func testInitialRefreshFailureDoesNotClaimCachedDataIsShown() async {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "primuse-listening-stats-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let service = ServerListeningStatsService(
            snapshotStore: ServerListeningStatsSnapshotStore(directoryURL: directoryURL),
            fetchPayload: { _ in throw FixtureError.offline }
        )

        await service.activate(source: makeSource())

        XCTAssertNil(service.snapshot)
        XCTAssertTrue(service.staleReasons.isEmpty)
        XCTAssertFalse(service.isStale)
        XCTAssertNotNil(service.errorMessage)
    }

    func testSuccessfulRefreshReplacesCachedAccountAndClearsStaleState() async throws {
        try await withSnapshotStore { store, _ in
            let now = Date(timeIntervalSince1970: 500_000)
            let source = makeSource()
            try await store.save(makeSnapshot(
                source: source,
                account: "old-account",
                fetchedAt: now.addingTimeInterval(-100_000)
            ))
            let newPayload = makePayload(account: "new-account", playCount: 9)
            let service = ServerListeningStatsService(
                snapshotStore: store,
                now: { now },
                fetchPayload: { _ in newPayload }
            )

            await service.activate(source: source)

            XCTAssertEqual(service.snapshot?.payload, newPayload)
            XCTAssertEqual(service.snapshot?.fetchedAt, now)
            XCTAssertTrue(service.staleReasons.isEmpty)
            XCTAssertNil(service.errorMessage)
            let stored = await store.load(for: source)
            XCTAssertEqual(stored?.snapshot.payload.accountFingerprint, "new-account")
        }
    }

    func testCancellationDoesNotOverwriteCachedSnapshotOrBecomeFailure() async throws {
        try await withSnapshotStore { store, _ in
            let now = Date(timeIntervalSince1970: 500_000)
            let source = makeSource()
            let cached = makeSnapshot(
                source: source,
                account: "cached-account",
                fetchedAt: now
            )
            try await store.save(cached)
            let probe = FetchProbe()
            let service = ServerListeningStatsService(
                snapshotStore: store,
                now: { now },
                fetchPayload: { _ in
                    probe.started = true
                    try await Task.sleep(for: .seconds(30))
                    return self.makePayload(account: "late-account", playCount: 99)
                }
            )

            let task = Task { await service.activate(source: source) }
            while !probe.started {
                await Task.yield()
            }
            task.cancel()
            await task.value

            XCTAssertEqual(service.snapshot, cached)
            XCTAssertFalse(service.staleReasons.contains(.refreshFailed))
            XCTAssertNil(service.errorMessage)
            XCTAssertFalse(service.isRefreshing)
            let stored = await store.load(for: source)
            XCTAssertEqual(stored?.snapshot.payload.accountFingerprint, "cached-account")
        }
    }

    private func withSnapshotStore(
        _ body: (
            ServerListeningStatsSnapshotStore,
            URL
        ) async throws -> Void
    ) async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "primuse-listening-stats-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ServerListeningStatsSnapshotStore(directoryURL: directoryURL)
        try await body(store, directoryURL)
    }

    private func makeSource(
        id: String = "server",
        username: String = "alice"
    ) -> MusicSource {
        MusicSource(
            id: id,
            name: "Server",
            type: .navidrome,
            host: "music.example.com",
            username: username,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makePayload(
        account: String,
        playCount: Int = 3
    ) -> ServerListeningStatsPayload {
        ServerListeningStatsPayload(
            accountFingerprint: account,
            temporalDetail: .aggregate,
            tracks: [
                ServerListeningTrackAggregate(
                    remoteTrackID: "track-1",
                    title: "Track",
                    playCount: playCount,
                    lastPlayedAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        )
    }

    private func makeSnapshot(
        source: MusicSource,
        account: String,
        fetchedAt: Date
    ) -> ServerListeningStatsSnapshot {
        ServerListeningStatsSnapshot(
            sourceID: source.id,
            sourceType: source.type,
            configurationFingerprint: ServerListeningStatsFingerprint.configuration(for: source),
            fetchedAt: fetchedAt,
            payload: makePayload(account: account)
        )
    }

    private enum FixtureError: Error {
        case offline
    }

    @MainActor
    private final class FetchProbe {
        var started = false
    }
}
