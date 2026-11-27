import Foundation
import Testing
@testable import PrimuseKit

struct SACDMetadataXMLTests {
    private var sheet: CueSheet {
        CueSheet(title: "内嵌专辑", performer: "内嵌艺术家", genre: "Jazz", year: 1999, files: [
            CueFile(name: "Album.iso", type: "SACD", tracks: [
                CueTrack(number: 1, type: "AUDIO", title: "内嵌第一轨", startTime: 0, endTime: 200),
                CueTrack(number: 2, type: "AUDIO", title: "内嵌第二轨", startTime: 0, endTime: 180)
            ])
        ])
    }

    private func xml(_ tracks: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><root><store type=\"SACD\" id=\"test-disc\" version=\"1.2\">\(tracks)</store></root>".utf8)
    }

    @Test(arguments: [0, 1])
    func importsCompleteIdentityAndReplayGainWithoutChangingPlayback(offset: Int) throws {
        let data = xml("""
        <track id="\(1 + offset)">
          <meta name="TITLE" value="晨光 &amp; 海岸"/>
          <meta name="ARTIST" value="林海;陈风"/>
          <meta name="ALBUM" value="春日录音"/>
          <meta name="ALBUM ARTIST" value="远山乐团"/>
          <meta name="TRACKNUMBER" value="01/02"/>
          <meta name="DISCNUMBER" value="2 / 3"/>
          <meta name="DATE" value="2026-11-15"/>
          <meta name="GENRE" value="Classical;Instrumental"/>
          <meta name="COMPOSER" value="陈风"/>
          <replaygain name="replaygain_track_gain" value="-4.25 dB"/>
          <replaygain name="replaygain_track_peak" value="0.96"/>
          <replaygain name="replaygain_album_gain" value="-3 dB"/>
          <replaygain name="replaygain_album_peak" value="1.02"/>
        </track>
        <track id="\(2 + offset)"><meta name="TRACKNUMBER" value="2"/><meta name="TITLE" value="夜航"/></track>
        """)
        let document = try #require(SACDMetadataXML.parse(data))
        let merged = SACDMetadataXML.merging(document, into: sheet)
        let tracks = merged.files[0].tracks
        let identity = CueTrackIdentity(sheet: merged, track: tracks[0])
        #expect(identity.title == "晨光 & 海岸")
        #expect(identity.artist == "林海; 陈风")
        #expect(identity.albumTitle == "春日录音")
        #expect(identity.albumArtist == "远山乐团")
        #expect(identity.discNumber == 2)
        #expect(identity.year == 2026)
        #expect(identity.genre == "Classical; Instrumental")
        #expect(tracks[0].songwriter == "陈风")
        #expect(tracks[1].title == "夜航")
        #expect(CueTrackIdentity(sheet: merged, track: tracks[1]).year == 1999)
        #expect(tracks.map(\.identityKey) == sheet.files[0].tracks.map(\.identityKey))
        #expect(tracks.map(\.startTime) == [0, 0])
        #expect(tracks.map(\.endTime) == [200, 180])
        #expect(tracks.map(\.isoAudioTrack) == sheet.files[0].tracks.map(\.isoAudioTrack))
        var song = Song(id: "one", title: "one", fileFormat: .sacdISO, filePath: "Album.iso", sourceID: "test")
        song.applySACDMetadata(from: tracks[0])
        song.applyReplayGain(from: tracks[0])
        #expect(song.discNumber == 2)
        #expect(song.sourceArtistNames == ["林海", "陈风"])
        #expect(song.replayGainTrackGain == -4.25)
        #expect(song.replayGainTrackPeak == 0.96)
        #expect(song.replayGainAlbumGain == -3)
        #expect(song.replayGainAlbumPeak == 1.02)
    }

    @Test func sparseNumberedTagsAndEmptyFieldsKeepEmbeddedFallbacks() throws {
        let document = try #require(SACDMetadataXML.parse(xml("""
        <track id="3"><meta name="TRACKNUMBER" value="2"/><meta name="TITLE" value="  "/>
        <meta name="ARTIST" value="客席"/><meta name="DISCNUMBER" value="-1"/>
        <replaygain name="replaygain_track_peak" value="NaN"/>
        <replaygain name="replaygain_album_gain" value="999 dB"/></track>
        """)))
        let merged = SACDMetadataXML.merging(document, into: sheet)
        #expect(merged.files[0].tracks[0] == sheet.files[0].tracks[0])
        #expect(merged.files[0].tracks[1].title == "内嵌第二轨")
        #expect(merged.files[0].tracks[1].performer == "客席")
        #expect(merged.files[0].tracks[1].replayGainTrackPeak == nil)
        #expect(merged.files[0].tracks[1].replayGainAlbumGain == nil)
        #expect(CueTrackIdentity(sheet: merged, track: merged.files[0].tracks[1]).discNumber == nil)
    }

    @Test(arguments: [0, 1])
    func completeUnnumberedTablesUseTheirIDs(offset: Int) throws {
        let document = try #require(SACDMetadataXML.parse(xml("""
        <track id="\(1 + offset)"><meta name="TITLE" value="甲"/></track>
        <track id="\(2 + offset)"><meta name="TITLE" value="乙"/></track>
        """)))
        #expect(SACDMetadataXML.merging(document, into: sheet).files[0].tracks.map(\.title) == ["甲", "乙"])
    }

    @Test func ambiguousOrUnrelatedLayoutsDoNotReplaceTags() throws {
        for text in [
            "<track id=\"2\"><meta name=\"TITLE\" value=\"Ambiguous\"/></track>",
            "<track id=\"99\"><meta name=\"TRACKNUMBER\" value=\"1\"/></track>",
            "<track id=\"1\"><meta name=\"TRACKNUMBER\" value=\"2\"/></track>"
        ] {
            let document = try #require(SACDMetadataXML.parse(xml(text)))
            #expect(SACDMetadataXML.merging(document, into: sheet) == sheet)
        }
        var dataDisc = sheet
        dataDisc.files[0].type = "DATA-ISO"
        let document = try #require(SACDMetadataXML.parse(xml("<track id=\"1\"><meta name=\"TRACKNUMBER\" value=\"1\"/></track>")))
        #expect(SACDMetadataXML.merging(document, into: dataDisc) == dataDisc)
    }

    @Test func malformedDuplicateOversizedAndEntityDocumentsAreIgnored() {
        for text in [
            "<root><store type=\"SACD\"><track id=\"1\">",
            "<root><store type=\"OTHER\"><track id=\"1\"/></store></root>",
            "<root><store type=\"SACD\"><track id=\"1\"/><track id=\"1\"/></store></root>",
            "<root><store type=\"SACD\"><track id=\"1\"/></store><store type=\"SACD\"><track id=\"2\"/></store></root>",
            "<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><root><store type=\"SACD\"><track id=\"1\"><meta name=\"TITLE\" value=\"&x;\"/></track></store></root>",
            "<!DOCTYPE root [<!ENTITY x 'expanded'>]><root><store type=\"SACD\"><track id=\"1\"><meta name=\"TITLE\" value=\"&x;\"/></track></store></root>"
        ] { #expect(SACDMetadataXML.parse(Data(text.utf8)) == nil) }
        #expect(SACDMetadataXML.parse(Data(repeating: 32, count: SACDMetadataXML.maximumBytes + 1)) == nil)
    }

    @Test func acceptsDeclaredUTF16AndRepeatedValues() throws {
        let text = """
        <?xml version="1.0" encoding="UTF-16"?><root><store type="SACD"><track id="1">
        <meta name="TRACKNUMBER" value="1"/><meta name="TITLE" value="星河"/>
        <meta name="ARTIST" value="林海"/><meta name="ARTIST" value="陈风"/>
        </track></store></root>
        """
        let data = try #require(text.data(using: .utf16))
        let document = try #require(SACDMetadataXML.parse(data))
        #expect(document.tracks[1]?.title == "星河")
        #expect(document.tracks[1]?.artists == ["林海", "陈风"])
    }

    @Test func directorySelectionIsCaseInsensitiveAndRejectsAmbiguity() {
        let file = SACDMetadataXML.File(name: "ALBUM.XML", path: "opaque-id", size: 4000)
        #expect(SACDMetadataXML.companion(imageFileName: "Album.iso", files: [file])?.path == "opaque-id")
        #expect(SACDMetadataXML.companion(imageFileName: "Other.iso", files: [file]) == nil)
        #expect(SACDMetadataXML.companion(imageFileName: "Album.iso", files: [file, file]) == nil)
    }

    @Test func remoteLoaderHandlesShortReadsAndOptionalFailures() async throws {
        let data = xml("<track id=\"2\"><meta name=\"TRACKNUMBER\" value=\"1\"/><meta name=\"TITLE\" value=\"远程标题\"/></track>")
        let file = SACDMetadataXML.File(name: "Album.xml", path: "remote-id", size: Int64(data.count))
        let merged = try await SACDMetadataXML.loading(into: sheet, imageFileName: "Album.iso", files: [file]) { item, offset, length in
            #expect(item.path == "remote-id")
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + min(17, Int(length))))
        }
        #expect(merged.files[0].tracks[0].title == "远程标题")
        let failed = try await SACDMetadataXML.loading(into: sheet, imageFileName: "Album.iso", files: [file]) { _, _, _ in
            throw URLError(.fileDoesNotExist)
        }
        #expect(failed == sheet)
        let truncated = try await SACDMetadataXML.loading(into: sheet, imageFileName: "Album.iso", files: [file]) { _, _, _ in Data() }
        #expect(truncated == sheet)
        await #expect(throws: CancellationError.self) {
            try await SACDMetadataXML.loading(into: sheet, imageFileName: "Album.iso", files: [file]) { _, _, _ in
                throw CancellationError()
            }
        }
    }

    @Test func unrelatedAndOversizedCompanionsAreNeverRead() async throws {
        for file in [SACDMetadataXML.File(name: "Other.xml", path: "other", size: 10),
                     SACDMetadataXML.File(name: "Album.xml", path: "huge", size: Int64(SACDMetadataXML.maximumBytes + 1))] {
            let merged = try await SACDMetadataXML.loading(into: sheet, imageFileName: "Album.iso", files: [file]) { _, _, _ in
                Issue.record("Ineligible XML was read")
                return Data()
            }
            #expect(merged == sheet)
        }
    }

    @Test func unknownSizeCompanionStopsAtCompleteXMLWithoutReadingPastEOF() async throws {
        let data = xml("<track id=\"1\"><meta name=\"TRACKNUMBER\" value=\"1\"/><meta name=\"ALBUMARTIST\" value=\"专辑艺术家\"/></track>")
        let file = SACDMetadataXML.File(name: "Album.xml", path: "unknown-size", size: 0)
        let merged = try await SACDMetadataXML.loading(into: sheet, imageFileName: "Album.iso", files: [file]) { _, offset, _ in
            #expect(offset == 0)
            if offset != 0 { throw URLError(.badServerResponse) }
            return data
        }
        let identity = CueTrackIdentity(sheet: merged, track: merged.files[0].tracks[0])
        #expect(identity.albumArtist == "专辑艺术家")
        #expect(identity.artist == "内嵌艺术家")
        let task = Task {
            try await SACDMetadataXML.loading(into: sheet, imageFileName: "Album.iso", files: [file]) { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return data
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cuePrecedenceAndRescanPreserveEditsAndPlaybackIdentity() throws {
        let document = try #require(SACDMetadataXML.parse(xml("""
        <track id="1"><meta name="TRACKNUMBER" value="1"/><meta name="TITLE" value="XML 标题"/>
        <meta name="ALBUM" value="XML 专辑"/><meta name="ALBUMARTIST" value="XML 艺术家"/>
        <meta name="GENRE" value="Classical"/><meta name="DISCNUMBER" value="2"/></track>
        """)))
        let tagged = SACDMetadataXML.merging(document, into: sheet)
        let cue = CueSheet(title: "CUE 专辑", performer: "CUE 艺术家", genre: "Folk", files: [
            CueFile(name: "Album.iso", type: "WAVE", tracks: [
                CueTrack(number: 1, type: "AUDIO", title: "CUE 标题", startTime: 0, endTime: 200),
                CueTrack(number: 2, type: "AUDIO", startTime: 200)
            ])
        ])
        let merged = ISOAlbumMetadataPolicy.merging(tagged, imageFileName: "Album.iso", sidecars: [.init(name: "Album.cue", sheet: cue)])
        let identity = CueTrackIdentity(sheet: merged, track: merged.files[0].tracks[0])
        #expect(identity.title == "CUE 标题")
        #expect(identity.albumTitle == "CUE 专辑")
        #expect(identity.albumArtist == "CUE 艺术家")
        #expect(identity.genre == "Folk")
        #expect(identity.discNumber == 2)
        let original = Song(id: "one", title: "Original", duration: 200, fileFormat: .sacdISO,
            filePath: "Album.iso", sourceID: "test", sampleRate: 2_822_400, bitDepth: 1,
            cueSheetPath: "Album.iso", cueStartTime: 0, cueEndTime: 200, sacdTrackNumber: 1)
        var candidate = original
        candidate.title = identity.title!
        candidate.applySACDMetadata(from: merged.files[0].tracks[0])
        candidate.replayGainTrackGain = -4
        let refreshed = ISOAlbumMetadataPolicy.refreshingIdentity(of: original, from: candidate)
        #expect(refreshed.discNumber == 2)
        #expect(refreshed.replayGainTrackGain == -4)
        #expect(refreshed.sacdTrackNumber == 1)
        #expect(refreshed.duration == 200)
        #expect(ISOAlbumMetadataPolicy.refreshingIdentity(of: refreshed, from: original).discNumber == nil)
        var edited = original
        edited.userMetadataEditedAt = Date()
        #expect(ISOAlbumMetadataPolicy.refreshingIdentity(of: edited, from: candidate).title == "Original")
    }
}
