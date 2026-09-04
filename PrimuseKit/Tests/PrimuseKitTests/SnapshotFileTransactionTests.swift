import Foundation
import Testing
@testable import PrimuseKit

struct SnapshotFileTransactionTests {
    @Test func partialWriteRestoresEveryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try Data("old".utf8).write(to: a)
        let transaction = SnapshotFileTransaction(directory: root.appendingPathComponent("transaction"))
        var writes = 0
        #expect(throws: CocoaError.self) {
            try transaction.apply([a: Data("new".utf8), b: Data("new".utf8)]) { data, url in
                writes += 1
                if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        }
        #expect(try Data(contentsOf: a) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func successfulCommitSurvivesRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("library")
        let transaction = SnapshotFileTransaction(directory: root.appendingPathComponent("transaction"))
        try transaction.apply([target: Data("complete".utf8)])
        try transaction.recover()
        #expect(try Data(contentsOf: target) == Data("complete".utf8))
    }
}
