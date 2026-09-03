import CryptoKit
import DeviceCheck
import Foundation
import PrimuseKit
import StoreKit

enum PrimuseAIRelayError: Error, Equatable, Sendable {
    case unsupportedDevice
    case credentialUnavailable
    case credentialCorrupted
    case credentialPersistenceFailed
    case storeKitTransactionUnavailable
    case storeKitTransactionUnverified
    case storeKitAuthenticationCancelled
    case invalidResponse
    case responseTooLarge
    case requestFailed(statusCode: Int, code: String)
}

enum PrimuseAIRelayAuthenticationMethod: Equatable, Sendable {
    case appAttest
    case storeKitFallback
}

enum PrimuseAIRelayDiagnosticCategory: Equatable, Sendable {
    case regionRestriction
    case deviceRegistration
    case serviceAuthentication
    case upstream
}

struct PrimuseAIRelayDiagnostic: Equatable, Sendable {
    var category: PrimuseAIRelayDiagnosticCategory
    var code: String

    static func classify(_ error: Error) -> PrimuseAIRelayDiagnostic {
        let nsError = error as NSError
        if nsError.domain == DCError.errorDomain {
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "app_attest_\(nsError.code)"
            )
        }
        if let urlError = error as? URLError {
            let code: String
            switch urlError.code {
            case .timedOut:
                code = "network_timeout"
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                code = "network_unavailable"
            default:
                code = "network_error"
            }
            return PrimuseAIRelayDiagnostic(category: .upstream, code: code)
        }
        guard let relayError = error as? PrimuseAIRelayError else {
            return PrimuseAIRelayDiagnostic(category: .upstream, code: "unknown_error")
        }
        switch relayError {
        case .unsupportedDevice:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "unsupported_device"
            )
        case .credentialUnavailable:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "credential_unavailable"
            )
        case .credentialCorrupted:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "credential_corrupted"
            )
        case .credentialPersistenceFailed:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "credential_persistence_failed"
            )
        case .storeKitTransactionUnavailable:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "storekit_transaction_unavailable"
            )
        case .storeKitTransactionUnverified:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "storekit_transaction_unverified"
            )
        case .storeKitAuthenticationCancelled:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "storekit_authentication_cancelled"
            )
        case .invalidResponse:
            return PrimuseAIRelayDiagnostic(category: .upstream, code: "invalid_response")
        case .responseTooLarge:
            return PrimuseAIRelayDiagnostic(category: .upstream, code: "response_too_large")
        case .requestFailed(let statusCode, let code):
            let deviceRegistrationCodes: Set<String> = [
                "invalid_attestation",
                "invalid_app_attest_policy",
                "invalid_app_transaction",
                "storekit_enrollment_unavailable",
            ]
            let authenticationCodes: Set<String> = [
                "assertion_replayed",
                "expired_challenge",
                "feature_disabled",
                "feature_not_in_plan",
                "installation_blocked",
                "installation_mismatch",
                "installation_unavailable",
                "invalid_apple_app_id",
                "invalid_assertion",
                "invalid_challenge",
                "invalid_installation_token",
                "request_replayed",
            ]
            if deviceRegistrationCodes.contains(code) {
                return PrimuseAIRelayDiagnostic(category: .deviceRegistration, code: code)
            }
            if statusCode == 401 || statusCode == 403 || authenticationCodes.contains(code) {
                return PrimuseAIRelayDiagnostic(category: .serviceAuthentication, code: code)
            }
            return PrimuseAIRelayDiagnostic(category: .upstream, code: code)
        }
    }
}

struct PrimuseAIRelayCredential: Codable, Equatable, Sendable {
    var keyID: String
    var installationID: String?
    var accessToken: String? = nil
}

struct PrimuseStoreKitEnrollmentMaterial: Equatable, Sendable {
    var appTransactionJWS: String
    var deviceVerificationID: String
}

protocol PrimuseAppAttesting: Actor {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

actor SystemPrimuseAppAttestor: PrimuseAppAttesting {
    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

protocol PrimuseStoreKitEnrollmentProviding: Actor {
    var isSupported: Bool { get }
    func enrollmentMaterial(
        allowsRefresh: Bool
    ) async throws -> PrimuseStoreKitEnrollmentMaterial
}

actor SystemPrimuseStoreKitEnrollmentProvider: PrimuseStoreKitEnrollmentProviding {
    var isSupported: Bool { AppStore.deviceVerificationID != nil }

    func enrollmentMaterial(
        allowsRefresh: Bool
    ) async throws -> PrimuseStoreKitEnrollmentMaterial {
        guard let deviceVerificationID = AppStore.deviceVerificationID else {
            throw PrimuseAIRelayError.unsupportedDevice
        }

        do {
            let result = try await AppTransaction.shared
            if case .verified = result {
                return Self.material(
                    from: result,
                    deviceVerificationID: deviceVerificationID
                )
            }
            guard allowsRefresh else {
                throw PrimuseAIRelayError.storeKitTransactionUnverified
            }
        } catch {
            guard allowsRefresh else { throw Self.normalized(error) }
        }

        do {
            let result = try await AppTransaction.refresh()
            guard case .verified = result else {
                throw PrimuseAIRelayError.storeKitTransactionUnverified
            }
            return Self.material(
                from: result,
                deviceVerificationID: deviceVerificationID
            )
        } catch {
            throw Self.normalized(error)
        }
    }

    private static func material(
        from result: VerificationResult<AppTransaction>,
        deviceVerificationID: UUID
    ) -> PrimuseStoreKitEnrollmentMaterial {
        return PrimuseStoreKitEnrollmentMaterial(
            appTransactionJWS: result.jwsRepresentation,
            deviceVerificationID: deviceVerificationID.uuidString.lowercased()
        )
    }

    private static func normalized(_ error: Error) -> Error {
        if let relayError = error as? PrimuseAIRelayError {
            return relayError
        }
        if let urlError = error as? URLError {
            return urlError
        }
        guard let storeKitError = error as? StoreKitError else {
            return PrimuseAIRelayError.storeKitTransactionUnavailable
        }
        switch storeKitError {
        case .userCancelled:
            return PrimuseAIRelayError.storeKitAuthenticationCancelled
        case .networkError(let urlError):
            return urlError
        case .systemError(let underlyingError):
            return normalized(underlyingError)
        default:
            return PrimuseAIRelayError.storeKitTransactionUnavailable
        }
    }
}

protocol PrimuseAIRelayCredentialStoring: Actor {
    func load() throws -> PrimuseAIRelayCredential?
    func save(_ credential: PrimuseAIRelayCredential) throws
    func clear() throws
}

actor KeychainPrimuseAIRelayCredentialStore: PrimuseAIRelayCredentialStoring {
    private static let account = "primuse.ai.relay.installation.v1"

    func load() throws -> PrimuseAIRelayCredential? {
        switch KeychainService.localOnlyPasswordLookup(for: Self.account) {
        case .found(let value):
            guard let data = value.data(using: .utf8),
                  let credential = try? JSONDecoder().decode(
                    PrimuseAIRelayCredential.self,
                    from: data
                  ),
                  !credential.keyID.isEmpty else {
                throw PrimuseAIRelayError.credentialCorrupted
            }
            return credential
        case .notFound:
            return nil
        case .temporarilyUnavailable, .failed:
            throw PrimuseAIRelayError.credentialUnavailable
        }
    }

    func save(_ credential: PrimuseAIRelayCredential) throws {
        guard let data = try? JSONEncoder().encode(credential),
              let value = String(data: data, encoding: .utf8),
              KeychainService.setLocalOnlyPassword(value, for: Self.account) else {
            throw PrimuseAIRelayError.credentialPersistenceFailed
        }
    }

    func clear() throws {
        guard KeychainService.deletePassword(for: Self.account) else {
            throw PrimuseAIRelayError.credentialPersistenceFailed
        }
    }
}

actor PrimuseAIRelayClient {
    static let productionBaseURL = URL(string: "https://primuse.yzs.ai")!
    static let providerID = UUID(uuidString: "C8465401-5F73-4FC4-9A58-019220216BC9")!

    nonisolated static var isSupportedOnCurrentDevice: Bool {
        DCAppAttestService.shared.isSupported || AppStore.deviceVerificationID != nil
    }

    private static let appID = "primuse"
    private static let maximumResponseBytes = 1_048_576
    private static let requestIdleTimeout: TimeInterval = 60

    private let baseURL: URL
    private let session: URLSession
    private let attestor: any PrimuseAppAttesting
    private let storeKitEnrollmentProvider: any PrimuseStoreKitEnrollmentProviding
    private let credentialStore: any PrimuseAIRelayCredentialStoring
    private let transientRetryDelay: Duration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = PrimuseAIRelayClient.productionBaseURL,
        session: URLSession = PrimuseAIRelayClient.makeSession(),
        attestor: any PrimuseAppAttesting = SystemPrimuseAppAttestor(),
        storeKitEnrollmentProvider: any PrimuseStoreKitEnrollmentProviding = SystemPrimuseStoreKitEnrollmentProvider(),
        credentialStore: any PrimuseAIRelayCredentialStoring = KeychainPrimuseAIRelayCredentialStore(),
        transientRetryDelay: Duration = .seconds(1)
    ) {
        precondition(baseURL.scheme?.lowercased() == "https")
        self.baseURL = baseURL
        self.session = session
        self.attestor = attestor
        self.storeKitEnrollmentProvider = storeKitEnrollmentProvider
        self.credentialStore = credentialStore
        self.transientRetryDelay = transientRetryDelay
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func prepareInstallation() async throws -> String {
        let credential = try await ensureEnrollment(
            canReplaceInvalidKey: true,
            allowsStoreKitRefresh: false,
            prefersAppAttestUpgrade: false
        )
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return installationID
    }

    func testConnection() async throws -> PrimuseAIRelayAuthenticationMethod {
        let request = AISemanticSearchRequest(
            query: "quiet evening music",
            languageCode: "en",
            maximumExpansionTerms: 2
        )
        let _: SemanticSearchOutput = try await performFeature(
            path: "/v1/semantic-search",
            purpose: "semantic_search",
            input: SemanticSearchInput(
                query: request.query,
                languageCode: request.languageCode,
                maximumExpansionTerms: request.maximumExpansionTerms
            ),
            allowsStoreKitRefresh: true,
            prefersAppAttestUpgrade: true
        )
        guard let credential = try await credentialStore.load(),
              credential.installationID != nil else {
            throw PrimuseAIRelayError.credentialUnavailable
        }
        return credential.accessToken == nil ? .appAttest : .storeKitFallback
    }

    func interpretSearch(
        _ request: AISemanticSearchRequest
    ) async throws -> AISemanticSearchPlan {
        let output: SemanticSearchOutput = try await performFeature(
            path: "/v1/semantic-search",
            purpose: "semantic_search",
            input: SemanticSearchInput(
                query: request.query,
                languageCode: request.languageCode,
                maximumExpansionTerms: request.maximumExpansionTerms
            )
        )
        return AISemanticSearchPlan(
            expandedTerms: output.expansionTerms,
            themes: [],
            moods: []
        ).normalized(for: request)
    }

    func semanticSearchEvents(
        _ request: AISemanticSearchRequest
    ) -> AsyncThrowingStream<AISemanticSearchStreamEvent, Error> {
        featureEventStream(
            path: "/v1/semantic-search",
            purpose: "semantic_search",
            input: SemanticSearchInput(
                query: request.query,
                languageCode: request.languageCode,
                maximumExpansionTerms: request.maximumExpansionTerms
            ),
            output: SemanticSearchOutput.self,
            progress: SemanticSearchProgress.self,
            progressIdentity: { $0.term.lowercased() }
        ) { rawEvent in
            switch rawEvent {
            case .reset:
                return .reset
            case .progress(let progress):
                let normalized = AISemanticSearchPlan(
                    expandedTerms: [progress.term]
                ).normalized(for: request)
                guard let term = normalized.expandedTerms.first else { return nil }
                return .term(term)
            case .completed(let output):
                return .completed(AISemanticSearchPlan(
                    expandedTerms: output.expansionTerms
                ).normalized(for: request))
            }
        }
    }

    func recommendations(
        _ request: AIRecommendationRequest
    ) async throws -> AIRecommendationPlan {
        let output: RecommendationsOutput = try await performFeature(
            path: "/v1/recommendations",
            purpose: "recommendations",
            input: RecommendationsInput(request: request)
        )
        return AIRecommendationPlan(
            selections: output.items.map {
                AIRecommendationSelection(songID: $0.songID, reason: $0.reason)
            }
        ).normalized(for: request)
    }

    func recommendationEvents(
        _ request: AIRecommendationRequest
    ) -> AsyncThrowingStream<AIRecommendationStreamEvent, Error> {
        featureEventStream(
            path: "/v1/recommendations",
            purpose: "recommendations",
            input: RecommendationsInput(request: request),
            output: RecommendationsOutput.self,
            progress: RecommendationProgress.self,
            progressIdentity: { $0.item.songID }
        ) { rawEvent in
            switch rawEvent {
            case .reset:
                return .reset
            case .progress(let progress):
                guard request.candidates.contains(where: {
                    $0.songID == progress.item.songID
                }) else { return nil }
                let reason = progress.item.reason
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                guard !reason.isEmpty else { return nil }
                return .selection(AIRecommendationSelection(
                    songID: progress.item.songID,
                    reason: String(reason.prefix(120))
                ))
            case .completed(let output):
                return .completed(AIRecommendationPlan(
                    selections: output.items.map {
                        AIRecommendationSelection(songID: $0.songID, reason: $0.reason)
                    }
                ).normalized(for: request))
            }
        }
    }

    func translateLyrics(
        _ candidates: [LyricTranslationCandidate],
        targetLanguageCode: String
    ) async throws -> [String: String] {
        let limitedCandidates = Array(candidates.prefix(80))
        let candidateIDs = Set(limitedCandidates.map(\.id))
        guard candidateIDs.count == limitedCandidates.count else {
            throw PrimuseAIRelayError.invalidResponse
        }
        let output: LyricsTranslationOutput = try await performFeature(
            path: "/v1/lyrics/translate",
            purpose: "lyrics_translation",
            input: LyricsTranslationInput(
                targetLanguageCode: targetLanguageCode,
                lines: limitedCandidates.map {
                    LyricsLine(
                        id: $0.id,
                        text: String($0.text.prefix(800)),
                        sourceLanguageCode: $0.sourceLanguageCode
                    )
                }
            )
        )
        var translations: [String: String] = [:]
        for line in output.lines {
            guard candidateIDs.contains(line.id), translations[line.id] == nil else {
                throw PrimuseAIRelayError.invalidResponse
            }
            translations[line.id] = line.translatedText
        }
        guard translations.count == candidateIDs.count else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return translations
    }

    func lyricsTranslationEvents(
        _ candidates: [LyricTranslationCandidate],
        targetLanguageCode: String
    ) -> AsyncThrowingStream<AILyricsTranslationStreamEvent, Error> {
        let limitedCandidates = Array(candidates.prefix(80))
        let candidateIDs = Set(limitedCandidates.map(\.id))
        guard candidateIDs.count == limitedCandidates.count else {
            return AsyncThrowingStream { $0.finish(throwing: PrimuseAIRelayError.invalidResponse) }
        }
        return featureEventStream(
            path: "/v1/lyrics/translate",
            purpose: "lyrics_translation",
            input: LyricsTranslationInput(
                targetLanguageCode: targetLanguageCode,
                lines: limitedCandidates.map {
                    LyricsLine(
                        id: $0.id,
                        text: String($0.text.prefix(800)),
                        sourceLanguageCode: $0.sourceLanguageCode
                    )
                }
            ),
            output: LyricsTranslationOutput.self,
            progress: LyricsTranslationProgress.self,
            progressIdentity: { $0.line.id }
        ) { rawEvent in
            switch rawEvent {
            case .reset:
                return .reset
            case .progress(let progress):
                guard candidateIDs.contains(progress.line.id) else { return nil }
                return .translation(
                    id: progress.line.id,
                    text: progress.line.translatedText
                )
            case .completed(let output):
                var translations: [String: String] = [:]
                for line in output.lines where candidateIDs.contains(line.id) {
                    translations[line.id] = line.translatedText
                }
                guard translations.count == candidateIDs.count else { return nil }
                return .completed(translations)
            }
        }
    }

    nonisolated static func assertionClientDataHash(
        challenge: String,
        method: String,
        path: String,
        body: Data
    ) -> Data {
        let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedString()
        let clientData = [
            "primuse-ai/v1",
            challenge,
            method.uppercased(),
            path,
            bodyHash,
        ].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(clientData.utf8)))
    }

    private enum FeatureWireEvent<Progress: Sendable, Output: Sendable>: Sendable {
        case reset
        case progress(Progress)
        case completed(Output)
    }

    private func featureEventStream<
        Input: Encodable & Sendable,
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable,
        Event: Sendable
    >(
        path: String,
        purpose: String,
        input: Input,
        output: Output.Type,
        progress: Progress.Type,
        progressIdentity: @escaping @Sendable (Progress) -> String? = { _ in nil },
        transform: @escaping @Sendable (FeatureWireEvent<Progress, Output>) -> Event?
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let operation = Task {
                var hasEmittedProgress = false
                var emittedProgressIdentities = Set<String>()
                do {
                    try await self.performStreamingFeature(
                        path: path,
                        purpose: purpose,
                        input: input,
                        output: output,
                        progress: progress
                    ) { wireEvent in
                        switch wireEvent {
                        case .reset where hasEmittedProgress:
                            return
                        case .progress(let progress):
                            hasEmittedProgress = true
                            if let identity = progressIdentity(progress),
                               !emittedProgressIdentities.insert(identity).inserted {
                                return
                            }
                        case .reset, .completed:
                            break
                        }
                        if let event = transform(wireEvent) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in operation.cancel() }
        }
    }

    private func performStreamingFeature<
        Input: Encodable & Sendable,
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable
    >(
        path: String,
        purpose: String,
        input: Input,
        output: Output.Type,
        progress: Progress.Type,
        canRecoverLocalAppAttestCredential: Bool = true,
        canRecoverServerCredential: Bool = true,
        canRetryFreshProof: Bool = true,
        canRetryTransientFailure: Bool = true,
        emit: (FeatureWireEvent<Progress, Output>) -> Void
    ) async throws {
        do {
            let request = try await streamingFeatureRequest(
                path: path,
                purpose: purpose,
                input: input
            )
            try await consumeFeatureResponse(
                request: request,
                output: output,
                progress: progress,
                emit: emit
            )
        } catch {
            if canRecoverLocalAppAttestCredential,
               Self.isLocalAppAttestFailure(error) {
                try await credentialStore.clear()
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: false,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: canRetryFreshProof,
                    canRetryTransientFailure: canRetryTransientFailure,
                    emit: emit
                )
            }
            if canRecoverServerCredential,
               Self.shouldReplaceCredential(after: error) {
                try await credentialStore.clear()
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: false,
                    canRetryFreshProof: canRetryFreshProof,
                    canRetryTransientFailure: canRetryTransientFailure,
                    emit: emit
                )
            }
            if canRetryFreshProof,
               Self.shouldRetryWithFreshProof(after: error) {
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: false,
                    canRetryTransientFailure: canRetryTransientFailure,
                    emit: emit
                )
            }
            if canRetryTransientFailure,
               Self.shouldRetryTransientStream(after: error) {
                try await Task.sleep(for: transientRetryDelay)
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: canRetryFreshProof,
                    canRetryTransientFailure: false,
                    emit: emit
                )
            }
            throw error
        }
    }

    private func streamingFeatureRequest<Input: Encodable & Sendable>(
        path: String,
        purpose: String,
        input: Input
    ) async throws -> URLRequest {
        let body = try encoder.encode(input)
        let credential = try await ensureEnrollment(
            canReplaceInvalidKey: true,
            allowsStoreKitRefresh: false,
            prefersAppAttestUpgrade: false
        )
        var request = try makeRequest(path: path, body: body)
        if let accessToken = credential.accessToken, !accessToken.isEmpty {
            request.setValue(accessToken, forHTTPHeaderField: "X-Primuse-Installation-Token")
            request.setValue(
                UUID().uuidString.lowercased(),
                forHTTPHeaderField: "X-Primuse-Request-Nonce"
            )
        } else {
            let challenge = try await issueChallenge(purpose: purpose)
            let clientDataHash = Self.assertionClientDataHash(
                challenge: challenge,
                method: "POST",
                path: path,
                body: body
            )
            let assertionResult = try await assertion(
                credential: credential,
                clientDataHash: clientDataHash
            )
            request.setValue(challenge, forHTTPHeaderField: "X-Primuse-Challenge")
            request.setValue(
                assertionResult.1.base64URLEncodedString(),
                forHTTPHeaderField: "X-Primuse-Assertion"
            )
        }
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }
        request.setValue(Self.appID, forHTTPHeaderField: "X-Primuse-App-Id")
        request.setValue(installationID, forHTTPHeaderField: "X-Primuse-Installation-Id")
        request.setValue(
            "application/x-ndjson, application/json",
            forHTTPHeaderField: "Accept"
        )
        return request
    }

    private func consumeFeatureResponse<
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable
    >(
        request: URLRequest,
        output: Output.Type,
        progress: Progress.Type,
        emit: (FeatureWireEvent<Progress, Output>) -> Void
    ) async throws {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw PrimuseAIRelayError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(response.expectedContentLength > 0
            ? Int(response.expectedContentLength) : 8_192, Self.maximumResponseBytes))

        if !(200..<300).contains(response.statusCode) {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else {
                    throw PrimuseAIRelayError.responseTooLarge
                }
                data.append(byte)
            }
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw PrimuseAIRelayError.requestFailed(
                statusCode: response.statusCode,
                code: Self.safeDiagnosticCode(
                    envelope?.error.code,
                    statusCode: response.statusCode
                )
            )
        }

        let isNDJSON = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("application/x-ndjson") == true
        guard isNDJSON else {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else {
                    throw PrimuseAIRelayError.responseTooLarge
                }
                data.append(byte)
            }
            guard let envelope = try? decoder.decode(SuccessEnvelope<Output>.self, from: data) else {
                throw PrimuseAIRelayError.invalidResponse
            }
            emit(.completed(envelope.data))
            return
        }

        var line = Data()
        var didComplete = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumResponseBytes else {
                throw PrimuseAIRelayError.responseTooLarge
            }
            data.append(byte)
            if byte == 0x0A {
                if let event = try decodeFeatureStreamLine(
                    line,
                    output: output,
                    progress: progress
                ) {
                    if case .completed = event { didComplete = true }
                    emit(event)
                }
                line.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                line.append(byte)
            }
        }
        if !line.isEmpty,
           let event = try decodeFeatureStreamLine(line, output: output, progress: progress) {
            if case .completed = event { didComplete = true }
            emit(event)
        }
        guard didComplete else { throw PrimuseAIRelayError.invalidResponse }
    }

    private func decodeFeatureStreamLine<
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable
    >(
        _ line: Data,
        output: Output.Type,
        progress: Progress.Type
    ) throws -> FeatureWireEvent<Progress, Output>? {
        guard !line.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else {
            throw PrimuseAIRelayError.invalidResponse
        }
        switch type {
        case "started":
            return nil
        case "reset":
            return .reset
        case "progress":
            guard let value = object["data"],
                  JSONSerialization.isValidJSONObject(value),
                  let decoded = try? decoder.decode(
                    progress,
                    from: JSONSerialization.data(withJSONObject: value)
                  ) else { throw PrimuseAIRelayError.invalidResponse }
            return .progress(decoded)
        case "complete":
            guard let value = object["data"],
                  JSONSerialization.isValidJSONObject(value),
                  let decoded = try? decoder.decode(
                    output,
                    from: JSONSerialization.data(withJSONObject: value)
                  ) else { throw PrimuseAIRelayError.invalidResponse }
            return .completed(decoded)
        case "error":
            let error = object["error"] as? [String: Any]
            throw PrimuseAIRelayError.requestFailed(
                statusCode: 502,
                code: Self.safeDiagnosticCode(error?["code"] as? String, statusCode: 502)
            )
        default:
            throw PrimuseAIRelayError.invalidResponse
        }
    }

    private func performFeature<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        path: String,
        purpose: String,
        input: Input,
        allowsStoreKitRefresh: Bool = false,
        prefersAppAttestUpgrade: Bool = false,
        canRecoverLocalAppAttestCredential: Bool = true,
        canRecoverServerCredential: Bool = true,
        canRetryFreshProof: Bool = true
    ) async throws -> Output {
        let body = try encoder.encode(input)
        let initialCredential = try await ensureEnrollment(
            canReplaceInvalidKey: true,
            allowsStoreKitRefresh: allowsStoreKitRefresh,
            prefersAppAttestUpgrade: prefersAppAttestUpgrade
        )
        let credential: PrimuseAIRelayCredential
        var request = try makeRequest(path: path, body: body)
        if let accessToken = initialCredential.accessToken, !accessToken.isEmpty {
            credential = initialCredential
            request.setValue(
                accessToken,
                forHTTPHeaderField: "X-Primuse-Installation-Token"
            )
            request.setValue(
                UUID().uuidString.lowercased(),
                forHTTPHeaderField: "X-Primuse-Request-Nonce"
            )
        } else {
            let challenge = try await issueChallenge(purpose: purpose)
            let clientDataHash = Self.assertionClientDataHash(
                challenge: challenge,
                method: "POST",
                path: path,
                body: body
            )
            let assertionResult: (PrimuseAIRelayCredential, Data)
            do {
                assertionResult = try await assertion(
                    credential: initialCredential,
                    clientDataHash: clientDataHash
                )
            } catch {
                guard canRecoverLocalAppAttestCredential,
                      Self.isLocalAppAttestFailure(error) else { throw error }
                try await credentialStore.clear()
                return try await performFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    allowsStoreKitRefresh: allowsStoreKitRefresh,
                    prefersAppAttestUpgrade: prefersAppAttestUpgrade,
                    canRecoverLocalAppAttestCredential: false,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: canRetryFreshProof
                )
            }
            credential = assertionResult.0
            request.setValue(challenge, forHTTPHeaderField: "X-Primuse-Challenge")
            request.setValue(
                assertionResult.1.base64URLEncodedString(),
                forHTTPHeaderField: "X-Primuse-Assertion"
            )
        }
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }

        request.setValue(Self.appID, forHTTPHeaderField: "X-Primuse-App-Id")
        request.setValue(installationID, forHTTPHeaderField: "X-Primuse-Installation-Id")
        do {
            let envelope = try await send(SuccessEnvelope<Output>.self, request: request)
            return envelope.data
        } catch {
            if canRecoverServerCredential,
               Self.shouldReplaceCredential(after: error) {
                try await credentialStore.clear()
                return try await performFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    allowsStoreKitRefresh: allowsStoreKitRefresh,
                    prefersAppAttestUpgrade: prefersAppAttestUpgrade,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: false,
                    canRetryFreshProof: canRetryFreshProof
                )
            }
            if canRetryFreshProof,
               Self.shouldRetryWithFreshProof(after: error) {
                return try await performFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    allowsStoreKitRefresh: allowsStoreKitRefresh,
                    prefersAppAttestUpgrade: prefersAppAttestUpgrade,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: false
                )
            }
            throw error
        }
    }

    private func ensureEnrollment(
        canReplaceInvalidKey: Bool,
        allowsStoreKitRefresh: Bool,
        prefersAppAttestUpgrade: Bool
    ) async throws -> PrimuseAIRelayCredential {
        let supportsAppAttest = await attestor.isSupported
        do {
            if let credential = try await credentialStore.load(),
               let installationID = credential.installationID,
               !installationID.isEmpty {
                let hasStoreKitToken = credential.accessToken?.isEmpty == false
                if credential.accessToken != nil, !hasStoreKitToken {
                    try await credentialStore.clear()
                } else if hasStoreKitToken {
                    if !prefersAppAttestUpgrade || !supportsAppAttest {
                        return credential
                    }
                    try await credentialStore.clear()
                } else if supportsAppAttest {
                    return credential
                } else {
                    try await credentialStore.clear()
                }
            }
        } catch PrimuseAIRelayError.credentialCorrupted {
            try await credentialStore.clear()
        }

        var appAttestFailure: Error?
        if supportsAppAttest {
            do {
                return try await ensureAppAttestEnrollment(
                    canReplaceInvalidKey: canReplaceInvalidKey
                )
            } catch {
                guard Self.isRecoverableAppAttestEnrollmentFailure(error) else {
                    throw error
                }
                try await credentialStore.clear()
                appAttestFailure = error
            }
        }
        do {
            return try await ensureStoreKitEnrollment(allowsRefresh: allowsStoreKitRefresh)
        } catch {
            if let appAttestFailure {
                throw appAttestFailure
            }
            throw error
        }
    }

    private func ensureAppAttestEnrollment(
        canReplaceInvalidKey: Bool
    ) async throws -> PrimuseAIRelayCredential {
        let existing = try await credentialStore.load()
        let keyID: String
        if let existing, existing.accessToken == nil {
            keyID = existing.keyID
        } else {
            keyID = try await attestor.generateKey()
            try await credentialStore.save(PrimuseAIRelayCredential(
                keyID: keyID,
                installationID: nil
            ))
        }

        let challenge = try await issueChallenge(purpose: "enroll")
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestationObject: Data
        do {
            attestationObject = try await attestor.attestKey(
                keyID,
                clientDataHash: clientDataHash
            )
        } catch {
            guard canReplaceInvalidKey, Self.isInvalidAppAttestKey(error) else { throw error }
            try await credentialStore.clear()
            return try await ensureAppAttestEnrollment(canReplaceInvalidKey: false)
        }

        let body = try encoder.encode(EnrollmentInput(
            appID: Self.appID,
            keyID: keyID,
            challenge: challenge,
            attestationObject: attestationObject.base64URLEncodedString()
        ))
        let response = try await send(
            EnrollmentOutput.self,
            request: try makeRequest(path: "/v1/auth/installations", body: body)
        )
        let credential = PrimuseAIRelayCredential(
            keyID: keyID,
            installationID: response.installationID
        )
        try await credentialStore.save(credential)
        return credential
    }

    private func ensureStoreKitEnrollment(
        allowsRefresh: Bool
    ) async throws -> PrimuseAIRelayCredential {
        guard await storeKitEnrollmentProvider.isSupported else {
            throw PrimuseAIRelayError.unsupportedDevice
        }
        let material = try await storeKitEnrollmentProvider.enrollmentMaterial(
            allowsRefresh: allowsRefresh
        )
        let challenge = try await issueChallenge(purpose: "enroll")
        let body = try encoder.encode(StoreKitEnrollmentInput(
            appID: Self.appID,
            challenge: challenge,
            appTransactionJWS: material.appTransactionJWS,
            deviceVerificationID: material.deviceVerificationID
        ))
        let response = try await send(
            EnrollmentOutput.self,
            request: try makeRequest(path: "/v1/auth/installations", body: body)
        )
        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw PrimuseAIRelayError.invalidResponse
        }
        let credential = PrimuseAIRelayCredential(
            keyID: "storekit",
            installationID: response.installationID,
            accessToken: accessToken
        )
        try await credentialStore.save(credential)
        return credential
    }

    private func assertion(
        credential: PrimuseAIRelayCredential,
        clientDataHash: Data
    ) async throws -> (PrimuseAIRelayCredential, Data) {
        return (
            credential,
            try await attestor.generateAssertion(
                credential.keyID,
                clientDataHash: clientDataHash
            )
        )
    }

    private func issueChallenge(purpose: String) async throws -> String {
        let body = try encoder.encode(ChallengeInput(appID: Self.appID, purpose: purpose))
        let response = try await send(
            ChallengeOutput.self,
            request: try makeRequest(path: "/v1/auth/challenge", body: body)
        )
        guard !response.challenge.isEmpty else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return response.challenge
    }

    private func makeRequest(path: String, body: Data) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == baseURL.host?.lowercased() else {
            throw PrimuseAIRelayError.invalidResponse
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestIdleTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let preferredLanguages = Locale.preferredLanguages.prefix(10).joined(separator: ", ")
        if !preferredLanguages.isEmpty {
            request.setValue(preferredLanguages, forHTTPHeaderField: "Accept-Language")
        }
        return request
    }

    private func send<Response: Decodable & Sendable>(
        _ type: Response.Type,
        request: URLRequest
    ) async throws -> Response {
        let (data, rawResponse) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseBytes else {
            throw PrimuseAIRelayError.responseTooLarge
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw PrimuseAIRelayError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw PrimuseAIRelayError.requestFailed(
                statusCode: response.statusCode,
                code: Self.safeDiagnosticCode(
                    envelope?.error.code,
                    statusCode: response.statusCode
                )
            )
        }
        guard let decoded = try? decoder.decode(type, from: data) else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return decoded
    }

    private nonisolated static func isInvalidAppAttestKey(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == DCError.errorDomain
            && value.code == DCError.invalidKey.rawValue
    }

    private nonisolated static func isLocalAppAttestFailure(_ error: Error) -> Bool {
        (error as NSError).domain == DCError.errorDomain
    }

    private nonisolated static func isRecoverableAppAttestEnrollmentFailure(
        _ error: Error
    ) -> Bool {
        if isLocalAppAttestFailure(error) { return true }
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code) = relayError else {
            return false
        }
        return code == "invalid_attestation" || code == "invalid_app_attest_policy"
    }

    private nonisolated static func shouldReplaceCredential(after error: Error) -> Bool {
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code) = relayError else {
            return false
        }
        return [
            "installation_mismatch",
            "installation_unavailable",
            "invalid_assertion",
            "invalid_installation_token",
        ].contains(code)
    }

    private nonisolated static func shouldRetryWithFreshProof(after error: Error) -> Bool {
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code) = relayError else {
            return false
        }
        return [
            "assertion_replayed",
            "expired_challenge",
            "invalid_challenge",
            "request_replayed",
        ].contains(code)
    }

    private nonisolated static func shouldRetryTransientStream(after error: Error) -> Bool {
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code) = relayError else {
            return false
        }
        return code == "concurrency_limited" || code == "upstreams_busy"
    }

    private nonisolated static func safeDiagnosticCode(
        _ rawCode: String?,
        statusCode: Int
    ) -> String {
        let fallback = "http_\(statusCode)"
        guard let rawCode else { return fallback }
        let normalized = rawCode.lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 64,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 97 && scalar.value <= 122)
                      || (scalar.value >= 48 && scalar.value <= 57)
                      || scalar.value == 95
                      || scalar.value == 45
              }) else {
            return fallback
        }
        return normalized
    }

    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestIdleTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private struct ChallengeInput: Encodable, Sendable {
        var appID: String
        var purpose: String

        private enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case purpose
        }
    }

    private struct ChallengeOutput: Decodable, Sendable {
        var challenge: String
    }

    private struct EnrollmentInput: Encodable, Sendable {
        var appID: String
        var keyID: String
        var challenge: String
        var attestationObject: String

        private enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case keyID = "key_id"
            case challenge
            case attestationObject = "attestation_object"
        }
    }

    private struct EnrollmentOutput: Decodable, Sendable {
        var installationID: String
        var accessToken: String?

        private enum CodingKeys: String, CodingKey {
            case installationID = "installation_id"
            case accessToken = "access_token"
        }
    }

    private struct StoreKitEnrollmentInput: Encodable, Sendable {
        var appID: String
        var challenge: String
        var appTransactionJWS: String
        var deviceVerificationID: String

        private enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case challenge
            case appTransactionJWS = "app_transaction_jws"
            case deviceVerificationID = "device_verification_id"
        }
    }

    private struct SuccessEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
        var data: Value
    }

    private struct ErrorEnvelope: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            var code: String
        }

        var error: Payload
    }

    private struct SemanticSearchInput: Encodable, Sendable {
        var query: String
        var languageCode: String?
        var maximumExpansionTerms: Int

        private enum CodingKeys: String, CodingKey {
            case query
            case languageCode = "language_code"
            case maximumExpansionTerms = "maximum_expansion_terms"
        }
    }

    private struct SemanticSearchOutput: Decodable, Sendable {
        var expansionTerms: [String]

        private enum CodingKeys: String, CodingKey {
            case expansionTerms = "expansion_terms"
        }
    }

    private struct SemanticSearchProgress: Decodable, Sendable {
        var term: String
    }

    private struct RecommendationsInput: Encodable, Sendable {
        var scene: String
        var intent: String?
        var languageCode: String?
        var preferences: [RecommendationPreference]
        var candidates: [RecommendationCandidate]
        var maximumResults: Int
        var minimumResults: Int

        private enum CodingKeys: String, CodingKey {
            case scene
            case intent
            case languageCode = "language_code"
            case preferences
            case candidates
            case maximumResults = "maximum_results"
            case minimumResults = "minimum_results"
        }

        init(request: AIRecommendationRequest) {
            scene = request.scene.rawValue
            intent = request.intent
            languageCode = request.languageCode
            preferences = request.preferences.map {
                RecommendationPreference(
                    title: $0.title,
                    artist: $0.artist,
                    genre: $0.genre,
                    playCount: $0.playCount
                )
            }
            candidates = request.candidates.map {
                RecommendationCandidate(
                    songID: $0.songID,
                    title: $0.title,
                    artist: $0.artist,
                    genre: $0.genre,
                    year: $0.year,
                    durationSeconds: $0.durationSeconds
                )
            }
            maximumResults = request.maximumResults
            minimumResults = request.minimumResults
        }
    }

    private struct RecommendationPreference: Encodable, Sendable {
        var title: String
        var artist: String
        var genre: String?
        var playCount: Int

        private enum CodingKeys: String, CodingKey {
            case title
            case artist
            case genre
            case playCount = "play_count"
        }
    }

    private struct RecommendationCandidate: Encodable, Sendable {
        var songID: String
        var title: String
        var artist: String
        var genre: String?
        var year: Int?
        var durationSeconds: Int

        private enum CodingKeys: String, CodingKey {
            case songID = "song_id"
            case title
            case artist
            case genre
            case year
            case durationSeconds = "duration_seconds"
        }
    }

    private struct RecommendationsOutput: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            var songID: String
            var reason: String

            private enum CodingKeys: String, CodingKey {
                case songID = "song_id"
                case reason
            }
        }

        var items: [Item]
    }

    private struct RecommendationProgress: Decodable, Sendable {
        var item: RecommendationsOutput.Item
    }

    private struct LyricsTranslationInput: Encodable, Sendable {
        var targetLanguageCode: String
        var lines: [LyricsLine]

        private enum CodingKeys: String, CodingKey {
            case targetLanguageCode = "target_language_code"
            case lines
        }
    }

    private struct LyricsLine: Encodable, Sendable {
        var id: String
        var text: String
        var sourceLanguageCode: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case text
            case sourceLanguageCode = "source_language_code"
        }
    }

    private struct LyricsTranslationOutput: Decodable, Sendable {
        struct Line: Decodable, Sendable {
            var id: String
            var translatedText: String

            private enum CodingKeys: String, CodingKey {
                case id
                case translatedText = "translated_text"
            }
        }

        var lines: [Line]
    }

    private struct LyricsTranslationProgress: Decodable, Sendable {
        var line: LyricsTranslationOutput.Line
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
