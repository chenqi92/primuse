import Foundation
import Testing
@testable import PrimuseKit

struct SpotlightIndexRecoveryTests {
    private func withJournal(_ work: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try work(directory.appendingPathComponent("requests.json"))
    }

    @Test("Requests survive restart and merge without losing identifiers")
    func durableRequests() throws {
        try withJournal { url in
            let journal = SpotlightIndexRecoveryJournal(url: url)
            try journal.record(identifiers: ["song:a"])
            let restarted = SpotlightIndexRecoveryJournal(url: url)
            #expect(restarted.request?.identifiers == ["song:a"])
            try restarted.record(identifiers: ["album:b"])
            #expect(restarted.request?.identifiers == ["song:a", "album:b"])
            try restarted.record(identifiers: nil)
            try restarted.record(identifiers: ["song:c"])
            #expect(SpotlightIndexRecoveryJournal(url: url).request?.allItems == true)
        }
    }

    @Test("An older run cannot clear a request received while it was running")
    func overlappingRequest() throws {
        try withJournal { url in
            let journal = SpotlightIndexRecoveryJournal(url: url)
            let old = try journal.record(identifiers: ["song:a"])
            let newer = try journal.record(identifiers: ["song:b"])
            #expect(try journal.complete(revision: old.revision) == false)
            #expect(SpotlightIndexRecoveryJournal(url: url).request == newer)
            #expect(try journal.complete(revision: newer.revision))
            #expect(SpotlightIndexRecoveryJournal(url: url).request == nil)
        }
    }

    @Test("Failed persistence throws and does not publish an undurable request")
    func failedPersistence() throws {
        try withJournal { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let blocker = url.deletingLastPathComponent().appendingPathComponent("file")
            try Data().write(to: blocker)
            let journal = SpotlightIndexRecoveryJournal(url: blocker.appendingPathComponent("requests.json"))
            #expect(throws: (any Error).self) { try journal.record(identifiers: ["song:a"]) }
            #expect(journal.request == nil)
        }
    }

    @Test("Unreadable recovery state conservatively reindexes all items")
    func unreadableState() throws {
        try withJournal { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: url)
            let journal = SpotlightIndexRecoveryJournal(url: url)
            #expect(journal.recoveredUnreadableState)
            #expect(journal.request?.allItems == true)
            #expect(try journal.complete(revision: #require(journal.request).revision))
            #expect(SpotlightIndexRecoveryJournal(url: url).request == nil)
        }
    }
}
