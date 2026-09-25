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

    @Test("The introduction is only for people who used the old layout")
    func introduction() {
        #expect(ListeningSpacesIntroductionPolicy.shouldShow(hasSeen: false, isExistingUser: true))
        #expect(!ListeningSpacesIntroductionPolicy.shouldShow(hasSeen: false, isExistingUser: false))
        #expect(!ListeningSpacesIntroductionPolicy.shouldShow(hasSeen: true, isExistingUser: true))
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
