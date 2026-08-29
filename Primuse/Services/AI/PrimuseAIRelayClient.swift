#if os(iOS)
import CryptoKit
import DeviceCheck
import Foundation
import PrimuseKit

enum PrimuseAIRelayError: Error, Equatable, Sendable {
    case unsupportedDevice
    case credentialUnavailable
    case credentialPersistenceFailed
    case invalidResponse
    case responseTooLarge
    case requestFailed(statusCode: Int, code: String)
}

struct PrimuseAIRelayCredential: Codable, Equatable, Sendable {
    var keyID: String
    var installationID: String?
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
                throw PrimuseAIRelayError.credentialUnavailable
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
        DCAppAttestService.shared.isSupported
    }

    private static let appID = "primuse"
    private static let maximumResponseBytes = 1_048_576

    private let baseURL: URL
    private let session: URLSession
    private let attestor: any PrimuseAppAttesting
    private let credentialStore: any PrimuseAIRelayCredentialStoring
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = PrimuseAIRelayClient.productionBaseURL,
        session: URLSession = PrimuseAIRelayClient.makeSession(),
        attestor: any PrimuseAppAttesting = SystemPrimuseAppAttestor(),
        credentialStore: any PrimuseAIRelayCredentialStoring = KeychainPrimuseAIRelayCredentialStore()
    ) {
        precondition(baseURL.scheme?.lowercased() == "https")
        self.baseURL = baseURL
        self.session = session
        self.attestor = attestor
        self.credentialStore = credentialStore
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func prepareInstallation() async throws -> String {
        let credential = try await ensureEnrollment(canReplaceInvalidKey: true)
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return installationID
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

    func recommendations(
        _ request: AIRecommendationRequest
    ) async throws -> AIRecommendationPlan {
        let output: RecommendationsOutput = try await performFeature(
            path: "/v1/recommendations",
            purpose: "recommendations",
            input: RecommendationsInput(
                scene: request.scene.rawValue,
                intent: request.intent,
                languageCode: request.languageCode,
                preferences: request.preferences.map {
                    RecommendationPreference(
                        title: $0.title,
                        artist: $0.artist,
                        genre: $0.genre,
                        playCount: $0.playCount
                    )
                },
                candidates: request.candidates.map {
                    RecommendationCandidate(
                        songID: $0.songID,
                        title: $0.title,
                        artist: $0.artist,
                        genre: $0.genre,
                        year: $0.year,
                        durationSeconds: $0.durationSeconds
                    )
                },
                maximumResults: request.maximumResults,
                minimumResults: request.minimumResults
            )
        )
        return AIRecommendationPlan(
            selections: output.items.map {
                AIRecommendationSelection(songID: $0.songID, reason: $0.reason)
            }
        ).normalized(for: request)
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

    private func performFeature<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        path: String,
        purpose: String,
        input: Input
    ) async throws -> Output {
        let body = try encoder.encode(input)
        let initialCredential = try await ensureEnrollment(canReplaceInvalidKey: true)
        let challenge = try await issueChallenge(purpose: purpose)
        let clientDataHash = Self.assertionClientDataHash(
            challenge: challenge,
            method: "POST",
            path: path,
            body: body
        )
        let (credential, assertion) = try await assertion(
            credential: initialCredential,
            clientDataHash: clientDataHash,
            canReplaceInvalidKey: true
        )
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }

        var request = try makeRequest(path: path, body: body)
        request.setValue(Self.appID, forHTTPHeaderField: "X-Primuse-App-Id")
        request.setValue(installationID, forHTTPHeaderField: "X-Primuse-Installation-Id")
        request.setValue(challenge, forHTTPHeaderField: "X-Primuse-Challenge")
        request.setValue(
            assertion.base64URLEncodedString(),
            forHTTPHeaderField: "X-Primuse-Assertion"
        )
        let envelope = try await send(SuccessEnvelope<Output>.self, request: request)
        return envelope.data
    }

    private func ensureEnrollment(
        canReplaceInvalidKey: Bool
    ) async throws -> PrimuseAIRelayCredential {
        if let credential = try await credentialStore.load(),
           credential.installationID != nil {
            return credential
        }
        guard await attestor.isSupported else {
            throw PrimuseAIRelayError.unsupportedDevice
        }

        let existing = try await credentialStore.load()
        let keyID: String
        if let existing {
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
            return try await ensureEnrollment(canReplaceInvalidKey: false)
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

    private func assertion(
        credential: PrimuseAIRelayCredential,
        clientDataHash: Data,
        canReplaceInvalidKey: Bool
    ) async throws -> (PrimuseAIRelayCredential, Data) {
        do {
            return (
                credential,
                try await attestor.generateAssertion(
                    credential.keyID,
                    clientDataHash: clientDataHash
                )
            )
        } catch {
            guard canReplaceInvalidKey, Self.isInvalidAppAttestKey(error) else { throw error }
            try await credentialStore.clear()
            let replacement = try await ensureEnrollment(canReplaceInvalidKey: false)
            return try await assertion(
                credential: replacement,
                clientDataHash: clientDataHash,
                canReplaceInvalidKey: false
            )
        }
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
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
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
                code: envelope?.error.code ?? "http_\(response.statusCode)"
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

    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
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

        private enum CodingKeys: String, CodingKey {
            case installationID = "installation_id"
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
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
