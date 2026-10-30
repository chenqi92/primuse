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

    static let currentVersion = 2
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
    private(set) var snapshot: ServerListeningStatsSnapshot? {
        didSet { musicPayloadCache = nil }
    }
    @ObservationIgnored private var musicPayloadCache: (revision: PlayHistoryStore.SnapshotRevision, payload: ServerListeningStatsPayload)?
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
        let history = PlayHistoryStore.shared
        let revision = history.snapshotRevision
        if musicPayloadCache?.revision != revision {
            musicPayloadCache = (revision, Self.musicPayload(snapshot.payload, sourceID: snapshot.sourceID,
                                                            classification: history.classification))
        }
        return ServerListeningStatsPresentationBuilder.build(
            payload: musicPayloadCache!.payload,
            range: range,
            now: now()
        )
    }

    static func musicPayload(_ payload: ServerListeningStatsPayload, sourceID: String,
                             classification: PlayHistoryStore.Classification) -> ServerListeningStatsPayload {
        var songsByRemoteID: [String: Song] = [:]
        classification.library?.forEachSong { song in
            guard song.sourceID == sourceID else { return }
            let remoteID = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
            songsByRemoteID[remoteID] = song
        }
        func isMusic(_ remoteID: String, _ content: ServerListeningContent?) -> Bool {
            if let song = songsByRemoteID[remoteID] {
                return classification.inputs.kind(songID: song.id, sourceID: song.sourceID, filePath: song.filePath,
                                                  genre: song.genre, serverLibraryID: song.serverLibraryID) == .music
            }
            return classification.inputs.kind(songID: content?.songID ?? remoteID, sourceID: sourceID,
                                               filePath: content?.filePath ?? "", genre: content?.genre,
                                               serverLibraryID: content?.serverLibraryID) == .music
        }
        let tracks = payload.tracks.filter { isMusic($0.remoteTrackID, $0.content) }
        let events = payload.events.filter { isMusic($0.remoteTrackID, $0.content) }
        // 旧缓存只有全媒体总数，不能从有限时间内的记录推算音乐累计数。
        let cumulative = payload.cumulativeTracks?.filter { isMusic($0.remoteTrackID, $0.content) }
        return ServerListeningStatsPayload(accountFingerprint: payload.accountFingerprint,
            temporalDetail: payload.temporalDetail, durationAvailability: payload.durationAvailability,
            tracks: tracks, events: events, allTimePlayCount: cumulative.map { $0.reduce(0) { $0 + $1.playCount } },
            cumulativeTracks: cumulative)
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
            if snapshot != nil {
                staleReasons.insert(.refreshFailed)
            }
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
