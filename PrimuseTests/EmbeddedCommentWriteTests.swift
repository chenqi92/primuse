import AVFoundation
import XCTest
@testable import Primuse

/// 专辑简介写进每首歌的「注释」:写入后回读一致(由写入器自己的回读校验把关),
/// 曲名、专辑这些别的标签不受影响,删除也能删干净。
final class EmbeddedCommentWriteTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseEmbeddedCommentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFixture(fileExtension: String, settings: [String: Any]) throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).\(fileExtension)")
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames: AVAudioFrameCount = 22_050
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private func assertCommentRoundTrip(at url: URL) async throws {
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(
                tags: .init(
                    title: "Song", artist: "Artist", albumTitle: "Album",
                    genre: nil, year: nil, trackNumber: 1, discNumber: nil
                ),
                coverData: nil,
                lyrics: .keep
            ),
            to: url
        )
        let intro = "第一段介绍。\n第二段 & 更多。"
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .keep, comment: .set(intro)),
            to: url
        )
        var tags = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(tags.title, "Song")
        XCTAssertEqual(tags.albumTitle, "Album")
        XCTAssertEqual(tags.trackNumber, 1)

        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .keep, comment: .remove),
            to: url
        )
        tags = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(tags.title, "Song")
        XCTAssertEqual(tags.artist, "Artist")
    }

    /// Core Audio 现写的 M4A 没有 iTunes 标签块,先写曲名那一步在这种样本上本来就过不了回读,
    /// 所以这里只验注释本身,并确认写注释不改动其它标签。
    func testCommentRoundTripsInM4A() async throws {
        let url = try makeFixture(fileExtension: "m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        let before = try EmbeddedMetadataWriter.currentTags(at: url)
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .keep, comment: .set("专辑简介。")),
            to: url
        )
        XCTAssertEqual(try EmbeddedMetadataWriter.currentTags(at: url), before)
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .keep, comment: .remove),
            to: url
        )
        XCTAssertEqual(try EmbeddedMetadataWriter.currentTags(at: url), before)
    }

    func testCommentRoundTripsInFLAC() async throws {
        let url: URL
        do {
            url = try makeFixture(fileExtension: "flac", settings: [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
            ])
        } catch {
            throw XCTSkip("This simulator cannot encode FLAC fixtures: \(error)")
        }
        try await assertCommentRoundTrip(at: url)
    }
}
