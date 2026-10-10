import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// iCloud 键值设置同步: 开关打开时按修订号两边补齐, 新装设备绝不把默认值推上去,
/// 初次下载与换账号以云端为准, 拉下来的值被本机观察者原样写回不算编辑。
@MainActor
final class CloudKVSSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: InMemoryCloudKeyValueStore!
    private var sync: CloudKVSSync!

    private let key = "test_setting"
    private var revisionKey: String { "\(key)__updatedAt" }
    private var writerKey: String { "\(key)__writerID" }

    override func setUp() {
        super.setUp()
        suiteName = "CloudKVSSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(true, forKey: CloudSyncChannel.masterDefaultsKey)
        defaults.set(true, forKey: CloudSyncChannel.settings.defaultsKey)
        store = InMemoryCloudKeyValueStore()
        sync = CloudKVSSync(store: store, defaults: defaults, observing: nil)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Home and library layout

    func testLayoutEditIsPushedAndAPulledLayoutIsNotEchoed() {
        let layoutKey = "test_layout_show"
        let layout = InterfaceLayoutSync(keys: [layoutKey], cloud: sync, defaults: defaults)
        layout.start()
        layout.pushEditedKeys()
        XCTAssertNil(store.object(forKey: layoutKey), "starting up pushes nothing")

        defaults.set(false, forKey: layoutKey)
        layout.pushEditedKeys()
        XCTAssertEqual(store.object(forKey: layoutKey) as? Bool, false)
        let pushedRevision = store.double(forKey: "\(layoutKey)__updatedAt")
        XCTAssertGreaterThan(pushedRevision, 0)

        // Another device turns the section back on: pulled and remembered,
        // not pushed back as this device's edit.
        store.set(true, forKey: layoutKey)
        store.set(pushedRevision + 100, forKey: "\(layoutKey)__updatedAt")
        store.set("mac", forKey: "\(layoutKey)__writerID")
        XCTAssertEqual(sync.catchUp().pulled, 1)
        XCTAssertTrue(defaults.bool(forKey: layoutKey))
        layout.pushEditedKeys()
        XCTAssertEqual(store.string(forKey: "\(layoutKey)__writerID"), "mac")
        XCTAssertEqual(store.double(forKey: "\(layoutKey)__updatedAt"), pushedRevision + 100)
    }

    func testOnlyListedLayoutKeysArePushed() {
        let layout = InterfaceLayoutSync(keys: ["test_layout_order"], cloud: sync, defaults: defaults)
        layout.start()
        defaults.set("[\"radio\"]", forKey: "test_unlisted_key")
        layout.pushEditedKeys()
        XCTAssertNil(store.object(forKey: "test_unlisted_key"))
    }

    func testAnyDefaultsWriteTriggersTheLayoutCheck() async throws {
        let layoutKey = "test_layout_order"
        let layout = InterfaceLayoutSync(
            keys: [layoutKey], cloud: sync, defaults: defaults, checkDelay: .milliseconds(20)
        )
        layout.start()
        defaults.set("[\"podcasts\",\"radio\"]", forKey: layoutKey)
        for _ in 0..<50 where store.object(forKey: layoutKey) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.object(forKey: layoutKey) as? String, "[\"podcasts\",\"radio\"]")
    }

    func testLayoutKeysLeaveOutWhatTheAppRewritesOnItsOwn() {
        let keys = InterfaceLayoutSync.keys
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.contains(HomeSectionConfiguration.orderKey))
        XCTAssertTrue(keys.contains(HomeFilterBarConfiguration.storageKey))
        XCTAssertTrue(keys.contains(LibrarySectionLayoutPolicy.hiddenKey))
        XCTAssertTrue(keys.contains("primuse.home.showHero"))
        for rewritten in [
            HomeSpotlightSelection.booksStorageKey,
            HomeSpotlightSelection.radioStorageKey,
            LibraryPinStorage.defaultsKey,
            HomeFolderPinStorage.key,
            ArtistBrowseMode.storageKey,
        ] {
            XCTAssertFalse(keys.contains(rewritten), rewritten)
        }
    }

    /// 播放器的显示偏好跟着走; 跟这台设备的网络、摆法、屏幕走的留在本机。
    func testPlayerDisplaySettingsSyncButDeviceBoundOnesStayLocal() {
        let keys = Set(InterfaceLayoutSync.keys)
        for synced in [
            PlayerAppearancePreferences.showsVolumeBarKey,
            PlayerAppearancePreferences.audioInfoModeKey,
            PlayerAppearancePreferences.animatedArtworkEnabledKey,
            PlayerAppearancePreferences.motionArtworkServiceEnabledKey,
            PlayerAppearancePreferences.motionArtworkServiceEndpointKey,
            PlayerAppearancePreferences.controlTintKey,
            PlayerAppearancePreferences.lyricsColorModeKey,
            PlayerAppearancePreferences.lyricsAlignmentKey,
            PlayerAppearancePreferences.tapLyricsToSeekKey,
            PlayerAppearancePreferences.showsLyricsInterludeKey,
        ] {
            XCTAssertTrue(keys.contains(synced), synced)
        }
        for local in [
            PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyKey,
            PlayerAppearancePreferences.keepsScreenAwakeInPlayerKey,
            PlayerAppearancePreferences.playerScreenWakeRequiresChargingKey,
            PlayerAppearancePreferences.entersFullscreenInLandscapeKey,
            ImmersiveLyricsMotionSettings.storageKey,
            ImmersiveFrameRateMode.storageKey,
            // 字号与所选全屏效果各有自己的登记, 不在这张表里重复。
            CloudKVSKey.lyricsFontScale,
            FullscreenPlayerEffect.storageKey,
        ] {
            XCTAssertFalse(keys.contains(local), local)
        }
    }

    func testFreshInstallPullsCloudCopyAndNeverPushesDefaults() {
        defaults.set("local-default", forKey: key)
        var reloads = 0
        sync.register(key: key) { reloads += 1 }
        XCTAssertNil(store.object(forKey: key), "a device that never edited the key must not push it")
        XCTAssertEqual(reloads, 1)

        store.set("from-mac", forKey: key)
        store.set(1_000.0, forKey: revisionKey)
        store.set("mac", forKey: writerKey)
        let result = sync.catchUp()
        XCTAssertEqual(result.pulled, 1)
        XCTAssertEqual(result.pushed, 0)
        XCTAssertEqual(defaults.string(forKey: key), "from-mac")
        XCTAssertEqual(defaults.double(forKey: revisionKey), 1_000)
        XCTAssertEqual(reloads, 2)
    }

    func testEditWhileSyncIsOffIsRecordedAndPushedWhenSwitchedOn() {
        sync.register(key: key) { }
        defaults.set(false, forKey: CloudSyncChannel.settings.defaultsKey)
        defaults.set("edited-offline", forKey: key)
        sync.markChanged(key: key)
        XCTAssertNil(store.object(forKey: key), "nothing reaches the cloud while the channel is off")
        XCTAssertGreaterThan(defaults.double(forKey: revisionKey), 0, "the edit is still recorded locally")

        // 云端在此期间有更老的一份。
        store.set("older-cloud", forKey: key)
        store.set(10.0, forKey: revisionKey)
        store.set("mac", forKey: writerKey)
        defaults.set(true, forKey: CloudSyncChannel.settings.defaultsKey)
        let result = sync.catchUp()
        XCTAssertEqual(result.pushed, 1)
        XCTAssertEqual(store.object(forKey: key) as? String, "edited-offline")
        XCTAssertEqual(store.double(forKey: revisionKey), defaults.double(forKey: revisionKey))
    }

    func testNewerCloudCopyWinsOverStaleOfflineEdit() {
        sync.register(key: key) { }
        defaults.set(false, forKey: CloudSyncChannel.settings.defaultsKey)
        defaults.set("stale-offline", forKey: key)
        sync.markChanged(key: key)
        let localRevision = defaults.double(forKey: revisionKey)

        store.set("newer-cloud", forKey: key)
        store.set(localRevision + 100, forKey: revisionKey)
        store.set("mac", forKey: writerKey)
        defaults.set(true, forKey: CloudSyncChannel.settings.defaultsKey)
        let result = sync.catchUp()
        XCTAssertEqual(result.pulled, 1)
        XCTAssertEqual(defaults.string(forKey: key), "newer-cloud")
    }

    func testOfflineDeletionIsPushedAsDeletion() {
        sync.register(key: key) { }
        defaults.set("value", forKey: key)
        sync.markChanged(key: key)
        XCTAssertEqual(store.object(forKey: key) as? String, "value")

        defaults.set(false, forKey: CloudSyncChannel.settings.defaultsKey)
        defaults.removeObject(forKey: key)
        sync.markChanged(key: key)
        defaults.set(true, forKey: CloudSyncChannel.settings.defaultsKey)
        XCTAssertEqual(sync.catchUp().pushed, 1)
        XCTAssertNil(store.object(forKey: key))
    }

    func testInitialSyncAppliesCloudCopyRegardlessOfLocalRevision() {
        sync.register(key: key) { }
        defaults.set("written-before-first-download", forKey: key)
        sync.markChanged(key: key)

        // 系统在初次下载时用云端值盖掉了本机之前的写入。
        store.set("cloud", forKey: key)
        store.set(5.0, forKey: revisionKey)
        store.set("mac", forKey: writerKey)
        sync.handleExternalChange(changedKeys: [key], reason: .initialSync)
        XCTAssertEqual(defaults.string(forKey: key), "cloud")
        XCTAssertEqual(defaults.double(forKey: revisionKey), 5)
    }

    func testAccountChangeResetsLocalRevisionsThenTakesCloudCopy() {
        sync.register(key: key) { }
        defaults.set("old-account", forKey: key)
        sync.markChanged(key: key)

        store.set("new-account", forKey: key)
        store.set(7.0, forKey: revisionKey)
        store.set("other", forKey: writerKey)
        sync.handleExternalChange(changedKeys: [key], reason: .accountChange)
        XCTAssertEqual(defaults.string(forKey: key), "new-account")
        XCTAssertEqual(defaults.double(forKey: revisionKey), 7)

        // 新账号云端没有的键: 本机修订号清零, 但值留着, 之后也不会被推上去。
        let other = "other_setting"
        sync.register(key: other) { }
        defaults.set("kept", forKey: other)
        sync.markChanged(key: other)
        // 换账号后存储里是新账号的内容, 本机刚推给旧账号的那份已经不在了。
        for storeKey in [other, "\(other)__updatedAt", "\(other)__writerID"] {
            store.removeObject(forKey: storeKey)
        }
        sync.handleExternalChange(changedKeys: [], reason: .accountChange)
        XCTAssertEqual(defaults.string(forKey: other), "kept")
        XCTAssertEqual(defaults.double(forKey: "\(other)__updatedAt"), 0)
        XCTAssertEqual(sync.catchUp().pushed, 0)
    }

    func testOrdinaryServerChangeStillRespectsRevisions() {
        sync.register(key: key) { }
        defaults.set("mine", forKey: key)
        sync.markChanged(key: key)
        let mine = defaults.double(forKey: revisionKey)

        store.set("older", forKey: key)
        store.set(mine - 1, forKey: revisionKey)
        store.set("mac", forKey: writerKey)
        sync.handleExternalChange(changedKeys: [key], reason: .serverChange)
        XCTAssertEqual(defaults.string(forKey: key), "mine")

        store.set("newer", forKey: key)
        store.set(mine + 1, forKey: revisionKey)
        sync.handleExternalChange(changedKeys: [revisionKey], reason: .serverChange)
        XCTAssertEqual(defaults.string(forKey: key), "newer")
    }

    /// 扫码直传来的值: 比这台设备上的云端旧值新、盖不回来, 但不推上这台设备的 iCloud
    /// (Apple TV 登录的可能是另一个 Apple ID); 云端之后真正改了照常拉下来。
    func testTransferredValueBeatsStaleCloudCopyWithoutBeingPushed() {
        var reloads = 0
        sync.register(key: key) { reloads += 1 }
        store.set("other-account", forKey: key)
        store.set(1_000.0, forKey: revisionKey)
        store.set("family-phone", forKey: writerKey)
        XCTAssertEqual(sync.catchUp().pulled, 1)
        let reloadsBefore = reloads

        sync.applyTransferred(key: key, value: "from-phone")
        XCTAssertEqual(defaults.string(forKey: key), "from-phone")
        XCTAssertEqual(reloads, reloadsBefore + 1)
        XCTAssertGreaterThan(defaults.double(forKey: revisionKey), 1_000)
        XCTAssertEqual(sync.catchUp().pushed, 0)
        XCTAssertEqual(store.object(forKey: key) as? String, "other-account",
                       "a transferred value never reaches this device's iCloud")

        sync.handleExternalChange(changedKeys: [key], reason: .serverChange)
        XCTAssertEqual(defaults.string(forKey: key), "from-phone", "the older cloud copy cannot win it back")

        store.set("edited-later", forKey: key)
        store.set(defaults.double(forKey: revisionKey) + 100, forKey: revisionKey)
        sync.handleExternalChange(changedKeys: [key], reason: .serverChange)
        XCTAssertEqual(defaults.string(forKey: key), "edited-later")
    }

    func testEditingATransferredValueOnThisDeviceIsPushed() {
        sync.register(key: key) { }
        sync.applyTransferred(key: key, value: "from-phone")
        XCTAssertNil(store.object(forKey: key))

        defaults.set("edited-on-tv", forKey: key)
        sync.markChanged(key: key)
        XCTAssertEqual(store.object(forKey: key) as? String, "edited-on-tv")
    }

    func testTransferMatchingTheCloudCopyAdoptsItsRevision() {
        sync.register(key: key) { }
        store.set("same", forKey: key)
        store.set(1_000.0, forKey: revisionKey)
        store.set("phone", forKey: writerKey)

        sync.applyTransferred(key: key, value: "same")
        XCTAssertEqual(defaults.double(forKey: revisionKey), 1_000)
        XCTAssertEqual(defaults.string(forKey: writerKey), "phone")
        let result = sync.catchUp()
        XCTAssertEqual(result.pulled, 0)
        XCTAssertEqual(result.pushed, 0)
    }

    func testWritingBackAJustPulledValueDoesNotEcho() {
        sync.register(key: key) { }
        store.set("cloud", forKey: key)
        store.set(50.0, forKey: revisionKey)
        store.set("mac", forKey: writerKey)
        sync.handleExternalChange(changedKeys: [key], reason: .serverChange)
        XCTAssertEqual(defaults.string(forKey: key), "cloud")

        // 比如 @AppStorage 的 onChange 在拉取后又调用了一次 markChanged。
        sync.markChanged(key: key)
        XCTAssertEqual(store.double(forKey: revisionKey), 50, "an unchanged value must not bump the cloud revision")
        XCTAssertEqual(store.string(forKey: writerKey), "mac")

        defaults.set("edited", forKey: key)
        sync.markChanged(key: key)
        XCTAssertGreaterThan(store.double(forKey: revisionKey), 50)
        XCTAssertEqual(store.object(forKey: key) as? String, "edited")
    }

    func testQuotaViolationChangesNothing() {
        sync.register(key: key) { }
        defaults.set("mine", forKey: key)
        sync.markChanged(key: key)
        store.set("cloud", forKey: key)
        store.set(9_999.0, forKey: revisionKey)
        sync.handleExternalChange(changedKeys: [key], reason: .quotaViolation)
        XCTAssertEqual(defaults.string(forKey: key), "mine")
    }

    func testLocalEditsPublishImmediatelyWithoutForcingSynchronization() {
        sync.register(key: key) { }
        for value in [true, false, true] {
            defaults.set(value, forKey: key)
            sync.markChanged(key: key)
            XCTAssertEqual(store.object(forKey: key) as? Bool, value)
            XCTAssertEqual(store.double(forKey: revisionKey), defaults.double(forKey: revisionKey))
        }
        XCTAssertEqual(store.synchronizeCount, 0, "toggle callbacks must not force KVS storage synchronization")
    }

    func testCatchUpPublishesAllOfflineEditsWithoutPerKeySynchronization() {
        let keys = [key, "second_setting"]
        defaults.set(false, forKey: CloudSyncChannel.settings.defaultsKey)
        for key in keys {
            sync.register(key: key) { }
            defaults.set("offline-edit", forKey: key)
            sync.markChanged(key: key)
        }
        defaults.set(true, forKey: CloudSyncChannel.settings.defaultsKey)
        XCTAssertEqual(sync.catchUp().pushed, keys.count)
        for key in keys {
            XCTAssertEqual(store.object(forKey: key) as? String, "offline-edit")
        }
        XCTAssertEqual(store.synchronizeCount, 0)
    }

    func testLinkedPlaybackTogglesPersistOnlyTheirFinalStateOnce() throws {
        let playback = PlaybackSettingsStore(defaults: defaults, cloudSync: sync)
        let key = PlaybackSettings.defaultsKey
        playback.gaplessEnabled = true
        let writesBeforeCrossfade = store.setCounts[key, default: 0]

        playback.crossfadeEnabled = true
        playback.gaplessEnabled = false // the UI's onChange repeats the linked value
        XCTAssertFalse(playback.gaplessEnabled)
        XCTAssertTrue(playback.crossfadeEnabled)
        XCTAssertEqual(store.setCounts[key, default: 0] - writesBeforeCrossfade, 1)

        let writesBeforeGapless = store.setCounts[key, default: 0]
        playback.gaplessEnabled = true
        playback.crossfadeEnabled = false
        XCTAssertTrue(playback.gaplessEnabled)
        XCTAssertFalse(playback.crossfadeEnabled)
        XCTAssertEqual(store.setCounts[key, default: 0] - writesBeforeGapless, 1)
        XCTAssertEqual(PlaybackSettings.load(defaults: defaults), playback.snapshot())
        let data = try XCTUnwrap(store.object(forKey: key) as? Data)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: data), playback.snapshot())
    }

    func testLinkedSpatialTogglesPersistOnlyTheirFinalStateOnce() {
        let playback = PlaybackSettingsStore(defaults: defaults, cloudSync: sync)
        let key = PlaybackSettings.defaultsKey
        playback.spatialHeadTrackingEnabled = true
        XCTAssertTrue(playback.spatialAudioEnabled)
        XCTAssertTrue(playback.spatialHeadTrackingEnabled)
        XCTAssertEqual(store.setCounts[key, default: 0], 1)

        playback.spatialAudioEnabled = false
        XCTAssertFalse(playback.spatialAudioEnabled)
        XCTAssertFalse(playback.spatialHeadTrackingEnabled)
        XCTAssertEqual(store.setCounts[key, default: 0], 2)
        XCTAssertEqual(PlaybackSettings.load(defaults: defaults), playback.snapshot())
    }

    func testUnchangedPlaybackPreferenceDoesNotPublishFreshInstallDefaults() {
        let playback = PlaybackSettingsStore(defaults: defaults, cloudSync: sync)
        playback.skipLeadingSilenceEnabled = playback.skipLeadingSilenceEnabled
        XCTAssertNil(store.object(forKey: PlaybackSettings.defaultsKey))
        XCTAssertEqual(defaults.double(forKey: PlaybackSettings.defaultsKey + "__updatedAt"), 0)
    }

    func testPlaybackEditAfterRemoteReloadUsesTheAppliedSnapshot() throws {
        let playback = PlaybackSettingsStore(defaults: defaults, cloudSync: sync)
        let key = PlaybackSettings.defaultsKey
        playback.skipLeadingSilenceEnabled = false
        var remote = playback.snapshot()
        remote.skipLeadingSilenceEnabled = true
        store.set(try JSONEncoder().encode(remote), forKey: key)
        store.set(defaults.double(forKey: key + "__updatedAt") + 100, forKey: key + "__updatedAt")
        store.set("other-device", forKey: key + "__writerID")
        sync.handleExternalChange(changedKeys: [key], reason: .serverChange)
        XCTAssertTrue(playback.skipLeadingSilenceEnabled)
        let writesBefore = store.setCounts[key, default: 0]

        playback.skipLeadingSilenceEnabled = false
        XCTAssertEqual(store.setCounts[key, default: 0] - writesBefore, 1)
        XCTAssertFalse(PlaybackSettings.load(defaults: defaults).skipLeadingSilenceEnabled)
        let data = try XCTUnwrap(store.object(forKey: key) as? Data)
        XCTAssertFalse(try JSONDecoder().decode(PlaybackSettings.self, from: data).skipLeadingSilenceEnabled)
    }

    func testSystemStoreWritesRunOffMainAndPreserveValueTypesAndDeletion() async throws {
        let system = InMemoryCloudKeyValueStore()
        let queued = CloudKVSSync(defaults: defaults, systemStoreFactory: { system })
        let values: [(String, Any)] = [
            (key, true), ("quality", 1.25), ("names", ["one", "two"]),
            ("payload", Data([1, 2, 3])), ("title", "saved"),
        ]
        for (key, value) in values {
            queued.register(key: key) { }
            defaults.set(value, forKey: key)
            queued.markChanged(key: key)
        }
        await queued.synchronizePendingChanges()
        for (key, value) in values {
            XCTAssertTrue((system.object(forKey: key) as? NSObject)?.isEqual(value) == true, key)
            XCTAssertEqual(system.double(forKey: key + "__updatedAt"), defaults.double(forKey: key + "__updatedAt"))
        }
        defaults.removeObject(forKey: key)
        queued.markChanged(key: key)
        await queued.synchronizePendingChanges()
        XCTAssertNil(system.object(forKey: key))
        XCTAssertEqual(system.mainThreadSetCount, 0)
        XCTAssertEqual(system.synchronizeCount, 1, "only the initial store load requests synchronization")
    }

    func testInitialCloudCacheIsAppliedBeforePlaybackRollouts() async throws {
        var local = PlaybackSettings()
        local.crossfadeDuration = PlaybackSettings.legacyDefaultCrossfadeDuration
        local.save(defaults: defaults)
        defaults.set(true, forKey: PlaybackSettings.lockScreenLyricsRolloutKey)
        var remote = local
        remote.crossfadeEnabled = true
        remote.crossfadeDuration = 9
        let key = PlaybackSettings.defaultsKey
        let system = InMemoryCloudKeyValueStore()
        system.set(try JSONEncoder().encode(remote), forKey: key)
        system.set(100.0, forKey: key + "__updatedAt")
        system.set("other-device", forKey: key + "__writerID")
        let queued = CloudKVSSync(defaults: defaults, initialValues: system.dictionaryRepresentation,
                                  systemStoreFactory: { system })
        let playback = PlaybackSettingsStore(defaults: defaults, cloudSync: queued)
        XCTAssertTrue(playback.crossfadeEnabled)
        XCTAssertEqual(playback.crossfadeDuration, 9)
        await queued.synchronizePendingChanges()
        XCTAssertEqual(playback.crossfadeDuration, 9)
        XCTAssertEqual(system.setCounts[key], 1, "the rollout must not publish stale local defaults")
    }

    func testBlockedSystemWriteDoesNotBlockToggleAndLatestValueWins() async throws {
        let gate = CloudKVSWriteGate(key: key)
        defer { gate.release() }
        let system = InMemoryCloudKeyValueStore(beforeSet: { gate.blockFirstWrite(to: $0) })
        let queued = CloudKVSSync(defaults: defaults, systemStoreFactory: { system })
        queued.register(key: key) { }
        await queued.synchronizePendingChanges()
        defaults.set(true, forKey: key)
        queued.markChanged(key: key)
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(defaults.bool(forKey: key))
        XCTAssertNil(system.object(forKey: key), "the click returned while the system write is still blocked")

        for value in [false, true, false] {
            defaults.set(value, forKey: key)
            queued.markChanged(key: key)
        }
        gate.release()
        await queued.synchronizePendingChanges()
        XCTAssertEqual(system.object(forKey: key) as? Bool, false)
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertEqual(system.mainThreadSetCount, 0)
    }

    func testQueuedWritePreservesNewerRemoteValueThatArrivedBeforeExecution() async throws {
        let gate = CloudKVSWriteGate(key: "blocking_setting")
        defer { gate.release() }
        let system = InMemoryCloudKeyValueStore(beforeSet: { gate.blockFirstWrite(to: $0) })
        let queued = CloudKVSSync(defaults: defaults, systemStoreFactory: { system })
        queued.register(key: key) { }
        queued.register(key: "blocking_setting") { }
        await queued.synchronizePendingChanges()
        defaults.set(true, forKey: "blocking_setting")
        queued.markChanged(key: "blocking_setting")
        await fulfillment(of: [gate.entered], timeout: 2)

        defaults.set("queued-local", forKey: key)
        queued.markChanged(key: key)
        system.set("newer-remote", forKey: key)
        system.set(defaults.double(forKey: revisionKey) + 100, forKey: revisionKey)
        system.set("other-device", forKey: writerKey)
        gate.release()
        await queued.synchronizePendingChanges()
        XCTAssertEqual(system.object(forKey: key) as? String, "newer-remote")
        XCTAssertEqual(defaults.string(forKey: key), "newer-remote")
    }

    func testAccountChangeInvalidatesWritesQueuedForPreviousAccount() async throws {
        let gate = CloudKVSWriteGate(key: "blocking_setting")
        defer { gate.release() }
        let applied = expectation(description: "new account applied")
        let system = InMemoryCloudKeyValueStore(beforeSet: { gate.blockFirstWrite(to: $0) })
        let queued = CloudKVSSync(defaults: defaults, systemStoreFactory: { system })
        queued.register(key: key) { [defaults, key] in
            if defaults?.string(forKey: key) == "new-account" { applied.fulfill() }
        }
        queued.register(key: "blocking_setting") { }
        await queued.synchronizePendingChanges()
        defaults.set(true, forKey: "blocking_setting")
        queued.markChanged(key: "blocking_setting")
        await fulfillment(of: [gate.entered], timeout: 2)
        defaults.set("previous-account", forKey: key)
        queued.markChanged(key: key)

        system.set("new-account", forKey: key)
        system.set(10.0, forKey: revisionKey)
        system.set("new-account-writer", forKey: writerKey)
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: system,
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreAccountChange]
        )
        gate.release()
        await fulfillment(of: [applied], timeout: 2)
        await queued.synchronizePendingChanges()
        XCTAssertEqual(system.object(forKey: key) as? String, "new-account")
        XCTAssertEqual(system.setCounts[key], 1, "old-account writes must never reach the new account")
        XCTAssertEqual(defaults.string(forKey: key), "new-account")
        XCTAssertEqual(defaults.double(forKey: revisionKey), 10)
    }

    // MARK: Favorites

    private struct FavoritesDevice {
        let defaults: UserDefaults
        let cloud: CloudKVSSync
        let library: MusicLibrary
        let favorites: FavoriteCollectionStore
    }

    private var favoritesKey: String { CloudKVSKey.favoriteCollection }

    /// 一台设备：自己的设置、共用同一份「iCloud」(`store`)。
    private func makeFavoritesDevice(
        defaults deviceDefaults: UserDefaults? = nil,
        pins: [QuickAccessPinReference],
        folders: [LibraryFolderNodeID]? = nil,
        sources: [MusicSource] = []
    ) throws -> FavoritesDevice {
        let deviceDefaults = try deviceDefaults ?? makeDeviceDefaults()
        deviceDefaults.set(LibraryPinStorage.encode(pins), forKey: LibraryPinStorage.defaultsKey)
        if let folders {
            deviceDefaults.set(HomeFolderPinStorage.encode(folders), forKey: HomeFolderPinStorage.key)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKVSSyncTests-favorites-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cloud = deviceDefaults === defaults ? sync! : CloudKVSSync(store: store, defaults: deviceDefaults, observing: nil)
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        let favorites = FavoriteCollectionStore(
            defaults: deviceDefaults,
            favorites: LibraryFavoritesStore(fileURL: directory.appendingPathComponent("favorites.json")),
            cloud: cloud
        )
        favorites.start(library: library, sources: { sources })
        return FavoritesDevice(defaults: deviceDefaults, cloud: cloud, library: library, favorites: favorites)
    }

    private func makeDeviceDefaults() throws -> UserDefaults {
        let suite = "CloudKVSSyncTests-favorites-\(UUID().uuidString)"
        let created = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { created.removePersistentDomain(forName: suite) }
        return created
    }

    private func pins(on device: FavoritesDevice) -> [QuickAccessPinReference] {
        LibraryPinStorage.decode(device.defaults.string(forKey: LibraryPinStorage.defaultsKey) ?? "")
    }

    private func cloudFavorites() -> FavoriteCollectionSyncState? {
        FavoriteCollectionSyncPolicy.decode(store.object(forKey: favoritesKey) as? Data)
    }

    /// 接上 iCloud 后的那次推送在一个任务里，等它落进「iCloud」。
    private func waitForCloudFavorites(
        _ condition: @escaping (FavoriteCollectionSyncState) -> Bool
    ) async throws {
        for _ in 0..<100 {
            if let state = cloudFavorites(), condition(state) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the favorites never reached the cloud copy")
    }

    func testFavoritesFirstSyncTakesTheUnionAndRemovalsPropagate() async throws {
        let liked = LibraryPinStorage.likedSongsPin
        let roadTrip = QuickAccessPinReference(kind: .playlist, itemID: "road-trip")
        let jazz = QuickAccessPinReference(kind: .playlist, itemID: "jazz")

        let phone = try makeFavoritesDevice(defaults: defaults, pins: [liked, roadTrip])
        try await waitForCloudFavorites { $0.members[roadTrip.id]?.isCollected == true }

        // Mac 上原本收藏着另一张歌单：接上时拉到手机那份，两边的都在，谁也没被冲掉。
        let mac = try makeFavoritesDevice(pins: [liked, jazz])
        XCTAssertEqual(pins(on: mac), [liked, roadTrip, jazz])
        try await waitForCloudFavorites { $0.members[jazz.id]?.isCollected == true }
        XCTAssertEqual(sync.catchUp().pulled, 1)
        XCTAssertEqual(pins(on: phone), [liked, roadTrip, jazz])

        // 手机上取消：Mac 跟着拿掉，Mac 手上的旧列表也不会把它推回来。
        phone.favorites.uncollect(jazz, library: phone.library)
        phone.favorites.pushToCloudNow()
        XCTAssertEqual(cloudFavorites()?.members[jazz.id]?.isCollected, false)
        XCTAssertEqual(mac.cloud.catchUp().pulled, 1)
        XCTAssertEqual(pins(on: mac), [liked, roadTrip])
        let revision = store.double(forKey: "\(favoritesKey)__updatedAt")
        mac.favorites.pushToCloudNow()
        XCTAssertEqual(store.double(forKey: "\(favoritesKey)__updatedAt"), revision, "nothing new: no echo")
        XCTAssertEqual(cloudFavorites()?.members[jazz.id]?.isCollected, false)

        // 排序也传过去。
        phone.favorites.setOrder([roadTrip, liked])
        phone.favorites.pushToCloudNow()
        XCTAssertEqual(mac.cloud.catchUp().pulled, 1)
        XCTAssertEqual(pins(on: mac), [roadTrip, liked])
    }

    func testFavoritesStayLocalWhileICloudSyncIsOff() async throws {
        let liked = LibraryPinStorage.likedSongsPin
        let jazz = QuickAccessPinReference(kind: .playlist, itemID: "jazz")
        let phone = try makeFavoritesDevice(defaults: defaults, pins: [liked])
        try await waitForCloudFavorites { $0.members[liked.id]?.isCollected == true }
        let mac = try makeFavoritesDevice(pins: [liked])
        try await Task.sleep(for: .milliseconds(50))

        mac.defaults.set(false, forKey: CloudSyncChannel.masterDefaultsKey)
        phone.favorites.collect(jazz, library: phone.library)
        phone.favorites.pushToCloudNow()
        XCTAssertEqual(cloudFavorites()?.members[jazz.id]?.isCollected, true)
        XCTAssertEqual(mac.cloud.catchUp().pulled, 0)
        XCTAssertEqual(pins(on: mac), [liked], "nothing is read while sync is off")

        let cloudBefore = store.object(forKey: favoritesKey) as? Data
        mac.favorites.uncollect(liked, library: mac.library)
        mac.favorites.pushToCloudNow()
        XCTAssertEqual(store.object(forKey: favoritesKey) as? Data, cloudBefore, "nothing is written while sync is off")

        // 打开之后两边补齐：Mac 关着时改过、修订号更新，也先把云端那份拉下来合，不直接盖掉
        // 手机刚收藏的 jazz；手机再收到 Mac 关着时拿掉的「我喜欢」。
        mac.defaults.set(true, forKey: CloudSyncChannel.masterDefaultsKey)
        XCTAssertEqual(mac.cloud.catchUp().pulled, 1)
        XCTAssertEqual(pins(on: mac), [jazz])
        XCTAssertEqual(cloudFavorites()?.members[jazz.id]?.isCollected, true)
        XCTAssertEqual(cloudFavorites()?.members[liked.id]?.isCollected, false)
        XCTAssertEqual(sync.catchUp().pulled, 1)
        XCTAssertEqual(pins(on: phone), [jazz])
    }

    func testFavoriteFoldersOnThisDevicesLocalSourcesStayLocal() async throws {
        let nas = MusicSource(id: "nas", name: "NAS", type: .webdav)
        let files = MusicSource(id: "phone-files", name: "Files", type: .local)
        let nasFolder = LibraryFolderNodeID(sourceID: nas.id, kind: .folder, normalizedRelativePath: "music/live")
        let localFolder = LibraryFolderNodeID(sourceID: files.id, kind: .folder, normalizedRelativePath: "inbox")
        let liked = LibraryPinStorage.likedSongsPin

        let phone = try makeFavoritesDevice(
            defaults: defaults,
            pins: [liked, .folder(localFolder), .folder(nasFolder)],
            folders: [localFolder, nasFolder],
            sources: [nas, files]
        )
        try await waitForCloudFavorites { $0.members[QuickAccessPinReference.folder(nasFolder).id] != nil }
        XCTAssertNil(cloudFavorites()?.members[QuickAccessPinReference.folder(localFolder).id])

        let mac = try makeFavoritesDevice(pins: [liked], sources: [nas])
        XCTAssertEqual(pins(on: mac), [liked, .folder(nasFolder)])
        XCTAssertEqual(HomeFolderPinStorage.decode(mac.defaults.string(forKey: HomeFolderPinStorage.key) ?? ""), [nasFolder])

        // 手机自己的目录留在原处，不会因为同步里没有它就被当成取消。
        try await Task.sleep(for: .milliseconds(50))
        sync.catchUp()
        XCTAssertEqual(pins(on: phone), [liked, .folder(localFolder), .folder(nasFolder)])
        XCTAssertEqual(
            HomeFolderPinStorage.decode(phone.defaults.string(forKey: HomeFolderPinStorage.key) ?? ""),
            [localFolder, nasFolder]
        )
    }

    func testFavoriteBookFromICloudTriggersServerReconciliation() async throws {
        let liked = LibraryPinStorage.likedSongsPin
        let book = QuickAccessPinReference(kind: .book, itemID: "book:三体\u{1F}刘慈欣")
        let phone = try makeFavoritesDevice(defaults: defaults, pins: [liked])
        try await waitForCloudFavorites { $0.members[liked.id] != nil }
        let mac = try makeFavoritesDevice(pins: [liked])
        try await Task.sleep(for: .milliseconds(50))

        phone.favorites.collect(book, library: phone.library)
        phone.favorites.pushToCloudNow()
        let changed = expectation(forNotification: FavoriteCollectionStore.collectedBooksDidChange, object: nil)
        XCTAssertEqual(mac.cloud.catchUp().pulled, 1)
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(mac.favorites.collectedBookIDs, [book.itemID])
    }

    func testMergingKeyPullsADifferentCloudCopyEvenWhenTheLocalRevisionIsNewer() {
        var reloads = 0
        sync.registerMerging(key: key) { reloads += 1 }
        defaults.set(false, forKey: CloudSyncChannel.settings.defaultsKey)
        defaults.set("merged-offline", forKey: key)
        sync.markChanged(key: key)

        store.set("from-mac", forKey: key)
        store.set(10.0, forKey: revisionKey)
        store.set("mac", forKey: writerKey)
        defaults.set(true, forKey: CloudSyncChannel.settings.defaultsKey)
        let result = sync.catchUp()
        XCTAssertEqual(result.pulled, 1, "handed to the store to merge instead of pushed over")
        XCTAssertEqual(result.pushed, 0)
        XCTAssertEqual(defaults.string(forKey: key), "from-mac")
        XCTAssertEqual(store.object(forKey: key) as? String, "from-mac")
        XCTAssertEqual(reloads, 2)

        // 一样的就不再拉。
        XCTAssertEqual(sync.catchUp().pulled, 0)
        // 普通的键照旧按修订号走。
        sync.register(key: "plain_setting") { }
        defaults.set(false, forKey: CloudSyncChannel.settings.defaultsKey)
        defaults.set("offline-edit", forKey: "plain_setting")
        sync.markChanged(key: "plain_setting")
        store.set("older-cloud", forKey: "plain_setting")
        store.set(10.0, forKey: "plain_setting__updatedAt")
        defaults.set(true, forKey: CloudSyncChannel.settings.defaultsKey)
        XCTAssertEqual(sync.catchUp().pushed, 1)
        XCTAssertEqual(store.object(forKey: "plain_setting") as? String, "offline-edit")
    }
}

private final class InMemoryCloudKeyValueStore: CloudKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var counts: [String: Int] = [:]
    private var synchronizations = 0
    private var mainThreadSets = 0
    private let beforeSet: @Sendable (String) -> Void
    init(beforeSet: @escaping @Sendable (String) -> Void = { _ in }) { self.beforeSet = beforeSet }
    var dictionaryRepresentation: [String: Any] { lock.withLock { values } }
    var setCounts: [String: Int] { lock.withLock { counts } }
    var synchronizeCount: Int { lock.withLock { synchronizations } }
    var mainThreadSetCount: Int { lock.withLock { mainThreadSets } }
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func set(_ value: Any?, forKey key: String) {
        beforeSet(key)
        lock.withLock {
            counts[key, default: 0] += 1
            if Thread.isMainThread { mainThreadSets += 1 }
            if let value { values[key] = value } else { values.removeValue(forKey: key) }
        }
    }
    func removeObject(forKey key: String) { lock.withLock { values.removeValue(forKey: key) } }
    func double(forKey key: String) -> Double { lock.withLock { (values[key] as? NSNumber)?.doubleValue ?? 0 } }
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    @discardableResult func synchronize() -> Bool {
        lock.withLock { synchronizations += 1 }
        return true
    }
}

private final class CloudKVSWriteGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "system write blocked")
    private let key: String
    private let lock = NSLock()
    private var used = false
    private let semaphore = DispatchSemaphore(value: 0)
    init(key: String) { self.key = key }
    func blockFirstWrite(to key: String) {
        guard key == self.key, lock.withLock({ if used { return false }; used = true; return true }) else { return }
        entered.fulfill()
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
}
