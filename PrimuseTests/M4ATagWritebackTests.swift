import AVFoundation
import PrimuseKit
import XCTest
@testable import Primuse

/// M4A 标签写回:SFB 0.12.1 把专辑写成 `©ALB`(那时保存的文件里还留着)、没封面时写一个空 `covr`
/// (AVFoundation 读到它就停),以前改专辑名要靠 AVFoundation 整文件重导出,导出时只带上它读得到的标签,
/// 曲名、艺人会被冲掉。
final class M4ATagWritebackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseM4ATagTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Core Audio 现写的 M4A:只有 iTunSMPB,没有曲名、专辑,也没有封面。
    private func makeFixture() throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).m4a")
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 22_050))
        buffer.frameLength = 22_050
        try file.write(from: buffer)
        return url
    }

    private func tags(title: String, album: String?) -> EmbeddedMetadataEdits.Tags {
        .init(title: title, artist: "Artist", albumTitle: album, genre: nil, year: nil, trackNumber: 1, discNumber: nil)
    }

    private func avFoundationValues(at url: URL) async throws -> [AVMetadataIdentifier: String] {
        var values: [AVMetadataIdentifier: String] = [:]
        for item in try await AVURLAsset(url: url).load(.metadata) {
            guard let identifier = item.identifier, let value = try await item.load(.stringValue) else { continue }
            values[identifier] = value
        }
        return values
    }

    func testScrapeWritesOnlySelectedTagsAndProtectsTheFileDuringFillAndOverwrite() async throws {
        let url = try makeFixture()
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            .init(tags: tags(title: "File title", album: "File album"), coverData: nil, lyrics: .keep), to: url)
        let path = "/" + url.lastPathComponent
        let connector = LocalFileSource(sourceID: "local", basePath: directory)
        var song = Song(id: "scrape", title: "Proposed title", albumTitle: "Proposed album", artistName: "Other artist",
                        duration: 1, fileFormat: .m4a, filePath: path, sourceID: "local")
        song.year = 2018
        let original = try await connector.embeddedMetadataSnapshot(for: path)
        song = original.applyingIdentity(to: song)
        var policy = EmbeddedAssetWritePolicy()
        policy.tagFields = [.album, .year]
        _ = try await connector.writeEmbeddedAssets(original: song, coverData: nil, lyrics: .keep, policy: policy)
        var written = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(written.year, 2018)
        XCTAssertEqual(written.albumTitle, "File album")
        XCTAssertEqual(written.title, "File title")
        XCTAssertEqual(written.artist, "Artist")

        policy.overwritesTags = [.album]
        do {
            _ = try await connector.writeEmbeddedAssets(original: song, coverData: nil, lyrics: .keep, policy: policy)
            XCTFail("The old file revision may not authorize a second write")
        } catch EmbeddedMetadataCoordinatedWritebackError.conflict {}
        let refreshed = try await connector.embeddedMetadataSnapshot(for: path)
        _ = try await connector.writeEmbeddedAssets(original: refreshed.applyingIdentity(to: song), coverData: nil,
                                                    lyrics: .keep, policy: policy)
        written = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(written.albumTitle, "Proposed album")
        XCTAssertEqual(written.year, 2018)
        XCTAssertEqual(written.artist, "Artist")
    }

    func testLocalLyricsEditorCapturesTheMovedFileAndRejectsAReplacementAfterOpening() async throws {
        let input = try makeFixture()
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            .init(tags: tags(title: "File title", album: "Album"), coverData: nil, lyrics: .set("Old words")), to: input)
        let path = "/" + input.lastPathComponent
        let first = LocalFileSource(sourceID: "local", basePath: directory)
        let initial = try await first.metadataWritebackState(for: path)
        let song = initial.applyingIdentity(to: Song(id: "local-song", title: "File title", albumTitle: "Album",
            artistName: "Artist", duration: 1, fileFormat: .m4a, filePath: path, sourceID: "local"))

        let moved = directory.appendingPathComponent("NewContainer", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let audio = moved.appendingPathComponent(input.lastPathComponent)
        try FileManager.default.copyItem(at: input, to: audio)
        let source = MusicSource(id: "local", name: "Music", type: .local, basePath: moved.path)
        let local = LocalFileSource(sourceID: source.id, basePath: moved)
        let manager = await SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in local })
        let migrated = try await local.metadataWritebackState(for: path)
        XCTAssertEqual(try Data(contentsOf: audio), try Data(contentsOf: input))
        XCTAssertFalse(migrated.matchesScannedSong(song, revisionFoldsSidecarFingerprints: true))
        let captured = await manager.localLyricsEditingIdentity(for: song)
        let opened = try XCTUnwrap(captured)
        XCTAssertTrue(migrated.matchesScannedSong(opened))
        _ = try await local.writeEmbeddedAssets(original: opened, coverData: nil, lyrics: .set("Saved words"), policy: .replace)
        let saved = await FileMetadataReader.read(from: audio)
        XCTAssertEqual(saved.lyricsText, "Saved words")

        let next = await manager.localLyricsEditingIdentity(for: song)
        let secondOpening = try XCTUnwrap(next)
        var external = try Data(contentsOf: audio)
        let range = try XCTUnwrap(external.range(of: Data("File title".utf8)))
        external.replaceSubrange(range, with: Data("New singer".utf8))
        try external.write(to: audio, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(secondOpening.lastModified)],
                                              ofItemAtPath: audio.path)
        do {
            _ = try await local.writeEmbeddedAssets(original: secondOpening, coverData: nil, lyrics: .set("Stale words"), policy: .replace)
            XCTFail("A replacement after the edit began must keep its content")
        } catch EmbeddedMetadataCoordinatedWritebackError.conflict {}
        XCTAssertEqual(try Data(contentsOf: audio), external)
    }

    func testAlbumArtistMergeWritesBothFieldsAndKeepsUnchangedTags() async throws {
        let url = try makeFixture()
        var before = tags(title: "Song", album: "Album")
        before.albumArtist = "English B"
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            .init(tags: before, coverData: nil, lyrics: .keep), to: url)
        let after = EmbeddedMetadataEdits.Tags(title: "Ignored", artist: "中文A; Guest", albumTitle: "Ignored",
            genre: nil, year: nil, trackNumber: nil, discNumber: nil, albumArtist: "中文A")
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            .init(tags: after, coverData: nil, lyrics: .keep, changedFields: [.artist, .albumArtist]), to: url)
        let written = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(written.artist, "中文A; Guest")
        XCTAssertEqual(written.albumArtist, "中文A")
        XCTAssertEqual(written.title, "Song")
        XCTAssertEqual(written.albumTitle, "Album")
        let read = await FileMetadataReader.read(from: url)
        XCTAssertEqual(read.albumArtist, "中文A")
    }

    func testAllTagsSurviveAndStayReadableByAVFoundation() async throws {
        let url = try makeFixture()
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: tags(title: "Song", album: "Album"), coverData: nil, lyrics: .keep),
            to: url
        )
        let sfb = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(sfb.title, "Song")
        XCTAssertEqual(sfb.artist, "Artist")
        XCTAssertEqual(sfb.albumTitle, "Album")

        let av = try await avFoundationValues(at: url)
        XCTAssertEqual(av[.iTunesMetadataSongName], "Song")
        XCTAssertEqual(av[.iTunesMetadataArtist], "Artist")
        XCTAssertEqual(av[.iTunesMetadataAlbum], "Album")
    }

    func testChangingOnlyTheAlbumKeepsTheTitleAndLeavesNoUppercaseAlbum() async throws {
        let url = try makeFixture()
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: tags(title: "Song", album: "Old"), coverData: nil, lyrics: .keep),
            to: url
        )
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(
                tags: tags(title: "Song", album: "New"),
                coverData: nil,
                lyrics: .keep,
                changedFields: [.album]
            ),
            to: url
        )
        let sfb = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(sfb.title, "Song")
        XCTAssertEqual(sfb.albumTitle, "New")
        let av = try await avFoundationValues(at: url)
        XCTAssertEqual(av[.iTunesMetadataAlbum], "New")
        XCTAssertEqual(av[.iTunesMetadataSongName], "Song")

        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data([0xA9, 0x41, 0x4C, 0x42])), "©ALB should be renamed to ©alb")
        XCTAssertEqual(occurrences(of: Data([0xA9, 0x61, 0x6C, 0x62]), in: data), 1, "only the new album item stays ©alb")
    }

    /// A file saved while SFB wrote the album as `©ALB`: the album sits only
    /// under the upper-case name.
    private func makeLegacyUppercaseAlbumFixture(album: String) async throws -> URL {
        let url = try makeFixture()
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: tags(title: "Song", album: album), coverData: nil, lyrics: .keep),
            to: url
        )
        var data = try Data(contentsOf: url)
        let lower = Data([0xA9, 0x61, 0x6C, 0x62])
        let range = try XCTUnwrap(data.range(of: lower))
        data.replaceSubrange(range, with: Data([0xA9, 0x41, 0x4C, 0x42]))
        try data.write(to: url)
        return url
    }

    func testEditedAlbumWinsOverALeftoverUppercaseAlbum() async throws {
        let url = try await makeLegacyUppercaseAlbumFixture(album: "Stale")
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(
                tags: tags(title: "Song", album: "Edited"),
                coverData: nil,
                lyrics: .keep,
                changedFields: [.album]
            ),
            to: url
        )
        XCTAssertEqual(try EmbeddedMetadataWriter.currentTags(at: url).albumTitle, "Edited")
        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data([0xA9, 0x41, 0x4C, 0x42])), "the stale ©ALB is dropped")
        XCTAssertNil(data.range(of: Data("Stale".utf8)))
    }

    func testUntouchedAlbumRecoversALeftoverUppercaseAlbum() async throws {
        let url = try await makeLegacyUppercaseAlbumFixture(album: "Intended")
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(
                tags: tags(title: "Renamed", album: nil),
                coverData: nil,
                lyrics: .keep,
                changedFields: [.title]
            ),
            to: url
        )
        let sfb = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(sfb.title, "Renamed")
        XCTAssertEqual(sfb.albumTitle, "Intended")
        XCTAssertNil(try Data(contentsOf: url).range(of: Data([0xA9, 0x41, 0x4C, 0x42])))
    }

    private func occurrences(of needle: Data, in data: Data) -> Int {
        var count = 0
        var searchRange = data.startIndex..<data.endIndex
        while let found = data.range(of: needle, in: searchRange) {
            count += 1
            searchRange = found.upperBound..<data.endIndex
        }
        return count
    }

    @MainActor
    func testScannedMultiVersionMusicRemainsPlayableAfterClearingLyrics() async throws {
        let files = FileManager.default
        let seed = files.temporaryDirectory.appendingPathComponent("PrimuseMediaVersionsSeed")
        try XCTSkipUnless(files.fileExists(atPath: seed.appendingPathComponent("Replacement.png").path),
                          "Requires the multi-version music acceptance fixture")
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try files.copyItem(at: seed, to: music)
        let audio = music.appendingPathComponent("Glass Harbor Versions.m4a")
        let original = try Data(contentsOf: audio)
        let originalPictures = try EmbeddedPictureArchive.pictures(in: original, format: .m4a)
        let embedded = try EmbeddedLyricsArchive.entries(in: original, fileExtension: "m4a")
        XCTAssertEqual(originalPictures.count, 3)
        XCTAssertEqual(embedded.count, 2)
        let tagOnly = EmbeddedMetadataEdits(tags: tags(title: "Glass Harbor Review", album: nil),
                                           coverData: nil, lyrics: .keep, changedFields: [.title])
        _ = try await EmbeddedMetadataWriter.writeAndVerify(tagOnly, to: audio)
        let renamed = try Data(contentsOf: audio)
        XCTAssertEqual(try EmbeddedPictureArchive.pictures(in: renamed, format: .m4a), originalPictures)
        XCTAssertEqual(try EmbeddedLyricsArchive.entries(in: renamed, fileExtension: "m4a"), embedded)
        let middle = try XCTUnwrap(originalPictures.dropFirst().first)
        let source = MusicSource(id: UUID().uuidString, name: "Versions", type: .local, basePath: music.path)
        let store = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("Sources"))
        try store.addDurably(source)
        let connector = LocalFileSource(sourceID: source.id, basePath: music)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("Library"))

        func scan() async throws -> Song {
            for try await item in try await connector.scanSongs(from: "/") where item.song.fileFormat == .m4a {
                return item.song
            }
            throw NSError(domain: "LyricsVersionAcceptance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Music scan produced no M4A"])
        }
        func versions(_ song: Song) async throws -> [LyricsDocumentCatalog.Entry] {
            switch await LyricsDocumentCatalog.load(for: song, sourceManager: manager, sourcesStore: store) {
            case .documents(let documents):
                XCTAssertNil(documents.sourceError)
                return documents.entries
            default: throw NSError(domain: "LyricsVersionAcceptance", code: 1)
            }
        }

        let firstScan = try await scan()
        let replacement = try Data(contentsOf: music.appendingPathComponent("Replacement.png"))
        let song = try await manager.writeEmbeddedPictures([middle.id: replacement], for: firstScan)
        let changed = try Data(contentsOf: audio)
        var expectedPictures = originalPictures.map(\.data)
        expectedPictures[1] = replacement
        XCTAssertEqual(try EmbeddedPictureArchive.pictures(in: changed, format: .m4a).map(\.data), expectedPictures)
        XCTAssertEqual(try EmbeddedLyricsArchive.entries(in: changed, fileExtension: "m4a"), embedded)
        let all = try await versions(song)
        XCTAssertEqual(all.count, 4)
        let selected = try XCTUnwrap(all.first { $0.name.hasSuffix(".en.lrc") })
        try await LyricsDocumentCatalog.activate(selected, for: song, sourceManager: manager)
        let selectedLines = await LyricsLoader.load(for: song, sourceManager: manager, allowsAutomaticOnlineLyrics: false)
        XCTAssertEqual(selectedLines.first?.text, "A copper bird unfolds")
        let single = try XCTUnwrap(all.first(where: \.isEmbedded))
        try await LyricsDocumentCatalog.remove([single], for: song, sourceManager: manager, sourcesStore: store, library: library)
        let updated = try await scan()
        let remaining = try await versions(updated)
        XCTAssertEqual(remaining.count, 3)
        try await LyricsDocumentCatalog.remove(remaining, for: updated, sourceManager: manager, removeAll: true,
                                              sourcesStore: store, library: library)
        let rescanned = try await scan()
        XCTAssertEqual(rescanned.id, firstScan.id)
        let reopened = try await versions(rescanned)
        XCTAssertTrue(reopened.isEmpty)
        let written = try Data(contentsOf: audio)
        XCTAssertTrue(try EmbeddedLyricsArchive.entries(in: written, fileExtension: "m4a").isEmpty)
        XCTAssertEqual(try EmbeddedPictureArchive.pictures(in: written, format: .m4a).map(\.data), expectedPictures)
        for language in ["zh", "en"] {
            XCTAssertFalse(files.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension(language + ".lrc").path))
        }
        let player = try AVAudioPlayer(contentsOf: audio)
        player.volume = 0.01
        defer { player.stop() }
        XCTAssertTrue(player.play())
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.currentTime, 0.2)
        let onPlayback = await LyricsLoader.load(for: rescanned, sourceManager: manager)
        XCTAssertTrue(onPlayback.isEmpty)
    }
}
