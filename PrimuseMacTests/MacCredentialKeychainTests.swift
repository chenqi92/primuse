import Foundation
import LocalAuthentication
import PrimuseKit
import Security
import XCTest
@testable import Primuse

final class MacCredentialKeychainTests: XCTestCase {
    private let account = "fixture"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: PrimuseConstants.keychainServiceName,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
         kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true]
    }

    private func withStore(_ test: (MacCredentialKeychain, Store) -> Void) {
        let suite = "mac-keychain-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store()
        test(MacCredentialKeychain(defaults: defaults, perform: store.perform), store)
    }

    func testStartupEnumerationAndMissingModernMigrationItemNeverConsultLoginKeychain() {
        withStore { bridge, store in
            var all = query
            all.removeValue(forKey: kSecAttrAccount as String)
            all.removeValue(forKey: kSecReturnData as String)
            all[kSecMatchLimit as String] = kSecMatchLimitAll
            all[kSecReturnAttributes as String] = true
            _ = bridge.copy(all)
            _ = MacCredentialKeychain.$modernMigration.withValue(true) { bridge.copy(query) }
            XCTAssertEqual(store.loginReads, [])
        }
    }

    func testBackgroundDenialAndExplicitRetryOnlyAskForTheSelectedItem() {
        withStore { bridge, store in
            store.requiresPermission = true
            XCTAssertEqual(bridge.copy(query).0, errSecInteractionNotAllowed)
            let other = MacCredentialKeychain.$interactiveAccount.withValue("other") { bridge.copy(query) }
            XCTAssertEqual(other.0, errSecInteractionNotAllowed)
            store.deny = true
            let denied = MacCredentialKeychain.$interactiveAccount.withValue(account) { bridge.copy(query) }
            XCTAssertEqual(denied.0, errSecInteractionNotAllowed)
            XCTAssertEqual(bridge.copy(query).0, errSecInteractionNotAllowed)
            XCTAssertEqual(store.loginReads, [false, false, true, false])
            XCTAssertNil(store.local)
            store.deny = false
            let allowed = MacCredentialKeychain.$interactiveAccount.withValue(account) { bridge.copy(query) }
            XCTAssertEqual(allowed.1 as? Data, store.secret)
            XCTAssertEqual(bridge.copy(query).1 as? Data, store.secret)
            XCTAssertEqual(store.loginReads, [false, false, true, false, true])
            bridge.promotePassword(store.secret, account: account)
            XCTAssertEqual(store.sync, store.secret)
            XCTAssertEqual(bridge.copy(query).0, errSecItemNotFound)
            XCTAssertEqual(store.loginReads.count, 5, "The retained login copy cannot shadow the sync password")
        }
    }

    func testDeviceOnlyItemIsVerifiedBeforeExactLegacyCopyIsRemoved() {
        withStore { bridge, store in
            let result = bridge.copy(query, deviceOnly: true)
            XCTAssertEqual(result.1 as? Data, store.secret)
            XCTAssertEqual(store.local, store.secret)
            XCTAssertEqual(store.added?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertEqual(store.added?[kSecAttrGeneric as String] as? Data, KeychainService.deviceOnlyItemMarker)
            XCTAssertTrue(store.deletedExactLoginItem)
            XCTAssertNil(store.sync)
        }
    }

    func testFailedCopyOrReadbackLeavesLegacyCredentialAvailable() {
        for failWrite in [true, false] {
            withStore { bridge, store in
                store.failWrite = failWrite
                store.failReadback = !failWrite
                XCTAssertEqual(bridge.copy(query).1 as? Data, store.secret)
                XCTAssertFalse(store.deletedExactLoginItem)
                XCTAssertNotNil(store.login)
            }
        }
    }

    func testLegacyDeviceOnlyMarkerPreservesUnlockedRestrictionInNewStore() {
        withStore { bridge, store in
            store.legacyAttributes = [
                kSecAttrGeneric as String: KeychainService.deviceOnlyItemMarker,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            ]
            XCTAssertEqual(bridge.copy(query).1 as? Data, store.secret)
            XCTAssertEqual(store.added?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }
    }

    func testExistingCloudPasswordAndRotatedTokenDateSurviveUpgrade() {
        withStore { bridge, store in
            store.local = store.secret
            store.sync = Data("different-on-other-device".utf8)
            bridge.promotePassword(store.secret, account: account)
            XCTAssertEqual(store.sync, Data("different-on-other-device".utf8))
            XCTAssertEqual(store.local, store.secret)
            store.local = nil
            var token = query
            token[kSecAttrService as String] = CloudTokenManager.serviceName
            XCTAssertEqual(bridge.copy(token).1 as? Data, store.secret)
            XCTAssertEqual(MacCredentialKeychain.originalTokenDate(store.added ?? [:]), store.originalDate)
        }
    }

    func testComparingLegacyTokenDatesDoesNotReadTheSecret() {
        withStore { bridge, store in
            store.requiresPermission = true
            XCTAssertFalse(bridge.localTokenIsNewer(account: account, than: store.originalDate.addingTimeInterval(1)))
            XCTAssertTrue(bridge.localTokenIsNewer(account: account, than: store.originalDate.addingTimeInterval(-1)))
            XCTAssertTrue(store.loginReads.isEmpty)
            XCTAssertNil(store.local)
        }
    }

    private final class Store {
        let secret = Data("test-secret".utf8)
        let originalDate = Date(timeIntervalSince1970: 12345)
        var login: Data? = Data("test-secret".utf8)
        var local: Data?
        var sync: Data?
        var requiresPermission = false
        var deny = false
        var failWrite = false
        var failReadback = false
        var legacyAttributes: [String: Any] = [:]
        var loginReads: [Bool] = []
        var added: [String: Any]?
        var deletedExactLoginItem = false

        func perform(_ op: MacCredentialKeychain.Operation, _ q: [String: Any]) -> MacCredentialKeychain.Match {
            let modern = q[kSecUseDataProtectionKeychain as String] as? Bool == true
            let synced = q[kSecAttrSynchronizable as String] as? Bool == true
            if modern { XCTAssertEqual((q[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true) }
            switch op {
            case .read where !modern:
                var allowed = DarwinBoolean(false)
                XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
                if q[kSecReturnData as String] as? Bool != true {
                    XCTAssertFalse(allowed.boolValue)
                    return (errSecSuccess, [kSecAttrModificationDate as String: originalDate] as NSDictionary)
                }
                loginReads.append(allowed.boolValue)
                guard let login else { return (errSecItemNotFound, nil) }
                if requiresPermission && !allowed.boolValue { return (errSecInteractionNotAllowed, nil) }
                if deny { return (errSecUserCanceled, nil) }
                var item = legacyAttributes
                item[kSecValueData as String] = login
                item[kSecAttrModificationDate as String] = originalDate
                item[kSecValuePersistentRef as String] = Data([1])
                return (errSecSuccess, item as NSDictionary)
            case .read:
                guard let data = synced ? sync : local else { return (errSecItemNotFound, nil) }
                return failReadback ? (errSecNotAvailable, nil) : (errSecSuccess, data as NSData)
            case .add:
                if failWrite { return (errSecNotAvailable, nil) }
                if (synced ? sync : local) != nil { return (errSecDuplicateItem, nil) }
                added = q
                let data = q[kSecValueData as String] as? Data
                if synced { sync = data } else { local = data }
                return (errSecSuccess, nil)
            case .delete where !modern:
                var allowed = DarwinBoolean(false)
                XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
                XCTAssertFalse(allowed.boolValue, "Cleanup must never request a second authorization")
                if requiresPermission { return (errSecInteractionNotAllowed, nil) }
                XCTAssertEqual(q[kSecValuePersistentRef as String] as? Data, Data([1]))
                deletedExactLoginItem = true
                login = nil
                return (errSecSuccess, nil)
            case .delete:
                if synced { sync = nil } else { local = nil }
                return (errSecSuccess, nil)
            case .update:
                XCTFail("An upgrade must never overwrite an existing item")
                return (errSecParam, nil)
            }
        }
    }
}
