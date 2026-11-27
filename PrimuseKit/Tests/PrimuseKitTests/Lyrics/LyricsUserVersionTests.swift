import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics the listener saved")
struct LyricsUserVersionTests {
    private func lines(_ text: String) -> [LyricLine] {
        LyricsContentParser.parseText(text)
    }

    private func fingerprint(_ text: String) -> String {
        LyricsDocumentFingerprint(lines: lines(text)).rawValue
    }

    // MARK: - Policy

    @Test("Paths that do not read the source cannot replace the saved version")
    func automaticWritesYieldToTheSavedVersion() {
        let saved = fingerprint("[00:01.00]Saved line")
        let choice = LyricsUserChoicePolicy.choice(afterUserWriteOf: saved, previous: nil)
        // An online fallback or a timing upgrade.
        #expect(!LyricsUserChoicePolicy.admitsWrite(
            origin: .automatic, force: false, preservingSelection: false,
            choice: choice, currentFingerprint: saved, incomingFingerprint: "other"
        ))
        // Re-picking an embedded variant by the priority setting forces, but preserves selection.
        #expect(!LyricsUserChoicePolicy.admitsWrite(
            origin: .automatic, force: true, preservingSelection: true,
            choice: choice, currentFingerprint: saved, incomingFingerprint: "other"
        ))
        // An explicit scrape still overwrites.
        #expect(LyricsUserChoicePolicy.admitsWrite(
            origin: .automatic, force: true, preservingSelection: false,
            choice: choice, currentFingerprint: saved, incomingFingerprint: "other"
        ))
        // The cache already holds something else: the pin no longer applies.
        #expect(LyricsUserChoicePolicy.admitsWrite(
            origin: .automatic, force: false, preservingSelection: false,
            choice: choice, currentFingerprint: fingerprint("[00:01.00]Other"), incomingFingerprint: "other"
        ))
        #expect(LyricsUserChoicePolicy.admitsWrite(
            origin: .user, force: false, preservingSelection: true,
            choice: choice, currentFingerprint: saved, incomingFingerprint: "other"
        ))
    }

    @Test("The source read back as saved or still old keeps the pin; a change made elsewhere replaces it")
    func sourceReadsReplaceTheSavedVersionOnlyWhenChangedElsewhere() {
        let choice = LyricsUserChoicePolicy.choice(
            afterUserWriteOf: "saved", sourceFingerprint: "saved-in-file", replacing: "old", previous: nil
        )
        func admits(_ incoming: String) -> Bool {
            LyricsUserChoicePolicy.admitsWrite(
                origin: .sourceDocument, force: false, preservingSelection: false,
                choice: choice, currentFingerprint: "saved", incomingFingerprint: incoming
            )
        }
        #expect(!admits("saved"))
        #expect(!admits("saved-in-file"))
        #expect(!admits("old"))
        #expect(admits("edited-on-another-device"))
    }

    @Test("A cleared song refuses every automatic write until the listener acts; hidden versions stay out")
    func clearedAndHiddenVersions() {
        let cleared = LyricsUserChoicePolicy.choice(afterUserClear: nil)
        #expect(cleared.isCleared)
        // Background completion, online fallback, a scrape that only fills gaps, a tag re-read: none of them.
        for origin in [LyricsCacheWriteOrigin.automatic, .sourceDocument] {
            #expect(!LyricsUserChoicePolicy.admitsWrite(
                origin: origin, force: true, preservingSelection: false,
                choice: cleared, currentFingerprint: nil, incomingFingerprint: "incoming"
            ))
        }
        #expect(LyricsUserChoicePolicy.admitsWrite(
            origin: .user, force: false, preservingSelection: false,
            choice: cleared, currentFingerprint: nil, incomingFingerprint: "incoming"
        ))
        let lifted = LyricsUserChoicePolicy.choice(afterUserWriteOf: "incoming", previous: cleared)
        #expect(!lifted.isCleared)
        #expect(lifted.savedFingerprint == "incoming")

        let hidden = LyricsUserChoicePolicy.choice(hiding: "old", previous: nil)
        #expect(!LyricsUserChoicePolicy.admitsWrite(
            origin: .sourceDocument, force: false, preservingSelection: false,
            choice: hidden, currentFingerprint: nil, incomingFingerprint: "old"
        ))
        #expect(LyricsUserChoicePolicy.admitsWrite(
            origin: .automatic, force: false, preservingSelection: false,
            choice: hidden, currentFingerprint: nil, incomingFingerprint: "other"
        ))
        // Picking the hidden version again brings it back.
        let chosen = LyricsUserChoicePolicy.choice(afterUserWriteOf: "old", previous: hidden)
        #expect(chosen.hiddenFingerprints.isEmpty)
        // Clearing keeps what was hidden.
        #expect(LyricsUserChoicePolicy.choice(afterUserClear: hidden).hiddenFingerprints == ["old"])
    }

    @Test("A choice survives encoding and older records decode")
    func choiceRoundTrip() throws {
        let choice = LyricsUserChoice(
            savedFingerprint: "abc", savedSourceFingerprint: "file", previousFingerprint: "old",
            isCleared: false, hiddenFingerprints: ["h"]
        )
        let decoded = try JSONDecoder().decode(LyricsUserChoice.self, from: JSONEncoder().encode(choice))
        #expect(decoded == choice)
        let partial = try JSONDecoder().decode(LyricsUserChoice.self, from: Data(#"{"savedFingerprint":"x"}"#.utf8))
        #expect(partial.savedFingerprint == "x")
        #expect(partial.savedSourceFingerprint == nil)
        #expect(!partial.isCleared)
        #expect(partial.hiddenFingerprints.isEmpty)
        #expect(LyricsUserChoice().isEmpty)
    }

    // MARK: - Candidates

    @Test("Saving replaces the version in use; saving as a new version keeps the old one listed")
    func replaceAndKeepVersions() {
        let old = LyricsDocumentSource.embedded.stamped(lines("[00:01.00]Old line\n[00:02.00]Old two"))
        let other = LyricsDocumentSource.online(identifier: "a", name: "A").stamped(lines("[00:01.00]Other"))
        let new = LyricsDocumentSource.embedded.stamped(lines("[00:01.00]New line"))

        var replaced = LyricsSourceCollection()
        replaced.remember(other)
        replaced.remember(old)
        replaced.record(new, replacing: old, handling: .forget)
        let replacedPrints = replaced.candidates.map { LyricsDocumentFingerprint(lines: $0.lines) }
        #expect(!replacedPrints.contains(LyricsDocumentFingerprint(lines: old)))
        #expect(replacedPrints.contains(LyricsDocumentFingerprint(lines: new)))
        #expect(replacedPrints.contains(LyricsDocumentFingerprint(lines: other)))
        #expect(replaced.selectedID == nil)

        var kept = LyricsSourceCollection()
        kept.remember(old)
        kept.record(new, replacing: old, handling: .keep)
        #expect(kept.candidates.count == 2)
        let keptOld = kept.candidates.first { LyricsDocumentFingerprint(lines: $0.lines) == LyricsDocumentFingerprint(lines: old) }
        #expect(keptOld.map { kept.isKept($0.id) } == true)

        // Older behaviour for automatic writes: the previous one is remembered.
        var remembered = LyricsSourceCollection()
        remembered.record(new, replacing: old, handling: .remember)
        #expect(remembered.candidates.count == 2)
    }

    @Test("A full list never evicts the version just kept or the one just saved")
    func keptVersionSurvivesAFullList() throws {
        var sources = LyricsSourceCollection()
        let old = lines("[00:01.00]Oldest kept")
        sources.remember(old)
        for index in 0..<11 { sources.remember(lines("[00:01.00]Filler \(index)")) }
        #expect(sources.candidates.count == 12)
        let new = lines("[00:01.00]Newly saved")
        sources.record(new, replacing: old, handling: .keep)
        #expect(sources.candidates.count == 12)
        let keptOld = try #require(sources.candidates.first {
            LyricsDocumentFingerprint(lines: $0.lines) == LyricsDocumentFingerprint(lines: old)
        })
        #expect(sources.isKept(keptOld.id))
        #expect(sources.candidates.contains { LyricsDocumentFingerprint(lines: $0.lines) == LyricsDocumentFingerprint(lines: new) })
    }

    @Test("Forgetting compares both sides after the same normalization")
    func forgetUsesOneNormalization() {
        var sources = LyricsSourceCollection()
        sources.remember([LyricLine(timestamp: 1, text: "Fish &amp; chips")])
        let normalize: ([LyricLine]) -> [LyricLine] = { $0.map { LyricTextEntityPolicy.decoded($0) } }
        let removed = sources.forget([LyricLine(timestamp: 1, text: "Fish & chips")], normalize: normalize)
        #expect(removed == 1)
        #expect(sources.candidates.isEmpty)
    }

    @Test("Removing one version leaves the rest and clears a selection of it")
    func removeOneVersion() throws {
        var sources = LyricsSourceCollection()
        let firstCandidate = sources.remember(lines("[00:01.00]First"))
        let secondCandidate = sources.remember(lines("[00:01.00]Second"))
        let first = try #require(firstCandidate)
        let second = try #require(secondCandidate)
        sources.selectedID = first.id
        sources.keep(id: first.id)
        let removed = sources.remove(id: first.id)
        #expect(removed != nil)
        #expect(sources.selectedID == nil)
        #expect(!sources.isKept(first.id))
        #expect(sources.candidates.map(\.id) == [second.id])
        sources.keep(id: second.id)
        let decoded = try JSONDecoder().decode(
            LyricsSourceCollection.self, from: JSONEncoder().encode(sources)
        )
        #expect(decoded.candidates.map(\.id) == [second.id])
        #expect(decoded.isKept(second.id))
        #expect(decoded.selectedID == nil)
        // Records written before versions were kept still decode.
        let legacy = try JSONDecoder().decode(
            LyricsSourceCollection.self, from: Data(#"{"candidates":[]}"#.utf8)
        )
        #expect(legacy.candidates.isEmpty)
    }

    // MARK: - FLAC fields

    /// "fLaC" + STREAMINFO + VORBIS_COMMENT (last block): the metadata region only.
    private func flacRegion(_ comments: [(String, String)]) -> Data {
        func le(_ value: Int) -> Data {
            Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                  UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
        }
        var data = Data("fLaC".utf8)
        data.append(contentsOf: [0x00, 0x00, 0x00, 34])
        data.append(Data(count: 34))
        var payload = Data()
        let vendor = Data("fixture".utf8)
        payload.append(le(vendor.count))
        payload.append(vendor)
        payload.append(le(comments.count))
        for (key, value) in comments {
            let item = Data("\(key)=\(value)".utf8)
            payload.append(le(item.count))
            payload.append(item)
        }
        data.append(contentsOf: [0x84, UInt8((payload.count >> 16) & 0xFF),
                                 UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)])
        data.append(payload)
        return data
    }

    @Test("Replacing the version in use rewrites only its FLAC field and moves it first")
    func flacReplaceOneField() throws {
        let plain = "Plain words one\nPlain words two"
        let synced = "[00:01.00]Synced words one\n[00:02.00]Synced words two"
        let edited = "[00:01.00]Edited words one\n[00:02.00]Edited words two\n[00:03.00]Edited three"
        let region = flacRegion([
            ("TITLE", "Fixture"),
            ("UNSYNCEDLYRICS", plain),
            ("LYRICS", "[00:01.00]Other version"),
            ("SYNCEDLYRICS", synced),
            ("TRANSLATEDLYRICS", "[00:01.00]Translation"),
        ])
        let operation = EmbeddedLyricsFieldEditor.Operation.replace(text: edited, anchor: synced + "\r\n")
        let edit = try #require(EmbeddedLyricsFieldEditor.editFLAC(region: region, operation))
        #expect(edit.result == .replacedField)
        #expect(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: edit.region) == [edited, plain, "[00:01.00]Other version"])
        #expect(EmbeddedLyricsFieldEditor.verifyFLAC(original: region, edited: edit.region, operation, result: edit.result))

        let parsed = try #require(EmbeddedTagMetadataParser.parse(head: edit.region, fileExtension: "flac"))
        #expect(parsed.title == "Fixture")
        #expect(parsed.translatedLyrics == "[00:01.00]Translation")
        #expect(EmbeddedLyricsVariantPolicy.preferred(in: parsed.lyricsVariants, priority: .firstInFile)?.text == edited)
    }

    @Test("Only a field with exactly the same text is touched: a word-timed or bilingual copy of the same words is another version")
    func exactMatchOnly() throws {
        let lineTimed = "[00:01.00]Copper tide"
        let wordTimed = "[00:01.00]<00:01.00>Copper <00:01.50>tide"
        let bilingual = "[00:01.00]Copper tide\n[00:01.00]铜色潮水"
        let region = flacRegion([
            ("LYRICS", lineTimed), ("SYNCEDLYRICS", wordTimed), ("UNSYNCEDLYRICS", bilingual),
        ])
        let removed = try #require(EmbeddedLyricsFieldEditor.editFLAC(region: region, .removeOne(lineTimed)))
        #expect(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: removed.region) == [wordTimed, bilingual])
        let replaced = try #require(EmbeddedLyricsFieldEditor.editFLAC(
            region: region, .replace(text: "[00:01.00]Copper tide, edited", anchor: lineTimed)
        ))
        #expect(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: replaced.region)
                == ["[00:01.00]Copper tide, edited", wordTimed, bilingual])
        // Same words with another timestamp spelling is not the same field either.
        #expect(EmbeddedLyricsFieldEditor.editFLAC(region: region, .removeOne("[00:01.000]Copper tide")) == nil)
    }

    @Test("Without a located field the default field is only added, never overwritten")
    func flacDefaultFieldOnlyWhenFree() throws {
        let twoOriginals = flacRegion([("LYRICS", "[00:01.00]A"), ("SYNCEDLYRICS", "[00:01.00]B")])
        #expect(EmbeddedLyricsFieldEditor.editFLAC(region: twoOriginals, .replace(text: "[00:01.00]C", anchor: nil)) == nil)
        #expect(EmbeddedLyricsFieldEditor.editFLAC(region: twoOriginals, .replace(text: "[00:01.00]C", anchor: "[00:01.00]Z")) == nil)

        let noDefault = flacRegion([("SYNCEDLYRICS", "[00:01.00]B"), ("UNSYNCEDLYRICS", "B")])
        #expect(EmbeddedLyricsFieldEditor.editFLAC(region: noDefault, .replace(text: "[00:01.00]C", anchor: "stale original")) == nil)
        let added = try #require(EmbeddedLyricsFieldEditor.editFLAC(region: noDefault, .replace(text: "[00:01.00]C", anchor: nil)))
        #expect(added.result == .wroteDefaultField)
        #expect(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: added.region) == ["[00:01.00]C", "[00:01.00]B", "B"])

        // The only original is replaced even when its exact text is unknown.
        let single = flacRegion([("SYNCEDLYRICS", "[00:01.00]Only")])
        let only = try #require(EmbeddedLyricsFieldEditor.editFLAC(region: single, .replace(text: "[00:01.00]New", anchor: nil)))
        #expect(only.result == .replacedField)
        #expect(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: only.region) == ["[00:01.00]New"])
    }

    @Test("Clearing removes every original field and keeps the translation and other tags")
    func flacClearKeepsTranslations() throws {
        let region = flacRegion([
            ("ARTIST", "One"), ("ARTIST", "Two"),
            ("LYRICS", "[00:01.00]A"), ("SYNCEDLYRICS", "[00:01.00]B"), ("LYRICS:ENG", "[00:01.00]C"),
            ("TRANSLATEDLYRICS", "[00:01.00]Translation"),
        ])
        let edit = try #require(EmbeddedLyricsFieldEditor.editFLAC(region: region, .removeAllOriginals))
        #expect(edit.result == .removedOriginals(3))
        #expect(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: edit.region) == [])
        #expect(EmbeddedLyricsFieldEditor.verifyFLAC(original: region, edited: edit.region, .removeAllOriginals, result: edit.result))
        let parsed = try #require(EmbeddedTagMetadataParser.parse(head: edit.region, fileExtension: "flac"))
        #expect(parsed.artists == ["One", "Two"])
        #expect(parsed.translatedLyrics == "[00:01.00]Translation")
    }

    @Test("The safety check refuses any change outside the planned lyric fields")
    func flacSafetyCheck() throws {
        let region = flacRegion([("TITLE", "Fixture"), ("LYRICS", "[00:01.00]A"), ("SYNCEDLYRICS", "[00:01.00]B")])
        let operation = EmbeddedLyricsFieldEditor.Operation.removeOne("[00:01.00]B")
        let edit = try #require(EmbeddedLyricsFieldEditor.editFLAC(region: region, operation))
        #expect(EmbeddedLyricsFieldEditor.verifyFLAC(original: region, edited: edit.region, operation, result: edit.result))
        // Another tag changed.
        let retitled = flacRegion([("TITLE", "Changed"), ("LYRICS", "[00:01.00]A")])
        #expect(!EmbeddedLyricsFieldEditor.verifyFLAC(original: region, edited: retitled, operation, result: .removedField))
        // The wrong original removed.
        let wrong = flacRegion([("TITLE", "Fixture"), ("SYNCEDLYRICS", "[00:01.00]B")])
        #expect(!EmbeddedLyricsFieldEditor.verifyFLAC(original: region, edited: wrong, operation, result: .removedField))
        // Both originals removed.
        let both = flacRegion([("TITLE", "Fixture")])
        #expect(!EmbeddedLyricsFieldEditor.verifyFLAC(original: region, edited: both, operation, result: .removedField))
    }

    // MARK: - ID3 USLT frames

    private func uslt(language: String, descriptor: String, text: String) -> Data {
        Data([0x03]) + Data(language.utf8) + Data(descriptor.utf8) + Data([0x00]) + Data(text.utf8)
    }

    private func id3(_ frames: [(String, Data)], audio: Data) -> Data {
        func synchsafe(_ value: Int) -> Data {
            Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
                  UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
        }
        var body = Data()
        for (id, payload) in frames {
            body.append(Data(id.utf8))
            body.append(synchsafe(payload.count))
            body.append(contentsOf: [0, 0])
            body.append(payload)
        }
        body.append(Data(count: 64))
        return Data("ID3".utf8) + Data([4, 0, 0]) + synchsafe(body.count) + body + audio
    }

    @Test("Replacing one USLT frame keeps its language and descriptor, leaves translations, and moves it first")
    func usltReplaceOneFrame() throws {
        let english = uslt(language: "eng", descriptor: "", text: "[00:01.00]Morning tide")
        let other = uslt(language: "eng", descriptor: "alt", text: "[00:01.00]Evening tide")
        let translation = uslt(language: "zho", descriptor: "translation", text: "[00:01.00]晚潮")
        let edit = try #require(EmbeddedLyricsFieldEditor.editUSLT(
            bodies: [english, other, translation],
            .replace(text: "[00:01.00]Evening tide, edited", anchor: "[00:01.00]Evening tide\n")
        ))
        #expect(edit.result == .replacedField)
        #expect(EmbeddedLyricsFieldEditor.usltText(edit.bodies[0]) == "[00:01.00]Evening tide, edited")
        #expect(edit.bodies[0].subdata(in: 1..<4) == Data("eng".utf8))
        #expect(Array(edit.bodies.dropFirst()) == [english, translation])

        let cleared = try #require(EmbeddedLyricsFieldEditor.editUSLT(
            bodies: [english, other, translation], .removeAllOriginals
        ))
        #expect(cleared.bodies == [translation])
        #expect(EmbeddedLyricsFieldEditor.editUSLT(bodies: [english], .removeOne("[00:01.000]Morning tide")) == nil)
    }

    @Test("The ID3 safety check sees other frames and the audio data")
    func id3SafetyCheck() throws {
        let audio = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x11, count: 64)
        let first = uslt(language: "eng", descriptor: "", text: "[00:01.00]First")
        let second = uslt(language: "eng", descriptor: "alt", text: "[00:01.00]Second")
        let title = Data([0x03]) + Data("Fixture".utf8)
        let original = id3([("TIT2", title), ("USLT", first), ("USLT", second)], audio: audio)
        let bodies = try #require(ID3LyricsFramePreservation.lyricsFrameBodies(in: original))
        let edit = try #require(EmbeddedLyricsFieldEditor.editUSLT(bodies: bodies, .removeOne("[00:01.00]Second")))
        let rewritten = try #require(ID3LyricsFramePreservation.replacingLyricsFrames(in: original, with: edit.bodies))
        #expect(EmbeddedLyricsFieldEditor.verifyID3(original: original, edited: rewritten, expectedBodies: edit.bodies))

        var damagedAudio = rewritten
        damagedAudio[damagedAudio.count - 1] = 0x22
        #expect(!EmbeddedLyricsFieldEditor.verifyID3(original: original, edited: damagedAudio, expectedBodies: edit.bodies))
        let retitled = id3([("TIT2", Data([0x03]) + Data("Changed".utf8)), ("USLT", first)], audio: audio)
        #expect(!EmbeddedLyricsFieldEditor.verifyID3(original: original, edited: retitled, expectedBodies: edit.bodies))
    }

    @Test("Only the normalized full text decides whether two lyrics are the same version")
    func sameLyricsIsExact() {
        #expect(EmbeddedLyricsFieldEditor.sameLyrics("[00:01.00]A\r\n[00:02.50]B\n", "[00:01.00]A\n[00:02.50]B"))
        #expect(!EmbeddedLyricsFieldEditor.sameLyrics("[00:01.00]A", "[00:01.000]A"))
        #expect(!EmbeddedLyricsFieldEditor.sameLyrics("[00:01.00]A", "[00:01.00]B"))
        #expect(!EmbeddedLyricsFieldEditor.sameLyrics("", ""))
    }
}
