import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback session persistence coalescing")
struct PlaybackSessionPersistenceCoordinatorTests {
    @Test("Rapid saves leave only the newest snapshot on disk, written once")
    func coalescesRapidSaves() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-session-coalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)

        for generation in UInt64(1)...UInt64(5) {
            coordinator.enqueue(
                .save(makeSnapshot(currentTime: Double(generation))),
                generation: generation
            )
        }
        let outcome = coordinator.drain()

        #expect(outcome.performedWrites == 1)
        #expect(outcome.failureDescription == nil)
        #expect(coordinator.performedWriteCount == 1)
        let restored = try #require(try store.load())
        #expect(restored.currentTime == 5)
    }

    @Test("Draining after every enqueue still ends on the final state")
    func drainsEveryRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-session-serial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)

        for generation in UInt64(1)...UInt64(4) {
            coordinator.enqueue(
                .save(makeSnapshot(currentTime: Double(generation) * 10)),
                generation: generation
            )
            coordinator.drain()
        }

        #expect(coordinator.performedWriteCount == 4)
        let restored = try #require(try store.load())
        #expect(restored.currentTime == 40)
    }

    @Test("A late stale request cannot overwrite newer durable state")
    func ignoresStaleGenerations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-session-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)

        coordinator.enqueue(.save(makeSnapshot(currentTime: 90)), generation: 7)
        coordinator.drain()
        coordinator.enqueue(.save(makeSnapshot(currentTime: 5)), generation: 3)
        coordinator.drain()

        #expect(coordinator.performedWriteCount == 1)
        let restored = try #require(try store.load())
        #expect(restored.currentTime == 90)
    }

    @Test("A clear supersedes a save that has not reached the disk yet")
    func clearSupersedesPendingSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-session-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)

        coordinator.enqueue(.save(makeSnapshot(currentTime: 12)), generation: 1)
        coordinator.drain()
        coordinator.enqueue(.save(makeSnapshot(currentTime: 33)), generation: 2)
        coordinator.enqueue(.clear, generation: 3)
        coordinator.drain()

        #expect(try store.load() == nil)
    }

    @Test("A drain reports the newest generation it made durable")
    func reportsLastSuccessfulGeneration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-session-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)

        for generation in UInt64(1)...UInt64(5) {
            coordinator.enqueue(
                .save(makeSnapshot(currentTime: Double(generation))),
                generation: generation
            )
        }
        let outcome = coordinator.drain()

        // The coalesced write carries the newest generation, so an older
        // request that was superseded is durable too.
        #expect(outcome.lastSuccessfulGeneration == 5)
        #expect(coordinator.lastSuccessfulGeneration == 5)
    }

    @Test("A drain with nothing pending still reports what is already durable")
    func reportsDurableGenerationWithoutNewWork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-session-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)

        coordinator.enqueue(.save(makeSnapshot(currentTime: 42)), generation: 9)
        coordinator.drain()
        // A second drainer (for example the background task whose request a
        // synchronous flush already wrote) must not conclude that nothing was
        // persisted just because it found the queue empty.
        let idle = coordinator.drain()

        #expect(idle.performedWrites == 0)
        #expect(idle.failureDescription == nil)
        #expect(idle.lastSuccessfulGeneration == 9)
    }

    @Test("A failed write never reports its generation as durable")
    func failedWriteKeepsPreviousDurableGeneration() throws {
        let containerName = "primuse-session-failure-\(UUID().uuidString)"
        // The same location as a file URL and as a directory URL: the store
        // needs the directory form, the blocking file needs the file form.
        let containerFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(containerName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(containerName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: containerFile) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let coordinator = PlaybackSessionPersistenceCoordinator(store: store)

        coordinator.enqueue(.save(makeSnapshot(currentTime: 7)), generation: 4)
        let firstOutcome = coordinator.drain()
        #expect(firstOutcome.lastSuccessfulGeneration == 4)

        // Replace the container directory with a regular file so the store's
        // directory creation fails the way a full or read-only disk would.
        try FileManager.default.removeItem(at: containerFile)
        try Data().write(to: containerFile)

        coordinator.enqueue(.save(makeSnapshot(currentTime: 8)), generation: 5)
        let failedOutcome = coordinator.drain()

        #expect(failedOutcome.performedWrites == 0)
        #expect(failedOutcome.failureDescription != nil)
        // Generation 5 is not durable, so a caller waiting on it must not be
        // told that its session reached the disk.
        #expect(failedOutcome.lastSuccessfulGeneration == 4)
    }

    private func makeSnapshot(currentTime: TimeInterval) -> PlaybackSessionSnapshot {
        PlaybackSessionSnapshot(
            queueSongIDs: ["a", "b", "c"],
            currentSongID: "b",
            currentIndex: 1,
            currentTime: currentTime,
            duration: 200,
            wasPlaying: true,
            shuffleEnabled: false,
            shuffledIndices: [],
            shufflePosition: 0,
            repeatMode: .off,
            isAtTrackEnd: false
        )
    }
}
