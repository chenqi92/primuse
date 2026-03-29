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
    func evictIfNeeded(reserveBytes: Int64) {
        ensureInitialized()
        let reserve = reserveBytes > 0 ? reserveBytes : 10_485_760 // default 10 MB estimate
        let currentSize = totalCacheSizeSync()
        let target = maxCacheSize - reserve

        guard currentSize > target else { return }

        // Sort by access time ascending (oldest first)
        let sorted = accessLog.sorted { $0.value < $1.value }
        var freed: Int64 = 0
        let needed = currentSize - target

        for (path, _) in sorted {
            guard freed < needed else { break }
            let fileURL = basePath.appendingPathComponent(path)
            if let size = fileSize(at: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                freed += size
                accessLog[path] = nil
            }
        }

        schedulePersist()
    }

    func totalCacheSize() -> Int64 {
        totalCacheSizeSync()
    }

    func clearAll() {
        accessLog.removeAll()
        try? FileManager.default.removeItem(at: logURL)
        persistNow()
    }

    // MARK: - Internal

    private func totalCacheSizeSync() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: basePath, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
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
