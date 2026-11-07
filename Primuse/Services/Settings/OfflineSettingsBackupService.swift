#if os(iOS) || os(macOS)
import Foundation
import CoreText
import WidgetKit
import PrimuseKit

@MainActor
enum OfflineSettingsBackupService {
    static func snapshot(defaults: UserDefaults, sharedDefaults: UserDefaults?) throws -> OfflineSettingsBackup {
        func collect(_ defaults: UserDefaults?, keys: Set<String>) throws -> OfflineSettingsBackup.Preferences {
            var values: [String: Data] = [:]
            for key in keys.sorted() {
                guard let value = defaults?.object(forKey: key) else { continue }
                guard let encoded = LANSettingsBundle.encodeValue(try portableValue(value, key: key)) else {
                    throw OfflineSettingsBackupError.invalidSetting
                }
                values[key] = encoded
            }
            return .init(keys: keys.sorted(), values: values)
        }
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        return try OfflineSettingsBackup(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            platform: platform,
            standard: collect(defaults, keys: OfflineSettingsCatalog.standardKeys),
            shared: collect(sharedDefaults, keys: sharedDefaults == nil ? [] : OfflineSettingsCatalog.sharedKeys)
        )
    }

    static func export() async throws -> Data {
        var backup = try snapshot(defaults: .standard, sharedDefaults: sharedDefaults)
        let imageIDs = PlayerBackdropSettingsStore.shared.customImageIDs
        let configs = ScraperConfigStore.shared.allConfigsIncludingDeleted
        backup.assets = try await Task.detached(priority: .utility) {
            var assets: [OfflineSettingsBackup.Asset] = []
            for id in imageIDs {
                guard let data = PlayerBackdropImageStore.data(id: id) else { throw OfflineSettingsBackupError.invalidAsset }
                assets.append(.init(kind: .backdrop, name: id, data: data))
            }
            let folder = ImportedPlayerTextFontFiles.directory
            if FileManager.default.fileExists(atPath: folder.path) {
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles)
                for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard ["ttf", "otf", "ttc", "otc"].contains(url.pathExtension.lowercased()),
                          info.isRegularFile == true else { continue }
                    guard (info.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw OfflineSettingsBackupError.tooLarge }
                    assets.append(.init(kind: .font, name: url.lastPathComponent, data: try Data(contentsOf: url)))
                }
            }
            for config in configs {
                assets.append(.init(kind: .scraper, name: config.id,
                                    data: try OfflineSettingsRedaction.json(JSONEncoder().encode(config))))
            }
            return assets
        }.value
        let validated = try validate(backup)
        return try await Task.detached(priority: .utility) { try validated.encoded() }.value
    }

    static func read(_ url: URL) async throws -> OfflineSettingsBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let backup = try await Task.detached(priority: .userInitiated) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= OfflineSettingsBackup.maximumFileBytes else { throw OfflineSettingsBackupError.tooLarge }
            return try OfflineSettingsBackup.decode(Data(contentsOf: url))
        }.value
        return try validate(backup)
    }

    static func validate(_ incoming: OfflineSettingsBackup) throws -> OfflineSettingsBackup {
        var backup = incoming
        try backup.standard.validate(allowedKeys: OfflineSettingsCatalog.standardKeys)
        try backup.shared.validate(allowedKeys: OfflineSettingsCatalog.sharedKeys)
        try backup.validateAssets()
        for (key, data) in backup.standard.values {
            guard let value = LANSettingsBundle.decodeValue(data),
                  let encoded = LANSettingsBundle.encodeValue(try portableValue(value, key: key)) else {
                throw OfflineSettingsBackupError.invalidSetting
            }
            backup.standard.values[key] = encoded
        }
        for index in backup.assets.indices {
            let asset = backup.assets[index]
            switch asset.kind {
            case .backdrop:
                guard asset.data.count <= PlayerBackdropImageStore.maximumStoredBytes,
                      PlayerBackdropImaging.decodedImage(data: asset.data, maxPixel: 64) != nil else {
                    throw OfflineSettingsBackupError.invalidAsset
                }
            case .font:
                let faces = CTFontManagerCreateFontDescriptorsFromData(asset.data as CFData)
                guard CFArrayGetCount(faces) > 0 else { throw OfflineSettingsBackupError.invalidAsset }
            case .scraper:
                let sanitized = try OfflineSettingsRedaction.json(asset.data)
                let summary = try ScraperConfigStore.shared.previewImportFromJSON(String(decoding: sanitized, as: UTF8.self))
                guard summary.configs.count == 1, summary.configs[0].id == asset.name else {
                    throw OfflineSettingsBackupError.invalidAsset
                }
                backup.assets[index].data = sanitized
            }
        }
        if let encoded = backup.standard.values[PlayerBackdropSettings.customImagesStorageKey] {
            guard let ids = LANSettingsBundle.decodeValue(encoded) as? [String],
                  Set(ids).isSubset(of: Set(backup.assets.filter { $0.kind == .backdrop }.map(\.name))) else {
                throw OfflineSettingsBackupError.invalidAsset
            }
        }
        return backup
    }

    static func restorePreferences(_ backup: OfflineSettingsBackup, defaults: UserDefaults, cloud: CloudKVSSync,
                                   sharedDefaults: UserDefaults?) throws {
        try backup.standard.validate(allowedKeys: OfflineSettingsCatalog.standardKeys)
        try backup.shared.validate(allowedKeys: OfflineSettingsCatalog.sharedKeys)
        var values: [String: Any] = [:]
        for (key, data) in backup.standard.values {
            guard let value = LANSettingsBundle.decodeValue(data) else { throw OfflineSettingsBackupError.invalidSetting }
            let portable = try portableValue(value, key: key)
            if let data = portable as? Data {
                let incoming = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
                let local = defaults.data(forKey: key).flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
                values[key] = try JSONSerialization.data(withJSONObject:
                    OfflineSettingsRedaction.preservingLocalCredentials(in: incoming, from: local), options: [.sortedKeys, .fragmentsAllowed])
            } else {
                values[key] = OfflineSettingsRedaction.preservingLocalCredentials(in: portable, from: defaults.object(forKey: key))
            }
        }
        cloud.applyOfflineSnapshot(values: values, restoringKeys: Set(backup.standard.keys))
        for key in backup.shared.keys {
            if let data = backup.shared.values[key], let value = LANSettingsBundle.decodeValue(data) {
                sharedDefaults?.set(value, forKey: key)
            } else { sharedDefaults?.removeObject(forKey: key) }
        }
    }

    static func restore(_ incoming: OfflineSettingsBackup) async throws {
        let backup = try validate(incoming)
        var configs: [ScraperConfig] = []
        var files: [URL: Data] = [:]
        for asset in backup.assets {
            switch asset.kind {
            case .backdrop:
                guard let url = PlayerBackdropImageStore.fileURL(id: asset.name) else { throw OfflineSettingsBackupError.invalidAsset }
                files[url] = asset.data
            case .font:
                files[ImportedPlayerTextFontFiles.directory.appendingPathComponent(asset.name)] = asset.data
            case .scraper:
                configs.append(try JSONDecoder().decode(ScraperConfig.self, from: asset.data))
            }
        }
        // All fallible file operations complete before defaults or observable stores are changed.
        try ScraperConfigStore.shared.restoreOfflineConfigs(configs, additionalFiles: files)
        try restorePreferences(backup, defaults: .standard, cloud: .shared, sharedDefaults: sharedDefaults)
        PlayerBackdropSettingsStore.shared.reloadAfterOfflineImport()
        LyricsTranslationSettingsStore.shared.reloadAfterOfflineImport()
        LyricsRomanizationSettingsStore.shared.reloadAfterOfflineImport()
        ScrobbleSettingsStore.shared.reloadAfterOfflineImport()
        SmartNudgeCenter.shared.reloadAfterOfflineImport()
        AppServices.shared.playerService.equalizerService.reloadAfterOfflineImport()
        #if os(iOS)
        CarPlaySettingsStore.shared.reloadAfterOfflineImport()
        #else
        MacUIPreferences.shared.reloadAfterOfflineImport()
        #endif
        CloudKVSSync.shared.finishOfflineSnapshot(keys: Set(backup.standard.keys))
        if backup.assets.contains(where: { $0.kind == .font }) { PlayerTextFontLibrary.shared.loadImportedFonts() }
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        if backup.platform == "iOS", backup.standard.keys.contains(AppIconService.storageKey) {
            let service = AppIconService.shared
            let id = UserDefaults.standard.string(forKey: AppIconService.storageKey) ?? ""
            if service.supportsAlternateIcons, let option = service.availableOptions.first(where: { $0.id == id }) {
                _ = await service.setIcon(option)
            }
        }
        #endif
    }

    private static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier) }

    private static func portableValue(_ value: Any, key: String) throws -> Any {
        if OfflineSettingsCatalog.jsonKeys.contains(key), !(value is Data) { throw OfflineSettingsBackupError.invalidSetting }
        if let data = value as? Data {
            let sanitized = try OfflineSettingsRedaction.json(data)
            if OfflineSettingsCatalog.jsonKeys.contains(key) {
                let decoded = try JSONSerialization.jsonObject(with: sanitized)
                guard decoded is [String: Any] || (key == "primuse.carplay.savedLayouts.v1" && decoded is [Any]) else {
                    throw OfflineSettingsBackupError.invalidSetting
                }
            }
            if key == PlaybackSettings.defaultsKey { _ = try JSONDecoder().decode(PlaybackSettings.self, from: sanitized) }
            if key == ScraperSettings.defaultsKey { _ = try JSONDecoder().decode(ScraperSettings.self, from: sanitized) }
            if key == LyricsAPIServerSettings.defaultsKey { _ = try JSONDecoder().decode(LyricsAPIServerSettings.self, from: sanitized) }
            return sanitized
        }
        return OfflineSettingsRedaction.sanitize(value)
    }
}
#endif
