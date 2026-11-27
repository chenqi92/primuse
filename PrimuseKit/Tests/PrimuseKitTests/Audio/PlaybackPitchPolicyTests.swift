import Foundation
import Testing

@testable import PrimuseKit

@Suite("Playback key shift")
struct PlaybackPitchPolicyTests {
    @Test("Choices run from six semitones down to six up, like the karaoke stage")
    func choices() {
        #expect(PlaybackPitchPolicy.choices.first == -6)
        #expect(PlaybackPitchPolicy.choices.last == 6)
        #expect(PlaybackPitchPolicy.choices.count == 13)
        #expect(PlaybackPitchPolicy.clamped(9) == 6)
        #expect(PlaybackPitchPolicy.clamped(-40) == -6)
        #expect(PlaybackPitchPolicy.cents(forSemitones: -2) == -200)
    }

    @Test("Spoken word, live radio and outputs without the time-pitch unit stay in the original key")
    func effectiveSemitones() {
        #expect(PlaybackPitchPolicy.effectiveSemitones(3, isSpokenWord: false, isLiveRadio: false, outputAllowsPitch: true) == 3)
        #expect(PlaybackPitchPolicy.effectiveSemitones(3, isSpokenWord: true, isLiveRadio: false, outputAllowsPitch: true) == 0)
        #expect(PlaybackPitchPolicy.effectiveSemitones(3, isSpokenWord: false, isLiveRadio: true, outputAllowsPitch: true) == 0)
        #expect(PlaybackPitchPolicy.effectiveSemitones(3, isSpokenWord: false, isLiveRadio: false, outputAllowsPitch: false) == 0)
        #expect(PlaybackPitchPolicy.effectiveSemitones(11, isSpokenWord: false, isLiveRadio: false, outputAllowsPitch: true) == 6)
    }

    @Test("The karaoke stage shifts on top of the global key instead of replacing it")
    func combinedSemitones() {
        #expect(PlaybackPitchPolicy.combinedSemitones(user: 2, karaoke: 0) == 2)
        #expect(PlaybackPitchPolicy.combinedSemitones(user: 2, karaoke: -3) == -1)
        #expect(PlaybackPitchPolicy.combinedSemitones(user: -6, karaoke: -6) == -12)
        #expect(PlaybackPitchPolicy.combinedSemitones(user: 20, karaoke: 9) == 12)
    }

    @Test("The unit is written the sum of both shifts, within what it accepts")
    func combinedCents() {
        #expect(PlaybackPitchPolicy.combinedCents(userCents: 200, karaokeCents: 0) == 200)
        // Closing the stage writes zero for its part; the global shift stays.
        #expect(PlaybackPitchPolicy.combinedCents(userCents: 200, karaokeCents: -300) == -100)
        #expect(PlaybackPitchPolicy.combinedCents(userCents: 0, karaokeCents: 0) == 0)
        #expect(PlaybackPitchPolicy.combinedCents(userCents: 2000, karaokeCents: 2000) == 2400)
        #expect(PlaybackPitchPolicy.combinedCents(userCents: .nan, karaokeCents: 300) == 300)
        #expect(PlaybackPitchPolicy.combinedCents(userCents: -.infinity, karaokeCents: -100) == -100)
    }

    @Test("Labels carry a sign and the original key has none")
    func labels() {
        #expect(PlaybackPitchPolicy.signedLabel(0) == nil)
        #expect(PlaybackPitchPolicy.signedLabel(2) == "+2")
        #expect(PlaybackPitchPolicy.signedLabel(-3) == "-3")
        #expect(PlaybackPitchPolicy.signedLabel(8) == "+6")
    }

    @Test("Availability names the reason, spoken word and radio are not offered")
    func availability() {
        func resolve(
            spoken: Bool = false,
            radio: Bool = false,
            appleMusic: Bool = false,
            casting: Bool = false,
            highFidelity: Bool = false
        ) -> PlaybackPitchPolicy.Availability {
            PlaybackPitchPolicy.availability(
                isSpokenWord: spoken,
                isLiveRadio: radio,
                isAppleMusic: appleMusic,
                isCasting: casting,
                isHighFidelityOutput: highFidelity
            )
        }
        #expect(resolve() == .available)
        #expect(resolve(spoken: true, highFidelity: true) == .notOffered)
        #expect(resolve(radio: true) == .notOffered)
        #expect(resolve(appleMusic: true, casting: true) == .appleMusic)
        #expect(resolve(casting: true, highFidelity: true) == .casting)
        #expect(resolve(highFidelity: true) == .highFidelity)
        let explains = resolve(highFidelity: true).explainsOnTap
        #expect(explains)
        let hidden = resolve(spoken: true).explainsOnTap
        #expect(!hidden)
    }
}
