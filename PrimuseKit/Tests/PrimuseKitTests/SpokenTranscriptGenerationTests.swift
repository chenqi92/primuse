import Foundation
import Testing
@testable import PrimuseKit

@Suite("Transcript generation segments (#314)")
struct SpokenTranscriptSegmentPlanTests {
    @Test("A short episode goes up in one piece")
    func shortEpisode() {
        let plan = SpokenTranscriptSegmentPlan(duration: 420)
        #expect(plan.segments.count == 1)
        #expect(plan.segments[0].audioStart == 0)
        #expect(plan.segments[0].audioEnd == 420)
    }

    @Test("A long episode is cut evenly, every part within the relay's ten minutes")
    func longEpisode() throws {
        let plan = SpokenTranscriptSegmentPlan(duration: 3_725)
        #expect(plan.segments.count == 7)
        for segment in plan.segments {
            #expect(segment.audioDuration <= SpokenTranscriptSegmentPlan.defaultMaximumSegmentSeconds + 0.001)
            #expect(segment.audioDuration <= 600)
        }
        // 相邻两段负责的区间首尾相接,音频两头各多带一点。
        for (previous, next) in zip(plan.segments, plan.segments.dropFirst()) {
            #expect(abs(previous.keepEnd - next.keepStart) < 0.000_1)
            #expect(next.audioStart < previous.audioEnd)
        }
        let first = try #require(plan.segments.first)
        let last = try #require(plan.segments.last)
        #expect(first.audioStart == 0)
        #expect(last.keepEnd == 3_725)
        #expect(last.audioEnd == 3_725)
    }

    @Test("Unknown or broken durations plan nothing")
    func emptyDuration() {
        #expect(SpokenTranscriptSegmentPlan(duration: 0).segments.isEmpty)
        #expect(SpokenTranscriptSegmentPlan(duration: .nan).segments.isEmpty)
    }

    @Test("Stitching moves words onto the episode clock and drops the overlap's repeats")
    func stitching() {
        let plan = SpokenTranscriptSegmentPlan(duration: 1_000, maximumSegmentSeconds: 595, overlap: 2)
        #expect(plan.segments.count == 2)
        let cut = plan.segments[0].keepEnd
        let secondStart = plan.segments[1].audioStart
        // 第一段末尾在切口前开始的词它负责;切口后开始的同一个词由第二段负责。
        let first = AIAudioTranscriptionResult(transcript: "a b", words: [
            AIAudioTranscriptionWord(text: "hello", startTime: 10, endTime: 10.5),
            AIAudioTranscriptionWord(text: "before", startTime: cut - 0.5, endTime: cut + 0.2),
            AIAudioTranscriptionWord(text: "after", startTime: cut + 0.5, endTime: cut + 1),
        ])
        let second = AIAudioTranscriptionResult(transcript: "c", words: [
            AIAudioTranscriptionWord(text: "before", startTime: cut - 0.5 - secondStart, endTime: cut + 0.2 - secondStart),
            AIAudioTranscriptionWord(text: "after", startTime: cut + 0.5 - secondStart, endTime: cut + 1 - secondStart),
            AIAudioTranscriptionWord(text: "end", startTime: 990 - secondStart, endTime: 991 - secondStart),
        ])
        let stitched = plan.stitch([0: first, 1: second])
        #expect(stitched.words.map(\.text) == ["hello", "before", "after", "end"])
        #expect(abs(stitched.words[2].startTime - (cut + 0.5)) < 0.000_1)
        #expect(abs(stitched.words[3].startTime - 990) < 0.000_1)
    }

    @Test("A part without timed words keeps its text")
    func untimedPart() {
        let plan = SpokenTranscriptSegmentPlan(duration: 300)
        let stitched = plan.stitch([0: AIAudioTranscriptionResult(transcript: "  just text  ", words: [])])
        #expect(stitched.words.isEmpty)
        #expect(stitched.transcript == "just text")
    }
}

@Suite("Transcript language and allowance (#314)")
struct SpokenTranscriptLanguagePolicyTests {
    @Test("Feed language, title script and device languages, in that order")
    func candidates() {
        #expect(SpokenTranscriptLanguagePolicy.candidates(
            declaredLanguage: "en-us",
            title: "Daily News",
            preferredLanguages: ["zh-Hans-CN", "en-US"]
        ) == ["en-US", "zh-Hans-CN"])
        #expect(SpokenTranscriptLanguagePolicy.candidates(
            declaredLanguage: nil,
            title: "三言二拍之吴衙内邻舟赴约",
            preferredLanguages: ["en-GB"]
        ) == ["zh-CN", "en-GB"])
        #expect(SpokenTranscriptLanguagePolicy.scriptHint(for: "ハイキュー!! ラジオ") == "ja-JP")
        #expect(SpokenTranscriptLanguagePolicy.scriptHint(for: "오늘의 뉴스") == "ko-KR")
        #expect(SpokenTranscriptLanguagePolicy.scriptHint(for: "The Daily") == nil)
    }

    @Test("Language tags from feeds are tidied")
    func normalization() {
        #expect(SpokenTranscriptLanguagePolicy.normalized("zh_hans_cn") == "zh-Hans-CN")
        #expect(SpokenTranscriptLanguagePolicy.normalized(" EN ") == "en")
        #expect(SpokenTranscriptLanguagePolicy.normalized("not a language") == nil)
    }

    @Test("Remaining parts are the smaller of today's and this period's")
    func remaining() {
        #expect(SpokenTranscriptBuiltInAllowance(segmentsToday: 1, dailyLimit: 3, segmentsThisPeriod: 10, periodLimit: 12)
            .remainingSegments == 2)
        #expect(SpokenTranscriptBuiltInAllowance(segmentsToday: 0, dailyLimit: 18, segmentsThisPeriod: 119, periodLimit: 120)
            .remainingSegments == 1)
        #expect(SpokenTranscriptBuiltInAllowance().remainingSegments == nil)
        #expect(SpokenTranscriptBuiltInAllowance(segmentsToday: 5, dailyLimit: 3).remainingSegments == 0)
    }
}

@Suite("Transcript layout of Alibaba Cloud results (#314)")
struct AliyunTranscriptLayoutTests {
    @Test("Chinese words join without spaces, English words with spaces, and a sentence ends its line")
    func layout() throws {
        let body = Data("""
        {"transcripts":[{"channel_id":0,"sentences":[
          {"begin_time":100,"end_time":1500,"text":"Hello world.","words":[
            {"begin_time":100,"end_time":600,"text":"Hello ","punctuation":""},
            {"begin_time":650,"end_time":1500,"text":"world","punctuation":"."}]},
          {"begin_time":2000,"end_time":4100,"text":"今天我们聊聊播客。","words":[
            {"begin_time":2000,"end_time":2600,"text":"今天","punctuation":""},
            {"begin_time":2600,"end_time":3000,"text":"我们","punctuation":""},
            {"begin_time":3000,"end_time":3500,"text":"聊聊","punctuation":""},
            {"begin_time":3500,"end_time":4100,"text":"播客","punctuation":"。"}]}
        ]}]}
        """.utf8)
        let lines = SpokenTranscriptLayout.lines(from: try AliyunFunASR.decodeTranscription(body))
        #expect(lines.map(\.text) == ["Hello world.", "今天我们聊聊播客。"])
        #expect(abs((lines.first?.timestamp ?? -1) - 0.1) < 0.000_1)
        #expect(abs((lines.last?.timestamp ?? -1) - 2.0) < 0.000_1)
    }

    @Test("Alibaba Cloud uploads the whole file; only the relay and Google go in parts")
    func segmentedEngines() {
        #expect(SpokenTranscriptEngine.aliyun.uploadsAudio)
        #expect(!SpokenTranscriptEngine.aliyun.uploadsInSegments)
        #expect(SpokenTranscriptEngine.builtIn.uploadsInSegments)
        #expect(SpokenTranscriptEngine.ownKey.uploadsInSegments)
        #expect(!SpokenTranscriptEngine.onDevice.uploadsInSegments)
    }
}
