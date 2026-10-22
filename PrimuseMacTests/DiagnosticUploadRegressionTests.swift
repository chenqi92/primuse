import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class DiagnosticUploadRegressionTests: XCTestCase {
    func testExplicitUploadRefreshesMissingReceiptAndCompletesUsingInstallationToken() async throws {
        let provider = UploadReceiptProvider()
        let (client, session, host) = makeClient(provider: provider)
        defer { session.invalidateAndCancel() }

        let slot = try await client.requestDiagnosticsUpload(uploadRequest)
        let code = try await client.completeDiagnosticsUpload(id: slot.uploadID)

        XCTAssertEqual(code, "PM-MACTEST")
        let refreshes = await provider.refreshes
        XCTAssertEqual(refreshes, [true])
        let requests = UploadURLProtocol.requests(host)
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/v1/auth/challenge", "/v1/auth/installations",
            "/v1/diagnostics/uploads", "/v1/diagnostics/uploads/complete",
        ])
        let upload = try XCTUnwrap(requests.first { $0.url?.path == "/v1/diagnostics/uploads" })
        XCTAssertEqual(upload.value(forHTTPHeaderField: "X-Primuse-Installation-Token"), "fixture-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(upload.httpBody)) as? [String: Any])
        XCTAssertEqual(body["platform"] as? String, "macOS")
    }

    func testAvailabilityCheckDoesNotRefreshOrEnroll() async throws {
        let provider = UploadReceiptProvider()
        let (client, session, host) = makeClient(provider: provider)
        defer { session.invalidateAndCancel() }
        let available = await client.diagnosticsUploadAvailability()
        XCTAssertEqual(available, true)
        let refreshes = await provider.refreshes
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertEqual(UploadURLProtocol.requests(host).compactMap(\.url?.path), ["/v1/service-info"])
    }

    func testBackgroundEnrollmentStillDoesNotRefreshMissingReceipt() async throws {
        let provider = UploadReceiptProvider()
        let (client, session, host) = makeClient(provider: provider)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.prepareInstallation()
            XCTFail("Background enrollment must not prompt for App Store authentication")
        } catch {
            XCTAssertEqual(error as? PrimuseAIRelayError, .storeKitTransactionUnavailable)
        }
        let refreshes = await provider.refreshes
        XCTAssertEqual(refreshes, [false])
        XCTAssertTrue(UploadURLProtocol.requests(host).isEmpty)
    }

    func testCancelledLoginCancelsUploadWithoutRequestingSlot() async throws {
        let provider = UploadReceiptProvider(cancelled: true)
        let (client, session, host) = makeClient(provider: provider)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.requestDiagnosticsUpload(uploadRequest)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(UploadURLProtocol.requests(host).isEmpty)
    }

    func testAuthenticationFailuresRetainCodesWithoutDisablingUpload() {
        let failures: [(PrimuseAIRelayError, String)] = [
            (.storeKitTransactionUnavailable, "storekit_transaction_unavailable"),
            (.storeKitTransactionUnverified, "storekit_transaction_unverified"),
            (.credentialUnavailable, "credential_unavailable"),
            (.credentialPersistenceFailed, "credential_persistence_failed"),
            (.requestFailed(statusCode: 401, code: "invalid_app_transaction"), "invalid_app_transaction"),
        ]
        for (error, code) in failures {
            XCTAssertEqual(PrimuseAIRelayClient.diagnosticUploadError(error) as? DiagnosticUpload.Failure,
                           .other(code: code))
        }
    }

    func testUnavailableServiceAndNetworkFailuresRemainDistinct() {
        XCTAssertEqual(PrimuseAIRelayClient.diagnosticUploadError(
            PrimuseAIRelayError.requestFailed(statusCode: 503, code: "diagnostics_unavailable")
        ) as? DiagnosticUpload.Failure, .unavailable)
        XCTAssertEqual(PrimuseAIRelayClient.diagnosticUploadError(URLError(.timedOut)) as? DiagnosticUpload.Failure,
                       .network)
    }

    private var uploadRequest: DiagnosticUpload.Request {
        .init(byteCount: 128, appVersion: "1.12.1", build: "110", platform: "macOS",
              osVersion: "15.0", deviceModel: "Mac", contents: [], message: nil)
    }

    private func makeClient(provider: UploadReceiptProvider) -> (PrimuseAIRelayClient, URLSession, String) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = PrimuseAIRelayClient(
            baseURL: URL(string: "https://" + host)!, session: session,
            attestor: UploadUnsupportedAttestor(), storeKitEnrollmentProvider: provider,
            credentialStore: UploadCredentialStore()
        )
        return (client, session, host)
    }
}

private actor UploadReceiptProvider: PrimuseStoreKitEnrollmentProviding {
    let isSupported = true
    let cancelled: Bool
    var refreshes: [Bool] = []
    init(cancelled: Bool = false) { self.cancelled = cancelled }
    func enrollmentMaterial(allowsRefresh: Bool) async throws -> PrimuseStoreKitEnrollmentMaterial {
        refreshes.append(allowsRefresh)
        guard allowsRefresh else { throw PrimuseAIRelayError.storeKitTransactionUnavailable }
        if cancelled { throw PrimuseAIRelayError.storeKitAuthenticationCancelled }
        return .init(appTransactionJWS: "fixture-receipt", deviceVerificationID: "fixture-device")
    }
}

private actor UploadUnsupportedAttestor: PrimuseAppAttesting {
    let isSupported = false
    func generateKey() async throws -> String { throw PrimuseAIRelayError.unsupportedDevice }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { throw PrimuseAIRelayError.unsupportedDevice }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { throw PrimuseAIRelayError.unsupportedDevice }
}

private actor UploadCredentialStore: PrimuseAIRelayCredentialStoring {
    var credential: PrimuseAIRelayCredential?
    func load() throws -> PrimuseAIRelayCredential? { credential }
    func save(_ value: PrimuseAIRelayCredential) throws { credential = value }
    func clear() throws { credential = nil }
}

private final class UploadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]
    static func requests(_ host: String) -> [URLRequest] {
        lock.withLock { captured[host] ?? [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var saved = request
        if saved.httpBody == nil, let stream = saved.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            saved.httpBody = data
        }
        guard let url = saved.url, let host = url.host else { return }
        Self.lock.withLock { Self.captured[host, default: []].append(saved) }
        let body: String
        switch url.path {
        case "/v1/service-info": body = #"{"data":{"diagnostics_upload":"available"}}"#
        case "/v1/auth/challenge": body = #"{"challenge":"fixture-challenge"}"#
        case "/v1/auth/installations":
            body = #"{"installation_id":"fixture-installation","access_token":"fixture-token"}"#
        case "/v1/diagnostics/uploads":
            body = #"{"data":{"upload_id":"fixture-upload","code":"PM-MACTEST","upload_url":"https://storage.invalid/upload","method":"PUT","headers":{"Content-Length":"128"}}}"#
        case "/v1/diagnostics/uploads/complete": body = #"{"data":{"code":"PM-MACTEST"}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
