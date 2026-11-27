import Foundation
import os
import PrimuseKit

/// 这台设备单独关了 iCloud 同步的音乐源。钥匙串在任意线程上被调用,读不到 SourcesStore,
/// 所以由它把名单(连同各源的附属钥匙串账号)同步到这里。
enum SourceCloudSyncOptOutRegistry {
    private static let accounts = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func update(optedOutSourceIDs: Set<String>) {
        var expanded = Set<String>()
        for sourceID in optedOutSourceIDs {
            expanded.insert(sourceID)
            expanded.insert(FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: sourceID))
            expanded.insert(FnConnectGatewayProtocol.sourceCredentialAccount(sourceID: sourceID))
            expanded.insert(PlexAccountAPI.accountTokenKeychainAccount(sourceID: sourceID))
        }
        let snapshot = expanded
        accounts.withLock { $0 = snapshot }
    }

    /// 这个钥匙串账号属于一个关了 iCloud 同步的音乐源。
    static func isOptedOut(account: String) -> Bool {
        accounts.withLock { $0.contains(account) }
    }
}

extension Notification.Name {
    /// 一个音乐源在这台设备上打开或关掉了 iCloud 同步。userInfo: `id`、`syncsViaICloud`、
    /// `uploadsLocal`(重新打开时本机这份要不要传上去)。
    static let primuseSourceCloudSyncPreferenceDidChange =
        Notification.Name("primuse.sourceCloudSyncPreferenceDidChange")
}

#if os(iOS) || os(macOS)
enum FnConnectGatewayCredentialStore {
    struct ReusableCandidate: Equatable, Sendable {
        enum Origin: Equatable, Sendable {
            case sharedProfile
            case fnMusicSource(sourceID: String)
        }

        let fnID: String
        let username: String
        let origin: Origin
    }

    private struct RegistryState {
        var sourceBindingsByID: [String: FnConnectGatewayBinding] = [:]
        var sourceIDByHost: [String: String] = [:]
        var fnMusicSourcesByFNID: [String: (sourceID: String, username: String)] = [:]
        var installedProvider = false
    }

    private static let state = OSAllocatedUnfairLock<RegistryState>(initialState: RegistryState())

    static func installSessionStoreProviderIfNeeded() {
        let shouldInstall = state.withLock { current -> Bool in
            guard !current.installedProvider else { return false }
            current.installedProvider = true
            return true
        }
        guard shouldInstall else { return }
        Task {
            await FnConnectGatewaySessionStore.shared.configure(
                credentialResolver: { _, fnID, requestHost, explicitSourceID in
                    resolveCredentialForRequest(
                        fnID: fnID,
                        requestHost: requestHost,
                        explicitSourceID: explicitSourceID
                    )
                },
                sessionLoader: { fnID, username in
                    loadLocalSession(fnID: fnID, username: username)
                },
                sessionSaver: { session in
                    saveLocalSession(session)
                },
                sessionRemover: { fnID, username in
                    deleteLocalSession(fnID: fnID, username: username)
                }
            )
        }
    }

    static func updateSources(_ sources: [MusicSource]) {
        var bindings: [String: FnConnectGatewayBinding] = [:]
        var hostMap: [String: String] = [:]
        var fnMusicMap: [String: (sourceID: String, username: String)] = [:]

        for source in sources where !source.isDeleted {
            if source.type == .fnMusic {
                if let fnID = fnIDForFnMusicSource(source),
                   let username = source.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !username.isEmpty,
                   fnMusicMap[fnID] == nil {
                    fnMusicMap[fnID] = (source.id, username)
                }
                continue
            }
            if let binding = source.fnConnectGateway {
                bindings[source.id] = binding
            }
            for address in source.fnConnectGatewayAddresses {
                if hostMap[address.host] == nil || source.fnConnectGateway != nil {
                    hostMap[address.host] = source.id
                }
            }
        }

        let bindingsSnapshot = bindings
        let hostMapSnapshot = hostMap
        let fnMusicMapSnapshot = fnMusicMap
        state.withLock { current in
            current.sourceBindingsByID = bindingsSnapshot
            current.sourceIDByHost = hostMapSnapshot
            current.fnMusicSourcesByFNID = fnMusicMapSnapshot
        }
    }

    static func fnIDForFnMusicSource(_ source: MusicSource) -> String? {
        guard source.type == .fnMusic else { return nil }
        if let vendor = source.effectiveConnectionConfiguration?.vendorIdentifier,
           let parsed = FnConnectResolver.fnID(from: vendor) {
            return parsed
        }
        if source.effectiveFnMusicConnectionMode == .fnConnect,
           let host = source.host,
           let parsed = FnConnectResolver.fnID(from: host) {
            return parsed
        }
        if let host = source.host,
           let address = FnConnectGatewayAddress.parseHost(host) {
            return address.fnID
        }
        if let publicHost = source.effectiveConnectionConfiguration?.publicEndpoint?.host,
           let address = FnConnectGatewayAddress.parseHost(publicHost) {
            return address.fnID
        }
        return nil
    }

    static func reusableCandidate(
        forFNID rawFNID: String,
        sources: [MusicSource]
    ) -> ReusableCandidate? {
        let fnID = rawFNID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !fnID.isEmpty else { return nil }

        if let shared = loadSharedCredential(fnID: fnID),
           !shared.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !shared.password.isEmpty {
            return ReusableCandidate(
                fnID: fnID,
                username: shared.username,
                origin: .sharedProfile
            )
        }

        for source in sources where !source.isDeleted && source.type == .fnMusic {
            guard fnIDForFnMusicSource(source) == fnID,
                  let username = source.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !username.isEmpty else { continue }
            if case .found(let password) = KeychainService.passwordLookup(for: source.id),
               !password.isEmpty {
                return ReusableCandidate(
                    fnID: fnID,
                    username: username,
                    origin: .fnMusicSource(sourceID: source.id)
                )
            }
        }
        return nil
    }

    static func resolveCredential(for candidate: ReusableCandidate) -> FnConnectGatewayCredential? {
        switch candidate.origin {
        case .sharedProfile:
            return loadSharedCredential(fnID: candidate.fnID)
        case .fnMusicSource(let sourceID):
            guard case .found(let password) = KeychainService.passwordLookup(for: sourceID),
                  !password.isEmpty else {
                return nil
            }
            let accessCode: String?
            if case .found(let code) = KeychainService.passwordLookup(
                for: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: sourceID)
            ), !code.isEmpty {
                accessCode = code
            } else {
                accessCode = nil
            }
            return FnConnectGatewayCredential(
                fnID: candidate.fnID,
                username: candidate.username,
                password: password,
                accessCode: accessCode
            )
        }
    }

    static func loadSharedCredential(fnID: String) -> FnConnectGatewayCredential? {
        let account = FnConnectGatewayProtocol.sharedCredentialAccount(fnID: fnID)
        guard case .found(let encoded) = KeychainService.passwordLookup(for: account) else {
            return nil
        }
        return FnConnectGatewayCredential.decode(from: encoded)
    }

    static func loadDedicatedCredential(sourceID: String) -> FnConnectGatewayCredential? {
        let account = FnConnectGatewayProtocol.sourceCredentialAccount(sourceID: sourceID)
        guard case .found(let encoded) = KeychainService.passwordLookup(for: account) else {
            return nil
        }
        return FnConnectGatewayCredential.decode(from: encoded)
    }

    @discardableResult
    static func saveSharedCredential(_ credential: FnConnectGatewayCredential) -> Bool {
        guard let encoded = credential.encodedJSONString() else { return false }
        return KeychainService.setPassword(
            encoded,
            for: FnConnectGatewayProtocol.sharedCredentialAccount(fnID: credential.fnID)
        )
    }

    @discardableResult
    static func saveDedicatedCredential(
        _ credential: FnConnectGatewayCredential,
        sourceID: String
    ) -> Bool {
        guard let encoded = credential.encodedJSONString() else { return false }
        return KeychainService.setPassword(
            encoded,
            for: FnConnectGatewayProtocol.sourceCredentialAccount(sourceID: sourceID)
        )
    }

    @discardableResult
    static func deleteDedicatedCredential(sourceID: String) -> Bool {
        KeychainService.deletePassword(
            for: FnConnectGatewayProtocol.sourceCredentialAccount(sourceID: sourceID)
        )
    }

    static func loadEffectiveCredential(
        for source: MusicSource,
        allSources: [MusicSource]
    ) -> FnConnectGatewayCredential? {
        guard source.type != .fnMusic, source.type.usesHTTPTransport else { return nil }
        if let binding = source.fnConnectGateway {
            switch binding.scope {
            case .dedicated:
                if let dedicated = loadDedicatedCredential(sourceID: source.id) {
                    return dedicated
                }
            case .shared:
                if let shared = loadSharedCredential(fnID: binding.fnID) {
                    return shared
                }
            }
            if let candidate = reusableCandidate(forFNID: binding.fnID, sources: allSources) {
                return resolveCredential(for: candidate)
            }
            return nil
        }
        guard let address = source.fnConnectGatewayAddresses.first else { return nil }
        if let shared = loadSharedCredential(fnID: address.fnID) {
            return shared
        }
        if let candidate = reusableCandidate(forFNID: address.fnID, sources: allSources) {
            return resolveCredential(for: candidate)
        }
        return nil
    }

    static func invalidateSession(forSourceID sourceID: String) {
        let binding = state.withLock { $0.sourceBindingsByID[sourceID] }
        guard let binding else { return }
        Task {
            await FnConnectGatewaySessionStore.shared.invalidate(
                fnID: binding.fnID,
                username: binding.username
            )
        }
    }

    static func deleteCredentialsOnPermanentDelete(
        _ source: MusicSource,
        remainingSources: [MusicSource]
    ) -> Bool {
        guard source.type != .fnMusic else { return true }
        let dedicatedDeleted = deleteDedicatedCredential(sourceID: source.id)
        guard dedicatedDeleted else { return false }

        if let binding = source.fnConnectGateway {
            let stillReferenced = remainingSources.contains { other in
                guard other.id != source.id, !other.isDeleted, other.type != .fnMusic else {
                    return false
                }
                if other.fnConnectGateway?.fnID == binding.fnID { return true }
                return other.fnConnectGatewayAddresses.contains { $0.fnID == binding.fnID }
            }
            if !stillReferenced {
                if binding.scope == .shared, !SourceCloudSyncOptOutRegistry.isOptedOut(account: source.id) {
                    let sharedDeleted = KeychainService.deletePassword(
                        for: FnConnectGatewayProtocol.sharedCredentialAccount(fnID: binding.fnID)
                    )
                    guard sharedDeleted else { return false }
                }
                Task {
                    await FnConnectGatewaySessionStore.shared.invalidate(
                        fnID: binding.fnID,
                        username: binding.username,
                        clearPersisted: true
                    )
                }
            }
        }
        return true
    }

    private static func resolveCredentialForRequest(
        fnID: String,
        requestHost: String,
        explicitSourceID: String?
    ) -> FnConnectGatewayCredential? {
        let normalizedFNID = fnID.lowercased()
        let normalizedHost = requestHost.lowercased()
        let snapshot = state.withLock { current -> (sourceID: String?, binding: FnConnectGatewayBinding?, fnMusic: (sourceID: String, username: String)?) in
            let resolvedSourceID = explicitSourceID ?? current.sourceIDByHost[normalizedHost]
            let binding = resolvedSourceID.flatMap { current.sourceBindingsByID[$0] }
            return (resolvedSourceID, binding, current.fnMusicSourcesByFNID[normalizedFNID])
        }

        if let sourceID = snapshot.sourceID,
           snapshot.binding?.scope == .dedicated,
           let dedicated = loadDedicatedCredential(sourceID: sourceID) {
            return dedicated
        }
        if let shared = loadSharedCredential(fnID: normalizedFNID) {
            return shared
        }
        if let fnMusic = snapshot.fnMusic,
           case .found(let password) = KeychainService.passwordLookup(for: fnMusic.sourceID),
           !password.isEmpty {
            let accessCode: String?
            if case .found(let code) = KeychainService.passwordLookup(
                for: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: fnMusic.sourceID)
            ), !code.isEmpty {
                accessCode = code
            } else {
                accessCode = nil
            }
            return FnConnectGatewayCredential(
                fnID: normalizedFNID,
                username: fnMusic.username,
                password: password,
                accessCode: accessCode
            )
        }
        return nil
    }

    private static func loadLocalSession(fnID: String, username: String) -> FnConnectGatewayPersistedSession? {
        let account = FnConnectGatewayProtocol.localSessionAccount(fnID: fnID, username: username)
        guard case .found(let encoded) = KeychainService.localOnlyPasswordLookup(for: account) else {
            return nil
        }
        return FnConnectGatewayPersistedSession.decode(from: encoded)
    }

    private static func saveLocalSession(_ session: FnConnectGatewayPersistedSession) {
        guard let encoded = session.encodedJSONString() else { return }
        let account = FnConnectGatewayProtocol.localSessionAccount(
            fnID: session.fnID,
            username: session.username
        )
        _ = KeychainService.setLocalOnlyPassword(encoded, for: account)
    }

    private static func deleteLocalSession(fnID: String, username: String) {
        let account = FnConnectGatewayProtocol.localSessionAccount(fnID: fnID, username: username)
        _ = KeychainService.deletePassword(for: account)
    }
}
#endif

private actor SourceCredentialPurgeExecutor {
    static let shared = SourceCredentialPurgeExecutor()

    func purge(_ source: MusicSource, remainingSources: [MusicSource]) -> Bool {
        #if os(iOS) || os(macOS)
        let requiredStores = SourcePermanentDeletionPolicy.requiredCredentialStores(
            for: source.type,
            authType: source.authType
        )
        let passwordDeleted = !requiredStores.contains(.password)
            || KeychainService.deletePassword(for: source.id)
        let fnConnectAccessCodeDeleted = source.type != .fnMusic
            || KeychainService.deletePassword(
                for: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: source.id)
            )
        let fnConnectGatewayDeleted = FnConnectGatewayCredentialStore.deleteCredentialsOnPermanentDelete(
            source,
            remainingSources: remainingSources
        )
        let plexAccountTokenDeleted = source.type != .plex
            || KeychainService.deletePassword(
                for: PlexAccountAPI.accountTokenKeychainAccount(sourceID: source.id)
            )
        // 这台设备单独关了 iCloud 同步的源:云盘授权存在 iCloud 钥匙串里、别的设备还在用,
        // 在这里彻底删除时不动它(删了会在所有设备上一起删)。密码类走 KeychainService,
        // 那边同样只删这台设备上的那份。
        let cloudCredentialsDeleted = !requiredStores.contains(.cloudCredentials)
            || SourceCloudSyncOptOutRegistry.isOptedOut(account: source.id)
            || CloudTokenManager.deleteStoredCredentials(for: source.id)
        guard SourcePermanentDeletionPolicy.canRemoveTombstone(
            requiredStores: requiredStores,
            passwordDeleted: passwordDeleted,
            cloudCredentialsDeleted: cloudCredentialsDeleted
        ), fnConnectAccessCodeDeleted, fnConnectGatewayDeleted, plexAccountTokenDeleted else { return false }
        LocalBookmarkStore.remove(sourceID: source.id)
        CloudDirectoryNameStore.deleteAll(for: source.id)
        #endif
        return true
    }
}

@MainActor
@Observable
final class SourcesStore {

    /// Backing storage including soft-deleted entries. `sources` filters this
    /// for normal UI use; `recentlyDeletedSources` exposes the deleted ones.
    private(set) var allSources: [MusicSource]
    private(set) var hasCompleteSnapshot = true

    /// Deletion evidence lives independently from user-facing source rows so a
    /// permanent prune cannot make an old CloudKit record eligible to restore.
    private(set) var sourceDeletionRecords: [MusicSourceDeletionRecord]

    /// Source tombstones whose required credential cleanup failed during this
    /// run. Keeping this observable lets both automatic pruning and manual
    /// deletion surface a retry target in Recently Deleted.
    private(set) var permanentDeletionFailureIDs: Set<String> = []

    /// Sources whose durable tombstone has been recorded and whose credentials
    /// are currently being removed away from the main actor.
    private(set) var permanentDeletionInProgressIDs: Set<String> = []

    /// CloudAccount entities owning OAuth-typed mounts. Persisted to a
    /// sibling JSON file (`cloudAccounts.json`). Stage 2 keeps this
    /// internal — UI doesn't read from it yet; stage 4 will wire OAuth
    /// to consult this list before minting a new mount, eliminating
    /// duplicate-account-from-reconnect.
    private(set) var allAccounts: [CloudAccount]

    /// 每个源在这台设备上的设置:同步配置里的启用值、是否经 iCloud 同步、关着期间收到的
    /// 远端配置。启用状态本身就是 `allSources` 里的 `isEnabled`,只在这台设备上生效。
    private(set) var deviceSettings = MusicSourceDeviceSettings()

    private let storeURL: URL
    private let accountsURL: URL
    private let sourceDeletionsURL: URL
    private let createdOnThisDeviceURL: URL
    private let deviceSettingsURL: URL
    /// 钥匙串查的是全局名单,只让 App 自己那份(默认目录)去写;取证页、测试另建的
    /// store 不能把它改掉。
    private let publishesKeychainOptOuts: Bool
    private let sourceDataWriter: (Data, URL) throws -> Void
    private let credentialPurger: CredentialPurger
    private let isUsingDefaultCredentialPurger: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Armed while a coalesced scan-counter write is waiting for its window.
    /// Any other persist path subsumes it: the encode always covers the whole
    /// `allSources` array, so there is never a partially-written generation.
    @ObservationIgnored private var coalescedPersistTask: Task<Void, Never>?
    @ObservationIgnored private var lastCoalescedPersistAt = Date.distantPast
    /// True once the scene left the foreground; see `setSceneBackgrounded`.
    @ObservationIgnored private var isSceneBackgrounded = false
    /// 在本机新建(经 `add` / `addDurably` 进来的新 id)、还没扫完过一次的源。id 是本机
    /// 生成的,别的设备只有在它同步过去之后扫过才会有它的行,首扫时不必先等别的设备的
    /// 结果(见 `PeerScanSeedCoordinator.lookup`)。存盘,首扫前被关掉的下次启动也认得。
    @ObservationIgnored private(set) var sourceIDsCreatedOnThisDevice: Set<String> = []
    /// 其中这次运行里才建的:别的设备不可能扫过。
    @ObservationIgnored private(set) var sourceIDsCreatedThisRun: Set<String> = []

    init(
        fileManager: FileManager = .default,
        storageDirectoryURL: URL? = nil,
        sourceDataWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        credentialPurger: CredentialPurger? = nil,
        publishesKeychainOptOuts: Bool? = nil
    ) {
        // tvOS 只允许写 Caches / tmp;须与 LibrarySnapshotSync / MusicLibrary 同目录。
        let directory: URL
        if let storageDirectoryURL {
            directory = storageDirectoryURL
        } else {
            #if os(tvOS)
            let appSupport = fileManager.primuseDirectoryURL(for: .cachesDirectory)
            #else
            let appSupport = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
            #endif
            directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.storeURL = directory.appendingPathComponent("sources.json")
        self.accountsURL = directory.appendingPathComponent("cloudAccounts.json")
        self.sourceDeletionsURL = directory.appendingPathComponent(MusicSourceDeletionRecord.fileName)
        self.createdOnThisDeviceURL = directory.appendingPathComponent("sourcesCreatedOnThisDevice.json")
        self.deviceSettingsURL = directory.appendingPathComponent(MusicSourceDeviceSettings.fileName)
        self.publishesKeychainOptOuts = publishesKeychainOptOuts ?? (storageDirectoryURL == nil)
        self.sourceDataWriter = sourceDataWriter
        self.isUsingDefaultCredentialPurger = credentialPurger == nil
        self.credentialPurger = credentialPurger ?? { source in
            await SourceCredentialPurgeExecutor.shared.purge(source, remainingSources: [])
        }
        self.allSources = []
        self.allAccounts = []
        self.sourceDeletionRecords = []

        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
        loadSourceDeletions()
        migrateSourceTombstonesIntoDeletionLedger()
        reconcileSourcesWithDeletionLedger()
        pruneForeignDeviceLocalSources()
        loadAccounts()
        loadSourcesCreatedOnThisDevice()
        loadDeviceSettings()
        #if os(iOS) || os(macOS)
        if self.publishesKeychainOptOuts {
            FnConnectGatewayCredentialStore.installSessionStoreProviderIfNeeded()
            FnConnectGatewayCredentialStore.updateSources(allSources)
        }
        #endif
    }
}

extension SourcesStore {
    typealias CredentialPurger = @Sendable (MusicSource) async -> Bool

    enum PermanentDeleteResult: Equatable {
        case deleted
        case sourceNotFound
        case sourceChanged
        case alreadyInProgress
        case credentialCleanupFailed
        case deletionLedgerPersistFailed
    }

    func validatedSourcesForSnapshot() throws -> [MusicSource] {
        guard hasCompleteSnapshot else { throw CocoaError(.fileReadCorruptFile) }
        return allSources
    }

    /// Live (non-deleted) sources for normal UI use.
    var sources: [MusicSource] { allSources.filter { !$0.isDeleted } }

    var typesByID: [String: MusicSourceType] {
        allSources.reduce(into: [:]) { $0[$1.id] = $1.type }
    }

    var sourceDeletionIDs: [String] { sourceDeletionRecords.map(\.id) }

    /// Soft-deleted sources, newest deletion first.
    var recentlyDeletedSources: [MusicSource] {
        allSources
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Live (non-deleted) accounts.
    var accounts: [CloudAccount] { allAccounts.filter { !$0.isDeleted } }

    /// 只改了这台设备上的状态(启用 / 停用)。iCloud 同步不把这种变更当成要上传的修改。
    nonisolated static let deviceOnlyChangeOrigin = "device"

    func source(id: String) -> MusicSource? {
        allSources.first(where: { $0.id == id })
    }

    /// Metadata-only eligibility shared by manual song and collection actions.
    /// Local originals do not become downloads just because their cache is empty.
    func downloadableSongs(in songs: [Song]) -> [Song] {
        OfflineDownloadActionPolicy.downloadableSongs(in: songs, sources: allSources)
    }

    func containsDownloadableSong(in songs: [Song]) -> Bool {
        OfflineDownloadActionPolicy.containsDownloadableSong(in: songs, sources: allSources)
    }

    /// tvOS 下载到新 sources.json 后重新从磁盘加载。
    func reloadFromDisk() {
        load()
        loadSourceDeletions()
        migrateSourceTombstonesIntoDeletionLedger()
        reconcileSourcesWithDeletionLedger()
        pruneForeignDeviceLocalSources()
        loadAccounts()
        loadSourcesCreatedOnThisDevice()
        loadDeviceSettings()
        #if os(iOS) || os(macOS)
        if publishesKeychainOptOuts {
            FnConnectGatewayCredentialStore.updateSources(allSources)
        }
        #endif
    }

    func sourceDeletionRecord(id: String) -> MusicSourceDeletionRecord? {
        sourceDeletionRecords.first(where: { $0.id == id })
    }

    func registerDeletionTombstone(_ tombstone: MusicSource) {
        guard tombstone.isDeleted else { return }
        let deletion = MusicSourceDeletionRecord(tombstone: tombstone)
        if let active = allSources.first(where: { $0.id == tombstone.id && !$0.isDeleted }),
           MusicSourceLifecyclePolicy.isExplicitRestore(active, after: deletion) {
            return
        }
        recordSourceDeletion(tombstone: tombstone)
        if reconcileSourcesWithDeletionLedger().contains(tombstone.id) {
            notifyChanged([tombstone.id])
        }
    }

    func add(_ source: MusicSource) {
        if self.source(id: source.id) == nil {
            noteCreatedOnThisDevice(source.id)
        }
        upsert(source)
    }

    /// Adds a source only after `sources.json` has been atomically persisted.
    /// The Files import path uses this before starting a scan so an out-of-space
    /// error cannot leave a source that exists only in memory.
    func addDurably(_ source: MusicSource) throws {
        let previousSources = allSources
        let previousDeletionRecords = sourceDeletionRecords
        let isNew = self.source(id: source.id) == nil
        applyUpsert(source)
        do {
            try persistThrowing()
        } catch {
            allSources = previousSources
            sourceDeletionRecords = previousDeletionRecords
            _ = persistSourceDeletions()
            throw error
        }
        if isNew { noteCreatedOnThisDevice(source.id) }
        notifyChanged([source.id])
    }

    func upsert(_ source: MusicSource) {
        let previous = allSources.first { $0.id == source.id }
        applyUpsert(source)
        persist()
        notifyChanged([source.id], previous: previous.map { [source.id: $0] } ?? [:])
    }

    private func applyUpsert(_ source: MusicSource) {
        var stamped = source
        let selectedDirectories = Set(stamped.scannedDirectories)
        stamped.scannedDirectoryDisplayNames = stamped.scannedDirectoryDisplayNames.filter {
            selectedDirectories.contains($0.key)
        }
        let now = Date()
        stamped.modifiedAt = now
        if !stamped.isDeleted,
           let deletion = sourceDeletionRecord(id: stamped.id),
           !MusicSourceLifecyclePolicy.isExplicitRestore(stamped, after: deletion) {
            stamped.restoredAt = now
        }
        if !stamped.isDeleted {
            removeSourceDeletionRecord(id: stamped.id)
        }
        if let index = allSources.firstIndex(where: { $0.id == stamped.id }) {
            allSources[index] = stamped
        } else {
            allSources.append(stamped)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        if deviceSettings.seed(from: [stamped]) {
            persistDeviceSettings()
        }
    }

    /// User-facing edit. Bumps `modifiedAt` and triggers an iCloud sync push.
    func update(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        let previous = allSources.first { $0.id == sourceID }
        guard applyUserUpdate(sourceID, mutate: mutate) else { return }
        persist()
        notifyChanged([sourceID], previous: previous.map { [sourceID: $0] } ?? [:])
    }

    /// User-facing edit that is reported as successful only after the updated
    /// source has been atomically persisted. The in-memory row is restored if
    /// the write fails so callers can keep credentials and configuration in one
    /// transaction.
    @discardableResult
    func updateDurably(
        _ sourceID: String,
        mutate: (inout MusicSource) -> Void
    ) throws -> Bool {
        let previousSources = allSources
        guard applyUserUpdate(sourceID, mutate: mutate) else { return false }
        do {
            try persistThrowing()
        } catch {
            allSources = previousSources
            throw error
        }
        notifyChanged(
            [sourceID],
            previous: previousSources.first { $0.id == sourceID }.map { [sourceID: $0] } ?? [:]
        )
        return true
    }

    private func applyUserUpdate(
        _ sourceID: String,
        mutate: (inout MusicSource) -> Void
    ) -> Bool {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else {
            return false
        }
        mutate(&allSources[index])
        let selectedDirectories = Set(allSources[index].scannedDirectories)
        allSources[index].scannedDirectoryDisplayNames = allSources[index]
            .scannedDirectoryDisplayNames.filter { selectedDirectories.contains($0.key) }
        allSources[index].modifiedAt = Date()
        return true
    }

    /// Device-local update — used by the scanner for fields that are derived
    /// state (`lastScannedAt`, `songCount`, `deviceId`). Persists to disk but
    /// does not bump `modifiedAt` or notify the cloud sync.
    func updateLocal(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return }
        mutate(&allSources[index])
        persist()
    }

    /// Same as `updateLocal`, but for derived counters a scan republishes every
    /// flush. `allSources` is updated immediately — every reader still sees the
    /// new count in the same turn — while the JSON encode + atomic write are
    /// coalesced into one write per debounce window. The value is device-local
    /// derived state: a process exit inside the window costs at most the
    /// intermediate counter, which the next flush or the terminal commit
    /// rewrites exactly. Terminal commits, cancellation and leaving the
    /// foreground all force the write through.
    func updateLocalCoalesced(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return }
        // 改在副本上再比一次: 重扫一个没有变动的来源时每次 flush 都会把同一个
        // 计数写回来, 而 Observation 不看新旧值 —— 照写就会让音乐源页整张列表
        // (连同每张卡片的长按菜单和滑动操作)重建一遍, 跟滑动抢主线程。没有变化
        // 也就没有要落盘的东西, 一并省掉。
        var updated = allSources[index]
        mutate(&updated)
        guard updated != allSources[index] else { return }
        allSources[index] = updated
        guard !SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: isSceneBackgrounded,
            secondsSinceLastPersist: Date().timeIntervalSince(lastCoalescedPersistAt)
        ) else {
            persist()
            return
        }
        guard coalescedPersistTask == nil else { return }
        coalescedPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(SourcePersistCoalescingPolicy.debounceInterval)
            )
            guard !Task.isCancelled, let self else { return }
            // 不在这里清 token: 只有真正落盘成功的那次写入才有资格解除武装
            // (`persistThrowing`)。写失败时 token 留着, 后面的
            // `flushCoalescedPersist()` 与下一次合并更新才能重试。
            self.persist()
        }
    }

    /// Write any coalesced source edit right now. Called on the terminal scan
    /// commit, on cancellation, and whenever the scene leaves `.active` — after
    /// that point iOS may suspend the process at any moment.
    func flushCoalescedPersist() {
        guard coalescedPersistTask != nil else { return }
        guard SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: true,
            isBackgrounded: isSceneBackgrounded,
            secondsSinceLastPersist: Date().timeIntervalSince(lastCoalescedPersistAt)
        ) else { return }
        persist()
    }

    /// Once the scene has left the foreground the process can be suspended at
    /// any moment, and a scan task that is still unwinding its cancellation can
    /// publish one more counter after the scene-leave flushes have run. From
    /// that point every coalesced update writes straight through instead of
    /// arming a window nothing will close.
    func setSceneBackgrounded(_ isBackgrounded: Bool) {
        guard isSceneBackgrounded != isBackgrounded else { return }
        isSceneBackgrounded = isBackgrounded
        if isBackgrounded { flushCoalescedPersist() }
    }

    @discardableResult
    func updateLocalDurably(_ sourceID: String, mutate: (inout MusicSource) -> Void) throws -> Bool {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return false }
        let previous = allSources
        mutate(&allSources[index])
        do {
            try persistThrowing()
        } catch {
            allSources = previous
            throw error
        }
        return true
    }

    /// Merge provider-supplied directory labels into the source payload so the
    /// mapping survives a new device, reinstall, or source resurrection.
    func mergeDirectoryDisplayNames(_ names: [String: String], sourceID: String) {
        guard !names.isEmpty,
              let index = allSources.firstIndex(where: { $0.id == sourceID }),
              !allSources[index].isDeleted else { return }
        let selectedDirectories = Set(allSources[index].scannedDirectories)
        var changed = false
        for (path, rawName) in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard selectedDirectories.contains(path), !name.isEmpty,
                  allSources[index].scannedDirectoryDisplayNames[path] != name else { continue }
            allSources[index].scannedDirectoryDisplayNames[path] = name
            changed = true
        }
        guard changed else { return }
        allSources[index].modifiedAt = Date()
        persist()
        notifyChanged([sourceID])
    }

    /// Reconcile the per-source counter with the songs that are actually
    /// present in the local library. `songCount` is device-local derived
    /// state, so a sources snapshot can legitimately outlive (or arrive
    /// before) the matching library snapshot. Updating every row in one pass
    /// prevents stale historical counts from being shown as if they were the
    /// current visible library size.
    func reconcileLocalSongCounts(_ countsBySourceID: [String: Int]) {
        var changed = false
        for index in allSources.indices where !allSources[index].isDeleted {
            let actualCount = countsBySourceID[allSources[index].id] ?? 0
            guard allSources[index].songCount != actualCount else { continue }
            allSources[index].songCount = actualCount
            changed = true
        }
        if changed { persist() }
    }

    /// Reset scan-derived state for a batch of removed sources with one
    /// Observable mutation/persist instead of rewriting sources.json per row.
    func resetLocalScanState(for sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        var changed = false
        for index in allSources.indices where sourceIDs.contains(allSources[index].id) {
            if allSources[index].songCount != 0 || allSources[index].lastScannedAt != nil {
                allSources[index].songCount = 0
                allSources[index].lastScannedAt = nil
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Source delete: hide from UI, keep the row for recycle-bin recovery,
    /// and persist the tombstone independently so CloudKit cursor resets and
    /// snapshot replay cannot reinterpret a missing row as a restore. This is
    /// not used by the enable/disable toggle.
    func remove(id: String) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        permanentDeletionFailureIDs.remove(id)
        allSources[index].isDeleted = true
        let deletedAt = Date()
        allSources[index].deletedAt = deletedAt
        allSources[index].modifiedAt = deletedAt
        let tombstone = allSources[index]
        recordSourceDeletion(tombstone: tombstone)
        persist()
        // notifyChanged drives UI refresh; the dedicated signal lets the
        // durable cleanup journal track CloudKit tombstone acknowledgement,
        // snapshot propagation and credential removal independently.
        notifyChanged([id])
        NotificationCenter.default.post(
            name: .primuseSourceDidSoftDelete,
            object: nil,
            userInfo: ["id": id, "source": tombstone]
        )
    }

    /// Restore a soft-deleted source from the recycle bin.
    func restore(id: String) {
        guard !permanentDeletionInProgressIDs.contains(id),
              let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        permanentDeletionFailureIDs.remove(id)
        let restoredAt = Date()
        allSources[index].isDeleted = false
        allSources[index].deletedAt = nil
        allSources[index].restoredAt = restoredAt
        allSources[index].modifiedAt = restoredAt
        removeSourceDeletionRecord(id: id)
        persist()
        notifyChanged([id])
    }

    @discardableResult
    func restoreDurably(id: String) throws -> Bool {
        guard !permanentDeletionInProgressIDs.contains(id),
              var source = allSources.first(where: { $0.id == id }) else { return false }
        source.isDeleted = false
        source.deletedAt = nil
        source.restoredAt = Date()
        try addDurably(source)
        permanentDeletionFailureIDs.remove(id)
        return true
    }

    @discardableResult
    func permanentlyDelete(id: String) async -> PermanentDeleteResult {
        guard !permanentDeletionInProgressIDs.contains(id) else {
            return .alreadyInProgress
        }
        guard let index = allSources.firstIndex(where: { $0.id == id }) else {
            permanentDeletionFailureIDs.remove(id)
            return .sourceNotFound
        }
        let tombstone = allSources[index]
        guard tombstone.isDeleted else { return .sourceChanged }
        guard recordSourceDeletion(tombstone: tombstone) else {
            permanentDeletionFailureIDs.insert(id)
            plog("⛔ Source permanent delete deferred: deletion ledger persist failed id=\(id.prefix(8))…")
            return .deletionLedgerPersistFailed
        }

        permanentDeletionFailureIDs.remove(id)
        permanentDeletionInProgressIDs.insert(id)
        defer { permanentDeletionInProgressIDs.remove(id) }

        // Security.framework calls are synchronous IPC and can wait on
        // securityd / iCloud Keychain. Always enter the injected purger from a
        // detached task so neither manual purge nor startup pruning can block
        // the main actor. The default purger is additionally serialized by its
        // own actor to avoid concurrent mutations of the same credential store.
        let purge = credentialPurger
        let useDefaultPurger = isUsingDefaultCredentialPurger
        let remainingSnapshot = allSources
        let credentialsDeleted = await Task.detached(priority: .utility) {
            if useDefaultPurger {
                return await SourceCredentialPurgeExecutor.shared.purge(
                    tombstone,
                    remainingSources: remainingSnapshot
                )
            }
            return await purge(tombstone)
        }.value

        // The await above permits cloud reconciliation and other source updates.
        // Only commit the removal if this is still the exact tombstone for which
        // credential cleanup began. In-progress user restores are rejected by
        // restore(id:), while this check protects remote restores and replacement
        // records that reuse the same source ID.
        guard let currentIndex = allSources.firstIndex(where: { $0.id == id }) else {
            permanentDeletionFailureIDs.remove(id)
            return .sourceNotFound
        }
        let current = allSources[currentIndex]
        guard current.isDeleted,
              current.deletedAt == tombstone.deletedAt,
              current.modifiedAt == tombstone.modifiedAt else {
            permanentDeletionFailureIDs.remove(id)
            return .sourceChanged
        }

        guard credentialsDeleted else {
            permanentDeletionFailureIDs.insert(id)
            plog("⛔ Source permanent delete deferred: credential cleanup failed id=\(id.prefix(8))…")
            return .credentialCleanupFailed
        }

        permanentDeletionFailureIDs.remove(id)
        allSources.remove(at: currentIndex)
        persist()
        NotificationCenter.default.post(
            name: .primuseSourceDidDelete,
            object: nil,
            userInfo: ["id": id, "source": tombstone]
        )
        return .deleted
    }

    /// Batch entry point intentionally funnels every source through the
    /// single-item credential and deletion-ledger path. A failure therefore
    /// leaves that source visible in Recently Deleted and does not block the
    /// remaining independent sources.
    @discardableResult
    func permanentlyDelete(ids: Set<String>) async -> [String: PermanentDeleteResult] {
        await withTaskGroup(of: (String, PermanentDeleteResult).self) { group in
            for id in ids.sorted() {
                group.addTask { [self] in
                    (id, await permanentlyDelete(id: id))
                }
            }

            var results: [String: PermanentDeleteResult] = [:]
            for await (id, result) in group {
                results[id] = result
            }
            return results
        }
    }

    /// Sweep soft-deleted sources older than `threshold` and remove them for
    /// good. Called on launch with a 30-day threshold.
    @discardableResult
    func pruneSources(deletedBefore threshold: Date) async -> [String: PermanentDeleteResult] {
        let toPrune = allSources.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        return await permanentlyDelete(ids: Set(toPrune.map(\.id)))
    }

    /// Apply a remote delete event as a tombstone. The notification keeps
    /// local UI caches in sync; CloudKit suppresses echo saves while applying
    /// remote changes.
    func removeFromRemote(id: String) {
        markDeletedFromRemote(id: id)
    }

    /// Preserve a remote delete as a local tombstone instead of physically
    /// dropping the row. Snapshot sync can arrive later with an older
    /// `sources.json`; without the tombstone there is no evidence that the
    /// source was deleted, so the stale active row can come back.
    func markDeletedFromRemote(id: String, at deletedAt: Date = Date()) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else {
            recordSourceDeletion(id: id, deletedAt: deletedAt)
            return
        }
        if allSources[index].isDeleted {
            if (allSources[index].deletedAt ?? .distantPast) < deletedAt {
                allSources[index].deletedAt = deletedAt
                allSources[index].modifiedAt = max(allSources[index].modifiedAt, deletedAt)
                recordSourceDeletion(tombstone: allSources[index])
                persist()
                notifyChanged([id], origin: "remote")
            } else {
                recordSourceDeletion(tombstone: allSources[index])
            }
            return
        }
        allSources[index].isDeleted = true
        allSources[index].deletedAt = deletedAt
        allSources[index].modifiedAt = max(allSources[index].modifiedAt, deletedAt)
        let tombstone = allSources[index]
        recordSourceDeletion(tombstone: tombstone)
        persist()
        notifyChanged([id], origin: "remote")
        NotificationCenter.default.post(
            name: .primuseSourceDidSoftDelete,
            object: nil,
            userInfo: ["id": id, "source": tombstone, "origin": "remote"]
        )
    }

    /// Apply a source pulled from CloudKit. Preserves device-local fields
    /// (`lastScannedAt`, `songCount`, `deviceId`) on the existing record if any.
    ///
    /// Last-writer-wins on `modifiedAt`: if the local copy was edited
    /// MORE recently than the remote, we keep the local. Without this
    /// guard, a `DidFetchRecordZoneChanges` event that arrives moments
    /// after the user toggled a directory selection would overwrite the
    /// fresh local edit with the older server payload — observable in
    /// the UI as "checkbox self-deselects ~1 second after tapping".
    /// The push path already does LWW (see `resolveServerRecordChanged`
    /// on the conflict path); the fetch path was the missing half.
    func upsertFromRemote(_ remote: MusicSource) {
        guard MusicSourceCloudSyncPolicy.isEligible(remote) else { return }
        // 这台设备单独关了这个源的 iCloud 同步:远端的修改(连同删除)先存着不套用,
        // 重新打开时再按下面同一套规则合并。
        guard deviceSettings.syncsViaICloud(remote.id) else {
            if deviceSettings.park(remote) {
                persistDeviceSettings()
            }
            return
        }
        if remote.isDeleted {
            let incomingDeletion = MusicSourceDeletionRecord(tombstone: remote)
            if let existing = allSources.first(where: { $0.id == remote.id }),
               !existing.isDeleted,
               MusicSourceLifecyclePolicy.isExplicitRestore(existing, after: incomingDeletion) {
                return
            }

            recordSourceDeletion(tombstone: remote)
            guard let index = allSources.firstIndex(where: { $0.id == remote.id }) else {
                return
            }
            if allSources[index].isDeleted,
               MusicSourceLifecyclePolicy.winner(
                   local: allSources[index],
                   remote: remote
               ) == .local {
                return
            }
            let wasActive = !allSources[index].isDeleted
            var merged = MusicSourceDeviceSettings.applyingLocalEnablement(
                to: remote,
                local: allSources[index]
            )
            merged.lastScannedAt = allSources[index].lastScannedAt
            merged.songCount = allSources[index].songCount
            merged.deviceId = allSources[index].deviceId
            noteSyncedIsEnabled(remote)
            // 同一块墓碑再拉一遍(全量重拉、本机推上去又回来)不重写也不广播。
            if Self.isSameIgnoringSubsecondDates(merged, allSources[index]) { return }
            allSources[index] = merged
            persist()
            notifyChanged([remote.id], origin: "remote")
            if wasActive {
                NotificationCenter.default.post(
                    name: .primuseSourceDidSoftDelete,
                    object: nil,
                    userInfo: ["id": remote.id, "source": merged, "origin": "remote"]
                )
            }
            return
        }

        let restoresRecordedDeletion: Bool
        if let deletion = sourceDeletionRecord(id: remote.id) {
            guard MusicSourceLifecyclePolicy.isExplicitRestore(remote, after: deletion) else {
                return
            }
            restoresRecordedDeletion = true
        } else {
            restoresRecordedDeletion = false
        }

        var previousRow: MusicSource?
        if let existing = allSources.first(where: { $0.id == remote.id }) {
            if existing.isDeleted && !remote.isDeleted {
                let deletion = MusicSourceDeletionRecord(tombstone: existing)
                if !MusicSourceLifecyclePolicy.isExplicitRestore(remote, after: deletion) {
                    return
                }
            }
            if Self.sourceClock(existing) > Self.sourceClock(remote) {
                // Local has unsent edits that are newer — keep them.
                // CloudKit will push them on the next sendChanges.
                return
            }
            // 启用状态按设备:别的设备启用 / 停用(或者改了别的设置)都不改这台设备的选择。
            var merged = MusicSourceDeviceSettings.applyingLocalEnablement(to: remote, local: existing)
            merged.lastScannedAt = existing.lastScannedAt
            merged.songCount = existing.songCount
            // Synology's trusted-device token belongs to this physical
            // device. A remote source edit must not erase it or replace it
            // with another device's token, otherwise the next scan needlessly
            // falls back to password + TOTP.
            merged.deviceId = existing.deviceId
            // 旧版本 App 存回来的源不带 Google Drive 的访问方式;没带不等于整盘,留着本机的。
            merged.googleDriveAccessMode = GoogleDrivePickerPolicy.mergedStoredAccessMode(
                local: existing.googleDriveAccessMode,
                remote: remote.googleDriveAccessMode
            )
            noteSyncedIsEnabled(remote)
            // iCloud 会把本机刚推上去的那份原样拉回来。一个字段都没变的记录
            // 不落盘也不广播: 广播会被当成源被改过 —— 缓存审查、连接器重建、
            // 音乐源列表整页重建都会跟着跑一遍。
            if !restoresRecordedDeletion, Self.isSameIgnoringSubsecondDates(merged, existing) { return }
            if let index = allSources.firstIndex(where: { $0.id == merged.id }) {
                allSources[index] = merged
            }
            previousRow = existing
        } else {
            // Don't reanimate a record the server has marked deleted.
            // Stage 4's migration may push tombstones up; once the
            // 30-day prune sweeps them, they shouldn't reappear here.
            if remote.isDeleted { return }
            var sanitized = remote
            sanitized.deviceId = nil
            noteSyncedIsEnabled(remote)
            allSources.append(sanitized)
            RemoteSourceArrivalLedger.markArrived(sourceID: sanitized.id)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        if restoresRecordedDeletion {
            removeSourceDeletionRecord(id: remote.id)
        }
        persist()
        notifyChanged(
            [remote.id],
            origin: "remote",
            previous: previousRow.map { [remote.id: $0] } ?? [:]
        )
    }

    // MARK: - This device only

    /// 这个源是否经 iCloud 同步。没单独关过的都是 true。
    func syncsViaICloud(_ sourceID: String) -> Bool {
        deviceSettings.syncsViaICloud(sourceID)
    }

    /// 这个源现在能不能经 iCloud 同步:类型允许(不是本机文件、音乐 App 资料库),
    /// 而且这台设备没有单独关掉它。
    func isCloudSyncEligible(_ source: MusicSource) -> Bool {
        MusicSourceCloudSyncPolicy.isEligible(source) && deviceSettings.syncsViaICloud(source.id)
    }

    /// 往 iCloud 写的那份:启用状态换成同步配置里的值,这台设备的选择不出设备。
    func cloudPayload(for source: MusicSource) -> MusicSource {
        deviceSettings.outgoing(source)
    }

    /// 只在这台设备上启用 / 停用。不改 `modifiedAt`,不上传 iCloud,别的设备不受影响;
    /// 停用只是不显示这个源的歌,歌曲记录、喜欢、评分和歌单都留着。
    func setEnabledOnThisDevice(_ sourceID: String, _ enabled: Bool) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }),
              allSources[index].isEnabled != enabled else { return }
        let previous = allSources[index]
        allSources[index].isEnabled = enabled
        persist()
        notifyChanged([sourceID], origin: Self.deviceOnlyChangeOrigin, previous: [sourceID: previous])
    }

    /// 同上,落盘成功才算数;写不进去时内存里那行还原。
    @discardableResult
    func setEnabledOnThisDeviceDurably(_ sourceID: String, _ enabled: Bool) throws -> Bool {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return false }
        let previous = allSources[index]
        guard previous.isEnabled != enabled else { return true }
        allSources[index].isEnabled = enabled
        do {
            try persistThrowing()
        } catch {
            if let current = allSources.firstIndex(where: { $0.id == sourceID }) {
                allSources[current] = previous
            }
            throw error
        }
        notifyChanged([sourceID], origin: Self.deviceOnlyChangeOrigin, previous: [sourceID: previous])
        return true
    }

    /// 打开或关掉一个源的 iCloud 同步。
    ///
    /// 关掉:这台设备不再上传这个源的配置、扫描结果和在这里改的密码,也不再套用别的设备
    /// 对它的修改与删除;iCloud 里已有的那份和别的设备上的这个源都不动,本机数据也不删。
    /// 打开:关着期间收到的远端配置按原有规则(较新的为准,删除优先于未明确恢复的修改)
    /// 并进本机;本机这份更新(或从没传上去过)就再传上去。
    func setSyncsViaICloud(_ syncs: Bool, for sourceID: String) {
        let local = allSources.first { $0.id == sourceID }
        guard let plan = deviceSettings.setSyncsViaICloud(syncs, for: sourceID, localRow: local) else {
            return
        }
        persistDeviceSettings()
        plog("☁️ Source iCloud sync \(syncs ? "on" : "off") source=\(sourceID.prefix(8))… merge=\(plan.remoteToMerge != nil) upload=\(plan.uploadsLocal)")
        if syncs, let remote = plan.remoteToMerge {
            upsertFromRemote(remote)
        }
        #if os(iOS) || os(macOS)
        if syncs {
            // 关着时在这台设备上改的密码只存在本机。本机这份配置赢了就把它当成这个源的密码
            // 传出去,远端赢了就丢掉本机那份,改用 iCloud 钥匙串里的。
            let promote = plan.uploadsLocal
            Task.detached(priority: .utility) {
                KeychainService.resolveDeviceOnlySourceSecrets(sourceID: sourceID, promote: promote)
            }
        }
        #endif
        NotificationCenter.default.post(
            name: .primuseSourceCloudSyncPreferenceDidChange,
            object: nil,
            userInfo: [
                "id": sourceID,
                "syncsViaICloud": syncs,
                "uploadsLocal": syncs && plan.uploadsLocal,
            ]
        )
    }

    private func noteSyncedIsEnabled(_ remote: MusicSource) {
        if deviceSettings.noteSyncedIsEnabled(remote.isEnabled, for: remote.id) {
            persistDeviceSettings()
        }
    }

    private func loadDeviceSettings() {
        var settings = MusicSourceDeviceSettings.load(from: deviceSettingsURL) ?? MusicSourceDeviceSettings()
        // 升级到按设备启用后的第一次启动:每个源现在的启用状态就是同步来的那份,原样记成
        // 同步值,也就成了这台设备的选择,什么都不会翻转。之后第一次见到的源同理。
        let seeded = settings.seed(from: allSources)
        deviceSettings = settings
        if seeded {
            persistDeviceSettings()
        } else {
            publishKeychainOptOuts()
        }
    }

    private func publishKeychainOptOuts() {
        guard publishesKeychainOptOuts else { return }
        SourceCloudSyncOptOutRegistry.update(optedOutSourceIDs: deviceSettings.optedOutSourceIDs)
    }

    private func persistDeviceSettings() {
        publishKeychainOptOuts()
        do {
            try deviceSettings.encoded().write(to: deviceSettingsURL, options: .atomic)
        } catch {
            plog("⛔ Source device settings persist failed — \(error.localizedDescription)")
        }
    }

    /// `origin` tells observers whether the change was produced locally or is
    /// the result of applying a record that CloudKit just handed us. The sync
    /// enqueue paths use it to avoid echoing a fetched record straight back as
    /// a save; UI observers ignore it and refresh either way.
    /// `previous` 是改之前的那几行：ScanService 拿它判断这次只改了线路、名称还是
    /// 真动了内容，只改线路时保留目录层级与同步索引。
    private func notifyChanged(
        _ ids: [String],
        origin: String = "local",
        previous: [String: MusicSource] = [:]
    ) {
        var scopeFingerprints: [String: String] = [:]
        var credentialScopeFingerprints: [String: String] = [:]
        // 活着的那几行本身也随通知带出去: ScanService 要拿它们判断扫描作用域
        // 到底变没变, 而不是一见通知就把正在跑的扫描取消。
        var changedSources: [String: MusicSource] = [:]
        for sourceID in ids {
            guard let source = allSources.first(where: {
                $0.id == sourceID && !$0.isDeleted
            }) else { continue }
            changedSources[sourceID] = source
            scopeFingerprints[sourceID] =
                MusicSourceSecurityRevision.scopedFingerprint(for: source)
            credentialScopeFingerprints[sourceID] =
                MusicSourceSecurityRevision.credentialScopedFingerprint(for: source)
        }
        NotificationCenter.default.post(
            name: .primuseSourcesDidChange,
            object: nil,
            userInfo: [
                "ids": ids,
                "sources": changedSources,
                "scopeFingerprints": scopeFingerprints,
                "credentialScopeFingerprints": credentialScopeFingerprints,
                "previousSources": previous,
                "origin": origin,
            ]
        )
    }

    private static func sourceClock(_ source: MusicSource) -> Date {
        MusicSourceLifecyclePolicy.lifecycleClock(source)
    }

    /// 本机落盘用 ISO-8601 整秒, CloudKit 载荷带小数秒: 重启之后同一条记录的
    /// 时间戳就差那么一点。比较「是不是同一份」时把一秒以内的差别抹掉。
    private static func isSameIgnoringSubsecondDates(_ lhs: MusicSource, _ rhs: MusicSource) -> Bool {
        func snapped(_ date: Date?, to reference: Date?) -> Date? {
            guard let date, let reference, abs(date.timeIntervalSince(reference)) < 1 else { return date }
            return reference
        }
        var normalized = lhs
        normalized.modifiedAt = snapped(lhs.modifiedAt, to: rhs.modifiedAt) ?? lhs.modifiedAt
        normalized.deletedAt = snapped(lhs.deletedAt, to: rhs.deletedAt)
        normalized.restoredAt = snapped(lhs.restoredAt, to: rhs.restoredAt)
        return normalized == rhs
    }

    @discardableResult
    private func recordSourceDeletion(tombstone: MusicSource) -> Bool {
        recordSourceDeletion(MusicSourceDeletionRecord(tombstone: tombstone))
    }

    @discardableResult
    private func recordSourceDeletion(id: String, deletedAt: Date) -> Bool {
        recordSourceDeletion(MusicSourceDeletionRecord(id: id, deletedAt: deletedAt))
    }

    @discardableResult
    private func recordSourceDeletion(_ incoming: MusicSourceDeletionRecord) -> Bool {
        if let index = sourceDeletionRecords.firstIndex(where: { $0.id == incoming.id }) {
            sourceDeletionRecords[index] = MusicSourceLifecyclePolicy.coalescing(
                current: sourceDeletionRecords[index],
                incoming: incoming
            )
        } else {
            sourceDeletionRecords.append(incoming)
            sourceDeletionRecords.sort { $0.id < $1.id }
        }
        return persistSourceDeletions()
    }

    private func removeSourceDeletionRecord(id: String) {
        guard sourceDeletionRecords.contains(where: { $0.id == id }) else { return }
        sourceDeletionRecords.removeAll { $0.id == id }
        persistSourceDeletions()
    }

    private func loadSourceDeletions() {
        guard let data = try? Data(contentsOf: sourceDeletionsURL) else {
            sourceDeletionRecords = []
            return
        }
        do {
            let decoded = try decoder.decode([MusicSourceDeletionRecord].self, from: data)
            var merged: [String: MusicSourceDeletionRecord] = [:]
            for record in decoded {
                merged[record.id] = MusicSourceLifecyclePolicy.coalescing(
                    current: merged[record.id],
                    incoming: record
                )
            }
            sourceDeletionRecords = merged.values.sorted { $0.id < $1.id }
        } catch {
            backupCorruptStore(at: sourceDeletionsURL, data: data, error: error)
            sourceDeletionRecords = []
        }
    }

    private func migrateSourceTombstonesIntoDeletionLedger() {
        var changed = false
        for source in allSources where source.isDeleted {
            let incoming = MusicSourceDeletionRecord(tombstone: source)
            if let index = sourceDeletionRecords.firstIndex(where: { $0.id == source.id }) {
                let merged = MusicSourceLifecyclePolicy.coalescing(
                    current: sourceDeletionRecords[index],
                    incoming: incoming
                )
                if merged != sourceDeletionRecords[index] {
                    sourceDeletionRecords[index] = merged
                    changed = true
                }
            } else {
                sourceDeletionRecords.append(incoming)
                changed = true
            }
        }
        guard changed else { return }
        sourceDeletionRecords.sort { $0.id < $1.id }
        persistSourceDeletions()
    }

    @discardableResult
    private func reconcileSourcesWithDeletionLedger() -> [String] {
        var changedSourceIDs: [String] = []
        var restoredIDs = Set<String>()
        var refreshedDeletions: [MusicSourceDeletionRecord] = []

        for index in allSources.indices {
            let source = allSources[index]
            guard !source.isDeleted,
                  let deletion = sourceDeletionRecord(id: source.id) else { continue }
            if MusicSourceLifecyclePolicy.isExplicitRestore(source, after: deletion) {
                restoredIDs.insert(source.id)
                continue
            }

            var tombstone = deletion.tombstone ?? source
            tombstone.isDeleted = true
            tombstone.deletedAt = deletion.deletedAt
            tombstone.modifiedAt = max(tombstone.modifiedAt, deletion.deletedAt)
            tombstone.lastScannedAt = source.lastScannedAt
            tombstone.songCount = source.songCount
            tombstone.deviceId = source.deviceId
            allSources[index] = tombstone
            refreshedDeletions.append(MusicSourceDeletionRecord(tombstone: tombstone))
            changedSourceIDs.append(source.id)
        }

        if !restoredIDs.isEmpty {
            sourceDeletionRecords.removeAll { restoredIDs.contains($0.id) }
        }
        for incoming in refreshedDeletions {
            if let index = sourceDeletionRecords.firstIndex(where: { $0.id == incoming.id }) {
                sourceDeletionRecords[index] = MusicSourceLifecyclePolicy.coalescing(
                    current: sourceDeletionRecords[index],
                    incoming: incoming
                )
            }
        }
        if !restoredIDs.isEmpty || !refreshedDeletions.isEmpty {
            sourceDeletionRecords.sort { $0.id < $1.id }
            persistSourceDeletions()
        }
        if !changedSourceIDs.isEmpty {
            persist()
        }
        return changedSourceIDs
    }

    /// Removes rows that older CloudKit builds copied from another device.
    /// This is intentionally a silent local migration: creating a tombstone or
    /// posting a sync notification could delete the real source on its owner.
    private func pruneForeignDeviceLocalSources() {
        #if os(iOS)
        var ownedSourceIDs = LocalBookmarkStore.storedSourceIDs
        if let copiedSourceID = LocalImportService.existingSourceID {
            ownedSourceIDs.insert(copiedSourceID)
        }
        let foreignSourceIDs = MusicSourceCloudSyncPolicy.foreignDeviceLocalSourceIDs(
            in: allSources,
            ownedSourceIDs: ownedSourceIDs
        )
        let foreignDeletionIDs: Set<String> = Set(sourceDeletionRecords.lazy.compactMap { record -> String? in
            guard let tombstone = record.tombstone,
                  MusicSourceCloudSyncPolicy.isDeviceLocal(tombstone),
                  !ownedSourceIDs.contains(record.id) else { return nil }
            return record.id
        })
        let removedIDs = foreignSourceIDs.union(foreignDeletionIDs)
        guard !removedIDs.isEmpty else { return }

        allSources.removeAll { foreignSourceIDs.contains($0.id) }
        sourceDeletionRecords.removeAll { foreignDeletionIDs.contains($0.id) }
        persist()
        if !foreignDeletionIDs.isEmpty {
            _ = persistSourceDeletions()
        }
        plog("SourcesStore: pruned \(removedIDs.count) foreign device-local source(s)")
        #endif
    }

    @discardableResult
    private func noteCreatedOnThisDevice(_ sourceID: String) {
        sourceIDsCreatedThisRun.insert(sourceID)
        sourceIDsCreatedOnThisDevice.insert(sourceID)
        persistSourcesCreatedOnThisDevice()
    }

    /// 扫完过一次、已删掉的不再记。
    private func loadSourcesCreatedOnThisDevice() {
        guard let data = try? Data(contentsOf: createdOnThisDeviceURL),
              let stored = try? decoder.decode([String].self, from: data) else {
            sourceIDsCreatedOnThisDevice = []
            return
        }
        let kept = Set(stored).filter { id in
            guard let source = self.source(id: id) else { return false }
            return !source.isDeleted && source.lastScannedAt == nil
        }
        sourceIDsCreatedOnThisDevice = kept
        if kept.count != stored.count { persistSourcesCreatedOnThisDevice() }
    }

    private func persistSourcesCreatedOnThisDevice() {
        if sourceIDsCreatedOnThisDevice.isEmpty {
            try? FileManager.default.removeItem(at: createdOnThisDeviceURL)
            return
        }
        guard let data = try? encoder.encode(sourceIDsCreatedOnThisDevice.sorted()) else { return }
        try? data.write(to: createdOnThisDeviceURL, options: .atomic)
    }

    private func persistSourceDeletions() -> Bool {
        do {
            let data = try encoder.encode(sourceDeletionRecords)
            try data.write(to: sourceDeletionsURL, options: .atomic)
            return true
        } catch {
            plog("⛔ Source deletion ledger persist failed — \(error.localizedDescription)")
            return false
        }
    }

    private func load() {
        // File-not-present is the normal first-launch case — start empty and
        // let the first add/upsert write a fresh sources.json.
        guard let data = try? Data(contentsOf: storeURL) else {
            hasCompleteSnapshot = !FileManager.default.fileExists(atPath: storeURL.path)
            allSources = []
            return
        }
        do {
            let decoded = try decoder.decode([MusicSource].self, from: data)
            allSources = decoded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            hasCompleteSnapshot = true
        } catch {
            // The file exists but is undecodable as a whole (corruption, an
            // incompatible future schema after a downgrade, a single malformed
            // row, …). Don't blindly empty the list — the very next persist()
            // would atomically overwrite the user's entire source config and
            // make the loss permanent. Try a per-element tolerant decode first
            // so one bad row only drops that row, and back up the original
            // bytes before anything else can clobber them.
            backupCorruptStore(at: storeURL, data: data, error: error)
            hasCompleteSnapshot = false
            allSources = recoverPartial(MusicSource.self, from: data)
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    private func persist() {
        do {
            try persistThrowing()
        } catch {
            plog("⛔ Sources persist failed — \(error.localizedDescription)")
        }
    }

    private func persistThrowing() throws {
        #if os(tvOS)
        // A tolerant partial read is useful for display, but is not a safe
        // baseline for replacing the only source configuration on disk.
        guard hasCompleteSnapshot else { throw CocoaError(.fileReadCorruptFile) }
        #endif
        let data = try encoder.encode(allSources)
        try sourceDataWriter(data, storeURL)
        #if os(iOS) || os(macOS)
        if publishesKeychainOptOuts {
            FnConnectGatewayCredentialStore.updateSources(allSources)
        }
        #endif
        // Whatever a coalesced counter was still waiting to write is part of
        // `allSources` already, so this write subsumes it. Only a write that
        // actually landed disarms it — a failed one must stay armed to retry.
        coalescedPersistTask?.cancel()
        coalescedPersistTask = nil
        lastCoalescedPersistAt = Date()
    }

    // MARK: - CloudAccount CRUD (stage 2: internal, not exposed to UI)

    /// Lookup by deterministic id. Same as `allAccounts.first(where:)`
    /// but spelled out for readability at call sites.
    func account(id: String) -> CloudAccount? {
        allAccounts.first(where: { $0.id == id })
    }

    /// Lookup by upstream identity. Used by the OAuth flow (stage 4) to
    /// ask "do I already have this Baidu account?" before minting a new
    /// mount. Includes soft-deleted rows so a user re-signing-in to a
    /// recently-deleted account can resurrect rather than duplicate.
    func account(provider: MusicSourceType, accountUID: String) -> CloudAccount? {
        let id = CloudAccount.deriveID(provider: provider, accountUID: accountUID)
        return allAccounts.first(where: { $0.id == id })
    }

    /// Insert or update. Bumps `modifiedAt` so the LWW resolver picks
    /// this edit on the next CloudKit sync. No-op if the deterministic
    /// id collides — by construction that means same upstream account.
    func upsertAccount(_ account: CloudAccount) {
        var stamped = account
        stamped.modifiedAt = Date()
        if let index = allAccounts.firstIndex(where: { $0.id == stamped.id }) {
            allAccounts[index] = stamped
        } else {
            allAccounts.append(stamped)
        }
        persistAccounts()
        NotificationCenter.default.post(
            name: .primuseCloudAccountsDidChange,
            object: nil,
            userInfo: ["ids": [stamped.id]]
        )
    }

    /// Soft-delete: hide the account from `accounts`, but the row stays
    /// on disk for recycle-bin recovery. CloudKit gets a real
    /// `deleteRecord` (via the soft-delete notification) so the upstream
    /// record clears — same pattern as `remove(id:)` for sources.
    func removeAccount(id: String) {
        guard let index = allAccounts.firstIndex(where: { $0.id == id }) else { return }
        allAccounts[index].isDeleted = true
        allAccounts[index].deletedAt = Date()
        allAccounts[index].modifiedAt = Date()
        persistAccounts()
        NotificationCenter.default.post(
            name: .primuseCloudAccountsDidChange,
            object: nil,
            userInfo: ["ids": [id]]
        )
        NotificationCenter.default.post(
            name: .primuseCloudAccountDidSoftDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Permanently remove. Called by the launch-time prune (after the
    /// 30-day soft-delete grace) and by the explicit "delete forever"
    /// action in the recycle bin.
    func permanentlyDeleteAccount(id: String) {
        allAccounts.removeAll { $0.id == id }
        persistAccounts()
        NotificationCenter.default.post(
            name: .primuseCloudAccountDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Apply an account pulled from CloudKit. Mirrors `upsertFromRemote`
    /// for sources — same LWW + soft-delete-respect rules.
    func upsertAccountFromRemote(_ remote: CloudAccount) {
        if let existing = allAccounts.first(where: { $0.id == remote.id }) {
            if existing.isDeleted, existing.modifiedAt.timeIntervalSinceReferenceDate >= remote.modifiedAt.timeIntervalSinceReferenceDate { return }
            if existing.modifiedAt > remote.modifiedAt { return }
            if let index = allAccounts.firstIndex(where: { $0.id == remote.id }) {
                allAccounts[index] = remote
            }
        } else {
            if remote.isDeleted { return }
            allAccounts.append(remote)
        }
        persistAccounts()
    }

    /// Apply a remote permanent-delete event. Silent so it doesn't echo
    /// back to CloudKit.
    func removeAccountFromRemote(id: String) {
        allAccounts.removeAll { $0.id == id }
        persistAccounts()
    }

    private func loadAccounts() {
        guard let data = try? Data(contentsOf: accountsURL) else {
            allAccounts = []
            return
        }
        do {
            allAccounts = try decoder.decode([CloudAccount].self, from: data)
        } catch {
            // Same hazard as load(): a decode failure here followed by any
            // upsert/remove would persistAccounts() over the original file.
            backupCorruptStore(at: accountsURL, data: data, error: error)
            allAccounts = recoverPartial(CloudAccount.self, from: data)
        }
    }

    private func persistAccounts() {
        guard let data = try? encoder.encode(allAccounts) else { return }
        try? data.write(to: accountsURL, options: .atomic)
    }

    // MARK: - Corruption recovery

    /// Snapshot the undecodable bytes next to the store (`*.corrupt`) before
    /// the next persist() can overwrite them, so the user's config is
    /// recoverable rather than silently lost. Logs the underlying error.
    private func backupCorruptStore(at url: URL, data: Data, error: Error) {
        let backupURL = url.appendingPathExtension("corrupt")
        try? data.write(to: backupURL, options: .atomic)
        print("SourcesStore: failed to decode \(url.lastPathComponent) (\(error)); backed up to \(backupURL.lastPathComponent)")
    }

    /// Best-effort per-element decode: parse the JSON array and decode each
    /// element independently so a single malformed row drops only that row
    /// instead of nuking the whole list. Returns whatever decoded cleanly
    /// (possibly empty if the bytes aren't even a JSON array).
    private func recoverPartial<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        guard let wrapped = try? decoder.decode([FailableDecodable<T>].self, from: data) else {
            return []
        }
        return wrapped.compactMap(\.value)
    }
}

/// Decodes `T` but never throws: a per-element decode failure leaves `value`
/// nil instead of aborting the surrounding array decode.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}

/// 记下哪些源是经 iCloud 从别的设备到达本机的, 以及到达时刻。源记录走 CloudKit,
/// 密码走 iCloud 钥匙串, 两条路不同步: 源先到、密码后到的那几分钟里, 本机钥匙串
/// 查不到密码。`KeychainService.connectorCredential` 据此把「还没到」和「本来就没
/// 有密码」分开, 前者暂不登录, 而不是拿空密码去试一次(NAS 会记一次失败, 还可能
/// 触发锁定)。到达超过一定时间就不再当作在途, 免得对方本来就没存密码的源永远
/// 连不上。
enum RemoteSourceArrivalLedger {
    private static let defaultsKey = "primuse.sources.remoteArrivals"
    /// 钥匙串同步通常几分钟内到齐; 超过这个时间还没到, 就按「没有密码」处理。
    static let pendingWindow: TimeInterval = 15 * 60

    static func markArrived(sourceID: String, now: Date = Date()) {
        var arrivals = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Date]) ?? [:]
        arrivals = arrivals.filter { now.timeIntervalSince($0.value) < pendingWindow * 4 }
        arrivals[sourceID] = now
        UserDefaults.standard.set(arrivals, forKey: defaultsKey)
    }

    static func forget(sourceID: String) {
        guard var arrivals = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Date],
              arrivals.removeValue(forKey: sourceID) != nil else { return }
        UserDefaults.standard.set(arrivals, forKey: defaultsKey)
    }

    /// 这个源刚从别的设备同步过来、它的密码可能还在路上。
    static func isAwaitingSyncedCredential(sourceID: String, now: Date = Date()) -> Bool {
        guard let arrivals = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Date],
              let arrivedAt = arrivals[sourceID] else { return false }
        return now.timeIntervalSince(arrivedAt) < pendingWindow
    }
}
