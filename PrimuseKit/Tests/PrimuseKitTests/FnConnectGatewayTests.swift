import CryptoKit
import Foundation
import Security
import Testing
@testable import PrimuseKit

@Suite("FN Connect Gateway")
struct FnConnectGatewayTests {

    // MARK: - Domain Parsing & Bypass

    @Test("Parses subdomain and root FN Connect hosts across all official suffixes")
    func parsesOfficialDomains() {
        let navidrome = FnConnectGatewayAddress.parseHost("navidrome.program.fnos.net")
        #expect(navidrome?.fnID == "program")
        #expect(navidrome?.suffix == "fnos.net")
        #expect(navidrome?.gatewayHost == "program.fnos.net")
        #expect(navidrome?.serviceLabel == "navidrome")
        #expect(navidrome?.isSubdomainProxy == true)

        let abs = FnConnectGatewayAddress.parseHost("AUDIOBOOKSHELF.My-Nas01.5DDD.COM.")
        #expect(abs?.fnID == "my-nas01")
        #expect(abs?.suffix == "5ddd.com")
        #expect(abs?.gatewayHost == "my-nas01.5ddd.com")
        #expect(abs?.serviceLabel == "audiobookshelf")
        #expect(abs?.isSubdomainProxy == true)

        let trzz = FnConnectGatewayAddress.parseHost("jellyfin.homebox99.trzznas.com")
        #expect(trzz?.fnID == "homebox99")
        #expect(trzz?.gatewayHost == "homebox99.trzznas.com")

        let root = FnConnectGatewayAddress.parseHost("program.fnos.net")
        #expect(root?.fnID == "program")
        #expect(root?.serviceLabel == nil)
        #expect(root?.isSubdomainProxy == false)
    }

    @Test("Rejects non-FN-Connect hosts, short reserved labels, and IP-style labels")
    func rejectsInvalidHosts() {
        #expect(FnConnectGatewayAddress.parseHost("5ddd.com") == nil)
        #expect(FnConnectGatewayAddress.parseHost("fnos.net") == nil)
        #expect(FnConnectGatewayAddress.parseHost("www.fnos.net") == nil)
        #expect(FnConnectGatewayAddress.parseHost("api.5ddd.com") == nil)
        #expect(FnConnectGatewayAddress.parseHost("192-168-1-10.fnos.net") == nil)
        #expect(FnConnectGatewayAddress.parseHost("abs.192-168-1-10.5ddd.com") == nil)
        #expect(FnConnectGatewayAddress.parseHost("music.example.com") == nil)
    }

    @Test("Bypasses Feiniu Music API, gateway control endpoints, and cleartext HTTP")
    func bypassesControlAndFnMusicPaths() {
        #expect(FnConnectGatewayAddress.interceptedAddress(for: URL(string: "https://navidrome.program.fnos.net/rest/ping.view")!) != nil)
        #expect(FnConnectGatewayAddress.interceptedAddress(for: URL(string: "https://program.fnos.net/app/audiobookshelf/api/items")!) != nil)
        #expect(FnConnectGatewayAddress.interceptedAddress(for: URL(string: "http://navidrome.program.fnos.net/rest/ping.view")!) == nil)
        #expect(FnConnectGatewayAddress.interceptedAddress(for: URL(string: "https://program.fnos.net/music/api/v1/sys/config")!) == nil)
        #expect(FnConnectGatewayAddress.interceptedAddress(for: URL(string: "https://program.fnos.net/access_code_verify")!) == nil)
        #expect(FnConnectGatewayAddress.interceptedAddress(for: URL(string: "https://program.fnos.net/websocket?type=main")!) == nil)
        #expect(FnConnectGatewayAddress.interceptedAddress(for: URL(string: "https://program.fnos.net/trimcon/info")!) == nil)
    }

    // MARK: - Rejection Detection

    @Test("Detects FN Connect 403 HTML, access code challenge, and login redirects without false positives")
    func detectsGatewayRejections() {
        let url = URL(string: "https://navidrome.program.fnos.net/rest/ping.view")!

        let html403 = HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        let htmlBody = Data("<html><title>FN Connect 访问提示</title><p>FN Connect 暂无权限访问该服务</p></html>".utf8)
        #expect(FnConnectGatewayAddress.gatewayRejection(for: url, response: html403, bodyPrefix: htmlBody) == .sessionRejected)

        // Third-party JSON 403 must never be treated as a gateway rejection.
        let json403 = HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/json"]
        )!
        let jsonBody = Data("{\"error\":\"Forbidden\"}".utf8)
        #expect(FnConnectGatewayAddress.gatewayRejection(for: url, response: json403, bodyPrefix: jsonBody) == nil)

        // Access code challenge header only triggers on 401/403/429 (fnOS also emits it on 204 success).
        let code401 = HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: "HTTP/2",
            headerFields: ["X-Trim-Safe-Code-Challenge": "1"]
        )!
        #expect(FnConnectGatewayAddress.gatewayRejection(for: url, response: code401, bodyPrefix: nil) == .accessCodeRequired)

        let ok204 = HTTPURLResponse(
            url: url,
            statusCode: 204,
            httpVersion: "HTTP/2",
            headerFields: ["X-Trim-Safe-Code-Challenge": "1"]
        )!
        #expect(FnConnectGatewayAddress.gatewayRejection(for: url, response: ok204, bodyPrefix: nil) == nil)

        // Redirect to gateway login page.
        let redirect302 = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/2",
            headerFields: ["Location": "https://program.fnos.net/login"]
        )!
        #expect(FnConnectGatewayAddress.gatewayRejection(for: url, response: redirect302, bodyPrefix: nil) == .sessionRejected)
    }

    // MARK: - Candidate Planning & Model Compatibility

    @Test("Plans HTTPS 443 only for automatic FN Connect third-party hosts")
    func candidatePlannerShortCircuitsGatewayHosts() {
        let parsed = SourceAddressInputPolicy.ParsedEndpointInput(
            host: "audiobookshelf.program.fnos.net",
            hostClass: .public,
            isIPLiteral: false
        )
        let candidates = SourceConnectionCandidatePlanner.candidates(
            for: parsed,
            sourceType: .audiobookshelf
        )
        #expect(candidates == [.init(useSsl: true, port: 443, origin: .schemeDefaultPort)])

        // Explicit custom port is still respected.
        let explicitPort = SourceAddressInputPolicy.ParsedEndpointInput(
            explicitScheme: "https",
            host: "audiobookshelf.program.fnos.net",
            explicitPort: 8443,
            hostClass: .public,
            isIPLiteral: false
        )
        let explicitCandidates = SourceConnectionCandidatePlanner.candidates(
            for: explicitPort,
            sourceType: .audiobookshelf
        )
        #expect(explicitCandidates == [.init(useSsl: true, port: 8443, origin: .explicitAddress)])
    }

    @Test("MusicSource decodes legacy records without fnConnectGateway and treats gateway change as content-unchanged")
    func musicSourceCompatibilityAndScanScope() throws {
        var source = MusicSource(
            id: "abs-1",
            name: "Audiobooks",
            type: .audiobookshelf,
            host: "audiobookshelf.program.fnos.net",
            port: 443,
            useSsl: true,
            fnConnectGateway: FnConnectGatewayBinding(fnID: "program", username: "chenqi", scope: .shared),
            username: "reader"
        )
        let encoded = try JSONEncoder().encode(source)
        var jsonObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        jsonObject.removeValue(forKey: "fnConnectGateway")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)
        let decodedLegacy = try JSONDecoder().decode(MusicSource.self, from: legacyData)
        #expect(decodedLegacy.fnConnectGateway == nil)

        var updated = source
        updated.fnConnectGateway = FnConnectGatewayBinding(fnID: "program", username: "other", scope: .dedicated)
        #expect(SourceScanContentScopePolicy.contentUnchanged(previous: source, current: updated))

        source.fnConnectGateway = nil
        #expect(source.fnConnectGatewayAddresses.map(\.fnID) == ["program"])
    }

    // MARK: - Crypto & Cookie Merging

    @Test("RSA SPKI unwrap, AES-256-CBC, HMAC-SHA256, and cookie merge")
    func cryptoAndCookieMerge() throws {
        let keyPair = try makeTestRSAKeyPair()
        let aesKey = FnConnectGatewayCrypto.randomAESKeyString()
        let iv = FnConnectGatewayCrypto.randomIV()
        #expect(aesKey.utf8.count == 32)
        #expect(iv.count == 16)

        let payload = Data("{\"req\":\"user.login\",\"user\":\"alice\"}".utf8)
        let frame = try FnConnectGatewayCrypto.encryptedEnvelope(
            payloadJSON: payload,
            publicKeyPEM: keyPair.spkiPEM,
            aesKeyString: aesKey,
            iv: iv
        )
        let dict = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: String])
        #expect(dict["req"] == "encrypted")
        let rsaB64 = try #require(dict["rsa"])
        let rsaData = try #require(Data(base64Encoded: rsaB64))
        let decryptedKey = try decryptRSA(rsaData, privateKey: keyPair.privateKey)
        #expect(String(data: decryptedKey, encoding: .utf8) == aesKey)

        let aesB64 = try #require(dict["aes"])
        let aesData = try #require(Data(base64Encoded: aesB64))
        let decryptedPayload = try FnConnectGatewayCrypto.aes256CBCDecrypt(aesData, key: decryptedKey, iv: iv)
        #expect(decryptedPayload == payload)

        // Verify reqID format: 8 hex ts + 16 hex backId + 4 hex seq = 28 chars.
        let reqID = FnConnectGatewayCrypto.makeReqID(backID: "0123456789abcdef", sequence: 7, timestamp: 0x6700_0001)
        #expect(reqID == "670000010123456789abcdef0007")

        // Verify cookie merge preserves third-party cookies while replacing gateway cookies.
        var req = URLRequest(url: URL(string: "https://navidrome.program.fnos.net/rest/ping.view")!)
        req.setValue("JSESSIONID=abc123; entry-token=old; mode=direct", forHTTPHeaderField: "Cookie")
        let updated = FnConnectGatewayProtocol.applyingHeaders(
            ["Cookie": "entry-token=newEntry; fnos-token=newFnos; mode=relay", "x-access-source": "app"],
            to: req
        )
        #expect(updated.value(forHTTPHeaderField: "Cookie") == "JSESSIONID=abc123; entry-token=newEntry; fnos-token=newFnos; mode=relay")
        #expect(updated.value(forHTTPHeaderField: "x-access-source") == "app")
    }

    // MARK: - Full Protocol Flows (Login, 2FA, Silent Refresh, Single-Flight)

    @Test("Authenticates, exchanges entry-token, caches session, and silently refreshes via tokenLogin after 403")
    func loginCacheAndSilentRefreshFlow() async throws {
        let keyPair = try makeTestRSAKeyPair()
        let server = FakeFnGatewayServer(keyPair: keyPair, requires2FA: false)
        let store = makeTestStore(server: server)

        let cred = FnConnectGatewayCredential(fnID: "program", username: "alice", password: "secret", accessCode: "4321")
        await store.configure(credentialResolver: { _, _, _, _ in cred })

        let targetURL = URL(string: "https://navidrome.program.fnos.net/rest/ping.view")!
        let headers1 = try #require(await store.headers(for: targetURL))
        #expect(headers1["Cookie"]?.contains("entry-token=entry-1") == true)
        #expect(headers1["Cookie"]?.contains("fnos-token=tok-1") == true)
        #expect(headers1["Cookie"]?.contains("mode=relay") == true)
        #expect(headers1["x-access-code"] == Data("4321".utf8).base64EncodedString())

        // Second call hits cache without another WebSocket connection.
        let headers2 = try #require(await store.headers(for: targetURL))
        #expect(headers2 == headers1)
        #expect(await server.loginCount == 1)
        #expect(await server.tokenLoginCount == 0)

        // Simulate gateway 403 HTML rejection -> silent refresh via user.tokenLogin + exchangeEntryToken.
        let req = URLRequest(url: targetURL)
        let refreshed = try #require(await store.refreshRequestAfterRejection(req, rejection: .sessionRejected))
        #expect(refreshed.value(forHTTPHeaderField: "Cookie")?.contains("entry-token=entry-2") == true)
        #expect(await server.loginCount == 1)
        #expect(await server.tokenLoginCount == 1)
    }

    @Test("Handles 2FA challenge, invalid OTP retry, and trusted device completion")
    func twoFactorChallengeAndVerifyFlow() async throws {
        let keyPair = try makeTestRSAKeyPair()
        let server = FakeFnGatewayServer(keyPair: keyPair, requires2FA: true, validOTP: "654321")
        let store = makeTestStore(server: server)
        let cred = FnConnectGatewayCredential(fnID: "program", username: "chenqi", password: "secret")

        var capturedChallenge: FnConnectTwoFactorChallenge?
        do {
            _ = try await store.authenticate(gatewayHost: "program.fnos.net", credential: cred)
            Issue.record("Expected twoFactorRequired error")
        } catch FnConnectGatewayError.twoFactorRequired(let challenge) {
            capturedChallenge = challenge
        }

        let challenge = try #require(capturedChallenge)
        #expect(challenge.fnID == "program")
        #expect(challenge.username == "chenqi")

        // Wrong code throws invalidTwoFactorCode and keeps challenge alive.
        await #expect(throws: FnConnectGatewayError.invalidTwoFactorCode) {
            _ = try await store.verifyTwoFactor(challenge: challenge, code: "000000", trustDevice: true)
        }

        // Correct code succeeds and exchanges entry-token.
        let session = try await store.verifyTwoFactor(challenge: challenge, code: "654321", trustDevice: true)
        #expect(session.entryToken == "entry-1")
        #expect(session.token == "tok-2fa-1")
        #expect(await server.lastTrustedDeviceFlag == true)
    }

    @Test("Deduplicates concurrent gateway logins with single-flight")
    func singleFlightConcurrentLogins() async throws {
        let keyPair = try makeTestRSAKeyPair()
        let server = FakeFnGatewayServer(keyPair: keyPair, requires2FA: false, artificialDelayNanoseconds: 40_000_000)
        let store = makeTestStore(server: server)
        let cred = FnConnectGatewayCredential(fnID: "program", username: "alice", password: "secret")
        await store.configure(credentialResolver: { _, _, _, _ in cred })

        let targetURL = URL(string: "https://audiobookshelf.program.fnos.net/api/libraries")!
        try await withThrowingTaskGroup(of: [String: String]?.self) { group in
            for _ in 0..<8 {
                group.addTask { try await store.headers(for: targetURL) }
            }
            for try await headers in group {
                #expect(headers?["Cookie"]?.contains("entry-token=entry-1") == true)
            }
        }
        #expect(await server.loginCount == 1)
    }

    @Test("Surfaces access code requirement when access_code_verify returns 401")
    func accessCodeChallengeError() async throws {
        let keyPair = try makeTestRSAKeyPair()
        let server = FakeFnGatewayServer(keyPair: keyPair, requires2FA: false, requiredAccessCode: "9999")
        let store = makeTestStore(server: server)

        await #expect(throws: FnConnectGatewayError.accessCodeRequired) {
            _ = try await store.authenticate(
                gatewayHost: "program.fnos.net",
                credential: FnConnectGatewayCredential(fnID: "program", username: "alice", password: "secret")
            )
        }

        await #expect(throws: FnConnectGatewayError.accessCodeRejected) {
            _ = try await store.authenticate(
                gatewayHost: "program.fnos.net",
                credential: FnConnectGatewayCredential(fnID: "program", username: "alice", password: "secret", accessCode: "0000")
            )
        }
    }

    // MARK: - Helpers

    private struct TestRSAKeyPair: @unchecked Sendable {
        let privateKey: SecKey
        let spkiPEM: String
    }

    private func makeTestRSAKeyPair() throws -> TestRSAKeyPair {
        var error: Unmanaged<CFError>?
        let privateKey: SecKey
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: false,
            ],
        ]
        if let generated = SecKeyCreateRandomKey(attributes as CFDictionary, &error) {
            privateKey = generated
        } else {
            #if os(macOS)
            let gen = Process()
            gen.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            gen.arguments = ["genrsa", "2048"]
            let genOut = Pipe()
            gen.standardOutput = genOut
            gen.standardError = Pipe()
            try gen.run()
            let pem = try genOut.fileHandleForReading.readToEnd() ?? Data()
            gen.waitUntilExit()

            let conv = Process()
            conv.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            conv.arguments = ["rsa", "-outform", "DER"]
            let convIn = Pipe()
            let convOut = Pipe()
            conv.standardInput = convIn
            conv.standardOutput = convOut
            conv.standardError = Pipe()
            try conv.run()
            try convIn.fileHandleForWriting.write(contentsOf: pem)
            try? convIn.fileHandleForWriting.close()
            let der = try convOut.fileHandleForReading.readToEnd() ?? Data()
            conv.waitUntilExit()

            guard let imported = SecKeyCreateWithData(
                der as CFData,
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                ] as CFDictionary,
                &error
            ) else {
                throw FnConnectGatewayError.invalidResponse
            }
            privateKey = imported
            #else
            throw FnConnectGatewayError.invalidResponse
            #endif
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1Data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw FnConnectGatewayError.invalidResponse
        }
        let spki = wrapPKCS1InSPKI(pkcs1Data)
        let pem = "-----BEGIN PUBLIC KEY-----\n\(spki.base64EncodedString())\n-----END PUBLIC KEY-----"
        return TestRSAKeyPair(privateKey: privateKey, spkiPEM: pem)
    }

    private func wrapPKCS1InSPKI(_ pkcs1: Data) -> Data {
        func derLength(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            if count <= 0xFF { return [0x81, UInt8(count)] }
            return [0x82, UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)]
        }
        func derSeq(_ body: [UInt8]) -> [UInt8] {
            [0x30] + derLength(body.count) + body
        }
        let algID: [UInt8] = [
            0x30, 0x0D,
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ]
        let bitPayload = [UInt8(0x00)] + [UInt8](pkcs1)
        let bitString = [UInt8(0x03)] + derLength(bitPayload.count) + bitPayload
        return Data(derSeq(algID + bitString))
    }

    private func decryptRSA(_ data: Data, privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionPKCS1,
            data as CFData,
            &error
        ) as Data? else {
            throw FnConnectGatewayError.invalidResponse
        }
        return decrypted
    }

    private func makeTestStore(server: FakeFnGatewayServer) -> FnConnectGatewaySessionStore {
        let client = FnConnectGatewayClient(
            timeout: 5,
            dataLoader: { request in
                try await server.handleHTTP(request)
            },
            webSocketFactory: { request in
                await server.openSocket(request)
            }
        )
        return FnConnectGatewaySessionStore(
            client: client,
            deviceIDProvider: { "00112233445566778899aabbccddeeff" }
        )
    }

    private actor FakeFnGatewayServer {
        let keyPair: TestRSAKeyPair
        let requires2FA: Bool
        let validOTP: String
        let requiredAccessCode: String?
        let artificialDelayNanoseconds: UInt64

        let sharedSecret = Data("0123456789abcdef0123456789abcdef".utf8)
        private(set) var loginCount = 0
        private(set) var tokenLoginCount = 0
        private(set) var entryCounter = 0
        private(set) var lastTrustedDeviceFlag: Bool?

        init(
            keyPair: TestRSAKeyPair,
            requires2FA: Bool,
            validOTP: String = "123456",
            requiredAccessCode: String? = nil,
            artificialDelayNanoseconds: UInt64 = 0
        ) {
            self.keyPair = keyPair
            self.requires2FA = requires2FA
            self.validOTP = validOTP
            self.requiredAccessCode = requiredAccessCode
            self.artificialDelayNanoseconds = artificialDelayNanoseconds
        }

        func handleHTTP(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url ?? URL(string: "https://program.fnos.net/access_code_verify")!
            if let requiredAccessCode {
                let expected = Data(requiredAccessCode.utf8).base64EncodedString()
                if request.value(forHTTPHeaderField: "x-access-code") != expected {
                    let resp = HTTPURLResponse(
                        url: url,
                        statusCode: 401,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["X-Trim-Safe-Code-Challenge": "1"]
                    )!
                    return (Data(), resp)
                }
            }
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-Trim-Safe-Code-Challenge": "1"]
            )!
            return (Data(), resp)
        }

        func openSocket(_ request: URLRequest) -> FakeSocket {
            FakeSocket(server: self)
        }

        func handleFrame(_ text: String) async throws -> String {
            if artificialDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: artificialDelayNanoseconds)
            }
            // Signed frame: <44-char base64 HMAC>{json}
            if let brace = text.firstIndex(of: "{"), brace > text.startIndex {
                let sig = String(text[..<brace])
                let jsonText = String(text[brace...])
                let expectedSig = FnConnectGatewayCrypto.hmacSHA256Base64(message: jsonText, secret: sharedSecret)
                guard sig == expectedSig else {
                    return "{\"result\":\"fail\",\"errno\":401}"
                }
                let obj = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any] ?? [:]
                return try await handleSignedRequest(obj)
            }

            let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            let req = obj["req"] as? String ?? ""
            let reqID = obj["reqid"] as? String ?? ""

            switch req {
            case "util.crypto.getRSAPub":
                return encodeJSON([
                    "reqid": reqID,
                    "result": "succ",
                    "pub": keyPair.spkiPEM,
                    "si": "test-si-1",
                ])
            case "util.getSI":
                return encodeJSON([
                    "reqid": reqID,
                    "result": "succ",
                    "si": "test-si-2",
                ])
            case "encrypted":
                let rsaData = Data(base64Encoded: obj["rsa"] as? String ?? "") ?? Data()
                let ivData = Data(base64Encoded: obj["iv"] as? String ?? "") ?? Data()
                let aesData = Data(base64Encoded: obj["aes"] as? String ?? "") ?? Data()
                var cfErr: Unmanaged<CFError>?
                guard let keyData = SecKeyCreateDecryptedData(keyPair.privateKey, .rsaEncryptionPKCS1, rsaData as CFData, &cfErr) as Data? else {
                    return "{\"result\":\"fail\"}"
                }
                let plain = try FnConnectGatewayCrypto.aes256CBCDecrypt(aesData, key: keyData, iv: ivData)
                let inner = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] ?? [:]
                return try await handleEncryptedRequest(inner, aesKey: keyData, iv: ivData)
            default:
                return encodeJSON(["reqid": reqID, "result": "fail"])
            }
        }

        private func handleEncryptedRequest(_ inner: [String: Any], aesKey: Data, iv: Data) async throws -> String {
            let req = inner["req"] as? String ?? ""
            let reqID = inner["reqid"] as? String ?? ""
            let encryptedSecret = try FnConnectGatewayCrypto.aes256CBCEncrypt(sharedSecret, key: aesKey, iv: iv)
                .base64EncodedString()

            switch req {
            case "user.login":
                loginCount += 1
                if requires2FA {
                    return encodeJSON([
                        "reqid": reqID,
                        "result": "succ",
                        "isBindTwofaSecret": 1,
                        "isTrustedDevice": 0,
                        "accessToken": "twofa-access-token",
                    ])
                }
                return encodeJSON([
                    "reqid": reqID,
                    "result": "succ",
                    "token": "tok-\(loginCount)",
                    "longToken": "long-tok-1",
                    "secret": encryptedSecret,
                    "backId": "0000000000000001",
                ])
            case "user.2fa.loginVerify":
                let code = inner["code"] as? String ?? ""
                lastTrustedDeviceFlag = inner["isTrustedDevice"] as? Bool
                guard code == validOTP else {
                    return encodeJSON([
                        "reqid": reqID,
                        "result": "fail",
                        "errno": 135_168,
                        "errmsg": "invalid code",
                    ])
                }
                return encodeJSON([
                    "reqid": reqID,
                    "result": "succ",
                    "token": "tok-2fa-1",
                    "longToken": "long-tok-2fa",
                    "secret": encryptedSecret,
                    "backId": "0000000000000002",
                ])
            default:
                return encodeJSON(["reqid": reqID, "result": "fail"])
            }
        }

        private func handleSignedRequest(_ obj: [String: Any]) async throws -> String {
            let req = obj["req"] as? String ?? ""
            let reqID = obj["reqid"] as? String ?? ""
            switch req {
            case "user.tokenLogin":
                tokenLoginCount += 1
                return encodeJSON([
                    "reqid": reqID,
                    "result": "succ",
                    "token": "tok-refreshed-\(tokenLoginCount)",
                    "longToken": "long-tok-1",
                    "backId": "0000000000000003",
                ])
            case "appcgi.sac.entry.v1.exchangeEntryToken":
                entryCounter += 1
                return encodeJSON([
                    "reqid": reqID,
                    "result": "succ",
                    "data": ["token": "entry-\(entryCounter)"],
                ])
            default:
                return encodeJSON(["reqid": reqID, "result": "fail"])
            }
        }

        private func encodeJSON(_ dict: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    private final class FakeSocket: FnConnectGatewayWebSocketConnection, @unchecked Sendable {
        private let server: FakeFnGatewayServer
        private let lock = NSLock()
        private var responses: [String] = []
        private var closed = false

        init(server: FakeFnGatewayServer) {
            self.server = server
        }

        func send(_ text: String) async throws {
            let isClosed = lock.withLock { closed }
            guard !isClosed else { throw URLError(.networkConnectionLost) }
            let reply = try await server.handleFrame(text)
            lock.withLock { responses.append(reply) }
        }

        func receiveText() async throws -> String {
            let next: String? = lock.withLock {
                guard !closed, !responses.isEmpty else { return nil }
                return responses.removeFirst()
            }
            guard let next else { throw URLError(.networkConnectionLost) }
            return next
        }

        func close() {
            lock.withLock { closed = true }
        }
    }
}
