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

    @Test("Appends land after earlier writes and before later removals")
    func appendOrdering() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.bin")
        let writer = OrderedFileWriter(label: "test.ordered.append")

        writer.append(to: url) { Data("a".utf8) }
        writer.write(to: url) {
            Thread.sleep(forTimeInterval: 0.1)
            return Data("base".utf8)
        }
        writer.append(to: url) { Data("-b".utf8) }
        writer.append(to: url) { nil }
        writer.append(to: url) { Data("-c".utf8) }
        writer.drain()
        #expect(text(at: url) == "base-b-c")

        writer.removeItem(at: url)
        writer.append(to: url) { Data("fresh".utf8) }
        writer.drain()
        #expect(text(at: url) == "fresh")
    }
}

@Suite("Keyed data journal")
struct KeyedDataJournalTests {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    private func journal(_ entries: [KeyedDataJournal.Entry]) throws -> Data {
        try entries.reduce(into: Data()) { $0.append(try KeyedDataJournal.encodeRecord($1)) }
    }

    @Test("Records replay in order on top of the base")
    func replayInOrder() throws {
        var table = ["a": bytes("1"), "b": bytes("2"), "c": bytes("3")]
        let data = try journal([
            .init(upserts: ["a": bytes("10"), "d": bytes("4")], removals: ["b"]),
            .init(upserts: ["b": bytes("20")]),
            .init(removals: ["c", "missing"]),
        ])
        #expect(KeyedDataJournal.replay(data, onto: &table) == 3)
        #expect(table == ["a": bytes("10"), "b": bytes("20"), "d": bytes("4")])
    }

    @Test("A record cut short by a killed append is dropped, the earlier ones are kept")
    func truncatedTail() throws {
        let complete = try journal([
            .init(upserts: ["a": bytes("1")]),
            .init(upserts: ["b": bytes("2")]),
        ])
        let last = try KeyedDataJournal.encodeRecord(.init(upserts: ["c": bytes("3")]))
        for cut in [1, 3, 4, last.count - 1] {
            var table: [String: Data] = [:]
            let data = complete + last.prefix(cut)
            #expect(KeyedDataJournal.replay(data, onto: &table) == 2)
            #expect(table == ["a": bytes("1"), "b": bytes("2")])
        }
    }

    @Test("Replay stops at a record that does not decode")
    func undecodableRecord() throws {
        var garbage = Data([0, 0, 0, 5])
        garbage.append(bytes("junk!"))
        let data = try journal([.init(upserts: ["a": bytes("1")])])
            + garbage
            + journal([.init(upserts: ["b": bytes("2")])])
        var table: [String: Data] = [:]
        #expect(KeyedDataJournal.replay(data, onto: &table) == 1)
        #expect(table == ["a": bytes("1")])
        var empty: [String: Data] = [:]
        #expect(KeyedDataJournal.replay(Data(), onto: &empty) == 0)
    }

    @Test("Replaying a journal that was already folded into the base changes nothing")
    func replayAfterCompactionIsIdempotent() throws {
        let data = try journal([
            .init(upserts: ["a": bytes("1"), "b": bytes("2")]),
            .init(upserts: ["a": bytes("3")], removals: ["b"]),
            .init(upserts: ["b": bytes("4")]),
        ])
        var compacted: [String: Data] = ["z": bytes("0")]
        KeyedDataJournal.replay(data, onto: &compacted)
        var replayedAgain = compacted
        KeyedDataJournal.replay(data, onto: &replayedAgain)
        #expect(replayedAgain == compacted)
        #expect(compacted == ["z": bytes("0"), "a": bytes("3"), "b": bytes("4")])
    }

    @Test("The journal is folded once it outgrows half the base")
    func compactionThreshold() {
        let floor = KeyedDataJournal.minimumCompactionBytes
        #expect(!KeyedDataJournal.shouldCompact(journalBytes: floor, baseBytes: 0))
        #expect(KeyedDataJournal.shouldCompact(journalBytes: floor + 1, baseBytes: 0))
        #expect(!KeyedDataJournal.shouldCompact(journalBytes: 4_000_000, baseBytes: 9_500_000))
        #expect(KeyedDataJournal.shouldCompact(journalBytes: 4_750_001, baseBytes: 9_500_000))
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
