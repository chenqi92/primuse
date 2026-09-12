import Foundation
import Testing
@testable import PrimuseKit

@Suite("Log redaction policy")
struct LogRedactionPolicyTests {
    @Test("URL query credentials keep their key and lose the value")
    func redactsQueryParameters() {
        // 非凭证参数放在前面: 裸 key=value 规则(规则 5)的值字符类不排除 &,
        // 所以最后一个凭证之后的同行内容会被一并吃掉 —— 这是既有行为。
        let redacted = LogRedactionPolicy.redact(
            "GET https://host/api?page=3&token=abcd1234&code=xyz&state=s1&password=hunter2"
        )
        #expect(redacted.contains("token=<redacted>"))
        #expect(redacted.contains("code=<redacted>"))
        #expect(redacted.contains("state=<redacted>"))
        #expect(redacted.contains("password=<redacted>"))
        #expect(redacted.contains("page=3"))
        #expect(!redacted.contains("abcd1234"))
        #expect(!redacted.contains("hunter2"))
    }

    @Test("Authorization and Cookie headers are redacted")
    func redactsHeaders() {
        let authorization = LogRedactionPolicy.redact("Authorization: Basic dXNlcjpwYXNz")
        #expect(authorization == "Authorization=<redacted>")

        let cookie = LogRedactionPolicy.redact("Cookie: id=abc; sid=def")
        #expect(cookie.hasPrefix("Cookie=<redacted>"))
        #expect(!cookie.contains("def"))
    }

    @Test("Bearer tokens keep the scheme only")
    func redactsBearerTokens() {
        let redacted = LogRedactionPolicy.redact("header Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig tail")
        #expect(redacted == "header Bearer <redacted> tail")
    }

    @Test("JSON body credential keys are redacted")
    func redactsJSONBody() {
        let redacted = LogRedactionPolicy.redact(
            #"{"access_token":"AAA","refresh_token":"BBB","expires_in":3600}"#
        )
        #expect(redacted.contains(#""access_token":"<redacted>""#))
        #expect(redacted.contains(#""refresh_token":"<redacted>""#))
        #expect(redacted.contains(#""expires_in":3600"#))
        #expect(!redacted.contains("AAA"))
        #expect(!redacted.contains("BBB"))
    }

    @Test("Bare credential assignments are redacted")
    func redactsBareAssignments() {
        #expect(LogRedactionPolicy.redact("access_token=AAA") == "access_token=<redacted>")
        #expect(LogRedactionPolicy.redact("client_secret: shhh") == "client_secret=<redacted>")
        #expect(LogRedactionPolicy.redact("api_key = K123") == "api_key=<redacted>")
        // 普通日志里的 state / code 不能被裸规则误伤。
        #expect(LogRedactionPolicy.redact("state: playing") == "state: playing")
        #expect(LogRedactionPolicy.redact("scan code: 42") == "scan code: 42")
    }

    @Test("Messages without credentials are returned unchanged")
    func leavesCleanMessagesAlone() {
        let message = "🎵 Scanned 128 songs from source-1 in 2.4s (album: Blue, artist: Joni)"
        #expect(LogRedactionPolicy.redact(message) == message)
    }

    @Test("Repeated redaction is idempotent")
    func isIdempotent() {
        let message = """
        GET https://host/api?access_token=AAA&page=2 \
        Authorization: Bearer eyJhbGciOi.J9 \
        {"refresh_token":"BBB"} client_secret: CCC
        """
        let once = LogRedactionPolicy.redact(message)
        var repeated = once
        for _ in 0..<5 {
            repeated = LogRedactionPolicy.redact(repeated)
        }
        #expect(repeated == once)
    }
}
