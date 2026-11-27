import Foundation
import Testing
@testable import PrimuseKit

@Suite("ISO top-level box walk")
struct ISOBaseMediaTopLevelBoxWalkTests {
    private let cap: Int64 = 32 * 1024 * 1024

    @Test("Fast-start moov inside the head needs no header read")
    func moovAtStart() {
        let ftyp = ftypBox()
        let moov = moovBox()
        let file = ftyp + moov + isoBox("mdat", Data(count: 64))
        let walk = ISOBaseMediaTopLevelBoxWalk(head: file, fileSize: 2_000_000_000, maximumMoovByteCount: cap)
        #expect(walk.step == .foundMoov(offset: Int64(ftyp.count), size: Int64(moov.count)))
        #expect(walk.ftyp == 0..<Int64(ftyp.count))
        #expect(walk.startOffset == 0)
        #expect(walk.fetchedHeaderCount == 0)
    }

    @Test("Follows a 32-bit mdat size past media that was never downloaded")
    func moovAfter32BitMdat() {
        let ftyp = ftypBox()
        let mdatSize: UInt32 = 3_000_000_000
        let head = ftyp + bigEndian(mdatSize) + Data("mdat".utf8) + Data(count: 1_000)
        let moovOffset = Int64(ftyp.count) + Int64(mdatSize)
        let moov = moovBox()
        var walk = ISOBaseMediaTopLevelBoxWalk(
            head: head,
            fileSize: moovOffset + Int64(moov.count),
            maximumMoovByteCount: cap
        )
        #expect(walk.step == .needsHeader(offset: moovOffset, count: 16))
        walk.consume(header: moov.prefix(16))
        #expect(walk.step == .foundMoov(offset: moovOffset, size: Int64(moov.count)))
        #expect(walk.fetchedHeaderCount == 1)
    }

    @Test("Follows a 64-bit mdat largesize beyond 4 GiB")
    func moovAfter64BitMdat() {
        let ftyp = ftypBox()
        let mdatSize: UInt64 = 7_000_000_000
        let head = ftyp + bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(mdatSize)
            + Data(count: 1_000)
        let moovOffset = Int64(ftyp.count) + Int64(mdatSize)
        #expect(moovOffset > Int64(UInt32.max))
        let moov = moovBox()
        var walk = ISOBaseMediaTopLevelBoxWalk(
            head: head,
            fileSize: moovOffset + Int64(moov.count) + 4_096,
            maximumMoovByteCount: cap
        )
        #expect(walk.step == .needsHeader(offset: moovOffset, count: 16))
        walk.consume(header: moov.prefix(16))
        #expect(walk.step == .foundMoov(offset: moovOffset, size: Int64(moov.count)))
    }

    @Test("A 64-bit moov header cut by the head is fetched in one 16-byte read")
    func largeSizeMoovHeaderAcrossHead() {
        let ftyp = ftypBox()
        let mdat = isoBox("mdat", Data(count: 32))
        let payload = isoBox("mvhd", Data(count: 100))
        let moov = bigEndian(UInt32(1)) + Data("moov".utf8) + bigEndian(UInt64(payload.count + 16)) + payload
        let file = ftyp + mdat + moov
        let moovOffset = ftyp.count + mdat.count
        var walk = ISOBaseMediaTopLevelBoxWalk(
            head: file.prefix(moovOffset + 8),
            fileSize: Int64(file.count),
            maximumMoovByteCount: cap
        )
        #expect(walk.step == .needsHeader(offset: Int64(moovOffset), count: 16))
        walk.consume(header: file.subdata(in: moovOffset..<moovOffset + 16))
        #expect(walk.step == .foundMoov(offset: Int64(moovOffset), size: Int64(moov.count)))
    }

    @Test("Steps over free, skip and uuid boxes inside and beyond the head")
    func paddingBeforeMoov() {
        let ftyp = ftypBox()
        let free = isoBox("free", Data(count: 200))
        let skip = isoBox("skip", Data(count: 50_000))
        let uuid = isoBox("uuid", Data(repeating: 0xAB, count: 16) + Data(count: 300))
        let mdat = isoBox("mdat", Data(count: 1_000_000))
        let moov = moovBox()
        let file = ftyp + free + skip + uuid + mdat + moov
        let skipOffset = ftyp.count + free.count
        let uuidOffset = skipOffset + skip.count
        let mdatOffset = uuidOffset + uuid.count
        let moovOffset = mdatOffset + mdat.count

        let complete = ISOBaseMediaTopLevelBoxWalk(head: file, fileSize: Int64(file.count), maximumMoovByteCount: cap)
        #expect(complete.step == .foundMoov(offset: Int64(moovOffset), size: Int64(moov.count)))
        #expect(complete.fetchedHeaderCount == 0)

        // 首段停在 skip 里面: 之后每个 box 只读一个头。
        var walk = ISOBaseMediaTopLevelBoxWalk(
            head: file.prefix(skipOffset + 100),
            fileSize: Int64(file.count),
            maximumMoovByteCount: cap
        )
        var requested: [Int64] = []
        while case .needsHeader(let offset, let count) = walk.step {
            requested.append(offset)
            #expect(count == 16)
            walk.consume(header: file.subdata(in: Int(offset)..<Int(offset) + count))
        }
        #expect(walk.step == .foundMoov(offset: Int64(moovOffset), size: Int64(moov.count)))
        #expect(requested == [Int64(uuidOffset), Int64(mdatOffset), Int64(moovOffset)])
        #expect(walk.fetchedHeaderCount == 3)
    }

    @Test("A size-zero box runs to EOF: media stops the walk, a moov is taken to EOF")
    func sizeZero() {
        let ftyp = ftypBox()
        let toEOF = ftyp + bigEndian(UInt32(0)) + Data("mdat".utf8)
        let media = ISOBaseMediaTopLevelBoxWalk(head: toEOF, fileSize: 5_000_000_000, maximumMoovByteCount: cap)
        #expect(media.step == .stopped(.extendsToEndOfFile))
        #expect(media.fetchedHeaderCount == 0)

        let mdat = isoBox("mdat", Data(count: 64))
        let payload = isoBox("mvhd", Data(count: 100))
        let file = ftyp + mdat + bigEndian(UInt32(0)) + Data("moov".utf8) + payload
        let moov = ISOBaseMediaTopLevelBoxWalk(head: file, fileSize: Int64(file.count), maximumMoovByteCount: cap)
        #expect(moov.step == .foundMoov(offset: Int64(ftyp.count + mdat.count), size: Int64(payload.count + 8)))
    }

    @Test("A short header read stops instead of guessing")
    func truncatedHeader() {
        let head = ftypBox() + bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(UInt64(7_000_000_000))
        var walk = ISOBaseMediaTopLevelBoxWalk(head: head, fileSize: 8_000_000_000, maximumMoovByteCount: cap)
        #expect(walk.step == .needsHeader(offset: Int64(head.count) + 7_000_000_000 - 16, count: 16))
        walk.consume(header: Data([0, 0, 0]))
        #expect(walk.step == .stopped(.truncatedHeader))

        // 声明了 64 位长度, 读回来却只有 8 字节。
        var large = ISOBaseMediaTopLevelBoxWalk(head: head, fileSize: 8_000_000_000, maximumMoovByteCount: cap)
        large.consume(header: bigEndian(UInt32(1)) + Data("moov".utf8))
        #expect(large.step == .stopped(.truncatedHeader))
    }

    @Test("Bytes that are not an ISO container stop on the first header")
    func notISOBaseMedia() {
        let page = Data("<!DOCTYPE html><html><body>Not found</body></html>".utf8)
        let walk = ISOBaseMediaTopLevelBoxWalk(head: page, fileSize: 9_000_000_000, maximumMoovByteCount: cap)
        #expect(walk.step == .stopped(.notISOBaseMedia))
        #expect(walk.fetchedHeaderCount == 0)

        let binary = Data([0x00, 0x00, 0x00, 0x20, 0x01, 0x02, 0x03, 0x04]) + Data(count: 24)
        let binaryWalk = ISOBaseMediaTopLevelBoxWalk(head: binary, fileSize: 9_000_000_000, maximumMoovByteCount: cap)
        #expect(binaryWalk.step == .stopped(.notISOBaseMedia))
    }

    @Test("Garbage headers after a valid start are rejected", arguments: [
        GarbageCase.nonPrintableType, .undersized, .beyondFile, .largeSizeBelowHeader, .largeSizeOverflow,
    ])
    func garbageHeader(_ garbage: GarbageCase) {
        let ftyp = ftypBox()
        let head = ftyp + garbage.header
        let walk = ISOBaseMediaTopLevelBoxWalk(head: head, fileSize: 1_000, maximumMoovByteCount: cap)
        #expect(walk.step == .stopped(garbage.expected))
        #expect(walk.fetchedHeaderCount == 0)
    }

    @Test("Garbage where the next header should be stops the walk")
    func garbageAfterMedia() {
        let head = ftypBox() + bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(UInt64(5_000_000_000))
        var walk = ISOBaseMediaTopLevelBoxWalk(head: head, fileSize: 6_000_000_000, maximumMoovByteCount: cap)
        guard case .needsHeader = walk.step else {
            Issue.record("Expected a header read after the media box")
            return
        }
        walk.consume(header: Data(repeating: 0xFF, count: 16))
        #expect(walk.step == .stopped(.malformedHeader))
    }

    @Test("Unknown file size, oversized moov and a missing moov stop the walk")
    func stopConditions() {
        let ftyp = ftypBox()
        let unknown = ISOBaseMediaTopLevelBoxWalk(head: ftyp + moovBox(), fileSize: 0, maximumMoovByteCount: cap)
        #expect(unknown.step == .stopped(.unknownFileSize))

        let oversizedHead = ftyp + bigEndian(UInt32(1)) + Data("moov".utf8) + bigEndian(UInt64(40 * 1024 * 1024))
        let oversized = ISOBaseMediaTopLevelBoxWalk(head: oversizedHead, fileSize: 5_000_000_000, maximumMoovByteCount: cap)
        #expect(oversized.step == .stopped(.moovTooLarge(size: 40 * 1024 * 1024)))

        let noMoov = ftyp + isoBox("mdat", Data(count: 100))
        let end = ISOBaseMediaTopLevelBoxWalk(head: noMoov, fileSize: Int64(noMoov.count), maximumMoovByteCount: cap)
        #expect(end.step == .stopped(.endOfFile))
    }

    @Test("Header reads and box counts are bounded")
    func bounded() {
        let ftyp = ftypBox()
        var file = ftyp
        for _ in 0..<40 { file += isoBox("free", Data(count: 8)) }
        file += moovBox()
        var walk = ISOBaseMediaTopLevelBoxWalk(
            head: ftyp,
            fileSize: Int64(file.count),
            maximumMoovByteCount: cap,
            maximumFetchedHeaderCount: 4
        )
        while case .needsHeader(let offset, let count) = walk.step {
            walk.consume(header: file.subdata(in: Int(offset)..<Int(offset) + count))
        }
        #expect(walk.step == .stopped(.tooManyBoxes))
        #expect(walk.fetchedHeaderCount == 4)

        let boxes = ISOBaseMediaTopLevelBoxWalk(
            head: file,
            fileSize: Int64(file.count),
            maximumMoovByteCount: cap,
            maximumBoxCount: 3
        )
        #expect(boxes.step == .stopped(.tooManyBoxes))
    }

    @Test("Skips a leading ID3v2 tag the same way signature detection does")
    func leadingID3() {
        let id3 = id3Tag(payloadByteCount: 300)
        let ftyp = ftypBox()
        let moov = moovBox()
        let file = id3 + ftyp + moov
        let walk = ISOBaseMediaTopLevelBoxWalk(head: file, fileSize: Int64(file.count), maximumMoovByteCount: cap)
        #expect(walk.startOffset == Int64(id3.count))
        #expect(walk.ftyp == Int64(id3.count)..<Int64(id3.count + ftyp.count))
        #expect(walk.step == .foundMoov(offset: Int64(id3.count + ftyp.count), size: Int64(moov.count)))
    }

    @Test("A QuickTime file without ftyp is walked from its first box")
    func quickTimeWithoutFTYP() {
        let moov = moovBox()
        let lead = isoBox("wide", Data()) + isoBox("mdat", Data(count: 500))
        let file = lead + moov
        let walk = ISOBaseMediaTopLevelBoxWalk(head: file, fileSize: Int64(file.count), maximumMoovByteCount: cap)
        #expect(walk.step == .foundMoov(offset: Int64(lead.count), size: Int64(moov.count)))
        #expect(walk.ftyp == nil)
    }

    @Test("Consuming a header when none was requested changes nothing")
    func consumeWithoutRequest() {
        let file = ftypBox() + moovBox()
        var walk = ISOBaseMediaTopLevelBoxWalk(head: file, fileSize: Int64(file.count), maximumMoovByteCount: cap)
        let before = walk.step
        walk.consume(header: Data(repeating: 0xFF, count: 16))
        #expect(walk.step == before)
    }

    enum GarbageCase: CustomTestStringConvertible, Sendable {
        case nonPrintableType, undersized, beyondFile, largeSizeBelowHeader, largeSizeOverflow

        var header: Data {
            switch self {
            case .nonPrintableType:
                return bigEndian(UInt32(100)) + Data([0x00, 0x01, 0x02, 0x03])
            case .undersized:
                return bigEndian(UInt32(4)) + Data("free".utf8)
            case .beyondFile:
                return bigEndian(UInt32(1_000_000)) + Data("mdat".utf8)
            case .largeSizeBelowHeader:
                return bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(UInt64(8))
            case .largeSizeOverflow:
                return bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(UInt64.max)
            }
        }

        var expected: ISOBaseMediaTopLevelBoxWalk.StopReason {
            switch self {
            case .nonPrintableType, .undersized, .largeSizeBelowHeader: return .malformedHeader
            case .beyondFile, .largeSizeOverflow: return .exceedsFile
            }
        }

        var testDescription: String {
            switch self {
            case .nonPrintableType: return "non-printable type"
            case .undersized: return "size below the header"
            case .beyondFile: return "size beyond the file"
            case .largeSizeBelowHeader: return "64-bit size below the header"
            case .largeSizeOverflow: return "64-bit size overflow"
            }
        }
    }
}

@Suite("ISO range reader layouts")
struct ISOBaseMediaRangeReaderLayoutTests {
    @Test("An ID3-prefixed file keeps its ftyp and finds moov after 64-bit media")
    func id3Prefixed() async throws {
        let id3 = id3Tag(payloadByteCount: 300)
        let ftyp = ftypBox()
        let mdatSize: UInt64 = 5_000_000_000
        let head = id3 + ftyp + bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(mdatSize)
        let moov = moovBox()
        let moovOffset = Int64(id3.count + ftyp.count) + Int64(mdatSize)
        var requests: [(Int64, Int64)] = []
        let located = try await ISOBaseMediaRangeReader.readLocated(
            head: head,
            fileSize: moovOffset + Int64(moov.count)
        ) { offset, count in
            requests.append((offset, count))
            #expect(offset >= moovOffset)
            let lower = Int(offset - moovOffset)
            return moov.subdata(in: lower..<lower + Int(count))
        }
        let result = try #require(located)
        #expect(result.metadataFile == ftyp + moov)
        #expect(result.moov == moovOffset..<(moovOffset + Int64(moov.count)))
        #expect(result.hasOriginalFTYP)
        // 一个 16 字节的头, 一段 moov。
        #expect(requests.count == 2)
        #expect(requests.first?.1 == 16)
    }

    @Test("A QuickTime file without ftyp gets a QuickTime ftyp in front of its moov")
    func quickTimeWithoutFTYP() async throws {
        let moov = moovBox()
        let file = isoBox("wide", Data()) + isoBox("mdat", Data(count: 2_000)) + moov
        let located = try await ISOBaseMediaRangeReader.readLocated(head: file, fileSize: Int64(file.count)) { _, _ in
            Issue.record("The whole layout is already in the head")
            return Data()
        }
        let result = try #require(located)
        #expect(!result.hasOriginalFTYP)
        #expect(Data(result.metadataFile.suffix(moov.count)) == moov)
        #expect(Data(result.metadataFile.prefix(12)) == bigEndian(UInt32(20)) + Data("ftypqt  ".utf8))
        #expect(AudioFileSignaturePolicy.inspect(result.metadataFile) == .isoBaseMedia)
    }

    @Test("A non-ISO head issues no range request")
    func garbageHead() async throws {
        let head = Data("<!DOCTYPE html><html><body>Not found</body></html>".utf8)
        let located = try await ISOBaseMediaRangeReader.readLocated(head: head, fileSize: 9_000_000_000) { _, _ in
            Issue.record("Garbage must not be walked")
            return Data()
        }
        #expect(located?.metadataFile == nil)
    }

    @Test("A short header read is a failed read, not an unsupported layout")
    func shortHeaderRead() async throws {
        let head = ftypBox() + bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(UInt64(5_000_000_000))
        await #expect(throws: ISOBaseMediaRangeReader.ReadError.self) {
            try await ISOBaseMediaRangeReader.readLocated(head: head, fileSize: 6_000_000_000) { _, _ in
                Data(count: 4)
            }
        }
    }
}

private func ftypBox() -> Data {
    isoBox("ftyp", Data("M4B ".utf8) + Data(count: 4) + Data("M4B isom".utf8))
}

private func moovBox() -> Data {
    isoBox("moov", isoBox("mvhd", Data(count: 100)) + isoBox("udta", Data(count: 40)))
}

private func isoBox(_ type: String, _ payload: Data) -> Data {
    bigEndian(UInt32(payload.count + 8)) + Data(type.utf8) + payload
}

/// ID3v2.3 头 + 全零负载, 长度按 syncsafe 写。
private func id3Tag(payloadByteCount: Int) -> Data {
    let size = [
        UInt8((payloadByteCount >> 21) & 0x7F),
        UInt8((payloadByteCount >> 14) & 0x7F),
        UInt8((payloadByteCount >> 7) & 0x7F),
        UInt8(payloadByteCount & 0x7F),
    ]
    return Data("ID3".utf8) + Data([0x03, 0x00, 0x00]) + Data(size) + Data(count: payloadByteCount)
}

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
