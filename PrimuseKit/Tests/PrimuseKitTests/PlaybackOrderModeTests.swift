import Testing
@testable import PrimuseKit

@Suite("Playback order mode")
struct PlaybackOrderModeTests {
    @Test func readsTheTwoSwitchesAsOneMode() {
        #expect(PlaybackOrderMode(shuffleEnabled: false, repeatMode: .off) == .sequential)
        #expect(PlaybackOrderMode(shuffleEnabled: false, repeatMode: .all) == .repeatAll)
        #expect(PlaybackOrderMode(shuffleEnabled: false, repeatMode: .one) == .repeatOne)
        #expect(PlaybackOrderMode(shuffleEnabled: true, repeatMode: .off) == .shuffle)
        #expect(PlaybackOrderMode(shuffleEnabled: true, repeatMode: .all) == .shuffle)
        // 单曲循环决定实际播什么,随机开着也算单曲循环。
        #expect(PlaybackOrderMode(shuffleEnabled: true, repeatMode: .one) == .repeatOne)
    }

    @Test func tappingCyclesThroughAllFourAndSkipsShuffleWhenItCannotOpen() {
        #expect(PlaybackOrderMode.sequential.next(allowsShuffle: true) == .repeatAll)
        #expect(PlaybackOrderMode.repeatAll.next(allowsShuffle: true) == .repeatOne)
        #expect(PlaybackOrderMode.repeatOne.next(allowsShuffle: true) == .shuffle)
        #expect(PlaybackOrderMode.shuffle.next(allowsShuffle: true) == .sequential)
        #expect(PlaybackOrderMode.repeatOne.next(allowsShuffle: false) == .sequential)
        #expect(PlaybackOrderMode.shuffle.next(allowsShuffle: false) == .sequential)
    }

    @Test func eachModeWritesBothSwitchesAndEveryTapLandsOnTheNextMode() {
        #expect(PlaybackOrderMode.sequential.settings(from: .all) == (false, .off))
        #expect(PlaybackOrderMode.repeatAll.settings(from: .off) == (false, .all))
        #expect(PlaybackOrderMode.repeatOne.settings(from: .all) == (false, .one))
        // 从单曲循环进随机:改成列表循环,随机播完一轮接着来,不会停在一首上。
        #expect(PlaybackOrderMode.shuffle.settings(from: .one) == (true, .all))
        #expect(PlaybackOrderMode.shuffle.settings(from: .off) == (true, .off))

        var shuffle = false
        var repeatMode = RepeatMode.off
        var visited: [PlaybackOrderMode] = []
        for _ in 0..<8 {
            let next = PlaybackOrderMode(shuffleEnabled: shuffle, repeatMode: repeatMode).next(allowsShuffle: true)
            (shuffle, repeatMode) = next.settings(from: repeatMode)
            #expect(PlaybackOrderMode(shuffleEnabled: shuffle, repeatMode: repeatMode) == next)
            visited.append(next)
        }
        #expect(visited == [.repeatAll, .repeatOne, .shuffle, .sequential, .repeatAll, .repeatOne, .shuffle, .sequential])
    }
}
