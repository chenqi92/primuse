import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke vocal assist")
struct KaraokeVocalAssistPolicyTests {
    /// Feeds readings every 50 ms from `start` to `end`, advancing the fade
    /// alongside, and returns the last reduction factor.
    @discardableResult
    private func run(
        _ policy: inout KaraokeVocalAssistPolicy,
        from start: TimeInterval,
        to end: TimeInterval,
        inOwnLine: Bool = true,
        sung: Double? = nil,
        reference: Double? = 60
    ) -> Double {
        var factor = 1.0
        var time = start
        while time < end - 1e-9 {
            policy.observe(time: time, inOwnLine: inOwnLine, sung: sung, reference: reference)
            factor = policy.advance(to: time)
            time += 0.05
        }
        return factor
    }

    @Test("Silence inside the singer's line brings the original back, gently")
    func engagesAfterSilence() {
        var policy = KaraokeVocalAssistPolicy()
        #expect(run(&policy, from: 0, to: 1.1) == 1)
        #expect(!policy.isEngaged)
        run(&policy, from: 1.1, to: 1.3)
        #expect(policy.isEngaged)
        // Half-way through the fade in.
        let halfway = run(&policy, from: 1.3, to: 1.5)
        #expect(halfway > 0.4 && halfway < 1)
        let full = run(&policy, from: 1.5, to: 2.5)
        #expect(abs(full - 0.2) < 1e-9)
    }

    @Test("Singing hands the line back quickly")
    func singingDisengages() {
        var policy = KaraokeVocalAssistPolicy()
        run(&policy, from: 0, to: 3)
        #expect(policy.isEngaged)
        // Well after the fade in, so not mistaken for leakage.
        let factor = run(&policy, from: 3, to: 3.2, sung: 64, reference: 64)
        #expect(!policy.isEngaged)
        #expect(factor == 1)
        #expect(!policy.isSuppressed)
    }

    @Test("Short breaths and gaps between lines never engage")
    func briefSilencesStayQuiet() {
        var policy = KaraokeVocalAssistPolicy()
        for start in stride(from: 0.0, to: 10, by: 1.5) {
            run(&policy, from: start, to: start + 1, sung: 62)
            #expect(run(&policy, from: start + 1, to: start + 1.5) == 1)
        }
        // Long rest outside any own line: the partner's row or an interlude.
        #expect(run(&policy, from: 20, to: 30, inOwnLine: false) == 1)
        #expect(!policy.isEngaged)
    }

    @Test("Playback leaking into the microphone suppresses assist for the song")
    func bleedSuppresses() {
        var policy = KaraokeVocalAssistPolicy()
        var time = 0.0
        for _ in 0..<2 {
            run(&policy, from: time, to: time + 1.3)
            #expect(policy.isEngaged)
            // The returned original is heard right away, on its own pitch.
            run(&policy, from: time + 1.3, to: time + 1.4, sung: 60.2, reference: 60)
            time += 1.5
        }
        #expect(policy.isSuppressed)
        #expect(run(&policy, from: time, to: time + 5) == 1)

        policy.reset()
        #expect(!policy.isSuppressed)
        run(&policy, from: 0, to: 1.3)
        #expect(policy.isEngaged)
    }

    @Test("A singer rejoining off the original's pitch is not leakage")
    func quickRejoinOffPitch() {
        var policy = KaraokeVocalAssistPolicy()
        var time = 0.0
        for _ in 0..<4 {
            run(&policy, from: time, to: time + 1.3)
            run(&policy, from: time + 1.3, to: time + 1.4, sung: 62, reference: 60)
            time += 1.5
        }
        #expect(!policy.isSuppressed)
    }

    @Test("Seeking backwards starts the silence count over")
    func seekResets() {
        var policy = KaraokeVocalAssistPolicy()
        run(&policy, from: 10, to: 11)
        run(&policy, from: 2, to: 2.5)
        #expect(!policy.isEngaged)
        run(&policy, from: 2.5, to: 3.3)
        #expect(policy.isEngaged)
    }
}
