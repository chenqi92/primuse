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

    /// All imported configs
    var allConfigs: [ScraperConfig] {
        lock.lock()
        defer { lock.unlock() }
        return Array(cache.values).sorted { $0.name < $1.name }
    }

    /// Get config by ID
    func config(for id: String) -> ScraperConfig? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    /// Import a config from JSON string. Returns the config if valid.
    @discardableResult
    func importFromJSON(_ jsonString: String) throws -> ScraperConfig {
        guard let data = jsonString.data(using: .utf8) else {
            throw ScraperConfigError.invalidJSON("Cannot encode string as UTF-8")
        }
        let config = try JSONDecoder().decode(ScraperConfig.self, from: data)
        try validate(config)
        try save(config, data: data)
        lock.lock()
        cache[config.id] = config
        lock.unlock()
        return config
    }

    /// Import from URL — downloads the JSON and imports it.
    func importFromURL(_ url: URL) async throws -> ScraperConfig {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScraperConfigError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ScraperConfigError.invalidJSON("Response is not valid UTF-8")
        }
        return try importFromJSON(jsonString)
    }

    /// Delete a config by ID
    func delete(id: String) {
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
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let config = try? JSONDecoder().decode(ScraperConfig.self, from: data) {
                cache[config.id] = config
            }
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
