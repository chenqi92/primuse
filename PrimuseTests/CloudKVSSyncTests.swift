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
}

private final class InMemoryCloudKeyValueStore: CloudKeyValueStore {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    func string(forKey key: String) -> String? { values[key] as? String }
    @discardableResult func synchronize() -> Bool { true }
}
