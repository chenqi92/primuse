import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class FileAlbumArtistLibraryTests: XCTestCase {
    func testTruncatedUTF8AlbumSurvivesLocalAndRemoteMetadataMapping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruncatedAlbumTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tags = truncatedAlbumTagFixture()
        let url = directory.appendingPathComponent("album.mp3")
        try (tags.head + tags.tail).write(to: url)
        let service = MetadataService()
        let local = await service.loadMetadata(
            for: url, allowOnlineFetch: false, trustedSource: false, discoverSidecars: false
        )
        let remote = await service.loadEmbeddedMetadata(
            from: tags.head, id3TailData: tags.tail, fileExtension: "mp3",
            fallbackTitle: "File name"
        )
        let tailOnly = await service.loadEmbeddedMetadata(
            from: Data(repeating: 0, count: 128), id3TailData: tags.tail,
            fileExtension: "mp3", fallbackTitle: "File name"
        )
        for metadata in [local, remote, tailOnly] {
            XCTAssertEqual(metadata.title, "雨一直下")
            XCTAssertEqual(metadata.artist, "张宇")
            XCTAssertEqual(metadata.albumTitle, "大人的情\u{FFFD}")
            XCTAssertTrue(TextEncodingRepair.hasUnrecoverableReplacement(in: metadata.albumTitle ?? ""))
        }
    }

    func testLoadedTruncatedAlbumRetainsMissingCharacterEvidence() {
        for album in ["澶т汉鐨勬儏姝?ARTIST=寮犲畤", "澶т汉鐨勬儏姝"] {
            var cached = song(id: "truncated-album", metadata: .init(artist: "张宇", albumTitle: album))
            cached.albumPinyin = "obsolete"
            XCTAssertTrue(MusicLibrary.repairLegacyChineseMetadataText(in: &cached))
            XCTAssertEqual(cached.albumTitle, "大人的情\u{FFFD}")
            XCTAssertNil(cached.albumPinyin)
            XCTAssertFalse(MusicLibrary.repairLegacyChineseMetadataText(in: &cached))
        }
    }

    func testAudioPropertiesIgnoreInvalidValuesAndAllowFallback() {
        let invalidValues: [Double] = [
            .nan, .infinity, -.infinity, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude, Double(Int.max), Double(Int.min),
            Double(Float.nan), Double(Float.infinity), Double(Float.greatestFiniteMagnitude),
            0, -1, 0.5,
        ]
        for value in invalidValues {
            var metadata = FileMetadataReader.Metadata(title: "Track", duration: 180)
            metadata.applyAudioProperties(sampleRate: value, bitRateKbps: value)
            XCTAssertNil(metadata.sampleRate, "\(value)")
            XCTAssertNil(metadata.bitRate, "\(value)")
            XCTAssertEqual(metadata.title, "Track")
            XCTAssertEqual(metadata.duration, 180)

            metadata.fillMissing(from: .init(sampleRate: 44_100, bitRate: 320))
            XCTAssertEqual(metadata.sampleRate, 44_100)
            XCTAssertEqual(metadata.bitRate, 320)
        }
    }

    func testAudioPropertiesPreserveValidFieldsAndTruncateFractionalValues() {
        var metadata = FileMetadataReader.Metadata()
        metadata.applyAudioProperties(
            sampleRate: 44_100.9,
            bitRateKbps: Double(Float(320_999) / 1000)
        )
        XCTAssertEqual(metadata.sampleRate, 44_100)
        XCTAssertEqual(metadata.bitRate, 320)

        metadata.applyAudioProperties(sampleRate: .nan, bitRateKbps: .infinity)
        metadata.applyAudioProperties(sampleRate: 0, bitRateKbps: -1)
        metadata.applyAudioProperties()
        XCTAssertEqual(metadata.sampleRate, 44_100)
        XCTAssertEqual(metadata.bitRate, 320)

        metadata.applyAudioProperties(sampleRate: 192_000, bitRateKbps: .nan)
        XCTAssertEqual(metadata.sampleRate, 192_000)
        XCTAssertEqual(metadata.bitRate, 320)
        metadata.applyAudioProperties(sampleRate: .infinity, bitRateKbps: 1_411.2)
        XCTAssertEqual(metadata.sampleRate, 192_000)
        XCTAssertEqual(metadata.bitRate, 1_411)
    }

    func testRepairsAlbumWithAppendedArtistInLocalAndRangeTags() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumTextTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in ["mp3", "flac"] {
            for separator in ["?", "\0", "\u{FFFD}"] {
                let data = tagFixture(
                    format: format, key: format == "mp3" ? "TPE2" : "ALBUMARTIST",
                    singer: "张宇", album: "闆ㄤ竴鐩翠笅\(separator)ARTIST=寮犲畤"
                )
                let url = directory.appendingPathComponent("album.\(format)")
                try data.write(to: url)
                let local = await FileMetadataReader.read(from: url)
                let range = await FileMetadataReader.read(from: data, fileExtension: format)
                for metadata in [local, range] {
                    XCTAssertEqual(metadata.albumTitle, "雨一直下")
                    XCTAssertEqual(metadata.artist, "张宇")
                    XCTAssertEqual(metadata.albumArtist, "Various Artists")
                }
            }
        }
    }

    func testLoadedAlbumRepairInvalidatesSearchTextAndPreservesUserEdits() {
        var original = song(id: "damaged-album", metadata: .init(
            artist: "张宇", albumTitle: "闆ㄤ竴鐩翠笅?ARTIST=寮犲畤"
        ))
        original.albumPinyin = "obsolete"
        var repaired = original
        XCTAssertTrue(MusicLibrary.repairLegacyChineseMetadataText(in: &repaired))
        XCTAssertEqual(repaired.albumTitle, "雨一直下")
        XCTAssertNil(repaired.albumPinyin)
        XCTAssertFalse(MusicLibrary.repairLegacyChineseMetadataText(in: &repaired))

        var edited = original
        edited.userMetadataEditedAt = Date()
        let snapshot = edited
        XCTAssertFalse(MusicLibrary.repairLegacyChineseMetadataText(in: &edited))
        XCTAssertEqual(edited, snapshot)
    }

    func testLocalAndRangeTagsGroupDifferentSingersIntoOneAlbum() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumArtistTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for format in ["mp3", "flac"] {
            for key in ["ALBUMARTIST", "Album Artist", "ALBUM_ARTIST"] {
                var localSongs: [Song] = []
                var rangeSongs: [Song] = []
                for (index, singer) in ["Singer One", "Singer Two"].enumerated() {
                    let data = tagFixture(format: format, key: key, singer: singer)
                    let url = directory.appendingPathComponent("\(index).\(format)")
                    try data.write(to: url)
                    let local = await FileMetadataReader.read(from: url)
                    let range = await FileMetadataReader.read(from: data, fileExtension: format)
                    for metadata in [local, range] {
                        XCTAssertEqual(metadata.artist, singer, "\(format)/\(key)")
                        XCTAssertEqual(metadata.albumArtist, "Various Artists", "\(format)/\(key)")
                    }
                    localSongs.append(song(id: "\(index)", metadata: local))
                    rangeSongs.append(song(id: "\(index)", metadata: range))
                }
                for songs in [localSongs, rangeSongs] {
                    let grouped = MusicLibrary.computeAlbumsAndArtists(songs: songs)
                    XCTAssertEqual(grouped.albums.count, 1, "\(format)/\(key)")
                    XCTAssertEqual(grouped.albums.first?.artistName, "Various Artists")
                    XCTAssertEqual(grouped.albums.first?.songCount, 2)
                    XCTAssertEqual(Set(grouped.artists.map(\.name)), ["Singer One", "Singer Two"])
                }
            }
        }
    }

    func testRangeSessionReusesPrefixWithoutLosingTailOrExpandedTags() async {
        let session = FileMetadataReader.RangeReadSession()
        let head = tagFixture(format: "mp3", key: "TPE2", singer: "Head Artist")
        let tail = tagFixture(format: "mp3", key: "TPE2", singer: "Tail Artist")
        _ = await session.read(from: head, fileExtension: "mp3")
        let combined = await session.read(from: head, fileExtension: "mp3", id3TailData: tail)
        let reference = await FileMetadataReader.read(from: head, fileExtension: "mp3", id3TailData: tail)
        XCTAssertEqual(combined.title, reference.title)
        XCTAssertEqual(combined.artist, "Head Artist")
        XCTAssertEqual(combined.artist, reference.artist)
        XCTAssertEqual(combined.albumArtist, reference.albumArtist)
        XCTAssertEqual(combined.albumTitle, reference.albumTitle)
        XCTAssertEqual(combined.sourceArtistNames, reference.sourceArtistNames)
        XCTAssertEqual(combined.lyricsText, reference.lyricsText)

        let expanded = tagFixture(format: "mp3", key: "TPE2", singer: "Expanded Artist")
        let changed = await session.read(from: expanded, fileExtension: "mp3")
        XCTAssertEqual(changed.artist, "Expanded Artist")
        let changedFormat = await session.read(
            from: tagFixture(format: "flac", key: "ALBUMARTIST", singer: "FLAC Artist"),
            fileExtension: "flac"
        )
        XCTAssertEqual(changedFormat.artist, "FLAC Artist")
        XCTAssertEqual(changedFormat.albumArtist, "Various Artists")
    }

    func testRangeSessionTailFillsMissingTagsWithoutLeakingIntoNextRead() async {
        let session = FileMetadataReader.RangeReadSession()
        let head = Data(repeating: 0, count: 64)
        let initial = await session.read(from: head, fileExtension: "mp3")
        XCTAssertNil(initial.artist)
        let tail = tagFixture(format: "mp3", key: "TPE2", singer: "Tail Artist")
        let combined = await session.read(from: head, fileExtension: "mp3", id3TailData: tail)
        XCTAssertEqual(combined.artist, "Tail Artist")
        XCTAssertEqual(combined.albumArtist, "Various Artists")
        let withoutTail = await session.read(from: head, fileExtension: "mp3")
        XCTAssertNil(withoutTail.artist)
    }

    func testStandardMP3TagAlbumArtistKeepsAllValues() async throws {
        let data = tagFixture(
            format: "mp3", key: "TPE2", singer: "Singer",
            albumArtist: "Host\0Guest"
        )
        let metadata = await FileMetadataReader.read(from: data, fileExtension: "mp3")
        XCTAssertEqual(metadata.artist, "Singer")
        XCTAssertEqual(metadata.albumArtist, "Host; Guest")
    }

    func testCompleteFLACRangePreservesTagsAndAudioProperties() async throws {
        let data = completeFLACFixture()
        let native = try XCTUnwrap(FileMetadataReader.completeFLACMetadata(from: data, fileExtension: "FLAC"))
        let reference = await FileMetadataReader.read(from: data, fileExtension: "flac")
        let result = await FileMetadataReader.RangeReadSession().read(from: data, fileExtension: "flac")
        for metadata in [native, reference, result] {
            XCTAssertEqual(metadata.title, "Track")
            XCTAssertEqual(metadata.sourceArtistNames, ["Singer One", "Singer Two"])
            XCTAssertEqual(metadata.artist, "Singer One; Singer Two")
            XCTAssertEqual(metadata.albumTitle, "Compilation")
            XCTAssertEqual(metadata.albumArtist, "Various Artists")
            XCTAssertEqual(metadata.trackNumber, 2)
            XCTAssertEqual(metadata.discNumber, 1)
            XCTAssertEqual(metadata.year, 2026)
            XCTAssertEqual(metadata.genre, "Pop")
            XCTAssertEqual(metadata.sampleRate, 44_100)
            XCTAssertEqual(metadata.lyricsText, "[00:00.00]Original lyrics")
            XCTAssertEqual(metadata.replayGainTrackGain, -7.5)
            XCTAssertEqual(metadata.replayGainTrackPeak, 0.95)
            XCTAssertEqual(metadata.replayGainAlbumGain, -6)
            XCTAssertEqual(metadata.replayGainAlbumPeak, 0.98)
            XCTAssertEqual(metadata.coverArtData, flacCoverFixture)
        }
        // AVFoundation may round a bounded FLAC prefix to whole audio frames
        // and report zero bit depth; STREAMINFO has the exact source values.
        for metadata in [native, result] {
            XCTAssertEqual(try XCTUnwrap(metadata.duration), 1, accuracy: 0.001)
            XCTAssertEqual(metadata.bitDepth, 16)
            XCTAssertEqual(metadata.lyricsLanguageCode, "en")
            XCTAssertEqual(metadata.languageTaggedLyrics["zh-Hans"], "[00:00.00]译文")
        }
        XCTAssertEqual(result.languageTaggedLyrics, reference.languageTaggedLyrics)
        XCTAssertEqual(result.languageTaggedTranslations, reference.languageTaggedTranslations)
        XCTAssertEqual(result.translatedLyricsText, reference.translatedLyricsText)
    }

    func testFLACFastSessionPreservesLegacyTailPrecedence() async {
        let head = completeFLACFixture()
        let tail = tagFixture(format: "mp3", key: "TPE2", singer: "Tail Artist")
        let session = FileMetadataReader.RangeReadSession()
        _ = await session.read(from: head, fileExtension: "flac")
        let result = await session.read(from: head, fileExtension: "flac", id3TailData: tail)
        let reference = await FileMetadataReader.read(from: head, fileExtension: "flac", id3TailData: tail)
        XCTAssertEqual(result.artist, "Singer One; Singer Two")
        XCTAssertEqual(result.title, reference.title)
        XCTAssertEqual(result.artist, reference.artist)
        XCTAssertEqual(result.sourceArtistNames, reference.sourceArtistNames)
        XCTAssertEqual(result.albumArtist, reference.albumArtist)
        XCTAssertEqual(result.lyricsText, reference.lyricsText)
        XCTAssertEqual(result.coverArtData, reference.coverArtData)
        let withoutTail = await session.read(from: head, fileExtension: "flac")
        XCTAssertEqual(withoutTail.sourceArtistNames, ["Singer One", "Singer Two"])
        XCTAssertEqual(withoutTail.duration ?? 0, 1, accuracy: 0.001)
    }

    func testFLACFastPathFallsBackForIncompleteOrUnusualMetadata() async {
        let data = completeFLACFixture()
        // Every cut inside the metadata chain must wait for the remaining
        // blocks, including a cover that arrives in an expanded range.
        let metadataEnd = data.count - 142
        for count in 0..<metadataEnd {
            XCTAssertNil(FileMetadataReader.completeFLACMetadata(
                from: Data(data.prefix(count)), fileExtension: "flac"
            ), "prefix \(count)")
        }
        var unknownDuration = data
        unknownDuration[21] &= 0xF0
        unknownDuration.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        var invalidStreamInfo = data
        invalidStreamInfo[8] = 0
        invalidStreamInfo[9] = 0
        var invalidCommentLength = data
        // STREAMINFO ends at 42; the following comments begin with vendor length.
        invalidCommentLength.replaceSubrange(46..<50, with: [255, 255, 255, 127])
        let unusual = [unknownDuration, invalidStreamInfo, invalidCommentLength,
                       completeFLACFixture(extraPicture: true),
                       Data("ID3".utf8) + data]
        for candidate in unusual {
            XCTAssertNil(FileMetadataReader.completeFLACMetadata(from: candidate, fileExtension: "flac"))
            let reference = await FileMetadataReader.read(from: candidate, fileExtension: "flac")
            let result = await FileMetadataReader.RangeReadSession().read(from: candidate, fileExtension: "flac")
            XCTAssertEqual(result.title, reference.title)
            XCTAssertEqual(result.artist, reference.artist)
            XCTAssertEqual(result.duration, reference.duration)
            XCTAssertEqual(result.coverArtData, reference.coverArtData)
        }
        let session = FileMetadataReader.RangeReadSession()
        let prefix = await session.read(from: Data(data.prefix(42)), fileExtension: "flac")
        XCTAssertNil(prefix.coverArtData)
        let expanded = await session.read(from: data, fileExtension: "flac")
        XCTAssertEqual(expanded.coverArtData, flacCoverFixture)
        XCTAssertEqual(expanded.artist, "Singer One; Singer Two")
    }

    func testFLACRangeParsingCostWithCompleteMetadata() async {
        let data = completeFLACFixture()
        let count = 16
        let oldStart = ContinuousClock.now
        for _ in 0..<count {
            let result = await FileMetadataReader.read(from: data, fileExtension: "flac")
            XCTAssertEqual(result.title, "Track")
            XCTAssertGreaterThan(result.duration ?? 0, 0)
        }
        let oldElapsed = ContinuousClock.now - oldStart
        let newStart = ContinuousClock.now
        for _ in 0..<count {
            let result = await FileMetadataReader.RangeReadSession().read(from: data, fileExtension: "flac")
            XCTAssertEqual(result.title, "Track")
            XCTAssertEqual(result.duration ?? 0, 1, accuracy: 0.001)
        }
        print("FLAC metadata benchmark: \(count) files AVFoundation=\(oldElapsed) native=\(ContinuousClock.now - newStart)")
    }

    func testRereadAlbumArtistRemovesPreviouslySplitAlbums() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumArtistRebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        let originals = ["Singer One", "Singer Two"].enumerated().map { index, singer in
            song(id: "\(index)", metadata: .init(
                artist: singer, albumTitle: "Compilation", albumArtist: singer
            ))
        }
        library.addSongs(originals, affectedSourceIDs: ["local-tags"])
        for _ in 0..<200 where library.albums.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.albums.count, 2)

        var corrected: [Song] = []
        for original in originals {
            let metadata = await FileMetadataReader.read(
                from: tagFixture(format: "flac", key: "ALBUM_ARTIST", singer: original.artistName!),
                fileExtension: "flac"
            )
            var updated = original
            updated.albumArtistName = metadata.albumArtist
            corrected.append(updated)
        }
        library.replaceSongs(corrected)
        for _ in 0..<200 where library.albums.count != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.albums.count, 1)
        XCTAssertEqual(library.albums.first?.artistName, "Various Artists")
        XCTAssertEqual(library.albums.first?.songCount, 2)
        XCTAssertEqual(Set(library.songs.compactMap(\.albumID)).count, 1)
        XCTAssertEqual(Set(library.songs.compactMap(\.artistName)), ["Singer One", "Singer Two"])
        _ = await library.persistNowAndWait()
    }

    func testMissingAlbumArtistDoesNotMergeUnrelatedSameTitleAlbums() {
        let songs = ["Singer One", "Singer Two"].enumerated().map { index, singer in
            song(id: "\(index)", metadata: .init(artist: singer, albumTitle: "Greatest Hits"))
        }
        XCTAssertEqual(MusicLibrary.computeAlbumsAndArtists(songs: songs).albums.count, 2)
    }

    private func song(id: String, metadata: FileMetadataReader.Metadata) -> Song {
        Song(
            id: id, title: id, albumTitle: metadata.albumTitle,
            artistName: metadata.artist,
            albumArtistName: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: metadata.albumArtist, trackArtistName: metadata.artist
            ),
            duration: 180, fileFormat: .mp3, filePath: "\(id).mp3", sourceID: "local-tags"
        )
    }

    private var flacCoverFixture: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private func completeFLACFixture(extraPicture: Bool = false) -> Data {
        func uint32(_ value: Int, littleEndian: Bool = false) -> Data {
            Data((littleEndian ? [0, 8, 16, 24] : [24, 16, 8, 0]).map { UInt8((value >> $0) & 255) })
        }
        func block(_ type: UInt8, _ body: Data, last: Bool = false) -> Data {
            Data([type | (last ? 0x80 : 0)]) + uint32(body.count).suffix(3) + body
        }
        // STREAMINFO and frames encode one second of 44.1 kHz, 16-bit stereo silence.
        let streamInfo = Data(base64Encoded: "EgASAAAADgAAEArEQvAAAKxE0rEgGZAZtjnVp+KzRj6clw==")!
        let frames = Data(base64Encoded: "//hZGABrAAAAAAAAEIr/+FkYAWwAAAAAAACH///4WRgCZQAAAAAAAL5l//hZGANiAAAAAAAAKRD/+FkYBHcAAAAAAADNUf/4WRgFcAAAAAAAAFok//hZGAZ5AAAAAAAAY77/+FkYB34AAAAAAAD0y//4WRgIUwAAAAAAACs5//h5GAkKQ3AAAAAAAACYhQ==")!
        let tags = ["TITLE=Track", "ARTIST=Singer One", "ARTIST=Singer Two", "ALBUM=Compilation",
                    "ALBUMARTIST=Various Artists", "TRACKNUMBER=2/10", "DISCNUMBER=1/2",
                    "DATE=2026-09-06", "GENRE=Pop", "LYRICS=[00:00.00]Original lyrics",
                    "LYRICS:en=[00:00.00]Original lyrics", "LYRICS:zh-Hans=[00:00.00]译文",
                    "LYRICS_LANGUAGE=en", "REPLAYGAIN_TRACK_GAIN=-7.5 dB", "REPLAYGAIN_TRACK_PEAK=0.95",
                    "REPLAYGAIN_ALBUM_GAIN=-6 dB", "REPLAYGAIN_ALBUM_PEAK=0.98"]
        var comments = uint32(0, littleEndian: true) + uint32(tags.count, littleEndian: true)
        for tag in tags {
            let bytes = Data(tag.utf8)
            comments += uint32(bytes.count, littleEndian: true) + bytes
        }
        let mime = Data("image/png".utf8)
        let cover = flacCoverFixture
        let picture = uint32(3) + uint32(mime.count) + mime + uint32(0)
            + uint32(1) + uint32(1) + uint32(24) + uint32(0) + uint32(cover.count) + cover
        var result = Data("fLaC".utf8) + block(0, streamInfo) + block(4, comments)
        if extraPicture { result += block(6, picture) }
        return result + block(6, picture, last: true) + frames
    }

    private func tagFixture(
        format: String, key: String, singer: String, albumArtist: String = "Various Artists",
        album: String = "Compilation"
    ) -> Data {
        func uint32(_ value: Int, littleEndian: Bool = false) -> Data {
            let shifts = littleEndian ? [0, 8, 16, 24] : [24, 16, 8, 0]
            return Data(shifts.map { UInt8((value >> $0) & 0xFF) })
        }
        if format == "flac" {
            let comments = ["TITLE=Track", "ARTIST=\(singer)", "ALBUM=\(album)", "\(key)=\(albumArtist)"]
            var block = uint32(6, littleEndian: true) + Data("Mp3tag".utf8)
            block.append(uint32(comments.count, littleEndian: true))
            for comment in comments {
                let bytes = Data(comment.utf8)
                block.append(uint32(bytes.count, littleEndian: true))
                block.append(bytes)
            }
            // A complete metadata region suffices even without audio frames.
            var file = Data("fLaC".utf8)
            file.append(contentsOf: [0, 0, 0, 34])
            file.append(Data(repeating: 0, count: 34))
            file.append(0x84)
            file.append(uint32(block.count).suffix(3))
            file.append(block)
            return file
        }
        let fields = [("TIT2", "Track"), ("TPE1", singer), ("TALB", album),
                      (key == "TPE2" ? "TPE2" : "TXXX", key == "TPE2" ? albumArtist : "\(key)\0\(albumArtist)")]
        var body = Data()
        for (id, value) in fields {
            let payload = Data([1]) + value.data(using: .utf16)!
            body.append(Data(id.utf8))
            body.append(uint32(payload.count))
            body.append(contentsOf: [0, 0])
            body.append(payload)
        }
        let size = Data([21, 14, 7, 0].map { UInt8((body.count >> $0) & 0x7F) })
        return Data([0x49, 0x44, 0x33, 3, 0, 0]) + size + body
    }

    private func truncatedAlbumTagFixture() -> (head: Data, tail: Data) {
        let title = Data("雨一直下".utf8)
        let artist = Data("张宇".utf8)
        let album = Data("大人的情".utf8) + Data([0xE6, 0xAD]) + Data("?ARTIST=张宇".utf8)
        func syncSafe(_ size: Int) -> Data {
            Data([21, 14, 7, 0].map { UInt8((size >> $0) & 0x7F) })
        }
        var body = Data()
        for (key, text) in [("TIT2", title), ("TPE1", artist), ("TALB", album)] {
            let payload = Data([3]) + text
            body += Data(key.utf8) + syncSafe(payload.count) + Data([0, 0]) + payload
        }
        let head = Data([0x49, 0x44, 0x33, 4, 0, 0]) + syncSafe(body.count) + body
        var tail = Data("TAG".utf8)
        for text in [title, artist, album] {
            tail += text + Data(repeating: 0, count: 30 - text.count)
        }
        tail += Data(repeating: 0, count: 35)
        return (head, tail)
    }
}

final class ArtistNameLibraryTests: XCTestCase {
    func testCatalogSearchFindsAlbumWithoutMatchingSongs() {
        let album = Album(id: "album", title: "独立专辑名称", artistName: "Artist")
        let result = SearchCatalogPolicy.albums(
            query: "独立专辑",
            visibleAlbums: [album],
            relatedAlbums: []
        )
        XCTAssertEqual(result.map(\.id), [album.id])
    }

    func testCatalogSearchPrioritizesDirectMatchesAndDeduplicatesRelatedAlbums() {
        let direct = Album(id: "direct", title: "Moonlight", artistName: "Artist")
        let related = Album(id: "related", title: "Other", artistName: "Artist")
        let hidden = Album(id: "hidden", title: "Hidden source")
        let result = SearchCatalogPolicy.albums(
            query: "moonlight",
            visibleAlbums: [related, direct],
            relatedAlbums: [related, direct, related, hidden]
        )
        XCTAssertEqual(result.map(\.id), [direct.id, related.id])
    }

    func testCatalogSearchKeepsAllArtistAlbumMatches() {
        let albums = (0..<24).map {
            Album(id: "album-\($0)", title: "Release \($0)", artistName: "Artist")
        }
        let result = SearchCatalogPolicy.albums(
            query: "artist",
            visibleAlbums: albums,
            relatedAlbums: []
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(albums.map(\.id)))
    }

    func testCatalogSearchDoesNotReturnRelatedAlbumsForBlankQuery() {
        let album = Album(id: "album", title: "Album")
        XCTAssertTrue(SearchCatalogPolicy.albums(
            query: " \n ",
            visibleAlbums: [album],
            relatedAlbums: [album]
        ).isEmpty)
    }

    func testTextArtistsJoinOneAlbumButCreateContributorEntries() throws {
        let song = makeSong(
            artistName: "Host; Guest",
            albumArtistName: "Host",
            albumTitle: "Collaboration"
        )

        let result = MusicLibrary.computeAlbumsAndArtists(songs: [song])
        let host = try XCTUnwrap(result.artists.first { $0.name == "Host" })
        let guest = try XCTUnwrap(result.artists.first { $0.name == "Guest" })

        XCTAssertEqual(result.albums.count, 1)
        XCTAssertEqual(result.albums.first?.artistName, "Host")
        XCTAssertEqual(host.songCount, 1)
        XCTAssertEqual(host.albumCount, 1)
        XCTAssertEqual(guest.songCount, 1)
        XCTAssertEqual(guest.albumCount, 0)
    }

    func testProtectedNamePreventsConfiguredSymbolFromSplittingArtist() {
        let configuration = ArtistNameConfiguration(
            separators: ["/", ";"],
            protectedNames: ["AC/DC"],
            displaySeparator: " / "
        )
        let song = makeSong(artistName: "AC/DC; Guest")

        let result = MusicLibrary.computeAlbumsAndArtists(
            songs: [song],
            configuration: configuration
        )

        XCTAssertEqual(Set(result.artists.map(\.name)), ["AC/DC", "Guest"])
    }

    func testNativeArtistArrayIsAuthoritativeEvenWhenNamesContainSeparators() {
        let configuration = ArtistNameConfiguration(
            separators: ["/", "&", ";"],
            protectedNames: [],
            displaySeparator: " + "
        )
        let song = makeSong(
            artistName: "AC/DC & Simon & Garfunkel",
            sourceArtistNames: ["AC/DC", "Simon & Garfunkel"]
        )

        let result = MusicLibrary.computeAlbumsAndArtists(
            songs: [song],
            configuration: configuration
        )

        XCTAssertEqual(Set(result.artists.map(\.name)), ["AC/DC", "Simon & Garfunkel"])
    }

    func testCaseVariantsCollapseIntoOneStableArtist() throws {
        let first = makeSong(artistName: "Artist")
        let second = makeSong(artistName: "ARTIST")

        let result = MusicLibrary.computeAlbumsAndArtists(songs: [first, second])
        let artist = try XCTUnwrap(result.artists.first)

        XCTAssertEqual(result.artists.count, 1)
        XCTAssertEqual(artist.id, MusicLibrary.hashID("artist"))
        XCTAssertEqual(artist.name, "Artist")
        XCTAssertEqual(artist.songCount, 2)
    }

    @MainActor
    func testArtistSongLookupIncludesContributorsAndTracksVisibility() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistSongLookupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(
            storageDirectory: storageDirectory,
            artistNameConfiguration: .defaultValue
        )
        let duet = makeSong(
            id: "duet",
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"],
            sourceID: "source-a"
        )
        let solo = makeSong(
            id: "solo",
            artistName: "Guest",
            sourceID: "source-b"
        )
        let legacyNativeValue = makeSong(
            id: "legacy-native-value",
            artistName: " ",
            sourceArtistNames: ["Guest; Legacy"],
            sourceID: "source-c"
        )
        library.addSongs(
            [duet, solo, legacyNativeValue],
            affectedSourceIDs: [duet.sourceID, solo.sourceID, legacyNativeValue.sourceID]
        )

        let guestID = MusicLibrary.hashID("guest")
        for _ in 0..<200 where library.songs(forArtist: guestID).count != 3 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let expectedGuestSongIDs = ["duet", "solo", "legacy-native-value"]
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), ["Host", "Guest", "Legacy"])

        let guestOwner = LibraryArtworkOwner(kind: .artist, id: guestID)
        XCTAssertTrue(library.setArtwork(for: guestOwner, to: duet))
        let artworkPresentation = library.artworkPresentation(for: guestOwner)
        XCTAssertEqual(artworkPresentation.resolution, .selectedSong(duet.id))
        XCTAssertEqual(artworkPresentation.selectedSong?.id, duet.id)

        library.updateDisabledSourceIDs([duet.sourceID])
        XCTAssertEqual(
            library.songs(forArtist: guestID).map(\.id),
            ["solo", "legacy-native-value"]
        )
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), ["Guest", "Legacy"])

        library.updateDisabledSourceIDs([])
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), ["Host", "Guest", "Legacy"])
        _ = await library.persistNowAndWait()

        let restored = MusicLibrary(
            disabledSourceIDs: [duet.sourceID],
            storageDirectory: storageDirectory,
            artistNameConfiguration: .defaultValue
        )
        XCTAssertEqual(restored.songs.count, 3)
        XCTAssertEqual(restored.visibleSongs.map(\.id), ["solo", "legacy-native-value"])
        XCTAssertEqual(restored.songs(forArtist: guestID).map(\.id), ["solo", "legacy-native-value"])
        XCTAssertEqual(Set(restored.visibleArtists.map(\.name)), ["Guest", "Legacy"])
        XCTAssertTrue(restored.songs(forArtist: MusicLibrary.hashID("host")).isEmpty)
    }

    @MainActor
    func testArtistArtworkFallbackPrefersCoveredContributorSong() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistArtworkFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let uncovered = makeSong(id: "a-uncovered", artistName: "Guest")
        var covered = makeSong(
            id: "z-covered",
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"]
        )
        covered.coverArtFileName = "/Music/Album/cover.jpg"
        library.addSongs([uncovered, covered], affectedSourceIDs: ["source"])

        let guestID = MusicLibrary.hashID("guest")
        for _ in 0..<200 where library.preferredArtworkSong(forArtistID: guestID) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(library.preferredArtworkSong(forArtistID: guestID)?.id, covered.id)
        XCTAssertEqual(
            library.preferredArtworkSong(forArtistID: MusicLibrary.hashID("host"))?.id,
            covered.id
        )
    }

    func testMetadataSearchFindsSecondaryNativeArtist() {
        let song = makeSong(
            artistName: "Primary & Secondary",
            sourceArtistNames: ["Primary", "Secondary"]
        )

        let result = LibrarySearchWorker.compute(
            query: "Secondary",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertEqual(result.songResults.map(\.song.id), [song.id])
        XCTAssertEqual(result.songResults.first?.matchKind, .metadata)
    }

    func testKeywordSearchFindsAUserVisibleRelativePath() {
        let song = makeSong(
            artistName: "Artist",
            filePath: "Archive/Live Sessions/Track.flac"
        )

        let result = LibrarySearchWorker.compute(
            query: "Live Sessions",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertEqual(result.songResults.map(\.song.id), [song.id])
        XCTAssertEqual(result.songResults.first?.matchKind, .path)
    }

    func testKeywordSearchDoesNotMatchAnAppleMusicPath() {
        let song = makeSong(
            artistName: "Artist",
            sourceID: AppleMusicLibraryIdentity.sourceID,
            filePath: "/PrivateFolder/Track.m4a"
        )

        let result = LibrarySearchWorker.compute(
            query: "PrivateFolder",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertTrue(result.songResults.isEmpty)
    }

    @MainActor
    func testSmartPlaylistArtistRulesEvaluateEveryContributor() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistNameSmartPlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let song = makeSong(
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"]
        )
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        for _ in 0..<100 where library.visibleSongs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.map(\.id), [song.id])

        let includesGuest = SmartPlaylist(
            name: "Guest",
            rules: [SmartPlaylistRule(field: .artistName, op: .equals, value: "Guest")]
        )
        let excludesGuest = SmartPlaylist(
            name: "Not Guest",
            rules: [SmartPlaylistRule(field: .artistName, op: .notContains, value: "Guest")]
        )

        XCTAssertEqual(
            SmartPlaylistEngine.match(includesGuest, in: library, history: .shared).map(\.id),
            [song.id]
        )
        XCTAssertTrue(
            SmartPlaylistEngine.match(excludesGuest, in: library, history: .shared).isEmpty
        )
        _ = await library.persistNowAndWait()
    }

    private func makeSong(
        id: String = UUID().uuidString,
        artistName: String,
        sourceArtistNames: [String]? = nil,
        albumArtistName: String? = nil,
        albumTitle: String? = nil,
        sourceID: String = "source",
        filePath: String = "/track.flac"
    ) -> Song {
        Song(
            id: id,
            title: "Track",
            albumTitle: albumTitle,
            artistName: artistName,
            sourceArtistNames: sourceArtistNames,
            albumArtistName: albumArtistName,
            duration: 180,
            fileFormat: .flac,
            filePath: filePath,
            sourceID: sourceID
        )
    }
}

final class MusicDiscoveryRecommendationTests: XCTestCase {
    func testDailyRecommendationsFillFromOtherArtistsBeforeRepeatingOneArtist() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-120 * 24 * 60 * 60)
        let dominant = (0..<8).map { index in
            makeSong(
                id: "artist-a-\(index)",
                artist: "Artist A",
                album: "Album A",
                dateAdded: oldDate
            )
        }
        let alternatives = ["Artist B", "Artist C", "Artist D"].flatMap { artist in
            (0..<2).map { index in
                makeSong(
                    id: "\(artist)-\(index)",
                    artist: artist,
                    album: "\(artist) Album",
                    dateAdded: oldDate
                )
            }
        }
        let songs = dominant + alternatives
        let input = MusicDiscoveryEngine.RecommendationInput(
            songs: songs,
            recentWeekIDs: [],
            recentMonthIDs: [],
            topArtists: ["artist a"],
            seedIDs: ["artist-a-0"],
            now: now
        )

        let recommendations = MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 8)
        let artistCounts = Dictionary(
            grouping: recommendations,
            by: { $0.song.artistName ?? "" }
        ).mapValues(\.count)

        XCTAssertEqual(recommendations.count, 8)
        XCTAssertEqual(artistCounts.count, 4)
        XCTAssertLessThanOrEqual(artistCounts.values.max() ?? 0, 2)
    }

    private func makeSong(
        id: String,
        artist: String,
        album: String,
        dateAdded: Date
    ) -> Song {
        Song(
            id: id,
            title: id,
            albumID: album,
            artistID: artist,
            albumTitle: album,
            artistName: artist,
            duration: 180,
            fileFormat: .flac,
            filePath: "/\(id).flac",
            sourceID: "source",
            dateAdded: dateAdded
        )
    }
}

@MainActor
final class ArtistNameSettingsStoreTests: XCTestCase {
    func testUnsupportedFutureConfigurationIsPreservedUntilUserEdits() throws {
        let suiteName = "ArtistNameSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let future = ArtistNameConfiguration(
            schemaVersion: ArtistNameConfiguration.currentSchemaVersion + 1,
            separators: ["|"],
            protectedNames: ["Future Artist"],
            displaySeparator: " + "
        )
        let futureData = try JSONEncoder().encode(future)
        defaults.set(futureData, forKey: ArtistNameConfiguration.storageKey)

        let store = ArtistNameSettingsStore(
            defaults: defaults,
            syncsThroughICloud: false
        )

        XCTAssertTrue(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration, .defaultValue)
        XCTAssertEqual(defaults.data(forKey: ArtistNameConfiguration.storageKey), futureData)

        XCTAssertTrue(store.addSeparator("|"))
        XCTAssertFalse(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration.separators, [";", "；", "/", "、", "|"])
        XCTAssertEqual(
            ArtistNameConfiguration.load(from: defaults),
            store.configuration
        )
    }

    func testUndecodableConfigurationIsPreservedUntilUserEdits() throws {
        let suiteName = "ArtistNameSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unknownData = try XCTUnwrap(
            "{\"schemaVersion\":2,\"rules\":{\"kind\":\"future\"}}".data(using: .utf8)
        )
        defaults.set(unknownData, forKey: ArtistNameConfiguration.storageKey)

        let store = ArtistNameSettingsStore(
            defaults: defaults,
            syncsThroughICloud: false
        )

        XCTAssertTrue(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration, .defaultValue)
        XCTAssertEqual(defaults.data(forKey: ArtistNameConfiguration.storageKey), unknownData)
    }
}

final class LibraryScopedSearchTests: XCTestCase {
    func testPlaylistScopeExcludesSameTitleOutsidePlaylistAndGlobalRestoresIt() {
        let songs = [song(id: "inside"), song(id: "outside")]
        let scope = LibrarySearchScope(title: "Playlist", songIDs: ["inside"])
        XCTAssertEqual(search(scope.songs(in: songs)), ["inside"])
        XCTAssertEqual(Set(search(songs)), ["inside", "outside"])
        XCTAssertTrue(search(LibrarySearchScope(title: "Empty", songIDs: []).songs(in: songs)).isEmpty)
    }

    func testScopedSearchFindsMatchesBeyondTheGlobalResultLimit() {
        let songs = (0..<300).map { song(id: String(format: "%03d", $0)) }
        let scope = LibrarySearchScope(title: "Playlist", songIDs: ["299"])
        XCTAssertEqual(search(scope.songs(in: songs)), ["299"])
        XCTAssertEqual(search(songs).count, 120)
    }

    func testDirectoryScopeIncludesChildrenButNotSiblingOrOtherSource() throws {
        let songs = [
            song(id: "album", path: "/Music/Album/track.flac"),
            song(id: "disc", path: "/Music/Album/Disc/track.flac"),
            song(id: "sibling", path: "/Music/Album Live/track.flac"),
            song(id: "other-source", path: "/Music/Album/track.flac", sourceID: "other"),
        ]
        let sources = ["source", "other"].map {
            LibraryFolderSourceDescriptor(sourceID: $0, displayName: $0,
                                          scanRoots: ["/Music"], pathSemantics: .hierarchical)
        }
        let index = LibraryFolderIndexBuilder.build(sources: sources, songs: songs)
        let folder = try XCTUnwrap(index.nodeID(containingSongID: "album"))
        let scope = LibrarySearchScope.folder(
            node: try XCTUnwrap(index.node(withID: folder)),
            index: index,
            title: { $0.displayName ?? "Folder" }
        )
        XCTAssertEqual(Set(search(scope.songs(in: songs))), ["album", "disc"])
        XCTAssertEqual(search(scope.songs(in: songs.filter { $0.id != "disc" })), ["album"])
        XCTAssertEqual(scope.kind, .folder)
        XCTAssertEqual(scope.title, "Album")
        XCTAssertEqual(scope.detail, "source › Music")
        XCTAssertTrue(scope.includesSubfolders)
    }

    func testVirtualPlaylistUsesPlaylistIdentityAndDoesNotClaimSubfolders() throws {
        let sourceID = AppleMusicLibraryIdentity.sourceID
        let source = LibraryFolderSourceDescriptor(
            sourceID: sourceID, displayName: "Music Service", scanRoots: [], pathSemantics: .opaque
        )
        let index = LibraryFolderIndexBuilder.build(
            sources: [source],
            songs: [song(id: "inside", sourceID: sourceID), song(id: "outside", sourceID: sourceID)],
            virtualCollections: [
                LibraryFolderVirtualCollectionDescriptor(
                    sourceID: sourceID, identity: AppleMusicLibraryIdentity.systemPlaylistID,
                    displayName: "Library Songs", kind: .librarySongs, songIDs: ["inside", "outside"]
                ),
                LibraryFolderVirtualCollectionDescriptor(
                    sourceID: sourceID, identity: AppleMusicLibraryIdentity.userPlaylistIDPrefix + "road-trip",
                    displayName: "Road Trip", kind: .playlist, songIDs: ["inside"]
                ),
            ]
        )
        let sourceNode = try XCTUnwrap(index.sourceNode(for: sourceID))
        let node = try XCTUnwrap(index.children(of: sourceNode.id).first { $0.kind == .playlist })
        let scope = LibrarySearchScope.folder(node: node, index: index, title: { $0.displayName ?? "Folder" })
        XCTAssertEqual(scope.kind, .playlist)
        XCTAssertEqual(scope.title, "Road Trip")
        XCTAssertEqual(scope.detail, "Music Service")
        XCTAssertEqual(scope.songIDs, ["inside"])
        XCTAssertFalse(scope.includesSubfolders)
        let sourceScope = LibrarySearchScope.folder(
            node: sourceNode, index: index, title: { $0.displayName ?? "Folder" }
        )
        XCTAssertEqual(sourceScope.kind, .source)
        XCTAssertFalse(sourceScope.includesSubfolders)
    }

    private func search(_ songs: [Song]) -> [String] {
        LibrarySearchWorker.compute(query: "Track", songs: songs, albums: [],
                                    cache: LibrarySearchCache(), includeLyrics: false).songResults.map(\.song.id)
    }

    private func song(id: String, path: String = "/Music/track.flac", sourceID: String = "source") -> Song {
        Song(id: id, title: "Track", duration: 180, fileFormat: .flac, filePath: path, sourceID: sourceID)
    }
}
