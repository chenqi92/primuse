import Foundation
import Testing
@testable import PrimuseKit

@Suite("Feiniu lyric candidate selection")
struct FnMusicLyricSelectionTests {
    private let synced = "[00:01.00]第一行\n[00:05.50]第二行"
    private let plain = "没有时间轴的歌词\n第二段"

    @Test func preferredCandidateWinsWhenItParses() {
        let payload: [String: Any] = [
            "preferred": "manual",
            "list": [
                ["guid": "embedded", "content": synced, "source": 1, "updatedAt": 10],
                ["guid": "manual", "content": "[00:02.00]手动版", "source": 4, "updatedAt": 5],
            ],
        ]
        let document = FnMusicLyricSelection.select(payload: payload)
        #expect(document?.guid == "manual")
        #expect(document?.text == "[00:02.00]手动版")
    }

    @Test func stalePreferredFallsBackToTheBestRemainingCandidate() {
        let payload: [String: Any] = [
            "preferred": "deleted",
            "list": [
                ["guid": "manual", "content": "[00:02.00]手动版", "source": 4, "updatedAt": 99],
                ["guid": "embedded", "content": synced, "source": 1, "updatedAt": 1],
            ],
        ]
        #expect(FnMusicLyricSelection.select(payload: payload)?.guid == "embedded")
    }

    @Test func emptyPreferredContentIsSkippedInsteadOfShowingNothing() {
        let payload: [String: Any] = [
            "preferred": "blank",
            "list": [
                ["guid": "blank", "content": "   ", "source": 1],
                ["guid": "lrc", "content": synced, "source": 2],
            ],
        ]
        #expect(FnMusicLyricSelection.select(payload: payload)?.guid == "lrc")
    }

    @Test func preferredWithTimestampsButNoLinesIsTreatedAsBroken() {
        let payload: [String: Any] = [
            "preferred": "broken",
            "list": [
                ["guid": "broken", "content": "[00:01.00]\n[00:02.00]", "source": 1],
                ["guid": "lrc", "content": synced, "source": 2],
            ],
        ]
        #expect(FnMusicLyricSelection.select(payload: payload)?.guid == "lrc")
    }

    @Test func sourcePriorityThenRecencyOrdersCandidates() {
        let payload: [String: Any] = [
            "list": [
                ["guid": "unknown-new", "content": synced, "source": 9, "updatedAt": 500],
                ["guid": "manual-old", "content": synced, "source": 4, "updatedAt": 1, "createdAt": 1],
                ["guid": "manual-new", "content": synced, "source": 4, "updatedAt": 1, "createdAt": 2],
                ["guid": "lrc", "content": synced, "source": 2],
            ],
        ]
        #expect(FnMusicLyricSelection.select(payload: payload)?.guid == "lrc")
        let manualOnly: [String: Any] = [
            "list": [
                ["guid": "manual-old", "content": synced, "source": 4, "updatedAt": 1, "createdAt": 1],
                ["guid": "manual-new", "content": synced, "source": 4, "updatedAt": 1, "createdAt": 2],
            ],
        ]
        #expect(FnMusicLyricSelection.select(payload: manualOnly)?.guid == "manual-new")
    }

    @Test func syncedLyricsBeatPlainTextEvenFromALowerPrioritySource() {
        let payload: [String: Any] = [
            "list": [
                ["guid": "plain-embedded", "content": plain, "source": 1],
                ["guid": "synced-manual", "content": synced, "source": 4],
            ],
        ]
        #expect(FnMusicLyricSelection.select(payload: payload)?.guid == "synced-manual")
    }

    @Test func plainTextIsTheLastResort() {
        let payload: [String: Any] = [
            "list": [
                ["guid": "broken", "content": "[00:01.00]", "source": 1],
                ["guid": "plain", "content": plain, "source": 9],
            ],
        ]
        let document = FnMusicLyricSelection.select(payload: payload)
        #expect(document?.guid == "plain")
        #expect(document?.text == plain)
    }

    @Test func allCandidatesInvalidYieldsNothing() {
        let payload: [String: Any] = [
            "preferred": "x",
            "list": [
                ["guid": "x", "content": "[00:01.00]"],
                ["guid": "y", "content": ""],
                ["guid": "z", "text": "\n\n"],
            ],
        ]
        #expect(FnMusicLyricSelection.select(payload: payload) == nil)
        #expect(FnMusicLyricSelection.select(payload: ["list": NSNull(), "preferred": ""]) == nil)
        #expect(FnMusicLyricSelection.select(payload: [String: Any]()) == nil)
        #expect(FnMusicLyricSelection.select(payload: nil) == nil)
    }

    @Test func legacyShapesStillParse() {
        let bare: [[String: Any]] = [["id": "legacy", "text": synced]]
        let document = FnMusicLyricSelection.select(payload: bare)
        #expect(document?.guid == "legacy")
        #expect(document?.text == synced)
    }

    @Test func serverOffsetBecomesAnOffsetTag() {
        func text(offset: Any?) -> String? {
            var item: [String: Any] = ["guid": "g", "content": synced, "source": 1]
            if let offset { item["offset"] = offset }
            return FnMusicLyricSelection.select(payload: ["list": [item]])?.text
        }
        #expect(text(offset: nil) == synced)
        #expect(text(offset: 0) == synced)
        #expect(text(offset: 350) == "[offset:350]\n" + synced)
        #expect(text(offset: -1200) == "[offset:-1200]\n" + synced)
        #expect(text(offset: 249.6) == "[offset:250]\n" + synced)
        #expect(text(offset: "350") == synced, "网页端不接受字符串偏移，这里也不猜")
        #expect(text(offset: true) == synced)
    }

    @Test func embeddedOffsetTagIsMergedNotStacked() {
        let content = "[ti:歌名]\n[offset:+200]\n" + synced
        let item: [String: Any] = ["guid": "g", "content": content, "source": 2, "offset": 500]
        let document = FnMusicLyricSelection.select(payload: ["list": [item]])
        // 飞牛把自带标签加到时间戳上（推后 0.2 秒）再提前 0.5 秒，净提前 0.3 秒。
        #expect(document?.text == "[offset:300]\n[ti:歌名]\n" + synced)
        let untouched: [String: Any] = ["guid": "g", "content": content, "source": 2]
        #expect(FnMusicLyricSelection.select(payload: ["list": [untouched]])?.text == content)
    }

    @Test func windowsLineEndingsAndFullWidthTimestampsAreRecognised() {
        let crlf = "[00:01.00]第一行\r\n[00:05.50]第二行"
        let item: [String: Any] = ["guid": "g", "content": crlf, "offset": 100]
        #expect(FnMusicLyricSelection.select(payload: ["list": [item]])?.text == "[offset:100]\n[00:01.00]第一行\n[00:05.50]第二行")
        #expect(FnMusicLyricSelection.hasTimestamps("［00:01.00］全角"))
        #expect(FnMusicLyricSelection.syncedLineCount("［00:01.00］全角\n[00:02.00][00:03.00]两个戳\n[00:04.00]") == 2)
    }

    @Test func numericSourceOneIsEmbeddedNotABoolean() {
        let (candidates, _) = FnMusicLyricSelection.candidates(in: ["list": [
            ["guid": "a", "content": synced, "source": 1, "offset": 1, "updatedAt": 1],
            ["guid": "b", "content": synced, "source": true],
        ]])
        #expect(candidates.map(\.source) == [.embedded, .unknown])
        #expect(candidates.first?.offsetMilliseconds == 1)
        #expect(candidates.first?.updatedAt == 1)
    }
}
