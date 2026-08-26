import Foundation
import Observation
import PrimuseKit
import StoreKit

@MainActor
@Observable
final class AISettingsStore {
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

    private(set) var providerSet: AIRemoteProviderSet
    private(set) var semanticSearchEnabled: Bool
    private(set) var recommendationsEnabled: Bool
    private(set) var hasExplicitRemoteConsent: Bool
    private(set) var hasExplicitListeningContextConsent: Bool
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
        let loaded = Self.decodeSettings(from: defaults.data(forKey: Self.storageKey))
        providerSet = loaded.providerSet
        semanticSearchEnabled = loaded.semanticSearchEnabled
        recommendationsEnabled = loaded.recommendationsEnabled
        hasExplicitRemoteConsent = loaded.hasExplicitRemoteConsent
        hasExplicitListeningContextConsent = loaded.hasExplicitListeningContextConsent

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
        hasExplicitRemoteConsent: Bool,
        hasExplicitListeningContextConsent: Bool = false
    ) throws {
        let normalized = providerSet.normalized()
        for provider in normalized.providers where provider.isEnabled {
            _ = try AIRemoteEndpointPolicy.generationEndpoint(configuration: provider)
        }
        let persisted = PersistedSettingsV3(
            schemaVersion: 3,
            providerSet: normalized,
            semanticSearchEnabled: semanticSearchEnabled,
            recommendationsEnabled: recommendationsEnabled,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent,
            hasExplicitListeningContextConsent: hasExplicitListeningContextConsent
        )
        let data = try JSONEncoder().encode(persisted)
        defaults.set(data, forKey: Self.storageKey)
        self.providerSet = normalized
        self.semanticSearchEnabled = semanticSearchEnabled
        self.recommendationsEnabled = recommendationsEnabled
        self.hasExplicitRemoteConsent = hasExplicitRemoteConsent
        self.hasExplicitListeningContextConsent = hasExplicitListeningContextConsent
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
            hasExplicitRemoteConsent: hasExplicitRemoteConsent,
            hasExplicitListeningContextConsent: false
        )
    }

    private func reloadFromDefaults() {
        let loaded = Self.decodeSettings(from: defaults.data(forKey: Self.storageKey))
        providerSet = loaded.providerSet
        semanticSearchEnabled = loaded.semanticSearchEnabled
        recommendationsEnabled = loaded.recommendationsEnabled
        hasExplicitRemoteConsent = loaded.hasExplicitRemoteConsent
        hasExplicitListeningContextConsent = loaded.hasExplicitListeningContextConsent
        revision &+= 1
    }

    private static func decodeSettings(
        from data: Data?
    ) -> (
        providerSet: AIRemoteProviderSet,
        semanticSearchEnabled: Bool,
        recommendationsEnabled: Bool,
        hasExplicitRemoteConsent: Bool,
        hasExplicitListeningContextConsent: Bool
    ) {
        if let data,
           let persisted = try? JSONDecoder().decode(PersistedSettingsV3.self, from: data),
           persisted.schemaVersion == 3 {
            return (
                persisted.providerSet.normalized(),
                persisted.semanticSearchEnabled,
                persisted.recommendationsEnabled,
                persisted.hasExplicitRemoteConsent,
                persisted.hasExplicitListeningContextConsent
            )
        }
        if let data,
           let persisted = try? JSONDecoder().decode(PersistedSettingsV2.self, from: data),
           persisted.schemaVersion == 2 {
            return (
                persisted.providerSet.normalized(),
                persisted.semanticSearchEnabled,
                false,
                persisted.hasExplicitRemoteConsent,
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
                persisted.hasExplicitRemoteConsent,
                false
            )
        }
        return (AIRemoteProviderSet(), false, false, false, false)
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
