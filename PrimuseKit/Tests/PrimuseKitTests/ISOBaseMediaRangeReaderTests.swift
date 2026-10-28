import Foundation
import Testing
@testable import PrimuseKit

@Suite("Remote ISO Base Media atom reads")
struct ISOBaseMediaRangeReaderTests {
    @Test("Skips a 64-bit media atom and reads a moov larger than the old head/tail limits")
    func largeTrailingMoov() async throws {
        let ftyp = atom("ftyp", Data("isom0000".utf8))
        let mediaSize: UInt64 = 7_000_000_000
        let head = ftyp + be(UInt32(1)) + Data("mdat".utf8) + be(mediaSize)
        let moov = atom("moov", atom("mvhd", Data(repeating: 0, count: 24))
            + atom("free", Data(repeating: 0, count: 17 * 1024 * 1024)))
        let start = Int64(ftyp.count) + Int64(mediaSize)
        var requests: [(Int64, Int64)] = []
        let result = try await ISOBaseMediaRangeReader.read(
            head: head, fileSize: start + Int64(moov.count)
        ) { offset, count in
            requests.append((offset, count))
            #expect(offset >= start)
            #expect(count <= ISOBaseMediaRangeReader.chunkByteCount)
            let lower = Int(offset - start)
            return moov.subdata(in: lower..<lower + Int(count))
        }
        #expect(result == ftyp + moov)
        #expect(requests.reduce(0) { $0 + $1.1 } <= moov.count + 16)
    }

    @Test("Reuses the fast-start prefix and does not fetch media or a suffix")
    func fastStart() async throws {
        let ftyp = atom("ftyp", Data("isom0000".utf8))
        let moov = atom("moov", atom("mvhd", Data(repeating: 0, count: 24))
            + atom("free", Data(repeating: 0, count: 400_000)))
        let metadata = ftyp + moov
        let head = Data(metadata.prefix(256 * 1024))
        var total = head.count
        let result = try await ISOBaseMediaRangeReader.read(head: head, fileSize: 5_000_000_000) { offset, count in
            #expect(offset >= head.count)
            #expect(offset + count <= metadata.count)
            total += Int(count)
            return metadata.subdata(in: Int(offset)..<Int(offset + count))
        }
        #expect(result == metadata)
        #expect(total == metadata.count)
    }

    @Test("A complete prefix does not issue a network read")
    func completeHead() async throws {
        let metadata = atom("ftyp", Data("isom0000".utf8))
            + atom("moov", atom("mvhd", Data(repeating: 0, count: 24)))
        let result = try await ISOBaseMediaRangeReader.read(head: metadata, fileSize: 9_000_000_000) { _, _ in
            Issue.record("Unexpected range read")
            return Data()
        }
        #expect(result == metadata)
    }

    @Test("Finds moov between media and trailing padding without searching payload signatures")
    func middleMoov() async throws {
        let ftyp = atom("ftyp", Data("isom0000".utf8))
        let media = atom("mdat", Data("false moov signature".utf8))
        let moov = atom("moov", atom("mvhd", Data(repeating: 0, count: 24)))
        let content = ftyp + media + moov + atom("free", Data(repeating: 0, count: 100))
        let result = try await ISOBaseMediaRangeReader.read(head: content, fileSize: Int64(content.count)) { _, _ in
            Issue.record("Unexpected range read")
            return Data()
        }
        #expect(result == ftyp + moov)
    }

    @Test("Rejects overflowing, undersized, out-of-file and over-budget atoms", arguments: [
        UInt64.max, UInt64(7), UInt64(100_000_000_000), UInt64(65 * 1024 * 1024)
    ])
    func invalidAtom(size: UInt64) async throws {
        let head = atom("ftyp", Data("isom0000".utf8))
            + be(UInt32(1)) + Data("moov".utf8) + be(size)
        let result = try await ISOBaseMediaRangeReader.read(head: head, fileSize: 10_000_000_000) { _, _ in
            Issue.record("Invalid atoms must not trigger body reads")
            return Data()
        }
        #expect(result == nil)
    }

    @Test("Size-zero media terminates traversal and truncated range reads fail")
    func truncatedRanges() async throws {
        let ftyp = atom("ftyp", Data("isom0000".utf8))
        let toEOF = ftyp + be(UInt32(0)) + Data("mdat".utf8)
        #expect(try await ISOBaseMediaRangeReader.read(head: toEOF, fileSize: 5_000_000_000) { _, _ in
            Issue.record("A size-zero atom extends to EOF")
            return Data()
        } == nil)
        let head = ftyp + be(UInt32(400)) + Data("moov".utf8)
        await #expect(throws: ISOBaseMediaRangeReader.ReadError.self) {
            try await ISOBaseMediaRangeReader.read(head: head, fileSize: 5_000_000_000) { _, _ in Data() }
        }
    }

    @Test("Cancellation stops before issuing a range request")
    func cancellation() async throws {
        let head = atom("ftyp", Data("isom0000".utf8))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ISOBaseMediaRangeReader.read(head: head, fileSize: 5_000_000_000) { _, _ in
                Issue.record("Cancelled reads must not reach the transport")
                return Data()
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        be(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }

    private func be<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
