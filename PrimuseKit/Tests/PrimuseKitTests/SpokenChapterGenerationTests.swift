import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken chapter generation")
struct SpokenChapterGenerationTests {
    typealias G = SpokenChapterGeneration

    @Test func plainTextIsNotAPlaybackTimeline() {
        #expect(throws: G.Failure.missingTimedTranscript) {
            try G.lines(from: [LyricLine(timestamp: 0, text: "Chapter one", isSynchronized: false)], duration: 100)
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, 100])
    func rejectsInvalidTimes(_ time: Double) {
        #expect(throws: G.Failure.invalidTranscript) {
            try G.lines(from: [LyricLine(timestamp: time, text: "Text", isSynchronized: true)], duration: 100)
        }
    }

    @Test func preservesExplicitEndsWithoutInventingSilence() throws {
        let lines = try G.lines(from: [
            LyricLine(timestamp: 0, text: "Chapter one", isSynchronized: true, endTimestamp: 2),
            LyricLine(timestamp: 60, text: "Story", isSynchronized: true)
        ], duration: 200)
        #expect(lines[0].end == 2)
        #expect(lines[1].end == nil)
        #expect(lines.map(\.id) == ["0", "1"])
    }

    @Test func longTextAndMultiDayBooksHaveCompleteNonOverlappingOwnership() {
        let lines = (0..<1500).map { G.Line(id: String($0), start: Double($0) * 90, text: String(repeating: "文", count: 100)) }
        let windows = G.windows(lines)
        #expect(windows.count > 20)
        let ids = windows.flatMap { $0.ownedIDs }
        #expect(ids.count == lines.count)
        #expect(Set(ids) == Set(lines.map(\.id)))
        for window in windows { #expect(window.lines.count <= 242) }
    }

    @Test func onDeviceWindowsPreserveTranscriptAndBoundDenseCues() async throws {
        let lines = (0..<120).map { G.Line(id: String($0), start: Double($0) * 30, text: String(repeating: "文", count: 80)) }
        let windows = G.windows(lines, maximumCharacters: G.Limits.onDevice.maximumCharacters,
                                maximumLines: G.Limits.onDevice.maximumLines)
        let owned = windows.flatMap { window in window.lines.filter { window.ownedIDs.contains($0.id) } }
        #expect(owned == lines)
        #expect(windows.allSatisfy { $0.lines.count <= 22 })
        let chapters = try await G.generate(title: "Book", language: "en", lines: lines, limits: .onDevice) { request in
            #expect(request.previousSummaries.allSatisfy { $0.count <= 200 })
            if request.stage == .curate {
                #expect(request.candidates.count <= 4)
                return .init(summary: "Whole", chapters: request.candidates)
            }
            return .init(summary: String(repeating: "文", count: 600),
                         chapters: [.init(lineID: request.lines.last!.id, title: "Topic")])
        }
        #expect(chapters.first?.startTime == 0)
        #expect(chapters.last?.startTime == lines.last?.start)
        #expect(chapters.map(\.startTime) == chapters.map(\.startTime).sorted())
    }

    @Test func oversizedCueLosesNoText() {
        let source = String(repeating: "word 🎵 ", count: 4000)
        let windows = G.windows([G.Line(id: "0", start: 2, text: source)])
        let owned = windows.flatMap { window in window.lines.filter { window.ownedIDs.contains($0.id) } }
        #expect(owned.map(\.text).joined() == source)
        #expect(owned.allSatisfy { $0.start == 2 })
        #expect(Set(owned.map(\.id)).count == owned.count)
    }

    @Test func providerCannotInventIDsOrReorderOrDuplicateChapters() throws {
        let request = G.Request(title: "Book", language: "en", lines: [
            .init(id: "a", start: 0, text: "First"), .init(id: "b", start: 60, text: "Next")
        ])
        for drafts: [G.Draft] in [
            [.init(lineID: "missing", title: "Invented")],
            [.init(lineID: "b", title: "Next"), .init(lineID: "a", title: "First")],
            [.init(lineID: "a", title: "First"), .init(lineID: "a", title: "Again")],
            [.init(lineID: "a", title: " ")], [.init(lineID: "a", title: "two\nlines")]
        ] {
            #expect(throws: G.Failure.invalidResponse) { try G.validate(.init(summary: "", chapters: drafts), for: request) }
        }
        let good = try G.decode("```json\n{\"summary\":\"Story\",\"chapters\":[{\"lineID\":\"a\",\"title\":\" Start \"}]}\n```", for: request)
        #expect(good.chapters.first?.title == "Start")
    }

    @Test func curationCannotDropOpeningOrAddUnproposedBoundary() {
        let request = G.Request(title: "Book", language: "en", stage: .curate,
                                lines: [.init(id: "a", start: 0, text: "First"), .init(id: "b", start: 90, text: "Next")],
                                candidates: [.init(lineID: "a", title: "First")])
        #expect(throws: G.Failure.invalidResponse) { try G.validate(.init(summary: "", chapters: []), for: request) }
        #expect(throws: G.Failure.invalidResponse) {
            try G.validate(.init(summary: "", chapters: [.init(lineID: "b", title: "Next")]), for: request)
        }
    }

    @Test func endToEndChunkingCurationAndExactPlaybackTimes() async throws {
        let lines = (0..<90).map { G.Line(id: String($0), start: Double($0) * 60, text: "Topic \($0)") }
        let chapters = try await G.generate(title: "Book", language: "en", lines: lines) { request in
            if request.stage == .curate { return .init(summary: "Whole", chapters: request.candidates) }
            return .init(summary: "Topics", chapters: request.lines.filter { Int($0.id)! % 15 == 0 }.map { .init(lineID: $0.id, title: $0.text) })
        }
        #expect(chapters.map(\.startTime) == [0, 900, 1800, 2700, 3600, 4500])
        #expect(chapters.map(\.title) == ["Topic 0", "Topic 15", "Topic 30", "Topic 45", "Topic 60", "Topic 75"])
    }

    @Test func curationMergesAcrossBatchBoundaries() async throws {
        let lines = (0..<70).map { G.Line(id: String($0), start: Double($0) * 120, text: "Topic \($0)") }
        let chapters = try await G.generate(title: "Book", language: "en", lines: lines) { request in
            if request.stage == .curate {
                #expect(request.candidates.count <= 32)
                // Boundary 31 continues topic 30, across the curation batch boundary.
                return .init(summary: "Curated", chapters: request.candidates.filter { $0.lineID != "31" })
            }
            return .init(summary: "Topics", chapters: request.lines.map { .init(lineID: $0.id, title: $0.text) })
        }
        #expect(chapters.count == 69)
        #expect(!chapters.contains { $0.startTime == 31 * 120 })
        #expect(chapters.last?.startTime == 8_280.0)
    }

    @Test func splitCueDoesNotCreateRepeatedTimeChapters() async throws {
        let chapters = try await G.generate(title: "Book", language: "en", lines: [
            .init(id: "0", start: 0, text: String(repeating: "a", count: 30_000))
        ]) { request in
            .init(summary: "One topic", chapters: request.stage == .curate ? request.candidates
                  : request.lines.map { .init(lineID: $0.id, title: "Topic") })
        }
        #expect(chapters.count == 1)
    }

    @Test func longEpisodesMergeShortTopicsWithoutSkippingTranscriptWindows() async throws {
        actor Coverage {
            var ids = Set<String>()
            func add(_ lines: [G.Line]) { ids.formUnion(lines.map(\.id)) }
        }
        let coverage = Coverage()
        let duration = 11.0 * 3_600
        let lines = (0..<330).map { G.Line(id: String($0), start: Double($0) * 120, text: "Scene \($0)") }
        let chapters = try await G.generate(title: "Long story", language: "en", lines: lines, duration: duration) { request in
            if request.stage == .analyze { await coverage.add(request.lines) }
            return .init(summary: "Story", chapters: request.stage == .curate ? request.candidates
                : request.lines.map { .init(lineID: $0.id, title: $0.text) })
        }
        #expect(await coverage.ids == Set(lines.map(\.id)))
        #expect(chapters.first?.startTime == 0)
        #expect(chapters.count > 30 && chapters.count < 90)
        #expect(chapters.last!.startTime > 10 * 3_600)
        #expect(zip(chapters, chapters.dropFirst()).allSatisfy { $1.startTime - $0.startTime >= 5 * 60 })
        #expect(duration - chapters.last!.startTime >= 5 * 60)
    }

    @Test func shortEpisodesRetainUsefulTwoMinuteTopics() async throws {
        let lines = (0..<10).map { G.Line(id: String($0), start: Double($0) * 120, text: "Topic \($0)") }
        let chapters = try await G.generate(title: "Short episode", language: "en", lines: lines, duration: 1_200) { request in
            .init(summary: "Topics", chapters: request.stage == .curate ? request.candidates
                : request.lines.map { .init(lineID: $0.id, title: $0.text) })
        }
        #expect(chapters.map(\.startTime) == lines.map(\.start))
    }

    @Test func spokenHeadingsSurviveModelOmissionAndShortSpacing() async throws {
        let lines: [G.Line] = [
            .init(id: "0", start: 0, text: "Opening"),
            .init(id: "1", start: 180, text: "Chapter 21: An unexpected visitor"),
            .init(id: "2", start: 240, text: "He remembered chapter 33 of the book."),
            .init(id: "3", start: 300, text: "Part IV — The return"),
            .init(id: "4", start: 420, text: "Chapter Twenty-One: The journey"),
            .init(id: "5", start: 510, text: "第二十二章 归途"),
            .init(id: "6", start: 600, text: "part of the story remains unexplained")
        ]
        let chapters = try await G.generate(title: "Book", language: "en", lines: lines, duration: 39_600) { request in
            // The model proposes no boundaries, then tries to merge all headings into the opening.
            .init(summary: "Story", chapters: request.stage == .curate ? Array(request.candidates.prefix(1)) : [])
        }
        #expect(chapters.map(\.startTime) == [0, 180, 300, 420, 510])
        #expect(chapters[1].title == "Chapter 21: An unexpected visitor")
    }

    @Test func explicitGapsSupportNearbyModelBoundariesButStartTimesAloneDoNot() async throws {
        func generate(withEnds: Bool, proposeGap: Bool) async throws -> [MediaChapter] {
            let lines: [G.Line] = [
                .init(id: "0", start: 0, end: withEnds ? 600 : nil, text: "Opening"),
                .init(id: "1", start: 600, end: withEnds ? 610 : nil, text: "Same scene"),
                .init(id: "2", start: 720, end: withEnds ? 1_440 : nil, text: "New scene"),
                .init(id: "3", start: 1_440, end: withEnds ? 1_500 : nil, text: "Next scene"),
                .init(id: "4", start: 1_500, end: withEnds ? 1_600 : nil, text: "Continuation")
            ]
            return try await G.generate(title: "Long book", language: "en", lines: lines, duration: 39_600) { request in
                .init(summary: "Scenes", chapters: request.stage == .curate ? request.candidates
                    : request.lines.filter { proposeGap || $0.id != "2" }.map { .init(lineID: $0.id, title: $0.text) })
            }
        }
        #expect(try await generate(withEnds: true, proposeGap: true).map(\.startTime) == [0, 720, 1_440])
        #expect(try await generate(withEnds: false, proposeGap: true).map(\.startTime) == [0, 600, 1_440])
        #expect(try await generate(withEnds: true, proposeGap: false).map(\.startTime) == [0, 600, 1_440])
    }

    @Test func overlappingSpeechDoesNotEstablishSilence() async throws {
        let lines: [G.Line] = [
            .init(id: "0", start: 0, end: 1_000, text: "Long simultaneous narration"),
            .init(id: "1", start: 600, end: 610, text: "An interruption"),
            .init(id: "2", start: 720, end: 800, text: "Same conversation")
        ]
        let chapters = try await G.generate(title: "Conversation", language: "en", lines: lines, duration: 39_600) { request in
            .init(summary: "Conversation", chapters: request.stage == .curate ? request.candidates
                : request.lines.map { .init(lineID: $0.id, title: $0.text) })
        }
        #expect(chapters.map(\.startTime) == [0, 600])
    }

    @Test func cancellationStopsBeforeCuration() async {
        let task = Task {
            try await G.generate(title: "Book", language: "en", lines: [.init(id: "0", start: 0, text: "Hello")]) { _ in
                throw CancellationError()
            }
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func failedChunkNeverReturnsPartialChapters() async {
        do {
            _ = try await G.generate(title: "Book", language: "en", lines: [
                .init(id: "0", start: 0, text: "Opening"), .init(id: "1", start: 2000, text: "Next")
            ]) { request in
                if request.lines.contains(where: { $0.id == "1" }) { throw G.Failure.invalidResponse }
                return .init(summary: "Opening", chapters: [.init(lineID: "0", title: "Opening")])
            }
            Issue.record("Expected failure")
        } catch { #expect(error as? G.Failure == .invalidResponse) }
    }

    @Test func syncDeletionWinsAgainstAnOlderDeviceAndMergeIsCommutative() throws {
        let old = SpokenChapterRecord(id: "song", chapters: [.init(startTime: 0, title: "Old")], transcriptFingerprint: "a", providerName: "AI", updatedAt: Date(timeIntervalSince1970: 10), revision: "a")
        var deleted = old; deleted.isDeleted = true; deleted.chapters = []; deleted.updatedAt = Date(timeIntervalSince1970: 20)
        #expect(SpokenChapterRecord.merge([old], [deleted]) == [deleted])
        #expect(SpokenChapterRecord.merge([deleted], [old]) == [deleted])
        #expect(try JSONDecoder().decode(SpokenChapterRecord.self, from: JSONEncoder().encode(deleted)) == deleted)
    }
}
