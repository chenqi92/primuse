import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric sidecar selection")
struct LyricsSidecarSelectionPolicyTests {
    @Test("A writable document wins over its read-only siblings")
    func prefersWritableDocument() {
        let names = ["song.srt", "song.lrc", "song.vtt"]
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: names)
            == .item(1))
    }

    @Test("Two writable documents stay ambiguous")
    func refusesTwoWritableDocuments() {
        let names = ["song.lrc", "song.ttml"]
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: names)
            == .conflict)
    }

    @Test("Read-only siblings are ranked, never a conflict")
    func ranksReadOnlySiblings() {
        // A transcription tool leaving `.vtt` and `.srt` side by side is
        // ordinary; nothing here will be overwritten, so one must be chosen.
        let mixed = ["song.srt", "song.vtt"]
        let wordTimed = ["song.vtt", "song.lys"]
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: mixed)
            == .item(1))
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: wordTimed)
            == .item(1))
    }

    @Test("Equal candidates fall back to the smallest name")
    func breaksTiesByName() {
        let names = ["song.vtt", "SONG.VTT"]
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: names)
            == .item(1))
    }

    @Test("Base name and extension are matched case-insensitively")
    func matchesCaseInsensitively() {
        let names = ["Song.VTT"]
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: names)
            == .item(0))
    }

    @Test("Unrelated files and unknown extensions are ignored")
    func ignoresUnrelatedFiles() {
        let unrelated = ["other.lrc", "song.vtt"]
        let unknown = ["song.txt", "song.flac"]
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: unrelated)
            == .item(1))
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: unknown)
            == .none)
        #expect(LyricsSidecarSelectionPolicy.currentDocument(baseName: "song", names: [])
            == .none)
    }

    @Test("Only the formats Primuse serializes may be written")
    func recognizesWritableDocuments() {
        #expect(LyricsSidecarSelectionPolicy.isWritableDocument(fileName: "song.lrc"))
        #expect(LyricsSidecarSelectionPolicy.isWritableDocument(fileName: "song.TTML"))
        #expect(!LyricsSidecarSelectionPolicy.isWritableDocument(fileName: "song.vtt"))
        #expect(!LyricsSidecarSelectionPolicy.isWritableDocument(fileName: "song.lys"))
        #expect(!LyricsSidecarSelectionPolicy.isWritableDocument(fileName: "song"))
    }

    @Test("A read-only document is replaced by an LRC next to it")
    func replacesReadOnlyDocument() throws {
        let plain = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "/music/album/song.vtt",
            fileName: "song.vtt"
        ))
        #expect(plain.targetPath == "/music/album/song.lrc")
        #expect(plain.fileName == "song.lrc")

        // ID-backed drives address a sidecar as the source item plus a suffix.
        let identifier = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "file-id-123.srt",
            fileName: "song.srt"
        ))
        #expect(identifier.targetPath == "file-id-123.lrc")
        #expect(identifier.fileName == "song.lrc")

        let uppercase = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "/music/song.VTT",
            fileName: "song.VTT"
        ))
        #expect(uppercase.targetPath == "/music/song.lrc")
        #expect(uppercase.fileName == "song.lrc")
    }

    @Test("An address that does not end in the extension has no replacement")
    func refusesUnrewritableAddress() {
        #expect(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "nfs::ZXhwb3J0::c29uZy52dHQ",
            fileName: "song.vtt"
        ) == nil)
        #expect(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "/music/song.vtt",
            fileName: "song"
        ) == nil)
    }

    @Test("An encoded address still learns the name of its writable sibling")
    func namesWritableSibling() {
        // NFS selection paths are base64, so the connector builds the sibling
        // address itself and only needs the file name from the policy.
        #expect(LyricsSidecarSelectionPolicy.writableFileName(replacing: "Song.vtt") == "Song.lrc")
        #expect(LyricsSidecarSelectionPolicy.writableFileName(replacing: "01. Intro.v2.SRT") == "01. Intro.v2.lrc")
    }
}
