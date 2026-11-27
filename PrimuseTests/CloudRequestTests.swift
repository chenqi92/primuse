import Foundation
import Network
import PrimuseKit
import XCTest
@testable import Primuse

final class CloudRequestTests: XCTestCase {
    func testJellyfinAndEmbyAlbumArtistWritesAreVerifiedAndPreserveOtherServerTags() async throws {
        for kind in [MediaServerSource.Kind.jellyfin, .emby] {
            for albumArtist in ["New album artist", ""] {
                let before = #"{"Id":"42","Name":"Fresh remote title","AlbumArtist":"Old","AlbumArtists":[{"Id":"old-album-artist","Name":"Old"}],"Artists":["Remote singer"],"ArtistItems":[{"Id":"old-singer","Name":"Remote singer"}],"Album":"Remote album","Genres":["Rock"]}"#
                let after = try JSONSerialization.data(withJSONObject: ["Id": "42", "Name": "Fresh remote title", "AlbumArtists": albumArtist.isEmpty ? [] : [["Name": albumArtist, "Id": "new-artist"]]])
                let fixture = CloudHTTPFixture(responses: [
                    .init(status: 200, body: Data(#"{"Id":"editor","Name":"Editor"}"#.utf8)),
                    .init(status: 200, body: Data(before.utf8)), .init(status: 204),
                    .init(status: 200, body: after),
                ])
                defer { fixture.remove() }
                let source = MediaServerSource(sourceID: fixture.id, kind: kind, host: "metadata.invalid", port: nil,
                    useSsl: true, basePath: nil, username: "editor", secret: "fixture", authType: .apiKey,
                    requestDataLoader: { request in
                        let response = fixture.response(to: request)
                        return (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!)
                    })
                let original = Song(id: "song", title: "Stale title", albumTitle: "Stale album", artistName: "Stale artist",
                                    albumArtistName: "Old", fileFormat: .flac, filePath: "42.flac", sourceID: fixture.id)
                var updated = original
                updated.albumArtistName = albumArtist.isEmpty ? nil : albumArtist
                let result = await TagMetadataWritebackCoordinator.write(mode: .serverAPI, connector: source,
                    original: original, updated: updated, coverData: nil)
                XCTAssertEqual(result.fields.first { $0.field == .albumArtist }?.disposition, .written, result.issueMessage ?? "")
                XCTAssertNil(result.issueMessage)
                let request = try XCTUnwrap(fixture.requests.first { $0.httpMethod == "POST" })
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(payload["AlbumArtist"] as? String, albumArtist)
                XCTAssertEqual(payload["AlbumArtists"] as? [[String: String]], albumArtist.isEmpty ? [] : [["Name": albumArtist]])
                XCTAssertEqual(payload["Name"] as? String, "Fresh remote title")
                XCTAssertEqual(payload["Artists"] as? [String], ["Remote singer"])
                XCTAssertEqual(payload["ArtistItems"] as? [[String: String]], [["Id": "old-singer", "Name": "Remote singer"]])
                XCTAssertEqual(payload["Album"] as? String, "Remote album")
                await source.disconnect()
            }
        }
    }

    func testPCloudReplacementChecksRevisionAndReadsBackResultingIdentity() async throws {
        for readbackMismatch in [false, true] {
            let old = #"{"id":"f7","fileid":7,"name":"Song.flac","isfolder":false,"parentfolderid":42,"size":3,"modified":1000,"hash":"old"}"#
            let new = #"{"id":"f8","fileid":8,"name":"Song.flac","isfolder":false,"parentfolderid":42,"size":4,"modified":1001,"hash":"new"}"#
            let confirmed = readbackMismatch ? new.replacingOccurrences(of: "new", with: "changed-again") : new
            let fixture = CloudHTTPFixture(responses: [
                .init(status: 200, body: Data("{\"result\":0,\"metadata\":\(old)}".utf8)),
                .init(status: 200, body: Data("{\"result\":0,\"metadata\":{\"contents\":[\(old)]}}".utf8)),
                .init(status: 200, body: Data("{\"result\":0,\"metadata\":\(old)}".utf8)),
                .init(status: 200, body: Data("{\"result\":0,\"metadata\":[\(new)]}".utf8)),
                .init(status: 200, body: Data("{\"result\":0,\"metadata\":\(confirmed)}".utf8)),
            ])
            let session = fixture.session()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { session.invalidateAndCancel(); fixture.remove(); try? FileManager.default.removeItem(at: file) }
            try Data([1, 2, 3, 4]).write(to: file)
            let source = PCloudSource(sourceID: fixture.id, session: session, tokenProvider: { .init(accessToken: "fixture") })
            do {
                let path = try await source.replaceMetadataFileReturningPath(at: "f7", with: file,
                    expected: .init(fileSize: 3, modifiedDate: Date(timeIntervalSince1970: 1000), revision: "old", replacementToken: "42/Song.flac"))
                XCTAssertEqual(path, "f8")
                XCTAssertFalse(readbackMismatch)
            } catch let error as EmbeddedMetadataReplacementReadbackError {
                XCTAssertTrue(readbackMismatch)
                XCTAssertEqual(error.filePath, "f8")
                XCTAssertEqual(error.fileSize, 4)
            }
            XCTAssertEqual(fixture.requests.map { $0.url?.path }, ["/stat", "/listfolder", "/stat", "/uploadfile", "/stat"])
            XCTAssertEqual(fixture.requests[3].httpMethod, "PUT")
            XCTAssertTrue(fixture.requests[3].url?.query?.contains("nopartial=1") == true)
            XCTAssertFalse(fixture.requests[3].url?.query?.contains("renameifexists") == true)
        }
    }

    func testJellyfinAndEmbyWriteAllEightTextTagsUsingEditableArtistObjects() async throws {
        for kind in [MediaServerSource.Kind.jellyfin, .emby] {
            let fixture = CloudHTTPFixture(responses: [
                .init(status: 200, body: Data(#"{"Id":"editor","Name":"Editor"}"#.utf8)),
                .init(status: 200, body: Data(#"{"Id":"42","Name":"Old title","AlbumArtist":"Old album artist","AlbumArtists":[{"Id":"old","Name":"Old album artist"}],"ArtistItems":[{"Id":"old","Name":"Old singer"}],"Overview":"Keep overview"}"#.utf8)),
                .init(status: 204),
                .init(status: 200, body: Data(#"{"Id":"42","Name":"New title","AlbumArtists":[{"Name":"New album artist"}],"ArtistItems":[{"Name":"New singer"},{"Name":"Guest"}],"Album":"New album","Genres":["Rock","Folk"],"ProductionYear":2026,"IndexNumber":4,"ParentIndexNumber":2}"#.utf8)),
            ])
            defer { fixture.remove() }
            let source = MediaServerSource(sourceID: fixture.id, kind: kind, host: "metadata.invalid", port: nil,
                useSsl: true, basePath: nil, username: "editor", secret: "fixture", authType: .apiKey,
                requestDataLoader: { request in
                    let response = fixture.response(to: request)
                    return (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!)
                })
            let original = Song(id: "song", title: "Old title", fileFormat: .flac, filePath: "42.flac", sourceID: fixture.id)
            var edited = original
            edited.title = "New title"
            edited.artistName = "New singer; Guest"
            edited.sourceArtistNames = ["New singer", "Guest"]
            edited.albumArtistName = "New album artist"
            edited.albumTitle = "New album"
            edited.genre = "Rock; Folk"
            edited.year = 2026
            edited.trackNumber = 4
            edited.discNumber = 2
            let result = await TagMetadataWritebackCoordinator.write(mode: .serverAPI, connector: source,
                original: original, updated: edited, coverData: nil)
            XCTAssertNil(result.issueMessage)
            XCTAssertEqual(result.fields.filter { $0.disposition == .written }.count, 8)
            let request = try XCTUnwrap(fixture.requests.first { $0.httpMethod == "POST" })
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(payload["ArtistItems"] as? [[String: String]], [["Name": "New singer"], ["Name": "Guest"]])
            XCTAssertEqual(payload["AlbumArtists"] as? [[String: String]], [["Name": "New album artist"]])
            XCTAssertEqual(payload["Overview"] as? String, "Keep overview")
            await source.disconnect()
        }
    }

    func testPCloudChangedFileIsNotOverwritten() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(#"{"result":0,"metadata":{"id":"f7","name":"Song.flac","isfolder":false,"parentfolderid":42,"size":3,"modified":1000,"hash":"changed"}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = PCloudSource(sourceID: fixture.id, session: session, tokenProvider: { .init(accessToken: "fixture") })
        do {
            try await source.replaceMetadataFile(at: "f7", with: URL(fileURLWithPath: "/unused"),
                expected: .init(fileSize: 3, modifiedDate: Date(timeIntervalSince1970: 1000), revision: "old", replacementToken: "42/Song.flac"))
            XCTFail("Conflicting remote bytes must not be replaced")
        } catch EmbeddedMetadataWritebackSourceError.conflict {}
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testPCloudSidecarRequiresExactReadbackAndDoesNotRetryRejectedUploads() async throws {
        for outcome in ["success", "mismatch", "denied"] {
            let fixture = CloudHTTPFixture(responses: [], responder: { request, _ in
                switch request.url!.path {
                case "/stat": return .init(status: 200, body: Data(#"{"result":0,"metadata":{"id":"f7","name":"Song.flac","isfolder":false,"parentfolderid":42,"size":3,"modified":1000,"hash":"old"}}"#.utf8))
                case "/listfolder": return .init(status: 200, body: Data(#"{"result":0,"metadata":{"contents":[]}}"#.utf8))
                case "/uploadfile":
                    if outcome == "denied" { return .init(status: 200, body: Data(#"{"result":2003,"error":"Access denied"}"#.utf8)) }
                    return .init(status: 200, body: Data(#"{"result":0,"metadata":[{"id":"f8","name":"Song.lrc","isfolder":false,"parentfolderid":42,"size":4,"modified":1001,"hash":"new"}]}"#.utf8))
                case "/getfilelink": return .init(status: 200, body: Data(#"{"result":0,"hosts":["download.pcloud.com"],"path":"/lyrics","expires":9999999999}"#.utf8))
                case "/lyrics": return .init(status: 206, headers: ["Content-Range": "bytes 0-3/4"], body: Data((outcome == "success" ? "song" : "nope").utf8))
                default: return .init(status: 404)
                }
            })
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let source = PCloudSource(sourceID: fixture.id, session: session, tokenProvider: { .init(accessToken: "fixture") })
            do {
                let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "f7", sourceID: fixture.id)
                let target = try await source.lyricsSidecarTarget(for: song, request: .current(pinned: nil))
                XCTAssertEqual(target.fileName, "Song.lrc")
                XCTAssertEqual(target.targetPath, "f7.lrc")
                let receipt = try await source.writeLyricsSidecar(data: Data("song".utf8), target: target, priority: .userInitiated)
                XCTAssertEqual(receipt.writtenPath, "f8")
                XCTAssertEqual(outcome, "success")
            } catch {
                XCTAssertNotEqual(outcome, "success", error.localizedDescription)
                if outcome == "denied" { XCTAssertTrue(MetadataWriteFailurePolicy.allowsLocalSave(error)) }
                if outcome == "mismatch" {
                    if case EmbeddedMetadataWritebackSourceError.remoteVerificationFailed = error {} else {
                        XCTFail("Expected a verified content mismatch, got \(error)")
                    }
                }
            }
            XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/uploadfile" }.count, 1)
        }
    }

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
        XCTAssertEqual(CloudHTTPFixture.formFields(of: request), ["refresh_token": "refresh+token/&=value"])
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

    func testPan115WalkReadsEveryTrackInSingleNestedAndMultipleRoots() async throws {
        let responses = [
            "10": #"{"state":true,"count":1,"data":[{"fn":"first.mp3","fc":"1","pc":"one"}]}"#,
            "20": #"{"state":true,"count":1,"data":[{"fn":"artist","fc":"0","fid":3540339254645229334}]}"#,
            "3540339254645229334": #"{"state":true,"count":1,"data":[{"fn":"album","fc":"0","cid":"40"}]}"#,
            "40": #"{"state":true,"count":2,"data":[{"fn":"second.mp3","fc":"1","pc":"two"},{"fn":"third.mp3","fc":"1","pc":"three"}]}"#
        ]
        let fixture = CloudHTTPFixture(responses: [], responder: { request, _ in
            let cid = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "cid" }?.value
            guard let cid, let body = responses[cid] else { return .init(status: 404) }
            return .init(status: 200, body: Data(body.utf8))
        })
        try await withPan115Connector(fixture) { connector in
            let cases: [([String], Set<String>)] = [
                (["10"], ["one"]), (["20"], ["two", "three"]),
                (["10", "40"], ["one", "two", "three"]), (["10", "20"], ["one", "two", "three"])
            ]
            for (roots, expected) in cases {
                let scanner = ConnectorScanner(connector: connector, sourceID: fixture.id)
                var last: ConnectorScanner.ScanUpdate?
                for try await update in await scanner.scan(directories: roots) { last = update }
                let completed = try XCTUnwrap(last)
                XCTAssertEqual(Set(completed.songs.map(\.filePath)), expected, roots.description)
                XCTAssertEqual(completed.songs.count, expected.count)
                XCTAssertEqual(completed.resumeState?.pendingDirectories, [])
            }
        }
    }

    func testPan115BlockedSubfolderPreservesFirstSongAndResumesAfterCooldown() async throws {
        let attempts = CloudTestCounter()
        let fixture = CloudHTTPFixture(responses: [], responder: { request, _ in
            let cid = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "cid" }?.value
            switch cid {
            case "10":
                return .init(status: 200, body: Data(#"{"state":true,"count":2,"data":[{"fn":"first.mp3","fc":"1","pc":"one"},{"fn":"album","fc":"0","fid":"20"}]}"#.utf8))
            case "20":
                attempts.increment()
                if attempts.value == 1 {
                    return .init(status: 405, headers: ["Retry-After": "600"], body: Data(
                        #"<html><textarea>{"code":"REQUEST_BLOCKED","error":"waf_agent_protection_triggered"}</textarea></html>"#.utf8))
                }
                return .init(status: 200, body: Data(#"{"state":true,"count":1,"data":[{"fn":"second.mp3","fc":"1","pc":"two"}]}"#.utf8))
            case "30":
                return .init(status: 405, body: Data("Method Not Allowed".utf8))
            default:
                return .init(status: 200, body: Data(#"{"state":true,"count":3,"data":[]}"#.utf8))
            }
        })
        let clock = CloudAdvancingClock()
        try await withPan115Connector(fixture, clock: clock) { connector in
            let scanner = ConnectorScanner(connector: connector, sourceID: fixture.id)
            var last: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["10"]) { last = update }
                XCTFail("The blocked subfolder must remain pending")
            } catch let error as HTTPResponseFailure {
                XCTAssertEqual(error.statusCode, 405)
                XCTAssertEqual(error.retryAfter, 600)
            }
            let partial = try XCTUnwrap(last)
            let state = try XCTUnwrap(partial.resumeState)
            XCTAssertEqual(partial.songs.map(\.filePath), ["one"])
            XCTAssertEqual(state.pendingDirectories, ["20"])
            do {
                _ = try await connector.listFiles(at: "20")
                XCTFail("Listing must wait for the account cooldown")
            } catch let error as HTTPResponseFailure { XCTAssertTrue(error.isRateLimitFailure) }
            XCTAssertEqual(attempts.value, 1)
            clock.advance(by: 601)
            let restored = try JSONDecoder().decode(SourceScanResumeState.self, from: JSONEncoder().encode(state))
            for try await update in await scanner.scan(directories: ["10"], existingSongs: partial.songs,
                                                         resumeState: restored) { last = update }
            XCTAssertEqual(last?.songs.map(\.filePath).sorted(), ["one", "two"])
            XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
            XCTAssertEqual(attempts.value, 2)
            do {
                _ = try await connector.listFiles(at: "30")
                XCTFail("An ordinary 405 must reach the caller")
            } catch CloudDriveError.apiError(let status, _) { XCTAssertEqual(status, 405) }
            do {
                _ = try await connector.listFiles(at: "40")
                XCTFail("An empty page before the advertised total cannot complete the listing")
            } catch CloudDriveError.invalidResponse {}
        }
    }

    func testPan115ReplacesTheSelectedIDAndPreservesOriginalOnFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("edited file".utf8).write(to: file)
        for outcome in Pan115WriteFixture.Outcome.allCases {
            let drive = Pan115WriteFixture(outcome)
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let before = try await source.metadataWritebackState(for: "old")
                do {
                    let path = try await source.replaceMetadataFileReturningPath(at: "old", with: file, expected: before)
                    XCTAssertTrue(outcome == .success || outcome == .lostDeleteReply)
                    XCTAssertEqual(path, "new")
                    let keys = await source.replacementIndexKeys(from: "old", to: path)
                    XCTAssertEqual(keys?.old, "71")
                    XCTAssertEqual(keys?.new, "81")
                    let after = try await source.metadataWritebackState(for: path)
                    XCTAssertEqual(after.revision, try Pan115FileUpload.Fingerprint(file: file).sha1)
                } catch {
                    if outcome == .success || outcome == .lostDeleteReply { throw error }
                }
                let remaining = try await source.listFiles(at: "42")
                if outcome == .success || outcome == .lostDeleteReply {
                    XCTAssertEqual(remaining.map(\.path), ["new"])
                    XCTAssertEqual(remaining.first?.name, "Ballad.flac")
                } else {
                    XCTAssertTrue(remaining.contains { $0.path == "old" && $0.name == "Ballad.flac" })
                    XCTAssertFalse(remaining.contains { $0.path == "new" })
                }
                if outcome == .duplicate {
                    XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/open/upload/init" })
                }
            }
        }
    }

    func testPan115RecoversFromOSSCallback203AndListingLagAndSurfacesRealErrors() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("edited oss file".utf8).write(to: file)

        // 1. OSS returns HTTP 203 CallbackFailed, but 115 commits the staged file on the second listing poll.
        do {
            let drive = Pan115WriteFixture(.oss203LateCommit)
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let before = try await source.metadataWritebackState(for: "old")
                let path = try await source.replaceMetadataFileReturningPath(at: "old", with: file, expected: before)
                XCTAssertEqual(path, "new")
                XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/open/upload/init" }.count, 1)
                let remaining = try await source.listFiles(at: "42")
                XCTAssertEqual(remaining.map(\.path), ["new"])
                XCTAssertEqual(remaining.first?.name, "Ballad.flac")
            }
        }

        // 2. OSS returns HTTP 203 CallbackFailed and never commits; retry uploads a fresh stage and succeeds.
        do {
            let drive = Pan115WriteFixture(.oss203ThenSucceed)
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let before = try await source.metadataWritebackState(for: "old")
                let path = try await source.replaceMetadataFileReturningPath(at: "old", with: file, expected: before)
                XCTAssertEqual(path, "new")
                XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/open/upload/init" }.count, 2)
                let remaining = try await source.listFiles(at: "42")
                XCTAssertEqual(remaining.map(\.path), ["new"])
                XCTAssertEqual(remaining.first?.name, "Ballad.flac")
            }
        }

        // 3. Upload succeeds (instant upload) with transient directory listing lag; polling finds stage without re-uploading.
        do {
            let drive = Pan115WriteFixture(.listingLag)
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let before = try await source.metadataWritebackState(for: "old")
                let path = try await source.replaceMetadataFileReturningPath(at: "old", with: file, expected: before)
                XCTAssertEqual(path, "new")
                XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/open/upload/init" }.count, 1)
            }
        }

        // 4. Persistent HTTP 203 surfaces transient HTTPResponseFailure(203) instead of opaque URLError(-1011).
        do {
            let drive = Pan115WriteFixture(.oss203Persistent)
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let before = try await source.metadataWritebackState(for: "old")
                do {
                    _ = try await source.replaceMetadataFileReturningPath(at: "old", with: file, expected: before)
                    XCTFail("Persistent 203 must fail")
                } catch let failure as HTTPResponseFailure {
                    XCTAssertEqual(failure.statusCode, 203)
                    XCTAssertTrue(MetadataWriteFailurePolicy.isTransient(failure))
                }
                let remaining = try await source.listFiles(at: "42")
                XCTAssertEqual(remaining.map(\.path), ["old"])
                XCTAssertEqual(remaining.first?.name, "Ballad.flac")
            }
        }

        // 5. Provider JSON failure in OSS callback surfaces CloudDriveError.apiError instead of URLError(-1011).
        do {
            let drive = Pan115WriteFixture(.ossCallbackProviderError)
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let before = try await source.metadataWritebackState(for: "old")
                do {
                    _ = try await source.replaceMetadataFileReturningPath(at: "old", with: file, expected: before)
                    XCTFail("Callback business error must fail")
                } catch CloudDriveError.apiError(let code, let message) {
                    XCTAssertEqual(code, 10002)
                    XCTAssertEqual(message, "校验文件失败")
                }
                XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/open/upload/init" }.count, 1)
                let remaining = try await source.listFiles(at: "42")
                XCTAssertEqual(remaining.map(\.path), ["old"])
                XCTAssertEqual(remaining.first?.name, "Ballad.flac")
            }
        }

        // 6. Staging and backup names preserve the exact target extension and are hidden from concurrent scans.
        let token = "11111111-2222-3333-4444-555555555555"
        XCTAssertEqual(
            U115Source.temporarySiblingName(prefix: "primuse-stage-", matching: "Ballad.FLAC", token: token),
            "primuse-stage-\(token).FLAC"
        )
        XCTAssertEqual(
            U115Source.temporarySiblingName(prefix: "primuse-old-", matching: "Ballad.en.vtt", token: token),
            "primuse-old-\(token).vtt"
        )
        XCTAssertEqual(
            U115Source.temporarySiblingName(prefix: "primuse-stage-", matching: "NoExtension", token: token),
            "primuse-stage-\(token)"
        )
        XCTAssertTrue(U115Source.isInternalStagingName("primuse-stage-\(token).flac"))
        XCTAssertTrue(U115Source.isInternalStagingName("primuse-old-\(token).FLAC"))
        XCTAssertTrue(U115Source.isInternalStagingName("primuse-stage-\(token)"))
        XCTAssertFalse(U115Source.isInternalStagingName("primuse-stage-demo.flac"))
        XCTAssertFalse(U115Source.isInternalStagingName("Ballad.flac"))

        do {
            let listingFixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(
                #"{"state":true,"count":3,"data":[{"fn":"Ballad.flac","fc":"1","fs":"10","pc":"pc1","fid":"71"},{"fn":"primuse-stage-\#(token).flac","fc":"1","fs":"10","pc":"stage1","fid":"81"},{"fn":"primuse-old-\#(token).flac","fc":"1","fs":"10","pc":"old1","fid":"82"}]}"#.utf8
            ))])
            try await withPan115Connector(listingFixture) { source in
                let scanned = try await source.listFiles(at: "42", confirmingPreviouslyObservedPaths: ["pc1"])
                XCTAssertEqual(scanned.map(\.path), ["pc1"])
            }
        }
    }

    func testPan115LargeMultipartReplacementEnforcesSequentialInitOSSV4AndSameExtensionSwap() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: file) }
        let expectedSize: Int64 = 65 * 1024 * 1024 + 123
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("fLaC-large-header".utf8))
        try handle.truncate(atOffset: UInt64(expectedSize))
        try handle.close()

        let expectedFingerprint = try Pan115FileUpload.Fingerprint(file: file)
        let drive = Pan115WriteFixture(.multipart)
        let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
        try await withPan115Connector(fixture) { source in
            _ = try await source.listFiles(at: "42")
            let before = try await source.metadataWritebackState(for: "old")
            let path = try await source.replaceMetadataFileReturningPath(at: "old", with: file, expected: before)
            XCTAssertEqual(path, "new")
            let keys = await source.replacementIndexKeys(from: "old", to: path)
            XCTAssertEqual(keys?.old, "71")
            XCTAssertEqual(keys?.new, "81")
            let after = try await source.metadataWritebackState(for: path)
            XCTAssertEqual(after.fileSize, expectedSize)
            XCTAssertEqual(after.revision, expectedFingerprint.sha1)
            let remaining = try await source.listFiles(at: "42")
            XCTAssertEqual(remaining.map(\.path), ["new"])
            XCTAssertEqual(remaining.first?.name, "Ballad.flac")
        }
        XCTAssertTrue(drive.multipartSequentialEnabled)
        XCTAssertEqual(drive.multipartPartNumbers, Array(1...9))
        XCTAssertEqual(drive.multipartTotalBytes, expectedSize)
        XCTAssertTrue(drive.multipartCompleted)
    }

    func testPan115LyricsAndCoverUseRealNamesAndVerifyReturnedPickCodes() async throws {
        let lyrics = Data("[00:01.00]窗外的灯正亮".utf8)
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x02, 0xFF, 0xD9])
        for (isCover, exists, badReadback) in [(false, false, false), (false, true, false),
                                                (true, false, false), (true, true, false), (false, true, true)] {
            let content = isCover ? cover : lyrics
            let returned = badReadback ? Data(repeating: 0, count: content.count) : content
            let server = try LocalCloudServer(response: .init(status: 206,
                headers: ["Content-Range": "bytes 0-\(content.count - 1)/\(content.count)"], body: returned))
            let cdn = try await server.start()
            defer { server.stop() }
            let name = isCover ? "Ballad-cover.jpg" : "Ballad.lrc"
            let drive = Pan115WriteFixture(.success, cdn: cdn, sidecar: exists ? name : nil)
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let song = Song(id: "saved", title: "Library title", fileFormat: .flac, filePath: "old", sourceID: fixture.id)
                do {
                    if isCover {
                        let report = await SidecarWriteService.shared.writeSidecars(
                            for: song, using: source, coverData: content, lyricsLines: nil, createsCoverFile: false
                        )
                        XCTAssertEqual(report.coverWritten, exists)
                        XCTAssertTrue(report.errors.isEmpty, report.errors.description)
                        if !exists {
                            XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/open/upload/init" })
                            return
                        }
                    } else {
                        let target = try await source.lyricsSidecarTarget(for: song, request: .current(pinned: nil))
                        XCTAssertEqual(target.fileName, name)
                        XCTAssertEqual(target.exists, exists)
                        let receipt = try await source.writeLyricsSidecar(data: content, target: target, priority: .background)
                        XCTAssertEqual(receipt.writtenPath, "new")
                        XCTAssertEqual(receipt.readback, content)
                        let updated = try await source.lyricsSidecarTarget(for: song, request: .current(pinned: nil))
                        XCTAssertEqual(updated.existingPath, "new")
                    }
                    XCTAssertFalse(badReadback)
                } catch EmbeddedMetadataWritebackSourceError.remoteVerificationFailed {
                    XCTAssertTrue(badReadback)
                }
                let files = try await source.listFiles(at: "42")
                XCTAssertEqual(Set(files.map(\.name)), ["Ballad.flac", name])
                XCTAssertEqual(files.first(where: { $0.name == name })?.path, badReadback ? "side" : "new")
                XCTAssertEqual(files.first(where: { $0.name == "Ballad.flac" })?.path, "old")
            }
        }
    }

    func testPan115NamedSubtitleEditAndSerializedLyricsChooseDifferentFiles() async throws {
        for rawEdit in [true, false] {
            let data = Data((rawEdit ? "WEBVTT\n\n00:01.000 --> 00:02.000\n窗前有风" : "<tt><body/></tt>").utf8)
            let server = try LocalCloudServer(response: .init(status: 206,
                headers: ["Content-Range": "bytes 0-\(data.count - 1)/\(data.count)"], body: data))
            let cdn = try await server.start()
            defer { server.stop() }
            let drive = Pan115WriteFixture(.success, cdn: cdn, sidecar: "Ballad.en.vtt")
            let fixture = CloudHTTPFixture(responses: [], responder: drive.respond)
            try await withPan115Connector(fixture) { source in
                _ = try await source.listFiles(at: "42")
                let song = Song(id: "track", title: "Ballad", fileFormat: .flac, filePath: "old", sourceID: fixture.id)
                let document = try await SidecarWriteService.shared.lyricsDocumentTarget(named: "Ballad.en.vtt", for: song, using: source)
                let target = rawEdit ? document : try LyricsSidecarTargetPolicy.writeTarget(for: document)
                let receipt = try await source.writeLyricsSidecar(data: data, target: target, priority: .background)
                XCTAssertEqual(receipt.fileName, rawEdit ? "Ballad.en.vtt" : "Ballad.ttml")
                let files = try await source.listFiles(at: "42")
                XCTAssertEqual(files.first { $0.name == "Ballad.en.vtt" }?.path, rawEdit ? "new" : "side")
                XCTAssertEqual(files.first { $0.name == "Ballad.ttml" }?.path, rawEdit ? nil : "new")
            }
        }
    }

    private func withPan115Connector(
        _ fixture: CloudHTTPFixture, clock: CloudAdvancingClock = .init(),
        run: (U115Source) async throws -> Void
    ) async throws {
        let session = fixture.session()
        defer {
            session.invalidateAndCancel()
            fixture.remove()
            _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id)
        }
        let saved = await CloudTokenManager(sourceID: fixture.id).saveTokens(
            .init(accessToken: "fixture", refreshToken: "fixture", expiresAt: Date().addingTimeInterval(3600))
        )
        XCTAssertTrue(saved)
        try await run(U115Source(sourceID: fixture.id, session: session,
                                 requests: CloudRequestScheduler(timing: clock.timing),
                                 sleep: { _ in }))
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

    func testGoogleDriveOAuthConfigUsesDriveFileScope() {
        let config = GoogleDriveSource.oauthConfig(clientId: "test-client")
        XCTAssertEqual(config.scopes, [GoogleDrivePickerPolicy.fileScope])
    }

    func testGoogleDrivePickedFilesListsAllAuthorizedFilesWithParentIsolatedSidecars() async throws {
        let payload = """
        {
          "files": [
            {"id":"trackA","name":"01.flac","mimeType":"audio/flac","size":"1024","parents":["folderA"]},
            {"id":"lrcA","name":"01.lrc","mimeType":"text/plain","size":"128","parents":["folderA"]},
            {"id":"coverA","name":"cover.jpg","mimeType":"image/jpeg","size":"512","parents":["folderA"]},
            {"id":"trackB","name":"02.flac","mimeType":"audio/flac","size":"2048","parents":["folderB"]},
            {"id":"orphan","name":"03.mp3","mimeType":"audio/mpeg","size":"512"}
          ]
        }
        """
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(payload.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }

        let source = GoogleDriveSource(
            sourceID: fixture.id,
            session: session,
            tokenProvider: { "fixture" },
            storedAccessMode: .pickedFiles
        )
        let items = try await source.listFiles(at: "/")
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.allSatisfy { $0.parentPath == "/" })

        let queryItems = URLComponents(url: try XCTUnwrap(fixture.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "q" })?.value, GoogleDrivePickerPolicy.authorizedFilesQuery)
        XCTAssertEqual(queryItems.first(where: { $0.name == "supportsAllDrives" })?.value, "true")
        XCTAssertEqual(queryItems.first(where: { $0.name == "includeItemsFromAllDrives" })?.value, "true")

        let flatIndex = SidecarHintResolver.DirectoryIndex(items)
        let trackA = try XCTUnwrap(items.first(where: { $0.path == "trackA" }))
        let trackB = try XCTUnwrap(items.first(where: { $0.path == "trackB" }))
        let orphan = try XCTUnwrap(items.first(where: { $0.path == "orphan" }))

        let scannedA = try XCTUnwrap(SidecarHintResolver.scannableItem(trackA, index: flatIndex))
        let scannedB = try XCTUnwrap(SidecarHintResolver.scannableItem(trackB, index: flatIndex))
        let scannedOrphan = try XCTUnwrap(SidecarHintResolver.scannableItem(orphan, index: flatIndex))

        XCTAssertEqual(scannedA.sidecarHints?.coverPath, "coverA")
        XCTAssertEqual(scannedA.sidecarHints?.lyricsPath, "lrcA")
        XCTAssertNil(scannedB.sidecarHints?.coverPath)
        XCTAssertNil(scannedB.sidecarHints?.lyricsPath)
        XCTAssertNil(scannedOrphan.sidecarHints?.coverPath)
    }

    func testGoogleDrivePickedFilesAccountIdentifierUsesDriveAbout() async throws {
        let body = Data(#"{"user":{"permissionId":"perm-987654"}}"#.utf8)
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: body)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }

        let source = GoogleDriveSource(
            sourceID: fixture.id,
            session: session,
            tokenProvider: { "fixture" },
            storedAccessMode: .pickedFiles
        )
        let identifier = try await source.accountIdentifier()
        XCTAssertEqual(identifier, "perm-987654")
        XCTAssertEqual(fixture.requests.first?.url?.path, "/drive/v3/about")
    }

    func testGoogleDriveAppNotAuthorizedToFileMapsToPermissionDenied() {
        let body = Data(#"{"error":{"errors":[{"reason":"appNotAuthorizedToFile"}]}}"#.utf8)
        let error = GoogleDriveSource.sidecarUploadError(status: 403, body: body)
        guard case SourceFileMutationError.permissionDenied = error else {
            return XCTFail("Expected permissionDenied, got \(error)")
        }
    }

    func testGoogleDrivePickedFilesChangesAvoidsParentFolderWalk() async throws {
        let body = """
        {
          "newStartPageToken": "cursor-2",
          "changes": [
            {"fileId":"deleted-1","removed":true},
            {"fileId":"added-1","removed":false,"file":{"id":"added-1","name":"new.flac","mimeType":"audio/flac","parents":["unowned-folder"]}}
          ]
        }
        """
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(body.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }

        let source = GoogleDriveSource(
            sourceID: fixture.id,
            session: session,
            tokenProvider: { "fixture" },
            storedAccessMode: .pickedFiles
        )
        var index = SourceSyncIndex()
        index["deleted-1"] = SourceSyncIndexedItem(
            stableKey: "deleted-1",
            path: "deleted-1",
            parentPath: "/",
            isDirectory: false,
            songIDs: ["song-1"],
            size: 100,
            modifiedDate: nil,
            revision: nil,
            seenEpoch: 1
        )
        let changes = try await source.changes(since: ["account": "cursor-1"], roots: ["/"], index: index)
        XCTAssertEqual(changes.cursors["account"], "cursor-2")
        XCTAssertEqual(changes.deletedStableKeys, ["deleted-1"])
        XCTAssertTrue(changes.requiresDeepScan)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testGoogleDriveHalfMigratedStatesThrowWithoutListing() async throws {
        let fileScope = [GoogleDrivePickerPolicy.oauthScopeExtraKey: GoogleDrivePickerPolicy.fileScope]
        let cases: [(stored: GoogleDrivePickerPolicy.AccessMode?, extra: [String: String]?, path: String)] = [
            // drive.file 令牌 + 旧的文件夹根目录(重新授权没改目录、电视代登录后、刷新回来是 drive.file)。
            (nil, fileScope, "folderID"),
            (.legacyFullDrive, fileScope, "/"),
            // 已选文件源的配置里还留着文件夹(令牌记没记范围都一样)。
            (.pickedFiles, fileScope, "folderID"),
            (.pickedFiles, nil, "folderID"),
        ]
        for item in cases {
            let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(#"{"files":[]}"#.utf8))])
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let extra = item.extra
            let source = GoogleDriveSource(
                sourceID: fixture.id, session: session, tokenProvider: { "fixture" },
                requests: CloudRequestScheduler(), storedAccessMode: item.stored,
                tokenExtraProvider: { extra }
            )
            let context = "stored=\(item.stored?.rawValue ?? "nil") path=\(item.path)"
            do {
                _ = try await source.listFiles(at: item.path)
                XCTFail("A half-migrated source must not return a listing: \(context)")
            } catch SourceRootResolutionError.pickedFilesReselectionRequired {
            } catch {
                XCTFail("Unexpected \(error): \(context)")
            }
            do {
                _ = try await source.changes(since: ["account": "cursor-1"], roots: [item.path], index: SourceSyncIndex())
                XCTFail("A half-migrated source must not reconcile changes: \(context)")
            } catch SourceRootResolutionError.pickedFilesReselectionRequired {
            } catch {
                XCTFail("Unexpected \(error): \(context)")
            }
            XCTAssertEqual(fixture.requests.count, 0, "Nothing may be listed in a half-migrated state: \(context)")
        }
    }

    func testGoogleDriveLegacyTokenWithoutStoredModeKeepsFolderListing() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, body: Data(#"{"files":[]}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        // 这一版之前授权的源:没存访问方式,令牌没记范围,只带着旧的已选文件 ID 也不改变模式。
        let source = GoogleDriveSource(
            sourceID: fixture.id, session: session, tokenProvider: { "fixture" },
            requests: CloudRequestScheduler(), storedAccessMode: nil,
            tokenExtraProvider: { [GoogleDrivePickerPolicy.pickedFileIDsExtraKey: "picked-1"] }
        )
        _ = try await source.listFiles(at: "folderID")
        let query = URLComponents(url: try XCTUnwrap(fixture.requests.first?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(query, "'folderID' in parents and trashed = false")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testGoogleDrivePickedFilesListOncePerPassForSiblingLookups() async throws {
        let listing = """
        {"files":[
          {"id":"trackA","name":"01.flac","mimeType":"audio/flac","size":"1024","parents":["folderA"]},
          {"id":"trackB","name":"02.flac","mimeType":"audio/flac","size":"1024","parents":["folderA"]},
          {"id":"lrcA","name":"01.lrc","mimeType":"text/plain","size":"64","parents":["folderA"]}
        ]}
        """
        let fixture = CloudHTTPFixture(responses: [], responder: { request, _ in
            let path = request.url?.path ?? ""
            if path == "/drive/v3/files" { return .init(status: 200, body: Data(listing.utf8)) }
            let id = String(path.split(separator: "/").last ?? "")
            let name = id == "trackA" ? "01.flac" : "02.flac"
            return .init(status: 200, body: Data(#"{"name":"\#(name)","parents":["folderA"],"trashed":false}"#.utf8))
        })
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = GoogleDriveSource(
            sourceID: fixture.id, session: session, tokenProvider: { "fixture" },
            requests: CloudRequestScheduler(), storedAccessMode: .pickedFiles
        )
        _ = try await source.listFiles(at: "/")
        for (id, name) in [("trackA", "01.flac"), ("trackB", "02.flac")] {
            let song = Song(id: id, title: name, fileFormat: .flac, filePath: id, sourceID: fixture.id)
            _ = try await source.lyricsSidecarTarget(for: song, request: .current(pinned: nil))
        }
        let listings = fixture.requests.filter { $0.url?.path == "/drive/v3/files" }
        XCTAssertEqual(listings.count, 1, "Sibling lookups in the same pass reuse the authorized-files listing")
    }

    func testGoogleDriveAuthorizedListNotFoundAsksForReselection() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 404, body: Data(#"{"error":{"code":404}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = GoogleDriveSource(
            sourceID: fixture.id, session: session, tokenProvider: { "fixture" },
            requests: CloudRequestScheduler(), storedAccessMode: .pickedFiles
        )
        do {
            _ = try await source.listFiles(at: "/")
            XCTFail("A 404 on the authorized list is not an empty source")
        } catch SourceRootResolutionError.pickedFilesReselectionRequired {
            XCTAssertEqual(SourceRootResolutionError.pickedFilesReselectionRequired.localizedDescription,
                           String(localized: "gdrive_reselection_required"))
        }
    }

    func testGoogleDriveLegacyScopeRejectionAsksToChooseFiles() async throws {
        let scope = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#
        let ordinary = #"{"error":{"code":403,"message":"The user does not have sufficient permissions for this file.","errors":[{"reason":"insufficientFilePermissions"}]}}"#
        for (body, expectsDisabled) in [(scope, true), (ordinary, false)] {
            let fixture = CloudHTTPFixture(responses: [.init(status: 403, body: Data(body.utf8))])
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            let source = GoogleDriveSource(
                sourceID: fixture.id, session: session, tokenProvider: { "fixture" },
                requests: CloudRequestScheduler(), storedAccessMode: .legacyFullDrive
            )
            do {
                _ = try await source.listFiles(at: "folderID")
                XCTFail("403 must not list")
            } catch SourceRootResolutionError.googleDriveLegacyAccessDisabled {
                XCTAssertTrue(expectsDisabled)
            } catch CloudDriveError.permissionDenied {
                XCTAssertFalse(expectsDisabled)
            }
        }
    }

    @MainActor
    func testGoogleDrivePickerScanHoldsRemovalsUntilConfirmedAndRemovesExactlyThose() async throws {
        let harness = try PickedFilesScanHarness()
        defer { harness.tearDown() }
        harness.listing.set(["keep-id", "old-1", "old-2", "old-3"])
        try await harness.scan()
        XCTAssertEqual(harness.filePaths, ["keep-id", "old-1", "old-2", "old-3"])

        // 选择文件:令牌换了、源改了(扫描范围对不上上一份状态),这一轮只剩一个文件。
        harness.listing.set(["keep-id"])
        harness.simulatePickerCommit()
        try await harness.scan(afterPicker: true)
        XCTAssertEqual(harness.filePaths, ["keep-id", "old-1", "old-2", "old-3"], "A picker scan removes nothing by itself")
        XCTAssertEqual(harness.scanService.scanStates[harness.sourceID]?.pickedFilesRemovalCount, 3)

        // 确认之前 old-3 又被选回来:确认后只移除仍然不在的 old-1、old-2。
        harness.listing.set(["keep-id", "old-3"])
        await harness.scanService.confirmPickedFilesRemoval(
            sourceID: harness.sourceID, sourceManager: harness.sourceManager,
            library: harness.library, sourceStore: harness.sourceStore
        )
        try await harness.waitForScan()
        XCTAssertEqual(harness.filePaths, ["keep-id", "old-3"])
        XCTAssertNil(harness.scanService.scanStates[harness.sourceID]?.pickedFilesRemovalCount)
    }

    @MainActor
    func testGoogleDrivePickerScanKeepsEverythingWhenDeclined() async throws {
        let harness = try PickedFilesScanHarness()
        defer { harness.tearDown() }
        harness.listing.set(["keep-id", "old-1", "old-2"])
        try await harness.scan()
        harness.listing.set(["keep-id"])
        harness.simulatePickerCommit()
        try await harness.scan(afterPicker: true)
        XCTAssertEqual(harness.scanService.scanStates[harness.sourceID]?.pickedFilesRemovalCount, 2)

        await harness.scanService.keepPickedFilesRemoval(sourceID: harness.sourceID)
        XCTAssertNil(harness.scanService.scanStates[harness.sourceID]?.pickedFilesRemovalCount)
        // 之后的普通完整扫描照旧不删,也不再提示。
        try await harness.scan()
        XCTAssertEqual(harness.filePaths, ["keep-id", "old-1", "old-2"])
        XCTAssertNil(harness.scanService.scanStates[harness.sourceID]?.pickedFilesRemovalCount)
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
    static func formFields(of request: URLRequest) -> [String: String] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
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

/// 一个 Google Drive 已选文件源加上真实的扫描服务:列表由测试决定,连接器不碰钥匙串。
@MainActor
private final class PickedFilesScanHarness {
    let root: URL
    let listing: PickedFilesListing
    let fixture: CloudHTTPFixture
    let session: URLSession
    let sourceID: String
    let sourceStore: SourcesStore
    let library: MusicLibrary
    let scanService: ScanService
    let sourceManager: SourceManager

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let listing = PickedFilesListing()
        self.root = root
        self.listing = listing
        fixture = CloudHTTPFixture(responses: [], responder: { request, _ in
            let path = request.url?.path ?? ""
            if path == "/drive/v3/files" { return .init(status: 200, body: listing.body) }
            if path.hasSuffix("/changes/startPageToken") {
                return .init(status: 200, body: Data(#"{"startPageToken":"cursor-1"}"#.utf8))
            }
            if path.hasSuffix("/changes") {
                return .init(status: 200, body: Data(#"{"newStartPageToken":"cursor-1","changes":[]}"#.utf8))
            }
            return .init(status: 404, body: Data("{}".utf8))
        })
        session = fixture.session()
        var source = MusicSource(id: fixture.id, name: "Google Drive", type: .googleDrive, authType: .oauth)
        source.googleDriveAccessMode = .pickedFiles
        source.extraConfig = MusicSource.encodeScannedDirectories(["/"], into: nil, type: .googleDrive)
        sourceID = source.id
        sourceStore = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        sourceStore.add(source)
        library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let connector = GoogleDriveSource(
            sourceID: source.id, session: session, tokenProvider: { "fixture" },
            requests: CloudRequestScheduler(), storedAccessMode: .pickedFiles
        )
        scanService = ScanService(
            fileManager: PickedFilesScanFileManager(root: root),
            connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        sourceManager = SourceManager(sourcesProvider: { [source] in [source] })
    }

    var filePaths: [String] {
        library.songs.filter { $0.sourceID == sourceID }.map(\.filePath).sorted()
    }

    /// 再次选择文件:目录仍是「/」、访问方式不变。这里故意不让扫描范围变(不改源、不换钥匙串的
    /// 安全修订),证明暂存靠的是选择文件之后那条扫描入口,不靠范围变化碰巧让上一份状态失效。
    func simulatePickerCommit() {}

    func scan(afterPicker: Bool = false) async throws {
        if afterPicker {
            let started = await scanService.scanAfterPickedFilesChange(
                sourceID: sourceID, sourceManager: sourceManager, library: library, sourceStore: sourceStore
            )
            XCTAssertTrue(started)
        } else {
            let current = try XCTUnwrap(sourceStore.source(id: sourceID))
            XCTAssertTrue(scanService.scanSource(
                current, sourceManager: sourceManager, library: library,
                sourceStore: sourceStore, requestsContinuedProcessing: false
            ))
        }
        try await waitForScan()
    }

    func waitForScan() async throws {
        let deadline = Date().addingTimeInterval(20)
        while scanService.scanStates[sourceID]?.isScanning == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scanService.scanStates[sourceID]?.isScanning == true)
        XCTAssertNil(scanService.scanStates[sourceID]?.failureMessage)
    }

    func tearDown() {
        scanService.cancelAllActiveScans()
        session.invalidateAndCancel()
        fixture.remove()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PickedFilesListing: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func set(_ ids: [String]) { lock.withLock { self.ids = ids } }
    var body: Data {
        let files = lock.withLock { ids }.map { id -> [String: Any] in
            ["id": id, "name": "\(id).mp3", "mimeType": "audio/mpeg", "size": "4320000",
             "modifiedTime": "2026-10-30T10:20:30.123Z", "md5Checksum": "content-\(id)", "parents": ["folderA"]]
        }
        return (try? JSONSerialization.data(withJSONObject: ["files": files])) ?? Data()
    }
}

private final class PickedFilesScanFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

/// CloudHTTPFixture serializes calls to this in-memory provider.
private final class Pan115WriteFixture: @unchecked Sendable {
    enum Outcome: CaseIterable {
        case success, duplicate, originalChanged, stageRenameFailed, denied, lostDeleteReply, uploadDenied
    }
    enum UploadMode {
        case instant, multipart, oss203LateCommit, oss203ThenSucceed, oss203Persistent, ossCallbackProviderError, listingLag
    }
    let outcome: Outcome
    let uploadMode: UploadMode
    let cdn: URL?
    private var files: [[String: String]]
    private var pendingUpload: [String: String]?
    private var pendingStageCommitPolls = 0
    private var uploadInitCount = 0
    private(set) var multipartSequentialEnabled = false
    private(set) var multipartPartNumbers: [Int] = []
    private(set) var multipartTotalBytes: Int64 = 0
    private(set) var multipartCompleted = false

    private static func requestBody(of request: URLRequest) -> Data {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    init(_ outcome: Outcome, cdn: URL? = nil, sidecar: String? = nil) {
        self.outcome = outcome
        self.uploadMode = .instant
        self.cdn = cdn
        let old = ["fn": "Ballad.flac", "fc": "1", "fid": "71", "pc": "old", "fs": "8",
                   "sha1": String(repeating: "A", count: 40)]
        files = [old]
        if let sidecar {
            files.append(old.merging(["fn": sidecar, "pc": "side", "fid": "72"]) { _, value in value })
        }
        if outcome == .duplicate {
            files.append(old.merging(["fid": "72", "pc": "other"]) { _, new in new })
        }
    }

    init(_ uploadMode: UploadMode) {
        self.outcome = .success
        self.uploadMode = uploadMode
        self.cdn = nil
        let old = ["fn": "Ballad.flac", "fc": "1", "fid": "71", "pc": "old", "fs": "8",
                   "sha1": String(repeating: "A", count: 40)]
        files = [old]
    }

    func respond(_ request: URLRequest, _ count: Int) -> CloudHTTPFixture.Response {
        if request.url?.host == "fixture.oss-cn-shenzhen.aliyuncs.com" {
            if uploadMode == .multipart {
                guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("OSS4-HMAC-SHA256 ") == true,
                      request.value(forHTTPHeaderField: "x-oss-security-token") == "sts",
                      request.value(forHTTPHeaderField: "x-oss-content-sha256") == "UNSIGNED-PAYLOAD" else {
                    return .init(status: 403, body: Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8))
                }
                let query = request.url?.query ?? ""
                if request.httpMethod == "POST", query == "sequential&uploads" {
                    multipartSequentialEnabled = true
                    return .init(status: 200, body: Data("<InitiateMultipartUploadResult><UploadId>up-115</UploadId></InitiateMultipartUploadResult>".utf8))
                }
                if request.httpMethod == "POST", query == "uploads" {
                    multipartSequentialEnabled = false
                    return .init(status: 200, body: Data("<InitiateMultipartUploadResult><UploadId>up-115</UploadId></InitiateMultipartUploadResult>".utf8))
                }
                let queryItems = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                if request.httpMethod == "PUT",
                   let partString = queryItems.first(where: { $0.name == "partNumber" })?.value,
                   let partNumber = Int(partString),
                   queryItems.first(where: { $0.name == "uploadId" })?.value == "up-115" {
                    let body = Self.requestBody(of: request)
                    multipartPartNumbers.append(partNumber)
                    multipartTotalBytes += Int64(body.count)
                    return .init(status: 200, headers: ["ETag": "\"0123456789ABCDEF0123456789ABCDEF\""])
                }
                if request.httpMethod == "POST", query == "uploadId=up-115" {
                    let xml = String(decoding: Self.requestBody(of: request), as: UTF8.self)
                    guard request.value(forHTTPHeaderField: "x-oss-callback") != nil,
                          request.value(forHTTPHeaderField: "x-oss-callback-var") != nil,
                          xml.contains("<PartNumber>1</PartNumber>"),
                          xml.contains("<PartNumber>9</PartNumber>") else {
                        return .init(status: 400)
                    }
                    guard multipartSequentialEnabled else {
                        return .init(status: 200, body: Data(#"{"state":false,"message":"校验文件失败，请重新上传。","code":10002}"#.utf8))
                    }
                    multipartCompleted = true
                    if let staged = pendingUpload {
                        files.append(staged)
                        pendingUpload = nil
                    }
                    return .init(status: 200, body: Data(#"{"state":true,"code":0,"data":{"pick_code":"new","file_id":"81"}}"#.utf8))
                }
                return .init(status: 400)
            }
            let staged = pendingUpload
            pendingUpload = nil
            switch uploadMode {
            case .oss203LateCommit:
                if let staged {
                    pendingUpload = staged
                    pendingStageCommitPolls = 1
                }
                return .init(status: 203, body: Data("<Error><Code>CallbackFailed</Code><Message>timeout</Message></Error>".utf8))
            case .oss203ThenSucceed:
                if uploadInitCount == 1 {
                    return .init(status: 203, body: Data("<Error><Code>CallbackFailed</Code><Message>timeout</Message></Error>".utf8))
                }
                if let staged { files.append(staged) }
                return .init(status: 200, body: Data(#"{"state":true,"code":0,"data":{"pick_code":"new","file_id":"81"}}"#.utf8))
            case .oss203Persistent:
                return .init(status: 203, body: Data("<Error><Code>CallbackFailed</Code><Message>timeout</Message></Error>".utf8))
            case .ossCallbackProviderError:
                return .init(status: 200, body: Data(#"{"state":false,"code":10002,"message":"校验文件失败"}"#.utf8))
            case .instant, .listingLag, .multipart:
                if let staged { files.append(staged) }
                return .init(status: 200, body: Data(#"{"state":true}"#.utf8))
            }
        }
        let fields = CloudHTTPFixture.formFields(of: request)
        var payload: [String: Any] = ["state": true]
        switch request.url?.path {
        case "/open/ufile/files":
            if let delayed = pendingUpload, pendingStageCommitPolls > 0 {
                pendingStageCommitPolls -= 1
                if pendingStageCommitPolls == 0 {
                    files.append(delayed)
                    pendingUpload = nil
                }
            }
            payload["count"] = files.count
            payload["data"] = files
        case "/open/upload/init":
            if outcome == .uploadDenied { return .init(status: 403) }
            guard let name = fields["file_name"], let hash = fields["fileid"], let size = fields["file_size"],
                  fields["target"] == "U_1_42" else { return .init(status: 400) }
            uploadInitCount += 1
            let staged = ["fn": name, "fc": "1", "fid": "81", "pc": "new", "fs": size, "sha1": hash]
            switch uploadMode {
            case .instant:
                files.append(staged)
                if outcome == .originalChanged { files[0]["sha1"] = String(repeating: "B", count: 40) }
                payload["data"] = ["status": 2, "pick_code": "new"]
            case .listingLag:
                pendingUpload = staged
                pendingStageCommitPolls = 2
                payload["data"] = ["status": 2, "pick_code": "new"]
            case .multipart, .oss203LateCommit, .oss203ThenSucceed, .oss203Persistent, .ossCallbackProviderError:
                pendingUpload = staged
                payload["data"] = [
                    "status": 1,
                    "bucket": "fixture",
                    "object": "a/b",
                    "callback": ["callback": "{\"callbackUrl\":\"https://115.example/cb\"}", "callback_var": "{\"x:k\":\"v\"}"]
                ]
            }
        case "/open/upload/get_token":
            payload["data"] = [
                "endpoint": "https://oss-cn-shenzhen.aliyuncs.com",
                "AccessKeyId": "id",
                "AccessKeySecret": "secret",
                "SecurityToken": "sts"
            ]
        case "/open/ufile/downurl":
            guard fields["pick_code"] == "new", let cdn else { return .init(status: 404) }
            payload["data"] = ["81": ["url": ["url": cdn.absoluteString]]]
        case "/open/ufile/update":
            guard let id = fields["file_id"], let i = files.firstIndex(where: { $0["fid"] == id }),
                  let name = fields["file_name"], !name.isEmpty else { return .init(status: 400) }
            if outcome == .stageRenameFailed && id == "81" && name == "Ballad.flac" {
                payload = ["state": false, "code": 50000, "message": "rename failed"]
                break
            }
            // Real 115 `/open/ufile/update` silently keeps the file's original extension even when
            // `file_name` requests another extension, returning state=true with the requested name.
            let existingName = files[i]["fn"] ?? ""
            let existingExt = (existingName as NSString).pathExtension
            let effectiveName: String
            if !existingExt.isEmpty && (name as NSString).pathExtension != existingExt {
                effectiveName = (name as NSString).deletingPathExtension + "." + existingExt
            } else {
                effectiveName = name
            }
            // Real 115 `/open/ufile/update` rejects renaming onto an existing sibling name with 20004.
            if files.contains(where: { $0["fid"] != id && $0["fn"]?.caseInsensitiveCompare(effectiveName) == .orderedSame }) {
                payload = ["state": false, "code": 20004, "message": "很抱歉，该目录名称已存在。"]
                break
            }
            files[i]["fn"] = effectiveName
        case "/open/ufile/delete":
            guard fields["parent_id"] == "42", let id = fields["file_ids"] else { return .init(status: 400) }
            if outcome == .denied && id == "71" { return .init(status: 403) }
            files.removeAll { $0["fid"] == id }
            if outcome == .lostDeleteReply && id == "71" { return .init(status: 500) }
        default: return .init(status: 404)
        }
        return .init(status: 200, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
    }
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
    func advance(by interval: TimeInterval) { lock.withLock { instant += interval } }
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
