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
        #expect(try AIRemoteEndpointPolicy.modelsEndpoint(
            configuration: configuration
        ).absoluteString == "https://api.example.com/v1/models")
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

    @Test func deviceOnlyAICredentialsAreExcludedFromICloudMigration() {
        let profileID = UUID(uuidString: "F36F1DD2-7471-4D96-A6B8-BBA6A3EF02C0")!
        #expect(!AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: AICredentialStoragePolicy.legacyAccount(profileID: profileID)
        ))
        #expect(!AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: "ai.provider.future-device-only-secret"
        ))
        #expect(AICredentialStoragePolicy.isEligibleForICloudMigration(
            account: "source.connection.example"
        ))
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
