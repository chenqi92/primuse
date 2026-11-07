import Foundation
import XCTest
import PrimuseKit
@testable import Primuse

@MainActor
final class OfflineSettingsBackupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var shared: UserDefaults!
    private var names: [String] = []

    override func setUp() {
        super.setUp()
        names = (0..<2).map { _ in "OfflineSettingsBackupTests-\(UUID().uuidString)" }
        defaults = UserDefaults(suiteName: names[0])!
        shared = UserDefaults(suiteName: names[1])!
    }
    override func tearDown() {
        for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults = nil
        shared = nil
        super.tearDown()
    }

    func testSharingJSONAndCodeStageTheSamePackageBeforeConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var package = ListeningSharePackage(title: "Night Signal")
        package.stations = [.init(RadioStation(name: "Night Signal", streamURL: "https://radio.example.org/live.aac"))]
        package.settings["eq.enabled"] = try ListeningShareSettingsPolicy.encode(true)
        let json = directory.appendingPathComponent("Radio.json")
        try ListeningShareJSON.encode(package).write(to: json)
        let coordinator = ListeningShareCoordinator()
        let file = try await coordinator.stage(json)
        defer { coordinator.discard(file) }
        let code = try await coordinator.stage(code: ListeningShareCode.encode(package))
        defer { coordinator.discard(code) }
        XCTAssertEqual(file.contents.package, package)
        XCTAssertEqual(code.contents.package, package)
        XCTAssertNil(coordinator.incoming)
    }

    func testSnapshotRoundTripRestoresSettingsAndResetsAbsentPreferencesOnly() throws {
        let navigation = "primuse.navigation.hiddenTabs.v1"
        defaults.set("[\"library\",\"settings\",\"search\"]", forKey: navigation)
        defaults.set(1.4, forKey: "primuse.player.artworkLyricsFontScale")
        defaults.set("private-account", forKey: "musicSources")
        defaults.set("private-key", forKey: "ai.apiKey")
        defaults.set(42, forKey: navigation + "__updatedAt")
        shared.set(false, forKey: PrimuseConstants.widgetSyncEnabledKey)
        let backup = try OfflineSettingsBackup.decode(OfflineSettingsBackupService.snapshot(defaults: defaults, sharedDefaults: shared).encoded())
        XCTAssertNil(backup.standard.values["musicSources"])
        XCTAssertNil(backup.standard.values["ai.apiKey"])
        XCTAssertNil(backup.standard.values[navigation + "__updatedAt"])
        defaults.set("[]", forKey: navigation)
        defaults.set(true, forKey: "library.hideSingleSongAlbums")
        defaults.set("keep", forKey: "unrelated.newer.setting")
        shared.set(true, forKey: PrimuseConstants.widgetSyncEnabledKey)
        shared.set("keep-widget-data", forKey: "widget.runtimeData")
        let cloud = CloudKVSSync(store: nil, defaults: defaults, observing: nil)
        try OfflineSettingsBackupService.restorePreferences(backup, defaults: defaults, cloud: cloud, sharedDefaults: shared)
        XCTAssertEqual(defaults.string(forKey: navigation), "[\"library\",\"settings\",\"search\"]")
        XCTAssertEqual(defaults.double(forKey: "primuse.player.artworkLyricsFontScale"), 1.4)
        XCTAssertNil(defaults.object(forKey: "library.hideSingleSongAlbums"))
        XCTAssertEqual(defaults.string(forKey: "musicSources"), "private-account")
        XCTAssertEqual(defaults.string(forKey: "unrelated.newer.setting"), "keep")
        XCTAssertFalse(shared.bool(forKey: PrimuseConstants.widgetSyncEnabledKey))
        XCTAssertEqual(shared.string(forKey: "widget.runtimeData"), "keep-widget-data")
    }

    func testForgedCredentialScopeFailsBeforeWritingAnyPreference() throws {
        defaults.set("before", forKey: "primuse.appearance")
        let backup = OfflineSettingsBackup(appVersion: "1", platform: "iOS",
            standard: .init(keys: ["primuse.appearance", "ai.apiKey"], values: [
                "primuse.appearance": LANSettingsBundle.encodeValue("dark")!,
                "ai.apiKey": LANSettingsBundle.encodeValue("injected")!
            ]), shared: .init(keys: [], values: [:]))
        XCTAssertThrowsError(try OfflineSettingsBackupService.restorePreferences(
            backup, defaults: defaults, cloud: CloudKVSSync(store: nil, defaults: defaults, observing: nil), sharedDefaults: shared))
        XCTAssertEqual(defaults.string(forKey: "primuse.appearance"), "before")
        XCTAssertNil(defaults.object(forKey: "ai.apiKey"))
    }

    func testLegacyCredentialFieldsAreStrippedFromBothDirections() throws {
        let blob = try JSONSerialization.data(withJSONObject: [
            "servers": [["id": "test", "name": "Example", "address": "https://user:pass@example.com?token=private", "authorization": "Bearer private"]]
        ])
        defaults.set(blob, forKey: LyricsAPIServerSettings.defaultsKey)
        let backup = try OfflineSettingsBackupService.snapshot(defaults: defaults, sharedDefaults: nil)
        let sanitized = try XCTUnwrap(backup.standard.values[LyricsAPIServerSettings.defaultsKey].flatMap(LANSettingsBundle.decodeValue) as? Data)
        XCTAssertFalse(String(decoding: sanitized, as: UTF8.self).contains("private"))
        defaults.removeObject(forKey: LyricsAPIServerSettings.defaultsKey)
        var incoming = backup
        incoming.standard.values[LyricsAPIServerSettings.defaultsKey] = LANSettingsBundle.encodeValue(blob)
        try OfflineSettingsBackupService.restorePreferences(incoming, defaults: defaults, cloud: CloudKVSSync(store: nil, defaults: defaults, observing: nil), sharedDefaults: nil)
        let loaded = LyricsAPIServerSettings.load(defaults: defaults)
        XCTAssertNil(loaded.servers.first?.authorization)
        XCTAssertEqual(loaded.servers.first?.address, "https://example.com")
    }

    func testMalformedSettingsBlobLeavesCurrentValuesUntouched() throws {
        defaults.set("light", forKey: "primuse.appearance")
        let backup = OfflineSettingsBackup(appVersion: "1", platform: "iOS",
            standard: .init(keys: ["primuse.appearance", PlaybackSettings.defaultsKey], values: [
                "primuse.appearance": LANSettingsBundle.encodeValue("dark")!,
                PlaybackSettings.defaultsKey: LANSettingsBundle.encodeValue(Data("[]".utf8))!
            ]), shared: .init(keys: [], values: [:]))
        XCTAssertThrowsError(try OfflineSettingsBackupService.restorePreferences(
            backup, defaults: defaults, cloud: CloudKVSSync(store: nil, defaults: defaults, observing: nil), sharedDefaults: nil))
        XCTAssertEqual(defaults.string(forKey: "primuse.appearance"), "light")
    }

    func testOfflinePlaybackImportRestoresDeviceLocalOptionsImmediately() throws {
        let cloud = CloudKVSSync(store: nil, defaults: defaults, observing: nil)
        let playback = PlaybackSettingsStore(defaults: defaults, cloudSync: cloud)
        var settings = PlaybackSettings()
        settings.outputMode = .highFidelity
        settings.audioCacheEnabled = false
        settings.cellularStreamQuality = .kbps128
        settings.crossfadeEnabled = true
        cloud.applyOfflineSnapshot(values: [PlaybackSettings.defaultsKey: try JSONEncoder().encode(settings)], restoringKeys: [PlaybackSettings.defaultsKey])
        XCTAssertEqual(playback.outputMode, .highFidelity)
        XCTAssertFalse(playback.audioCacheEnabled)
        XCTAssertEqual(playback.cellularStreamQuality, .kbps128)
        XCTAssertTrue(playback.crossfadeEnabled)
    }

    func testBackupWithoutRequiredBackgroundIsRejected() throws {
        let key = PlayerBackdropSettings.customImagesStorageKey
        let backup = OfflineSettingsBackup(appVersion: "1", platform: "iOS",
            standard: .init(keys: [key], values: [key: LANSettingsBundle.encodeValue([String(repeating: "a", count: 64)])!]),
            shared: .init(keys: [], values: [:]))
        XCTAssertThrowsError(try OfflineSettingsBackupService.validate(backup))
    }
}
