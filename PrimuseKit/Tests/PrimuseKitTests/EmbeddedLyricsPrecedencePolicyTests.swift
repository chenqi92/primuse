import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric files beside the song outrank embedded lyrics")
struct EmbeddedLyricsPrecedencePolicyTests {
    @Test("Source documents are told apart from the app's own cache names")
    func sourceReferences() {
        #expect(EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("/Music/Album/Song.lrc"))
        #expect(EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("Song.ttml"))
        // Google Drive 记的是歌词文件的 id。
        #expect(EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("1AbC-dEf_ghIJ"))
        #expect(!EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("0f3a9c1e2b4d5a6f7e8d9c0b1a2f3e4d.json"))
        #expect(!EmbeddedLyricsPrecedencePolicy.referencesSourceDocument(nil))
        #expect(!EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("  "))
    }

    @Test("Only an untimed cache is rechecked, and only a timed file replaces it")
    func recheck() {
        let plain = [LyricLine(timestamp: 0, text: "Let it be", isSynchronized: false)]
        let timed = [LyricLine(timestamp: 10.45, text: "Let it be")]
        var edited = plain
        edited[0].documentIsLocalOverride = true

        #expect(EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: plain))
        #expect(!EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: timed))
        #expect(!EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: edited))
        #expect(!EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: []))

        #expect(EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: plain, with: timed))
        #expect(!EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: plain, with: plain))
        #expect(!EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: edited, with: timed))
    }
}
