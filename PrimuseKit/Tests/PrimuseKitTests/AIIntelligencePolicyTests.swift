import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI settings operation policy")
struct AISettingsOperationPolicyTests {
    @Test func currentDraftAcceptsOperationCompletion() {
        #expect(AISettingsOperationPolicy.canApplyCompletion(
            operationGeneration: 4,
            currentGeneration: 4
        ))
    }

    @Test func editedDraftRejectsOldSuccessAndCredentialCleanup() {
        #expect(!AISettingsOperationPolicy.canApplyCompletion(
            operationGeneration: 4,
            currentGeneration: 5
        ))
    }
}

@Suite("AI region availability")
struct AIRegionAvailabilityTests {
    @Test func storefrontIsAuthoritative() {
        #expect(AIRegionResolver.resolve(
            storefrontCountryCode: "CHN",
            localeRegionCode: "US"
        ) == AIRegionContext(
            region: .mainlandChina,
            source: .appStorefront,
            countryCode: "CHN"
        ))

        #expect(AIRegionResolver.resolve(
            storefrontCountryCode: "USA",
            localeRegionCode: "CN"
        ) == AIRegionContext(
            region: .international,
            source: .appStorefront,
            countryCode: "USA"
        ))
    }

    @Test func localeFallbackOnlyFailsClosedForMainlandChina() {
        #expect(AIRegionResolver.resolve(
            storefrontCountryCode: nil,
            localeRegionCode: "CN"
        ).region == .mainlandChina)
        #expect(AIRegionResolver.resolve(
            storefrontCountryCode: nil,
            localeRegionCode: "US"
        ) == .unknown)
        #expect(AIRegionResolver.resolve(
            storefrontCountryCode: "not-a-code",
            localeRegionCode: nil
        ) == .unknown)
    }

    @Test func mainlandChinaAllowsLocalAndConfiguredDomesticProviders() {
        let region = AIRegionContext(
            region: .mainlandChina,
            source: .appStorefront,
            countryCode: "CHN"
        )

        let localDecision = AIAvailabilityPolicy.decision(
            for: .localDiscriminativeModel,
            regionContext: region
        )
        #expect(localDecision.isAllowed)
        #expect(localDecision.shouldExposeConfiguration)

        let localGenerativeDecision = AIAvailabilityPolicy.decision(
            for: .localGenerativeModel,
            regionContext: region
        )
        #expect(localGenerativeDecision.isAllowed)
        #expect(localGenerativeDecision.shouldExposeConfiguration)
        #expect(!localGenerativeDecision.requiresExplicitConsent)

        let configuredRemote = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: region
        )
        #expect(configuredRemote.isAllowed)
        #expect(configuredRemote.shouldExposeConfiguration)
        #expect(configuredRemote.requiresExplicitConsent)

        for executionClass in [AIExecutionClass.appleSystemModel, .bundledRemote] {
            let decision = AIAvailabilityPolicy.decision(
                for: executionClass,
                regionContext: region
            )
            #expect(!decision.isAllowed)
            #expect(!decision.shouldExposeConfiguration)
            #expect(decision.denialReason == .regionRestricted)
        }
    }

    @Test func unknownRegionFailsClosedForRemoteProviders() {
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: .unknown
        )
        #expect(!decision.isAllowed)
        #expect(!decision.shouldExposeConfiguration)
        #expect(decision.denialReason == .regionUndetermined)
    }

    @Test func internationalRemoteProviderRequiresConsent() {
        let region = AIRegionContext(
            region: .international,
            source: .appStorefront,
            countryCode: "USA"
        )
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: region
        )
        #expect(decision.isAllowed)
        #expect(decision.shouldExposeConfiguration)
        #expect(decision.requiresExplicitConsent)
    }

    @Test func remoteResultsRequireTheCurrentAllowedRegionRevision() {
        let captured = AIRegionSnapshot(
            context: AIRegionContext(
                region: .international,
                source: .appStorefront,
                countryCode: "USA"
            ),
            revision: 7
        )
        #expect(AIRegionRequestPolicy.canSendRemoteRequest(
            captured: captured,
            latest: captured
        ))
        #expect(AIRegionRequestPolicy.canCommitRemoteResponse(
            captured: captured,
            latest: captured
        ))

        let refreshed = AIRegionSnapshot(context: captured.context, revision: 8)
        #expect(!AIRegionRequestPolicy.canSendRemoteRequest(
            captured: captured,
            latest: refreshed
        ))
        #expect(!AIRegionRequestPolicy.canCommitRemoteResponse(
            captured: captured,
            latest: refreshed
        ))
    }

    @Test func unknownAndMainlandRegionsFailClosed() {
        let international = AIRegionSnapshot(
            context: AIRegionContext(
                region: .international,
                source: .appStorefront,
                countryCode: "USA"
            ),
            revision: 3
        )
        for context in [
            AIRegionContext.unknown,
            AIRegionContext(
                region: .mainlandChina,
                source: .appStorefront,
                countryCode: "CHN"
            ),
        ] {
            let latest = AIRegionSnapshot(context: context, revision: 4)
            #expect(!AIRegionRequestPolicy.canSendRemoteRequest(
                captured: international,
                latest: latest
            ))
            #expect(!AIRegionRequestPolicy.canCommitRemoteResponse(
                captured: international,
                latest: latest
            ))
        }
    }
}

@Suite("AI provider routing")
struct AIProviderRoutingTests {
    private let international = AIRegionContext(
        region: .international,
        source: .appStorefront,
        countryCode: "GBR"
    )

    @Test func routingFiltersCapabilityStateRegionAndConsent() {
        let local = AIProviderDescriptor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Local",
            kind: .coreML,
            executionClass: .localDiscriminativeModel,
            capabilities: [.embeddings],
            priority: 10
        )
        let remote = AIProviderDescriptor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayName: "Remote",
            kind: .openAICompatible,
            executionClass: .userConfiguredRemote,
            capabilities: [.embeddings],
            priority: 100
        )
        let disabled = AIProviderDescriptor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            displayName: "Disabled",
            kind: .coreML,
            executionClass: .localDiscriminativeModel,
            capabilities: [.embeddings],
            priority: 200,
            isEnabled: false
        )

        #expect(AIProviderRoutingPolicy.candidates(
            from: [local, remote, disabled],
            capability: .embeddings,
            regionContext: international,
            hasExplicitRemoteConsent: false
        ).map(\.id) == [local.id])

        #expect(AIProviderRoutingPolicy.candidates(
            from: [local, remote, disabled],
            capability: .embeddings,
            regionContext: international,
            hasExplicitRemoteConsent: true
        ).map(\.id) == [remote.id, local.id])
    }

    @Test func mainlandRoutingRequiresConsentBeforeEndpointPolicyRuns() {
        let remote = AIRemoteProviderConfiguration(
            generationModel: "example-model",
            isEnabled: true
        ).descriptor
        let mainland = AIRegionContext(
            region: .mainlandChina,
            source: .appStorefront,
            countryCode: "CHN"
        )

        #expect(AIProviderRoutingPolicy.candidates(
            from: [remote],
            capability: .semanticSearchInterpretation,
            regionContext: mainland,
            hasExplicitRemoteConsent: false
        ).isEmpty)
        #expect(AIProviderRoutingPolicy.candidates(
            from: [remote],
            capability: .semanticSearchInterpretation,
            regionContext: mainland,
            hasExplicitRemoteConsent: true
        ).map(\.id) == [remote.id])
    }
}

@Suite("AI remote endpoint policy")
struct AIRemoteEndpointPolicyTests {
    @Test func recognizesOnlyOfficialOpenAIPlatformEndpoints() {
        let official = AIProviderPreset.openAI.applying(
            to: AIRemoteProviderConfiguration()
        )
        #expect(AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
            configuration: official
        ))

        var versioned = official
        versioned.baseURL = "https://API.OPENAI.COM/v1/"
        #expect(AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
            configuration: versioned
        ))

        var insecure = official
        insecure.baseURL = "http://api.openai.com"
        #expect(!AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
            configuration: insecure
        ))

        var lookalike = official
        lookalike.baseURL = "https://api.openai.com.example.invalid/v1"
        #expect(!AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
            configuration: lookalike
        ))

        var nonstandardPort = official
        nonstandardPort.baseURL = "https://api.openai.com:8443/v1"
        #expect(!AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
            configuration: nonstandardPort
        ))

        var relay = official
        relay.baseURL = "https://relay.example.invalid/v1"
        #expect(!AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
            configuration: relay
        ))
    }

    @Test func normalizesHTTPSBaseURLAndBuildsEndpoints() throws {
        let configuration = AIRemoteProviderConfiguration(
            baseURL: " https://api.example.com/v1/ ",
            apiStyle: .chatCompletions,
            generationModel: "model"
        )
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: configuration
        ).absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(try AIRemoteEndpointPolicy.embeddingsEndpoint(
            configuration: configuration
        ).absoluteString == "https://api.example.com/v1/embeddings")
        #expect(try AIRemoteEndpointPolicy.modelsEndpoint(
            configuration: configuration
        ).absoluteString == "https://api.example.com/v1/models")
    }

    @Test func providerAwarePathModesBuildDocumentedEndpoints() throws {
        let openAI = AIRemoteProviderConfiguration(
            baseURL: "https://api.openai.com",
            apiStyle: .responses,
            apiPathMode: .automatic,
            generationModel: "model"
        )
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: openAI
        ).absoluteString == "https://api.openai.com/v1/responses")

        let customOpenAI = AIRemoteProviderConfiguration(
            baseURL: "https://relay.example.com",
            apiStyle: .chatCompletions,
            apiPathMode: .automatic,
            generationModel: "model"
        )
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: customOpenAI
        ).absoluteString == "https://relay.example.com/v1/chat/completions")

        let deepSeek = AIProviderPreset.deepSeekOpenAI.applying(
            to: AIRemoteProviderConfiguration()
        )
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: deepSeek
        ).absoluteString == "https://api.deepseek.com/chat/completions")

        let anthropic = AIProviderPreset.anthropic.applying(
            to: AIRemoteProviderConfiguration()
        )
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: anthropic
        ).absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(try AIRemoteEndpointPolicy.modelsEndpoint(
            configuration: anthropic
        ).absoluteString == "https://api.anthropic.com/v1/models")

        let deepSeekAnthropic = AIProviderPreset.deepSeekAnthropic.applying(
            to: AIRemoteProviderConfiguration()
        )
        #expect(deepSeekAnthropic.authenticationStyle == .xAPIKey)
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: deepSeekAnthropic
        ).absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
        #expect(try AIRemoteEndpointPolicy.modelsEndpoint(
            configuration: deepSeekAnthropic
        ).absoluteString == "https://api.deepseek.com/models")
        #expect(AIRemoteEndpointPolicy.usesOpenAIModelCatalog(
            configuration: deepSeekAnthropic
        ))

        let gemini = AIProviderPreset.gemini.applying(
            to: AIRemoteProviderConfiguration()
        )
        #expect(gemini.apiStyle == .geminiGenerateContent)
        #expect(gemini.authenticationStyle == .xGoogAPIKey)
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: gemini
        ).absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent")
        #expect(try AIRemoteEndpointPolicy.modelsEndpoint(
            configuration: gemini
        ).absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")
    }

    @Test func customPathCanBeUsedDirectlyOrReceiveV1() throws {
        var configuration = AIRemoteProviderConfiguration(
            baseURL: "https://relay.example.com/openai",
            apiStyle: .responses,
            apiPathMode: .asEntered,
            generationModel: "model"
        )
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: configuration
        ).absoluteString == "https://relay.example.com/openai/responses")

        configuration.apiPathMode = .appendV1
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: configuration
        ).absoluteString == "https://relay.example.com/openai/v1/responses")
    }

    @Test func legacyConfigurationDecodesWithSafeAutomaticDefaults() throws {
        let encoded = try JSONEncoder().encode(AIRemoteProviderConfiguration())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["apiPathMode"] = nil
        object["authenticationStyle"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            AIRemoteProviderConfiguration.self,
            from: legacyData
        )

        #expect(decoded.apiPathMode == .automatic)
        #expect(decoded.authenticationStyle == .automatic)
    }

    @Test func localHTTPRequiresExplicitConsent() throws {
        #expect(throws: AIRemoteEndpointValidationError.insecureLocalHTTPRequiresConsent) {
            try AIRemoteEndpointPolicy.validatedBaseURL(
                "http://192.168.1.20:11434/v1",
                allowInsecureLocalHTTP: false
            )
        }
        #expect(try AIRemoteEndpointPolicy.validatedBaseURL(
            "http://192.168.1.20:11434/v1",
            allowInsecureLocalHTTP: true
        ).host == "192.168.1.20")
    }

    @Test func publicHTTPAndEmbeddedCredentialsAreRejected() {
        #expect(throws: AIRemoteEndpointValidationError.insecurePublicHTTP) {
            try AIRemoteEndpointPolicy.validatedBaseURL(
                "http://api.example.com/v1",
                allowInsecureLocalHTTP: true
            )
        }
        #expect(throws: AIRemoteEndpointValidationError.embeddedCredential) {
            try AIRemoteEndpointPolicy.validatedBaseURL(
                "https://user:password@api.example.com/v1",
                allowInsecureLocalHTTP: false
            )
        }
    }

    @Test func insecureHTTPAllowsOnlyPrivateIPAddressLiterals() throws {
        for host in [
            "127.0.0.1",
            "127.255.255.254",
            "10.0.0.1",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.0.1",
            "169.254.1.1",
            "[::1]",
            "[fc00::1]",
            "[fdff::1]",
            "[fe80::1]",
            "[febf::1]",
        ] {
            #expect(try AIRemoteEndpointPolicy.validatedBaseURL(
                "http://\(host):11434/v1",
                allowInsecureLocalHTTP: true
            ).scheme == "http")
        }

        for host in [
            "localhost",
            "model.local",
            "model.home",
            "model.lan",
            "model.internal",
            "8.8.8.8",
            "100.64.0.1",
            "172.15.255.255",
            "172.32.0.1",
            "169.255.0.1",
            "0.0.0.0",
            "[2001:4860:4860::8888]",
            "[fec0::1]",
            "[::ffff:192.168.1.1]",
        ] {
            #expect(throws: AIRemoteEndpointValidationError.insecurePublicHTTP) {
                try AIRemoteEndpointPolicy.validatedBaseURL(
                    "http://\(host):11434/v1",
                    allowInsecureLocalHTTP: true
                )
            }
        }
    }

    @Test func descriptorOnlyAdvertisesConfiguredCapabilities() throws {
        let generationOnly = AIRemoteProviderConfiguration(
            generationModel: "chat-model",
            embeddingModel: "",
            isEnabled: true
        ).descriptor
        #expect(generationOnly.capabilities.contains(.semanticSearchInterpretation))
        #expect(generationOnly.capabilities.contains(.lyricsTranslation))
        #expect(!generationOnly.capabilities.contains(.audioTranscription))
        #expect(!generationOnly.capabilities.contains(.embeddings))
        #expect(!generationOnly.capabilities.contains(.reranking))
        #expect(!generationOnly.capabilities.contains(.songAnnotation))
        #expect(generationOnly.capabilities.contains(.recommendations))
        #expect(!generationOnly.capabilities.contains(.commandInterpretation))

        let embeddingOnly = AIRemoteProviderConfiguration(
            generationModel: "",
            embeddingModel: "embedding-model",
            isEnabled: true
        ).descriptor
        #expect(!embeddingOnly.capabilities.contains(.semanticSearchInterpretation))
        #expect(!embeddingOnly.capabilities.contains(.lyricsTranslation))
        #expect(!embeddingOnly.capabilities.contains(.audioTranscription))
        #expect(embeddingOnly.capabilities.contains(.embeddings))

        let anthropic = AIRemoteProviderConfiguration(
            apiStyle: .anthropicMessages,
            generationModel: "claude-example",
            embeddingModel: "must-not-be-advertised",
            isEnabled: true
        )
        #expect(anthropic.descriptor.capabilities.contains(.semanticSearchInterpretation))
        #expect(anthropic.descriptor.capabilities.contains(.lyricsTranslation))
        #expect(!anthropic.descriptor.capabilities.contains(.audioTranscription))
        #expect(!anthropic.descriptor.capabilities.contains(.embeddings))
        #expect(throws: AIRemoteEndpointValidationError.unsupportedCapability) {
            try AIRemoteEndpointPolicy.embeddingsEndpoint(configuration: anthropic)
        }

        let gemini = AIProviderPreset.gemini.applying(to:
            AIRemoteProviderConfiguration(isEnabled: true)
        )
        #expect(gemini.descriptor.capabilities.contains(.audioTranscription))
        #expect(try AIRemoteEndpointPolicy.geminiInteractionsEndpoint(
            configuration: gemini
        ).path == "/v1beta/interactions")
        #expect(try AIRemoteEndpointPolicy.geminiFilesUploadEndpoint(
            configuration: gemini
        ).path == "/upload/v1beta/files")
    }

    @Test func credentialAccountIsStableAndContainsNoSecretMaterial() {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        #expect(AICredentialStoragePolicy.legacyAccount(profileID: profileID)
            == "ai.provider.f36f1dd2-7471-4d96-a6b8-bba6a3ef02c0.apiKey")
    }

    @Test func credentialAccountBindsToCanonicalOrigin() throws {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        let first = try AICredentialStoragePolicy.account(
            profileID: profileID,
            baseURL: "https://API.Example.com:443/v1/",
            allowInsecureLocalHTTP: false
        )
        let sameOrigin = try AICredentialStoragePolicy.account(
            profileID: profileID,
            baseURL: "https://api.example.com/compatible/v2",
            allowInsecureLocalHTTP: false
        )
        let differentPort = try AICredentialStoragePolicy.account(
            profileID: profileID,
            baseURL: "https://api.example.com:8443/v1",
            allowInsecureLocalHTTP: false
        )

        #expect(first == sameOrigin)
        #expect(first.contains("https://api.example.com"))
        #expect(first != differentPort)
        #expect(try AICredentialStoragePolicy.canonicalOrigin(
            baseURL: "http://192.168.1.20:80/v1",
            allowInsecureLocalHTTP: true
        ) == "http://192.168.1.20")
    }

    @Test func credentialAccountChangesAcrossSchemeHostAndEffectivePort() throws {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        let urls = [
            ("https://api.example.com/v1", false),
            ("https://other.example.com/v1", false),
            ("https://api.example.com:8443/v1", false),
            ("http://127.0.0.1:443/v1", true),
        ]
        let accounts = try urls.map { baseURL, allowHTTP in
            try AICredentialStoragePolicy.account(
                profileID: profileID,
                baseURL: baseURL,
                allowInsecureLocalHTTP: allowHTTP
            )
        }
        #expect(Set(accounts).count == urls.count)
    }

    @Test func scopedCredentialSeparatesPathProtocolAndAuthentication() throws {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        let openAI = AIRemoteProviderConfiguration(
            id: profileID,
            baseURL: "https://relay.example.com/openai",
            apiStyle: .responses,
            apiPathMode: .appendV1,
            authenticationStyle: .bearer
        )
        var anthropic = openAI
        anthropic.baseURL = "https://relay.example.com/anthropic"
        anthropic.apiStyle = .anthropicMessages
        anthropic.authenticationStyle = .xAPIKey
        var bearerAnthropic = anthropic
        bearerAnthropic.authenticationStyle = .bearer

        let accounts = try [
            AICredentialStoragePolicy.scopedAccount(configuration: openAI),
            AICredentialStoragePolicy.scopedAccount(configuration: anthropic),
            AICredentialStoragePolicy.scopedAccount(configuration: bearerAnthropic),
        ]
        #expect(Set(accounts).count == accounts.count)
    }

    @Test func presetsKeepKnownProtocolSettingsAndPreserveProfileIdentity() throws {
        let id = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        let original = AIRemoteProviderConfiguration(id: id, embeddingModel: "old")
        let anthropic = AIProviderPreset.anthropic.applying(to: original)

        #expect(anthropic.id == id)
        #expect(anthropic.apiStyle == .anthropicMessages)
        #expect(anthropic.authenticationStyle == .xAPIKey)
        #expect(anthropic.embeddingModel.isEmpty)
        #expect(!anthropic.prefersCustomConfiguration)
        #expect(AIProviderPreset.matching(configuration: anthropic) == .anthropic)

        let custom = AIProviderPreset.custom.applying(to: anthropic)
        #expect(custom.prefersCustomConfiguration)
        #expect(AIProviderPreset.matching(configuration: custom) == .custom)
        #expect(custom.baseURL == anthropic.baseURL)
        #expect(custom.authenticationStyle == anthropic.authenticationStyle)
        #expect(try AICredentialStoragePolicy.scopedAccount(configuration: custom)
            == AICredentialStoragePolicy.scopedAccount(configuration: anthropic))
        let decodedCustom = try JSONDecoder().decode(
            AIRemoteProviderConfiguration.self,
            from: JSONEncoder().encode(custom)
        )
        #expect(decodedCustom.prefersCustomConfiguration)
        #expect(AIProviderPreset.matching(configuration: decodedCustom) == .custom)
    }

    @Test func openAIPresetUsesExplicitAPINameAndMigratesLegacyProfiles() throws {
        let id = UUID(uuidString: "AA2D40DE-B7C7-46DC-A291-5427BDCE96EE")!
        let preset = AIProviderPreset.openAI.applying(
            to: AIRemoteProviderConfiguration(id: id)
        )
        #expect(preset.displayName == "OpenAI API")

        var legacy = preset
        legacy.displayName = "OpenAI"
        var expected = legacy
        expected.displayName = "OpenAI API"
        let migrated = AIRemoteProviderSet(
            providers: [legacy],
            primaryProviderID: id,
            fallbackEnabled: false
        ).primaryProvider

        #expect(migrated == expected)
        #expect(try AICredentialStoragePolicy.scopedAccount(configuration: migrated)
            == AICredentialStoragePolicy.scopedAccount(configuration: legacy))

        var custom = legacy
        custom.prefersCustomConfiguration = true
        let preserved = AIRemoteProviderSet(
            providers: [custom],
            primaryProviderID: id,
            fallbackEnabled: false
        ).primaryProvider
        #expect(preserved.displayName == "OpenAI")
    }

    @Test func providerCatalogSeparatesMainlandAndInternationalServices() throws {
        #expect(AIProviderPreset.catalog(for: .mainlandChina)
            == AIProviderPreset.mainlandChinaCatalog)
        #expect(AIProviderPreset.catalog(for: .international)
            == AIProviderPreset.globalCatalog + AIProviderPreset.mainlandChinaCatalog)
        #expect(AIProviderPreset.catalog(for: .mainlandChina).contains(.xiaomiMiMo))
        #expect(!AIProviderPreset.catalog(for: .mainlandChina).contains(.openRouter))
        #expect(AIProviderPreset.catalog(for: .international).contains(.nvidiaNIM))
        #expect(AIProviderPreset.catalog(for: .international).contains(.openRouter))
        #expect(AIProviderPreset.catalog(for: .unknown).isEmpty)

        let qwen = AIProviderPreset.qwen.applying(to: AIRemoteProviderConfiguration())
        #expect(qwen.baseURL == "https://dashscope.aliyuncs.com/compatible-mode/v1")
        #expect(qwen.generationModel == "qwen-plus")
        #expect(try AIRemoteEndpointPolicy.generationEndpoint(
            configuration: qwen
        ).absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")

        let gemini = AIProviderPreset.gemini.applying(to: AIRemoteProviderConfiguration())
        #expect(gemini.baseURL == "https://generativelanguage.googleapis.com/v1beta")
        #expect(gemini.generationModel == "gemini-3.7-flash")
        #expect(try AIRemoteEndpointPolicy.modelsEndpoint(
            configuration: gemini
        ).absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")

        let xiaomi = AIProviderPreset.xiaomiMiMo.applying(to: AIRemoteProviderConfiguration())
        #expect(xiaomi.baseURL == "https://api.xiaomimimo.com/v1")
        #expect(xiaomi.generationModel == "mimo-v2.5-pro")

        let nvidia = AIProviderPreset.nvidiaNIM.applying(to: AIRemoteProviderConfiguration())
        #expect(nvidia.baseURL == "https://integrate.api.nvidia.com/v1")
    }

    @Test func customCompatibilityModeKeepsEndpointDetailsAutomatic() {
        let original = AIRemoteProviderConfiguration(
            baseURL: "https://relay.example.com/anthropic",
            apiStyle: .responses,
            apiPathMode: .asEntered,
            authenticationStyle: .bearer,
            embeddingModel: "embedding"
        )
        let configured = AIProviderCompatibilityMode.anthropicMessages.applying(to: original)

        #expect(configured.apiStyle == .anthropicMessages)
        #expect(configured.apiPathMode == .automatic)
        #expect(configured.authenticationStyle == .automatic)
        #expect(configured.embeddingModel.isEmpty)

        let gemini = AIProviderCompatibilityMode.geminiGenerateContent.applying(to: original)
        #expect(gemini.apiStyle == .geminiGenerateContent)
        #expect(gemini.apiPathMode == .automatic)
        #expect(gemini.authenticationStyle == .automatic)
        #expect(gemini.embeddingModel.isEmpty)
    }

    @Test func mainlandRegionChecksProviderEndpointAndAggregatorModels() {
        let deepSeek = AIProviderPreset.deepSeekOpenAI.applying(
            to: AIRemoteProviderConfiguration()
        )
        let openAI = AIProviderPreset.openAI.applying(
            to: AIRemoteProviderConfiguration()
        )
        var qwen = AIProviderPreset.qwen.applying(to: AIRemoteProviderConfiguration())

        #expect(AIProviderRegionPolicy.allows(
            configuration: deepSeek,
            region: .mainlandChina,
            purpose: .generation
        ))
        #expect(!AIProviderRegionPolicy.allows(
            configuration: openAI,
            region: .mainlandChina,
            purpose: .modelCatalog
        ))
        #expect(AIProviderRegionPolicy.allows(
            configuration: openAI,
            region: .international,
            purpose: .generation
        ))
        #expect(AIProviderRegionPolicy.allows(
            configuration: qwen,
            region: .mainlandChina,
            purpose: .generation
        ))

        qwen.generationModel = "openai/gpt-oss-20b"
        #expect(AIProviderRegionPolicy.allows(
            configuration: qwen,
            region: .mainlandChina,
            purpose: .modelCatalog
        ))
        #expect(!AIProviderRegionPolicy.allows(
            configuration: qwen,
            region: .mainlandChina,
            purpose: .generation
        ))

        let filtered = AIProviderRegionPolicy.filterModels(
            [
                AIProviderModel(id: "Qwen/Qwen3.5-Plus"),
                AIProviderModel(id: "openai/gpt-oss-20b"),
                AIProviderModel(id: "deepseek-v4-flash"),
            ],
            configuration: qwen,
            region: .mainlandChina
        )
        #expect(filtered.map(\.id) == ["Qwen/Qwen3.5-Plus", "deepseek-v4-flash"])
    }

    @Test func AICredentialsAreEligibleForICloudKeychainMigration() {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        #expect(AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: AICredentialStoragePolicy.legacyAccount(profileID: profileID)
        ))
        #expect(AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: "ai.provider.future-device-only-secret"
        ))
        #expect(AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: "source.connection.example"
        ))
    }

    @Test func providerSetRoutesPrimaryThenEnabledFallbacks() {
        let primary = AIRemoteProviderConfiguration(
            displayName: "Primary",
            isEnabled: true
        )
        let disabled = AIRemoteProviderConfiguration(
            displayName: "Disabled",
            isEnabled: false
        )
        let fallback = AIRemoteProviderConfiguration(
            displayName: "Fallback",
            isEnabled: true
        )
        let providers = AIRemoteProviderSet(
            providers: [disabled, fallback, primary],
            primaryProviderID: primary.id,
            fallbackEnabled: true
        )

        #expect(providers.routedProviders.map(\.id) == [primary.id, fallback.id])
        #expect(AIRemoteProviderSet(
            providers: providers.providers,
            primaryProviderID: primary.id,
            fallbackEnabled: false
        ).routedProviders.map(\.id) == [primary.id])
    }
}

@Suite("AI scene recommendations")
struct AIRecommendationPolicyTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test func automaticSceneUsesLocalTimeWithoutOverridingManualChoice() throws {
        let bedtime = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 26, hour: 23)
        ))
        let commute = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 26, hour: 8)
        ))
        let focus = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 26, hour: 14)
        ))

        #expect(AIRecommendationSceneResolver.resolved(
            .automatic,
            at: bedtime,
            calendar: calendar
        ) == .bedtime)
        #expect(AIRecommendationSceneResolver.resolved(
            .automatic,
            at: commute,
            calendar: calendar
        ) == .driving)
        #expect(AIRecommendationSceneResolver.resolved(
            .automatic,
            at: focus,
            calendar: calendar
        ) == .focus)
        #expect(AIRecommendationSceneResolver.resolved(
            .workout,
            at: bedtime,
            calendar: calendar
        ) == .workout)
    }

    @Test func recommendationPlanRejectsUnknownAndDuplicateSongs() {
        let request = AIRecommendationRequest(
            scene: .bedtime,
            preferences: [],
            candidates: [
                AIRecommendationCandidate(songID: "one", title: "One", artist: "A"),
                AIRecommendationCandidate(songID: "two", title: "Two", artist: "B"),
            ],
            maximumResults: 2
        )
        let plan = AIRecommendationPlan(
            summary: String(repeating: "s", count: 240),
            selections: [
                AIRecommendationSelection(songID: "one", reason: " calm "),
                AIRecommendationSelection(songID: "missing", reason: "invented"),
                AIRecommendationSelection(songID: "one", reason: "duplicate"),
                AIRecommendationSelection(songID: "two", reason: "   "),
            ]
        ).normalized(for: request)

        #expect(plan.selections == [
            AIRecommendationSelection(songID: "one", reason: "calm")
        ])
        #expect(plan.summary.count == 180)
    }

    @Test func recommendationPlanRejectsSingleArtistConcentration() {
        let candidates = (0..<8).map { index in
            AIRecommendationCandidate(
                songID: "song-\(index)",
                title: "Song \(index)",
                artist: index < 5 ? "Artist A" : "Artist \(index)"
            )
        }
        let request = AIRecommendationRequest(
            scene: .driving,
            preferences: [],
            candidates: candidates,
            maximumResults: 8
        )
        let plan = AIRecommendationPlan(
            selections: (0..<8).map { index in
                AIRecommendationSelection(songID: "song-\(index)", reason: "reason")
            }
        ).normalized(for: request)

        #expect(plan.selections.isEmpty)
    }

    @Test func recommendationPlanAcceptsBalancedArtistSelection() {
        let candidates = (0..<8).map { index in
            AIRecommendationCandidate(
                songID: "song-\(index)",
                title: "Song \(index)",
                artist: "Artist \(index / 2)"
            )
        }
        let request = AIRecommendationRequest(
            scene: .focus,
            preferences: [],
            candidates: candidates,
            maximumResults: 8,
            minimumResults: 8
        )
        let plan = AIRecommendationPlan(
            selections: (0..<8).map { index in
                AIRecommendationSelection(songID: "song-\(index)", reason: "reason")
            }
        ).normalized(for: request)

        #expect(plan.selections.count == 8)
    }

    @Test func recommendationPlanRejectsFewerThanRequiredSelections() {
        let candidates = (0..<12).map { index in
            AIRecommendationCandidate(
                songID: "song-\(index)",
                title: "Song \(index)",
                artist: "Artist \(index / 2)"
            )
        }
        let request = AIRecommendationRequest(
            scene: .relaxation,
            preferences: [],
            candidates: candidates,
            maximumResults: 12,
            minimumResults: 8
        )
        let plan = AIRecommendationPlan(
            selections: (0..<7).map { index in
                AIRecommendationSelection(songID: "song-\(index)", reason: "reason")
            }
        ).normalized(for: request)

        #expect(plan.selections.isEmpty)
    }

    @Test func recommendationRequestBoundsResultRangeToAvailableCandidates() {
        let candidates = (0..<20).map { index in
            AIRecommendationCandidate(
                songID: "song-\(index)",
                title: "Song \(index)",
                artist: "Artist \(index)"
            )
        }
        let fullPage = AIRecommendationRequest(
            scene: .focus,
            preferences: [],
            candidates: candidates,
            maximumResults: 20,
            minimumResults: 8
        )
        let shortPage = AIRecommendationRequest(
            scene: .focus,
            preferences: [],
            candidates: Array(candidates.prefix(5)),
            maximumResults: 12,
            minimumResults: 8
        )

        #expect(fullPage.maximumResults == 12)
        #expect(fullPage.minimumResults == 8)
        #expect(shortPage.maximumResults == 5)
        #expect(shortPage.minimumResults == 5)
    }

    @Test func recommendationIntentIsSanitizedAndBounded() {
        let request = AIRecommendationRequest(
            scene: .relaxation,
            intent: "  rainy\n  " + String(repeating: "m", count: 200),
            preferences: [],
            candidates: [
                AIRecommendationCandidate(songID: "one", title: "One", artist: "A"),
            ]
        )

        #expect(request.intent?.hasPrefix("rainy ") == true)
        #expect(request.intent?.contains("\n") == false)
        #expect(request.intent?.count == 160)
    }

    @Test func customRecommendationIntentsNormalizeAndDeduplicate() throws {
        let duplicateID = UUID()
        let raw = try JSONEncoder().encode([
            AICustomRecommendationIntent(
                id: duplicateID,
                title: "  凌晨返程  ",
                prompt: "  slow\n  rain  "
            ),
            AICustomRecommendationIntent(
                id: duplicateID,
                title: "Duplicate ID",
                prompt: "ignored"
            ),
            AICustomRecommendationIntent(
                title: "凌晨返程",
                prompt: "duplicate title"
            ),
            AICustomRecommendationIntent(title: "", prompt: "invalid"),
        ])
        let decoded = AIRecommendationIntentStoragePolicy.decode(
            String(decoding: raw, as: UTF8.self)
        )

        #expect(decoded.count == 1)
        #expect(decoded[0].title == "凌晨返程")
        #expect(decoded[0].prompt == "slow rain")
        #expect(AIRecommendationIntentStoragePolicy.decode(
            AIRecommendationIntentStoragePolicy.encode(decoded)
        ) == decoded)
    }

    @Test func audioTranscriptionCreatesReviewableWordTimedLyrics() {
        let result = AIAudioTranscriptionResult(
            transcript: "Hello world! Home again.",
            words: [
                AIAudioTranscriptionWord(text: "Hello", startTime: 0.2, endTime: 0.6),
                AIAudioTranscriptionWord(text: "world", startTime: 0.7, endTime: 1.1),
                AIAudioTranscriptionWord(text: "!", startTime: 1.1, endTime: 1.2),
                AIAudioTranscriptionWord(text: "Home", startTime: 2.0, endTime: 2.4),
                AIAudioTranscriptionWord(text: "again", startTime: 2.5, endTime: 3.0),
                AIAudioTranscriptionWord(text: ".", startTime: 3.0, endTime: 3.1),
            ]
        )
        let document = AIAudioTranscriptionLyricsFormatter.document(from: result)

        #expect(document.lines.map(\.text) == ["Hello world!", "Home again."])
        #expect(document.lines.map(\.timestamp) == [0.2, 2.0])
        #expect(document.lines[0].syllables?.map(\.text) == ["Hello", " world", "!"])
        #expect(document.serialized().contains("<00:00.700> world"))
    }

    @Test func audioTranscriptionRequestBoundsAndDeduplicatesVocabularyHints() {
        let request = AIAudioTranscriptionRequest(
            audioFileURL: URL(fileURLWithPath: "/tmp/song.mp3"),
            mimeType: " audio/mpeg ",
            displayName: "  Song\nName  ",
            languageCodes: [" zh-CN ", "", "en-US"],
            customVocabulary: ["  Artist  Name ", "artist name", "专辑\n名称", ""]
        )

        #expect(request.mimeType == "audio/mpeg")
        #expect(request.displayName == "Song Name")
        #expect(request.languageCodes == ["zh-CN", "en-US"])
        #expect(request.customVocabulary == ["Artist Name", "专辑 名称"])
    }
}

@Suite("AI request limits")
struct AIRequestLimitPolicyTests {
    @Test func initializationProducesOnlySafeTimeouts() {
        #expect(AIRemoteProviderConfiguration(requestTimeout: .nan).requestTimeout == 12)
        #expect(AIRemoteProviderConfiguration(requestTimeout: .infinity).requestTimeout == 12)
        #expect(AIRemoteProviderConfiguration(requestTimeout: 1).requestTimeout == 2)
        #expect(AIRemoteProviderConfiguration(requestTimeout: 61).requestTimeout == 60)
    }

    @Test func decodingRejectsPersistedOutOfRangeTimeouts() throws {
        let validData = try JSONEncoder().encode(AIRemoteProviderConfiguration())
        var object = try #require(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )

        for timeout in [1, 61] {
            object["requestTimeout"] = timeout
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AIRemoteProviderConfiguration.self, from: data)
            }
        }
    }

    @Test func encodingAndRuntimeConversionRejectMutatedInvalidTimeouts() {
        for timeout in [TimeInterval.nan, .infinity, -.infinity, 1, 61] {
            var configuration = AIRemoteProviderConfiguration()
            configuration.requestTimeout = timeout
            #expect(throws: EncodingError.self) {
                try JSONEncoder().encode(configuration)
            }
            #expect(AIRequestTimeoutPolicy.validated(timeout) == nil)
            #expect(AIRequestTimeoutPolicy.nanoseconds(timeout) == nil)
        }
        #expect(AIRequestTimeoutPolicy.nanoseconds(2) == 2_000_000_000)
        #expect(AIRequestTimeoutPolicy.nanoseconds(60) == 60_000_000_000)
    }

    @Test func responseLimitChecksEveryIncomingChunkWithoutOverflow() {
        let maximum = AIResponseSizePolicy.maximumBytes
        #expect(AIResponseSizePolicy.allowsAppend(
            currentBytes: maximum - 1,
            incomingBytes: 1
        ))
        #expect(!AIResponseSizePolicy.allowsAppend(
            currentBytes: maximum,
            incomingBytes: 1
        ))
        #expect(!AIResponseSizePolicy.allowsAppend(
            currentBytes: Int.max,
            incomingBytes: Int.max
        ))
        #expect(!AIResponseSizePolicy.allowsAppend(currentBytes: -1, incomingBytes: 1))
        #expect(!AIResponseSizePolicy.allowsAppend(currentBytes: 0, incomingBytes: -1))
    }
}

@Suite("AI semantic search plan")
struct AISemanticSearchPlanTests {
    @Test func recommendationIntentPresetsResolveLocalizedLabels() {
        for preset in AIRecommendationIntentPreset.allCases {
            #expect(!preset.localizedTitle.isEmpty)
            #expect(!preset.localizedDetail.isEmpty)
            #expect(preset.localizedTitle != "ai_recommendation_intent_\(preset.rawValue)")
            #expect(
                preset.localizedDetail
                    != "ai_recommendation_intent_\(preset.rawValue)_detail"
            )
        }
    }

    @Test func normalizationRemovesDuplicatesOriginalAndUnsafeLengths() {
        let request = AISemanticSearchRequest(query: "乡愁", maximumExpansionTerms: 3)
        let plan = AISemanticSearchPlan(
            expandedTerms: ["故乡", " 故乡 ", "乡愁", "归途", "离别", String(repeating: "a", count: 49)],
            themes: ["思乡", "思乡"],
            moods: ["怀念\n安静"]
        ).normalized(for: request)

        #expect(plan.expandedTerms == ["故乡", "归途", "离别"])
        #expect(plan.themes == ["思乡"])
        #expect(plan.moods == ["怀念 安静"])
    }

    @Test func semanticLibraryConceptsAreDeduplicatedAndLimitedToEight() {
        let plan = AISemanticSearchPlan(
            expandedTerms: [" One ", "one", "Two", "Three", "Four"],
            themes: ["Five", "Six", "Seven", "Eight", "Nine"],
            moods: ["Ten"]
        )
        #expect(AISemanticLibraryAggregationPolicy.concepts(from: plan) == [
            "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight",
        ])
    }

    @Test func semanticLibraryAggregationUsesTheBestScoreFromAllConcepts() {
        let candidates = [
            AISemanticLibraryMatchCandidate(
                songID: "song-a",
                title: "Beta",
                score: 80,
                relatedConcept: "first concept",
                conceptOrder: 0
            ),
            AISemanticLibraryMatchCandidate(
                songID: "song-b",
                title: "Alpha",
                score: 90,
                relatedConcept: "first concept",
                conceptOrder: 0
            ),
            AISemanticLibraryMatchCandidate(
                songID: "song-a",
                title: "Beta",
                score: 120,
                relatedConcept: "later better concept",
                conceptOrder: 7
            ),
        ]

        let ranked = AISemanticLibraryAggregationPolicy.rankedMatches(candidates)
        #expect(ranked.map(\.songID) == ["song-a", "song-b"])
        #expect(ranked.first?.score == 120)
        #expect(ranked.first?.relatedConcept == "later better concept")
    }

    @Test func semanticLibraryAggregationSortsStablyBeforeApplyingLimit() {
        var candidates = (0..<31).map { index in
            AISemanticLibraryMatchCandidate(
                songID: String(format: "song-%02d", 30 - index),
                title: index < 2 ? "Same" : String(format: "Title %02d", index),
                score: 100,
                relatedConcept: "concept",
                conceptOrder: 0
            )
        }
        candidates.append(AISemanticLibraryMatchCandidate(
            songID: "song-30",
            title: "Same",
            score: 100,
            relatedConcept: "later equal concept",
            conceptOrder: 4
        ))

        let ranked = AISemanticLibraryAggregationPolicy.rankedMatches(candidates)
        #expect(ranked.count == 30)
        #expect(ranked[0].songID == "song-29")
        #expect(ranked[1].songID == "song-30")
        #expect(ranked[1].relatedConcept == "concept")
        #expect(!ranked.contains(where: { $0.songID == "song-00" }))
    }
}
