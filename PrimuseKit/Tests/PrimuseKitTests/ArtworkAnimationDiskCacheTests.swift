import CryptoKit
import Foundation
import Testing
@testable import PrimuseKit

@Suite("Artwork animation disk cache")
struct ArtworkAnimationDiskCacheTests {
    @Test("Positive assets persist as raw bytes under a SHA-256 key")
    func positiveAssetPersistenceAndAccessTime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = "subsonic|album/animated-cover"
        let payload = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        let cache = ArtworkAnimationDiskCache(directory: directory)
        try await cache.storeAsset(payload, forKey: key)

        let expectedURL = assetURL(in: directory, key: key)
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        #expect(try Data(contentsOf: expectedURL) == payload)
        #expect(try regularFiles(in: directory.appendingPathComponent("assets")).count == 1)
        #expect(
            try regularFiles(in: directory.appendingPathComponent("asset-metadata")).count == 1
        )
        #expect(try await cache.assetExpirationDate(forKey: key) == nil)

        let oldDate = Date(timeIntervalSince1970: 10)
        try setModificationDate(oldDate, for: expectedURL)
        let accessDate = Date(timeIntervalSince1970: 1_000)
        let reopened = ArtworkAnimationDiskCache(directory: directory)
        #expect(try await reopened.lookup(forKey: key, now: accessDate) == .asset(payload))

        let touchedDate = try #require(
            expectedURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        )
        #expect(touchedDate >= accessDate)
    }

    @Test("Positive asset expiry persists without changing payload bytes")
    func positiveAssetExpiryPersists() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = "expiring-motion-artwork"
        let payload = Data([0x47, 0x49, 0x46])
        let now = Date(timeIntervalSince1970: 20_000)
        let expiry = now.addingTimeInterval(300)
        let cache = ArtworkAnimationDiskCache(directory: directory)
        let generation = try await cache.storeAsset(
            payload,
            forKey: key,
            expiresAt: expiry
        )

        #expect(try Data(contentsOf: assetURL(in: directory, key: key)) == payload)
        let reopened = ArtworkAnimationDiskCache(directory: directory)
        #expect(
            try await reopened.lookup(forKey: key, now: now) == .asset(payload)
        )
        #expect(
            try await reopened.assetExpirationDate(forKey: key, now: now) == expiry
        )
        #expect(
            try await reopened.detailedLookup(forKey: key, now: now)
                == .asset(.init(
                    data: payload,
                    expiresAt: expiry,
                    generation: generation
                ))
        )
    }

    @Test("Conditional expiry removal preserves a refreshed generation")
    func conditionalExpiryRemoval() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkAnimationDiskCache(directory: directory)
        let key = "refreshed-motion-artwork"
        let payload = Data([1, 2, 3])
        let firstExpiry = Date(timeIntervalSince1970: 40_000)
        let refreshedExpiry = firstExpiry

        let firstGeneration = try await cache.storeAsset(
            payload,
            forKey: key,
            expiresAt: firstExpiry
        )
        let refreshedGeneration = try await cache.storeAsset(
            payload,
            forKey: key,
            expiresAt: refreshedExpiry
        )
        #expect(firstGeneration != refreshedGeneration)

        #expect(
            try await cache.removeAsset(
                forKey: key,
                matchingGeneration: firstGeneration
            ) == false
        )
        #expect(
            try await cache.detailedLookup(
                forKey: key,
                now: firstExpiry.addingTimeInterval(-1)
            ) == .asset(.init(
                data: payload,
                expiresAt: refreshedExpiry,
                generation: refreshedGeneration
            ))
        )
        #expect(
            try await cache.removeAsset(
                forKey: key,
                matchingGeneration: refreshedGeneration
            )
        )
        #expect(try await cache.lookup(forKey: key) == nil)
    }

    @Test("Conditional negative writes preserve a refreshed generation")
    func conditionalNegativeReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkAnimationDiskCache(directory: directory)
        let key = "refreshed-before-static-inspection-finished"
        let first = Data([1, 2, 3])
        let refreshed = Data([4, 5, 6])
        let now = Date(timeIntervalSince1970: 50_000)
        let expiry = now.addingTimeInterval(300)
        let firstGeneration = try await cache.storeAsset(first, forKey: key)
        let refreshedGeneration = try await cache.storeAsset(refreshed, forKey: key)

        #expect(
            try await cache.replaceAssetWithNegative(
                forKey: key,
                matchingGeneration: firstGeneration,
                expiresAt: expiry,
                now: now
            ) == false
        )
        #expect(
            try await cache.detailedLookup(forKey: key, now: now)
                == .asset(.init(
                    data: refreshed,
                    expiresAt: nil,
                    generation: refreshedGeneration
                ))
        )
        #expect(
            try await cache.storeNegativeIfAssetMissing(
                forKey: key,
                expiresAt: expiry,
                now: now
            ) == false
        )
        #expect(
            try await cache.replaceAssetWithNegative(
                forKey: key,
                matchingGeneration: refreshedGeneration,
                expiresAt: expiry,
                now: now
            )
        )
        #expect(try await cache.lookup(forKey: key, now: now) == .negative(expiresAt: expiry))
    }

    @Test("Only one concurrent missing-value candidate becomes authoritative")
    func concurrentMissingValueStore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkAnimationDiskCache(directory: directory)
        let key = "concurrent-first-writer"
        let first = Data([1, 1, 1])
        let second = Data([2, 2, 2])

        async let firstGeneration = cache.storeAssetIfValueMissing(first, forKey: key)
        async let secondGeneration = cache.storeAssetIfValueMissing(second, forKey: key)
        let generations = try await [firstGeneration, secondGeneration]
        #expect(generations.compactMap { $0 }.count == 1)

        let result = try await cache.lookup(forKey: key)
        #expect(result == .asset(first) || result == .asset(second))
    }

    @Test("Missing-only negative writes do not replace a concurrently stored asset")
    func missingOnlyNegativeWrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkAnimationDiskCache(directory: directory)
        let key = "candidate-became-available"
        let payload = Data([7, 8, 9])
        let now = Date(timeIntervalSince1970: 60_000)
        let expiry = now.addingTimeInterval(300)

        #expect(
            try await cache.storeNegativeIfAssetMissing(
                forKey: key,
                expiresAt: expiry,
                now: now
            )
        )
        try await cache.storeAsset(payload, forKey: key)
        #expect(
            try await cache.storeNegativeIfAssetMissing(
                forKey: key,
                expiresAt: expiry,
                now: now
            ) == false
        )
        #expect(try await cache.lookup(forKey: key, now: now) == .asset(payload))
    }

    @Test("Expired positive assets and metadata are removed")
    func positiveAssetExpiryRemovesValue() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = "expired-motion-artwork"
        let payload = Data([1, 2, 3])
        let expiry = Date(timeIntervalSince1970: 30_000)
        let cache = ArtworkAnimationDiskCache(directory: directory)
        try await cache.storeAsset(payload, forKey: key, expiresAt: expiry)

        #expect(try await cache.lookup(forKey: key, now: expiry) == nil)
        #expect(!FileManager.default.fileExists(atPath: assetURL(in: directory, key: key).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: assetMetadataURL(in: directory, key: key).path
            )
        )
        #expect(try await cache.assetExpirationDate(forKey: key, now: expiry) == nil)
    }

    @Test("Missing or corrupt positive metadata fails closed")
    func corruptPositiveMetadataRemovesAsset() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkAnimationDiskCache(directory: directory)
        try await cache.storeAsset(Data([1]), forKey: "corrupt")
        let corruptMetadataURL = assetMetadataURL(in: directory, key: "corrupt")
        try Data("{}".utf8).write(to: corruptMetadataURL, options: .atomic)

        #expect(try await cache.lookup(forKey: "corrupt") == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: assetURL(in: directory, key: "corrupt").path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: corruptMetadataURL.path))

        try await cache.storeAsset(Data([2]), forKey: "missing")
        let missingMetadataURL = assetMetadataURL(in: directory, key: "missing")
        try FileManager.default.removeItem(at: missingMetadataURL)
        #expect(try await cache.lookup(forKey: "missing") == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: assetURL(in: directory, key: "missing").path
            )
        )
    }

    @Test("Negative entries persist and are removed after expiry")
    func negativePersistenceAndExpiry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = "album-without-motion"
        let now = Date(timeIntervalSince1970: 10_000)
        let expiry = now.addingTimeInterval(120)
        let cache = ArtworkAnimationDiskCache(directory: directory)
        try await cache.storeNegative(forKey: key, expiresAt: expiry, now: now)

        let reopened = ArtworkAnimationDiskCache(directory: directory)
        #expect(
            try await reopened.lookup(forKey: key, now: now.addingTimeInterval(30))
                == .negative(expiresAt: expiry)
        )
        #expect(try await reopened.lookup(forKey: key, now: expiry) == nil)
        #expect(
            try regularFiles(in: directory.appendingPathComponent("negative")).isEmpty
        )
    }

    @Test("Positive and negative writes replace the previous value")
    func replacementSemantics() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = "replace-me"
        let first = Data([1, 2, 3])
        let replacement = Data([4, 5, 6, 7])
        let now = Date()
        let cache = ArtworkAnimationDiskCache(directory: directory)

        try await cache.storeAsset(first, forKey: key)
        try await cache.storeAsset(replacement, forKey: key)
        #expect(try await cache.lookup(forKey: key) == .asset(replacement))
        #expect(try regularFiles(in: directory.appendingPathComponent("assets")).count == 1)

        try await cache.storeNegative(
            forKey: key,
            expiresAt: now.addingTimeInterval(300),
            now: now
        )
        #expect(
            try await cache.lookup(forKey: key, now: now)
                == .negative(expiresAt: now.addingTimeInterval(300))
        )
        #expect(try regularFiles(in: directory.appendingPathComponent("assets")).isEmpty)
        #expect(
            try regularFiles(in: directory.appendingPathComponent("asset-metadata")).isEmpty
        )

        try await cache.storeAsset(first, forKey: key)
        #expect(try await cache.lookup(forKey: key) == .asset(first))
        #expect(try regularFiles(in: directory.appendingPathComponent("negative")).isEmpty)

        try await cache.removeValue(forKey: key)
        #expect(try regularFiles(in: directory.appendingPathComponent("assets")).isEmpty)
        #expect(
            try regularFiles(in: directory.appendingPathComponent("asset-metadata")).isEmpty
        )
    }

    @Test("Clearing retry suppression does not remove a positive asset")
    func removeNegativePreservesPositiveAsset() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkAnimationDiskCache(directory: directory)
        let payload = Data([1, 2, 3])

        try await cache.storeAsset(payload, forKey: "positive")
        try await cache.removeNegative(forKey: "positive")
        #expect(try await cache.lookup(forKey: "positive") == .asset(payload))

        let now = Date()
        try await cache.storeNegative(
            forKey: "negative",
            expiresAt: now.addingTimeInterval(60),
            now: now
        )
        try await cache.removeNegative(forKey: "negative")
        #expect(try await cache.lookup(forKey: "negative", now: now) == nil)
    }

    @Test("Capacity eviction honors access time and returns to its target waterline")
    func capacityEvictionUsesLeastRecentlyAccessedOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = ArtworkAnimationDiskCache.Configuration(
            maximumAssetBytes: 5,
            capacityBytes: 12,
            evictionTargetBytes: 10,
            maximumNegativeEntryCount: 4
        )
        let cache = ArtworkAnimationDiskCache(
            directory: directory,
            configuration: configuration
        )
        let first = Data(repeating: 1, count: 5)
        let second = Data(repeating: 2, count: 5)
        let third = Data(repeating: 3, count: 5)

        try await cache.storeAsset(first, forKey: "first")
        try await cache.storeAsset(second, forKey: "second")
        try setModificationDate(
            Date(timeIntervalSince1970: 100),
            for: assetURL(in: directory, key: "first")
        )
        try setModificationDate(
            Date(timeIntervalSince1970: 200),
            for: assetURL(in: directory, key: "second")
        )

        // Refreshing the first item makes the untouched second item the oldest.
        #expect(
            try await cache.lookup(
                forKey: "first",
                now: Date(timeIntervalSince1970: 300)
            ) == .asset(first)
        )
        try await cache.storeAsset(third, forKey: "third")

        #expect(try await cache.lookup(forKey: "first") == .asset(first))
        #expect(try await cache.lookup(forKey: "second") == nil)
        #expect(try await cache.lookup(forKey: "third") == .asset(third))
        #expect(
            !FileManager.default.fileExists(
                atPath: assetMetadataURL(in: directory, key: "second").path
            )
        )
        let files = try regularFiles(in: directory.appendingPathComponent("assets"))
        #expect(files.count == 2)
        let totalSize = try files.reduce(0) { total, url in
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return total + fileSize
        }
        #expect(totalSize <= 10)
    }

    @Test("Capacity accounting excludes bounded metadata sidecars")
    func capacityCountsPayloadBytesOnly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = ArtworkAnimationDiskCache.Configuration(
            maximumAssetBytes: 2,
            capacityBytes: 4,
            evictionTargetBytes: 2
        )
        let cache = ArtworkAnimationDiskCache(
            directory: directory,
            configuration: configuration
        )
        try await cache.storeAsset(
            Data([1, 2]),
            forKey: "first",
            expiresAt: Date.distantFuture
        )
        try await cache.storeAsset(
            Data([3, 4]),
            forKey: "second",
            expiresAt: Date.distantFuture
        )

        #expect(try await cache.lookup(forKey: "first") == .asset(Data([1, 2])))
        #expect(try await cache.lookup(forKey: "second") == .asset(Data([3, 4])))
        #expect(try regularFiles(in: directory.appendingPathComponent("assets")).count == 2)
        #expect(
            try regularFiles(in: directory.appendingPathComponent("asset-metadata")).count == 2
        )
    }

    @Test("Maintenance removes expired assets and orphaned metadata")
    func maintenanceCleansPositiveMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 40_000)
        let cache = ArtworkAnimationDiskCache(directory: directory)
        try await cache.storeAsset(
            Data([1]),
            forKey: "expired",
            expiresAt: now.addingTimeInterval(-1)
        )
        try await cache.storeAsset(Data([2]), forKey: "retained")
        let orphanURL = directory
            .appendingPathComponent("asset-metadata", isDirectory: true)
            .appendingPathComponent("orphan.json")
        try Data("orphan".utf8).write(to: orphanURL, options: .atomic)

        try await cache.performMaintenance(now: now)

        #expect(try await cache.lookup(forKey: "expired", now: now) == nil)
        #expect(try await cache.lookup(forKey: "retained", now: now) == .asset(Data([2])))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: assetMetadataURL(in: directory, key: "expired").path
            )
        )
    }

    @Test("Oversized and empty assets are rejected without a partial file")
    func rejectsInvalidAssetSizes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = ArtworkAnimationDiskCache.Configuration(
            maximumAssetBytes: 4,
            capacityBytes: 16,
            evictionTargetBytes: 8
        )
        let cache = ArtworkAnimationDiskCache(
            directory: directory,
            configuration: configuration
        )

        await #expect(
            throws: ArtworkAnimationDiskCache.CacheError.assetTooLarge(
                size: 5,
                maximum: 4
            )
        ) {
            try await cache.storeAsset(Data(repeating: 7, count: 5), forKey: "large")
        }
        await #expect(throws: ArtworkAnimationDiskCache.CacheError.emptyAsset) {
            try await cache.storeAsset(Data(), forKey: "empty")
        }
        #expect(try regularFiles(in: directory.appendingPathComponent("assets")).isEmpty)
    }

    @Test("Negative cache count is bounded by least-recent access")
    func negativeCountLimitUsesLeastRecentlyAccessedOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = ArtworkAnimationDiskCache.Configuration(
            maximumAssetBytes: 8,
            capacityBytes: 32,
            evictionTargetBytes: 24,
            maximumNegativeEntryCount: 2
        )
        let cache = ArtworkAnimationDiskCache(
            directory: directory,
            configuration: configuration
        )
        let now = Date()
        let expiry = now.addingTimeInterval(600)
        try await cache.storeNegative(forKey: "first", expiresAt: expiry, now: now)
        try await cache.storeNegative(forKey: "second", expiresAt: expiry, now: now)
        try setModificationDate(
            Date(timeIntervalSince1970: 100),
            for: negativeURL(in: directory, key: "first")
        )
        try setModificationDate(
            Date(timeIntervalSince1970: 200),
            for: negativeURL(in: directory, key: "second")
        )

        #expect(try await cache.lookup(forKey: "first", now: now) != nil)
        try await cache.storeNegative(forKey: "third", expiresAt: expiry, now: now)

        #expect(try await cache.lookup(forKey: "first", now: now) != nil)
        #expect(try await cache.lookup(forKey: "second", now: now) == nil)
        #expect(try await cache.lookup(forKey: "third", now: now) != nil)
        #expect(
            try regularFiles(in: directory.appendingPathComponent("negative")).count == 2
        )
    }

    @Test("A task cancelled before entry does not mutate the cache")
    func cancellationBeforeOperation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkAnimationDiskCache(directory: directory)

        let task = Task<Void, any Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cache.storeAsset(Data([1, 2, 3]), forKey: "cancelled")
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try regularFiles(in: directory.appendingPathComponent("assets")).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkAnimationDiskCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assetURL(in directory: URL, key: String) -> URL {
        directory
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("\(digest(key)).asset")
    }

    private func negativeURL(in directory: URL, key: String) -> URL {
        directory
            .appendingPathComponent("negative", isDirectory: true)
            .appendingPathComponent("\(digest(key)).json")
    }

    private func assetMetadataURL(in directory: URL, key: String) -> URL {
        directory
            .appendingPathComponent("asset-metadata", isDirectory: true)
            .appendingPathComponent("\(digest(key)).json")
    }

    private func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }
}
