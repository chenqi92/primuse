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

    /// Import one or more configs from a JSON string.
    ///
    /// Accepts three input shapes (with arbitrary leading/trailing/inter-object whitespace):
    /// - Single object: `{ ... }`
    /// - JSON array:    `[{...}, {...}]`
    /// - Concatenated:  `{...}\n{...}` or `{...} {...}`
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
            let chunks = try extractTopLevelObjects(trimmed)
            configs = try chunks.map { try decoder.decode(ScraperConfig.self, from: $0) }
        } else {
            throw ScraperConfigError.invalidJSON("Expected '{' or '[' at start")
        }

        return try persistAll(configs)
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

    /// Validate everything before writing anything — avoid half-imported state.
    private func persistAll(_ configs: [ScraperConfig]) throws -> [ScraperConfig] {
        guard !configs.isEmpty else {
            throw ScraperConfigError.invalidJSON("No config object found")
        }
        for config in configs { try validate(config) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for config in configs {
            let data = try encoder.encode(config)
            try save(config, data: data)
            lock.lock()
            cache[config.id] = config
            lock.unlock()
        }
        return configs
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
