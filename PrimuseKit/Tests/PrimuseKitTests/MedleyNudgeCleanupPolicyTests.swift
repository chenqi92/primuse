import Foundation
import Testing
@testable import PrimuseKit

@Suite("Medley segments")
struct MedleySegmentPolicyTests {
    @Test("The default plays a ten-second slice", arguments: [0.0, 240.0])
    func defaultSlice(duration: TimeInterval) {
        let segment = MedleySegmentPolicy.segment(
            duration: duration, segmentLength: MedleySegmentPolicy.defaultSegmentLength
        )
        #expect(segment?.length == 10)
    }

    @Test("A typical song is cut around its first chorus")
    func typicalSong() {
        let segment = MedleySegmentPolicy.segment(duration: 240, segmentLength: 45)
        #expect(segment?.start == 79)
        #expect(segment?.length == 45)
    }

    @Test("A section boundary near the target is preferred")
    func sectionBoundary() {
        let segment = MedleySegmentPolicy.segment(
            duration: 240, segmentLength: 45, sectionStarts: [0, 12, 62, 150]
        )
        #expect(segment?.start == 62)
    }

    @Test("Boundaries in the intro or too close to the end are ignored")
    func boundariesOutOfRange() {
        let segment = MedleySegmentPolicy.segment(
            duration: 240, segmentLength: 45, sectionStarts: [2, 230]
        )
        #expect(segment?.start == 79)
    }

    @Test("A short song is played whole")
    func shortSong() {
        let segment = MedleySegmentPolicy.segment(duration: 60, segmentLength: 45)
        #expect(segment == MedleySegment(start: 0, end: 60))
    }

    @Test("An unknown length plays the opening slice")
    func unknownLength() {
        #expect(MedleySegmentPolicy.segment(duration: 0, segmentLength: 30)
            == MedleySegment(start: 0, end: 30))
        #expect(MedleySegmentPolicy.segment(duration: .nan, segmentLength: 30) == nil)
    }

    @Test("The slice never runs into the outro")
    func respectsEndMargin() {
        let segment = MedleySegmentPolicy.segment(duration: 80, segmentLength: 45)
        // 80 > 45 + 20, latest start = 80 - 45 - 8 = 27
        #expect(segment?.start == 26)
        #expect((segment?.end ?? 0) <= 80 - 8)
    }

    @Test("Lengths snap to the offered choices")
    func snapping() {
        #expect(MedleySegmentPolicy.clampedSegmentLength(44) == 45)
        #expect(MedleySegmentPolicy.clampedSegmentLength(1) == 10)
        #expect(MedleySegmentPolicy.clampedSegmentLength(1000) == 90)
    }

    @Test("Overlap is a short blend, never a quarter of the slice or more")
    func overlap() {
        #expect(MedleySegmentPolicy.overlap(segmentLength: 45) == 4)
        #expect(MedleySegmentPolicy.overlap(segmentLength: 8) == 2)
        #expect(MedleySegmentPolicy.overlap(segmentLength: 2) == 1)
        #expect(MedleySegmentPolicy.overlap(segmentLength: 0) == 0)
    }
}

@Suite("Smart nudges")
struct SmartNudgePolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A song played a lot this week and not liked suggests favourites")
    func favourites() {
        let context = SmartNudgeContext(songID: "s", playsInLastWeek: 5, progress: 0.6)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .addToFavorites)
    }

    @Test("Not before the listener has heard half of it")
    func favouritesWaitsForProgress() {
        let context = SmartNudgeContext(songID: "s", playsInLastWeek: 9, progress: 0.2)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == nil)
    }

    @Test("Three plays in a row also counts")
    func repeatsCount() {
        let context = SmartNudgeContext(songID: "s", playsInLastWeek: 3, consecutivePlays: 3, progress: 0.9)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .addToFavorites)
    }

    @Test("A liked song on repeat suggests similar songs")
    func similar() {
        let context = SmartNudgeContext(songID: "s", isLiked: true, playsInLastWeek: 3, consecutivePlays: 2, progress: 0.7)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .playSimilar)
    }

    @Test("A liked song skipped often suggests removing it from favourites")
    func skippedFavourite() {
        let context = SmartNudgeContext(songID: "s", isLiked: true, recentEarlySkips: 3, progress: 0.02)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .removeFromFavorites)
    }

    @Test("The end of the queue comes before song-level suggestions")
    func queueEnding() {
        let context = SmartNudgeContext(songID: "s", playsInLastWeek: 9, progress: 0.6, isLastInQueue: true)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .continueWithRecommendations)
    }

    @Test("A repeating queue never runs out")
    func repeatingQueue() {
        let context = SmartNudgeContext(songID: "s", progress: 0.6, isLastInQueue: true, repeatsQueue: true)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == nil)
    }

    @Test("Late at night after a long session, a sleep timer is offered")
    func sleepTimer() {
        let context = SmartNudgeContext(songID: "s", continuousListeningMinutes: 50, hour: 0)
        #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == .sleepTimer)
        var withTimer = context
        withTimer.sleepTimerActive = true
        #expect(SmartNudgePolicy.nudge(for: withTimer, history: .init(), now: now) == nil)
        var afternoon = context
        afternoon.hour = 15
        #expect(SmartNudgePolicy.nudge(for: afternoon, history: .init(), now: now) == nil)
    }

    @Test("Medleys, radio and spoken word do not get song prompts")
    func excludedContexts() {
        let base = SmartNudgeContext(songID: "s", playsInLastWeek: 9, progress: 0.6)
        var medley = base; medley.isMedley = true
        var radio = base; radio.isLiveRadio = true
        var spoken = base; spoken.isSpokenWord = true
        for context in [medley, radio, spoken] {
            #expect(SmartNudgePolicy.nudge(for: context, history: .init(), now: now) == nil)
        }
    }

    @Test("Prompts are at least ten minutes apart")
    func minimumInterval() {
        let context = SmartNudgeContext(songID: "s", playsInLastWeek: 9, progress: 0.6)
        let recent = SmartNudgeHistory(lastShownAt: now.addingTimeInterval(-60))
        #expect(SmartNudgePolicy.nudge(for: context, history: recent, now: now) == nil)
        let older = SmartNudgeHistory(lastShownAt: now.addingTimeInterval(-11 * 60))
        #expect(SmartNudgePolicy.nudge(for: context, history: older, now: now) == .addToFavorites)
    }

    @Test("An answered prompt about a song waits a month, other songs do not")
    func songCooldown() {
        let context = SmartNudgeContext(songID: "s", playsInLastWeek: 9, progress: 0.6)
        let history = SmartNudgePolicy.recordingAnswer(
            .init(), kind: .addToFavorites, songID: "s", accepted: false, at: now.addingTimeInterval(-3600)
        )
        #expect(SmartNudgePolicy.nudge(for: context, history: history, now: now) == nil)
        var other = context; other.songID = "t"
        #expect(SmartNudgePolicy.nudge(for: other, history: history, now: now) == .addToFavorites)
    }

    @Test("Three dismissals in a row snooze the kind for two weeks")
    func snooze() {
        var history = SmartNudgeHistory()
        for (index, id) in ["a", "b", "c"].enumerated() {
            history = SmartNudgePolicy.recordingAnswer(
                history, kind: .addToFavorites, songID: id, accepted: false,
                at: now.addingTimeInterval(TimeInterval(-3600 * (3 - index)))
            )
        }
        let context = SmartNudgeContext(songID: "d", playsInLastWeek: 9, progress: 0.6)
        #expect(SmartNudgePolicy.nudge(for: context, history: history, now: now) == nil)
        let later = now.addingTimeInterval(SmartNudgePolicy.snoozeDuration + 1)
        #expect(SmartNudgePolicy.nudge(for: context, history: history, now: later) == .addToFavorites)
    }

    @Test("Acceptance resets the dismissal streak")
    func acceptanceResets() {
        var history = SmartNudgePolicy.recordingAnswer(.init(), kind: .playSimilar, songID: "a", accepted: false, at: now)
        history = SmartNudgePolicy.recordingAnswer(history, kind: .playSimilar, songID: "b", accepted: false, at: now)
        history = SmartNudgePolicy.recordingAnswer(history, kind: .playSimilar, songID: "c", accepted: true, at: now)
        #expect(history.consecutiveDismissals["playSimilar"] == 0)
        #expect(history.snoozedUntil["playSimilar"] == nil)
    }

    @Test("A disabled kind is never offered")
    func disabledKind() {
        let context = SmartNudgeContext(songID: "s", playsInLastWeek: 9, progress: 0.6)
        #expect(SmartNudgePolicy.nudge(
            for: context, history: .init(), enabledKinds: [.sleepTimer], now: now
        ) == nil)
    }

    @Test("Early skips are counted within thirty days")
    func skips() {
        #expect(SmartNudgeSkipPolicy.isEarlySkip(listened: 5, duration: 200))
        #expect(!SmartNudgeSkipPolicy.isEarlySkip(listened: 45, duration: 200))
        #expect(!SmartNudgeSkipPolicy.isEarlySkip(listened: 20, duration: 22))
        var skips: [String: [Date]] = [:]
        skips = SmartNudgeSkipPolicy.recording(skipOf: "s", at: now.addingTimeInterval(-40 * 86_400), into: skips)
        skips = SmartNudgeSkipPolicy.recording(skipOf: "s", at: now.addingTimeInterval(-86_400), into: skips)
        skips = SmartNudgeSkipPolicy.recording(skipOf: "s", at: now, into: skips)
        #expect(SmartNudgeSkipPolicy.recentCount(of: "s", in: skips, now: now) == 2)
    }
}

@Suite("Tag cleanup")
struct TagCleanupPolicyTests {
    private func proposals(_ songs: [TagCleanupSong]) -> [TagCleanupProposal] {
        TagCleanupPolicy.proposals(for: songs, currentYear: 2026)
    }

    @Test("Advertisement brackets are removed")
    func advertisements() {
        let result = proposals([TagCleanupSong(id: "1", title: "晴天【www.music123.com】", artist: "周杰伦")])
        #expect(result.contains { $0.field == .title && $0.newValue == "晴天" && $0.reason == .advertisement })
    }

    @Test("Ordinary brackets survive")
    func ordinaryBrackets() {
        let result = proposals([TagCleanupSong(id: "1", title: "Song (Live)", artist: "A")])
        #expect(result.isEmpty)
    }

    @Test("Whitespace is collapsed")
    func whitespace() {
        let result = proposals([TagCleanupSong(id: "1", title: "  Hello   World ", artist: "A")])
        #expect(result == [TagCleanupProposal(songID: "1", field: .title, oldValue: "  Hello   World ",
                                              newValue: "Hello World", reason: .whitespace)])
    }

    @Test("Placeholder artists and albums are cleared")
    func placeholders() {
        let result = proposals([TagCleanupSong(id: "1", title: "T", artist: "Unknown Artist", album: "未知专辑")])
        #expect(result.contains { $0.field == .artist && $0.newValue == nil })
        #expect(result.contains { $0.field == .album && $0.newValue == nil })
    }

    @Test("A track prefix moves into the track number")
    func trackPrefix() {
        let result = proposals([TagCleanupSong(id: "1", title: "03. Yesterday", artist: "B")])
        #expect(result.contains { $0.field == .title && $0.newValue == "Yesterday" })
        #expect(result.contains { $0.field == .trackNumber && $0.newValue == "3" })
    }

    @Test("A number that is the whole title is kept")
    func numericTitle() {
        #expect(proposals([TagCleanupSong(id: "1", title: "1999", artist: "Prince")]).isEmpty)
        #expect(proposals([TagCleanupSong(id: "1", title: "7 Rings", artist: "A", trackNumber: 1)]).isEmpty)
    }

    @Test("Artist - Title is split when the artist is missing")
    func artistInTitle() {
        let result = proposals([TagCleanupSong(id: "1", title: "Adele - Hello")])
        #expect(result.contains { $0.field == .title && $0.newValue == "Hello" })
        #expect(result.contains { $0.field == .artist && $0.newValue == "Adele" })
    }

    @Test("A hyphen inside a name is not a separator, and a different artist blocks the split")
    func hyphenSafe() {
        #expect(proposals([TagCleanupSong(id: "1", title: "Jay-Z Anthem", artist: "X")]).isEmpty)
        #expect(proposals([TagCleanupSong(id: "1", title: "Intro - Reprise", artist: "Band")]).isEmpty)
    }

    @Test("Album spellings that differ only by case unify to the common one")
    func unify() {
        let result = proposals([
            TagCleanupSong(id: "1", title: "a", artist: "X", album: "Abbey Road"),
            TagCleanupSong(id: "2", title: "b", artist: "X", album: "Abbey Road"),
            TagCleanupSong(id: "3", title: "c", artist: "X", album: "abbey road"),
        ])
        #expect(result == [TagCleanupProposal(songID: "3", field: .album, oldValue: "abbey road",
                                              newValue: "Abbey Road", reason: .unifiedSpelling)])
    }

    @Test("Different albums are never unified")
    func differentAlbums() {
        let result = proposals([
            TagCleanupSong(id: "1", title: "a", artist: "X", album: "Help!"),
            TagCleanupSong(id: "2", title: "b", artist: "X", album: "Help"),
        ])
        #expect(result.isEmpty)
    }

    @Test("Impossible years are cleared")
    func years() {
        let result = proposals([TagCleanupSong(id: "1", title: "a", artist: "X", year: 20_150)])
        #expect(result == [TagCleanupProposal(songID: "1", field: .year, oldValue: "20150",
                                              newValue: nil, reason: .invalidYear)])
    }

    @Test("A missing track number comes from the file name")
    func trackFromFile() {
        let result = proposals([TagCleanupSong(id: "1", title: "Song", artist: "X", fileName: "Album/07 - Song.flac")])
        #expect(result == [TagCleanupProposal(songID: "1", field: .trackNumber, oldValue: nil,
                                              newValue: "7", reason: .trackFromFileName)])
    }

    @Test("A title that repeats the artist is recovered from the file name")
    func titleFromFileName() {
        let result = proposals([TagCleanupSong(
            id: "1", title: "王菲 (1)", artist: "王菲 (1)", album: "只爱陌生人",
            fileName: "/Music/百年孤寂 - 王菲.mp3"
        )])
        #expect(Set(result) == [
            TagCleanupProposal(songID: "1", field: .title, oldValue: "王菲 (1)",
                               newValue: "百年孤寂", reason: .titleFromFileName),
            TagCleanupProposal(songID: "1", field: .artist, oldValue: "王菲 (1)",
                               newValue: "王菲", reason: .copyCounter),
        ])
    }

    @Test("Without file name evidence a repeated title is only flagged")
    func repeatedTitleWithoutEvidence() {
        let song = TagCleanupSong(id: "1", title: "王菲", artist: "王菲", fileName: "track.mp3")
        #expect(proposals([song]).isEmpty)
        #expect(TagCleanupPolicy.needsAttention(song))
        #expect(!TagCleanupPolicy.needsAttention(
            TagCleanupSong(id: "2", title: "红豆", artist: "王菲", fileName: "红豆.mp3")
        ))
    }

    @Test("A copy counter on the title goes when the file name has the bare title")
    func titleCopyCounter() {
        let result = proposals([TagCleanupSong(
            id: "1", title: "红豆 (1)", artist: "王菲", fileName: "王菲 - 红豆.flac"
        )])
        #expect(result == [TagCleanupProposal(songID: "1", field: .title, oldValue: "红豆 (1)",
                                              newValue: "红豆", reason: .copyCounter)])
        #expect(proposals([TagCleanupSong(
            id: "2", title: "红豆 (1)", artist: "王菲", fileName: "红豆 (1).flac"
        )]).isEmpty)
    }

    @Test("An artist copy joins the plain spelling in the same selection, albums do not")
    func artistCopyCounterAcrossSelection() {
        let result = proposals([
            TagCleanupSong(id: "1", title: "红豆", artist: "王菲", album: "Hits"),
            TagCleanupSong(id: "2", title: "流年", artist: "王菲 (1)", album: "Hits (2)"),
        ])
        #expect(result == [TagCleanupProposal(songID: "2", field: .artist, oldValue: "王菲 (1)",
                                              newValue: "王菲", reason: .copyCounter)])
        #expect(proposals([
            TagCleanupSong(id: "1", title: "Song", artist: "Band (1994)"),
            TagCleanupSong(id: "2", title: "Song 2", artist: "Band"),
        ]).isEmpty)
    }

    @Test("Applying only the switched-on proposals")
    func applying() {
        let song = TagCleanupSong(id: "1", title: "03. Yesterday", artist: "B")
        let kept = proposals([song]).filter { $0.field == .title }
        let applied = TagCleanupPolicy.applying(kept, to: song)
        #expect(applied.title == "Yesterday")
        #expect(applied.trackNumber == nil)
    }

    @Test("Merging keeps the first source for a field and drops no-ops")
    func merging() {
        let local = [TagCleanupProposal(songID: "1", field: .title, oldValue: "a ", newValue: "a", reason: .whitespace)]
        let remote = [
            TagCleanupProposal(songID: "1", field: .title, oldValue: "a ", newValue: "A", reason: .assistant),
            TagCleanupProposal(songID: "1", field: .genre, oldValue: "pop", newValue: "Pop", reason: .assistant),
            TagCleanupProposal(songID: "1", field: .year, oldValue: "1999", newValue: "1999", reason: .assistant),
        ]
        let merged = TagCleanupPolicy.merging(local, remote)
        #expect(merged.map(\.id) == ["1|title", "1|genre"])
        #expect(merged[0].newValue == "a")
    }
}

@Suite("Tag cleanup AI exchange")
struct TagCleanupAIExchangeTests {
    private let songs = [
        TagCleanupSong(id: "id-a", title: "hello world", artist: "adele", album: "25", year: 2015, trackNumber: 1, fileName: "01 Hello.flac"),
        TagCleanupSong(id: "id-b", title: "When We Were Young", artist: "Adele", album: "25"),
    ]

    @Test("The payload uses tokens, not song ids")
    func payloadTokens() throws {
        let built = try #require(TagCleanupAIExchange.payload(for: songs, languageCode: "zh"))
        #expect(!built.json.contains("id-a"))
        #expect(built.json.contains("\"s0\""))
        #expect(built.songsByToken["s1"]?.id == "id-b")
    }

    @Test("Answers become proposals against the original values")
    func decode() throws {
        let built = try #require(TagCleanupAIExchange.payload(for: songs, languageCode: "zh"))
        let output = """
        Sure! {"changes":[
          {"id":"s0","field":"title","value":"Hello World","reason":"大小写"},
          {"id":"s0","field":"artist","value":"Adele","reason":"与列表统一"},
          {"id":"s1","field":"album","value":"25","reason":"no-op"},
          {"id":"s9","field":"title","value":"x"},
          {"id":"s1","field":"mood","value":"sad"},
          {"id":"s0","field":"year","value":"99999"},
          {"id":"s0","field":"track","value":3},
          {"id":"s1","field":"title","value":null},
          {"id":"s1","field":"genre","value":"Pop"}
        ]}
        """
        let proposals = try TagCleanupAIExchange.proposals(
            from: output, songsByToken: built.songsByToken, currentYear: 2026
        )
        #expect(proposals.map(\.id) == ["id-a|title", "id-a|artist", "id-a|trackNumber", "id-b|genre"])
        #expect(proposals[0].oldValue == "hello world")
        #expect(proposals[0].note == "大小写")
        #expect(proposals[2].newValue == "3")
        #expect(proposals.allSatisfy { $0.reason == .assistant })
    }

    @Test("A reply that is not the expected JSON is an error")
    func malformed() throws {
        let built = try #require(TagCleanupAIExchange.payload(for: songs, languageCode: "en"))
        #expect(throws: TagCleanupAIExchangeError.malformedResponse) {
            try TagCleanupAIExchange.proposals(from: "I cannot help", songsByToken: built.songsByToken, currentYear: 2026)
        }
    }

    @Test("Clearing a placeholder is allowed")
    func clearing() throws {
        let placeholder = [TagCleanupSong(id: "p", title: "T", artist: "Unknown Artist")]
        let built = try #require(TagCleanupAIExchange.payload(for: placeholder, languageCode: "en"))
        let proposals = try TagCleanupAIExchange.proposals(
            from: #"{"changes":[{"id":"s0","field":"artist","value":null}]}"#,
            songsByToken: built.songsByToken, currentYear: 2026
        )
        #expect(proposals.first?.newValue == nil)
        #expect(proposals.first?.oldValue == "Unknown Artist")
    }
}
