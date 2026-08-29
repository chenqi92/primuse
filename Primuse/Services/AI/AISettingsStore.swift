import Foundation
import Observation
import PrimuseKit
import StoreKit

@MainActor
@Observable
final class AISettingsStore {
    private struct PersistedSettingsV4: Codable {
        var schemaVersion: Int
        var providerSet: AIRemoteProviderSet
        var semanticSearchEnabled: Bool
        var recommendationsEnabled: Bool
        var audioTranscriptionEnabled: Bool
        var hasExplicitRemoteConsent: Bool
        var hasExplicitListeningContextConsent: Bool
        var hasExplicitAudioUploadConsent: Bool
    }

    private struct PersistedSettingsV3: Codable {
        var schemaVersion: Int
        var providerSet: AIRemoteProviderSet
        var semanticSearchEnabled: Bool
        var recommendationsEnabled: Bool
        var hasExplicitRemoteConsent: Bool
        var hasExplicitListeningContextConsent: Bool
    }

    private struct PersistedSettingsV2: Codable {
        var schemaVersion: Int
        var providerSet: AIRemoteProviderSet
        var semanticSearchEnabled: Bool
        var hasExplicitRemoteConsent: Bool
    }

    private struct PersistedSettingsV1: Codable {
        var schemaVersion: Int
        var configuration: AIRemoteProviderConfiguration
        var hasExplicitRemoteConsent: Bool
    }

    nonisolated static let storageKey = "ai.settings.v1"
    private let defaults: UserDefaults
    private let syncsThroughICloud: Bool
    @ObservationIgnored var externalReloadHandler: (() -> Void)?

    private(set) var providerSet: AIRemoteProviderSet
    private(set) var semanticSearchEnabled: Bool
    private(set) var recommendationsEnabled: Bool
    private(set) var audioTranscriptionEnabled: Bool
    private(set) var hasExplicitRemoteConsent: Bool
    private(set) var hasExplicitListeningContextConsent: Bool
    private(set) var hasExplicitAudioUploadConsent: Bool
    private(set) var hasPersistedSettings: Bool
    private(set) var revision: UInt64 = 0

    var configuration: AIRemoteProviderConfiguration {
        providerSet.primaryProvider
    }

    init(
        defaults: UserDefaults = .standard,
        syncsThroughICloud: Bool? = nil
    ) {
        self.defaults = defaults
        self.syncsThroughICloud = syncsThroughICloud ?? (defaults === UserDefaults.standard)
        let persistedData = defaults.data(forKey: Self.storageKey)
        let loaded = Self.decodeSettings(from: persistedData)
        providerSet = loaded.providerSet
        semanticSearchEnabled = loaded.semanticSearchEnabled
        recommendationsEnabled = loaded.recommendationsEnabled
        audioTranscriptionEnabled = loaded.audioTranscriptionEnabled
        hasExplicitRemoteConsent = loaded.hasExplicitRemoteConsent
        hasExplicitListeningContextConsent = loaded.hasExplicitListeningContextConsent
        hasExplicitAudioUploadConsent = loaded.hasExplicitAudioUploadConsent
        hasPersistedSettings = persistedData != nil

        if self.syncsThroughICloud {
            CloudKVSSync.shared.register(key: Self.storageKey) { [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    func save(
        providerSet: AIRemoteProviderSet,
        semanticSearchEnabled: Bool,
        recommendationsEnabled: Bool = false,
        audioTranscriptionEnabled: Bool = false,
        hasExplicitRemoteConsent: Bool,
        hasExplicitListeningContextConsent: Bool = false,
        hasExplicitAudioUploadConsent: Bool = false
    ) throws {
        let normalized = providerSet.normalized()
        for provider in normalized.providers where provider.isEnabled {
            _ = try AIRemoteEndpointPolicy.generationEndpoint(configuration: provider)
        }
        if audioTranscriptionEnabled,
           !normalized.routedProviders.contains(where: {
               AIAudioTranscriptionPolicy.supports(configuration: $0)
           }) {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }
        let persisted = PersistedSettingsV4(
            schemaVersion: 4,
            providerSet: normalized,
            semanticSearchEnabled: semanticSearchEnabled,
            recommendationsEnabled: recommendationsEnabled,
            audioTranscriptionEnabled: audioTranscriptionEnabled,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent,
            hasExplicitListeningContextConsent: hasExplicitListeningContextConsent,
            hasExplicitAudioUploadConsent: hasExplicitAudioUploadConsent
        )
        let data = try JSONEncoder().encode(persisted)
        defaults.set(data, forKey: Self.storageKey)
        self.providerSet = normalized
        self.semanticSearchEnabled = semanticSearchEnabled
        self.recommendationsEnabled = recommendationsEnabled
        self.audioTranscriptionEnabled = audioTranscriptionEnabled
        self.hasExplicitRemoteConsent = hasExplicitRemoteConsent
        self.hasExplicitListeningContextConsent = hasExplicitListeningContextConsent
        self.hasExplicitAudioUploadConsent = hasExplicitAudioUploadConsent
        hasPersistedSettings = true
        revision &+= 1
        if syncsThroughICloud {
            CloudKVSSync.shared.markChanged(key: Self.storageKey)
        }
    }

    func save(
        configuration: AIRemoteProviderConfiguration,
        hasExplicitRemoteConsent: Bool
    ) throws {
        try save(
            providerSet: AIRemoteProviderSet(
                providers: [configuration],
                primaryProviderID: configuration.id,
                fallbackEnabled: false
            ),
            semanticSearchEnabled: configuration.isEnabled,
            recommendationsEnabled: false,
            audioTranscriptionEnabled: false,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent,
            hasExplicitListeningContextConsent: false,
            hasExplicitAudioUploadConsent: false
        )
    }

    private func reloadFromDefaults() {
        let persistedData = defaults.data(forKey: Self.storageKey)
        let loaded = Self.decodeSettings(from: persistedData)
        providerSet = loaded.providerSet
        semanticSearchEnabled = loaded.semanticSearchEnabled
        recommendationsEnabled = loaded.recommendationsEnabled
        audioTranscriptionEnabled = loaded.audioTranscriptionEnabled
        hasExplicitRemoteConsent = loaded.hasExplicitRemoteConsent
        hasExplicitListeningContextConsent = loaded.hasExplicitListeningContextConsent
        hasExplicitAudioUploadConsent = loaded.hasExplicitAudioUploadConsent
        hasPersistedSettings = persistedData != nil
        revision &+= 1
        externalReloadHandler?()
    }

    private static func decodeSettings(
        from data: Data?
    ) -> (
        providerSet: AIRemoteProviderSet,
        semanticSearchEnabled: Bool,
        recommendationsEnabled: Bool,
        audioTranscriptionEnabled: Bool,
        hasExplicitRemoteConsent: Bool,
        hasExplicitListeningContextConsent: Bool,
        hasExplicitAudioUploadConsent: Bool
    ) {
        if let data,
           let persisted = try? JSONDecoder().decode(PersistedSettingsV4.self, from: data),
           persisted.schemaVersion == 4 {
            return (
                persisted.providerSet.normalized(),
                persisted.semanticSearchEnabled,
                persisted.recommendationsEnabled,
                persisted.audioTranscriptionEnabled,
                persisted.hasExplicitRemoteConsent,
                persisted.hasExplicitListeningContextConsent,
                persisted.hasExplicitAudioUploadConsent
            )
        }
        if let data,
           let persisted = try? JSONDecoder().decode(PersistedSettingsV3.self, from: data),
           persisted.schemaVersion == 3 {
            return (
                persisted.providerSet.normalized(),
                persisted.semanticSearchEnabled,
                persisted.recommendationsEnabled,
                false,
                persisted.hasExplicitRemoteConsent,
                persisted.hasExplicitListeningContextConsent,
                false
            )
        }
        if let data,
           let persisted = try? JSONDecoder().decode(PersistedSettingsV2.self, from: data),
           persisted.schemaVersion == 2 {
            return (
                persisted.providerSet.normalized(),
                persisted.semanticSearchEnabled,
                false,
                false,
                persisted.hasExplicitRemoteConsent,
                false,
                false
            )
        }
        if let data,
           let persisted = try? JSONDecoder().decode(PersistedSettingsV1.self, from: data),
           persisted.schemaVersion == 1 {
            var provider = persisted.configuration
            let semanticSearchEnabled = provider.isEnabled
            provider.isEnabled = true
            return (
                AIRemoteProviderSet(
                    providers: [provider],
                    primaryProviderID: provider.id,
                    fallbackEnabled: false
                ),
                semanticSearchEnabled,
                false,
                false,
                persisted.hasExplicitRemoteConsent,
                false,
                false
            )
        }
        return (AIRemoteProviderSet(), false, false, false, false, false, false)
    }
}

@MainActor
@Observable
final class LyricsTranscriptionSettingsStore {
    private struct PersistedSettingsV1: Codable {
        var schemaVersion: Int
        var configuration: AIRemoteProviderConfiguration
        var isEnabled: Bool
        var hasExplicitAudioUploadConsent: Bool
        var legacyCredentialConfiguration: AIRemoteProviderConfiguration?
        var credentialMigrationCompleted: Bool
        var awaitsLegacySettingsMigration: Bool?
    }

    nonisolated static let storageKey = "lyrics.transcription.settings.v1"

    private let defaults: UserDefaults
    private let syncsThroughICloud: Bool
    @ObservationIgnored var externalReloadHandler: (() -> Void)?
    private(set) var configuration: AIRemoteProviderConfiguration
    private(set) var isEnabled: Bool
    private(set) var hasExplicitAudioUploadConsent: Bool
    private(set) var legacyCredentialConfiguration: AIRemoteProviderConfiguration?
    private(set) var credentialMigrationCompleted: Bool
    private(set) var awaitsLegacySettingsMigration: Bool
    private(set) var revision: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        legacySettingsStore: AISettingsStore? = nil,
        syncsThroughICloud: Bool? = nil,
        identifier: @autoclosure () -> UUID = UUID()
    ) {
        self.defaults = defaults
        self.syncsThroughICloud = syncsThroughICloud ?? (defaults === UserDefaults.standard)

        if let data = defaults.data(forKey: Self.storageKey),
           let persisted = try? JSONDecoder().decode(PersistedSettingsV1.self, from: data),
           persisted.schemaVersion == 1 {
            let normalized = Self.normalizedGoogleConfiguration(persisted.configuration)
            configuration = normalized
            isEnabled = persisted.isEnabled
                && AIAudioTranscriptionPolicy.supports(configuration: normalized)
            hasExplicitAudioUploadConsent = persisted.hasExplicitAudioUploadConsent
            legacyCredentialConfiguration = persisted.legacyCredentialConfiguration
            credentialMigrationCompleted = persisted.credentialMigrationCompleted
            awaitsLegacySettingsMigration = persisted.awaitsLegacySettingsMigration
                ?? (persisted.legacyCredentialConfiguration == nil
                    && normalized.transcriptionModel.isEmpty)
        } else if let legacySettingsStore,
                  let legacy = Self.legacyConfiguration(from: legacySettingsStore) {
            var migrated = Self.normalizedGoogleConfiguration(legacy)
            migrated.id = identifier()
            configuration = migrated
            isEnabled = legacySettingsStore.audioTranscriptionEnabled
                && AIAudioTranscriptionPolicy.supports(configuration: migrated)
            hasExplicitAudioUploadConsent = legacySettingsStore
                .hasExplicitAudioUploadConsent
            legacyCredentialConfiguration = legacy
            credentialMigrationCompleted = false
            awaitsLegacySettingsMigration = false
            persistCurrentSettings()
        } else {
            configuration = Self.defaultConfiguration(id: identifier())
            isEnabled = false
            hasExplicitAudioUploadConsent = false
            legacyCredentialConfiguration = nil
            credentialMigrationCompleted = true
            awaitsLegacySettingsMigration = true
            // Keep a concrete disabled value in UserDefaults. A manual settings
            // sync must not interpret a fresh device's missing value as a
            // deletion of transcription settings configured on another device.
            persistCurrentSettings()
        }

        if self.syncsThroughICloud {
            CloudKVSSync.shared.register(key: Self.storageKey) { [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    static func defaultConfiguration(id: UUID = UUID()) -> AIRemoteProviderConfiguration {
        AIRemoteProviderConfiguration(
            id: id,
            displayName: "Google",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiStyle: .geminiGenerateContent,
            apiPathMode: .asEntered,
            authenticationStyle: .xGoogAPIKey,
            generationModel: "",
            embeddingModel: "",
            transcriptionModel: "",
            isEnabled: true
        )
    }

    func save(
        configuration: AIRemoteProviderConfiguration,
        isEnabled: Bool,
        hasExplicitAudioUploadConsent: Bool,
        credentialMigrationCompleted: Bool = true
    ) throws {
        let normalized = Self.normalizedGoogleConfiguration(configuration)
        guard AIAudioTranscriptionPolicy.isCompatibleEndpoint(
            configuration: normalized
        ) else {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }
        if isEnabled,
           !AIAudioTranscriptionPolicy.supports(configuration: normalized) {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }
        let persisted = PersistedSettingsV1(
            schemaVersion: 1,
            configuration: normalized,
            isEnabled: isEnabled,
            hasExplicitAudioUploadConsent: hasExplicitAudioUploadConsent,
            legacyCredentialConfiguration: legacyCredentialConfiguration,
            credentialMigrationCompleted: credentialMigrationCompleted,
            awaitsLegacySettingsMigration: false
        )
        defaults.set(try JSONEncoder().encode(persisted), forKey: Self.storageKey)
        self.configuration = normalized
        self.isEnabled = isEnabled
        self.hasExplicitAudioUploadConsent = hasExplicitAudioUploadConsent
        self.credentialMigrationCompleted = credentialMigrationCompleted
        awaitsLegacySettingsMigration = false
        revision &+= 1
        if syncsThroughICloud {
            CloudKVSSync.shared.markChanged(key: Self.storageKey)
        }
    }

    func markCredentialMigrationCompleted() {
        guard !credentialMigrationCompleted else { return }
        credentialMigrationCompleted = true
        persistCurrentSettings()
        revision &+= 1
        if syncsThroughICloud {
            CloudKVSSync.shared.markChanged(key: Self.storageKey)
        }
    }

    private func reloadFromDefaults() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let persisted = try? JSONDecoder().decode(PersistedSettingsV1.self, from: data),
              persisted.schemaVersion == 1 else { return }
        configuration = Self.normalizedGoogleConfiguration(persisted.configuration)
        isEnabled = persisted.isEnabled
            && AIAudioTranscriptionPolicy.supports(configuration: configuration)
        hasExplicitAudioUploadConsent = persisted.hasExplicitAudioUploadConsent
        legacyCredentialConfiguration = persisted.legacyCredentialConfiguration
        credentialMigrationCompleted = persisted.credentialMigrationCompleted
        awaitsLegacySettingsMigration = persisted.awaitsLegacySettingsMigration
            ?? (persisted.legacyCredentialConfiguration == nil
                && configuration.transcriptionModel.isEmpty)
        revision &+= 1
        externalReloadHandler?()
    }

    private func persistCurrentSettings() {
        let persisted = PersistedSettingsV1(
            schemaVersion: 1,
            configuration: configuration,
            isEnabled: isEnabled,
            hasExplicitAudioUploadConsent: hasExplicitAudioUploadConsent,
            legacyCredentialConfiguration: legacyCredentialConfiguration,
            credentialMigrationCompleted: credentialMigrationCompleted,
            awaitsLegacySettingsMigration: awaitsLegacySettingsMigration
        )
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    @discardableResult
    func adoptLegacySettingsIfNeeded(from store: AISettingsStore) -> Bool {
        guard awaitsLegacySettingsMigration,
              legacyCredentialConfiguration == nil,
              configuration.transcriptionModel.isEmpty,
              !isEnabled,
              !hasExplicitAudioUploadConsent,
              let legacy = Self.legacyConfiguration(from: store) else {
            return false
        }

        var migrated = Self.normalizedGoogleConfiguration(legacy)
        migrated.id = configuration.id
        configuration = migrated
        isEnabled = store.audioTranscriptionEnabled
            && AIAudioTranscriptionPolicy.supports(configuration: migrated)
        hasExplicitAudioUploadConsent = store.hasExplicitAudioUploadConsent
        legacyCredentialConfiguration = legacy
        credentialMigrationCompleted = false
        awaitsLegacySettingsMigration = false
        persistCurrentSettings()
        revision &+= 1
        if syncsThroughICloud {
            CloudKVSSync.shared.markChanged(key: Self.storageKey)
        }
        return true
    }

    private static func legacyConfiguration(
        from store: AISettingsStore
    ) -> AIRemoteProviderConfiguration? {
        let routed = store.providerSet.routedProviders
        let routedIDs = Set(routed.map(\.id))
        let remaining = store.providerSet.providers.filter { !routedIDs.contains($0.id) }
        return (routed + remaining).first {
            AIAudioTranscriptionPolicy.isCompatibleEndpoint(configuration: $0)
                && AIAudioTranscriptionPolicy.isSupportedModelID($0.transcriptionModel)
        }
    }

    static func normalizedGoogleConfiguration(
        _ source: AIRemoteProviderConfiguration
    ) -> AIRemoteProviderConfiguration {
        var configuration = source
        configuration.displayName = "Google"
        configuration.baseURL = "https://generativelanguage.googleapis.com/v1beta"
        configuration.apiStyle = .geminiGenerateContent
        configuration.apiPathMode = .asEntered
        configuration.authenticationStyle = .xGoogAPIKey
        configuration.generationModel = ""
        configuration.embeddingModel = ""
        configuration.transcriptionModel = AIAudioTranscriptionPolicy.normalizedModel(
            source.transcriptionModel
        )
        configuration.allowInsecureLocalHTTP = false
        configuration.isEnabled = true
        configuration.prefersCustomConfiguration = false
        return configuration
    }
}

@MainActor
@Observable
final class AIRegionAvailabilityService {
    private(set) var context: AIRegionContext = .unknown
    private(set) var revision: UInt64 = 0
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var storefrontUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var contextDidChange: (@MainActor @Sendable () -> Void)?

    var snapshot: AIRegionSnapshot {
        AIRegionSnapshot(context: context, revision: revision)
    }

    var remoteProviderDecision: AIAccessDecision {
        AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: context
        )
    }

    func start(onContextChange: @escaping @MainActor @Sendable () -> Void) {
        contextDidChange = onContextChange
        guard storefrontUpdatesTask == nil else { return }

        storefrontUpdatesTask = Task { @MainActor [weak self] in
            for await storefront in Storefront.updates {
                guard !Task.isCancelled, let self else { return }
                await self.applyStorefrontUpdate(countryCode: storefront.countryCode)
            }
        }
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let generation = invalidateContext()
        let storefront = await Storefront.current
        guard generation == refreshGeneration else { return }
        publishContext(AIRegionResolver.resolve(
            storefrontCountryCode: storefront?.countryCode,
            localeRegionCode: Locale.current.region?.identifier
        ))
    }

    private func applyStorefrontUpdate(countryCode: String) async {
        let generation = invalidateContext()
        await Task.yield()
        guard generation == refreshGeneration else { return }
        publishContext(AIRegionResolver.resolve(
            storefrontCountryCode: countryCode,
            localeRegionCode: Locale.current.region?.identifier
        ))
    }

    @discardableResult
    private func invalidateContext() -> UInt64 {
        refreshGeneration &+= 1
        revision &+= 1
        context = .unknown
        contextDidChange?()
        return refreshGeneration
    }

    private func publishContext(_ newContext: AIRegionContext) {
        revision &+= 1
        context = newContext
        contextDidChange?()
    }

    deinit {
        storefrontUpdatesTask?.cancel()
    }
}
