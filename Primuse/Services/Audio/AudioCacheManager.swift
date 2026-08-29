import CryptoKit
import Foundation
import Observation
import PrimuseKit

struct AutomaticOfflinePinRequest: Sendable {
    let path: String
    let playlistIDs: Set<String>
    let expectedByteCount: Int64
}

enum OfflineAudioCacheState: String, Codable, Sendable, Equatable {
    case notCached
    case cached
    case pinned
    case downloading
    case failed
}

struct OfflineAudioCacheSnapshot: Sendable, Equatable {
    var state: OfflineAudioCacheState
    var progress: Double?
    var byteCount: Int64?
    var errorMessage: String?

    static let notCached = OfflineAudioCacheSnapshot(
        state: .notCached,
        progress: nil,
        byteCount: nil,
        errorMessage: nil
    )

    var isPinned: Bool { state == .pinned }
    var isDownloading: Bool { state == .downloading }
    var isDownloaded: Bool { state == .cached || state == .pinned }
}

/// LRU cache manager for audio files. Enforces the configured disk size limit
/// by evicting least-recently-accessed files when the cache grows too large.
actor AudioCacheManager {
    static let shared = AudioCacheManager()

    static let defaultMaxCacheSize = AudioCacheLimitPolicy.defaultBytes

    private var accessLog: [String: Date] = [:]
    private var offlineManifest: [String: OfflineManifestEntry] = [:]
    private let logURL: URL
    private let manifestURL: URL
    private let basePath: URL
    private var persistTask: Task<Void, Never>?
    private var manifestPersistTask: Task<Void, Never>?

    private struct OfflineManifestEntry: Codable, Sendable {
        var isManuallyPinned: Bool
        var playlistIDs: Set<String>
        var byteCount: Int64?
        var pinnedAt: Date?
        var downloadedAt: Date?

        var isPinned: Bool {
            isManuallyPinned || !playlistIDs.isEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case isPinned
            case isManuallyPinned
            case playlistIDs
            case byteCount
            case pinnedAt
            case downloadedAt
        }

        init(
            isManuallyPinned: Bool,
            playlistIDs: Set<String> = [],
            byteCount: Int64?,
            pinnedAt: Date?,
            downloadedAt: Date?
        ) {
            self.isManuallyPinned = isManuallyPinned
            self.playlistIDs = playlistIDs
            self.byteCount = byteCount
            self.pinnedAt = pinnedAt
            self.downloadedAt = downloadedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let legacyPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            isManuallyPinned = try container.decodeIfPresent(
                Bool.self,
                forKey: .isManuallyPinned
            ) ?? legacyPinned
            playlistIDs = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .playlistIDs
            ) ?? []
            byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
            pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
            downloadedAt = try container.decodeIfPresent(Date.self, forKey: .downloadedAt)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(isPinned, forKey: .isPinned)
            try container.encode(isManuallyPinned, forKey: .isManuallyPinned)
            try container.encode(playlistIDs, forKey: .playlistIDs)
            try container.encodeIfPresent(byteCount, forKey: .byteCount)
            try container.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
            try container.encodeIfPresent(downloadedAt, forKey: .downloadedAt)
        }
    }

    private init() {
        let caches = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        basePath = caches.appendingPathComponent("primuse_audio_cache")
        logURL = basePath.appendingPathComponent(".access_log.json")
        manifestURL = basePath.appendingPathComponent(".offline_manifest.json")
        // Actor init is nonisolated; defer loading to first access
    }

    private var initialized = false
    private func ensureInitialized() {
        guard !initialized else { return }
        initialized = true
        loadAccessLog()
        loadOfflineManifest()
        migrateExistingFiles()
    }

    // MARK: - Public API

    /// Record that a cached file was accessed (played or just created).
    func recordAccess(path: String) {
        ensureInitialized()
        accessLog[path] = Date()
        schedulePersist()
    }

    func migrateEntry(from oldPath: String, to newPath: String, byteCount: Int64?) {
        ensureInitialized()
        if let date = accessLog.removeValue(forKey: oldPath) {
            accessLog[newPath] = max(accessLog[newPath] ?? .distantPast, date)
        } else {
            accessLog[newPath] = Date()
        }
        if var entry = offlineManifest.removeValue(forKey: oldPath) {
            entry.byteCount = byteCount ?? entry.byteCount
            offlineManifest[newPath] = entry
        }
        schedulePersist()
        scheduleManifestPersist()
    }

    func cacheLimitBytes() -> Int64 {
        PlaybackSettings.load().audioCacheLimitBytes
    }

    func snapshot(path: String, fileExists: Bool, byteCount: Int64?) -> OfflineAudioCacheSnapshot {
        ensureInitialized()
        if let entry = offlineManifest[path], entry.isPinned, fileExists {
            return OfflineAudioCacheSnapshot(
                state: .pinned,
                progress: nil,
                byteCount: byteCount ?? entry.byteCount,
                errorMessage: nil
            )
        }
        if fileExists {
            return OfflineAudioCacheSnapshot(
                state: .cached,
                progress: nil,
                byteCount: byteCount,
                errorMessage: nil
            )
        }
        return .notCached
    }

    func markDownloaded(path: String, byteCount: Int64?, pinned: Bool) {
        ensureInitialized()
        accessLog[path] = Date()
        var entry = offlineManifest[path] ?? OfflineManifestEntry(
            isManuallyPinned: false,
            byteCount: byteCount,
            pinnedAt: nil,
            downloadedAt: Date()
        )
        entry.isManuallyPinned = entry.isManuallyPinned || pinned
        entry.byteCount = byteCount ?? entry.byteCount
        entry.pinnedAt = entry.isPinned ? (entry.pinnedAt ?? Date()) : nil
        entry.downloadedAt = Date()
        offlineManifest[path] = entry
        schedulePersist()
        scheduleManifestPersist()
    }

    func pin(path: String, byteCount: Int64?) {
        ensureInitialized()
        var entry = offlineManifest[path] ?? OfflineManifestEntry(
            isManuallyPinned: true,
            byteCount: byteCount,
            pinnedAt: Date(),
            downloadedAt: Date()
        )
        entry.isManuallyPinned = true
        entry.byteCount = byteCount ?? entry.byteCount
        entry.pinnedAt = entry.pinnedAt ?? Date()
        entry.downloadedAt = entry.downloadedAt ?? Date()
        offlineManifest[path] = entry
        accessLog[path] = Date()
        schedulePersist()
        scheduleManifestPersist()
    }

    func pin(path: String, byteCount: Int64?, forPlaylistIDs playlistIDs: Set<String>) {
        guard !playlistIDs.isEmpty else { return }
        ensureInitialized()
        var entry = offlineManifest[path] ?? OfflineManifestEntry(
            isManuallyPinned: false,
            playlistIDs: playlistIDs,
            byteCount: byteCount,
            pinnedAt: Date(),
            downloadedAt: Date()
        )
        entry.playlistIDs.formUnion(playlistIDs)
        entry.byteCount = byteCount ?? entry.byteCount
        entry.pinnedAt = entry.pinnedAt ?? Date()
        entry.downloadedAt = entry.downloadedAt ?? Date()
        offlineManifest[path] = entry
        accessLog[path] = Date()
        schedulePersist()
        scheduleManifestPersist()
    }

    /// Replaces only automatic playlist ownership. Manual pins survive, while
    /// files that lose their final automatic owner remain as ordinary LRU
    /// cache entries instead of being deleted immediately.
    func reconcileAutomaticPlaylistPins(
        _ requests: [AutomaticOfflinePinRequest]
    ) -> Set<String> {
        ensureInitialized()
        var desiredByPath: [String: AutomaticOfflinePinRequest] = [:]
        for request in requests {
            if let existing = desiredByPath[request.path] {
                desiredByPath[request.path] = AutomaticOfflinePinRequest(
                    path: request.path,
                    playlistIDs: existing.playlistIDs.union(request.playlistIDs),
                    expectedByteCount: max(
                        existing.expectedByteCount,
                        request.expectedByteCount
                    )
                )
            } else {
                desiredByPath[request.path] = request
            }
        }
        var manifestChanged = false
        var missingPaths = Set<String>()

        for path in Array(offlineManifest.keys) {
            guard var entry = offlineManifest[path] else { continue }
            let desiredOwners = desiredByPath[path]?.playlistIDs ?? []
            if entry.playlistIDs != desiredOwners {
                entry.playlistIDs = desiredOwners
                entry.pinnedAt = entry.isPinned ? (entry.pinnedAt ?? Date()) : nil
                offlineManifest[path] = entry
                manifestChanged = true
            }
        }

        for request in desiredByPath.values {
            let fileURL = basePath.appendingPathComponent(request.path)
            let byteCount = logicalFileSize(at: fileURL)
            let isUsable = byteCount.map { size in
                request.expectedByteCount <= 0
                    || size >= Int64(Double(request.expectedByteCount) * 0.95)
            } ?? false
            guard isUsable else {
                missingPaths.insert(request.path)
                continue
            }

            let entryExisted = offlineManifest[request.path] != nil
            var entry = offlineManifest[request.path] ?? OfflineManifestEntry(
                isManuallyPinned: false,
                playlistIDs: request.playlistIDs,
                byteCount: byteCount,
                pinnedAt: Date(),
                downloadedAt: Date()
            )
            let previous = entry
            entry.playlistIDs = request.playlistIDs
            entry.byteCount = byteCount ?? entry.byteCount
            entry.pinnedAt = entry.isPinned ? (entry.pinnedAt ?? Date()) : nil
            entry.downloadedAt = entry.downloadedAt ?? Date()
            offlineManifest[request.path] = entry
            if !entryExisted
                || previous.isManuallyPinned != entry.isManuallyPinned
                || previous.playlistIDs != entry.playlistIDs
                || previous.byteCount != entry.byteCount
                || previous.pinnedAt != entry.pinnedAt
                || previous.downloadedAt != entry.downloadedAt {
                manifestChanged = true
            }
        }

        if manifestChanged { scheduleManifestPersist() }
        return missingPaths
    }

    func unpin(path: String) {
        ensureInitialized()
        guard var entry = offlineManifest[path] else { return }
        entry.isManuallyPinned = false
        entry.pinnedAt = entry.isPinned ? entry.pinnedAt : nil
        offlineManifest[path] = entry
        scheduleManifestPersist()
    }

    func pinnedBytes() -> Int64 {
        ensureInitialized()
        return offlineManifest.values.reduce(Int64(0)) { total, entry in
            total + (entry.isPinned ? (entry.byteCount ?? 0) : 0)
        }
    }

    func pinnedRelativePaths() -> Set<String> {
        ensureInitialized()
        return Set(offlineManifest.compactMap { path, entry in
            entry.isPinned ? path : nil
        })
    }

    func clearUnpinnedAccessEntries() {
        ensureInitialized()
        accessLog = accessLog.filter { path, _ in
            offlineManifest[path]?.isPinned == true
        }
        schedulePersist()
    }

    /// Evict oldest files until there is room for `reserveBytes` additional data.
    ///
    /// 之前的版本只看 `accessLog` 的文件 — 但 `.partial` 半成品 (Range
    /// streaming 中途没下完, 或者只 prewarm 的 head+tail) 永远不进
    /// accessLog (因为 recordAccess 只在完整 rename 后调)。结果 LRU
    /// 看不见 .partial, 完整文件被压在 2GB 但 .partial 无限堆 —— 用户
    /// 实际见到 5GB+ 缓存。
    ///
    /// 现在改成扫整个 cache 目录, 对没记录的 .partial / orphan 用 mtime
    /// 当 access time 兜底, 一并参与 LRU 排序 + eviction。
    func evictIfNeeded(reserveBytes: Int64) {
        ensureInitialized()
        let currentSize = totalCacheSizeSync()
        guard let target = AudioCacheLimitPolicy.evictionTarget(
            limitBytes: cacheLimitBytes(),
            reserveBytes: reserveBytes
        ) else { return }

        guard currentSize > target else { return }

        // 扫整个 cache 目录, 给 accessLog 没覆盖的文件 (主要是 .partial /
        // .partial.prewarmed) 用 mtime 当 access 时间兜底。
        struct EvictCandidate { let url: URL; let relativePath: String; let size: Int64; let lastUsed: Date }
        var candidates: [EvictCandidate] = []
        let basePathPrefix = basePath.path + "/"

        if let enumerator = FileManager.default.enumerator(
            at: basePath,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
                ), values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? 0)
                guard size > 0 else { continue }
                let relative = fileURL.path.hasPrefix(basePathPrefix)
                    ? String(fileURL.path.dropFirst(basePathPrefix.count))
                    : fileURL.lastPathComponent
                let lastUsed = accessLog[relative] ?? values.contentModificationDate ?? .distantPast
                if offlineManifest[relative]?.isPinned == true {
                    continue
                }
                candidates.append(EvictCandidate(url: fileURL, relativePath: relative, size: size, lastUsed: lastUsed))
            }
        }

        // 最旧的优先 evict
        candidates.sort { $0.lastUsed < $1.lastUsed }
        var freed: Int64 = 0
        let needed = currentSize - target
        for cand in candidates {
            if freed >= needed { break }
            do {
                try FileManager.default.removeItem(at: cand.url)
                freed += cand.size
                accessLog[cand.relativePath] = nil
            } catch {
                plog("⚠️ evictIfNeeded: failed to remove \(cand.relativePath): \(error.localizedDescription)")
            }
        }
        plog("🧹 evictIfNeeded: freed \(freed / 1024 / 1024)MB / needed \(needed / 1024 / 1024)MB")

        schedulePersist()
    }

    func totalCacheSize() -> Int64 {
        totalCacheSizeSync()
    }

    /// Remove a single cache entry by its relative path.
    func removeEntry(path: String) {
        ensureInitialized()
        let fileURL = basePath.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: fileURL)
        accessLog[path] = nil
        offlineManifest[path] = nil
        schedulePersist()
        scheduleManifestPersist()
    }

    /// 删 LRU 里以 `prefix` 开头的所有记录。配合 SourceManager.purgeAudioCache
    /// 用 —— 删源时一次清掉所有属于这个 sourceID 的访问时间戳, 不然
    /// accessLog 里残留的 dead key 越堆越多。
    func removeAllEntries(forSourcePrefix prefix: String) {
        removeAllEntries(forSourcePrefixes: [prefix])
    }

    func removeAllEntries(forSourcePrefixes prefixes: [String]) {
        guard !prefixes.isEmpty else { return }
        ensureInitialized()
        let keys = accessLog.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
        for key in keys { accessLog[key] = nil }
        let manifestKeys = offlineManifest.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
        for key in manifestKeys { offlineManifest[key] = nil }
        if !keys.isEmpty { schedulePersist() }
        if !manifestKeys.isEmpty { scheduleManifestPersist() }
    }

    func removeEntries(paths: [String]) {
        guard !paths.isEmpty else { return }
        ensureInitialized()
        var accessChanged = false
        var manifestChanged = false
        for path in paths {
            accessChanged = accessLog.removeValue(forKey: path) != nil || accessChanged
            manifestChanged = offlineManifest.removeValue(forKey: path) != nil || manifestChanged
        }
        if accessChanged { schedulePersist() }
        if manifestChanged { scheduleManifestPersist() }
    }

    func clearAll() {
        accessLog.removeAll()
        offlineManifest.removeAll()
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: manifestURL)
        persistNow()
        persistManifestNow()
    }

    // MARK: - Internal

    private func totalCacheSizeSync() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: basePath, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let size = values.totalFileAllocatedSize else { return nil }
        return Int64(size)
    }

    private func logicalFileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// For files already in cache with no access log entry, use modification date.
    private func migrateExistingFiles() {
        guard let enumerator = FileManager.default.enumerator(
            at: basePath, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        var changed = false
        for case let fileURL as URL in enumerator {
            let relative = fileURL.path.replacingOccurrences(of: basePath.path + "/", with: "")
            if accessLog[relative] == nil {
                let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                accessLog[relative] = modified
                changed = true
            }
        }
        if changed { persistNow() }
    }

    // MARK: - Persistence

    private func loadAccessLog() {
        guard let data = try? Data(contentsOf: logURL),
              let log = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        accessLog = log
    }

    private func loadOfflineManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode([String: OfflineManifestEntry].self, from: data) else { return }
        offlineManifest = manifest
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func scheduleManifestPersist() {
        manifestPersistTask?.cancel()
        manifestPersistTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            persistManifestNow()
        }
    }

    private func persistNow() {
        try? FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(accessLog) else { return }
        try? data.write(to: logURL, options: .atomic)
    }

    private func persistManifestNow() {
        try? FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(offlineManifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

private actor AlwaysDownloadWorker {
    private struct Job: Codable, Sendable {
        var song: Song
        var playlistIDs: Set<String>
        var contentSignature: String
        var forceRedownload: Bool
        var attemptCount: Int
        var nextAttemptAt: Date
        var enqueuedAt: Date
    }

    private struct Journal: Codable, Sendable {
        var jobs: [String: Job] = [:]
        var completedSignatures: [String: String] = [:]
        /// Optional keeps journals written by the first queue schema
        /// decodable. This records the provenance of complete and partial
        /// automatic transfers even while their playlist is disabled.
        var lastKnownSignatures: [String: String]? = nil
    }

    private struct ResourceSnapshot: Sendable {
        let hasDeterminedNetwork: Bool
        let isReachable: Bool
        let isExpensive: Bool
        let isConstrained: Bool
        let isPlaybackBuffering: Bool
        let isLowPowerModeEnabled: Bool
        let hasSeriousThermalPressure: Bool
    }

    private let sourceManager: SourceManager
    private let player: AudioPlayerService
    private let journalURL: URL
    private var journal = Journal()
    private var desiredBySongID: [String: AlwaysDownloadDesiredSong] = [:]
    private var applicationIsActive = true
    private var playbackIsBuffering = false
    private var resourceConditionsAllowTransfers = false
    private var didLoadJournal = false
    private var runner: Task<Void, Never>?
    private var runnerGeneration = UUID()

    init(
        sourceManager: SourceManager,
        player: AudioPlayerService,
        journalURL: URL
    ) {
        self.sourceManager = sourceManager
        self.player = player
        self.journalURL = journalURL
    }

    func start(
        applicationIsActive: Bool,
        playbackIsBuffering: Bool,
        resourceConditionsAllowTransfers: Bool
    ) {
        loadJournalIfNeeded()
        self.applicationIsActive = applicationIsActive
        self.playbackIsBuffering = playbackIsBuffering
        self.resourceConditionsAllowTransfers = resourceConditionsAllowTransfers
    }

    func setApplicationActive(_ active: Bool) async {
        applicationIsActive = active
        if active {
            scheduleRunner()
        } else {
            await cancelRunner()
        }
    }

    func resourceConditionsDidChange(
        playbackIsBuffering: Bool,
        allowTransfers: Bool
    ) async {
        self.playbackIsBuffering = playbackIsBuffering
        resourceConditionsAllowTransfers = allowTransfers
        if playbackIsBuffering || !allowTransfers {
            await cancelRunner()
        } else {
            scheduleRunner()
        }
    }

    func replaceDesiredSongs(_ desiredSongs: [AlwaysDownloadDesiredSong]) async {
        loadJournalIfNeeded()
        await cancelRunner()

        var nextDesired: [String: AlwaysDownloadDesiredSong] = [:]
        nextDesired.reserveCapacity(desiredSongs.count)
        for desired in desiredSongs {
            if let existing = nextDesired[desired.song.id] {
                nextDesired[desired.song.id] = AlwaysDownloadDesiredSong(
                    song: desired.song,
                    playlistIDs: existing.playlistIDs.union(desired.playlistIDs),
                    contentSignature: desired.contentSignature
                )
            } else {
                nextDesired[desired.song.id] = desired
            }
        }
        desiredBySongID = nextDesired
        var knownSignatures = journal.lastKnownSignatures ?? [:]
        for (songID, job) in journal.jobs where !job.forceRedownload {
            knownSignatures[songID] = job.contentSignature
        }

        let desiredValues = Array(nextDesired.values)
        let missingSongIDs = await sourceManager.reconcileAutomaticPlaylistPins(
            desiredValues
        )
        let desiredSignatures = nextDesired.mapValues(\.contentSignature)

        // A complete file already in the ordinary playback cache can be
        // promoted without another transfer on first enable. Once a signature
        // has been recorded, a signature change deliberately forces refresh.
        for desired in desiredValues
        where !missingSongIDs.contains(desired.song.id)
            && journal.completedSignatures[desired.song.id] == nil
            && AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
                desiredSignature: desired.contentSignature,
                completedSignature: nil,
                lastKnownSignature: knownSignatures[desired.song.id]
            ) {
            journal.completedSignatures[desired.song.id] = desired.contentSignature
            knownSignatures[desired.song.id] = desired.contentSignature
        }

        let requiredSongIDs = AutomaticOfflineDownloadPolicy.requiredSongIDs(
            desiredSignatures: desiredSignatures,
            completedSignatures: journal.completedSignatures,
            missingSongIDs: missingSongIDs
        )
        journal.jobs = journal.jobs.filter { requiredSongIDs.contains($0.key) }
        let now = Date()
        for songID in requiredSongIDs {
            guard let desired = nextDesired[songID] else { continue }
            let contentChanged = AutomaticOfflineDownloadPolicy.requiresContentRefresh(
                desiredSignature: desired.contentSignature,
                completedSignature: journal.completedSignatures[songID],
                lastKnownSignature: knownSignatures[songID]
            )
            if var existing = journal.jobs[songID],
               existing.contentSignature == desired.contentSignature {
                existing.song = desired.song
                existing.playlistIDs = desired.playlistIDs
                existing.forceRedownload = existing.forceRedownload || contentChanged
                journal.jobs[songID] = existing
            } else {
                journal.jobs[songID] = Job(
                    song: desired.song,
                    playlistIDs: desired.playlistIDs,
                    contentSignature: desired.contentSignature,
                    forceRedownload: contentChanged,
                    attemptCount: 0,
                    nextAttemptAt: now,
                    enqueuedAt: now
                )
            }
        }
        journal.lastKnownSignatures = knownSignatures
        persistJournal()
        scheduleRunner()
    }

    func invalidateCompletedSong(_ songID: String) async {
        loadJournalIfNeeded()
        journal.completedSignatures.removeValue(forKey: songID)
        guard let desired = desiredBySongID[songID] else {
            journal.jobs.removeValue(forKey: songID)
            persistJournal()
            return
        }
        let now = Date()
        journal.jobs[songID] = Job(
            song: desired.song,
            playlistIDs: desired.playlistIDs,
            contentSignature: desired.contentSignature,
            forceRedownload: false,
            attemptCount: 0,
            nextAttemptAt: now,
            enqueuedAt: now
        )
        persistJournal()
        await restartRunner()
    }

    private func cancelRunner() async {
        runnerGeneration = UUID()
        let previousRunner = runner
        previousRunner?.cancel()
        runner = nil
        await previousRunner?.value
    }

    private func restartRunner() async {
        await cancelRunner()
        scheduleRunner()
    }

    private func scheduleRunner() {
        guard runner == nil,
              applicationIsActive,
              !playbackIsBuffering,
              resourceConditionsAllowTransfers,
              !journal.jobs.isEmpty else { return }
        let generation = UUID()
        runnerGeneration = generation
        runner = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(generation: generation)
        }
    }

    private func runLoop(generation: UUID) async {
        defer {
            if runnerGeneration == generation {
                runner = nil
            }
        }
        while !Task.isCancelled,
              runnerGeneration == generation,
              applicationIsActive,
              !playbackIsBuffering,
              resourceConditionsAllowTransfers {
            guard let job = nextJob() else { return }
            let now = Date()
            if job.nextAttemptAt > now {
                let seconds = max(1, min(30, Int(job.nextAttemptAt.timeIntervalSince(now).rounded(.up))))
                try? await Task.sleep(for: .seconds(seconds))
                continue
            }

            let resources = await resourceSnapshot()
            let eligibility = AutomaticOfflineDownloadPolicy.eligibility(
                applicationIsActive: applicationIsActive,
                hasDeterminedNetwork: resources.hasDeterminedNetwork,
                isReachable: resources.isReachable,
                isExpensive: resources.isExpensive,
                isConstrained: resources.isConstrained,
                isLowPowerModeEnabled: resources.isLowPowerModeEnabled,
                hasSeriousThermalPressure: resources.hasSeriousThermalPressure,
                availableDiskBytes: Self.availableDiskBytes(),
                expectedDownloadBytes: job.song.fileSize,
                isPlaybackBuffering: resources.isPlaybackBuffering
            )
            guard eligibility == .allowed else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }

            let prepared = await sourceManager.prepareAutomaticOfflineDownload(
                song: job.song,
                forceRedownload: job.forceRedownload
            )
            guard !Task.isCancelled,
                  runnerGeneration == generation,
                  let currentDesired = desiredBySongID[job.song.id],
                  currentDesired.contentSignature == job.contentSignature else {
                return
            }
            guard prepared else {
                var deferred = journal.jobs[job.song.id] ?? job
                deferred.nextAttemptAt = Date().addingTimeInterval(5)
                journal.jobs[job.song.id] = deferred
                persistJournal()
                continue
            }
            if job.forceRedownload {
                var preparedJob = journal.jobs[job.song.id] ?? job
                preparedJob.forceRedownload = false
                journal.jobs[job.song.id] = preparedJob
                journal.completedSignatures.removeValue(forKey: job.song.id)
                var knownSignatures = journal.lastKnownSignatures ?? [:]
                knownSignatures[job.song.id] = job.contentSignature
                journal.lastKnownSignatures = knownSignatures
                persistJournal()
            }

            let result = await sourceManager.downloadAutomaticallyForOffline(
                song: job.song,
                playlistIDs: job.playlistIDs
            )
            guard !Task.isCancelled,
                  runnerGeneration == generation,
                  let currentDesired = desiredBySongID[job.song.id],
                  currentDesired.contentSignature == job.contentSignature else {
                return
            }

            switch result {
            case .completed:
                journal.completedSignatures[job.song.id] = job.contentSignature
                var knownSignatures = journal.lastKnownSignatures ?? [:]
                knownSignatures[job.song.id] = job.contentSignature
                journal.lastKnownSignatures = knownSignatures
                journal.jobs.removeValue(forKey: job.song.id)
                persistJournal()
                await refreshPinsAndAbsorbExistingFiles()
            case .cancelled:
                return
            case .failed(let authenticationRequired, _):
                var retry = journal.jobs[job.song.id] ?? job
                retry.attemptCount = min(retry.attemptCount + 1, 16)
                let exponent = min(retry.attemptCount - 1, 7)
                let backoff = min(30 * (1 << exponent), 3_600)
                retry.nextAttemptAt = Date().addingTimeInterval(
                    TimeInterval(authenticationRequired ? max(backoff, 900) : backoff)
                )
                journal.jobs[job.song.id] = retry
                persistJournal()
            }
        }
    }

    private func refreshPinsAndAbsorbExistingFiles() async {
        let desiredValues = Array(desiredBySongID.values)
        let missingSongIDs = await sourceManager.reconcileAutomaticPlaylistPins(
            desiredValues
        )
        for desired in desiredValues
        where !missingSongIDs.contains(desired.song.id)
            && journal.completedSignatures[desired.song.id] == nil
            && AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
                desiredSignature: desired.contentSignature,
                completedSignature: nil,
                lastKnownSignature: journal.lastKnownSignatures?[desired.song.id]
            ) {
            journal.completedSignatures[desired.song.id] = desired.contentSignature
            var knownSignatures = journal.lastKnownSignatures ?? [:]
            knownSignatures[desired.song.id] = desired.contentSignature
            journal.lastKnownSignatures = knownSignatures
            journal.jobs.removeValue(forKey: desired.song.id)
        }
        persistJournal()
    }

    private func nextJob() -> Job? {
        journal.jobs.values.min { lhs, rhs in
            if lhs.nextAttemptAt != rhs.nextAttemptAt {
                return lhs.nextAttemptAt < rhs.nextAttemptAt
            }
            if lhs.enqueuedAt != rhs.enqueuedAt {
                return lhs.enqueuedAt < rhs.enqueuedAt
            }
            return lhs.song.id < rhs.song.id
        }
    }

    private func resourceSnapshot() async -> ResourceSnapshot {
        let player = self.player
        return await MainActor.run {
            let network = NetworkMonitor.shared
            let thermal = ProcessInfo.processInfo.thermalState
            return ResourceSnapshot(
                hasDeterminedNetwork: network.hasDeterminedPath,
                isReachable: network.isReachable,
                isExpensive: network.isExpensive,
                isConstrained: network.isConstrained,
                isPlaybackBuffering: player.isLoading,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                hasSeriousThermalPressure: thermal == .serious || thermal == .critical
            )
        }
    }

    private func loadJournalIfNeeded() {
        guard !didLoadJournal else { return }
        didLoadJournal = true
        guard let data = try? Data(contentsOf: journalURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        journal = (try? decoder.decode(Journal.self, from: data)) ?? Journal()
    }

    private func persistJournal() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(journal) else { return }
        try? FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: journalURL, options: .atomic)
    }

    private static func availableDiskBytes() -> Int64 {
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        guard let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: base.path
        ), let value = attributes[.systemFreeSize] as? NSNumber else { return 0 }
        return value.int64Value
    }
}

@MainActor
@Observable
final class AlwaysDownloadCoordinator {
    private static let defaultsKey = "primuse.playlist-always-download.v1"

    private let library: MusicLibrary
    private let sourcesStore: SourcesStore
    private let sourceManager: SourceManager
    private let player: AudioPlayerService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let worker: AlwaysDownloadWorker
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var resourceObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var applicationIsActive = true
    private(set) var enabledPlaylistIDs: Set<String>

    init(
        library: MusicLibrary,
        sourcesStore: SourcesStore,
        sourceManager: SourceManager,
        player: AudioPlayerService,
        defaults: UserDefaults = .standard
    ) {
        self.library = library
        self.sourcesStore = sourcesStore
        self.sourceManager = sourceManager
        self.player = player
        self.defaults = defaults
        enabledPlaylistIDs = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        #if os(tvOS)
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        worker = AlwaysDownloadWorker(
            sourceManager: sourceManager,
            player: player,
            journalURL: base
                .appendingPathComponent("Primuse", isDirectory: true)
                .appendingPathComponent("always-download-queue-v1.json")
        )
    }

    func isEnabled(for playlistID: String) -> Bool {
        enabledPlaylistIDs.contains(playlistID)
    }

    func setEnabled(_ enabled: Bool, for playlistID: String) {
        if enabled {
            enabledPlaylistIDs.insert(playlistID)
        } else {
            enabledPlaylistIDs.remove(playlistID)
        }
        persistPreferences()
        scheduleReconciliation(delay: .zero)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        observeLibraryAndSources()
        observeTransferConditions()
        observePowerAndThermalConditions()
        Task { [weak self] in
            guard let self else { return }
            await self.worker.start(
                applicationIsActive: self.applicationIsActive,
                playbackIsBuffering: self.player.isLoading,
                resourceConditionsAllowTransfers: self.resourceConditionsAllowTransfers()
            )
            await self.reconcileNow()
        }
    }

    func setApplicationActive(_ active: Bool) {
        applicationIsActive = active
        Task { [weak self] in
            await self?.worker.setApplicationActive(active)
        }
    }

    func sourceScanDidComplete() {
        scheduleReconciliation()
    }

    func downloadedFileWasRemoved(songID: String) {
        Task { [weak self] in
            await self?.worker.invalidateCompletedSong(songID)
        }
    }

    private func observeLibraryAndSources() {
        withObservationTracking {
            _ = library.playlistCollectionRevision
            _ = library.visibleSongCollectionRevision
            _ = library.songReplacementToken
            _ = sourcesStore.sources
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeLibraryAndSources()
                self.scheduleReconciliation()
            }
        }
    }

    private func observeTransferConditions() {
        withObservationTracking {
            _ = player.isLoading
            _ = NetworkMonitor.shared.pathGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeTransferConditions()
                await self.worker.resourceConditionsDidChange(
                    playbackIsBuffering: self.player.isLoading,
                    allowTransfers: self.resourceConditionsAllowTransfers()
                )
            }
        }
    }

    private func observePowerAndThermalConditions() {
        let center = NotificationCenter.default
        for name in [
            Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            Notification.Name("NSProcessInfoThermalStateDidChangeNotification"),
        ] {
            resourceObserverTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.worker.resourceConditionsDidChange(
                            playbackIsBuffering: self.player.isLoading,
                            allowTransfers: self.resourceConditionsAllowTransfers()
                        )
                    }
                }
            )
        }
    }

    private func resourceConditionsAllowTransfers() -> Bool {
        let network = NetworkMonitor.shared
        guard network.hasDeterminedPath,
              network.isReachable,
              !network.isExpensive,
              !network.isConstrained,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }

    private func scheduleReconciliation(delay: Duration = .milliseconds(500)) {
        guard didStart else { return }
        reconciliationTask?.cancel()
        reconciliationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.reconcileNow()
        }
    }

    private func reconcileNow() async {
        let visiblePlaylistIDs = Set(library.playlists.map(\.id))
        let cleanedIDs = enabledPlaylistIDs.intersection(visiblePlaylistIDs)
        if cleanedIDs != enabledPlaylistIDs {
            enabledPlaylistIDs = cleanedIDs
            persistPreferences()
        }

        let selectedPlaylists = library.playlists.compactMap { playlist -> (String, [Song])? in
            guard cleanedIDs.contains(playlist.id) else { return nil }
            return (playlist.id, library.songs(forPlaylist: playlist.id).filteredPlayable())
        }
        let sources = sourcesStore.sources
        let desired = await Task.detached(priority: .utility) {
            Self.makeDesiredSongs(
                selectedPlaylists: selectedPlaylists,
                sources: sources
            )
        }.value
        guard !Task.isCancelled else { return }
        await worker.replaceDesiredSongs(desired)
    }

    private nonisolated static func makeDesiredSongs(
        selectedPlaylists: [(String, [Song])],
        sources: [MusicSource]
    ) -> [AlwaysDownloadDesiredSong] {
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var desiredBySongID: [String: AlwaysDownloadDesiredSong] = [:]
        for (playlistID, songs) in selectedPlaylists {
            for song in songs {
                guard let source = sourcesByID[song.sourceID],
                      source.isEnabled,
                      !source.isDeleted else { continue }
                let signature = contentSignature(
                    song: song,
                    source: source
                )
                if let existing = desiredBySongID[song.id] {
                    desiredBySongID[song.id] = AlwaysDownloadDesiredSong(
                        song: song,
                        playlistIDs: existing.playlistIDs.union([playlistID]),
                        contentSignature: signature
                    )
                } else {
                    desiredBySongID[song.id] = AlwaysDownloadDesiredSong(
                        song: song,
                        playlistIDs: [playlistID],
                        contentSignature: signature
                    )
                }
            }
        }
        return desiredBySongID.values.sorted { $0.song.id < $1.song.id }
    }

    private nonisolated static func contentSignature(
        song: Song,
        source: MusicSource?
    ) -> String {
        let components = [
            song.id,
            song.sourceID,
            song.filePath,
            song.fileFormat.rawValue,
            String(song.fileSize),
            song.revision ?? "",
            song.lastModified.map { String($0.timeIntervalSince1970) } ?? "",
            source?.type.rawValue ?? "",
            source?.host?.lowercased() ?? "",
            source?.port.map { String($0) } ?? "",
            source?.useSsl == true ? "1" : "0",
            source?.basePath ?? "",
            source?.username ?? "",
            source?.cloudAccountID ?? "",
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persistPreferences() {
        defaults.set(enabledPlaylistIDs.sorted(), forKey: Self.defaultsKey)
    }
}
