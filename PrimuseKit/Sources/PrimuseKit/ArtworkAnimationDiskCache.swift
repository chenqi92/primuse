import CryptoKit
import Foundation

/// A bounded, persistent cache for original animated-artwork resources.
///
/// Positive payloads and negative lookup results live in separate directories.
/// Callers own the cache location so app targets can choose an appropriate
/// caches container without introducing an application-layer dependency here.
public actor ArtworkAnimationDiskCache {
    public struct Configuration: Equatable, Sendable {
        public var maximumAssetBytes: Int
        public var capacityBytes: Int64
        public var evictionTargetBytes: Int64
        public var maximumNegativeEntryCount: Int

        public init(
            maximumAssetBytes: Int = 32 * 1024 * 1024,
            capacityBytes: Int64 = 192 * 1024 * 1024,
            evictionTargetBytes: Int64 = 160 * 1024 * 1024,
            maximumNegativeEntryCount: Int = 512
        ) {
            let boundedAssetBytes = max(1, maximumAssetBytes)
            let boundedCapacity = max(Int64(boundedAssetBytes), capacityBytes)
            self.maximumAssetBytes = boundedAssetBytes
            self.capacityBytes = boundedCapacity
            self.evictionTargetBytes = min(
                boundedCapacity,
                max(Int64(boundedAssetBytes), evictionTargetBytes)
            )
            self.maximumNegativeEntryCount = max(1, maximumNegativeEntryCount)
        }

        public static let `default` = Configuration()
    }

    public enum LookupResult: Equatable, Sendable {
        case asset(Data)
        case negative(expiresAt: Date)
    }

    public struct AssetRecord: Equatable, Sendable {
        public let data: Data
        public let expiresAt: Date?
        public let generation: String

        public init(data: Data, expiresAt: Date?, generation: String) {
            self.data = data
            self.expiresAt = expiresAt
            self.generation = generation
        }
    }

    public enum DetailedLookupResult: Equatable, Sendable {
        case asset(AssetRecord)
        case negative(expiresAt: Date)
    }

    public enum CacheError: Error, Equatable, Sendable {
        case emptyKey
        case emptyAsset
        case assetTooLarge(size: Int, maximum: Int)
    }

    private struct NegativeEntry: Codable, Sendable {
        let expiresAt: Date
    }

    private struct AssetMetadata: Codable, Sendable {
        static let currentVersion = 2

        let version: Int
        let expiresAt: Date?
        let generation: String

        init(expiresAt: Date?, generation: String) {
            self.version = Self.currentVersion
            self.expiresAt = expiresAt
            self.generation = generation
        }

        var isSupported: Bool {
            version == Self.currentVersion && !generation.isEmpty
        }
    }

    private struct FileEntry: Sendable {
        let url: URL
        let size: Int64
        let modificationDate: Date
    }

    private let directory: URL
    private let configuration: Configuration
    private let fileManager: FileManager

    private var assetsDirectory: URL {
        directory.appendingPathComponent("assets", isDirectory: true)
    }

    private var negativesDirectory: URL {
        directory.appendingPathComponent("negative", isDirectory: true)
    }

    private var assetMetadataDirectory: URL {
        directory.appendingPathComponent("asset-metadata", isDirectory: true)
    }

    public init(
        directory: URL,
        configuration: Configuration = .default
    ) {
        self.directory = directory
        self.configuration = configuration
        self.fileManager = .default
    }

    /// Returns a positive payload first when recovery from an interrupted write
    /// temporarily leaves both record types on disk.
    public func lookup(
        forKey key: String,
        now: Date = Date()
    ) async throws -> LookupResult? {
        switch try lookupDetailed(forKey: key, now: now) {
        case .asset(let record):
            return .asset(record.data)
        case .negative(let expiresAt):
            return .negative(expiresAt: expiresAt)
        case nil:
            return nil
        }
    }

    /// Atomically returns positive bytes together with their expiry metadata.
    /// Consumers that schedule expiry must use this form so a replacement
    /// cannot pair older bytes with newer metadata across actor calls.
    public func detailedLookup(
        forKey key: String,
        now: Date = Date()
    ) async throws -> DetailedLookupResult? {
        try lookupDetailed(forKey: key, now: now)
    }

    private func lookupDetailed(
        forKey key: String,
        now: Date
    ) throws -> DetailedLookupResult? {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()

        let assetURL = assetURL(forDigest: digest)
        if fileManager.fileExists(atPath: assetURL.path) {
            guard try isAcceptableAsset(at: assetURL),
                  let metadata = try validAssetMetadata(digest: digest),
                  metadata.expiresAt.map({ $0 > now }) ?? true else {
                try removePositiveValue(digest: digest)
                return try lookupNegativeDetailed(digest: digest, now: now)
            }

            let data = try Data(contentsOf: assetURL, options: .mappedIfSafe)
            try Task.checkCancellation()
            guard !data.isEmpty,
                  data.count <= configuration.maximumAssetBytes else {
                try removePositiveValue(digest: digest)
                return try lookupNegativeDetailed(digest: digest, now: now)
            }
            try touch(assetURL, at: now)
            try removeIfPresent(negativeURL(forDigest: digest))
            return .asset(AssetRecord(
                data: data,
                expiresAt: metadata.expiresAt,
                generation: metadata.generation
            ))
        }

        try removeIfPresent(assetMetadataURL(forDigest: digest))

        return try lookupNegativeDetailed(digest: digest, now: now)
    }

    /// Atomically stores the exact source bytes and makes this the authoritative
    /// value for the key. The payload is never transcoded by this cache.
    @discardableResult
    public func storeAsset(
        _ data: Data,
        forKey key: String,
        expiresAt: Date? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw CacheError.emptyAsset }
        guard data.count <= configuration.maximumAssetBytes else {
            throw CacheError.assetTooLarge(
                size: data.count,
                maximum: configuration.maximumAssetBytes
            )
        }

        let digest = try digest(forKey: key)
        try prepareDirectories()
        try Task.checkCancellation()

        return try writeAsset(data, digest: digest, expiresAt: expiresAt)
    }

    /// Stores the candidate only when neither a valid positive nor negative
    /// value exists. The check and write run in one actor turn so concurrent
    /// source loads cannot both observe a miss and overwrite one another.
    @discardableResult
    public func storeAssetIfValueMissing(
        _ data: Data,
        forKey key: String,
        expiresAt: Date? = nil,
        now: Date = Date()
    ) async throws -> String? {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw CacheError.emptyAsset }
        guard data.count <= configuration.maximumAssetBytes else {
            throw CacheError.assetTooLarge(
                size: data.count,
                maximum: configuration.maximumAssetBytes
            )
        }
        let digest = try digest(forKey: key)
        try prepareDirectories()
        guard try lookupDetailed(forKey: key, now: now) == nil else { return nil }
        try Task.checkCancellation()
        return try writeAsset(data, digest: digest, expiresAt: expiresAt)
    }

    private func writeAsset(
        _ data: Data,
        digest: String,
        expiresAt: Date?
    ) throws -> String {
        try Task.checkCancellation()

        // Removing the older metadata first makes an interrupted replacement
        // fail closed: a payload without valid metadata is discarded on read.
        try removeIfPresent(assetMetadataURL(forDigest: digest))
        try data.write(to: assetURL(forDigest: digest), options: .atomic)
        try Task.checkCancellation()
        let generation = UUID().uuidString
        let metadata = try JSONEncoder().encode(AssetMetadata(
            expiresAt: expiresAt,
            generation: generation
        ))
        try metadata.write(
            to: assetMetadataURL(forDigest: digest),
            options: .atomic
        )
        try removeIfPresent(negativeURL(forDigest: digest))
        try enforceAssetCapacity()
        return generation
    }

    /// Returns the expiry of a currently valid positive asset without changing
    /// its least-recently-used access time. A non-expiring asset returns `nil`.
    /// Missing, expired, or corrupt records are conservatively removed.
    public func assetExpirationDate(
        forKey key: String,
        now: Date = Date()
    ) async throws -> Date? {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()

        let assetURL = assetURL(forDigest: digest)
        guard fileManager.fileExists(atPath: assetURL.path) else {
            try removeIfPresent(assetMetadataURL(forDigest: digest))
            return nil
        }
        guard try isAcceptableAsset(at: assetURL),
              let metadata = try validAssetMetadata(digest: digest),
              metadata.expiresAt.map({ $0 > now }) ?? true else {
            try removePositiveValue(digest: digest)
            return nil
        }
        return metadata.expiresAt
    }

    /// Persists a bounded negative lookup. Recording a valid negative result is
    /// a replacement operation, so any older positive payload is removed.
    public func storeNegative(
        forKey key: String,
        expiresAt: Date,
        now: Date = Date()
    ) async throws {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()

        try writeNegative(digest: digest, expiresAt: expiresAt, now: now)
    }

    /// Records a negative result only when no valid positive asset currently
    /// exists. This prevents an older inspection from replacing a concurrently
    /// refreshed asset that it never observed.
    @discardableResult
    public func storeNegativeIfAssetMissing(
        forKey key: String,
        expiresAt: Date,
        now: Date = Date()
    ) async throws -> Bool {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()
        let assetURL = assetURL(forDigest: digest)
        if fileManager.fileExists(atPath: assetURL.path),
           let metadata = try validAssetMetadata(digest: digest),
           metadata.expiresAt.map({ $0 > now }) ?? true {
            return false
        }
        try removePositiveValue(digest: digest)
        try writeNegative(digest: digest, expiresAt: expiresAt, now: now)
        return expiresAt > now
    }

    /// Atomically replaces only the exact positive generation inspected by the
    /// caller. A newer generation survives a stale static-image result.
    @discardableResult
    public func replaceAssetWithNegative(
        forKey key: String,
        matchingGeneration expectedGeneration: String,
        expiresAt: Date,
        now: Date = Date()
    ) async throws -> Bool {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()
        let assetURL = assetURL(forDigest: digest)
        guard fileManager.fileExists(atPath: assetURL.path),
              let metadata = try validAssetMetadata(digest: digest),
              metadata.generation == expectedGeneration,
              metadata.expiresAt.map({ $0 > now }) ?? true else {
            return false
        }
        try writeNegative(digest: digest, expiresAt: expiresAt, now: now)
        return expiresAt > now
    }

    private func writeNegative(
        digest: String,
        expiresAt: Date,
        now: Date
    ) throws {
        try Task.checkCancellation()

        let negativeURL = negativeURL(forDigest: digest)
        guard expiresAt > now else {
            try removeIfPresent(negativeURL)
            return
        }

        let encoded = try JSONEncoder().encode(NegativeEntry(expiresAt: expiresAt))
        try Task.checkCancellation()
        try encoded.write(to: negativeURL, options: .atomic)
        try removePositiveValue(digest: digest)
        try pruneNegativeEntries(now: now)
    }

    public func removeValue(forKey key: String) async throws {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()
        try removePositiveValue(digest: digest)
        try Task.checkCancellation()
        try removeIfPresent(negativeURL(forDigest: digest))
    }

    /// Clears only a retry suppression record while preserving any validated
    /// positive asset for the same identity (for example after a network-path
    /// change).
    public func removeNegative(forKey key: String) async throws {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()
        try removeIfPresent(negativeURL(forDigest: digest))
    }

    /// Removes only the exact positive generation observed by the caller. A
    /// concurrently refreshed asset survives even when its expiry is unchanged.
    @discardableResult
    public func removeAsset(
        forKey key: String,
        matchingGeneration expectedGeneration: String
    ) async throws -> Bool {
        try Task.checkCancellation()
        let digest = try digest(forKey: key)
        try prepareDirectories()
        let assetURL = assetURL(forDigest: digest)
        guard fileManager.fileExists(atPath: assetURL.path),
              let metadata = try validAssetMetadata(digest: digest),
              metadata.generation == expectedGeneration else {
            return false
        }
        try removePositiveValue(digest: digest)
        return true
    }

    /// Removes expired/corrupt records and restores both cache bounds.
    public func performMaintenance(now: Date = Date()) async throws {
        try Task.checkCancellation()
        try prepareDirectories()
        try prunePositiveEntries(now: now)
        try pruneNegativeEntries(now: now)
        try enforceAssetCapacity()
    }

    private func lookupNegativeDetailed(
        digest: String,
        now: Date
    ) throws -> DetailedLookupResult? {
        try Task.checkCancellation()
        let url = negativeURL(forDigest: digest)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let entry: NegativeEntry
        do {
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            entry = try JSONDecoder().decode(NegativeEntry.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try removeIfPresent(url)
            return nil
        }

        guard entry.expiresAt > now else {
            try removeIfPresent(url)
            return nil
        }
        try touch(url, at: now)
        return .negative(expiresAt: entry.expiresAt)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: negativesDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: assetMetadataDirectory,
            withIntermediateDirectories: true
        )
    }

    private func digest(forKey key: String) throws -> String {
        guard !key.isEmpty else { throw CacheError.emptyKey }
        return SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func assetURL(forDigest digest: String) -> URL {
        assetsDirectory.appendingPathComponent("\(digest).asset", isDirectory: false)
    }

    private func negativeURL(forDigest digest: String) -> URL {
        negativesDirectory.appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func assetMetadataURL(forDigest digest: String) -> URL {
        assetMetadataDirectory.appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func validAssetMetadata(digest: String) throws -> AssetMetadata? {
        let url = assetMetadataURL(forDigest: digest)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            let metadata = try JSONDecoder().decode(AssetMetadata.self, from: data)
            return metadata.isSupported ? metadata : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func isAcceptableAsset(at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else { return false }
        return fileSize > 0 && fileSize <= configuration.maximumAssetBytes
    }

    private func touch(_ url: URL, at date: Date) throws {
        try fileManager.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Metadata is removed first so interruption cannot leave a potentially
    /// expired payload looking like a non-expiring asset.
    private func removePositiveValue(digest: String) throws {
        try removeIfPresent(assetMetadataURL(forDigest: digest))
        try Task.checkCancellation()
        try removeIfPresent(assetURL(forDigest: digest))
    }

    /// Capacity accounting intentionally includes payload bytes only. Metadata
    /// is bounded one-to-one with retained payloads and removed alongside them.
    private func enforceAssetCapacity() throws {
        var entries = try fileEntries(
            in: assetsDirectory,
            pathExtension: "asset"
        )
        let total = entries.reduce(Int64(0)) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.size)
            return overflow ? Int64.max : sum
        }
        guard total > configuration.capacityBytes else { return }

        entries.sort(by: oldestFirst)
        var remaining = total
        for entry in entries where remaining > configuration.evictionTargetBytes {
            try Task.checkCancellation()
            try removePositiveValue(
                digest: entry.url.deletingPathExtension().lastPathComponent
            )
            remaining = max(0, remaining - entry.size)
        }
    }

    private func prunePositiveEntries(now: Date) throws {
        let assets = try fileEntries(
            in: assetsDirectory,
            pathExtension: "asset"
        )
        var retainedDigests = Set<String>()
        retainedDigests.reserveCapacity(assets.count)

        for entry in assets {
            try Task.checkCancellation()
            let digest = entry.url.deletingPathExtension().lastPathComponent
            guard try isAcceptableAsset(at: entry.url),
                  let metadata = try validAssetMetadata(digest: digest),
                  metadata.expiresAt.map({ $0 > now }) ?? true else {
                try removePositiveValue(digest: digest)
                continue
            }
            retainedDigests.insert(digest)
        }

        let metadataURLs = try fileManager.contentsOfDirectory(
            at: assetMetadataDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in metadataURLs where url.pathExtension == "json" {
            try Task.checkCancellation()
            let digest = url.deletingPathExtension().lastPathComponent
            guard retainedDigests.contains(digest) else {
                try removeIfPresent(url)
                continue
            }
        }
    }

    private func pruneNegativeEntries(now: Date) throws {
        var retained: [FileEntry] = []
        let urls = try fileManager.contentsOfDirectory(
            at: negativesDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )

        for url in urls where url.pathExtension == "json" {
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(NegativeEntry.self, from: data),
                  record.expiresAt > now else {
                try removeIfPresent(url)
                continue
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            guard values.isRegularFile == true else {
                try removeIfPresent(url)
                continue
            }
            retained.append(FileEntry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }

        guard retained.count > configuration.maximumNegativeEntryCount else { return }
        retained.sort(by: oldestFirst)
        for entry in retained.prefix(
            retained.count - configuration.maximumNegativeEntryCount
        ) {
            try Task.checkCancellation()
            try removeIfPresent(entry.url)
        }
    }

    private func fileEntries(
        in directory: URL,
        pathExtension: String
    ) throws -> [FileEntry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        var entries: [FileEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls where url.pathExtension == pathExtension {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            guard values.isRegularFile == true else { continue }
            entries.append(FileEntry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }
        return entries
    }

    private func oldestFirst(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.modificationDate != rhs.modificationDate {
            return lhs.modificationDate < rhs.modificationDate
        }
        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
    }
}
