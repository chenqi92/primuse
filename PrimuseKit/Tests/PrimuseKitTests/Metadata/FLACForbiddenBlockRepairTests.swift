import Foundation
import Testing
@testable import PrimuseKit

@Suite("FLAC forbidden metadata block repair")
struct FLACForbiddenBlockRepairTests {
    private func header(type: UInt8, length: Int, last: Bool) -> [UInt8] {
        [(last ? 0x80 : 0) | type, UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
    }

    private func id3(size: Int, footer: Bool = false) -> [UInt8] {
        [0x49, 0x44, 0x33, 4, 0, footer ? 0x10 : 0,
         UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)]
    }

    /// `fLaC`, STREAMINFO, then `blocks` in order (the last one flagged last),
    /// then a few fake frame bytes.
    private func flac(_ blocks: [(type: UInt8, length: Int)], prefix: [UInt8] = []) -> (bytes: Data, headers: [Int64]) {
        var bytes = prefix + Array("fLaC".utf8)
        bytes += header(type: 0, length: 34, last: blocks.isEmpty)
        bytes += [0x10, 0x00, 0x10, 0x00] + [UInt8](repeating: 0x55, count: 30)
        var headers: [Int64] = []
        for (index, block) in blocks.enumerated() {
            headers.append(Int64(bytes.count))
            bytes += header(type: block.type, length: block.length, last: index == blocks.count - 1)
            bytes += [UInt8](repeating: 0x7F, count: block.length)
        }
        bytes += [0xFF, 0xF8, 0x69, 0x18] + [UInt8](repeating: 0x7F, count: 64)
        return (Data(bytes), headers)
    }

    private func expectOnlyRetagged(_ output: Data, original: Data, at headers: [Int64]) {
        #expect(output.count == original.count)
        for index in 0..<original.count {
            let offset = Int64(index)
            if headers.contains(offset) {
                #expect(output[index] == (original[index] & 0x80) | 1)
            } else {
                #expect(output[index] == original[index])
            }
        }
    }

    @Test("A forbidden block becomes padding and nothing else changes")
    func retagsForbiddenBlock() {
        let file = flac([(127, 6266), (4, 40)])
        let repair = FLACForbiddenBlockRepair()
        let output = repair.repairing(file.bytes, at: 0)
        expectOnlyRetagged(output, original: file.bytes, at: [file.headers[0]])
        #expect(repair.repairedHeaderOffsets == [42])
    }

    @Test("A forbidden last block keeps its last-block flag")
    func keepsLastFlag() {
        let file = flac([(4, 40), (1, 100), (127, 500)])
        let output = FLACForbiddenBlockRepair().repairing(file.bytes, at: 0)
        #expect(output[Int(file.headers[2])] == 0x81)
        expectOnlyRetagged(output, original: file.bytes, at: [file.headers[2]])
    }

    @Test("Headers split across reads of every size are still found")
    func splitAcrossReads() {
        let file = flac([(4, 40), (127, 7), (6, 300), (127, 3)])
        let wanted = [file.headers[1], file.headers[3]]
        for size in 1...9 {
            let repair = FLACForbiddenBlockRepair()
            var output = Data()
            var offset = 0
            while offset < file.bytes.count {
                let end = min(offset + size, file.bytes.count)
                output += repair.repairing(file.bytes.subdata(in: offset..<end), at: Int64(offset))
                offset = end
            }
            expectOnlyRetagged(output, original: file.bytes, at: wanted)
            #expect(repair.repairedHeaderOffsets == wanted)
        }
    }

    @Test("Repeated and overlapping reads are retagged every time, reported once")
    func repeatedReads() {
        let file = flac([(127, 20), (4, 40)])
        let reported = Counter()
        let repair = FLACForbiddenBlockRepair { _ in reported.increment() }
        // AVPlayer's content-information request asks for two bytes first.
        #expect(repair.repairing(file.bytes.prefix(2), at: 0) == file.bytes.prefix(2))
        for _ in 0..<3 {
            expectOnlyRetagged(repair.repairing(file.bytes, at: 0), original: file.bytes, at: [file.headers[0]])
        }
        let header = Int(file.headers[0])
        let slice = file.bytes.subdata(in: (header - 5)..<(header + 5))
        #expect(repair.repairing(slice, at: Int64(header - 5))[5] == 0x01)
        #expect(reported.value == 1)
    }

    @Test("Bytes past the walk wait until the bytes before them arrive")
    func readAheadOfWalk() {
        let file = flac([(1, 1_000), (127, 30), (4, 40)])
        let repair = FLACForbiddenBlockRepair()
        let tail = file.bytes.subdata(in: 500..<file.bytes.count)
        // The header inside this read is not known to be one yet.
        #expect(repair.repairing(tail, at: 500) == tail)
        #expect(repair.repairedHeaderOffsets.isEmpty)
        let output = repair.repairing(file.bytes, at: 0)
        expectOnlyRetagged(output, original: file.bytes, at: [file.headers[1]])
    }

    @Test("An ID3v2 tag in front of the stream is skipped", arguments: [false, true])
    func id3Prefix(footer: Bool) {
        let tag = id3(size: 300, footer: footer) + [UInt8](repeating: 0x7F, count: 300 + (footer ? 10 : 0))
        let file = flac([(127, 12), (4, 40)], prefix: tag)
        let output = FLACForbiddenBlockRepair().repairing(file.bytes, at: 0)
        expectOnlyRetagged(output, original: file.bytes, at: [file.headers[0]])
    }

    @Test("Reserved block types other than 127 are left alone", arguments: [UInt8(7), 64, 126])
    func reservedTypes(type: UInt8) {
        let file = flac([(type, 20), (4, 40)])
        #expect(FLACForbiddenBlockRepair().repairing(file.bytes, at: 0) == file.bytes)
    }

    @Test("Data that is not a FLAC stream is never touched")
    func notFLAC() {
        var bytes = flac([(127, 20)]).bytes
        bytes.replaceSubrange(0..<4, with: Array("OggS".utf8))
        #expect(FLACForbiddenBlockRepair().repairing(bytes, at: 0) == bytes)

        var wrongFirst = flac([(127, 20)]).bytes
        wrongFirst[4] = 4
        #expect(FLACForbiddenBlockRepair().repairing(wrongFirst, at: 0) == wrongFirst)
    }

    @Test("Local files are repaired in place")
    func localFile() throws {
        let file = flac([(4, 40), (127, 6266), (1, 100)])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-repair-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try file.bytes.write(to: url)

        #expect(try FLACForbiddenBlockRepair.forbiddenHeaderOffsets(inFileAt: url) == [file.headers[1]])
        #expect(try FLACForbiddenBlockRepair.repairFile(at: url))
        expectOnlyRetagged(try Data(contentsOf: url), original: file.bytes, at: [file.headers[1]])
        #expect(try FLACForbiddenBlockRepair.forbiddenHeaderOffsets(inFileAt: url).isEmpty)
        #expect(try FLACForbiddenBlockRepair.repairFile(at: url) == false)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
