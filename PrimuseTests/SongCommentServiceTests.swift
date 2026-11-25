import Foundation
import PrimuseKit
import SwiftUI
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import Primuse

@MainActor
final class SongCommentServiceTests: XCTestCase {
    private var suiteNames: [String] = []
    private var mockHosts: [String] = []

    override func tearDown() {
        for host in mockHosts {
            CommentMockURLProtocol.unregister(host: host)
        }
        mockHosts.removeAll()
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SongCommentServiceTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name) ?? .standard
    }

    private func makeMockSession(
        host: String,
        handler: @escaping @Sendable (URLRequest) -> (Int, Data, [String: String])
    ) -> URLSession {
        mockHosts.append(host)
        CommentMockURLProtocol.register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommentMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func sampleSong() -> Song {
        Song(
            id: "comment-test-song-1",
            title: "夜空中最亮的星",
            albumTitle: "世界",
            artistName: "逃跑计划",
            duration: 252,
            fileFormat: .flac,
            filePath: "/music/star.flac",
            sourceID: "local"
        )
    }

    // MARK: - Service: Fallback, Caching, Pinning, Pagination, Probe

    func testSequentialFallbackCachingAndPreferredServerPinning() async throws {
        let host = "comments-\(UUID().uuidString.lowercased()).local"
        let recorder = CommentRequestRecorder()
        let session = makeMockSession(host: host) { request in
            recorder.record(request)
            let path = request.url?.path ?? ""
            if path == "/failing" {
                return (500, Data("internal error".utf8), [:])
            }
            if path == "/empty" {
                return (200, Data(#"{"total":0,"comments":[]}"#.utf8), ["Content-Type": "application/json"])
            }
            if path == "/primary" {
                let body = """
                {
                  "total": 1280,
                  "hasMore": true,
                  "nextCursor": "cur-2",
                  "hotComments": [
                    {
                      "id": "hot-1",
                      "author": "林间听风",
                      "authorId": "u-100",
                      "content": "前奏响起的那一刻，仿佛回到了大学晚自习后骑车回宿舍的夏夜。",
                      "likedCount": 15420,
                      "location": "上海",
                      "pinned": true,
                      "replies": [
                        { "id": "r-1", "author": "阿泽", "content": "每次听到副歌都会起鸡皮疙瘩。" }
                      ]
                    }
                  ],
                  "comments": [
                    {
                      "id": "c-1",
                      "author": "Nora",
                      "content": "Headphones on, world off.",
                      "likedCount": 98
                    }
                  ]
                }
                """
                return (200, Data(body.utf8), ["Content-Type": "application/json"])
            }
            return (404, Data(), [:])
        }

        let service = SongCommentService(session: session)
        let query = SongCommentQuery(song: sampleSong())
        let serverFail = CommentAPIServer(id: "s-fail", name: "Fail", address: "https://\(host)/failing")
        let serverEmpty = CommentAPIServer(id: "s-empty", name: "Empty", address: "https://\(host)/empty")
        let serverPrimary = CommentAPIServer(id: "s-ok", name: "Primary", address: "https://\(host)/primary")

        // 1. Sequential fallback skips 500 and empty, lands on Primary.
        let first = try await service.fetchFirstPage(
            query: query,
            servers: [serverFail, serverEmpty, serverPrimary],
            sort: .hot
        )
        let resolved = try XCTUnwrap(first)
        XCTAssertEqual(resolved.server.id, "s-ok")
        XCTAssertEqual(resolved.page.total, 1280)
        XCTAssertEqual(resolved.page.hotComments.count, 1)
        XCTAssertEqual(resolved.page.comments.count, 1)
        XCTAssertEqual(recorder.count, 3)

        // 2. Cache hit makes zero new HTTP requests.
        let cached = try await service.fetchFirstPage(
            query: query,
            servers: [serverFail, serverEmpty, serverPrimary],
            sort: .hot
        )
        XCTAssertEqual(cached?.server.id, "s-ok")
        XCTAssertEqual(recorder.count, 3)

        // 3. Force refresh bypasses cache.
        _ = try await service.fetchFirstPage(
            query: query,
            servers: [serverPrimary],
            sort: .hot,
            forceRefresh: true
        )
        XCTAssertEqual(recorder.count, 4)

        // 4. Pinning preferredServerID to empty server returns nil without falling back to Primary.
        let pinnedEmpty = try await service.fetchFirstPage(
            query: query,
            servers: [serverEmpty, serverPrimary],
            preferredServerID: serverEmpty.id,
            sort: .hot
        )
        XCTAssertNil(pinnedEmpty)
        XCTAssertEqual(recorder.count, 5)

        // 5. clearCache forces re-fetch on subsequent call.
        await service.clearCache()
        _ = try await service.fetchFirstPage(query: query, servers: [serverPrimary], sort: .hot)
        XCTAssertEqual(recorder.count, 6)
    }

    func testPaginationUsesCursorAndPageIncrement() async throws {
        let host = "comments-page-\(UUID().uuidString.lowercased()).local"
        let recorder = CommentRequestRecorder()
        let session = makeMockSession(host: host) { request in
            recorder.record(request)
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let page = items.first(where: { $0.name == "page" })?.value
            let cursor = items.first(where: { $0.name == "cursor" })?.value
            if page == "2", cursor == "cursor-page-2" {
                let body = #"{"total":30,"hasMore":false,"comments":[{"id":"c-21","author":"Page2User","content":"Second page item","likedCount":12}]}"#
                return (200, Data(body.utf8), ["Content-Type": "application/json"])
            }
            return (400, Data(), [:])
        }

        let service = SongCommentService(session: session)
        let server = CommentAPIServer(id: "s-page", name: "Paged", address: "https://\(host)/comments")
        let page2 = try await service.fetchNextPage(
            server: server,
            query: SongCommentQuery(song: sampleSong()),
            sort: .latest,
            page: 2,
            cursor: "cursor-page-2"
        )
        XCTAssertEqual(page2.comments.map(\.id), ["c-21"])
        XCTAssertFalse(page2.hasMore)
        XCTAssertEqual(recorder.count, 1)
    }

    func testProbeSendsDraftAuthorizationWithoutReadingKeychain() async {
        let host = "comments-probe-\(UUID().uuidString.lowercased()).local"
        let recorder = CommentRequestRecorder()
        let session = makeMockSession(host: host) { request in
            recorder.record(request)
            let auth = request.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer draft-secret-99" {
                let body = #"{"total":42,"comments":[{"id":"p1","author":"Alice","content":"Verified!"}]}"#
                return (200, Data(body.utf8), ["Content-Type": "application/json"])
            }
            return (401, Data(), [:])
        }

        let query = SongCommentQuery(song: sampleSong())
        let authorizedServer = CommentAPIServer(
            id: "draft-id",
            name: "Draft",
            address: "https://\(host)/probe/{{title}}",
            authorization: "Bearer draft-secret-99"
        )
        let ok = await SongCommentService.probe(server: authorizedServer, query: query, session: session)
        XCTAssertEqual(ok, .found(total: 42, loadedCount: 1))
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer draft-secret-99")

        let unauthorizedServer = CommentAPIServer(
            id: "draft-id-2",
            name: "DraftNoAuth",
            address: "https://\(host)/probe/{{title}}",
            authorization: nil
        )
        let failed = await SongCommentService.probe(server: unauthorizedServer, query: query, session: session)
        if case .failed(let message) = failed {
            XCTAssertTrue(message.contains("401"), "Unexpected failure message: \(message)")
        } else {
            XCTFail("Expected 401 failure, got \(failed)")
        }
    }

    // MARK: - Persistence, Redaction, Moderation, Settings Discovery

    func testCommentServerSettingsStripCredentialsAndOfflineBackupRedactsSecrets() throws {
        let defaults = makeDefaults()
        let server = CommentAPIServer(
            id: "srv-backup",
            name: "Self Hosted",
            address: "https://comments.example.com/api",
            authorization: "Bearer super-secret-value",
            isEnabled: true
        )
        CommentAPIServerSettings(servers: [server]).save(defaults: defaults)
        let persistedBlob = try XCTUnwrap(defaults.data(forKey: CommentAPIServerSettings.defaultsKey))
        XCTAssertFalse(String(decoding: persistedBlob, as: UTF8.self).contains("super-secret-value"))

        // Inject a legacy blob with embedded secret and verify OfflineSettingsBackupService strips it both ways.
        let legacyWithSecret = try JSONSerialization.data(withJSONObject: [
            "servers": [[
                "id": "srv-backup",
                "name": "Self Hosted",
                "address": "https://user:pass@comments.example.com/api?token=leaked-token",
                "authorization": "Bearer leaked-header",
                "isEnabled": true,
            ]]
        ])
        defaults.set(legacyWithSecret, forKey: CommentAPIServerSettings.defaultsKey)

        let backup = try OfflineSettingsBackupService.snapshot(defaults: defaults, sharedDefaults: nil)
        let snapshotData = try XCTUnwrap(
            backup.standard.values[CommentAPIServerSettings.defaultsKey].flatMap(LANSettingsBundle.decodeValue) as? Data
        )
        let snapshotText = String(decoding: snapshotData, as: UTF8.self)
        XCTAssertFalse(snapshotText.contains("leaked-header"))
        XCTAssertFalse(snapshotText.contains("leaked-token"))

        defaults.removeObject(forKey: CommentAPIServerSettings.defaultsKey)
        var incoming = backup
        incoming.standard.values[CommentAPIServerSettings.defaultsKey] = LANSettingsBundle.encodeValue(legacyWithSecret)
        let cloud = CloudKVSSync(store: nil, defaults: defaults, observing: nil)
        try OfflineSettingsBackupService.restorePreferences(incoming, defaults: defaults, cloud: cloud, sharedDefaults: nil)
        let restored = CommentAPIServerSettings.load(defaults: defaults)
        XCTAssertEqual(restored.servers.count, 1)
        XCTAssertNil(restored.servers.first?.authorization)
        XCTAssertEqual(restored.servers.first?.address, "https://comments.example.com/api")
    }

    func testStoreVisibilityGateReorderAndModerationPersistence() {
        let defaults = makeDefaults()
        let store = CommentAPIServerStore(defaults: defaults, registersCloudSync: false)
        XCTAssertFalse(store.hasEnabledServers)

        XCTAssertFalse(store.add(name: "Bad", address: "ftp://example.com/comments", authorization: nil))
        XCTAssertFalse(store.hasEnabledServers)

        XCTAssertTrue(store.add(name: "Disabled", address: "https://one.example.com/api", authorization: nil, isEnabled: false))
        XCTAssertFalse(store.hasEnabledServers)

        XCTAssertTrue(store.add(name: "Enabled", address: "https://two.example.com/api", authorization: nil, isEnabled: true))
        XCTAssertTrue(store.hasEnabledServers)
        XCTAssertEqual(store.enabledServers.map(\.name), ["Enabled"])

        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.servers.map(\.name), ["Enabled", "Disabled"])

        let firstID = store.servers[0].id
        store.setEnabled(false, id: firstID)
        XCTAssertFalse(store.hasEnabledServers)
        store.remove(id: firstID)
        XCTAssertEqual(store.servers.count, 1)

        // Moderation persistence & nested reply filtering.
        let modDefaults = makeDefaults()
        let moderation = SongCommentModerationStore(defaults: modDefaults)
        let items = [
            SongCommentItem(
                id: "c1",
                authorName: "Alice",
                authorID: "u1",
                content: "Great melody",
                replies: [
                    SongCommentReply(id: "r1", authorName: "Spam", authorID: "u-spam", content: "Ad"),
                    SongCommentReply(id: "r2", authorName: "Bob", authorID: "u2", content: "Agreed"),
                ]
            ),
            SongCommentItem(id: "c2", authorName: "Spam", authorID: "u-spam", content: "Spam post"),
            SongCommentItem(id: "c3", authorName: "Carol", content: "Hide me"),
        ]
        moderation.hideComment(id: "c3")
        moderation.blockAuthor(key: items[1].authorBlockKey, displayName: "Spam")

        let reloaded = SongCommentModerationStore(defaults: modDefaults)
        let filtered = reloaded.filter(items)
        XCTAssertEqual(filtered.map(\.id), ["c1"])
        XCTAssertEqual(filtered[0].replies.map(\.id), ["r2"])

        reloaded.clearAll()
        XCTAssertTrue(reloaded.isEmpty)
        XCTAssertEqual(reloaded.filter(items).count, 3)
    }

    func testSettingsCatalogDiscoversCommentsUnderIntegrations() {
        XCTAssertEqual(SettingsPage.comments.category, .integrations)
        XCTAssertTrue(SettingsPage.comments.available)
        XCTAssertEqual(SettingsCatalog.byID["comments.servers"]?.page, .comments)
        for keyword in ["评论", "comments"] {
            XCTAssertTrue(
                SettingsCatalog.search(keyword).contains { $0.id == "comments.servers" },
                "Expected SettingsCatalog.search(\(keyword)) to find comments.servers"
            )
        }
    }

    // MARK: - iOS Zero-Footprint Editor Gate & Live SwiftUI Rendering Verification

    #if os(iOS)
    func testZeroFootprintEditorGateAndLiveSwiftUIRendering() async throws {
        // 1. Verify NowPlayingControlAction & NowPlayingMenuItem gate follows CommentAPIServerStore.shared.
        let sharedStore = CommentAPIServerStore.shared
        let originalServers = sharedStore.servers
        defer {
            sharedStore.servers = originalServers
        }
        sharedStore.servers = []
        XCTAssertFalse(NowPlayingControlAction.comments.isOfferedInEditor)
        XCTAssertFalse(NowPlayingMenuItem.comments.isOfferedInEditor)

        XCTAssertTrue(sharedStore.add(name: "GateCheck", address: "https://gate.example.com/comments", authorization: nil))
        XCTAssertTrue(NowPlayingControlAction.comments.isOfferedInEditor)
        XCTAssertTrue(NowPlayingMenuItem.comments.isOfferedInEditor)
        sharedStore.servers = originalServers

        // 2. Render SongCommentsSheet, NowPlayingCarouselCommentsFace, and CommentAPIServersView
        //    with realistic mock comments on the real iOS SwiftUI/UIKit runtime.
        let host = "comments-ui-\(UUID().uuidString.lowercased()).local"
        let session = makeMockSession(host: host) { _ in
            let now = Int(Date().timeIntervalSince1970)
            let body = """
            {
              "total": 12840,
              "hasMore": true,
              "nextCursor": "next-2",
              "hotComments": [
                {
                  "id": "hot-1",
                  "author": "林间听风",
                  "authorId": "u-1",
                  "content": "前奏吉他刚响起来，就想起那年夏夜骑着单车穿过林荫道回宿舍的晚风。有些旋律不需要太多修饰，只凭几个和弦就能把一整段青春重新点亮。",
                  "likedCount": 24860,
                  "timestamp": \(now - 3600 * 5),
                  "location": "上海",
                  "pinned": true,
                  "replies": [
                    { "id": "r-1", "author": "阿泽", "content": "同感，戴上耳机闭眼听副歌真的会起鸡皮疙瘩。" },
                    { "id": "r-2", "author": "小满", "replyTo": "阿泽", "content": "尤其是现场版最后全场大合唱那一段，百听不腻。" },
                    { "id": "r-3", "author": "北纬三十度", "content": "十年后再听依然热泪盈眶。" }
                  ]
                },
                {
                  "id": "hot-2",
                  "author": "Nora",
                  "authorId": "u-2",
                  "content": "Late-night coding soundtrack on repeat. The bassline right before the second chorus hits different with lossless playback.",
                  "likedCount": 6340,
                  "timestamp": \(now - 86400 * 2),
                  "location": "Tokyo",
                  "badge": "热评"
                }
              ],
              "comments": [
                {
                  "id": "c-1",
                  "author": "云端漫步者",
                  "authorId": "u-3",
                  "content": "刚刚换了新耳机来试音，声场开阔度和人声细节太舒服了。希望以后每次加班到深夜，都能有这样一首歌陪着走完最后一段路，也祝看到这条评论的陌生人一切顺遂，明天醒来都有好天气和好心情。有时候我们会忘记最初为什么出发，但只要音乐重新响起，心里那一点点光就还在。",
                  "likedCount": 428,
                  "timestamp": \(now - 1800),
                  "location": "深圳"
                },
                {
                  "id": "c-2",
                  "author": "Kai",
                  "authorId": "u-4",
                  "content": "Clean mastering and timeless chorus.",
                  "likedCount": 76,
                  "timestamp": \(now - 86400 * 14),
                  "location": "Berlin"
                }
              ]
            }
            """
            return (200, Data(body.utf8), ["Content-Type": "application/json"])
        }

        let service = SongCommentService(session: session)
        let uiDefaults = makeDefaults()
        let uiStore = CommentAPIServerStore(defaults: uiDefaults, registersCloudSync: false)
        XCTAssertTrue(uiStore.add(name: "自建主站", address: "https://\(host)/api/comments", authorization: nil))
        XCTAssertTrue(uiStore.add(name: "备用镜像", address: "https://\(host)/mirror/comments", authorization: nil))
        let modStore = SongCommentModerationStore(defaults: makeDefaults())
        let song = sampleSong()
        let previewDir = ProcessInfo.processInfo.environment["PRIMUSE_COMMENT_PREVIEW_DIR"]

        // Dark Bottom Sheet
        let darkSheet = SongCommentsSheet(song: song, service: service, serverStore: uiStore, moderationStore: modStore)
            .preferredColorScheme(.dark)
            .background(Color(uiColor: .systemBackground))
        let darkSheetImage = try await renderView(darkSheet, size: CGSize(width: 402, height: 760), style: .dark)
        XCTAssertEqual(Int(darkSheetImage.size.width), 402)

        // Light Bottom Sheet
        let lightSheet = SongCommentsSheet(song: song, service: service, serverStore: uiStore, moderationStore: modStore)
            .preferredColorScheme(.light)
            .background(Color(uiColor: .systemBackground))
        let lightSheetImage = try await renderView(lightSheet, size: CGSize(width: 402, height: 760), style: .light)
        XCTAssertEqual(Int(lightSheetImage.size.width), 402)

        // Carousel Comments Face over ambient dark player gradient
        let carouselFace = ZStack {
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.15, blue: 0.25), Color(red: 0.05, green: 0.06, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            NowPlayingCarouselCommentsFace(
                context: NowPlayingCarouselFaceContext(phase: .settled, isSurfaceExposed: true, cards: []),
                appearance: NowPlayingAppearance(colorScheme: .dark, contrast: .standard),
                songOverride: song,
                service: service,
                serverStore: uiStore,
                moderationStore: modStore
            )
            .padding(.top, 56)
            .environment(AppServices.shared.playerService)
        }
        let carouselImage = try await renderView(carouselFace, size: CGSize(width: 402, height: 874), style: .dark)
        XCTAssertEqual(Int(carouselImage.size.width), 402)

        // Comment API Servers Settings View
        let settingsView = NavigationStack {
            CommentAPIServersView(store: uiStore, moderationStore: modStore)
                .environment(AppServices.shared.playerService)
        }
        let settingsImage = try await renderView(settingsView, size: CGSize(width: 402, height: 874), style: .dark)
        XCTAssertEqual(Int(settingsImage.size.width), 402)

        if let previewDir, !previewDir.isEmpty {
            let dirURL = URL(fileURLWithPath: previewDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try darkSheetImage.pngData()?.write(to: dirURL.appendingPathComponent("comments-sheet-dark.png"))
            try lightSheetImage.pngData()?.write(to: dirURL.appendingPathComponent("comments-sheet-light.png"))
            try carouselImage.pngData()?.write(to: dirURL.appendingPathComponent("comments-carousel-dark.png"))
            try settingsImage.pngData()?.write(to: dirURL.appendingPathComponent("comments-settings-dark.png"))
        }
    }

    private func renderView<V: View>(_ view: V, size: CGSize, style: UIUserInterfaceStyle) async throws -> UIImage {
        let wrapped = view
            .environment(AppServices.shared.sourceManager)
            .environment(AppServices.shared.musicLibrary)
            .environment(AppServices.shared.playerService)
        let host = UIHostingController(rootView: wrapped)
        host.overrideUserInterfaceStyle = style
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Allow SwiftUI .task + async mock URLSession response to settle and lay out cards.
        try await Task.sleep(for: .milliseconds(550))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }
    #endif
}

// MARK: - Deterministic URLProtocol Test Harness

private final class CommentRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var count: Int { lock.withLock { requests.count } }
    var lastRequest: URLRequest? { lock.withLock { requests.last } }
}

private final class CommentMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data, [String: String])
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func unregister(host: String) {
        lock.withLock { handlers.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.lock.withLock({ Self.handlers[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data, headers) = handler(request)
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
