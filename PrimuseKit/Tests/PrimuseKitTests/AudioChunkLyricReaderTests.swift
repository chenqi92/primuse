import Foundation
import Testing
@testable import PrimuseKit

struct AudioChunkLyricReaderTests {
    @Test func cafInfoPreservesRepeatedKeysAndSurvivesInvalidUTF8InOneEntry() async throws {
        let first = "[00:01.00]折一盏纸灯"
        let second = "[00:03.20]把晚霞装进信封"
        var info = number(UInt32(5), little: false)
        for (key, value) in [
            ("lyrics", Data(first.utf8)),
            ("title", Data("[00:00.00]零点的标题".utf8)),
            ("lyrics", Data([0xff])),
            ("lyrics", Data(second.utf8)),
            ("romanization", Data("ba wan xia zhuang jin xin feng".utf8)),
        ] {
            info += Data(key.utf8) + Data([0]) + value + Data([0])
        }
        info += Data("lyrics\0unassigned storage\0".utf8)
        let description = number(Double(44_100).bitPattern, little: false) + Data("lpcm".utf8)
            + Data(repeating: 0, count: 20)
        let audio = Data(repeating: 0xee, count: 17)
        var bytes = Data("caff".utf8) + Data([0, 1, 0, 0])
        bytes += cafChunk("desc", description)
        let audioStart = bytes.count + 12
        bytes += cafChunk("data", audio)
        bytes += cafChunk("info", info)
        let fields = try await read(bytes, forbidden: audioStart..<(audioStart + audio.count), responseLimit: 5)
        #expect(fields.map(\.text) == [first, second, "ba wan xia zhuang jin xin feng"])
        #expect(fields.map(\.role) == [.original, .original, .romanization])
    }

    @Test func rf64AndBw64ReadPastFourGiBAndResolveRepeatedSizeTableIDs() async throws {
        let audioSize: Int64 = 0x1_0000_0001
        var objects = riffChunk("JUNK", Data([1, 2, 3]), size: .max)
        objects += riffChunk("JUNK", Data([4, 5, 6, 7, 8]), size: .max)
        var info = Data("INFO".utf8)
        info += riffChunk("ICMT", Data("[00:02.10]星屑落在杯沿\0".utf8))
        info += riffChunk("ICMT", Data("录音室三号棚\0".utf8))
        info += riffChunk("INAM", Data("[00:01.10]这一字段是曲名\0".utf8))
        info += riffChunk("ICMT", Data("[00:04.50]月光拂过窗格\0".utf8))
        objects += riffChunk("LIST", info)
        objects += riffChunk("id3 ", id3("A lantern drifts above the quay"))
        for marker in ["RF64", "BW64"] {
            var header = Data(marker.utf8) + number(UInt32.max) + Data("WAVE".utf8)
            let fmt = riffChunk("fmt ", waveFormat)
            let dsSize = 28 + 2 * 12
            let audioStart = Int64(header.count + 8 + dsSize + fmt.count + 8)
            let tailStart = audioStart + audioSize + 1
            let fileSize = tailStart + Int64(objects.count)
            var ds = number(UInt64(fileSize - 8)) + number(UInt64(audioSize)) + number(UInt64(0)) + number(UInt32(2))
            for n in [3, 5] {
                ds += Data("JUNK".utf8) + number(UInt64(n))
            }
            header += riffChunk("ds64", ds) + fmt + Data("data".utf8) + number(UInt32.max)
            let tail = objects
            let fields = try await AudioChunkLyricReader.fields(head: header, fileSize: fileSize) { offset, length in
                guard offset >= tailStart, length <= fileSize - offset else { throw FixtureError.unexpectedRead }
                let position = Int(offset - tailStart)
                return tail.subdata(in: position..<(position + Int(length)))
            }
            #expect(fields.map(\.name) == ["ICMT", "ICMT", "USLT"])
            #expect(fields.map(\.text) == [
                "[00:02.10]星屑落在杯沿", "[00:04.50]月光拂过窗格", "A lantern drifts above the quay",
            ])
            #expect(fields.last?.languageCode == "en")
        }
    }

    @Test func wave64ReadsSonySummaryStringsRiffListAndVendorID3AtAlignedOffsets() async throws {
        let shared = Data([0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a])
        let riff = Data("riff".utf8) + Data([0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 4, 0xc1, 0, 0])
        let summary = Data([0xbc, 0x94, 0x5f, 0x92, 0x5a, 0x52, 0xd2, 0x11, 0x86, 0xdc, 0, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a])
        let list = Data("list".utf8) + Data([0x2f, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 4, 0xc1, 0, 0])
        var body = wideChunk(Data("fmt ".utf8) + shared, waveFormat)
        let audioStart = 40 + body.count + 24
        body += wideChunk(Data("data".utf8) + shared, Data(repeating: 0x41, count: 11))
        var properties = number(UInt32(4))
        for (key, value) in [
            ("ICMT", "记录"), ("ICMT", "[00:01.20]一粒雨收进掌心"),
            ("INAM", "[00:00.90]留给曲名"), ("ICMT", "[00:06.10]纸桥沉入薄雾"),
        ] {
            let utf16 = try #require((value + "\0").data(using: .utf16LittleEndian))
            properties += Data(key.utf8) + number(UInt32(utf16.count)) + utf16
        }
        body += wideChunk(summary, properties)
        let info = Data("INFO".utf8) + riffChunk("ICMT", Data("[00:08.00]霜花画满阶梯\0".utf8))
        body += wideChunk(list, info)
        body += wideChunk(Data(repeating: 0x77, count: 16), id3("Clouds fold the silver map"))
        let file = riff + number(UInt64(40 + body.count)) + Data("wave".utf8) + shared + body
        let fields = try await read(file, forbidden: audioStart..<(audioStart + 11))
        #expect(fields.map(\.text) == [
            "[00:01.20]一粒雨收进掌心", "[00:06.10]纸桥沉入薄雾", "[00:08.00]霜花画满阶梯", "Clouds fold the silver map",
        ])
    }

    @Test func sunAUReadsStructuredAnnotationsAndNamedTranslationsOnlyBeforeAudio() async throws {
        let raw = "[00:02.40]雾里数过七扇窗\n[00:05.00]灯船靠向石阶"
        let keyed = "Title=[00:01.00]题名\nLyrics=雾里数过七扇窗\n灯船靠向石阶\nTRANSLATION-en=I count seven windows\nArtist=录音笔记"
        let utf16 = try #require(raw.data(using: .utf16LittleEndian))
        for (annotation, expected) in [
            (Data(raw.utf8), [raw]),
            (Data([0xff, 0xfe]) + utf16, [raw]),
            (Data(keyed.utf8), ["雾里数过七扇窗\n灯船靠向石阶", "I count seven windows"]),
            (Data("录音棚便笺，周四混音".utf8), []),
        ] {
            let pad = 8 - annotation.count % 8
            let audioStart = 24 + annotation.count + pad
            var header = Data(".snd".utf8) + number(UInt32(audioStart), little: false)
            header += number(UInt32.max, little: false) + number(UInt32(3), little: false)
            header += number(UInt32(44_100), little: false) + number(UInt32(1), little: false)
            let audio = Data("[00:00.00]This is in the sample data".utf8)
            let file = header + annotation + Data(repeating: 0, count: pad) + audio
            let fields = try await read(file, forbidden: audioStart..<file.count)
            #expect(fields.map(\.text) == expected)
            if expected.count == 2 {
                #expect(fields.last?.role == .translation)
                #expect(fields.last?.languageCode == "en")
            }
        }
    }

    @Test func wave64FindsSmallID3LyricsAfterThirtyThreeMiBCoverWithoutFetchingCover() async throws {
        let shared = Data([0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a])
        let riff = Data("riff".utf8) + Data([0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 4, 0xc1, 0, 0])
        let coverCount = 33 * 1024 * 1024
        let lyric = "Silver pebbles trace the quiet tide"
        let lyricFrame = Data(id3(lyric).dropFirst(10))
        let tagPayloadSize = 10 + coverCount + lyricFrame.count
        let id3ObjectSize = 24 + 10 + tagPayloadSize
        let pad = (8 - id3ObjectSize % 8) % 8
        var chunks = wideChunk(Data("fmt ".utf8) + shared, waveFormat)
        chunks += wideChunk(Data("data".utf8) + shared, Data([0, 0]))
        let fileSize = Int64(40 + chunks.count + id3ObjectSize + pad)
        chunks += Data("id3 ".utf8) + shared + number(UInt64(id3ObjectSize))
        var tag = Data("ID3".utf8) + Data([3, 0, 0])
        tag += Data((0..<4).reversed().map { UInt8((tagPayloadSize >> ($0 * 7)) & 127) })
        tag += Data("APIC".utf8) + number(UInt32(coverCount), little: false) + Data([0, 0])
        let header = riff + number(UInt64(fileSize)) + Data("wave".utf8) + shared + chunks + tag
        let tailOffset = Int64(header.count + coverCount)
        let tail = lyricFrame + Data(repeating: 0, count: pad)
        let fields = try await AudioChunkLyricReader.fields(head: header, fileSize: fileSize) { offset, length in
            guard offset >= tailOffset, length <= fileSize - offset else { throw FixtureError.unexpectedRead }
            let start = Int(offset - tailOffset)
            return tail.subdata(in: start..<(start + Int(length)))
        }
        #expect(fields.map(\.text) == [lyric])
        #expect(fields.first?.languageCode == "en")
    }

    @Test func stopsAtIndefiniteOrInvalidLengthsAndReportsShortRangeReads() async throws {
        let header = Data("caff".utf8) + Data([0, 1, 0, 0])
        let indefinite = header + Data("data".utf8) + number(UInt64.max, little: false)
        let payload = Data("info\0lyrics\0a line inside the audio".utf8)
        #expect(try await read(indefinite + payload, forbidden: indefinite.count..<(indefinite.count + payload.count)).isEmpty)
        let malformed = Data(".snd".utf8) + number(UInt32.max, little: false) + Data(repeating: 0, count: 22)
        #expect(try await read(malformed).isEmpty)
        await #expect(throws: ISOBaseMediaRangeReader.ReadError.self) {
            try await AudioChunkLyricReader.fields(head: header, fileSize: 28) { _, _ in Data() }
        }
    }

    private enum FixtureError: Error { case unexpectedRead }

    private func read(_ data: Data, forbidden: Range<Int>? = nil, responseLimit: Int = .max) async throws -> [EmbeddedLyricField] {
        try await AudioChunkLyricReader.fields(head: Data(data.prefix(5)), fileSize: Int64(data.count)) { offset, length in
            let start = Int(offset)
            let range = start..<(start + Int(length))
            guard range.lowerBound >= 5, range.upperBound <= data.count,
                  forbidden?.overlaps(range) != true else { throw FixtureError.unexpectedRead }
            return data.subdata(in: start..<(start + min(Int(length), responseLimit)))
        }
    }

    private var waveFormat: Data {
        number(UInt16(1)) + number(UInt16(1)) + number(UInt32(44_100)) + number(UInt32(88_200))
            + number(UInt16(2)) + number(UInt16(16))
    }

    private func number<T: FixedWidthInteger>(_ value: T, little: Bool = true) -> Data {
        var ordered = little ? value.littleEndian : value.bigEndian
        return withUnsafeBytes(of: &ordered) { Data($0) }
    }

    private func riffChunk(_ key: String, _ bytes: Data, size: UInt32? = nil) -> Data {
        Data(key.utf8) + number(size ?? UInt32(bytes.count)) + bytes + Data(repeating: 0, count: bytes.count % 2)
    }

    private func cafChunk(_ key: String, _ bytes: Data) -> Data {
        Data(key.utf8) + number(UInt64(bytes.count), little: false) + bytes
    }

    private func wideChunk(_ guid: Data, _ bytes: Data) -> Data {
        let size = 24 + bytes.count
        return guid + number(UInt64(size)) + bytes + Data(repeating: 0, count: (8 - size % 8) % 8)
    }

    private func id3(_ text: String) -> Data {
        let payload = Data([0]) + Data("eng".utf8) + Data([0]) + Data(text.utf8)
        let frame = Data("USLT".utf8) + number(UInt32(payload.count), little: false) + Data([0, 0]) + payload
        return Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, UInt8(frame.count)]) + frame
    }
}
