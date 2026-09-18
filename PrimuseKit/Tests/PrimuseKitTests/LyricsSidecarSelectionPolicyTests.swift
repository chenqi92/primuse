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

    // MARK: - Language-tagged subtitles

    @Test("A language suffix is read from the last dot of the stem")
    func splitsLanguageTaggedNames() throws {
        let simple = try #require(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "01. Song.en.vtt"))
        #expect(simple.baseName == "01. Song")
        #expect(simple.tag == "en")

        let script = try #require(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.zh-Hans.srt"))
        #expect(script.baseName == "Song")
        #expect(script.tag == "zh-Hans")

        let original = try #require(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.en-orig.vtt"))
        #expect(original.baseName == "Song")
        #expect(original.tag == "en-orig")

        // yt-dlp keeps the video ID in the name, and a base name may hold any
        // number of dots; only the last one can be the tag.
        let dotted = try #require(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Title [dQw4w9WgXcQ].A.B.ja.srt"))
        #expect(dotted.baseName == "Title [dQw4w9WgXcQ].A.B")
        #expect(dotted.tag == "ja")
    }

    @Test("A suffix that is not a language leaves the name untagged")
    func rejectsNonLanguageSuffixes() {
        // The would-be tag here is " Song" — a track number, not a language.
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "01. Song.vtt") == nil)
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.Remix.srt") == nil)
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.live.vtt") == nil)
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.inst.srt") == nil)
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.v2.vtt") == nil)
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.vtt") == nil)
    }

    @Test("Only subtitle containers carry a language suffix")
    func tagsOnlySubtitleExtensions() {
        // `.lrc` and `.ttml` are writable, so admitting a tag here would let a
        // save land on a file no later read would look for.
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.en.lrc") == nil)
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.en.ttml") == nil)
        #expect(LyricsSidecarSelectionPolicy
            .languageTaggedComponents(ofSidecarNamed: "Song.en.lys") == nil)
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "Song",
            names: ["Song.en.lrc"],
            preferredLanguages: ["en"]
        ) == .none)
    }

    @Test("An exactly named document outranks every tagged one")
    func prefersExactlyNamedDocument() {
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "song",
            names: ["song.en.vtt", "song.lrc"],
            preferredLanguages: ["en"]
        ) == .item(1))
        // Even a read-only exact name wins: the tag tier is the last resort.
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "song",
            names: ["song.en.vtt", "song.srt"],
            preferredLanguages: ["en"]
        ) == .item(1))
    }

    @Test("A lone tagged subtitle is the song's document")
    func readsSingleTaggedSubtitle() {
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "01. Song",
            names: ["01. Song.flac", "01. Song.en.vtt"],
            preferredLanguages: ["fr"]
        ) == .item(1))
    }

    @Test("The base name of a tagged subtitle is matched case-insensitively")
    func matchesTaggedBaseNameCaseInsensitively() {
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "song",
            names: ["SONG.EN.VTT"],
            preferredLanguages: ["en"]
        ) == .item(0))
    }

    @Test("The original-language track beats the user's own language")
    func prefersOriginalLanguageTrack() {
        // yt-dlp's other tracks are machine translations of this one, and
        // Primuse puts its own translation layer on top of the original.
        #expect(LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: ["ja", "en-orig"],
            preferredLanguages: ["ja"]
        ) == 1)
    }

    @Test("Preferred languages are honoured in order, strong match first")
    func ranksPreferredLanguages() {
        #expect(LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: ["fr", "ja", "en"],
            preferredLanguages: ["ja", "fr"]
        ) == 1)
        // Both are English; only one is the requested variant.
        #expect(LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: ["en-GB", "en-US"],
            preferredLanguages: ["en-US"]
        ) == 1)
    }

    @Test("Chinese tags resolve to a script before they are compared")
    func infersChineseScript() {
        #expect(LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: ["cht", "chs"],
            preferredLanguages: ["zh-Hans-CN"]
        ) == 1)
        #expect(LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: ["zh-CN", "zh-TW"],
            preferredLanguages: ["zh-Hant-TW"]
        ) == 1)
    }

    @Test("Nothing preferred still resolves to the same file every time")
    func fallsBackDeterministically() {
        #expect(LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: ["ko", "ja"],
            preferredLanguages: ["fr"]
        ) == 1)
        #expect(LyricsSidecarSelectionPolicy.bestLanguageTagIndex(
            tags: [],
            preferredLanguages: ["fr"]
        ) == nil)
    }

    @Test("A tagged subtitle belonging to another song is left alone")
    func ignoresAnotherSongsSidecar() {
        // `Track.it.vtt` is the exact-name sidecar of `Track.it.flac`.
        let names = ["Track.flac", "Track.it.flac", "Track.it.vtt"]
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "Track",
            names: names,
            preferredLanguages: ["it"]
        ) == .none)
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "Track.it",
            names: names,
            preferredLanguages: ["it"]
        ) == .item(2))
    }

    @Test("Two tagged subtitles are a choice, never a conflict")
    func neverConflictsOnTaggedSubtitles() {
        #expect(LyricsSidecarSelectionPolicy.currentDocument(
            baseName: "song",
            names: ["song.en.vtt", "song.ja.srt"],
            preferredLanguages: ["ja"]
        ) == .item(1))
    }

    @Test("A save beside a tagged subtitle drops the tag")
    func replacesTaggedDocumentWithoutItsTag() throws {
        // `song.en.lrc` would be invisible to every later read, so the edit
        // has to land on `song.lrc`.
        let plain = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "/music/album/Song.en.vtt",
            fileName: "Song.en.vtt",
            baseName: "Song"
        ))
        #expect(plain.targetPath == "/music/album/Song.lrc")
        #expect(plain.fileName == "Song.lrc")

        // ID-backed drives address the sidecar as the source item plus a
        // suffix, so only the suffix can be rewritten there.
        let identifier = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "abc123.vtt",
            fileName: "Song.en.vtt",
            baseName: "Song"
        ))
        #expect(identifier.targetPath == "abc123.lrc")
        #expect(identifier.fileName == "Song.lrc")

        let uppercase = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "/music/Song.EN.VTT",
            fileName: "Song.EN.VTT",
            baseName: "Song"
        ))
        #expect(uppercase.targetPath == "/music/Song.lrc")
        #expect(uppercase.fileName == "Song.lrc")

        #expect(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "nfs::ZXhwb3J0::U29uZy5lbi52dHQ",
            fileName: "Song.en.vtt",
            baseName: "Song"
        ) == nil)
    }

    @Test("A song whose name ends in a language keeps its own base")
    func keepsBaseNameThatLooksLikeATag() throws {
        // `A.en.flac` really is called `A.en`; guessing would rename its
        // sidecar to `A.lrc` and lose it.
        let replacement = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "/music/A.en.vtt",
            fileName: "A.en.vtt",
            baseName: "A.en"
        ))
        #expect(replacement.targetPath == "/music/A.en.lrc")
        #expect(replacement.fileName == "A.en.lrc")
        #expect(LyricsSidecarSelectionPolicy.writableFileName(
            replacing: "A.en.vtt",
            baseName: "A.en"
        ) == "A.en.lrc")
    }

    @Test("Without a base name the replacement is unchanged")
    func keepsLegacyReplacementWithoutBaseName() throws {
        let legacy = try #require(LyricsSidecarSelectionPolicy.writableReplacement(
            targetPath: "/music/Song.en.vtt",
            fileName: "Song.en.vtt"
        ))
        #expect(legacy.targetPath == "/music/Song.en.lrc")
        #expect(legacy.fileName == "Song.en.lrc")
        #expect(LyricsSidecarSelectionPolicy.writableFileName(replacing: "Song.en.vtt")
            == "Song.en.lrc")
    }

    @Test("A directory indexes its tagged subtitles once")
    func indexesLanguageTaggedDirectory() {
        let index = LanguageTaggedLyricsIndex(
            fileNames: ["Song.flac", "Song.en.vtt", "Song.ja.vtt", "Other.fr.srt"],
            preferredLanguages: ["ja"]
        )
        #expect(index.bestMatch(baseName: "Song") == "Song.ja.vtt")
        #expect(index.bestMatch(baseName: "Other") == "Other.fr.srt")
        #expect(index.bestMatch(baseName: "Missing") == nil)

        let guarded = LanguageTaggedLyricsIndex(
            fileNames: ["Track.flac", "Track.it.flac", "Track.it.vtt"],
            preferredLanguages: ["it"]
        )
        #expect(guarded.bestMatch(baseName: "Track") == nil)
    }

    @Test("The original track's companion is the one the listener can read")
    func choosesTranslationTrackByPreferredLanguage() {
        let names = ["Song.mp3", "Song.en-orig.vtt", "Song.zh-Hans.vtt", "Song.fr.vtt"]
        #expect(LyricsSidecarSelectionPolicy.translationTrack(
            forPrimary: "Song.en-orig.vtt",
            baseName: "Song",
            names: names,
            preferredLanguages: ["zh-Hans", "fr"]
        ) == 2)
        #expect(LyricsSidecarSelectionPolicy.translationTrack(
            forPrimary: "Song.en-orig.vtt",
            baseName: "Song",
            names: names,
            preferredLanguages: ["fr"]
        ) == 3)
    }

    @Test("A track in the sung language is not a translation")
    func skipsTranslationTrackInTheOriginalLanguage() {
        // `en-GB` is the same words the `-orig` track already carries.
        #expect(LyricsSidecarSelectionPolicy.translationTrack(
            forPrimary: "Song.en-orig.vtt",
            baseName: "Song",
            names: ["Song.en-orig.vtt", "Song.en-GB.vtt", "Song.zh-Hans.vtt"],
            preferredLanguages: ["en-GB", "zh-Hans"]
        ) == 2)
    }

    @Test("A translation nobody reads is no translation at all")
    func refusesTranslationTrackWithoutPreferredLanguage() {
        // The main document falls back to the first tag by name; a companion
        // must not, or a Japanese listener would get Danish under every line.
        #expect(LyricsSidecarSelectionPolicy.translationTrack(
            forPrimary: "Song.en-orig.vtt",
            baseName: "Song",
            names: ["Song.en-orig.vtt", "Song.da.vtt", "Song.pt.vtt"],
            preferredLanguages: ["ja"]
        ) == nil)
    }

    @Test("Only an original track carries a companion")
    func refusesTranslationTrackForAnOrdinaryDocument() {
        // Two ordinary language tracks are alternatives, not a pair.
        #expect(LyricsSidecarSelectionPolicy.translationTrack(
            forPrimary: "Song.en.vtt",
            baseName: "Song",
            names: ["Song.en.vtt", "Song.zh-Hans.vtt"],
            preferredLanguages: ["zh-Hans"]
        ) == nil)
        // An exact-name document is the user's own file; nothing beside it is
        // a machine translation of it.
        #expect(LyricsSidecarSelectionPolicy.translationTrack(
            forPrimary: "Song.lrc",
            baseName: "Song",
            names: ["Song.lrc", "Song.zh-Hans.vtt"],
            preferredLanguages: ["zh-Hans"]
        ) == nil)
    }

    @Test("Another song's sidecar is never a companion")
    func guardsTranslationTrackAgainstAnotherSongsSidecar() {
        // `Track.it.vtt` is the exact-name sidecar of `Track.it.flac`.
        #expect(LyricsSidecarSelectionPolicy.translationTrack(
            forPrimary: "Track.en-orig.vtt",
            baseName: "Track",
            names: ["Track.flac", "Track.it.flac", "Track.it.vtt", "Track.en-orig.vtt"],
            preferredLanguages: ["it"]
        ) == nil)
    }

    @Test("A companion's tag is spelled the way translations are compared")
    func normalizesTranslationLanguageCode() {
        #expect(LyricsSidecarSelectionPolicy.translationLanguageCode(forTag: "zh-CN") == "zh-Hans")
        #expect(LyricsSidecarSelectionPolicy.translationLanguageCode(forTag: "chs") == "zh-Hans")
        #expect(LyricsSidecarSelectionPolicy.translationLanguageCode(forTag: "en-orig") == "en")
        #expect(LyricsSidecarSelectionPolicy.translationLanguageCode(forTag: "jpn") == "ja")
    }

    @Test("A directory hands out the companion it already indexed")
    func indexesTranslationTrack() {
        let index = LanguageTaggedLyricsIndex(
            fileNames: ["Song.mp3", "Song.en-orig.vtt", "Song.zh-Hans.vtt", "Song.fr.vtt"],
            preferredLanguages: ["fr"]
        )
        #expect(index.translationTrack(forPrimary: "Song.en-orig.vtt", baseName: "Song")
            == "Song.fr.vtt")
        #expect(index.translationTrack(forPrimary: "Song.zh-Hans.vtt", baseName: "Song") == nil)

        let alone = LanguageTaggedLyricsIndex(
            fileNames: ["Song.mp3", "Song.en-orig.vtt"],
            preferredLanguages: ["fr"]
        )
        #expect(alone.translationTrack(forPrimary: "Song.en-orig.vtt", baseName: "Song") == nil)
    }
}
