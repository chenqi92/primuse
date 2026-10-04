import Foundation

public enum AICompatibleAPIStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case responses
    case chatCompletions
    case anthropicMessages
    case geminiGenerateContent
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
    case xGoogAPIKey

    public func resolved(for apiStyle: AICompatibleAPIStyle) -> AIAuthenticationStyle {
        guard self == .automatic else { return self }
        switch apiStyle {
        case .anthropicMessages:
            return .xAPIKey
        case .geminiGenerateContent:
            return .xGoogAPIKey
        case .responses, .chatCompletions:
            return .bearer
        }
    }
}

/// Keeps Primuse's general Responses requests separate from Codex's
/// product-scoped ChatGPT sign-in. Revisit this only when OpenAI documents a
/// public third-party grant for general Responses access.
public enum AIOpenAIAccountAccessPolicy {
    public static let supportsChatGPTSubscriptionForGeneralResponses = false
    public static let requiresPlatformCredentialForGeneralResponses = true
}

/// User-facing compatibility choices for a custom endpoint. The detailed
/// path and authentication fields remain part of the persisted provider
/// configuration, while common gateways can be configured with one choice.
public enum AIProviderCompatibilityMode: String, CaseIterable, Hashable, Sendable {
    case openAIResponses
    case openAIChatCompletions
    case anthropicMessages
    case geminiGenerateContent

    public init(configuration: AIRemoteProviderConfiguration) {
        switch configuration.apiStyle {
        case .responses:
            self = .openAIResponses
        case .chatCompletions:
            self = .openAIChatCompletions
        case .anthropicMessages:
            self = .anthropicMessages
        case .geminiGenerateContent:
            self = .geminiGenerateContent
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
        case .geminiGenerateContent:
            configuration.apiStyle = .geminiGenerateContent
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
    /// Retained so an existing DeepSeek Messages configuration can still be
    /// recognized. New profiles expose DeepSeek once and keep protocol choice
    /// in the custom compatibility controls.
    case deepSeekAnthropic
    case qwen
    case zhipu
    case xiaomiMiMo
    case kimi
    case miniMax
    case volcengineArk
    case tencentTokenHub
    case baiduQianfan
    case stepFun
    case siliconFlow
    case senseNova
    /// Agnes AI runs one key across two hosts: the international `.com`
    /// gateway and a `.cn` gateway operated for mainland China. Each host
    /// is its own preset so the mainland catalog can list the reachable one.
    case agnesAI
    case agnesAIMainland
    case openRouter
    case nvidiaNIM
    case xAI
    case mistral
    case groq
    case togetherAI
    case fireworksAI

    public static let mainlandChinaCatalog: [AIProviderPreset] = [
        .deepSeekOpenAI,
        .qwen,
        .zhipu,
        .xiaomiMiMo,
        .kimi,
        .miniMax,
        .volcengineArk,
        .tencentTokenHub,
        .baiduQianfan,
        .stepFun,
        .siliconFlow,
        .senseNova,
        .agnesAIMainland,
    ]

    public static let globalCatalog: [AIProviderPreset] = [
        .openAI,
        .anthropic,
        .gemini,
        .agnesAI,
        .openRouter,
        .nvidiaNIM,
        .xAI,
        .mistral,
        .groq,
        .togetherAI,
        .fireworksAI,
    ]

    /// Mainland storefronts only suggest mainland providers. Other
    /// storefronts expose both the global and mainland provider catalogs.
    public static func catalog(for region: AICommercialRegion) -> [AIProviderPreset] {
        switch region {
        case .mainlandChina:
            return mainlandChinaCatalog
        case .international:
            return globalCatalog + mainlandChinaCatalog
        case .unknown:
            return []
        }
    }

    public static func visibleSelection(
        _ preset: AIProviderPreset,
        for region: AICommercialRegion
    ) -> AIProviderPreset {
        catalog(for: region).contains(preset) ? preset : .custom
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
        configuration.transcriptionModel = ""
        switch self {
        case .custom:
            return configuration
        case .openAI:
            configuration.displayName = "OpenAI API"
            configuration.baseURL = "https://api.openai.com"
            configuration.apiStyle = .responses
            configuration.apiPathMode = .appendV1
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "gpt-5.2"
            configuration.embeddingModel = "text-embedding-3-small"
        case .anthropic:
            configuration.displayName = "Anthropic"
            configuration.baseURL = "https://api.anthropic.com"
            configuration.apiStyle = .anthropicMessages
            configuration.apiPathMode = .appendV1
            configuration.authenticationStyle = .xAPIKey
            configuration.generationModel = "claude-sonnet-5"
        case .gemini:
            configuration.displayName = "Google Gemini"
            configuration.baseURL = "https://generativelanguage.googleapis.com/v1beta"
            configuration.apiStyle = .geminiGenerateContent
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .xGoogAPIKey
            configuration.generationModel = "gemini-3.7-flash"
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
        case .xiaomiMiMo:
            configuration.displayName = "Xiaomi MiMo"
            configuration.baseURL = "https://api.xiaomimimo.com/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "mimo-v2.5-pro"
        case .kimi:
            configuration.displayName = "Kimi"
            configuration.baseURL = "https://api.moonshot.cn/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "kimi-k3"
        case .miniMax:
            configuration.displayName = "MiniMax"
            configuration.baseURL = "https://api.minimaxi.com/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "MiniMax-M3"
        case .volcengineArk:
            configuration.displayName = "Volcengine Ark"
            configuration.baseURL = "https://ark.cn-beijing.volces.com/api/v3"
            configuration.apiStyle = .responses
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "doubao-seed-2-0-lite-260215"
        case .tencentTokenHub:
            configuration.displayName = "Tencent TokenHub"
            configuration.baseURL = "https://tokenhub.tencentmaas.com/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "hy3"
        case .baiduQianfan:
            configuration.displayName = "Baidu Qianfan"
            configuration.baseURL = "https://qianfan.baidubce.com/v2"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "ernie-4.5-turbo-32k"
        case .stepFun:
            configuration.displayName = "StepFun"
            configuration.baseURL = "https://api.stepfun.com/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "step-3.5-flash-2603"
        case .siliconFlow:
            configuration.displayName = "SiliconFlow"
            configuration.baseURL = "https://api.siliconflow.cn/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "Qwen/Qwen3-235B-A22B-Instruct-2507"
        case .senseNova:
            // 日日新 Token Plan 的 OpenAI 兼容网关;早先的 api.sensenova.cn
            // 兼容模式要用 AK/SK 换 JWT,普通用户拿到的是 token.sensenova.cn 的 sk 密钥。
            configuration.displayName = "SenseNova"
            configuration.baseURL = "https://token.sensenova.cn/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "sensenova-6.8-flash-lite"
        case .agnesAI:
            configuration.displayName = "Agnes AI"
            configuration.baseURL = "https://apihub.agnes-ai.com/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "agnes-2.5-flash"
        case .agnesAIMainland:
            configuration.displayName = "Agnes AI"
            configuration.baseURL = "https://apihub.agnes-ai.cn/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "agnes-2.5-flash"
        case .openRouter:
            configuration.displayName = "OpenRouter"
            configuration.baseURL = "https://openrouter.ai/api/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "openrouter/auto"
        case .nvidiaNIM:
            configuration.displayName = "NVIDIA NIM"
            configuration.baseURL = "https://integrate.api.nvidia.com/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "nvidia/nemotron-3-super"
        case .xAI:
            configuration.displayName = "xAI"
            configuration.baseURL = "https://api.x.ai/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "grok-4.6"
        case .mistral:
            configuration.displayName = "Mistral AI"
            configuration.baseURL = "https://api.mistral.ai/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "mistral-small-latest"
        case .groq:
            configuration.displayName = "Groq"
            configuration.baseURL = "https://api.groq.com/openai/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "openai/gpt-oss-20b"
        case .togetherAI:
            configuration.displayName = "Together AI"
            configuration.baseURL = "https://api.together.ai/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "openai/gpt-oss-20b"
        case .fireworksAI:
            configuration.displayName = "Fireworks AI"
            configuration.baseURL = "https://api.fireworks.ai/inference/v1"
            configuration.apiStyle = .chatCompletions
            configuration.apiPathMode = .asEntered
            configuration.authenticationStyle = .bearer
            configuration.generationModel = "accounts/fireworks/models/llama-v3p1-8b-instruct"
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

public enum AIAudioTranscriptionPolicy {
    public static let maximumDuration: TimeInterval = 30 * 60
    public static let maximumFileBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let requestTimeout: TimeInterval = 15 * 60

    /// 内置 AI 一首最长 10 分钟(中转从上传的 M4A 里读时长,超过就拒)。
    public static let builtInMaximumDuration: TimeInterval = 10 * 60
    /// 上传前在本机转成的 AAC:Gemini 自己会降到 16 kHz 单声道,22.05 kHz、
    /// 立体声 48 kbps(单声道减半)对唱词足够,10 分钟约 3.6 MB。
    public static let builtInUploadSampleRate: Double = 22_050
    public static let builtInUploadKbps = 48
    /// 中转收的音频上限(解码后 8 MB)。
    public static let builtInMaximumUploadBytes = 8 * 1_024 * 1_024

    /// 这首歌能不能听歌识词:内置 AI 先在本机转码,能播的格式都行,但限 10 分钟;
    /// 自己的 Google 密钥直接上传原文件,只认 Google 写明支持的格式,限 30 分钟。
    /// 时长未知(≤ 0)时交给服务端判断。
    public static func canTranscribe(
        format: AudioFormat,
        duration: TimeInterval,
        builtIn: Bool,
        ownKey: Bool
    ) -> Bool {
        let fitsBuiltIn = builtIn && (duration <= 0 || duration <= builtInMaximumDuration)
        let fitsOwnKey = ownKey
            && supportsInput(format: format)
            && (duration <= 0 || duration <= maximumDuration)
        return fitsBuiltIn || fitsOwnKey
    }

    /// File formats explicitly documented by Google's transcription endpoint.
    /// Keep this conservative: playback support is broader than remote
    /// transcription support, and relabelling an unknown payload as MP3 only
    /// postpones an otherwise preventable upload failure.
    public static let supportedInputFormats: Set<AudioFormat> = [
        .mp3, .aac, .flac, .wav, .aiff, .aif, .ogg,
    ]

    public static func supportsInput(format: AudioFormat) -> Bool {
        supportedInputFormats.contains(format)
    }

    public static func mimeType(for format: AudioFormat) -> String? {
        switch format {
        case .mp3: return "audio/mpeg"
        case .aac: return "audio/aac"
        case .flac: return "audio/flac"
        case .wav: return "audio/wav"
        case .aiff, .aif: return "audio/aiff"
        case .ogg: return "audio/ogg"
        default: return nil
        }
    }

    public static func supportsInput(mimeType rawValue: String) -> Bool {
        let mimeType = rawValue
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return [
            "audio/mpeg", "audio/mp3",
            "audio/aac",
            "audio/flac",
            "audio/wav", "audio/wave", "audio/x-wav",
            "audio/aiff", "audio/x-aiff",
            "audio/ogg",
        ].contains(mimeType)
    }

    public static func supports(
        configuration: AIRemoteProviderConfiguration
    ) -> Bool {
        isCompatibleEndpoint(configuration: configuration)
            && isSupportedModelID(configuration.transcriptionModel)
    }

    public static func isCompatibleEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) -> Bool {
        guard configuration.apiStyle == .geminiGenerateContent,
              configuration.authenticationStyle == .xGoogAPIKey,
              let baseURL = try? AIRemoteEndpointPolicy.validatedBaseURL(
                  configuration.baseURL,
                  allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
              ) else { return false }
        return baseURL.scheme?.lowercased() == "https"
            && baseURL.host?.lowercased() == "generativelanguage.googleapis.com"
            && (baseURL.port == nil || baseURL.port == 443)
    }

    public static func normalizedModel(_ rawValue: String) -> String {
        AIRemoteEndpointPolicy.normalizedGeminiModelID(rawValue)
    }

    /// Google exposes transcription models through its authenticated model
    /// catalog. Match the capability family instead of pinning a release name
    /// that will age out; the endpoint gate above still prevents every other
    /// vendor or compatibility relay from advertising support.
    public static func isSupportedModelID(_ rawValue: String) -> Bool {
        let model = normalizedModel(rawValue).lowercased()
        return !model.isEmpty
            && model.contains("transcribe")
            && !model.contains("live")
    }

    public static func supportedModels(
        from models: [AIProviderModel]
    ) -> [AIProviderModel] {
        models.filter { isSupportedModelID($0.id) }
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
    /// 除默认模型外,这项服务还给各功能挑的生成模型(同一家服务商的不同模型
    /// 分给不同功能)。默认模型不在这里面。
    public var additionalGenerationModels: [String]
    public var embeddingModel: String
    public var transcriptionModel: String
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
        additionalGenerationModels: [String] = [],
        embeddingModel: String = "",
        transcriptionModel: String = "",
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
        self.additionalGenerationModels = additionalGenerationModels
        self.embeddingModel = embeddingModel
        self.transcriptionModel = transcriptionModel
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
            capabilities.insert(.recommendations)
        }
        if AIAudioTranscriptionPolicy.supports(configuration: self) {
            capabilities.insert(.audioTranscription)
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

    /// 各功能可以挑的生成模型:默认模型在前,其余按添加顺序,去掉空白与重复。
    public var selectableGenerationModels: [String] {
        var seen = Set<String>()
        return ([generationModel] + additionalGenerationModels).compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    public var supportsEmbeddings: Bool {
        switch apiStyle {
        case .responses, .chatCompletions:
            return true
        case .anthropicMessages, .geminiGenerateContent:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case apiStyle
        case apiPathMode
        case authenticationStyle
        case generationModel
        case additionalGenerationModels
        case embeddingModel
        case transcriptionModel
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
        additionalGenerationModels = (try? container.decodeIfPresent(
            [String].self,
            forKey: .additionalGenerationModels
        )) ?? []
        embeddingModel = try container.decode(String.self, forKey: .embeddingModel)
        transcriptionModel = try container.decodeIfPresent(
            String.self,
            forKey: .transcriptionModel
        ) ?? ""
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
        if !additionalGenerationModels.isEmpty {
            try container.encode(additionalGenerationModels, forKey: .additionalGenerationModels)
        }
        try container.encode(embeddingModel, forKey: .embeddingModel)
        try container.encode(transcriptionModel, forKey: .transcriptionModel)
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
    /// 各功能的分工,键是 `AIFeature.rawValue`。没有记录的功能跟随默认;
    /// 新版本才有的功能键原样保留,旧版本读写时不丢。
    public var featureRoutes: [String: AIFeatureRoute]

    public init(
        providers: [AIRemoteProviderConfiguration] = [],
        primaryProviderID: UUID? = nil,
        fallbackEnabled: Bool = true,
        featureRoutes: [String: AIFeatureRoute] = [:]
    ) {
        var normalizedProviders: [AIRemoteProviderConfiguration] = []
        var seen = Set<UUID>()
        for var provider in providers where seen.insert(provider.id).inserted {
            if provider.displayName == "OpenAI",
               AIProviderPreset.matching(configuration: provider) == .openAI {
                provider.displayName = "OpenAI API"
            }
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
        // 服务删掉了,交给它的分工也就没有了;停用的服务保留分工,重新启用还在。
        let providerIDs = Set(normalizedProviders.map(\.id))
        self.featureRoutes = featureRoutes.filter { _, route in
            guard case .provider(let id, _) = route else { return true }
            return providerIDs.contains(id)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case primaryProviderID
        case fallbackEnabled
        case featureRoutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decode([AIRemoteProviderConfiguration].self, forKey: .providers)
        primaryProviderID = try container.decode(UUID.self, forKey: .primaryProviderID)
        fallbackEnabled = try container.decode(Bool.self, forKey: .fallbackEnabled)
        // 认不出的单条分工丢掉就好,不能连累整份智能设置读不出来。
        featureRoutes = (try? container.decodeIfPresent(
            [String: LenientFeatureRoute].self,
            forKey: .featureRoutes
        ))?.compactMapValues(\.route) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
        try container.encode(primaryProviderID, forKey: .primaryProviderID)
        try container.encode(fallbackEnabled, forKey: .fallbackEnabled)
        if !featureRoutes.isEmpty {
            try container.encode(featureRoutes, forKey: .featureRoutes)
        }
    }

    private struct LenientFeatureRoute: Decodable {
        let route: AIFeatureRoute?

        init(from decoder: any Decoder) throws {
            route = try? AIFeatureRoute(from: decoder)
        }
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

    /// 记下的分工;`nil` 是跟随默认。
    public func route(for feature: AIFeature) -> AIFeatureRoute? {
        featureRoutes[feature.rawValue]
    }

    public mutating func setRoute(_ route: AIFeatureRoute?, for feature: AIFeature) {
        featureRoutes[feature.rawValue] = route
    }

    /// 实际生效的分工:交给了已停用(或已删除)的服务时,先按跟随默认处理。
    public func effectiveRoute(for feature: AIFeature) -> AIFeatureRoute? {
        guard let route = route(for: feature) else { return nil }
        if case .provider(let id, _) = route,
           !providers.contains(where: { $0.id == id && $0.isEnabled }) {
            return nil
        }
        return route
    }

    /// 这个功能要不要先问内置 AI:点名内置 AI 的要,点名自己服务的不要,
    /// 跟随默认的看内置 AI 是不是默认。
    public func asksBuiltInFirst(for feature: AIFeature, relayEnabled: Bool) -> Bool {
        switch effectiveRoute(for: feature) {
        case .builtIn: true
        case .provider: false
        case nil: relayEnabled
        }
    }

    /// 这个功能依次去问的自己的服务。点名了某个服务时它排第一并换上点名的模型;
    /// 打开了「出错时改用其他服务」才接着按原来的顺序问其余的服务。
    public func routedProviders(for feature: AIFeature) -> [AIRemoteProviderConfiguration] {
        guard case .provider(let id, let model)? = effectiveRoute(for: feature),
              var assigned = providers.first(where: { $0.id == id }) else {
            return routedProviders
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            assigned.generationModel = trimmedModel
        }
        guard fallbackEnabled else { return [assigned] }
        return [assigned] + routedProviders.filter { $0.id != id }
    }

    public func normalized() -> AIRemoteProviderSet {
        AIRemoteProviderSet(
            providers: providers,
            primaryProviderID: primaryProviderID,
            fallbackEnabled: fallbackEnabled,
            featureRoutes: featureRoutes
        )
    }
}

/// 会用到 AI 的功能。每个功能可以跟随默认、交给内置 AI,或交给自己某个服务的某个模型。
public enum AIFeature: String, Codable, CaseIterable, Sendable {
    case recommendations
    case semanticSearch
    case lyricsTranslation
    case listeningIntents
    case tagCleanup
    case songDiscovery
    case libraryInsight
    case listeningMood
}

/// 一个功能交给谁。没有记录就是跟随默认。
public enum AIFeatureRoute: Hashable, Sendable {
    case builtIn
    /// 自己的服务;`model` 为空表示用这个服务的默认模型。
    case provider(id: UUID, model: String)

    public var providerID: UUID? {
        guard case .provider(let id, _) = self else { return nil }
        return id
    }
}

extension AIFeatureRoute: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case providerID
        case model
    }

    private enum Kind: String, Codable {
        case builtIn
        case provider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .builtIn:
            self = .builtIn
        case .provider:
            self = .provider(
                id: try container.decode(UUID.self, forKey: .providerID),
                model: try container.decodeIfPresent(String.self, forKey: .model) ?? ""
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn:
            try container.encode(Kind.builtIn, forKey: .kind)
        case .provider(let id, let model):
            try container.encode(Kind.provider, forKey: .kind)
            try container.encode(id, forKey: .providerID)
            try container.encode(model, forKey: .model)
        }
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
    public static func isOpenAIPlatformEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) -> Bool {
        guard let baseURL = try? validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        ) else {
            return false
        }
        return baseURL.scheme?.lowercased() == "https"
            && baseURL.host?.lowercased() == "api.openai.com"
            && (baseURL.port == nil || baseURL.port == 443)
    }

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
        case .geminiGenerateContent:
            let model = normalizedGeminiModelID(configuration.generationModel)
            guard !model.isEmpty else {
                throw AIRemoteEndpointValidationError.invalidURL
            }
            return baseURL
                .appendingPathComponent("models")
                .appendingPathComponent("\(model):generateContent")
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

    public static func geminiInteractionsEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        guard AIAudioTranscriptionPolicy.supports(configuration: configuration) else {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }
        return try apiBaseURL(configuration: configuration)
            .appendingPathComponent("interactions")
    }

    public static func geminiFilesUploadEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        guard AIAudioTranscriptionPolicy.supports(configuration: configuration),
              let baseURL = try? validatedBaseURL(
                  configuration.baseURL,
                  allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
              ),
              var components = URLComponents(
                  url: baseURL,
                  resolvingAgainstBaseURL: false
              ) else {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }
        components.path = "/upload/v1beta/files"
        guard let url = components.url else {
            throw AIRemoteEndpointValidationError.invalidURL
        }
        return url
    }

    public static func geminiFileDeleteEndpoint(
        configuration: AIRemoteProviderConfiguration,
        fileName: String
    ) throws -> URL {
        guard AIAudioTranscriptionPolicy.supports(configuration: configuration) else {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }
        let path = fileName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = path.split(separator: "/").map(String.init)
        guard pathComponents.count == 2,
              pathComponents[0] == "files",
              pathComponents[1].allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) })
        else {
            throw AIRemoteEndpointValidationError.invalidURL
        }
        return pathComponents.reduce(try apiBaseURL(configuration: configuration)) {
            $0.appendingPathComponent($1)
        }
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
        if style == .geminiGenerateContent {
            return baseURL.appendingPathComponent("v1beta")
        }
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

    public static func normalizedGeminiModelID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return String(trimmed.dropFirst("models/".count))
        }
        return trimmed
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
    private static let apiKeyAccountSuffix = ".apiKey"

    public static func legacyAccount(profileID: UUID) -> String {
        "\(accountNamespace)\(profileID.uuidString.lowercased())\(apiKeyAccountSuffix)"
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
        return "\(accountNamespace)\(profileID.uuidString.lowercased()).origin.\(origin)\(apiKeyAccountSuffix)"
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
        return "\(accountNamespace)\(configuration.id.uuidString.lowercased()).endpoint.\(scope)\(apiKeyAccountSuffix)"
    }

    /// 启动迁移把旧的本地钥匙串项改写成 iCloud 钥匙串项时的准入判定。
    ///
    /// `storedDeviceOnly` 表示这一项是以「仅本机」方式落盘的（`…ThisDeviceOnly`
    /// 可访问性或本机标记）。这类项默认不迁：中继安装凭据、自建分享令牌这些
    /// 秘密本来就不该离开设备。唯一例外是 AI 服务商密钥：e1424418 之前它们走
    /// 本机路径写入，之后改为随服务商配置一起漫游，旧密钥仍要补迁进 iCloud
    /// 钥匙串，否则其他设备只能看到配置却没有密钥。判定按账号形态（命名空间
    /// 前缀 + `.apiKey` 后缀）而不是整个命名空间，免得日后放进同一命名空间的
    /// 本机专用秘密也被顺带迁走。
    public static func isEligibleForICloudMigration(
        account: String,
        storedDeviceOnly: Bool
    ) -> Bool {
        guard storedDeviceOnly else { return true }
        return isAPIKeyAccount(account)
    }

    private static func isAPIKeyAccount(_ account: String) -> Bool {
        account.hasPrefix(accountNamespace) && account.hasSuffix(apiKeyAccountSuffix)
    }
}
