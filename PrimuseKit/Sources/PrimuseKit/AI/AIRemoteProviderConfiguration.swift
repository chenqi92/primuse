import Foundation

public enum AICompatibleAPIStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case responses
    case chatCompletions
    case anthropicMessages
}

public enum AIAPIPathMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Chooses the provider's documented convention while preserving an
    /// explicitly versioned or provider-specific path entered by the user.
    case automatic
    /// Appends request paths directly to the configured base URL.
    case asEntered
    /// Ensures `/v1` exists immediately before the request path.
    case appendV1
}

public enum AIAuthenticationStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case bearer
    case xAPIKey

    public func resolved(for apiStyle: AICompatibleAPIStyle) -> AIAuthenticationStyle {
        guard self == .automatic else { return self }
        return apiStyle == .anthropicMessages ? .xAPIKey : .bearer
    }
}

/// User-facing compatibility choices for a custom endpoint. The detailed
/// path and authentication fields remain part of the persisted provider
/// configuration, while common gateways can be configured with one choice.
public enum AIProviderCompatibilityMode: String, CaseIterable, Hashable, Sendable {
    case openAIResponses
    case openAIChatCompletions
    case anthropicMessages

    public init(configuration: AIRemoteProviderConfiguration) {
        switch configuration.apiStyle {
        case .responses:
            self = .openAIResponses
        case .chatCompletions:
            self = .openAIChatCompletions
        case .anthropicMessages:
            self = .anthropicMessages
        }
    }

    public func applying(
        to original: AIRemoteProviderConfiguration
    ) -> AIRemoteProviderConfiguration {
        var configuration = original
        configuration.apiPathMode = .automatic
        configuration.authenticationStyle = .automatic
        switch self {
        case .openAIResponses:
            configuration.apiStyle = .responses
        case .openAIChatCompletions:
            configuration.apiStyle = .chatCompletions
        case .anthropicMessages:
            configuration.apiStyle = .anthropicMessages
            configuration.embeddingModel = ""
        }
        return configuration
    }
}

public enum AIProviderPreset: String, CaseIterable, Hashable, Sendable {
    case custom
    case openAI
    case anthropic
    case gemini
    case deepSeekOpenAI
    case deepSeekAnthropic
    case qwen
    case zhipu

    /// Curated presets shown for a storefront. Mainland-China entries use
    /// endpoints operated in mainland China; international storefronts avoid
    /// presenting those endpoints as equivalent to their global counterparts.
    public static func catalog(for region: AICommercialRegion) -> [AIProviderPreset] {
        switch region {
        case .mainlandChina:
            return [.deepSeekOpenAI, .qwen, .zhipu]
        case .international:
            return [.openAI, .anthropic, .gemini]
        case .unknown:
            return []
        }
    }

    public static func recommended(for region: AICommercialRegion) -> AIProviderPreset? {
        catalog(for: region).first
    }

    public func applying(to original: AIRemoteProviderConfiguration) -> AIRemoteProviderConfiguration {
        var configuration = original
        if self == .custom {
            configuration.prefersCustomConfiguration = true
            return configuration
        }
        configuration.prefersCustomConfiguration = false
        configuration.embeddingModel = ""
        switch self {
        case .custom:
            return configuration
        case .openAI:
            configuration.displayName = "OpenAI"
            configuration.baseURL = "https://api.openai.com"
            configuration.apiStyle = .responses
            configuration.apiPathMode = .appendV1
            configuration.authenticationStyle = .bearer
            configuration.generationModel = ""
        case .anthropic:
            configuration.displayName = "Anthropic"
            configuration.baseURL = "https://api.anthropic.com"
            configuration.apiStyle = .anthropicMessages
            configuration.apiPathMode = .appendV1
            configuration.authenticationStyle = .xAPIKey
            configuration.generationModel = ""
        case .gemini:
            configuration.displayName = "Google Gemini"
            configuration.baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "gemini-3.7-flash"
            configuration.embeddingModel = "gemini-embedding-001"
        case .deepSeekOpenAI:
            configuration.displayName = "DeepSeek"
            configuration.baseURL = "https://api.deepseek.com"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "deepseek-v4-flash"
        case .deepSeekAnthropic:
            configuration.displayName = "DeepSeek (Anthropic)"
            configuration.baseURL = "https://api.deepseek.com/anthropic"
            configuration.apiStyle = .anthropicMessages
            configuration.apiPathMode = .appendV1
            configuration.authenticationStyle = .xAPIKey
            configuration.generationModel = "deepseek-v4-flash"
        case .qwen:
            configuration.displayName = "Qwen"
            configuration.baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "qwen-plus"
        case .zhipu:
            configuration.displayName = "Zhipu GLM"
            configuration.baseURL = "https://open.bigmodel.cn/api/paas/v4"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "glm-5.2"
        }
        return configuration
    }

    public static func matching(
        configuration: AIRemoteProviderConfiguration
    ) -> AIProviderPreset {
        guard !configuration.prefersCustomConfiguration else { return .custom }
        for preset in AIProviderPreset.allCases where preset != .custom {
            let candidate = preset.applying(to: configuration)
            if candidate.baseURL == configuration.baseURL,
               candidate.apiStyle == configuration.apiStyle,
               candidate.apiPathMode == configuration.apiPathMode,
               candidate.authenticationStyle == configuration.authenticationStyle {
                return preset
            }
        }
        return .custom
    }
}

public enum AIRequestTimeoutPolicy {
    public static let defaultValue: TimeInterval = 12
    public static let minimum: TimeInterval = 2
    public static let maximum: TimeInterval = 60

    public static func normalizedForInitialization(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultValue }
        return min(max(value, minimum), maximum)
    }

    public static func validated(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, (minimum...maximum).contains(value) else { return nil }
        return value
    }

    public static func nanoseconds(_ value: TimeInterval) -> UInt64? {
        guard let value = validated(value) else { return nil }
        return UInt64(value * 1_000_000_000)
    }
}

public enum AIResponseSizePolicy {
    public static let maximumBytes = 2 * 1_024 * 1_024

    public static func allowsAppend(currentBytes: Int, incomingBytes: Int) -> Bool {
        guard currentBytes >= 0,
              incomingBytes >= 0,
              currentBytes <= maximumBytes else { return false }
        return incomingBytes <= maximumBytes - currentBytes
    }
}

public enum AISettingsOperationPolicy {
    public static func canApplyCompletion(
        operationGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        operationGeneration == currentGeneration
    }
}

public struct AIRemoteProviderConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var baseURL: String
    public var apiStyle: AICompatibleAPIStyle
    public var apiPathMode: AIAPIPathMode
    public var authenticationStyle: AIAuthenticationStyle
    public var generationModel: String
    public var embeddingModel: String
    public var requestTimeout: TimeInterval
    public var allowInsecureLocalHTTP: Bool
    public var isEnabled: Bool
    public var prefersCustomConfiguration: Bool

    public init(
        id: UUID = UUID(),
        displayName: String = "OpenAI Compatible",
        baseURL: String = "https://api.openai.com/v1",
        apiStyle: AICompatibleAPIStyle = .responses,
        apiPathMode: AIAPIPathMode = .automatic,
        authenticationStyle: AIAuthenticationStyle = .automatic,
        generationModel: String = "",
        embeddingModel: String = "",
        requestTimeout: TimeInterval = 12,
        allowInsecureLocalHTTP: Bool = false,
        isEnabled: Bool = false,
        prefersCustomConfiguration: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiStyle = apiStyle
        self.apiPathMode = apiPathMode
        self.authenticationStyle = authenticationStyle
        self.generationModel = generationModel
        self.embeddingModel = embeddingModel
        self.requestTimeout = AIRequestTimeoutPolicy.normalizedForInitialization(requestTimeout)
        self.allowInsecureLocalHTTP = allowInsecureLocalHTTP
        self.isEnabled = isEnabled
        self.prefersCustomConfiguration = prefersCustomConfiguration
    }

    public var descriptor: AIProviderDescriptor {
        var capabilities: Set<AICapability> = []
        if !generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            capabilities.insert(.semanticSearchInterpretation)
            capabilities.insert(.lyricsTranslation)
            capabilities.insert(.lyricsGeneration)
            capabilities.insert(.recommendations)
        }
        if supportsEmbeddings,
           !embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            capabilities.insert(.embeddings)
        }
        return AIProviderDescriptor(
            id: id,
            displayName: displayName,
            kind: .openAICompatible,
            executionClass: .userConfiguredRemote,
            capabilities: capabilities,
            priority: 100,
            isEnabled: isEnabled
        )
    }

    public var supportsEmbeddings: Bool {
        apiStyle != .anthropicMessages
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case apiStyle
        case apiPathMode
        case authenticationStyle
        case generationModel
        case embeddingModel
        case requestTimeout
        case allowInsecureLocalHTTP
        case isEnabled
        case prefersCustomConfiguration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requestTimeout = try container.decode(TimeInterval.self, forKey: .requestTimeout)
        guard AIRequestTimeoutPolicy.validated(requestTimeout) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .requestTimeout,
                in: container,
                debugDescription: "AI request timeout must be finite and between 2 and 60 seconds"
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiStyle = try container.decode(AICompatibleAPIStyle.self, forKey: .apiStyle)
        apiPathMode = try container.decodeIfPresent(AIAPIPathMode.self, forKey: .apiPathMode)
            ?? .automatic
        authenticationStyle = try container.decodeIfPresent(
            AIAuthenticationStyle.self,
            forKey: .authenticationStyle
        ) ?? .automatic
        generationModel = try container.decode(String.self, forKey: .generationModel)
        embeddingModel = try container.decode(String.self, forKey: .embeddingModel)
        self.requestTimeout = requestTimeout
        allowInsecureLocalHTTP = try container.decode(Bool.self, forKey: .allowInsecureLocalHTTP)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        prefersCustomConfiguration = try container.decodeIfPresent(
            Bool.self,
            forKey: .prefersCustomConfiguration
        ) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        guard AIRequestTimeoutPolicy.validated(requestTimeout) != nil else {
            throw EncodingError.invalidValue(
                requestTimeout,
                EncodingError.Context(
                    codingPath: encoder.codingPath + [CodingKeys.requestTimeout],
                    debugDescription: "AI request timeout must be finite and between 2 and 60 seconds"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiStyle, forKey: .apiStyle)
        try container.encode(apiPathMode, forKey: .apiPathMode)
        try container.encode(authenticationStyle, forKey: .authenticationStyle)
        try container.encode(generationModel, forKey: .generationModel)
        try container.encode(embeddingModel, forKey: .embeddingModel)
        try container.encode(requestTimeout, forKey: .requestTimeout)
        try container.encode(allowInsecureLocalHTTP, forKey: .allowInsecureLocalHTTP)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(prefersCustomConfiguration, forKey: .prefersCustomConfiguration)
    }
}

/// Ordered remote-provider profiles. The primary profile is attempted first;
/// when fallback is enabled, the remaining enabled profiles are tried in list
/// order. Keeping routing data separate from secrets lets the same profile list
/// roam through iCloud while API keys remain protected by iCloud Keychain.
public struct AIRemoteProviderSet: Codable, Equatable, Sendable {
    public var providers: [AIRemoteProviderConfiguration]
    public var primaryProviderID: UUID
    public var fallbackEnabled: Bool

    public init(
        providers: [AIRemoteProviderConfiguration] = [],
        primaryProviderID: UUID? = nil,
        fallbackEnabled: Bool = true
    ) {
        var normalizedProviders: [AIRemoteProviderConfiguration] = []
        var seen = Set<UUID>()
        for provider in providers where seen.insert(provider.id).inserted {
            normalizedProviders.append(provider)
        }
        if normalizedProviders.isEmpty {
            var provider = AIRemoteProviderConfiguration()
            provider.isEnabled = true
            normalizedProviders = [provider]
        }
        self.providers = normalizedProviders
        self.primaryProviderID = normalizedProviders.contains {
            $0.id == primaryProviderID
        } ? primaryProviderID! : normalizedProviders[0].id
        self.fallbackEnabled = fallbackEnabled
    }

    public var primaryProvider: AIRemoteProviderConfiguration {
        providers.first { $0.id == primaryProviderID } ?? providers[0]
    }

    public var routedProviders: [AIRemoteProviderConfiguration] {
        guard fallbackEnabled else {
            return primaryProvider.isEnabled ? [primaryProvider] : []
        }
        var result: [AIRemoteProviderConfiguration] = []
        if primaryProvider.isEnabled {
            result.append(primaryProvider)
        }
        result.append(contentsOf: providers.filter {
            $0.id != primaryProviderID && $0.isEnabled
        })
        return result
    }

    public func normalized() -> AIRemoteProviderSet {
        AIRemoteProviderSet(
            providers: providers,
            primaryProviderID: primaryProviderID,
            fallbackEnabled: fallbackEnabled
        )
    }
}

public enum AIRemoteEndpointValidationError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case embeddedCredential
    case queryOrFragmentNotAllowed
    case invalidRequestTimeout
    case insecurePublicHTTP
    case insecureLocalHTTPRequiresConsent
    case unsupportedCapability
}

public enum AIRemoteEndpointPolicy {
    public static func validatedBaseURL(
        _ rawValue: String,
        allowInsecureLocalHTTP: Bool
    ) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw AIRemoteEndpointValidationError.invalidURL
        }
        guard scheme == "https" || scheme == "http" else {
            throw AIRemoteEndpointValidationError.unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw AIRemoteEndpointValidationError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw AIRemoteEndpointValidationError.embeddedCredential
        }
        guard components.query == nil, components.fragment == nil else {
            throw AIRemoteEndpointValidationError.queryOrFragmentNotAllowed
        }

        if scheme == "http" {
            guard InsecureHTTPHostPolicy.isPrivateIPAddressLiteral(host) else {
                throw AIRemoteEndpointValidationError.insecurePublicHTTP
            }
            guard allowInsecureLocalHTTP else {
                throw AIRemoteEndpointValidationError.insecureLocalHTTPRequiresConsent
            }
        }

        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else {
            throw AIRemoteEndpointValidationError.invalidURL
        }
        return url
    }

    public static func generationEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        guard AIRequestTimeoutPolicy.validated(configuration.requestTimeout) != nil else {
            throw AIRemoteEndpointValidationError.invalidRequestTimeout
        }
        let baseURL = try apiBaseURL(configuration: configuration)
        switch configuration.apiStyle {
        case .responses:
            return baseURL.appendingPathComponent("responses")
        case .chatCompletions:
            return baseURL.appendingPathComponent("chat/completions")
        case .anthropicMessages:
            return baseURL.appendingPathComponent("messages")
        }
    }

    public static func embeddingsEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        guard AIRequestTimeoutPolicy.validated(configuration.requestTimeout) != nil else {
            throw AIRemoteEndpointValidationError.invalidRequestTimeout
        }
        guard configuration.supportsEmbeddings else {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }
        let baseURL = try apiBaseURL(configuration: configuration)
        return baseURL.appendingPathComponent("embeddings")
    }

    public static func modelsEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        guard AIRequestTimeoutPolicy.validated(configuration.requestTimeout) != nil else {
            throw AIRemoteEndpointValidationError.invalidRequestTimeout
        }
        if usesOpenAIModelCatalog(configuration: configuration) {
            let configuredBaseURL = try validatedBaseURL(
                configuration.baseURL,
                allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
            )
            guard var components = URLComponents(
                url: configuredBaseURL,
                resolvingAgainstBaseURL: false
            ) else {
                throw AIRemoteEndpointValidationError.invalidURL
            }
            components.path = ""
            guard let origin = components.url else {
                throw AIRemoteEndpointValidationError.invalidURL
            }
            return origin.appendingPathComponent("models")
        }
        let baseURL = try apiBaseURL(configuration: configuration)
        return baseURL.appendingPathComponent("models")
    }

    public static func usesOpenAIModelCatalog(
        configuration: AIRemoteProviderConfiguration
    ) -> Bool {
        guard configuration.apiStyle == .anthropicMessages,
              let baseURL = try? validatedBaseURL(
                  configuration.baseURL,
                  allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
              ),
              baseURL.host?.lowercased() == "api.deepseek.com" else {
            return false
        }
        let pathComponents = baseURL.pathComponents
            .filter { $0 != "/" }
            .map { $0.lowercased() }
        guard pathComponents.first == "anthropic" else { return false }
        return pathComponents.count == 1
            || (pathComponents.count == 2 && isVersionPathComponent(pathComponents[1]))
    }

    public static func apiBaseURL(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        let baseURL = try validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
        switch configuration.apiPathMode {
        case .asEntered:
            return baseURL
        case .appendV1:
            return appendingV1IfNeeded(to: baseURL)
        case .automatic:
            return automaticAPIBaseURL(baseURL, style: configuration.apiStyle)
        }
    }

    private static func automaticAPIBaseURL(
        _ baseURL: URL,
        style: AICompatibleAPIStyle
    ) -> URL {
        if hasVersionPath(baseURL) { return baseURL }

        let host = baseURL.host?.lowercased() ?? ""
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "api.deepseek.com" {
            if style == .anthropicMessages, path.lowercased() == "anthropic" {
                return baseURL.appendingPathComponent("v1")
            }
            return baseURL
        }
        if style == .anthropicMessages {
            return baseURL.appendingPathComponent("v1")
        }
        if host == "api.openai.com" || host == "api.anthropic.com" || path.isEmpty {
            return baseURL.appendingPathComponent("v1")
        }
        return baseURL
    }

    private static func appendingV1IfNeeded(to baseURL: URL) -> URL {
        hasVersionPath(baseURL) ? baseURL : baseURL.appendingPathComponent("v1")
    }

    private static func hasVersionPath(_ url: URL) -> Bool {
        guard let component = url.pathComponents.last?.lowercased() else { return false }
        return isVersionPathComponent(component)
    }

    private static func isVersionPathComponent(_ component: String) -> Bool {
        guard component.count > 1, component.first == "v" else { return false }
        return component.dropFirst().allSatisfy(\.isNumber)
    }
}

public enum AICredentialStoragePolicy {
    private static let accountNamespace = "ai.provider."

    public static func legacyAccount(profileID: UUID) -> String {
        "\(accountNamespace)\(profileID.uuidString.lowercased()).apiKey"
    }

    public static func canonicalOrigin(
        baseURL: String,
        allowInsecureLocalHTTP: Bool
    ) throws -> String {
        let url = try AIRemoteEndpointPolicy.validatedBaseURL(
            baseURL,
            allowInsecureLocalHTTP: allowInsecureLocalHTTP
        )
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            throw AIRemoteEndpointValidationError.invalidURL
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            components.port = port
        }
        guard let origin = components.string else {
            throw AIRemoteEndpointValidationError.invalidURL
        }
        return origin
    }

    public static func account(
        profileID: UUID,
        baseURL: String,
        allowInsecureLocalHTTP: Bool
    ) throws -> String {
        let origin = try canonicalOrigin(
            baseURL: baseURL,
            allowInsecureLocalHTTP: allowInsecureLocalHTTP
        )
        return "\(accountNamespace)\(profileID.uuidString.lowercased()).origin.\(origin).apiKey"
    }

    public static func canonicalScope(
        configuration: AIRemoteProviderConfiguration
    ) throws -> String {
        let apiBaseURL = try AIRemoteEndpointPolicy.apiBaseURL(configuration: configuration)
        let authentication = configuration.authenticationStyle.resolved(
            for: configuration.apiStyle
        )
        return "\(apiBaseURL.absoluteString)|\(configuration.apiStyle.rawValue)|\(authentication.rawValue)"
    }

    public static func scopedAccount(
        configuration: AIRemoteProviderConfiguration
    ) throws -> String {
        let scope = try canonicalScope(configuration: configuration)
        return "\(accountNamespace)\(configuration.id.uuidString.lowercased()).endpoint.\(scope).apiKey"
    }

    public static func isEligibleForICloudMigration(account: String) -> Bool {
        true
    }
}
