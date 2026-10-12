import Foundation
import Testing
@testable import PrimuseKit

@Suite("HTTP failure presentation")
struct HTTPFailurePresentationTests {
    @Test("Rate limits retain useful wait text instead of a misleading HTTP status", arguments: [200, 403, 429, 503])
    func explainsRateLimit(status: Int) {
        let failure = HTTPResponseFailure(statusCode: status, retryAfter: 2.2, isRateLimited: status == 200)
        #expect(failure.localizedDescription == PMString("request.rateLimited.wait", 3.0))
        #expect(SourceFailureClassifier.kind(for: failure).identifier == "rateLimited")
        #expect(!SourceFailureClassifier.isActionable(failure))
    }

    @Test("Headerless quota responses still explain rate limiting", arguments: [200, 429])
    func explainsUnknownWait(status: Int) {
        let failure = HTTPResponseFailure(statusCode: status, isRateLimited: status == 200)
        #expect(failure.localizedDescription == PMString("request.rateLimited"))
        #expect(SourceFailureClassifier.kind(for: failure).identifier == "rateLimited")
    }

    @Test("HTTP authentication and server failures retain their source classification")
    func classifiesHTTPFailures() {
        for status in [401, 403] {
            #expect(SourceFailureClassifier.kind(for: HTTPResponseFailure(statusCode: status)) == .authFailed)
        }
        for status in [400, 404, 500, 502, 503] {
            let failure = HTTPResponseFailure(statusCode: status)
            #expect(SourceFailureClassifier.kind(for: failure) == .serverError(status: status))
            #expect(failure.localizedDescription == PMString("ext.tv.playback.httpError", status))
        }
        #expect(SourceFailureClassifier.kind(for: CancellationError()) == .cancelled)
        #expect(SourceFailureClassifier.kind(for: URLError(.serverCertificateUntrusted)) == .certificateRejected)
    }

    @Test("Waits of a minute or more read in larger units instead of seconds")
    func describesLongWaitInLargerUnits() {
        #expect(HTTPResponseFailure(statusCode: 429, retryAfter: 59).localizedDescription
                == PMString("request.rateLimited.wait", 59.0))
        for delay: TimeInterval in [59.2, 3600, 90_061] {
            let remaining = Duration.seconds(ceil(delay)).formatted(.units(
                allowed: [.days, .hours, .minutes], width: .abbreviated,
                maximumUnitCount: 2, fractionalPart: .hide(rounded: .up)
            ))
            #expect(HTTPResponseFailure(statusCode: 429, retryAfter: delay).localizedDescription
                    == PMString("request.rateLimited.after", remaining))
        }
    }

    @Test("Unusable or impractical wait values use a safe generic rate-limit message", arguments: [Double.nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude])
    func safelyFormatsExtremeWait(delay: TimeInterval) {
        let failure = HTTPResponseFailure(statusCode: 429, retryAfter: delay)
        #expect(failure.localizedDescription == PMString("request.rateLimited"))
    }

    @Test("Every supported localization contains the common rate-limit messages")
    func allLocalizationsContainRateLimitText() throws {
        let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es-MX", "pt-BR", "ru", "uk", "pl", "tr", "ar", "hi", "th"]
        for language in languages {
            let path = try #require(Bundle.primuseKit.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in ["request.rateLimited", "request.rateLimited.wait", "request.rateLimited.after"] {
                let value = bundle.localizedString(forKey: key, value: key, table: nil)
                #expect(value != key, "Missing \(language)/\(key)")
                if key.hasSuffix(".wait") {
                    #expect(value.contains("%.0f"))
                    #expect(String(format: value, 3.0).contains("3"))
                }
                if key.hasSuffix(".after") {
                    #expect(String(format: value, "1 hr").contains("1 hr"))
                }
            }
        }
    }
}
