import Foundation
import CryptoKit

public enum OfflineSettingsBackupError: Error, Equatable, Sendable {
    case invalidFile, unsupportedVersion, tooLarge, invalidSetting, invalidAsset
}

/// A settings snapshot has an explicit scope, so an unset preference restores its default
/// without touching keys introduced after the backup or unrelated application data.
public struct OfflineSettingsBackup: Codable, Equatable, Sendable {
    public struct Preferences: Codable, Equatable, Sendable {
        public var keys: [String]
        public var values: [String: Data]

        public init(keys: [String], values: [String: Data]) {
            self.keys = keys.sorted()
            self.values = values
        }

        public func validate(allowedKeys: Set<String>) throws {
            let scope = Set(keys)
            guard scope.count == keys.count, scope.isSubset(of: allowedKeys),
                  Set(values.keys).isSubset(of: scope) else { throw OfflineSettingsBackupError.invalidSetting }
            for data in values.values {
                guard data.count <= 8 * 1024 * 1024, LANSettingsBundle.decodeValue(data) != nil else {
                    throw OfflineSettingsBackupError.invalidSetting
                }
            }
        }
    }

    public struct Asset: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case backdrop, font, scraper }
        public var kind: Kind
        public var name: String
        public var data: Data

        public init(kind: Kind, name: String, data: Data) {
            self.kind = kind
            self.name = name
            self.data = data
        }

        public func validate() throws {
            guard !name.isEmpty, name.utf8.count <= 240, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
                  !data.isEmpty, data.count <= 32 * 1024 * 1024 else {
                throw OfflineSettingsBackupError.invalidAsset
            }
            switch kind {
            case .backdrop:
                guard LibraryArtworkContentIDPolicy.isValid(name),
                      Self.digest(data) == name else { throw OfflineSettingsBackupError.invalidAsset }
            case .scraper:
                guard LANSettingsTransferPolicy.isSafeScraperConfigID(name) else {
                    throw OfflineSettingsBackupError.invalidAsset
                }
            case .font:
                guard ["ttf", "otf", "ttc", "otc"].contains((name as NSString).pathExtension.lowercased()) else {
                    throw OfflineSettingsBackupError.invalidAsset
                }
            }
        }

        private static func digest(_ data: Data) -> String { OfflineSettingsBackup.digest(data) }
    }

    public static let maximumFileBytes = 192 * 1024 * 1024
    public var createdAt: Date
    public var appVersion: String
    public var platform: String
    public var standard: Preferences
    public var shared: Preferences
    public var assets: [Asset]

    public init(createdAt: Date = Date(), appVersion: String, platform: String,
                standard: Preferences, shared: Preferences, assets: [Asset] = []) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.platform = platform
        self.standard = standard
        self.shared = shared
        self.assets = assets
    }

    private struct Envelope: Codable {
        var format = "Primuse.Settings"
        var version = 1
        var checksum: String
        var payload: Data
    }

    public func encoded() throws -> Data {
        try validateAssets()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(self)
        guard payload.count <= 140 * 1024 * 1024 else { throw OfflineSettingsBackupError.tooLarge }
        let data = try encoder.encode(Envelope(checksum: Self.digest(payload), payload: payload))
        guard data.count <= Self.maximumFileBytes else { throw OfflineSettingsBackupError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw OfflineSettingsBackupError.tooLarge }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.format == "Primuse.Settings" else { throw OfflineSettingsBackupError.invalidFile }
        guard envelope.version == 1 else { throw OfflineSettingsBackupError.unsupportedVersion }
        guard digest(envelope.payload) == envelope.checksum,
              let backup = try? decoder.decode(Self.self, from: envelope.payload) else {
            throw OfflineSettingsBackupError.invalidFile
        }
        try backup.validateAssets()
        return backup
    }

    public func validateAssets() throws {
        guard assets.count <= 500, standard.keys.count <= 2048, shared.keys.count <= 256 else {
            throw OfflineSettingsBackupError.tooLarge
        }
        var names = Set<String>()
        var bytes = 0
        for asset in assets {
            try asset.validate()
            guard names.insert(asset.kind.rawValue + "/" + asset.name).inserted else {
                throw OfflineSettingsBackupError.invalidAsset
            }
            bytes += asset.data.count
        }
        guard bytes <= 96 * 1024 * 1024 else { throw OfflineSettingsBackupError.tooLarge }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Legacy settings may still contain credentials that newer versions moved to Keychain.
/// Apply the same stripping on both export and import; never import consent from a file.
public enum OfflineSettingsRedaction {
    private static let secretNames: Set<String> = [
        "password", "passwd", "apikey", "apisecret", "secret", "secrets", "clientsecret",
        "token", "accesstoken", "refreshtoken", "sessiontoken", "sessionkey", "authorization",
        "cookie", "cookies", "credentials", "credential", "signature", "auth", "xapikey", "xgoogapikey",
    ]
    private static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func json(_ data: Data) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: sanitize(value), options: [.sortedKeys, .fragmentsAllowed])
    }

    public static func sanitize(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                let name = normalized(key)
                guard !secretNames.contains(name), name != "ssltrustdomains" else { continue }
                if name.hasPrefix("hasexplicit"), name.hasSuffix("consent") {
                    result[key] = false
                } else if name == "headers" || name == "httpheaders" {
                    let headers = value as? [String: Any] ?? [:]
                    result[key] = headers.filter { ["accept", "acceptlanguage", "contenttype", "useragent"].contains(normalized($0.key)) }
                } else {
                    result[key] = sanitize(value)
                }
            }
            return result
        }
        if let array = value as? [Any] { return array.map(sanitize) }
        if let string = value as? String, var url = URLComponents(string: string),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            url.user = nil
            url.password = nil
            let items = url.queryItems?.filter {
                !secretNames.contains(normalized($0.name)) && normalized($0.name) != "key"
            }
            url.queryItems = items?.isEmpty == false ? items : nil
            return url.string ?? string
        }
        return value
    }

    /// Values stripped from the file belong to the receiving device. Match list items by
    /// their stable ID so one provider can never inherit another provider's credentials.
    public static func preservingLocalCredentials(in incoming: Any, from existing: Any?) -> Any {
        if var result = incoming as? [String: Any], let local = existing as? [String: Any] {
            if let id = result["id"] as? String, let oldID = local["id"] as? String, id != oldID { return result }
            for (key, value) in result {
                if normalized(key) == "headers" || normalized(key) == "httpheaders",
                   var headers = value as? [String: Any], let old = local[key] as? [String: Any] {
                    let safe = sanitize([key: old]) as? [String: Any]
                    let portable = safe?[key] as? [String: Any] ?? [:]
                    for (name, credential) in old where portable[name] == nil { headers[name] = credential }
                    result[key] = headers
                } else {
                    result[key] = preservingLocalCredentials(in: value, from: local[key])
                }
            }
            for (key, value) in local {
                let name = normalized(key)
                if (name == "headers" || name == "httpheaders"), result[key] == nil,
                   let old = value as? [String: Any] {
                    let portable = (sanitize([key: old]) as? [String: Any])?[key] as? [String: Any] ?? [:]
                    let retained = old.filter { portable[$0.key] == nil }
                    if !retained.isEmpty { result[key] = retained }
                }
                if secretNames.contains(name) || name == "ssltrustdomains"
                    || (name.hasPrefix("hasexplicit") && name.hasSuffix("consent")) {
                    result[key] = value
                }
            }
            return result
        }
        if let list = incoming as? [Any], let local = existing as? [[String: Any]] {
            return list.map { item in
                guard let object = item as? [String: Any], let id = object["id"] as? String else { return item }
                return preservingLocalCredentials(in: item, from: local.first { $0["id"] as? String == id })
            }
        }
        if let string = incoming as? String, let local = existing as? String,
           sanitize(local) as? String == string { return local }
        return incoming
    }
}

/// Restore files before preferences. A failed write rolls back the files already replaced.
public enum OfflineSettingsFileWriter {
    public static func apply(_ files: [URL: Data],
                             write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        var originals: [URL: Data] = [:]
        var created = Set<URL>()
        var touched: [URL] = []
        let manager = FileManager.default
        for url in files.keys {
            if manager.fileExists(atPath: url.path) { originals[url] = try Data(contentsOf: url) }
            else { created.insert(url) }
        }
        do {
            for url in files.keys.sorted(by: { $0.path < $1.path }) {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                touched.append(url)
                try write(files[url]!, url)
            }
        } catch {
            let originalError = error
            var rollbackFailed = false
            for url in touched.reversed() {
                do {
                    if let data = originals[url] { try data.write(to: url, options: .atomic) }
                    else if created.contains(url), manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw CocoaError(.fileWriteUnknown) }
            throw originalError
        }
    }
}
