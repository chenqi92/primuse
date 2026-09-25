import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke practice")
struct KaraokePracticePolicyTests {
    private let windows = [
        KaraokeLineWindow(lineIndex: 0, lineID: "a", voice: .primary, start: 10, end: 14),
        KaraokeLineWindow(lineIndex: 1, lineID: "b", voice: .primary, start: 14.2, end: 18),
        KaraokeLineWindow(lineIndex: 2, lineID: "c", voice: .primary, start: 25, end: 29),
    ]

    @Test("Looping the current line counts in and stops before the next line")
    func currentLine() throws {
        let loop = try #require(KaraokePracticePolicy.loop(windows: windows, at: 11))
        #expect(loop.firstWindow == 0 && loop.lastWindow == 0)
        #expect(loop.start == 8.5)
        // The next line starts 0.2 s later, sooner than the post-roll.
        #expect(abs(loop.end - 14.2) < 1e-9)
    }

    @Test("Between lines the next line is looped; after the last none is")
    func nextLine() throws {
        let loop = try #require(KaraokePracticePolicy.loop(windows: windows, at: 20))
        #expect(loop.firstWindow == 2)
        #expect(loop.start == 23.5)
        #expect(abs(loop.end - 29.4) < 1e-9)
        #expect(KaraokePracticePolicy.loop(windows: windows, at: 40) == nil)
        #expect(KaraokePracticePolicy.loop(windows: [], at: 0) == nil)
    }

    @Test("Extending adds the following line until there is none")
    func extend() throws {
        let first = try #require(KaraokePracticePolicy.loop(windows: windows, at: 11))
        let two = try #require(KaraokePracticePolicy.extended(first, windows: windows))
        #expect(two.lineCount == 2)
        #expect(two.start == first.start)
        #expect(abs(two.end - 18.4) < 1e-9)
        let three = try #require(KaraokePracticePolicy.extended(two, windows: windows))
        #expect(three.lineCount == 3)
        #expect(KaraokePracticePolicy.extended(three, windows: windows) == nil)
    }

    @Test("Playback jumps back at the end and leaves when moved away by hand")
    func actions() throws {
        let loop = try #require(KaraokePracticePolicy.loop(windows: windows, at: 11))
        #expect(KaraokePracticePolicy.action(for: loop, at: 9) == .none)
        #expect(KaraokePracticePolicy.action(for: loop, at: 14.1) == .none)
        #expect(KaraokePracticePolicy.action(for: loop, at: 14.2) == .jumpBack)
        #expect(KaraokePracticePolicy.action(for: loop, at: 15) == .jumpBack)
        #expect(KaraokePracticePolicy.action(for: loop, at: 30) == .leave)
        #expect(KaraokePracticePolicy.action(for: loop, at: 3) == .leave)
    }

    @Test("Speeds step within the practice range")
    func rates() {
        #expect(KaraokePracticePolicy.stepped(1, up: false) == 0.9)
        #expect(KaraokePracticePolicy.stepped(0.9, up: true) == 1)
        #expect(KaraokePracticePolicy.stepped(1, up: true) == 1)
        #expect(KaraokePracticePolicy.stepped(0.5, up: false) == 0.5)
        #expect(KaraokePracticePolicy.stepped(0.75, up: false) == 0.7)
    }
}
