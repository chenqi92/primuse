import Foundation
import Testing
@testable import PrimuseKit

@Suite("CarPlay title lyrics timing")
struct CarPlayLyricsTimingPolicyTests {
    private let lyrics = [
        LyricLine(id: "first", timestamp: 2, text: "First", isSynchronized: true),
        LyricLine(id: "first-translation", timestamp: 2, text: "First translated", isSynchronized: true),
        LyricLine(id: "second", timestamp: 5, text: "Second", isSynchronized: true),
        LyricLine(id: "third", timestamp: 7.5, text: "Third", isSynchronized: true),
    ]

    private func line(at playbackTime: TimeInterval, lookahead: TimeInterval) -> String? {
        NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            synchronizedLyrics: lyrics,
            playbackTime: playbackTime,
            isEnabled: true,
            isLiveStream: false,
            lookahead: lookahead
        ).lyricLineID
    }

    @Test("Engine output delay is taken off the display lead but never delays lyrics")
    func lookaheadAbsorbsOutputDelay() {
        let lead = CarPlayLyricsTimingPolicy.displayLead
        #expect(CarPlayLyricsTimingPolicy.lookahead(audioOutputDelay: 0) == lead)
        #expect(abs(CarPlayLyricsTimingPolicy.lookahead(audioOutputDelay: 0.1) - (lead - 0.1)) < 0.000_001)
        #expect(CarPlayLyricsTimingPolicy.lookahead(audioOutputDelay: 2) == 0)
        #expect(CarPlayLyricsTimingPolicy.lookahead(audioOutputDelay: .nan) == lead)
        #expect(CarPlayLyricsTimingPolicy.lookahead(audioOutputDelay: -1) == lead)
    }

    @Test("The next change lands lead seconds before the next timestamp group")
    func nextChangeSkipsCompanionRows() throws {
        let beforeFirst = try #require(CarPlayLyricsTimingPolicy.nextChangeTime(in: lyrics, after: 0, lookahead: 0.4))
        #expect(abs(beforeFirst - 1.6) < 0.000_001)
        // 翻译行与原文同一时间戳, 下一次换行是下一组。
        let onFirst = try #require(CarPlayLyricsTimingPolicy.nextChangeTime(in: lyrics, after: 2, lookahead: 0.4))
        #expect(abs(onFirst - 4.6) < 0.000_001)
        // 恰好走到换行点时, 下一次换行已是再下一组。
        let atChange = try #require(CarPlayLyricsTimingPolicy.nextChangeTime(in: lyrics, after: 4.6, lookahead: 0.4))
        #expect(abs(atChange - 7.1) < 0.000_001)
        #expect(CarPlayLyricsTimingPolicy.nextChangeTime(in: lyrics, after: 7.2, lookahead: 0.4) == nil)
        #expect(CarPlayLyricsTimingPolicy.nextChangeTime(in: [], after: 0, lookahead: 0.4) == nil)
        #expect(CarPlayLyricsTimingPolicy.nextChangeTime(in: lyrics, after: .nan, lookahead: 0.4) == nil)
    }

    @Test("The scheduled change is exactly where the presentation switches")
    func presentationMatchesScheduledChange() throws {
        let lead = 0.4
        let change = try #require(CarPlayLyricsTimingPolicy.nextChangeTime(in: lyrics, after: 3, lookahead: lead))
        let delay = try #require(CarPlayLyricsTimingPolicy.delay(until: change, from: 3, rate: 1))
        #expect(line(at: 3 + delay - 0.01, lookahead: lead) == "first")
        #expect(line(at: 3 + delay, lookahead: lead) == "second")
    }

    @Test("Lookahead switches lines early and shows the first line early")
    func presentationHonorsLookahead() {
        #expect(line(at: 4.65, lookahead: 0.4) == "second")
        #expect(line(at: 4.65, lookahead: 0) == "first")
        #expect(line(at: 1.5, lookahead: 0.4) == nil)
        #expect(line(at: 1.65, lookahead: 0.4) == "first")
        #expect(line(at: 4.65, lookahead: -1) == "first")
        #expect(line(at: 4.65, lookahead: .nan) == "first")
    }

    @Test("Waiting time follows the playback rate and lands just past the boundary")
    func delayScalesWithRate() throws {
        let normal = try #require(CarPlayLyricsTimingPolicy.delay(until: 4.6, from: 3.6, rate: 1))
        #expect(abs(normal - 1.005) < 0.000_001)
        let fast = try #require(CarPlayLyricsTimingPolicy.delay(until: 4.6, from: 3.6, rate: 2))
        #expect(abs(fast - 0.505) < 0.000_001)
        let invalidRate = try #require(CarPlayLyricsTimingPolicy.delay(until: 4.6, from: 3.6, rate: 0))
        #expect(abs(invalidRate - 1.005) < 0.000_001)
        // 已经到点也留一个最小间隔, 时钟异常时不会在主线程上空转。
        #expect(CarPlayLyricsTimingPolicy.delay(until: 4.6, from: 4.6, rate: 1) == 0.02)
        #expect(CarPlayLyricsTimingPolicy.delay(until: .nan, from: 4.6, rate: 1) == nil)
    }
}
