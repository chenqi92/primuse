import CryptoKit
import Foundation

/// A directory snapshot is published only after every image is available locally.
/// Remote paths identify images; short-lived download URLs and credentials are never persisted.
public actor AlbumBackdropCache {
    public struct Collection: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let sourceID: String
        public let songID: String
        public let title: String

        public init(id: String, sourceID: String, songID: String, title: String) {
            self.id = id
            self.sourceID = sourceID
            self.songID = songID
            self.title = title
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public let path: String
        public let size: Int64
        public let modified: Date?
        public let providerID: String?
        public let revision: String?

        public init(path: String, size: Int64, modified: Date? = nil, providerID: String? = nil, revision: String? = nil) {
            self.path = path
            self.size = size
            self.modified = modified
            self.providerID = providerID
            self.revision = revision
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let item: Item
        public let assetID: String
    }

    public struct Snapshot: Codable, Sendable, Equatable, Identifiable {
        public let collection: Collection
        public let entries: [Entry]
        public let checkedAt: Date
        public var id: String { collection.id }
    }

    public struct Usage: Sendable, Identifiable {
        public let snapshot: Snapshot
        public let bytes: Int64
        public var id: String { snapshot.id }
    }

    private struct Job {
        let id: UUID
        let forceDownload: Bool
        let task: Task<Snapshot, Error>
    }

    private let directory: URL
    private var jobs: [String: Job] = [:]
    private let manager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public func snapshot(forKey key: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: manifestURL(key)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.id == key else { return nil }
        return snapshot
    }

    public func fileURL(for entry: Entry, collectionKey key: String) -> URL? {
        guard entry.assetID.count == 64, entry.assetID.allSatisfy({ $0.isHexDigit }) else { return nil }
        let url = collectionURL(key).appendingPathComponent(entry.assetID + ".image")
        return manager.fileExists(atPath: url.path) ? url : nil
    }

    public func needsRefresh(forKey key: String, interval: TimeInterval?, now: Date = Date()) -> Bool {
        guard let snapshot = snapshot(forKey: key) else { return true }
        if snapshot.entries.contains(where: { fileURL(for: $0, collectionKey: key) == nil }) { return true }
        guard let interval else { return false }
        return now.timeIntervalSince(snapshot.checkedAt) >= interval
    }

    public func synchronize(
        collection: Collection,
        forceDownload: Bool = false,
        now: Date = Date(),
        list: @escaping @Sendable () async throws -> [Item],
        download: @escaping @Sendable (Item) async throws -> Data
    ) async throws -> Snapshot {
        if let job = jobs[collection.id] {
            if !forceDownload || job.forceDownload { return try await job.task.value }
            job.task.cancel()
        }
        let id = UUID()
        let task = Task {
            try await perform(collection: collection, jobID: id, forceDownload: forceDownload,
                              now: now, list: list, download: download)
        }
        jobs[collection.id] = Job(id: id, forceDownload: forceDownload, task: task)
        defer {
            if jobs[collection.id]?.id == id { jobs[collection.id] = nil }
        }
        return try await task.value
    }

    public func remove(forKey key: String) throws {
        jobs.removeValue(forKey: key)?.task.cancel()
        let url = collectionURL(key)
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
    }

    public func cancelSynchronizations() {
        for key in Array(jobs.keys) { cancelSynchronization(forKey: key) }
    }

    public func cancelSynchronization(forKey key: String) {
        jobs.removeValue(forKey: key)?.task.cancel()
        prune(key: key, keeping: snapshot(forKey: key)?.entries ?? [])
    }

    public func usage() -> [Usage] {
        let folders = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  collectionURL(snapshot.id).lastPathComponent == folder.lastPathComponent else { return nil }
            let urls = Set(snapshot.entries.compactMap { fileURL(for: $0, collectionKey: snapshot.id) })
            let bytes = urls.reduce(Int64(0)) { total, url in
                return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return Usage(snapshot: snapshot, bytes: bytes)
        }.sorted { $0.snapshot.collection.title.localizedStandardCompare($1.snapshot.collection.title) == .orderedAscending }
    }

    private func perform(
        collection: Collection,
        jobID: UUID,
        forceDownload: Bool,
        now: Date,
        list: @Sendable () async throws -> [Item],
        download: @Sendable (Item) async throws -> Data
    ) async throws -> Snapshot {
        let key = collection.id
        let previous = snapshot(forKey: key)
        do {
            let items = try await list()
            try checkJob(key, jobID)
            var entries: [Entry] = []
            var seen = Set<String>()
            for item in items where seen.insert(item.path).inserted {
                try checkJob(key, jobID)
                if !forceDownload,
                   let old = previous?.entries.first(where: { $0.item == item }),
                   fileURL(for: old, collectionKey: key) != nil {
                    entries.append(old)
                    continue
                }
                let data = try await download(item)
                try checkJob(key, jobID)
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                let entry = Entry(item: item, assetID: Self.hash(data))
                try manager.createDirectory(at: collectionURL(key), withIntermediateDirectories: true)
                let url = collectionURL(key).appendingPathComponent(entry.assetID + ".image")
                try data.write(to: url, options: .atomic)
                entries.append(entry)
            }
            try checkJob(key, jobID)
            let snapshot = Snapshot(collection: collection, entries: entries, checkedAt: now)
            try manager.createDirectory(at: collectionURL(key), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: manifestURL(key), options: .atomic)
            prune(key: key, keeping: entries)
            return snapshot
        } catch {
            if jobs[key]?.id == jobID { prune(key: key, keeping: previous?.entries ?? []) }
            throw error
        }
    }

    private func checkJob(_ key: String, _ id: UUID) throws {
        try Task.checkCancellation()
        guard jobs[key]?.id == id else { throw CancellationError() }
    }

    private func prune(key: String, keeping entries: [Entry]) {
        let retained = Set(entries.map { $0.assetID + ".image" })
        let files = (try? manager.contentsOfDirectory(at: collectionURL(key), includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "image" && !retained.contains(file.lastPathComponent) {
            try? manager.removeItem(at: file)
        }
    }

    private func collectionURL(_ key: String) -> URL {
        directory.appendingPathComponent(Self.hash(Data(key.utf8)), isDirectory: true)
    }

    private func manifestURL(_ key: String) -> URL {
        collectionURL(key).appendingPathComponent("manifest.json")
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
