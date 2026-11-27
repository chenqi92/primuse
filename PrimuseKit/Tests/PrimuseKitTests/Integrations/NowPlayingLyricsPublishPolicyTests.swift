import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lock-screen lyrics publish cadence")
struct NowPlayingLyricsPublishPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("An unchanged line never republishes")
    func skipsUnchangedLine() {
        #expect(!NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: nil,
            now: now,
            lineChanged: false
        ))
        #expect(!NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: now.addingTimeInterval(-30),
            now: now,
            lineChanged: false
        ))
    }

    @Test("The first line of a session publishes immediately")
    func publishesFirstLine() {
        #expect(NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: nil,
            now: now,
            lineChanged: true
        ))
        #expect(NowPlayingLyricsPublishPolicy.delayUntilNextPublish(
            lastPublishedAt: nil,
            now: now
        ) == 0)
    }

    @Test("A line arriving inside the one-second window waits for the remainder")
    func rateLimitsRapidLines() {
        let lastPublishedAt = now.addingTimeInterval(-0.25)

        #expect(!NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: lastPublishedAt,
            now: now,
            lineChanged: true
        ))
        let delay = NowPlayingLyricsPublishPolicy.delayUntilNextPublish(
            lastPublishedAt: lastPublishedAt,
            now: now
        )
        #expect(abs(delay - 0.75) < 0.000_001)
        // 等到窗口结束, 同一行必须能发出去 —— 限流只推迟, 不丢弃。
        #expect(NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: lastPublishedAt,
            now: now.addingTimeInterval(delay),
            lineChanged: true
        ))
    }

    @Test("Exactly one second later the next line publishes")
    func publishesAtTheWindowBoundary() {
        #expect(NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: now.addingTimeInterval(-NowPlayingLyricsPublishPolicy.minimumPublishInterval),
            now: now,
            lineChanged: true
        ))
    }

    @Test("A backwards clock cannot stall lyric publication")
    func toleratesBackwardsClock() {
        let futureStamp = now.addingTimeInterval(600)

        #expect(NowPlayingLyricsPublishPolicy.shouldPublish(
            lastPublishedAt: futureStamp,
            now: now,
            lineChanged: true
        ))
        #expect(NowPlayingLyricsPublishPolicy.delayUntilNextPublish(
            lastPublishedAt: futureStamp,
            now: now
        ) == 0)
    }
}
