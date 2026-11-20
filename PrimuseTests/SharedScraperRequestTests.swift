import Foundation
import Observation
import SwiftUI
import PrimuseKit
import XCTest
@testable import Primuse

final class SharedScraperRequestTests: XCTestCase {

    func testAutomaticLyricsFailureCanRetryWithoutWaitingSixHours() async {
        let ledger = AutomaticOnlineLyricsLedger()
        let now = Date()
        let missing = await ledger.serverFallbackLyrics(songID: "fixture", now: now) { nil }
        XCTAssertNil(missing)
        let immediate = await ledger.serverFallbackLyrics(songID: "fixture", now: now.addingTimeInterval(59)) {
            XCTFail("Retry storm"); return nil
        }
        XCTAssertNil(immediate)
        let found = await ledger.serverFallbackLyrics(songID: "fixture", now: now.addingTimeInterval(61)) {
            [LyricLine(timestamp: 1, text: "Lanterns return with the tide")]
        }
        XCTAssertEqual(found?.count, 1)
        let cooledDown = await ledger.serverFallbackLyrics(songID: "fixture", now: now.addingTimeInterval(120)) {
            XCTFail("Successful lookup should remain cached"); return nil
        }
        XCTAssertNil(cooledDown)
    }

    func testSearchUsesSupportedPageSizeAndKeepsRequestedResultCount() async throws {
        let body = try JSONSerialization.data(withJSONObject: (0..<20).map { ["id": String($0), "title": "Paper Lanterns", "artist": "North Bay"] })
        let fixture = ScraperHTTPFixture { request in
            let size = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value
            return size == "20" ? .init(body: body) : .init(status: 400)
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.search = .init(url: fixture.url("search?q={{query}}&limit={{limit}}"), method: "GET", rule: .init())
        let result = try await ConfigurableScraper(config: config, session: fixture.session)
            .search(query: "Paper Lanterns", artist: "North Bay", album: nil, limit: 15)
        XCTAssertEqual(result.items.count, 15)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testSearchBroadensOnlyAfterNoIdentityMatchAndKeepsBestCandidate() async throws {
        let fixture = ScraperHTTPFixture { request in
            let keyword = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            let body = keyword == "Paper Lanterns" ? #"[{"id":"wrong","title":"Paper Lanterns","artist":"Someone Else"},{"id":"right","title":"Paper Lanterns","artist":"North Bay","album":"Evening"}]"# : #"[{"id":"wrong","title":"Paper Lanterns","artist":"Someone Else"}]"#
            return .init(body: Data(body.utf8))
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.search = .init(url: fixture.url("search?q={{query}}"), method: "GET", rule: .init())
        let scraper = ConfigurableScraper(config: config, session: fixture.session)
        let result = try await scraper.search(query: "Paper Lanterns", artist: "North Bay", album: nil, limit: 2)
        XCTAssertEqual(result.items.map(\.externalId), ["right", "wrong"])
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testSearchDoesNotBroadenAConfidentMatchOrAQuotaFailure() async throws {
        for status in [200, 429] {
            let fixture = ScraperHTTPFixture { _ in .init(status: status, headers: ["Retry-After": "60"],
                body: Data(#"[{"id":"right","title":"Paper Lanterns","artist":"North Bay"}]"#.utf8)) }
            defer { fixture.close() }
            var config = fixture.config()
            config.search = .init(url: fixture.url("search?q={{query}}"), method: "GET", rule: .init())
            do {
                let result = try await ConfigurableScraper(config: config, session: fixture.session, requestPool: .init())
                    .search(query: "Paper Lanterns", artist: "North Bay", album: nil, limit: 1)
                XCTAssertEqual(status, 200)
                XCTAssertEqual(result.items.first?.externalId, "right")
            } catch ScraperError.rateLimited { XCTAssertEqual(status, 429) }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testImportedMatchesRejectWrongArtistTitleAndRecordingVersion() {
        for (title, artist) in [("Paper Lanterns (Live)", "North Bay"), ("Paper Lanterns", "North Bay Tribute"), ("Paper Lanterns Forever", "North Bay")] {
            let item = ScraperSearchItem(externalId: "wrong", source: .custom("fixture"), title: title, artist: artist, durationMs: 180000)
            XCTAssertFalse(ScraperManager.isConfidentAutoMatch(item, title: "Paper Lanterns", artist: "North Bay", durationMs: 180000))
        }
        let alias = ScraperSearchItem(externalId: "right", source: .custom("fixture"), title: "紙燈", artist: "北岸", artistAliases: ["North Bay"])
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(alias, title: "纸灯", artist: "North Bay", durationMs: nil))
    }

    func testImportedRankingUsesIdentityAndAlbumBeforeDuration() {
        let source = MusicScraperType.custom("fixture")
        let wrong = ScraperSearchItem(externalId: "wrong", source: source, title: "Paper Lanterns", artist: "Someone Else", album: "Evening", durationMs: 180000)
        let compilation = ScraperSearchItem(externalId: "compilation", source: source, title: "Paper Lanterns", artist: "North Bay", album: "Collection", durationMs: 180000)
        let original = ScraperSearchItem(externalId: "original", source: source, title: "Paper Lanterns", artist: "North Bay", album: "Evening", durationMs: 182000)
        let result = ScraperManager.topMatches(in: [wrong, compilation, original], title: "Paper Lanterns", artist: "North Bay", durationMs: 180000, maxCount: 3, album: "Evening")
        XCTAssertEqual(result.map(\.externalId), ["original", "compilation", "wrong"])
    }

    func testImportedLyricsNeverFetchAConflictingArtistOrVersion() async {
        let fixture = ScraperHTTPFixture { _ in .init(body: Data(#"[{"id":"cover","title":"Paper Lanterns","artist":"Someone Else","durationMs":180000},{"id":"live","title":"Paper Lanterns (Live)","artist":"North Bay","durationMs":180000}]"#.utf8)) }
        defer { fixture.close() }
        var config = fixture.config()
        config.lyrics = .init(url: fixture.url("lyrics"), method: "GET", rule: .init())
        let scraper = ConfigurableScraper(config: config, session: fixture.session)
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let result = await manager.scrapeMetadata(title: "Paper Lanterns", artist: "North Bay", album: nil, duration: 180,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "fixture", type: .itunes, isEnabled: true, priority: 0)]))
        XCTAssertNil(result.lyrics)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.url?.path == "/search" })
    }

    func testKnownLegacyAdapterConvertsOnlyTheExactApprovedScript() throws {
        let script = "var parts = response._externalId ? response._externalId.split('|') : []; if (parts.length < 6) return null; var cover = parts[5] || ''; if (cover) cover = cover.replace('/150/', '/400/'); return {title: parts[2], artist: parts[3]||null, coverUrl: cover||null};"
        let legacy = EndpointConfig(url: "https://fixture.test/unused", method: "GET", script: script)
        XCTAssertEqual(legacy.rule?.format, .hashCatalogDetail)
        XCTAssertEqual(legacy.method, "LOCAL")
        XCTAssertFalse(legacy.hasLegacyCode)
        try legacy.validateRules()
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("script"))
        let altered = EndpointConfig(url: "", method: "LOCAL", script: script + "while(true){}")
        XCTAssertTrue(altered.hasLegacyCode)
        XCTAssertThrowsError(try altered.validateRules())
    }

    func testSubscriptionPermissionExpansionKeepsInstalledVersionUntilReimport() async throws {
        for replacement in [
            ("https://fixture.test/search", "https://different.test/search"),
            ("\"GET\"", "\"POST\""),
            ("\"metadata\"", "\"metadata\",\"newCapability\"")
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = Self.subscriptionManifest(["fixture": 1], credential: "local-only")
            let fixture = ScraperSubscriptionFixture(manifest: original)
            let store = ScraperConfigStore(configDirectory: root, manifestLoader: { await fixture.load($0) })
            let url = URL(string: "https://fixture.test/config.json")!
            try store.confirmImport(try await store.previewImportFromURL(url), automaticallyUpdates: true)
            // JSONSerialization may escape slashes; normalize before changing the URL.
            let changed = Self.subscriptionManifest(["fixture": 2], credential: "remote")
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: replacement.0, with: replacement.1)
            await fixture.setManifest(changed)
            let updated = await store.refreshSubscriptionsIfDue(now: Date().addingTimeInterval(172800))
            XCTAssertTrue(updated.isEmpty)
            XCTAssertEqual(store.config(for: "fixture")?.version, 1)
            XCTAssertEqual(store.config(for: "fixture")?.cookie, "local-only")
            XCTAssertTrue(store.updateNeedsReview(id: "fixture"))
            XCTAssertTrue(ScraperConfigStore(configDirectory: root).updateNeedsReview(id: "fixture"))
            try store.confirmImport(try await store.previewImportFromURL(url), automaticallyUpdates: true)
            XCTAssertEqual(store.config(for: "fixture")?.version, 2)
            XCTAssertFalse(store.updateNeedsReview(id: "fixture"))
        }
    }

    func testSubscriptionRejectsBroaderTLSAndAssetHosts() throws {
        let original = try JSONDecoder().decode(ScraperConfig.self, from: Data(Self.subscriptionManifest(["fixture": 1]).utf8))
        var changed = original
        changed.sslTrustDomains = ["fixture.test"]
        XCTAssertFalse(ScraperNetworkScope.permitsAutomaticUpdate(from: original, to: changed))
        changed = original
        changed.dynamicCover?.assetHosts = ["*.other.test"]
        XCTAssertFalse(ScraperNetworkScope.permitsAutomaticUpdate(from: original, to: changed))
    }

    func testCredentialsStayOnApprovedOriginAndResourceRedirectsAreSanitized() async throws {
        let fixture = ScraperHTTPFixture { _ in .init() }
        defer { fixture.close() }
        let origin = try XCTUnwrap(ScraperNetworkScope.origin(URL(string: fixture.url(""))!))
        let transport = ScraperSessionManager(headers: ["Cookie": "fixture-cookie", "Authorization": "fixture-token", "X-API-Key": "fixture-key", "User-Agent": "Fixture"],
            trustDomains: [], credentialOrigins: [origin], session: fixture.session)
        _ = try await transport.data(for: URLRequest(url: URL(string: fixture.url("cover"))!))
        _ = try await transport.data(for: URLRequest(url: URL(string: "https://cdn.other.test/cover")!))
        XCTAssertEqual(fixture.requests.first?.value(forHTTPHeaderField: "Cookie"), "fixture-cookie")
        let cross = try XCTUnwrap(fixture.requests.last)
        for header in ["Cookie", "Authorization", "X-API-Key"] { XCTAssertNil(cross.value(forHTTPHeaderField: header)) }
        XCTAssertEqual(cross.value(forHTTPHeaderField: "User-Agent"), "Fixture")
        var request = URLRequest(url: URL(string: "https://cdn.other.test/cover")!)
        request.allHTTPHeaderFields = ["Cookie": "fixture-cookie", "X-API-Key": "fixture-key", "User-Agent": "Fixture"]
        let source = URL(string: fixture.url("cover"))!
        XCTAssertNil(ScraperTransportDelegate.redirect(request, from: source, to: request.url!, isResource: false))
        let redirected = try XCTUnwrap(ScraperTransportDelegate.redirect(request, from: source, to: request.url!, isResource: true))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertNil(ScraperTransportDelegate.redirect(request, from: source, to: URL(string: "http://cdn.other.test/cover")!, isResource: true))
    }

    func testUnknownLegacyScriptStaysStoredButCannotImportOrExecute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = #"{"id":"old","name":"Old source","version":1,"capabilities":["metadata"],"search":{"url":"https://fixture.test/search","method":"GET","script":"while(true){}"}}"#
        let file = root.appendingPathComponent("old.json")
        try Data(raw.utf8).write(to: file)
        let store = ScraperConfigStore(configDirectory: root)
        let config = try XCTUnwrap(store.config(for: "old"))
        XCTAssertEqual(config.search?.script, "while(true){}")
        XCTAssertEqual(try Data(contentsOf: file), Data(raw.utf8))
        XCTAssertThrowsError(try store.previewImportFromJSON(raw))
        let fixture = ScraperHTTPFixture { _ in XCTFail("Unsupported source sent a request"); return .init() }
        defer { fixture.close() }
        do {
            _ = try await ConfigurableScraper(config: config, session: fixture.session).search(query: "Paper Lanterns", artist: nil, album: nil, limit: 1)
            XCTFail("Legacy code must not run")
        } catch ScraperError.parseError { }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSubscriptionRequiresExplicitURLConsentAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ScraperSubscriptionFixture(manifest: Self.subscriptionManifest(["fixture": 1]))
        let store = ScraperConfigStore(configDirectory: root, manifestLoader: { await fixture.load($0) })
        let url = try XCTUnwrap(URL(string: "https://fixture.test/bundle.json?key=local-reference"))
        let preview = try await store.previewImportFromURL(url)
        XCTAssertEqual(preview.sourceURL, url)
        XCTAssertTrue(store.allConfigs.isEmpty)
        XCTAssertFalse(store.automaticallyUpdates(id: "fixture"))
        try store.confirmImport(preview)
        let future = Date().addingTimeInterval(172800)
        let first = await store.refreshSubscriptionsIfDue(now: future)
        XCTAssertTrue(first.isEmpty)
        let requestsWithoutConsent = await fixture.requests
        XCTAssertEqual(requestsWithoutConsent, 1)

        try store.confirmImport(preview, automaticallyUpdates: true)
        let restored = ScraperConfigStore(configDirectory: root, manifestLoader: { await fixture.load($0) })
        XCTAssertTrue(restored.automaticallyUpdates(id: "fixture"))
        let exported = String(decoding: try JSONEncoder().encode(restored.allConfigs), as: UTF8.self)
        XCTAssertFalse(exported.contains("local-reference"))
        await fixture.setManifest(Self.subscriptionManifest(["fixture": 2]))
        let updated = await restored.refreshSubscriptionsIfDue(now: future)
        XCTAssertEqual(updated.map(\.version), [2])
        let offPreview = try await restored.previewImportFromURL(url)
        try restored.confirmImport(offPreview, automaticallyUpdates: false)
        XCTAssertFalse(ScraperConfigStore(configDirectory: root).automaticallyUpdates(id: "fixture"))

        let localPreview = try restored.previewImportFromJSON(Self.subscriptionManifest(["local": 1]))
        try restored.confirmImport(localPreview, automaticallyUpdates: true)
        XCTAssertFalse(restored.automaticallyUpdates(id: "local"))
    }

    func testSubscriptionBundleOnlyUpgradesImportedSourcesAndKeepsCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Self.subscriptionManifest(["first": 1, "second": 5, "missing": 2], credential: "local-only")
        let fixture = ScraperSubscriptionFixture(manifest: original)
        let store = ScraperConfigStore(configDirectory: root, manifestLoader: { await fixture.load($0) })
        let preview = try await store.previewImportFromURL(URL(string: "https://fixture.test/bundle.json")!)
        try store.confirmImport(preview, automaticallyUpdates: true)
        await fixture.setManifest(Self.subscriptionManifest(["first": 2, "second": 4, "new": 1], credential: "remote"))
        let future = Date().addingTimeInterval(172800)
        let updated = await store.refreshSubscriptionsIfDue(now: future)
        XCTAssertEqual(updated.map(\.id), ["first"])
        XCTAssertEqual(store.config(for: "second")?.version, 5)
        XCTAssertEqual(store.config(for: "missing")?.version, 2)
        XCTAssertNil(store.config(for: "new"))
        let first = try XCTUnwrap(store.config(for: "first"))
        XCTAssertEqual(first.secrets?["sample"], "local-only")
        XCTAssertEqual(first.cookie, "local-only")
        XCTAssertEqual(first.headers?["Authorization"], "local-only")
        XCTAssertEqual(first.search?.rule?.fields?["id"]?.value, "2")
        XCTAssertNotNil(first.cover)
        XCTAssertNotNil(first.lyrics)
        XCTAssertNotNil(first.dynamicCover)
        let requests = await fixture.requests
        XCTAssertEqual(requests, 2, "One request for the bundle, not one per source")
        let repeated = await store.refreshSubscriptionsIfDue(now: future.addingTimeInterval(60))
        XCTAssertTrue(repeated.isEmpty)
        let sameDayRequests = await fixture.requests
        XCTAssertEqual(sameDayRequests, 2)
        await fixture.setManifest(Self.subscriptionManifest(["first": 2], credential: "changed"))
        let equalVersion = await store.refreshSubscriptionsIfDue(now: future.addingTimeInterval(86401))
        XCTAssertTrue(equalVersion.isEmpty)
        XCTAssertEqual(ScraperConfigStore(configDirectory: root).config(for: "first")?.secrets?["sample"], "local-only")
    }

    func testSubscriptionFailureKeepsInstalledConfigAndRetriesLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ScraperSubscriptionFixture(manifest: Self.subscriptionManifest(["fixture": 1]))
        let store = ScraperConfigStore(configDirectory: root, manifestLoader: { await fixture.load($0) })
        try store.confirmImport(try await store.previewImportFromURL(URL(string: "https://fixture.test/bundle.json")!),
                                automaticallyUpdates: true)
        await fixture.setManifest("invalid manifest")
        let future = Date().addingTimeInterval(172800)
        let failed = await store.refreshSubscriptionsIfDue(now: future)
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(store.config(for: "fixture")?.version, 1)
        await fixture.setManifest(Self.subscriptionManifest(["fixture": 2]))
        let tooEarly = await store.refreshSubscriptionsIfDue(now: future.addingTimeInterval(1800))
        XCTAssertTrue(tooEarly.isEmpty)
        let requests = await fixture.requests
        XCTAssertEqual(requests, 2)
        let retried = await store.refreshSubscriptionsIfDue(now: future.addingTimeInterval(3601))
        XCTAssertEqual(retried.map(\.version), [2])
    }

    func testSubscriptionInFlightRefreshDoesNotOverwriteReimportOrDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "Refresh started")
        let gate = AsyncStream<Void>.makeStream()
        let original = Self.subscriptionManifest(["edited": 1, "deleted": 1])
        let fixture = ScraperSubscriptionFixture(manifest: original)
        let seed = ScraperConfigStore(configDirectory: root, manifestLoader: { await fixture.load($0) })
        let preview = try await seed.previewImportFromURL(URL(string: "https://fixture.test/bundle.json")!)
        try seed.confirmImport(preview, automaticallyUpdates: true)
        let store = ScraperConfigStore(configDirectory: root) { _ in
            started.fulfill()
            for await _ in gate.stream { break }
            return Self.subscriptionManifest(["edited": 5, "deleted": 5])
        }
        let future = Date().addingTimeInterval(172800)
        let refresh = Task { await store.refreshSubscriptionsIfDue(now: future) }
        await fulfillment(of: [started], timeout: 3)
        let concurrent = await store.refreshSubscriptionsIfDue(now: future)
        XCTAssertTrue(concurrent.isEmpty)
        let edit = try store.previewImportFromJSON(Self.subscriptionManifest(["edited": 2]))
        try store.confirmImport(edit)
        store.delete(id: "deleted")
        gate.continuation.yield(())
        gate.continuation.finish()
        let result = await refresh.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(store.config(for: "edited")?.version, 2)
        XCTAssertEqual(store.config(for: "deleted")?.isDeleted, true)
        XCTAssertFalse(store.automaticallyUpdates(id: "edited"))
        XCTAssertFalse(store.automaticallyUpdates(id: "deleted"))
        store.restore(id: "deleted")
        XCTAssertFalse(store.automaticallyUpdates(id: "deleted"))
    }

    func testSubscriptionDuplicateIDsRejectUpdateAndManualEditRetainsSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ScraperSubscriptionFixture(manifest: Self.subscriptionManifest(["fixture": 1], credential: "local-only"))
        let store = ScraperConfigStore(configDirectory: root, manifestLoader: { await fixture.load($0) })
        try store.confirmImport(try await store.previewImportFromURL(URL(string: "https://fixture.test/bundle.json")!),
                                automaticallyUpdates: true)
        let duplicate = Self.subscriptionManifest(["fixture": 2])
        await fixture.setManifest("[\(duplicate),\(duplicate)]")
        let failed = await store.refreshSubscriptionsIfDue(now: Date().addingTimeInterval(172800))
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(store.config(for: "fixture")?.version, 1)
        try store.importFromJSON(Self.subscriptionManifest(["fixture": 3]))
        XCTAssertEqual(store.config(for: "fixture")?.secrets?["sample"], "local-only")
        XCTAssertFalse(store.automaticallyUpdates(id: "fixture"))
    }

    private static func subscriptionManifest(_ versions: [String: Int], credential: String? = nil) -> String {
        let objects = versions.sorted { $0.key < $1.key }.map { id, version in
            var config: [String: Any] = [
                "id": id, "name": id, "version": version,
                "capabilities": ["metadata", "cover", "lyrics", "dynamicCover"],
                "search": ["url": "https://fixture.test/search", "method": "GET", "rule": ["format": "json", "fields": ["id": ["value": String(version)]], "array": true]],
                "cover": ["url": "", "method": "LOCAL", "script": "return [];"],
                "lyrics": ["url": "https://fixture.test/lyrics", "method": "GET", "script": "return null;"],
                "dynamicCover": ["url": "https://fixture.test/motion", "method": "GET", "script": "return [];"],
            ]
            if let credential {
                config["secrets"] = ["sample": credential]
                config["cookie"] = credential
                config["headers"] = ["Authorization": credential]
            }
            return config
        }
        let value: Any
        if objects.count == 1 { value = objects[0] }
        else { value = ["sources": objects] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    func testBuiltInMotionSourceExportsAsJSONRulesWithoutCode() throws {
        let source = try XCTUnwrap(ScraperSourceConfig.defaultSources().first { $0.type == .custom("m8tec") })
        XCTAssertTrue(source.type.isBuiltIn)
        XCTAssertTrue(source.isEnabled)
        XCTAssertTrue(source.type.supportsDynamicCover)
        XCTAssertFalse(source.type.supportsMetadata)
        XCTAssertEqual(ScraperSettings(sources: [
            .init(id: "motion", type: source.type, isEnabled: true, priority: 0)
        ]).gateSourceCount(for: .all), 0)
        let config = try XCTUnwrap(ScraperConfigStore.shared.config(for: "m8tec"))
        let data = try JSONEncoder().encode(config)
        let imported = try ScraperConfigStore.shared.previewImportFromJSON(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(imported.configs.first?.id, "m8tec")
        XCTAssertEqual(imported.configs.first?.dynamicCover?.playlist, "boundedHLS")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("script"))
        XCTAssertEqual(imported.endpointCount, 1)
    }

    func testExistingSettingsGainMotionSourceWithoutResettingChoices() throws {
        let suite = "motion-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = ScraperSettings()
        saved.sources.removeAll { $0.type == .custom("m8tec") }
        let index = try XCTUnwrap(saved.sources.firstIndex { $0.type == .musicBrainz })
        saved.sources[index].isEnabled = true
        saved.save(defaults: defaults)
        var loaded = ScraperSettings.load(defaults: defaults)
        XCTAssertEqual(loaded.sources.first { $0.type == .musicBrainz }?.isEnabled, true)
        XCTAssertEqual(loaded.sources.first { $0.type == .custom("m8tec") }?.isEnabled, true)
        let motionIndex = try XCTUnwrap(loaded.sources.firstIndex { $0.type == .custom("m8tec") })
        loaded.sources[motionIndex].isEnabled = false
        loaded.save(defaults: defaults)
        XCTAssertEqual(ScraperSettings.load(defaults: defaults).sources.filter { $0.type == .custom("m8tec") }.count, 1)
        XCTAssertEqual(ScraperSettings.load(defaults: defaults).configuredMotionArtworkEndpoints.first?.isEnabled, false)

        defaults.removeObject(forKey: ScraperSettings.defaultsKey)
        defaults.set(try JSONEncoder().encode(saved), forKey: "primuse_scraper_settings_v2")
        XCTAssertEqual(ScraperSettings.load(defaults: defaults).configuredMotionArtworkEndpoints.first?.isEnabled, true)
    }

    @MainActor
    func testEnablingOneMotionSourceFromDisabledServiceKeepsTheOthersOff() throws {
        let suite = "motion-selected-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var list = MotionArtworkEndpointList()
        let first = try list.add(name: "First", url: "https://first.example/motion").get()
        _ = try list.add(name: "Second", url: "https://second.example/motion").get()
        defaults.set(list.encodedData(), forKey: PlayerAppearancePreferences.motionArtworkEndpointsKey)
        defaults.set(false, forKey: PlayerAppearancePreferences.motionArtworkServiceEnabledKey)
        let store = ScraperSettingsStore(defaults: defaults)
        let preferences = AnimatedArtworkPreferences(defaults: defaults)
        let source = try XCTUnwrap(store.sources.first { $0.type == .custom("m8tec") })
        preferences.setStandaloneEndpoint(first.id, enabled: true)
        XCTAssertEqual(preferences.activeMotionArtworkEndpoints.map(\.id), [first.id])
        XCTAssertFalse(store.isSourceEnabled(source))
        store.toggleSource(id: source.id)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertTrue(store.isSourceEnabled(source))
        XCTAssertEqual(preferences.activeMotionArtworkEndpoints.map(\.scraperID), ["m8tec", nil])
    }

    @MainActor
    func testBuiltInMotionSourceToggleControlsPlaybackAndReset() throws {
        let suite = "motion-toggle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScraperSettingsStore(defaults: defaults)
        let preferences = AnimatedArtworkPreferences(defaults: defaults)
        let source = try XCTUnwrap(store.sources.first { $0.type == .custom("m8tec") })
        XCTAssertEqual(preferences.activeMotionArtworkEndpoints.map(\.scraperID), ["m8tec"])
        store.toggleSource(id: source.id)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertTrue(preferences.activeMotionArtworkEndpoints.isEmpty)
        store.toggleSource(id: source.id)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(preferences.activeMotionArtworkEndpoints.map(\.scraperID), ["m8tec"])
        store.toggleSource(id: source.id)
        store.resetToDefaults()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(preferences.activeMotionArtworkEndpoints.map(\.scraperID), ["m8tec"])
    }

    @MainActor
    func testMotionDefaultsPreserveAnExplicitlyDisabledService() throws {
        let suite = "motion-service-off-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PlayerAppearancePreferences.motionArtworkServiceEnabledKey)
        let preferences = AnimatedArtworkPreferences(defaults: defaults)
        XCTAssertEqual(preferences.configuredMotionArtworkEndpoints.first?.isEnabled, true)
        XCTAssertFalse(preferences.isMotionArtworkServiceOn)
        XCTAssertTrue(preferences.activeMotionArtworkEndpoints.isEmpty)
    }

    func testJSONManifestRoundTripsAllEndpointCapabilities() throws {
        let raw = #"""
        {"id":"fixture-motion","name":"Fixture","version":2,"capabilities":["metadata","cover","lyrics","dynamicCover"],
         "search":{"url":"https://fixture.test/search","method":"GET","rule":{"format":"json","path":"items"}},
         "detail":{"url":"https://fixture.test/detail","method":"GET","rule":{"format":"json"}},
         "cover":{"url":"","method":"LOCAL","rule":{"format":"empty"}},
         "lyrics":{"url":"https://fixture.test/lyrics","method":"GET","rule":{"format":"none"}},
         "dynamicCover":{"url":"https://fixture.test/motion","method":"POST","rule":{"format":"motionArtwork"},
            "playlist":"boundedHLS","assetHosts":["*.cdn.fixture.test"],"optional":true,"requiredIdSegments":[0,2],
            "sign":{"type":"md5-wrap","saltSecret":"test"},"crypto":{"algorithm":"aes-128-ecb"}},
         "secrets":{"test":"local-only"}}
        """#
        let decoded = try JSONDecoder().decode(ScraperConfig.self, from: Data(raw.utf8))
        let encoded = try JSONEncoder().encode(decoded)
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        expected.removeValue(forKey: "secrets")
        XCTAssertEqual(expected as NSDictionary, try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        let summary = try ScraperConfigStore.shared.previewImportFromJSON(String(decoding: encoded, as: UTF8.self))
        XCTAssertEqual(summary.endpointCount, 5)
        XCTAssertEqual(summary.ruleCount, 5)
        XCTAssertTrue(summary.domains.contains("*.cdn.fixture.test"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("local-only"))
    }

    func testLocalCoverScriptKeepsCompositeIDWithoutMakingARequest() async throws {
        let fixture = ScraperHTTPFixture { _ in XCTFail("Local endpoint sent a request"); return .init() }
        defer { fixture.close() }
        var config = fixture.config()
        config.cover = .init(url: "", method: "LOCAL", rule: .init(fields: ["coverUrl": .init(path: "$id.1")], array: true))
        let scraper = ConfigurableScraper(config: config, session: fixture.session, requestPool: .init())
        let result = try await scraper.getCoverArt(externalId: "41|https://fixture.test/cover.jpg")
        XCTAssertEqual(result.first?.coverUrl, "https://fixture.test/cover.jpg")
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testFixedSigningAndResponseSelectionKeepRequestBehavior() async throws {
        let fixture = ScraperHTTPFixture { _ in .init(body: Data(#"{"items":[]}"#.utf8)) }
        defer { fixture.close() }
        var config = fixture.config()
        config.secrets = ["sample": "fixture-only"]
        config.search = .init(url: fixture.url("search"), method: "POST", params: ["q": "{{query}}"],
            headers: ["X-Test": "fixture-only"], bodyTemplate: #"{"query":"{{query}}"}"#,
            sign: ["type": "md5-wrap", "saltSecret": "sample", "deviceIDSecret": "requestDeviceID"], rule: .init(), responsePath: "items")
        _ = try await ConfigurableScraper(config: config, session: fixture.session, requestPool: .init(), allowExpensiveNetwork: false)
            .search(query: "Paper Lanterns", artist: nil, album: nil, limit: 3)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "fixture-only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "mid")?.count, 32)
        XCTAssertFalse(request.allowsExpensiveNetworkAccess)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "signature" }?.value, ScraperNativeResolvers.md5("fixture-onlyq=Paper Lanternsfixture-only"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["query"], "Paper Lanterns")
    }

    func testFixedCodecRoundTripsWithoutAScriptRuntime() throws {
        let original = Data("Paper lanterns cross the bay".utf8)
        let encrypted = try XCTUnwrap(ScraperNativeResolvers.aes(original, key: "0123456789abcdef", decrypt: false))
        XCTAssertEqual(ScraperNativeResolvers.aes(encrypted, key: "0123456789abcdef", decrypt: true), original)
        XCTAssertEqual(ScraperNativeResolvers.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testLyricsSourceCandidatesKeepPriorityContinueAfterFailureAndStopAtThree() async {
        let a = StubDirectLyricsScraper(.success("[00:01.00]Paper lanterns"))
        let b = StubDirectLyricsScraper(.failure(ScraperError.networkError("fixture unavailable")))
        let c = StubDirectLyricsScraper(.success("[00:01.00]Across the bay"))
        let d = StubDirectLyricsScraper(.success("[00:01.00]A silver trail"))
        let e = StubDirectLyricsScraper(.success("[00:01.00]Never requested"))
        let stubs = ["a": a, "b": b, "c": c, "d": d, "e": e]
        let manager = ScraperManager(scraperFactory: { stubs[$0.id] ?? e })
        let settings = ScraperSettings(sources: ["e", "c", "b", "d", "a"].map { id in
            ScraperSourceConfig(id: id, type: .lrclib, isEnabled: true, priority: ["a", "b", "c", "d", "e"].firstIndex(of: id)!)
        })
        let song = Song(id: "candidate-test", title: "Lantern Bay", fileFormat: .flac, filePath: "/fixture.flac", sourceID: "fixture", fileSize: 1)
        let result = await manager.lyricsSourceCandidates(for: song, settings: settings)
        XCTAssertEqual(result.compactMap { $0.first?.text }, ["Paper lanterns", "Across the bay", "A silver trail"])
        XCTAssertTrue(result.allSatisfy { LyricsDocumentSource.of($0)?.kind == .online })
        let skipped = await e.requestCount
        XCTAssertEqual(skipped, 0)
    }

    func testLegacyConfigRoundTripPreservesUserFieldsAndFallback() throws {
        let original = Data(#"{"id":"fixture-source","name":"My source","version":6,"cookie":"fixture-cookie","modifiedAt":12345,"sslTrustDomains":["fixture.test"],"capabilities":["lyrics"],"lyrics":{"url":"https://fixture.test/lyrics","method":"GET","script":"return response;"},"secrets":{"testKey":"fixture-secret"}}"#.utf8)
        let config = try JSONDecoder().decode(ScraperConfig.self, from: original)
        let encoded = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(ScraperConfig.self, from: encoded)
        XCTAssertEqual(restored.id, config.id)
        XCTAssertEqual(restored.name, config.name)
        XCTAssertEqual(restored.version, config.version)
        XCTAssertEqual(restored.cookie, config.cookie)
        XCTAssertEqual(restored.modifiedAt, config.modifiedAt)
        XCTAssertEqual(restored.sslTrustDomains, config.sslTrustDomains)
        XCTAssertEqual(restored.lyrics?.script, config.lyrics?.script)
        XCTAssertNil(restored.secrets)
        XCTAssertNil(restored.lyricsFallback)
        XCTAssertNil(restored.responseValidation)
        XCTAssertNil(LegacyScraperCompatibility.lyricsFallback(for: restored))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-secret"))
    }

    func testConfiguredFallbackRoundTripAndImportPreview() throws {
        let fixture = ScraperHTTPFixture { _ in .init() }
        defer { fixture.close() }
        var config = fixture.config()
        config.lyricsFallback = .init(url: "https://lyrics.fixture.test/get?id={{id}}", contentField: "text",
                                      encoding: .utf8, requiredVariables: ["id"])
        config.responseValidation = .init(codePaths: ["status", "operations.*.status"], successCodes: [200])
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(ScraperConfig.self, from: data)
        XCTAssertEqual(restored.lyricsFallback?.requiredVariables, ["id"])
        XCTAssertEqual(restored.responseValidation?.successCodes, [200])
        let summary = try ScraperConfigStore.shared.previewImportFromJSON(String(decoding: data, as: UTF8.self))
        XCTAssertTrue(summary.domains.contains("lyrics.fixture.test"))
        XCTAssertEqual(summary.endpointCount, 2)
    }

    func testConfiguredFallbackSupportsBothEncodingsAndEscapesVariables() async throws {
        for encoding in [LyricsFallbackConfig.ContentEncoding.utf8, .base64UTF8] {
            let expected = "[00:01.00]Paper boats cross the bay"
            let content = encoding == .utf8 ? expected : Data(expected.utf8).base64EncodedString()
            let body = try JSONSerialization.data(withJSONObject: ["text": content])
            let fixture = ScraperHTTPFixture { request in
                request.url?.path == "/lyrics"
                    ? .init(body: Data(#"{"_fetchLyrics":true,"vars":{"id":"a&other=1"}}"#.utf8))
                    : .init(body: body)
            }
            defer { fixture.close() }
            // Explicit configuration also overrides the legacy source's default URL.
            var config = ScraperConfig(id: "fixture-source", name: "Fixture", version: 7, rateLimit: 0, capabilities: ["lyrics"])
            config.lyrics = fixture.encryptedConfig().lyrics
            config.lyricsFallback = .init(url: fixture.url("fallback?id={{id}}"), contentField: "text",
                                          encoding: encoding, requiredVariables: ["id"])
            let result = try await ConfigurableScraper(config: config, session: fixture.session).getLyrics(externalId: "song")
            XCTAssertEqual(result?.lrcContent, expected)
            let url = try XCTUnwrap(fixture.requests.last?.url)
            XCTAssertEqual(url.host, URL(string: fixture.url(""))?.host)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                           [.init(name: "id", value: "a&other=1")])
        }
    }

    func testMissingFallbackVariablesDoNotSendSecondRequest() async throws {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Data(#"{"_fetchLyrics":true,"vars":{"id":"123"}}"#.utf8))
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.lyrics = fixture.encryptedConfig().lyrics
        config.lyricsFallback = .init(url: fixture.url("fallback"), contentField: "content", encoding: .base64UTF8,
                                      requiredVariables: ["ticket"])
        let result = try await ConfigurableScraper(config: config, session: fixture.session).getLyrics(externalId: "song")
        XCTAssertNil(result)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testConfiguredBusinessFailureReachesCircuitBreaker() async throws {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Data(#"{"status":200,"operations":{"search":{"status":401}}}"#.utf8))
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.responseValidation = .init(codePaths: ["status", "operations.*.status"], successCodes: [200])
        let scraper = ConfigurableScraper(config: config, session: fixture.session, requestPool: ScraperRequestPool())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let settings = ScraperSettings(sources: [.init(id: config.id, type: .itunes, isEnabled: true, priority: 0)])
        for index in 0..<8 {
            _ = await manager.scrapeMetadata(title: "Song \(index)", artist: nil, album: nil, duration: nil,
                needs: .init(metadata: true, cover: false, lyrics: false), settings: settings)
        }
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testExplicitBusinessRulesOverrideLegacyDefaults() async throws {
        let fixture = ScraperHTTPFixture { _ in .init(body: Data(#"{"code":200,"items":[]}"#.utf8)) }
        defer { fixture.close() }
        var config = ScraperConfig(id: "fixture-source", name: "Fixture", version: 2, rateLimit: 0, capabilities: ["metadata"])
        config.search = .init(url: fixture.url("search"), method: "GET", script: "return response.items;")
        config.responseValidation = .init(codePaths: ["code"], successCodes: [200])
        let result = try await ConfigurableScraper(config: config, session: fixture.session).search(query: "Song", artist: nil, album: nil, limit: 1)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testScriptErrorsAreFailuresWhileExplicitEmptyResultsRemainSuccessful() async throws {
        let fixture = ScraperHTTPFixture { _ in .init() }
        defer { fixture.close() }
        for script in ["while(true){}", "throw new Error('fixture');", "return (;", "return missingVariable.value;"] {
            var config = fixture.config()
            config.search = .init(url: fixture.url("search"), method: "GET", script: script)
            do {
                _ = try await ConfigurableScraper(config: config, session: fixture.session).search(query: "Song", artist: nil, album: nil, limit: 1)
                XCTFail("Script failure must not become a search miss")
            } catch ScraperError.parseError { }
        }
        for script in ["return null;", "return undefined;", "return [];"] {
            var config = fixture.config()
            config.search = .init(url: fixture.url("search"), method: "GET", script: script)
            let result = try await ConfigurableScraper(config: config, session: fixture.session).search(query: "Song", artist: nil, album: nil, limit: 1)
            XCTAssertTrue(result.items.isEmpty)
        }
    }

    func testEncryptedCatalogWithoutPrivateConfigurationFetchesPublicLRC() async throws {
        let expected = "[00:01.00]A line\n[00:02.00]Another line"
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path == "/lyrics" {
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"123","accesskey":"fixture-key"}]}"#.utf8))
            }
            return .init(body: Data("{\"status\":200,\"content\":\"\(Data(expected.utf8).base64EncodedString())\"}".utf8))
        }
        defer { fixture.close() }
        var config = ScraperConfig(id: "fixture-source", name: "Fixture", version: 6, rateLimit: 0, capabilities: ["lyrics"])
        config.lyrics = fixture.encryptedConfig().lyrics
        config.lyricsFallback = .init(url: fixture.url("download?fmt=lrc&id={{id}}&accesskey={{accesskey}}"), contentField: "content", encoding: .base64UTF8, requiredVariables: ["id", "accesskey"])
        let result = try await ConfigurableScraper(config: config, session: fixture.session).getLyrics(externalId: "song")
        XCTAssertEqual(result?.lrcContent, expected)
        let request = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(request.url?.host, URL(string: fixture.url(""))?.host)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "fmt" }?.value, "lrc")
        XCTAssertEqual(query?.first { $0.name == "id" }?.value, "123")
    }

    func testEncryptedCatalogPlainFallbackPreservesRateLimit() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/lyrics"
                ? .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":{"id":"123","accesskey":"fixture-key"}}"#.utf8))
                : .init(status: 429, headers: ["Retry-After": "3600"])
        }
        defer { fixture.close() }
        var config = ScraperConfig(id: "fixture-source", name: "Fixture", version: 6, rateLimit: 0, capabilities: ["lyrics"])
        config.lyrics = fixture.encryptedConfig().lyrics
        config.lyricsFallback = .init(url: fixture.url("download?fmt=lrc&id={{id}}&accesskey={{accesskey}}"), contentField: "content", encoding: .base64UTF8, requiredVariables: ["id", "accesskey"])
        await assertRateLimited {
            _ = try await ConfigurableScraper(config: config, session: fixture.session, requestPool: ScraperRequestPool()).getLyrics(externalId: "song")
        }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testEnvelopeCatalogBusinessFailuresReachCircuitBreakerInsteadOfBecomingSearchMisses() async throws {
        for usesProxy in [false, true] {
            let fixture = ScraperHTTPFixture { _ in
                .init(body: Data(#"{"code":0,"req_1":{"code":2001,"data":{"body":{"song":{"list":[]}}}}}"#.utf8))
            }
            defer { fixture.close() }
            let config = ScraperConfig(id: fixture.id, name: "Fixture", version: 1,
                rateLimit: 0, capabilities: ["metadata", "lyrics"], search: .init(
                    url: usesProxy ? fixture.url("proxy") : fixture.url("search"),
                    method: "POST", bodyTemplate: "{}", rule: .init(format: .envelopeCatalogSearch)))
            let scraper = ConfigurableScraper(config: config, session: fixture.session, requestPool: ScraperRequestPool())
            let manager = ScraperManager(scraperFactory: { _ in scraper })
            let settings = ScraperSettings(sources: [
                .init(id: config.id, type: .itunes, isEnabled: true, priority: 0)
            ])
            for index in 0..<8 {
                _ = await manager.scrapeMetadata(title: "Song \(index)", artist: nil, album: nil, duration: nil,
                    needs: .init(metadata: true, cover: false, lyrics: false), settings: settings)
            }
            XCTAssertEqual(fixture.requests.count, 3, "Repeated API failures must open the existing source circuit")
        }
    }

    func testEnvelopeCatalogEmptySuccessAndUnrelatedProviderCodesDoNotOpenCircuit() async throws {
        for (host, body) in [
            ("envelope.fixture.test", #"{"code":0,"req_1":{"code":0,"data":{}}}"#),
            ("unrelated.test", #"{"code":2001,"req_1":{"code":2001}}"#)
        ] {
            let fixture = ScraperHTTPFixture { _ in .init(body: Data(body.utf8)) }
            defer { fixture.close() }
            var config = fixture.config()
            config.search = .init(url: "https://\(host)/search", method: "GET", rule: .init(format: host == "envelope.fixture.test" ? .envelopeCatalogSearch : .empty))
            let scraper = ConfigurableScraper(config: config, session: fixture.session)
            for _ in 0..<4 {
                let result = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
                XCTAssertTrue(result.items.isEmpty)
            }
            XCTAssertEqual(fixture.requests.count, 4)
        }
    }

    func testCustomInstancesAndResourcesShareCooldown() async {
        let fixture = ScraperHTTPFixture { _ in .init(status: 429, headers: ["Retry-After": "3600"]) }
        defer { fixture.close() }
        let config = fixture.config()
        for _ in 0..<2 {
            let scraper = ConfigurableScraper(config: config, session: fixture.session)
            await assertRateLimited {
                _ = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
            }
        }
        await assertRateLimited {
            _ = try await ConfigurableScraper.downloadResource(
                from: fixture.url("cover"),
                sourceConfig: .init(id: "another-row", type: .custom(config.id), isEnabled: true, priority: 0),
                session: fixture.session
            )
        }
        XCTAssertEqual(fixture.requests.count, 1, "Recreating a scraper or downloading artwork must respect the same quota")
    }

    func testEncryptedLyricsStopsAtRateLimit() async {
        let fixture = encryptedFixture(status: 429, headers: ["Retry-After": "3600"])
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
        await assertRateLimited { _ = try await scraper.getLyrics(externalId: "song") }
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/lyrics", "/encrypted/one"])
    }

    func testEncryptedLyricsPreservesServerFailureAndCancellation() async {
        for cancelled in [false, true] {
            let fixture = encryptedFixture(status: 500, error: cancelled ? URLError(.cancelled) : nil)
            defer { fixture.close() }
            let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
            do {
                _ = try await scraper.getLyrics(externalId: "song")
                XCTFail("Secondary failures must not become missing lyrics")
            } catch let error as URLError where cancelled {
                XCTAssertEqual(error.code, .cancelled)
            } catch ScraperError.networkError(let message) where !cancelled {
                XCTAssertTrue(message.contains("500"))
            } catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertEqual(fixture.requests.count, 2, "Stop before requesting another candidate")
        }
    }

    func testLyricsServersKeepIndependentCooldownAcrossInstancesAndMisses() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/a"
                ? .init(status: 429, headers: ["Retry-After": "3600"])
                : .init(status: 404)
        }
        defer { fixture.close() }
        let servers = [LyricsAPIServer(address: fixture.url("a")), LyricsAPIServer(address: fixture.url("b"))]
        for _ in 0..<2 {
            let scraper = LyricsAPIServerScraper(servers: servers, session: fixture.session)
            await assertRateLimited {
                _ = try await scraper.fetchLyrics(title: "Song", artist: nil, album: nil, duration: nil)
            }
        }
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/a", "/b", "/b"],
                       "A's cooldown must survive B's miss without blocking B")
    }

    func testManagerObservesManualLRCLIBCooldownUntilServerDeadline() async throws {
        let clock = ScraperTestClock()
        let fixture = ScraperHTTPFixture { _ in .init(status: 429, headers: ["Retry-After": "3600"]) }
        defer { fixture.close() }
        let scraper = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor(timing: clock.timing))
        await assertRateLimited { _ = try await scraper.fetchLyrics(title: "Song", artist: "Artist") }
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        for time in [0.0, 301, 3599] {
            clock.advance(to: time)
            let result = await scrape(manager, type: .lrclib)
            XCTAssertTrue(result.errors.isEmpty, "Skip the shared cooldown, including beyond the old 300s cap")
        }
        XCTAssertEqual(fixture.requests.count, 1)
        clock.advance(to: 3600)
        let resumed = await scrape(manager, type: .lrclib)
        XCTAssertEqual(resumed.errors.count, 1)
        XCTAssertEqual(fixture.requests.count, 2, "Resume only once the server deadline expires")
    }

    func testManagerContinuesHealthyLyricsEndpointWhileAnotherIsCooling() async {
        let phase = ScraperTestClock()
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path == "/a" { return .init(status: 429, headers: ["Retry-After": "3600"]) }
            return phase.now == 0 ? .init(status: 404) : .init(body: Data("[00:01.00]Fixture lyrics".utf8))
        }
        defer { fixture.close() }
        let scraper = LyricsAPIServerScraper(servers: [
            .init(address: fixture.url("a")), .init(address: fixture.url("b"))
        ], session: fixture.session)
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let first = await scrape(manager, type: .lyricsServer)
        XCTAssertEqual(first.errors.count, 1, "A 404 on B must not erase A's error")
        phase.advance(to: 1)
        let next = await scrape(manager, type: .lyricsServer)
        XCTAssertFalse(next.lyrics?.isEmpty ?? true, "B remains available during A's cooldown")
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/a", "/b", "/b"])
    }

    func testEncryptedLyricsFallsBackOnlyForMissingCandidates() async throws {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/lyrics":
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"one"},{"id":"two"}]}"#.utf8))
            case "/encrypted/one": return .init(status: 404)
            default:
                // Synthetic zlib text, XOR key 01, magic 00; no provider secrets.
                return .init(body: Data(#"{"content":"AHmdijc1MTHRABCwNxFbxsHPIjQmJh4BTWkHTw=="}"#.utf8))
            }
        }
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
        let result = try await scraper.getLyrics(externalId: "song")
        XCTAssertTrue(result?.lrcContent?.contains("Hello") == true)
        XCTAssertTrue(result?.lrcContent?.contains("[00:01.00]") == true)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/lyrics", "/encrypted/one", "/encrypted/two"])
    }

    /// 已经解出一份时, 后面的候选出错不把整首歌词丢掉。
    func testEncryptedLyricsKeepsDecodedCandidateWhenALaterOneFails() async throws {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/lyrics":
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"one"},{"id":"two"}]}"#.utf8))
            case "/encrypted/two": return .init(status: 500)
            default:
                return .init(body: Data(#"{"content":"AHmdijc1MTHRABCwNxFbxsHPIjQmJh4BTWkHTw=="}"#.utf8))
            }
        }
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
        let result = try await scraper.getLyrics(externalId: "song")
        XCTAssertTrue(result?.lrcContent?.contains("Hello") == true)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/lyrics", "/encrypted/one", "/encrypted/two"])
    }

    /// 一台歌词服务器明确说没有时, 另一台宕机不算这个源失败, 免得连着几首把能用的那台一起熔断。
    func testLyricsServerMissOutweighsAnotherServersOutage() async throws {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/a" ? .init(status: 500) : .init(status: 404)
        }
        defer { fixture.close() }
        let scraper = LyricsAPIServerScraper(servers: [
            .init(address: fixture.url("a")), .init(address: fixture.url("b"))
        ], session: fixture.session)
        let result = try await scraper.fetchLyrics(title: "Song", artist: nil, album: nil, duration: nil)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/a", "/b"])
    }

    func testCustomEndpointParsingHeadersAndHTTPUpgradeArePreserved() async throws {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/search": return .init(body: Data(#"[{"id":"one","title":"Song","artist":"Artist"}]"#.utf8))
            case "/detail": return .init(body: Data(#"{"title":"Song","album":"Album"}"#.utf8))
            case "/cover": return .init(body: Data(#"[{"coverUrl":"https://images.test/cover"}]"#.utf8))
            default: return .init(body: Data(#"{"lrcContent":"[00:01.00]Hello"}"#.utf8))
            }
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.headers = ["X-Global": "global", "X-Override": "global"]
        config.cookie = "session=fixture"
        config.search = .init(url: fixture.url("search").replacingOccurrences(of: "https:", with: "http:"),
                              method: "GET", headers: ["X-Override": "endpoint"], script: "return response;")
        config.detail = .init(url: fixture.url("detail"), method: "GET", script: "return response;")
        config.cover = .init(url: fixture.url("cover"), method: "GET", script: "return response;")
        config.lyrics = .init(url: fixture.url("lyrics"), method: "GET", script: "return response;")
        let scraper = ConfigurableScraper(config: config, session: fixture.session)
        let search = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
        let detail = try await scraper.getDetail(externalId: "one")
        let covers = try await scraper.getCoverArt(externalId: "one")
        let lyrics = try await scraper.getLyrics(externalId: "one")
        XCTAssertEqual(search.items.first?.title, "Song")
        XCTAssertEqual(detail?.album, "Album")
        XCTAssertEqual(covers.first?.coverUrl, "https://images.test/cover")
        XCTAssertEqual(lyrics?.lrcContent, "[00:01.00]Hello")
        XCTAssertEqual(fixture.requests.first?.url?.scheme, "https")
        XCTAssertEqual(fixture.requests.first?.value(forHTTPHeaderField: "X-Override"), "endpoint")
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "session=fixture" })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Global") == "global" })
    }

    func testCustomPOSTIsNotReplayedAfterAnUncertainTransportOutcome() async {
        let fixture = ScraperHTTPFixture { _ in .init(error: URLError(.networkConnectionLost)) }
        defer { fixture.close() }
        var config = fixture.config()
        config.search = .init(url: fixture.url("search"), method: "POST",
                              bodyTemplate: #"{"query":"{{query}}"}"#, script: "return response;")
        let scraper = ConfigurableScraper(config: config, session: fixture.session)
        do {
            _ = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
            XCTFail("Expected transport failure")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.httpMethod, "POST")
    }

    func testResponseSizeLimitsRemainAtTheAdapterBoundary() async throws {
        let fixture = ScraperHTTPFixture { request in
            let limit = request.url?.path == "/cover"
                ? ConfigurableScraper.maxResourceResponseBytes : ConfigurableScraper.maxEndpointResponseBytes
            return .init(body: Data(repeating: 32, count: limit + 1))
        }
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.config(), session: fixture.session)
        do {
            _ = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
            XCTFail("Oversized JSON must not enter the script")
        } catch ScraperError.networkError(let message) { XCTAssertTrue(message.contains("too large")) }
        catch { XCTFail("Unexpected failure: \(error)") }
        let resource = try await ConfigurableScraper.downloadResource(from: fixture.url("cover"), session: fixture.session)
        XCTAssertNil(resource)
    }

    func testResourcesReturnBytesWithoutInvalidatingBorrowedSession() async throws {
        let bytes = Data([1, 2, 3, 4])
        let fixture = ScraperHTTPFixture { _ in .init(body: bytes) }
        defer { fixture.close() }
        for path in ["first", "second"] {
            let data = try await ConfigurableScraper.downloadResource(from: fixture.url(path), session: fixture.session)
            XCTAssertEqual(data, bytes)
        }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testResourceMissServerFailureAndCancellationStayDistinct() async throws {
        for status in [403, 404, 500, 503] {
            let fixture = ScraperHTTPFixture { _ in .init(status: status) }
            defer { fixture.close() }
            do {
                let data = try await ConfigurableScraper.downloadResource(from: fixture.url("cover"), session: fixture.session)
                XCTAssertNil(data)
                XCTAssertLessThan(status, 500)
            } catch ScraperError.networkError(let message) where status == 500 {
                XCTAssertTrue(message.contains("500"))
            } catch ScraperError.rateLimited where status == 503 {
            } catch { XCTFail("Unexpected failure for \(status): \(error)") }
            XCTAssertEqual(fixture.requests.count, 1)
        }
        let fixture = ScraperHTTPFixture { _ in .init(error: URLError(.cancelled)) }
        defer { fixture.close() }
        do {
            _ = try await ConfigurableScraper.downloadResource(from: fixture.url("cover"), session: fixture.session)
            XCTFail("Cancellation must reach caller")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    }

    func testSettingsProbeAndEquivalentEndpointShareHTTPDateCooldown() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: Date().addingTimeInterval(3600))
        let fixture = ScraperHTTPFixture { _ in .init(status: 503, headers: ["Retry-After": date]) }
        defer { fixture.close() }
        let server = LyricsAPIServer(address: fixture.url("api"), authorization: "Bearer draft")
        let probe = await LyricsAPIServerScraper.probe(server: server, title: "Song", artist: nil, album: nil,
                                                     duration: nil, session: fixture.session)
        guard case .failed = probe else { return XCTFail("Expected probe failure") }
        var alias = server
        alias.id = UUID().uuidString
        alias.address = "HTTPS://" + fixture.id.uppercased() + ".TEST:443/api#ignored"
        let scraper = LyricsAPIServerScraper(servers: [alias], session: fixture.session)
        let deadline = formatter.date(from: date)!
        let earliest = Date()
        do {
            _ = try await scraper.getLyrics(externalId: "Song|Artist")
            XCTFail("Expected the probe's shared cooldown")
        } catch ScraperError.rateLimited(let delay) {
            let latest = Date()
            XCTAssertGreaterThanOrEqual(delay ?? 0, Int(ceil(deadline.timeIntervalSince(latest))))
            XCTAssertLessThanOrEqual(delay ?? Int.max, Int(ceil(deadline.timeIntervalSince(earliest))))
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1, "New settings rows and equivalent URLs share the endpoint quota")
        XCTAssertEqual(fixture.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer draft")
    }

    func testMissingLyricsAPIStillFallsBackToNextProvider() async throws {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/api/get"
                ? .init(body: Data(#"{"syncedLyrics":"[00:01.00]Hello"}"#.utf8))
                : .init(status: 404)
        }
        defer { fixture.close() }
        let server = LyricsAPIServerScraper(servers: [.init(address: fixture.url("api"))], session: fixture.session)
        let lrclib = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { config in
            if config.type == .lyricsServer { return server }
            return lrclib
        })
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true), settings: .init(sources: [
                .init(id: "first", type: .lyricsServer, isEnabled: true, priority: 0),
                .init(id: "second", type: .lrclib, isEnabled: true, priority: 1)
            ]))
        XCTAssertFalse(result.lyrics?.isEmpty ?? true)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/api", "/api/get"])
    }

    func testManualSearchListsLyricsAPIResultForTheSongIdentity() async {
        let fixture = ScraperHTTPFixture { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let title = items.first { $0.name == "title" }?.value
            let artist = items.first { $0.name == "artist" }?.value
            return title == "小海" && artist == "Singer"
                ? .init(body: Data("[00:01.00]第一句\n[00:05.00]第二句".utf8))
                : .init(status: 404)
        }
        defer { fixture.close() }
        let server = LyricsAPIServerScraper(servers: [.init(address: fixture.url("api"))], session: fixture.session)
        let manager = ScraperManager(scraperFactory: { _ in server })
        let settings = ScraperSettings(sources: [
            .init(id: "itunes", type: .itunes, isEnabled: true, priority: 0),
            .init(id: "lyrics", type: .lyricsServer, isEnabled: true, priority: 1)
        ])

        let lookup = ScraperManager.lyricsLookupIdentity(query: "小海 Singer", title: "小海", artist: "Singer")
        let found = await manager.manualLyricsCandidates(
            title: lookup.title, artist: lookup.artist, album: nil, duration: 200, settings: settings
        )
        XCTAssertEqual(found.map(\.config.id), ["lyrics"])
        XCTAssertEqual(found.first?.lyrics.map(\.text), ["第一句", "第二句"])

        let miss = await manager.manualLyricsCandidates(
            title: "别的歌", artist: "Singer", album: nil, duration: 200, settings: settings
        )
        XCTAssertTrue(miss.isEmpty)

        let disabled = await manager.manualLyricsCandidates(
            title: "小海", artist: "Singer", album: nil, duration: 200,
            settings: ScraperSettings(sources: [.init(id: "lyrics", type: .lyricsServer, isEnabled: false, priority: 0)])
        )
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertEqual(fixture.requests.count, 2, "A disabled lyrics API is never asked")
    }

    func testManualLyricsLookupPreservesVersionsWhenSplittingTitleAndArtist() {
        func lookup(_ query: String, title: String = "小海", artist: String? = "Singer") -> [String?] {
            let identity = ScraperManager.lyricsLookupIdentity(query: query, title: title, artist: artist)
            return [identity.title, identity.artist]
        }
        XCTAssertEqual(lookup("小海 Singer"), ["小海", "Singer"], "The suggested query is title + artist")
        XCTAssertEqual(lookup("小海"), ["小海", "Singer"], "A title-only query keeps the song's artist")
        XCTAssertEqual(lookup("小海 (Live) singer"), ["小海 (Live)", "Singer"], "Artist suffix is matched case-insensitively")
        XCTAssertEqual(lookup("小海 (Live)"), ["小海 (Live)", "Singer"])
        XCTAssertEqual(lookup("周杰伦 - 稻香 (Remix摇滚版)", artist: nil), ["稻香 (Remix摇滚版)", "周杰伦"])
        XCTAssertEqual(lookup("调查中 - Live", artist: nil), ["调查中 - Live", nil])
        XCTAssertEqual(MusicScraperService.searchQuery(title: "01. 调查中 (Live)【无损】", artist: "周深"), "调查中 (Live) 周深")
        XCTAssertEqual(lookup("别的歌 Singer"), ["别的歌", "Singer"])
        XCTAssertEqual(lookup("Other Artist - 别的歌"), ["别的歌", "Other Artist"])
        XCTAssertEqual(lookup("完全不同", artist: nil), ["完全不同", nil])
    }

    func testLyricsAPICancellationDoesNotTryNextEndpoint() async {
        let fixture = ScraperHTTPFixture { _ in .init(error: URLError(.cancelled)) }
        defer { fixture.close() }
        let scraper = LyricsAPIServerScraper(servers: [
            .init(address: fixture.url("a")), .init(address: fixture.url("b"))
        ], session: fixture.session)
        do {
            _ = try await scraper.getLyrics(externalId: "Song|Artist")
            XCTFail("Expected cancellation")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testDirectMusicBrainzCoverFetchPreservesHTTPFailure() async {
        let fixture = ScraperHTTPFixture { _ in .init(status: 500) }
        defer { fixture.close() }
        let scraper = MusicBrainzScraper(session: fixture.session, requestExecutor: RequestExecutor())
        do {
            _ = try await scraper.fetchCoverData(releaseID: "fixture-release")
            XCTFail("A cover service outage is not a missing image")
        } catch ScraperError.networkError(let message) { XCTAssertTrue(message.contains("500")) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testAMLLFallsBackToTitleSearchAndReturnsWordLevelLyrics() async {
        let fixture = ScraperHTTPFixture { request in
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let items = components?.queryItems ?? []
            switch components?.path {
            case "/v1/lyrics/search" where items.contains(where: { $0.name == "artistName" }):
                return .init(body: SharedScraperRequestTests.amllSearchBody([]))
            case "/v1/lyrics/search":
                return .init(body: SharedScraperRequestTests.amllSearchBody([(7, "晴天", "周杰伦")]))
            case "/v1/lyrics/get" where items.first(where: { $0.name == "id" })?.value == "7":
                return .init(body: SharedScraperRequestTests.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
            default:
                return .init(status: 404)
            }
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in amll })
        // 曲库里写的是繁体歌手名：接口按歌手搜不到，只按歌名搜出来后本地认出是同一位。
        let result = await manager.scrapeMetadata(title: "晴天", artist: "周杰倫", album: nil, duration: 269,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertEqual(result.lyrics?.count, 2)
        XCTAssertTrue(result.lyrics?.allSatisfy(\.isWordLevel) ?? false)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/v1/lyrics/search", "/v1/lyrics/search", "/v1/lyrics/get"])
    }

    func testAMLLAutomaticLookupPreservesRecordingVersionThroughManager() async {
        for (input, expected, artist) in [
            ("01. 调查中 (Live)【无损】", "调查中 (Live)", "周深"),
            ("周杰伦 - 稻香 (Remix摇滚版)", "稻香 (Remix摇滚版)", "周杰伦"),
            ("调查中（Live）", "调查中（Live）", "周深"),
            ("调查中 [Live]", "调查中 [Live]", "周深")
        ] {
            let fixture = ScraperHTTPFixture { request in
                let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                if components?.path == "/v1/lyrics/get" {
                    return .init(body: Self.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
                }
                let title = components?.queryItems?.first { $0.name == "musicName" }?.value
                return .init(body: Self.amllSearchBody(title == expected ? [(7, expected, artist)] : []))
            }
            defer { fixture.close() }
            let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
            let manager = ScraperManager(scraperFactory: { _ in amll })
            let result = await manager.scrapeMetadata(title: input, artist: artist, album: nil, duration: 240,
                needs: .init(metadata: false, cover: false, lyrics: true),
                settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
            XCTAssertEqual(result.lyrics?.count, 2, input)
            XCTAssertTrue(result.lyrics?.allSatisfy(\.isWordLevel) ?? false, input)
            XCTAssertEqual(fixture.requests.count, 2, input)
        }
    }

    func testAMLLLiveQueryDoesNotAcceptStudioLyricsThroughManager() async {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Self.amllSearchBody([(7, "调查中", "周深")]))
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in amll })
        let result = await manager.scrapeMetadata(title: "调查中 (Live)", artist: "周深", album: nil, duration: 240,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertNil(result.lyrics)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.url?.path == "/v1/lyrics/search" })
    }

    func testAMLLRetriesTitleWhenArtistSearchReturnsOnlyIncompatibleVersions() async throws {
        let fixture = ScraperHTTPFixture { request in
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            if components?.path == "/v1/lyrics/get" {
                return .init(body: Self.amllLyricsBody(id: 8, lastLineEnd: "03:20.000"))
            }
            let hasArtist = components?.queryItems?.contains { $0.name == "artistName" } ?? false
            return .init(body: Self.amllSearchBody(hasArtist
                ? [(7, "Song (Live)", "Singer")] : [(8, "Song", "Singer")]))
        }
        defer { fixture.close() }
        let scraper = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.fetchLyrics(title: "Song", artist: "Singer", album: nil, duration: 240)
        XCTAssertTrue(result?.hasLyrics ?? false)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/v1/lyrics/search", "/v1/lyrics/search", "/v1/lyrics/get"])
        let lastURL = try XCTUnwrap(fixture.requests.last?.url)
        XCTAssertEqual(URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "8")
    }

    func testManualAMLLAliasCandidateUsesUpstreamIdentityAndExactLyricsID() async throws {
        let fixture = ScraperHTTPFixture { request in
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            if components?.path == "/v1/lyrics/get" {
                return .init(body: Self.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
            }
            let hasArtist = components?.queryItems?.contains { $0.name == "artistName" } ?? false
            return .init(body: Self.amllSearchBody(hasArtist ? [] : [(7, "晴天", "周杰伦")]))
        }
        defer { fixture.close() }
        let scraper = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let automatic = try await scraper.fetchLyrics(title: "晴天", artist: "Jay Chou", album: nil, duration: 269)
        XCTAssertNil(automatic, "An unverified alias must not silently bypass automatic identity matching")
        let candidates = await manager.manualLyricsCandidates(title: "晴天", artist: "Jay Chou", album: nil, duration: 269,
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.item.artist, "周杰伦")
        XCTAssertEqual(candidates.first?.item.title, "晴天")
        XCTAssertEqual(candidates.first?.item.externalId, "amll:7")
        XCTAssertEqual(candidates.first?.lyrics.count, 2)
        XCTAssertTrue(candidates.first?.lyrics.allSatisfy(\.isWordLevel) ?? false)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/v1/lyrics/get" }.count, 1)
    }

    func testManualAMLLCandidatesRespectDisabledSourcesAndDuration() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/v1/lyrics/get"
                ? .init(body: Self.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
                : .init(body: Self.amllSearchBody([(7, "Song", "Singer")]))
        }
        defer { fixture.close() }
        let scraper = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let disabled = await manager.manualLyricsCandidates(title: "Song", artist: "Singer", album: nil, duration: 240,
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: false, priority: 0)]))
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
        let tooLong = await manager.manualLyricsCandidates(title: "Song", artist: "Singer", album: nil, duration: 100,
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertTrue(tooLong.isEmpty)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testManualAMLLFailureStillQueriesLyricsServer() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.host == "api.amll.dev"
                ? .init(status: 503, headers: ["Retry-After": "60"])
                : .init(body: Data("[00:01.00]歌词".utf8))
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let server = LyricsAPIServerScraper(servers: [.init(address: fixture.url("api"))], session: fixture.session)
        let manager = ScraperManager(scraperFactory: { config in
            if config.type == .amll { return amll }
            return server
        })
        let settings = ScraperSettings(sources: [
            .init(id: "amll", type: .amll, isEnabled: true, priority: 0),
            .init(id: "server", type: .lyricsServer, isEnabled: true, priority: 1)
        ])
        for _ in 0..<2 {
            let candidates = await manager.manualLyricsCandidates(title: "Song", artist: "Singer", album: nil,
                duration: 240, settings: settings)
            XCTAssertEqual(candidates.map(\.config.id), ["server"])
        }
        XCTAssertEqual(fixture.requests.filter { $0.url?.host == "api.amll.dev" }.count, 1,
            "The manual path must share the source cooldown")
    }

    func testAMLLLyricsLongerThanTheSongFallThroughToLRCLIB() async {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/v1/lyrics/search":
                return .init(body: SharedScraperRequestTests.amllSearchBody([(7, "Song", "Artist")]))
            case "/v1/lyrics/get":
                return .init(body: SharedScraperRequestTests.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
            case "/api/get":
                return .init(body: Data(#"{"syncedLyrics":"[00:01.00]Hello"}"#.utf8))
            default:
                return .init(status: 404)
            }
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let lrclib = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { config in
            if config.type == .amll { return amll }
            return lrclib
        })
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: 150,
            needs: .init(metadata: false, cover: false, lyrics: true), settings: .init(sources: [
                .init(id: "amll", type: .amll, isEnabled: true, priority: 0),
                .init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 1)
            ]))
        XCTAssertEqual(result.lyrics?.map(\.text), ["Hello"])
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/v1/lyrics/search", "/v1/lyrics/get", "/api/get"])
    }

    func testLineTimedLyricsAskTheNextSourceForWordTiming() async {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/api/get":
                return .init(body: Data(#"{"syncedLyrics":"[00:10.00]Paper towers\n[03:10.00]Meet the quay","plainLyrics":"Paper towers\nMeet the quay"}"#.utf8))
            case "/v1/lyrics/search":
                return .init(body: SharedScraperRequestTests.amllSearchBody([(7, "Song", "Artist")]))
            case "/v1/lyrics/get":
                return .init(body: SharedScraperRequestTests.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
            default:
                return .init(status: 404)
            }
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let lrclib = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { config in
            if config.type == .amll { return amll }
            return lrclib
        })
        // LRCLIB 排在前面、只给逐行：再问后面的 AMLL，拿到逐字就用逐字。
        var settings = ScraperSettings(sources: [
            .init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 0),
            .init(id: "amll", type: .amll, isEnabled: true, priority: 1)
        ])
        let needs = ScraperManager.ScrapeNeeds(metadata: false, cover: false, lyrics: true)
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: 269,
                                                  needs: needs, settings: settings)
        XCTAssertEqual(result.lyrics?.count, 2)
        XCTAssertTrue(result.lyrics?.allSatisfy(\.isWordLevel) ?? false)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/api/get", "/v1/lyrics/search", "/v1/lyrics/get"])
        settings.fieldRules[.lyrics].preferredSource = MusicScraperType.lrclib.rawValue
        let preferred = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: 269,
                                                     needs: needs, settings: settings, collectingReview: true)
        XCTAssertEqual(preferred.lyrics?.count, 2)
        XCTAssertFalse(preferred.lyrics?.first?.isWordLevel ?? true)
        let options = preferred.review.options[.lyrics] ?? []
        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(preferred.review.recommended[.lyrics], options.first?.id)
        let variants = options.compactMap { option -> ScrapeReviewLyrics? in
            if case .lyrics(let value) = option.value { return value }
            return nil
        }
        XCTAssertEqual(variants.map(\.summary.isWordLevel), [false, false, true])
        XCTAssertEqual(variants.map(\.summary.isSynchronized), [true, false, true])
        XCTAssertEqual(variants.map(\.format), ["LRC", nil, "TTML"])
        settings.fieldRules[.lyrics].mode = .skip
        let requestCount = fixture.requests.count
        let skipped = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: 269,
                                                   needs: needs, settings: settings)
        XCTAssertNil(skipped.lyrics)
        XCTAssertEqual(requestCount, fixture.requests.count)
    }

    func testTimingPickAsksTwoMoreSourcesAndKeepsWhatItHas() async {
        let first = StubDirectLyricsScraper(.success("[00:01.00]Hello\n[00:03.00]World"))
        let failing = StubDirectLyricsScraper(.failure(ScraperError.networkError("HTTP 500")))
        let sameLevel = StubDirectLyricsScraper(.success("[00:01.00]Other\n[00:03.00]Lyrics"))
        let wordTimed = StubDirectLyricsScraper(.success("[00:01.00]<00:01.00>Hel<00:01.50>lo"))
        let stubs = ["a": first, "b": failing, "c": sameLevel, "d": wordTimed]
        let manager = ScraperManager(scraperFactory: { config in stubs[config.id] ?? wordTimed })
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true), settings: .init(sources: [
                .init(id: "a", type: .lrclib, isEnabled: true, priority: 0),
                .init(id: "b", type: .lrclib, isEnabled: true, priority: 1),
                .init(id: "c", type: .lrclib, isEnabled: true, priority: 2),
                .init(id: "d", type: .lrclib, isEnabled: true, priority: 3)
            ]))
        // 出错的和同级的都不顶掉先拿到的那份；多问两个之后就停，第四个源不问。
        XCTAssertEqual(result.lyrics?.map(\.text), ["Hello", "World"])
        XCTAssertEqual(result.errors.count, 1)
        let first1 = await first.requestCount
        let failing1 = await failing.requestCount
        let same1 = await sameLevel.requestCount
        let word1 = await wordTimed.requestCount
        XCTAssertEqual([first1, failing1, same1, word1], [1, 1, 1, 0])
    }

    func testWordDiscoveryContinuesPastLineTimedFallbackLimit() async {
        let line = StubDirectLyricsScraper(.success("[00:01.00]Hello"))
        let word = StubDirectLyricsScraper(.success("[00:01.00]<00:01.00>Hel<00:01.50>lo"))
        let manager = ScraperManager(scraperFactory: { config in config.id == "word" ? word : line })
        let sources = (0..<4).map { index in
            ScraperSourceConfig(id: "line-\(index)", type: .lrclib, isEnabled: true, priority: index)
        } + [ScraperSourceConfig(id: "word", type: .lrclib, isEnabled: true, priority: 4)]
        let result = await manager.scrapeMetadata(
            title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: sources), requiresWordTiming: true
        )
        XCTAssertEqual(result.lyrics.map { LyricsTimingLevel(lines: $0) }, .word)
        let lineCount = await line.requestCount
        let wordCount = await word.requestCount
        XCTAssertEqual(lineCount, 4)
        XCTAssertEqual(wordCount, 1)
    }

    func testWordDiscoveryDoesNotReturnLineTimedLyricsAsSuccess() async {
        let line = StubDirectLyricsScraper(.success("[00:01.00]Hello"))
        let manager = ScraperManager(scraperFactory: { _ in line })
        let result = await manager.scrapeMetadata(
            title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "line", type: .lrclib, isEnabled: true, priority: 0)]),
            requiresWordTiming: true
        )
        XCTAssertNil(result.lyrics)
        XCTAssertTrue(result.errors.isEmpty)
    }

    @MainActor
    func testPlayerActivitiesStayWithTheirSongAndKeepOtherTasksVisible() async throws {
        let store = PlayerActivityStore()
        let first = UUID(), second = UUID(), batch = UUID()
        store.publish(.init(id: first, songID: "a", title: "lyrics", progress: nil))
        store.publish(.init(id: second, songID: "b", title: "cover", progress: nil))
        XCTAssertEqual(store.status(for: "a")?.id, first)
        XCTAssertEqual(store.status(for: "b")?.id, second)
        XCTAssertNil(store.status(for: "c"))
        XCTAssertNil(store.status(for: nil))
        store.publish(.init(id: batch, songID: nil, title: "batch", progress: 0.5))
        store.remove(first)
        XCTAssertEqual(store.status(for: "a")?.id, batch)
        store.remove(batch)
        XCTAssertEqual(store.status(for: "b")?.id, second)
        let preview = VStack(spacing: 20) {
            ForEach([false, true], id: \.self) { activityFirst in
                PlayerStatusItemsRow(items: activityFirst ? [.activity, .source] : [.source, .activity]) { item in
                    if item == .source {
                        Label("Navidrome", systemImage: "externaldrive")
                    } else {
                        PlayerActivityStatusView(status: .init(
                            id: first, songID: "a", title: "正在获取逐字歌词", progress: 0.5
                        ))
                    }
                }
            }
            PlayerStatusItemsRow(items: [.source, .output, .activity]) { item in
                switch item {
                case .source: Label("Navidrome", systemImage: "externaldrive")
                case .output: Label("AirPods", systemImage: "headphones")
                case .activity:
                    PlayerActivityStatusView(status: .init(
                        id: first, songID: "a", title: "逐字歌词已下载", progress: nil, isRunning: false
                    ))
                case .sleepTimer: EmptyView()
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(24)
        .frame(width: 390)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
        let inline = UIHostingController(rootView: PlayerStatusItemsRow(items: [.source, .activity]) { item in
            if item == .source {
                Label("Navidrome", systemImage: "externaldrive")
            } else {
                PlayerActivityStatusView(status: .init(
                    id: first, songID: "a", title: "正在从 AMLL 获取逐字歌词", progress: 0.5
                ))
            }
        })
        inline.safeAreaRegions = []
        let fitted = inline.sizeThatFits(in: CGSize(width: 338, height: 100))
        XCTAssertLessThanOrEqual(fitted.height, 20, "Task activity must stay within the existing footer line")
        let host = UIHostingController(rootView: preview)
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 184)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "player-activity-status"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPlaybackDiscoveryInstallsLyricsWithoutALyricsView() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.close() }
        LyricsDocumentPinStore.shared.setAutomaticPick("song.lrc", forSongID: fixture.song.id)
        let completed = expectation(description: "installed")
        fixture.start { _, _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertEqual(cached.map { LyricsTimingLevel(lines: $0) }, .word)
        XCTAssertEqual(fixture.state.song?.id, fixture.song.id)
    }

    @MainActor
    func testPlaybackDiscoveryPreservesConcurrentEdits() async throws {
        let fixture = try DiscoveryFixture(delay: .milliseconds(200))
        defer { fixture.close() }
        fixture.start()
        await fixture.waitForRequest()
        var edited = [LyricLine(timestamp: 1, text: "Edited by user")]
        edited[0].documentIsLocalOverride = true
        _ = await MetadataAssetStore.shared.cacheLyrics(edited, forSongID: fixture.song.id, force: true)
        try await Task.sleep(for: .milliseconds(300))
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertEqual(cached?.first?.text, "Edited by user")
        XCTAssertEqual(cached?.first?.documentIsLocalOverride, true)
    }

    @MainActor
    func testPlaybackDiscoveryCancelsOnSongChangeAndCanRetry() async throws {
        let fixture = try DiscoveryFixture(delay: .milliseconds(200))
        defer { fixture.close() }
        fixture.start()
        await fixture.waitForRequest()
        fixture.state.song = nil
        try await Task.sleep(for: .milliseconds(40))
        let cancelledCache = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertNil(cancelledCache)
        XCTAssertNil(PlayerActivityStore.shared.status(for: fixture.song.id))
        let completed = expectation(description: "retry installed")
        fixture.installed = { _, _ in completed.fulfill() }
        fixture.state.song = fixture.song
        await fulfillment(of: [completed], timeout: 3)
        let requests = await fixture.stub.requestCount
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    func testPlaybackDiscoveryTurningOffCancelsPendingResult() async throws {
        let fixture = try DiscoveryFixture(delay: .milliseconds(200))
        defer { fixture.close() }
        fixture.start()
        await fixture.waitForRequest()
        fixture.defaults.set(false, forKey: WordLyricsDiscoveryPreferences.enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: fixture.defaults)
        try await Task.sleep(for: .milliseconds(300))
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertNil(cached)
        XCTAssertNil(PlayerActivityStore.shared.status(for: fixture.song.id))
    }

    func testExistingSettingsGainAMLLRightBeforeLRCLIB() throws {
        let suite = "amll-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = ScraperSettings(sources: [
            .init(id: "itunes", type: .itunes, isEnabled: true, priority: 0),
            .init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 1),
            .init(id: "musicbrainz", type: .musicBrainz, isEnabled: false, priority: 2),
            .init(id: "server", type: .lyricsServer, isEnabled: false, priority: 3)
        ])
        saved.save(defaults: defaults)

        let loaded = ScraperSettings.load(defaults: defaults)
        let builtIns = loaded.sources.filter(\.type.isBuiltIn).map(\.type)
        XCTAssertEqual(builtIns, [.itunes, .amll, .lrclib, .musicBrainz, .lyricsServer, .custom("m8tec")])
        XCTAssertEqual(loaded.sources.first { $0.type == .amll }?.isEnabled, true)
        XCTAssertEqual(loaded.sources.map(\.priority), Array(loaded.sources.indices))
    }

    private static func amllSearchBody(_ songs: [(id: Int, title: String, artist: String)]) -> Data {
        let items: [[String: Any]] = songs.map {
            ["id": $0.id, "musicNames": [$0.title], "artistNames": [$0.artist], "albumNames": []]
        }
        let body: [String: Any] = ["status": 200, "data": ["items": items, "pagination": [
            "page": 1, "pageSize": 50, "total": items.count, "totalPages": items.isEmpty ? 0 : 1, "hasMore": false
        ]]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func amllLyricsBody(id: Int, lastLineEnd: String) -> Data {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>\
        <p begin="00:10.000" end="00:12.000" ttm:agent="v1"><span begin="00:10.000" end="00:11.000">故</span>\
        <span begin="00:11.000" end="00:12.000">事</span></p>\
        <p begin="03:10.000" end="\(lastLineEnd)" ttm:agent="v1"><span begin="03:10.000" end="03:15.000">的</span>\
        <span begin="03:15.000" end="\(lastLineEnd)">花</span></p></div></body></tt>
        """
        let body: [String: Any] = ["status": 200, "data": [
            "id": id, "musicNames": ["x"], "artistNames": ["y"], "albumNames": [], "lyrics": ttml, "format": "ttml"
        ]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func scrape(_ manager: ScraperManager, type: MusicScraperType) async -> ScrapeResult {
        await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "row", type: type, isEnabled: true, priority: 0)]))
    }

    private func encryptedFixture(
        status: Int, headers: [String: String] = [:], error: URLError? = nil
    ) -> ScraperHTTPFixture {
        ScraperHTTPFixture { request in
            if request.url?.path == "/lyrics" {
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"one"},{"id":"two"}]}"#.utf8))
            }
            return .init(status: status, headers: headers, error: error)
        }
    }

    private func assertRateLimited(
        file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected server cooldown", file: file, line: line)
        } catch ScraperError.rateLimited(let delay) {
            XCTAssertGreaterThanOrEqual(delay ?? 0, 3599, file: file, line: line)
        } catch {
            XCTFail("Expected rate limit, got \(error)", file: file, line: line)
        }
    }
}

/// Only the HTTP transport is replaced: requests still pass through the real
/// scraper, request executor, response validation and fixed data decoding.
private final class ScraperHTTPFixture: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let session: URLSession
    private let state: ScraperFixtureProtocol.State

    init(reply: @escaping @Sendable (URLRequest) -> ScraperFixtureProtocol.Reply) {
        state = .init(reply: reply)
        ScraperFixtureProtocol.register(state, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScraperFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Scraper-Fixture": id]
        session = URLSession(configuration: configuration)
    }

    var requests: [URLRequest] { state.requests }
    func url(_ path: String) -> String { "https://\(id).test/\(path)" }
    func config() -> ScraperConfig {
        .init(id: id, name: "Fixture", version: 1, rateLimit: 0,
              capabilities: ["metadata", "cover", "lyrics"],
              search: .init(url: url("search"), method: "GET", script: "return response;"))
    }
    func encryptedConfig() -> ScraperConfig {
        var value = config()
        value.lyrics = .init(url: url("lyrics"), method: "GET", script: "return response;")
        value.secrets = ["lyricsFetchUrl": url("encrypted/{{id}}"), "lyricsContentField": "content",
                         "lyricsMagicHex": "00", "lyricsXorKeyHex": "01"]
        return value
    }
    func close() {
        session.invalidateAndCancel()
        ScraperFixtureProtocol.remove(id: id)
    }
}

private final class ScraperFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data("[]".utf8)
        var error: URLError?
    }
    final class State: @unchecked Sendable {
        let reply: @Sendable (URLRequest) -> Reply
        private let lock = NSLock()
        private var captured: [URLRequest] = []
        init(reply: @escaping @Sendable (URLRequest) -> Reply) { self.reply = reply }
        var requests: [URLRequest] { lock.withLock { captured } }
        func record(_ request: URLRequest) { lock.withLock { captured.append(request) } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    static func register(_ state: State, id: String) { lock.withLock { states[id] = state } }
    static func remove(id: String) { _ = lock.withLock { states.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let id = request.value(forHTTPHeaderField: "X-Scraper-Fixture"),
              let state = Self.lock.withLock({ Self.states[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        state.record(captured)
        let reply = state.reply(captured)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ScraperTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(to time: TimeInterval) { lock.withLock { value = time } }
    var timing: RequestExecutor.Timing { .init(now: { self.now }) }
}

/// 直接按歌名取歌词的源的替身：固定返回一份歌词、没有或出错，并记下被问了几次。
private actor StubDirectLyricsScraper: MusicScraper, DirectLyricsLookup {
    let type = MusicScraperType.lrclib
    private let reply: Result<String?, any Error>
    private let delay: Duration
    private(set) var requestCount = 0

    init(_ reply: Result<String?, any Error>, delay: Duration = .zero) {
        self.reply = reply
        self.delay = delay
    }

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        .empty(.lrclib)
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? { nil }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] { [] }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }

    func fetchLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> ScraperLyricsResult? {
        requestCount += 1
        try? await Task.sleep(for: delay)
        return try reply.get().map { ScraperLyricsResult(source: .lrclib, lrcContent: $0) }
    }
}

/// 只剩歌名可比(没有歌手、也没有时长)时,括号里的版本说明要照写对上。
final class ScraperTitleOnlyMatchTests: XCTestCase {
    private func item(_ title: String, artist: String? = nil, durationMs: Int? = nil) -> ScraperSearchItem {
        ScraperSearchItem(externalId: title, source: .itunes, title: title, artist: artist, durationMs: durationMs)
    }

    func testVersionNoteKeepsTheOriginalSongFromMatching() {
        let written = "The Final Countdown (&TEAM ver.)"
        let cleaned = ScraperManager.cleanTitle(written)
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown"), title: cleaned, artist: nil, durationMs: nil, writtenTitle: written
        ))
        XCTAssertNil(ScraperManager.bestMatch(
            in: [item("The Final Countdown")], title: cleaned, artist: nil, durationMs: nil, writtenTitle: written
        ))
    }

    func testSameVersionNoteStillMatches() {
        let written = "04. The Final Countdown（&TEAM Ver.）"
        let cleaned = ScraperManager.cleanTitle(written)
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown (&TEAM ver.)"), title: cleaned, artist: nil, durationMs: nil, writtenTitle: written
        ))
    }

    func testPlainTitleWithoutNotesStillMatches() {
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(
            item("Hello"), title: "Hello", artist: nil, durationMs: nil, writtenTitle: "Hello"
        ))
    }

    func testArtistEvidenceStillDecidesWhenPresent() {
        let written = "The Final Countdown (&TEAM ver.)"
        let cleaned = ScraperManager.cleanTitle(written)
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown", artist: "Europe"), title: cleaned, artist: "&TEAM", durationMs: nil,
            writtenTitle: written
        ))
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown (&TEAM ver.)", artist: "&TEAM"), title: cleaned, artist: "&TEAM",
            durationMs: nil, writtenTitle: written
        ))
    }
}


@MainActor @Observable
private final class DiscoveryPlaybackState {
    var song: Song?
}

@MainActor
private final class DiscoveryFixture {
    let suite = "word-discovery-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let song: Song
    let state = DiscoveryPlaybackState()
    let stub: StubDirectLyricsScraper
    var coordinator: PlaybackWordLyricsDiscovery?
    var installed: (Song, [LyricLine]) -> Void = { _, _ in }

    init(delay: Duration = .zero) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: WordLyricsDiscoveryPreferences.enabledKey)
        song = Song(id: UUID().uuidString, title: "Song", fileFormat: .mp3, filePath: "song.mp3", sourceID: "test")
        state.song = song
        stub = StubDirectLyricsScraper(.success("[00:01.00]<00:01.00>Hel<00:01.50>lo"), delay: delay)
    }

    func start(installed: @escaping (Song, [LyricLine]) -> Void = { _, _ in }) {
        self.installed = installed
        let state = state
        let stub = stub
        coordinator = PlaybackWordLyricsDiscovery(
            playback: { .init(song: state.song, isPlaying: state.song != nil, isSpokenWord: false) },
            load: { _ in [] },
            didInstall: { [weak self] song, lines in self?.installed(song, lines) },
            scraper: ScraperManager(scraperFactory: { _ in stub }),
            defaults: defaults,
            settings: { .init(sources: [.init(id: "test", type: .lrclib, isEnabled: true, priority: 0)]) },
            debounce: .zero
        )
    }

    func waitForRequest() async {
        for _ in 0..<200 {
            if await stub.requestCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Discovery did not request lyrics")
    }

    func close() {
        state.song = nil
        coordinator = nil
        defaults.removePersistentDomain(forName: suite)
        let songID = song.id
        LyricsDocumentPinStore.shared.forgetFile(named: "song.lrc", forSongID: songID)
        if let status = PlayerActivityStore.shared.status(for: songID) {
            PlayerActivityStore.shared.remove(status.id)
        }
        Task { _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID) }
    }
}

final class BuiltInScraperRegressionTests: XCTestCase {
    private static let lyric = "[00:01.00]小船停在清晨的岸边\n[00:03.00]纸灯照亮未写的明天"

    private static func row(id: Int = 1, title: String = "纸灯", artist: String = "林舟", duration: Double = 180) -> [String: Any] {
        ["id": id, "trackName": title, "artistName": artist, "albumName": "岸边", "duration": duration, "syncedLyrics": lyric]
    }

    private static func data(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private static func query(_ request: URLRequest, _ key: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }

    func testManualMusicBrainzUsesSeparateFieldsAndKeepsLuceneEscaping() async throws {
        let fixture = ScraperHTTPFixture { _ in .init(body: Data(#"{"recordings":[]}"#.utf8)) }
        defer { fixture.close() }
        let identity = ScraperManager.manualSearchIdentity(query: "纸灯 林舟", title: "纸灯", artist: "林舟", source: .musicBrainz)
        _ = try await MusicBrainzScraper(session: fixture.session, requestExecutor: RequestExecutor()).search(
            query: identity.title, artist: identity.artist, album: nil, limit: 20)
        XCTAssertEqual(Self.query(try XCTUnwrap(fixture.requests.first), "query"), "recording:\"纸灯\" AND artist:\"林舟\"")
        let custom = ScraperManager.manualSearchIdentity(query: "纸灯 林舟", title: "纸灯", artist: "林舟", source: .custom("existing"))
        XCTAssertEqual(custom.title, "纸灯 林舟")
        XCTAssertNil(custom.artist)
    }

    func testLRCLIBManualCandidatesUseRealIDsAndCachedLyrics() async throws {
        let fixture = ScraperHTTPFixture { _ in .init(body: Self.data([Self.row(), Self.row(id: 2, title: "纸灯 (Live)")])) }
        defer { fixture.close() }
        let scraper = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let results = await manager.manualLyricsCandidates(title: "纸灯", artist: "林舟", album: nil, duration: 180,
            settings: .init(sources: [.init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 0)]))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.item.externalId, "lrclib:1")
        XCTAssertEqual(results.first?.lyrics.count, 2)
        XCTAssertEqual(fixture.requests.count, 1, "Search already returns lyrics; selecting candidates must not refetch them")
    }

    func testLRCLIBExactMissFallsBackWithoutAlbumAndRejectsWrongArtistVersionAndDuration() async throws {
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path == "/api/get" { return .init(status: 404) }
            return .init(body: Self.data([
                Self.row(id: 1, artist: "别的歌手"), Self.row(id: 2, title: "纸灯 (Live)"),
                Self.row(id: 3, duration: 240), Self.row(id: 4, title: "紙燈", artist: "林舟", duration: 182)
            ]))
        }
        defer { fixture.close() }
        let result = try await LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor()).fetchLyrics(
            title: "纸灯", artist: "林舟", album: "本地文件夹名称", duration: 180)
        XCTAssertEqual(result?.lrcContent, Self.lyric)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/api/get", "/api/search"])
        XCTAssertNil(Self.query(fixture.requests[1], "album_name"))
    }

    func testLRCLIBFailureDoesNotTriggerBroaderSearch() async throws {
        for status in [429, 500] {
            let fixture = ScraperHTTPFixture { _ in .init(status: status, headers: ["Retry-After": "60"]) }
            defer { fixture.close() }
            do {
                _ = try await LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor()).fetchLyrics(title: "纸灯", artist: "林舟")
                XCTFail("A service failure must remain distinguishable from a miss")
            } catch { }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testLRCLIBWrongArtistIsNeverAcceptedByAutomaticFallback() async throws {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/api/get" ? .init(status: 404)
                : .init(body: Self.data([Self.row(artist: "别的歌手")]))
        }
        defer { fixture.close() }
        let result = try await LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor()).fetchLyrics(title: "纸灯", artist: "林舟", duration: 180)
        XCTAssertNil(result)
    }

    func testAppleChineseStorefrontSurvivesDetailLookupAndTraditionalNamesMatch() async throws {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Self.data(["resultCount": 1, "results": [["trackId": 7, "artistId": 8, "trackName": "紙燈", "artistName": "林舟", "trackTimeMillis": 180000]]]))
        }
        defer { fixture.close() }
        let scraper = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "纸灯", artist: "林舟", album: nil, limit: 15)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(Self.query(fixture.requests[0], "country"), "TW")
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(try XCTUnwrap(result.items.first), title: "纸灯", artist: "林舟", durationMs: 180000))
        let reopened = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        _ = try await reopened.getDetail(externalId: try XCTUnwrap(result.items.first?.externalId))
        XCTAssertEqual(Self.query(fixture.requests.last!, "country"), "TW")
        XCTAssertEqual(Self.query(fixture.requests.last!, "id"), "7")
    }

    func testAppleFallbackVerifiesAliasByArtistIDAndRepairsFilenameTitle() async throws {
        let fixture = ScraperHTTPFixture { request in
            let artist = Self.query(request, "country") == "TW" ? "林舟" : "Paper Boat"
            return .init(body: Self.data(["resultCount": 1, "results": [["trackId": 7, "artistId": 8, "trackName": "纸灯", "artistName": artist, "trackTimeMillis": 180000]]]))
        }
        defer { fixture.close() }
        let scraper = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "林舟 - 纸灯", artist: "Paper Boat", album: nil, limit: 15)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(Set(item.artistAliases), ["林舟", "Paper Boat"])
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(item, title: "林舟 - 纸灯", artist: "Paper Boat", durationMs: 180000))
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(item, title: "纸灯", artist: "另一歌手", durationMs: 180000))
    }

    func testAppleDifferentArtistIDsDoNotCreateAliases() async throws {
        let fixture = ScraperHTTPFixture { request in
            let native = Self.query(request, "country") == "TW"
            return .init(body: Self.data(["resultCount": 1, "results": [["trackId": native ? 9 : 7, "artistId": native ? 10 : 8,
                                                                       "trackName": "纸灯", "artistName": native ? "林舟" : "Paper Boat"]]]))
        }
        defer { fixture.close() }
        let scraper = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "林舟 - 纸灯", artist: "Paper Boat", album: nil, limit: 15)
        XCTAssertFalse(result.items.contains { ScraperManager.isConfidentAutoMatch($0, title: "林舟 - 纸灯", artist: "Paper Boat", durationMs: 180000) })
    }

    func testMusicBrainzArtistAliasesRemainAttachedToDetail() async throws {
        let artistID = "10000000-0000-0000-0000-000000000001"
        let recordingID = "20000000-0000-0000-0000-000000000001"
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path.contains("/artist/") == true {
                return .init(body: Self.data(["id": artistID, "name": "林舟", "aliases": [["name": "Paper Boat"]]]))
            }
            let recording: [String: Any] = ["id": recordingID, "title": "纸灯", "length": 180000,
                                            "artist-credit": [["name": "林舟", "artist": ["id": artistID, "name": "林舟"]]]]
            let isSearch = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "ws/2/recording"
            let searchesAlias = Self.query(request, "query")?.contains("artist:") == true
            let body: [String: Any] = isSearch ? ["recordings": searchesAlias ? [] : [recording]] : recording
            return .init(body: Self.data(body))
        }
        defer { fixture.close() }
        let scraper = MusicBrainzScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "纸灯", artist: "Paper Boat", album: nil, limit: 15)
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(try XCTUnwrap(result.items.first), title: "纸灯", artist: "Paper Boat", durationMs: 180000))
        let detail = try await scraper.getDetail(externalId: recordingID)
        XCTAssertTrue(detail?.artistAliases.contains("Paper Boat") == true)
    }

    func testNativeAutomaticMatchDoesNotReplaceLiveWithStudio() {
        let candidate = ScraperSearchItem(externalId: "7", source: .itunes, title: "纸灯", artist: "林舟", durationMs: 180000)
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(candidate, title: "纸灯", artist: "林舟", durationMs: 180000, writtenTitle: "纸灯 (Live)"))
    }

    func testCooldownIsReportedWithoutSendingRequests() async throws {
        let clock = ScraperTestClock()
        let fixture = ScraperHTTPFixture { _ in .init(status: 429, headers: ["Retry-After": "600"]) }
        defer { fixture.close() }
        let scraper = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor(timing: clock.timing))
        do { _ = try await scraper.fetchLyrics(title: "纸灯", artist: "林舟") } catch { }
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let result = await manager.scrapeMetadata(title: "纸灯", artist: "林舟", album: nil, duration: 180,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 0)]))
        XCTAssertEqual(result.unavailableParts, .lyrics)
        XCTAssertEqual(result.retryAfter, 600, accuracy: 0.01)
        XCTAssertEqual(fixture.requests.count, 1)
    }
}

@MainActor
final class BatchScraperRecoveryTests: XCTestCase {
    func testNewBatchDeduplicatesSongsAndResumesOnlyRemainingIDs() async throws {
        try await withFixture(failures: .max) { service, _, song, root, source, library in
            var second = song
            second.id = UUID().uuidString
            library.addSongs([song, second])
            _ = service.scrapeMissingMetadata(songs: [song, song, second], in: library, parts: .lyrics)
            XCTAssertEqual(service.totalCount, 2)
            let checkpointURL = root.appendingPathComponent("checkpoint/scrape-checkpoint.json")
            let initialCheckpoint = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: checkpointURL)
            ) as? [String: Any])
            XCTAssertEqual(initialCheckpoint["songIDs"] as? [String], [song.id, second.id])
            await service.waitUntilScrapeIdle()
            var checkpoint = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: checkpointURL)
            ) as? [String: Any])
            XCTAssertEqual(checkpoint["songIDs"] as? [String], [second.id, song.id])
            checkpoint["nextSongIndex"] = 1
            checkpoint["skippedCount"] = 1
            try JSONSerialization.data(withJSONObject: checkpoint).write(to: checkpointURL)

            let healthy = RecoveryLyricsProbe(failures: 0, returnsLyrics: false)
            let resumed = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [source] }),
                metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in healthy })),
                checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in })
            resumed.resumePendingScrape(in: library)
            await resumed.waitUntilScrapeIdle()
            XCTAssertEqual(resumed.lastCompletion?.processedSongCount, 2)
            XCTAssertEqual(resumed.lastCompletion?.skippedCount, 2)
            let requestCount = await healthy.requests
            XCTAssertEqual(requestCount, 1)
            XCTAssertFalse(resumed.hasPendingScrape)
        }
    }

    func testTransientFailureRetriesCurrentSongAndReturnsLyrics() async throws {
        try await withFixture(failures: 1) { service, _, song, _, _, _ in
            var delays: [TimeInterval] = []
            let result = try await service.processedSongForBatch(song, forceRescrape: true, parts: .lyrics,
                                                                 sleep: { delays.append($0) })
            XCTAssertEqual(result?.lyricsLines?.count, 2)
            XCTAssertEqual(delays, [5])
            XCTAssertTrue(result?.unavailableParts.isEmpty == true)
        }
    }

    func testUnavailableBatchPreservesCheckpointAndCanResumeAfterRestart() async throws {
        try await withFixture(failures: .max) { service, _, song, root, source, library in
            var second = song
            second.id = UUID().uuidString
            library.addSongs([song, second])
            _ = service.scrapeMissingMetadata(songs: [song, second], in: library, parts: .lyrics)
            await service.waitUntilScrapeIdle()
            XCTAssertTrue(service.hasPendingScrape)
            XCTAssertEqual(service.processedCount, 0)
            XCTAssertEqual(service.skippedCount, 0)
            XCTAssertNil(service.lastCompletion)
            let checkpoint = try Data(contentsOf: root.appendingPathComponent("checkpoint/scrape-checkpoint.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: checkpoint) as? [String: Any])
            XCTAssertEqual(json["nextSongIndex"] as? Int, 0)
            let healthy = RecoveryLyricsProbe(failures: 0, returnsLyrics: false)
            let resumed = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [source] }),
                metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in healthy })),
                checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in })
            resumed.resumePendingScrape(in: library)
            await resumed.waitUntilScrapeIdle()
            XCTAssertFalse(resumed.hasPendingScrape)
            XCTAssertEqual(resumed.lastCompletion?.processedSongCount, 2)
            XCTAssertEqual(resumed.lastCompletion?.skippedCount, 2, "Confirmed misses may complete; unavailable lookups may not")
        }
    }

    func testCancellationDuringRetryDoesNotTryAnotherSong() async throws {
        try await withFixture(failures: .max) { service, probe, song, _, _, _ in
            do {
                _ = try await service.processedSongForBatch(song, forceRescrape: true, parts: .lyrics,
                    sleep: { _ in throw CancellationError() })
                XCTFail("Cancellation must leave the request pending")
            } catch is CancellationError { }
            let requests = await probe.requests
            XCTAssertEqual(requests, 1)
        }
    }

    func testUnrequestedLyricsFailureDoesNotBlockMetadataBatch() async throws {
        try await withFixture(failures: .max) { service, _, song, _, _, _ in
            let result = try await service.processedSongForBatch(song, forceRescrape: true, parts: .metadata,
                sleep: { _ in XCTFail("Unrequested assets must not hold this batch") })
            XCTAssertNotNil(result)
        }
    }

    /// 后台时间用完时批量刮削停在断点上；回到前台要接着刮，不能等系统哪天给 BGProcessing。
    func testForegroundResumesABatchTheSystemStoppedInThisLaunch() async throws {
        try await withFixture(failures: 0) { service, _, song, _, _, library in
            library.addSongs([song])
            // 续刮按可见集找断点里的歌(找不到就清断点)。真实流程里回前台要等曲库就绪再隔几秒；
            // 这里不靠时间，直接等可见集发布。
            await library.waitForPendingIndex()
            XCTAssertNotNil(library.visibleSong(id: song.id))
            _ = service.scrapeMissingMetadata(songs: [song], in: library, parts: .lyrics)
            XCTAssertTrue(service.isScraping)
            service.cancelPreservingCheckpoint(reason: .backgroundTimeExpired)
            XCTAssertFalse(service.isScraping)
            XCTAssertTrue(service.hasPendingScrape)

            XCTAssertEqual(
                service.resumeInterruptedScrapeInForeground(in: library, isApplicationActive: true, isSafeModeActive: true),
                .skip(.safeMode)
            )
            XCTAssertEqual(
                service.resumeInterruptedScrapeInForeground(in: library, isApplicationActive: false, isSafeModeActive: false),
                .skip(.leavingForeground)
            )
            XCTAssertFalse(service.isScraping)
            XCTAssertEqual(
                service.resumeInterruptedScrapeInForeground(in: library, isApplicationActive: true, isSafeModeActive: false),
                .resume
            )
            XCTAssertTrue(service.isScraping)
            await service.waitUntilScrapeIdle()
            XCTAssertFalse(service.hasPendingScrape)
            XCTAssertEqual(service.lastCompletion?.processedSongCount, 1)
        }
    }

    /// 用户点停止会清掉断点：回到前台什么也不续。
    func testForegroundNeverResumesABatchTheUserStopped() async throws {
        try await withFixture(failures: 0) { service, probe, song, _, _, library in
            library.addSongs([song])
            _ = service.scrapeMissingMetadata(songs: [song], in: library, parts: .lyrics)
            XCTAssertTrue(service.isScraping)
            service.cancel()
            XCTAssertFalse(service.hasPendingScrape)
            XCTAssertEqual(
                service.resumeInterruptedScrapeInForeground(in: library, isApplicationActive: true, isSafeModeActive: false),
                .skip(.noCheckpoint)
            )
            XCTAssertFalse(service.isScraping)
            let requests = await probe.requests
            XCTAssertEqual(requests, 0)
        }
    }

    /// 被系统回收后重新打开：上一个进程留下的断点在前台接着刮。
    func testForegroundResumesACheckpointLeftByAnEarlierLaunch() async throws {
        try await withFixture(failures: .max) { service, _, song, root, source, library in
            var second = song
            second.id = UUID().uuidString
            library.addSongs([song, second])
            await library.waitForPendingIndex()
            XCTAssertNotNil(library.visibleSong(id: second.id))
            _ = service.scrapeMissingMetadata(songs: [song, second], in: library, parts: .lyrics)
            await service.waitUntilScrapeIdle()
            XCTAssertTrue(service.hasPendingScrape)

            let healthy = RecoveryLyricsProbe(failures: 0, returnsLyrics: false)
            let relaunched = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [source] }),
                metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in healthy })),
                checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in })
            XCTAssertEqual(
                relaunched.resumeInterruptedScrapeInForeground(in: library, isApplicationActive: true, isSafeModeActive: false),
                .resume
            )
            await relaunched.waitUntilScrapeIdle()
            XCTAssertFalse(relaunched.hasPendingScrape)
            XCTAssertEqual(relaunched.lastCompletion?.processedSongCount, 2)
        }
    }

    /// 上一次打开时从同一位置自动续过、一首都没往前走进程就没了：这次不在前台再试，免得每次打开都闪退。
    func testForegroundSkipsACheckpointTheEarlierLaunchCouldNotAdvance() async throws {
        try await withFixture(failures: .max) { service, _, song, root, source, library in
            library.addSongs([song])
            _ = service.scrapeMissingMetadata(songs: [song], in: library, parts: .lyrics)
            await service.waitUntilScrapeIdle()
            XCTAssertTrue(service.hasPendingScrape)
            let checkpointURL = root.appendingPathComponent("checkpoint/scrape-checkpoint.json")
            var checkpoint = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: checkpointURL)
            ) as? [String: Any])
            checkpoint["launchResumeIndex"] = checkpoint["nextSongIndex"] as? Int ?? 0
            try JSONSerialization.data(withJSONObject: checkpoint).write(to: checkpointURL)

            let probe = RecoveryLyricsProbe(failures: 0, returnsLyrics: false)
            let relaunched = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [source] }),
                metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in probe })),
                checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in })
            XCTAssertEqual(
                relaunched.resumeInterruptedScrapeInForeground(in: library, isApplicationActive: true, isSafeModeActive: false),
                .skip(.noProgressSinceLastLaunch)
            )
            XCTAssertFalse(relaunched.isScraping)
            XCTAssertTrue(relaunched.hasPendingScrape)
            let requests = await probe.requests
            XCTAssertEqual(requests, 0)
        }
    }

    private func withFixture(failures: Int, body: (MusicScraperService, RecoveryLyricsProbe, Song, URL, MusicSource, MusicLibrary) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ScraperSettings.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: ScraperSettings.defaultsKey) }
            else { defaults.removeObject(forKey: ScraperSettings.defaultsKey) }
        }
        var settings = ScraperSettings.load()
        for index in settings.sources.indices { settings.sources[index].isEnabled = settings.sources[index].type == .lrclib }
        settings.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrape-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var wav = Data("RIFF".utf8)
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        wav.append(u32(196)); wav.append(Data("WAVEfmt ".utf8)); wav.append(u32(16)); wav.append(contentsOf: [1, 0, 1, 0])
        wav.append(u32(8000)); wav.append(u32(16000)); wav.append(contentsOf: [2, 0, 16, 0])
        wav.append(Data("data".utf8)); wav.append(u32(160)); wav.append(Data(repeating: 0, count: 160))
        try wav.write(to: root.appendingPathComponent("Paper Lantern.wav"))
        let source = MusicSource(id: UUID().uuidString, name: "Recovery fixture", type: .local, basePath: root.path)
        let probe = RecoveryLyricsProbe(failures: failures)
        let service = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [source] }),
            metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in probe })),
            checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in })
        let song = Song(id: UUID().uuidString, title: "Paper Lantern", fileFormat: .wav, filePath: "/Paper Lantern.wav", sourceID: source.id)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        defer { service.cancel() }
        try await body(service, probe, song, root, source, library)
    }
}

private actor RecoveryLyricsProbe: MusicScraper, DirectLyricsLookup {
    let type = MusicScraperType.lrclib
    private var failures: Int
    private let returnsLyrics: Bool
    private(set) var requests = 0
    init(failures: Int, returnsLyrics: Bool = true) { self.failures = failures; self.returnsLyrics = returnsLyrics }
    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult { .empty(.lrclib) }
    func getDetail(externalId: String) async throws -> ScraperDetail? { nil }
    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] { [] }
    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }
    func fetchLyrics(title: String, artist: String?, album: String?, duration: TimeInterval?) async throws -> ScraperLyricsResult? {
        requests += 1
        if failures > 0 { failures -= 1; throw URLError(.timedOut) }
        return returnsLyrics ? .init(source: .lrclib, lrcContent: "[00:01.00]Paper lights along the shore\n[00:03.00]Footsteps find an open door") : nil
    }
}

private actor ScraperSubscriptionFixture {
    private var manifest: String
    private(set) var requests = 0
    init(manifest: String) { self.manifest = manifest }
    func setManifest(_ manifest: String) { self.manifest = manifest }
    func load(_ url: URL) -> String {
        requests += 1
        return manifest
    }
}

/// 整库刮削的两份按歌数增长的状态：同名同大小副本的元数据种子只给真有副本的身份留,
/// 旁车写入排队有上限(每个排队的写入都抱着一张刮到的封面)。
@MainActor
final class BatchScrapeMemoryBoundsTests: XCTestCase {
    private func song(_ id: String, file: String, size: Int64, artist: String? = nil, duration: TimeInterval = 0) -> Song {
        Song(id: id, title: id, artistName: artist, duration: duration, fileFormat: .flac,
             filePath: "/music/\(file)", sourceID: "nas", fileSize: size)
    }

    func testOnlySharedIdentitiesGetASeedAndTheBestCopyWins() {
        let songs = [
            song("a1", file: "Track.flac", size: 1_000),
            song("a2", file: "track.flac", size: 1_000, artist: "Artist", duration: 200),
            song("b", file: "Other.flac", size: 1_000),
            song("c", file: "Track.flac", size: 2_000),
            song("unsized", file: "Track.flac", size: 0),
        ]
        let seeds = MusicScraperService.remoteMetadataSeedIDsForTesting(songs)
        // The two copies of Track.flac (same size) share the better-described one.
        XCTAssertEqual(seeds["a1"], "a2")
        XCTAssertEqual(seeds["a2"], "a2")
        // A song alone under its identity has no seed: it seeds itself, as before.
        XCTAssertNil(seeds["b"])
        XCTAssertNil(seeds["c"])
        XCTAssertNil(seeds["unsized"])
        XCTAssertEqual(seeds.count, 2)
    }

    func testLargeBatchesKeepNoSeedsForUniqueFiles() {
        let songs = (0..<5_000).map { song("s\($0)", file: "\($0).flac", size: Int64(1_000 + $0)) }
        XCTAssertTrue(MusicScraperService.remoteMetadataSeedIDsForTesting(songs).isEmpty)
    }

    func testSidecarBacklogIsBounded() {
        XCTAssertFalse(MusicScraperService.sidecarBacklogIsFull(queuedWrites: 0))
        XCTAssertFalse(MusicScraperService.sidecarBacklogIsFull(
            queuedWrites: MusicScraperService.maximumQueuedSidecarWrites - 1))
        XCTAssertTrue(MusicScraperService.sidecarBacklogIsFull(
            queuedWrites: MusicScraperService.maximumQueuedSidecarWrites))
        // Room for at least one publication batch beyond the batch being written.
        XCTAssertGreaterThanOrEqual(MusicScraperService.maximumQueuedSidecarWrites, 40)
    }
}

/// 一张封面下不来不能让整批刮削挂起:只算这一首没有封面,同一地址不再重复等待。
final class ScrapeResourceFailureTests: XCTestCase {
    private let settings = ScraperSettings(sources: [.init(id: "itunes", type: .itunes, isEnabled: true, priority: 0)])
    private let needs = ScraperManager.ScrapeNeeds(metadata: false, cover: true, lyrics: false)

    func testCoverTimeoutIsASongLevelMissNotSourceUnavailable() async {
        let downloads = DownloadCounter()
        let manager = ScraperManager(
            scraperFactory: { _ in CoverResourceProbe() },
            imageDownloader: { url, _ in
                await downloads.record(url)
                throw ScraperError.networkError("The request timed out.")
            }
        )
        let first = await manager.scrapeMetadata(title: "纸灯", artist: "林舟", album: nil, duration: 180,
                                                 needs: needs, settings: settings)
        XCTAssertNil(first.coverData)
        XCTAssertTrue(first.unavailableParts.isEmpty, "One broken image must not pause the whole batch")
        XCTAssertFalse(first.errors.isEmpty)

        let second = await manager.scrapeMetadata(title: "纸灯", artist: "林舟", album: nil, duration: 180,
                                                  needs: needs, settings: settings)
        XCTAssertTrue(second.unavailableParts.isEmpty)
        let count = await downloads.count
        XCTAssertEqual(count, 1, "A failed cover address is not requested again right away")
    }

    func testRateLimitedCoverStillMarksSourceUnavailable() async {
        let manager = ScraperManager(
            scraperFactory: { _ in CoverResourceProbe() },
            imageDownloader: { _, _ in throw ScraperError.rateLimited(retryAfter: 30) }
        )
        let result = await manager.scrapeMetadata(title: "纸灯", artist: "林舟", album: nil, duration: 180,
                                                  needs: needs, settings: settings)
        XCTAssertEqual(result.unavailableParts, .cover)
        XCTAssertEqual(result.retryAfter, 30, accuracy: 0.01)
    }

    func testDeferredSongMovesBehindRemainingSongs() {
        XCTAssertEqual(
            MusicScraperService.songIDsMovingDeferredSongToEnd("b", in: ["a", "b", "c", "d"], resumeIndex: 1),
            ["a", "c", "d", "b"]
        )
        // Already last, or before the resume point: order stays.
        XCTAssertEqual(
            MusicScraperService.songIDsMovingDeferredSongToEnd("d", in: ["a", "b", "c", "d"], resumeIndex: 3),
            ["a", "b", "c", "d"]
        )
        XCTAssertEqual(
            MusicScraperService.songIDsMovingDeferredSongToEnd("a", in: ["a", "b", "c"], resumeIndex: 1),
            ["a", "b", "c"]
        )
    }
}

private actor DownloadCounter {
    private(set) var count = 0
    func record(_ url: String) { count += 1 }
}

private struct CoverResourceProbe: MusicScraper {
    let type = MusicScraperType.itunes
    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        ScraperSearchResult(
            items: [ScraperSearchItem(externalId: "1", source: .itunes, title: "纸灯", artist: "林舟", durationMs: 180_000)],
            source: .itunes
        )
    }
    func getDetail(externalId: String) async throws -> ScraperDetail? { nil }
    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        [ScraperCoverResult(source: .itunes, coverUrl: "https://images.test/front-500")]
    }
    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }
}

final class ScrapeFieldAggregationTests: XCTestCase {
    private let apple = ScraperSourceConfig(id: "apple", type: .itunes, isEnabled: true, priority: 0)
    private let brainz = ScraperSourceConfig(id: "brainz", type: .musicBrainz, isEnabled: true, priority: 1)

    private func detail(_ source: MusicScraperType, album: String = "Paper Roads") -> ScraperDetail {
        .init(externalId: "track", source: source, title: "Copper Sky", artist: "North Quay",
              album: album, durationMs: 180_000)
    }

    private func scrape(_ first: ScraperDetail, _ second: ScraperDetail, settings: ScraperSettings,
                        fields: Set<ScrapeField>) async -> ScraperDetail? {
        let manager = ScraperManager(scraperFactory: { source in
            FieldDetailFixture(detail: source.type == first.source ? first : second)
        })
        return await manager.scrapeMetadata(
            title: "Copper Sky", artist: "North Quay", album: "Paper Roads", duration: 180,
            needs: .init(metadata: true, cover: false, lyrics: false, metadataFields: fields),
            settings: settings
        ).detail
    }

    func testPreferredFieldUsesSecondSourceAndFallsBackForMissingValues() async throws {
        var first = detail(.itunes)
        first.year = 2020
        first.genres = ["Folk"]
        var second = detail(.musicBrainz)
        second.genres = ["Chamber folk"]
        second.trackNumber = 8
        var settings = ScraperSettings(sources: [apple, brainz])
        settings.fieldRules[.genre].preferredSource = brainz.type.rawValue
        settings.fieldRules[.year].preferredSource = brainz.type.rawValue
        let result = await scrape(first, second, settings: settings, fields: [.genre, .track, .year])
        XCTAssertEqual(result?.genres, ["Chamber folk"])
        XCTAssertEqual(result?.year, 2020)
        XCTAssertEqual(result?.trackNumber, 8)
        let disabled = ScraperSettings(sources: [apple], fieldRules: settings.fieldRules)
        let fallback = await scrape(first, second, settings: disabled, fields: [.genre])
        XCTAssertEqual(fallback?.genres, ["Folk"])
    }

    func testReviewCollectsLaterSourcesAndRebasesOnlyExplicitFieldChoices() async throws {
        var first = detail(.itunes)
        first.genres = ["Harbor folk"]
        first.year = 2016
        var second = detail(.musicBrainz)
        second.genres = ["Chamber folk"]
        second.year = 2018
        let fixtures = [first.source.rawValue: first, second.source.rawValue: second]
        let manager = ScraperManager(scraperFactory: { FieldDetailFixture(detail: fixtures[$0.type.rawValue]!) })
        var settings = ScraperSettings(sources: [apple, brainz], onlyFillMissingFields: false)
        settings.fieldRules[.genre].preferredSource = brainz.type.rawValue
        settings.fieldRules[.year].mode = .fillMissing
        settings.fieldRules[.track].mode = .skip
        let song = Song(id: "review-song", title: "Copper Sky", albumTitle: "Paper Roads", artistName: "North Quay",
                        duration: 180, fileFormat: .flac, filePath: "song.flac", sourceID: "test", year: 2001)
        let review = await manager.review(for: song, query: "Copper Sky North Quay", settings: settings, parts: .metadata)
        let allowed = settings.reviewFields(for: song, parts: .metadata)
        var draft = ScrapeReviewDraft(song: song, catalog: review, request: allowed, defaults: settings.request(for: song, parts: .metadata))
        XCTAssertEqual(draft.choices(for: .genre).map(\.id), ["Chamber folk", "Harbor folk"])
        XCTAssertEqual(draft.selected[.genre], "Chamber folk")
        XCTAssertNil(draft.selected[.year])
        XCTAssertFalse(draft.fields.contains(.track))
        XCTAssertFalse(draft.isEdited)
        draft.select("2018", for: .year)
        draft.select("unavailable", for: .genre)
        var latest = song
        latest.title = "Edited during review"
        XCTAssertEqual(draft.proposedTags(on: latest).title, latest.title)
        XCTAssertEqual(draft.proposedTags(on: latest).genre, "Chamber folk")
        XCTAssertEqual(draft.proposedTags(on: latest).year, 2018)
        XCTAssertTrue(draft.isEdited)
        draft.select(nil, for: .year)
        XCTAssertFalse(draft.isEdited)
        XCTAssertEqual(draft.proposedTags(on: latest).year, 2001)
    }

    func testReviewKeepsDistinctCoverChoicesAndDownloadsOnlyTheRecommendation() async throws {
        var first = detail(.itunes)
        var second = detail(.musicBrainz)
        let fullCover = "https://art.example/front.png"
        first.coverUrl = "https://art.example/thumbnail.png"
        second.coverUrl = "https://art.example/alternate.png"
        let fixtures = [first.source.rawValue: first, second.source.rawValue: second]
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNYu+MRAARdAkiYxAhaAAAAAElFTkSuQmCC"))
        let requests = ReviewCoverRequests()
        let manager = ScraperManager(scraperFactory: { config in
            FieldDetailFixture(detail: fixtures[config.type.rawValue]!, coverURLs: config.type == .itunes ? [fullCover] : [])
        }, imageDownloader: { url, _ in await requests.record(url); return png })
        let result = await manager.scrapeMetadata(title: first.title, artist: first.artist, album: first.album, duration: 180,
            needs: .init(metadata: true, cover: true, lyrics: false, metadataFields: [.album]),
            settings: ScraperSettings(sources: [apple, brainz]), collectingReview: true)
        let requested = await requests.urls
        XCTAssertEqual(requested, [fullCover])
        XCTAssertEqual(result.review.recommended[.cover], fullCover)
        let choices = try XCTUnwrap(result.review.options[.cover])
        XCTAssertEqual(choices.map(\.id), [fullCover, second.coverUrl!])
        guard case .cover(let secondCover) = choices[1].value else { return XCTFail("Missing second artwork") }
        XCTAssertNil(secondCover.data)
        XCTAssertEqual(secondCover.config?.id, brainz.id)
    }

    func testDifferentReleaseCannotSupplyTrackAndWrongArtistCannotSupplyGenre() async throws {
        let first = detail(.itunes)
        var otherRelease = detail(.musicBrainz, album: "City Compilation")
        otherRelease.trackNumber = 13
        let settings = ScraperSettings(sources: [apple, brainz])
        let result = await scrape(first, otherRelease, settings: settings, fields: [.track])
        XCTAssertNil(result?.trackNumber)
        var compilation = detail(.itunes, album: "City Compilation")
        compilation.trackNumber = 12
        compilation.coverUrl = "https://art.example/compilation.jpg"
        let compilations = await scrape(compilation, otherRelease, settings: settings, fields: [.track, .album])
        XCTAssertNil(compilations?.trackNumber)
        XCTAssertNil(compilations?.album)
        XCTAssertNil(compilations?.coverUrl)
        var otherArtist = detail(.musicBrainz)
        otherArtist.artist = "Harbor Quartet"
        otherArtist.genres = ["Jazz"]
        let differentSong = await scrape(first, otherArtist, settings: settings, fields: [.genre])
        XCTAssertNil(differentSong?.genres)
    }

    func testLegacySettingsAndExplicitFillSurviveRefreshAndRoundTrip() throws {
        var settings = ScraperSettings(sources: [apple, brainz], onlyFillMissingFields: false)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "fieldRules")
        settings = try JSONDecoder().decode(ScraperSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(settings.onlyFillMissingFields)
        settings.fieldRules[.title].mode = .skip
        settings.fieldRules[.genre].mode = .fillMissing
        settings.fieldRules[.year] = .init(mode: .overwrite, preferredSource: brainz.type.rawValue)
        let loaded = try JSONDecoder().decode(ScraperSettings.self, from: JSONEncoder().encode(settings))
        let song = Song(id: "a", title: "Copper Sky", fileFormat: .flac, filePath: "Copper Sky.flac",
                        sourceID: "local", genre: "Folk", year: 2020)
        let request = loaded.request(for: song, force: true)
        XCTAssertFalse(request.fields.contains(.title))
        XCTAssertFalse(request.fields.contains(.genre))
        XCTAssertTrue(request.overwrites.contains(.year))
        XCTAssertEqual(loaded.orderedSources(for: .year).map(\.id), ["brainz", "apple"])
        XCTAssertFalse(loaded.request(for: song, force: true, fillOnly: true).fields.contains(.year))
    }
}

private actor ReviewCoverRequests {
    var urls: [String] = []
    func record(_ url: String) { urls.append(url) }
}

private struct FieldDetailFixture: MusicScraper {
    let detail: ScraperDetail
    var coverURLs: [String] = []
    var type: MusicScraperType { detail.source }
    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        .init(items: [.init(externalId: detail.externalId, source: type, title: detail.title, artist: detail.artist,
                           album: detail.album, durationMs: detail.durationMs)], source: type)
    }
    func getDetail(externalId: String) async throws -> ScraperDetail? { detail }
    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        coverURLs.map { ScraperCoverResult(source: type, coverUrl: $0) }
    }
    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }
}
