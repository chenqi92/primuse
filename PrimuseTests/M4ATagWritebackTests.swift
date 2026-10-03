import AVFoundation
import XCTest
@testable import Primuse

/// M4A 标签写回:SFB 0.12.1 把专辑写成 `©ALB`、没封面时写一个空 `covr`(AVFoundation 读到它就停),
/// 以前改专辑名要靠 AVFoundation 整文件重导出,导出时只带上它读得到的标签,曲名、艺人会被冲掉。
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

    private func occurrences(of needle: Data, in data: Data) -> Int {
        var count = 0
        var searchRange = data.startIndex..<data.endIndex
        while let found = data.range(of: needle, in: searchRange) {
            count += 1
            searchRange = found.upperBound..<data.endIndex
        }
        return count
    }
}
