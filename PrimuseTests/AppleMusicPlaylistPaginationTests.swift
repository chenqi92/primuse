import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class AppleMusicPlaylistPaginationTests: XCTestCase, @unchecked Sendable {
    private let link = "https://music.apple.com/us/playlist/fixture/pl.fixture"
    func testInitialAndLaterSDKCancellationStayCancellation() async {
        for later in [false, true] {
            for cancellation in [CancellationError() as any Error, URLError(.cancelled)] {
                let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
                    if !later { throw cancellation }
                    return .init(name: "Fixture", tracks: [Self.track(1)], next: { throw cancellation })
                })
                do { _ = try await fetcher.fetch(sharedText: link); XCTFail("Cancelled imports must not produce a playlist") }
                catch is CancellationError { }
                catch { XCTFail("Lost SDK cancellation: \(error)") }
            }
        }
    }
    func testLaterPageFailureKeepsReadPagesAsIncomplete() async throws {
        for failure in [URLError(.notConnectedToInternet) as any Error, ExternalPlaylistFetcher.FetchError.appleMusicNotAuthorized] {
            let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
                .init(name: "Fixture", tracks: [Self.track(1)], next: {
                    .init(name: "Fixture", tracks: [Self.track(2)], next: { throw failure })
                })
            })
            let result = try await fetcher.fetch(sharedText: link)
            XCTAssertEqual(result.tracks.map(\.externalID), ["1", "2"])
            XCTAssertEqual(result.partialReason, .incomplete, "A missing page must never read as a complete playlist")
        }
    }
    func testAdvertisedContinuationWithoutAPageIsNotComplete() async throws {
        let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
            .init(name: "Fixture", tracks: [Self.track(1)], next: { nil })
        })
        let result = try await fetcher.fetch(sharedText: link)
        XCTAssertEqual(result.tracks.map(\.externalID), ["1"])
        XCTAssertEqual(result.partialReason, .incomplete)
    }
    func testSuccessfulPagesKeepOrderAndStopAtEnd() async throws {
        let fetcher = ExternalPlaylistFetcher(appleMusicPage: { id in
            XCTAssertEqual(id, "pl.fixture")
            return .init(name: "Fixture", tracks: [Self.track(1)], next: {
                .init(name: "Fixture", tracks: [Self.track(2), Self.track(3)])
            })
        })
        let result = try await fetcher.fetch(sharedText: link)
        XCTAssertEqual(result.name, "Fixture")
        XCTAssertEqual(result.tracks.map(\.externalID), ["1", "2", "3"])
        XCTAssertFalse(result.isPartial)
    }
    func testTrackCapDoesNotFetchAnUnneededPage() async throws {
        for extra in [0, 1] {
            let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
                .init(name: "Fixture", tracks: (0..<(ExternalPlaylistFetcher.maximumTracks + extra)).map(Self.track), next: {
                    XCTFail("Cap already reached; must not request another SDK page")
                    return nil
                })
            })
            let result = try await fetcher.fetch(sharedText: link)
            XCTAssertEqual(result.tracks.count, ExternalPlaylistFetcher.maximumTracks)
            XCTAssertEqual(result.tracks.last?.externalID, "9999")
        }
    }
    func testActualTaskCancellationDuringContinuationDoesNotReturnPartialResult() async throws {
        let started = expectation(description: "SDK continuation started")
        let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
            .init(name: "Fixture", tracks: [Self.track(1)], next: {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                return .init(name: "Fixture", tracks: [Self.track(2)])
            })
        })
        let link = link
        let task = Task { try await fetcher.fetch(sharedText: link) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import returned a playlist") }
        catch is CancellationError { }
    }
    func testSDKAuthorizationAndMissingPlaylistErrorsStaySpecific() async {
        for error in [ExternalPlaylistFetcher.FetchError.appleMusicNotAuthorized, .notFoundOrPrivate] {
            let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in throw error })
            do { _ = try await fetcher.fetch(sharedText: link); XCTFail("Expected SDK precondition failure") }
            catch let actual as ExternalPlaylistFetcher.FetchError {
                switch (error, actual) {
                case (.appleMusicNotAuthorized, .appleMusicNotAuthorized), (.notFoundOrPrivate, .notFoundOrPrivate): break
                default: XCTFail("Lost specific SDK error")
                }
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }
    private static func track(_ index: Int) -> ExternalPlaylistTrack {
        .init(title: "Track \(index)", artists: ["Fixture"], externalID: String(index))
    }
}
