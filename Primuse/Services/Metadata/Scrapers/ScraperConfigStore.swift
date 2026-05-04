import Foundation

/// Manages storage and retrieval of user-imported ScraperConfig JSON files.
/// Configs are stored as individual .json files in Application Support/Primuse/ScraperConfigs/.
final class ScraperConfigStore: @unchecked Sendable {
    static let shared = ScraperConfigStore()

    private let configDir: URL
    private var cache: [String: ScraperConfig] = [:]
    private let lock = NSLock()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        configDir = appSupport.appendingPathComponent("Primuse/ScraperConfigs")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: - Public API

    /// Live (non-deleted) imported configs for normal UI use.
    var allConfigs: [ScraperConfig] {
        lock.lock()
        defer { lock.unlock() }
        return cache.values
            .filter { $0.isDeleted != true }
            .sorted { $0.name < $1.name }
    }

    /// Includes soft-deleted entries — used by CloudKit sync to push the full
    /// state (including the soft-delete tombstone) to other devices.
    var allConfigsIncludingDeleted: [ScraperConfig] {
        lock.lock()
        defer { lock.unlock() }
        return Array(cache.values).sorted { $0.name < $1.name }
    }

    /// Soft-deleted configs, newest deletion first.
    var recentlyDeletedConfigs: [ScraperConfig] {
        lock.lock()
        defer { lock.unlock() }
        return cache.values
            .filter { $0.isDeleted == true }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Get config by ID — also returns soft-deleted entries so the cloud sync
    /// path can re-push them. UI callers should look it up via `allConfigs`.
    func config(for id: String) -> ScraperConfig? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    /// Import one or more configs from a JSON string.
    ///
    /// Accepts these input shapes (with arbitrary leading/trailing/inter-object whitespace):
    /// - Single object:   `{ ... }`
    /// - JSON array:      `[{...}, {...}]`
    /// - Concatenated:    `{...}\n{...}` or `{...} {...}`
    /// - Bundle manifest: `{ "schema": N, "sources": [{...}, ...] }`
    @discardableResult
    func importFromJSON(_ jsonString: String) throws -> [ScraperConfig] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScraperConfigError.invalidJSON("Empty input")
        }

        let decoder = JSONDecoder()
        let configs: [ScraperConfig]

        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8) else {
                throw ScraperConfigError.invalidJSON("Cannot encode string as UTF-8")
            }
            configs = try decoder.decode([ScraperConfig].self, from: data)
        } else if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8) else {
                throw ScraperConfigError.invalidJSON("Cannot encode string as UTF-8")
            }
            if let bundle = try? decoder.decode(BundleManifest.self, from: data),
               !bundle.sources.isEmpty {
                configs = bundle.sources
            } else {
                let chunks = try extractTopLevelObjects(trimmed)
                configs = try chunks.map { try decoder.decode(ScraperConfig.self, from: $0) }
            }
        } else {
            throw ScraperConfigError.invalidJSON("Expected '{' or '[' at start")
        }

        return try persistAll(configs)
    }

    private struct BundleManifest: Decodable {
        let sources: [ScraperConfig]
    }

    /// Import one or more configs from a URL — downloads the JSON and imports it.
    func importFromURL(_ url: URL) async throws -> [ScraperConfig] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScraperConfigError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ScraperConfigError.invalidJSON("Response is not valid UTF-8")
        }
        return try importFromJSON(jsonString)
    }

    /// Soft-delete a config — flag and persist, propagated to other devices as
    /// an update. Use `permanentlyDelete(id:)` for the real removal.
    func delete(id: String) {
        lock.lock()
        guard var config = cache[id] else { lock.unlock(); return }
        config.isDeleted = true
        config.deletedAt = Date()
        config.modifiedAt = Date()
        cache[id] = config
        lock.unlock()
        writeToDisk(config)
        NotificationCenter.default.post(
            name: .primuseScraperConfigDidChange,
            object: nil,
            userInfo: ["ids": [id]]
        )
    }

    /// Restore a soft-deleted config.
    func restore(id: String) {
        lock.lock()
        guard var config = cache[id] else { lock.unlock(); return }
        config.isDeleted = false
        config.deletedAt = nil
        config.modifiedAt = Date()
        cache[id] = config
        lock.unlock()
        writeToDisk(config)
        NotificationCenter.default.post(
            name: .primuseScraperConfigDidChange,
            object: nil,
            userInfo: ["ids": [id]]
        )
    }

    /// Permanently remove a config — drops the file from disk and notifies
    /// CloudKit sync to delete the record. Also removes the sibling
    /// `<id>.secrets.json` if present.
    func permanentlyDelete(id: String) {
        lock.lock()
        cache.removeValue(forKey: id)
        lock.unlock()
        let fileURL = configDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: fileURL)
        let secretsURL = configDir.appendingPathComponent("\(id).secrets.json")
        try? FileManager.default.removeItem(at: secretsURL)
        NotificationCenter.default.post(
            name: .primuseScraperConfigDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Sweep configs whose `deletedAt` is older than `threshold`. Called on
    /// launch with a 30-day threshold.
    func pruneConfigs(deletedBefore threshold: Date) {
        let toPrune: [String] = {
            lock.lock()
            defer { lock.unlock() }
            return cache.values
                .filter { $0.isDeleted == true && ($0.deletedAt ?? .distantFuture) < threshold }
                .map(\.id)
        }()
        for id in toPrune {
            permanentlyDelete(id: id)
        }
    }

    private func writeToDisk(_ config: ScraperConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        let fileURL = configDir.appendingPathComponent("\(config.id).json")
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Apply a config pulled from CloudKit. Skips notification — caller is the
    /// remote-apply path. Compares `modifiedAt` last-writer-wins so a slow
    /// remote arrival doesn't clobber a fresher local edit.
    func applyRemoteConfig(_ config: ScraperConfig) {
        lock.lock()
        if let existing = cache[config.id],
           let localTS = existing.modifiedAt,
           let remoteTS = config.modifiedAt,
           localTS > remoteTS {
            lock.unlock()
            return
        }
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        let fileURL = configDir.appendingPathComponent("\(config.id).json")
        try? data.write(to: fileURL, options: .atomic)
        lock.lock()
        cache[config.id] = config
        lock.unlock()
    }

    /// Delete a config in response to a remote deletion. Skips notification.
    func deleteFromRemote(id: String) {
        lock.lock()
        cache.removeValue(forKey: id)
        lock.unlock()
        let fileURL = configDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Check if a config exists
    func exists(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[id] != nil
    }

    // MARK: - Private

    private func loadAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil) else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for file in files where file.pathExtension == "json" && !file.lastPathComponent.contains(".secrets.") {
            guard let data = try? Data(contentsOf: file),
                  var config = try? JSONDecoder().decode(ScraperConfig.self, from: data) else { continue }

            // 主 JSON 里如果不小心带了 secrets（一次性导入流程），自动剥离到旁路文件 +
            // 重写主 JSON。保证主 JSON 始终干净，不会因后续编辑误传 secrets。
            if let inlineSecrets = config.secrets, !inlineSecrets.isEmpty {
                let secretsURL = configDir.appendingPathComponent("\(config.id).secrets.json")
                if let secretsData = try? encoder.encode(inlineSecrets) {
                    try? secretsData.write(to: secretsURL, options: .atomic)
                }
                if let cleanedData = try? encoder.encode(config) {
                    try? cleanedData.write(to: file, options: .atomic)
                }
            }

            // 旁路加载 <id>.secrets.json — 不进同步、不进仓库、不参与 Codable
            let secretsURL = configDir.appendingPathComponent("\(config.id).secrets.json")
            let secretsExists = FileManager.default.fileExists(atPath: secretsURL.path)
            if let secretsData = try? Data(contentsOf: secretsURL),
               let secrets = try? JSONDecoder().decode([String: String].self, from: secretsData) {
                config.secrets = secrets
                plog("📦 ScraperConfigStore loadAll: \(config.id) v\(config.version) + secrets file keys=\(Array(secrets.keys))")
            } else if let bundled = AppSecrets.scraperSecrets[config.id] {
                // Fallback: 用户没手动放 secrets 文件, 但 AppSecrets 内置了
                // 一份解密参数, 自动注入让用户开箱即用。
                config.secrets = bundled
                plog("📦 ScraperConfigStore loadAll: \(config.id) v\(config.version) + secrets builtin keys=\(Array(bundled.keys))")
            } else {
                plog("📦 ScraperConfigStore loadAll: \(config.id) v\(config.version) NO secrets (file exists=\(secretsExists))")
            }

            cache[config.id] = config
        }
    }

    private func save(_ config: ScraperConfig, data: Data) throws {
        let fileURL = configDir.appendingPathComponent("\(config.id).json")
        try data.write(to: fileURL, options: .atomic)
    }

    private func validate(_ config: ScraperConfig) throws {
        guard !config.id.isEmpty else {
            throw ScraperConfigError.validationFailed("Config ID is empty")
        }
        guard !config.name.isEmpty else {
            throw ScraperConfigError.validationFailed("Config name is empty")
        }
        guard !config.capabilities.isEmpty else {
            throw ScraperConfigError.validationFailed("Config has no capabilities")
        }
        // At least one endpoint must be defined
        guard config.search != nil || config.detail != nil || config.cover != nil || config.lyrics != nil else {
            throw ScraperConfigError.validationFailed("Config has no endpoints defined")
        }
    }

    /// Validate everything before writing anything — avoid half-imported state.
    private func persistAll(_ configs: [ScraperConfig]) throws -> [ScraperConfig] {
        guard !configs.isEmpty else {
            throw ScraperConfigError.invalidJSON("No config object found")
        }
        for config in configs { try validate(config) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let now = Date()
        var stamped: [ScraperConfig] = []
        for var config in configs {
            // Stamp with import time so conflict resolution can compare wall-clock
            // edit times across devices.
            config.modifiedAt = now
            // 主 config encode 时 secrets 自动剥离（见 ScraperConfig.encode(to:)）
            let data = try encoder.encode(config)
            try save(config, data: data)
            // secrets 单独写 <id>.secrets.json — 不进 CloudKit、不参与 encode 导出
            if let secrets = config.secrets, !secrets.isEmpty {
                if let secretsData = try? encoder.encode(secrets) {
                    let secretsURL = configDir.appendingPathComponent("\(config.id).secrets.json")
                    try? secretsData.write(to: secretsURL, options: .atomic)
                }
            }
            lock.lock()
            cache[config.id] = config
            lock.unlock()
            stamped.append(config)
        }
        NotificationCenter.default.post(
            name: .primuseScraperConfigDidChange,
            object: nil,
            userInfo: ["ids": stamped.map(\.id)]
        )
        return stamped
    }

    /// Split a buffer of one-or-more concatenated top-level `{...}` JSON objects.
    /// Tolerates whitespace/newlines between objects; rejects any other stray characters.
    /// String contents and `\"` escapes are respected so braces inside strings don't fool the scanner.
    private func extractTopLevelObjects(_ text: String) throws -> [Data] {
        var results: [Data] = []
        var depth = 0
        var inString = false
        var escape = false
        var startIdx: String.Index? = nil

        for idx in text.indices {
            let c = text[idx]
            if escape { escape = false; continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { startIdx = idx }
                depth += 1
            case "}":
                depth -= 1
                if depth < 0 {
                    throw ScraperConfigError.invalidJSON("Unbalanced '}'")
                }
                if depth == 0, let s = startIdx {
                    let slice = text[s...idx]
                    guard let data = String(slice).data(using: .utf8) else {
                        throw ScraperConfigError.invalidJSON("Cannot encode chunk as UTF-8")
                    }
                    results.append(data)
                    startIdx = nil
                }
            default:
                if depth == 0 && !c.isWhitespace && !c.isNewline {
                    throw ScraperConfigError.invalidJSON("Unexpected '\(c)' between objects")
                }
            }
        }
        guard depth == 0, !inString else {
            throw ScraperConfigError.invalidJSON("Unclosed JSON object")
        }
        return results
    }
}

enum ScraperConfigError: Error, LocalizedError {
    case invalidJSON(String)
    case downloadFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let msg): "Invalid JSON: \(msg)"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        case .validationFailed(let msg): "Validation failed: \(msg)"
        }
    }
}
