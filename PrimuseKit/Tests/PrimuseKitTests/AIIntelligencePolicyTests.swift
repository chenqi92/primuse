import Foundation
import Testing
@testable import PrimuseKit

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

    @Test func mainlandChinaAllowsNonGenerativeLocalModelsOnly() {
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

        for executionClass in [
            AIExecutionClass.localGenerativeModel,
            .appleSystemModel,
            .userConfiguredRemote,
            .bundledRemote,
        ] {
            let decision = AIAvailabilityPolicy.decision(
                for: executionClass,
                regionContext: region
            )
            #expect(!decision.isAllowed)
            #expect(!decision.shouldExposeConfiguration)
            #expect(decision.denialReason == .regionRestricted)
        }
    }

    @Test func unknownRegionFailsClosedForGenerativeProviders() {
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

    @Test func mainlandRegionRemovesRemoteProviderEvenWithConsent() {
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
            hasExplicitRemoteConsent: true
        ).isEmpty)
    }
}

@Suite("AI remote endpoint policy")
struct AIRemoteEndpointPolicyTests {
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

    @Test func descriptorOnlyAdvertisesConfiguredCapabilities() {
        let generationOnly = AIRemoteProviderConfiguration(
            generationModel: "chat-model",
            embeddingModel: "",
            isEnabled: true
        ).descriptor
        #expect(generationOnly.capabilities.contains(.semanticSearchInterpretation))
        #expect(!generationOnly.capabilities.contains(.embeddings))

        let embeddingOnly = AIRemoteProviderConfiguration(
            generationModel: "",
            embeddingModel: "embedding-model",
            isEnabled: true
        ).descriptor
        #expect(!embeddingOnly.capabilities.contains(.semanticSearchInterpretation))
        #expect(embeddingOnly.capabilities.contains(.embeddings))
    }

    @Test func credentialAccountIsStableAndContainsNoSecretMaterial() {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        #expect(AICredentialStoragePolicy.account(profileID: profileID)
            == "ai.provider.f36f1dd2-7471-4d96-a6b8-bba6a3ef02c0.apiKey")
    }

    @Test func deviceOnlyAICredentialsAreExcludedFromICloudMigration() {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        #expect(!AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: AICredentialStoragePolicy.account(profileID: profileID)
        ))
        #expect(!AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: "ai.provider.future-device-only-secret"
        ))
        #expect(AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: "source.connection.example"
        ))
    }
}

@Suite("AI semantic search plan")
struct AISemanticSearchPlanTests {
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
}
