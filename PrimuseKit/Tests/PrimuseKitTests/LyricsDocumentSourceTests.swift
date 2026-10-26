import Foundation
import Testing
@testable import PrimuseKit

/// 歌词来源记号(#357):记在第一行上、随缓存存取,旧缓存与认不出的来源都读成「没记」。
struct LyricsDocumentSourceTests {
    @Test func fileSourceKeepsOnlyTheLowercasedExtension() {
        #expect(LyricsDocumentSource.file("Song.TTML").identifier == "ttml")
        #expect(LyricsDocumentSource.file("/Music/Album/01 Song.lrc").identifier == "lrc")
        #expect(LyricsDocumentSource.file("Song.zh-Hans.lrc").identifier == "lrc")
        #expect(LyricsDocumentSource.file("README").identifier == nil)
        #expect(LyricsDocumentSource.file(".lrc").identifier == nil)
        #expect(LyricsDocumentSource.file(nil).identifier == nil)
    }

    @Test func stampingMarksOnlyTheFirstLine() {
        let lines = [
            LyricLine(timestamp: 1, text: "one"),
            LyricLine(timestamp: 2, text: "two"),
        ]
        let stamped = LyricsDocumentSource.embedded.stamped(lines)
        #expect(stamped[0].documentSource == .embedded)
        #expect(stamped[1].documentSource == nil)
        #expect(stamped.map(\.text) == lines.map(\.text))
        #expect(LyricsDocumentSource.embedded.stamped([]).isEmpty)
    }

    @Test func stampingDoesNotChangeTheDocumentFingerprint() {
        let lines = [
            LyricLine(timestamp: 1, text: "one"),
            LyricLine(timestamp: 2, text: "two"),
        ]
        let stamped = LyricsDocumentSource.online(identifier: "amll", name: "AMLL TTML DB").stamped(lines)
        #expect(LyricsDocumentFingerprint(lines: stamped) == LyricsDocumentFingerprint(lines: lines))
    }

    @Test func sourceRoundTripsThroughTheCacheEncoding() throws {
        let lines = LyricsDocumentSource.online(identifier: "lrclib", name: "LRCLIB").stamped([
            LyricLine(timestamp: 1, text: "one"),
            LyricLine(timestamp: 2, text: "two"),
        ])
        let data = try JSONEncoder().encode(lines)
        let decoded = try JSONDecoder().decode([LyricLine].self, from: data)
        #expect(LyricsDocumentSource.of(decoded) == .online(identifier: "lrclib", name: "LRCLIB"))
        // 没记来源的行不写这一项,老缓存不膨胀。
        let second = try JSONEncoder().encode(lines[1])
        #expect(String(decoding: second, as: UTF8.self).contains("documentSource") == false)
    }

    @Test func oldCachesAndUnknownSourcesDecodeAsUnrecorded() throws {
        let old = Data(#"[{"id":"a","timestamp":1,"text":"one"}]"#.utf8)
        let oldLines = try JSONDecoder().decode([LyricLine].self, from: old)
        #expect(oldLines.first?.documentSource == nil)

        let future = Data(#"[{"id":"a","timestamp":1,"text":"one","documentSource":{"kind":"satellite"}}]"#.utf8)
        let futureLines = try JSONDecoder().decode([LyricLine].self, from: future)
        #expect(futureLines.first?.text == "one")
        #expect(futureLines.first?.documentSource == nil)
    }

    @Test func lookupSurvivesTheFirstLineMovingIntoABackgroundVoice() {
        var host = LyricLine(timestamp: 1, text: "lead")
        host.background = [
            LyricsDocumentSource.server("jellyfin").stamped([LyricLine(timestamp: 1, text: "echo")])[0],
        ]
        let lines = [host, LyricLine(timestamp: 2, text: "next")]
        #expect(LyricsDocumentSource.of(lines) == .server("jellyfin"))

        let shifted = [LyricLine(timestamp: 0.5, text: "pair")]
            + LyricsDocumentSource.file("a.ttml").stamped([LyricLine(timestamp: 1, text: "one")])
        #expect(LyricsDocumentSource.of(shifted) == .file("a.ttml"))
    }

    @Test func addsReportsOnlyANewOrDifferentSource() {
        let lines = [LyricLine(timestamp: 1, text: "one")]
        let server = LyricsDocumentSource.server("navidrome").stamped(lines)
        #expect(LyricsDocumentSource.adds(to: lines, from: server))
        #expect(!LyricsDocumentSource.adds(to: server, from: server))
        #expect(!LyricsDocumentSource.adds(to: server, from: lines))
        let online = LyricsDocumentSource.online(identifier: "amll", name: "AMLL TTML DB").stamped(lines)
        #expect(LyricsDocumentSource.adds(to: server, from: online))
    }

    @Test func badgeFollowsTheRecordedSource() {
        let lines = [LyricLine(timestamp: 1, text: "one")]
        #expect(LyricsSourceBadge.resolve(lines) == nil)
        #expect(LyricsSourceBadge.resolve([]) == nil)
        #expect(LyricsSourceBadge.resolve(LyricsDocumentSource.file("x.ttml").stamped(lines)) == .file(format: "TTML"))
        #expect(LyricsSourceBadge.resolve(LyricsDocumentSource.file("README").stamped(lines)) == .file(format: nil))
        #expect(LyricsSourceBadge.resolve(LyricsDocumentSource.embedded.stamped(lines)) == .embedded)
        #expect(LyricsSourceBadge.resolve(LyricsDocumentSource.appleMusic.stamped(lines)) == .appleMusic)
        #expect(LyricsSourceBadge.resolve(LyricsDocumentSource.server("fnMusic").stamped(lines)) == .server(sourceType: "fnMusic"))
        #expect(LyricsSourceBadge.resolve(LyricsDocumentSource.server("").stamped(lines)) == nil)
        #expect(
            LyricsSourceBadge.resolve(LyricsDocumentSource.online(identifier: "amll", name: "AMLL TTML DB").stamped(lines))
                == .online(identifier: "amll", name: "AMLL TTML DB")
        )
    }

    @Test func localEditWinsOverTheOriginalSource() {
        var lines = LyricsDocumentSource.online(identifier: "lrclib", name: "LRCLIB").stamped([
            LyricLine(timestamp: 1, text: "one"),
        ])
        lines[0].documentIsLocalOverride = true
        #expect(LyricsSourceBadge.resolve(lines) == .localEdit)
    }
}
