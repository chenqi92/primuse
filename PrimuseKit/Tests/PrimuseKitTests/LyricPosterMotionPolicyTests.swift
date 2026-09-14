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
}
