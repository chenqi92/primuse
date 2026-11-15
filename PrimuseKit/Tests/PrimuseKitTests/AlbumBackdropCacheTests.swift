import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album backdrop pre-cache")
struct AlbumBackdropCacheTests {
    private let collection = AlbumBackdropCache.Collection(id: "source|/album", sourceID: "source", songID: "song", title: "Album")

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func restartAndUnchangedRefreshReuseEveryImage() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let remote = Remote(items: [item("back.jpg"), item("inside 1.jpg")])
        let first = try await sync(cache, remote)
        #expect(await remote.downloads == 2)
        let reopened = AlbumBackdropCache(directory: root)
        #expect(await reopened.snapshot(forKey: collection.id) == first)
        #expect(await reopened.needsRefresh(forKey: collection.id, interval: nil) == false)
        #expect(await reopened.needsRefresh(forKey: collection.id, interval: 86_400, now: first.checkedAt.addingTimeInterval(86_401)))
        for entry in first.entries {
            let url = try #require(await reopened.fileURL(for: entry, collectionKey: collection.id))
            #expect(try Data(contentsOf: url) == Data(entry.item.path.utf8))
        }
        _ = try await sync(reopened, remote)
        #expect(await remote.downloads == 2)
        #expect(await reopened.usage().count == 1)
        #expect(await reopened.usage().first?.bytes == Int64(first.entries.reduce(0) { $0 + $1.item.path.utf8.count }))
    }

    @Test func refreshAppliesAdditionsRemovalsOrderingAndProviderRevision() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let a = item("back.jpg"), b = item("inside 1.jpg"), c = item("inside 2.jpg")
        let remote = Remote(items: [a, b])
        let first = try await sync(cache, remote)
        let removedURL = try #require(await cache.fileURL(for: first.entries[1], collectionKey: collection.id))
        let changed = item("back.jpg", revision: "replacement")
        await remote.set(items: [c, changed], payloads: [changed.path: Data("new back".utf8)])
        let updated = try await sync(cache, remote)
        #expect(updated.entries.map(\.item) == [c, changed])
        #expect(await remote.downloads == 4)
        #expect(!FileManager.default.fileExists(atPath: removedURL.path))
        await remote.set(items: [changed, c])
        let reordered = try await sync(cache, remote)
        #expect(reordered.entries.map(\.item) == [changed, c])
        #expect(await remote.downloads == 4)
        await remote.set(items: [])
        #expect(try await sync(cache, remote).entries.isEmpty)
        #expect(await cache.usage().first?.bytes == 0)
    }

    @Test func failedRefreshPreservesOldManifestAndImages() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let remote = Remote(items: [item("back.jpg")])
        let old = try await sync(cache, remote)
        await remote.set(items: [item("inside 1.jpg"), item("inside 2.jpg")], failingPath: "/album/inside 2.jpg")
        await #expect(throws: URLError.self) { try await sync(cache, remote) }
        #expect(await cache.snapshot(forKey: collection.id) == old)
        #expect(await cache.fileURL(for: old.entries[0], collectionKey: collection.id) != nil)
        #expect(await cache.usage().first?.bytes == Int64(old.entries[0].item.path.utf8.count))
    }

    @Test func manualRefreshHandlesReplacementWithUnchangedMetadata() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let image = item("back.jpg")
        let remote = Remote(items: [image])
        let old = try await sync(cache, remote)
        await remote.set(items: [image], payloads: [image.path: Data("replacement".utf8)])
        let replaced = try await sync(cache, remote, force: true)
        #expect(replaced.entries[0].assetID != old.entries[0].assetID)
        #expect(await remote.downloads == 2)
    }

    @Test func purgedAssetIsRecoveredEvenInManualMode() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let remote = Remote(items: [item("back.jpg"), item("inside.jpg")])
        let old = try await sync(cache, remote)
        let url = try #require(await cache.fileURL(for: old.entries[0], collectionKey: collection.id))
        try FileManager.default.removeItem(at: url)
        #expect(await cache.needsRefresh(forKey: collection.id, interval: nil))
        _ = try await sync(cache, remote)
        #expect(await remote.downloads == 3)
        #expect(await cache.needsRefresh(forKey: collection.id, interval: nil) == false)
    }

    @Test func clearDuringDownloadCannotRecreateDeletedCollection() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let gate = Gate()
        let image = item("back.jpg")
        let operation = Task {
            try await cache.synchronize(collection: collection, list: { [image] }, download: { _ in
                await gate.wait()
                return Data("image".utf8)
            })
        }
        await gate.untilEntered()
        try await cache.remove(forKey: collection.id)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await cache.snapshot(forKey: collection.id) == nil)
        #expect(await cache.usage().isEmpty)
    }

    @Test func collectionsRemainIsolatedWhenOneIsCleared() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let remote = Remote(items: [item("back.jpg")])
        _ = try await sync(cache, remote)
        let other = AlbumBackdropCache.Collection(id: "other|/album", sourceID: "other", songID: "song2", title: "Other")
        let saved = try await cache.synchronize(collection: other, list: { await remote.items }, download: { try await remote.download($0) })
        try await cache.remove(forKey: collection.id)
        #expect(await cache.snapshot(forKey: collection.id) == nil)
        #expect(await cache.fileURL(for: saved.entries[0], collectionKey: other.id) != nil)
        #expect(await cache.usage().map(\.id) == [other.id])
    }

    @Test func cancelPrefetchPreservesPublishedImagesAndAllowsImmediateRetry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AlbumBackdropCache(directory: root)
        let remote = Remote(items: [item("back.jpg")])
        let saved = try await sync(cache, remote)
        let gate = Gate()
        let additions = [item("inside 1.jpg"), item("inside 2.jpg")]
        let operation = Task {
            try await cache.synchronize(collection: collection, list: { additions }, download: { item in
                if item.path == additions.last?.path { await gate.wait() }
                return Data(item.path.utf8)
            })
        }
        await gate.untilEntered()
        await cache.cancelSynchronization(forKey: collection.id)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await cache.snapshot(forKey: collection.id) == saved)
        #expect(await cache.fileURL(for: saved.entries[0], collectionKey: collection.id) != nil)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let imageFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "image" }
        #expect(imageFiles.count == 1)
        await remote.set(items: additions)
        #expect(try await sync(cache, remote).entries.map(\.item) == additions)
    }

    private func item(_ name: String, revision: String = "v1") -> AlbumBackdropCache.Item {
        .init(path: "/album/" + name, size: 100, modified: Date(timeIntervalSince1970: 10), providerID: name, revision: revision)
    }

    private func sync(_ cache: AlbumBackdropCache, _ remote: Remote, force: Bool = false) async throws -> AlbumBackdropCache.Snapshot {
        try await cache.synchronize(collection: collection, forceDownload: force,
                                    list: { await remote.items }, download: { try await remote.download($0) })
    }

    private actor Remote {
        var items: [AlbumBackdropCache.Item]
        var downloads = 0
        var payloads: [String: Data] = [:]
        var failingPath: String?
        init(items: [AlbumBackdropCache.Item]) { self.items = items }
        func set(items: [AlbumBackdropCache.Item], payloads: [String: Data] = [:], failingPath: String? = nil) {
            self.items = items
            self.payloads = payloads
            self.failingPath = failingPath
        }
        func download(_ item: AlbumBackdropCache.Item) throws -> Data {
            downloads += 1
            if item.path == failingPath { throw URLError(.networkConnectionLost) }
            return payloads[item.path] ?? Data(item.path.utf8)
        }
    }

    private actor Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func untilEntered() async {
            while !entered { await Task.yield() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
}
