import Foundation
import Testing
@testable import PrimuseKit

/// 整库续接请求的 id 放在映射文件里:内容、顺序、窗口与旧的内存数组完全一样;旧版存档读回时转换一次。
@Suite("Queue continuation mapped ID file", .serialized)
struct QueueContinuationIDFileTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qcid-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A large request is spooled to a mapped file and hands out the same windows")
    func largeRequestIsMapped() throws {
        let ids = (0..<50_000).map { "song-\($0)" }
        var mapped = QueueContinuation(requestedIDs: ids, window: 1_000..<2_000)
        guard case .file = mapped.idStorage else {
            Issue.record("expected a mapped list")
            return
        }
        #expect(mapped.requestedCount == ids.count)
        #expect(mapped.requestedIDs == ids)
        #expect(mapped.requestedIDs(in: 10..<13) == ["song-10", "song-11", "song-12"])
        #expect(mapped.requestedIDs(in: 49_998..<60_000) == ["song-49998", "song-49999"])
        var expected: [String] = []
        while case let batch = mapped.takeNext(maxCount: 7_000, repeatsAll: true), !batch.isEmpty {
            expected += batch
        }
        #expect(expected == Array(ids[2_000...]) + Array(ids[..<1_000]))
        #expect(mapped.isExhausted)
    }

    @Test("Small requests stay in memory")
    func smallRequestStaysInMemory() {
        let continuation = QueueContinuation(requestedIDs: ["a", "b"], window: 0..<1)
        guard case .memory = continuation.idStorage else {
            Issue.record("expected an in-memory list")
            return
        }
        #expect(continuation.requestedIDs == ["a", "b"])
    }

    @Test("Unusual IDs survive the binary format")
    func unusualIDsRoundTrip() throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let ids = ["", "a\nb", "雨一直下", "e\u{301}", "😀", String(repeating: "x", count: 5_000), "tail"]
            + (0..<5_000).map { "n\($0)" }
        let url = base.appendingPathComponent("list.qids")
        let fingerprint = try QueueContinuationIDFile.write(ids, count: ids.count, to: url)
        #expect(fingerprint == QueueContinuationStore.fingerprint(ids))
        let file = try #require(QueueContinuationIDFile.open(url: url))
        #expect(file.count == ids.count)
        #expect((0..<file.count).map { file[$0] } == ids)
        #expect(QueueContinuationIDFile.header(at: url)?.count == ids.count)
    }

    @Test("The store maps the saved list back and keeps it between advances")
    func storeMapsTheList() throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = QueueContinuationStore(url: base.appendingPathComponent("c.json"))
        var continuation = QueueContinuation(requestedIDs: (0..<20_000).map { "s\($0)" }, window: 0..<1_000)
        store.save(continuation)
        let loaded = try #require(store.load())
        guard case .file = loaded.idStorage else {
            Issue.record("expected the loaded list to be mapped")
            return
        }
        #expect(loaded == continuation)
        _ = continuation.takeNext(maxCount: 300, repeatsAll: false)
        store.save(continuation)
        #expect(store.load() == continuation)
        #expect(store.load()?.nextOffset == 1_300)
        continuation.removePendingSongs(withIDs: ["s1500", "s19999"])
        store.save(continuation)
        let reloaded = try #require(store.load())
        #expect(reloaded == continuation)
        #expect(reloaded.requestedCount == 19_998)
    }

    @Test("A former plain-text ID list is converted once and removed")
    func legacyTextListIsConverted() throws {
        let base = directory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("c.json")
        let store = QueueContinuationStore(url: url)
        let ids = (0..<9_000).map { "legacy-\($0)" }
        let fingerprint = QueueContinuationStore.fingerprint(ids)
        var text = "primuse-queue-ids v1 \(ids.count) \(String(fingerprint, radix: 16))\n"
        for id in ids { text += id + "\n" }
        try Data(text.utf8).write(to: store.legacyIDsURL)
        let state = """
            {"token":"t","nextOffset":1200,"leadingEnd":200,"leadingOffset":0,"idsCount":\(ids.count),"idsFingerprint":\(fingerprint)}
            """
        try Data(state.utf8).write(to: url)

        let loaded = try #require(store.load())
        #expect(loaded.token == "t")
        #expect(loaded.nextOffset == 1_200 && loaded.leadingEnd == 200)
        #expect(loaded.requestedIDs == ids)
        #expect(!FileManager.default.fileExists(atPath: store.legacyIDsURL.path))
        #expect(FileManager.default.fileExists(atPath: store.idsURL.path))
        // 第二次读的是新格式。
        let again = try #require(store.load())
        guard case .file = again.idStorage else {
            Issue.record("expected the converted list to be mapped")
            return
        }
        #expect(again == loaded)

        // 头行对不上的旧文件不猜。
        try Data(text.utf8).write(to: store.legacyIDsURL)
        try Data(state.replacingOccurrences(of: "\(ids.count)", with: "\(ids.count + 1)").utf8).write(to: url)
        #expect(store.load() == nil)
    }

    @Test("A former single JSON document is converted to the mapped format")
    func legacyDocumentIsConverted() throws {
        let base = directory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("c.json")
        var continuation = QueueContinuation(requestedIDs: (0..<6_000).map { "doc-\($0)" }, window: 0..<1_000)
        _ = continuation.takeNext(maxCount: 10, repeatsAll: false)
        try JSONEncoder().encode(continuation).write(to: url)
        let store = QueueContinuationStore(url: url)
        let loaded = try #require(store.load())
        #expect(loaded == continuation)
        guard case .file = loaded.idStorage else {
            Issue.record("expected the converted list to be mapped")
            return
        }
        #expect(FileManager.default.fileExists(atPath: store.idsURL.path))
    }

    @Test("A damaged ID file loads as nothing")
    func damagedFileLoadsAsNothing() throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = QueueContinuationStore(url: base.appendingPathComponent("c.json"))
        store.save(QueueContinuation(requestedIDs: (0..<10_000).map { "d\($0)" }, window: 0..<1_000))
        let handle = try FileHandle(forWritingTo: store.idsURL)
        try handle.truncate(atOffset: 100)
        try handle.close()
        #expect(store.load() == nil)
    }

    @Test("The spool file goes away with the last continuation that maps it")
    func spoolFileIsRemoved() throws {
        var spoolURL: URL?
        do {
            let continuation = QueueContinuation(requestedIDs: (0..<10_000).map { "p\($0)" }, window: 0..<10)
            guard case .file(let file) = continuation.idStorage else {
                Issue.record("expected a mapped list")
                return
            }
            spoolURL = file.spooledURL
            #expect(spoolURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            #expect(continuation.requestedCount == 10_000)
        }
        let url = try #require(spoolURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
