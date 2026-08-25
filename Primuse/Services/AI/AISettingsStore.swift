import Foundation
import Observation
import PrimuseKit
import StoreKit

@MainActor
@Observable
final class AISettingsStore {
    private struct PersistedSettings: Codable {
        var schemaVersion: Int
        var configuration: AIRemoteProviderConfiguration
        var hasExplicitRemoteConsent: Bool
    }

    private static let storageKey = "ai.settings.v1"
    private let defaults: UserDefaults

    private(set) var configuration: AIRemoteProviderConfiguration
    private(set) var hasExplicitRemoteConsent: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let persisted = try? JSONDecoder().decode(PersistedSettings.self, from: data),
           persisted.schemaVersion == 1 {
            configuration = persisted.configuration
            hasExplicitRemoteConsent = persisted.hasExplicitRemoteConsent
        } else {
            configuration = AIRemoteProviderConfiguration()
            hasExplicitRemoteConsent = false
        }
    }

    func save(
        configuration: AIRemoteProviderConfiguration,
        hasExplicitRemoteConsent: Bool
    ) throws {
        guard AIRequestTimeoutPolicy.validated(configuration.requestTimeout) != nil else {
            throw AIRemoteEndpointValidationError.invalidRequestTimeout
        }
        _ = try AIRemoteEndpointPolicy.validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
        let persisted = PersistedSettings(
            schemaVersion: 1,
            configuration: configuration,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent
        )
        let data = try JSONEncoder().encode(persisted)
        defaults.set(data, forKey: Self.storageKey)
        self.configuration = configuration
        self.hasExplicitRemoteConsent = hasExplicitRemoteConsent
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
