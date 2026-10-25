import Foundation
import Testing
@testable import PrimuseKit

@Suite("Palveni diagnostic upload")
struct PalveniDiagnosticUploadTests {
    private let key = "pvk_primuse_0123456789abcdefABCDEF0123456789"

    @Test("Only a real Palveni key from Info.plist counts; empty or unexpanded values keep primuse-ai")
    func readsUploadKey() {
        #expect(PalveniDiagnosticUpload.uploadKey(fromInfoValue: "  \(key)\n") == key)
        #expect(PalveniDiagnosticUpload.uploadKey(fromInfoValue: "") == nil)
        #expect(PalveniDiagnosticUpload.uploadKey(fromInfoValue: "$(PALVENI_UPLOAD_KEY)") == nil)
        #expect(PalveniDiagnosticUpload.uploadKey(fromInfoValue: nil) == nil)
        #expect(PalveniDiagnosticUpload.uploadKey(fromInfoValue: 42) == nil)
        // Same shape Palveni checks: pvk_, lower-case product, 32 letters and digits.
        #expect(PalveniDiagnosticUpload.isUploadKey("pvk_viozi-tv_0123456789abcdefABCDEF0123456789"))
        #expect(!PalveniDiagnosticUpload.isUploadKey("pvk_Primuse_0123456789abcdefABCDEF0123456789"))
        #expect(!PalveniDiagnosticUpload.isUploadKey("pvk_primuse_0123456789abcdef"))
        #expect(!PalveniDiagnosticUpload.isUploadKey("pk_primuse_0123456789abcdefABCDEF0123456789"))
        #expect(!PalveniDiagnosticUpload.isUploadKey("pvk_primuse_0123456789abcdefABCDEF012345678!"))
    }

    @Test("A stored installation id is kept; a missing or malformed one is replaced and saved")
    func keepsInstallationID() {
        let stored = "6F1C2A9E-0B7D-4A55-9A3B-1D2C3E4F5A6B"
        #expect(PalveniDiagnosticUpload.installationID(stored: stored, make: { "unused-id" }) == (stored, false))
        #expect(PalveniDiagnosticUpload.installationID(stored: nil, make: { "fresh-id-1" }) == ("fresh-id-1", true))
        #expect(PalveniDiagnosticUpload.installationID(stored: "short", make: { "fresh-id-2" }) == ("fresh-id-2", true))
        #expect(PalveniDiagnosticUpload.installationID(stored: "has space in it", make: { "fresh-id-3" }) == ("fresh-id-3", true))
        // A new random UUID always passes the server's rule.
        #expect(PalveniDiagnosticUpload.isInstallationID(UUID().uuidString))
        #expect(!PalveniDiagnosticUpload.isInstallationID(String(repeating: "a", count: 129)))
    }

    @Test("Channel and locale use the values Palveni accepts")
    func channelAndLocale() {
        #expect(PalveniDiagnosticUpload.channel(.appStore) == "app_store")
        #expect(PalveniDiagnosticUpload.channel(.testFlight) == "testflight")
        #expect(PalveniDiagnosticUpload.channel(.development) == "debug")
        #expect(PalveniDiagnosticUpload.locale(preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh-Hans-CN")
        #expect(PalveniDiagnosticUpload.locale(preferredLanguages: ["es-419"]) == "es-419")
        #expect(PalveniDiagnosticUpload.locale(preferredLanguages: []) == nil)
        #expect(PalveniDiagnosticUpload.locale(preferredLanguages: ["x"]) == nil)
    }

    @Test("The upload body is primuse-ai's plus channel and locale")
    func encodesUploadBody() throws {
        let request = DiagnosticUpload.Request(
            byteCount: 1_234, appVersion: "1.12.1", build: "109", platform: "tvOS", osVersion: "26.1",
            deviceModel: "AppleTV14,1", contents: [.reports, .message], message: "  卡住了  "
        )
        let body = PalveniDiagnosticUpload.UploadBody(request: request, channel: .testFlight, locale: "zh-Hans-CN")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["byte_count"] as? Int == 1_234)
        #expect(json["app_version"] as? String == "1.12.1")
        #expect(json["build"] as? String == "109")
        #expect(json["platform"] as? String == "tvOS")
        #expect(json["os_version"] as? String == "26.1")
        #expect(json["device_model"] as? String == "AppleTV14,1")
        #expect(json["contents"] as? [String] == ["reports", "message"])
        #expect(json["message"] as? String == "卡住了")
        #expect(json["channel"] as? String == "testflight")
        #expect(json["locale"] as? String == "zh-Hans-CN")
        let withoutLocale = PalveniDiagnosticUpload.UploadBody(request: request, channel: .appStore, locale: nil)
        let other = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutLocale)) as? [String: Any])
        #expect(other["locale"] == nil)
        #expect(other["channel"] as? String == "app_store")
    }

    @Test("Reads config, slot and code replies in Palveni's envelope")
    func readsReplies() throws {
        #expect(PalveniDiagnosticUpload.isAvailable(configResponse: Data(#"{"data":{"diagnostics_upload":"available","max_bytes":8388608},"request_id":"r"}"#.utf8)))
        #expect(!PalveniDiagnosticUpload.isAvailable(configResponse: Data(#"{"data":{"diagnostics_upload":"unavailable"}}"#.utf8)))
        #expect(!PalveniDiagnosticUpload.isAvailable(configResponse: Data("not json".utf8)))

        let reply = Data(#"""
        {"data":{"upload_id":"dg_0123456789abcdef0123456789abcdef","code":"PM-7K2Q9X",
        "upload_url":"https://palveni.com/api/v1/storage/upload/abc","method":"PUT",
        "headers":{"Content-Type":"application/zip","Content-Length":1234},"expires_at":1792844091},"request_id":"r"}
        """#.utf8)
        let slot = try #require(PalveniDiagnosticUpload.slot(fromUploadResponse: reply, byteCount: 1_234))
        #expect(slot.uploadID == "dg_0123456789abcdef0123456789abcdef")
        #expect(slot.code == "PM-7K2Q9X")
        #expect(slot.uploadURL.absoluteString == "https://palveni.com/api/v1/storage/upload/abc")
        #expect(slot.headers == ["Content-Type": "application/zip", "Content-Length": "1234"])
        #expect(slot.expiresAt == Date(timeIntervalSince1970: 1_792_844_091))
        // The signed length must match the local zip, and only https PUTs are used.
        #expect(PalveniDiagnosticUpload.slot(fromUploadResponse: reply, byteCount: 999) == nil)
        let plainHTTP = Data(#"{"data":{"upload_id":"dg_1","code":"PM-1","upload_url":"http://palveni.com/x","method":"PUT","headers":{}}}"#.utf8)
        #expect(PalveniDiagnosticUpload.slot(fromUploadResponse: plainHTTP, byteCount: 1) == nil)

        #expect(PalveniDiagnosticUpload.code(fromCompleteResponse: Data(#"{"data":{"upload_id":"dg_1","code":"PM-7K2Q9X","status":"received"}}"#.utf8)) == "PM-7K2Q9X")
        #expect(PalveniDiagnosticUpload.code(fromCompleteResponse: Data(#"{"data":{"code":"PM 7K"}}"#.utf8)) == nil)
    }

    @Test("Errors map onto the same failures as primuse-ai; a rejected key means use mail")
    func classifiesErrors() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func failure(_ status: Int, _ body: String, retryAfter: String? = nil) -> DiagnosticUpload.Failure {
            PalveniDiagnosticUpload.failure(statusCode: status, body: Data(body.utf8), retryAfterHeader: retryAfter, now: now)
        }
        #expect(failure(401, #"{"error":{"code":"unauthorized","message":"x"},"request_id":"r"}"#) == .unavailable)
        #expect(failure(413, #"{"error":{"code":"diagnostics_too_large"}}"#) == .tooLarge)
        #expect(failure(429, #"{"error":{"code":"diagnostics_daily_limit","retry_after":3600}}"#)
            == .dailyLimit(retryAt: now.addingTimeInterval(3_600)))
        #expect(failure(429, #"{"error":{"code":"diagnostics_daily_limit"}}"#, retryAfter: "120")
            == .dailyLimit(retryAt: now.addingTimeInterval(120)))
        #expect(failure(409, #"{"error":{"code":"diagnostics_upload_missing"}}"#) == .other(code: "diagnostics_upload_missing"))
        #expect(failure(507, #"{"error":{"code":"diagnostics_storage_full"}}"#) == .other(code: "diagnostics_storage_full"))
        #expect(failure(404, "<html>not found</html>") == .unavailable)
        #expect(failure(502, "") == .other(code: "http_502"))
    }

    @Test("Retry-After also accepts an HTTP date")
    func readsHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = PalveniDiagnosticUpload.retryDate(seconds: nil, header: "Fri, 15 Jan 2027 08:00:00 GMT", now: now)
        #expect(date.map { ISO8601DateFormatter().string(from: $0) } == "2027-01-15T08:00:00Z")
        #expect(PalveniDiagnosticUpload.retryDate(seconds: nil, header: "soon", now: now) == nil)
    }
}
