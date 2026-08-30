#if os(iOS)
import CryptoKit
import DeviceCheck
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class PrimuseAIRelayClientTests: XCTestCase {
    func testAssertionClientDataHashMatchesRelayContract() {
        let body = Data(#"{"query":"night rain"}"#.utf8)
        let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedForRelayTests()
        let clientData = [
            "primuse-ai/v1",
            "challenge-value",
            "POST",
            "/v1/semantic-search",
            bodyHash,
        ].joined(separator: "\n")
        let expected = Data(SHA256.hash(data: Data(clientData.utf8)))

        XCTAssertEqual(
            PrimuseAIRelayClient.assertionClientDataHash(
                challenge: "challenge-value",
                method: "post",
                path: "/v1/semantic-search",
                body: body
            ),
            expected
        )
    }

    func testEnrollmentAndSemanticSearchUseBoundAppAttestCredentials() async throws {
        let host = "primuse-relay-enrollment.invalid"
        PrimuseRelayURLProtocol.configure(host: host)
        let (client, session, attestor, credentials) = makeClient(host: host)
        defer { session.invalidateAndCancel() }

        let plan = try await client.interpretSearch(
            AISemanticSearchRequest(query: "night rain", languageCode: "en")
        )

        XCTAssertEqual(plan.expandedTerms, ["rainy night"])
        let requests = PrimuseRelayURLProtocol.requests(host: host)
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/v1/auth/challenge",
            "/v1/auth/installations",
            "/v1/auth/challenge",
            "/v1/semantic-search",
        ])

        let enrollment = try XCTUnwrap(requests.first {
            $0.url?.path == "/v1/auth/installations"
        })
        let enrollmentBody = try jsonObject(enrollment)
        XCTAssertEqual(enrollmentBody["app_id"] as? String, "primuse")
        XCTAssertEqual(enrollmentBody["key_id"] as? String, "test-app-attest-key")
        XCTAssertEqual(enrollmentBody["challenge"] as? String, "enroll-challenge")
        XCTAssertEqual(enrollmentBody["attestation_object"] as? String, "AQI")

        let feature = try XCTUnwrap(requests.last)
        XCTAssertEqual(feature.value(forHTTPHeaderField: "X-Primuse-App-Id"), "primuse")
        XCTAssertEqual(
            feature.value(forHTTPHeaderField: "X-Primuse-Installation-Id"),
            "test-installation"
        )
        XCTAssertEqual(
            feature.value(forHTTPHeaderField: "X-Primuse-Challenge"),
            "semantic_search-challenge"
        )
        XCTAssertEqual(feature.value(forHTTPHeaderField: "X-Primuse-Assertion"), "AwQ")
        XCTAssertEqual(feature.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let attestorSnapshot = await attestor.snapshot()
        XCTAssertEqual(attestorSnapshot.generateKeyCount, 1)
        XCTAssertEqual(
            attestorSnapshot.attestationHashes,
            [Data(SHA256.hash(data: Data("enroll-challenge".utf8)))]
        )
        let featureBody = try XCTUnwrap(feature.httpBody)
        XCTAssertEqual(attestorSnapshot.assertionHashes, [
            PrimuseAIRelayClient.assertionClientDataHash(
                challenge: "semantic_search-challenge",
                method: "POST",
                path: "/v1/semantic-search",
                body: featureBody
            ),
        ])
        let savedCredential = await credentials.current()
        XCTAssertEqual(
            savedCredential,
            PrimuseAIRelayCredential(
                keyID: "test-app-attest-key",
                installationID: "test-installation"
            )
        )
    }

    func testInvalidAssertionKeyReenrollsOnceAndRetriesWithTheSameFeatureBinding() async throws {
        let host = "primuse-relay-key-recovery.invalid"
        PrimuseRelayURLProtocol.configure(host: host)
        let attestor = TestPrimuseAppAttestor(assertionFailuresRemaining: 1)
        let credentials = TestPrimuseRelayCredentialStore(
            credential: PrimuseAIRelayCredential(
                keyID: "stale-app-attest-key",
                installationID: "stale-installation"
            )
        )
        let (client, session, _, _) = makeClient(
            host: host,
            attestor: attestor,
            credentials: credentials
        )
        defer { session.invalidateAndCancel() }

        _ = try await client.interpretSearch(
            AISemanticSearchRequest(query: "quiet night", languageCode: "en")
        )

        let snapshot = await attestor.snapshot()
        XCTAssertEqual(snapshot.generateKeyCount, 1)
        XCTAssertEqual(snapshot.attestationHashes.count, 1)
        XCTAssertEqual(snapshot.assertionHashes.count, 2)
        XCTAssertEqual(snapshot.assertionHashes.first, snapshot.assertionHashes.last)
        let clearCount = await credentials.clearCount()
        let recoveredCredential = await credentials.current()
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(
            recoveredCredential,
            PrimuseAIRelayCredential(
                keyID: "test-app-attest-key",
                installationID: "test-installation"
            )
        )
        XCTAssertEqual(
            PrimuseRelayURLProtocol.requests(host: host).compactMap(\.url?.path),
            [
                "/v1/auth/challenge",
                "/v1/auth/challenge",
                "/v1/auth/installations",
                "/v1/semantic-search",
            ]
        )
    }

    func testRelayPreservesServerErrorCodeWithoutReturningServerMessage() async throws {
        let host = "primuse-relay-quota.invalid"
        PrimuseRelayURLProtocol.configure(
            host: host,
            featureStatusCode: 429,
            featureBody: #"{"error":{"code":"daily_quota_exhausted","message":"private upstream detail"}}"#
        )
        let credentials = TestPrimuseRelayCredentialStore(
            credential: PrimuseAIRelayCredential(
                keyID: "test-app-attest-key",
                installationID: "test-installation"
            )
        )
        let (client, session, _, _) = makeClient(host: host, credentials: credentials)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await client.interpretSearch(
                AISemanticSearchRequest(query: "quiet night")
            )
            XCTFail("Expected the relay quota error")
        } catch {
            XCTAssertEqual(
                error as? PrimuseAIRelayError,
                .requestFailed(statusCode: 429, code: "daily_quota_exhausted")
            )
            XCTAssertFalse(String(describing: error).contains("private upstream detail"))
        }
    }

    func testRelayReplacesUnsafeServerErrorCodeWithHTTPStatus() async throws {
        let host = "primuse-relay-unsafe-code.invalid"
        PrimuseRelayURLProtocol.configure(
            host: host,
            featureStatusCode: 502,
            featureBody: #"{"error":{"code":"private detail","message":"internal"}}"#
        )
        let credentials = TestPrimuseRelayCredentialStore(
            credential: PrimuseAIRelayCredential(
                keyID: "test-app-attest-key",
                installationID: "test-installation"
            )
        )
        let (client, session, _, _) = makeClient(host: host, credentials: credentials)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await client.testConnection()
            XCTFail("Expected an upstream failure")
        } catch {
            XCTAssertEqual(
                error as? PrimuseAIRelayError,
                .requestFailed(statusCode: 502, code: "http_502")
            )
            XCTAssertFalse(String(describing: error).contains("private"))
        }
    }

    func testRelayDiagnosticClassificationSeparatesFailureBoundaries() {
        XCTAssertEqual(
            PrimuseAIRelayDiagnostic.classify(
                PrimuseAIRelayError.requestFailed(
                    statusCode: 400,
                    code: "invalid_attestation"
                )
            ),
            PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "invalid_attestation"
            )
        )
        XCTAssertEqual(
            PrimuseAIRelayDiagnostic.classify(
                PrimuseAIRelayError.requestFailed(
                    statusCode: 401,
                    code: "invalid_assertion"
                )
            ),
            PrimuseAIRelayDiagnostic(
                category: .serviceAuthentication,
                code: "invalid_assertion"
            )
        )
        XCTAssertEqual(
            PrimuseAIRelayDiagnostic.classify(
                PrimuseAIRelayError.requestFailed(
                    statusCode: 502,
                    code: "upstreams_failed"
                )
            ),
            PrimuseAIRelayDiagnostic(category: .upstream, code: "upstreams_failed")
        )
        XCTAssertEqual(
            PrimuseAIRelayDiagnostic.classify(NSError(
                domain: DCError.errorDomain,
                code: DCError.invalidKey.rawValue
            )).category,
            .deviceRegistration
        )
    }

    func testConnectionReportsAppAttestAuthentication() async throws {
        let host = "primuse-relay-test-app-attest.invalid"
        PrimuseRelayURLProtocol.configure(host: host)
        let credentials = TestPrimuseRelayCredentialStore(
            credential: PrimuseAIRelayCredential(
                keyID: "test-app-attest-key",
                installationID: "test-installation"
            )
        )
        let (client, session, _, _) = makeClient(host: host, credentials: credentials)
        defer { session.invalidateAndCancel() }

        let authenticationMethod = try await client.testConnection()

        XCTAssertEqual(authenticationMethod, .appAttest)
    }

    func testStoredInstallationSkipsKeyGenerationAndEnrollment() async throws {
        let host = "primuse-relay-existing-installation.invalid"
        PrimuseRelayURLProtocol.configure(host: host)
        let credentials = TestPrimuseRelayCredentialStore(
            credential: PrimuseAIRelayCredential(
                keyID: "test-app-attest-key",
                installationID: "test-installation"
            )
        )
        let (client, session, attestor, _) = makeClient(host: host, credentials: credentials)
        defer { session.invalidateAndCancel() }

        _ = try await client.interpretSearch(AISemanticSearchRequest(query: "night rain"))

        let snapshot = await attestor.snapshot()
        XCTAssertEqual(snapshot.generateKeyCount, 0)
        XCTAssertTrue(snapshot.attestationHashes.isEmpty)
        XCTAssertEqual(snapshot.assertionHashes.count, 1)
        XCTAssertEqual(
            PrimuseRelayURLProtocol.requests(host: host).compactMap(\.url?.path),
            ["/v1/auth/challenge", "/v1/semantic-search"]
        )
    }

    func testUnsupportedDeviceFailsClosedBeforeEnrollmentRequest() async throws {
        let host = "primuse-relay-unsupported.invalid"
        PrimuseRelayURLProtocol.configure(host: host)
        let attestor = TestPrimuseAppAttestor(isSupported: false)
        let (client, session, _, _) = makeClient(host: host, attestor: attestor)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await client.prepareInstallation()
            XCTFail("Expected App Attest to be unavailable")
        } catch {
            XCTAssertEqual(error as? PrimuseAIRelayError, .unsupportedDevice)
        }
        XCTAssertTrue(PrimuseRelayURLProtocol.requests(host: host).isEmpty)
    }

    func testStoreKitFallbackEnrollsAndUsesPerInstallationToken() async throws {
        let host = "primuse-relay-storekit.invalid"
        PrimuseRelayURLProtocol.configure(host: host)
        let attestor = TestPrimuseAppAttestor(isSupported: false)
        let storeKitProvider = TestPrimuseStoreKitEnrollmentProvider(
            material: PrimuseStoreKitEnrollmentMaterial(
                appTransactionJWS: "signed-app-transaction",
                deviceVerificationID: "7f1043e4-79dc-4d73-a5b9-08ae0dc04c7f"
            )
        )
        let credentials = TestPrimuseRelayCredentialStore()
        let (client, session, _, _) = makeClient(
            host: host,
            attestor: attestor,
            storeKitProvider: storeKitProvider,
            credentials: credentials
        )
        defer { session.invalidateAndCancel() }

        let authenticationMethod = try await client.testConnection()

        XCTAssertEqual(authenticationMethod, .storeKitFallback)

        let requests = PrimuseRelayURLProtocol.requests(host: host)
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/v1/auth/challenge",
            "/v1/auth/installations",
            "/v1/semantic-search",
        ])
        let enrollment = try XCTUnwrap(requests.first {
            $0.url?.path == "/v1/auth/installations"
        })
        let enrollmentBody = try jsonObject(enrollment)
        XCTAssertEqual(enrollmentBody["app_transaction_jws"] as? String, "signed-app-transaction")
        XCTAssertEqual(
            enrollmentBody["device_verification_id"] as? String,
            "7f1043e4-79dc-4d73-a5b9-08ae0dc04c7f"
        )
        XCTAssertNil(enrollmentBody["key_id"])
        XCTAssertNil(enrollmentBody["attestation_object"])

        let feature = try XCTUnwrap(requests.last)
        XCTAssertEqual(
            feature.value(forHTTPHeaderField: "X-Primuse-Installation-Token"),
            "test-installation-token"
        )
        XCTAssertNotNil(feature.value(forHTTPHeaderField: "X-Primuse-Request-Nonce"))
        XCTAssertNil(feature.value(forHTTPHeaderField: "X-Primuse-Challenge"))
        XCTAssertNil(feature.value(forHTTPHeaderField: "X-Primuse-Assertion"))
        let storedCredential = await credentials.current()
        XCTAssertEqual(
            storedCredential,
            PrimuseAIRelayCredential(
                keyID: "storekit",
                installationID: "test-installation",
                accessToken: "test-installation-token"
            )
        )
    }

    func testDuplicateLyricsResponseIDsAreRejectedInsteadOfTrapping() async throws {
        let host = "primuse-relay-duplicate-lyrics.invalid"
        PrimuseRelayURLProtocol.configure(
            host: host,
            featureBody: #"{"data":{"lines":[{"id":"line-1","translated_text":"first"},{"id":"line-1","translated_text":"second"}]}}"#
        )
        let credentials = TestPrimuseRelayCredentialStore(
            credential: PrimuseAIRelayCredential(
                keyID: "test-app-attest-key",
                installationID: "test-installation"
            )
        )
        let (client, session, _, _) = makeClient(host: host, credentials: credentials)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await client.translateLyrics(
                [LyricTranslationCandidate(
                    id: "line-1",
                    text: "source",
                    sourceLanguageCode: nil
                )],
                targetLanguageCode: "en"
            )
            XCTFail("Expected duplicate lyric IDs to be rejected")
        } catch {
            XCTAssertEqual(error as? PrimuseAIRelayError, .invalidResponse)
        }
    }

    func testProductionRelayWhenLiveDeviceTestIsEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_RUN_LIVE_RELAY_TEST"] == "1" else {
            throw XCTSkip("Live Primuse Relay testing is opt-in")
        }

        let authenticationMethod = try await PrimuseAIRelayClient().testConnection()

        XCTAssertEqual(authenticationMethod, .appAttest)
    }

    @MainActor
    func testFreshSettingsKeepRelayAndRemoteFeaturesDisabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "PrimuseAIRelayClientTests.\(UUID().uuidString)"
        ))

        let settings = AISettingsStore(defaults: defaults, syncsThroughICloud: false)

        XCTAssertFalse(settings.primuseRelayEnabled)
        XCTAssertFalse(settings.semanticSearchEnabled)
        XCTAssertFalse(settings.recommendationsEnabled)
        XCTAssertFalse(settings.hasExplicitRemoteConsent)
        XCTAssertFalse(settings.hasExplicitListeningContextConsent)
    }

    @MainActor
    func testVersionFourSettingsDoNotOptInToNewRelayDuringMigration() throws {
        struct LegacySettingsV4: Codable {
            var schemaVersion: Int
            var providerSet: AIRemoteProviderSet
            var semanticSearchEnabled: Bool
            var recommendationsEnabled: Bool
            var audioTranscriptionEnabled: Bool
            var hasExplicitRemoteConsent: Bool
            var hasExplicitListeningContextConsent: Bool
            var hasExplicitAudioUploadConsent: Bool
        }
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "PrimuseAIRelayClientTests.\(UUID().uuidString)"
        ))
        defaults.set(
            try JSONEncoder().encode(LegacySettingsV4(
                schemaVersion: 4,
                providerSet: AIRemoteProviderSet(),
                semanticSearchEnabled: true,
                recommendationsEnabled: true,
                audioTranscriptionEnabled: false,
                hasExplicitRemoteConsent: true,
                hasExplicitListeningContextConsent: true,
                hasExplicitAudioUploadConsent: false
            )),
            forKey: AISettingsStore.storageKey
        )

        let migrated = AISettingsStore(defaults: defaults, syncsThroughICloud: false)

        XCTAssertFalse(migrated.primuseRelayEnabled)
        XCTAssertTrue(migrated.semanticSearchEnabled)
        XCTAssertTrue(migrated.recommendationsEnabled)
        XCTAssertTrue(migrated.hasExplicitRemoteConsent)
        XCTAssertTrue(migrated.hasExplicitListeningContextConsent)
    }

    @MainActor
    func testExplicitRelayChoicePersistsInVersionFiveSettings() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "PrimuseAIRelayClientTests.\(UUID().uuidString)"
        ))
        let settings = AISettingsStore(defaults: defaults, syncsThroughICloud: false)

        try settings.save(
            providerSet: settings.providerSet,
            primuseRelayEnabled: true,
            semanticSearchEnabled: true,
            recommendationsEnabled: true,
            hasExplicitRemoteConsent: true,
            hasExplicitListeningContextConsent: true
        )
        let reloaded = AISettingsStore(defaults: defaults, syncsThroughICloud: false)

        XCTAssertTrue(reloaded.primuseRelayEnabled)
        XCTAssertTrue(reloaded.semanticSearchEnabled)
        XCTAssertTrue(reloaded.recommendationsEnabled)
        XCTAssertTrue(reloaded.hasExplicitRemoteConsent)
        XCTAssertTrue(reloaded.hasExplicitListeningContextConsent)
    }

    private func makeClient(
        host: String,
        attestor: TestPrimuseAppAttestor = TestPrimuseAppAttestor(),
        storeKitProvider: TestPrimuseStoreKitEnrollmentProvider = TestPrimuseStoreKitEnrollmentProvider(),
        credentials: TestPrimuseRelayCredentialStore = TestPrimuseRelayCredentialStore()
    ) -> (
        PrimuseAIRelayClient,
        URLSession,
        TestPrimuseAppAttestor,
        TestPrimuseRelayCredentialStore
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrimuseRelayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = PrimuseAIRelayClient(
            baseURL: URL(string: "https://\(host)")!,
            session: session,
            attestor: attestor,
            storeKitEnrollmentProvider: storeKitProvider,
            credentialStore: credentials
        )
        return (client, session, attestor, credentials)
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }
}

private actor TestPrimuseStoreKitEnrollmentProvider: PrimuseStoreKitEnrollmentProviding {
    let isSupported: Bool
    private let material: PrimuseStoreKitEnrollmentMaterial?

    init(material: PrimuseStoreKitEnrollmentMaterial? = nil) {
        self.material = material
        isSupported = material != nil
    }

    func enrollmentMaterial() async throws -> PrimuseStoreKitEnrollmentMaterial {
        guard let material else { throw PrimuseAIRelayError.unsupportedDevice }
        return material
    }
}

private actor TestPrimuseAppAttestor: PrimuseAppAttesting {
    struct Snapshot: Sendable {
        var generateKeyCount: Int
        var attestationHashes: [Data]
        var assertionHashes: [Data]
    }

    let isSupported: Bool
    private var assertionFailuresRemaining: Int
    private var generateKeyCount = 0
    private var attestationHashes: [Data] = []
    private var assertionHashes: [Data] = []

    init(isSupported: Bool = true, assertionFailuresRemaining: Int = 0) {
        self.isSupported = isSupported
        self.assertionFailuresRemaining = assertionFailuresRemaining
    }

    func generateKey() async throws -> String {
        generateKeyCount += 1
        return "test-app-attest-key"
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        XCTAssertEqual(keyID, "test-app-attest-key")
        attestationHashes.append(clientDataHash)
        return Data([0x01, 0x02])
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionHashes.append(clientDataHash)
        if assertionFailuresRemaining > 0 {
            assertionFailuresRemaining -= 1
            throw NSError(
                domain: DCError.errorDomain,
                code: DCError.invalidKey.rawValue
            )
        }
        XCTAssertEqual(keyID, "test-app-attest-key")
        return Data([0x03, 0x04])
    }

    func snapshot() -> Snapshot {
        Snapshot(
            generateKeyCount: generateKeyCount,
            attestationHashes: attestationHashes,
            assertionHashes: assertionHashes
        )
    }
}

private actor TestPrimuseRelayCredentialStore: PrimuseAIRelayCredentialStoring {
    private var credential: PrimuseAIRelayCredential?
    private var numberOfClears = 0

    init(credential: PrimuseAIRelayCredential? = nil) {
        self.credential = credential
    }

    func load() throws -> PrimuseAIRelayCredential? {
        credential
    }

    func save(_ credential: PrimuseAIRelayCredential) throws {
        self.credential = credential
    }

    func clear() throws {
        credential = nil
        numberOfClears += 1
    }

    func current() -> PrimuseAIRelayCredential? {
        credential
    }

    func clearCount() -> Int {
        numberOfClears
    }
}

private final class PrimuseRelayURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var requests: [URLRequest] = []
        var featureStatusCode = 200
        var featureBody = #"{"data":{"normalized_query":"night rain","expansion_terms":["night rain","rainy night"]}}"#
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    static func configure(
        host: String,
        featureStatusCode: Int = 200,
        featureBody: String = #"{"data":{"normalized_query":"night rain","expansion_terms":["night rain","rainy night"]}}"#
    ) {
        lock.lock()
        states[host] = State(
            featureStatusCode: featureStatusCode,
            featureBody: featureBody
        )
        lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return states[host]?.requests ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            captured.httpBody = Self.readBody(from: stream)
        }

        Self.lock.lock()
        guard var state = Self.states[host] else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        state.requests.append(captured)
        Self.states[host] = state
        Self.lock.unlock()

        let statusCode: Int
        let responseBody: String
        switch url.path {
        case "/v1/auth/challenge":
            let purpose = Self.purpose(from: captured.httpBody) ?? "unknown"
            statusCode = 200
            responseBody = #"{"challenge":"\#(purpose)-challenge","request_id":"test-request"}"#
        case "/v1/auth/installations":
            statusCode = 201
            if Self.isStoreKitEnrollment(captured.httpBody) {
                responseBody = #"{"installation_id":"test-installation","trust_level":"storekit_fallback","access_token":"test-installation-token","request_id":"test-request"}"#
            } else {
                responseBody = #"{"installation_id":"test-installation","trust_level":"attested","request_id":"test-request"}"#
            }
        default:
            statusCode = state.featureStatusCode
            responseBody = state.featureBody
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func purpose(from data: Data?) -> String? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["purpose"] as? String
    }

    private static func isStoreKitEnrollment(_ data: Data?) -> Bool {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["app_transaction_jws"] is String
    }

    private static func readBody(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private extension Data {
    func base64URLEncodedForRelayTests() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
