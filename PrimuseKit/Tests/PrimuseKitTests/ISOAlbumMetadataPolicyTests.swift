import Foundation
import Testing
@testable import PrimuseKit

struct ISOAlbumMetadataPolicyTests {
    private func image(name: String = "Album.iso") -> CueSheet {
        CueSheet(title: "Internal Album", performer: "Internal Artist", genre: "Jazz", year: 1990, files: [
            CueFile(name: name, type: "SACD", tracks: [
                CueTrack(number: 1, type: "AUDIO", title: "Internal One", startTime: 0, endTime: 200),
                CueTrack(number: 2, type: "AUDIO", title: "Internal Two", startTime: 0, endTime: 180)
            ])
        ])
    }

    private func sidecar(name: String = "Album.cue", file: String = "Album.iso",
                         album: String = "External Album【香港首版】", secondStart: String = "03:20:00") throws -> ISOAlbumMetadataPolicy.Sidecar {
        let sheet = try #require(CueSheetParser.parse(text: """
        TITLE "\(album)"
        PERFORMER "External Artist"
        REM DATE 2001
        FILE "\(file)" WAVE
          TRACK 01 AUDIO
            TITLE "External One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "External Two"
            PERFORMER "Guest"
            INDEX 01 \(secondStart)
        """))
        return .init(name: name, sheet: sheet)
    }

    @Test func externalTextWinsWithoutChangingISOTimelineOrDuplicatingTracks() throws {
        let native = image()
        let external = try sidecar()
        let merged = ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album.iso", sidecars: [external])
        #expect(merged.title == "External Album【香港首版】")
        #expect(merged.performer == "External Artist")
        #expect(merged.genre == "Jazz")
        #expect(merged.year == 2001)
        #expect(merged.files[0].tracks.map(\.title) == ["External One", "External Two"])
        #expect(merged.files[0].tracks.map(\.performer) == ["External Artist", "Guest"])
        #expect(merged.files[0].tracks.map(\.number) == [1, 2])
        #expect(merged.files[0].tracks.map(\.identityKey) == native.files[0].tracks.map(\.identityKey))
        #expect(merged.files[0].tracks.map(\.startTime) == [0, 0])
        #expect(merged.files[0].tracks.map(\.endTime) == [200, 180])
        #expect(external.sheet.filesForScanning(sheetFileName: external.name).isEmpty)
    }

    @Test func mismatchedTrackLayoutOnlyProvidesAlbumText() throws {
        let native = image()
        let merged = ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album.iso",
            sidecars: [try sidecar(secondStart: "01:00:00")])
        #expect(merged.title == "External Album【香港首版】")
        #expect(merged.files[0].tracks == native.files[0].tracks)
        var short = try sidecar()
        var sheet = short.sheet
        sheet.files[0].tracks.removeLast()
        short = .init(name: short.name, sheet: sheet)
        #expect(ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album.iso", sidecars: [short]).files == native.files)
    }

    @Test func referenceMustIdentifyThisImageInTheSameDirectory() throws {
        let native = image()
        for file in ["Other.iso", "../Album.iso", "other/Album.iso", "/Album.iso"] {
            let merged = ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album.iso", sidecars: [try sidecar(file: file)])
            #expect(merged == native)
        }
        let merged = ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album.iso", sidecars: [try sidecar(file: ".\\ALBUM.ISO")])
        #expect(merged.title == "External Album【香港首版】")
    }

    @Test func sameNameSidecarWinsAndAmbiguityDoesNotDependOnListingOrder() throws {
        let canonical = try sidecar()
        let other = try sidecar(name: "Alternative.cue", album: "Alternative")
        for entries in [[canonical, other], [other, canonical]] {
            #expect(ISOAlbumMetadataPolicy.merging(image(), imageFileName: "Album.iso", sidecars: entries).title == canonical.sheet.title)
        }
        let another = try sidecar(name: "Another.cue", album: "Another")
        for entries in [[other, another], [another, other]] {
            #expect(ISOAlbumMetadataPolicy.merging(image(), imageFileName: "Album.iso", sidecars: entries) == image())
        }
    }

    @Test func blankExternalFieldsFallBackToInternalValues() {
        let external = CueSheet(title: "  ", performer: "", files: [CueFile(name: "Album.iso", type: "WAVE", tracks: [])])
        #expect(ISOAlbumMetadataPolicy.merging(image(), imageFileName: "Album.iso", sidecars: [.init(name: "Album.cue", sheet: external)]) == image())
    }

    @Test func imageAndCueFileEditionMarksAreAppendedOnce() throws {
        let name = "Album【台版】.iso"
        let external = try sidecar(name: "Album【台版】[美版].cue", file: name, album: "Album【香港首版】")
        let merged = ISOAlbumMetadataPolicy.merging(image(name: name), imageFileName: name, sidecars: [external])
        #expect(merged.title == "Album【香港首版】 【台版】 [美版]")
        #expect(ISOAlbumMetadataPolicy.merging(merged, imageFileName: name, sidecars: [external]) == merged)
        #expect(ISOAlbumMetadataPolicy.addingEditionMarkers(to: "Album[台版]", fileNames: ["Album【臺灣版】.iso"]) == "Album[台版]")
        #expect(ISOAlbumMetadataPolicy.addingEditionMarkers(to: "Album", fileNames: ["Album[24bit][96kHz][Disc 1].iso"]) == "Album")
        #expect(ISOAlbumMetadataPolicy.addingEditionMarkers(to: "Album", fileNames: ["Album（香港首版）.iso"]) == "Album （香港首版）")
    }

    @Test func missingAlbumNameFallsBackToISOFileName() {
        var native = image(name: "Album【台版】.iso")
        native.title = nil
        #expect(ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album【台版】.iso", sidecars: []).title == "Album【台版】")
    }

    private func dataImage(albums: [String]) -> CueSheet {
        let tracks = albums.enumerated().map { index, album in
            CueTrack(number: index + 1, type: "AUDIO", title: "Track \(index)", startTime: 0, endTime: 200,
                isoAudioTrack: ISOAudioTrack(path: "/\(index)【台版】.flac", format: .flac, byteCount: 1234,
                    sampleRate: 96000, bitDepth: 24, duration: 200, albumTitle: album, albumArtist: "Artist"))
        }
        return CueSheet(title: "Collection", files: [CueFile(name: "Album.iso", type: "DATA-ISO", tracks: tracks)])
    }

    @Test func dataCollectionKeepsEachAlbumAndItsOwnEditionWithoutOuterOverrides() throws {
        let native = dataImage(albums: ["First", "Second"])
        let merged = ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album【美版】.iso",
            sidecars: [try sidecar(file: "Album【美版】.iso")])
        let tracks = merged.files[0].tracks
        #expect(tracks.map { $0.isoAudioTrack?.albumTitle } == ["First 【台版】", "Second 【台版】"])
        #expect(tracks.map(\.title) == native.files[0].tracks.map(\.title))
        #expect(tracks.map(\.identityKey) == native.files[0].tracks.map(\.identityKey))
        #expect(merged.performer == nil)
        #expect(merged.year == nil)
    }

    @Test func singleAlbumDataImageUpdatesTextWithoutChangingFileSelectorsOrTrackNames() throws {
        let native = dataImage(albums: ["Internal Album", "Internal Album"])
        let merged = ISOAlbumMetadataPolicy.merging(native, imageFileName: "Album.iso", sidecars: [try sidecar()])
        let tracks = merged.files[0].tracks
        #expect(tracks.map { $0.isoAudioTrack?.albumTitle } == Array(repeating: "External Album【香港首版】", count: 2))
        #expect(tracks.map { $0.isoAudioTrack?.albumArtist } == ["External Artist", "External Artist"])
        #expect(tracks.map(\.title) == native.files[0].tracks.map(\.title))
        #expect(tracks.map(\.identityKey) == native.files[0].tracks.map(\.identityKey))
        #expect(tracks.allSatisfy { $0.isoAudioTrack?.sampleRate == 96000 && $0.isoAudioTrack?.byteCount == 1234 })
        #expect(CueTrackIdentity(sheet: merged, track: tracks[0]).albumTitle == "External Album【香港首版】")
    }

    @Test func tvRescanAdoptsChangedOrRemovedSidecarTextWhilePreservingUserEditsAndTechnicalData() {
        let original = Song(id: "one", title: "Internal One", albumTitle: "Internal Album", artistName: "Artist",
            trackNumber: 1, duration: 200, fileFormat: .sacdISO, filePath: "/Album.iso", sourceID: "source",
            fileSize: 10000, sampleRate: 2_822_400, bitDepth: 1, cueSheetPath: "/Album.iso", cueStartTime: 0,
            cueEndTime: 200, sacdTrackNumber: 1, revision: "same")
        var candidate = original
        candidate.albumTitle = "Album【香港首版】"
        candidate.title = "External One"
        candidate.sampleRate = nil
        let updated = TVScanPipelinePolicy.reconciledSkeleton(existing: original, candidate: candidate)
        #expect(updated.albumTitle == candidate.albumTitle)
        #expect(updated.title == candidate.title)
        #expect(updated.sampleRate == original.sampleRate)
        #expect(updated.dateAdded == original.dateAdded)
        #expect(updated.id == original.id)
        #expect(TVScanPipelinePolicy.reconciledSkeleton(existing: updated, candidate: original).albumTitle == original.albumTitle)
        var edited = original
        edited.albumTitle = "My Album"
        edited.userMetadataEditedAt = Date()
        #expect(TVScanPipelinePolicy.reconciledSkeleton(existing: edited, candidate: candidate).albumTitle == "My Album")
    }
}
