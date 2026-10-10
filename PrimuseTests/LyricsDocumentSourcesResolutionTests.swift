import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// The lyric sources page end to end on a path-addressed source: which file
/// each request resolves to, that a picked read-only file never gets its
/// replacement written over another source, and that the raw editor's save
/// rewrites exactly one file, byte for byte, only while it is unchanged.
final class LyricsDocumentSourcesResolutionTests: XCTestCase {
    private let lrc = Data("[00:01.00]From the LRC\n".utf8)
    private let ttml = Data("""
    <tt xmlns="http://www.w3.org/ns/ttml"><body><div>\
    <p begin="00:01.000" end="00:02.000"><span begin="00:01.000" end="00:02.000">TTML</span></p>\
    </div></body></tt>
    """.utf8)
    private let yrc = Data("[1000,1000](1000,1000,0)YRC\n".utf8)

    private func song() -> Song {
        Song(id: "song-\(UUID().uuidString)", title: "Night Changes", fileFormat: .flac,
             filePath: "/Music/Night Changes.flac", sourceID: "source", fileSize: 1)
    }

    private func connector(_ files: [String: Data]) -> LyricsDocumentFixtureConnector {
        var all = files
        all["Night Changes.flac"] = Data([0])
        all["cover.jpg"] = Data([1])
        return LyricsDocumentFixtureConnector(directory: "/Music", files: all)
    }

    func testRequestsResolveTheListenersChoice() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.ttml": ttml, "Night Changes.yrc": yrc])

        // Two writable documents and no pick: a save cannot tell which one is meant.
        do {
            _ = try await LyricsSidecarTargetPolicy.resolve(for: song, using: fixture, request: .current(pinned: nil))
            XCTFail("expected the two writable documents to stay ambiguous")
        } catch EmbeddedMetadataWritebackSourceError.conflict {
        }

        let catalog = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .catalog(pinned: nil)
        )
        XCTAssertEqual(catalog.fileName, "Night Changes.lrc")
        XCTAssertEqual(catalog.documents.map(\.name),
                       ["Night Changes.lrc", "Night Changes.ttml", "Night Changes.yrc"])

        let pinned = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .current(pinned: "Night Changes.ttml")
        )
        XCTAssertEqual(pinned.fileName, "Night Changes.ttml")
        XCTAssertEqual(pinned.existingPath, "/Music/Night Changes.ttml")
        XCTAssertEqual(pinned.existingSize, Int64(ttml.count))

        let named = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .named("Night Changes.yrc")
        )
        XCTAssertTrue(named.exists)
        XCTAssertEqual(named.fileName, "Night Changes.yrc")

        let missing = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .named("Night Changes.qrc")
        )
        XCTAssertFalse(missing.exists)
    }

    func testSeveralFilesWithoutAPickReadTheFinerTimedOne() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.yrc": yrc])

        // 没人选过: 逐字的 .yrc 胜过逐行的 .lrc, 播放、来源页与保存都按它。
        await LyricsLoader.refreshAutomaticDocumentPick(for: song, connector: fixture)
        XCTAssertEqual(
            LyricsDocumentPinStore.shared.effectiveFileName(forSongID: song.id),
            "Night Changes.yrc"
        )
        XCTAssertNil(LyricsDocumentPinStore.shared.pinnedFileName(forSongID: song.id))
        let current = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .current(for: song)
        )
        XCTAssertEqual(current.fileName, "Night Changes.yrc")

        // 用户在来源页选了别的, 以用户的为准。
        LyricsDocumentPinStore.shared.pin("Night Changes.lrc", forSongID: song.id)
        defer { LyricsDocumentPinStore.shared.clearPin(forSongID: song.id) }
        let picked = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .current(for: song)
        )
        XCTAssertEqual(picked.fileName, "Night Changes.lrc")
    }

    func testPickedReadOnlyFileNeverOverwritesAnotherSource() async throws {
        let song = song()
        let fixture = connector(["Night Changes.ttml": ttml, "Night Changes.yrc": yrc])
        LyricsDocumentPinStore.shared.pin("Night Changes.yrc", forSongID: song.id)
        defer { LyricsDocumentPinStore.shared.clearPin(forSongID: song.id) }

        do {
            _ = try await SidecarWriteService.shared.preflightLyricsWrite(for: song, using: fixture)
            XCTFail("expected the replacement name to collide with the existing TTML")
        } catch let collision as LyricsSidecarReplacementCollision {
            XCTAssertEqual(collision.documentName, "Night Changes.yrc")
            XCTAssertEqual(collision.replacementName, "Night Changes.ttml")
        }
        let written = await fixture.writtenPaths
        XCTAssertTrue(written.isEmpty)
    }

    func testPickedReadOnlyFileWithoutSiblingStillSavesBesideIt() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.yrc": yrc])
        LyricsDocumentPinStore.shared.pin("Night Changes.yrc", forSongID: song.id)
        defer { LyricsDocumentPinStore.shared.clearPin(forSongID: song.id) }

        // `.yrc` is saved as `.ttml`; the `.lrc` is another name and stays out of it.
        let preflight = try await SidecarWriteService.shared.preflightLyricsWrite(for: song, using: fixture)
        XCTAssertEqual(preflight.fileName, "Night Changes.ttml")
        XCTAssertFalse(preflight.replacesExistingFile)
        XCTAssertTrue(preflight.hasLyricsDocument)
    }

    func testRawSaveRewritesOnlyThatFileByteForByte() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.yrc": yrc])
        let edited = Data("[1000,1500](1000,1500,0)Edited\n".utf8)

        let target = try await SidecarWriteService.shared.lyricsDocumentTarget(
            named: "Night Changes.yrc", for: song, using: fixture
        )
        let receipt = try await SidecarWriteService.shared.writeLyricsDocument(
            edited, to: target, expecting: yrc, using: fixture
        )
        XCTAssertEqual(receipt.readback, edited)
        let files = await fixture.files
        XCTAssertEqual(files["Night Changes.yrc"], edited)
        XCTAssertEqual(files["Night Changes.lrc"], lrc)
        let written = await fixture.writtenPaths
        XCTAssertEqual(written, ["/Music/Night Changes.yrc"])
    }

    func testRawSaveRefusesAFileChangedSinceItWasOpened() async throws {
        let song = song()
        let fixture = connector(["Night Changes.ttml": ttml])
        let target = try await SidecarWriteService.shared.lyricsDocumentTarget(
            named: "Night Changes.ttml", for: song, using: fixture
        )
        do {
            _ = try await SidecarWriteService.shared.writeLyricsDocument(
                Data("<tt/>".utf8), to: target, expecting: Data("stale".utf8), using: fixture
            )
            XCTFail("expected a stale baseline to be refused")
        } catch SidecarWriteService.LyricsDocumentWriteError.changedElsewhere(let name) {
            XCTAssertEqual(name, "Night Changes.ttml")
        }
        let written = await fixture.writtenPaths
        XCTAssertTrue(written.isEmpty)
    }

    func testRawSaveOfAVanishedFileIsRefused() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc])
        do {
            _ = try await SidecarWriteService.shared.lyricsDocumentTarget(
                named: "Night Changes.ttml", for: song, using: fixture
            )
            XCTFail("expected a missing file to be refused")
        } catch SidecarWriteService.LyricsDocumentWriteError.documentMissing(let name) {
            XCTAssertEqual(name, "Night Changes.ttml")
        }
    }
}

/// A writable folder held in memory.
private actor LyricsDocumentFixtureConnector: MusicSourceConnector {
    let sourceID = "source"
    let directory: String
    private(set) var files: [String: Data]
    private(set) var writtenPaths: [String] = []

    nonisolated var supportsSidecarWriting: Bool { true }

    init(directory: String, files: [String: Data]) {
        self.directory = directory
        self.files = files
    }

    func connect() async throws { }
    func disconnect() async { }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard path == directory else { throw SourceError.pathNotFound(path) }
        return files.keys.sorted().map { name in
            RemoteFileItem(
                name: name,
                path: (directory as NSString).appendingPathComponent(name),
                isDirectory: false,
                size: Int64(files[name]?.count ?? 0),
                modifiedDate: nil
            )
        }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let data = files[(path as NSString).lastPathComponent] else {
            throw SourceError.fileNotFound(path)
        }
        let start = Int(max(0, offset))
        let end = min(data.count, start + Int(max(0, length)))
        return start < end ? data.subdata(in: start..<end) : Data()
    }

    func writeFile(data: Data, to path: String) async throws {
        writtenPaths.append(path)
        files[(path as NSString).lastPathComponent] = data
    }

    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}
