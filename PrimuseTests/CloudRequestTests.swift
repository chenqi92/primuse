import Foundation
import Network
import PrimuseKit
import XCTest
@testable import Primuse

final class CloudRequestTests: XCTestCase {
    func testPan115PastedRefreshTokenNeedsNoAppCredentialsAndKeepsRotation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(
            #"{"state":true,"data":{"access_token":"fresh","refresh_token":"rotated","expires_in":"7200"}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let started = Date()
        let result = try await U115Source(sourceID: fixture.id, session: session)
            .exchangeRefreshToken("  refresh+token/&=value\n")
        XCTAssertEqual(result.accessToken, "fresh")
        XCTAssertEqual(result.refreshToken, "rotated")
        XCTAssertGreaterThan(try XCTUnwrap(result.expiresAt).timeIntervalSince(started), 7190)
        let request = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(request.url?.absoluteString, "https://passportapi.115.com/open/refreshToken")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(components.queryItems, [.init(name: "refresh_token", value: "refresh+token/&=value")])
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testPan115RefreshKeepsOriginalTokenWhenProviderOmitsRotation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(
            #"{"state":1,"data":{"access_token":"fresh"}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let result = try await U115Source(sourceID: fixture.id, session: session).exchangeRefreshToken("original")
        XCTAssertEqual(result.refreshToken, "original")
        XCTAssertFalse(result.isExpired)
    }

    func testPan115RejectsEmptyTokenWithoutSending() async throws {
        let fixture = CloudHTTPFixture(responses: [])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            _ = try await U115Source(sourceID: fixture.id, session: session).exchangeRefreshToken(" \n ")
            XCTFail("Empty token accepted")
        } catch CloudDriveError.notAuthenticated {}
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testPan115RejectedImportPreservesExistingCredentials() async throws {
        for response in [
            #"{"state":false,"code":40140116,"data":{"access_token":"rejected"}}"#,
            #"{"state":true,"data":{"access_token":" "}}"#,
            #"{"state":true,"data":{}}"#
        ] {
            let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(response.utf8))])
            let session = fixture.session()
            let manager = CloudTokenManager(sourceID: fixture.id)
            defer {
                session.invalidateAndCancel(); fixture.remove()
                _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id)
            }
            let saved = await manager.saveTokens(.init(accessToken: "existing", refreshToken: "existing-refresh"))
            XCTAssertTrue(saved)
            do {
                _ = try await U115Source(sourceID: fixture.id, session: session).exchangeRefreshToken("invalid")
                XCTFail("Rejected token accepted")
            } catch is CloudDriveError {}
            let tokens = await manager.getTokens()
            XCTAssertEqual(tokens?.accessToken, "existing")
            XCTAssertEqual(tokens?.refreshToken, "existing-refresh")
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testPan115ExpiredDirectLoginRefreshesAndPersistsWithoutClientID() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(
            #"{"state":true,"data":{"access_token":"fresh","refresh_token":"rotated","expires_in":7200}}"#.utf8))])
        let session = fixture.session()
        let manager = CloudTokenManager(sourceID: fixture.id)
        defer {
            session.invalidateAndCancel(); fixture.remove()
            _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id)
        }
        let saved = await manager.saveTokens(.init(accessToken: "expired", refreshToken: "original", expiresAt: .distantPast))
        XCTAssertTrue(saved)
        let credentials = await manager.getAppCredentials()
        XCTAssertNil(credentials)
        let connector = U115Source(sourceID: fixture.id, session: session)
        try await connector.connect()
        try await connector.connect()
        let tokens = await manager.getTokens()
        XCTAssertEqual(tokens?.accessToken, "fresh")
        XCTAssertEqual(tokens?.refreshToken, "rotated")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testPan115SuccessBodyWithEmptyErrorKeepsTheRotatedTokens() async throws {
        // 真机上粘贴 OpenList 给的 refresh token 报「刷新令牌失败：HTTP 200」:成功体里的 `"error":""` 被当成了失败,
        // 服务端其实已经换发了新的一对。
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(
            #"{"state":true,"code":0,"message":"","error":"","errno":0,"data":{"access_token":"fresh","refresh_token":"rotated","expires_in":7200}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let result = try await U115Source(sourceID: fixture.id, session: session).exchangeRefreshToken("pasted")
        XCTAssertEqual(result.accessToken, "fresh")
        XCTAssertEqual(result.refreshToken, "rotated")
    }

    func testPan115ConsumedRefreshTokenAsksForANewOne() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(
            #"{"state":false,"code":40140120,"message":"refresh_token 校验失败","error":"refresh_token 校验失败","errno":40140120,"data":[]}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            _ = try await U115Source(sourceID: fixture.id, session: session).exchangeRefreshToken("consumed")
            XCTFail("Consumed refresh token accepted")
        } catch CloudDriveError.tokenRefreshFailed(let reason) {
            XCTAssertEqual(reason, U115Source.invalidRefreshTokenReason)
        }
    }

    func testPan115RefreshRateLimitStaysRetryable() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(
            #"{"state":false,"code":40140117,"message":"access_token 刷新太频繁","data":[]}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            _ = try await U115Source(sourceID: fixture.id, session: session).exchangeRefreshToken("valid")
            XCTFail("Rate-limited refresh accepted")
        } catch let failure as HTTPResponseFailure {
            XCTAssertTrue(failure.isRateLimited)
        }
    }

    func testTokenRefreshJSONOnlyTreatsNonEmptyErrorsAsFailure() throws {
        let ok = HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!
        let json = try CloudDriveHelper.tokenRefreshJSON(
            data: Data(#"{"error":" ","access_token":"fresh"}"#.utf8), response: ok)
        XCTAssertEqual(json["access_token"] as? String, "fresh")
        XCTAssertThrowsError(try CloudDriveHelper.tokenRefreshJSON(
            data: Data(#"{"error":"invalid_grant"}"#.utf8), response: ok))
    }

    func testPan115BodyTokenErrorRefreshesAndFailedListingNeverReadsAsEmpty() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200)], responder: { request, _ in
            if request.url?.host == "passportapi.115.com" {
                return .init(status: 200, body: Data(
                    #"{"state":true,"error":"","data":{"access_token":"fresh","refresh_token":"rotated","expires_in":7200}}"#.utf8))
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" else {
                return .init(status: 200, body: Data(#"{"state":false,"code":40140125,"message":"access_token 无效","data":[]}"#.utf8))
            }
            if request.url?.query?.contains("cid=broken") == true {
                return .init(status: 200, body: Data(#"{"state":false,"code":20130827,"message":"系统繁忙","data":[]}"#.utf8))
            }
            return .init(status: 200, body: Data(
                #"{"state":true,"count":1,"data":[{"fn":"a.flac","fc":"1","fs":"10","pc":"pc1","fid":"77","upt":"1700000000"}]}"#.utf8))
        })
        let session = fixture.session()
        let manager = CloudTokenManager(sourceID: fixture.id)
        defer {
            session.invalidateAndCancel(); fixture.remove()
            _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id)
        }
        let saved = await manager.saveTokens(.init(accessToken: "old", refreshToken: "original",
                                                   expiresAt: Date().addingTimeInterval(3600)))
        XCTAssertTrue(saved)
        let connector = U115Source(sourceID: fixture.id, session: session,
                                   requests: CloudRequestScheduler(timing: CloudAdvancingClock().timing))
        let items = try await connector.listFiles(at: "0")
        XCTAssertEqual(items.map(\.path), ["pc1"])
        XCTAssertEqual(items.first?.modifiedDate, Date(timeIntervalSince1970: 1_700_000_000))
        let tokens = await manager.getTokens()
        XCTAssertEqual(tokens?.refreshToken, "rotated")
        let listings = fixture.requests.filter { $0.url?.host == "proapi.115.com" }
        XCTAssertTrue(listings.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == Pan115APIProtocol.userAgent })
        XCTAssertEqual(fixture.requests.filter { $0.url?.host == "passportapi.115.com" }.count, 1)
        do {
            _ = try await connector.listFiles(at: "broken")
            XCTFail("A failed listing was returned as an empty folder")
        } catch CloudDriveError.apiError(let code, _) {
            XCTAssertEqual(code, 20_130_827)
        }
    }

    func testPan115ConfirmsMissingChildrenWithASecondListing() async throws {
        let listing = CloudTestCounter()
        let fixture = CloudHTTPFixture(responses: [.init(status: 200)], responder: { _, _ in
            listing.increment()
            // 第一遍少了 pc2,第二遍又列出来了:不能当作删除。
            let body = listing.value == 1
                ? #"{"state":true,"count":1,"data":[{"fn":"a.flac","fc":"1","fs":"10","pc":"pc1","fid":"77"}]}"#
                : #"{"state":true,"count":2,"data":[{"fn":"a.flac","fc":"1","fs":"10","pc":"pc1","fid":"77"},{"fn":"b.flac","fc":"1","fs":"10","pc":"pc2","fid":"78"}]}"#
            return .init(status: 200, body: Data(body.utf8))
        })
        let session = fixture.session()
        let manager = CloudTokenManager(sourceID: fixture.id)
        defer {
            session.invalidateAndCancel(); fixture.remove()
            _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id)
        }
        let saved = await manager.saveTokens(.init(accessToken: "token", refreshToken: "refresh",
                                                   expiresAt: Date().addingTimeInterval(3600)))
        XCTAssertTrue(saved)
        let connector = U115Source(sourceID: fixture.id, session: session,
                                   requests: CloudRequestScheduler(timing: CloudAdvancingClock().timing))
        let items = try await connector.listFiles(at: "100", confirmingPreviouslyObservedPaths: ["pc1", "pc2"])
        XCTAssertEqual(Set(items.map(\.path)), ["pc1", "pc2"])
        XCTAssertEqual(listing.value, 2)
        // ID 寻址的子项靠同步索引里的父目录找回来。
        let index = try ConnectorScanner.ObservedChildPathIndex(
            paths: ["pc1", "/Music/a.mp3"],
            parentLinks: [(parent: "100", child: "pc1"), (parent: "/Music", child: "/Music/a.mp3")]
        )
        XCTAssertEqual(index.childPaths(in: "100"), ["pc1"])
        XCTAssertEqual(index.childPaths(in: "/Music"), ["/Music/a.mp3"])
    }

    func testPan115ConcurrentReadsShareOneLinkLookupWithTheSameUserAgent() async throws {
        let server = try LocalCloudServer(response: .init(
            status: 206, headers: ["Content-Range": "bytes 0-3/4"], body: Data("abcd".utf8)))
        let cdn = try await server.start()
        defer { server.stop() }
        let fixture = CloudHTTPFixture(responses: [.init(status: 200)], responder: { _, _ in
            .init(status: 200, body: Data(
                #"{"state":true,"code":0,"message":"","data":{"77":{"file_name":"a.flac","url":{"url":"\#(cdn.absoluteString)"}}}}"#.utf8))
        })
        let session = fixture.session()
        let manager = CloudTokenManager(sourceID: fixture.id)
        defer {
            session.invalidateAndCancel(); fixture.remove()
            _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id)
        }
        let saved = await manager.saveTokens(.init(accessToken: "token", refreshToken: "refresh",
                                                   expiresAt: Date().addingTimeInterval(3600)))
        XCTAssertTrue(saved)
        let connector = U115Source(sourceID: fixture.id, session: session,
                                   requests: CloudRequestScheduler(timing: CloudAdvancingClock().timing))
        async let first = connector.fetchRange(path: "pc1", offset: 0, length: 4)
        async let second = connector.fetchRange(path: "pc1", offset: 0, length: 4)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, Data("abcd".utf8))
        XCTAssertEqual(b, Data("abcd".utf8))
        let lookups = fixture.requests
        XCTAssertEqual(lookups.count, 1)
        XCTAssertEqual(lookups.first?.value(forHTTPHeaderField: "User-Agent"), Pan115APIProtocol.userAgent)
        XCTAssertTrue(server.requestHeaders.contains(Pan115APIProtocol.userAgent))
    }

    func testRefreshAdoptsTokensRotatedOnAnotherDevice() async throws {
        let sourceID = UUID().uuidString
        let manager = CloudTokenManager(sourceID: sourceID)
        defer { _ = CloudTokenManager.deleteStoredCredentials(for: sourceID) }
        let saved = await manager.saveTokens(.init(accessToken: "old", refreshToken: "r1", expiresAt: .distantPast))
        XCTAssertTrue(saved)
        let calls = CloudTestCounter()
        let tokens = try await manager.refreshDeduped(.ifExpired) { _ in
            calls.increment()
            // 另一台设备先用掉了 r1,新的一对经 iCloud 钥匙串同步到了这台设备。
            _ = await CloudTokenManager(sourceID: sourceID).saveTokens(
                .init(accessToken: "other-device", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600)))
            throw CloudDriveError.tokenRefreshFailed("consumed")
        }
        XCTAssertEqual(tokens.accessToken, "other-device")
        XCTAssertEqual(tokens.refreshToken, "r2")
        XCTAssertEqual(calls.value, 1)
    }

    func testRefreshStillFailsWhenNoOtherDeviceRotatedTheToken() async throws {
        let sourceID = UUID().uuidString
        let manager = CloudTokenManager(sourceID: sourceID)
        defer { _ = CloudTokenManager.deleteStoredCredentials(for: sourceID) }
        let saved = await manager.saveTokens(.init(accessToken: "old", refreshToken: "r1", expiresAt: .distantPast))
        XCTAssertTrue(saved)
        do {
            _ = try await manager.refreshDeduped(.ifExpired) { _ in throw CloudDriveError.tokenRefreshFailed("revoked") }
            XCTFail("Revoked refresh token accepted")
        } catch CloudDriveError.tokenRefreshFailed(let reason) {
            XCTAssertEqual(reason, "revoked")
        }
    }

    func testManagersForOneSourceShareTheRefreshTask() async throws {
        let sourceID = UUID().uuidString
        defer { _ = CloudTokenManager.deleteStoredCredentials(for: sourceID) }
        let saved = await CloudTokenManager(sourceID: sourceID).saveTokens(
            .init(accessToken: "old", refreshToken: "r1", expiresAt: .distantPast))
        XCTAssertTrue(saved)
        let calls = CloudTestCounter()
        let refresh: @Sendable (CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens = { tokens in
            calls.increment()
            try await Task.sleep(for: .milliseconds(300))
            return .init(accessToken: "fresh", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600))
        }
        async let scan = CloudTokenManager(sourceID: sourceID).refreshDeduped(.ifExpired, refresh: refresh)
        async let playback = CloudTokenManager(sourceID: sourceID).refreshDeduped(.ifExpired, refresh: refresh)
        let (a, b) = try await (scan, playback)
        XCTAssertEqual(a.refreshToken, "r2")
        XCTAssertEqual(b.refreshToken, "r2")
        XCTAssertEqual(calls.value, 1)
    }

    func testOAuthPermanentRefreshRejectionKeepsCredentialMeaning() async throws {
        for status in [200, 400] {
            let fixture = CloudHTTPFixture(responses: [.init(status: status,
                body: Data(#"{"error":"invalid_grant","error_description":"echoed SECRET","refresh_token":"SECRET"}"#.utf8))])
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            do {
                _ = try await CloudDriveHelper(sourceID: fixture.id).tokenRequest(URLRequest(url: fixture.url),
                    clientID: UUID().uuidString, session: session)
                XCTFail("Invalid grant was returned as token data")
            } catch CloudDriveError.tokenRefreshFailed(let reason) { XCTAssertEqual(reason, "invalid_grant") }
            catch { XCTFail("Permanent credential error lost its classification") }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    @MainActor
    func testOAuthExchangePreservesProviderFormatAndRotation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200,
            body: Data(#"{"access_token":"new","refresh_token":"rotated","expires_in":3600}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let config = CloudOAuthConfig(provider: .oneDrive, authURL: "https://fixture.invalid/auth",
            tokenURL: fixture.url.absoluteString, clientId: "client", clientSecret: "secret",
            scopes: [], redirectURI: "primuse://oauth")
        let result = try await OAuthService(session: session).exchangeCodeForTokens(
            code: "code+value", config: config, codeVerifier: "verifier")
        XCTAssertEqual(result.accessToken, "new"); XCTAssertEqual(result.refreshToken, "rotated")
        XCTAssertEqual(fixture.requests.last?.httpMethod, "POST")
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    @MainActor
    func testOAuthExchangeRejectionKeepsTheProviderExplanation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 400, body: Data(
            #"{"error":"invalid_request","error_description":"AADSTS50011: The redirect URI does not match. refresh_token=SECRET"}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let config = CloudOAuthConfig(provider: .oneDrive, authURL: "https://fixture.invalid/auth",
            tokenURL: fixture.url.absoluteString, clientId: "client", clientSecret: nil,
            scopes: [], redirectURI: "primuse://oauth")
        do {
            _ = try await OAuthService(session: session, tokenRequests: OAuthTokenRequests(registry: RequestQuotaRegistry()))
                .exchangeCodeForTokens(code: "code", config: config, codeVerifier: "verifier")
            XCTFail("Rejected exchange returned tokens")
        } catch OAuthError.tokenExchangeFailed(let message) {
            XCTAssertTrue(message.hasPrefix("HTTP 400: invalid_request: AADSTS50011"), message)
            XCTAssertFalse(message.contains("SECRET"), message)
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testOAuthExchangeAndRefreshShareLongCooldown() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 429, headers: ["Retry-After": "3600"])])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let requests = OAuthTokenRequests(registry: RequestQuotaRegistry())
        let service = OAuthService(session: session, tokenRequests: requests)
        let config = CloudOAuthConfig(provider: .oneDrive, authURL: "https://fixture.invalid/auth",
            tokenURL: fixture.url.absoluteString, clientId: "fixture", clientSecret: nil,
            scopes: [], redirectURI: "primuse://oauth")
        do { _ = try await service.exchangeCodeForTokens(code: "code", config: config, codeVerifier: "verifier"); XCTFail("Expected HTTP quota") }
        catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590) }
        catch { XCTFail("Lost HTTP classification") }
        do {
            _ = try await CloudDriveHelper(sourceID: fixture.id).tokenRequest(URLRequest(url: fixture.url),
                clientID: "fixture", session: session, requests: requests)
            XCTFail("Refresh bypassed authorization cooldown")
        } catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testSharedHTTPFailuresKeepBackfillPauseAndLocalizedScanAdvice() {
        let manager = SourceManager(sourcesProvider: { [] })
        let source = MusicSource(id: UUID().uuidString, name: "fixture", type: .baiduPan)
        for failure in [HTTPResponseFailure(statusCode: 429, retryAfter: 3600),
                        HTTPResponseFailure(statusCode: 200, retryAfter: 3600, isRateLimited: true),
                        HTTPResponseFailure(statusCode: 503, retryAfter: 3600)] {
            XCTAssertTrue(MetadataBackfillService.isSourceUnavailableBackfillError(failure))
            let message = manager.scanFailureMessage(for: failure, source: source)
            XCTAssertTrue(message.contains(String(localized: "source_diag_advice_rate_message")))
            XCTAssertTrue(message.contains(String(localized: "source_diag_advice_rate_suggestion")))
            XCTAssertFalse(message.contains("200"))
        }
        XCTAssertFalse(MetadataBackfillService.isSourceUnavailableBackfillError(HTTPResponseFailure(statusCode: 404)))
        XCTAssertFalse(MetadataBackfillService.isSourceUnavailableBackfillError(HTTPResponseFailure(statusCode: 503)))
    }

    func testLongCooldownIsPreservedAndSharedByHelpers() async throws {
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 429, headers: ["Retry-After": "3600"]), .init(status: 200)
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let first = CloudDriveHelper(sourceID: fixture.id)
        let second = CloudDriveHelper(sourceID: fixture.id)
        for helper in [first, second] {
            do {
                _ = try await helper.makeAuthorizedRequest(
                    url: fixture.url, method: "POST", accessToken: "fixture", session: session
                )
                XCTFail("Expected shared cooldown")
            } catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 429)
                XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
            } catch { XCTFail("Expected complete HTTP failure, got \(error)") }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }
    func testAPICooldownAlsoStopsRangeOnTheSameHost() async throws {
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 429, headers: ["Retry-After": "3600"]), .init(status: 200)
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let helper = CloudDriveHelper(sourceID: fixture.id)
        _ = try? await helper.makeAuthorizedRequest(url: fixture.url, method: "POST", accessToken: "fixture", session: session)
        do {
            _ = try await helper.rangeRequest(url: fixture.url, offset: 0, length: 4, session: session)
            XCTFail("Range bypassed the account/host quota")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 429)
            XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
        } catch { XCTFail("Expected shared cooldown, got \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testWritebackRequestsShareTheAccountCooldownWithReads() async throws {
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 429, headers: ["Retry-After": "3600"]), .init(status: 200)
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(), session: session)
        var upload = URLRequest(url: fixture.url)
        upload.httpMethod = "PUT"
        do {
            _ = try await helper.sendOnce(upload) { session, request in
                try await session.upload(for: request, from: Data("tags".utf8))
            }
            XCTFail("Expected the upload's rate limit")
        } catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590) }
        do {
            _ = try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: "fixture", session: session)
            XCTFail("A read bypassed the cooldown a write established")
        } catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590) }
        do {
            _ = try await helper.sendOnce(upload)
            XCTFail("A second write bypassed the cooldown")
        } catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 429) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testWritebackKeepsAdapterStatusesAndSendsOnce() async throws {
        for status in [409, 412, 403, 500, 503] {
            let fixture = CloudHTTPFixture(responses: [.init(status: status), .init(status: 200)])
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(), session: session)
            var request = URLRequest(url: fixture.url)
            request.httpMethod = "PUT"
            let (_, response) = try await helper.sendOnce(request)
            // Conflict and permission handling stays with each provider's writeback code.
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual(fixture.requests.count, 1, "HTTP \(status): a write is sent once")
        }
    }

    func testReadDefersLongHTTPDateWithoutSendingAgain() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let fixture = CloudHTTPFixture(responses: [.init(status: 503,
            headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(3600))])])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            _ = try await CloudDriveHelper(sourceID: fixture.id).makeAuthorizedRequest(url: fixture.url, accessToken: "fixture", session: session)
            XCTFail("Expected deferral")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 503)
            XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3500)
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMountsShareAccountQuotaButOtherAccountsStayIndependent() async throws {
        let scheduler = CloudRequestScheduler()
        let fixture = CloudHTTPFixture(responses: [.init(status: 429, headers: ["Retry-After": "3600"]), .init(status: 200)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        scheduler.register(sourceID: "mount-a", accountID: "account-one")
        scheduler.register(sourceID: "mount-b", accountID: "account-one")
        scheduler.register(sourceID: "mount-c", accountID: "account-two")
        for id in ["mount-a", "mount-b"] {
            do {
                _ = try await CloudDriveHelper(sourceID: id, requests: scheduler).makeAuthorizedRequest(
                    url: fixture.url, accessToken: "fixture", session: session)
                XCTFail("Expected account quota to be shared")
            } catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 429) }
        }
        _ = try await CloudDriveHelper(sourceID: "mount-c", requests: scheduler).makeAuthorizedRequest(
            url: fixture.url, accessToken: "fixture", session: session)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testPan123BusinessQuotaSurvivesHTTP200AndConnectorRecreation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, headers: ["Retry-After": "3600"], body: Data(#"{"code":429,"message":"quota"}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = Pan123Source(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })
            do { _ = try await source.listFiles(at: ""); XCTFail("Expected quota failure") }
            catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 200)
                XCTAssertTrue(failure.isRateLimited)
                XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
                XCTAssertTrue(String(decoding: failure.body, as: UTF8.self).contains("429"))
            }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testPan123MonthlyDownloadQuotaIsNamedAndClearedByTheNextLink() async throws {
        let linkRequests = CloudTestCounter()
        let fixture = CloudHTTPFixture(responses: [.init(status: 200)], responder: { request, _ in
            if request.url?.path.hasSuffix("/file/list") == true {
                return .init(status: 200, body: Data(#"{"code":0,"data":{"lastFileId":-1,"fileList":[{"filename":"cover.jpg","fileId":41,"type":0,"size":1},{"filename":"song.mp3","fileId":42,"type":0,"size":10}]}}"#.utf8))
            }
            linkRequests.increment()
            if linkRequests.value == 1 {
                return .init(status: 200, body: Data(#"{"code":5113,"message":"您本月下载流量已超出10GB限制"}"#.utf8))
            }
            return .init(status: 200, body: Data(#"{"code":0,"data":{"downloadUrl":"https://download.invalid/song.mp3"}}"#.utf8))
        })
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); CloudDownloadQuotaState.shared.clear(sourceID: fixture.id) }
        let source = Pan123Source(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })

        do { _ = try await source.diagnosticDownloadProbe(roots: ["/"]); XCTFail("Expected the monthly quota failure") }
        catch let error as CloudDriveError {
            guard case .downloadQuotaExceeded(_, let detail) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(detail.contains("10GB"))
            XCTAssertEqual(AutomaticOfflineFailureClassifier.classify(error), .sourceAccessDenied)
            XCTAssertTrue(MetadataBackfillService.isSourceUnavailableBackfillError(error))
            XCTAssertEqual(CloudDownloadQuotaState.shared.exhaustedMessage(sourceID: fixture.id), error.localizedDescription)
            let manager = SourceManager(sourcesProvider: { [] })
            let message = manager.scanFailureMessage(
                for: error, source: MusicSource(id: fixture.id, name: "fixture", type: .pan123)
            )
            XCTAssertTrue(message.contains(String(localized: "source_diag_advice_download_quota_title")))
        }
        XCTAssertNil(CloudDownloadQuotaState.shared.exhaustedMessage(sourceID: UUID().uuidString))

        let found = try await source.diagnosticDownloadProbe(roots: ["/"])
        XCTAssertTrue(found)
        XCTAssertEqual(linkRequests.value, 2)
        XCTAssertNil(CloudDownloadQuotaState.shared.exhaustedMessage(sourceID: fixture.id))
        XCTAssertTrue(fixture.requests.contains { $0.url?.query?.contains("fileId=42") == true })
    }

    func testBaiduBusinessQuotaSurvivesHTTP200AndConnectorRecreation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, headers: ["Retry-After": "3600"], body: Data(#"{"errno":31034}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = BaiduPanSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })
            do { _ = try await source.listFiles(at: "/"); XCTFail("Expected quota failure") }
            catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 200)
                XCTAssertTrue(failure.isRateLimited)
                XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
            }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testGoogleQuota403KeepsReasonAndSharesCooldown() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 403, headers: ["Retry-After": "3600"],
            body: Data(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = GoogleDriveSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })
            do { _ = try await source.listFiles(at: ""); XCTFail("Expected quota failure") }
            catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 403)
                XCTAssertTrue(failure.isRateLimited)
                XCTAssertEqual(AutomaticOfflineFailureClassifier.classify(failure), .rateLimited)
                XCTAssertTrue(String(decoding: failure.body, as: UTF8.self).contains("userRateLimitExceeded"))
            }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testOrdinaryGoogle403IsPermissionWithoutRetry() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 403,
            body: Data(#"{"error":{"errors":[{"reason":"insufficientFilePermissions"}]}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            _ = try await GoogleDriveSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" }).listFiles(at: "")
            XCTFail("Expected permission rejection")
        } catch CloudDriveError.permissionDenied { }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testBaiduRejectedTokensRecoverEvenOnHTTP403() async throws {
        for body in [#"{"errno":111}"#, #"{"errno":-6}"#, ""] {
            let fixture = CloudHTTPFixture(responses: [.init(status: 200)], responder: { request, _ in
                if request.url?.host == "openapi.baidu.com" {
                    return .init(status: 200, body: Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8))
                }
                let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "access_token" }?.value
                return token == "fresh" ? .init(status: 200, body: Data(#"{"errno":0,"list":[]}"#.utf8))
                    : .init(status: 403, body: Data(body.utf8))
            })
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
            let tokens = CloudTokenManager(sourceID: fixture.id)
            let saved = await tokens.saveTokens(.init(accessToken: "old", refreshToken: "refresh"))
            let savedApp = await tokens.saveAppCredentials(.init(clientId: "fixture-client", clientSecret: "fixture-secret"))
            XCTAssertTrue(saved && savedApp)
            let source = BaiduPanSource(sourceID: fixture.id, session: session, tokenProvider: { "old" })
            let files = try await source.listFiles(at: "/")
            XCTAssertTrue(files.isEmpty)
            XCTAssertEqual(fixture.requests.filter { $0.url?.host == "openapi.baidu.com" }.count, 1)
            XCTAssertEqual(fixture.requests.filter { $0.url?.host == "pan.baidu.com" }.count, 2)
        }
    }

    func testBaiduReadCooldownAlsoDefersWritesWithoutSending() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 429, headers: ["Retry-After": "3600"])])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = BaiduPanSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })
        _ = try? await source.listFiles(at: "/")
        do { try await source.deleteFile(at: "/track.flac"); XCTFail("A write bypassed read cooldown") }
        catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 429)
            XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590)
        } catch { XCTFail("Lost shared cooldown: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testGuangYaSharesIPQuotaAcrossAccounts() async throws {
        let scheduler = CloudRequestScheduler()
        let fixture = CloudHTTPFixture(responses: [.init(status: 429, headers: ["Retry-After": "3600"])])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = GuangYaSource(sourceID: UUID().uuidString, session: session, tokenProvider: { "fixture" },
                configuration: .init(clientID: "fixture", projectID: "fixture", signSecret: "fixture"), requests: scheduler)
            do { _ = try await source.listFiles(at: ""); XCTFail("Expected shared IP quota") }
            catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 429) }
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertNotNil(fixture.requests.first?.value(forHTTPHeaderField: "sign"))
    }

    func testMixedGuangYaHTTPAndBusinessFailuresHaveOneAttemptBudget() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500),
            .init(status: 200, body: Data(#"{"code":101,"msg":"temporary"}"#.utf8)),
            .init(status: 500), .init(status: 200, body: Data(#"{"code":101}"#.utf8)), .init(status: 500)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = GuangYaSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" },
            configuration: .init(clientID: "fixture", projectID: "fixture", signSecret: "fixture"),
            requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let task = Task { try await source.listFiles(at: "") }
        defer { task.cancel() }
        for delay in [0.5, 1.5, 3.5, 7.5] { try await clock.waitForSleep(at: delay); clock.advance(to: delay) }
        do { _ = try await task.value; XCTFail("Expected exhausted attempt budget") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 500) }
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testPCloudListsOnTheAccountRegionWithBearerHeader() async throws {
        let listing = Data("""
        {"result":0,"metadata":{"folderid":230807,"isfolder":true,"name":"Music","id":"d230807","contents":[
          {"id":"d42","folderid":42,"isfolder":true,"name":"Album","modified":1380719015},
          {"id":"f7","fileid":7,"isfolder":false,"name":"Song.flac","size":1024,"modified":1380719000,"hash":99}
        ]}}
        """.utf8)
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: listing)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let tokens = CloudTokenManager.Tokens(
            accessToken: "fixture",
            extra: PCloudAPIProtocol.credentialExtra(apiHost: "eapi.pcloud.com", locationID: "2")
        )
        let source = PCloudSource(sourceID: fixture.id, session: session, tokenProvider: { tokens })

        let items = try await source.listFiles(at: "d230807")

        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.url?.host, "eapi.pcloud.com")
        XCTAssertEqual(request.url?.path, "/listfolder")
        XCTAssertTrue(request.url?.query?.contains("folderid=230807") == true)
        XCTAssertFalse(request.url?.query?.contains("access_token") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(items.map(\.path), ["d42", "f7"])
        XCTAssertEqual(items.map(\.isDirectory), [true, false])
        XCTAssertEqual(items.map(\.parentPath), ["d230807", "d230807"])
        XCTAssertEqual(items[1].size, 1024)
        XCTAssertEqual(items[1].revision, "99")
    }

    func testPCloudRejectedTokenIsNotRetriedAsAnHTTPFailure() async throws {
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 200, body: Data(#"{"result":2094,"error":"Invalid 'access_token' provided."}"#.utf8)),
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = PCloudSource(sourceID: fixture.id, session: session, tokenProvider: {
            CloudTokenManager.Tokens(accessToken: "revoked")
        })
        do {
            _ = try await source.listFiles(at: "/")
            XCTFail("A revoked pCloud token must ask for a new authorization")
        } catch is CloudDriveError {
            // pCloud 没有 refresh_token:钥匙串里没有新 token 时只能请用户重新授权。
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.url?.host, "api.pcloud.com")
    }

    func testPCloudTransientResultIsRetriedWithinTheAttemptBudget() async throws {
        let clock = CloudClock()
        let listing = Data(#"{"result":0,"metadata":{"folderid":0,"isfolder":true,"name":"/","contents":[]}}"#.utf8)
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 200, body: Data(#"{"result":5000,"error":"Internal error. Try again later."}"#.utf8)),
            .init(status: 200, body: listing),
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = PCloudSource(
            sourceID: fixture.id, session: session,
            tokenProvider: { CloudTokenManager.Tokens(accessToken: "fixture") },
            requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 })
        )
        let task = Task { try await source.listFiles(at: "/") }
        defer { task.cancel() }
        try await clock.waitForSleep(at: 0.5)
        clock.advance(to: 0.5)
        let items = try await task.value
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testPCloudDeletionRequiresConfirmedTrashMetadata() async throws {
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 200, body: Data(#"{"result":0,"metadata":{"isdeleted":true,"fileid":7,"name":"a.mp3"}}"#.utf8)),
            .init(status: 200, body: Data(#"{"result":0,"metadata":{"fileid":8,"name":"b.mp3"}}"#.utf8)),
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = PCloudSource(sourceID: fixture.id, session: session, tokenProvider: {
            CloudTokenManager.Tokens(accessToken: "fixture")
        })

        try await source.deleteFile(at: "f7")
        do {
            try await source.deleteFile(at: "f8")
            XCTFail("An unconfirmed deletion must not be reported as done")
        } catch {}

        XCTAssertEqual(fixture.requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(fixture.requests.first?.url?.path, "/deletefile")
        XCTAssertTrue(fixture.requests.first?.url?.query?.contains("fileid=7") == true)
        do {
            try await source.deleteFile(at: "d7")
            XCTFail("A folder ID is not a deletable file")
        } catch {}
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testCancellingBackoffDoesNotSendAnotherRequest() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500), .init(status: 200)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let task = Task { try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: "fixture", session: session) }
        try await clock.waitForSleep(at: 0.5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testOfflineRecoveryDoesNotShortenCloudCooldowns() {
        XCTAssertNil(OfflineRangeDownloadRetry.delay(after: HTTPResponseFailure(statusCode: 429, retryAfter: 3600), failedAttempts: 1))
        XCTAssertEqual(OfflineRangeDownloadRetry.delay(after: HTTPResponseFailure(statusCode: 503, retryAfter: 12), failedAttempts: 1), 12)
        XCTAssertNil(OfflineRangeDownloadRetry.delay(after: HTTPResponseFailure(statusCode: 403), failedAttempts: 1))
    }

    func testTCPHeadersRetainLongSecondsAndHTTPDatesBeforeBodyRead() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "1994-11-06T08:49:37Z"))
        for (status, header, delay) in [(429, "3600", 3600.0), (503, "Sun, 06 Nov 1994 09:49:37 GMT", 3600.0)] {
            let data = Data("HTTP/1.1 \(status) Rejected\r\nRetry-After: \(header)\r\nContent-Length: 999999999\r\n".utf8)
            do { _ = try TCPRangeFetcher.parseResponseHead(data, now: now); XCTFail("Expected HTTP failure before reading body") }
            catch TCPRangeFetcher.FetchError.http(let failure) {
                XCTAssertEqual(failure.statusCode, status)
                XCTAssertEqual(failure.retryAfter, delay)
            }
        }
        do {
            _ = try TCPRangeFetcher.parseResponseHead(Data("HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n".utf8))
            XCTFail("Ignored Range must abort before full-file buffering")
        } catch TCPRangeFetcher.FetchError.http(let failure) { XCTAssertEqual(failure.statusCode, 200) }
    }

    func testRangeKeepsItsReadBoundOverARealLocalConnection() async throws {
        let server = try LocalCloudServer(response: .init(status: 206, body: Data(0..<8)))
        let url = try await server.start()
        defer { server.stop() }
        let helper = CloudDriveHelper(sourceID: UUID().uuidString)
        let data = try await helper.rangeRequest(url: url, offset: 0, length: 4)
        XCTAssertEqual(data, Data(0..<4))
        XCTAssertTrue(server.requestHeaders.lowercased().contains("range: bytes=0-3"))
    }

    func testProgressingRangeCanOutliveItsIdleTimeout() async throws {
        let payload = Data(0..<8)
        let server = try LocalCloudServer(response: .init(status: 206, body: payload), bodyChunkDelay: 0.25)
        let url = try await server.start()
        defer { server.stop() }
        let started = Date()
        let data = try await CloudDriveHelper(sourceID: UUID().uuidString).rangeRequest(
            url: url, offset: 0, length: 8, timeoutSeconds: 1, resourceTimeoutSeconds: 5
        )
        XCTAssertEqual(data, payload)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(server.requestCount, 1, "Progressing bytes must not be discarded and retried")
    }

    func testProgressingRangeStillHonorsItsTotalBudget() async throws {
        let server = try LocalCloudServer(response: .init(status: 206, body: Data(0..<8)), bodyChunkDelay: 0.25)
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await CloudDriveHelper(sourceID: UUID().uuidString).rangeRequest(
                url: url, offset: 0, length: 8, timeoutSeconds: 1, resourceTimeoutSeconds: 0.5
            )
            XCTFail("The total transfer budget must remain bounded")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testIgnoredRangeDoesNotBecomeAFullFileResponse() async throws {
        let server = try LocalCloudServer(response: .init(status: 200, body: Data(repeating: 1, count: 65536)))
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await CloudDriveHelper(sourceID: UUID().uuidString).rangeRequest(url: url, offset: 0, length: 4)
            XCTFail("Expected ignored Range error")
        } catch CloudDriveError.apiError(let status, _) { XCTAssertEqual(status, 200) }
    }

    func testRangeAndStreamedDownloadsRetainRateLimitAndNeverPublishErrors() async throws {
        for download in [false, true] {
            for status in [429, 503] {
                let server = try LocalCloudServer(response: .init(status: status, headers: ["Retry-After": "3600"], body: Data("limited".utf8)))
                let url = try await server.start()
                let helper = CloudDriveHelper(sourceID: UUID().uuidString)
                let path = "fixture.flac"
                defer { server.stop(); try? FileManager.default.removeItem(at: helper.cacheDirectory.deletingLastPathComponent()) }
                do {
                    if download { _ = try await helper.downloadToCache(request: URLRequest(url: url), for: path) }
                    else { _ = try await helper.rangeRequest(url: url, offset: 0, length: 4) }
                    XCTFail("Expected HTTP failure")
                } catch let failure as HTTPResponseFailure {
                    XCTAssertEqual(failure.statusCode, status)
                    XCTAssertEqual(failure.retryAfter, 3600)
                }
                XCTAssertFalse(helper.hasCached(path: path))
                XCTAssertEqual(server.requestCount, 1)
            }
        }
    }

    func testStreamedDownloadPublishesCompleteFileAndReusesCache() async throws {
        let bytes = Data(repeating: 7, count: 65536)
        let server = try LocalCloudServer(response: .init(status: 200, body: bytes))
        let url = try await server.start()
        let helper = CloudDriveHelper(sourceID: UUID().uuidString)
        defer { server.stop(); try? FileManager.default.removeItem(at: helper.cacheDirectory.deletingLastPathComponent()) }
        let first = try await helper.downloadToCache(request: URLRequest(url: url), for: "fixture.flac")
        let second = try await helper.downloadToCache(request: URLRequest(url: url), for: "fixture.flac")
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testTokenRecoveryConsumesExistingHTTPAttemptBudget() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500), .init(status: 401), .init(status: 500)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture-refresh"))
        XCTAssertTrue(saved, "The isolated simulator must support fixture Keychain credentials")
        let refreshes = CloudTestCounter()
        let task = Task {
            try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment()
                return .init(accessToken: "new", refreshToken: "rotated-fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        }
        defer { task.cancel() }
        for deadline in [0.5, 2.5, 6.5] { try await clock.waitForSleep(at: deadline); clock.advance(to: deadline) }
        do { _ = try await task.value; XCTFail("Expected exhausted HTTP budget") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 500) }
        XCTAssertEqual(fixture.requests.count, 5)
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(fixture.requests.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" },
                       ["Bearer old", "Bearer old", "Bearer new", "Bearer new", "Bearer new"])
    }

    func testConcurrentTokenRejectionsStillShareOneRefresh() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 200)], responder: { request, _ in
            .init(status: request.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? 200 : 401)
        })
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture-refresh"))
        XCTAssertTrue(saved)
        let refreshes = CloudTestCounter()
        let tasks = (0..<2).map { _ in Task {
            try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment()
                try await clock.timing.sleep(0.1)
                return .init(accessToken: "new", refreshToken: "rotated-fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        } }
        defer { tasks.forEach { $0.cancel() } }
        try await clock.waitForSleep(at: 0.1)
        for _ in 0..<10000 {
            if fixture.requests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(fixture.requests.count, 2)
        clock.advance(to: 0.1)
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testRefreshedTokenIsNotRefreshedRepeatedly() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 401)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id)
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture-refresh"))
        XCTAssertTrue(saved)
        let refreshes = CloudTestCounter()
        do {
            _ = try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment()
                return .init(accessToken: "new", refreshToken: "rotated-fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
            XCTFail("Expected rejected credentials")
        } catch CloudDriveError.tokenExpired { }
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testFinalAttemptAuthFailureCannotRestartTheBudgetOutsideExecutor() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500), .init(status: 500), .init(status: 500), .init(status: 500), .init(status: 401)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture"))
        XCTAssertTrue(saved)
        let refreshes = CloudTestCounter()
        let task = Task {
            try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment(); return .init(accessToken: "new", refreshToken: "fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        }
        defer { task.cancel() }
        for deadline in [0.5, 1.5, 3.5, 7.5] { try await clock.waitForSleep(at: deadline); clock.advance(to: deadline) }
        do { _ = try await task.value; XCTFail("Expected rejected token at exhausted budget") }
        catch CloudDriveError.tokenExpired { }
        XCTAssertEqual(fixture.requests.count, 5)
        XCTAssertEqual(refreshes.value, 0)
    }

    func testCancellingARequestStopsWaitingForSharedTokenRefresh() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 401)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture"))
        XCTAssertTrue(saved)
        let task = Task {
            return try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                try await clock.timing.sleep(100)
                return .init(accessToken: "new", refreshToken: "fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        }
        try await clock.waitForSleep(at: 100)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation before releasing the shared refresh") }
        catch { XCTAssertTrue(error is CancellationError) }
        clock.advance(to: 100)
        _ = try await helper.tokenManager.refreshDeduped(.ifMatches("old"), refresh: { _ in
            XCTFail("The existing refresh should remain shared")
            return .init(accessToken: "new", refreshToken: "fixture")
        })
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testCancellingQueuedTCPRangeDoesNotWaitForAnotherTransfer() async throws {
        // A TCP peer holding the TLS handshake keeps the production per-host
        // connection occupied without relying on a real CDN or certificate.
        let server = try LocalCloudServer(response: .init(status: 206), holdConnections: true)
        let address = try await server.start()
        var components = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        components.scheme = "https"
        let url = try XCTUnwrap(components.url)
        let helper = CloudDriveHelper(sourceID: UUID().uuidString)
        let first = Task { try await helper.rangeRequest(url: url, offset: 0, length: 4, forceTCP: true) }
        defer { first.cancel(); server.stop() }
        for _ in 0..<10000 {
            if server.connectionCount > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(server.connectionCount, 1)
        let started = CloudTestCounter()
        let queued = Task {
            started.increment()
            return try await helper.rangeRequest(url: url, offset: 4, length: 4, forceTCP: true)
        }
        for _ in 0..<10000 {
            if started.value == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation before releasing the occupied connection") }
        catch { XCTAssertTrue(error is CancellationError) }
        first.cancel()
        _ = await first.result
        XCTAssertEqual(server.connectionCount, 1)
    }

}

private final class CloudHTTPFixture: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }
    let id = UUID().uuidString
    var url: URL { URL(string: "https://fixture.invalid/\(id)")! }
    private let lock = NSLock()
    private let responses: [Response]
    private let responder: (@Sendable (URLRequest, Int) -> Response)?
    private var sent: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { sent } }
    init(responses: [Response], responder: (@Sendable (URLRequest, Int) -> Response)? = nil) {
        self.responses = responses
        self.responder = responder
    }
    func response(to request: URLRequest) -> Response {
        lock.withLock {
            sent.append(request)
            return responder?(request, sent.count) ?? responses[min(sent.count - 1, responses.count - 1)]
        }
    }
    func session() -> URLSession {
        CloudHTTPProtocol.fixtures.insert(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudHTTPProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
        return URLSession(configuration: configuration)
    }
    func remove() { CloudHTTPProtocol.fixtures.remove(id) }
}

private final class CloudHTTPFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CloudHTTPFixture] = [:]
    func insert(_ fixture: CloudHTTPFixture) { lock.withLock { values[fixture.id] = fixture } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func get(_ id: String) -> CloudHTTPFixture? { lock.withLock { values[id] } }
}

private final class CloudHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = CloudHTTPFixtures()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID"),
              let fixture = Self.fixtures.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let result = fixture.response(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status,
                                       httpVersion: "HTTP/1.1", headerFields: result.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CloudClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var recorded: [TimeInterval] = []
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { instant } }
    var starts: [TimeInterval] { lock.withLock { recorded } }
    func recordStart() { lock.withLock { recorded.append(instant) } }
    func advance(to value: TimeInterval) {
        let ready = lock.withLock {
            instant = value
            let ready = sleepers.filter { $0.value.0 <= value }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for (_, continuation) in ready { continuation.resume() }
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
    func waitForSleep(at deadline: TimeInterval, count: Int = 1) async throws {
        for _ in 0..<10000 {
            if lock.withLock({ sleepers.values.filter { abs($0.0 - deadline) < 0.00001 }.count >= count }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, sleep: { try await self.sleep($0) })
    }
}

/// An in-process HTTP peer exercises URLSession bytes/download transports,
/// including temporary-file creation. It never contacts a provider.
private final class LocalCloudServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: CloudHTTPFixture.Response
    private let bodyChunkDelay: TimeInterval?
    private let queue = DispatchQueue(label: "CloudRequestTests.server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var headers: [String] = []
    var requestCount: Int { lock.withLock { headers.count } }
    var connectionCount: Int { lock.withLock { connections.count } }
    var requestHeaders: String { lock.withLock { headers.joined(separator: "\n") } }

    init(response: CloudHTTPFixture.Response, holdConnections: Bool = false, bodyChunkDelay: TimeInterval? = nil) throws {
        self.response = response
        self.bodyChunkDelay = bodyChunkDelay
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            if !holdConnections { self.receive(connection, buffered: Data()) }
        }
    }
    func start() async throws -> URL {
        listener.start(queue: queue)
        for _ in 0..<10000 {
            if let port = listener.port, port.rawValue != 0 { return URL(string: "http://127.0.0.1:\(port.rawValue)/fixture")! }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var input = buffered
            input.append(data ?? Data())
            guard input.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() }
                else { self.receive(connection, buffered: input) }
                return
            }
            self.lock.withLock { self.headers.append(String(decoding: input, as: UTF8.self)) }
            var head = "HTTP/1.1 \(self.response.status) Fixture\r\nConnection: close\r\nContent-Length: \(self.response.body.count)\r\n"
            for (key, value) in self.response.headers { head += "\(key): \(value)\r\n" }
            var payload = Data((head + "\r\n").utf8)
            if let delay = self.bodyChunkDelay {
                connection.send(content: payload, completion: .contentProcessed { error in
                    guard error == nil else { connection.cancel(); return }
                    self.sendBody(connection, index: 0, delay: delay)
                })
                return
            }
            payload.append(self.response.body)
            connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func sendBody(_ connection: NWConnection, index: Int, delay: TimeInterval) {
        guard index < response.body.count else { connection.cancel(); return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { connection.cancel(); return }
            connection.send(content: Data([self.response.body[index]]), completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                self.sendBody(connection, index: index + 1, delay: delay)
            })
        }
    }
}

/// 限频间隔、退避这类短等待即时完成,时钟跟着往前走,测试不真的睡;请求的总超时(几十秒起)照常真睡,
/// 请求结束时被取消,不会抢在请求前面判超时。
private final class CloudAdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    var timing: RequestExecutor.Timing {
        .init(now: { self.lock.withLock { self.instant } },
              sleep: { interval in
                  guard interval <= 10 else {
                      try await Task.sleep(for: .seconds(interval))
                      return
                  }
                  self.lock.withLock { self.instant += max(0, interval) }
              })
    }
}

private final class CloudTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
