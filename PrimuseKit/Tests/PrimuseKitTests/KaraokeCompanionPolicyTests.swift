import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke companion matching")
struct KaraokeCompanionPolicyTests {
    static func song(
        _ id: String,
        _ title: String,
        artist: String? = "Jay Chou",
        album: String? = "Fantasy",
        duration: TimeInterval = 240,
        path: String? = nil,
        source: String = "nas"
    ) -> KaraokeCompanionCandidate {
        KaraokeCompanionCandidate(
            id: id,
            title: title,
            artistName: artist,
            albumTitle: album,
            duration: duration,
            filePath: path ?? "Music/Fantasy/\(title).flac",
            sourceID: source
        )
    }

    @Test("Recognises instrumental markers without false positives", arguments: [
        ("晴天 (伴奏)", true),
        ("晴天【伴奏】", true),
        ("Lemon (Instrumental)", true),
        ("恋 - off vocal ver.", true),
        ("Dynamite (Inst.)", true),
        ("밤편지 (MR)", true),
        ("Song Karaoke Version", true),
        ("Mr. Brightside", false),
        ("Instrumentalist Blues", false),
        ("晴天", false),
        ("Inside Out", false),
    ])
    func markers(title: String, expected: Bool) {
        #expect(KaraokeCompanionPolicy.isInstrumental(Self.song("x", title)) == expected)
    }

    @Test("A marker in the file name counts too")
    func fileNameMarker() {
        let tagged = Self.song("x", "晴天", path: "Music/Fantasy/晴天_伴奏.flac")
        #expect(KaraokeCompanionPolicy.isInstrumental(tagged))
    }

    @Test("Base titles agree between a song and its instrumental")
    func baseTitles() {
        let base = KaraokeCompanionPolicy.baseTitle("晴天")
        #expect(KaraokeCompanionPolicy.baseTitle("晴天 (伴奏)") == base)
        #expect(KaraokeCompanionPolicy.baseTitle("晴天【伴奏】") == base)
        #expect(KaraokeCompanionPolicy.baseTitle("晴天 - 伴奏") == base)
        #expect(KaraokeCompanionPolicy.baseTitle("晴天伴奏") == base)
        #expect(KaraokeCompanionPolicy.baseTitle("Lemon (Instrumental)") == "lemon")
        #expect(KaraokeCompanionPolicy.baseTitle("Lemon - Instrumental") == "lemon")
        #expect(KaraokeCompanionPolicy.baseTitle("밤편지 (MR)") == KaraokeCompanionPolicy.baseTitle("밤편지"))
        // A non-marker qualifier stays part of the title.
        #expect(KaraokeCompanionPolicy.baseTitle("Lemon (Live)") != "lemon")
    }

    @Test("Finds the instrumental and, in reverse, the original")
    func pairsBothWays() {
        let original = Self.song("a", "晴天")
        let instrumental = Self.song("b", "晴天 (伴奏)", duration: 241.5)
        let other = Self.song("c", "七里香 (伴奏)")
        let library = [original, instrumental, other]
        #expect(KaraokeCompanionPolicy.instrumental(for: original, in: library)?.id == "b")
        #expect(KaraokeCompanionPolicy.original(for: instrumental, in: library)?.id == "a")
        #expect(KaraokeCompanionPolicy.instrumental(for: instrumental, in: library) == nil)
        #expect(KaraokeCompanionPolicy.original(for: original, in: library) == nil)
    }

    @Test("Rejects a different arrangement, artist or unrelated folder")
    func rejections() {
        let original = Self.song("a", "晴天")
        let longer = Self.song("b", "晴天 (伴奏)", duration: 300)
        #expect(KaraokeCompanionPolicy.instrumental(for: original, in: [original, longer]) == nil)
        let otherArtist = Self.song("c", "晴天 (伴奏)", artist: "Someone Else", album: "Covers")
        #expect(KaraokeCompanionPolicy.instrumental(for: original, in: [original, otherArtist]) == nil)
        let unknownDurationElsewhere = Self.song(
            "d", "晴天 (伴奏)", artist: nil, album: nil, duration: 0, path: "Other/晴天 (伴奏).mp3"
        )
        #expect(KaraokeCompanionPolicy.instrumental(for: original, in: [original, unknownDurationElsewhere]) == nil)
    }

    @Test("Prefers the same folder, then the closest duration")
    func ranking() {
        let original = Self.song("a", "晴天", path: "Music/Fantasy/01 晴天.flac")
        let sameFolder = Self.song("b", "晴天 (伴奏)", duration: 242.5, path: "Music/Fantasy/01 晴天 (伴奏).flac")
        let elsewhere = Self.song("c", "晴天 (伴奏)", duration: 240.2, path: "Downloads/晴天 伴奏.mp3")
        #expect(KaraokeCompanionPolicy.instrumental(for: original, in: [elsewhere, original, sameFolder])?.id == "b")
        let closer = Self.song("d", "晴天 (伴奏)", duration: 240.1, path: "Downloads/b.mp3")
        #expect(KaraokeCompanionPolicy.instrumental(for: original, in: [elsewhere, closer])?.id == "d")
    }

    @Test("A companion without artist tags still pairs inside the same folder")
    func untaggedInSameFolder() {
        let original = Self.song("a", "晴天", path: "Music/Fantasy/晴天.flac")
        let bare = Self.song("b", "晴天 伴奏", artist: nil, album: nil, duration: 0, path: "Music/Fantasy/晴天 伴奏.wav")
        #expect(KaraokeCompanionPolicy.instrumental(for: original, in: [original, bare])?.id == "b")
    }
}
