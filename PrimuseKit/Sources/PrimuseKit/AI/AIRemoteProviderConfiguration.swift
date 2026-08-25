import Foundation

public enum AICompatibleAPIStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case responses
    case chatCompletions
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
    public var generationModel: String
    public var embeddingModel: String
    public var requestTimeout: TimeInterval
    public var allowInsecureLocalHTTP: Bool
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        displayName: String = "OpenAI Compatible",
        baseURL: String = "https://api.openai.com/v1",
        apiStyle: AICompatibleAPIStyle = .responses,
        generationModel: String = "",
        embeddingModel: String = "",
        requestTimeout: TimeInterval = 12,
        allowInsecureLocalHTTP: Bool = false,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiStyle = apiStyle
        self.generationModel = generationModel
        self.embeddingModel = embeddingModel
        self.requestTimeout = AIRequestTimeoutPolicy.normalizedForInitialization(requestTimeout)
        self.allowInsecureLocalHTTP = allowInsecureLocalHTTP
        self.isEnabled = isEnabled
    }

    public var descriptor: AIProviderDescriptor {
        var capabilities: Set<AICapability> = []
        if !generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            capabilities.formUnion([
                .semanticSearchInterpretation,
                .reranking,
                .songAnnotation,
                .recommendations,
                .commandInterpretation,
            ])
        }
        if !embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case apiStyle
        case generationModel
        case embeddingModel
        case requestTimeout
        case allowInsecureLocalHTTP
        case isEnabled
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
        generationModel = try container.decode(String.self, forKey: .generationModel)
        embeddingModel = try container.decode(String.self, forKey: .embeddingModel)
        self.requestTimeout = requestTimeout
        allowInsecureLocalHTTP = try container.decode(Bool.self, forKey: .allowInsecureLocalHTTP)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
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
        try container.encode(generationModel, forKey: .generationModel)
        try container.encode(embeddingModel, forKey: .embeddingModel)
        try container.encode(requestTimeout, forKey: .requestTimeout)
        try container.encode(allowInsecureLocalHTTP, forKey: .allowInsecureLocalHTTP)
        try container.encode(isEnabled, forKey: .isEnabled)
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
        let baseURL = try validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
        switch configuration.apiStyle {
        case .responses:
            return baseURL.appendingPathComponent("responses")
        case .chatCompletions:
            return baseURL.appendingPathComponent("chat/completions")
        }
    }

    public static func embeddingsEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        guard AIRequestTimeoutPolicy.validated(configuration.requestTimeout) != nil else {
            throw AIRemoteEndpointValidationError.invalidRequestTimeout
        }
        let baseURL = try validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
        return baseURL.appendingPathComponent("embeddings")
    }

    public static func modelsEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        guard AIRequestTimeoutPolicy.validated(configuration.requestTimeout) != nil else {
            throw AIRemoteEndpointValidationError.invalidRequestTimeout
        }
        let baseURL = try validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
        return baseURL.appendingPathComponent("models")
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

    public static func isEligibleForICloudMigration(account: String) -> Bool {
        !account.hasPrefix(accountNamespace)
    }
}
