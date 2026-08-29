import Foundation
import Testing
@testable import PrimuseKit

struct WidgetLyricsPresentationPolicyTests {
    private let lines = [
        WidgetLyricLine(time: 0, text: "zero"),
        WidgetLyricLine(time: 1, text: "one"),
        WidgetLyricLine(time: 2, text: "two"),
        WidgetLyricLine(time: 3, text: "three"),
    ]

    @Test func threeRowWindowClampsAnchorsAndMarksTheActualCurrentLine() {
        let beginning = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: -10,
            maximumRowCount: 3
        )
        #expect(beginning.map(\.index) == [0, 1, 2])
        #expect(beginning.map(\.role) == [.current, .next, .next])

        let end = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 99,
            maximumRowCount: 3
        )
        #expect(end.map(\.index) == [1, 2, 3])
        #expect(end.map(\.role) == [.previous, .previous, .current])
    }

    @Test func reducedBudgetsAlwaysKeepTheCurrentLine() {
        let twoRows = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 1,
            maximumRowCount: 2
        )
        #expect(twoRows.map(\.index) == [1, 2])
        #expect(twoRows.map(\.role) == [.current, .next])

        let oneRow = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 2,
            maximumRowCount: 1
        )
        #expect(oneRow.map(\.index) == [2])
        #expect(oneRow.map(\.role) == [.current])
    }

    @Test func endOfSongUsesPreviousLineBeforeDroppingCurrentLine() {
        let rows = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 3,
            maximumRowCount: 2
        )
        #expect(rows.map(\.index) == [2, 3])
        #expect(rows.map(\.role) == [.previous, .current])
    }

    @Test func explicitDocumentDirectionWinsForTaggedMixedLyrics() {
        let mixed = [
            WidgetLyricLine(time: 0, text: "Tonight سلام دنیا"),
            WidgetLyricLine(time: 1, text: "Primuse 2026"),
        ]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: mixed,
                preferredDirection: .rightToLeft
            ) == .rightToLeft
        )
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: mixed,
                preferredDirection: .leftToRight
            ) == .leftToRight
        )
    }

    @Test func legacySnapshotsInferPersianButLeaveBalancedMixedTextNatural() {
        let persian = [
            WidgetLyricLine(time: 0, text: "تو مرا جان و جهانی\nچه کنم جان و جهان را"),
            WidgetLyricLine(time: 1, text: "تو مرا گنج روانی چه کنم سود و زیان را"),
        ]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: persian,
                preferredDirection: nil
            ) == .rightToLeft
        )

        let arabic = [WidgetLyricLine(time: 0, text: "ألا ليت الشباب يعود يوماً")]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: arabic,
                preferredDirection: nil
            ) == .rightToLeft
        )

        let mixed = [WidgetLyricLine(time: 0, text: "Hello سلام")]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: mixed,
                preferredDirection: nil
            ) == .natural
        )
    }

    @Test func legacySnapshotPayloadStillDecodesWithoutDirection() throws {
        let legacy = LegacyLyricsSnapshot(
            songID: "song",
            title: "title",
            artist: "artist",
            coverImageName: nil,
            lines: lines,
            anchorIndex: 1,
            isPlaying: true,
            updatedAt: Date(timeIntervalSinceReferenceDate: 42)
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(LyricsSnapshot.self, from: data)

        #expect(decoded.songID == legacy.songID)
        #expect(decoded.anchorIndex == legacy.anchorIndex)
        #expect(decoded.writingDirection == nil)
    }
}

private struct LegacyLyricsSnapshot: Codable {
    let songID: String
    let title: String
    let artist: String
    let coverImageName: String?
    let lines: [WidgetLyricLine]
    let anchorIndex: Int
    let isPlaying: Bool
    let updatedAt: Date
}
