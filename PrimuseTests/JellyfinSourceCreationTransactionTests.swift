import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class JellyfinSourceCreationTransactionTests: XCTestCase {
    func testPreflightPolicyAppliesOnlyToNewJellyfinSources() {
        for sourceType in MusicSourceType.allCases {
            XCTAssertEqual(
                JellyfinSourceCreationPolicy.requiresPreflight(
                    for: sourceType,
                    isEditing: false
                ),
                sourceType == .jellyfin
            )
            XCTAssertFalse(
                JellyfinSourceCreationPolicy.requiresPreflight(
                    for: sourceType,
                    isEditing: true
                )
            )
        }
    }

    func testWrongAddressShowsNetworkFailureWithoutPersistence() async {
        let transaction = JellyfinSourceCreationTransaction { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        var credentialWrites = 0
        var sourceWrites = 0

        transaction.submit(
            source: makeSource(),
            secret: "wrong-secret",
            persistCredential: { _, _ in credentialWrites += 1; return true },
            removeCredential: { _ in true },
            persistSource: { _ in sourceWrites += 1 },
            onCommit: { _ in }
        )
        await waitUntil { !transaction.isRunning }

        XCTAssertEqual(transaction.failure?.kind, .network)
        XCTAssertFalse(transaction.failure?.title.isEmpty ?? true)
        XCTAssertFalse(transaction.failure?.message.isEmpty ?? true)
        XCTAssertEqual(credentialWrites, 0)
        XCTAssertEqual(sourceWrites, 0)
    }

    func testRejectedAccountOrPasswordShowsAuthenticationFailureWithoutPersistence() async {
        for source in [
            makeSource(username: "missing-account"),
            makeSource(username: "qa-user")
        ] {
            let transaction = JellyfinSourceCreationTransaction { _, _ in
                throw SourceError.authenticationFailed
            }
            var credentialWrites = 0
            var sourceWrites = 0

            transaction.submit(
                source: source,
                secret: "wrong-secret",
                persistCredential: { _, _ in credentialWrites += 1; return true },
                removeCredential: { _ in true },
                persistSource: { _ in sourceWrites += 1 },
                onCommit: { _ in }
            )
            await waitUntil { !transaction.isRunning }

            XCTAssertEqual(transaction.failure?.kind, .authentication)
            XCTAssertEqual(credentialWrites, 0)
            XCTAssertEqual(sourceWrites, 0)
        }
    }

    func testSuccessfulAuthenticationCommitsCredentialSourceAndScanOnce() async {
        let preflights = JellyfinPreflightCounter()
        let transaction = JellyfinSourceCreationTransaction { _, _ in
            await preflights.increment()
        }
        var credentials: [String: String] = [:]
        var persistedSources: [MusicSource] = []
        var scanRequests: [String] = []
        let source = makeSource()

        transaction.submit(
            source: source,
            secret: "correct-secret",
            persistCredential: { credentials[$0] = $1; return true },
            removeCredential: { credentials[$0] = nil; return true },
            persistSource: {
                persistedSources.append($0)
                scanRequests.append($0.id)
            },
            onCommit: { _ in }
        )
        transaction.submit(
            source: source,
            secret: "correct-secret",
            persistCredential: { _, _ in XCTFail("duplicate credential write"); return true },
            removeCredential: { _ in true },
            persistSource: { _ in XCTFail("duplicate source write") },
            onCommit: { _ in XCTFail("duplicate commit") }
        )
        await waitUntil { transaction.didCommit }

        let preflightCount = await preflights.value
        XCTAssertEqual(preflightCount, 1)
        XCTAssertEqual(credentials, [source.id: "correct-secret"])
        XCTAssertEqual(persistedSources.map(\.id), [source.id])
        XCTAssertEqual(scanRequests, [source.id])
        XCTAssertNil(transaction.failure)
    }

    func testTimeoutLeavesFormFailedAndDoesNotPersist() async {
        let gate = JellyfinPreflightGate()
        let transaction = JellyfinSourceCreationTransaction(timeout: 0.05) { _, _ in
            await gate.wait()
        }
        var credentialWrites = 0
        var sourceWrites = 0

        transaction.submit(
            source: makeSource(),
            secret: "secret",
            persistCredential: { _, _ in credentialWrites += 1; return true },
            removeCredential: { _ in true },
            persistSource: { _ in sourceWrites += 1 },
            onCommit: { _ in }
        )
        await waitUntil { !transaction.isRunning }

        XCTAssertEqual(transaction.failure?.kind, .timeout)
        XCTAssertEqual(credentialWrites, 0)
        XCTAssertEqual(sourceWrites, 0)
        await gate.release()
    }

    func testCancelBeforeLatePreflightCompletionNeverCommits() async {
        let gate = JellyfinPreflightGate()
        let transaction = JellyfinSourceCreationTransaction(timeout: 5) { _, _ in
            await gate.wait()
        }
        var credentialWrites = 0
        var sourceWrites = 0

        transaction.submit(
            source: makeSource(),
            secret: "secret",
            persistCredential: { _, _ in credentialWrites += 1; return true },
            removeCredential: { _ in true },
            persistSource: { _ in sourceWrites += 1 },
            onCommit: { _ in }
        )
        await gate.waitUntilStarted()
        transaction.cancel()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(transaction.isRunning)
        XCTAssertFalse(transaction.didCommit)
        XCTAssertNil(transaction.failure)
        XCTAssertEqual(credentialWrites, 0)
        XCTAssertEqual(sourceWrites, 0)
    }

    func testSourcePersistenceFailureRollsBackCredential() async {
        let transaction = JellyfinSourceCreationTransaction { _, _ in }
        var credentials: [String: String] = [:]
        let source = makeSource()

        transaction.submit(
            source: source,
            secret: "secret",
            persistCredential: { credentials[$0] = $1; return true },
            removeCredential: { credentials[$0] = nil; return true },
            persistSource: { _ in throw JellyfinCreationTestError.persistence },
            onCommit: { _ in XCTFail("failed persistence committed") }
        )
        await waitUntil { !transaction.isRunning }

        XCTAssertTrue(credentials.isEmpty)
        XCTAssertEqual(transaction.failure?.kind, .sourcePersistence)
        XCTAssertFalse(transaction.didCommit)
    }

    func testRealJellyfinLoginPreflightAcceptsValidResponse() async throws {
        let requests = JellyfinRequestRecorder()

        try await JellyfinSourceCreationPreflight.validate(
            source: makeSource(),
            secret: "correct-secret",
            requestDataLoader: { request in
                await requests.record(request)
                return try makeResponse(
                    for: request,
                    status: 200,
                    json: #"{"AccessToken":"qa-token","User":{"Id":"qa-user-id"}}"#
                )
            }
        )

        let recordedRequests = await requests.values
        XCTAssertEqual(recordedRequests.count, 1)
        XCTAssertEqual(recordedRequests.first?.url?.path, "/Users/AuthenticateByName")
        XCTAssertEqual(recordedRequests.first?.httpMethod, "POST")
    }

    func testRealJellyfinLoginPreflightMapsHTTP401ToAuthenticationFailure() async {
        do {
            try await JellyfinSourceCreationPreflight.validate(
                source: makeSource(),
                secret: "wrong-secret",
                requestDataLoader: { request in
                    try makeResponse(
                        for: request,
                        status: 401,
                        json: #"{"Message":"Unauthorized"}"#
                    )
                }
            )
            XCTFail("Expected authentication failure")
        } catch let error as SourceError {
            guard case .authenticationFailed = error else {
                return XCTFail("Unexpected source error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSource(username: String = "qa-user") -> MusicSource {
        MusicSource(
            id: UUID().uuidString,
            name: "Jellyfin QA",
            type: .jellyfin,
            host: "jellyfin-preflight.invalid",
            port: 8096,
            useSsl: false,
            username: username,
            authType: .password
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private func makeResponse(
    for request: URLRequest,
    status: Int,
    json: String
) throws -> (Data, URLResponse) {
    guard let url = request.url,
          let response = HTTPURLResponse(
              url: url,
              statusCode: status,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
          ) else {
        throw URLError(.badURL)
    }
    return (Data(json.utf8), response)
}

private enum JellyfinCreationTestError: LocalizedError {
    case persistence

    var errorDescription: String? { "Source persistence failed" }
}

private actor JellyfinPreflightGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor JellyfinPreflightCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor JellyfinRequestRecorder {
    private(set) var values: [URLRequest] = []

    func record(_ request: URLRequest) {
        values.append(request)
    }
}
