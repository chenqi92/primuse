import Testing
@testable import PrimuseKit

@Suite("Playback progress animation")
struct PlaybackProgressAnimationPolicyTests {
    @Test("A regular clock tick interpolates")
    func clockTickAnimates() {
        #expect(PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 10, to: 10.5, isSameItem: true, isPlaying: true
        ))
        // 两倍速一跳正好一秒,仍算正常推进。
        #expect(PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 10, to: 11, isSameItem: true, isPlaying: true
        ))
    }

    @Test("Track changes, seeks and rewinds jump")
    func discontinuitiesJump() {
        // 换歌:从上一首的末尾回到 0。
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 212, to: 0, isSameItem: false, isPlaying: true
        ))
        // 换歌后恰好也是往前一小步,也不接动画。
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 0, to: 0.5, isSameItem: false, isPlaying: true
        ))
        // 往前 seek 15 秒。
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 30, to: 45, isSameItem: true, isPlaying: true
        ))
        // 往回拖。
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 30, to: 29.5, isSameItem: true, isPlaying: true
        ))
        // 原地不动。
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 30, to: 30, isSameItem: true, isPlaying: true
        ))
    }

    @Test("Paused changes jump")
    func pausedJumps() {
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 30, to: 30.5, isSameItem: true, isPlaying: false
        ))
    }

    @Test("Non-finite readings never animate")
    func nonFinite() {
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: .nan, to: 1, isSameItem: true, isPlaying: true
        ))
        #expect(!PlaybackProgressAnimationPolicy.animatesAdvance(
            from: 1, to: .infinity, isSameItem: true, isPlaying: true
        ))
    }

    @Test("Fraction is clamped and safe for unknown durations")
    func fraction() {
        #expect(PlaybackProgressAnimationPolicy.fraction(time: 30, duration: 120) == 0.25)
        #expect(PlaybackProgressAnimationPolicy.fraction(time: 130, duration: 120) == 1)
        #expect(PlaybackProgressAnimationPolicy.fraction(time: -3, duration: 120) == 0)
        #expect(PlaybackProgressAnimationPolicy.fraction(time: 30, duration: 0) == 0)
        #expect(PlaybackProgressAnimationPolicy.fraction(time: 30, duration: .nan) == 0)
    }
}
