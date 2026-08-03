import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric line synchronization semantics")
struct LyricLineSynchronizationTests {
    @Test("Plain-text compatibility timestamps do not imply synchronization")
    func plainTextLinesRemainUnsynchronized() {
        let lines = [
            LyricLine(timestamp: 0, text: "First"),
            LyricLine(timestamp: 0, text: "Second"),
        ]

        #expect(lines.allSatisfy { !$0.isSynchronized })
    }

    @Test("A synchronized line may explicitly begin at zero")
    func synchronizedLineCanBeginAtZero() {
        let line = LyricLine(
            timestamp: 0,
            text: "Opening",
            isSynchronized: true
        )

        #expect(line.isSynchronized)
    }

    @Test("Explicit zero-time synchronization survives cache encoding")
    func explicitSynchronizationRoundTrips() throws {
        let line = LyricLine(
            id: "opening",
            timestamp: 0,
            text: "Opening",
            isSynchronized: true
        )

        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(LyricLine.self, from: data)

        #expect(decoded == line)
        #expect(decoded.isSynchronized)
    }
}
