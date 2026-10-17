import Foundation
import Testing
@testable import PrimuseKit

struct GoogleCloudRomanizationTests {
    /// 一个结构完整的假 RSAPrivateKey（只用来测 DER 解包，不是能用的密钥）。
    private static let fakeRSAPrivateKey: [UInt8] = [
        0x30, 0x0D, 0x02, 0x01, 0x00, 0x02, 0x02, 0x00, 0xC5, 0x02, 0x01, 0x03, 0x02, 0x01, 0x07,
    ]

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var bytes = [tag]
        if content.count < 0x80 {
            bytes.append(UInt8(content.count))
        } else if content.count <= 0xFF {
            bytes += [0x81, UInt8(content.count)]
        } else {
            bytes += [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)]
        }
        return bytes + content
    }

    private static func pkcs8(oid: [UInt8] = RSAPrivateKeyDERUnwrapper.rsaEncryptionOID, key: [UInt8] = fakeRSAPrivateKey) -> [UInt8] {
        let algorithm = der(0x30, der(0x06, oid) + [0x05, 0x00])
        return der(0x30, der(0x02, [0x00]) + algorithm + der(0x04, key))
    }

    private static func pem(_ bytes: [UInt8], label: String = "PRIVATE KEY") -> String {
        let base64 = Data(bytes).base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    private static func serviceAccountJSON(
        type: String = "service_account",
        projectID: String = "primuse-test-123",
        tokenURI: String? = "https://oauth2.googleapis.com/token",
        privateKey: String? = nil
    ) -> Data {
        var object: [String: Any] = [
            "type": type,
            "project_id": projectID,
            "private_key_id": "abc123",
            "private_key": privateKey ?? pem(pkcs8()),
            "client_email": "romanize@primuse-test-123.iam.gserviceaccount.com",
            "client_id": "1234567890",
        ]
        if let tokenURI { object["token_uri"] = tokenURI }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: PKCS#8

    @Test func unwrapsPKCS8IntoPKCS1() throws {
        let unwrapped = try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPKCS8: Data(Self.pkcs8()))
        #expect([UInt8](unwrapped) == Self.fakeRSAPrivateKey)
        let fromPEM = try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPEM: Self.pem(Self.pkcs8()))
        #expect([UInt8](fromPEM) == Self.fakeRSAPrivateKey)
    }

    @Test func handlesLongFormLengthsAndEscapedNewlines() throws {
        // 真实的 2048 位密钥长度要用两字节长度表示。
        let bigKey = Self.der(0x30, Self.der(0x02, [0x00]) + Self.der(0x02, [UInt8](repeating: 0x7F, count: 300)))
        let pem = Self.pem(Self.pkcs8(key: bigKey)).replacingOccurrences(of: "\n", with: "\\n")
        let unwrapped = try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPEM: pem)
        #expect([UInt8](unwrapped) == bigKey)
    }

    @Test func acceptsTraditionalPKCS1PEM() throws {
        let unwrapped = try RSAPrivateKeyDERUnwrapper.pkcs1DER(
            fromPEM: Self.pem(Self.fakeRSAPrivateKey, label: "RSA PRIVATE KEY")
        )
        #expect([UInt8](unwrapped) == Self.fakeRSAPrivateKey)
    }

    @Test func rejectsOtherKeyTypesAndBrokenDER() {
        let ecOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        #expect(throws: RSAPrivateKeyDERUnwrapper.UnwrapError.notRSA) {
            try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPKCS8: Data(Self.pkcs8(oid: ecOID)))
        }
        var truncated = Self.pkcs8()
        truncated.removeLast(3)
        #expect(throws: RSAPrivateKeyDERUnwrapper.UnwrapError.invalidDER) {
            try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPKCS8: Data(truncated))
        }
        #expect(throws: RSAPrivateKeyDERUnwrapper.UnwrapError.invalidPEM) {
            try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPEM: "not a key")
        }
    }

    // MARK: 服务账号 JSON

    @Test func parsesServiceAccountJSON() throws {
        let key = try GoogleServiceAccountKey.parse(Self.serviceAccountJSON())
        #expect(key.projectID == "primuse-test-123")
        #expect(key.clientEmail == "romanize@primuse-test-123.iam.gserviceaccount.com")
        #expect(key.privateKeyID == "abc123")
        #expect(key.tokenURI == "https://oauth2.googleapis.com/token")

        let reparsed = try GoogleServiceAccountKey.parse(key.storedJSON())
        #expect(reparsed == key)
    }

    @Test func defaultsTheTokenURIAndRejectsUntrustedOnes() throws {
        let key = try GoogleServiceAccountKey.parse(Self.serviceAccountJSON(tokenURI: nil))
        #expect(key.tokenURI == GoogleServiceAccountKey.defaultTokenURI)
        #expect(throws: GoogleServiceAccountKey.ParseError.invalidTokenURI) {
            try GoogleServiceAccountKey.parse(Self.serviceAccountJSON(tokenURI: "https://example.com/token"))
        }
        #expect(throws: GoogleServiceAccountKey.ParseError.invalidTokenURI) {
            try GoogleServiceAccountKey.parse(Self.serviceAccountJSON(tokenURI: "http://oauth2.googleapis.com/token"))
        }
    }

    @Test func rejectsWrongFiles() {
        #expect(throws: GoogleServiceAccountKey.ParseError.notJSON) {
            try GoogleServiceAccountKey.parse(Data("hello".utf8))
        }
        #expect(throws: GoogleServiceAccountKey.ParseError.notServiceAccount) {
            try GoogleServiceAccountKey.parse(Self.serviceAccountJSON(type: "authorized_user"))
        }
        #expect(throws: GoogleServiceAccountKey.ParseError.invalidPrivateKey) {
            try GoogleServiceAccountKey.parse(Self.serviceAccountJSON(privateKey: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"))
        }
        #expect(throws: GoogleServiceAccountKey.ParseError.invalidProjectID) {
            try GoogleServiceAccountKey.parse(Self.serviceAccountJSON(projectID: "Bad Project/../x"))
        }
    }

    // MARK: 令牌

    @Test func signingInputCarriesTheRequiredClaims() throws {
        let key = try GoogleServiceAccountKey.parse(Self.serviceAccountJSON())
        let input = GoogleServiceAccountJWT.signingInput(for: key, issuedAt: Date(timeIntervalSince1970: 1_700_000_000.7))
        let parts = input.split(separator: ".").map(String.init)
        #expect(parts.count == 2)
        func decoded(_ part: String) throws -> [String: Any] {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            let data = try #require(Data(base64Encoded: base64))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let header = try decoded(parts[0])
        #expect(header["alg"] as? String == "RS256")
        #expect(header["typ"] as? String == "JWT")
        #expect(header["kid"] as? String == "abc123")
        let claims = try decoded(parts[1])
        #expect(claims["iss"] as? String == key.clientEmail)
        #expect(claims["scope"] as? String == "https://www.googleapis.com/auth/cloud-translation")
        #expect(claims["aud"] as? String == "https://oauth2.googleapis.com/token")
        #expect(claims["iat"] as? Int == 1_700_000_000)
        #expect(claims["exp"] as? Int == 1_700_003_600)
        #expect(!input.contains("="))

        let assertion = GoogleServiceAccountJWT.assertion(signingInput: input, signature: Data([0xFB, 0xFF, 0x01]))
        #expect(assertion == input + ".-_8B")
    }

    @Test func tokenRequestBodyIsFormEncoded() {
        let body = String(decoding: GoogleServiceAccountJWT.tokenRequestBody(assertion: "a.b-c_d"), as: UTF8.self)
        #expect(body == "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=a.b-c_d")
    }

    @Test func accessTokenIsReusedUntilFiveMinutesBeforeExpiry() throws {
        let received = Date(timeIntervalSince1970: 1_000)
        let token = try GoogleAccessToken.decode(
            Data(#"{"access_token":"ya29.token","expires_in":3599,"token_type":"Bearer"}"#.utf8),
            receivedAt: received
        )
        #expect(token.value == "ya29.token")
        #expect(token.expiresAt == received.addingTimeInterval(3599))
        #expect(token.isUsable(at: received.addingTimeInterval(3000)))
        #expect(!token.isUsable(at: received.addingTimeInterval(3300)))
        #expect(throws: GoogleAccessToken.DecodeError.invalidResponse) {
            try GoogleAccessToken.decode(Data(#"{"error":"invalid_grant"}"#.utf8), receivedAt: received)
        }
    }

    // MARK: romanizeText

    @Test func requestAndResponseKeepTheLineOrder() throws {
        let url = try #require(GoogleCloudRomanizeText.endpoint(projectID: "primuse-test-123"))
        #expect(url.absoluteString
            == "https://translation.googleapis.com/v3/projects/primuse-test-123/locations/global:romanizeText")
        #expect(GoogleCloudRomanizeText.endpoint(projectID: "../evil") == nil)

        let body = GoogleCloudRomanizeText.requestBody(sourceLanguageCode: "ja-JP", contents: ["君の名は", "夢"])
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["source_language_code"] as? String == "ja")
        #expect(object["contents"] as? [String] == ["君の名は", "夢"])

        let response = Data(#"{"romanizations":[{"romanizedText":"kimi no na wa","detectedLanguageCode":"ja"},{"romanizedText":"yume"}]}"#.utf8)
        #expect(try GoogleCloudRomanizeText.decodeResponse(response, expectedCount: 2) == ["kimi no na wa", "yume"])
        #expect(throws: GoogleCloudRomanizeText.DecodeError.countMismatch(expected: 3, actual: 2)) {
            try GoogleCloudRomanizeText.decodeResponse(response, expectedCount: 3)
        }
    }

    @Test func supportedLanguagesExcludeKoreanAndChinese() {
        #expect(GoogleCloudRomanizeText.supports(languageCode: "ja"))
        #expect(GoogleCloudRomanizeText.supports(languageCode: "ru"))
        #expect(GoogleCloudRomanizeText.supports(languageCode: "uk"))
        #expect(!GoogleCloudRomanizeText.supports(languageCode: "ko"))
        #expect(!GoogleCloudRomanizeText.supports(languageCode: "zh-Hans"))
        #expect(!GoogleCloudRomanizeText.supports(languageCode: "el"))
    }

    @Test func batchesRespectLineAndCharacterLimits() {
        let lines = Array(repeating: "あ", count: 120)
        #expect(GoogleCloudRomanizeText.batches(lines) == [0..<50, 50..<100, 100..<120])

        let long = [String(repeating: "あ", count: 3_000), String(repeating: "い", count: 2_500), "う"]
        #expect(GoogleCloudRomanizeText.batches(long) == [0..<1, 1..<3])

        let huge = [String(repeating: "あ", count: 6_000), "い"]
        #expect(GoogleCloudRomanizeText.batches(huge) == [0..<1, 1..<2])
        #expect(GoogleCloudRomanizeText.batches([]).isEmpty)
    }

    @Test func errorSummariesNameTheReason() {
        let forbidden = GoogleCloudErrorSummary.parse(
            statusCode: 403,
            body: Data(#"{"error":{"code":403,"message":"Cloud Translation API has not been used in project 1 before or it is disabled.","status":"PERMISSION_DENIED"}}"#.utf8)
        )
        #expect(forbidden.kind == .permissionDenied)
        #expect(forbidden.message?.hasPrefix("Cloud Translation API") == true)

        let grant = GoogleCloudErrorSummary.parse(
            statusCode: 400,
            body: Data(#"{"error":"invalid_grant","error_description":"Invalid JWT Signature."}"#.utf8)
        )
        #expect(grant.kind == .unauthorized)
        #expect(grant.message == "Invalid JWT Signature.")

        #expect(GoogleCloudErrorSummary.parse(statusCode: 429, body: Data()).kind == .quotaExceeded)
        #expect(GoogleCloudErrorSummary.parse(statusCode: 503, body: Data()).kind == .serverError)
    }

    // MARK: 自己的智能服务

    @Test func aiExchangeRequiresEveryLine() throws {
        let lines = [
            LyricRomanizationAIExchange.Line(id: "l0", text: "君の名は"),
            LyricRomanizationAIExchange.Line(id: "l1", text: "夢"),
        ]
        let payload = try #require(LyricRomanizationAIExchange.payload(lines: lines, sourceLanguageCode: "ja"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(object["source_language_code"] as? String == "ja")
        #expect((object["lines"] as? [[String: String]])?.map { $0["id"] } == ["l0", "l1"])

        let allowed: Set<String> = ["l0", "l1"]
        let complete = """
        Here you go: {"lines":[{"id":"l0","romanized_text":"kimi no na wa"},{"id":"l1","romanized_text":" yume "}]}
        """
        #expect(try LyricRomanizationAIExchange.decode(complete, allowedIDs: allowed)
            == ["l0": "kimi no na wa", "l1": "yume"])

        let partial = #"{"lines":[{"id":"l0","romanized_text":"kimi no na wa"},{"id":"zz","romanized_text":"x"}]}"#
        #expect(throws: LyricRomanizationAIExchange.DecodeError.incomplete(expected: 2, actual: 1)) {
            try LyricRomanizationAIExchange.decode(partial, allowedIDs: allowed)
        }
        #expect(throws: LyricRomanizationAIExchange.DecodeError.invalidResponse) {
            try LyricRomanizationAIExchange.decode("no json", allowedIDs: allowed)
        }
        #expect(LyricRomanizationAIExchange.instructions.contains("never translation"))
    }
}
