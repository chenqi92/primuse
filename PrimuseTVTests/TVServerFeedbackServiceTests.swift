#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

private actor TVServerFeedbackClientStub: TVServerFeedbackClient {
    enum Outcome: Sendable {
        case value(Bool)
        case timedOut
        case rejected
    }

    struct FavoriteCall: Equatable, Sendable {
        let sourceID: String
        let songID: String
        let desired: Bool
    }

    struct ReportCall: Equatable, Sendable {
        let sourceID: String
        let feedback: TVServerPlaybackFeedback
    }

    private var favoriteOutcomes: [String: [Outcome]] = [:]
    private var reportOutcomes: [String: [Outcome]] = [:]
    private var blockedFavoriteSources: Set<String> = []
    private var blockedReportSources: Set<String> = []
    private var favoriteWaiters: [String: CheckedContinuation<Bool, Error>] = [:]
    private var reportWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var favoriteCalls: [FavoriteCall] = []
    private var reportCalls: [ReportCall] = []
    private var invalidatedSourceIDs: [String] = []

    func enqueueFavoriteOutcomes(_ values: [Outcome], sourceID: String) {
        favoriteOutcomes[sourceID] = values
    }

    func enqueueReportOutcomes(_ values: [Outcome], sourceID: String) {
        reportOutcomes[sourceID] = values
    }

    func blockNextFavorite(sourceID: String) {
        blockedFavoriteSources.insert(sourceID)
    }

    func blockNextReport(sourceID: String) {
        blockedReportSources.insert(sourceID)
    }

    func releaseFavorite(sourceID: String, outcome: Outcome) {
        guard let waiter = favoriteWaiters.removeValue(forKey: sourceID) else { return }
        switch outcome {
        case .value(let value): waiter.resume(returning: value)
        case .timedOut: waiter.resume(throwing: URLError(.timedOut))
        case .rejected: waiter.resume(throwing: TVServerFeedbackError.favoriteMismatch)
        }
    }

    func releaseReport(sourceID: String, outcome: Outcome = .value(true)) {
        guard let waiter = reportWaiters.removeValue(forKey: sourceID) else { return }
        switch outcome {
        case .value: waiter.resume(returning: ())
        case .timedOut: waiter.resume(throwing: URLError(.timedOut))
        case .rejected: waiter.resume(throwing: TVServerFeedbackError.invalidResponse)
        }
    }

    func setFavorite(
        song: Song,
        source: MusicSource,
        credential _: SourceCredential,
        desired: Bool
    ) async throws -> Bool {
        favoriteCalls.append(.init(sourceID: source.id, songID: song.id, desired: desired))
        if blockedFavoriteSources.remove(source.id) != nil {
            return try await withCheckedThrowingContinuation { continuation in
                favoriteWaiters[source.id] = continuation
            }
        }
        let outcome = popFavoriteOutcome(sourceID: source.id)
            ?? .value(desired)
        switch outcome {
        case .value(let value): return value
        case .timedOut: throw URLError(.timedOut)
        case .rejected: throw TVServerFeedbackError.favoriteMismatch
        }
    }

    func report(
        _ feedback: TVServerPlaybackFeedback,
        source: MusicSource,
        credential _: SourceCredential
    ) async throws {
        reportCalls.append(.init(sourceID: source.id, feedback: feedback))
        if blockedReportSources.remove(source.id) != nil {
            try await withCheckedThrowingContinuation { continuation in
                reportWaiters[source.id] = continuation
            }
            return
        }
        let outcome = popReportOutcome(sourceID: source.id)
            ?? .value(true)
        switch outcome {
        case .value: return
        case .timedOut: throw URLError(.timedOut)
        case .rejected: throw TVServerFeedbackError.invalidResponse
        }
    }

    func invalidate(source: MusicSource) async {
        invalidatedSourceIDs.append(source.id)
    }

    func favoriteCallSnapshot() -> [FavoriteCall] { favoriteCalls }
    func reportCallSnapshot() -> [ReportCall] { reportCalls }
    func invalidationSnapshot() -> [String] { invalidatedSourceIDs }
    func hasFavoriteWaiter(sourceID: String) -> Bool { favoriteWaiters[sourceID] != nil }
    func hasReportWaiter(sourceID: String) -> Bool { reportWaiters[sourceID] != nil }

    private func popFavoriteOutcome(sourceID: String) -> Outcome? {
        guard var sourceValues = favoriteOutcomes[sourceID], !sourceValues.isEmpty else { return nil }
        let value = sourceValues.removeFirst()
        favoriteOutcomes[sourceID] = sourceValues
        return value
    }

    private func popReportOutcome(sourceID: String) -> Outcome? {
        guard var sourceValues = reportOutcomes[sourceID], !sourceValues.isEmpty else { return nil }
        let value = sourceValues.removeFirst()
        reportOutcomes[sourceID] = sourceValues
        return value
    }
}

@MainActor
final class TVServerFeedbackServiceTests: XCTestCase {
    func testProviderBoundariesMatchSharedConnectors() {
        XCTAssertTrue(TVServerFeedbackPolicy.supportsFavorite(.subsonic))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsFavorite(.navidrome))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsFavorite(.emby))
        XCTAssertFalse(TVServerFeedbackPolicy.supportsFavorite(.airsonic))
        XCTAssertFalse(TVServerFeedbackPolicy.supportsFavorite(.gonic))
        XCTAssertFalse(TVServerFeedbackPolicy.supportsFavorite(.jellyfin))
        XCTAssertFalse(TVServerFeedbackPolicy.supportsFavorite(.fnMusic))

        XCTAssertTrue(TVServerFeedbackPolicy.supportsNowPlaying(.subsonic))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsNowPlaying(.navidrome))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsNowPlaying(.airsonic))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsNowPlaying(.gonic))
        XCTAssertFalse(TVServerFeedbackPolicy.supportsNowPlaying(.fnMusic))

        XCTAssertTrue(TVServerFeedbackPolicy.supportsScrobble(.subsonic))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsScrobble(.navidrome))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsScrobble(.airsonic))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsScrobble(.gonic))
        XCTAssertTrue(TVServerFeedbackPolicy.supportsScrobble(.fnMusic))
        XCTAssertFalse(TVServerFeedbackPolicy.supportsScrobble(.emby))
    }

    func testTransientFavoriteFailureRetriesThenKeepsOptimisticState() async {
        let source = makeSource(id: "retry", type: .navidrome)
        let song = makeSong(id: "retry-song", sourceID: source.id)
        let client = TVServerFeedbackClientStub()
        await client.enqueueFavoriteOutcomes([.timedOut, .value(true)], sourceID: source.id)
        var liked = [song.id: true]
        var errors: [String] = []
        let service = makeService(
            sources: [source.id: source],
            liked: { liked[$0] ?? false },
            applyLiked: { liked[$0] = $1 },
            reportError: { errors.append($0) },
            client: client,
            retryDelays: [.zero]
        )

        service.setLiked(song: song, previous: false, desired: true)
        await service.waitForPendingWork(sourceID: source.id)

        let calls = await client.favoriteCallSnapshot()
        let invalidations = await client.invalidationSnapshot()
        XCTAssertEqual(calls.map(\.desired), [true, true])
        XCTAssertEqual(invalidations, [source.id])
        XCTAssertEqual(liked[song.id], true)
        XCTAssertTrue(errors.isEmpty)
    }

    func testRejectedFavoriteRollsBackLastConfirmedState() async {
        let source = makeSource(id: "rollback", type: .subsonic)
        let song = makeSong(id: "rollback-song", sourceID: source.id)
        let client = TVServerFeedbackClientStub()
        await client.enqueueFavoriteOutcomes([.rejected], sourceID: source.id)
        var liked = [song.id: true]
        var applied: [Bool] = []
        var errors: [String] = []
        let service = makeService(
            sources: [source.id: source],
            liked: { liked[$0] ?? false },
            applyLiked: {
                liked[$0] = $1
                applied.append($1)
            },
            reportError: { errors.append($0) },
            client: client
        )

        service.setLiked(song: song, previous: false, desired: true)
        await service.waitForPendingWork(sourceID: source.id)

        XCTAssertEqual(liked[song.id], false)
        XCTAssertEqual(applied, [false])
        XCTAssertEqual(errors.count, 1)
    }

    func testRapidLikedChangesConvergeWithoutStaleFailureRollback() async {
        let source = makeSource(id: "rapid", type: .navidrome)
        let song = makeSong(id: "rapid-song", sourceID: source.id)
        let client = TVServerFeedbackClientStub()
        await client.blockNextFavorite(sourceID: source.id)
        var liked = [song.id: true]
        var applied: [Bool] = []
        var errors: [String] = []
        let service = makeService(
            sources: [source.id: source],
            liked: { liked[$0] ?? false },
            applyLiked: {
                liked[$0] = $1
                applied.append($1)
            },
            reportError: { errors.append($0) },
            client: client
        )

        service.setLiked(song: song, previous: false, desired: true)
        await waitUntil { await client.hasFavoriteWaiter(sourceID: source.id) }
        liked[song.id] = false
        service.setLiked(song: song, previous: true, desired: false)
        await client.releaseFavorite(sourceID: source.id, outcome: .rejected)
        await service.waitForPendingWork(sourceID: source.id)

        let calls = await client.favoriteCallSnapshot()
        XCTAssertEqual(calls.map(\.desired), [true, false])
        XCTAssertEqual(liked[song.id], false)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    func testCancelOneSourceDoesNotRollbackOrCancelAnotherSource() async {
        let cancelled = makeSource(id: "cancelled", type: .subsonic)
        let retained = makeSource(id: "retained", type: .navidrome)
        let cancelledSong = makeSong(id: "cancelled-song", sourceID: cancelled.id)
        let retainedSong = makeSong(id: "retained-song", sourceID: retained.id)
        let client = TVServerFeedbackClientStub()
        await client.blockNextFavorite(sourceID: cancelled.id)
        var liked = [cancelledSong.id: true, retainedSong.id: true]
        var appliedSongIDs: [String] = []
        let service = makeService(
            sources: [cancelled.id: cancelled, retained.id: retained],
            liked: { liked[$0] ?? false },
            applyLiked: {
                liked[$0] = $1
                appliedSongIDs.append($0)
            },
            client: client
        )

        service.setLiked(song: cancelledSong, previous: false, desired: true)
        service.setLiked(song: retainedSong, previous: false, desired: true)
        await waitUntil { await client.hasFavoriteWaiter(sourceID: cancelled.id) }
        service.cancel(sourceID: cancelled.id)
        await client.releaseFavorite(sourceID: cancelled.id, outcome: .rejected)
        await service.waitForPendingWork(sourceID: retained.id)
        for _ in 0..<10 { await Task.yield() }

        let calls = await client.favoriteCallSnapshot()
        XCTAssertEqual(Set(calls.map(\.sourceID)), Set([cancelled.id, retained.id]))
        XCTAssertEqual(liked[cancelledSong.id], true)
        XCTAssertEqual(liked[retainedSong.id], true)
        XCTAssertFalse(appliedSongIDs.contains(cancelledSong.id))
    }

    func testNowPlayingIsSerializedSoNewestSongIsReportedLast() async {
        let source = makeSource(id: "now-playing", type: .subsonic)
        let oldSong = makeSong(id: "old-song", sourceID: source.id)
        let newSong = makeSong(id: "new-song", sourceID: source.id)
        let client = TVServerFeedbackClientStub()
        await client.blockNextReport(sourceID: source.id)
        let service = makeService(
            sources: [source.id: source],
            liked: { _ in false },
            applyLiked: { _, _ in },
            client: client
        )

        service.reportNowPlaying(song: oldSong)
        await waitUntil { await client.hasReportWaiter(sourceID: source.id) }
        service.reportNowPlaying(song: newSong)
        await client.releaseReport(sourceID: source.id)
        await service.waitForPendingWork(sourceID: source.id)

        let calls = await client.reportCallSnapshot()
        XCTAssertEqual(calls.map { $0.feedback.song.id }, [oldSong.id, newSong.id])
        XCTAssertEqual(calls.map { $0.feedback.kind }, [.nowPlaying, .nowPlaying])
    }

    func testScrobbleRetryKeepsOneStableEventIdentity() async {
        let source = makeSource(id: "fnmusic", type: .fnMusic)
        let song = makeSong(
            id: "fnmusic-song",
            sourceID: source.id,
            filePath: "/fnmusic/tracks/track-guid.flac"
        )
        let client = TVServerFeedbackClientStub()
        await client.enqueueReportOutcomes([.timedOut, .value(true)], sourceID: source.id)
        let service = makeService(
            sources: [source.id: source],
            liked: { _ in false },
            applyLiked: { _, _ in },
            client: client,
            retryDelays: [.zero]
        )

        service.reportScrobble(song: song)
        await service.waitForPendingWork(sourceID: source.id)

        let calls = await client.reportCallSnapshot()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map { $0.feedback.id }.uniqued.count, 1)
        XCTAssertEqual(calls.map { $0.feedback.occurredAt }.uniqued.count, 1)
        XCTAssertEqual(calls.map { $0.feedback.kind }, [.scrobble, .scrobble])
    }

    private func makeService(
        sources: [String: MusicSource],
        liked: @escaping (String) -> Bool,
        applyLiked: @escaping (String, Bool) -> Void,
        reportError: @escaping (String) -> Void = { _ in },
        client: TVServerFeedbackClientStub,
        retryDelays: [Duration] = []
    ) -> TVServerFeedbackService {
        TVServerFeedbackService(
            sourceProvider: { sources[$0] },
            credentialProvider: { _ in
                SourceCredential(username: "test", password: "test-only")
            },
            currentLikedState: liked,
            applyLikedState: applyLiked,
            reportError: reportError,
            client: client,
            retryDelays: retryDelays,
            sleeper: { _ in }
        )
    }

    private func makeSource(id: String, type: MusicSourceType) -> MusicSource {
        MusicSource(
            id: id,
            name: id,
            type: type,
            host: "feedback.invalid",
            port: 443,
            useSsl: true,
            username: "test"
        )
    }

    private func makeSong(
        id: String,
        sourceID: String,
        filePath: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: id,
            duration: 180,
            fileFormat: .mp3,
            filePath: filePath ?? "/songs/\(id).mp3",
            sourceID: sourceID
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for feedback operation", file: file, line: line)
    }
}

private extension Array where Element: Hashable {
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
#endif
