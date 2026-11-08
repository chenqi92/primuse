import XCTest
import PrimuseKit
@testable import Primuse

@MainActor
final class LyricsSettingsLoadingTests: XCTestCase {
    func testFontPreviewChecksRunOffMainThreadAndReuseResults() async {
        let library = PlayerTextFontLibrary(loadsImportedFonts: false)
        let started = expectation(description: "Font lookup started")
        let release = DispatchSemaphore(value: 0)
        let calls = LyricsSettingsProbeCalls()
        defer { release.signal() }
        let probe: @Sendable (String) -> Bool = { name in
            if calls.record(name) == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return name == "PingFangSC-Regular"
        }
        let first = Task { await library.preparePreviews(probe: probe) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await library.preparePreviews(probe: probe) }
        await Task.yield()
        XCTAssertEqual(calls.count, 1, "The UI executor remains available while the lookup is blocked")
        XCTAssertFalse(calls.usedMainThread)
        release.signal()
        await first.value
        await second.value
        let expected = PlayerTextFont.Builtin.allCases.compactMap(\.postScriptName).count
        XCTAssertEqual(calls.count, expected)
        await library.preparePreviews(probe: probe)
        XCTAssertEqual(library.state(of: .builtin(.pingFang)), .available)
        XCTAssertEqual(library.state(of: .builtin(.songti)), .needsDownload)
        XCTAssertEqual(calls.count, expected, "Re-entering the page must reuse availability results")
    }

    func testModelAvailabilityRefreshDoesNotBlockUIAndCoalescesCallers() async {
        let started = expectation(description: "Model lookup started")
        let release = DispatchSemaphore(value: 0)
        let calls = LyricsSettingsProbeCalls()
        defer { release.signal() }
        let service = LocalLyricsTranslationService(isSupported: true, refreshOnInit: false) { pack in
            if calls.record(pack.rawValue) == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return nil
        }
        let first = Task { await service.refreshAvailability() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await service.refreshAvailability() }
        await Task.yield()
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls.usedMainThread)
        first.cancel()
        release.signal()
        await first.value
        await second.value
        XCTAssertEqual(calls.count, LocalLyricsTranslationModel.Pack.allCases.count)
        XCTAssertEqual(service.modelState(for: .persian), .notDownloaded)
        XCTAssertEqual(service.modelState(for: .cjk), .notDownloaded)
        XCTAssertEqual(service.modelRevision, 0)
    }

    func testUnsupportedSystemsDoNotQueryAssetPacks() async {
        let calls = LyricsSettingsProbeCalls()
        let service = LocalLyricsTranslationService(isSupported: false, refreshOnInit: false) { pack in
            calls.record(pack.rawValue)
            return nil
        }
        await service.refreshAvailability()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(service.modelState, .unsupportedSystem)
    }
}

private final class LyricsSettingsProbeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var onMainThread = false

    @discardableResult
    func record(_ name: String) -> Int {
        lock.withLock {
            names.append(name)
            onMainThread = onMainThread || Thread.isMainThread
            return names.count
        }
    }

    var count: Int { lock.withLock { names.count } }
    var usedMainThread: Bool { lock.withLock { onMainThread } }
}

final class SettingsDiscoveryTests: XCTestCase {
    @MainActor
    func testStreamTranscodeFormatPersistsAndIsDiscoverable() throws {
        try withService { _, playback, defaults in
            XCTAssertEqual(playback.streamTranscodeFormat, .mp3)
            for format in StreamTranscodeFormat.allCases {
                playback.streamTranscodeFormat = format
                XCTAssertEqual(PlaybackSettings.load(defaults: defaults).streamTranscodeFormat, format)
                XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).streamTranscodeFormat, format)
            }
        }
        for query in ["Navidrome", "Subsonic", "Emby", "Jellyfin", "Plex", "Opus", "AAC"] {
            XCTAssertTrue(SettingsCatalog.search(query).contains { $0.id == "playback.streamTranscodeFormat" })
        }
    }

    func testStreamTranscodeFormatUpgradeAndUnknownValuePreserveExistingSettings() throws {
        var settings = PlaybackSettings()
        settings.cellularStreamQuality = .kbps192
        let data = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "streamTranscodeFormat")
        for unknownValue in [nil, "future-codec"] as [String?] {
            object["streamTranscodeFormat"] = unknownValue
            let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.streamTranscodeFormat, .mp3)
            XCTAssertEqual(decoded.cellularStreamQuality, .kbps192)
        }
    }

    @MainActor
    func testOfflineFormatPersistsIndependentlyOfStreamingFormat() throws {
        try withService { _, playback, defaults in
            XCTAssertEqual(playback.offlineDownloadFormat, .aac)
            playback.streamTranscodeFormat = .opus
            for format in StreamTranscodeFormat.allCases {
                playback.offlineDownloadFormat = format
                let restored = PlaybackSettingsStore(defaults: defaults)
                XCTAssertEqual(restored.offlineDownloadFormat, format)
                XCTAssertEqual(restored.streamTranscodeFormat, .opus)
            }
        }
        for payload in [#"{}"#, #"{"offlineDownloadFormat":"future-codec"}"#] {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertEqual(settings.offlineDownloadFormat, .aac)
            XCTAssertEqual(settings.offlineDownloadQuality, .original)
        }
        XCTAssertEqual(SettingsCatalog.byID["storage.offlineDownloadFormat"]?.page, .storage)
    }

    func testLegacyNavidromeFormatMigratesToSharedFormat() throws {
        let data = Data(#"{"navidromeTranscodeFormat":"opus","wifiStreamQuality":"kbps128"}"#.utf8)
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(settings.streamTranscodeFormat, .opus)
        XCTAssertEqual(settings.wifiStreamQuality, .kbps128)
        let roundTrip = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.streamTranscodeFormat, .opus)
        let both = Data(#"{"navidromeTranscodeFormat":"opus","streamTranscodeFormat":"aac"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: both).streamTranscodeFormat, .aac)
    }

    @MainActor
    func testSimulatedWordLyricsDefaultsOffAndPersistsBothStates() throws {
        let id = "lyrics.simulatedWordTiming"
        XCTAssertEqual(SettingsCatalog.byID[id]?.page, .lyrics)
        for query in ["模拟逐字", "simulated"] {
            XCTAssertTrue(SettingsCatalog.search(query).contains { $0.id == id }, query)
        }
        try withService { service, playback, defaults in
            XCTAssertFalse(PlayerAppearancePreferences.simulatesWordLyricsByDefault)
            XCTAssertEqual(service.booleanValue(for: id), false)
            try service.setEnabled(true, for: id)
            let restored = SettingsActionService(playback: playback, defaults: defaults)
            XCTAssertEqual(restored.booleanValue(for: id), true)
            XCTAssertTrue(defaults.bool(forKey: PlayerAppearancePreferences.simulatesWordLyricsKey))
            try restored.setEnabled(false, for: id)
            XCTAssertEqual(service.booleanValue(for: id), false)
        }
    }

    @MainActor
    func testMiniPlayerPinningIsDiscoverableAndPersistsBothStates() throws {
        let id = "player.pinMiniPlayer"
        guard PlayerAppearancePreferences.supportsMiniPlayerPinning else {
            XCTAssertNil(SettingsCatalog.byID[id])
            return
        }
        XCTAssertEqual(SettingsCatalog.byID[id]?.page, .player)
        for query in ["胶囊", "小播放器", "mini player"] {
            XCTAssertTrue(SettingsCatalog.search(query).contains { $0.id == id }, query)
        }
        try withService { service, playback, defaults in
            XCTAssertEqual(service.booleanValue(for: id), false)
            try service.setEnabled(true, for: id)
            let restored = SettingsActionService(playback: playback, defaults: defaults)
            XCTAssertEqual(restored.booleanValue(for: id), true)
            XCTAssertTrue(defaults.bool(forKey: PlayerAppearancePreferences.pinsMiniPlayerKey))
            try restored.setEnabled(false, for: id)
            XCTAssertEqual(service.booleanValue(for: id), false)
            XCTAssertFalse(defaults.bool(forKey: PlayerAppearancePreferences.pinsMiniPlayerKey))
        }
    }

    func testCatalogHasUniqueStableIDsAndPlatformAppropriateDestinations() {
        let all = SettingsCatalog.definitions
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(SettingsCatalog.available.allSatisfy { $0.page?.available == true })
        #if os(iOS)
        XCTAssertNil(SettingsCatalog.byID["keyboard.playPause"])
        XCTAssertEqual(SettingsCatalog.byID["lyrics.lockScreen"]?.page, .playback)
        XCTAssertEqual(SettingsCatalog.byID["lyrics.colorMode"]?.page, .lyrics)
        XCTAssertEqual(SettingsCatalog.byID["storage.wifiOnly"]?.page, .storage)
        XCTAssertEqual(SettingsCatalog.byID["library.recommendationDirections"]?.page, .libraryDisplay)
        XCTAssertEqual(SettingsCatalog.byID["appearance.immersiveMotionIntensity"]?.page, .fullscreen)
        #endif
        XCTAssertTrue(SettingsCatalog.search("动效强度").contains { $0.id == "appearance.immersiveMotionIntensity" })
    }

    func testSearchIncludesFunctionalAliasesAndHidesUnavailableIntelligence() {
        XCTAssertEqual(SettingsCatalog.search("锁屏没歌词").first?.id, "lyrics.lockScreen")
        let dataSavingResults = Set(SettingsCatalog.search("省流量").map(\.id))
        XCTAssertTrue(dataSavingResults.contains("storage.wifiOnly"))
        XCTAssertTrue(dataSavingResults.contains("playback.wifiStreamQuality"))
        XCTAssertFalse(SettingsCatalog.search("AI", showsIntelligence: false).contains { $0.page == .intelligence })
        XCTAssertFalse(SettingsCatalog.available.contains { $0.title.contains("%d") || $0.title.contains("%@") })
    }

    func testAboutAndDiagnosticSearchFollowMovedEntries() {
        XCTAssertEqual(SettingsCatalog.byID["about.build"]?.anchorID, "about.version")
        XCTAssertNil(SettingsCatalog.byID["about.contact"])
        #if os(iOS)
        XCTAssertEqual(SettingsCatalog.search("hi@yzs.ai").first?.id, "diagnostics.sendReports")
        XCTAssertEqual(SettingsCatalog.byID["about.repository"]?.page, .licenses)
        XCTAssertEqual(SettingsCatalog.byID["storage.exportLog"]?.page, .diagnostics)
        #endif
    }

    @MainActor
    func testDismissingSettingsSearchRestoresSettingsAndClearsQuery() {
        let search = SettingsSearchState()
        search.isPresented = true
        search.query = "歌词"
        XCTAssertEqual(search.content, .results)

        search.isPresented = false
        XCTAssertEqual(search.content, .settings)
        XCTAssertEqual(search.query, "")

        search.isPresented = true
        XCTAssertEqual(search.content, .recent)
    }

    @MainActor
    func testDismissingEmptySettingsSearchHidesRecentItems() {
        for query in ["", " \n "] {
            let search = SettingsSearchState()
            search.isPresented = true
            search.query = query
            XCTAssertEqual(search.content, .recent)

            search.isPresented = false
            XCTAssertEqual(search.content, .settings)
            XCTAssertEqual(search.query, "")
        }
    }

    @MainActor
    func testClearingSettingsSearchKeepsSearchOpen() {
        let search = SettingsSearchState()
        search.isPresented = true
        search.query = "歌词"
        search.query = ""

        XCTAssertTrue(search.isPresented)
        XCTAssertEqual(search.content, .recent)
    }

    @MainActor
    func testActiveEmptySearchKeepsFullSettingsListVisible() {
        let search = SettingsSearchState()
        search.isPresented = true

        XCTAssertEqual(search.content, .recent)
        XCTAssertTrue(search.showsSettingsRows)

        search.query = "歌词"
        XCTAssertEqual(search.content, .results)
        XCTAssertFalse(search.showsSettingsRows)
    }

    @MainActor
    func testEndingSearchSessionRestoresFullSettingsList() {
        let search = SettingsSearchState()
        search.isPresented = true
        search.query = "歌词"

        search.endSession()

        XCTAssertFalse(search.isPresented)
        XCTAssertEqual(search.query, "")
        XCTAssertEqual(search.content, .settings)
        XCTAssertTrue(search.showsSettingsRows)
    }

    @MainActor
    func testInactiveSettingsSearchNeverShowsStaleResults() {
        let search = SettingsSearchState()
        search.query = "歌词"

        XCTAssertFalse(search.isPresented)
        XCTAssertEqual(search.content, .settings)
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

#if os(iOS)
@MainActor
final class DiagnosticFeedbackTests: XCTestCase {
    func testFeedbackWithoutAttachmentsDoesNotReadReportsAndKeepsMessage() async throws {
        let message = "希望支持新的播放方式。\n\n建议保留快捷入口。"
        let draft = try await DiagnosticReportMailer.prepare(
            selection: .none,
            reportURLs: [URL(fileURLWithPath: "/missing/diagnostic-report.json")],
            message: message
        )
        XCTAssertTrue(draft.attachments.isEmpty)
        XCTAssertEqual(draft.reportCount, 0)
        XCTAssertEqual(draft.messageBody, message)
        XCTAssertTrue(draft.subject.hasPrefix("Primuse feedback"))
    }
}
#endif
