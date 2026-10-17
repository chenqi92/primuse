import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music listening policy")
struct AppleMusicListeningPolicyTests {
    private let request = UUID()

    private func occurrence(
        request: UUID? = nil,
        entry: UUID? = nil,
        raw: String? = "1440",
        song: String = "i.song"
    ) -> AppleMusicListeningPolicy.Occurrence {
        .init(requestID: request ?? self.request, queueEntryID: entry, rawSongID: raw, songID: song)
    }

    private func sample(
        _ time: TimeInterval,
        at uptime: TimeInterval,
        playing: Bool = true
    ) -> AppleMusicListeningPolicy.Sample {
        .init(playbackTime: time, isPlaying: playing, uptime: uptime)
    }

    /// 按 0.5s 一拍连续放 `seconds` 秒, 返回累计算听了多少。
    private func play(
        _ progress: inout AppleMusicListeningPolicy.Progress?,
        from start: TimeInterval,
        seconds: TimeInterval,
        uptime: inout TimeInterval,
        occurrence: AppleMusicListeningPolicy.Occurrence,
        duration: TimeInterval = 240
    ) -> TimeInterval {
        var total: TimeInterval = 0
        var time = start
        for _ in 0..<Int(seconds * 2) {
            time += 0.5
            uptime += 0.5
            let step = AppleMusicListeningPolicy.advance(
                &progress,
                occurrence: occurrence,
                sample: sample(time, at: uptime),
                duration: duration
            )
            if case .continued(let listened) = step { total += listened }
        }
        return total
    }

    @Test("The first mirrored tick of a request opens a listening session")
    func firstTickStarts() {
        var progress: AppleMusicListeningPolicy.Progress?
        let step = AppleMusicListeningPolicy.advance(
            &progress,
            occurrence: occurrence(),
            sample: sample(0, at: 100),
            duration: 240
        )
        #expect(step == .started)
        #expect(progress?.sessionSongID == "i.song")
        #expect(progress?.listenedSeconds == 0)
    }

    @Test("Steady playback accumulates the real listening time")
    func steadyPlaybackAccumulates() {
        var progress: AppleMusicListeningPolicy.Progress?
        let current = occurrence()
        _ = AppleMusicListeningPolicy.advance(&progress, occurrence: current, sample: sample(0, at: 100), duration: 240)
        var uptime: TimeInterval = 100
        let listened = play(&progress, from: 0, seconds: 130, uptime: &uptime, occurrence: current)
        #expect(abs(listened - 130) < 0.001)
        #expect(abs((progress?.listenedSeconds ?? 0) - 130) < 0.001)
    }

    @Test("Seeking forward does not count the skipped part")
    func forwardSeekIsCapped() {
        var progress: AppleMusicListeningPolicy.Progress?
        let current = occurrence()
        _ = AppleMusicListeningPolicy.advance(&progress, occurrence: current, sample: sample(10, at: 100), duration: 240)
        let step = AppleMusicListeningPolicy.advance(&progress, occurrence: current, sample: sample(200, at: 100.5), duration: 240)
        #expect(step == .continued(listened: 1))
    }

    @Test("Seeking backward and pausing add nothing")
    func backwardSeekAndPause() {
        var progress: AppleMusicListeningPolicy.Progress?
        let current = occurrence()
        _ = AppleMusicListeningPolicy.advance(&progress, occurrence: current, sample: sample(120, at: 100), duration: 240)
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(30, at: 100.5), duration: 240
        ) == .continued(listened: 0))
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(30, at: 101, playing: false), duration: 240
        ) == .continued(listened: 0))
        // 暂停时拖进度条再继续放: 暂停那一拍到恢复那一拍之间不算。
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(150, at: 400, playing: false), duration: 240
        ) == .continued(listened: 0))
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(150.5, at: 400.5), duration: 240
        ) == .continued(listened: 0))
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(151, at: 401), duration: 240
        ) == .continued(listened: 0.5))
    }

    @Test("A long gap between ticks counts only what really played")
    func longGapCountsPlayedTime() {
        var progress: AppleMusicListeningPolicy.Progress?
        let current = occurrence()
        _ = AppleMusicListeningPolicy.advance(&progress, occurrence: current, sample: sample(10, at: 100), duration: 240)
        // 主线程忙了 40 秒, 这期间一直在放。
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(50, at: 140), duration: 240
        ) == .continued(listened: 40))
    }

    @Test("A canonical id flip within the first ticks is the same play")
    func canonicalFlipIsSamePlay() {
        var progress: AppleMusicListeningPolicy.Progress?
        _ = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(song: "am.1440"), sample: sample(0, at: 100), duration: 240
        )
        let step = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(song: "i.song"), sample: sample(0.5, at: 100.5), duration: 240
        )
        #expect(step == .continued(listened: 0.5))
        #expect(progress?.sessionSongID == "am.1440")
    }

    @Test("A native transition to another song starts a new play")
    func nativeTransitionStarts() {
        var progress: AppleMusicListeningPolicy.Progress?
        _ = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(raw: "1", song: "i.a"), sample: sample(200, at: 100), duration: 240
        )
        let step = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(raw: "2", song: "i.b"), sample: sample(0.3, at: 100.5), duration: 180
        )
        #expect(step == .started)
        #expect(progress?.sessionSongID == "i.b")
    }

    @Test("The same song twice in a managed queue is two plays")
    func duplicateQueueEntriesAreDistinct() {
        var progress: AppleMusicListeningPolicy.Progress?
        _ = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(entry: UUID()), sample: sample(100, at: 100), duration: 240
        )
        let step = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(entry: UUID()), sample: sample(0.5, at: 100.5), duration: 240
        )
        #expect(step == .started)
    }

    @Test("A managed entry that briefly loses its mapping stays the same play")
    func unmappedEntryStaysSamePlay() {
        var progress: AppleMusicListeningPolicy.Progress?
        let entry = UUID()
        _ = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(entry: entry), sample: sample(10, at: 100), duration: 240
        )
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(entry: nil), sample: sample(10.5, at: 100.5), duration: 240
        ) == .continued(listened: 0.5))
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(entry: entry), sample: sample(11, at: 101), duration: 240
        ) == .continued(listened: 0.5))
    }

    @Test("A new playback request is a new play even for the same song")
    func newRequestStarts() {
        var progress: AppleMusicListeningPolicy.Progress?
        _ = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(), sample: sample(100, at: 100), duration: 240
        )
        let step = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(request: UUID()), sample: sample(0, at: 300), duration: 240
        )
        #expect(step == .started)
    }

    @Test("Repeat-one wrapping back to the top is another play")
    func repeatOneWrapStarts() {
        var progress: AppleMusicListeningPolicy.Progress?
        let current = occurrence()
        _ = AppleMusicListeningPolicy.advance(&progress, occurrence: current, sample: sample(0, at: 100), duration: 240)
        var uptime: TimeInterval = 100
        _ = play(&progress, from: 0, seconds: 239.5, uptime: &uptime, occurrence: current)
        let step = AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(0.4, at: uptime + 0.5), duration: 240
        )
        #expect(step == .started)
        #expect(progress?.listenedSeconds == 0)
    }

    @Test("A stale end time on the first ticks of a song is not a replay")
    func staleEndTimeIsNotReplay() {
        var progress: AppleMusicListeningPolicy.Progress?
        // 换歌那一拍播放时间还停在上一首曲尾 (比这首还长), 下一拍才归零。
        _ = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(raw: "2", song: "i.b"), sample: sample(238, at: 100), duration: 180
        )
        let step = AppleMusicListeningPolicy.advance(
            &progress, occurrence: occurrence(raw: "2", song: "i.b"), sample: sample(0.2, at: 100.5), duration: 180
        )
        #expect(step == .continued(listened: 0))
    }

    @Test("Seeking back to the top mid-song is not a replay")
    func midSongSeekToTopIsNotReplay() {
        var progress: AppleMusicListeningPolicy.Progress?
        let current = occurrence()
        _ = AppleMusicListeningPolicy.advance(&progress, occurrence: current, sample: sample(0, at: 100), duration: 240)
        var uptime: TimeInterval = 100
        _ = play(&progress, from: 0, seconds: 60, uptime: &uptime, occurrence: current)
        #expect(AppleMusicListeningPolicy.advance(
            &progress, occurrence: current, sample: sample(0.5, at: uptime + 0.5), duration: 240
        ) == .continued(listened: 0))
    }
}
