import Foundation
import Testing
@testable import PrimuseKit

struct WAVEHeaderParserTests {
    @Test func parsesAdvertisedFullDurationFromHeaderOnly() {
        let header = makeHeader(
            channels: 2,
            sampleRate: 44_100,
            bitDepth: 16,
            advertisedAudioBytes: 1_764_000
        )

        let info = WAVEHeaderParser.parse(header)

        #expect(info?.duration == 10)
        #expect(info?.sampleRate == 44_100)
        #expect(info?.bitRateKbps == 1_411)
        #expect(info?.bitDepth == 16)
        #expect(info?.channelCount == 2)
    }

    @Test func skipsUnknownOddSizedChunks() {
        var header = makeHeader(
            channels: 1,
            sampleRate: 48_000,
            bitDepth: 24,
            advertisedAudioBytes: 144_000,
            leadingChunk: ("JUNK", Data([1, 2, 3]))
        )
        // The RIFF size is not used for duration but keep the fixture valid.
        replaceUInt32(&header, at: 4, with: UInt32(header.count - 8 + 144_000))

        let info = WAVEHeaderParser.parse(header)

        #expect(info?.duration == 1)
        #expect(info?.bitRateKbps == 1_152)
    }

    @Test func rejectsTruncatedOrNonWaveInput() {
        #expect(WAVEHeaderParser.parse(Data("not a wave".utf8)) == nil)
        #expect(WAVEHeaderParser.parse(Data("RIFF\0\0\0\0WAVEfmt ".utf8)) == nil)
    }

    private func makeHeader(
        channels: UInt16,
        sampleRate: UInt32,
        bitDepth: UInt16,
        advertisedAudioBytes: UInt32,
        leadingChunk: (String, Data)? = nil
    ) -> Data {
        let blockAlign = channels * (bitDepth / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var data = Data("RIFF".utf8)
        appendUInt32(36 + advertisedAudioBytes, to: &data)
        data.append(Data("WAVE".utf8))
        if let leadingChunk {
            data.append(Data(leadingChunk.0.utf8))
            appendUInt32(UInt32(leadingChunk.1.count), to: &data)
            data.append(leadingChunk.1)
            if leadingChunk.1.count.isMultiple(of: 2) == false { data.append(0) }
        }
        data.append(Data("fmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(channels, to: &data)
        appendUInt32(sampleRate, to: &data)
        appendUInt32(byteRate, to: &data)
        appendUInt16(blockAlign, to: &data)
        appendUInt16(bitDepth, to: &data)
        data.append(Data("data".utf8))
        appendUInt32(advertisedAudioBytes, to: &data)
        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func replaceUInt32(_ data: inout Data, at offset: Int, with value: UInt32) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}
