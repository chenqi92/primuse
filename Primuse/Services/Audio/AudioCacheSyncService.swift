#if os(iOS) || os(macOS)
import CryptoKit
import Foundation
import Network
import Observation
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum CacheSyncLocalization {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "CacheSync")
    }
}

enum AudioCacheSyncPlatform: String, Codable, Sendable {
    case iPhone
    case iPad
    case mac

    var symbolName: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "macbook"
        }
    }
}

struct AudioCacheSyncPeer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let platform: AudioCacheSyncPlatform
}

struct AudioCacheSyncInventorySummary: Equatable, Sendable {
    let fileCount: Int
    let byteCount: Int64
}

struct AudioCacheSyncPeerPlan: Equatable, Sendable {
    let peerID: String
    let missingFileCount: Int
    let missingByteCount: Int64
    let alreadyPresentCount: Int
    let rejectedCount: Int
}

struct AudioCacheSyncTransferProgress: Equatable, Sendable {
    let peerID: String
    let completedFileCount: Int
    let failedFileCount: Int
    let totalFileCount: Int
    let sentByteCount: Int64
    let totalByteCount: Int64
    let currentTitle: String?

    var fractionCompleted: Double {
        if totalByteCount > 0 {
            return min(1, max(0, Double(sentByteCount) / Double(totalByteCount)))
        }
        guard totalFileCount > 0 else { return 0 }
        return min(
            1,
            max(0, Double(completedFileCount + failedFileCount) / Double(totalFileCount))
        )
    }
}

struct AudioCacheSyncTransferCompletion: Equatable, Sendable {
    let peerID: String
    let transferredFileCount: Int
    let failedFileCount: Int
    let transferredByteCount: Int64
}

enum AudioCacheSyncOperation: Equatable, Sendable {
    case idle
    case preparing
    case inspecting
    case transferring
}

/// Cross-device cache transfer policy. Only canonical, complete cache files
/// are announced; receivers independently resolve every opaque song ID back
/// to their own library and compute their own destination path.
enum AudioCacheSyncPolicy {
    static let protocolVersion = 1
    static let serviceType = "_primuse-cache._tcp."
    static let chunkByteCount = 256 * 1_024
    static let maximumManifestItems = 25_000
    static let maximumControlFrameByteCount = 16 * 1_024 * 1_024
    static let frameIdleTimeout: TimeInterval = 30

    static func itemID(sourceID: String, cacheFileName: String) -> String {
        "\(sourceID)/\(cacheFileName)"
    }

    static func isSafeCacheFileName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name.utf8.count <= 255,
              name != ".",
              name != "..",
              (name as NSString).lastPathComponent == name,
              !name.contains("\\"),
              !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        return true
    }

    static func byteCountIsCompatible(
        transferredByteCount: Int64,
        catalogByteCount: Int64
    ) -> Bool {
        guard transferredByteCount > 0 else { return false }
        guard catalogByteCount > 0 else { return true }
        let minimum = catalogByteCount - catalogByteCount / 20
        let maximumResult = catalogByteCount.addingReportingOverflow(4 * 1_024)
        let maximum = maximumResult.overflow ? Int64.max : maximumResult.partialValue
        return transferredByteCount >= minimum && transferredByteCount <= maximum
    }
}

private struct AudioCacheSyncWireItem: Codable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let sourceFingerprint: String
    let songIDs: [String]
    let cacheFileName: String
    let byteCount: Int64
    let catalogByteCount: Int64
}

private struct AudioCacheSyncWireHello: Codable, Sendable {
    let version: Int
    let sessionID: String
    let publicKey: Data
}

private enum AudioCacheSyncWireAction: String, Codable, Sendable {
    case inspect
    case transfer
}

private struct AudioCacheSyncWireRequest: Codable, Sendable {
    let action: AudioCacheSyncWireAction
    let items: [AudioCacheSyncWireItem]
}

private struct AudioCacheSyncWirePlan: Codable, Sendable {
    let missingItemIDs: [String]
    let alreadyPresentCount: Int
    let rejectedCount: Int
}

private struct AudioCacheSyncWireFileHeader: Codable, Sendable {
    let itemID: String
    let isAvailable: Bool
}

private struct AudioCacheSyncWireReady: Codable, Sendable {
    let itemID: String
    let accepted: Bool
}

private struct AudioCacheSyncWireFileResult: Codable, Sendable {
    let itemID: String
    let succeeded: Bool
}

private struct AudioCacheSyncWireCompletionMarker: Codable, Sendable {
    let complete: Bool
}

private struct AudioCacheSyncWireTransferSummary: Codable, Sendable {
    let transferredFileCount: Int
    let failedFileCount: Int
    let transferredByteCount: Int64
}

private struct AudioCacheSyncLocalFile: Sendable {
    let item: AudioCacheSyncWireItem
    let url: URL
    let title: String
}

private struct AudioCacheSyncLocalManifest: Sendable {
    let files: [AudioCacheSyncLocalFile]

    var items: [AudioCacheSyncWireItem] { files.map(\.item) }
    var filesByID: [String: AudioCacheSyncLocalFile] {
        Dictionary(files.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    var summary: AudioCacheSyncInventorySummary {
        AudioCacheSyncInventorySummary(
            fileCount: files.count,
            byteCount: files.reduce(Int64(0)) { total, file in
                let result = total.addingReportingOverflow(file.item.byteCount)
                return result.overflow ? .max : result.partialValue
            }
        )
    }
}

private struct AudioCacheSyncIncomingPlan: Sendable {
    let response: AudioCacheSyncWirePlan
    let songsByItemID: [String: Song]
    let itemsByID: [String: AudioCacheSyncWireItem]
}

private struct AudioCacheSyncNetworkProgress: Sendable {
    let completedFileCount: Int
    let failedFileCount: Int
    let totalFileCount: Int
    let sentByteCount: Int64
    let totalByteCount: Int64
    let currentItemID: String?
}

private enum AudioCacheSyncSocketError: Error {
    case connectionFailed
    case connectionClosed
    case invalidFrame
    case frameTooLarge
    case invalidHandshake
    case invalidMessage
    case encryptionFailed
}

@MainActor
@Observable
final class AudioCacheSyncService {
    private(set) var peers: [AudioCacheSyncPeer] = []
    private(set) var isDiscovering = false
    private(set) var isReceiving = false
    private(set) var operation: AudioCacheSyncOperation = .idle
    private(set) var activePeerID: String?
    private(set) var localInventory: AudioCacheSyncInventorySummary?
    private(set) var peerPlans: [String: AudioCacheSyncPeerPlan] = [:]
    private(set) var transferProgress: AudioCacheSyncTransferProgress?
    private(set) var lastCompletion: AudioCacheSyncTransferCompletion?
    private(set) var lastError: String?

    @ObservationIgnored private weak var sourcesStore: SourcesStore?
    @ObservationIgnored private weak var library: MusicLibrary?
    @ObservationIgnored private var sourceManager: SourceManager?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var discoveryIndicatorTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var endpointByPeerID: [String: NWEndpoint] = [:]
    @ObservationIgnored private var publicKeyByPeerID: [String: Data] = [:]
    @ObservationIgnored private var incomingSessionIDs: [String] = []
    @ObservationIgnored private var incomingSessionIDSet: Set<String> = []
    @ObservationIgnored private var activeIncomingConnectionCount = 0
    @ObservationIgnored private var incomingConnections: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private var receiverShouldRun = false
    @ObservationIgnored private let receiverPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let platform: AudioCacheSyncPlatform

    init(defaults: UserDefaults = .standard) {
        let deviceIDKey = "primuse.cacheSync.deviceID.v1"
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            deviceID = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: deviceIDKey)
            deviceID = created
        }

        #if os(iOS)
        deviceName = String(UIDevice.current.name.prefix(64))
        platform = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #else
        deviceName = String((Host.current().localizedName ?? "Mac").prefix(64))
        platform = .mac
        #endif
    }

    func attach(
        sourceManager: SourceManager,
        sourcesStore: SourcesStore,
        library: MusicLibrary
    ) {
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.library = library
    }

    func setApplicationActive(_ active: Bool) {
        #if os(iOS)
        receiverShouldRun = active
        if active {
            startReceiving()
        } else {
            stopReceiving()
        }
        #else
        receiverShouldRun = true
        startReceiving()
        #endif
    }

    func startDiscovery() {
        stopDiscovery()
        peers = []
        endpointByPeerID = [:]
        publicKeyByPeerID = [:]
        peerPlans = [:]
        isDiscovering = true
        lastError = nil

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: AudioCacheSyncPolicy.serviceType,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed = state {
                    self.isDiscovering = false
                    self.lastError = CacheSyncLocalization.text("cache_sync_error_discovery")
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.applyBrowseResults(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        discoveryIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.isDiscovering = false
        }
    }

    func stopDiscovery() {
        discoveryIndicatorTask?.cancel()
        discoveryIndicatorTask = nil
        browser?.cancel()
        browser = nil
        isDiscovering = false
    }

    func refreshLocalInventory() {
        guard operation == .idle else { return }
        operationTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        operation = .preparing
        lastError = nil
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let manifest = await self.buildLocalManifest()
            guard !Task.isCancelled, self.activeOperationID == operationID else { return }
            self.localInventory = manifest.summary
            self.operation = .idle
            self.operationTask = nil
        }
    }

    func inspect(peerID: String) {
        guard operation != .transferring,
              let endpoint = endpointByPeerID[peerID],
              let publicKey = publicKeyByPeerID[peerID] else { return }
        operationTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        operation = .inspecting
        activePeerID = peerID
        lastError = nil
        lastCompletion = nil
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let manifest = await self.buildLocalManifest()
            guard !Task.isCancelled, self.activeOperationID == operationID else { return }
            self.localInventory = manifest.summary
            do {
                let plan = try await Self.requestPlan(
                    endpoint: endpoint,
                    receiverPublicKey: publicKey,
                    manifest: manifest,
                    action: .inspect
                )
                guard !Task.isCancelled, self.activeOperationID == operationID else { return }
                self.peerPlans[peerID] = Self.peerPlan(
                    peerID: peerID,
                    wirePlan: plan,
                    manifest: manifest
                )
                self.operation = .idle
                self.activePeerID = nil
                self.operationTask = nil
            } catch {
                guard self.activeOperationID == operationID else { return }
                self.failCurrentOperation(
                    CacheSyncLocalization.text("cache_sync_error_connection")
                )
            }
        }
    }

    func sync(to peerID: String) {
        guard operation == .idle,
              let endpoint = endpointByPeerID[peerID],
              let publicKey = publicKeyByPeerID[peerID] else { return }
        operationTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        operation = .transferring
        activePeerID = peerID
        lastError = nil
        lastCompletion = nil
        transferProgress = nil
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let manifest = await self.buildLocalManifest()
            guard !Task.isCancelled, self.activeOperationID == operationID else { return }
            self.localInventory = manifest.summary
            do {
                let outcome = try await Self.transfer(
                    endpoint: endpoint,
                    receiverPublicKey: publicKey,
                    manifest: manifest
                ) { [weak self] update in
                    await self?.applyNetworkProgress(
                        update,
                        peerID: peerID,
                        manifest: manifest,
                        operationID: operationID
                    )
                }
                guard !Task.isCancelled, self.activeOperationID == operationID else { return }
                self.peerPlans[peerID] = AudioCacheSyncPeerPlan(
                    peerID: peerID,
                    missingFileCount: outcome.plan.missingFileCount,
                    missingByteCount: outcome.plan.missingByteCount,
                    alreadyPresentCount: outcome.plan.alreadyPresentCount,
                    rejectedCount: outcome.plan.rejectedCount
                )
                self.lastCompletion = AudioCacheSyncTransferCompletion(
                    peerID: peerID,
                    transferredFileCount: outcome.summary.transferredFileCount,
                    failedFileCount: outcome.summary.failedFileCount,
                    transferredByteCount: outcome.summary.transferredByteCount
                )
                self.transferProgress = nil
                self.operation = .idle
                self.activePeerID = nil
                self.operationTask = nil
            } catch is CancellationError {
                guard self.activeOperationID == operationID else { return }
                self.operation = .idle
                self.activePeerID = nil
                self.transferProgress = nil
                self.operationTask = nil
            } catch {
                guard self.activeOperationID == operationID else { return }
                self.failCurrentOperation(
                    CacheSyncLocalization.text("cache_sync_error_transfer")
                )
            }
        }
    }

    func cancelTransfer() {
        guard operation == .transferring else { return }
        activeOperationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        operation = .idle
        activePeerID = nil
        transferProgress = nil
    }

    func clearFeedback() {
        lastError = nil
        lastCompletion = nil
    }

    @ObservationIgnored private var activeOperationID = UUID()

    private func failCurrentOperation(_ message: String) {
        lastError = message
        operation = .idle
        activePeerID = nil
        transferProgress = nil
        operationTask = nil
    }

    private func applyNetworkProgress(
        _ update: AudioCacheSyncNetworkProgress,
        peerID: String,
        manifest: AudioCacheSyncLocalManifest,
        operationID: UUID
    ) {
        guard activeOperationID == operationID else { return }
        let file = update.currentItemID.flatMap { manifest.filesByID[$0] }
        transferProgress = AudioCacheSyncTransferProgress(
            peerID: peerID,
            completedFileCount: update.completedFileCount,
            failedFileCount: update.failedFileCount,
            totalFileCount: update.totalFileCount,
            sentByteCount: update.sentByteCount,
            totalByteCount: update.totalByteCount,
            currentTitle: file?.title
        )
    }

    private func startReceiving() {
        guard receiverShouldRun, listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            let txtRecord = NWTXTRecord([
                "id": deviceID,
                "name": deviceName,
                "platform": platform.rawValue,
                "v": String(AudioCacheSyncPolicy.protocolVersion),
                "pk": receiverPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            ])
            listener.service = NWListener.Service(
                name: deviceName,
                type: AudioCacheSyncPolicy.serviceType,
                domain: nil,
                txtRecord: txtRecord
            )
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.isReceiving = true
                    case .failed:
                        self.listener = nil
                        self.isReceiving = false
                        if self.receiverShouldRun {
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(for: .seconds(2))
                                self?.startReceiving()
                            }
                        }
                    case .cancelled:
                        self.isReceiving = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.acceptIncomingConnection(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            isReceiving = false
        }
    }

    private func stopReceiving() {
        listener?.cancel()
        listener = nil
        for connection in incomingConnections.values {
            connection.cancel()
        }
        isReceiving = false
    }

    private func acceptIncomingConnection(_ connection: NWConnection) {
        guard receiverShouldRun, activeIncomingConnectionCount < 2 else {
            connection.cancel()
            return
        }
        activeIncomingConnectionCount += 1
        let connectionID = ObjectIdentifier(connection)
        incomingConnections[connectionID] = connection
        let privateKey = receiverPrivateKey.rawRepresentation
        Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.incomingConnections.removeValue(forKey: connectionID)
                    self?.activeIncomingConnectionCount = max(
                        0,
                        (self?.activeIncomingConnectionCount ?? 1) - 1
                    )
                }
            }
            guard let self else {
                connection.cancel()
                return
            }
            await Self.handleIncomingConnection(
                connection,
                receiverPrivateKey: privateKey,
                service: self
            )
        }
    }

    private func claimIncomingSession(_ sessionID: String) -> Bool {
        guard UUID(uuidString: sessionID) != nil,
              incomingSessionIDSet.insert(sessionID).inserted else { return false }
        incomingSessionIDs.append(sessionID)
        if incomingSessionIDs.count > 256 {
            let removed = incomingSessionIDs.removeFirst()
            incomingSessionIDSet.remove(removed)
        }
        return true
    }

    private func applyBrowseResults(_ results: Set<NWBrowser.Result>) {
        var nextPeers: [AudioCacheSyncPeer] = []
        var nextEndpoints: [String: NWEndpoint] = [:]
        var nextPublicKeys: [String: Data] = [:]

        for result in results {
            guard case .service(let serviceName, _, _, _) = result.endpoint,
                  case .bonjour(let txtRecord) = result.metadata else { continue }
            let values = txtRecord.dictionary
            guard let peerID = values["id"],
                  peerID != deviceID,
                  let versionText = values["v"],
                  Int(versionText) == AudioCacheSyncPolicy.protocolVersion,
                  let platformText = values["platform"],
                  let peerPlatform = AudioCacheSyncPlatform(rawValue: platformText),
                  let publicKeyText = values["pk"],
                  let publicKey = Data(base64Encoded: publicKeyText),
                  publicKey.count == 32 else { continue }
            let name = values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
            nextPeers.append(AudioCacheSyncPeer(id: peerID, name: name, platform: peerPlatform))
            nextEndpoints[peerID] = result.endpoint
            nextPublicKeys[peerID] = publicKey
        }

        peers = Dictionary(nextPeers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        endpointByPeerID = nextEndpoints
        publicKeyByPeerID = nextPublicKeys
        let visibleIDs = Set(peers.map(\.id))
        peerPlans = peerPlans.filter { visibleIDs.contains($0.key) }
    }

    private struct LocalDraft: Sendable {
        var songIDs: [String]
        let sourceID: String
        let sourceFingerprint: String
        let cacheFileName: String
        var catalogByteCount: Int64
        let url: URL
        let title: String
    }

    private func buildLocalManifest() async -> AudioCacheSyncLocalManifest {
        guard let sourceManager, let sourcesStore, let library else {
            return AudioCacheSyncLocalManifest(files: [])
        }
        let sourceByID = Dictionary(
            sourcesStore.sources.lazy
                .filter {
                    $0.isEnabled
                        && $0.type != .local
                        && $0.type != .appleMusic
                        && $0.type != .appleMusicLibrary
                }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let songs = library.songs.filter {
            sourceByID[$0.sourceID] != nil && !$0.isStreamDescriptor
        }
        guard !songs.isEmpty else { return AudioCacheSyncLocalManifest(files: []) }

        let downloadedIDs = await sourceManager.downloadedSongIDs(in: songs)
        guard !Task.isCancelled else { return AudioCacheSyncLocalManifest(files: []) }

        var draftsByID: [String: LocalDraft] = [:]
        draftsByID.reserveCapacity(downloadedIDs.count)
        for song in songs where downloadedIDs.contains(song.id) {
            guard let source = sourceByID[song.sourceID] else { continue }
            let cacheFileName = CacheFileNamePolicy.make(
                path: song.filePath,
                preferredExtension: song.fileFormat.rawValue
            )
            guard AudioCacheSyncPolicy.isSafeCacheFileName(cacheFileName) else { continue }
            let id = AudioCacheSyncPolicy.itemID(
                sourceID: song.sourceID,
                cacheFileName: cacheFileName
            )
            if var existing = draftsByID[id] {
                if existing.songIDs.count < 64, !existing.songIDs.contains(song.id) {
                    existing.songIDs.append(song.id)
                }
                existing.catalogByteCount = max(existing.catalogByteCount, song.fileSize)
                draftsByID[id] = existing
            } else {
                draftsByID[id] = LocalDraft(
                    songIDs: [song.id],
                    sourceID: song.sourceID,
                    sourceFingerprint: MusicSourceScopeFingerprint.make(
                        for: source,
                        includeSourceID: true
                    ),
                    cacheFileName: cacheFileName,
                    catalogByteCount: song.fileSize,
                    url: sourceManager.audioCacheTargetURL(for: song),
                    title: song.title
                )
            }
        }

        let drafts = draftsByID.map { ($0.key, $0.value) }
        let files = await Task.detached(priority: .utility) {
            drafts.compactMap { id, draft -> AudioCacheSyncLocalFile? in
                guard let attributes = try? FileManager.default.attributesOfItem(
                    atPath: draft.url.path
                ),
                      (attributes[.type] as? FileAttributeType) == .typeRegular,
                      let number = attributes[.size] as? NSNumber,
                      number.int64Value > 0 else { return nil }
                let byteCount = number.int64Value
                guard AudioCacheSyncPolicy.byteCountIsCompatible(
                    transferredByteCount: byteCount,
                    catalogByteCount: draft.catalogByteCount
                ) else { return nil }
                return AudioCacheSyncLocalFile(
                    item: AudioCacheSyncWireItem(
                        id: id,
                        sourceID: draft.sourceID,
                        sourceFingerprint: draft.sourceFingerprint,
                        songIDs: draft.songIDs.sorted(),
                        cacheFileName: draft.cacheFileName,
                        byteCount: byteCount,
                        catalogByteCount: draft.catalogByteCount
                    ),
                    url: draft.url,
                    title: draft.title
                )
            }.sorted { $0.item.id < $1.item.id }
        }.value
        return AudioCacheSyncLocalManifest(files: files)
    }

    private func prepareIncomingPlan(
        _ request: AudioCacheSyncWireRequest
    ) async -> AudioCacheSyncIncomingPlan {
        guard request.items.count <= AudioCacheSyncPolicy.maximumManifestItems,
              let sourceManager,
              let sourcesStore,
              let library else {
            return AudioCacheSyncIncomingPlan(
                response: AudioCacheSyncWirePlan(
                    missingItemIDs: [],
                    alreadyPresentCount: 0,
                    rejectedCount: request.items.count
                ),
                songsByItemID: [:],
                itemsByID: [:]
            )
        }

        let sourcesByID = Dictionary(
            sourcesStore.sources.filter {
                $0.isEnabled
                    && $0.type != .local
                    && $0.type != .appleMusic
                    && $0.type != .appleMusicLibrary
            }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let songsByID = Dictionary(
            library.songs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var candidates: [(AudioCacheSyncWireItem, Song)] = []
        var seenItemIDs = Set<String>()
        var rejectedCount = 0

        for item in request.items {
            guard seenItemIDs.insert(item.id).inserted,
                  item.id == AudioCacheSyncPolicy.itemID(
                      sourceID: item.sourceID,
                      cacheFileName: item.cacheFileName
                  ),
                  AudioCacheSyncPolicy.isSafeCacheFileName(item.cacheFileName),
                  item.songIDs.count <= 64,
                  let source = sourcesByID[item.sourceID],
                  MusicSourceScopeFingerprint.make(
                      for: source,
                      includeSourceID: true
                  ) == item.sourceFingerprint,
                  let song = item.songIDs.lazy.compactMap({ songsByID[$0] }).first(where: {
                      $0.sourceID == item.sourceID
                          && CacheFileNamePolicy.make(
                              path: $0.filePath,
                              preferredExtension: $0.fileFormat.rawValue
                          ) == item.cacheFileName
                  }),
                  AudioCacheSyncPolicy.byteCountIsCompatible(
                      transferredByteCount: item.byteCount,
                      catalogByteCount: song.fileSize > 0
                          ? song.fileSize
                          : item.catalogByteCount
                  ) else {
                rejectedCount += 1
                continue
            }
            candidates.append((item, song))
        }

        await sourceManager.prepareOfflineAudioSnapshots(
            for: candidates.map(\.1)
        )
        var missingItemIDs: [String] = []
        var acceptedSongs: [String: Song] = [:]
        var acceptedItems: [String: AudioCacheSyncWireItem] = [:]
        var alreadyPresentCount = 0
        for (item, song) in candidates {
            if sourceManager.offlineAudioSnapshot(for: song).isDownloaded {
                alreadyPresentCount += 1
            } else {
                missingItemIDs.append(item.id)
                acceptedSongs[item.id] = song
                acceptedItems[item.id] = item
            }
        }
        return AudioCacheSyncIncomingPlan(
            response: AudioCacheSyncWirePlan(
                missingItemIDs: missingItemIDs,
                alreadyPresentCount: alreadyPresentCount,
                rejectedCount: rejectedCount
            ),
            songsByItemID: acceptedSongs,
            itemsByID: acceptedItems
        )
    }

    private func beginIncomingImport(
        item: AudioCacheSyncWireItem,
        song: Song
    ) async throws -> AudioCacheSyncImportReservation {
        guard let sourceManager else { throw AudioCacheSyncImportError.sourceUnavailable }
        return try await sourceManager.beginAudioCacheSyncImport(
            for: song,
            expectedByteCount: item.byteCount
        )
    }

    private func finishIncomingImport(
        _ reservation: AudioCacheSyncImportReservation
    ) async throws {
        guard let sourceManager else { throw AudioCacheSyncImportError.sourceUnavailable }
        try await sourceManager.finishAudioCacheSyncImport(reservation)
    }

    private func cancelIncomingImport(
        _ reservation: AudioCacheSyncImportReservation
    ) async {
        await sourceManager?.cancelAudioCacheSyncImport(reservation)
    }

    private static func peerPlan(
        peerID: String,
        wirePlan: AudioCacheSyncWirePlan,
        manifest: AudioCacheSyncLocalManifest
    ) -> AudioCacheSyncPeerPlan {
        let files = manifest.filesByID
        let missingBytes = wirePlan.missingItemIDs.reduce(Int64(0)) { total, id in
            let result = total.addingReportingOverflow(files[id]?.item.byteCount ?? 0)
            return result.overflow ? .max : result.partialValue
        }
        return AudioCacheSyncPeerPlan(
            peerID: peerID,
            missingFileCount: wirePlan.missingItemIDs.count,
            missingByteCount: missingBytes,
            alreadyPresentCount: wirePlan.alreadyPresentCount,
            rejectedCount: wirePlan.rejectedCount
        )
    }

    private static func requestPlan(
        endpoint: NWEndpoint,
        receiverPublicKey: Data,
        manifest: AudioCacheSyncLocalManifest,
        action: AudioCacheSyncWireAction
    ) async throws -> AudioCacheSyncWirePlan {
        let socket = AudioCacheSyncSocket(connection: NWConnection(to: endpoint, using: .tcp))
        return try await withTaskCancellationHandler {
            defer { socket.cancel() }
            try await socket.start()
            let session = try await makeClientSession(
                socket: socket,
                receiverPublicKey: receiverPublicKey
            )
            try await session.sendJSON(
                AudioCacheSyncWireRequest(action: action, items: manifest.items)
            )
            let plan = try await session.receiveJSON(AudioCacheSyncWirePlan.self)
            return try validated(plan: plan, manifest: manifest)
        } onCancel: {
            socket.cancel()
        }
    }

    private static func transfer(
        endpoint: NWEndpoint,
        receiverPublicKey: Data,
        manifest: AudioCacheSyncLocalManifest,
        progress: @escaping @Sendable (AudioCacheSyncNetworkProgress) async -> Void
    ) async throws -> (plan: AudioCacheSyncPeerPlan, summary: AudioCacheSyncWireTransferSummary) {
        let socket = AudioCacheSyncSocket(connection: NWConnection(to: endpoint, using: .tcp))
        return try await withTaskCancellationHandler {
            defer { socket.cancel() }
            try await socket.start()
            let session = try await makeClientSession(
                socket: socket,
                receiverPublicKey: receiverPublicKey
            )
            try await session.sendJSON(
                AudioCacheSyncWireRequest(action: .transfer, items: manifest.items)
            )
            let receivedPlan = try await session.receiveJSON(AudioCacheSyncWirePlan.self)
            let wirePlan = try validated(plan: receivedPlan, manifest: manifest)
            let files = manifest.filesByID
            let totalBytes = wirePlan.missingItemIDs.reduce(Int64(0)) { total, id in
                let result = total.addingReportingOverflow(files[id]?.item.byteCount ?? 0)
                return result.overflow ? .max : result.partialValue
            }
            var completed = 0
            var failed = 0
            var sentBytes: Int64 = 0

            await progress(AudioCacheSyncNetworkProgress(
                completedFileCount: 0,
                failedFileCount: 0,
                totalFileCount: wirePlan.missingItemIDs.count,
                sentByteCount: 0,
                totalByteCount: totalBytes,
                currentItemID: wirePlan.missingItemIDs.first
            ))

            for itemID in wirePlan.missingItemIDs {
                try Task.checkCancellation()
                guard let file = files[itemID],
                      let lease = await AudioCacheManager.shared.acquirePathFamilyLease(
                          path: itemID,
                          reserveBytes: 0
                      ) else {
                    try await session.sendJSON(
                        AudioCacheSyncWireFileHeader(itemID: itemID, isAvailable: false)
                    )
                    _ = try await session.receiveJSON(AudioCacheSyncWireReady.self)
                    failed += 1
                    await progress(AudioCacheSyncNetworkProgress(
                        completedFileCount: completed,
                        failedFileCount: failed,
                        totalFileCount: wirePlan.missingItemIDs.count,
                        sentByteCount: sentBytes,
                        totalByteCount: totalBytes,
                        currentItemID: itemID
                    ))
                    continue
                }

                do {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
                    let actualByteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    guard actualByteCount == file.item.byteCount else {
                        try await session.sendJSON(
                            AudioCacheSyncWireFileHeader(itemID: itemID, isAvailable: false)
                        )
                        _ = try await session.receiveJSON(AudioCacheSyncWireReady.self)
                        failed += 1
                        await AudioCacheManager.shared.releasePathFamilyLease(lease)
                        await progress(AudioCacheSyncNetworkProgress(
                            completedFileCount: completed,
                            failedFileCount: failed,
                            totalFileCount: wirePlan.missingItemIDs.count,
                            sentByteCount: sentBytes,
                            totalByteCount: totalBytes,
                            currentItemID: itemID
                        ))
                        continue
                    }

                    try await session.sendJSON(
                        AudioCacheSyncWireFileHeader(itemID: itemID, isAvailable: true)
                    )
                    let ready = try await session.receiveJSON(AudioCacheSyncWireReady.self)
                    guard ready.itemID == itemID, ready.accepted else {
                        failed += 1
                        await AudioCacheManager.shared.releasePathFamilyLease(lease)
                        await progress(AudioCacheSyncNetworkProgress(
                            completedFileCount: completed,
                            failedFileCount: failed,
                            totalFileCount: wirePlan.missingItemIDs.count,
                            sentByteCount: sentBytes,
                            totalByteCount: totalBytes,
                            currentItemID: itemID
                        ))
                        continue
                    }

                    let handle = try FileHandle(forReadingFrom: file.url)
                    defer { try? handle.close() }
                    var fileSent: Int64 = 0
                    var lastPublishedBytes = sentBytes
                    while fileSent < file.item.byteCount {
                        try Task.checkCancellation()
                        let requested = min(
                            AudioCacheSyncPolicy.chunkByteCount,
                            Int(file.item.byteCount - fileSent)
                        )
                        guard let chunk = try handle.read(upToCount: requested),
                              !chunk.isEmpty,
                              chunk.count <= requested else {
                            throw AudioCacheSyncSocketError.connectionClosed
                        }
                        try await session.send(chunk)
                        fileSent += Int64(chunk.count)
                        sentBytes += Int64(chunk.count)
                        if sentBytes - lastPublishedBytes >= 4 * 1_024 * 1_024
                            || fileSent == file.item.byteCount {
                            lastPublishedBytes = sentBytes
                            await progress(AudioCacheSyncNetworkProgress(
                                completedFileCount: completed,
                                failedFileCount: failed,
                                totalFileCount: wirePlan.missingItemIDs.count,
                                sentByteCount: sentBytes,
                                totalByteCount: totalBytes,
                                currentItemID: itemID
                            ))
                        }
                    }
                    let result = try await session.receiveJSON(AudioCacheSyncWireFileResult.self)
                    if result.itemID == itemID, result.succeeded {
                        completed += 1
                    } else {
                        failed += 1
                    }
                    await AudioCacheManager.shared.releasePathFamilyLease(lease)
                } catch {
                    await AudioCacheManager.shared.releasePathFamilyLease(lease)
                    throw error
                }

                await progress(AudioCacheSyncNetworkProgress(
                    completedFileCount: completed,
                    failedFileCount: failed,
                    totalFileCount: wirePlan.missingItemIDs.count,
                    sentByteCount: sentBytes,
                    totalByteCount: totalBytes,
                    currentItemID: itemID
                ))
            }

            try await session.sendJSON(AudioCacheSyncWireCompletionMarker(complete: true))
            let summary = try await session.receiveJSON(AudioCacheSyncWireTransferSummary.self)
            let finalizedPlan = AudioCacheSyncPeerPlan(
                peerID: "",
                missingFileCount: max(0, wirePlan.missingItemIDs.count - summary.transferredFileCount),
                missingByteCount: max(0, totalBytes - summary.transferredByteCount),
                alreadyPresentCount: wirePlan.alreadyPresentCount + summary.transferredFileCount,
                rejectedCount: wirePlan.rejectedCount
            )
            return (finalizedPlan, summary)
        } onCancel: {
            socket.cancel()
        }
    }

    private static func validated(
        plan: AudioCacheSyncWirePlan,
        manifest: AudioCacheSyncLocalManifest
    ) throws -> AudioCacheSyncWirePlan {
        guard plan.alreadyPresentCount >= 0,
              plan.rejectedCount >= 0,
              plan.alreadyPresentCount <= manifest.files.count,
              plan.rejectedCount <= manifest.files.count - plan.alreadyPresentCount,
              plan.missingItemIDs.count
                  == manifest.files.count
                    - plan.alreadyPresentCount
                    - plan.rejectedCount else {
            throw AudioCacheSyncSocketError.invalidMessage
        }
        let availableIDs = Set(manifest.files.map(\.item.id))
        let missingIDs = Set(plan.missingItemIDs)
        guard missingIDs.count == plan.missingItemIDs.count,
              missingIDs.isSubset(of: availableIDs) else {
            throw AudioCacheSyncSocketError.invalidMessage
        }
        return plan
    }

    private static func makeClientSession(
        socket: AudioCacheSyncSocket,
        receiverPublicKey: Data
    ) async throws -> AudioCacheSyncSecureSession {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: receiverPublicKey
        )
        let sessionID = UUID().uuidString
        let hello = AudioCacheSyncWireHello(
            version: AudioCacheSyncPolicy.protocolVersion,
            sessionID: sessionID,
            publicKey: privateKey.publicKey.rawRepresentation
        )
        try await socket.sendFrame(try JSONEncoder().encode(hello))
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sessionID.utf8),
            sharedInfo: Data("PrimuseAudioCacheSync.v1".utf8),
            outputByteCount: 32
        )
        return AudioCacheSyncSecureSession(
            socket: socket,
            key: key,
            sessionID: sessionID,
            role: .client
        )
    }

    private nonisolated static func handleIncomingConnection(
        _ connection: NWConnection,
        receiverPrivateKey: Data,
        service: AudioCacheSyncService
    ) async {
        let socket = AudioCacheSyncSocket(connection: connection)
        await withTaskCancellationHandler {
            defer { socket.cancel() }
            do {
                try await socket.start()
                let helloData = try await socket.receiveFrame(maximumLength: 8 * 1_024)
                let hello = try JSONDecoder().decode(AudioCacheSyncWireHello.self, from: helloData)
                guard hello.version == AudioCacheSyncPolicy.protocolVersion,
                      hello.publicKey.count == 32,
                      await service.claimIncomingSession(hello.sessionID) else {
                    throw AudioCacheSyncSocketError.invalidHandshake
                }
                let privateKey = try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: receiverPrivateKey
                )
                let publicKey = try Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: hello.publicKey
                )
                let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
                let key = sharedSecret.hkdfDerivedSymmetricKey(
                    using: SHA256.self,
                    salt: Data(hello.sessionID.utf8),
                    sharedInfo: Data("PrimuseAudioCacheSync.v1".utf8),
                    outputByteCount: 32
                )
                let session = AudioCacheSyncSecureSession(
                    socket: socket,
                    key: key,
                    sessionID: hello.sessionID,
                    role: .server
                )
                let request = try await session.receiveJSON(AudioCacheSyncWireRequest.self)
                let incomingPlan = await service.prepareIncomingPlan(request)
                try await session.sendJSON(incomingPlan.response)
                guard request.action == .transfer else { return }

                var transferred = 0
                var failed = 0
                var transferredBytes: Int64 = 0
                for itemID in incomingPlan.response.missingItemIDs {
                    let header = try await session.receiveJSON(AudioCacheSyncWireFileHeader.self)
                    guard header.itemID == itemID else {
                        throw AudioCacheSyncSocketError.invalidMessage
                    }
                    guard header.isAvailable,
                          let item = incomingPlan.itemsByID[itemID],
                          let song = incomingPlan.songsByItemID[itemID] else {
                        failed += 1
                        try await session.sendJSON(
                            AudioCacheSyncWireReady(itemID: itemID, accepted: false)
                        )
                        continue
                    }

                    let reservation: AudioCacheSyncImportReservation
                    do {
                        reservation = try await service.beginIncomingImport(item: item, song: song)
                    } catch {
                        failed += 1
                        try await session.sendJSON(
                            AudioCacheSyncWireReady(itemID: itemID, accepted: false)
                        )
                        continue
                    }
                    try await session.sendJSON(
                        AudioCacheSyncWireReady(itemID: itemID, accepted: true)
                    )

                    var installed = false
                    do {
                        guard FileManager.default.createFile(
                            atPath: reservation.stagingURL.path,
                            contents: nil
                        ) else {
                            throw AudioCacheSyncSocketError.connectionFailed
                        }
                        let output = try FileHandle(forWritingTo: reservation.stagingURL)
                        defer { try? output.close() }
                        var received: Int64 = 0
                        while received < item.byteCount {
                            let chunk = try await session.receive(
                                maximumPlaintextLength: AudioCacheSyncPolicy.chunkByteCount
                            )
                            let nextReceived = received.addingReportingOverflow(
                                Int64(chunk.count)
                            )
                            guard !chunk.isEmpty,
                                  !nextReceived.overflow,
                                  nextReceived.partialValue <= item.byteCount else {
                                throw AudioCacheSyncSocketError.invalidFrame
                            }
                            try output.write(contentsOf: chunk)
                            received = nextReceived.partialValue
                        }
                        try output.synchronize()
                        try output.close()
                        try await service.finishIncomingImport(reservation)
                        installed = true
                        transferred += 1
                        transferredBytes += item.byteCount
                        try await session.sendJSON(
                            AudioCacheSyncWireFileResult(itemID: itemID, succeeded: true)
                        )
                    } catch {
                        if !installed {
                            await service.cancelIncomingImport(reservation)
                        }
                        failed += 1
                        try? await session.sendJSON(
                            AudioCacheSyncWireFileResult(itemID: itemID, succeeded: false)
                        )
                        if error is AudioCacheSyncSocketError {
                            throw error
                        }
                    }
                }

                let marker = try await session.receiveJSON(
                    AudioCacheSyncWireCompletionMarker.self
                )
                guard marker.complete else { throw AudioCacheSyncSocketError.invalidMessage }
                try await session.sendJSON(AudioCacheSyncWireTransferSummary(
                    transferredFileCount: transferred,
                    failedFileCount: failed,
                    transferredByteCount: transferredBytes
                ))
                Task { @MainActor in
                    service.refreshLocalInventory()
                }
            } catch {
                return
            }
        } onCancel: {
            socket.cancel()
        }
    }
}

private final class AudioCacheSyncSecureSession: @unchecked Sendable {
    enum Role {
        case client
        case server
    }

    private let socket: AudioCacheSyncSocket
    private let key: SymmetricKey
    private let sessionID: String
    private let role: Role
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    init(socket: AudioCacheSyncSocket, key: SymmetricKey, sessionID: String, role: Role) {
        self.socket = socket
        self.key = key
        self.sessionID = sessionID
        self.role = role
    }

    func sendJSON<T: Encodable>(_ value: T) async throws {
        try await send(JSONEncoder().encode(value))
    }

    func receiveJSON<T: Decodable>(_ type: T.Type) async throws -> T {
        let data = try await receive(
            maximumPlaintextLength: AudioCacheSyncPolicy.maximumControlFrameByteCount
        )
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AudioCacheSyncSocketError.invalidMessage
        }
    }

    func send(_ plaintext: Data) async throws {
        let sequence = sendSequence
        sendSequence &+= 1
        do {
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: additionalData(
                    direction: role == .client ? "c2s" : "s2c",
                    sequence: sequence
                )
            )
            guard let combined = sealed.combined else {
                throw AudioCacheSyncSocketError.encryptionFailed
            }
            try await socket.sendFrame(combined)
        } catch let error as AudioCacheSyncSocketError {
            throw error
        } catch {
            throw AudioCacheSyncSocketError.encryptionFailed
        }
    }

    func receive(maximumPlaintextLength: Int) async throws -> Data {
        let combined = try await socket.receiveFrame(
            maximumLength: maximumPlaintextLength + 64
        )
        let sequence = receiveSequence
        receiveSequence &+= 1
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                box,
                using: key,
                authenticating: additionalData(
                    direction: role == .client ? "s2c" : "c2s",
                    sequence: sequence
                )
            )
        } catch {
            throw AudioCacheSyncSocketError.encryptionFailed
        }
    }

    private func additionalData(direction: String, sequence: UInt64) -> Data {
        Data("PrimuseAudioCacheSync.v1|\(sessionID)|\(direction)|\(sequence)".utf8)
    }
}

private final class AudioCacheSyncSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "com.welape.primuse.cache-sync.socket.\(UUID().uuidString)"
    )
    private var receiveBuffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AudioCacheSyncConnectionStartGate(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.finish(with: .success(()))
                case .failed, .cancelled:
                    gate.finish(with: .failure(AudioCacheSyncSocketError.connectionFailed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            gate.scheduleTimeout(on: queue, after: 8)
        }
    }

    func cancel() {
        connection.cancel()
    }

    func sendFrame(_ data: Data) async throws {
        guard data.count <= AudioCacheSyncPolicy.maximumControlFrameByteCount + 64,
              data.count <= Int(UInt32.max) else {
            throw AudioCacheSyncSocketError.frameTooLarge
        }
        var length = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(data)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = AudioCacheSyncConnectionStartGate(
                connection: connection,
                continuation: continuation
            )
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    gate.finish(with: .failure(error))
                } else {
                    gate.finish(with: .success(()))
                }
            })
            gate.scheduleTimeout(
                on: queue,
                after: AudioCacheSyncPolicy.frameIdleTimeout
            )
        }
    }

    func receiveFrame(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AudioCacheSyncReceiveGate(
                connection: connection,
                continuation: continuation
            )
            queue.async { [self] in
                readFrame(maximumLength: maximumLength, gate: gate)
                gate.scheduleTimeout(
                    on: queue,
                    after: AudioCacheSyncPolicy.frameIdleTimeout
                )
            }
        }
    }

    private func readFrame(
        maximumLength: Int,
        gate: AudioCacheSyncReceiveGate
    ) {
        if receiveBuffer.count >= 4 {
            let start = receiveBuffer.startIndex
            let length = Int(receiveBuffer[start]) << 24
                | Int(receiveBuffer[start + 1]) << 16
                | Int(receiveBuffer[start + 2]) << 8
                | Int(receiveBuffer[start + 3])
            guard length > 0, length <= maximumLength else {
                gate.finish(with: .failure(AudioCacheSyncSocketError.frameTooLarge))
                return
            }
            if receiveBuffer.count >= 4 + length {
                let payloadStart = receiveBuffer.index(start, offsetBy: 4)
                let payloadEnd = receiveBuffer.index(payloadStart, offsetBy: length)
                let payload = Data(receiveBuffer[payloadStart..<payloadEnd])
                receiveBuffer.removeSubrange(start..<payloadEnd)
                gate.finish(with: .success(payload))
                return
            }
        }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 512 * 1_024
        ) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                readFrame(maximumLength: maximumLength, gate: gate)
            } else if let error {
                gate.finish(with: .failure(error))
            } else if isComplete {
                gate.finish(with: .failure(AudioCacheSyncSocketError.connectionClosed))
            } else {
                readFrame(maximumLength: maximumLength, gate: gate)
            }
        }
    }
}

private final class AudioCacheSyncReceiveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func scheduleTimeout(on queue: DispatchQueue, after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.finish(with: .failure(AudioCacheSyncSocketError.connectionFailed))
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        timeoutWorkItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func finish(with result: Result<Data, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()
        timeoutWorkItem?.cancel()
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            connection.cancel()
            continuation.resume(throwing: error)
        }
    }
}

private final class AudioCacheSyncConnectionStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func scheduleTimeout(on queue: DispatchQueue, after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.finish(with: .failure(AudioCacheSyncSocketError.connectionFailed))
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        timeoutWorkItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func finish(with result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()
        timeoutWorkItem?.cancel()
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            connection.cancel()
            continuation.resume(throwing: error)
        }
    }
}
#endif
