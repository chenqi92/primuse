import XCTest
@testable import Primuse

final class SettingsDiscoveryTests: XCTestCase {
    func testCatalogHasUniqueStableIDsAndPlatformAppropriateDestinations() {
        let all = SettingsCatalog.definitions
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(SettingsCatalog.available.allSatisfy { $0.page?.available == true })
        #if os(iOS)
        XCTAssertNil(SettingsCatalog.byID["keyboard.playPause"])
        XCTAssertEqual(SettingsCatalog.byID["lyrics.lockScreen"]?.page, .playback)
        XCTAssertEqual(SettingsCatalog.byID["lyrics.colorMode"]?.page, .player)
        XCTAssertEqual(SettingsCatalog.byID["storage.wifiOnly"]?.page, .storage)
        XCTAssertEqual(SettingsCatalog.byID["library.recommendationDirections"]?.page, .libraryDisplay)
        #endif
    }

    func testSearchIncludesFunctionalAliasesAndHidesUnavailableIntelligence() {
        XCTAssertEqual(SettingsCatalog.search("锁屏没歌词").first?.id, "lyrics.lockScreen")
        XCTAssertEqual(SettingsCatalog.search("省流量").first?.id, "storage.wifiOnly")
        XCTAssertFalse(SettingsCatalog.search("AI", showsIntelligence: false).contains { $0.page == .intelligence })
        XCTAssertFalse(SettingsCatalog.available.contains { $0.title.contains("%d") || $0.title.contains("%@") })
    }

    func testSiriQueriesKeepDestructiveAndCredentialActionsOutOfWritableChoices() async throws {
        let writable = try await PrimuseToggleSettingQuery().suggestedEntities()
        XCTAssertTrue(writable.contains { $0.id == "lyrics.lockScreen" })
        for forbidden in ["storage.clearAudioCache", "deleted.empty", "intelligence.apiKey", "unknown"] {
            let resolved = try await PrimuseToggleSettingQuery().entities(for: [forbidden])
            XCTAssertTrue(resolved.isEmpty, forbidden)
        }
        let opened = try await PrimuseSettingQuery().entities(matching: "锁屏没歌词")
        XCTAssertEqual(opened.first?.id, "lyrics.lockScreen")
    }

    @MainActor
    func testHighFidelityCannotBeBypassedAndReportsEffectiveValues() throws {
        try withService { service, playback, _ in
            playback.outputMode = .highFidelity
            playback.playbackRate = 1.75
            playback.matchOutputSampleRate = false
            XCTAssertThrowsError(try service.setEnabled(true, for: "playback.crossfade"))
            XCTAssertThrowsError(try service.setEnabled(false, for: "playback.matchSampleRate"))
            XCTAssertFalse(playback.crossfadeEnabled)
            XCTAssertFalse(playback.matchOutputSampleRate)
            XCTAssertEqual(playback.playbackRate, 1.75)
            XCTAssertEqual(service.effectivePlaybackRate, 1)
            XCTAssertEqual(service.booleanValue(for: "playback.matchSampleRate"), true)
            XCTAssertNotNil(service.unavailableReason(for: "page.equalizer"))
            try service.setEnabled(false, for: "lyrics.lockScreen")
            XCTAssertFalse(playback.lockScreenLyricsEnabled)
        }
    }

    @MainActor
    func testExplicitChangesPreserveMutualExclusionAndAreIdempotent() throws {
        try withService { service, playback, defaults in
            playback.outputMode = .effects
            playback.gaplessEnabled = true
            let result = try service.setEnabled(true, for: "playback.crossfade")
            XCTAssertTrue(playback.crossfadeEnabled)
            XCTAssertFalse(playback.gaplessEnabled)
            XCTAssertNotNil(result.reason)
            try service.setEnabled(true, for: "playback.crossfade")
            XCTAssertTrue(playback.crossfadeEnabled)
            try service.setEnabled(true, for: "playback.gapless")
            XCTAssertFalse(playback.crossfadeEnabled)
            XCTAssertTrue(PlaybackSettings.load(defaults: defaults).gaplessEnabled)
        }
    }

    @MainActor
    func testCacheActionsUseExistingStoreCallbacksAndRejectUnknownActions() throws {
        try withService { service, playback, _ in
            var changes: [Bool] = []
            playback.audioCacheEnabledDidChange = { changes.append($0) }
            try service.setEnabled(false, for: "storage.audioCacheEnabled")
            try service.setEnabled(false, for: "storage.audioCacheEnabled")
            XCTAssertEqual(changes, [false])
            XCTAssertThrowsError(try service.setEnabled(true, for: "storage.clearAudioCache"))
            XCTAssertThrowsError(try service.setEnabled(true, for: "unknown"))
            XCTAssertFalse(playback.audioCacheEnabled)
        }
    }

    @MainActor
    func testAudioEffectActionsUpdateLiveServiceAndPersist() throws {
        try withService { _, playback, defaults in
            playback.outputMode = .effects
            let effects = AudioEffectsService(audioEngine: AudioEngine(), settingsStore: playback)
            let service = SettingsActionService(playback: playback, defaults: defaults, effects: effects)
            try service.setEnabled(true, for: "effects.reverb")
            try service.setEnabled(true, for: "effects.compressor")
            XCTAssertTrue(effects.reverbEnabled)
            XCTAssertTrue(effects.compressorEnabled)
            let saved = PlaybackSettings.load(defaults: defaults)
            XCTAssertTrue(saved.reverbEnabled)
            XCTAssertTrue(saved.compressorEnabled)
            playback.outputMode = .highFidelity
            XCTAssertThrowsError(try service.setEnabled(false, for: "effects.reverb"))
            XCTAssertTrue(effects.reverbEnabled)
        }
    }

    @MainActor
    func testParentOptionMustBeEnabledBeforeDependentChange() throws {
        try withService { service, playback, _ in
            playback.outputMode = .effects
            playback.spatialAudioEnabled = false
            XCTAssertThrowsError(try service.setEnabled(true, for: "playback.headTracking"))
            XCTAssertFalse(playback.spatialAudioEnabled)
            try service.setEnabled(true, for: "playback.spatialAudio")
            try service.setEnabled(true, for: "playback.headTracking")
            XCTAssertTrue(playback.spatialHeadTrackingEnabled)
        }
    }

    @MainActor
    func testNavigationAcceptsKnownSettingsAndRepeatedRequestsHaveNewTokens() {
        #if os(iOS)
        let navigation = SettingsNavigation()
        navigation.open("lyrics.lockScreen")
        let first = navigation.request
        XCTAssertEqual(first?.settingID, "lyrics.lockScreen")
        navigation.open("missing")
        XCTAssertEqual(navigation.request, first)
        navigation.open("lyrics.lockScreen")
        XCTAssertNotEqual(navigation.request?.token, first?.token)
        #endif
    }

    @MainActor
    private func withService(_ body: (SettingsActionService, PlaybackSettingsStore, UserDefaults) throws -> Void) throws {
        let name = "SettingsDiscoveryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PlaybackSettingsStore(defaults: defaults)
        try body(SettingsActionService(playback: store, defaults: defaults), store, defaults)
    }
}
