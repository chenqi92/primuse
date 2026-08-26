import Foundation
import PrimuseKit

enum ServerListeningStatsStaleReason: String, Hashable, Sendable {
    case expired
    case clockChanged
    case recoveredBackup
    case refreshFailed
}

actor ServerListeningStatsSnapshotStore {
    struct LoadResult: Sendable {
        let snapshot: ServerListeningStatsSnapshot
        let recoveredFromBackup: Bool
    }

    private struct Envelope: Codable {
        let version: Int
        var snapshots: [ServerListeningStatsSnapshot]
    }

    static let currentVersion = 1
    static let fileName = "server-listening-stats.json"
    static let backupFileName = "server-listening-stats.backup.json"

    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            #if os(tvOS)
            let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
            #else
            let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
            #endif
            self.directoryURL = base
                .appendingPathComponent("Primuse", isDirectory: true)
                .appendingPathComponent("ListeningStats", isDirectory: true)
        }
    }

    func load(for source: MusicSource) -> LoadResult? {
        guard let read = readLatestEnvelope() else { return nil }
        guard let snapshot = read.envelope.snapshots.last(where: {
            $0.isValid(for: source)
        }) else { return nil }
        return LoadResult(
            snapshot: snapshot,
            recoveredFromBackup: read.recoveredFromBackup
        )
    }

    func save(_ snapshot: ServerListeningStatsSnapshot) throws {
        guard snapshot.payload.isStructurallyValid else {
            throw ServerListeningStatsServiceError.invalidPayload
        }

        let primaryEnvelope = decodeEnvelope(at: primaryURL)
        let backupEnvelope = decodeEnvelope(at: backupURL)
        var envelope = primaryEnvelope
            ?? backupEnvelope
            ?? Envelope(version: Self.currentVersion, snapshots: [])

        // One source keeps only its latest account/configuration snapshot. This
        // prevents a credential edit from resurrecting data from the old account.
        envelope.snapshots.removeAll { $0.sourceID == snapshot.sourceID }
        envelope.snapshots.append(snapshot)
        if envelope.snapshots.count > 100 {
            envelope.snapshots.removeFirst(envelope.snapshots.count - 100)
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try AtomicBackupFileWriter.write(
            data,
            to: primaryURL,
            backupURL: backupURL,
            preserveExistingAsBackup: primaryEnvelope != nil
        )
    }

    private var primaryURL: URL {
        directoryURL.appendingPathComponent(Self.fileName)
    }

    private var backupURL: URL {
        directoryURL.appendingPathComponent(Self.backupFileName)
    }

    private func readLatestEnvelope() -> (
        envelope: Envelope,
        recoveredFromBackup: Bool
    )? {
        if let primary = decodeEnvelope(at: primaryURL) {
            return (primary, false)
        }
        if let backup = decodeEnvelope(at: backupURL) {
            return (backup, true)
        }
        return nil
    }

    private func decodeEnvelope(at url: URL) -> Envelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else { return nil }
        return envelope
    }
}

enum ServerListeningStatsServiceError: LocalizedError, Equatable {
    case unsupportedSource
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return String(localized: "stats_server_error_unsupported")
        case .invalidPayload:
            return String(localized: "stats_server_error_invalid_payload")
        }
    }
}

@MainActor
@Observable
final class ServerListeningStatsService {
    typealias PayloadFetcher = @MainActor @Sendable (
        MusicSource
    ) async throws -> ServerListeningStatsPayload?

    static let freshnessInterval: TimeInterval = 24 * 60 * 60
    static let futureClockTolerance: TimeInterval = 5 * 60

    private(set) var sourceID: String?
    private(set) var snapshot: ServerListeningStatsSnapshot?
    private(set) var isRefreshing = false
    private(set) var staleReasons: Set<ServerListeningStatsStaleReason> = []
    private(set) var errorMessage: String?

    private let snapshotStore: ServerListeningStatsSnapshotStore
    private let fetchPayload: PayloadFetcher
    private let now: @Sendable () -> Date
    private var generation = 0

    convenience init(sourceManager: SourceManager) {
        self.init(
            snapshotStore: ServerListeningStatsSnapshotStore(),
            fetchPayload: { source in
                try await sourceManager.fetchServerListeningStats(for: source)
            }
        )
    }

    init(
        snapshotStore: ServerListeningStatsSnapshotStore,
        now: @escaping @Sendable () -> Date = Date.init,
        fetchPayload: @escaping PayloadFetcher
    ) {
        self.snapshotStore = snapshotStore
        self.now = now
        self.fetchPayload = fetchPayload
    }

    var isStale: Bool { !staleReasons.isEmpty }

    func presentation(
        range: ServerListeningStatsRange
    ) -> ServerListeningStatsPresentation? {
        guard let snapshot else { return nil }
        return ServerListeningStatsPresentationBuilder.build(
            payload: snapshot.payload,
            range: range,
            now: now()
        )
    }

    func activate(source: MusicSource) async {
        guard source.isEnabled,
              !source.isDeleted,
              source.type.serverListeningStatsCapability != .unavailable else {
            reset()
            return
        }

        let token = begin(source: source, keepSnapshot: false)
        if let cached = await snapshotStore.load(for: source), isCurrent(token, source) {
            snapshot = cached.snapshot
            staleReasons = staleReasons(
                for: cached.snapshot,
                recoveredFromBackup: cached.recoveredFromBackup
            )
        }
        guard isCurrent(token, source), !Task.isCancelled else {
            finishIfCurrent(token)
            return
        }
        await performRefresh(source: source, token: token)
    }

    func refresh(source: MusicSource) async {
        guard source.isEnabled,
              !source.isDeleted,
              source.type.serverListeningStatsCapability != .unavailable else {
            reset()
            return
        }
        let keepSnapshot = sourceID == source.id
            && snapshot?.isValid(for: source) == true
        let token = begin(source: source, keepSnapshot: keepSnapshot)
        await performRefresh(source: source, token: token)
    }

    func cancel() {
        generation &+= 1
        isRefreshing = false
    }

    func reset() {
        generation &+= 1
        sourceID = nil
        snapshot = nil
        isRefreshing = false
        staleReasons = []
        errorMessage = nil
    }

    private func begin(source: MusicSource, keepSnapshot: Bool) -> Int {
        generation &+= 1
        let token = generation
        sourceID = source.id
        if !keepSnapshot {
            snapshot = nil
            staleReasons = []
        }
        errorMessage = nil
        isRefreshing = true
        return token
    }

    private func performRefresh(source: MusicSource, token: Int) async {
        defer { finishIfCurrent(token) }
        do {
            guard let payload = try await fetchPayload(source) else {
                throw ServerListeningStatsServiceError.unsupportedSource
            }
            try Task.checkCancellation()
            guard isCurrent(token, source), payload.isStructurallyValid else {
                if isCurrent(token, source) {
                    throw ServerListeningStatsServiceError.invalidPayload
                }
                return
            }

            let refreshed = ServerListeningStatsSnapshot(
                sourceID: source.id,
                sourceType: source.type,
                configurationFingerprint: ServerListeningStatsFingerprint.configuration(for: source),
                fetchedAt: now(),
                payload: payload
            )
            guard refreshed.isValid(for: source) else {
                throw ServerListeningStatsServiceError.invalidPayload
            }
            try Task.checkCancellation()
            guard isCurrent(token, source) else { return }
            try await snapshotStore.save(refreshed)
            try Task.checkCancellation()
            guard isCurrent(token, source) else { return }

            snapshot = refreshed
            staleReasons = staleReasons(for: refreshed, recoveredFromBackup: false)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(token, source) else { return }
            staleReasons.insert(.refreshFailed)
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ token: Int, _ source: MusicSource) -> Bool {
        generation == token && sourceID == source.id
    }

    private func finishIfCurrent(_ token: Int) {
        guard generation == token else { return }
        isRefreshing = false
    }

    private func staleReasons(
        for snapshot: ServerListeningStatsSnapshot,
        recoveredFromBackup: Bool
    ) -> Set<ServerListeningStatsStaleReason> {
        var reasons: Set<ServerListeningStatsStaleReason> = []
        let age = now().timeIntervalSince(snapshot.fetchedAt)
        if age > Self.freshnessInterval {
            reasons.insert(.expired)
        } else if age < -Self.futureClockTolerance {
            reasons.insert(.clockChanged)
        }
        if recoveredFromBackup {
            reasons.insert(.recoveredBackup)
        }
        return reasons
    }
}
