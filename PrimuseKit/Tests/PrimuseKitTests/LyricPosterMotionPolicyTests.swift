import Foundation
import Testing
@testable import PrimuseKit

struct LyricPosterMotionPolicyTests {
    private func content(
        lineCount: Int,
        spacing: TimeInterval = 3,
        dwell: TimeInterval = 2,
        synchronized: Bool = true
    ) -> LyricPosterContent {
        LyricPosterContent(
            songTitle: "Song",
            lines: (0..<lineCount).map { index in
                LyricPosterLine(
                    id: "l\(index)",
                    text: "line \(index)",
                    timestamp: 60 + Double(index) * spacing,
                    endTimestamp: synchronized ? 60 + Double(index) * spacing + dwell : nil,
                    isSynchronized: synchronized
                )
            }
        )
    }

    @Test func clipsStayInsideTheLivePhotoDurationRange() {
        for lineCount in 1...LyricPosterSelectionPolicy.maximumLines {
            let plan = LyricPosterMotionPolicy.plan(for: content(lineCount: lineCount))
            #expect(plan.duration >= LyricPosterMotionPolicy.minimumDuration)
            #expect(plan.duration <= LyricPosterMotionPolicy.maximumDuration)
            #expect(plan.frameCount >= 1)
        }
    }

    @Test func everyLineKeepsAVisibleWindowEvenWhenThePassageIsCompressed() {
        let plan = LyricPosterMotionPolicy.plan(for: content(lineCount: 8, spacing: 6, dwell: 5))
        #expect(plan.windows.count == 8)
        #expect(plan.duration == LyricPosterMotionPolicy.maximumDuration)
        for window in plan.windows {
            #expect(window.duration > 0)
            #expect(window.start >= LyricPosterMotionPolicy.leadIn)
            #expect(window.end <= plan.duration)
        }
        // Windows stay in order and never overlap backward.
        for pair in zip(plan.windows, plan.windows.dropFirst()) {
            #expect(pair.1.start >= pair.0.start)
        }
    }

    @Test func longInstrumentalGapsBetweenSelectedLinesAreNotExported() {
        // Two lines a minute apart must not produce a minute of dead air.
        let sparse = LyricPosterContent(
            songTitle: "Song",
            lines: [
                LyricPosterLine(id: "a", text: "one", timestamp: 10, endTimestamp: 12, isSynchronized: true),
                LyricPosterLine(id: "b", text: "two", timestamp: 70, endTimestamp: 72, isSynchronized: true),
            ]
        )
        let plan = LyricPosterMotionPolicy.plan(for: sparse)
        #expect(plan.duration <= LyricPosterMotionPolicy.maximumDuration)
        #expect(plan.windows[1].start - plan.windows[0].end <= 0.7)
    }

    @Test func theStillFrameSitsAfterTheLastLineAndInsideTheClip() {
        let plan = LyricPosterMotionPolicy.plan(for: content(lineCount: 3))
        let stillTime = plan.stillFrameTime
        #expect(stillTime <= plan.duration)
        #expect(stillTime >= plan.windows.last!.end - 0.05)
        #expect(plan.stillFrameIndex <= plan.frameCount)
        #expect(plan.reveal(ofLineAt: 2, at: stillTime) == 1)
    }

    @Test func playheadQueriesTrackTheActiveLine() {
        let plan = LyricPosterMotionPolicy.plan(for: content(lineCount: 3))
        #expect(plan.activeIndex(at: 0) == nil)
        #expect(plan.activeProgress(at: 0) == 0)

        let first = plan.windows[0]
        #expect(plan.activeIndex(at: first.start + first.duration / 2) == 0)
        #expect(abs(plan.activeProgress(at: first.start + first.duration / 2) - 0.5) < 0.001)
        #expect(plan.activeIndex(at: plan.duration) == 2)
        #expect(plan.reveal(ofLineAt: 0, at: plan.duration) == 1)
        // Out-of-range rows report as fully revealed rather than crashing.
        #expect(plan.reveal(ofLineAt: 99, at: 0) == 1)
    }

    @Test func unsynchronizedPassagesFallBackToAnEvenCadence() {
        let plan = LyricPosterMotionPolicy.plan(
            for: content(lineCount: 4, synchronized: false)
        )
        #expect(plan.windows.count == 4)
        let durations = plan.windows.map(\.duration)
        for duration in durations {
            #expect(abs(duration - durations[0]) < 0.001)
        }
    }

    @Test func emptyPassagesStillProduceAUsablePlan() {
        let plan = LyricPosterMotionPolicy.plan(for: LyricPosterContent(songTitle: "Song", lines: []))
        #expect(plan.windows.isEmpty)
        #expect(plan.frameCount >= 1)
        #expect(plan.stillFrameIndex == 0)
        #expect(plan.activeIndex(at: 1) == nil)
    }

    @Test func frameTimingFollowsTheRequestedFrameRate() {
        let plan = LyricPosterMotionPolicy.plan(for: content(lineCount: 2), frameRate: 24)
        #expect(plan.frameRate == 24)
        #expect(abs(plan.time(ofFrame: 24) - 1.0) < 0.0001)
        #expect(plan.frameCount == Int((plan.duration * 24).rounded()))
    }

    @Test func musicKeepsOriginalTimingIncludingInstrumentalGaps() throws {
        let passage = content(lineCount: 3, spacing: 6, dwell: 5)
        let plan = try #require(LyricPosterAudioPlan.make(
            content: passage, allLines: passage.lines, songDuration: 180, livePhoto: false
        ))
        #expect(plan.sourceStart == 60)
        #expect(plan.sourceEnd == 77)
        #expect(plan.motion.windows.map(\.start) == [0, 6, 12])
        #expect(plan.motion.windows.map(\.end) == [5, 11, 17])
        #expect(plan.motion.activeProgress(at: 2.5) == 0.5)
    }

    @Test func liveMusicClipsTheExcerptWithoutSpeedingUpTheLyrics() throws {
        let passage = content(lineCount: 3, spacing: 6, dwell: 5)
        let plan = try #require(LyricPosterAudioPlan.make(
            content: passage, allLines: passage.lines, songDuration: 180, livePhoto: true
        ))
        #expect(plan.sourceStart == 60)
        #expect(plan.sourceEnd == 63)
        #expect(plan.motion.duration == 3)
        #expect(plan.motion.activeProgress(at: 2.5) == 0.5)
        #expect(plan.motion.reveal(ofLineAt: 1, at: 3) == 0)
        #expect(plan.motion.stillFrameIndex < plan.motion.frameCount - 1)
    }

    @Test func musicUsesTheNextUnselectedLineAsAnUntimedLineEnd() throws {
        let first = LyricPosterLine(id: "a", text: "one", timestamp: 12, isSynchronized: true)
        let next = LyricPosterLine(id: "b", text: "two", timestamp: 18, isSynchronized: true)
        let plan = try #require(LyricPosterAudioPlan.make(
            content: LyricPosterContent(songTitle: "Song", lines: [first]),
            allLines: [first, next], songDuration: 100, livePhoto: false
        ))
        #expect(plan.sourceEnd == 18)
        #expect(plan.motion.windows[0].duration == 6)
    }

    @Test func musicAtTheSongEndStaysInBoundsAndKeepsTheLineOffset() throws {
        let passage = LyricPosterContent(songTitle: "Song", lines: [
            LyricPosterLine(id: "end", text: "end", timestamp: 119, endTimestamp: 124, isSynchronized: true)
        ])
        for livePhoto in [false, true] {
            let plan = try #require(LyricPosterAudioPlan.make(
                content: passage, allLines: passage.lines, songDuration: 120, livePhoto: livePhoto
            ))
            #expect(plan.sourceStart == 118)
            #expect(plan.sourceEnd == 120)
            #expect(plan.motion.windows[0].start == 1)
            #expect(plan.motion.windows[0].end == 2)
        }
    }

    @Test func musicAndVideoEndOnTheSameFrameBoundary() throws {
        let passage = content(lineCount: 1, dwell: 2.79)
        let plan = try #require(LyricPosterAudioPlan.make(
            content: passage, allLines: passage.lines, songDuration: 180, livePhoto: false, frameRate: 24
        ))
        #expect(abs(plan.sourceEnd - plan.sourceStart - Double(plan.motion.frameCount) / 24) < 0.000001)
        #expect(plan.sourceEnd <= 62.79)
        #expect(62.79 - plan.sourceEnd < 1.0 / 24)
    }

    @Test func musicRejectsMissingOrInvalidTiming() {
        #expect(LyricPosterAudioPlan.make(
            content: content(lineCount: 2, synchronized: false), allLines: [], songDuration: 180, livePhoto: true
        ) == nil)
        for timestamp in [Double.nan, .infinity, -1, 180] {
            let passage = LyricPosterContent(songTitle: "Song", lines: [
                LyricPosterLine(id: "bad", text: "bad", timestamp: timestamp, isSynchronized: true)
            ])
            #expect(LyricPosterAudioPlan.make(
                content: passage, allLines: [], songDuration: 180, livePhoto: true
            ) == nil)
        }
    }
}
