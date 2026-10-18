import CloudKit
import Foundation
import PrimuseKit

/// 同一个 iCloud 账号下别的 iPhone / iPad / Mac 已经读好标签的歌曲行。
///
/// 每台设备上传的曲库快照(`library-snapshot.<设备 id>`)原来只给 Apple TV 装整库用。
/// 这里把别的设备的那份拉下来,只留文件型网络源里真读过文件的行,按音乐源分文件存在
/// 本机。扫描遇到新文件、补读遇到还没读的行时先查这里,文件没变就直接用,不用再读一遍。
/// 本机扫描仍是唯一依据:有哪些歌、删了哪些歌都由本机列出来的文件决定。
actor PeerScanSeedStore {
    static let shared = PeerScanSeedStore()

    struct RefreshResult: Sendable {
        /// 这次有新内容的音乐源。
        var updatedSourceIDs: Set<String>
        var peerDeviceCount: Int
    }

    private struct DeviceState: Codable, Sendable {
        var modifiedAt: Date
        var deviceName: String
        var sourceIDs: [String]
        /// 存盘时扔掉的源(`PeerScanSeedScope.excluded`)。旧版本存的没有这一项。
        var excludedSourceIDs: [String]?
    }

    private struct State: Codable, Sendable {
        var devices: [String: DeviceState] = [:]
        /// 旧版本只留本机当时认的文件型源,这是那份名单;没有 `excludedSourceIDs` 的设备
        /// 靠它判断本机后来有的源在不在里面。新版本不再改它。
        var eligibleSourceIDs: [String] = []
        /// 上次看清单时账号里别的上传过曲库的设备数(不论有没有用得上的行)。
        var peerDeviceCount: Int = 0
    }

    /// 别的设备快照里这里用得到的两样。其余字段(歌单、封面图片等)解码时跳过。
    private struct PeerSnapshotPayload: Decodable {
        var songs: [Song]?
        var coverContentSongIDs: [String: [String]]?
    }

    nonisolated let directory: URL
    private var lastAttemptAt: Date?
    private var inFlight: Task<RefreshResult?, Never>?
    private var inFlightToken = UUID()
    private var inFlightSourceIDs: Set<String> = []

    /// 没有新情况时多久才去 iCloud 看一次清单。
    private static let minimumRefreshInterval: TimeInterval = 10 * 60
    private static let stateFileName = "state.json"

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("peer-scan-seeds", isDirectory: true)
    }

    /// 音乐源同步开着才拿别的设备的结果:关掉时两边的源 id 本来就对不上。
    nonisolated static var isEnabled: Bool {
        CloudSyncChannel.isEnabled(.sources)
    }

    /// 能借用别的设备结果的源:跨设备同步的、靠读文件拿标签的网络源。服务端曲库源的
    /// 标签来自服务器目录,本机源的路径换台设备就打不开。
    nonisolated static func isEligible(_ source: MusicSource) -> Bool {
        MusicSourceCloudSyncPolicy.isEligible(source)
            && !source.type.isServerLibrary
            && source.type.supportsEmbeddedMetadataBackfill
    }

    // MARK: - Refresh

    /// 看一眼 iCloud 上别的设备的清单,有更新的设备就把它的快照拉下来重新整理。
    /// `force` 跳过十分钟的节流(本机第一次扫一个源时用)。同时只跑一次:正在跑的
    /// 那次覆盖了这次要的源就等它的结果,没覆盖(刚加了新源)就等它跑完再跑一次
    /// (快照没变时只多读一次清单)。
    func refresh(scope: PeerScanSeedScope, force: Bool = false) async -> RefreshResult? {
        guard Self.isEnabled, !scope.wanted.isEmpty else { return nil }
        var waitedForNarrowerRefresh = false
        while let running = inFlight {
            if scope.wanted.isSubset(of: inFlightSourceIDs) {
                return await running.value
            }
            _ = await running.value
            waitedForNarrowerRefresh = true
        }
        if !force, !waitedForNarrowerRefresh, let lastAttemptAt,
           Date().timeIntervalSince(lastAttemptAt) < Self.minimumRefreshInterval {
            return nil
        }
        lastAttemptAt = Date()
        let token = UUID()
        let task = Task { () -> RefreshResult? in
            let result = await self.performRefresh(scope: scope)
            // 在任务里清掉,等它的调用方醒来时看到的已经是空的。
            if self.inFlightToken == token {
                self.inFlight = nil
                self.inFlightSourceIDs = []
            }
            return result
        }
        inFlight = task
        inFlightToken = token
        inFlightSourceIDs = scope.wanted
        return await task.value
    }

    private func performRefresh(scope: PeerScanSeedScope) async -> RefreshResult? {
        guard let database = CloudKitRuntime.makeContainer()?.privateCloudDatabase else { return nil }
        let localDeviceID = LibrarySnapshotSync.shared.localDeviceID
        let manifestRecordID = CKRecord.ID(recordName: "library-snapshot")
        let manifest: [LibrarySnapshotDeviceEntry]
        let record: CKRecord
        do {
            let results = try await database.records(
                for: [manifestRecordID],
                desiredKeys: [LibrarySnapshotDeviceManifestPolicy.manifestFieldKey]
            )
            switch results[manifestRecordID] {
            case .success(let fetched)?:
                record = fetched
            case .failure(let error)?:
                if (error as? CKError)?.code == .unknownItem {
                    // 账号里没有曲库快照(新账号、换了账号):本机存着的别的设备的结果作废。
                    for deviceID in loadState().devices.keys { removeDevice(deviceID) }
                    saveState(State())
                    plog("🧩 peer seeds: no library snapshot in iCloud yet")
                    return RefreshResult(updatedSourceIDs: [], peerDeviceCount: 0)
                }
                plog("🧩 peer seeds: manifest fetch failed — \(error.localizedDescription)")
                return nil
            case nil:
                return nil
            }
            manifest = LibrarySnapshotDeviceManifestPolicy.decode(
                record[LibrarySnapshotDeviceManifestPolicy.manifestFieldKey] as? Data
            ).filter { $0.deviceID != localDeviceID }
        } catch {
            plog("🧩 peer seeds: manifest fetch failed — \(error.localizedDescription)")
            return nil
        }

        var state = loadState()
        var updatedSourceIDs = Set<String>()

        // 清单里没了的设备(换了账号、删了 App、曲库清空)连同它的结果一起删掉。
        let peerIDs = Set(manifest.map(\.deviceID))
        for deviceID in state.devices.keys where !peerIDs.contains(deviceID) {
            removeDevice(deviceID)
            state.devices[deviceID] = nil
        }
        // 本机后来删掉的源,存着的结果不必等那台设备传新快照才清。
        for (deviceID, device) in state.devices {
            let dropped = device.sourceIDs.filter { scope.excluded.contains($0) }
            guard !dropped.isEmpty else { continue }
            let deviceDirectory = Self.deviceDirectory(deviceID, in: directory)
            for sourceID in dropped {
                try? FileManager.default.removeItem(at: Self.sourceFileURL(sourceID, in: deviceDirectory))
            }
            state.devices[deviceID]?.sourceIDs.removeAll { scope.excluded.contains($0) }
        }

        let legacyKeptSourceIDs = Set(state.eligibleSourceIDs)
        let stale = manifest.filter { entry in
            let known = state.devices[entry.deviceID]
            return PeerScanSeedPolicy.needsReinstall(
                storedModifiedAt: known?.modifiedAt,
                uploadedModifiedAt: entry.modifiedAt,
                excludedAtInstall: known?.excludedSourceIDs.map(Set.init),
                legacyKeptSourceIDs: legacyKeptSourceIDs,
                wanted: scope.wanted
            )
        }
        for entry in LibrarySnapshotDeviceManifestPolicy.mergeOrder(stale) {
            guard !Task.isCancelled else { break }
            let recordID = CKRecord.ID(
                recordName: LibrarySnapshotDeviceManifestPolicy.recordName(forDevice: entry.deviceID)
            )
            let data: Data
            do {
                let results = try await database.records(
                    for: [recordID],
                    desiredKeys: ["libraryGz", "library"]
                )
                guard case .success(let record)? = results[recordID],
                      let raw = try LibrarySnapshotSync.libraryData(from: record) else {
                    plog("🧩 peer seeds: device \(entry.deviceID.prefix(8))… has no readable library")
                    continue
                }
                data = raw
            } catch {
                plog("🧩 peer seeds: device \(entry.deviceID.prefix(8))… fetch failed — \(error.localizedDescription)")
                continue
            }
            let written = installDevice(
                entry,
                libraryData: data,
                scope: scope,
                previous: state.devices[entry.deviceID]
            )
            guard let written else { continue }
            updatedSourceIDs.formUnion(written.sourceIDs)
            state.devices[entry.deviceID] = written
        }
        state.peerDeviceCount = manifest.count
        saveState(state)
        plog("🧩 peer seeds: refreshed devices=\(manifest.count) updated=\(stale.count) sources=\(updatedSourceIDs.count)")
        return RefreshResult(updatedSourceIDs: updatedSourceIDs, peerDeviceCount: manifest.count)
    }

    /// 解出一台设备的歌曲行,按源写进本机。快照最大 64MB,解码只建歌曲和封面表两样。
    private func installDevice(
        _ entry: LibrarySnapshotDeviceEntry,
        libraryData: Data,
        scope: PeerScanSeedScope,
        previous: DeviceState?
    ) -> DeviceState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PeerSnapshotPayload.self, from: libraryData) else {
            plog("🧩 peer seeds: device \(entry.deviceID.prefix(8))… snapshot does not decode")
            return nil
        }
        let coverKeys = PeerScanSeedPolicy.coverContentKeys(bySongIDFrom: payload.coverContentSongIDs)
        var bySource: [String: [PeerScanSeed]] = [:]
        var usable = 0
        for song in payload.songs ?? [] where !scope.excluded.contains(song.sourceID) {
            guard PeerScanSeedPolicy.isUsableSeed(song) else { continue }
            bySource[song.sourceID, default: []].append(
                PeerScanSeed(song: song, coverContentKey: coverKeys[song.id])
            )
            usable += 1
        }

        let deviceDirectory = Self.deviceDirectory(entry.deviceID, in: directory)
        try? FileManager.default.createDirectory(at: deviceDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var written: [String] = []
        for (sourceID, seeds) in bySource {
            let url = Self.sourceFileURL(sourceID, in: deviceDirectory)
            guard let data = try? encoder.encode(seeds),
                  (try? data.write(to: url, options: .atomic)) != nil else { continue }
            written.append(sourceID)
        }
        for sourceID in previous?.sourceIDs ?? [] where bySource[sourceID] == nil {
            try? FileManager.default.removeItem(at: Self.sourceFileURL(sourceID, in: deviceDirectory))
        }
        plog("🧩 peer seeds: device \(entry.deviceName) rows=\(payload.songs?.count ?? 0) usable=\(usable) sources=\(written.count) coverKeys=\(coverKeys.count)")
        return DeviceState(
            modifiedAt: entry.modifiedAt,
            deviceName: entry.deviceName,
            sourceIDs: written.sorted(),
            excludedSourceIDs: scope.excluded.sorted()
        )
    }

    private func removeDevice(_ deviceID: String) {
        try? FileManager.default.removeItem(at: Self.deviceDirectory(deviceID, in: directory))
    }

    // MARK: - Lookup

    /// 一个源的查询对象。真正用到第一行时才从磁盘读,没有新文件的重扫不花这份开销。
    nonisolated func lookup(forSourceID sourceID: String) -> PeerScanSeedLookup? {
        guard Self.isEnabled else { return nil }
        let directory = directory
        guard Self.hasSeedFiles(forSourceID: sourceID, in: directory) else { return nil }
        return PeerScanSeedLookup {
            Self.loadSeeds(forSourceID: sourceID, in: directory)
        }
    }

    /// 账号里有没有别的 iPhone / iPad / Mac 在上传曲库。没有的话本机读完标签也不必
    /// 赶着上传。
    nonisolated var hasKnownPeerDevices: Bool {
        Self.loadState(in: directory).peerDeviceCount > 0
    }

    nonisolated static func hasSeedFiles(forSourceID sourceID: String, in directory: URL) -> Bool {
        let state = loadState(in: directory)
        return state.devices.contains { deviceID, device in
            device.sourceIDs.contains(sourceID)
                && FileManager.default.fileExists(
                    atPath: sourceFileURL(sourceID, in: deviceDirectory(deviceID, in: directory)).path
                )
        }
    }

    /// 几台设备的结果并成一份:同一首歌取读得最全的,一样全取较新那台。
    nonisolated static func loadSeeds(forSourceID sourceID: String, in directory: URL) -> [String: PeerScanSeed] {
        let state = loadState(in: directory)
        let ordered = state.devices
            .filter { $0.value.sourceIDs.contains(sourceID) }
            .sorted {
                if $0.value.modifiedAt != $1.value.modifiedAt { return $0.value.modifiedAt > $1.value.modifiedAt }
                return $0.key < $1.key
            }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let perDevice: [[PeerScanSeed]] = ordered.compactMap { deviceID, _ in
            let url = sourceFileURL(sourceID, in: deviceDirectory(deviceID, in: directory))
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode([PeerScanSeed].self, from: data)
        }
        return PeerScanSeedPolicy.merged(perDevice)
    }

    // MARK: - Files

    private func loadState() -> State { Self.loadState(in: directory) }

    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.stateFileName), options: .atomic)
    }

    private nonisolated static func loadState(in directory: URL) -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(stateFileName)),
              let state = try? decoder.decode(State.self, from: data) else { return State() }
        return state
    }

    /// 设备 id 和源 id 都不直接拼进路径。
    private nonisolated static func deviceDirectory(_ deviceID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(CacheFileNamePolicy.make(path: "device:" + deviceID), isDirectory: true)
    }

    private nonisolated static func sourceFileURL(_ sourceID: String, in deviceDirectory: URL) -> URL {
        deviceDirectory.appendingPathComponent(
            CacheFileNamePolicy.make(path: "source:" + sourceID, preferredExtension: "json")
        )
    }
}

/// 一个源在一次扫描或一次补齐里用的查询对象。扫描器在自己的 actor 上同步查,
/// 第一次查时才读盘。
final class PeerScanSeedLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds: [String: PeerScanSeed]?
    private let load: @Sendable () -> [String: PeerScanSeed]

    init(load: @escaping @Sendable () -> [String: PeerScanSeed]) {
        self.load = load
    }

    init(seeds: [String: PeerScanSeed]) {
        self.seeds = seeds
        self.load = { seeds }
    }

    func seed(for songID: String) -> PeerScanSeed? {
        lock.lock()
        defer { lock.unlock() }
        if seeds == nil {
            seeds = load()
        }
        return seeds?[songID]
    }
}

/// 把别的设备的结果接到扫描、补读和上传上:什么时候去 iCloud 看、什么时候拿来补本机
/// 还没读的行、本机读完一轮后什么时候把自己的结果传上去。
@MainActor
final class PeerScanSeedCoordinator {
    private let sourcesStore: SourcesStore
    private weak var library: MusicLibrary?
    private weak var backfill: MetadataBackfillService?
    private var activeRefreshTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    /// 这次运行里已经拿现有结果补过的源。结果没更新就不再整库比一遍。
    private var filledSourceIDs: Set<String> = []
    /// 首扫没等别的设备、扫完要再去看一眼的源(见 `lookup`)。
    private var postScanCheckSourceIDs: Set<String> = []

    init(sourcesStore: SourcesStore, library: MusicLibrary, backfill: MetadataBackfillService) {
        self.sourcesStore = sourcesStore
        self.library = library
        self.backfill = backfill
    }

    private var seedScope: PeerScanSeedScope {
        PeerScanSeedScope.make(
            sources: sourcesStore.allSources,
            deletedSourceIDs: Set(sourcesStore.sourceDeletionRecords.map(\.id)),
            isEligible: PeerScanSeedStore.isEligible
        )
    }

    /// 扫描开始前调用。本机还没扫过这个源时先去 iCloud 取一次最新的结果,最多等 15 秒。
    /// 这段时间扫描还没开始列文件,所以本机建的源不等:id 是本机生成的,这次运行才建的
    /// 别的设备不可能扫过;之前建的、还没扫过就被关掉的,别的设备也只是可能扫过,
    /// 扫完再去看一眼,有结果就交给补读接过来。
    func lookup(for source: MusicSource) async -> PeerScanSeedLookup? {
        guard PeerScanSeedStore.isEnabled, PeerScanSeedStore.isEligible(source) else { return nil }
        let hasLocalRows = library?.songs.contains { $0.sourceID == source.id } ?? true
        if !hasLocalRows, sourcesStore.sourceIDsCreatedOnThisDevice.contains(source.id) {
            if !sourcesStore.sourceIDsCreatedThisRun.contains(source.id) {
                postScanCheckSourceIDs.insert(source.id)
            }
        } else if !hasLocalRows {
            let scope = seedScope.including(source.id)
            let refresh = Task.detached(priority: .userInitiated) {
                _ = await PeerScanSeedStore.shared.refresh(scope: scope, force: true)
            }
            let startedAt = Date()
            await Self.wait(for: refresh, upTo: 15)
            plog("🧩 peer seeds: waited \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s before the first scan of \(source.name)")
        }
        return PeerScanSeedStore.shared.lookup(forSourceID: source.id)
    }

    /// 启动后、回到前台时。本机有标签没读完才去看别的设备有没有新结果。
    func sceneDidBecomeActive() {
        activeRefreshTask?.cancel()
        activeRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await self?.refreshAndFill()
        }
    }

    func refreshAndFill() async {
        guard PeerScanSeedStore.isEnabled, let backfill else { return }
        let scope = seedScope
        let needing = scope.wanted.filter { backfill.statusCount(forSource: $0) > 0 }
        guard !needing.isEmpty else { return }
        let result = await PeerScanSeedStore.shared.refresh(scope: scope)
        let targets = needing.filter {
            result?.updatedSourceIDs.contains($0) == true || !filledSourceIDs.contains($0)
        }
        await fill(sourceIDs: targets)
    }

    private func fill(sourceIDs: Set<String>) async {
        guard !sourceIDs.isEmpty else { return }
        filledSourceIDs.formUnion(sourceIDs)
        var lookups: [String: PeerScanSeedLookup] = [:]
        for id in sourceIDs {
            if let lookup = PeerScanSeedStore.shared.lookup(forSourceID: id) { lookups[id] = lookup }
        }
        guard !lookups.isEmpty else { return }
        await backfill?.adoptPeerScanSeeds(lookups: lookups)
    }

    /// 一次扫描刚结束。群晖 File Station 由它自己的扫描器生成行,扫描时没接这条路,
    /// 在这里补一遍;首扫没等别的设备的源再去看一眼;然后让别的设备早点拿到本机的结果。
    func sourceScanSucceeded(sourceID: String) {
        guard let source = sourcesStore.source(id: sourceID),
              PeerScanSeedStore.isEligible(source) else { return }
        if PeerScanSeedStore.isEnabled {
            if source.type == .synology {
                Task { [weak self] in await self?.fill(sourceIDs: [sourceID]) }
            }
            if postScanCheckSourceIDs.remove(sourceID) != nil {
                let scope = seedScope.including(sourceID)
                Task { [weak self] in
                    _ = await PeerScanSeedStore.shared.refresh(scope: scope, force: true)
                    await self?.fill(sourceIDs: [sourceID])
                }
            }
            // 扫描交来的行这时都已提交:同一张封面已经有着落的,把后进库的歌指过去。
            backfill?.schedulePeerCoverSweep()
        }
        readingProgressDidAdvance()
    }

    /// 本机读完了一批标签。账号里有别的设备在用时,不等退到后台、也不等一小时,
    /// 30 秒后把本机的结果传上去(上传本身至少隔十五分钟)。
    func readingProgressDidAdvance() {
        guard CloudSyncChannel.isMasterEnabled(),
              PeerScanSeedStore.shared.hasKnownPeerDevices else { return }
        LibrarySnapshotSync.shared.noteLibraryReadingProgress()
        uploadTask?.cancel()
        uploadTask = Task(priority: .utility) { [weak library] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let library else { return }
            if library.hasPendingPortableSnapshotChanges,
               case .failure = await library.persistNowAndWait() {
                return
            }
            _ = await LibrarySnapshotSync.shared.uploadAutomaticallyIfNeeded()
        }
    }

    /// 等 `task` 结束,最多 `seconds` 秒;超时就不等了,任务照旧在后台跑完。
    private static func wait(for task: Task<Void, Never>, upTo seconds: Double) async {
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            func arm(_ continuation: CheckedContinuation<Void, Never>) {
                lock.lock(); self.continuation = continuation; lock.unlock()
            }
            func open() {
                lock.lock()
                let continuation = self.continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume()
            }
        }
        let gate = Gate()
        await withCheckedContinuation { continuation in
            gate.arm(continuation)
            Task.detached {
                await task.value
                gate.open()
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                gate.open()
            }
        }
    }
}
