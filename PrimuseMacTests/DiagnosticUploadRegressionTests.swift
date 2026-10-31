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

final class DiagnosticStorageRegressionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    func testMetricsOnlyRemainAvailableWithoutCrashReports() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CrashDiagnosticsService(directory: directory)
        for index in 0..<3 {
            service.persistData(Data("{\"sample\":\(index)}".utf8), prefix: CrashDiagnosticsService.metricFilePrefix)
        }
        XCTAssertTrue(service.reports().isEmpty)
        XCTAssertEqual(service.metricReports().count, 3)
        XCTAssertTrue(service.metricReports().allSatisfy { $0.sizeBytes > 0 })
    }

    @MainActor
    func testDeletingOneMetricPreservesOtherReports() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CrashDiagnosticsService(directory: directory)
        service.persistData(Data("{\"crash\":1}".utf8))
        service.persistData(Data("{\"metric\":1}".utf8), prefix: CrashDiagnosticsService.metricFilePrefix)
        service.persistData(Data("{\"metric\":2}".utf8), prefix: CrashDiagnosticsService.metricFilePrefix)
        let deleted = try XCTUnwrap(service.metricReports().first)
        try service.delete(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.url.path))
        XCTAssertEqual(service.reports().count, 1)
        XCTAssertEqual(service.metricReports().count, 1)
        try service.delete(deleted)
        XCTAssertEqual(service.metricReports().count, 1)
    }

    @MainActor
    func testClearAllRemovesBothCategoriesAndPreservesUnrelatedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        let service = CrashDiagnosticsService(directory: directory)
        service.persistData(Data("{}".utf8))
        service.persistData(Data("{}".utf8), prefix: CrashDiagnosticsService.metricFilePrefix)
        try service.clearAll()
        XCTAssertTrue(service.reports().isEmpty)
        XCTAssertTrue(service.metricReports().isEmpty)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    }

    func testClearLogsRemovesAllGenerationsAndPendingDuplicatesBeforeExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(directory: directory)
        _ = try await logger.exportData()
        let generations = (1...DiagnosticLoggingPolicy.diagnosticLimits.rotatedGenerations).map {
            directory.appendingPathComponent("primuse_debug.log.\($0)")
        }
        for url in generations { try Data("old generation\n".utf8).write(to: url) }
        let unrelated = directory.appendingPathComponent("unrelated.log")
        try Data("keep".utf8).write(to: unrelated)
        for _ in 0..<3 { logger.log("repeated message", file: "fixture.swift", line: 1) }
        let before = await logger.storedLogSize()
        XCTAssertGreaterThan(before, 0)

        try await logger.clearLogs()
        let exported = try await logger.exportData()
        let tail = await logger.tailData(maxBytes: 10_000)
        let size = await logger.storedLogSize()
        XCTAssertTrue(exported.isEmpty)
        XCTAssertTrue(tail.isEmpty)
        XCTAssertEqual(size, 0)
        XCTAssertTrue(generations.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")

        logger.log("repeated message", file: "fixture.swift", line: 1)
        let fresh = String(decoding: try await logger.exportData(), as: UTF8.self)
        XCTAssertTrue(fresh.contains("repeated message"))
        XCTAssertFalse(fresh.contains("old generation"))
        XCTAssertFalse(fresh.contains("SESSION START"))
        let freshSize = await logger.storedLogSize()
        XCTAssertEqual(freshSize, fresh.utf8.count)
        try await logger.clearLogs()
        let clearedAgain = try await logger.exportData()
        XCTAssertTrue(clearedAgain.isEmpty)
    }

    func testClearLogsReportsFileSystemFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(directory: directory.appendingPathComponent("missing-parent"))
        do {
            try await logger.clearLogs()
            XCTFail("A failed cleanup must not be reported as success")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
    }

    @MainActor
    func testConfirmedUploadClearsPackagedReportsAndHistoricalLogsButPreservesNewData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CrashDiagnosticsService(directory: directory)
        service.persistData(Data("{}".utf8))
        service.persistData(Data("{}".utf8), prefix: CrashDiagnosticsService.metricFilePrefix)
        let uploadedURLs = (service.reports() + service.metricReports()).map(\.url)
        let logger = FileLogger(directory: directory)
        logger.log("before upload", file: "fixture.swift", line: 1)
        let previous = directory.appendingPathComponent("primuse_debug.log.1")
        try Data("old generation\n".utf8).write(to: previous)
        let snapshot = await logger.uploadSnapshot(maxBytes: 10_000)
        let archive = try makeArchive(reportURLs: uploadedURLs, log: snapshot.data)
        defer { archive.remove() }

        let result = try await DiagnosticReportUploader.finishUpload(archive, logSnapshot: snapshot, logger: logger) {
            XCTAssertTrue(uploadedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            let pendingLog = try await logger.exportData()
            XCTAssertTrue(String(decoding: pendingLog, as: UTF8.self).contains("before upload"))
            service.persistData(Data("{\"new\":1}".utf8))
            service.persistData(Data("{\"new\":1}".utf8), prefix: CrashDiagnosticsService.metricFilePrefix)
            logger.log("during upload", file: "fixture.swift", line: 2)
            logger.log("during upload", file: "fixture.swift", line: 2)
            return "PM-CLEANUP"
        }

        XCTAssertEqual(result.code, "PM-CLEANUP")
        XCTAssertNil(result.cleanupError)
        XCTAssertTrue(uploadedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(service.reports().count, 1)
        XCTAssertEqual(service.metricReports().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        let remaining = String(decoding: try await logger.exportData(), as: UTF8.self)
        XCTAssertTrue(remaining.contains("during upload"))
        XCTAssertTrue(remaining.contains("重复 1 次"))
        XCTAssertFalse(remaining.contains("before upload"))
        logger.log("after cleanup", file: "fixture.swift", line: 3)
        let continued = String(decoding: try await logger.exportData(), as: UTF8.self)
        XCTAssertTrue(continued.contains("during upload"))
        XCTAssertTrue(continued.contains("after cleanup"))
    }

    @MainActor
    func testFailedOrCancelledConfirmationPreservesReportsAndLogs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("report.json")
        try Data("{}".utf8).write(to: report)
        let logger = FileLogger(directory: directory)
        let snapshot = await logger.uploadSnapshot(maxBytes: 10_000)
        let archive = try makeArchive(reportURLs: [report], log: snapshot.data)
        defer { archive.remove() }
        for failure in [DiagnosticUpload.Failure.network as any Error, CancellationError()] {
            do {
                _ = try await DiagnosticReportUploader.finishUpload(archive, logSnapshot: snapshot, logger: logger) {
                    throw failure
                }
                XCTFail("Confirmation must succeed before cleanup")
            } catch {
                XCTAssertTrue(error is CancellationError || error as? DiagnosticUpload.Failure == .network)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
            let log = try await logger.exportData()
            XCTAssertEqual(log, snapshot.data)
        }
    }

    @MainActor
    func testCleanupPreservesUnselectedAndUnpackagedContents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("selected.json")
        let unselected = directory.appendingPathComponent("unselected.json")
        let missing = directory.appendingPathComponent("missing.json")
        try Data("{}".utf8).write(to: selected)
        try Data("{}".utf8).write(to: unselected)
        let logger = FileLogger(directory: directory)
        let before = try await logger.exportData()
        let archive = try makeArchive(reportURLs: [selected, missing], log: nil)
        defer { archive.remove() }
        XCTAssertEqual(archive.reportURLs, [selected])
        try Data("{}".utf8).write(to: missing)

        _ = try await DiagnosticReportUploader.finishUpload(archive, logSnapshot: nil, logger: logger) { "PM-REPORT" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.path))
        let after = try await logger.exportData()
        XCTAssertEqual(after, before)

        let snapshot = await logger.uploadSnapshot(maxBytes: 10_000)
        let logArchive = try makeArchive(reportURLs: [], log: snapshot.data)
        defer { logArchive.remove() }
        _ = try await DiagnosticReportUploader.finishUpload(logArchive, logSnapshot: snapshot, logger: logger) { "PM-LOG" }
        let cleared = try await logger.exportData()
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path))
    }

    @MainActor
    func testCleanupFailureRetainsConfirmedUploadCode() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let report = directory.appendingPathComponent("report.json")
        try Data("{}".utf8).write(to: report)
        let logger = FileLogger(directory: directory)
        let archive = try makeArchive(reportURLs: [report], log: nil)
        defer { archive.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let result = try await DiagnosticReportUploader.finishUpload(archive, logSnapshot: nil, logger: logger) { "PM-CONFIRMED" }
        XCTAssertEqual(result.code, "PM-CONFIRMED")
        XCTAssertNotNil(result.cleanupError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
    }

    func testUploadedLogCleanupFollowsRotationAndPreservesNewGenerations() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("primuse_debug.log")
        let limit = DiagnosticLoggingPolicy.limits(isActive: false).maxFileBytes
        try Data(repeating: 0x41, count: limit - 1024).write(to: logURL)
        let logger = FileLogger(directory: directory)
        let snapshot = await logger.uploadSnapshot(maxBytes: 512)
        logger.log("boundary " + String(repeating: "b", count: 2048), file: "fixture.swift", line: 1)
        logger.log("new generation", file: "fixture.swift", line: 2)
        _ = try await logger.exportData()

        try await logger.clearUploadedLogs(snapshot)
        let tail = String(decoding: await logger.tailData(maxBytes: 10_000), as: UTF8.self)
        XCTAssertTrue(tail.contains("boundary "))
        XCTAssertTrue(tail.contains("new generation"))
        XCTAssertFalse(tail.contains("AAAA"))
        XCTAssertFalse(tail.contains("SESSION START"))
        let size = await logger.storedLogSize()
        XCTAssertLessThan(size, 4000)
    }

    func testOldSnapshotCannotClearLogsCreatedAfterManualClear() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(directory: directory)
        let snapshot = await logger.uploadSnapshot(maxBytes: 10_000)
        try await logger.clearLogs()
        logger.log("keep new file " + String(repeating: "x", count: 200), file: "fixture.swift", line: 1)
        let before = try await logger.exportData()
        try await logger.clearUploadedLogs(snapshot)
        let after = try await logger.exportData()
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testStartupRemovesWeekOldReportsAndMetricsOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldDate = Date().addingTimeInterval(-8 * 24 * 3600)
        let oldReports = ["crash-old.json", "metrics-old.json"].map { directory.appendingPathComponent($0) }
        for url in oldReports { try writeFixture(url, modifiedAt: oldDate) }
        let fresh = directory.appendingPathComponent("crash-fresh.json")
        try writeFixture(fresh, modifiedAt: Date())
        let unrelated = directory.appendingPathComponent("keep.txt")
        try writeFixture(unrelated, modifiedAt: oldDate)

        let service = CrashDiagnosticsService(directory: directory)
        XCTAssertTrue(oldReports.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(service.reports().map { $0.url.resolvingSymlinksInPath() }, [fresh.resolvingSymlinksInPath()])
        XCTAssertTrue(service.metricReports().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @MainActor
    func testReportRetentionUsesLastWriteAndKeepsSevenDayBoundary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CrashDiagnosticsService(directory: directory)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let expired = directory.appendingPathComponent("crash-expired.json")
        let boundary = directory.appendingPathComponent("metrics-boundary.json")
        let future = directory.appendingPathComponent("crash-future.json")
        try writeFixture(expired, modifiedAt: cutoff.addingTimeInterval(-1))
        try writeFixture(boundary, modifiedAt: cutoff)
        try writeFixture(future, modifiedAt: now.addingTimeInterval(3600))

        service.pruneExpiredReports(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: future.path))
    }

    @MainActor
    func testListingAndReceivingReportsPrunesExpiredFilesWithoutRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CrashDiagnosticsService(directory: directory)
        let oldDate = Date().addingTimeInterval(-8 * 24 * 3600)
        let report = directory.appendingPathComponent("crash-old.json")
        let metric = directory.appendingPathComponent("metrics-old.json")
        try writeFixture(report, modifiedAt: oldDate)
        try writeFixture(metric, modifiedAt: oldDate)
        XCTAssertTrue(service.reports().isEmpty)
        XCTAssertTrue(service.metricReports().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metric.path))

        try writeFixture(report, modifiedAt: oldDate)
        service.persistData(Data("{}".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        XCTAssertEqual(service.reports().count, 1)
    }

    func testLoggerStartupExpiresCurrentAndRotatedLogsBeforeWritingSessionHeader() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldDate = Date().addingTimeInterval(-8 * 24 * 3600)
        let current = directory.appendingPathComponent("primuse_debug.log")
        let generations = (1...DiagnosticLoggingPolicy.diagnosticLimits.rotatedGenerations).map {
            directory.appendingPathComponent("primuse_debug.log.\($0)")
        }
        for url in [current] + generations { try writeFixture(url, modifiedAt: oldDate, content: "expired content\n") }
        let unrelated = directory.appendingPathComponent("keep.log")
        try writeFixture(unrelated, modifiedAt: oldDate)

        let logger = FileLogger(directory: directory)
        let log = String(decoding: try await logger.exportData(), as: UTF8.self)
        XCTAssertFalse(log.contains("expired content"))
        XCTAssertTrue(log.contains("SESSION START"))
        XCTAssertTrue(generations.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testLogRetentionKeepsBoundaryAndFutureFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(directory: directory)
        _ = try await logger.exportData()
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let boundary = directory.appendingPathComponent("primuse_debug.log.1")
        let expired = directory.appendingPathComponent("primuse_debug.log.2")
        let future = directory.appendingPathComponent("primuse_debug.log.3")
        try writeFixture(boundary, modifiedAt: cutoff)
        try writeFixture(expired, modifiedAt: cutoff.addingTimeInterval(-1))
        try writeFixture(future, modifiedAt: now.addingTimeInterval(3600))

        _ = await logger.storedLogSize(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: future.path))
    }

    func testLoggingAfterIdleExpiryPreservesTheNewMessage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("primuse_debug.log")
        try Data("old content\n".utf8).write(to: current)
        let logger = FileLogger(directory: directory, now: Date().addingTimeInterval(-7200))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: current.path
        )
        logger.log("fresh message", file: "fixture.swift", line: 1)
        let log = String(decoding: try await logger.exportData(), as: UTF8.self)
        XCTAssertTrue(log.contains("fresh message"))
        XCTAssertFalse(log.contains("old content"))
        XCTAssertFalse(log.contains("SESSION START"))
    }

    func testUploadSnapshotExpiresInactiveLogsAndLoggingContinues() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(directory: directory)
        _ = try await logger.exportData()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: logger.logFileURL.path
        )
        let snapshot = await logger.uploadSnapshot(maxBytes: 10_000)
        XCTAssertTrue(snapshot.data.isEmpty)
        logger.log("fresh message", file: "fixture.swift", line: 1)
        let log = String(decoding: try await logger.exportData(), as: UTF8.self)
        XCTAssertTrue(log.contains("fresh message"))
        XCTAssertFalse(log.contains("SESSION START"))
    }

    func testWriteAtExpiryCannotRenewOldLogDuringHourlyCheckInterval() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(directory: directory)
        _ = try await logger.exportData()
        let lastCheck = Date().addingTimeInterval(-2)
        try FileManager.default.setAttributes(
            [.modificationDate: lastCheck.addingTimeInterval(-7 * 24 * 3600 + 1)],
            ofItemAtPath: logger.logFileURL.path
        )
        _ = await logger.storedLogSize(now: lastCheck)
        XCTAssertTrue(try String(contentsOf: logger.logFileURL, encoding: .utf8).contains("SESSION START"))
        logger.log("fresh message", file: "fixture.swift", line: 1)
        let log = String(decoding: try await logger.exportData(), as: UTF8.self)
        XCTAssertTrue(log.contains("fresh message"))
        XCTAssertFalse(log.contains("SESSION START"))
    }

    private func writeFixture(_ url: URL, modifiedAt date: Date, content: String = "{}") throws {
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeArchive(reportURLs: [URL], log: Data?) throws -> DiagnosticReportPackager.Archive {
        try DiagnosticReportPackager.build(.init(
            environment: .init(appVersion: "1.12.2", buildNumber: "119", deviceModel: "Mac", systemName: "macOS", systemVersion: "27"),
            intro: "", reportURLs: reportURLs, log: log, message: "", screenshots: []
        ))
    }
}
