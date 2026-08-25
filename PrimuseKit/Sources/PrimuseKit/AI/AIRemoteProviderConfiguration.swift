import Foundation

public enum AICompatibleAPIStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case responses
    case chatCompletions
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
        self.requestTimeout = min(max(requestTimeout, 2), 60)
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
}

public enum AIRemoteEndpointValidationError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case embeddedCredential
    case queryOrFragmentNotAllowed
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
        let baseURL = try validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
        return baseURL.appendingPathComponent("embeddings")
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
