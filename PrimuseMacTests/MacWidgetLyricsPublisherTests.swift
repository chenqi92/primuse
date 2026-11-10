import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class MacWidgetLyricsPublisherTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, title: "纸船", fileFormat: .mp3, filePath: "/\(id).mp3", sourceID: "fixture")
    }

    private func line(_ text: String) -> [LyricLine] {
        [LyricLine(id: "line", timestamp: 2, text: text)]
    }

    func testLyricsCachedAfterEmptyLoadAppearWithoutChangingSong() async {
        let center = NotificationCenter()
        let state = MacWidgetLyricsPublisher.State(song: song("a"), artist: "河岸", position: 3, isPlaying: true)
        var lines: [LyricLine] = []
        var snapshots: [LyricsSnapshot?] = []
        let updated = expectation(description: "Cached lyrics published")
        let publisher = MacWidgetLyricsPublisher(
            state: { state }, load: { _ in lines }, enabled: { true },
            publish: { snapshot in snapshots.append(snapshot); if snapshot != nil { updated.fulfill() } },
            notificationCenter: center
        )
        defer { publisher.stop() }
        publisher.refresh()
        await publisher.waitForPendingPublication()
        XCTAssertNil(snapshots.last!)
        lines = line("纸船向着晨光去")
        center.post(name: .primuseLyricsDidCache, object: nil, userInfo: ["songID": "a"])
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(snapshots.last??.lines.first?.text, "纸船向着晨光去")
        XCTAssertEqual(snapshots.last??.playbackPosition, 3)
    }

    func testSameSongReplacementRejectsOlderInFlightResult() async {
        let center = NotificationCenter()
        let state = MacWidgetLyricsPublisher.State(song: song("a"), artist: "河岸", position: 9, isPlaying: false)
        var resumeOld: CheckedContinuation<[LyricLine], Never>?
        let started = expectation(description: "Old load started")
        let oldReturned = expectation(description: "Old load returned")
        let replaced = expectation(description: "Replacement published")
        var snapshots: [LyricsSnapshot?] = []
        var count = 0
        let publisher = MacWidgetLyricsPublisher(
            state: { state }, load: { _ in
                count += 1
                if count == 1 {
                    let result = await withCheckedContinuation { resumeOld = $0; started.fulfill() }
                    oldReturned.fulfill()
                    return result
                }
                return self.line("新的一页等风来")
            }, enabled: { true }, publish: {
                snapshots.append($0)
                if $0 != nil { replaced.fulfill() }
            }, notificationCenter: center
        )
        defer { publisher.stop() }
        publisher.refresh()
        await fulfillment(of: [started], timeout: 2)
        center.post(name: .primuseLyricsDidChange, object: "a")
        await fulfillment(of: [replaced], timeout: 2)
        resumeOld?.resume(returning: line("旧的一页已翻过"))
        await fulfillment(of: [oldReturned], timeout: 2)
        await publisher.waitForPendingPublication()
        XCTAssertEqual(snapshots.compactMap { $0 }.count, 1)
        XCTAssertEqual(snapshots.last??.lines.first?.text, "新的一页等风来")
        XCTAssertEqual(snapshots.last??.isPlaying, false)
    }

    func testTrackChangeRejectsPreviousLyricsAndUsesLatestPlaybackSample() async {
        var state = MacWidgetLyricsPublisher.State(song: song("a"), artist: "河岸", position: 0, isPlaying: true)
        let started = expectation(description: "Previous song load started")
        let oldReturned = expectation(description: "Previous song load returned")
        var resumeOld: CheckedContinuation<[LyricLine], Never>?
        var snapshots: [LyricsSnapshot?] = []
        let publisher = MacWidgetLyricsPublisher(
            state: { state }, load: { song in
                if song.id == "a" {
                    let result = await withCheckedContinuation { resumeOld = $0; started.fulfill() }
                    oldReturned.fulfill()
                    return result
                }
                state.position = 12
                state.isPlaying = false
                return self.line("月色停在小桥边")
            }, enabled: { true }, publish: { snapshots.append($0) }, notificationCenter: NotificationCenter()
        )
        defer { publisher.stop() }
        publisher.refresh()
        await fulfillment(of: [started], timeout: 2)
        state.song = song("b")
        publisher.refresh()
        await publisher.waitForPendingPublication()
        resumeOld?.resume(returning: line("纸船向着晨光去"))
        await fulfillment(of: [oldReturned], timeout: 2)
        XCTAssertEqual(snapshots.compactMap { $0 }.map(\.songID), ["b"])
        XCTAssertEqual(snapshots.last??.playbackPosition, 12)
        XCTAssertEqual(snapshots.last??.isPlaying, false)
    }

    func testPrivacyGateClearsAndReenableRepublishesWithoutTrackChange() async {
        let center = NotificationCenter()
        let state = MacWidgetLyricsPublisher.State(song: song("a"), artist: "河岸", position: 0, isPlaying: true)
        var enabled = true
        var snapshots: [LyricsSnapshot?] = []
        var loads = 0
        let cleared = expectation(description: "Sharing disabled")
        let republished = expectation(description: "Sharing reenabled")
        let publisher = MacWidgetLyricsPublisher(
            state: { state }, load: { _ in loads += 1; return self.line("小桥留住一片云") },
            enabled: { enabled }, publish: {
                snapshots.append($0)
                if !enabled, $0 == nil { cleared.fulfill() }
                if loads == 2, $0 != nil { republished.fulfill() }
            }, notificationCenter: center
        )
        defer { publisher.stop() }
        publisher.refresh()
        await publisher.waitForPendingPublication()
        publisher.refresh()
        XCTAssertEqual(loads, 1)
        enabled = false
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertNil(snapshots.last!)
        publisher.refresh(force: true)
        XCTAssertEqual(loads, 1)
        enabled = true
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        await fulfillment(of: [republished], timeout: 2)
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(snapshots.last??.songID, "a")
    }

    func testUnrelatedPreferenceChangeDoesNotRetryMissingLyrics() async {
        let center = NotificationCenter()
        let state = MacWidgetLyricsPublisher.State(song: song("a"), artist: "河岸", position: 0, isPlaying: false)
        let checked = expectation(description: "Preference notification handled")
        checked.assertForOverFulfill = false
        var inspectChange = false
        var loads = 0
        let publisher = MacWidgetLyricsPublisher(
            state: { state }, load: { _ in loads += 1; return [] },
            enabled: { if inspectChange { checked.fulfill() }; return true },
            publish: { _ in }, notificationCenter: center
        )
        defer { publisher.stop() }
        publisher.refresh()
        await publisher.waitForPendingPublication()
        inspectChange = true
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        await fulfillment(of: [checked], timeout: 2)
        await publisher.waitForPendingPublication()
        XCTAssertEqual(loads, 1)
    }
}
