import Foundation
import Testing
@testable import PrimuseKit

@Suite("Feiniu library and session recovery")
struct FnMusicLibraryTests {
    /// 歌单索引照网页端那样一次请求、不带分页参数；歌单内曲目仍按页翻。
    @Test func playlistIndexIsFetchedOnceAndTracksArePaged() async throws {
        let fixture = FnMusicLibraryFixture()
        let summaries = (0..<51).map { ["guid": "p\($0)", "name": "List \($0)", "trackCount": $0 == 0 ? 51 : 0] as [String: Any] }
        fixture.setPage("/playlist/list", page: 1, list: summaries, total: 51)
        for i in 0..<51 {
            fixture.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, list: [], total: 0)
        }
        fixture.setPage("/track/playlist-detail/list", playlist: "p0", page: 1,
                        list: (0..<50).map { ["guid": "s\($0)"] }, total: 51)
        fixture.setPage("/track/playlist-detail/list", playlist: "p0", page: 2,
                        list: [["guid": "s50"]], total: 51)
        fixture.setPage("/track/playlist-detail/list", playlist: "p1", page: 1,
                        list: [["guid": "unexpected"]], total: 1)
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.failedPlaylistIDs == ["p1"])
        #expect(snapshot.playlists.map(\.id) == ["p0"] + (2..<51).map { "p\($0)" })
        #expect(snapshot.playlists.first?.trackIDs == (0..<51).map { "s\($0)" })
        #expect(snapshot.playlists.last?.trackIDs.isEmpty == true)
        #expect(fixture.requests.allSatisfy { request in
            request.url?.path.hasSuffix("password-login") == true
                || request.value(forHTTPHeaderField: "Cookie") != nil
        })
        #expect(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "authx") != nil })
        let indexRequests = fixture.requests.filter { $0.url?.path.hasSuffix("/playlist/list") == true }
        #expect(indexRequests.count == 1)
        #expect((indexRequests.first?.url?.query ?? "").isEmpty, "索引请求不带 page/size")
        // p1 每次都读不全：第一轮失败后补读一次，仍失败才记进 failedPlaylistIDs。
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("/track/playlist-detail/list") == true }.count == 53)
    }

    /// 明细翻到一半失败的歌单在同一次同步里补读一次，不再整份漏掉；顺序仍按服务端清单。
    @Test func playlistDetailsThatFailOnceAreReadAgainInTheSameSync() async throws {
        let fixture = FnMusicLibraryFixture(transientDetailFailures: ["p1": 1])
        fixture.setPage("/playlist/list", page: 1,
                        list: (0..<3).map { ["guid": "p\($0)", "name": "List \($0)"] }, total: 3)
        for i in 0..<3 {
            fixture.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1,
                            list: [["guid": "s\(i)"]], total: 1)
        }
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        let snapshot = try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(snapshot.playlists.map(\.id) == ["p0", "p1", "p2"])
        #expect(snapshot.playlists.map(\.trackIDs) == [["s0"], ["s1"], ["s2"]])
        let details = fixture.requests.filter { $0.url?.path.hasSuffix("/track/playlist-detail/list") == true }
        #expect(details.count == 4)
        let playlistTag = LogRedactionPolicy.digest("p1")
        #expect(diagnostics.messages.contains { $0.contains("result=failed playlist=\(playlistTag) attempt=1") && $0.contains("500") })
        #expect(diagnostics.messages.contains { $0.contains("result=complete playlist=\(playlistTag) attempt=2") && $0.contains("received=1") })
        #expect(diagnostics.messages.last?.contains("listed=3 detailed=3 failed=0") == true)
    }

    /// 每读全一个歌单就先交出去，不等整轮：补读成功的在第二轮交出，始终读不全的不交。
    @Test func playlistsAreHandedOverAsSoonAsEachOneIsRead() async throws {
        let fixture = FnMusicLibraryFixture(transientDetailFailures: ["p1": 1])
        fixture.setPage("/playlist/list", page: 1,
                        list: (0..<4).map { ["guid": "p\($0)", "name": "List \($0)"] }, total: 4)
        for i in [0, 1, 3] {
            fixture.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1,
                            list: [["guid": "s\(i)"]], total: 1)
        }
        fixture.setPage("/track/playlist-detail/list", playlist: "p2", page: 1,
                        list: [["guid": "unexpected"]], total: 2)
        let (client, _, _) = fixture.clients()
        let delivered = DeliveredPlaylists()
        let diagnostics = PlaylistDiagnostics()
        let snapshot = try await client.library.playlists(
            diagnosticLogger: { diagnostics.append($0) },
            onPlaylist: { await delivered.append($0) }
        )
        #expect(await delivered.ids == ["p0", "p3", "p1"])
        #expect(await delivered.trackIDs == [["s0"], ["s3"], ["s1"]])
        #expect(snapshot.playlists.map(\.id) == ["p0", "p1", "p3"])
        #expect(snapshot.failedPlaylistIDs == ["p2"])
        let failures = diagnostics.messages.filter { $0.contains("result=failed playlist=\(LogRedactionPolicy.digest("p2"))") }
        #expect(failures.count == 2)
        #expect(failures.allSatisfy { $0.contains("error=invalid-response") })
        #expect(diagnostics.messages.contains { $0.contains("stage=detail-page playlist=\(LogRedactionPolicy.digest("p2"))") && $0.contains("page=1 received=1 accumulated=0 reported_total=2") })
        #expect(diagnostics.messages.last?.contains("listed=4 detailed=3 failed=1") == true)
    }

    /// 飞牛同一个 deviceId 只认最后一次登录。曲库客户端与播放解析器以前各存各的 token，
    /// 谁登录都会让对方 401、再重新登录把对方挤掉；现在两边共用一次登录。
    @Test func libraryClientAndStreamResolverShareOneLogin() async throws {
        let fixture = FnMusicLibraryFixture(enforcesDeviceSessions: true, favorites: ["s0"])
        let (client, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        let credential = SourceCredential(username: "qa", password: "test")

        #expect(try await client.library.favorites() == ["s0"])
        let resolved = try await resolver.resolve(for: song, source: source, credential: credential)
        #expect(resolved.headers["Cookie"] == "music-token=token-1")
        #expect(try await client.library.favorites() == ["s0"])
        _ = try await resolver.resolve(for: song, source: source, credential: credential)

        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 1)
        #expect(fixture.unauthorizedCount == 0)
    }

    /// 两边同时第一次用到时也只登录一次。
    @Test func concurrentFirstUseByLibraryAndPlaybackLogsInOnce() async throws {
        let fixture = FnMusicLibraryFixture(enforcesDeviceSessions: true, favorites: ["s0"])
        let (client, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        async let favorites = client.library.favorites()
        async let resolved = resolver.resolve(for: song, source: source, credential: .init(username: "qa", password: "test"))
        _ = try await (favorites, resolved)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 1)
        #expect(fixture.unauthorizedCount == 0)
    }

    /// 会话在服务端过期后，先发现的一方重新登录一次，另一方被拒后直接改用新的 token，
    /// 不会再各自登录、来回挤掉对方。登录始终用同一个设备号。
    @Test func expiredSharedSessionIsRenewedOnceAndAdoptedByTheOtherClient() async throws {
        let fixture = FnMusicLibraryFixture(enforcesDeviceSessions: true, favorites: ["s0"])
        let (client, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        let credential = SourceCredential(username: "qa", password: "test")

        #expect(try await client.library.favorites() == ["s0"])
        _ = try await resolver.resolve(for: song, source: source, credential: credential)
        fixture.expireSessions()

        let renewed = try await resolver.resolve(for: song, source: source, credential: credential)
        #expect(renewed.headers["Cookie"] == "music-token=token-2")
        #expect(try await client.library.favorites() == ["s0"])
        _ = try await resolver.resolve(for: song, source: source, credential: credential)

        let logins = fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }
        #expect(logins.count == 2)
        #expect(fixture.unauthorizedCount == 2)
        let deviceIDs = try logins.map { request -> String in
            let body = try JSONSerialization.jsonObject(with: FnMusicLibraryFixture.body(request)) as? [String: Any]
            return try #require(body?["deviceId"] as? String)
        }
        #expect(Set(deviceIDs).count == 1)
    }

    /// 服务端照单全给、条数正好是 50 的整数倍时，以前会再翻一页拿到同一批歌单而报「重复项」。
    @Test func playlistIndexWithExactlyOnePageOfEntriesDoesNotRequestASecondPage() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/playlist/list", page: 1,
                           data: ["list": (0..<50).map { ["guid": "p\($0)", "name": "List \($0)"] }])
        fixture.setRawPage("/playlist/list", page: 2,
                           data: ["list": (0..<50).map { ["guid": "p\($0)", "name": "List \($0)"] }])
        for i in 0..<50 {
            fixture.setRawPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, data: ["list": NSNull(), "total": 0])
        }
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.playlists.count == 50)
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("/playlist/list") == true }.count == 1)
    }

    @Test func incompletePlaylistIndexCannotBecomeAnEmptyAuthoritativeSnapshot() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [], total: 1)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        await #expect(throws: FnMusicServiceError.self) {
            try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        }
        #expect(diagnostics.messages.last?.contains("stage=index result=failed") == true)
        #expect(diagnostics.messages.contains { $0.contains("received=0 reported_total=1") })
        #expect(!diagnostics.messages.contains { $0.contains("result=complete") })
    }

    @Test func playlistDiagnosticsDistinguishEmptyListAndCancellation() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [], total: 0)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        let empty = try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        #expect(empty.playlists.isEmpty)
        #expect(diagnostics.messages.last?.contains("listed=0 detailed=0 failed=0") == true)

        let cancelled = FnMusicLibraryClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await cancelled.playlists(diagnosticLogger: { diagnostics.append($0) })
        }
        #expect(diagnostics.messages.last?.contains("stage=index result=cancelled") == true)
    }

    @Test func playlistDiagnosticErrorsAreRedactedAndBounded() async {
        let diagnostics = PlaylistDiagnostics()
        let client = FnMusicLibraryClient { _ in
            throw FnMusicServiceError.invalidResponse(
                "private-test-playlist /private-test-folder username@example.invalid https://private-test.invalid\n"
                    + "password=private-test-value Cookie: music-token=private-test-cookie " + String(repeating: "x", count: 2_000)
            )
        }
        await #expect(throws: FnMusicServiceError.self) {
            try await client.playlists(diagnosticLogger: { diagnostics.append($0) })
        }
        let failure = diagnostics.messages.last ?? ""
        #expect(failure.contains("stage=index result=failed"))
        #expect(!failure.contains("private-test"))
        #expect(!failure.contains("\n"))
        #expect(failure.count < 600)
        #expect(failure.hasSuffix("error=invalid-response"))
        #expect(LogRedactionPolicy.errorSummary(NSError(
            domain: "private-test-domain", code: 123,
            userInfo: [NSLocalizedDescriptionKey: "private-test-account"]
        )) == "error=other")
    }

    @Test func invalidPlaylistDiagnosticsExposeFieldStatesWithoutValues() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [[
            "guid": 42,
            "name": "private-test-playlist",
            "id": "private-test-id",
            "playlistGUID": NSNull(),
            "title": "private-test-title",
        ]], total: 1)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        let snapshot = try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        #expect(!snapshot.isIndexComplete)
        #expect(snapshot.playlists.isEmpty)
        #expect(diagnostics.messages.contains {
            $0.contains("result=invalid-item row=1 guid=number name=string id=string playlistGUID=null title=string trackCount=missing")
        })
        #expect(diagnostics.messages.allSatisfy { !$0.contains("private-test") })
        #expect(diagnostics.messages.last?.contains("stage=fetch result=partial listed=1 detailed=0 failed=0 index_complete=false invalid=1") == true)
    }

    @Test func playlistNamesAndOpaqueIdentifiersPreserveUnicodeAndQueryCharacters() async throws {
        let fixture = FnMusicLibraryFixture()
        let names = ["\u{3055}\u{304F}\u{3089} / J-Pop", "🎧 👨‍👩‍👧‍👦", "Cafe\u{301}", "A/B \\\"&%+#?<>\nLive", "　中文　"]
        let ids = names.indices.map { " p\($0)/../+%2F?x=1&y=2#\u{200D} " }
        fixture.setPage("/playlist/list", page: 1, list: zip(ids, names).map {
            ["guid": $0.0, "name": $0.1]
        }, total: names.count)
        for id in ids {
            fixture.setPage("/track/playlist-detail/list", playlist: id, page: 1, list: [["guid": "song"]], total: 1)
        }
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.isIndexComplete)
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(snapshot.playlists.map(\.id) == ids)
        #expect(snapshot.playlists.map { Array($0.name.utf8) } == names.map { Array($0.utf8) })
        let details = fixture.requests.filter { $0.url?.path.hasSuffix("/track/playlist-detail/list") == true }
        #expect(details.count == names.count)
        #expect(details.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "playlistGUID" }?.value
        } == ids.map(Optional.some))
        #expect(details.allSatisfy { $0.url?.path == "/music/api/v1/track/playlist-detail/list" })
    }

    @Test func missingOrBlankPlaylistNamesDoNotInvalidateTheirStableIdentity() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [
            ["guid": "p0", "name": ""], ["guid": "p1", "name": " \n　"],
            ["guid": "p2", "name": NSNull()], ["guid": "p3"],
        ], total: 4)
        for i in 0..<4 {
            fixture.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, list: [], total: 0)
        }
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.isIndexComplete)
        #expect(snapshot.playlists.map(\.id) == ["p0", "p1", "p2", "p3"])
        #expect(snapshot.playlists.allSatisfy { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test func malformedIndexRowsDoNotBlockHealthyPlaylistsOrAuthorizePruning() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/playlist/list", page: 1, data: ["list": [
            NSNull(),
            ["guid": NSNull(), "name": "private-test-name"],
            ["guid": "bad-count", "name": "private-test-name", "trackCount": "not-a-count"],
            ["guid": "duplicate", "name": "First"],
            ["guid": "healthy", "name": "Healthy"],
            ["guid": "duplicate", "name": "Conflicting"],
        ], "total": 6])
        fixture.setPage("/track/playlist-detail/list", playlist: "healthy", page: 1, list: [["guid": "song"]], total: 1)
        let (client, _, _) = fixture.clients()
        let delivered = DeliveredPlaylists()
        let diagnostics = PlaylistDiagnostics()
        let snapshot = try await client.library.playlists(
            diagnosticLogger: { diagnostics.append($0) },
            onPlaylist: { await delivered.append($0) }
        )
        #expect(!snapshot.isIndexComplete)
        #expect(snapshot.playlists.map(\.id) == ["healthy"])
        #expect(snapshot.failedPlaylistIDs == ["bad-count", "duplicate"])
        #expect(await delivered.ids == ["healthy"])
        #expect(diagnostics.messages.contains { $0.contains("result=partial listed=6 usable=1 invalid=4") })
        #expect(diagnostics.messages.allSatisfy { !$0.contains("private-test") })
    }

    @Test func playlistTrackRepetitionsRetainServerOrder() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1,
                        list: [["guid": "p", "name": "我喜欢", "trackCount": 3, "coverId": "cover", "updatedAt": 42]], total: 1)
        fixture.setPage("/track/playlist-detail/list", playlist: "p", page: 1,
                        list: [["guid": "b"], ["guid": "a"], ["guid": "b"]], total: 3)
        let (client, _, _) = fixture.clients()
        let playlist = try #require(try await client.library.playlists().playlists.first)
        #expect(playlist.trackIDs == ["b", "a", "b"])
        #expect(playlist.coverReference == "fnmusic-cover/cover?revision=42")
    }

    @Test func nullableTrackIdentifiersUseTheFirstUsableAlias() async throws {
        let fixture = FnMusicLibraryFixture()
        let rows: [[String: Any]] = [
            ["guid": NSNull(), "trackGUID": "s0"],
            ["guid": "", "trackGUID": NSNull(), "id": "s1"],
            ["guid": "s2", "trackGUID": "unrelated", "id": "unrelated-id"],
        ]
        fixture.setPage("/playlist/list", page: 1, list: [["guid": "p", "name": "List", "coverId": NSNull()]], total: 1)
        fixture.setPage("/track/playlist-detail/list", playlist: "p", page: 1, list: rows, total: 3)
        fixture.setPage("/favorite-track/list", page: 1, list: rows, total: 3)
        let (client, _, _) = fixture.clients()
        let playlist = try #require(try await client.library.playlists().playlists.first)
        #expect(playlist.trackIDs == ["s0", "s1", "s2"])
        #expect(playlist.coverReference == nil)
        #expect(try await client.library.favorites() == ["s0", "s1", "s2"])
    }

    @Test func trackIdentifiersFollowTheCatalogInsteadOfFilenameRules() async throws {
        let rows: [[String: Any]] = [" s0 ", "private-test/1", "s\u{200B}2", ".", "s4\n"].map {
            ["guid": $0, "accessStatus": 0]
        }
        let catalogIDs = try rows.map { try #require(FnMusicCatalogTrack(json: $0)).guid }
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [["guid": "p", "name": "List"]], total: 1)
        fixture.setPage("/track/playlist-detail/list", playlist: "p", page: 1, list: rows, total: rows.count)
        fixture.setPage("/favorite-track/list", page: 1, list: rows, total: rows.count)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        let snapshot = try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(snapshot.playlists.first?.trackIDs == catalogIDs)
        #expect(try await client.library.favorites(diagnosticLogger: { diagnostics.append($0) }) == catalogIDs)
        #expect(diagnostics.messages.filter { $0.contains("result=complete") && $0.contains("id_shape=len=2 chars=alnum") }.count == 2)
    }

    @Test func identifierShapeDiagnosticsDescribeFormatWithoutContent() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [["guid": "hex", "name": "A"], ["guid": "slash", "name": "B"]], total: 2)
        fixture.setPage("/track/playlist-detail/list", playlist: "hex", page: 1,
                        list: [["guid": "0123456789abcdef0123456789ABCDEF"]], total: 1)
        fixture.setPage("/track/playlist-detail/list", playlist: "slash", page: 1,
                        list: [["guid": "private-test/song:1 x"]], total: 1)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        _ = try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        #expect(diagnostics.messages.contains { $0.hasSuffix("received=1 id_shape=hex32") })
        #expect(diagnostics.messages.contains { $0.hasSuffix("received=1 id_shape=len=21 chars=alnum,dash,dot,slash,space") })
        #expect(diagnostics.messages.allSatisfy { !$0.contains("private-test") })
    }

    @Test func unreadableFavoriteIsSkippedAndMarksTheSnapshotIncomplete() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/favorite-track/list", page: 1, list: [
            ["guid": "private-test-song", "accessStatus": 0],
            ["guid": NSNull(), "title": "private-test-title", "accessStatus": 3],
        ], total: 2)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        let snapshot = try await client.library.favoriteSnapshot(diagnosticLogger: { diagnostics.append($0) })
        #expect(snapshot.trackIDs == ["private-test-song"])
        #expect(!snapshot.isComplete)
        #expect(diagnostics.messages.contains {
            $0.contains("page=1 result=invalid-item row=2 guid=null trackGUID=missing id=missing access=missing action=skip")
        })
        #expect(diagnostics.messages.contains { $0.hasSuffix("result=skipped-items skipped=1 kept=1") })
        #expect(diagnostics.messages.last?.contains("stage=fetch result=complete received=1") == true)
        #expect(diagnostics.messages.allSatisfy { !$0.contains("private-test") })

        let healthy = FnMusicLibraryFixture()
        healthy.setPage("/favorite-track/list", page: 1, list: [["guid": "s0"]], total: 1)
        #expect(try await healthy.clients().0.library.favoriteSnapshot().isComplete)
    }

    @Test func unreadablePlaylistRowsAreSkippedWithoutBreakingPagingOrEmptyingThePlaylist() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [
            ["guid": "mixed", "name": "Mixed"], ["guid": "unreadable", "name": "Unreadable"],
        ], total: 2)
        var firstPage: [[String: Any]] = (0..<50).map { ["guid": "s\($0)"] }
        firstPage[3] = ["guid": NSNull(), "accessStatus": 3]
        fixture.setPage("/track/playlist-detail/list", playlist: "mixed", page: 1, list: firstPage, total: 52)
        fixture.setRawPage("/track/playlist-detail/list", playlist: "mixed", page: 2,
                           data: ["list": [["guid": "s50"], "not-an-object"], "total": 52])
        fixture.setPage("/track/playlist-detail/list", playlist: "unreadable", page: 1,
                        list: [["guid": ""], ["trackGUID": 7]], total: 2)
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        let mixed = try #require(snapshot.playlists.first { $0.id == "mixed" })
        #expect(mixed.trackIDs == (0...50).filter { $0 != 3 }.map { "s\($0)" })
        #expect(mixed.reportedTrackCount == 52)
        let unreadable = try #require(snapshot.playlists.first { $0.id == "unreadable" })
        #expect(unreadable.trackIDs.isEmpty)
        #expect(unreadable.reportedTrackCount == 2)
    }

    @Test func serverVersionDiagnosticsExcludeOtherConfigurationFields() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/sys/config", page: 1, data: [
            "serverVersion": "1.0.10", "mediasrvVersion": "0.8.42",
            "serverName": "private-test-server", "serverGUID": "private-test-guid",
            "nasOAuth": ["clientId": "private-test-client", "url": "https://private-test.invalid"],
        ])
        fixture.setPage("/playlist/list", page: 1, list: [], total: 0)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        _ = try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        #expect(diagnostics.messages.contains {
            $0.hasSuffix("stage=server api=v1 server_version=1.0.10 media_version=0.8.42")
        })
        #expect(diagnostics.messages.allSatisfy { !$0.contains("private-test") })
    }

    @Test func invalidVersionLabelsCannotInjectSensitiveConfigurationIntoLogs() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/sys/config", page: 1, data: [
            "serverVersion": "1.0.10\nprivate-test-secret", "mediasrvVersion": "https://private-test.invalid",
        ])
        fixture.setPage("/playlist/list", page: 1, list: [], total: 0)
        let (client, _, _) = fixture.clients()
        let diagnostics = PlaylistDiagnostics()
        _ = try await client.library.playlists(diagnosticLogger: { diagnostics.append($0) })
        #expect(diagnostics.messages.contains {
            $0.hasSuffix("stage=server api=v1 server_version=unknown media_version=unknown")
        })
        #expect(diagnostics.messages.allSatisfy { !$0.contains("private-test") && !$0.contains("\n") })
    }

    @Test func catalogFallsBackToAlbumOriginalReleaseYear() throws {
        var json: [String: Any] = [
            "guid": "s0", "title": "Song", "year": NSNull(),
            "album": ["guid": "a0", "name": "Album", "originalReleaseYear": 2003],
            "audioSpec": ["format": "flac"],
        ]
        let fallback = try #require(FnMusicCatalogTrack(json: json))
        #expect(fallback.makeSong(sourceID: "source")?.year == 2003)
        json["year"] = 2005
        let explicit = try #require(FnMusicCatalogTrack(json: json))
        #expect(explicit.year == 2005)
        json.removeValue(forKey: "year")
        json["album"] = ["guid": "a0", "name": "Album"]
        #expect(FnMusicCatalogTrack(json: json)?.year == nil)
    }

    @Test func favoriteWritesAreIdempotentAndConfirmedAcrossAllPages() async throws {
        let fixture = FnMusicLibraryFixture(favorites: (0..<51).map { "s\($0)" })
        let (client, _, _) = fixture.clients()
        #expect(try await client.library.favorites().count == 51)
        #expect(try await client.library.setFavorite(trackID: "new.track", isFavorite: true).trackIDs.contains("new.track"))
        _ = try await client.library.setFavorite(trackID: "new.track", isFavorite: true)
        #expect(try await !client.library.setFavorite(trackID: "new.track", isFavorite: false).trackIDs.contains("new.track"))
        _ = try await client.library.setFavorite(trackID: "new.track", isFavorite: false)
        let writes = fixture.requests.filter { $0.url?.path.contains("/favorite-track/") == true && $0.httpMethod == "POST" }
        #expect(writes.map { $0.url!.lastPathComponent } == ["create", "delete"])
        for write in writes {
            let object = try JSONSerialization.jsonObject(with: FnMusicLibraryFixture.body(write)) as? [String: String]
            #expect(object == ["trackGUID": "new.track"])
        }
    }

    @Test func malformedFavoritesAndUnconfirmedWritesFailClosed() async throws {
        let malformed = FnMusicLibraryFixture()
        malformed.setPage("/favorite-track/list", page: 1, list: [["guid": "a"], ["guid": "a"]], total: 2)
        let (reader, _, _) = malformed.clients()
        await #expect(throws: FnMusicServiceError.self) { try await reader.library.favorites() }
        let rejected = FnMusicLibraryFixture(ignoresFavoriteWrites: true)
        let (writer, _, _) = rejected.clients()
        await #expect(throws: FnMusicServiceError.self) {
            try await writer.library.setFavorite(trackID: "new", isFavorite: true)
        }
        let before = rejected.requests.count
        await #expect(throws: FnMusicServiceError.self) {
            try await writer.library.setFavorite(trackID: "nested/song", isFavorite: true)
        }
        #expect(rejected.requests.count == before)
    }

    /// 飞牛把空集合序列化成 null（`{"list":null,"total":0}`），命令类接口甚至整个 data 为 null。
    /// 以前这两种都被判成「响应不是有效的飞牛音乐 JSON」，歌单与收藏同步三天没成功过一次。
    @Test func emptyServerCollectionsArriveAsNullListsOrNullData() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/favorite-track/list", page: 1, data: ["list": NSNull(), "total": 0])
        fixture.setRawPage("/playlist/list", page: 1, data: NSNull())
        let (client, _, _) = fixture.clients()
        #expect(try await client.library.favorites().isEmpty)
        let snapshot = try await client.library.playlists()
        #expect(snapshot.playlists.isEmpty)
        #expect(snapshot.failedPlaylistIDs.isEmpty)
    }

    /// 没有 total 时短页就是末页；歌单清单不分页、一次全给，条数可以超过我们请求的 size。
    @Test func listsWithoutTotalEndAtTheFirstShortPage() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/favorite-track/list", page: 1, data: ["list": (0..<50).map { ["guid": "s\($0)"] }])
        fixture.setRawPage("/favorite-track/list", page: 2, data: ["list": [["guid": "s50"]]])
        fixture.setRawPage("/playlist/list", page: 1,
                           data: ["list": (0..<60).map { ["guid": "p\($0)", "name": "List \($0)"] }])
        for i in 0..<60 {
            fixture.setRawPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, data: ["list": NSNull(), "total": 0])
        }
        let (client, _, _) = fixture.clients()
        #expect(try await client.library.favorites() == (0..<51).map { "s\($0)" })
        let snapshot = try await client.library.playlists()
        #expect(snapshot.playlists.map(\.id) == (0..<60).map { "p\($0)" })
        #expect(snapshot.playlists.allSatisfy { $0.trackIDs.isEmpty })
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("/playlist/list") == true }.count == 1)
    }

    /// 带 total 的清单一次给全也照收；说了 total 却给了短页、list 不是数组、没有 total 又
    /// 永远返回同一满页，仍然是坏响应而不是被当成空集合或无限翻页。
    @Test func completeUnpagedListsAreAcceptedAndBrokenPagesStillFailClosed() async throws {
        let whole = FnMusicLibraryFixture()
        whole.setPage("/playlist/list", page: 1,
                      list: (0..<60).map { ["guid": "p\($0)", "name": "List \($0)"] }, total: 60)
        for i in 0..<60 {
            whole.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, list: [], total: 0)
        }
        let (reader, _, _) = whole.clients()
        #expect(try await reader.library.playlists().playlists.count == 60)

        let short = FnMusicLibraryFixture()
        short.setRawPage("/favorite-track/list", page: 1, data: ["list": NSNull(), "total": 3])
        let (shortReader, _, _) = short.clients()
        await #expect(throws: FnMusicServiceError.self) { try await shortReader.library.favorites() }

        let malformed = FnMusicLibraryFixture()
        malformed.setRawPage("/favorite-track/list", page: 1, data: ["list": "nope"])
        let (malformedReader, _, _) = malformed.clients()
        await #expect(throws: FnMusicServiceError.self) { try await malformedReader.library.favorites() }

        let looping = FnMusicLibraryFixture()
        let full = (0..<50).map { ["guid": "s\($0)"] }
        looping.setRawPage("/favorite-track/list", page: 1, data: ["list": full])
        looping.setRawPage("/favorite-track/list", page: 2, data: ["list": full])
        let (loopingReader, _, _) = looping.clients()
        await #expect(throws: FnMusicServiceError.self) { try await loopingReader.library.favorites() }
        #expect(looping.requests.filter { $0.url?.path.hasSuffix("/favorite-track/list") == true }.count == 2)
    }

    @Test(arguments: [99999, 120001, 401, 403])
    func streamBusinessAuthenticationErrorsRefreshExactlyOnce(code: Int) async throws {
        let fixture = FnMusicLibraryFixture(streamError: code)
        let (_, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        let resolved = try await resolver.resolve(for: song, source: source, credential: .init(username: "qa", password: "test"))
        #expect(resolved.headers["Cookie"] == "music-token=token-2")
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 2)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("track/stream") == true }.count == 2)
    }

    @Test func ordinaryHTTP200MediaErrorsDoNotCauseRepeatedLogins() async throws {
        let fixture = FnMusicLibraryFixture(streamError: 500)
        let (_, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        await #expect(throws: StreamResolveError.badServerResponse(200)) {
            try await resolver.resolve(for: song, source: source, credential: .init(username: "qa", password: "test"))
        }
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 1)
    }
}

private final class FnMusicLibraryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let host = UUID().uuidString.lowercased() + ".invalid"
    private var pages: [String: Data] = [:]
    private var favorites: [String]
    private let ignoresFavoriteWrites: Bool
    private let streamError: Int?
    /// 照真服务端的行为：同一个 deviceId 再登录一次，之前发出去的 token 就 401。
    private let enforcesDeviceSessions: Bool
    private var tokenByDevice: [String: String] = [:]
    private var unauthorized = 0
    private var transientDetailFailures: [String: Int]
    private var loginCount = 0
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    var unauthorizedCount: Int { lock.withLock { unauthorized } }
    /// 模拟服务端会话过期：之前发出的 token 全部作废。
    func expireSessions() { lock.withLock { tokenByDevice.removeAll() } }

    init(
        enforcesDeviceSessions: Bool = false,
        transientDetailFailures: [String: Int] = [:],
        favorites: [String] = [],
        ignoresFavoriteWrites: Bool = false,
        streamError: Int? = nil
    ) {
        self.enforcesDeviceSessions = enforcesDeviceSessions
        self.transientDetailFailures = transientDetailFailures
        self.favorites = favorites
        self.ignoresFavoriteWrites = ignoresFavoriteWrites
        self.streamError = streamError
    }

    func setPage(_ path: String, playlist: String = "", page: Int, list: [[String: Any]], total: Int) {
        lock.withLock { pages["\(path)|\(playlist)|\(page)"] = Self.json(["code": 0, "data": ["list": list, "total": total]]) }
    }

    /// 原样塞一个 `data`：用来摆服务端真实会给的形状（`list: null`、整个 data 为 null、没有 total）。
    func setRawPage(_ path: String, playlist: String = "", page: Int, data: Any) {
        lock.withLock { pages["\(path)|\(playlist)|\(page)"] = Self.json(["code": 0, "data": data]) }
    }

    func clients() -> (FnMusicServiceClient, FnMusicStreamResolver, MusicSource) {
        FnMusicLibraryURLProtocol.register(self, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FnMusicLibraryURLProtocol.self]
        let session = URLSession(configuration: config)
        let source = MusicSource(id: host, name: "Feiniu", type: .fnMusic, host: host, port: 5666, useSsl: false, username: "qa")
        // 和真机一样，曲库客户端与播放解析器共用同一个会话仓库。
        let sessions = SourceLoginSessionStore()
        return (FnMusicServiceClient(source: source, credential: .init(username: "qa", password: "test"),
                                     session: session, sessionStore: sessions),
                FnMusicStreamResolver(session: URLSession(configuration: config), sessionStore: sessions), source)
    }

    func response(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            var saved = request
            if request.httpMethod == "POST" { saved.httpBody = Self.body(request) }
            recorded.append(saved)
            let path = request.url!.path.replacingOccurrences(of: FnMusicAPIProtocol.apiPath, with: "")
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let headers = ["Content-Type": "application/json"]
            if path == "/user/password-login" {
                loginCount += 1
                let token = "token-\(loginCount)"
                if let body = try? JSONSerialization.jsonObject(with: saved.httpBody ?? Data()) as? [String: Any],
                   let device = body["deviceId"] as? String {
                    tokenByDevice[device] = token
                }
                return (200, headers, Self.json(["code": 200, "data": ["userToken": token]]))
            }
            if enforcesDeviceSessions {
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                let token = cookie.components(separatedBy: "; ").first { $0.hasPrefix("music-token=") }
                    .map { String($0.dropFirst("music-token=".count)) }
                guard let token, tokenByDevice.values.contains(token) else {
                    unauthorized += 1
                    return (401, headers, Data())
                }
            }
            if path == "/track/playlist-detail/list", let playlist = query["playlistGUID"],
               let remaining = transientDetailFailures[playlist], remaining > 0 {
                transientDetailFailures[playlist] = remaining - 1
                return (500, headers, Data())
            }
            if path == "/track/stream" {
                if let streamError, loginCount == 1 {
                    return (200, headers, Self.json(["code": String(streamError), "msg": "INVALID TOKEN"]))
                }
                return (206, ["Content-Type": "audio/flac", "Content-Range": "bytes 0-1/8", "Content-Length": "2"], Data([1, 2]))
            }
            let page = Int(query["page"] ?? "1") ?? 1
            if let payload = pages["\(path)|\(query["playlistGUID"] ?? "")|\(page)"] { return (200, headers, payload) }
            if path == "/favorite-track/list" {
                let start = min((page - 1) * 50, favorites.count)
                let ids = favorites.dropFirst(start).prefix(50).map { ["guid": $0] }
                return (200, headers, Self.json(["code": 0, "data": ["list": ids, "total": favorites.count]]))
            }
            if path == "/favorite-track/create" || path == "/favorite-track/delete" {
                if !ignoresFavoriteWrites,
                   let body = try? JSONSerialization.jsonObject(with: saved.httpBody ?? Data()) as? [String: String],
                   let id = body["trackGUID"] {
                    favorites.removeAll { $0 == id }
                    if path.hasSuffix("create") { favorites.append(id) }
                }
                return (200, headers, Self.json(["code": 0, "data": NSNull()]))
            }
            return (404, headers, Data())
        }
    }

    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class FnMusicLibraryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: FnMusicLibraryFixture] = [:]
    static func register(_ fixture: FnMusicLibraryFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, headers, data) = fixture.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PlaylistDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var messages: [String] { lock.withLock { entries } }

    func append(_ message: String) { lock.withLock { entries.append(message) } }
}

private actor DeliveredPlaylists {
    private(set) var ids: [String] = []
    private(set) var trackIDs: [[String]] = []

    func append(_ playlist: FnMusicPlaylist) {
        ids.append(playlist.id)
        trackIDs.append(playlist.trackIDs)
    }
}
