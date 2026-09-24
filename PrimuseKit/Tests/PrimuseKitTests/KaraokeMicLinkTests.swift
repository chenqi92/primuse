import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke mic link")
struct KaraokeMicLinkTests {
    @Test("Pairing links round-trip and reject incomplete ones")
    func pairing() throws {
        let endpoint = KaraokeMicLink.Endpoint(host: "192.168.1.20", port: 51_234, key: KaraokeMicLink.makeKey())
        #expect(endpoint.url.absoluteString.hasPrefix("primuse://karaoke-mic?"))
        #expect(KaraokeMicLink.Endpoint(url: endpoint.url) == endpoint)
        #expect(KaraokeMicLink.Endpoint(url: URL(string: "primuse://karaoke-mic?host=a&port=0&k=abcdefghijklmnopqrst")!) == nil)
        #expect(KaraokeMicLink.Endpoint(url: URL(string: "primuse://karaoke-mic?host=a&port=80&k=short")!) == nil)
        #expect(KaraokeMicLink.Endpoint(url: URL(string: "primuse://pair?host=a&port=80&k=abcdefghijklmnopqrst")!) == nil)
        #expect(KaraokeMicLink.makeKey().count == 24)
        #expect(KaraokeMicLink.makeKey() != KaraokeMicLink.makeKey())
    }

    @Test("Messages survive arbitrary stream splits")
    func framing() {
        let messages: [KaraokeMicLink.PhoneMessage] = [
            .hello(version: 1, key: "k", deviceName: "iPhone"),
            .reading(sequence: 1, midiNote: 61.5),
            .reading(sequence: 2, midiNote: nil),
            .goodbye,
        ]
        let stream = messages.map { KaraokeMicLink.encode($0) }.reduce(Data(), +)
        var framer = KaraokeMicLink.Framer()
        var received: [KaraokeMicLink.PhoneMessage] = []
        var offset = 0
        for size in [1, 7, 3, 40, 2, 1_000] where offset < stream.count {
            let end = min(stream.count, offset + size)
            received += framer.append(stream[offset..<end], as: KaraokeMicLink.PhoneMessage.self)
            offset = end
        }
        #expect(received == messages)
    }

    @Test("Garbage and oversized lines are dropped")
    func badInput() {
        var framer = KaraokeMicLink.Framer()
        #expect(framer.append(Data("nonsense\n".utf8), as: KaraokeMicLink.TVMessage.self).isEmpty)
        let huge = Data(repeating: 0x41, count: KaraokeMicLink.Framer.maximumLineLength + 10)
        #expect(framer.append(huge, as: KaraokeMicLink.TVMessage.self).isEmpty)
        let good = KaraokeMicLink.encode(KaraokeMicLink.TVMessage.status(songTitle: "a", isPlaying: true, score: 90))
        #expect(framer.append(good, as: KaraokeMicLink.TVMessage.self) == [.status(songTitle: "a", isPlaying: true, score: 90)])
    }

    @Test("Finds the delay between the song and the sung readings")
    func lagEstimate() {
        var reference = KaraokePitchTrack(capacity: 2_000)
        let notes: [Double] = [60, 62, 64, 65, 67, 65, 64, 62]
        func note(at t: Double) -> Double? {
            let index = Int(t / 0.4)
            // Short rests between notes, as in singing.
            return t - Double(index) * 0.4 < 0.32 ? notes[index % notes.count] : nil
        }
        var t = 0.0
        while t < 20 {
            reference.append(time: t, midiNote: note(at: t))
            t += 0.05
        }
        let lag = 0.26
        var estimator = KaraokeLagEstimator()
        estimator.update(reference: reference)
        #expect(!estimator.isCalibrated)
        #expect(estimator.lag == KaraokeLagEstimator.defaultLag)
        t = 1
        var step = 0
        while t < 20 {
            // The singer hits the note heard `lag` ago, with a few wrong notes.
            let sung = note(at: t - lag).map { step % 9 == 0 ? $0 + 2 : $0 }
            estimator.record(time: t, sung: sung)
            t += 0.05
            step += 1
        }
        estimator.update(reference: reference)
        #expect(estimator.isCalibrated)
        #expect(abs(estimator.lag - lag) <= 0.03, "lag \(estimator.lag)")
    }
}
