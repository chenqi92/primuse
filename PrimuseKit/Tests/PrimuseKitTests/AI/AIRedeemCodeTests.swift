import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI redeem codes")
struct AIRedeemCodeTests {
    @Test("Codes are normalized the way the relay compares them")
    func normalizesCodes() {
        #expect(AIRedeemCode.normalized("PRM-7K2Q-9XAB-C3DE") == "7K2Q9XABC3DE")
        #expect(AIRedeemCode.normalized("prm 7k2q 9xab c3de") == "7K2Q9XABC3DE")
        #expect(AIRedeemCode.normalized("  7K2Q-9XAB-C3DE\n") == "7K2Q9XABC3DE")
        // Full-width characters and other dash shapes typed on CJK keyboards.
        #expect(AIRedeemCode.normalized("ＰＲＭ－７Ｋ２Ｑ－９ＸＡＢ－Ｃ３ＤＥ") == "7K2Q9XABC3DE")
        #expect(AIRedeemCode.normalized("PRM–7K2Q—9XAB‐C3DE") == "7K2Q9XABC3DE")
        // I and L read as 1, O as 0.
        #expect(AIRedeemCode.normalized("PRM-IK2Q-9XAB-C3DO") == "1K2Q9XABC3D0")
        #expect(AIRedeemCode.normalized("PRM-LK2Q-9XAB-C3DE") == "1K2Q9XABC3DE")
    }

    @Test("A body that itself starts with PRM keeps those letters")
    func keepsBodyStartingWithPrefixLetters() {
        #expect(AIRedeemCode.normalized("PRMK-2Q9X-ABC3") == "PRMK2Q9XABC3")
        #expect(AIRedeemCode.normalized("PRM-PRMK-2Q9X-ABC3") == "PRMK2Q9XABC3")
    }

    @Test("Anything that is not a 12-character Crockford body is rejected")
    func rejectsMalformedCodes() {
        #expect(AIRedeemCode.normalized("") == nil)
        #expect(AIRedeemCode.normalized("PRM-7K2Q-9XAB") == nil)
        #expect(AIRedeemCode.normalized("PRM-7K2Q-9XAB-C3DE-1") == nil)
        // U is not in the Crockford alphabet.
        #expect(AIRedeemCode.normalized("PRM-UK2Q-9XAB-C3DE") == nil)
        #expect(AIRedeemCode.normalized("兑换码7K2Q9XABC3DE") == "7K2Q9XABC3DE")
        #expect(AIRedeemCode.normalized("PRM-7K2Q-9XAB-C3D!") == nil)
    }

    @Test("Codes are shown and sent in groups of four after the prefix")
    func formatsCodes() {
        #expect(AIRedeemCode.formatted("7K2Q9XABC3DE") == "PRM-7K2Q-9XAB-C3DE")
        #expect(AIRedeemCode.Request(body: "7K2Q9XABC3DE").code == "PRM-7K2Q-9XAB-C3DE")
        let body = AIRedeemCode.normalized(AIRedeemCode.formatted("1K2Q9XABC3D0"))
        #expect(body == "1K2Q9XABC3D0")
    }

    @Test("The field keeps typing tidy without moving the cursor around")
    func cleansEditingText() {
        #expect(AIRedeemCode.editingText("prm-7k2q 9x") == "PRM-7K2Q 9X")
        #expect(AIRedeemCode.editingText("ｐｒｍ－７ｋ") == "PRM-7K")
        #expect(AIRedeemCode.editingText("PRM_7K2Q/9XAB") == "PRM7K2Q9XAB")
        #expect(AIRedeemCode.editingText(String(repeating: "A", count: 40)).count == AIRedeemCode.maximumInputLength)
    }

    @Test("Redemption results need a plan; names and subjects fall back sensibly")
    func validatesRedemption() {
        let expires = Date(timeIntervalSince1970: 1_799_592_000)
        #expect(AIRedeemCode.validatedRedemption(
            planID: "pro", planName: "Pro", subjectType: "account", startsAt: nil, expiresAt: expires
        ) == AIRedeemCode.Redemption(planID: "pro", planName: "Pro", subject: .account, startsAt: nil, expiresAt: expires))
        #expect(AIRedeemCode.validatedRedemption(
            planID: "plus", planName: "  ", subjectType: "installation", startsAt: nil, expiresAt: nil
        )?.planName == "plus")
        #expect(AIRedeemCode.validatedRedemption(
            planID: "plus", planName: "Plus", subjectType: "household", startsAt: nil, expiresAt: nil
        )?.subject == .installation)
        #expect(AIRedeemCode.validatedRedemption(
            planID: " ", planName: "Pro", subjectType: "account", startsAt: nil, expiresAt: nil
        ) == nil)
        #expect(AIRedeemCode.validatedRedemption(
            planID: nil, planName: "Pro", subjectType: "account", startsAt: nil, expiresAt: nil
        ) == nil)
    }

    @Test("Relay error codes map to what the screen explains")
    func mapsFailures() {
        let retry = Date(timeIntervalSince1970: 1_797_000_000)
        #expect(AIRedeemCode.failure(statusCode: 404, code: "redeem_code_invalid", retryAt: nil) == .notFound)
        #expect(AIRedeemCode.failure(statusCode: 409, code: "redeem_code_redeemed", retryAt: nil) == .alreadyRedeemed)
        #expect(AIRedeemCode.failure(statusCode: 410, code: "redeem_code_expired", retryAt: nil) == .expired)
        #expect(AIRedeemCode.failure(statusCode: 410, code: "redeem_code_revoked", retryAt: nil) == .revoked)
        #expect(AIRedeemCode.failure(statusCode: 429, code: "redeem_rate_limited", retryAt: retry) == .rateLimited(retryAt: retry))
        #expect(AIRedeemCode.failure(statusCode: 400, code: "invalid_request", retryAt: nil) == .malformed)
        // A relay that predates redeem codes.
        #expect(AIRedeemCode.failure(statusCode: 404, code: "route_not_found", retryAt: nil) == .unavailable)
        #expect(AIRedeemCode.failure(statusCode: 400, code: "unsupported_purpose", retryAt: nil) == .unavailable)
        #expect(AIRedeemCode.failure(statusCode: 404, code: "http_404", retryAt: nil) == .unavailable)
        #expect(AIRedeemCode.failure(statusCode: 429, code: "rate_limited", retryAt: retry) == .rateLimited(retryAt: retry))
        #expect(AIRedeemCode.failure(statusCode: 500, code: "redeem_failed", retryAt: nil) == .other(code: "redeem_failed"))
        #expect(AIRedeemCode.failure(statusCode: 503, code: "upstream_unavailable", retryAt: nil) == .other(code: "upstream_unavailable"))
    }

    @Test("Without a retry time the limit lifts at the next UTC midnight")
    func retryDateDefaultsToNextUTCDay() {
        let now = Date(timeIntervalSince1970: 1_797_000_000) // 2026-12-11 14:40 UTC
        #expect(AIRedeemCode.retryDate(retryAt: nil, now: now) == Date(timeIntervalSince1970: 1_797_033_600))
        let later = now.addingTimeInterval(600)
        #expect(AIRedeemCode.retryDate(retryAt: later, now: now) == later)
        #expect(AIRedeemCode.retryDate(retryAt: now.addingTimeInterval(-1), now: now) == Date(timeIntervalSince1970: 1_797_033_600))
    }
}
