import Foundation

public enum AICommercialRegion: String, Codable, Equatable, Hashable, Sendable {
    case mainlandChina
    case international
    case unknown
}

public enum AIRegionSource: String, Codable, Equatable, Sendable {
    case appStorefront
    case localeFallback
    case unresolved
}

public enum AIDistributionEnvironment: String, Codable, Equatable, Sendable {
    case production
    case testing
}

public struct AIRegionContext: Codable, Equatable, Sendable {
    public var region: AICommercialRegion
    public var source: AIRegionSource
    public var countryCode: String?
    public var distributionEnvironment: AIDistributionEnvironment

    public init(
        region: AICommercialRegion,
        source: AIRegionSource,
        countryCode: String? = nil,
        distributionEnvironment: AIDistributionEnvironment = .production
    ) {
        self.region = region
        self.source = source
        self.countryCode = countryCode
        self.distributionEnvironment = distributionEnvironment
    }

    public static let unknown = AIRegionContext(region: .unknown, source: .unresolved)

    private enum CodingKeys: String, CodingKey {
        case region
        case source
        case countryCode
        case distributionEnvironment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = try container.decode(AICommercialRegion.self, forKey: .region)
        source = try container.decode(AIRegionSource.self, forKey: .source)
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        distributionEnvironment = try container.decodeIfPresent(
            AIDistributionEnvironment.self,
            forKey: .distributionEnvironment
        ) ?? .production
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(region, forKey: .region)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(countryCode, forKey: .countryCode)
        try container.encode(distributionEnvironment, forKey: .distributionEnvironment)
    }
}

public struct AIRegionSnapshot: Equatable, Sendable {
    public var context: AIRegionContext
    public var revision: UInt64

    public init(context: AIRegionContext, revision: UInt64) {
        self.context = context
        self.revision = revision
    }
}

public enum AIRegionRequestPolicy {
    public static func canSendRemoteRequest(
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot
    ) -> Bool {
        captured == latest && AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: latest.context
        ).isAllowed
    }

    public static func canCommitRemoteResponse(
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot
    ) -> Bool {
        canSendRemoteRequest(captured: captured, latest: latest)
    }

    public static func canSendRemoteRequest(
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot,
        configuration: AIRemoteProviderConfiguration,
        purpose: AIProviderRegionPurpose = .generation
    ) -> Bool {
        canSendRemoteRequest(captured: captured, latest: latest)
            && AIProviderRegionPolicy.allows(
                configuration: configuration,
                region: latest.context.region,
                purpose: purpose
            )
    }

    public static func canCommitRemoteResponse(
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot,
        configuration: AIRemoteProviderConfiguration,
        purpose: AIProviderRegionPurpose = .generation
    ) -> Bool {
        canSendRemoteRequest(
            captured: captured,
            latest: latest,
            configuration: configuration,
            purpose: purpose
        )
    }
}

public enum AIProviderRegionPurpose: Sendable {
    case modelCatalog
    case generation
}

/// Storefronts choose the preset catalog. Saved and custom providers retain
/// their endpoint and model choices, subject to the same URL safety checks.
public enum AIProviderRegionPolicy {
    public static func allows(
        configuration: AIRemoteProviderConfiguration,
        region: AICommercialRegion,
        purpose: AIProviderRegionPurpose
    ) -> Bool {
        (try? AIRemoteEndpointPolicy.validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )) != nil
    }

    public static func filterModels(
        _ models: [AIProviderModel],
        configuration: AIRemoteProviderConfiguration,
        region: AICommercialRegion
    ) -> [AIProviderModel] {
        models
    }
}

public enum AIRegionResolver {
    private static let mainlandChinaCodes: Set<String> = ["CN", "CHN"]

    /// The App Store storefront is authoritative. Locale is used only to fail
    /// closed for an obvious mainland-China locale while StoreKit is still
    /// unavailable; a non-China locale never upgrades an unknown storefront to
    /// international access.
    public static func resolve(
        storefrontCountryCode: String?,
        localeRegionCode: String?,
        distributionEnvironment: AIDistributionEnvironment = .production
    ) -> AIRegionContext {
        if let storefrontCode = normalizedCountryCode(storefrontCountryCode) {
            return AIRegionContext(
                region: mainlandChinaCodes.contains(storefrontCode) ? .mainlandChina : .international,
                source: .appStorefront,
                countryCode: storefrontCode,
                distributionEnvironment: distributionEnvironment
            )
        }

        if let localeCode = normalizedCountryCode(localeRegionCode),
           mainlandChinaCodes.contains(localeCode) {
            return AIRegionContext(
                region: .mainlandChina,
                source: .localeFallback,
                countryCode: localeCode,
                distributionEnvironment: distributionEnvironment
            )
        }

        return AIRegionContext(
            region: .unknown,
            source: .unresolved,
            distributionEnvironment: distributionEnvironment
        )
    }

    private static func normalizedCountryCode(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (2...3).contains(value.count), value.allSatisfy(\.isLetter) else { return nil }
        return value
    }
}

public enum AIAccessDenialReason: String, Codable, Equatable, Sendable {
    case regionRestricted
    case regionUndetermined
}

public struct AIAccessDecision: Codable, Equatable, Sendable {
    public var isAllowed: Bool
    public var shouldExposeConfiguration: Bool
    public var requiresExplicitConsent: Bool
    public var denialReason: AIAccessDenialReason?

    public init(
        isAllowed: Bool,
        shouldExposeConfiguration: Bool,
        requiresExplicitConsent: Bool,
        denialReason: AIAccessDenialReason? = nil
    ) {
        self.isAllowed = isAllowed
        self.shouldExposeConfiguration = shouldExposeConfiguration
        self.requiresExplicitConsent = requiresExplicitConsent
        self.denialReason = denialReason
    }
}

public enum AIAvailabilityPolicy {
    public static func decision(
        for executionClass: AIExecutionClass,
        regionContext: AIRegionContext
    ) -> AIAccessDecision {
        switch executionClass {
        case .deterministicLocal, .localDiscriminativeModel, .localGenerativeModel:
            return AIAccessDecision(
                isAllowed: true,
                shouldExposeConfiguration: true,
                requiresExplicitConsent: false
            )

        case .userConfiguredRemote:
            return AIAccessDecision(
                isAllowed: true,
                shouldExposeConfiguration: true,
                requiresExplicitConsent: true
            )

        // 内置中转暂不按商店地区拦截，实际可用性由服务响应判断。
        case .bundledRemote:
            return AIAccessDecision(
                isAllowed: true,
                shouldExposeConfiguration: true,
                requiresExplicitConsent: true
            )

        case .appleSystemModel:
            switch regionContext.region {
            case .international:
                return AIAccessDecision(
                    isAllowed: true,
                    shouldExposeConfiguration: true,
                    requiresExplicitConsent: false
                )
            case .mainlandChina:
                return AIAccessDecision(
                    isAllowed: false,
                    shouldExposeConfiguration: false,
                    requiresExplicitConsent: false,
                    denialReason: .regionRestricted
                )
            case .unknown:
                return AIAccessDecision(
                    isAllowed: false,
                    shouldExposeConfiguration: false,
                    requiresExplicitConsent: false,
                    denialReason: .regionUndetermined
                )
            }
        }
    }
}

public enum AIProviderRoutingPolicy {
    public static func candidates(
        from descriptors: [AIProviderDescriptor],
        capability: AICapability,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool
    ) -> [AIProviderDescriptor] {
        descriptors
            .filter { descriptor in
                guard descriptor.isEnabled,
                      descriptor.capabilities.contains(capability) else { return false }
                let decision = AIAvailabilityPolicy.decision(
                    for: descriptor.executionClass,
                    regionContext: regionContext
                )
                guard decision.isAllowed else { return false }
                return !decision.requiresExplicitConsent || hasExplicitRemoteConsent
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
