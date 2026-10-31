import Foundation
import Testing
@testable import PrimuseKit

struct AudioFileRenamePlanTests {
    private func entries(_ names: [String]) -> [AudioFileRenamePlan.Entry] {
        names.map { .init(name: $0, path: "/Music/\($0)") }
    }

    @Test func movesAudioAndItsCompanionsButKeepsAlbumArtwork() throws {
        let plan = try AudioFileRenamePlan(audioPath: "/Music/old.FLAC", stem: "歌手 - 새 노래",
            entries: entries(["old.FLAC", "old.lrc", "old-cover.jpg", "old-back.png", "old.mp4", "cover.jpg", "folder.jpg", "other.lrc"]))
        #expect(plan.moves.count == 5)
        #expect(plan.moves.last?.to == "/Music/歌手 - 새 노래.FLAC")
        #expect(plan.moves.contains { $0.to == "/Music/歌手 - 새 노래.lrc" })
        #expect(!plan.moves.contains { $0.from == "/Music/cover.jpg" })
    }

    @Test(arguments: ["", "..", "a/b", "a\\b", "a:b", "a?b", ".hidden", "name.", " name", "a\nname", String(repeating: "曲", count: 90)])
    func rejectsInvalidNames(_ stem: String) {
        #expect(throws: AudioFileRenamePlan.Failure.invalidName) {
            try AudioFileRenamePlan.fileName(stem: stem, original: "old.flac")
        }
    }

    @Test(arguments: ["new.flac", "NEW.FLAC", "new.lrc"])
    func refusesAudioOrSidecarCollisions(_ occupied: String) {
        #expect(throws: AudioFileRenamePlan.Failure.collision) {
            try AudioFileRenamePlan(audioPath: "/Music/old.flac", stem: "new",
                entries: entries(["old.flac", "old.lrc", occupied]))
        }
    }

    @Test func rejectsDirectoriesAtDestinationAndCanonicalUnicodeCollision() {
        #expect(throws: AudioFileRenamePlan.Failure.collision) {
            try AudioFileRenamePlan(audioPath: "/Music/old.flac", stem: "new", entries: entries(["old.flac"]) + [.init(name: "new.flac", path: "/Music/new.flac", isDirectory: true)])
        }
        #expect(throws: AudioFileRenamePlan.Failure.collision) {
            try AudioFileRenamePlan(audioPath: "/Music/old.flac", stem: "café", entries: entries(["old.flac", "cafe\u{301}.flac"]))
        }
    }

    @Test func protectsCueReferencesAndSharedSidecars() {
        #expect(throws: AudioFileRenamePlan.Failure.cue) {
            try AudioFileRenamePlan(audioPath: "/Music/old.flac", stem: "new", entries: entries(["old.flac", "album.cue"]))
        }
        #expect(throws: AudioFileRenamePlan.Failure.sharedSidecars) {
            try AudioFileRenamePlan(audioPath: "/Music/old.flac", stem: "new", entries: entries(["old.flac", "old.mp3", "old.lrc"]))
        }
    }

    @Test func keepsExtensionAndAllowsUnchangedNames() throws {
        #expect(try AudioFileRenamePlan.fileName(stem: "new.mp3", original: "old.FLAC") == "new.mp3.FLAC")
        #expect(try AudioFileRenamePlan(audioPath: "/Music/old.flac", stem: "old", entries: entries(["old.flac", "album.cue"])).moves.isEmpty)
    }

    @Test func generatesNamesFromCurrentTagsWithoutLosingUnicode() {
        #expect(AudioFileRenamePlan.suggestedStem(title: "中文 (한국어)", artist: "Artist") == "Artist - 中文 (한국어)")
        #expect(AudioFileRenamePlan.suggestedStem(title: "Track", artist: "", track: 2) == "02 - Track")
        #expect(AudioFileRenamePlan.suggestedStem(title: "A/B: C", artist: "") == "A B  C")
    }
}
