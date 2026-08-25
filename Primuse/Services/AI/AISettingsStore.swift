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
    private(set) var isRefreshing = false

    var remoteProviderDecision: AIAccessDecision {
        AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: context
        )
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let storefront = await Storefront.current
        context = AIRegionResolver.resolve(
            storefrontCountryCode: storefront?.countryCode,
            localeRegionCode: Locale.current.region?.identifier
        )
    }
}
