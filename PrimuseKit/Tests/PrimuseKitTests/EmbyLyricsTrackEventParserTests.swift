import Foundation
import Testing
@testable import PrimuseKit

@Suite("Emby lyrics TrackEvents")
struct EmbyLyricsTrackEventParserTests {
    @Test("Timed events become LRC and preserve an explicit zero timestamp")
    func timedEvents() throws {
        let data = Data(#"{"TrackEvents":[{"StartPositionTicks":0,"EndPositionTicks":10000000,"Text":"first"},{"StartPositionTicks":12500000,"Text":"second"}]}"#.utf8)

        let text = try EmbyLyricsTrackEventParser.editableText(from: data)

        #expect(text == "[00:00.000]first\n[00:01.250]second")
    }

    @Test("Untimed events remain editable plain text")
    func plainTextEvents() throws {
        let data = Data(#"{"TrackEvents":[{"Text":"first\r\nline"},{"Text":"second"}]}"#.utf8)

        let text = try EmbyLyricsTrackEventParser.editableText(from: data)

        #expect(text == "first\nline\nsecond")
    }

    @Test("Empty events do not create a false lyrics document")
    func emptyEvents() throws {
        let data = Data(#"{"TrackEvents":[{"StartPositionTicks":0,"Text":"  "}]}"#.utf8)

        #expect(try EmbyLyricsTrackEventParser.editableText(from: data) == nil)
    }

    @Test("Malformed JSON fails without producing partial lyrics")
    func malformedDocument() {
        #expect(throws: DecodingError.self) {
            try EmbyLyricsTrackEventParser.editableText(from: Data("not-json".utf8))
        }
    }

    @Test("Event count is bounded")
    func eventCountLimit() {
        let data = Data(#"{"TrackEvents":[{"Text":"one"},{"Text":"two"}]}"#.utf8)

        #expect(throws: EmbyLyricsTrackEventParser.ParseError.tooManyEvents(2)) {
            try EmbyLyricsTrackEventParser.editableText(from: data, maximumEventCount: 1)
        }
    }
}
