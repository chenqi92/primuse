import Foundation
import Testing
@testable import PrimuseKit

@Suite("Repeat behavior")
struct RepeatBehaviorTests {
    @Test func readsAndWritesTheTwoSettings() {
        for behavior in RepeatBehavior.allCases {
            #expect(RepeatBehavior(repeatMode: behavior.repeatMode, eachTrackStop: behavior.eachTrackStop) == behavior)
        }
        #expect(RepeatBehavior(repeatMode: .off, eachTrackStop: .stay) == .playOnce)
        #expect(RepeatBehavior(repeatMode: .off, eachTrackStop: .cueNext) == .trackByTrack)
        // 每首播完都停只在循环关着时成立:锁屏、车机打开循环后它就不算数。
        #expect(RepeatBehavior(repeatMode: .all, eachTrackStop: .stay) == .all)
        #expect(RepeatBehavior(repeatMode: .one, eachTrackStop: .cueNext) == .one)
        // 系统那边只看得到循环关。
        #expect(RepeatBehavior.playOnce.repeatMode == .off)
        #expect(RepeatBehavior.trackByTrack.repeatMode == .off)
    }

    @Test func tappingCyclesTheThreeRepeatModesAndLeavesStopsToTheMenu() {
        #expect(RepeatBehavior.off.next == .all)
        #expect(RepeatBehavior.all.next == .one)
        #expect(RepeatBehavior.one.next == .off)
        #expect(RepeatBehavior.playOnce.next == .off)
        #expect(RepeatBehavior.trackByTrack.next == .off)
        #expect(!RepeatBehavior.off.isActive)
        #expect(RepeatBehavior.allCases.filter(\.isActive).count == 4)
    }

    @Test func eachTrackStopsAreOnlyOfferedWhenThePlayerCanSeeTrackEnds() {
        #expect(RepeatBehavior.choices(includingEachTrackStops: false) == [.off, .all, .one])
        #expect(RepeatBehavior.choices(includingEachTrackStops: true) == RepeatBehavior.allCases)
    }

    @Test("A book starts without each-track stops and music gets them back")
    func listeningSpacesKeepEachTrackStops() {
        let songBySong = ListeningPlayMode(shuffleEnabled: true, repeatMode: .off, eachTrackStop: .cueNext)
        var ledger = ListeningPlayModeLedger()
        #expect(ledger.queueInstalled(ownedBy: .spokenWord, current: songBySong) == .inOrder)
        #expect(ledger.queueInstalled(ownedBy: .music, current: .inOrder) == songBySong)
    }

    @Test("Changing repeat during a book is kept, each-track stop included", arguments: [false, true])
    func repeatChangeDuringBookWins(musicShuffleEnabled: Bool) {
        let songBySong = ListeningPlayMode(shuffleEnabled: musicShuffleEnabled, repeatMode: .off, eachTrackStop: .cueNext)
        var ledger = ListeningPlayModeLedger()
        _ = ledger.queueInstalled(ownedBy: .spokenWord, current: songBySong)
        ledger.repeatChanged()
        let current = ListeningPlayMode(shuffleEnabled: false, repeatMode: .off, eachTrackStop: .stay)
        let restored = ledger.queueInstalled(
            ownedBy: .music,
            current: current
        )
        #expect((restored ?? current) == ListeningPlayMode(
            shuffleEnabled: musicShuffleEnabled, repeatMode: .off, eachTrackStop: .stay
        ))
    }

    @Test("Play modes saved before each-track stops still decode")
    func legacyPlayModeDecodes() throws {
        let data = Data(#"{"shuffleEnabled":true,"repeatMode":"all"}"#.utf8)
        let decoded = try JSONDecoder().decode(ListeningPlayMode.self, from: data)
        #expect(decoded == ListeningPlayMode(shuffleEnabled: true, repeatMode: .all))
        #expect(decoded.eachTrackStop == nil)
    }

    @Test("A restored session keeps an each-track stop only while repeat is off")
    func sessionRestoreCarriesEachTrackStop() throws {
        func snapshot(repeatMode: RepeatMode, stop: EachTrackStop?) -> PlaybackSessionSnapshot {
            PlaybackSessionSnapshot(
                queueSongIDs: ["a", "b"],
                currentSongID: "a",
                currentIndex: 0,
                currentTime: 0,
                duration: 180,
                wasPlaying: false,
                shuffleEnabled: false,
                shuffledIndices: [],
                shufflePosition: 0,
                repeatMode: repeatMode,
                isAtTrackEnd: false,
                eachTrackStop: stop
            )
        }
        let kept = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot(repeatMode: .off, stop: .cueNext),
            availableSongIDs: ["a", "b"]
        ))
        #expect(kept.eachTrackStop == .cueNext)
        let dropped = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot(repeatMode: .all, stop: .stay),
            availableSongIDs: ["a", "b"]
        ))
        #expect(dropped.eachTrackStop == nil)

        let data = try JSONEncoder().encode(snapshot(repeatMode: .off, stop: .stay))
        #expect(try JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data).eachTrackStop == .stay)
    }

    @Test("The merged play mode button covers shuffle and repeat in the More menu")
    func playModeButtonCoversShuffleAndRepeat() {
        let merged = NowPlayingControlLayout.default
            .placing(.playMode, at: .slot(.leadingEdge))
            .placing(.abRepeat, at: .slot(.trailingEdge))
        #expect(merged.action(in: .leadingEdge) == .playMode)
        #expect(merged.action(in: .trailingEdge) == .abRepeat)
        #expect(!merged.placedActions.contains(.shuffle))
        #expect(!merged.placedActions.contains(.repeatMode))
        #expect(merged.menuFallback(on: .portrait).isEmpty)
        #expect(NowPlayingControlLayout.decode(merged.encoded()) == merged)
        // 名字写进配置、经 iCloud 同步,发布后不能改。
        #expect(NowPlayingControlAction.playMode.rawValue == "playMode")
        #expect(NowPlayingControlAction.abRepeat.rawValue == "abRepeat")
        // 两端都不放它时,随机与循环照旧补进「更多」。
        let none = merged.placing(.sleepTimer, at: .slot(.leadingEdge))
        #expect(none.menuFallback(on: .portrait) == [.shuffle, .shufflePreference, .repeatMode])
    }
}

@Suite("A-B repeat")
struct ABRepeatPolicyTests {
    private let song: ClosedRange<TimeInterval> = 0...200

    @Test func tapsSetATheBThenTurnOff() throws {
        let pointA = ABRepeatPolicy.advanced(.off, at: 30, playable: song)
        #expect(pointA == .pointA(30))
        let looping = ABRepeatPolicy.advanced(pointA, at: 45.5, playable: song)
        #expect(looping == .looping(ABRepeatLoop(start: 30, end: 45.5)))
        #expect(ABRepeatPolicy.advanced(looping, at: 50, playable: song) == .off)
    }

    @Test func bBeforeASwapsAndTooShortWaits() {
        // 设了 A 之后往回拖再设 B:两点对调。
        #expect(ABRepeatPolicy.advanced(.pointA(60), at: 40, playable: song)
            == .looping(ABRepeatLoop(start: 40, end: 60)))
        // 两下挨得太近,第二下不算数,还等着 B。
        #expect(ABRepeatPolicy.advanced(.pointA(60), at: 60.5, playable: song) == .pointA(60))
    }

    @Test func pointsStayInsideThePlaybackRange() {
        let range: ClosedRange<TimeInterval> = 20...120
        #expect(ABRepeatPolicy.advanced(.off, at: 5, playable: range) == .pointA(20))
        #expect(ABRepeatPolicy.loop(from: 100, to: 300, playable: range) == ABRepeatLoop(start: 100, end: 120))
        #expect(ABRepeatPolicy.loop(from: 119.5, to: 300, playable: range) == nil)
        #expect(ABRepeatPolicy.fitted(ABRepeatLoop(start: 10, end: 40), to: range) == ABRepeatLoop(start: 20, end: 40))
        #expect(ABRepeatPolicy.fitted(ABRepeatLoop(start: 130, end: 140), to: range) == nil)
    }

    @Test func choosingASectionStartsAtThePlayheadAndShiftsBackNearTheEnd() {
        #expect(ABRepeatPolicy.initialLoop(at: 50, playable: song) == ABRepeatLoop(start: 50, end: 65))
        #expect(ABRepeatPolicy.initialLoop(at: 195, playable: song) == ABRepeatLoop(start: 185, end: 200))
        #expect(ABRepeatPolicy.initialLoop(at: 3, playable: 0...8) == ABRepeatLoop(start: 0, end: 8))
        #expect(ABRepeatPolicy.initialLoop(at: 0, playable: 0...0.5) == nil)
    }

    @Test func movingAnEdgeNeverCrossesTheOtherOrLeavesTheSong() {
        let loop = ABRepeatLoop(start: 30, end: 40)
        #expect(ABRepeatPolicy.moving(.start, of: loop, to: 39.8, playable: song) == ABRepeatLoop(start: 39, end: 40))
        #expect(ABRepeatPolicy.moving(.start, of: loop, to: -5, playable: song) == ABRepeatLoop(start: 0, end: 40))
        #expect(ABRepeatPolicy.moving(.end, of: loop, to: 30.2, playable: song) == ABRepeatLoop(start: 30, end: 31))
        #expect(ABRepeatPolicy.moving(.end, of: loop, to: 999, playable: song) == ABRepeatLoop(start: 30, end: 200))
    }

    @Test func jumpsBackAtBOnTimeForThePlaybackSpeed() {
        let loop = ABRepeatLoop(start: 30, end: 40)
        #expect(!ABRepeatPolicy.reachedEnd(of: loop, at: 39.5))
        #expect(ABRepeatPolicy.reachedEnd(of: loop, at: 39.99))
        #expect(ABRepeatPolicy.reachedEnd(of: loop, at: 41))
        #expect(ABRepeatPolicy.timeUntilEnd(of: loop, at: 39, rate: 1) == 1)
        #expect(ABRepeatPolicy.timeUntilEnd(of: loop, at: 39, rate: 0.5) == 2)
        #expect(ABRepeatPolicy.timeUntilEnd(of: loop, at: 45, rate: 1) == 0)
        #expect(ABRepeatPolicy.timeUntilEnd(of: loop, at: 39, rate: 0) == 1)
    }

    @Test func draggingOutOfTheSectionLeavesIt() {
        let looping = ABRepeatState.looping(ABRepeatLoop(start: 30, end: 40))
        #expect(!ABRepeatPolicy.seekLeaves(looping, target: 30))
        #expect(!ABRepeatPolicy.seekLeaves(looping, target: 29))
        #expect(!ABRepeatPolicy.seekLeaves(looping, target: 41))
        #expect(ABRepeatPolicy.seekLeaves(looping, target: 10))
        #expect(ABRepeatPolicy.seekLeaves(looping, target: 60))
        // 只设了 A 时随便拖,B 可以设在 A 前面。
        #expect(!ABRepeatPolicy.seekLeaves(.pointA(30), target: 0))
        #expect(!ABRepeatPolicy.seekLeaves(.off, target: 0))
    }
}
