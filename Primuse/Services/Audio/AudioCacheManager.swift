import CryptoKit
import Foundation
import Observation
import PrimuseKit

struct AutomaticOfflinePinRequest: Sendable {
    let path: String
    let playlistIDs: Set<String>
    let expectedByteCount: Int64
}

struct AudioCachePathLease: Hashable, Sendable {
    fileprivate let id: UUID
}

enum AudioCacheTransferReservationApproval: Sendable, Equatable {
    case approved(Int64)
    case invalidLease
    case insufficientCapacity(available: Int64)
}

enum AudioCachePathFamily {
    static func relativePaths(for path: String) -> Set<String> {
        let partial = path + ".partial"
        let refresh = path + ".refresh"
        return [
            path,
            path + ".installing",
            partial,
            partial + CloudPlaybackSource.prewarmMarkerSuffix,
            path + ".offline",
            refresh,
            refresh + ".installing",
            refresh + ".offline",
        ]
    }
}

enum AudioCacheTransferCapacityPolicy {
    static func isSatisfied(
        currentSize: Int64,
        limitBytes: Int64,
        reservedBytes: Int64
    ) -> Bool {
        guard let target = AudioCacheLimitPolicy.evictionTarget(
            limitBytes: limitBytes,
            reserveBytes: reservedBytes
        ) else { return true }
        return currentSize <= target
    }
}

enum AutomaticOfflineArtifactPolicy {
    static func signature(
        sourceID: String,
        filePath: String,
        fileFormat: String,
        fileSize: Int64,
        revision: String?,
        lastModified: Date?,
        sourceIdentitySignature: String
    ) -> String {
        let components = [
            sourceID,
            filePath,
            fileFormat,
            String(fileSize),
            revision ?? "",
            lastModified.map { String($0.timeIntervalSince1970) } ?? "",
            sourceIdentitySignature,
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func provenanceIsTrusted(
        recordedArtifactSignature: String?,
        desiredArtifactSignature: String
    ) -> Bool {
        recordedArtifactSignature == desiredArtifactSignature
    }

    static func refreshDisposition(
        fileExists: Bool,
        recordedArtifactSignature: String?,
        desiredArtifactSignature: String,
        recordedSourceIdentitySignature: String?,
        desiredSourceIdentitySignature: String
    ) -> AutomaticOfflineRefreshDisposition {
        guard fileExists else { return .none }
        if provenanceIsTrusted(
            recordedArtifactSignature: recordedArtifactSignature,
            desiredArtifactSignature: desiredArtifactSignature
        ) {
            return .none
        }
        if recordedSourceIdentitySignature == desiredSourceIdentitySignature {
            return .preserveExisting
        }
        return .discardUntrusted
    }
}

enum AutomaticOfflineSourceCooldownPolicy {
    static func adjustedAttemptDate(
        current: Date,
        jobSourceID: String,
        failedSourceID: String,
        cooldownUntil: Date,
        failureKind: AutomaticOfflineFailureKind
    ) -> Date {
        guard failureKind.requiresSourceCooldown,
              jobSourceID == failedSourceID else { return current }
        return max(current, cooldownUntil)
    }
}

enum AutomaticOfflineDiskAdmissionPolicy {
    static func adjustedAvailableBytes(
        physicalAvailableBytes: Int64,
        refreshDisposition: AutomaticOfflineRefreshDisposition,
        recoverableArtifactBytes: Int64
    ) -> Int64 {
        guard refreshDisposition == .discardUntrusted else {
            return physicalAvailableBytes
        }
        let result = physicalAvailableBytes.addingReportingOverflow(
            max(0, recoverableArtifactBytes)
        )
        return result.overflow ? .max : result.partialValue
    }
}

enum AutomaticOfflineSongPolicy {
    static func supports(_ song: Song) -> Bool {
        song.isStreamDescriptor || song.fileSize > 0
    }
}

struct AutomaticOfflineJobSongSnapshot: Codable, Sendable {
    let id: String
    let title: String
    let fileFormat: AudioFormat
    let filePath: String
    let sourceID: String
    let fileSize: Int64

    init(_ song: Song) {
        id = song.id
        title = song.title
        fileFormat = song.fileFormat
        filePath = song.filePath
        sourceID = song.sourceID
        fileSize = song.fileSize
    }

    var materializedSong: Song {
        Song(
            id: id,
            title: title,
            fileFormat: fileFormat,
            filePath: filePath,
            sourceID: sourceID,
            fileSize: fileSize
        )
    }
}

struct AutomaticOfflineCompletionDeltaPayload: Codable, Sendable {
    let completedSignatures: [String: String]
    let artifactPath: String
    let artifactSignature: String
    let sourceIdentitySignature: String
    let sourceID: String
}

enum AutomaticOfflineArtifactIndex {
    static func key(path: String, signature: String) -> String {
        path + "\0" + signature
    }

    static func make(
        from desiredSongs: some Sequence<AlwaysDownloadDesiredSong>
    ) -> [String: [String]] {
        var songIDsByArtifact: [String: [String]] = [:]
        for desired in desiredSongs {
            songIDsByArtifact[
                key(path: desired.artifactPath, signature: desired.artifactSignature),
                default: []
            ].append(desired.song.id)
        }
        return songIDsByArtifact
    }
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
    private var automaticPlaylistProtectedPaths: Set<String> = []
    private var automaticPlaylistReconciliationGeneration = 0
    private var trackedFileSizes: [String: Int64] = [:]
    private var trackedFileModificationDates: [String: Date] = [:]
    private var trackedTotalSize: Int64 = 0
    private var leasedPathCounts: [String: Int] = [:]
    private var leasedPathsByID: [UUID: Set<String>] = [:]
    private var leasedCanonicalPathByID: [UUID: String] = [:]
    private var reservedBytesByLeaseID: [UUID: Int64] = [:]
    private var reservationUsesConfiguredCacheByLeaseID: [UUID: Bool] = [:]
    private var activeReservedBytes: Int64 = 0
    private var activeConfiguredCacheReservedBytes: Int64 = 0
    private var sourcePurgeGenerationByPrefix: [String: Int] = [:]
    private var completedSourcePurgeGenerationByPrefix: [String: Int] = [:]
    private let logURL: URL
    private let manifestURL: URL
    private let basePath: URL
    private let quarantineBasePath: URL
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

    private struct QuarantinedSourceCacheMetadata: Codable {
        var version = 1
        var sourceID: String
        var recordedSignature: String?
        var replacementSignature: String
        var quarantinedAt: Date
        var fileCount: Int
        var allocatedByteCount: Int64
        var accessLog: [String: Date]
        var offlineManifest: [String: OfflineManifestEntry]
    }

    private init() {
        let caches = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        basePath = caches.appendingPathComponent("primuse_audio_cache")
        quarantineBasePath = caches.appendingPathComponent("primuse_audio_cache_quarantine")
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
        refreshTrackedPathFamily(path)
        accessLog[path] = Date()
        schedulePersist()
    }

    func migrateEntry(from oldPath: String, to newPath: String, byteCount: Int64?) {
        ensureInitialized()
        refreshTrackedPathFamily(oldPath)
        refreshTrackedPathFamily(newPath)
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
        refreshTrackedPathFamily(path)
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
        refreshTrackedPathFamily(path)
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
        refreshTrackedPathFamily(path)
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
        _ requests: [AutomaticOfflinePinRequest],
        generation: Int,
        excludedPaths: Set<String> = []
    ) -> Set<String>? {
        ensureInitialized()
        guard generation >= automaticPlaylistReconciliationGeneration else { return nil }
        automaticPlaylistReconciliationGeneration = generation
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
        automaticPlaylistProtectedPaths = Set(
            desiredByPath.keys.flatMap { AudioCachePathFamily.relativePaths(for: $0) }
        )
        var manifestChanged = false
        var missingPaths = Set<String>()

        for path in Array(offlineManifest.keys) {
            guard var entry = offlineManifest[path] else { continue }
            let desiredOwners = excludedPaths.contains(path)
                ? []
                : (desiredByPath[path]?.playlistIDs ?? [])
            if entry.playlistIDs != desiredOwners {
                entry.playlistIDs = desiredOwners
                entry.pinnedAt = entry.isPinned ? (entry.pinnedAt ?? Date()) : nil
                offlineManifest[path] = entry
                manifestChanged = true
            }
        }

        for request in desiredByPath.values {
            guard !excludedPaths.contains(request.path) else {
                missingPaths.insert(request.path)
                continue
            }
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

    /// Returns only paths owned by at least one Always Download playlist.
    /// Manual pins are deliberately excluded: content-change invalidation may
    /// replace those normally, while a playlist-owned artifact must remain
    /// playable until its verified refresh is atomically installed.
    func automaticPlaylistPinnedRelativePaths(
        matching candidatePaths: Set<String>
    ) -> Set<String> {
        ensureInitialized()
        return Set(candidatePaths.filter { path in
            offlineManifest[path]?.playlistIDs.isEmpty == false
        })
    }

    func clearUnpinnedAccessEntries() {
        ensureInitialized()
        accessLog = accessLog.filter { path, _ in
            offlineManifest[path]?.isPinned == true
        }
        rebuildTrackedInventory(migrateAccessDates: false)
        schedulePersist()
    }

    func acquirePathFamilyLease(
        path: String,
        reserveBytes: Int64 = 0
    ) -> AudioCachePathLease? {
        ensureInitialized()
        guard !sourcePurgeGenerationByPrefix.keys.contains(where: { path.hasPrefix($0) }) else {
            return nil
        }
        let lease = AudioCachePathLease(id: UUID())
        let paths = AudioCachePathFamily.relativePaths(for: path)
        leasedPathsByID[lease.id] = paths
        leasedCanonicalPathByID[lease.id] = path
        for path in paths {
            leasedPathCounts[path, default: 0] += 1
        }
        let reservation = max(0, reserveBytes)
        reservedBytesByLeaseID[lease.id] = reservation
        reservationUsesConfiguredCacheByLeaseID[lease.id] = true
        let reservationResult = activeReservedBytes.addingReportingOverflow(reservation)
        activeReservedBytes = reservationResult.overflow ? .max : reservationResult.partialValue
        let configuredResult = activeConfiguredCacheReservedBytes
            .addingReportingOverflow(reservation)
        activeConfiguredCacheReservedBytes = configuredResult.overflow
            ? .max
            : configuredResult.partialValue
        return lease
    }

    func releasePathFamilyLease(_ lease: AudioCachePathLease) {
        ensureInitialized()
        guard let paths = leasedPathsByID.removeValue(forKey: lease.id) else { return }
        if let canonicalPath = leasedCanonicalPathByID.removeValue(forKey: lease.id) {
            refreshTrackedPathFamily(canonicalPath)
        }
        for path in paths {
            let count = max(0, (leasedPathCounts[path] ?? 1) - 1)
            leasedPathCounts[path] = count == 0 ? nil : count
        }
        let reservation = reservedBytesByLeaseID.removeValue(forKey: lease.id) ?? 0
        activeReservedBytes = max(0, activeReservedBytes - reservation)
        if reservationUsesConfiguredCacheByLeaseID.removeValue(forKey: lease.id) == true {
            activeConfiguredCacheReservedBytes = max(
                0,
                activeConfiguredCacheReservedBytes - reservation
            )
        }
    }

    /// Atomically upgrades a provisional path lease into a physical-disk
    /// transfer reservation. Every admission subtracts all other active
    /// reservations before preserving the safety headroom, so two concurrent
    /// downloads cannot both spend the same free bytes.
    func approveTransferReservation(
        _ lease: AudioCachePathLease,
        expectedSize: Int64,
        physicalAvailableBytes: Int64,
        minimumRequiredBytes: Int64,
        respectsConfiguredCacheLimit: Bool = true
    ) -> AudioCacheTransferReservationApproval {
        ensureInitialized()
        guard leasedPathsByID[lease.id] != nil,
              let previousReservation = reservedBytesByLeaseID[lease.id],
              let previousUsesConfiguredCache =
                  reservationUsesConfiguredCacheByLeaseID[lease.id] else {
            return .invalidLease
        }
        let otherReservedBytes = max(0, activeReservedBytes - previousReservation)
        let previousConfiguredReservation = previousUsesConfiguredCache
            ? previousReservation
            : 0
        let otherConfiguredCacheReservedBytes = max(
            0,
            activeConfiguredCacheReservedBytes - previousConfiguredReservation
        )
        let maximum = OfflineTransferSizePolicy.maximumAllowedBytes(
            expectedSize: expectedSize,
            cacheLimitBytes: respectsConfiguredCacheLimit
                ? cacheLimitBytes()
                : AudioCacheLimitPolicy.unlimitedBytes,
            availableDiskBytes: max(0, physicalAvailableBytes),
            otherReservedBytes: otherReservedBytes,
            otherConfiguredCacheReservedBytes: otherConfiguredCacheReservedBytes
        )
        guard previousReservation == 0
                || previousUsesConfiguredCache == respectsConfiguredCacheLimit else {
            return .invalidLease
        }
        // Re-admission of an already-live playback lease must be monotonic.
        // A failed larger request cannot shrink the reservation protecting the
        // current sparse writer, and bytes already written may have reduced the
        // subsequently reported free-space value without invalidating the
        // reservation granted before those writes began.
        let approvedReservation = max(previousReservation, maximum)
        guard approvedReservation > 0,
              approvedReservation >= max(1, minimumRequiredBytes) else {
            return .insufficientCapacity(available: approvedReservation)
        }

        activeReservedBytes = otherReservedBytes
        reservedBytesByLeaseID[lease.id] = approvedReservation
        reservationUsesConfiguredCacheByLeaseID[lease.id] = respectsConfiguredCacheLimit
        let updated = activeReservedBytes.addingReportingOverflow(approvedReservation)
        activeReservedBytes = updated.overflow ? .max : updated.partialValue
        activeConfiguredCacheReservedBytes = otherConfiguredCacheReservedBytes
        if respectsConfiguredCacheLimit {
            let configured = activeConfiguredCacheReservedBytes
                .addingReportingOverflow(approvedReservation)
            activeConfiguredCacheReservedBytes = configured.overflow
                ? .max
                : configured.partialValue
        }
        return .approved(approvedReservation)
    }

    /// Stops charging an existing playback reservation against the configured
    /// cache budget while preserving its full physical-disk reservation. This
    /// is used when automatic caching is disabled during an active sparse
    /// stream: playback may continue in temporary storage, but the file must
    /// no longer be eligible for persistent-cache promotion.
    func downgradeTransferReservationToPhysicalOnly(
        _ lease: AudioCachePathLease
    ) -> Bool {
        ensureInitialized()
        guard leasedPathsByID[lease.id] != nil,
              let reservation = reservedBytesByLeaseID[lease.id],
              let usesConfiguredCache =
                  reservationUsesConfiguredCacheByLeaseID[lease.id] else {
            return false
        }
        guard usesConfiguredCache else { return true }
        activeConfiguredCacheReservedBytes = max(
            0,
            activeConfiguredCacheReservedBytes - reservation
        )
        reservationUsesConfiguredCacheByLeaseID[lease.id] = false
        return true
    }

    func isPathFamilyLeased(path: String) -> Bool {
        ensureInitialized()
        return AudioCachePathFamily.relativePaths(for: path).contains {
            (leasedPathCounts[$0] ?? 0) > 0
        }
    }

    func hasLeasedPath(forSourcePrefix prefix: String) -> Bool {
        ensureInitialized()
        return leasedCanonicalPathByID.values.contains { $0.hasPrefix(prefix) }
    }

    func beginSourcePurge(prefix: String, generation: Int) -> Bool {
        ensureInitialized()
        guard generation > (completedSourcePurgeGenerationByPrefix[prefix] ?? .min),
              generation >= (sourcePurgeGenerationByPrefix[prefix] ?? .min) else {
            return false
        }
        sourcePurgeGenerationByPrefix[prefix] = generation
        return !leasedCanonicalPathByID.values.contains { $0.hasPrefix(prefix) }
    }

    func sourcePurgeCanProceed(prefix: String, generation: Int) -> Bool {
        ensureInitialized()
        guard sourcePurgeGenerationByPrefix[prefix] == generation else { return false }
        return !leasedCanonicalPathByID.values.contains { $0.hasPrefix(prefix) }
    }

    func purgeSourceCacheDirectoryIfReady(
        prefix: String,
        generation: Int
    ) -> Bool {
        ensureInitialized()
        guard sourcePurgeGenerationByPrefix[prefix] == generation,
              !leasedCanonicalPathByID.values.contains(where: { $0.hasPrefix(prefix) }) else {
            return false
        }
        let sourceRelativePath = prefix.hasSuffix("/")
            ? String(prefix.dropLast())
            : prefix
        let directory = basePath.appendingPathComponent(sourceRelativePath).standardizedFileURL
        let basePrefix = basePath.standardizedFileURL.path + "/"
        guard directory.path.hasPrefix(basePrefix) else { return false }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            return false
        }

        let accessKeys = accessLog.keys.filter { $0.hasPrefix(prefix) }
        for key in accessKeys { accessLog[key] = nil }
        let manifestKeys = offlineManifest.keys.filter { $0.hasPrefix(prefix) }
        for key in manifestKeys { offlineManifest[key] = nil }
        let trackedKeys = trackedFileSizes.keys.filter { $0.hasPrefix(prefix) }
        for key in trackedKeys { removeTrackedPath(key) }
        automaticPlaylistProtectedPaths = automaticPlaylistProtectedPaths.filter {
            !$0.hasPrefix(prefix)
        }
        if !accessKeys.isEmpty { schedulePersist() }
        if !manifestKeys.isEmpty { scheduleManifestPersist() }
        return true
    }

    /// Moves bytes that belong to a previous source security scope out of the
    /// active cache namespace. The move stays on the same volume and preserves
    /// the old access/pin metadata, so an account or endpoint change cannot
    /// silently destroy a large offline library.
    func quarantineSourceCacheDirectoryIfReady(
        prefix: String,
        generation: Int,
        recordedSignature: String?,
        replacementSignature: String
    ) -> Bool {
        ensureInitialized()
        guard sourcePurgeGenerationByPrefix[prefix] == generation,
              !leasedCanonicalPathByID.values.contains(where: { $0.hasPrefix(prefix) }) else {
            return false
        }

        let sourceID = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        guard !sourceID.isEmpty,
              sourceID != ".",
              sourceID != "..",
              !sourceID.contains("/") else {
            return false
        }
        let sourceDirectory = basePath.appendingPathComponent(sourceID).standardizedFileURL
        let basePrefix = basePath.standardizedFileURL.path + "/"
        guard sourceDirectory.path.hasPrefix(basePrefix) else { return false }

        let accessEntries = accessLog.filter { $0.key.hasPrefix(prefix) }
        let manifestEntries = offlineManifest.filter { $0.key.hasPrefix(prefix) }
        let trackedEntries = trackedFileSizes.filter { $0.key.hasPrefix(prefix) }
        let sourceDirectoryExists = FileManager.default.fileExists(
            atPath: sourceDirectory.path
        )

        if sourceDirectoryExists || !accessEntries.isEmpty || !manifestEntries.isEmpty {
            let recordDirectory = quarantineBasePath
                .appendingPathComponent(sourceID, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let payloadDirectory = recordDirectory.appendingPathComponent(
                "payload",
                isDirectory: true
            )
            let metadata = QuarantinedSourceCacheMetadata(
                sourceID: sourceID,
                recordedSignature: recordedSignature,
                replacementSignature: replacementSignature,
                quarantinedAt: Date(),
                fileCount: trackedEntries.count,
                allocatedByteCount: trackedEntries.values.reduce(0) { partial, size in
                    let result = partial.addingReportingOverflow(max(0, size))
                    return result.overflow ? .max : result.partialValue
                },
                accessLog: accessEntries,
                offlineManifest: manifestEntries
            )
            do {
                try FileManager.default.createDirectory(
                    at: recordDirectory,
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let metadataData = try encoder.encode(metadata)
                try metadataData.write(
                    to: recordDirectory.appendingPathComponent("metadata.json"),
                    options: .atomic
                )
                if sourceDirectoryExists {
                    try FileManager.default.moveItem(
                        at: sourceDirectory,
                        to: payloadDirectory
                    )
                }
            } catch {
                // The canonical source directory is moved last. A failure before
                // that point leaves active bytes untouched; a failure after a
                // successful move still leaves them in the recorded quarantine.
                if FileManager.default.fileExists(atPath: sourceDirectory.path) {
                    try? FileManager.default.removeItem(at: recordDirectory)
                }
                plog("⚠️ Audio cache quarantine failed source=\(sourceID.prefix(8)): \(error.localizedDescription)")
                return false
            }
        }

        for key in accessEntries.keys { accessLog[key] = nil }
        for key in manifestEntries.keys { offlineManifest[key] = nil }
        for key in trackedEntries.keys { removeTrackedPath(key) }
        automaticPlaylistProtectedPaths = automaticPlaylistProtectedPaths.filter {
            !$0.hasPrefix(prefix)
        }
        if !accessEntries.isEmpty { persistNow() }
        if !manifestEntries.isEmpty { persistManifestNow() }
        plog(
            "🛡️ Audio cache quarantined source=\(sourceID.prefix(8)) "
                + "files=\(trackedEntries.count)"
        )
        return true
    }

    func endSourcePurge(prefix: String, generation: Int) {
        ensureInitialized()
        completedSourcePurgeGenerationByPrefix[prefix] = max(
            completedSourcePurgeGenerationByPrefix[prefix] ?? .min,
            generation
        )
        if let activeGeneration = sourcePurgeGenerationByPrefix[prefix],
           activeGeneration <= generation {
            sourcePurgeGenerationByPrefix.removeValue(forKey: prefix)
        }
    }

    func pathFamilyHasOtherLeases(
        path: String,
        excluding lease: AudioCachePathLease
    ) -> Bool {
        ensureInitialized()
        guard leasedCanonicalPathByID[lease.id] == path,
              let ownedPaths = leasedPathsByID[lease.id] else { return true }
        return ownedPaths.contains { (leasedPathCounts[$0] ?? 0) > 1 }
    }

    func refreshPathFamily(path: String) {
        ensureInitialized()
        refreshTrackedPathFamily(path)
    }

    /// Evict oldest files until there is room for `reserveBytes` additional data.
    ///
    /// 之前的版本只看 `accessLog` 的文件 — 但 `.partial` 半成品 (Range
    /// streaming 中途没下完, 或者只 prewarm 的 head+tail) 永远不进
    /// accessLog (因为 recordAccess 只在完整 rename 后调)。结果 LRU
    /// 看不见 .partial, 完整文件被压在 2GB 但 .partial 无限堆 —— 用户
    /// 实际见到 5GB+ 缓存。
    ///
    /// Startup builds one inventory. Normal transfers then update only their
    /// path family, keeping the common under-limit check O(1) even for a large
    /// always-download queue.
    @discardableResult
    func evictIfNeeded(reserveBytes: Int64) -> Bool {
        ensureInitialized()
        let currentSize = trackedTotalSize
        let combinedReservation: Int64
        let reservationResult = activeConfiguredCacheReservedBytes
            .addingReportingOverflow(max(0, reserveBytes))
        combinedReservation = reservationResult.overflow ? .max : reservationResult.partialValue
        guard let target = AudioCacheLimitPolicy.evictionTarget(
            limitBytes: cacheLimitBytes(),
            reserveBytes: combinedReservation
        ) else { return true }

        guard currentSize > target else { return true }

        struct EvictCandidate { let url: URL; let relativePath: String; let size: Int64; let lastUsed: Date }
        var candidates: [EvictCandidate] = []
        let protectedPaths = protectedRelativePaths()
        let activeStreamingPaths = activeStreamingRelativePaths()
        candidates.reserveCapacity(trackedFileSizes.count)
        for (relative, size) in trackedFileSizes where size > 0 {
            guard !protectedPaths.contains(relative),
                  !activeStreamingPaths.contains(relative),
                  (leasedPathCounts[relative] ?? 0) == 0 else { continue }
            candidates.append(EvictCandidate(
                url: basePath.appendingPathComponent(relative),
                relativePath: relative,
                size: size,
                lastUsed: accessLog[relative]
                    ?? trackedFileModificationDates[relative]
                    ?? .distantPast
            ))
        }

        // 最旧的优先 evict
        candidates.sort { $0.lastUsed < $1.lastUsed }
        var freed: Int64 = 0
        let needed = currentSize - target
        for cand in candidates {
            if freed >= needed { break }
            // Playback registration and transfer leases can change after the
            // candidate snapshot. Recheck immediately before the destructive
            // operation so an active path family cannot be evicted.
            guard !protectedPaths.contains(cand.relativePath),
                  !activeStreamingRelativePaths().contains(cand.relativePath),
                  (leasedPathCounts[cand.relativePath] ?? 0) == 0 else { continue }
            do {
                try FileManager.default.removeItem(at: cand.url)
                let removedSize = trackedFileSizes.removeValue(forKey: cand.relativePath) ?? cand.size
                trackedFileModificationDates.removeValue(forKey: cand.relativePath)
                trackedTotalSize = max(0, trackedTotalSize - removedSize)
                freed += removedSize
                accessLog[cand.relativePath] = nil
            } catch {
                plog("⚠️ evictIfNeeded: failed to remove \(cand.relativePath): \(error.localizedDescription)")
            }
        }
        plog("🧹 evictIfNeeded: freed \(freed / 1024 / 1024)MB / needed \(needed / 1024 / 1024)MB")

        schedulePersist()
        return AudioCacheTransferCapacityPolicy.isSatisfied(
            currentSize: trackedTotalSize,
            limitBytes: cacheLimitBytes(),
            reservedBytes: combinedReservation
        )
    }

    func totalCacheSize() -> Int64 {
        ensureInitialized()
        return trackedTotalSize
    }

    /// Remove a single cache entry by its relative path.
    func removeEntry(path: String) {
        ensureInitialized()
        let fileURL = basePath.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: fileURL)
        for familyPath in AudioCachePathFamily.relativePaths(for: path) {
            removeTrackedPath(familyPath)
        }
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
        let trackedKeys = trackedFileSizes.keys.filter { key in
            prefixes.contains { key.hasPrefix($0) }
        }
        for key in trackedKeys { removeTrackedPath(key) }
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
            for familyPath in AudioCachePathFamily.relativePaths(for: path) {
                removeTrackedPath(familyPath)
            }
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
        rebuildTrackedInventory(migrateAccessDates: true)
    }

    private func rebuildTrackedInventory(migrateAccessDates: Bool) {
        trackedFileSizes.removeAll(keepingCapacity: true)
        trackedFileModificationDates.removeAll(keepingCapacity: true)
        trackedTotalSize = 0
        guard let enumerator = FileManager.default.enumerator(
            at: basePath,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return }
        var changed = false
        let pathResolver = AudioCachePathResolver(root: basePath)
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey,
                .isRegularFileKey,
            ]), values.isRegularFile == true else { continue }
            guard let relative = pathResolver.relativePath(for: fileURL) else { continue }
            let allocatedSize = Int64(values.totalFileAllocatedSize ?? 0)
            let previousSize = trackedFileSizes.updateValue(allocatedSize, forKey: relative) ?? 0
            trackedFileModificationDates[relative] = values.contentModificationDate ?? Date()
            trackedTotalSize += allocatedSize - previousSize
            if migrateAccessDates, accessLog[relative] == nil {
                let modified = values.contentModificationDate ?? Date()
                accessLog[relative] = modified
                changed = true
            }
        }
        if changed { persistNow() }
    }

    private func refreshTrackedPathFamily(_ path: String) {
        for relativePath in AudioCachePathFamily.relativePaths(for: path) {
            refreshTrackedPath(relativePath)
        }
    }

    private func refreshTrackedPath(_ relativePath: String) {
        let url = basePath.appendingPathComponent(relativePath)
        guard let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .totalFileAllocatedSizeKey,
            .isRegularFileKey,
        ]), values.isRegularFile == true else {
            removeTrackedPath(relativePath)
            return
        }
        let newSize = Int64(values.totalFileAllocatedSize ?? 0)
        let oldSize = trackedFileSizes[relativePath] ?? 0
        trackedFileSizes[relativePath] = newSize
        trackedFileModificationDates[relativePath] = values.contentModificationDate ?? Date()
        trackedTotalSize = max(0, trackedTotalSize - oldSize + newSize)
    }

    private func removeTrackedPath(_ relativePath: String) {
        trackedTotalSize = max(
            0,
            trackedTotalSize - (trackedFileSizes.removeValue(forKey: relativePath) ?? 0)
        )
        trackedFileModificationDates.removeValue(forKey: relativePath)
    }

    private func protectedRelativePaths() -> Set<String> {
        var paths = automaticPlaylistProtectedPaths
        for (path, entry) in offlineManifest where entry.isPinned {
            paths.formUnion(AudioCachePathFamily.relativePaths(for: path))
        }
        return paths
    }

    private func activeStreamingRelativePaths() -> Set<String> {
        let pathResolver = AudioCachePathResolver(root: basePath)
        var relativePaths = Set<String>()
        for path in CloudPlaybackSource.activeSessionPaths() {
            guard var relative = pathResolver.relativePath(
                for: URL(fileURLWithPath: path)
            ) else { continue }
            if relative.hasSuffix(".partial") {
                relative.removeLast(".partial".count)
            }
            relativePaths.formUnion(AudioCachePathFamily.relativePaths(for: relative))
        }
        return relativePaths
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
        var song: AutomaticOfflineJobSongSnapshot
        var playlistIDs: Set<String>
        var contentSignature: String
        var forceRedownload: Bool
        var attemptCount: Int
        var nextAttemptAt: Date
        var enqueuedAt: Date
        var artifactPath: String? = nil
        var artifactSignature: String? = nil
        var refreshDisposition: AutomaticOfflineRefreshDisposition? = nil
        var refreshPrepared: Bool? = nil
    }

    private struct Journal: Codable, Sendable {
        var jobs: [String: Job] = [:]
        var completedSignatures: [String: String] = [:]
        /// Optional keeps journals written by the first queue schema
        /// decodable. This records the provenance of complete and partial
        /// automatic transfers even while their playlist is disabled.
        var lastKnownSignatures: [String: String]? = nil
        /// Tags a source-wide retry deadline with the identity that created it,
        /// so changing account/endpoint clears stale cooldown. This is not file
        /// provenance; only the artifact maps below can authorize adoption.
        var sourceIdentitySignatures: [String: String]? = nil
        /// Provenance is earned only by a successful transfer of this exact
        /// physical artifact. A successful song must never make every file in
        /// the source/account namespace trustworthy.
        var artifactProvenanceSignatures: [String: String]? = nil
        /// Kept separately so a content revision from the same trusted account
        /// can preserve its old playable bytes while an account/endpoint
        /// switch must discard them before transfer.
        var artifactSourceIdentitySignatures: [String: String]? = nil
        /// A terminal login failure applies to the source, not one song. New
        /// jobs inherit this durable cooldown instead of retrying credentials
        /// once per playlist member.
        var sourceRetryAfter: [String: Date]? = nil
        /// Deltas at or below this sequence are already represented in this
        /// full snapshot. Replaying an old append log after an atomic snapshot
        /// write is therefore idempotent even if truncation was interrupted.
        var lastAppliedDeltaSequence: UInt64? = nil
    }

    private struct JournalDelta: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case jobUpdate
            case completion
        }

        let sequence: UInt64
        let kind: Kind
        let expectedContentSignature: String?
        let job: Job?
        let sourceCooldownID: String?
        let sourceCooldownUntil: Date?
        let completion: AutomaticOfflineCompletionDeltaPayload?
    }

    private struct ResourceSnapshot: Sendable {
        let hasDeterminedNetwork: Bool
        let isReachable: Bool
        let isExpensive: Bool
        let isConstrained: Bool
        let isPlaybackActive: Bool
        let isPlaybackBuffering: Bool
        let isLowPowerModeEnabled: Bool
        let hasSeriousThermalPressure: Bool
    }

    private struct JobQueueEntry: Sendable {
        let songID: String
        let nextAttemptAt: Date
        let enqueuedAt: Date
    }

    private let sourceManager: SourceManager
    private let player: AudioPlayerService
    private let journalURL: URL
    private var journal = Journal()
    private var desiredBySongID: [String: AlwaysDownloadDesiredSong] = [:]
    private var desiredSongIDsByArtifact: [String: [String]] = [:]
    private var applicationIsActive = false
    private var playbackIsActive = false
    private var playbackIsBuffering = false
    private var resourceConditionsAllowTransfers = false
    private var didLoadJournal = false
    private var runner: Task<Void, Never>?
    private var runnerGeneration = UUID()
    private var jobHeap: [JobQueueEntry] = []
    private var journalMutationCountSincePersist = 0
    private var desiredReplacementGeneration = 0
    private var nextJournalDeltaSequence: UInt64 = 1

    private var journalDeltaURL: URL {
        journalURL.appendingPathExtension("delta")
    }

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
        playbackIsActive: Bool,
        playbackIsBuffering: Bool,
        resourceConditionsAllowTransfers: Bool
    ) {
        loadJournalIfNeeded()
        self.applicationIsActive = applicationIsActive
        self.playbackIsActive = playbackIsActive
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
        playbackIsActive: Bool,
        playbackIsBuffering: Bool,
        allowTransfers: Bool
    ) async {
        self.playbackIsActive = playbackIsActive
        self.playbackIsBuffering = playbackIsBuffering
        resourceConditionsAllowTransfers = allowTransfers
        if playbackIsActive || playbackIsBuffering || !allowTransfers {
            await cancelRunner()
        } else {
            scheduleRunner()
        }
    }

    func replaceDesiredSongs(_ desiredSongs: [AlwaysDownloadDesiredSong]) async {
        loadJournalIfNeeded()
        desiredReplacementGeneration += 1
        let replacementGeneration = desiredReplacementGeneration
        await cancelRunner()
        guard !Task.isCancelled,
              desiredReplacementGeneration == replacementGeneration else { return }

        var nextDesired: [String: AlwaysDownloadDesiredSong] = [:]
        nextDesired.reserveCapacity(desiredSongs.count)
        for desired in desiredSongs {
            if let existing = nextDesired[desired.song.id] {
                nextDesired[desired.song.id] = AlwaysDownloadDesiredSong(
                    song: desired.song,
                    playlistIDs: existing.playlistIDs.union(desired.playlistIDs),
                    contentSignature: desired.contentSignature,
                    sourceIdentitySignature: desired.sourceIdentitySignature,
                    artifactPath: desired.artifactPath,
                    artifactSignature: desired.artifactSignature
                )
            } else {
                nextDesired[desired.song.id] = desired
            }
        }
        let desiredValues = Array(nextDesired.values)
        let nextDesiredSongIDsByArtifact = AutomaticOfflineArtifactIndex.make(
            from: desiredValues
        )
        let knownSourceIdentities = journal.sourceIdentitySignatures ?? [:]
        let knownArtifactProvenance = journal.artifactProvenanceSignatures ?? [:]
        let knownArtifactSourceIdentities = journal.artifactSourceIdentitySignatures ?? [:]
        var preflightDispositions: [String: AutomaticOfflineRefreshDisposition] = [:]
        preflightDispositions.reserveCapacity(desiredValues.count)
        for desired in desiredValues {
            let disposition = AutomaticOfflineArtifactPolicy.refreshDisposition(
                fileExists: true,
                recordedArtifactSignature: knownArtifactProvenance[desired.artifactPath],
                desiredArtifactSignature: desired.artifactSignature,
                recordedSourceIdentitySignature: knownArtifactSourceIdentities[desired.artifactPath],
                desiredSourceIdentitySignature: desired.sourceIdentitySignature
            )
            preflightDispositions[desired.artifactPath] = AutomaticOfflineRefreshDisposition.strongest(
                preflightDispositions[desired.artifactPath] ?? .none,
                disposition
            )
        }
        guard let excludedArtifactPaths = await sourceManager.reconcileAutomaticOfflineProvenance(
            preflightDispositions,
            generation: replacementGeneration
        ), !Task.isCancelled,
           desiredReplacementGeneration == replacementGeneration else { return }
        guard let missingSongIDs = await sourceManager.reconcileAutomaticPlaylistPins(
            desiredValues,
            generation: replacementGeneration,
            excludedArtifactPaths: excludedArtifactPaths
        ), !Task.isCancelled,
           desiredReplacementGeneration == replacementGeneration else { return }
        desiredBySongID = nextDesired
        desiredSongIDsByArtifact = nextDesiredSongIDsByArtifact
        var knownSignatures = journal.lastKnownSignatures ?? [:]
        for (songID, job) in journal.jobs
        where (job.refreshDisposition ?? (job.forceRedownload ? .discardUntrusted : .none)) == .none {
            knownSignatures[songID] = job.contentSignature
        }
        let desiredSignatures = nextDesired.mapValues(\.contentSignature)

        var sourceRetryAfter = journal.sourceRetryAfter ?? [:]
        for desired in desiredValues
        where knownSourceIdentities[desired.song.sourceID] != nil
            && knownSourceIdentities[desired.song.sourceID] != desired.sourceIdentitySignature {
            sourceRetryAfter.removeValue(forKey: desired.song.sourceID)
        }
        // Trust is earned per physical artifact, never by another successful
        // file from the same source/account namespace.
        for desired in desiredValues
        where !missingSongIDs.contains(desired.song.id)
            && journal.completedSignatures[desired.song.id] == nil
            && (journal.jobs[desired.song.id].map {
                $0.refreshDisposition ?? ($0.forceRedownload ? .discardUntrusted : .none)
            } ?? .none) == .none
            && AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
                desiredSignature: desired.contentSignature,
                completedSignature: nil,
                lastKnownSignature: knownSignatures[desired.song.id],
                provenanceIsTrusted: AutomaticOfflineArtifactPolicy.provenanceIsTrusted(
                    recordedArtifactSignature: knownArtifactProvenance[desired.artifactPath],
                    desiredArtifactSignature: desired.artifactSignature
                )
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
            let requestedDisposition = preflightDispositions[desired.artifactPath] == .discardUntrusted
                ? .discardUntrusted
                : AutomaticOfflineArtifactPolicy.refreshDisposition(
                    fileExists: !missingSongIDs.contains(songID),
                    recordedArtifactSignature: knownArtifactProvenance[desired.artifactPath],
                    desiredArtifactSignature: desired.artifactSignature,
                    recordedSourceIdentitySignature: knownArtifactSourceIdentities[desired.artifactPath],
                    desiredSourceIdentitySignature: desired.sourceIdentitySignature
                )
            if var existing = journal.jobs[songID],
               existing.contentSignature == desired.contentSignature {
                existing.song = AutomaticOfflineJobSongSnapshot(desired.song)
                existing.playlistIDs = desired.playlistIDs
                existing.artifactPath = desired.artifactPath
                existing.artifactSignature = desired.artifactSignature
                let existingDisposition = existing.refreshDisposition
                    ?? (existing.forceRedownload ? .discardUntrusted : .none)
                let disposition = AutomaticOfflineRefreshDisposition.strongest(
                    existingDisposition,
                    requestedDisposition
                )
                if disposition != existingDisposition {
                    existing.refreshPrepared = false
                }
                existing.refreshDisposition = disposition
                existing.forceRedownload = disposition != .none
                    && existing.refreshPrepared != true
                if let retryAfter = sourceRetryAfter[desired.song.sourceID] {
                    existing.nextAttemptAt = max(existing.nextAttemptAt, retryAfter)
                }
                journal.jobs[songID] = existing
            } else {
                journal.jobs[songID] = Job(
                    song: AutomaticOfflineJobSongSnapshot(desired.song),
                    playlistIDs: desired.playlistIDs,
                    contentSignature: desired.contentSignature,
                    forceRedownload: requestedDisposition != .none,
                    attemptCount: 0,
                    nextAttemptAt: max(
                        now,
                        sourceRetryAfter[desired.song.sourceID] ?? .distantPast
                    ),
                    enqueuedAt: now,
                    artifactPath: desired.artifactPath,
                    artifactSignature: desired.artifactSignature,
                    refreshDisposition: requestedDisposition,
                    refreshPrepared: false
                )
            }
        }
        journal.lastKnownSignatures = knownSignatures
        var sourceIdentities = journal.sourceIdentitySignatures ?? [:]
        for desired in desiredValues {
            sourceIdentities[desired.song.sourceID] = desired.sourceIdentitySignature
        }
        journal.sourceIdentitySignatures = sourceIdentities
        journal.sourceRetryAfter = sourceRetryAfter
        let preservingArtifactPaths = Set(journal.jobs.compactMap { songID, job -> String? in
            let disposition = job.refreshDisposition
                ?? (job.forceRedownload ? .discardUntrusted : .none)
            guard disposition == .preserveExisting else { return nil }
            return job.artifactPath ?? nextDesired[songID]?.artifactPath
        })
        guard await sourceManager.reconcileAutomaticRefreshProtections(
            preservingArtifactPaths,
            generation: replacementGeneration
        ), !Task.isCancelled,
              desiredReplacementGeneration == replacementGeneration else { return }
        persistJournal(force: true)
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
            song: AutomaticOfflineJobSongSnapshot(desired.song),
            playlistIDs: desired.playlistIDs,
            contentSignature: desired.contentSignature,
            forceRedownload: false,
            attemptCount: 0,
            nextAttemptAt: now,
            enqueuedAt: now,
            artifactPath: desired.artifactPath,
            artifactSignature: desired.artifactSignature,
            refreshDisposition: AutomaticOfflineRefreshDisposition.none,
            refreshPrepared: false
        )
        persistJournal(force: true)
        await restartRunner()
    }

    private func cancelRunner() async {
        let cancellationGeneration = UUID()
        runnerGeneration = cancellationGeneration
        let previousRunner = runner
        runner = nil
        previousRunner?.cancel()
        // Do not wait for a connector that may take time to observe
        // cancellation. The old runner is fenced by `runnerGeneration` after
        // every suspension point, while a replacement reconciliation can
        // immediately isolate paths belonging to a changed account/scope.
        persistJournal(force: true)
    }

    private func restartRunner() async {
        await cancelRunner()
        scheduleRunner()
    }

    private func scheduleRunner() {
        guard runner == nil,
              applicationIsActive,
              !playbackIsActive,
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
            persistJournal(force: true)
            if runnerGeneration == generation {
                runner = nil
            }
        }
        rebuildJobHeap()
        while !Task.isCancelled,
              runnerGeneration == generation,
              applicationIsActive,
              !playbackIsActive,
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
            let refreshDisposition = job.refreshDisposition
                ?? (job.forceRedownload ? .discardUntrusted : .none)
            let recoverableArtifactBytes = await sourceManager.automaticOfflineRecoverableBytes(
                song: job.song.materializedSong,
                refreshDisposition: refreshDisposition
            )
            guard !Task.isCancelled,
                  runnerGeneration == generation else { return }
            let eligibility = AutomaticOfflineDownloadPolicy.eligibility(
                applicationIsActive: applicationIsActive,
                hasDeterminedNetwork: resources.hasDeterminedNetwork,
                isReachable: resources.isReachable,
                isExpensive: resources.isExpensive,
                isConstrained: resources.isConstrained,
                isLowPowerModeEnabled: resources.isLowPowerModeEnabled,
                hasSeriousThermalPressure: resources.hasSeriousThermalPressure,
                availableDiskBytes: AutomaticOfflineDiskAdmissionPolicy.adjustedAvailableBytes(
                    physicalAvailableBytes: Self.availableDiskBytes(),
                    refreshDisposition: refreshDisposition,
                    recoverableArtifactBytes: recoverableArtifactBytes
                ),
                expectedDownloadBytes: job.song.fileSize,
                isPlaybackActive: resources.isPlaybackActive,
                isPlaybackBuffering: resources.isPlaybackBuffering
            )
            guard eligibility == .allowed else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }

            removeJobHeapRoot()

            let needsRefreshPreparation = refreshDisposition != .none
                && job.refreshPrepared != true
            let prepared = await sourceManager.prepareAutomaticOfflineDownload(
                song: job.song.materializedSong,
                forceRedownload: needsRefreshPreparation,
                refreshDisposition: refreshDisposition
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
                insertIntoJobHeap(deferred)
                persistJobDelta(deferred)
                continue
            }
            if needsRefreshPreparation {
                var preparedJob = journal.jobs[job.song.id] ?? job
                preparedJob.forceRedownload = false
                preparedJob.refreshDisposition = refreshDisposition
                preparedJob.refreshPrepared = true
                journal.jobs[job.song.id] = preparedJob
                journal.completedSignatures.removeValue(forKey: job.song.id)
                persistJobDelta(preparedJob)
            }

            let result = await sourceManager.downloadAutomaticallyForOffline(
                song: job.song.materializedSong,
                playlistIDs: job.playlistIDs,
                refreshDisposition: refreshDisposition,
                artifactSignature: job.artifactSignature
                    ?? currentDesired.artifactSignature
            )
            guard !Task.isCancelled,
                  runnerGeneration == generation,
                  let currentDesired = desiredBySongID[job.song.id],
                  currentDesired.contentSignature == job.contentSignature else {
                return
            }

            switch result {
            case .completed:
                journal.sourceRetryAfter?.removeValue(forKey: job.song.sourceID)
                var knownSignatures = journal.lastKnownSignatures ?? [:]
                let artifactPath = job.artifactPath
                    ?? currentDesired.artifactPath
                let artifactSignature = job.artifactSignature
                    ?? currentDesired.artifactSignature
                let siblingIDs = desiredSongIDsByArtifact[
                    AutomaticOfflineArtifactIndex.key(
                        path: artifactPath,
                        signature: artifactSignature
                    )
                ] ?? [job.song.id]
                var completedSignatures: [String: String] = [:]
                completedSignatures.reserveCapacity(siblingIDs.count)
                for songID in siblingIDs {
                    guard let sibling = desiredBySongID[songID] else { continue }
                    journal.completedSignatures[songID] = sibling.contentSignature
                    knownSignatures[songID] = sibling.contentSignature
                    journal.jobs.removeValue(forKey: songID)
                    completedSignatures[songID] = sibling.contentSignature
                }
                journal.lastKnownSignatures = knownSignatures
                var artifactProvenance = journal.artifactProvenanceSignatures ?? [:]
                artifactProvenance[artifactPath] = artifactSignature
                journal.artifactProvenanceSignatures = artifactProvenance
                var artifactSourceIdentities = journal.artifactSourceIdentitySignatures ?? [:]
                artifactSourceIdentities[artifactPath] = currentDesired.sourceIdentitySignature
                journal.artifactSourceIdentitySignatures = artifactSourceIdentities
                persistCompletionDelta(AutomaticOfflineCompletionDeltaPayload(
                    completedSignatures: completedSignatures,
                    artifactPath: artifactPath,
                    artifactSignature: artifactSignature,
                    sourceIdentitySignature: currentDesired.sourceIdentitySignature,
                    sourceID: job.song.sourceID
                ))
            case .cancelled:
                return
            case .failed(let failureKind, _):
                var retry = journal.jobs[job.song.id] ?? job
                retry.attemptCount = min(retry.attemptCount + 1, 16)
                let authenticationLike = failureKind == .authentication
                    || failureKind == .sourceAccessDenied
                var retryDelay = AutomaticOfflineDownloadPolicy.retryDelay(
                    attemptCount: retry.attemptCount,
                    authenticationRequired: authenticationLike
                )
                if failureKind == .rateLimited {
                    retryDelay = max(retryDelay, 300)
                }
                retry.nextAttemptAt = Date().addingTimeInterval(retryDelay)
                journal.jobs[job.song.id] = retry
                if failureKind.requiresSourceCooldown {
                    var sourceRetryAfter = journal.sourceRetryAfter ?? [:]
                    sourceRetryAfter[job.song.sourceID] = retry.nextAttemptAt
                    journal.sourceRetryAfter = sourceRetryAfter
                    for (songID, var queuedJob) in journal.jobs
                    where queuedJob.song.sourceID == job.song.sourceID {
                        queuedJob.nextAttemptAt = AutomaticOfflineSourceCooldownPolicy.adjustedAttemptDate(
                            current: queuedJob.nextAttemptAt,
                            jobSourceID: queuedJob.song.sourceID,
                            failedSourceID: job.song.sourceID,
                            cooldownUntil: retry.nextAttemptAt,
                            failureKind: failureKind
                        )
                        journal.jobs[songID] = queuedJob
                        insertIntoJobHeap(queuedJob)
                    }
                } else {
                    insertIntoJobHeap(retry)
                }
                // Retry deadlines and prepared refresh state are safety
                // critical even for a tiny queue; never leave them behind the
                // throughput-oriented completion batch.
                persistJobDelta(
                    retry,
                    sourceCooldownID: failureKind.requiresSourceCooldown
                        ? job.song.sourceID
                        : nil,
                    sourceCooldownUntil: failureKind.requiresSourceCooldown
                        ? retry.nextAttemptAt
                        : nil
                )
            }
        }
    }

    private func nextJob() -> Job? {
        while let entry = jobHeap.first {
            guard let job = journal.jobs[entry.songID],
                  job.nextAttemptAt == entry.nextAttemptAt,
                  job.enqueuedAt == entry.enqueuedAt else {
                removeJobHeapRoot()
                continue
            }
            return job
        }
        return nil
    }

    private func rebuildJobHeap() {
        jobHeap.removeAll(keepingCapacity: true)
        jobHeap.reserveCapacity(journal.jobs.count)
        for job in journal.jobs.values {
            insertIntoJobHeap(job)
        }
    }

    private func insertIntoJobHeap(_ job: Job) {
        jobHeap.append(JobQueueEntry(
            songID: job.song.id,
            nextAttemptAt: job.nextAttemptAt,
            enqueuedAt: job.enqueuedAt
        ))
        var index = jobHeap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard Self.jobQueueEntry(jobHeap[index], precedes: jobHeap[parent]) else {
                break
            }
            jobHeap.swapAt(index, parent)
            index = parent
        }
    }

    private func removeJobHeapRoot() {
        guard !jobHeap.isEmpty else { return }
        if jobHeap.count == 1 {
            jobHeap.removeLast()
            return
        }
        jobHeap[0] = jobHeap.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < jobHeap.count else { return }
            let right = left + 1
            let candidate = right < jobHeap.count
                && Self.jobQueueEntry(jobHeap[right], precedes: jobHeap[left])
                ? right
                : left
            guard Self.jobQueueEntry(jobHeap[candidate], precedes: jobHeap[index]) else {
                return
            }
            jobHeap.swapAt(index, candidate)
            index = candidate
        }
    }

    private static func jobQueueEntry(
        _ lhs: JobQueueEntry,
        precedes rhs: JobQueueEntry
    ) -> Bool {
        if lhs.nextAttemptAt != rhs.nextAttemptAt {
            return lhs.nextAttemptAt < rhs.nextAttemptAt
        }
        if lhs.enqueuedAt != rhs.enqueuedAt {
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
        return lhs.songID < rhs.songID
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
                isPlaybackActive: player.isPlaybackActive,
                isPlaybackBuffering: player.isLoading,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                hasSeriousThermalPressure: thermal == .serious || thermal == .critical
            )
        }
    }

    private func loadJournalIfNeeded() {
        guard !didLoadJournal else { return }
        didLoadJournal = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: journalURL),
           let decoded = try? decoder.decode(Journal.self, from: data) {
            journal = decoded
        }

        let snapshotSequence = journal.lastAppliedDeltaSequence ?? 0
        var highestSequence = snapshotSequence
        var deltaLogNeedsCompaction = false
        if let deltaData = try? Data(contentsOf: journalDeltaURL) {
            deltaLogNeedsCompaction = !deltaData.isEmpty && deltaData.last != 0x0A
            for line in deltaData.split(separator: 0x0A) {
                guard let delta = try? decoder.decode(JournalDelta.self, from: Data(line)) else {
                    // A killed append can leave only the final line partial.
                    deltaLogNeedsCompaction = true
                    continue
                }
                highestSequence = max(highestSequence, delta.sequence)
                guard delta.sequence > snapshotSequence else { continue }
                applyJournalDelta(delta)
                journal.lastAppliedDeltaSequence = delta.sequence
            }
        }
        nextJournalDeltaSequence = highestSequence == .max
            ? .max
            : highestSequence + 1
        if deltaLogNeedsCompaction {
            // A subsequent append must never concatenate onto a torn final
            // record. Fold every decodable delta into one atomic snapshot first.
            persistJournal(force: true)
        }
    }

    private func persistJournal(force: Bool = false) {
        journalMutationCountSincePersist += 1
        let batchSize = max(128, journal.jobs.count / 100)
        guard force || journalMutationCountSincePersist >= batchSize else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var snapshot = journal
        snapshot.lastAppliedDeltaSequence = nextJournalDeltaSequence > 0
            ? nextJournalDeltaSequence - 1
            : 0
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: journalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: journalURL, options: .atomic)
            journal = snapshot
            journalMutationCountSincePersist = 0
            try Data().write(to: journalDeltaURL, options: .atomic)
        } catch {
            // The append log remains authoritative until both the snapshot and
            // its empty replacement are durably installed.
        }
    }

    private func persistJobDelta(
        _ job: Job,
        sourceCooldownID: String? = nil,
        sourceCooldownUntil: Date? = nil
    ) {
        appendJournalDelta(JournalDelta(
            sequence: takeNextJournalDeltaSequence(),
            kind: .jobUpdate,
            expectedContentSignature: job.contentSignature,
            job: job,
            sourceCooldownID: sourceCooldownID,
            sourceCooldownUntil: sourceCooldownUntil,
            completion: nil
        ))
    }

    private func persistCompletionDelta(_ completion: AutomaticOfflineCompletionDeltaPayload) {
        appendJournalDelta(JournalDelta(
            sequence: takeNextJournalDeltaSequence(),
            kind: .completion,
            expectedContentSignature: nil,
            job: nil,
            sourceCooldownID: nil,
            sourceCooldownUntil: nil,
            completion: completion
        ))
    }

    private func takeNextJournalDeltaSequence() -> UInt64 {
        let sequence = nextJournalDeltaSequence
        if nextJournalDeltaSequence < .max {
            nextJournalDeltaSequence += 1
        }
        return sequence
    }

    private func appendJournalDelta(_ delta: JournalDelta) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(delta) else {
            persistJournal(force: true)
            return
        }
        data.append(0x0A)
        do {
            try FileManager.default.createDirectory(
                at: journalDeltaURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: journalDeltaURL.path) {
                guard FileManager.default.createFile(
                    atPath: journalDeltaURL.path,
                    contents: nil
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: journalDeltaURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // Fall back to one atomic full snapshot if the O(1) append fails.
            // The in-memory mutation has already been applied.
            persistJournal(force: true)
        }
    }

    private func applyJournalDelta(_ delta: JournalDelta) {
        switch delta.kind {
        case .jobUpdate:
            guard let job = delta.job,
                  let expected = delta.expectedContentSignature,
                  journal.jobs[job.song.id]?.contentSignature == expected else { return }
            journal.jobs[job.song.id] = job
            if let sourceID = delta.sourceCooldownID,
               let retryAfter = delta.sourceCooldownUntil {
                var sourceRetryAfter = journal.sourceRetryAfter ?? [:]
                sourceRetryAfter[sourceID] = max(
                    sourceRetryAfter[sourceID] ?? .distantPast,
                    retryAfter
                )
                journal.sourceRetryAfter = sourceRetryAfter
                for (songID, var queuedJob) in journal.jobs
                where queuedJob.song.sourceID == sourceID {
                    queuedJob.nextAttemptAt = max(queuedJob.nextAttemptAt, retryAfter)
                    journal.jobs[songID] = queuedJob
                }
            }
        case .completion:
            guard let completion = delta.completion else { return }
            var appliedAny = false
            var knownSignatures = journal.lastKnownSignatures ?? [:]
            for (songID, signature) in completion.completedSignatures {
                if let queued = journal.jobs[songID],
                   queued.contentSignature != signature {
                    continue
                }
                journal.completedSignatures[songID] = signature
                knownSignatures[songID] = signature
                if journal.jobs[songID]?.contentSignature == signature {
                    journal.jobs.removeValue(forKey: songID)
                }
                appliedAny = true
            }
            guard appliedAny else { return }
            journal.lastKnownSignatures = knownSignatures
            journal.sourceRetryAfter?.removeValue(forKey: completion.sourceID)
            var artifactProvenance = journal.artifactProvenanceSignatures ?? [:]
            artifactProvenance[completion.artifactPath] = completion.artifactSignature
            journal.artifactProvenanceSignatures = artifactProvenance
            var artifactSources = journal.artifactSourceIdentitySignatures ?? [:]
            artifactSources[completion.artifactPath] = completion.sourceIdentitySignature
            journal.artifactSourceIdentitySignatures = artifactSources
        }
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
    @ObservationIgnored private var applicationIsActive = false
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
                playbackIsActive: self.player.isPlaybackActive,
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
            _ = player.isPlaying
            _ = player.isLoading
            _ = NetworkMonitor.shared.pathGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeTransferConditions()
                await self.worker.resourceConditionsDidChange(
                    playbackIsActive: self.player.isPlaybackActive,
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
                            playbackIsActive: self.player.isPlaybackActive,
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
                      !source.isDeleted,
                      AutomaticOfflineSongPolicy.supports(song),
                      AutomaticOfflineDownloadPolicy.supportsSourceType(source.type) else {
                    continue
                }
                let signature = contentSignature(
                    song: song,
                    source: source
                )
                let sourceIdentity = sourceIdentitySignature(source)
                let artifactFileName = CacheFileNamePolicy.make(
                    path: song.filePath,
                    preferredExtension: song.fileFormat.rawValue
                )
                let artifactPath = "\(song.sourceID)/\(artifactFileName)"
                let artifactContentSignature = artifactSignature(
                    song: song,
                    sourceIdentitySignature: sourceIdentity
                )
                if let existing = desiredBySongID[song.id] {
                    desiredBySongID[song.id] = AlwaysDownloadDesiredSong(
                        song: song,
                        playlistIDs: existing.playlistIDs.union([playlistID]),
                        contentSignature: signature,
                        sourceIdentitySignature: sourceIdentity,
                        artifactPath: artifactPath,
                        artifactSignature: artifactContentSignature
                    )
                } else {
                    desiredBySongID[song.id] = AlwaysDownloadDesiredSong(
                        song: song,
                        playlistIDs: [playlistID],
                        contentSignature: signature,
                        sourceIdentitySignature: sourceIdentity,
                        artifactPath: artifactPath,
                        artifactSignature: artifactContentSignature
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
            source.map { sourceIdentitySignature($0) } ?? "",
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func sourceIdentitySignature(_ source: MusicSource) -> String {
        MusicSourceSecurityRevision.scopedFingerprint(for: source)
    }

    private nonisolated static func artifactSignature(
        song: Song,
        sourceIdentitySignature: String
    ) -> String {
        AutomaticOfflineArtifactPolicy.signature(
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat.rawValue,
            fileSize: song.fileSize,
            revision: song.revision,
            lastModified: song.lastModified,
            sourceIdentitySignature: sourceIdentitySignature
        )
    }

    private func persistPreferences() {
        defaults.set(enabledPlaylistIDs.sorted(), forKey: Self.defaultsKey)
    }
}
