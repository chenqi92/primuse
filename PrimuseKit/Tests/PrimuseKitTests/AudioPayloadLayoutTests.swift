import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio Payload Layout")
struct AudioPayloadLayoutTests {
    private func id3(size: Int, footer: Bool = false) -> [UInt8] {
        let syncsafe: [UInt8] = [
            UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
            UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F),
        ]
        return [0x49, 0x44, 0x33, 4, 0, footer ? 0x10 : 0] + syncsafe
    }

    private func flacBlock(type: UInt8, length: Int, last: Bool) -> [UInt8] {
        [(last ? 0x80 : 0) | type, UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
    }

    private func box(_ type: String, size: Int) -> [UInt8] {
        [UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
            + Array(type.utf8)
    }

    @Test("An MP3 behind a large ID3v2 cover starts after the tag")
    func mp3AfterCover() {
        let tagSize = 3_000_000
        var head = id3(size: tagSize)
        head += [UInt8](repeating: 0, count: 1000)
        // Whether a FLAC stream follows the tag is only known once the bytes
        // after it are read.
        let partial = AudioPayloadLayout.locate(head: Data(head), fileSize: 12_000_000)
        #expect(partial.audioStart == .beyond(Int64(10 + tagSize + 4)))
        head += [UInt8](repeating: 0, count: tagSize - 1000)
        head += [0xFF, 0xFB, 0x90, 0x00]
        let layout = AudioPayloadLayout.locate(head: Data(head), fileSize: 12_000_000)
        #expect(layout.audioStart == .at(Int64(10 + tagSize)))
        #expect(layout.trailingIndexStart == nil)
    }

    @Test("A footer and a second tag are both skipped")
    func stackedTags() {
        var head = id3(size: 100, footer: true) + [UInt8](repeating: 0, count: 110)
        head += id3(size: 50) + [UInt8](repeating: 0, count: 50)
        head += [0xFF, 0xFB, 0x90, 0x00]
        let layout = AudioPayloadLayout.locate(head: Data(head), fileSize: 5_000_000)
        #expect(layout.audioStart == .at(Int64(10 + 100 + 10 + 10 + 50)))
    }

    @Test("FLAC metadata blocks are walked to the last one")
    func flacPicture() {
        var head: [UInt8] = Array("fLaC".utf8)
        head += flacBlock(type: 0, length: 34, last: false) + [UInt8](repeating: 0, count: 34)
        head += flacBlock(type: 4, length: 200, last: false) + [UInt8](repeating: 0, count: 200)
        head += flacBlock(type: 6, length: 2_500_000, last: true)
        let layout = AudioPayloadLayout.locate(head: Data(head), fileSize: 40_000_000)
        #expect(layout.audioStart == .at(Int64(4 + 38 + 204 + 4 + 2_500_000)))
    }

    @Test("A FLAC block header past the head asks for more bytes")
    func flacNeedsMore() {
        var head: [UInt8] = Array("fLaC".utf8)
        head += flacBlock(type: 6, length: 2_000_000, last: false)
        let layout = AudioPayloadLayout.locate(head: Data(head), fileSize: 40_000_000)
        #expect(layout.audioStart == .beyond(Int64(4 + 4 + 2_000_000 + 4)))
    }

    @Test("FLAC behind an ID3v2 tag")
    func flacAfterID3() {
        var head = id3(size: 20) + [UInt8](repeating: 0, count: 20)
        head += Array("fLaC".utf8) + flacBlock(type: 0, length: 34, last: true)
        let layout = AudioPayloadLayout.locate(head: Data(head), fileSize: 40_000_000)
        #expect(layout.audioStart == .at(Int64(30 + 4 + 4 + 34)))
    }

    @Test("An MP4 with moov first starts at the mdat payload")
    func mp4MoovFirst() {
        var head = box("ftyp", size: 24) + [UInt8](repeating: 0, count: 16)
        head += box("moov", size: 1_800_000)
        let truncated = AudioPayloadLayout.locate(head: Data(head), fileSize: 9_000_000)
        #expect(truncated.audioStart == .beyond(Int64(24 + 1_800_000 + 16)))

        head += [UInt8](repeating: 0, count: 1_800_000 - 8)
        head += box("mdat", size: 9_000_000 - 24 - 1_800_000)
        let layout = AudioPayloadLayout.locate(head: Data(head), fileSize: 9_000_000)
        #expect(layout.audioStart == .at(Int64(24 + 1_800_000 + 8)))
        #expect(layout.trailingIndexStart == nil)
    }

    @Test("An MP4 with moov last reports where its index starts")
    func mp4MoovLast() {
        let mdatSize = 7_000_000
        let head = box("ftyp", size: 24) + [UInt8](repeating: 0, count: 16) + box("mdat", size: mdatSize)
        let layout = AudioPayloadLayout.locate(head: Data(head), fileSize: 8_000_000)
        #expect(layout.audioStart == .at(32))
        #expect(layout.trailingIndexStart == Int64(24 + mdatSize))
    }

    @Test("Unknown or corrupt structures do not move the seed")
    func unknownStructures() {
        #expect(AudioPayloadLayout.locate(head: Data([0xFF, 0xFB, 0x90, 0x00]), fileSize: 5_000_000).audioStart == .unrecognized)
        #expect(AudioPayloadLayout.locate(head: Data(), fileSize: 5_000_000).audioStart == .unrecognized)
        // A tag claiming to be larger than the file.
        #expect(AudioPayloadLayout.locate(head: Data(id3(size: 9_000_000)), fileSize: 5_000_000).audioStart == .unrecognized)
        // Size bytes that are not syncsafe.
        var bad = id3(size: 10)
        bad[7] = 0x80
        #expect(AudioPayloadLayout.locate(head: Data(bad), fileSize: 5_000_000).audioStart == .unrecognized)
    }
}
