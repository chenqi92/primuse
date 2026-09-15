import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ServerRatingSyncTests: XCTestCase {
    func testRatingClearAndCommentOnlyEdits() async throws {
        try await withRig { rig in
            rig.edit(5, comment: "keep")
            await rig.settle()
            rig.edit(5, comment: "edited")
            await rig.settle()
            rig.edit(nil, comment: "edited")
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.map(\.rating), [5, 0])
            XCTAssertNil(rig.library.libraryReview(for: rig.subject)?.rating)
            XCTAssertEqual(rig.library.libraryReview(for: rig.subject)?.comment, "edited")
            XCTAssertFalse(try XCTUnwrap(rig.library.storedLibraryReview(for: rig.subject)).isDeleted)
        }
    }

    func testRapidClearSurvivesEarlierWriteConfirmation() async throws {
        try await withRig { rig in
            let gate = RatingGate()
            rig.manager.beforeWrite = { await gate.enter() }
            rig.edit(5)
            await gate.waitUntilEntered()
            rig.manager.beforeWrite = nil
            rig.edit(nil)
            gate.release()
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.map(\.rating), [5, 0])
            XCTAssertNil(rig.library.libraryReview(for: rig.subject))
            XCTAssertEqual(rig.manager.values[rig.target], 0)
        }
    }

    func testOfflineClearPersistsAndRetriesAfterRestart() async throws {
        try await withRig { rig in
            rig.edit(5, comment: "keep")
            await rig.settle()
            rig.manager.writeError = URLError(.notConnectedToInternet)
            rig.edit(nil, comment: "keep")
            await rig.settle()
            XCTAssertNil(rig.library.libraryReview(for: rig.subject)?.rating)
            _ = await rig.library.persistNowAndWait()

            let restored = MusicLibrary(storageDirectory: rig.directory)
            let resumed = ServerRatingSyncService(
                sourceManager: rig.manager, sourcesStore: rig.sources, library: restored, defaults: rig.defaults
            )
            restored.serverRatingTargetProvider = { [weak resumed] in resumed?.target(for: $0) }
            rig.manager.writeError = nil
            resumed.resume()
            await resumed.waitForPendingMutations(sourceID: rig.sourceID)
            XCTAssertEqual(rig.manager.values[rig.target], 0)
            XCTAssertNil(restored.libraryReview(for: rig.subject)?.rating)
            XCTAssertEqual(restored.libraryReview(for: rig.subject)?.comment, "keep")
            _ = await restored.persistNowAndWait()
        }
    }

    func testRetryDoesNotOverwriteAnotherClientsChangedRating() async throws {
        try await withRig { rig in
            rig.edit(5)
            await rig.settle()
            rig.manager.writeError = URLError(.timedOut)
            rig.edit(2)
            await rig.settle()
            let writes = rig.manager.writes.count
            rig.manager.writeError = nil
            rig.manager.values[rig.target] = 3
            rig.service.resume()
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.count, writes)
            XCTAssertEqual(rig.manager.values[rig.target], 3)
            XCTAssertEqual(rig.library.libraryReview(for: rig.subject)?.rating, 2)
            XCTAssertNotNil(rig.library.serverRatingErrorMessage)
            rig.edit(4)
            await rig.settle()
            XCTAssertEqual(rig.manager.values[rig.target], 4)
        }
    }

    func testDurableOutboxRestoresEditMissingFromOlderLibrarySnapshot() async throws {
        try await withRig { rig in
            rig.edit(5, comment: "keep")
            await rig.settle()
            _ = await rig.library.persistNowAndWait()
            await rig.library.beginExternalSnapshotWrite()
            rig.manager.writeError = URLError(.timedOut)
            rig.edit(nil, comment: "keep")
            await rig.settle()
            let restored = MusicLibrary(storageDirectory: rig.directory)
            XCTAssertEqual(restored.libraryReview(for: rig.subject)?.rating, 5)
            let resumed = ServerRatingSyncService(sourceManager: rig.manager, sourcesStore: rig.sources,
                                                  library: restored, defaults: rig.defaults)
            restored.serverRatingTargetProvider = { [weak resumed] in resumed?.target(for: $0) }
            rig.manager.writeError = nil
            resumed.resume()
            await resumed.waitForPendingMutations(sourceID: rig.sourceID)
            XCTAssertNil(restored.libraryReview(for: rig.subject)?.rating)
            XCTAssertEqual(restored.libraryReview(for: rig.subject)?.comment, "keep")
            XCTAssertEqual(rig.manager.values[rig.target], 0)
            _ = await restored.persistNowAndWait()
            rig.library.endExternalSnapshotWrite()
        }
    }

    func testLostWriteResponseIsConfirmedWithoutRepeatingMutation() async throws {
        try await withRig { rig in
            rig.manager.applyBeforeThrowing = true
            rig.manager.writeError = URLError(.timedOut)
            rig.edit(4)
            await rig.settle()
            rig.manager.writeError = nil
            rig.service.resume()
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.map(\.rating), [4])
            XCTAssertEqual(rig.manager.values[rig.target], 4)
        }
    }

    func testConfirmedClearSurvivesRestartBeforeSnapshotPersistence() async throws {
        try await withRig { rig in
            rig.edit(5, comment: "keep")
            await rig.settle()
            _ = await rig.library.persistNowAndWait()
            await rig.library.beginExternalSnapshotWrite()
            rig.edit(nil, comment: "keep")
            await rig.settle()
            let writeCount = rig.manager.writes.count
            let restored = MusicLibrary(storageDirectory: rig.directory)
            XCTAssertEqual(restored.libraryReview(for: rig.subject)?.rating, 5)
            let resumed = ServerRatingSyncService(sourceManager: rig.manager, sourcesStore: rig.sources,
                                                  library: restored, defaults: rig.defaults)
            restored.serverRatingTargetProvider = { [weak resumed] in resumed?.target(for: $0) }
            resumed.resume()
            await resumed.waitForPendingMutations(sourceID: rig.sourceID)
            XCTAssertNil(restored.libraryReview(for: rig.subject)?.rating)
            XCTAssertEqual(restored.libraryReview(for: rig.subject)?.comment, "keep")
            XCTAssertEqual(rig.manager.writes.count, writeCount)
            _ = await restored.persistNowAndWait()
            rig.library.endExternalSnapshotWrite()
        }
    }

    func testAccountChangeDuringReadPreventsWrite() async throws {
        try await withRig { rig in
            let gate = RatingGate()
            rig.manager.beforeRead = { await gate.enter() }
            rig.edit(5)
            await gate.waitUntilEntered()
            rig.sources.items[rig.sourceID]?.username = "different-user"
            gate.release()
            await rig.settle()
            rig.service.resume()
            await rig.settle()
            XCTAssertTrue(rig.manager.writes.isEmpty)
            XCTAssertNil(rig.library.libraryReview(for: rig.subject))
        }
    }

    func testChangedCredentialEpochPreventsOldPendingWrite() async throws {
        try await withRig { rig in
            rig.manager.writeError = URLError(.timedOut)
            rig.edit(4)
            await rig.settle()
            let count = rig.manager.writes.count
            try MusicSourceSecurityRevision.prepareChange(for: rig.sourceID)
            rig.manager.writeError = nil
            rig.service.resume()
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.count, count)
            try MusicSourceSecurityRevision.commitChange(for: rig.sourceID)
            rig.service.resume()
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.count, count)
        }
    }

    func testOpaqueIDsRemainSourceScopedAndRejectNonSongPaths() async throws {
        try await withRig { rig in
            let other = MusicSource(id: "other", name: "Other", type: .navidrome, host: "other.invalid", username: "u")
            let song = Song(id: "other-local", title: "same title", fileFormat: .flac,
                            filePath: "/songs/song.a-42.flac", sourceID: other.id)
            rig.sources.items[other.id] = other
            rig.library.addSongs([song], affectedSourceIDs: [other.id])
            rig.edit(5)
            rig.library.updateLibraryReview(for: .song(song.id), rating: 2, comment: "")
            await rig.settle()
            await rig.service.waitForPendingMutations(sourceID: other.id)
            XCTAssertEqual(rig.manager.values[rig.target], 5)
            XCTAssertEqual(rig.manager.values[try XCTUnwrap(ServerSongRatingTarget.make(song: song, source: other))], 2)
            XCTAssertTrue(rig.manager.writes.allSatisfy { $0.target.itemID == "song.a-42" })
            for path in ["/albums/song.a-42.flac", "/songs/nested/a.mp3", "/songs/.mp3"] {
                var invalid = rig.song
                invalid.filePath = path
                XCTAssertNil(ServerSongRatingTarget.make(song: invalid, source: rig.source))
            }
            var cue = rig.song
            cue.cueSheetPath = "/album.cue"
            cue.cueStartTime = 1
            XCTAssertNil(ServerSongRatingTarget.make(song: cue, source: rig.source))
        }
    }

    func testRemappedSongIDAndChangedSuffixKeepTheNativeRating() async throws {
        try await withRig { rig in
            rig.edit(5, comment: "keep")
            await rig.settle()
            rig.library.remapSongIDs([rig.song.id: "remapped-local"])
            XCTAssertEqual(rig.library.libraryReview(for: .song("remapped-local"))?.rating, 5)
            var renamed = rig.song
            renamed.id = "new-suffix-local"
            renamed.filePath = "/songs/song.a-42.flac"
            rig.library.addSongs([renamed], affectedSourceIDs: [rig.sourceID])
            XCTAssertEqual(rig.library.libraryReview(for: .song(renamed.id))?.rating, 5)
            rig.library.updateLibraryReview(for: .song(renamed.id), rating: nil, comment: "keep")
            await rig.settle()
            XCTAssertNil(rig.library.libraryReview(for: .song("remapped-local"))?.rating)
            XCTAssertEqual(rig.manager.writes.map(\.rating), [5, 0])
        }
    }

    func testSameSecondClearSurvivesISO8601AndCommentMerge() async throws {
        try await withRig { rig in
            let t = 1_800_000_000.0
            rig.library.updateLibraryReview(for: rig.subject, rating: 5, comment: "keep", updatedAt: Date(timeIntervalSince1970: t + 0.1))
            let old = try XCTUnwrap(rig.library.storedLibraryReview(for: rig.subject))
            rig.library.updateLibraryReview(for: rig.subject, rating: nil, comment: "keep", updatedAt: Date(timeIntervalSince1970: t + 0.2))
            let cleared = try XCTUnwrap(rig.library.storedLibraryReview(for: rig.subject))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let copies = try decoder.decode([LibraryReview].self, from: encoder.encode([old, cleared]))
            let merged = LibraryReviewReconciliationPolicy.winner(local: copies[0], remote: copies[1])
            XCTAssertNil(merged.rating)
            XCTAssertEqual(merged.comment, "keep")
            let changedComment = LibraryReview(
                subject: old.subject, rating: old.rating, comment: "new comment",
                updatedAt: Date(timeIntervalSince1970: t + 0.3), deletedAt: nil,
                ratingModifiedAt: old.ratingVersion, commentModifiedAt: t + 0.3,
                serverRatingTarget: old.serverRatingTarget
            )
            let combined = LibraryReviewReconciliationPolicy.winner(local: merged, remote: changedComment)
            XCTAssertNil(combined.rating)
            XCTAssertEqual(combined.comment, "new comment")
            await rig.settle()
        }
    }

    func testExternalSnapshotReloadPreservesConcurrentClearAndDoesNotEnqueue() async throws {
        try await withRig { rig in
            rig.edit(5, comment: "keep")
            await rig.settle()
            _ = await rig.library.persistNowAndWait()
            await rig.library.beginExternalSnapshotWrite()
            rig.edit(nil, comment: "keep")
            rig.library.reloadFromDisk()
            rig.library.endExternalSnapshotWrite()
            await rig.settle()
            XCTAssertNil(rig.library.libraryReview(for: rig.subject)?.rating)
            XCTAssertEqual(rig.library.libraryReview(for: rig.subject)?.comment, "keep")
            XCTAssertEqual(rig.manager.writes.map(\.rating), [5, 0])

            _ = await rig.library.persistNowAndWait()
            let otherSuite = UUID().uuidString
            let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
            defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
            let otherDevice = MusicLibrary(storageDirectory: rig.directory)
            let otherManager = RatingManagerFake()
            let otherService = ServerRatingSyncService(sourceManager: otherManager, sourcesStore: rig.sources,
                                                       library: otherDevice, defaults: otherDefaults)
            otherDevice.serverRatingTargetProvider = { [weak otherService] in otherService?.target(for: $0) }
            otherService.resume()
            await otherService.waitForPendingMutations(sourceID: rig.sourceID)
            XCTAssertTrue(otherManager.writes.isEmpty)
            _ = await otherDevice.persistNowAndWait()
        }
    }

    func testInitialMigrationUploadsOnlyPositiveUnboundSongRatingsOnce() async throws {
        try await withRig { rig in
            rig.library.serverRatingTargetProvider = nil
            rig.library.ratingStateMutationHandler = nil
            rig.edit(4)
            rig.library.updateLibraryReview(for: .album("local-album"), rating: 5, comment: "")
            rig.wire()
            rig.service.resume()
            await rig.settle()
            rig.service.resume()
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.map(\.rating), [4])
        }
    }

    func testIndependentFirstRatingAndCommentMergeWithoutErasingEachOther() async throws {
        try await withRig { rig in
            let ratedSubject = LibraryReviewSubject.album("rated-copy")
            let commentedSubject = LibraryReviewSubject.album("commented-copy")
            rig.library.updateLibraryReview(for: ratedSubject, rating: 5, comment: "",
                                             updatedAt: Date(timeIntervalSince1970: 100))
            rig.library.updateLibraryReview(for: commentedSubject, rating: nil, comment: "keep",
                                             updatedAt: Date(timeIntervalSince1970: 200))
            let rated = try XCTUnwrap(rig.library.libraryReview(for: ratedSubject))
            let commented = try XCTUnwrap(rig.library.libraryReview(for: commentedSubject))
            for (local, remote) in [(rated, commented), (commented, rated)] {
                let merged = LibraryReviewReconciliationPolicy.winner(local: local, remote: remote)
                XCTAssertEqual(merged.rating, 5)
                XCTAssertEqual(merged.comment, "keep")
            }
            XCTAssertTrue(rig.manager.writes.isEmpty)
        }
    }

    func testInitialMigrationCoalescesAliasesBeforeWriting() async throws {
        try await withRig { rig in
            rig.library.serverRatingTargetProvider = nil
            rig.library.ratingStateMutationHandler = nil
            var alias = rig.song
            alias.id = "alias-local"
            alias.filePath = "/songs/song.a-42.flac"
            rig.library.addSongs([rig.song, alias], affectedSourceIDs: [rig.sourceID])
            XCTAssertNotNil(rig.library.songForSynchronization(id: rig.song.id))
            XCTAssertNotNil(rig.library.songForSynchronization(id: alias.id))
            let date = Date(timeIntervalSince1970: 100)
            rig.library.updateLibraryReview(for: rig.subject, rating: 2, comment: "", updatedAt: date)
            rig.library.updateLibraryReview(for: .song(alias.id), rating: 4, comment: "", updatedAt: date)
            rig.wire()
            rig.service.resume()
            await rig.settle()
            XCTAssertEqual(rig.manager.writes.map(\.rating), [4])
            XCTAssertEqual(rig.library.libraryReview(for: rig.subject)?.rating, 4)
        }
    }

    func testLegacyAliasDoesNotAuthorizeReplayingAnImportedClear() async throws {
        try await withRig { rig in
            rig.library.serverRatingTargetProvider = nil
            rig.library.ratingStateMutationHandler = nil
            var alias = rig.song
            alias.id = "legacy-alias"
            alias.filePath = "/songs/song.a-42.flac"
            rig.library.addSongs([rig.song, alias], affectedSourceIDs: [rig.sourceID])
            rig.library.updateLibraryReview(for: .song(alias.id), rating: 4, comment: "",
                                             updatedAt: Date(timeIntervalSince1970: 100))
            rig.library.updateLibraryReview(for: rig.subject, rating: 5, comment: "",
                                             updatedAt: Date(timeIntervalSince1970: 200))
            XCTAssertNotNil(rig.library.bindServerRating(rig.target, to: rig.subject))
            rig.library.updateLibraryReview(for: rig.subject, rating: nil, comment: "",
                                             updatedAt: Date(timeIntervalSince1970: 300))
            rig.wire()
            rig.service.resume()
            await rig.settle()
            XCTAssertTrue(rig.manager.writes.isEmpty)
            XCTAssertNil(rig.library.libraryReview(for: .song(alias.id)))
        }
    }

    private func withRig(_ body: (RatingRig) async throws -> Void) async throws {
        let rig = try RatingRig()
        let directory = rig.directory
        addTeardownBlock {
            // Close library-owned SQLite handles before unlinking the fixture.
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try await body(rig)
            await rig.cleanup()
        } catch {
            await rig.cleanup()
            throw error
        }
    }
}

@MainActor
private final class RatingRig {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let library: MusicLibrary
    let sources = RatingSourcesFake()
    let manager = RatingManagerFake()
    let service: ServerRatingSyncService
    let source: MusicSource
    let song: Song
    var sourceID: String { source.id }
    var subject: LibraryReviewSubject { .song(song.id) }
    var target: ServerSongRatingTarget { ServerSongRatingTarget.make(song: song, source: source)! }

    init() throws {
        suite = "ServerRatingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = MusicSource(id: UUID().uuidString, name: "Navidrome", type: .navidrome,
                             host: "ratings.invalid", username: "user")
        song = Song(id: "local-hash", title: "Test", fileFormat: .mp3,
                    filePath: "/songs/song.a-42.mp3", sourceID: source.id)
        library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults,
                               lyricsSearchIndexRefresh: { _, _, _ in })
        sources.items[source.id] = source
        library.addSongs([song], affectedSourceIDs: [source.id])
        service = ServerRatingSyncService(sourceManager: manager, sourcesStore: sources, library: library, defaults: defaults)
        wire()
    }

    func wire() {
        library.serverRatingTargetProvider = { [weak service] in service?.target(for: $0) }
        library.ratingStateMutationHandler = { [weak service] in service?.localRatingDidChange($0) }
    }

    func edit(_ rating: Int?, comment: String = "") {
        library.updateLibraryReview(for: subject, rating: rating, comment: comment)
    }

    func settle() async { await service.waitForPendingMutations(sourceID: sourceID) }

    func cleanup() async {
        await settle()
        _ = await library.persistNowAndWait()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class RatingSourcesFake: ServerFavoriteSourcesProviding {
    var items: [String: MusicSource] = [:]
    func source(id: String) -> MusicSource? { items[id] }
}

@MainActor
private final class RatingManagerFake: ServerRatingManaging {
    struct Write { let target: ServerSongRatingTarget; let rating: Int }
    var values: [ServerSongRatingTarget: Int] = [:]
    var writes: [Write] = []
    var writeError: Error?
    var applyBeforeThrowing = false
    var beforeRead: (() async -> Void)?
    var beforeWrite: (() async -> Void)?

    func fetchServerRating(target: ServerSongRatingTarget, source: MusicSource) async throws -> Int? {
        await beforeRead?()
        return values[target].flatMap { $0 == 0 ? nil : $0 }
    }

    func setServerRating(target: ServerSongRatingTarget, source: MusicSource, rating: Int?) async throws -> Int? {
        writes.append(Write(target: target, rating: rating ?? 0))
        await beforeWrite?()
        if applyBeforeThrowing { values[target] = rating ?? 0 }
        if let writeError { throw writeError }
        values[target] = rating ?? 0
        return rating
    }
}

@MainActor
private final class RatingGate {
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        started?.resume()
        started = nil
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}
