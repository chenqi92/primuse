import Foundation

/// LRU cache manager for audio files. Enforces a 2 GB disk size limit
/// by evicting least-recently-accessed files when the cache grows too large.
actor AudioCacheManager {
    static let shared = AudioCacheManager()

    let maxCacheSize: Int64 = 2_147_483_648 // 2 GB

    private var accessLog: [String: Date] = [:]
    private let logURL: URL
    private let basePath: URL
    private var persistTask: Task<Void, Never>?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        basePath = caches.appendingPathComponent("primuse_audio_cache")
        logURL = basePath.appendingPathComponent(".access_log.json")
        // Actor init is nonisolated; defer loading to first access
    }

    private var initialized = false
    private func ensureInitialized() {
        guard !initialized else { return }
        initialized = true
        loadAccessLog()
        migrateExistingFiles()
    }

    // MARK: - Public API

    /// Record that a cached file was accessed (played or just created).
    func recordAccess(path: String) {
        ensureInitialized()
        accessLog[path] = Date()
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
        let reserve = reserveBytes > 0 ? reserveBytes : 10_485_760 // default 10 MB estimate
        let currentSize = totalCacheSizeSync()
        let target = maxCacheSize - reserve

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
                candidates.append(EvictCandidate(
                    url: fileURL, relativePath: relative, size: size, lastUsed: lastUsed
                ))
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
        schedulePersist()
    }

    /// 删 LRU 里以 `prefix` 开头的所有记录。配合 SourceManager.purgeAudioCache
    /// 用 —— 删源时一次清掉所有属于这个 sourceID 的访问时间戳, 不然
    /// accessLog 里残留的 dead key 越堆越多。
    func removeAllEntries(forSourcePrefix prefix: String) {
        ensureInitialized()
        let keys = accessLog.keys.filter { $0.hasPrefix(prefix) }
        for key in keys { accessLog[key] = nil }
        if !keys.isEmpty { schedulePersist() }
    }

    func clearAll() {
        accessLog.removeAll()
        try? FileManager.default.removeItem(at: logURL)
        persistNow()
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

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        try? FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(accessLog) else { return }
        try? data.write(to: logURL, options: .atomic)
    }
}
