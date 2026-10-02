import Foundation
import Testing
@testable import PrimuseKit

@Suite("Ordered file writer")
struct OrderedFileWriterTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrderedFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func text(at url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test("Later writes to the same file win")
    func lastWriteWins() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.bin")
        let writer = OrderedFileWriter(label: "test.ordered.last")

        for value in 0..<40 {
            writer.write(to: url) { Data("\(value)".utf8) }
        }
        writer.drain()

        #expect(text(at: url) == "39")
    }

    @Test("A removal queued after a slow write is not undone by it")
    func removalAfterSlowWrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fields.plist")
        let writer = OrderedFileWriter(label: "test.ordered.remove")

        writer.write(to: url) {
            Thread.sleep(forTimeInterval: 0.15)
            return Data("stale".utf8)
        }
        writer.removeItem(at: url)
        writer.drain()

        #expect(!FileManager.default.fileExists(atPath: url.path))

        writer.write(to: url) { Data("fresh".utf8) }
        writer.drain()
        #expect(text(at: url) == "fresh")
    }

    @Test("A file queued earlier is on disk before a later file is written")
    func crossFileOrdering() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fields = directory.appendingPathComponent("fields.plist")
        let cursor = directory.appendingPathComponent("cursor.bin")
        let writer = OrderedFileWriter(label: "test.ordered.cross")
        let observed = LockedFlag()

        writer.write(to: fields) {
            Thread.sleep(forTimeInterval: 0.15)
            return Data("fields".utf8)
        }
        writer.write(to: cursor, encode: { Data("cursor".utf8) }, written: { _ in
            observed.set(FileManager.default.fileExists(atPath: fields.path))
        })
        writer.drain()

        #expect(observed.value == true)
    }

    @Test("A failed encode writes nothing and does not block later writes")
    func failedEncodeIsSkipped() throws {
        struct EncodeFailure: Error {}
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.bin")
        let writer = OrderedFileWriter(label: "test.ordered.failure")

        writer.write(to: url) { throw EncodeFailure() }
        writer.write(to: url) { nil }
        writer.drain()
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let bytes = LockedCount()
        writer.write(to: url, encode: { Data("ok".utf8) }, written: { bytes.set($0) })
        writer.drain()
        #expect(text(at: url) == "ok")
        #expect(bytes.value == 2)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }
    func set(_ newValue: Int) { lock.withLock { stored = newValue } }
}
