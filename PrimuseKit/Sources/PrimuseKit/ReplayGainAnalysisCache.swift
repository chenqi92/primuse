import CryptoKit
import Foundation
import GRDB

public actor ReplayGainAnalysisCache {
    public static let shared = ReplayGainAnalysisCache()
    private struct Entry: Codable {
        let measurement: ReplayGainLoudnessMeasurement
        let filePathHash: String?
        let fileVersion: String?
        let savedAt: Date
    }
    private let directory: URL
    private var entries: [String: Entry]?
    private var database: DatabaseQueue?

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplayGainAnalysis", isDirectory: true)
    }

    public nonisolated static func key(for song: Song) -> String {
        hash([song.sourceID, song.id, song.filePath, song.revision ?? "",
              String(song.fileSize), String(song.lastModified?.timeIntervalSince1970 ?? 0),
              String(song.duration), String(song.cueStartTime ?? 0), String(song.cueEndTime ?? -1),
              String(song.sacdTrackNumber ?? 0)].joined(separator: "\u{1f}"))
    }

    public func measurement(for song: Song, fileURL: URL? = nil) -> ReplayGainLoudnessMeasurement? {
        load()
        guard let entry = entries?[Self.key(for: song)] else { return nil }
        if let fileURL, fileURL.isFileURL,
           entry.filePathHash == Self.hash(fileURL.standardizedFileURL.path),
           entry.fileVersion != Self.fileVersion(fileURL) { return nil }
        return entry.measurement
    }

    public func albumMeasurement(for songs: [Song]) -> ReplayGainLoudnessMeasurement? {
        let unique = Dictionary(songs.map { (Self.key(for: $0), $0) }, uniquingKeysWith: { first, _ in first }).values
        guard !unique.isEmpty else { return nil }
        let measurements = unique.compactMap { measurement(for: $0) }
        guard measurements.count == unique.count else { return nil }
        return .album(measurements)
    }

    public func store(_ measurement: ReplayGainLoudnessMeasurement, for song: Song, fileURL: URL) {
        guard measurement.peak.isFinite, measurement.duration.isFinite,
              measurement.blockEnergies.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        load()
        let key = Self.key(for: song)
        let pathHash = Self.hash(fileURL.standardizedFileURL.path)
        let version = Self.fileVersion(fileURL)
        if let existing = entries?[key], existing.measurement == measurement,
           existing.filePathHash == pathHash, existing.fileVersion == version { return }
        let previousKeys = Set(entries?.keys.map { $0 } ?? [])
        entries?[key] = Entry(measurement: measurement, filePathHash: pathHash,
                              fileVersion: version, savedAt: Date())
        let kept = Self.pruned(entries ?? [:])
        entries = kept
        do {
            try database?.write { db in
                for removed in previousKeys.subtracting(kept.keys) {
                    try db.execute(sql: "DELETE FROM measurements WHERE cacheKey = ?", arguments: [removed])
                }
                if let entry = kept[key] {
                    try db.execute(sql: "INSERT OR REPLACE INTO measurements (cacheKey, payload) VALUES (?, ?)",
                                   arguments: [key, try JSONEncoder().encode(entry)])
                }
            }
        } catch { /* An evicted or unwritable cache must not prevent playback. */ }
    }

    private static func pruned(_ entries: [String: Entry]) -> [String: Entry] {
        // Keep only analysis data, never audio. Bound both entry count and the
        // energy-window count, including unusually long concert recordings.
        let ordered = entries.sorted { $0.value.savedAt > $1.value.savedAt }
        var kept: [String: Entry] = [:]
        var windows = 0
        for (key, value) in ordered {
            guard kept.count < 512, windows + value.measurement.blockEnergies.count <= 1_000_000 else { continue }
            kept[key] = value
            windows += value.measurement.blockEnergies.count
        }
        return kept
    }

    private func load() {
        guard entries == nil else { return }
        entries = [:]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try DatabaseQueue(path: directory.appendingPathComponent("v2.sqlite").path)
            try database.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS measurements (cacheKey TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                if try Int.fetchOne(db, sql: "PRAGMA user_version") == 0 {
                    // Import once in the same transaction as the version marker.
                    // Later measurements only replace their own row.
                    for (key, entry) in Self.pruned(legacyEntries()) {
                        try db.execute(sql: "INSERT OR IGNORE INTO measurements (cacheKey, payload) VALUES (?, ?)",
                                       arguments: [key, try JSONEncoder().encode(entry)])
                    }
                    try db.execute(sql: "PRAGMA user_version = 1")
                }
            }
            entries = try database.read { db in
                var result: [String: Entry] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT cacheKey, payload FROM measurements") {
                    if let entry = try? JSONDecoder().decode(Entry.self, from: row["payload"]) {
                        result[row["cacheKey"]] = entry
                    }
                }
                return result
            }
            self.database = database
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("v1.json"))
        } catch {
            entries = Self.pruned(legacyEntries())
        }
    }

    private func legacyEntries() -> [String: Entry] {
        let url = directory.appendingPathComponent("v1.json")
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size < 32 * 1024 * 1024, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func fileVersion(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return "\((attributes[.size] as? NSNumber)?.int64Value ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
}
