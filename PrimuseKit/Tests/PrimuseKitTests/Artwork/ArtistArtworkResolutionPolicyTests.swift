import Foundation
import Testing
@testable import PrimuseKit

@Suite("Artist artwork resolution ownership")
struct ArtistArtworkResolutionPolicyTests {
    @Test("List and detail bytes cannot satisfy each other's cache key")
    func qualityKeys() {
        let small = ArtistArtworkResolutionPolicy.cacheID(baseID: "portrait", maximumPixels: 192)
        let full = ArtistArtworkResolutionPolicy.cacheID(baseID: "portrait", maximumPixels: 1536)
        #expect(small == "portrait")
        #expect(small != full)
        #expect(full == ArtistArtworkResolutionPolicy.cacheID(baseID: "portrait", maximumPixels: 768))
        #expect(ArtistArtworkResolutionPolicy.requestedPixels(for: 192) == 480)
        #expect(ArtistArtworkResolutionPolicy.requestedPixels(for: 768) == 1536)
        let catalog = ArtistArtworkResolutionPolicy.appleMusicCacheID(artistID: "portrait")
        #expect(catalog != small)
        #expect(catalog != full)
    }

    @Test("A list-first thumbnail does not mask a later detail request")
    func upgradeAfterThumbnail() async {
        let cache = Cache()
        let base = "server-portrait"
        let key = ArtistArtworkResolutionPolicy.cacheID(baseID: base, maximumPixels: 1536)
        await cache.put(Data([1]), key: base)
        let result = await ArtistArtworkResolutionPolicy.resolve(
            cached: { await cache.read(key) },
            fetch: { await cache.fetch(Data([2])) },
            store: { await cache.put($0, key: key) },
            fallback: { await cache.read(base) })
        #expect(result?.data == Data([2]))
        #expect(result?.isProvisional == false)
        #expect(await cache.requests == 1)
        #expect(await cache.read(base) == Data([1]))
        #expect(await cache.read(key) == Data([2]))
    }

    @Test("Offline fallback never becomes a full-quality hit and can upgrade next time")
    func offlineFallbackStaysProvisional() async {
        let cache = Cache()
        let base = "legacy-portrait"
        let key = ArtistArtworkResolutionPolicy.cacheID(baseID: base, maximumPixels: 1536)
        await cache.put(Data([1]), key: base)
        let offline = await ArtistArtworkResolutionPolicy.resolve(
            cached: { await cache.read(key) }, fetch: { await cache.fetch(nil) },
            store: { await cache.put($0, key: key) }, fallback: { await cache.read(base) })
        #expect(offline?.data == Data([1]))
        #expect(offline?.isProvisional == true)
        #expect(await cache.read(key) == nil)
        let online = await ArtistArtworkResolutionPolicy.resolve(
            cached: { await cache.read(key) }, fetch: { await cache.fetch(Data([2])) },
            store: { await cache.put($0, key: key) }, fallback: { await cache.read(base) })
        #expect(online?.data == Data([2]))
        #expect(online?.isProvisional == false)
        #expect(await cache.read(key) == Data([2]))
        let warm = await ArtistArtworkResolutionPolicy.resolve(
            cached: { await cache.read(key) }, fetch: { await cache.fetch(Data([3])) },
            store: { await cache.put($0, key: key) }, fallback: { nil })
        #expect(warm?.data == Data([2]))
        #expect(await cache.requests == 2)
    }

    @Test("With no old cache, only one thumbnail fallback is stored under the list key")
    func fetchedThumbnailStaysProvisional() async {
        let cache = Cache()
        let base = "cold-portrait"
        let key = ArtistArtworkResolutionPolicy.cacheID(baseID: base, maximumPixels: 1536)
        let result = await ArtistArtworkResolutionPolicy.resolve(
            cached: { await cache.read(key) }, fetch: { await cache.fetch(nil) },
            store: { await cache.put($0, key: key) }, fallback: {
                guard let data = await cache.fetch(Data([1])) else { return nil }
                await cache.put(data, key: base)
                return data
            })
        #expect(result?.data == Data([1]))
        #expect(result?.isProvisional == true)
        #expect(await cache.requests == 2)
        #expect(await cache.read(base) == Data([1]))
        #expect(await cache.read(key) == nil)
    }

    @Test("A cancelled fetch does not write a late high-resolution result")
    func cancellationDoesNotPublish() async {
        let cache = Cache()
        let gate = FetchGate()
        let task = Task {
            await ArtistArtworkResolutionPolicy.resolve(cached: { nil }, fetch: {
                await gate.fetch()
            }, store: { await cache.put($0, key: "full") }, fallback: { Data([1]) })
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.finish()
        #expect(await task.value == nil)
        #expect(await cache.read("full") == nil)
    }

    private actor FetchGate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var resultWaiter: CheckedContinuation<Data?, Never>?
        func fetch() async -> Data? {
            started = true
            startWaiter?.resume(); startWaiter = nil
            return await withCheckedContinuation { resultWaiter = $0 }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func finish() { resultWaiter?.resume(returning: Data([2])); resultWaiter = nil }
    }

    private actor Cache {
        private var values: [String: Data] = [:]
        private(set) var requests = 0
        func read(_ key: String) -> Data? { values[key] }
        func put(_ data: Data, key: String) { values[key] = data }
        func fetch(_ data: Data?) -> Data? { requests += 1; return data }
    }
}
