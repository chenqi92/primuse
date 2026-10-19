import Foundation
import Testing
@testable import PrimuseKit

@Suite struct AudioClipExportPolicyTests {
    @Test func ringtoneKeepsItsStartAndStopsShortOfTheLimit() {
        let window = AudioClipExportPolicy.exportedWindow(start: 62, end: 110, songDuration: 240, purpose: .ringtone)
        #expect(window?.start == 62)
        // 30 s minus the margin the encoder's padding needs.
        #expect(abs((window?.end ?? 0) - 91.8) < 0.0001)

        let short = AudioClipExportPolicy.exportedWindow(start: 62, end: 80, songDuration: 240, purpose: .ringtone)
        #expect(short?.start == 62)
        #expect(short?.end == 80)
    }

    @Test func clipIsWrittenAsSelectedInsideTheSong() {
        let window = AudioClipExportPolicy.exportedWindow(start: 30, end: 200, songDuration: 180, purpose: .clip)
        #expect(window?.start == 30)
        #expect(window?.end == 180)

        // A CUE image's timeline is not written whole.
        let long = AudioClipExportPolicy.exportedWindow(start: 0, end: 4000, songDuration: 4000, purpose: .clip)
        #expect(long?.end == 1200)
    }

    @Test func refusesWhatIsTooShortOrUnknown() {
        #expect(AudioClipExportPolicy.exportedWindow(start: 10, end: 11, songDuration: 200, purpose: .clip) == nil)
        #expect(AudioClipExportPolicy.exportedWindow(start: 199, end: 260, songDuration: 200, purpose: .ringtone) == nil)
        #expect(AudioClipExportPolicy.exportedWindow(start: 0, end: 30, songDuration: 0, purpose: .clip) == nil)
        #expect(AudioClipExportPolicy.exportedWindow(start: .nan, end: 30, songDuration: 200, purpose: .clip) == nil)
    }

    @Test func tellsWhenARingtoneIsShortened() {
        #expect(!AudioClipExportPolicy.ringtoneIsShortened(length: 30))
        #expect(!AudioClipExportPolicy.ringtoneIsShortened(length: 30.04))
        #expect(AudioClipExportPolicy.ringtoneIsShortened(length: 30.5))
        #expect(!AudioClipExportPolicy.ringtoneIsShortened(length: .infinity))
    }

    @Test func highlightBecomesARangeAtTenths() {
        let range = AudioClipExportPolicy.range(highlightStart: 61.234, highlightEnd: 98.76, songDuration: 240)
        #expect(range == SongPlaybackRange(start: 61.2, end: 98.8, isEnabled: true))
    }

    @Test func ringtoneHighlightOpensOnTheChorus() {
        let range = AudioClipExportPolicy.range(
            highlightStart: 61.2,
            highlightEnd: 104,
            songDuration: 240,
            maximumLength: AudioClipExportPolicy.ringtoneMaximumLength
        )
        #expect(range?.start == 61.2)
        #expect(abs((range?.end ?? 0) - 91.2) < 0.0001)
    }

    @Test func highlightIsKeptInsideTheSong() {
        let tail = AudioClipExportPolicy.range(highlightStart: 230, highlightEnd: 260, songDuration: 240)
        #expect(tail?.start == 230)
        #expect(tail?.end == 240)

        // Too short at the very end: it grows backwards to the minimum.
        let sliver = AudioClipExportPolicy.range(highlightStart: 239.5, highlightEnd: 245, songDuration: 240)
        #expect(sliver?.end == 240)
        #expect(sliver?.start == 238)

        #expect(AudioClipExportPolicy.range(highlightStart: 0, highlightEnd: 10, songDuration: 1) == nil)
    }

    @Test func fadesScaleWithTheClip() {
        #expect(AudioClipExportPolicy.fades(forLength: 30) == .init(fadeIn: 1, fadeOut: 2))
        let short = AudioClipExportPolicy.fades(forLength: 4)
        #expect(abs(short.fadeIn - 0.4) < 0.0001)
        #expect(abs(short.fadeOut - 0.6) < 0.0001)
        #expect(AudioClipExportPolicy.fades(forLength: 0) == .off)
    }

    @Test func gainRisesAndFallsAtTheEnds() {
        let fades = AudioClipExportPolicy.Fades(fadeIn: 1, fadeOut: 2)
        #expect(AudioClipExportPolicy.gain(at: 0, length: 30, fades: fades) == 0)
        #expect(AudioClipExportPolicy.gain(at: 15, length: 30, fades: fades) == 1)
        #expect(AudioClipExportPolicy.gain(at: 30, length: 30, fades: fades) == 0)
        let rising = AudioClipExportPolicy.gain(at: 0.5, length: 30, fades: fades)
        #expect(abs(rising - Float(sin(Double.pi / 4))) < 0.0001)
        let falling = AudioClipExportPolicy.gain(at: 29, length: 30, fades: fades)
        #expect(abs(falling - Float(sin(Double.pi / 4))) < 0.0001)
        #expect(AudioClipExportPolicy.gain(at: 0, length: 30, fades: .off) == 1)
    }

    @Test func outputFollowsTheSourceFamily() {
        #expect(AudioClipExportPolicy.outputSampleRate(sourceSampleRate: 96_000) == 48_000)
        #expect(AudioClipExportPolicy.outputSampleRate(sourceSampleRate: 88_200) == 44_100)
        #expect(AudioClipExportPolicy.outputSampleRate(sourceSampleRate: 44_100) == 44_100)
        #expect(AudioClipExportPolicy.outputChannelCount(sourceChannelCount: 1) == 1)
        #expect(AudioClipExportPolicy.outputChannelCount(sourceChannelCount: 2) == 2)
        #expect(AudioClipExportPolicy.outputChannelCount(sourceChannelCount: 6) == 2)
        #expect(AudioClipExportPolicy.bitRateCandidates(channelCount: 1).first == 128_000)
        #expect(AudioClipExportPolicy.bitRateCandidates(channelCount: 2).first == 256_000)
        #expect(AudioClipExportPolicy.bitRateCandidates(channelCount: 1).last == 32_000)
    }

    @Test func writtenLengthCheck() {
        #expect(AudioClipExportPolicy.writtenLengthIsComplete(expected: 29.8, actual: 29.85))
        #expect(!AudioClipExportPolicy.writtenLengthIsComplete(expected: 29.8, actual: 12))
        #expect(!AudioClipExportPolicy.writtenLengthIsComplete(expected: 29.8, actual: 0))
    }

    @Test func fileNameIsSafe() {
        #expect(AudioClipExportPolicy.fileName(title: "晴天", artist: "周杰伦") == "晴天 - 周杰伦.m4a")
        #expect(AudioClipExportPolicy.fileName(title: "AC/DC: Live?", artist: nil) == "AC DC Live.m4a")
        #expect(AudioClipExportPolicy.fileName(title: "  ...  ", artist: "  ") == "Primuse.m4a")
        #expect(AudioClipExportPolicy.fileName(title: "Line\nBreak", artist: "") == "Line Break.m4a")
        let long = AudioClipExportPolicy.fileName(title: String(repeating: "a", count: 200), artist: "b")
        #expect(long.count == 80 + 4)
    }
}
