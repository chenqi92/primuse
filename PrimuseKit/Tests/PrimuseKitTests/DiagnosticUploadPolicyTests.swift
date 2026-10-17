import Foundation
import Testing
@testable import PrimuseKit

@Suite("Diagnostic upload policy")
struct DiagnosticUploadPolicyTests {
    private let mebibyte = 1_048_576

    @Test("The App Store build carries a shorter log tail than test builds")
    func logTailDependsOnChannel() {
        #expect(DiagnosticUpload.logTailBytes(channel: .appStore) == 4 * mebibyte)
        #expect(DiagnosticUpload.logTailBytes(channel: .testFlight) == 8 * mebibyte)
        #expect(DiagnosticUpload.logTailBytes(channel: .development) == 8 * mebibyte)
        #expect(DiagnosticUpload.maximumBytes == 8 * mebibyte)
    }

    @Test("Contents are listed in a fixed order and only when present")
    func listsContents() {
        #expect(DiagnosticUpload.contents(
            includesReports: true, includesLog: true, screenshotCount: 2, message: "it skips"
        ) == [.reports, .log, .screenshots, .message])
        #expect(DiagnosticUpload.contents(
            includesReports: false, includesLog: false, screenshotCount: 0, message: "  \n "
        ) == [])
        #expect(DiagnosticUpload.contents(
            includesReports: false, includesLog: true, screenshotCount: 0, message: nil
        ) == [.log])
        #expect(DiagnosticUpload.Content.allCases.map(\.rawValue)
            == ["reports", "log", "screenshots", "message"])
    }

    @Test("Screenshots shrink first, then the log tail halves down to the floor")
    func stepsDownScreenshotsThenLog() {
        let steps = DiagnosticUpload.attempts(logTailBytes: 8 * mebibyte, hasScreenshots: true)
        let medium = DiagnosticUpload.ImageScale(maxPixel: 1_600, quality: 0.7)
        let small = DiagnosticUpload.ImageScale(maxPixel: 1_200, quality: 0.6)

        #expect(steps == [
            .init(logTailBytes: 8 * mebibyte, screenshotScale: nil),
            .init(logTailBytes: 8 * mebibyte, screenshotScale: medium),
            .init(logTailBytes: 8 * mebibyte, screenshotScale: small),
            .init(logTailBytes: 4 * mebibyte, screenshotScale: small),
            .init(logTailBytes: 2 * mebibyte, screenshotScale: small),
            .init(logTailBytes: 1 * mebibyte, screenshotScale: small),
        ])
    }

    @Test("Steps that would rebuild the same package are left out")
    func skipsStepsWithNothingToShrink() {
        #expect(DiagnosticUpload.attempts(logTailBytes: nil, hasScreenshots: false) == [
            .init(logTailBytes: nil, screenshotScale: nil),
        ])
        let noLog = DiagnosticUpload.attempts(logTailBytes: nil, hasScreenshots: true)
        #expect(noLog.count == 3)
        #expect(noLog.allSatisfy { $0.logTailBytes == nil })

        let appStore = DiagnosticUpload.attempts(logTailBytes: 4 * mebibyte, hasScreenshots: false)
        #expect(appStore.map(\.logTailBytes) == [4 * mebibyte, 2 * mebibyte, 1 * mebibyte])
        #expect(appStore.allSatisfy { $0.screenshotScale == nil })
    }

    @Test("A short message is trimmed, an empty one counts as none")
    func trimsMessage() {
        #expect(DiagnosticUpload.clampedMessage("  hello \n") == "hello")
        #expect(DiagnosticUpload.clampedMessage(" \n\t ") == nil)
    }

    @Test("A long message is cut by UTF-16 length without splitting a character")
    func clampsLongMessageOnCharacterBoundary() {
        let ascii = String(repeating: "a", count: 2_500)
        #expect(DiagnosticUpload.clampedMessage(ascii)?.utf16.count == 2_000)

        // 1999 个 ASCII 后面接一个占两个 UTF-16 码元的 emoji:放不下就整个不要。
        let edge = String(repeating: "b", count: 1_999) + "\u{1F600}" + "tail"
        let clamped = DiagnosticUpload.clampedMessage(edge)
        #expect(clamped == String(repeating: "b", count: 1_999))

        let chinese = String(repeating: "\u{4E2D}", count: 2_001)
        #expect(DiagnosticUpload.clampedMessage(chinese)?.count == 2_000)
    }

    @Test("A cut log starts on a whole line")
    func alignsLogTailToLineStart() {
        let log = Data("partial line\nfirst whole\nsecond\n".utf8)
        #expect(DiagnosticUpload.alignedToLineStart(log) == Data("first whole\nsecond\n".utf8))
        let noNewline = Data("no newline at all".utf8)
        #expect(DiagnosticUpload.alignedToLineStart(noNewline) == noNewline)

        let full = Data("aaaa\nbbbb\ncccc\n".utf8)
        #expect(DiagnosticUpload.logSuffix(full, maxBytes: 100) == full)
        #expect(DiagnosticUpload.logSuffix(full, maxBytes: 7) == Data("cccc\n".utf8))
        // 恰好切在行首:那一行是完整的,不能再被当成半行丢掉。
        #expect(DiagnosticUpload.logSuffix(full, maxBytes: 5) == Data("cccc\n".utf8))
        #expect(DiagnosticUpload.logSuffix(full, maxBytes: 10) == Data("bbbb\ncccc\n".utf8))
        #expect(DiagnosticUpload.logSuffix(full, maxBytes: 0) == Data())
    }

    @Test("Only code-like strings are shown as the upload code")
    func acceptsOnlyCodeLikeStrings() {
        #expect(DiagnosticUpload.isDisplayableCode("PM-7K3QX2"))
        #expect(!DiagnosticUpload.isDisplayableCode(""))
        #expect(!DiagnosticUpload.isDisplayableCode("PM 7K3QX2"))
        #expect(!DiagnosticUpload.isDisplayableCode("<script>"))
        #expect(!DiagnosticUpload.isDisplayableCode(String(repeating: "A", count: 33)))
    }

    @Test("The archive name sorts by UTC time")
    func namesArchive() {
        let date = Date(timeIntervalSince1970: 1_792_224_000) // 2026-10-17 08:00:00 UTC
        #expect(DiagnosticUpload.archiveName(date: date) == "primuse-diagnostics-20261017-080000.zip")
    }

    @Test("Without a retry hint the daily limit resets at the next UTC midnight")
    func resetsAtNextUTCMidnight() {
        let now = Date(timeIntervalSince1970: 1_792_224_000) // 2026-10-17 08:00 UTC
        let midnight = Date(timeIntervalSince1970: 1_792_281_600) // 2026-10-18 00:00 UTC
        #expect(DiagnosticUpload.dailyLimitResetDate(retryAt: nil, now: now) == midnight)
        let hinted = now.addingTimeInterval(3_600)
        #expect(DiagnosticUpload.dailyLimitResetDate(retryAt: hinted, now: now) == hinted)
        #expect(DiagnosticUpload.dailyLimitResetDate(retryAt: now.addingTimeInterval(-5), now: now) == midnight)
    }

    @Test("A usable slot is an https PUT whose Content-Length matches the package")
    func validatesSlot() {
        let headers = ["Content-Type": "application/zip", "Content-Length": "1234"]
        let slot = DiagnosticUpload.validatedSlot(
            uploadID: "u1", code: "PM-ABC123", uploadURL: "https://bucket.example.com/u1?sig=x",
            method: "PUT", headers: headers, byteCount: 1_234, expiresAt: nil
        )
        #expect(slot?.uploadURL.host == "bucket.example.com")
        #expect(slot?.headers == headers)

        #expect(DiagnosticUpload.validatedSlot(
            uploadID: "u1", code: "PM-ABC123", uploadURL: "http://bucket.example.com/u1",
            method: "PUT", headers: headers, byteCount: 1_234, expiresAt: nil
        ) == nil)
        #expect(DiagnosticUpload.validatedSlot(
            uploadID: "u1", code: "PM-ABC123", uploadURL: "https://bucket.example.com/u1",
            method: "POST", headers: headers, byteCount: 1_234, expiresAt: nil
        ) == nil)
        #expect(DiagnosticUpload.validatedSlot(
            uploadID: "u1", code: "PM-ABC123", uploadURL: "https://bucket.example.com/u1",
            method: "put", headers: ["content-length": "999"], byteCount: 1_234, expiresAt: nil
        ) == nil)
        #expect(DiagnosticUpload.validatedSlot(
            uploadID: "", code: "PM-ABC123", uploadURL: "https://bucket.example.com/u1",
            method: "PUT", headers: [:], byteCount: 1_234, expiresAt: nil
        ) == nil)
        #expect(DiagnosticUpload.validatedSlot(
            uploadID: "u1", code: "PM ABC", uploadURL: "https://bucket.example.com/u1",
            method: "PUT", headers: [:], byteCount: 1_234, expiresAt: nil
        ) == nil)
    }

    @Test("The request body uses the relay's snake_case keys and drops an empty message")
    func encodesRequest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = DiagnosticUpload.Request(
            byteCount: 2_048, appVersion: "1.9.8", build: "120", platform: "iOS",
            osVersion: "26.1", deviceModel: "iPhone17,1",
            contents: [.reports, .log], message: "   "
        )
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)
        #expect(json == #"{"app_version":"1.9.8","build":"120","byte_count":2048,"contents":["reports","log"],"device_model":"iPhone17,1","os_version":"26.1","platform":"iOS"}"#)

        let withMessage = DiagnosticUpload.Request(
            byteCount: 1, appVersion: "1", build: "1", platform: "macOS",
            osVersion: "15.5", deviceModel: "Mac14,2", contents: [.message], message: " hi "
        )
        #expect(withMessage.message == "hi")
        let encoded = String(decoding: try encoder.encode(withMessage), as: UTF8.self)
        #expect(encoded.contains(#""message":"hi""#))
    }

    @Test("Relay error codes map to the cases the UI explains")
    func mapsRelayErrors() {
        let later = Date(timeIntervalSince1970: 1_000)
        #expect(DiagnosticUpload.failure(statusCode: 413, code: "diagnostics_too_large", retryAt: nil) == .tooLarge)
        #expect(DiagnosticUpload.failure(statusCode: 413, code: "http_413", retryAt: nil) == .tooLarge)
        #expect(DiagnosticUpload.failure(statusCode: 429, code: "diagnostics_daily_limit", retryAt: later)
            == .dailyLimit(retryAt: later))
        #expect(DiagnosticUpload.failure(statusCode: 503, code: "diagnostics_unavailable", retryAt: nil) == .unavailable)
        // 老版本中转没有这条路由,也不认 diagnostics 这个挑战用途。
        #expect(DiagnosticUpload.failure(statusCode: 404, code: "route_not_found", retryAt: nil) == .unavailable)
        #expect(DiagnosticUpload.failure(statusCode: 404, code: "http_404", retryAt: nil) == .unavailable)
        #expect(DiagnosticUpload.failure(statusCode: 400, code: "unsupported_purpose", retryAt: nil) == .unavailable)
        // 通用限流不是「今天的次数用完了」。
        #expect(DiagnosticUpload.failure(statusCode: 429, code: "rate_limited", retryAt: later)
            == .other(code: "rate_limited"))
        #expect(DiagnosticUpload.failure(statusCode: 409, code: "diagnostics_upload_missing", retryAt: nil)
            == .other(code: "diagnostics_upload_missing"))
        // 确认时找不到这次上传,不是「服务不可用」。
        #expect(DiagnosticUpload.failure(statusCode: 404, code: "diagnostics_upload_not_found", retryAt: nil)
            == .other(code: "diagnostics_upload_not_found"))
        #expect(DiagnosticUpload.failure(statusCode: 502, code: "diagnostics_storage_error", retryAt: nil)
            == .other(code: "diagnostics_storage_error"))
        #expect(DiagnosticUpload.failure(statusCode: 400, code: "invalid_request", retryAt: nil)
            == .other(code: "invalid_request"))
    }

    @Test("A failed PUT is retried on the same slot only for transient errors and while it is still valid")
    func retriesTransferOnTheSameSlot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = now.addingTimeInterval(900)
        #expect(DiagnosticUpload.canRetryTransfer(after: .network, attemptsMade: 1, expiresAt: fresh, now: now))
        #expect(DiagnosticUpload.canRetryTransfer(
            after: .other(code: "storage_http_503"), attemptsMade: 2, expiresAt: fresh, now: now
        ))
        #expect(DiagnosticUpload.canRetryTransfer(after: .network, attemptsMade: 1, expiresAt: nil, now: now))
        // 次数用完、快过期、签名被拒都不再试。
        #expect(!DiagnosticUpload.canRetryTransfer(after: .network, attemptsMade: 3, expiresAt: fresh, now: now))
        #expect(!DiagnosticUpload.canRetryTransfer(
            after: .network, attemptsMade: 1, expiresAt: now.addingTimeInterval(30), now: now
        ))
        #expect(!DiagnosticUpload.canRetryTransfer(
            after: .other(code: "storage_http_403"), attemptsMade: 1, expiresAt: fresh, now: now
        ))
        #expect(DiagnosticUpload.retryDelay(afterAttempt: 1) == 1)
        #expect(DiagnosticUpload.retryDelay(afterAttempt: 2) == 3)
        #expect(DiagnosticUpload.retryDelay(afterAttempt: 7) == 5)
    }

    @Test("Completion re-uploads a missing object, retries transient errors, and gives up on the rest")
    func recoversCompletion() {
        #expect(DiagnosticUpload.completionRecovery(after: .other(code: "diagnostics_upload_missing")) == .reupload)
        #expect(DiagnosticUpload.completionRecovery(after: .other(code: "diagnostics_storage_error")) == .retry)
        #expect(DiagnosticUpload.completionRecovery(after: .network) == .retry)
        #expect(DiagnosticUpload.completionRecovery(after: .other(code: "diagnostics_upload_mismatch")) == .none)
        #expect(DiagnosticUpload.completionRecovery(after: .other(code: "diagnostics_upload_not_found")) == .none)
        #expect(DiagnosticUpload.completionRecovery(after: .unavailable) == .none)
    }
}
