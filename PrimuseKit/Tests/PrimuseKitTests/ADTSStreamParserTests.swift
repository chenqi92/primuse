import Foundation
import Testing
@testable import PrimuseKit

@Suite("Raw ADTS AAC frame walk")
struct ADTSStreamParserTests {
    /// 一帧 ADTS: 7 字节帧头(不带 CRC)+ 不含 0xFF 的载荷。
    private func frame(
        length: Int,
        sampleRateIndex: Int = 4,
        channels: Int = 2,
        objectType: Int = 2,
        rawBlocks: Int = 1,
        crc: Bool = false
    ) -> Data {
        var bytes = [UInt8](repeating: 0x21, count: length)
        bytes[0] = 0xFF
        bytes[1] = 0xF0 | (crc ? 0x00 : 0x01)
        bytes[2] = UInt8((objectType - 1) << 6) | UInt8(sampleRateIndex << 2) | UInt8((channels >> 2) & 0x01)
        bytes[3] = UInt8((channels & 0x03) << 6) | UInt8((length >> 11) & 0x03)
        bytes[4] = UInt8((length >> 3) & 0xFF)
        bytes[5] = UInt8((length & 0x07) << 5) | 0x1F
        bytes[6] = 0xFC | UInt8(rawBlocks - 1)
        return Data(bytes)
    }

    private func stream(_ lengths: [Int], sampleRateIndex: Int = 4, rawBlocks: Int = 1) -> Data {
        var data = Data()
        for length in lengths {
            data.append(frame(length: length, sampleRateIndex: sampleRateIndex, rawBlocks: rawBlocks))
        }
        return data
    }

    /// 帧长在 300…520 之间来回变, 像真实 AAC 的比特池。
    private func variableLengths(_ count: Int) -> [Int] {
        (0..<count).map { 300 + ($0 * 37) % 221 }
    }

    private func id3(size: Int) -> Data {
        var header = Data("ID3".utf8) + Data([3, 0, 0])
        header.append(contentsOf: [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
                                   UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
        return header + Data(repeating: 0, count: size)
    }

    private func seconds(blocks: Int, rate: Int) -> Double {
        Double(blocks * 1_024) / Double(rate)
    }

    @Test func constantFrameLengthsAreCountedExactly() throws {
        let data = stream(Array(repeating: 400, count: 100))
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(info.firstFrameOffset == 0)
        #expect(info.frameCount == 100)
        #expect(info.rawDataBlockCount == 100)
        #expect(info.frameByteCount == 40_000)
        #expect(info.endOffset == 40_000)
        #expect(info.sampleRate == 44_100)
        #expect(info.channelConfiguration == 2)
        #expect(info.audioObjectType == 2)
        #expect(info.skippedByteCount == 0)
        #expect(abs(info.duration - seconds(blocks: 100, rate: 44_100)) < 1e-9)
    }

    @Test func variableFrameLengthsAreCountedExactly() throws {
        let lengths = variableLengths(777)
        let info = try #require(ADTSStreamParser.parse(stream(lengths)))
        #expect(info.frameCount == 777)
        #expect(info.frameByteCount == lengths.reduce(0, +))
        #expect(abs(info.duration - seconds(blocks: 777, rate: 44_100)) < 1e-9)
    }

    /// 回归: QA 里独立解码 12.028 秒(518 帧)的那首, 原来整条读标签链路报 10.983 秒。
    @Test func qaFixtureDurationMatchesIndependentDecode() throws {
        let data = stream(variableLengths(518))
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(abs(info.duration - 12.027_936_5) < 0.000_1)
    }

    @Test func leadingID3TagIsSkipped() throws {
        let data = id3(size: 1_000) + stream(Array(repeating: 400, count: 10))
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(info.firstFrameOffset == 1_010)
        #expect(info.frameCount == 10)
        // 标签比手里的字节还长: 找不到音频。
        #expect(ADTSStreamParser.parse(Data(data.prefix(800))) == nil)
    }

    @Test func truncatedFinalFrameIsNotCounted() throws {
        var data = stream(Array(repeating: 400, count: 20))
        data.append(frame(length: 400).prefix(150))
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(info.frameCount == 20)
        #expect(info.endOffset == 8_000)
    }

    @Test func garbageBetweenFramesIsSkippedAndTheWalkResynchronizes() throws {
        var garbage = Data(repeating: 0x00, count: 1_234)
        // 一个看着像帧头、但 128 字节后没有下一帧印证的假同步字。
        garbage.replaceSubrange(100..<107, with: [0xFF, 0xF1, 0x50, 0x80, 0x10, 0x1F, 0xFC])
        var data = stream(Array(repeating: 400, count: 10))
        data.append(garbage)
        data.append(stream(Array(repeating: 410, count: 15)))
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(info.frameCount == 25)
        #expect(info.skippedByteCount == 1_234)
        #expect(abs(info.duration - seconds(blocks: 25, rate: 44_100)) < 1e-9)
    }

    @Test func trailingTagEndsTheWalk() throws {
        var data = stream(Array(repeating: 400, count: 12))
        data.append(Data("TAG".utf8) + Data(repeating: 0x20, count: 125))
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(info.frameCount == 12)
        #expect(info.endOffset == 4_800)
    }

    @Test func multipleRawDataBlocksPerFrameMultiplyTheSampleCount() throws {
        let data = stream(Array(repeating: 1_500, count: 30), rawBlocks: 4)
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(info.frameCount == 30)
        #expect(info.rawDataBlockCount == 120)
        #expect(abs(info.duration - seconds(blocks: 120, rate: 44_100)) < 1e-9)
    }

    @Test func sampleRateTableCoversLowAndHighRates() throws {
        let eight = try #require(ADTSStreamParser.parse(stream(Array(repeating: 200, count: 40), sampleRateIndex: 11)))
        #expect(eight.sampleRate == 8_000)
        #expect(abs(eight.duration - seconds(blocks: 40, rate: 8_000)) < 1e-9)
        let fortyEight = try #require(ADTSStreamParser.parse(stream(Array(repeating: 600, count: 40), sampleRateIndex: 3)))
        #expect(fortyEight.sampleRate == 48_000)
        #expect(abs(fortyEight.duration - seconds(blocks: 40, rate: 48_000)) < 1e-9)
    }

    /// 隐式 SBR 的 HE-AAC: ADTS 头写的是核心采样率, 每块 1024 个核心样本 = 2048 个输出样本,
    /// 秒数一样; 采样率与 M4A 那边一样报核心的那一档。
    @Test func implicitSBRReportsTheCoreRateWithTheSameSeconds() throws {
        let info = try #require(ADTSStreamParser.parse(stream(Array(repeating: 250, count: 75), sampleRateIndex: 6)))
        #expect(info.sampleRate == 24_000)
        #expect(abs(info.duration - Double(75 * 2_048) / 48_000) < 1e-9)
    }

    @Test func crcProtectedFramesAreAccepted() throws {
        var data = Data()
        for _ in 0..<8 { data.append(frame(length: 300, crc: true)) }
        let info = try #require(ADTSStreamParser.parse(data))
        #expect(info.frameCount == 8)
    }

    @Test func otherContentIsNotTakenForADTS() {
        // 一个孤零零的同步字, 后面接的不是帧。
        var lonely = Data(repeating: 0x11, count: 64) + frame(length: 400).prefix(7)
        lonely.append(Data(repeating: 0x22, count: 4_000))
        #expect(ADTSStreamParser.parse(lonely) == nil)
        // MPEG Layer III 帧头(layer 位不是 0)。
        var mp3 = Data()
        for _ in 0..<5 { mp3.append(Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)) }
        #expect(ADTSStreamParser.parse(mp3) == nil)
        #expect(ADTSStreamParser.parse(Data()) == nil)
    }

    @Test func chunkedFileWalkMatchesTheInMemoryWalk() throws {
        var data = id3(size: 3_000)
        data.append(stream(variableLengths(1_200)))
        data.append(Data(repeating: 0x00, count: 900))
        data.append(stream(variableLengths(400)))
        let expected = try #require(ADTSStreamParser.parse(data))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adts-walk-\(UUID().uuidString).aac")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // 块长按下限 128 KB 切, 帧会跨块。
        let chunked = try #require(ADTSStreamParser.parseFile(at: url, chunkByteCount: 1))
        #expect(chunked == expected)
        #expect(chunked.frameCount == 1_600)
        #expect(chunked.skippedByteCount == 900)
    }

    @Test func asyncRangeWalkMatchesTheInMemoryWalk() async throws {
        let data = stream(variableLengths(1_500))
        let expected = try #require(ADTSStreamParser.parse(data))
        let walked = try await ADTSStreamParser.parse(byteCount: data.count, chunkByteCount: 0) { offset, length in
            Data(data[offset..<min(data.count, offset + length)])
        }
        #expect(walked == expected)
    }

    @Test func headOnlyReadsEstimateFromMeanFrameLength() throws {
        let data = stream(variableLengths(2_000))
        let exact = try #require(ADTSStreamParser.parse(data)).duration
        let head = Data(data.prefix(256 * 1_024))
        let estimate = try #require(ADTSStreamParser.duration(head: head, fileSize: Int64(data.count)))
        #expect(!estimate.isExact)
        #expect(estimate.sampleRate == 44_100)
        #expect(abs(estimate.duration - exact) / exact < 0.01)
        // 手里那段的时长明显偏短, 折算之后不再偏短。
        let inHand = try #require(ADTSStreamParser.parse(head)).duration
        #expect(inHand < exact * 0.5)
    }

    @Test func tailWindowJoinsTheMeanAndItsTrailingTagIsNotAudio() throws {
        var data = stream(Array(repeating: 400, count: 1_000))
        data.append(Data("TAG".utf8) + Data(repeating: 0x20, count: 125))
        let head = Data(data.prefix(64 * 1_024))
        let tail = Data(data.suffix(32 * 1_024))
        let estimate = try #require(ADTSStreamParser.duration(head: head, tail: tail, fileSize: Int64(data.count)))
        #expect(!estimate.isExact)
        #expect(abs(estimate.duration - seconds(blocks: 1_000, rate: 44_100)) < 0.03)
    }

    @Test func headCoveringTheWholeFileIsExact() throws {
        let data = id3(size: 500) + stream(variableLengths(300))
        let estimate = try #require(ADTSStreamParser.duration(head: data, fileSize: Int64(data.count)))
        #expect(estimate.isExact)
        #expect(abs(estimate.duration - seconds(blocks: 300, rate: 44_100)) < 1e-9)
        // 不知道文件多大: 不猜。
        #expect(ADTSStreamParser.duration(head: data, fileSize: 0) == nil)
    }

    @Test func localSourcesCountEveryFrameThroughRangeReads() async throws {
        let data = stream(variableLengths(2_500))
        let head = Data(data.prefix(256 * 1_024))
        var localReads = 0
        let local = try await ADTSStreamParser.duration(
            head: head,
            fileSize: Int64(data.count),
            countsEveryFrame: true
        ) { offset, length in
            localReads += 1
            let start = Int(offset)
            return Data(data[start..<min(data.count, start + Int(length))])
        }
        let estimate = try #require(local)
        #expect(estimate.isExact)
        #expect(localReads > 1)
        #expect(abs(estimate.duration - seconds(blocks: 2_500, rate: 44_100)) < 1e-9)

        // 远端不逐帧数: 一次都不读。
        var remoteReads = 0
        let remoteResult = try await ADTSStreamParser.duration(
            head: head,
            fileSize: Int64(data.count),
            countsEveryFrame: false
        ) { _, _ in
            remoteReads += 1
            return Data()
        }
        let remote = try #require(remoteResult)
        #expect(!remote.isExact)
        #expect(remoteReads == 0)
    }
}
