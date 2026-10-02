import Foundation
import Testing
@testable import PrimuseKit

@Suite("LAN settings transfer")
struct LANSettingsTransferTests {
    typealias Policy = LANSettingsTransferPolicy
    private let key = Data(repeating: 7, count: 32)

    private func value(_ raw: Any) throws -> Data {
        try #require(LANSettingsBundle.encodeValue(raw))
    }

    @Test("Only allowlisted setting keys survive; per-device and sync-control keys are dropped")
    func valueAllowlist() throws {
        let blob = Data("{}".utf8)
        var bundle = LANSettingsBundle()
        bundle.values = [
            Policy.scraperSettingsKey: try value(blob),
            Policy.aiSettingsKey: try value(blob),
            ArtistNameConfiguration.storageKey: try value(blob),
            AIRecommendationIntentSelectionPolicy.storageKey: try value("preset:balanced"),
            Policy.playerEffectKey: try value("aurora"),
            "tvAutoSync": try value(false),
            "primuse.iCloudSyncEnabled": try value(false),
            "primuse_ssl_trusted_fingerprints": try value(blob),
            "primuse_playback_settings_v1": try value(blob),
            "lyricsFontScale": try value(1.4),
        ]
        let sanitized = Policy.sanitized(bundle)
        #expect(Set(sanitized.values.keys) == [
            Policy.scraperSettingsKey,
            Policy.aiSettingsKey,
            ArtistNameConfiguration.storageKey,
            AIRecommendationIntentSelectionPolicy.storageKey,
            Policy.playerEffectKey,
        ])
        #expect(Policy.allowedValueKeys.contains(Policy.lyricsAPIServersKey))
        #expect(Policy.allowedValueKeys.contains(Policy.lyricsTranscriptionKey))
        #expect(Policy.allowedValueKeys.contains(AIRecommendationIntentStoragePolicy.storageKey))
        #expect(Policy.allowedValueKeys.contains(AIRecommendationIntentPresetVisibilityPolicy.storageKey))
        #expect(!Policy.allowedValueKeys.contains("tvAutoSync"))
    }

    @Test("Secrets are limited to scraper cookies, lyrics server authorization and AI API keys")
    func secretAllowlist() {
        #expect(Policy.category(forSecretAccount: "scraper.cookie.config.netease") == .scraping)
        #expect(Policy.category(forSecretAccount: "lyrics.apiServer.1234.authorization") == .lyricsServers)
        #expect(Policy.category(forSecretAccount: "ai.provider.abc.endpoint.https://x|responses|bearer.apiKey") == .intelligence)
        #expect(Policy.category(forSecretAccount: "scraper.cookie.config.") == nil)
        #expect(Policy.category(forSecretAccount: "scraper.cookie.source.row-id") == nil)
        #expect(Policy.category(forSecretAccount: "lyrics.apiServer.1234") == nil)
        #expect(Policy.category(forSecretAccount: "ai.provider..apiKey") == nil)
        #expect(Policy.category(forSecretAccount: "source-uuid") == nil)
        #expect(Policy.category(forSecretAccount: "relay.install.credential") == nil)
        #expect(Policy.category(forSecretAccount: "") == nil)

        let bundle = LANSettingsBundle(secrets: [
            "scraper.cookie.config.netease": "MUSIC_U=1",
            "lyrics.apiServer.1.authorization": "",
            "source-uuid": "hunter2",
            "ai.provider.p.endpoint.x.apiKey": String(repeating: "k", count: Policy.maximumSecretBytes + 1),
        ])
        #expect(Policy.sanitized(bundle).secrets == ["scraper.cookie.config.netease": "MUSIC_U=1"])
    }

    @Test("Scraper configs need a file-safe id, stay unique and within the size caps")
    func scraperConfigFiltering() {
        let json = Data(#"{"id":"a"}"#.utf8)
        let bundle = LANSettingsBundle(scraperConfigs: [
            LANScraperConfigEntry(id: "netease.v2", json: json, secrets: ["key": "value"]),
            LANScraperConfigEntry(id: "netease.v2", json: json),
            LANScraperConfigEntry(id: "../escape", json: json),
            LANScraperConfigEntry(id: "x.secrets.y", json: json),
            LANScraperConfigEntry(id: "empty", json: Data()),
            LANScraperConfigEntry(id: "huge", json: Data(count: Policy.maximumScraperConfigBytes + 1)),
            LANScraperConfigEntry(id: "no-secrets", json: json, secrets: [:]),
        ])
        let sanitized = Policy.sanitized(bundle)
        #expect(sanitized.scraperConfigs.map(\.id) == ["netease.v2", "no-secrets"])
        #expect(sanitized.scraperConfigs[0].secrets == ["key": "value"])
        #expect(sanitized.scraperConfigs[1].secrets == nil)
        #expect(Policy.isSafeScraperConfigID("qq_music-1.0"))
        #expect(!Policy.isSafeScraperConfigID(".hidden"))
        #expect(!Policy.isSafeScraperConfigID(String(repeating: "a", count: 65)))
    }

    @Test("Backdrop pictures travel only with the backdrop setting, with valid ids and within the caps")
    func backdropImages() throws {
        let image = Data(repeating: 1, count: 1_000)
        func id(_ n: Int) -> String { String(format: "%064x", n) }
        var bundle = LANSettingsBundle(backdropImages: [LANBackdropImageEntry(id: id(1), data: image)])
        #expect(Policy.sanitized(bundle).backdropImages.isEmpty)

        bundle.values[Policy.playerBackdropKey] = try value(Data("{}".utf8))
        bundle.backdropImages = [
            LANBackdropImageEntry(id: id(1), data: image),
            LANBackdropImageEntry(id: id(1), data: image),
            LANBackdropImageEntry(id: "not-a-hash", data: image),
            LANBackdropImageEntry(id: id(2), data: Data()),
            LANBackdropImageEntry(id: id(3), data: Data(count: Policy.maximumValueBytes + 1)),
        ] + (10..<30).map { LANBackdropImageEntry(id: id($0), data: image) }
        let sanitized = Policy.sanitized(bundle)
        #expect(sanitized.backdropImages.count == Policy.maximumBackdropImages)
        #expect(sanitized.backdropImages.first?.id == id(1))
        #expect(!sanitized.backdropImages.contains { $0.id == id(3) })
        #expect(Policy.categories(in: sanitized) == [.playerBackdrop])
        #expect(Policy.playerBackdropKey == PlayerBackdropSettings.storageKey)

        let large = Data(count: Policy.maximumValueBytes)
        bundle.backdropImages = (40..<50).map { LANBackdropImageEntry(id: id($0), data: large) }
        let total = Policy.sanitized(bundle).backdropImages.reduce(0) { $0 + $1.data.count }
        #expect(total <= Policy.maximumTotalBackdropImageBytes)

        let payload = LANSyncPayload(sourcesGz: Data([1]), credentials: CredentialBundle(), settings: sanitized)
        #expect(try #require(LANSyncPayload.decode(try payload.jsonData())).settings == sanitized)
        let withoutImages = try LANSyncPayload(
            sourcesGz: Data([1]), credentials: CredentialBundle(), settings: LANSettingsBundle(values: [:])
        ).jsonData()
        #expect(!String(decoding: withoutImages, as: UTF8.self).contains("backdropImages"))
    }

    @Test("Scraper settings are applied first so custom rows find their configs")
    func applicationOrder() {
        let order = Policy.applicationOrder(of: [
            Policy.playerEffectKey, Policy.aiSettingsKey, Policy.scraperSettingsKey, Policy.lyricsAPIServersKey,
        ])
        #expect(order.first == Policy.scraperSettingsKey)
        #expect(Array(order.dropFirst()) == [Policy.aiSettingsKey, Policy.lyricsAPIServersKey, Policy.playerEffectKey].sorted())
    }

    @Test("Categories summarize values, configs and secrets in a stable order")
    func categories() throws {
        let bundle = LANSettingsBundle(
            values: [Policy.playerEffectKey: try value("aurora"), Policy.lyricsTranscriptionKey: try value(Data([1]))],
            scraperConfigs: [LANScraperConfigEntry(id: "a", json: Data([1]))],
            secrets: ["lyrics.apiServer.1.authorization": "Bearer x"]
        )
        #expect(Policy.categories(in: bundle) == [.scraping, .lyricsServers, .intelligence, .playerEffect])
        #expect(Policy.categories(in: LANSettingsBundle()).isEmpty)
        #expect(LANSettingsBundle().isEmpty)
    }

    @Test("UserDefaults values round-trip through the property-list encoding")
    func valueRoundTrip() throws {
        let data = Data([0, 1, 2, 255])
        #expect(LANSettingsBundle.decodeValue(try value(data)) as? Data == data)
        #expect(LANSettingsBundle.decodeValue(try value("aurora")) as? String == "aurora")
        #expect(LANSettingsBundle.decodeValue(try value(true)) as? Bool == true)
        #expect(LANSettingsBundle.decodeValue(try value(1.25)) as? Double == 1.25)
        #expect(LANSettingsBundle.decodeValue(try value(["a", "b"])) as? [String] == ["a", "b"])
        #expect(LANSettingsBundle.decodeValue(Data("not a plist".utf8)) == nil)
    }

    @Test("The bundle round-trips through JSON inside the pairing payload")
    func bundleRoundTrip() throws {
        let bundle = LANSettingsBundle(
            values: [Policy.aiSettingsKey: try value(Data("{\"schemaVersion\":5}".utf8))],
            scraperConfigs: [LANScraperConfigEntry(id: "cfg", json: Data("{}".utf8), secrets: ["k": "v"])],
            secrets: ["scraper.cookie.config.cfg": "c=1"]
        )
        let payload = LANSyncPayload(sourcesGz: Data([1]), credentials: CredentialBundle(), settings: bundle)
        let decoded = try #require(LANSyncPayload.decode(try payload.jsonData()))
        #expect(decoded.settings == bundle)
        #expect(decoded.isCompleteSourcesStage)
    }

    @Test("Older payloads without settings still decode, and newer fields are ignored")
    func forwardAndBackwardCompatibility() throws {
        let legacy = LANSyncPayload(sourcesGz: Data([1]), credentials: CredentialBundle())
        let legacyJSON = try legacy.jsonData()
        #expect(!String(decoding: legacyJSON, as: UTF8.self).contains("settings"))
        #expect(try #require(LANSyncPayload.decode(legacyJSON)).settings == nil)

        let future = Data("""
        {"version":7,"values":{},"secrets":{"scraper.cookie.config.a":"x"},"futureField":[1,2,3]}
        """.utf8)
        let decoded = try JSONDecoder().decode(LANSettingsBundle.self, from: future)
        #expect(decoded.version == 7)
        #expect(decoded.secrets == ["scraper.cookie.config.a": "x"])
        #expect(decoded.scraperConfigs.isEmpty)
    }

    @Test("A malformed settings section never makes the sources stage undecodable")
    func malformedSettingsAreIgnored() throws {
        let base = try LANSyncPayload(sourcesGz: Data([1]), credentials: CredentialBundle()).jsonData()
        var object = try #require(try JSONSerialization.jsonObject(with: base) as? [String: Any])
        object["settings"] = ["values": "not a dictionary", "secrets": 42, "scraperConfigs": [["id": 1]]]
        let payload = try #require(LANSyncPayload.decode(try JSONSerialization.data(withJSONObject: object)))
        #expect(payload.isCompleteSourcesStage)
        #expect(payload.settings?.isEmpty == true)

        object["settings"] = "garbage"
        let other = try #require(LANSyncPayload.decode(try JSONSerialization.data(withJSONObject: object)))
        #expect(other.isCompleteSourcesStage)
        #expect(other.settings?.isEmpty == true)
    }

    @Test("Apple TV QR codes at version 3 accept settings; version 2 only staged transfers")
    func pairingCapability() throws {
        let current = LANPairLink(host: "192.168.1.5", port: 5000, key: key, pairCode: "123456",
                                  protocolVersion: LANPairLink.currentProtocolVersion)
        let url = try #require(URL(string: current.qrContent))
        let parsed = try #require(LANPairLink(url: url))
        #expect(parsed.protocolVersion == 3)
        #expect(parsed.supportsStagedTransfer)
        #expect(parsed.supportsSettingsTransfer)
        #expect(current.qrContent.contains("v=3"))

        let staged = LANPairLink(host: "192.168.1.5", port: 5000, key: key, pairCode: "123456",
                                 protocolVersion: LANPairLink.stagedProtocolVersion)
        #expect(staged.supportsStagedTransfer)
        #expect(!staged.supportsSettingsTransfer)
        #expect(!LANPairLink(host: "h", port: 1, key: key).supportsSettingsTransfer)
    }

    @Test("A transferred value is never pushed to this device's iCloud until it is edited here")
    func transferredRevisionIsNotPushed() {
        typealias KVS = CloudKVSReconciliationPolicy
        let transferred = KVS.Version(revision: 5_000, writer: "tv")
        let staleCloud = KVS.Version(revision: 1_000, writer: "other-phone")
        #expect(KVS.catchUpAction(local: transferred, hasLocalValue: true, remote: staleCloud,
                                  transferredRevision: 5_000) == .keep)
        #expect(KVS.catchUpAction(local: transferred, hasLocalValue: true, remote: .unset,
                                  transferredRevision: 5_000) == .keep)
        // 云端之后真的改了, 照常拉下来。
        let laterCloud = KVS.Version(revision: 6_000, writer: "other-phone")
        #expect(KVS.catchUpAction(local: transferred, hasLocalValue: true, remote: laterCloud,
                                  transferredRevision: 5_000) == .pull)
        // 这台设备上又改了一次(修订号变了), 就是普通编辑。
        let edited = KVS.Version(revision: 7_000, writer: "tv")
        #expect(KVS.catchUpAction(local: edited, hasLocalValue: true, remote: staleCloud,
                                  transferredRevision: 5_000) == .pushValue)
        #expect(KVS.catchUpAction(local: transferred, hasLocalValue: true, remote: staleCloud,
                                  transferredRevision: nil) == .pushValue)
    }
}
