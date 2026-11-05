import Foundation
import Testing
@testable import PrimuseKit

@Suite("Existing lyrics alignment")
struct LyricAlignmentTests {
    private func output(_ rows: [[String: Any]]) throws -> LyricAlignmentOutput {
        try JSONDecoder().decode(LyricAlignmentOutput.self, from: JSONSerialization.data(withJSONObject: ["lines": rows]))
    }

    @Test func preservesTextAndCompanionsAndFallback() throws {
        let a = EditableLyricLine(timestamp: 1, text: "纸船，向灯岸。", manualTranslation: .init(text: "Paper boat", source: .localEditor), romanization: "zhi chuan")
        let b = EditableLyricLine(timestamp: 5, text: "潮声把夜放慢")
        let doc = LyricsEditorDocument(metadataLines: ["[ti:灯岸]"], lines: [a,b])
        let response = try output([
            ["id":a.id.uuidString, "status":"aligned", "words":[["text":"纸船，", "start":1.2,"end":2.0],["text":"向灯岸。","start":2.2,"end":3.0]]],
            ["id":b.id.uuidString,"status":"unaligned","words":[]]
        ])
        let aligned = try LyricAlignment.applying(response, to: doc, duration: 10)
        #expect(aligned.lines[0].text == a.text)
        #expect(aligned.lines[0].manualTranslation == a.manualTranslation)
        #expect(aligned.lines[0].romanization == a.romanization)
        #expect(aligned.lines[0].syllables?.allSatisfy { $0.endTiming == .explicit } == true)
        #expect(aligned.lines[1] == b)
        #expect(aligned.metadataLines == doc.metadataLines)
        #expect(LyricsStructuredPersistencePolicy.requiresTTML(aligned.lyricLines()))
    }

    @Test func rejectsAlteredMissingAndOverlappingWords() throws {
        let row = EditableLyricLine(text: "纸船")
        let doc = LyricsEditorDocument(lines: [row])
        for words in [
            [["text":"小船","start":1.0,"end":2.0]],
            [["text":"纸","start":1.0,"end":2.0]],
            [["text":"纸","start":1.0,"end":2.0],["text":"船","start":1.5,"end":3.0]],
            [["text":"纸船","start":1.0,"end":11.0]],
        ] {
            let response = try output([["id":row.id.uuidString,"status":"aligned","words":words]])
            #expect(throws: LyricAlignmentFailure.self) { try LyricAlignment.applying(response, to: doc, duration:10) }
        }
        let wrongID = try output([["id":UUID().uuidString,"status":"unaligned","words":[]]])
        #expect(throws: LyricAlignmentFailure.self) { try LyricAlignment.applying(wrongID, to:doc,duration:10) }
    }

    @Test func offsetAndRepeatedLinesStayDistinct() throws {
        let doc = LyricsEditorDocument(metadataLines:["[offset:500]"],lines:[
            EditableLyricLine(timestamp:1,text:"纸船"), EditableLyricLine(timestamp:4,text:"纸船")])
        let request = try LyricAlignment.requestLines(document:doc,duration:10)
        #expect(request[0].start == 0.5)
        #expect(request[0].end == 3.5)
        #expect(request[0].id != request[1].id)
        let response = try output(request.enumerated().map { i,row in
            ["id":row.id,"status":"aligned","words":[["text":row.text,"start":Double(i*3)+1,"end":Double(i*3)+2]]]
        })
        let result = try LyricAlignment.applying(response,to:doc,duration:10)
        #expect(result.lines[0].timestamp == 1)
        #expect(result.lines[1].timestamp == 4)
        #expect(result.metadataLines.isEmpty)
        let restored = LyricsContentParser.parse(LyricsContentParser.serializeTTML(result.lyricLines()))
        #expect(restored.first?.syllables?.first?.start == 1)
        #expect(restored.first?.syllables?.first?.end == 2)
    }

    @Test func enforcesWindowsAndPlainDuration() throws {
        let plain = LyricsEditorDocument(lines:[EditableLyricLine(text:"纸船")])
        #expect(throws: LyricAlignmentFailure.self) { try LyricAlignment.requestLines(document:plain,duration:301) }
        #expect(throws: LyricAlignmentFailure.self) { try LyricAlignment.requestLines(document:plain,duration:.nan) }
        let overlapping = LyricsEditorDocument(lines:[EditableLyricLine(timestamp:1,text:"纸船",endTimestamp:5),EditableLyricLine(timestamp:4,text:"灯岸")])
        #expect(throws: LyricAlignmentFailure.self) { try LyricAlignment.requestLines(document:overlapping,duration:10) }
        let mixed = LyricsEditorDocument(lines:[EditableLyricLine(timestamp:1,text:"纸船"),EditableLyricLine(text:"灯岸")])
        #expect(try LyricAlignment.requestLines(document:mixed,duration:10).allSatisfy { $0.start == nil && $0.end == nil })
    }
}
