import Foundation
import PrimuseKit

extension Notification.Name {
    static let primuseRadioStationsDidChange = Notification.Name("primuse.radioStations.changed")
    static let primuseRadioStationDidDelete = Notification.Name("primuse.radioStations.deleted")
}

struct ServerRadioSyncResult: Sendable {
    var discoveredCount = 0
    var synchronizedCount = 0
    var removedCount = 0
    var isSupported = false
}

@MainActor
@Observable
final class RadioStationsStore {
    private(set) var allStations: [RadioStation]

    var stations: [RadioStation] {
        RadioStationOrdering.sorted(allStations.filter { !$0.isDeleted })
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
        guard !stamped.isServerMirror else { return }
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
            if stamped.sortOrder == nil {
                stamped.sortOrder = allStations[index].sortOrder
            }
            allStations[index] = stamped
        } else {
            if stamped.sortOrder == nil,
               allStations.contains(where: { !$0.isDeleted && $0.sortOrder != nil }) {
                stamped.sortOrder = (allStations.compactMap(\.sortOrder).max() ?? -1) + 1
            }
            allStations.append(stamped)
        }
        persist()
        materializeLogos(for: [stamped])
        notifyChanged(ids: [stamped.id])
    }

    func update(_ id: String, mutate: (inout RadioStation) -> Void) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        guard !allStations[index].isServerMirror else { return }
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

    func moveStations(from offsets: IndexSet, to destination: Int) {
        var ordered = stations
        let validOffsets = offsets.filter { ordered.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }

        let moving = validOffsets.map { ordered[$0] }
        for index in validOffsets.sorted(by: >) {
            ordered.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = max(0, min(ordered.count, destination - removedBeforeDestination))
        ordered.insert(contentsOf: moving, at: insertionIndex)
        applyPriorityOrder(ordered.map(\.id))
    }

    func moveStation(id: String, by offset: Int) {
        guard offset != 0 else { return }
        let ordered = stations
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(ordered.count - 1, index + offset))
        guard target != index else { return }

        var reordered = ordered
        let station = reordered.remove(at: index)
        reordered.insert(station, at: target)
        applyPriorityOrder(reordered.map(\.id))
    }

    func sortStationsByName() {
        let ordered = stations.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.id < $1.id : result == .orderedAscending
        }
        applyPriorityOrder(ordered.map(\.id))
    }

    /// 一次性把顺序设成给定的 id 序列。批量操作(置顶 / 归组)用它，
    /// 逐个 `update` 会按站数触发同样多次落盘和同步。
    func applyOrder(_ stationIDs: [String]) {
        applyPriorityOrder(stationIDs)
    }

    func remove(id: String) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        guard !allStations[index].isServerMirror else { return }
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
              RadioStationValidation.hasConsistentServerIdentity(remote),
              remote.isDeleted
                || RadioStationValidation.hasValidPlaybackReference(remote) else {
            return
        }
        var normalized = remote
        if !normalized.isDeleted {
            normalized.name = RadioStationValidation.normalizedName(normalized.name)
            if normalized.requiresSourceStreamResolution,
               normalized.streamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.streamURL = ""
            } else {
                guard let normalizedURL = RadioStationValidation.normalizedURLString(normalized.streamURL) else {
                    return
                }
                normalized.streamURL = normalizedURL
            }
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

    /// Reconciles one source's complete radio snapshot in a single durable
    /// write. Server fields are authoritative, while local playback recency
    /// and user ordering survive refreshes. Missing upstream stations become
    /// tombstones so CloudKit and LAN snapshots cannot resurrect them.
    @discardableResult
    func reconcileServerStations(
        source: MusicSource,
        snapshot: ServerRadioStationSnapshot
    ) -> ServerRadioSyncResult {
        let now = Date()
        var result = ServerRadioSyncResult(
            discoveredCount: snapshot.stations.count,
            isSupported: true
        )
        let keepIDs = ServerRadioReconciliationPolicy.mirrorIDsToKeep(
            sourceID: source.id,
            serverStationIDs: snapshot.stations.map {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            failedServerStationIDs: snapshot.failedStationIDs
        )
        var changedIDs: [String] = []
        var seenServerIDs = Set<String>()
        var nextSortOrder: Int? = allStations.contains(where: {
            !$0.isDeleted && $0.sortOrder != nil
        }) ? (allStations.compactMap(\.sortOrder).max() ?? -1) + 1 : nil

        for serverStation in snapshot.stations {
            let serverID = serverStation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverID.isEmpty, seenServerIDs.insert(serverID).inserted else { continue }
            let name = RadioStationValidation.normalizedName(serverStation.name)
            guard !name.isEmpty else { continue }

            let playbackPath = serverStation.sourcePlaybackPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPlaybackPath = playbackPath?.isEmpty == false ? playbackPath : nil
            let normalizedStreamURL: String
            if let rawURL = serverStation.streamURL,
               !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let url = RadioStationValidation.normalizedURLString(rawURL) else { continue }
                normalizedStreamURL = url
            } else {
                guard normalizedPlaybackPath != nil else { continue }
                normalizedStreamURL = ""
            }

            let localID = ServerRadioStationIdentity.stationID(
                sourceID: source.id,
                serverStationID: serverID
            )
            let index = allStations.firstIndex(where: { $0.id == localID })
            if let index, !allStations[index].isServerMirror {
                continue
            }

            let existing = index.map { allStations[$0] }
            var updated = RadioStation(
                id: localID,
                name: name,
                streamURL: normalizedStreamURL,
                logoData: nil,
                logoFileName: normalizedOptional(serverStation.coverArtReference),
                streamFormat: serverStation.streamFormat,
                bitRate: serverStation.bitRate,
                createdAt: existing?.createdAt ?? now,
                modifiedAt: existing?.modifiedAt ?? now,
                lastPlayedAt: existing?.lastPlayedAt,
                sortOrder: existing?.sortOrder ?? nextSortOrder,
                sourceID: source.id,
                serverStationID: serverID,
                sourceName: source.name,
                sourcePlaybackPath: normalizedPlaybackPath,
                homepageURL: normalizedHTTPURLString(serverStation.homepageURL)
            )
            if existing == nil, nextSortOrder != nil {
                nextSortOrder = (nextSortOrder ?? 0) + 1
            }

            if let existing, serverMirrorContentMatches(existing, updated) {
                continue
            }
            updated.modifiedAt = now
            if let index {
                allStations[index] = updated
            } else {
                allStations.append(updated)
            }
            changedIDs.append(localID)
            result.synchronizedCount += 1
        }

        let prefix = ServerRadioStationIdentity.stationIDPrefix(sourceID: source.id)
        for index in allStations.indices where
            allStations[index].id.hasPrefix(prefix)
                && !allStations[index].isDeleted
                && !keepIDs.contains(allStations[index].id) {
            allStations[index].isDeleted = true
            allStations[index].deletedAt = now
            allStations[index].modifiedAt = now
            changedIDs.append(allStations[index].id)
            result.removedCount += 1
        }

        guard !changedIDs.isEmpty else { return result }
        persist()
        notifyChanged(ids: changedIDs)
        return result
    }

    func removeServerMirrors(forSourceIDs sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        let prefixes = sourceIDs.map(ServerRadioStationIdentity.stationIDPrefix(sourceID:))
        let now = Date()
        var changedIDs: [String] = []
        for index in allStations.indices where
            !allStations[index].isDeleted
                && prefixes.contains(where: { allStations[index].id.hasPrefix($0) }) {
            allStations[index].isDeleted = true
            allStations[index].deletedAt = now
            allStations[index].modifiedAt = now
            changedIDs.append(allStations[index].id)
        }
        guard !changedIDs.isEmpty else { return }
        persist()
        notifyChanged(ids: changedIDs)
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

    private func applyPriorityOrder(_ stationIDs: [String]) {
        let orderByID = Dictionary(uniqueKeysWithValues: stationIDs.enumerated().map { ($1, $0) })
        let now = Date()
        var changedIDs: [String] = []

        for index in allStations.indices where !allStations[index].isDeleted {
            guard let order = orderByID[allStations[index].id],
                  allStations[index].sortOrder != order else { continue }
            allStations[index].sortOrder = order
            allStations[index].modifiedAt = now
            changedIDs.append(allStations[index].id)
        }

        guard !changedIDs.isEmpty else { return }
        persist()
        notifyChanged(ids: changedIDs)
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

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func normalizedHTTPURLString(_ value: String?) -> String? {
        guard let value else { return nil }
        return RadioStationValidation.normalizedURLString(value)
    }

    private func serverMirrorContentMatches(_ lhs: RadioStation, _ rhs: RadioStation) -> Bool {
        lhs.name == rhs.name
            && lhs.streamURL == rhs.streamURL
            && lhs.logoFileName == rhs.logoFileName
            && lhs.streamFormat == rhs.streamFormat
            && lhs.bitRate == rhs.bitRate
            && lhs.sortOrder == rhs.sortOrder
            && !lhs.isDeleted
            && lhs.sourceID == rhs.sourceID
            && lhs.serverStationID == rhs.serverStationID
            && lhs.sourceName == rhs.sourceName
            && lhs.sourcePlaybackPath == rhs.sourcePlaybackPath
            && lhs.homepageURL == rhs.homepageURL
    }
}

@MainActor
enum ServerRadioSyncService {
    @discardableResult
    static func sync(
        source: MusicSource,
        sourceManager: SourceManager,
        store: RadioStationsStore,
        applyFence: ServerMirrorApplyFence = { true }
    ) async -> ServerRadioSyncResult {
        do {
            guard let snapshot = try await sourceManager.fetchServerRadioStations(for: source) else {
                return ServerRadioSyncResult()
            }
            guard applyFence() else { return ServerRadioSyncResult() }
            let result = store.reconcileServerStations(source: source, snapshot: snapshot)
            plog(
                "📻 Server radio '\(source.name)' synchronized "
                    + "\(result.synchronizedCount)/\(result.discoveredCount), removed \(result.removedCount)"
            )
            return result
        } catch is CancellationError {
            return ServerRadioSyncResult()
        } catch {
            plog("⚠️ Server radio '\(source.name)' sync failed: \(error.localizedDescription)")
            return ServerRadioSyncResult()
        }
    }
}
