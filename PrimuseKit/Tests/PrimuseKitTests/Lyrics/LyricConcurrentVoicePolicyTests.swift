import Foundation
import Testing
@testable import PrimuseKit

@Suite("Concurrent duet voices")
struct LyricConcurrentVoicePolicyTests {
    private func line(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval?,
        _ voice: LyricVoice
    ) -> LyricLine {
        LyricLine(
            id: text,
            timestamp: start,
            text: text,
            isSynchronized: true,
            syllables: end.map { [LyricSyllable(text: text, start: start, end: $0, endTiming: .explicit)] },
            endTimestamp: end,
            voice: voice
        )
    }

    /// v2 joins while v1 is still singing, then v1 takes the next line while
    /// v2 is still singing, and finally both sing at the same moment.
    private var duet: [LyricLine] {
        [
            line("v1 first", 10, 14, .primary),
            line("v2 joins", 12.5, 15.5, .secondary),
            line("v1 next", 15, 18, .primary),
            line("v2 together", 20, 22, .secondary),
            line("v1 together", 20, 22, .primary),
            line("v1 solo", 23, 25, .primary),
        ]
    }

    @Test("Overlapping lines of different voices sing together and scroll to the earliest one")
    func overlappingVoicesAreActiveTogether() throws {
        let lyrics = duet

        #expect(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 11)?.rows == [0])

        let joined = try #require(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 13))
        #expect(joined.rows == [0, 1])
        #expect(joined.anchor == 0)
        #expect(joined.frontier == 1)
        #expect(joined.isConcurrent)

        // v1 finished its first line; its next line and the v2 line overlap.
        let handover = try #require(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 15.2))
        #expect(handover.rows == [1, 2])
        #expect(handover.anchor == 1)
        #expect(handover.hasPassed(0))
        #expect(!handover.hasPassed(1))

        // v2 ended: only the v1 line keeps singing.
        #expect(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 16)?.rows == [2])

        let together = try #require(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 21))
        #expect(together.rows == [3, 4])
        #expect(together.anchor == 3)

        #expect(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 24)?.rows == [5])
        #expect(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 5) == nil)
    }

    @Test("A finished row between two singing rows counts as sung")
    func finishedRowBetweenSingersHasPassed() throws {
        let lyrics = [
            line("v1 long", 10, 20, .primary),
            line("v2 short", 11, 12, .secondary),
            line("v2 again", 13, 14, .secondary),
        ]
        let rows = try #require(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 13.5))
        #expect(rows.rows == [0, 2])
        #expect(rows.hasPassed(1))
        #expect(!rows.hasPassed(0))
        #expect(!rows.hasPassed(2))
    }

    @Test("Single-voice lyrics keep exactly one active row")
    func singleVoiceMatchesActiveLineIndex() {
        let lyrics = [
            line("First", 10, 13, .primary),
            line("Second overlaps the first end", 12.5, 15, .primary),
            LyricLine(timestamp: 16, text: "Plain"),
            LyricLine(timestamp: 16, text: "Translation"),
        ]
        for time in stride(from: 9.0, through: 18.0, by: 0.25) {
            let expected = LyricPlaybackPositionPolicy.activeLineIndex(in: lyrics, at: time)
            let rows = LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: time)
            #expect(rows?.rows == expected.map { [$0] })
            #expect(rows?.anchor == expected)
        }
    }

    @Test("Same-voice companions at one timestamp do not light up")
    func sameVoiceCompanionsStayCompanions() {
        let lyrics = [
            LyricLine(timestamp: 10, text: "Source", endTimestamp: 12),
            LyricLine(timestamp: 10, text: "Reading", endTimestamp: 12),
            LyricLine(timestamp: 10, text: "Partner", endTimestamp: 12, voice: .secondary),
        ]
        #expect(LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: 11)?.rows == [0, 2])
    }

    @Test("A word sweep keeps running while the other voice sings")
    func deactivationWaitsForOwnEnd() {
        let lyrics = duet
        // v2 joins at 12.5, but the v1 line runs to 14.
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(in: lyrics, afterLine: 0, lookahead: 0.1) == 14)
        // v2 line ends at 15.5; the next v2 line starts later.
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(in: lyrics, afterLine: 1, lookahead: 0.1) == 15.5)
        // v1 next ends before the next group: hand over at the next group as before.
        let handover = LyricPlaybackPositionPolicy.wordLevelDeactivationTime(in: lyrics, afterLine: 2, lookahead: 0.1)
        #expect(handover.map { abs($0 - 19.9) < 0.000001 } == true)

        // The same voice taking its next line ends the sweep even before the written end.
        let sloppy = [
            line("v1 a", 10, 16, .primary),
            line("v2", 11, 12, .secondary),
            line("v1 b", 14, 18, .primary),
        ]
        let release = LyricPlaybackPositionPolicy.wordLevelDeactivationTime(in: sloppy, afterLine: 0, lookahead: 0.1)
        #expect(release.map { abs($0 - 13.9) < 0.000001 } == true)
    }

    @Test("No interlude while the other voice is still singing")
    func interludeWaitsForOverlappingVoice() {
        let lyrics = [
            line("v1 held note", 10, 30, .primary),
            line("v2 short", 12, 14, .secondary),
            line("v1 after", 31, 33, .primary),
        ]
        #expect(LyricPlaybackPositionPolicy.interludeWindow(afterLine: 1, in: lyrics) == nil)
        #expect(LyricPlaybackPositionPolicy.activeInterlude(in: lyrics, at: 20) == nil)

        let solo = [
            line("v1", 10, 14, .primary),
            line("v1 after", 31, 33, .primary),
        ]
        #expect(LyricPlaybackPositionPolicy.interludeWindow(afterLine: 0, in: solo)?.vocalsEnd == 14)
    }

    @Test("Generic rows match the LyricLine rows")
    func genericRowsMatch() {
        struct Row { let time: TimeInterval; let end: TimeInterval?; let voice: LyricVoice }
        let lyrics = duet
        let rows = lyrics.map { Row(time: $0.timestamp, end: $0.endTime, voice: $0.voice) }
        for time in stride(from: 9.0, through: 26.0, by: 0.5) {
            let generic = LyricConcurrentVoicePolicy.activeRows(
                in: rows,
                at: time,
                timestamp: \.time,
                end: \.end,
                voice: \.voice
            )
            #expect(generic == LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: time))
        }
    }

    @Test("Legacy caches split overlapping duet lines out of the lead row")
    func legacyGroupedDuetLinesSeparate() throws {
        var host = line("v1 host", 10, 14, .primary)
        let beyond = line("v2 beyond", 12, 16, .secondary)
        let sameStart = line("v2 same start", 10, 13, .secondary)
        let contained = line("v2 contained", 11, 12, .secondary)
        var backing = line("(echo)", 12, 15, .secondary)
        backing.isBackingVocal = true
        host.background = [beyond, sameStart, contained, backing]
        let cached = [host, line("v2 solo", 20, 22, .secondary)]

        let separated = LyricVoiceTimelinePolicy.separatingLegacyOverlapGroups(in: cached)

        #expect(separated.map(\.text) == ["v1 host", "v2 same start", "v2 beyond", "v2 solo"])
        #expect(separated[0].background?.map(\.text) == ["v2 contained", "(echo)"])
        #expect(LyricVoiceTimelinePolicy.separatingLegacyOverlapGroups(in: separated) == separated)
    }

    @Test("Backing vocals of non-duet lyrics are never split")
    func nonDuetBackingStays() {
        var host = line("Lead", 10, 14, .primary)
        host.background = [line("(beyond)", 12, 16, .secondary)]
        let cached = [host, line("Next", 20, 22, .primary)]
        #expect(LyricVoiceTimelinePolicy.separatingLegacyOverlapGroups(in: cached) == cached)
    }

    @Test("Karaoke stage sings the overlapping partner row together")
    func karaokePartnerRow() {
        let windows = KaraokeLineWindowPolicy.windows(in: duet)
        let active = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: 13)
        #expect(active == 1)
        #expect(KaraokeLineWindowPolicy.concurrentPartnerIndex(before: 1, in: windows, at: 13) == 0)
        #expect(KaraokeLineWindowPolicy.concurrentPartnerIndex(before: 1, in: windows, at: 14.5) == nil)
        #expect(KaraokeLineWindowPolicy.concurrentPartnerIndex(before: 0, in: windows, at: 11) == nil)
    }
}
