import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audiobook keep offline")
struct AudiobookOfflinePolicyTests {
    @Test("A book's owner id round-trips and never reads as a playlist")
    func ownerIDs() {
        let owner = AudiobookOfflinePolicy.ownerID(forBook: "book-42")
        #expect(owner == "book:book-42")
        #expect(AudiobookOfflinePolicy.bookID(fromOwnerID: owner) == "book-42")
        #expect(AudiobookOfflinePolicy.bookID(fromOwnerID: "playlist-uuid") == nil)
        #expect(AudiobookOfflinePolicy.bookID(fromOwnerID: "book:") == nil)
    }

    @Test("The shelf's grouping wins; the remembered chapters cover a gap")
    func members() {
        #expect(AudiobookOfflinePolicy.members(current: ["a", "b", "c"], remembered: ["a", "b"]) == ["a", "b", "c"])
        // Before the shelf has grouped (startup) the book keeps its chapters
        // instead of being dropped from the offline set for a moment.
        #expect(AudiobookOfflinePolicy.members(current: [], remembered: ["a", "b"]) == ["a", "b"])
        #expect(AudiobookOfflinePolicy.members(current: [], remembered: []).isEmpty)
    }

    @Test("One downloadable chapter is enough; otherwise say why not")
    func availability() {
        #expect(AudiobookOfflinePolicy.availability([]) == .available)
        #expect(AudiobookOfflinePolicy.availability([.unsupported, .downloadable]) == .available)
        #expect(AudiobookOfflinePolicy.availability([.alreadyOnDevice, .alreadyOnDevice]) == .alreadyOnDevice)
        #expect(AudiobookOfflinePolicy.availability([.alreadyOnDevice, .unsupported]) == .unsupported)
        #expect(AudiobookOfflinePolicy.availability([.unsupported]) == .unsupported)
    }

    @Test("Progress counts each downloadable chapter once")
    func progress() {
        let progress = AudiobookOfflinePolicy.progress(
            downloadableIDs: ["a", "b", "c", "a"],
            downloadedIDs: ["a", "c", "z"]
        )
        #expect(progress == .init(downloaded: 2, total: 3))
        #expect(!progress.isComplete)
        #expect(AudiobookOfflinePolicy.progress(downloadableIDs: ["a"], downloadedIDs: ["a"]).isComplete)
        #expect(!AudiobookOfflinePolicy.progress(downloadableIDs: [], downloadedIDs: []).isComplete)
    }

    @Test("Records survive encoding and junk reads as none")
    func records() throws {
        let records = [
            "book-1": AudiobookOfflinePolicy.Record(title: "三体", songIDs: ["s1", "s2"]),
            "book-2": AudiobookOfflinePolicy.Record(title: "Dune", songIDs: []),
        ]
        let data = try #require(AudiobookOfflinePolicy.encode(records))
        #expect(AudiobookOfflinePolicy.decode(data) == records)
        #expect(AudiobookOfflinePolicy.decode(nil).isEmpty)
        #expect(AudiobookOfflinePolicy.decode(Data("not json".utf8)).isEmpty)
        let withEmptyKey = try #require(AudiobookOfflinePolicy.encode(["": .init(title: "x", songIDs: ["s"])]))
        #expect(AudiobookOfflinePolicy.decode(withEmptyKey).isEmpty)
    }
}
