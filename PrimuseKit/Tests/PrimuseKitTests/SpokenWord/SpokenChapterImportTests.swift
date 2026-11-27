import Foundation
import Testing
@testable import PrimuseKit

struct SpokenChapterImportTests {
    @Test func textSupportsHoursFractionsBOMAndWindowsLines() throws {
        let chapters = try SpokenChapterImport.parse(Data("\u{feff}00:00 Opening\r\n12:30.5 A title with spaces\r\n11:02:03 Finale\r\n".utf8), duration: 40_000)
        #expect(chapters.map(\.startTime) == [0, 750.5, 39_723])
        #expect(chapters.map(\.title) == ["Opening", "A title with spaces", "Finale"])
    }

    @Test func podcastJSONHonorsHiddenMarkersAndExplicitEnds() throws {
        let json = #"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Intro","endTime":12.5},{"startTime":15,"toc":false,"img":"https://example.com/art.jpg"},{"startTime":30}]}"#
        let chapters = try SpokenChapterImport.parse(Data(json.utf8), duration: 90)
        #expect(chapters.count == 2)
        #expect(chapters[0].endTime == 12.5)
        #expect(chapters[1].title == "0:30")
        #expect(SpokenWordSleepChapter.choices(songID: "s", title: "Episode", chapters: chapters)[0].endTime == 12.5)
    }

    @Test(arguments: ["", "00:00", "00:99 Bad", "-1:00 Bad", "00:00 First\n00:00 Duplicate",
                      "01:00 First\n00:00 Reversed", "00:00 First\ninvalid line", "01:60:00 Bad",
                      #"{"chapters":[{"startTime":true}]}"#,
                      #"{"chapters":[{"startTime":1e300}]}"#,
                      #"{"chapters":[{"startTime":0,"endTime":1e300}]}"#,
                      #"{"chapters":[{"startTime":-1,"title":"Bad"}]}"#,
                      #"{"chapters":[{"startTime":5,"endTime":2}]}"#,
                      #"{"chapters":[{"startTime":0,"endTime":20},{"startTime":10}]}"#])
    func invalidImportIsRejected(_ input: String) {
        #expect(throws: (any Error).self) { try SpokenChapterImport.parse(Data(input.utf8), duration: 100) }
    }

    @Test func durationAndSizeLimits() throws {
        #expect(throws: SpokenChapterImport.Failure.invalidTimeline) {
            try SpokenChapterImport.parse(Data("01:00 Out of range".utf8), duration: 60)
        }
        #expect(throws: SpokenChapterImport.Failure.invalidTimeline) {
            try SpokenChapterImport.parse(Data(#"{"chapters":[{"startTime":0,"endTime":61}]}"#.utf8), duration: 60)
        }
        #expect(throws: SpokenChapterImport.Failure.tooLarge) {
            try SpokenChapterImport.parse(Data(repeating: 32, count: SpokenChapterImport.maximumBytes + 1))
        }
        #expect(throws: SpokenChapterImport.Failure.invalidFormat) {
            try SpokenChapterImport.parse(Data([0xff, 0xfe, 0x00]))
        }
        #expect(try SpokenChapterImport.parse(Data("11:00:00 Long book".utf8)).count == 1)
    }

    @Test func previewDoesNotOverwriteConcurrentEditsAndRoundTripsOrigin() throws {
        let preview = try SpokenChapterImportPreview(songID: "s", data: Data("00:00 Intro".utf8), duration: 60, previousRevision: nil)
        let record = try preview.record(replacing: nil)
        #expect(record.origin == .imported)
        #expect(try JSONDecoder().decode(SpokenChapterRecord.self, from: JSONEncoder().encode(record)) == record)
        #expect(throws: SpokenChapterGeneration.Failure.changedDuringGeneration) { try preview.record(replacing: record) }
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacy.removeValue(forKey: "origin")
        #expect(try JSONDecoder().decode(SpokenChapterRecord.self, from: JSONSerialization.data(withJSONObject: legacy)).origin == nil)
    }
}

struct SpokenWordSleepSelectionTests {
    private let target = SpokenWordSleepChapter(songID: "two", title: "Chapter 5", startTime: 30, endTime: 60)

    @Test func followsBookFilesAndStopsOnContentTime() throws {
        var lock = try #require(SpokenWordSleepSelection(chapter: target, orderedSongIDs: ["one", "two", "three"],
                                                       currentSongID: "one", position: 500, chapterRevision: nil))
        #expect(!lock.shouldStop(songID: "one", position: 1_000))
        let followsTarget = lock.follow(songID: "two")
        #expect(followsTarget)
        #expect(!lock.shouldStop(songID: "two", position: 59.99))
        #expect(lock.shouldStop(songID: "two", position: 60))
        #expect(lock.shouldStop(songID: "two", position: 100))
        #expect(!lock.shouldStop(songID: "two", position: 20))
        let followsPastTarget = lock.follow(songID: "three")
        let followsNothing = lock.follow(songID: nil)
        #expect(!followsPastTarget)
        #expect(!followsNothing)
    }

    @Test func rejectsPastChapterAndFollowsNaturalEndWithoutKnownDuration() throws {
        #expect(SpokenWordSleepSelection(chapter: target, orderedSongIDs: ["one", "two"],
                                         currentSongID: "two", position: 60, chapterRevision: nil) == nil)
        let final = try #require(SpokenWordSleepChapter.choices(songID: "two", title: "Book",
                                    chapters: [.init(startTime: 0, title: "First"), .init(startTime: 30, title: "Last")]).last)
        #expect(final.endTime == nil)
        let lock = try #require(SpokenWordSleepSelection(chapter: final, orderedSongIDs: ["two"],
                                     currentSongID: "two", position: 35, chapterRevision: nil))
        #expect(!lock.shouldStop(songID: "two", position: 100))
    }
}
