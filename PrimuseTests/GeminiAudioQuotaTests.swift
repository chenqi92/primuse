import Foundation
import PrimuseKit
import XCTest
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class GeminiAudioQuotaTests: XCTestCase, @unchecked Sendable {
    func testEveryAudioPhaseSharesFullCooldownWithNewAudioAndOrdinaryAI() async throws {
        for phase in 0...3 {
            for status in [429, 503] {
                let fixture = AudioHTTPFixture()
                var replies = fixture.success
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                let delay = status == 429 ? "86400" : formatter.string(from: Date().addingTimeInterval(86400))
                replies[phase] = .init(status: status, headers: ["Retry-After": delay])
                fixture.replies = replies
                let session = fixture.session()
                defer { session.invalidateAndCancel() }
                let key = UUID().uuidString
                let provider = audio(key, session)
                let request = try audioRequest()
                defer { try? FileManager.default.removeItem(at: request.audioFileURL) }
                if phase == 3 {
                    let result = try await provider.transcribeAudio(request)
                    XCTAssertEqual(result.transcript, "fixture")
                } else {
                    await quota { _ = try await provider.transcribeAudio(request) }
                }
                await quota { _ = try await self.audio(key, session).transcribeAudio(request) }
                let ordinary = OpenAICompatibleProvider(configuration: configuration,
                    credentialStore: AudioCredentialStore(key), apiKeyOverride: key, session: session)
                await quota { _ = try await ordinary.listModels() }
                XCTAssertEqual(fixture.requests.count, phase + 1, "Cooldown applies to every phase, including deletion")
                // Independent credentials can still reach their endpoint.
                _ = try? await audio(UUID().uuidString, session).transcribeAudio(request)
                XCTAssertGreaterThan(fixture.requests.count, phase + 1)
            }
        }
    }

    func testUnknownUploadAndGenerationOutcomesAreNotReplayed() async throws {
        for phase in 0...2 {
            for error in [URLError.Code.networkConnectionLost, .timedOut] {
                let fixture = AudioHTTPFixture()
                fixture.replies = Array(fixture.success.prefix(phase)) + [.init(error: error)] + [.init()]
                let session = fixture.session()
                defer { session.invalidateAndCancel() }
                let request = try audioRequest()
                defer { try? FileManager.default.removeItem(at: request.audioFileURL) }
                do { _ = try await audio(UUID().uuidString, session).transcribeAudio(request); XCTFail("Expected transport failure") }
                catch { XCTAssertFalse(error is CancellationError) }
                XCTAssertEqual(fixture.requests.filter { $0.httpMethod != "DELETE" }.count, phase + 1)
            }
        }
    }

    func testCancellationStopsEachActivePhaseWithoutReplay() async throws {
        for phase in 0...3 {
            let fixture = AudioHTTPFixture()
            fixture.replies = Array(fixture.success.prefix(phase)) + [.init(hold: true)] + [.init()]
            fixture.held = expectation(description: "audio request held")
            fixture.stopped = expectation(description: "audio request cancelled")
            let session = fixture.session()
            defer { session.invalidateAndCancel() }
            let provider = audio(UUID().uuidString, session)
            let request = try audioRequest()
            defer { try? FileManager.default.removeItem(at: request.audioFileURL) }
            let done = expectation(description: "transcription cancellation returned")
            let task = Task {
                defer { done.fulfill() }
                do { _ = try await provider.transcribeAudio(request); XCTFail("Expected cancellation") }
                catch is CancellationError { }
                catch { XCTFail("Lost cancellation: \(error)") }
            }
            await fulfillment(of: [fixture.held!], timeout: 5)
            task.cancel()
            await fulfillment(of: [done, fixture.stopped!], timeout: 5)
            XCTAssertEqual(fixture.requests.filter { $0.httpMethod != "DELETE" }.count, min(phase + 1, 3))
            if phase == 3 {
                // The interrupted deletion is handed to the deferred queue exactly once.
                for _ in 0..<1_000 where fixture.requests.count < 5 { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(fixture.requests.count, 5)
                XCTAssertEqual(fixture.requests.last?.httpMethod, "DELETE")
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertEqual(fixture.requests.count, 5, "The handed-off deletion must not loop")
            }
        }
    }

    func testUnsafeUploadURLAndEmptyAudioNeverSendAudioBytes() async throws {
        let fixture = AudioHTTPFixture()
        fixture.replies = [.init(headers: ["x-goog-upload-url": "https://other.invalid/upload"])]
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let request = try audioRequest()
        defer { try? FileManager.default.removeItem(at: request.audioFileURL) }
        let provider = audio(UUID().uuidString, session)
        do { _ = try await provider.transcribeAudio(request); XCTFail("Untrusted upload URL") }
        catch { XCTAssertEqual(error as? OpenAICompatibleProviderError, .invalidResponse) }
        XCTAssertEqual(fixture.requests.count, 1)
        try Data().write(to: request.audioFileURL)
        do { _ = try await provider.transcribeAudio(request); XCTFail("Empty audio") }
        catch { XCTAssertEqual(error as? OpenAICompatibleProviderError, .responseTooLarge) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testDeferredCleanupWaitsForFullQuotaAndAttemptsOnlyOnce() async throws {
        let clock = AudioClock()
        let cleanup = GeminiDeferredCleanup(timing: clock.timing)
        let fixture = AudioHTTPFixture()
        fixture.replies = Array(fixture.success.prefix(2)) + [
            .init(status: 429, headers: ["Retry-After": "86400"]),
            .init(status: 503, headers: ["Retry-After": "86400"])
        ]
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let provider = GeminiAudioTranscriptionProvider(configuration: configuration,
            credentialStore: AudioCredentialStore(UUID().uuidString), session: session,
            scheduler: AIRequestScheduler(timing: clock.timing), cleanup: cleanup)
        let request = try audioRequest()
        defer { try? FileManager.default.removeItem(at: request.audioFileURL) }
        await quota { _ = try await provider.transcribeAudio(request) }
        try await clock.waitForSleep(at: 60)
        XCTAssertEqual(fixture.requests.count, 3, "Deletion must not bypass the original failure's cooldown")
        clock.advance(to: 86399)
        try await clock.waitForSleep(at: 86400)
        XCTAssertEqual(fixture.requests.count, 3)
        clock.advance(to: 86400)
        // Up to ten seconds: the deferred task runs on a busy build host's executor too.
        for _ in 0..<1_000 {
            if fixture.requests.count == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertEqual(fixture.requests.last?.httpMethod, "DELETE")
        clock.advance(to: 200000)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.requests.count, 4, "A second cleanup failure must not create a retry loop")
        await cleanup.cancelAll()
    }

    func testCleanupThatWouldOutlastTheUploadedFileIsNotQueued() async throws {
        let clock = AudioClock()
        let cleanup = GeminiDeferredCleanup(timing: clock.timing)
        let sent = AudioCounter()
        await cleanup.enqueue(after: GeminiDeferredCleanup.uploadedFileLifetime) { await sent.increment() }
        await cleanup.enqueue(after: 0) { await sent.increment() }
        for _ in 0..<1_000 {
            if await sent.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        clock.advance(to: GeminiDeferredCleanup.uploadedFileLifetime + 1)
        try await Task.sleep(for: .milliseconds(20))
        let count = await sent.count
        XCTAssertEqual(count, 1, "Only the cleanup that can still find the file runs")
        await cleanup.cancelAll()
    }

    func testDeferredCleanupHasBoundedCapacityAndCanBeCancelled() async throws {
        let clock = AudioClock()
        let cleanup = GeminiDeferredCleanup(capacity: 1, timing: clock.timing)
        let sent = AudioCounter()
        await cleanup.enqueue(after: 86400) { await sent.increment() }
        await cleanup.enqueue(after: 0) { await sent.increment() }
        try await clock.waitForSleep(at: 60)
        await cleanup.cancelAll()
        clock.advance(to: 200000)
        try await Task.sleep(for: .milliseconds(20))
        let count = await sent.count
        XCTAssertEqual(count, 0)
    }

    func testAudioRetainsLongBudgetAndCallerTimeoutStillApplies() async throws {
        let clock = AudioClock()
        let scheduler = AIRequestScheduler(timing: clock.timing)
        let fixture = AudioHTTPFixture()
        fixture.replies = fixture.success
        fixture.onRequest = { index in if index == 0 { clock.advance(to: 61) } }
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let key = UUID().uuidString
        let provider = GeminiAudioTranscriptionProvider(configuration: configuration,
            credentialStore: AudioCredentialStore(key), session: session, scheduler: scheduler)
        let request = try audioRequest()
        defer { try? FileManager.default.removeItem(at: request.audioFileURL) }
        let result = try await provider.transcribeAudio(request)
        XCTAssertEqual(result.transcript, "fixture", "A successful audio phase can exceed the ordinary 60-second cap")
        var ordinary = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
        ordinary.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            _ = try await scheduler.executor(for: ordinary).execute(timeout: 12, operation: {
                clock.advance(to: 74)
                return true
            })
            XCTFail("Ordinary requests must still honor their own shorter deadline")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testCleanupFailureCannotReplaceOriginalDecodeFailureAndResponsesStayBounded() async throws {
        let fixture = AudioHTTPFixture()
        fixture.replies = Array(fixture.success.prefix(2)) + [.init(), .init(status: 503)]
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let cleanup = GeminiDeferredCleanup()
        let provider = GeminiAudioTranscriptionProvider(configuration: configuration,
            credentialStore: AudioCredentialStore(UUID().uuidString), session: session, cleanup: cleanup)
        let request = try audioRequest()
        defer { try? FileManager.default.removeItem(at: request.audioFileURL) }
        do { _ = try await provider.transcribeAudio(request); XCTFail("Expected decode failure") }
        catch { XCTAssertEqual(error as? OpenAICompatibleProviderError, .invalidResponse) }
        await cleanup.cancelAll()
        for phase in 0...2 {
            let oversized = AudioHTTPFixture()
            oversized.replies = Array(oversized.success.prefix(phase)) + [
                .init(body: String(repeating: "x", count: AIResponseSizePolicy.maximumBytes + 1)), .init()
            ]
            let session = oversized.session()
            defer { session.invalidateAndCancel() }
            do { _ = try await audio(UUID().uuidString, session).transcribeAudio(request); XCTFail("Expected bounded response") }
            catch { XCTAssertEqual(error as? OpenAICompatibleProviderError, .responseTooLarge) }
        }
    }

    private var configuration: AIRemoteProviderConfiguration {
        var config = AIProviderPreset.gemini.applying(to: .init(isEnabled: true))
        config.transcriptionModel = "fixture-transcribe"
        return config
    }
    private func audio(_ key: String, _ session: URLSession) -> GeminiAudioTranscriptionProvider {
        .init(configuration: configuration, credentialStore: AudioCredentialStore(key), session: session)
    }
    private func audioRequest() throws -> AIAudioTranscriptionRequest {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try Data([0x49, 0x44, 0x33, 0x04, 0, 0]).write(to: url)
        return .init(audioFileURL: url, mimeType: "audio/mpeg", displayName: "fixture.mp3")
    }
    private func quota(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected quota failure") }
        catch {
            guard case .requestFailed(let status, let delay) = error as? OpenAICompatibleProviderError else {
                XCTFail("Lost quota status: \(error)"); return
            }
            XCTAssertTrue([429, 503].contains(status))
            XCTAssertGreaterThan(delay ?? 0, 86390)
        }
    }
}

private actor AudioCredentialStore: AICredentialStoring {
    let key: String
    init(_ key: String) { self.key = key }
    func lookupAPIKey(configuration: AIRemoteProviderConfiguration) -> AICredentialLookup { .ready(key) }
    func requireAPIKey(configuration: AIRemoteProviderConfiguration) throws -> String { key }
    func saveAPIKey(_ rawValue: String, configuration: AIRemoteProviderConfiguration) throws -> Bool { false }
    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) throws {}
}
private final class AudioHTTPFixture: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = "{}"
        var headers: [String: String] = [:]
        var error: URLError.Code?
        var hold = false
    }
    var success: [Reply] { [
        .init(headers: ["x-goog-upload-url": "https://generativelanguage.googleapis.com/upload-session"]),
        .init(body: #"{"file":{"name":"files/fixture","uri":"https://generativelanguage.googleapis.com/v1beta/files/fixture","mimeType":"audio/mpeg"}}"#),
        .init(body: #"{"output_text":"fixture"}"#),
        .init()
    ] }
    var onRequest: (@Sendable (Int) -> Void)?
    private let id = UUID().uuidString
    var replies: [Reply] = []
    var held: XCTestExpectation?
    var stopped: XCTestExpectation?
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    func next(_ request: URLRequest) -> Reply {
        lock.withLock {
            let index = captured.count; captured.append(request)
            onRequest?(index)
            return index < replies.count ? replies[index] : .init(status: 503, headers: ["Retry-After": "86400"])
        }
    }
    func session() -> URLSession {
        AudioHTTPProtocol.lock.withLock { AudioHTTPProtocol.fixtures[id] = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioHTTPProtocol.self]
        config.httpAdditionalHeaders = ["X-Primuse-Audio-Fixture": id]
        return URLSession(configuration: config)
    }
}
private final class AudioHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixtures: [String: AudioHTTPFixture] = [:]
    private var owner: AudioHTTPFixture?
    private var held = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixtures[request.value(forHTTPHeaderField: "X-Primuse-Audio-Fixture")!]! }; owner = fixture
        let reply = fixture.next(request)
        if reply.hold { held = true; fixture.held?.fulfill(); return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if held { owner?.stopped?.fulfill() } }
}

private actor AudioCounter {
    var count = 0
    func increment() { count += 1 }
}
private final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { instant } }
    func advance(to value: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            instant = value
            let ready = sleepers.filter { $0.value.0 <= value }
            for key in ready.keys { sleepers[key] = nil }
            return ready.values.map { $0.1 }
        }
        for continuation in ready { continuation.resume() }
    }
    private func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { sleepers[id] = (instant + interval, continuation) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }
    func waitForSleep(at deadline: TimeInterval) async throws {
        for _ in 0..<2000 {
            if lock.withLock({ sleepers.values.contains { abs($0.0 - deadline) < 0.00001 } }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    var timing: RequestExecutor.Timing { .init(now: { self.now }, sleep: { try await self.sleep($0) }) }
}
