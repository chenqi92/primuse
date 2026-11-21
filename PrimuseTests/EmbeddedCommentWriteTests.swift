import AVFoundation
import PrimuseKit
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

    func testCommentRoundTripsInM4A() async throws {
        let url = try makeFixture(fileExtension: "m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        try await assertCommentRoundTrip(at: url)
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

/// 文件里有好几份原文时，保存只改正在用的那一份所在的字段，读回来选中的是新写的那份；
/// 「删除此版本」只删那一个字段。
final class EmbeddedLyricsFieldWriteTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseEmbeddedLyricsFieldTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFLAC() throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).flac")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatFLAC,
                    AVSampleRateKey: 44_100.0,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let frames: AVAudioFrameCount = 22_050
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            try file.write(from: buffer)
        } catch {
            throw XCTSkip("This simulator cannot encode FLAC fixtures: \(error)")
        }
        return url
    }

    private func littleEndian(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    /// 在 Vorbis comment 块末尾追加一个字段，模拟别的软件写进去的第二份原文。
    private func appendingComment(_ key: String, _ value: String, to data: Data) throws -> Data {
        var cursor = 4
        while cursor + 4 <= data.count {
            let header = data[cursor]
            let length = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            let payloadStart = cursor + 4
            let payloadEnd = payloadStart + length
            if header & 0x7F == 4 {
                var payload = data.subdata(in: payloadStart..<payloadEnd)
                let vendorLength = Int(payload[0]) | Int(payload[1]) << 8
                    | Int(payload[2]) << 16 | Int(payload[3]) << 24
                let countOffset = 4 + vendorLength
                let count = Int(payload[countOffset]) | Int(payload[countOffset + 1]) << 8
                    | Int(payload[countOffset + 2]) << 16 | Int(payload[countOffset + 3]) << 24
                payload.replaceSubrange(countOffset..<(countOffset + 4), with: littleEndian(count + 1))
                let item = Data("\(key)=\(value)".utf8)
                payload.append(littleEndian(item.count))
                payload.append(item)
                var result = data.subdata(in: 0..<cursor)
                result.append(contentsOf: [
                    header,
                    UInt8((payload.count >> 16) & 0xFF),
                    UInt8((payload.count >> 8) & 0xFF),
                    UInt8(payload.count & 0xFF),
                ])
                result.append(payload)
                result.append(data.subdata(in: payloadEnd..<data.count))
                return result
            }
            if header & 0x80 != 0 { break }
            cursor = payloadEnd
        }
        throw XCTSkip("The FLAC fixture has no Vorbis comment block")
    }

    private func write(_ operation: EmbeddedLyricsFieldEditor.Operation, to url: URL) async throws -> EmbeddedLyricsFieldReport? {
        let request = EmbeddedLyricsFieldRequest(operation)
        defer { _ = EmbeddedLyricsFieldReports.take(request.id) }
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .field(request)),
            to: url
        )
        return EmbeddedLyricsFieldReports.take(request.id)
    }

    private func flacRegion(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var offset = 4
        while offset + 4 <= data.count {
            let header = data[offset]
            offset += 4 + (Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3]))
            if header & 0x80 != 0 { break }
        }
        return data.subdata(in: 0..<offset)
    }

    func testReplacingTheVersionInUseKeepsTheOtherFLACOriginal() async throws {
        let url = try makeFLAC()
        let other = "[00:01.00]Copper harbor\n[00:02.00]Copper bell"
        let inUse = "[00:01.00]Silver harbor\n[00:02.00]Silver bell"
        let edited = "[00:01.00]Silver harbor, edited\n[00:02.00]Silver bell\n[00:03.00]Silver coda"
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .set(other)),
            to: url
        )
        let seeded = try appendingComment("SYNCEDLYRICS", inUse, to: Data(contentsOf: url))
        try seeded.write(to: url)
        let audioBefore = try Data(contentsOf: url).subdata(in: try flacRegion(of: url).count..<seeded.count)
        XCTAssertEqual(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: try flacRegion(of: url)), [other, inUse])

        let report = try await write(.replace(text: edited, anchor: inUse), to: url)
        XCTAssertEqual(report, .done(.replacedField, remainingOriginals: false))
        XCTAssertEqual(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: try flacRegion(of: url)), [edited, other])
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written.subdata(in: try flacRegion(of: url).count..<written.count), audioBefore)
        let metadata = await FileMetadataReader.read(from: url)
        XCTAssertEqual(metadata.lyricsText, edited)
        XCTAssertFalse(metadata.lyricsVariants.contains { $0.text == inUse })

        let removed = try await write(.removeOne(other), to: url)
        XCTAssertEqual(removed, .done(.removedField, remainingOriginals: false))
        XCTAssertEqual(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: try flacRegion(of: url)), [edited])

        let cleared = try await write(.removeAllOriginals, to: url)
        XCTAssertEqual(cleared, .done(.removedOriginals(1), remainingOriginals: false))
        XCTAssertEqual(EmbeddedLyricsFieldEditor.flacOriginalLyrics(in: try flacRegion(of: url)), [])
    }

    func testAmbiguousOrMissingFieldsLeaveTheFileAlone() async throws {
        let url = try makeFLAC()
        _ = try await EmbeddedMetadataWriter.writeAndVerify(
            EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .set("[00:01.00]One")),
            to: url
        )
        try appendingComment("SYNCEDLYRICS", "[00:01.00]Two", to: Data(contentsOf: url)).write(to: url)
        let before = try Data(contentsOf: url)
        for operation in [
            EmbeddedLyricsFieldEditor.Operation.removeOne("[00:01.00]Somewhere else"),
            .removeOne(nil),
            .replace(text: "[00:01.00]Three", anchor: nil),
            .replace(text: "[00:01.00]Three", anchor: "[00:01.000]One"),
        ] {
            let request = EmbeddedLyricsFieldRequest(operation)
            do {
                _ = try await EmbeddedMetadataWriter.writeAndVerify(
                    EmbeddedMetadataEdits(tags: nil, coverData: nil, lyrics: .field(request)),
                    to: url
                )
                XCTFail("An edit that cannot locate its field must fail: \(operation)")
            } catch {}
            XCTAssertEqual(EmbeddedLyricsFieldReports.take(request.id), .notLocated)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    /// 合成一个最小的 MP3：ID3v2.4 标签 + 几十帧静音帧。
    private func makeMP3(lyricsFrames: [(language: String, descriptor: String, text: String)]) throws -> URL {
        func synchsafe(_ value: Int) -> Data {
            Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
                  UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
        }
        func frame(_ id: String, _ payload: Data) -> Data {
            Data(id.utf8) + synchsafe(payload.count) + Data([0, 0]) + payload
        }
        var body = frame("TIT2", Data([0x03]) + Data("Fixture".utf8))
        for lyrics in lyricsFrames {
            body += frame("USLT", Data([0x03]) + Data(lyrics.language.utf8) + Data(lyrics.descriptor.utf8)
                          + Data([0x00]) + Data(lyrics.text.utf8))
        }
        body += Data(count: 256)
        var file = Data("ID3".utf8) + Data([4, 0, 0]) + synchsafe(body.count) + body
        let audioFrame = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        for _ in 0..<64 { file += audioFrame }
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).mp3")
        try file.write(to: url)
        do {
            _ = try EmbeddedMetadataWriter.currentTags(at: url)
        } catch {
            throw XCTSkip("The tag library cannot open the synthetic MP3 fixture: \(error)")
        }
        return url
    }

    func testMP3ReplaceAndRemoveTouchOnlyTheMatchingUSLTFrame() async throws {
        let url = try makeMP3(lyricsFrames: [
            ("eng", "", "[00:01.00]Morning tide"),
            ("eng", "alt", "[00:01.00]Evening tide"),
            ("zho", "translation", "[00:01.00]晚潮"),
        ])
        let report = try await write(
            .replace(text: "[00:01.00]Evening tide, edited", anchor: "[00:01.00]Evening tide"),
            to: url
        )
        XCTAssertEqual(report, .done(.replacedField, remainingOriginals: false))
        var bodies = try XCTUnwrap(ID3LyricsFramePreservation.lyricsFrameBodies(in: Data(contentsOf: url)))
        XCTAssertEqual(bodies.compactMap(EmbeddedLyricsFieldEditor.usltText),
                       ["[00:01.00]Evening tide, edited", "[00:01.00]Morning tide", "[00:01.00]晚潮"])
        let tags = try EmbeddedMetadataWriter.currentTags(at: url)
        XCTAssertEqual(tags.title, "Fixture")

        let removed = try await write(.removeOne("[00:01.00]Morning tide"), to: url)
        XCTAssertEqual(removed, .done(.removedField, remainingOriginals: false))
        bodies = try XCTUnwrap(ID3LyricsFramePreservation.lyricsFrameBodies(in: Data(contentsOf: url)))
        XCTAssertEqual(bodies.compactMap(EmbeddedLyricsFieldEditor.usltText),
                       ["[00:01.00]Evening tide, edited", "[00:01.00]晚潮"])

        let cleared = try await write(.removeAllOriginals, to: url)
        XCTAssertEqual(cleared, .done(.removedOriginals(1), remainingOriginals: false))
        bodies = try XCTUnwrap(ID3LyricsFramePreservation.lyricsFrameBodies(in: Data(contentsOf: url)))
        XCTAssertEqual(bodies.compactMap(EmbeddedLyricsFieldEditor.usltText), ["[00:01.00]晚潮"])
    }
}
