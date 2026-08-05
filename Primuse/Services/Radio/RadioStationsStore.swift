import Foundation
import PrimuseKit

extension Notification.Name {
    static let primuseRadioStationsDidChange = Notification.Name("primuse.radioStations.changed")
    static let primuseRadioStationDidDelete = Notification.Name("primuse.radioStations.deleted")
}

@MainActor
@Observable
final class RadioStationsStore {
    private(set) var allStations: [RadioStation]

    var stations: [RadioStation] {
        allStations
            .filter { !$0.isDeleted }
            .sorted {
                switch ($0.lastPlayedAt, $1.lastPlayedAt) {
                case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
                default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
    }

    private let storeURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, storeURL: URL? = nil) {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = base.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = storeURL ?? directory.appendingPathComponent("radio-stations.json")
        self.allStations = []

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
        materializeLogos(for: allStations)
    }

    func station(id: String) -> RadioStation? {
        allStations.first { $0.id == id && !$0.isDeleted }
    }

    func add(_ station: RadioStation) {
        upsert(station)
    }

    func upsert(_ station: RadioStation) {
        var stamped = station
        guard RadioStationValidation.isValid(name: stamped.name, urlString: stamped.streamURL),
              let normalizedURL = RadioStationValidation.normalizedURLString(stamped.streamURL),
              stamped.logoData.map({ $0.count <= RadioStationValidation.maximumLogoBytes }) ?? true else {
            return
        }
        stamped.name = RadioStationValidation.normalizedName(stamped.name)
        stamped.streamURL = normalizedURL
        stamped.modifiedAt = Date()
        stamped.isDeleted = false
        stamped.deletedAt = nil

        if let index = allStations.firstIndex(where: { $0.id == stamped.id }) {
            allStations[index] = stamped
        } else {
            allStations.append(stamped)
        }
        persist()
        materializeLogos(for: [stamped])
        notifyChanged(ids: [stamped.id])
    }

    func update(_ id: String, mutate: (inout RadioStation) -> Void) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        var updated = allStations[index]
        mutate(&updated)
        guard RadioStationValidation.isValid(name: updated.name, urlString: updated.streamURL),
              let normalizedURL = RadioStationValidation.normalizedURLString(updated.streamURL),
              updated.logoData.map({ $0.count <= RadioStationValidation.maximumLogoBytes }) ?? true else {
            return
        }
        updated.name = RadioStationValidation.normalizedName(updated.name)
        updated.streamURL = normalizedURL
        updated.modifiedAt = Date()
        updated.isDeleted = false
        updated.deletedAt = nil
        allStations[index] = updated
        persist()
        materializeLogos(for: [updated])
        notifyChanged(ids: [id])
    }

    /// Device-local recency is intentionally not pushed through CloudKit.
    func markPlayed(_ id: String, at date: Date = Date()) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        allStations[index].lastPlayedAt = date
        persist()
    }

    func remove(id: String) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        allStations[index].isDeleted = true
        allStations[index].deletedAt = Date()
        allStations[index].modifiedAt = Date()
        persist()
        notifyChanged(ids: [id])
        NotificationCenter.default.post(
            name: .primuseRadioStationDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    func upsertFromRemote(_ remote: RadioStation) {
        guard remote.logoData.map({ $0.count <= RadioStationValidation.maximumLogoBytes }) ?? true,
              remote.isDeleted
                || RadioStationValidation.isValid(name: remote.name, urlString: remote.streamURL) else {
            return
        }
        var normalized = remote
        if !normalized.isDeleted {
            normalized.name = RadioStationValidation.normalizedName(normalized.name)
            guard let normalizedURL = RadioStationValidation.normalizedURLString(normalized.streamURL) else {
                return
            }
            normalized.streamURL = normalizedURL
        }
        if let index = allStations.firstIndex(where: { $0.id == normalized.id }) {
            guard allStations[index].modifiedAt <= normalized.modifiedAt else { return }
            var merged = normalized
            merged.lastPlayedAt = allStations[index].lastPlayedAt
            allStations[index] = merged
        } else {
            guard !normalized.isDeleted else { return }
            allStations.append(normalized)
        }
        persist()
        materializeLogos(for: [normalized])
    }

    func removeFromRemote(id: String) {
        allStations.removeAll { $0.id == id }
        persist()
    }

    func encodedSnapshot() throws -> Data {
        try encoder.encode(allStations)
    }

    func applySnapshot(_ data: Data) throws {
        let incoming = try decoder.decode([RadioStation].self, from: data)
        for station in incoming {
            upsertFromRemote(station)
        }
    }

    func reloadFromDisk() {
        load()
        materializeLogos(for: allStations)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else {
            allStations = []
            return
        }
        do {
            allStations = try decoder.decode([RadioStation].self, from: data)
        } catch {
            let backupURL = storeURL.appendingPathExtension("corrupt")
            try? data.write(to: backupURL, options: .atomic)
            allStations = []
            plog("RadioStationsStore: invalid snapshot backed up as \(backupURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(allStations) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func notifyChanged(ids: [String]) {
        NotificationCenter.default.post(
            name: .primuseRadioStationsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func materializeLogos(for stations: [RadioStation]) {
        for station in stations {
            guard let data = station.logoData, !data.isEmpty else { continue }
            Task {
                _ = await MetadataAssetStore.shared.storeCover(data, for: "radio:\(station.id)")
            }
        }
    }
}
