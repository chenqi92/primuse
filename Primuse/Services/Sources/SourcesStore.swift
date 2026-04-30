import Foundation
import PrimuseKit

@MainActor
@Observable
final class SourcesStore {
    /// Backing storage including soft-deleted entries. `sources` filters this
    /// for normal UI use; `recentlyDeletedSources` exposes the deleted ones.
    private(set) var allSources: [MusicSource]

    /// Live (non-deleted) sources for normal UI use.
    var sources: [MusicSource] { allSources.filter { !$0.isDeleted } }

    /// Soft-deleted sources, newest deletion first.
    var recentlyDeletedSources: [MusicSource] {
        allSources
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    private let storeURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.storeURL = directory.appendingPathComponent("sources.json")
        self.allSources = []

        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func source(id: String) -> MusicSource? {
        allSources.first(where: { $0.id == id })
    }

    func add(_ source: MusicSource) {
        upsert(source)
    }

    func upsert(_ source: MusicSource) {
        var stamped = source
        stamped.modifiedAt = Date()
        if let index = allSources.firstIndex(where: { $0.id == stamped.id }) {
            allSources[index] = stamped
        } else {
            allSources.append(stamped)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        persist()
        notifyChanged([stamped.id])
    }

    /// User-facing edit. Bumps `modifiedAt` and triggers an iCloud sync push.
    func update(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return }
        mutate(&allSources[index])
        allSources[index].modifiedAt = Date()
        persist()
        notifyChanged([sourceID])
    }

    /// Device-local update — used by the scanner for fields that are derived
    /// state (`lastScannedAt`, `songCount`, `deviceId`). Persists to disk but
    /// does not bump `modifiedAt` or notify the cloud sync.
    func updateLocal(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return }
        mutate(&allSources[index])
        persist()
    }

    /// Soft-delete: hide from UI but keep on disk + CloudKit until pruned.
    func remove(id: String) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        allSources[index].isDeleted = true
        allSources[index].deletedAt = Date()
        allSources[index].modifiedAt = Date()
        persist()
        notifyChanged([id])
    }

    /// Restore a soft-deleted source from the recycle bin.
    func restore(id: String) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        allSources[index].isDeleted = false
        allSources[index].deletedAt = nil
        allSources[index].modifiedAt = Date()
        persist()
        notifyChanged([id])
    }

    /// Permanently remove a source (manual purge or 30-day prune).
    func permanentlyDelete(id: String) {
        allSources.removeAll { $0.id == id }
        persist()
        NotificationCenter.default.post(
            name: .primuseSourceDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Sweep soft-deleted sources older than `threshold` and remove them for
    /// good. Called on launch with a 30-day threshold.
    func pruneSources(deletedBefore threshold: Date) {
        let toPrune = allSources.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        for source in toPrune {
            permanentlyDelete(id: source.id)
        }
    }

    /// Remove a source in response to a remote permanent-delete event. No
    /// notification fires (which would echo back to CloudKit).
    func removeFromRemote(id: String) {
        allSources.removeAll { $0.id == id }
        persist()
    }

    /// Apply a source pulled from CloudKit. Preserves device-local fields
    /// (`lastScannedAt`, `songCount`) on the existing record if any.
    func upsertFromRemote(_ remote: MusicSource) {
        var merged = remote
        if let existing = allSources.first(where: { $0.id == remote.id }) {
            merged.lastScannedAt = existing.lastScannedAt
            merged.songCount = existing.songCount
        }
        if let index = allSources.firstIndex(where: { $0.id == merged.id }) {
            allSources[index] = merged
        } else {
            allSources.append(merged)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        persist()
    }

    private func notifyChanged(_ ids: [String]) {
        NotificationCenter.default.post(
            name: .primuseSourcesDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode([MusicSource].self, from: data) else {
            allSources = []
            return
        }

        allSources = decoded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        guard let data = try? encoder.encode(allSources) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
