import Foundation
import Testing
@testable import PrimuseKit

@Suite("Listening spaces")
struct ListeningSpacePolicyTests {
    @Test("Music is always there; radio and spoken word appear with content")
    func visibility() {
        #expect(ListeningSpaceVisibilityPolicy.visibleSpaces(hasRadioStations: false, hasSpokenWord: false) == [.music])
        #expect(ListeningSpaceVisibilityPolicy.visibleSpaces(hasRadioStations: true, hasSpokenWord: false) == [.music, .radio])
        #expect(ListeningSpaceVisibilityPolicy.visibleSpaces(hasRadioStations: true, hasSpokenWord: true) == [.music, .radio, .spokenWord])
        #expect(ListeningSpaceVisibilityPolicy.visibleSpaces(hasRadioStations: false, hasSpokenWord: true) == [.music, .spokenWord])
    }

    @Test("Sleep options follow what can end")
    func sleepOptions() {
        #expect(SleepTimerOptionPolicy.options(for: .radio, hasChapters: false)
            == [.minutes(15), .minutes(30), .minutes(60), .minutes(90)])
        #expect(SleepTimerOptionPolicy.options(for: .music, hasChapters: true).last == .endOfTrack)
        let book = SleepTimerOptionPolicy.options(for: .spokenWord, hasChapters: true)
        #expect(book.contains(.endOfChapter))
        #expect(book.last == .endOfBook)
        #expect(!SleepTimerOptionPolicy.options(for: .spokenWord, hasChapters: false).contains(.endOfChapter))
    }

    @Test("The fade is silent at zero, full before it starts, and monotonic")
    func fade() {
        #expect(SleepFadePolicy.volume(remaining: 120) == 1)
        #expect(SleepFadePolicy.volume(remaining: 30) == 1)
        #expect(SleepFadePolicy.volume(remaining: 0) == 0)
        #expect(SleepFadePolicy.volume(remaining: -3) == 0)
        var last: Float = 1
        for second in stride(from: 29.0, through: 0, by: -1) {
            let volume = SleepFadePolicy.volume(remaining: second)
            #expect(volume <= last)
            last = volume
        }
    }

    @Test("Resume cards: newest first, one per space, not the one playing, not stale")
    func resumeCards() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cards = ListeningResumePolicy.cards(
            from: [
                .init(space: .music, lastListenedAt: now.addingTimeInterval(-600)),
                .init(space: .spokenWord, lastListenedAt: now.addingTimeInterval(-60)),
                .init(space: .radio, lastListenedAt: now.addingTimeInterval(-40 * 86_400)),
                .init(space: .music, lastListenedAt: now.addingTimeInterval(-7_200)),
            ],
            playingSpace: nil,
            now: now
        )
        #expect(cards.map(\.space) == [.spokenWord, .music])
        #expect(cards.last?.lastListenedAt == now.addingTimeInterval(-600))

        let whilePlayingBook = ListeningResumePolicy.cards(
            from: [
                .init(space: .music, lastListenedAt: now),
                .init(space: .spokenWord, lastListenedAt: now),
            ],
            playingSpace: .spokenWord,
            now: now
        )
        #expect(whilePlayingBook.map(\.space) == [.music])
    }
}

@Suite("Listening-space nudges")
struct ListeningSpaceNudgeTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Back to music: only near the end of the last item, with music set aside")
    func backToMusic() {
        var context = SmartNudgeContext(
            songID: "book-last",
            progress: 0.9,
            isLastInQueue: true,
            isSpokenWord: true,
            hasRememberedMusic: true
        )
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .backToMusic)
        context.hasRememberedMusic = false
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == nil)
        context.hasRememberedMusic = true
        context.progress = 0.4
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == nil)
        context.progress = 0.9
        context.isLastInQueue = false
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == nil)
    }

    @Test("Untagged long files are asked about; tagged or short ones are not")
    func classify() {
        #expect(SmartNudgePolicy.isLongUntagged(duration: 45 * 60, albumTitle: nil, artistName: " "))
        #expect(!SmartNudgePolicy.isLongUntagged(duration: 45 * 60, albumTitle: "Album", artistName: nil))
        #expect(!SmartNudgePolicy.isLongUntagged(duration: 5 * 60, albumTitle: nil, artistName: nil))
        let context = SmartNudgeContext(songID: "long", progress: 0.1, isLongUntagged: true)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .classifyAsSpokenWord)
        let spoken = SmartNudgeContext(songID: "long", progress: 0.1, isSpokenWord: true, isLongUntagged: true)
        #expect(SmartNudgePolicy.nudge(for: spoken, history: .init(), now: now) == nil)
    }
}

@Suite("Shuffle and repeat per listening space")
struct ListeningPlayModeLedgerTests {
    private let shuffledLoop = ListeningPlayMode(shuffleEnabled: true, repeatMode: .all)

    @Test("A book opened after shuffled, looping music plays in order, once")
    func bookStartsInOrder() {
        var ledger = ListeningPlayModeLedger()
        #expect(ledger.queueInstalled(ownedBy: .spokenWord, current: shuffledLoop) == .inOrder)
        #expect(ledger.activeSpace == .spokenWord)
        #expect(ledger.parkedMusicMode == shuffledLoop)
    }

    @Test("Music gets its own switches back when a music queue replaces the book")
    func musicRestored() {
        var ledger = ListeningPlayModeLedger()
        _ = ledger.queueInstalled(ownedBy: .spokenWord, current: shuffledLoop)
        #expect(ledger.queueInstalled(ownedBy: .music, current: .inOrder) == shuffledLoop)
        #expect(ledger.activeSpace == .music)
        #expect(ledger.parkedMusicMode == nil)
        // Music after music changes nothing.
        #expect(ledger.queueInstalled(ownedBy: .music, current: shuffledLoop) == nil)
    }

    @Test("A switch touched during the book is the listener's latest word")
    func touchedSwitchKept() {
        var ledger = ListeningPlayModeLedger()
        _ = ledger.queueInstalled(ownedBy: .spokenWord, current: shuffledLoop)
        // "Play in order" entry point for music, or a toggle during the book.
        ledger.shuffleChanged()
        let restored = ledger.queueInstalled(
            ownedBy: .music,
            current: ListeningPlayMode(shuffleEnabled: false, repeatMode: .off)
        )
        #expect(restored == ListeningPlayMode(shuffleEnabled: false, repeatMode: .all))
    }

    @Test("Touching a switch during music is not remembered as a book change")
    func musicTouchesIgnored() {
        var ledger = ListeningPlayModeLedger()
        ledger.shuffleChanged()
        ledger.repeatChanged()
        #expect(!ledger.shuffleChangedDuringBook)
        #expect(!ledger.repeatChangedDuringBook)
    }

    @Test("A second book starts in order and keeps music parked")
    func bookAfterBook() {
        var ledger = ListeningPlayModeLedger()
        _ = ledger.queueInstalled(ownedBy: .spokenWord, current: shuffledLoop)
        ledger.repeatChanged()
        let looping = ListeningPlayMode(shuffleEnabled: false, repeatMode: .one)
        #expect(ledger.queueInstalled(ownedBy: .spokenWord, current: looping) == .inOrder)
        #expect(!ledger.repeatChangedDuringBook)
        #expect(ledger.queueInstalled(ownedBy: .music, current: .inOrder) == shuffledLoop)
    }

    @Test("Radio never moves the ledger")
    func radioIgnored() {
        var ledger = ListeningPlayModeLedger()
        #expect(ledger.queueInstalled(ownedBy: .radio, current: shuffledLoop) == nil)
        _ = ledger.queueInstalled(ownedBy: .spokenWord, current: shuffledLoop)
        #expect(ledger.queueInstalled(ownedBy: .radio, current: .inOrder) == nil)
        #expect(ledger.activeSpace == .spokenWord)
    }

    @Test("The ledger survives a relaunch")
    func codable() throws {
        var ledger = ListeningPlayModeLedger()
        _ = ledger.queueInstalled(ownedBy: .spokenWord, current: shuffledLoop)
        ledger.shuffleChanged()
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(ListeningPlayModeLedger.self, from: data) == ledger)
    }

    @Test("Only music crossfades, and only music tops up from the library")
    func transitions() {
        #expect(ListeningSpaceTransitionPolicy.allowsCrossfade(from: .music, to: .music))
        #expect(!ListeningSpaceTransitionPolicy.allowsCrossfade(from: .spokenWord, to: .spokenWord))
        #expect(!ListeningSpaceTransitionPolicy.allowsCrossfade(from: .spokenWord, to: .music))
        #expect(!ListeningSpaceTransitionPolicy.allowsCrossfade(from: .music, to: .spokenWord))
        #expect(ShuffleLibraryContinuationPolicy.continuesFromLibrary(currentSpace: .music))
        #expect(!ShuffleLibraryContinuationPolicy.continuesFromLibrary(currentSpace: .spokenWord))
        #expect(!ShuffleLibraryContinuationPolicy.continuesFromLibrary(currentSpace: nil))
    }
}
