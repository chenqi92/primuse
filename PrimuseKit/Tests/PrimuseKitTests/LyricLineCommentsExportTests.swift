import Foundation
import Testing
@testable import PrimuseKit

@MainActor
struct LyricLineCommentsExportTests {
    @Test func exportsEverySavedLineIncludingRepeatedVoicesAndReplacedLyrics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricLineCommentStore(directory: directory)
        for (time, voice, occurrence, note) in [
            (40.125, LyricVoice.primary, 1, "第二次听见纸船"),
            (10.0, .secondary, 0, "另一位的回应"),
            (10.0, .primary, 0, "最初的声音"),
        ] {
            try store.save(songID: "song", anchor: .init(text: "纸船经过小桥", occurrence: occurrence,
                           voice: voice, timestamp: time), text: note)
        }
        try store.save(songID: "song", anchor: .init(text: "旧版本里的晚风", occurrence: 0, timestamp: 3), text: "仍然保留")
        let restored = LyricLineCommentStore(directory: directory)
        let markdown = LyricLineCommentsExport.markdown(title: "窗边的光", artist: "河岸乐队",
            comments: try restored.comments(songID: "song"), voiceNames: [.primary: "主唱", .secondary: "对唱"])
        #expect(markdown.hasPrefix("# 窗边的光\n\n河岸乐队\n"))
        #expect(markdown.contains("## 00:03.000"))
        #expect(markdown.contains("## 00:40.125 · 主唱"))
        #expect(markdown.contains("## 00:10.000 · 对唱"))
        for note in ["第二次听见纸船", "另一位的回应", "最初的声音", "旧版本里的晚风", "仍然保留"] {
            #expect(markdown.contains(note))
        }
        #expect(markdown.components(separatedBy: "> 纸船经过小桥").count == 4)
    }

    @Test func preservesUnicodeAndMultilineTextWithoutTurningNotesIntoMarkdownCommands() {
        let comment = LyricLineComment(anchor: .init(text: "纸船 [晨光]\n<桥边>", occurrence: 0, timestamp: 59.9996),
            text: "# 感想\n[不是链接](https://example.com)\n\n轻声 *回应* 🎵", updatedAt: Date())
        let markdown = LyricLineCommentsExport.markdown(title: "*夜色*", comments: [comment])
        #expect(markdown.contains("# \\*夜色\\*"))
        #expect(markdown.contains("## 01:00.000"))
        #expect(markdown.contains("> 纸船 \\[晨光\\]  \n> \\<桥边\\>"))
        #expect(markdown.contains("\\# 感想"))
        #expect(markdown.contains("轻声 \\*回应\\* 🎵"))
        #expect(String(data: Data(markdown.utf8), encoding: .utf8) == markdown)
    }

    @Test func fileNamesCannotEscapeTheSaveDirectory() {
        let name = LyricLineCommentsExport.fileName(title: "../../夜色:桥边/\n纸船")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("\n"))
        #expect(!name.hasPrefix("."))
        #expect(name.hasSuffix(".md"))
        #expect(LyricLineCommentsExport.fileName(title: "... /\n") == "Lyrics.md")
    }

    @Test func deletedNotesStayOutOfExportsAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricLineCommentStore(directory: directory)
        let removed = LyricLineCommentAnchor(text: "旧桥下的回声", occurrence: 0, timestamp: 5)
        let kept = LyricLineCommentAnchor(text: "纸船走向晨光", occurrence: 0, timestamp: 15)
        try store.save(songID: "song", anchor: removed, text: "已放下的心事")
        try store.save(songID: "song", anchor: kept, text: "仍要记住的日子")
        try store.save(songID: "song", anchor: removed, text: "")
        let restored = LyricLineCommentStore(directory: directory)
        let markdown = LyricLineCommentsExport.markdown(title: "河岸", comments: try restored.comments(songID: "song"))
        #expect(!markdown.contains("旧桥下的回声"))
        #expect(!markdown.contains("已放下的心事"))
        #expect(markdown.contains("仍要记住的日子"))
    }
}
