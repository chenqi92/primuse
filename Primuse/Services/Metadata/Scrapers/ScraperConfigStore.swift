import Foundation
import PrimuseKit

/// Non-persistent review payload shown before a custom scraper is imported.
struct ScraperImportSummary: Sendable {
    let configs: [ScraperConfig]
    let sourceHost: String?
    let domains: [String]
    let sslTrustDomains: [String]
    let capabilities: [String]
    let methods: [String]
    let endpointCount: Int
    let scriptCharacterCount: Int
    let includesHeaders: Bool
    let includesCookie: Bool
    let includesSecrets: Bool
    let warnings: [String]

    var sourceDescription: String {
        if let sourceHost { return sourceHost }
        return "Pasted JSON"
    }
}

/// User-facing scraper import accepts either inline JSON or a remote manifest
/// URL in the same field. Keep classification here so every settings surface
/// follows exactly the same rules.
enum ScraperImportInput {
    case json(String)
    case remoteURL(URL)
}

/// Manages storage and retrieval of user-imported ScraperConfig JSON files.
/// Configs are stored as individual .json files in Application Support/Primuse/ScraperConfigs/.
final class ScraperConfigStore: @unchecked Sendable {
    static let shared = ScraperConfigStore()

    private static let maxRemoteImportBytes = 2 * 1024 * 1024

    private let configDir: URL
    private var cache: [String: ScraperConfig] = [:]
    private let lock = NSLock()

    private init() {
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
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
        try importConfigs(parseConfigs(from: jsonString))
    }

    /// Parse and validate one or more configs without writing them to disk.
    func previewImportFromJSON(_ jsonString: String) throws -> ScraperImportSummary {
        try makeImportSummary(configs: parseConfigs(from: jsonString), sourceURL: nil)
    }

    /// Recognize inline JSON and HTTPS manifest URLs without requiring the
    /// user to select an import mode first. JSON-looking input stays classified
    /// as JSON even when malformed so the decoder can return the useful parse
    /// error. Remote manifest URLs are HTTPS-only and cannot carry credentials.
    func classifyImportInput(_ input: String) throws -> ScraperImportInput {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScraperConfigError.invalidInput("Empty input")
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return .json(trimmed)
        }
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           components.host?.isEmpty == false {
            guard scheme == "https" else {
                if scheme == "http" {
                    throw ScraperConfigError.downloadFailed("Only HTTPS URLs are supported")
                }
                throw ScraperConfigError.invalidInput("Paste scraper JSON or an HTTPS manifest URL")
            }
            guard components.user == nil, components.password == nil, let url = components.url else {
                throw ScraperConfigError.invalidInput("Manifest URLs cannot contain credentials")
            }
            return .remoteURL(url)
        }
        throw ScraperConfigError.invalidInput("Paste scraper JSON or an HTTPS manifest URL")
    }

    /// Persist configs that have already been parsed/reviewed.
    @discardableResult
    func importConfigs(_ configs: [ScraperConfig]) throws -> [ScraperConfig] {
        try persistAll(configs)
    }

    private func parseConfigs(from jsonString: String) throws -> [ScraperConfig] {
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

        for config in configs { try validate(config) }
        return configs
    }

    private struct BundleManifest: Decodable {
        let sources: [ScraperConfig]
    }

    /// Import one or more configs from a URL — downloads the JSON and imports it.
    func importFromURL(_ url: URL) async throws -> [ScraperConfig] {
        try importConfigs((try await previewImportFromURL(url)).configs)
    }

    /// Download, parse and validate a remote config without writing it to disk.
    func previewImportFromURL(_ url: URL) async throws -> ScraperImportSummary {
        let jsonString = try await downloadConfigJSON(from: url)
        return try makeImportSummary(configs: parseConfigs(from: jsonString), sourceURL: url)
    }

    private func downloadConfigJSON(from url: URL) async throws -> String {
        guard url.scheme?.lowercased() == "https" else {
            throw ScraperConfigError.downloadFailed("Only HTTPS URLs are supported")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScraperConfigError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
        if let declaredLength,
           declaredLength < 0 || declaredLength > Self.maxRemoteImportBytes {
            throw ScraperConfigError.downloadFailed("Invalid response size")
        }

        var data = Data()
        data.reserveCapacity(min(declaredLength ?? 0, Self.maxRemoteImportBytes))
        for try await byte in bytes {
            if data.count >= Self.maxRemoteImportBytes {
                throw ScraperConfigError.downloadFailed("Response too large")
            }
            data.append(byte)
        }
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ScraperConfigError.invalidJSON("Response is not valid UTF-8")
        }
        return jsonString
    }

    private func makeImportSummary(configs: [ScraperConfig], sourceURL: URL?) throws -> ScraperImportSummary {
        guard !configs.isEmpty else {
            throw ScraperConfigError.invalidJSON("No config object found")
        }
        for config in configs { try validate(config) }

        let endpoints = configs.flatMap { Self.endpoints(in: $0) }
        let endpointDomains = endpoints.flatMap { endpoint in
            Self.hosts(in: endpoint.url)
                + Self.hosts(in: endpoint.bodyTemplate ?? "")
                + Self.hosts(in: endpoint.script)
        }
        let sslTrustDomains = configs
            .flatMap { $0.sslTrustDomains ?? [] }
            .compactMap(Self.normalizedHost)
        let capabilities = configs
            .flatMap(\.capabilities)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let methods = endpoints
            .map { $0.method.uppercased() }
            .filter { !$0.isEmpty }
        let includesHeaders = configs.contains { $0.headers?.isEmpty == false }
            || endpoints.contains { $0.headers?.isEmpty == false }
        let includesCookie = configs.contains { config in
            config.cookie?.isEmpty == false
                || config.headers?.keys.contains(where: { $0.caseInsensitiveCompare("cookie") == .orderedSame }) == true
                || Self.endpoints(in: config).contains {
                    $0.headers?.keys.contains(where: { $0.caseInsensitiveCompare("cookie") == .orderedSame }) == true
                }
        }
        let includesSecrets = configs.contains { $0.secrets?.isEmpty == false }
        let scriptCharacterCount = endpoints.reduce(0) { $0 + $1.script.count }

        var warnings: [String] = []
        if Set(endpointDomains).isEmpty {
            warnings.append(String(localized: "scraper_warn_no_fixed_domain"))
        }
        if includesCookie {
            warnings.append(String(localized: "scraper_warn_includes_cookie"))
        } else if includesHeaders {
            warnings.append(String(localized: "scraper_warn_custom_headers"))
        }
        if includesSecrets {
            warnings.append(String(localized: "scraper_warn_includes_secrets"))
        }
        if !sslTrustDomains.isEmpty {
            warnings.append(String(localized: "scraper_warn_tls_trust_domains"))
        }
        if endpoints.contains(where: { $0.method.uppercased() != "GET" }) {
            warnings.append(String(localized: "scraper_warn_non_get_requests"))
        }
        if endpoints.contains(where: { $0.script.count > 200_000 }) {
            warnings.append(String(localized: "scraper_warn_script_too_large"))
        }

        return ScraperImportSummary(
            configs: configs,
            sourceHost: sourceURL?.host?.lowercased(),
            domains: Array(Set(endpointDomains)).sorted(),
            sslTrustDomains: Array(Set(sslTrustDomains)).sorted(),
            capabilities: Array(Set(capabilities)).sorted(),
            methods: Array(Set(methods)).sorted(),
            endpointCount: endpoints.count,
            scriptCharacterCount: scriptCharacterCount,
            includesHeaders: includesHeaders,
            includesCookie: includesCookie,
            includesSecrets: includesSecrets,
            warnings: warnings
        )
    }

    private static func endpoints(in config: ScraperConfig) -> [EndpointConfig] {
        [config.search, config.detail, config.cover, config.lyrics].compactMap { $0 }
    }

    private static func hosts(in text: String) -> [String] {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s"'<>)}\]]+"#) else {
            return []
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).compactMap { match in
            let candidate = nsText.substring(with: match.range)
            return URL(string: candidate).flatMap { normalizedHost($0.host) }
        }
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !trimmed.isEmpty, !trimmed.contains("{"), !trimmed.contains("}") else { return nil }
        return trimmed
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
        if let fileURL = try? configFileURL(for: id) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let secretsURL = try? secretsFileURL(for: id) {
            try? FileManager.default.removeItem(at: secretsURL)
        }
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
        guard let data = try? encoder.encode(config),
              let fileURL = try? configFileURL(for: config.id) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Apply a config pulled from CloudKit. Skips notification — caller is the
    /// remote-apply path. Compares `modifiedAt` last-writer-wins so a slow
    /// remote arrival doesn't clobber a fresher local edit.
    func applyRemoteConfig(_ config: ScraperConfig) {
        do {
            try validate(config)
        } catch {
            plog("📦 ScraperConfigStore applyRemoteConfig skipped invalid id=\(config.id): \(error.localizedDescription)")
            return
        }

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
        guard let data = try? encoder.encode(config),
              let fileURL = try? configFileURL(for: config.id) else { return }
        try? data.write(to: fileURL, options: .atomic)

        // CloudKit 拉回的 config 因 encode 剥离必然 secrets == nil，写入 cache 前
        // 旁路补回 secrets（磁盘文件或内置 fallback），否则加密歌词源在本会话内
        // 会因 secrets 缺失而静默失效，要等 App 重启才恢复。
        var resolved = config
        injectSecrets(into: &resolved, context: "applyRemoteConfig")

        lock.lock()
        cache[config.id] = resolved
        lock.unlock()
    }

    /// Delete a config in response to a remote deletion. Skips notification.
    func deleteFromRemote(id: String) {
        lock.lock()
        cache.removeValue(forKey: id)
        lock.unlock()
        if let fileURL = try? configFileURL(for: id) {
            try? FileManager.default.removeItem(at: fileURL)
        }
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
            do {
                try validate(config)
            } catch {
                plog("📦 ScraperConfigStore loadAll skipped invalid file=\(file.lastPathComponent): \(error.localizedDescription)")
                continue
            }

            // 主 JSON 里如果不小心带了 secrets（一次性导入流程），自动剥离到旁路文件 +
            // 重写主 JSON。保证主 JSON 始终干净，不会因后续编辑误传 secrets。
            if let inlineSecrets = config.secrets, !inlineSecrets.isEmpty {
                if let secretsURL = try? secretsFileURL(for: config.id),
                   let secretsData = try? encoder.encode(inlineSecrets) {
                    try? secretsData.write(to: secretsURL, options: .atomic)
                }
                if let cleanedData = try? encoder.encode(config) {
                    try? cleanedData.write(to: file, options: .atomic)
                }
            }

            // 旁路加载 <id>.secrets.json — 不进同步、不进仓库、不参与 Codable
            injectSecrets(into: &config, context: "loadAll")

            cache[config.id] = config
        }
    }

    /// 给一个 config 注入旁路 secrets：优先读磁盘 `<id>.secrets.json`，否则
    /// 回退到 `AppSecrets.scraperSecrets` 内置参数。`loadAll` 与
    /// `applyRemoteConfig` 共用——因为 `ScraperConfig.encode(to:)` 故意不输出
    /// secrets，CloudKit 拉回的 config 必然 `secrets == nil`，必须在写入 cache
    /// 前补回，否则加密歌词源在本会话内会因 secrets 缺失而静默失效。
    private func injectSecrets(into config: inout ScraperConfig, context: String) {
        guard let secretsURL = try? secretsFileURL(for: config.id) else { return }
        let secretsExists = FileManager.default.fileExists(atPath: secretsURL.path)
        if let secretsData = try? Data(contentsOf: secretsURL),
           let secrets = try? JSONDecoder().decode([String: String].self, from: secretsData) {
            config.secrets = secrets
            plog("📦 ScraperConfigStore \(context): \(config.id) v\(config.version) + secrets file keys=\(Array(secrets.keys))")
        } else if let bundled = AppSecrets.scraperSecrets[config.id] {
            // Fallback: 用户没手动放 secrets 文件, 但 AppSecrets 内置了
            // 一份解密参数, 自动注入让用户开箱即用。
            config.secrets = bundled
            plog("📦 ScraperConfigStore \(context): \(config.id) v\(config.version) + secrets builtin keys=\(Array(bundled.keys))")
        } else {
            plog("📦 ScraperConfigStore \(context): \(config.id) v\(config.version) NO secrets (file exists=\(secretsExists))")
        }
    }

    private func save(_ config: ScraperConfig, data: Data) throws {
        let fileURL = try configFileURL(for: config.id)
        try data.write(to: fileURL, options: .atomic)
    }

    private func validate(_ config: ScraperConfig) throws {
        guard Self.isSafeConfigID(config.id) else {
            throw ScraperConfigError.validationFailed("Config ID must be 1-64 chars: letters, numbers, '.', '_' or '-'")
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
                    let secretsURL = try secretsFileURL(for: config.id)
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

    private static func isSafeConfigID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64, id.range(of: ".secrets.", options: [.caseInsensitive]) == nil else {
            return false
        }
        return id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    private func configFileURL(for id: String) throws -> URL {
        try safeChildURL(fileName: "\(id).json")
    }

    private func secretsFileURL(for id: String) throws -> URL {
        try safeChildURL(fileName: "\(id).secrets.json")
    }

    private func safeChildURL(fileName: String) throws -> URL {
        let base = configDir.standardizedFileURL
        let url = configDir.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        let basePrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard url.path.hasPrefix(basePrefix), url.deletingLastPathComponent().standardizedFileURL.path == base.path else {
            throw ScraperConfigError.validationFailed("Unsafe config file path")
        }
        return url
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
    case invalidInput(String)
    case invalidJSON(String)
    case downloadFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): "Invalid import input: \(msg)"
        case .invalidJSON(let msg): "Invalid JSON: \(msg)"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        case .validationFailed(let msg): "Validation failed: \(msg)"
        }
    }
}
