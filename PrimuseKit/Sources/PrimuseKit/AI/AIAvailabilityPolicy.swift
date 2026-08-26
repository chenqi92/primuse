import Foundation

public enum AICommercialRegion: String, Codable, Equatable, Sendable {
    case mainlandChina
    case international
    case unknown
}

public enum AIRegionSource: String, Codable, Equatable, Sendable {
    case appStorefront
    case localeFallback
    case unresolved
}

public struct AIRegionContext: Codable, Equatable, Sendable {
    public var region: AICommercialRegion
    public var source: AIRegionSource
    public var countryCode: String?

    public init(
        region: AICommercialRegion,
        source: AIRegionSource,
        countryCode: String? = nil
    ) {
        self.region = region
        self.source = source
        self.countryCode = countryCode
    }

    public static let unknown = AIRegionContext(region: .unknown, source: .unresolved)
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
}

public enum AIRegionResolver {
    private static let mainlandChinaCodes: Set<String> = ["CN", "CHN"]

    /// The App Store storefront is authoritative. Locale is used only to fail
    /// closed for an obvious mainland-China locale while StoreKit is still
    /// unavailable; a non-China locale never upgrades an unknown storefront to
    /// international access.
    public static func resolve(
        storefrontCountryCode: String?,
        localeRegionCode: String?
    ) -> AIRegionContext {
        if let storefrontCode = normalizedCountryCode(storefrontCountryCode) {
            return AIRegionContext(
                region: mainlandChinaCodes.contains(storefrontCode) ? .mainlandChina : .international,
                source: .appStorefront,
                countryCode: storefrontCode
            )
        }

        if let localeCode = normalizedCountryCode(localeRegionCode),
           mainlandChinaCodes.contains(localeCode) {
            return AIRegionContext(
                region: .mainlandChina,
                source: .localeFallback,
                countryCode: localeCode
            )
        }

        return .unknown
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

        case .appleSystemModel, .userConfiguredRemote, .bundledRemote:
            switch regionContext.region {
            case .international:
                let requiresConsent: Bool
                switch executionClass {
                case .userConfiguredRemote, .bundledRemote:
                    requiresConsent = true
                default:
                    requiresConsent = false
                }
                return AIAccessDecision(
                    isAllowed: true,
                    shouldExposeConfiguration: true,
                    requiresExplicitConsent: requiresConsent
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
