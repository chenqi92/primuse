import XCTest
import CryptoKit
@testable import PrimuseKit

final class OfflineSettingsBackupTests: XCTestCase {
    private func backup() -> OfflineSettingsBackup {
        .init(createdAt: Date(timeIntervalSince1970: 12345), appVersion: "1.0", platform: "iOS",
              standard: .init(keys: ["enabled", "unset", "layout"], values: [
                "enabled": LANSettingsBundle.encodeValue(false)!,
                "layout": LANSettingsBundle.encodeValue(["home", "search"])!
              ]), shared: .init(keys: [], values: [:]))
    }

    func testRoundTripPreservesTypesScopeAndAssets() throws {
        var original = backup()
        let image = Data("image fixture".utf8)
        let id = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        original.assets = [.init(kind: .backdrop, name: id, data: image),
                           .init(kind: .font, name: "Custom.otf", data: Data([1, 2, 3]))]
        let restored = try OfflineSettingsBackup.decode(original.encoded())
        XCTAssertEqual(restored, original)
        try restored.standard.validate(allowedKeys: ["enabled", "layout", "unset"])
        XCTAssertEqual(LANSettingsBundle.decodeValue(restored.standard.values["enabled"]!) as? Bool, false)
        XCTAssertNil(restored.standard.values["unset"])
    }

    func testCorruptPayloadIsRejectedBeforeDecoding() throws {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: backup().encoded()) as? [String: Any])
        envelope["payload"] = Data("{}".utf8).base64EncodedString()
        XCTAssertThrowsError(try OfflineSettingsBackup.decode(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? OfflineSettingsBackupError, .invalidFile)
        }
    }

    func testForeignAndNewerFormatsAreRejected() throws {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: backup().encoded()) as? [String: Any])
        envelope["version"] = 2
        XCTAssertThrowsError(try OfflineSettingsBackup.decode(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? OfflineSettingsBackupError, .unsupportedVersion)
        }
        envelope["format"] = "OtherApp"
        XCTAssertThrowsError(try OfflineSettingsBackup.decode(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? OfflineSettingsBackupError, .invalidFile)
        }
    }

    func testUnknownKeysAndValuesOutsideTheScopeAreRejected() {
        let data = LANSettingsBundle.encodeValue(true)!
        for preferences in [
            OfflineSettingsBackup.Preferences(keys: ["credential"], values: [:]),
            .init(keys: ["enabled"], values: ["credential": data]),
            .init(keys: ["enabled", "enabled"], values: [:]),
            .init(keys: ["enabled"], values: ["enabled": Data("broken".utf8)])
        ] {
            XCTAssertThrowsError(try preferences.validate(allowedKeys: ["enabled"]))
        }
    }

    func testUnsafeAssetNamesAndInvalidHashesAreRejected() {
        for name in ["../font.otf", "..\\font.otf", ".", "", "/font.otf", "font.txt"] {
            XCTAssertThrowsError(try OfflineSettingsBackup.Asset(kind: .font, name: name, data: Data([1])).validate())
        }
        XCTAssertThrowsError(try OfflineSettingsBackup.Asset(kind: .scraper, name: "../secret", data: Data([1])).validate())
        XCTAssertThrowsError(try OfflineSettingsBackup.Asset(kind: .backdrop, name: String(repeating: "a", count: 64), data: Data([1])).validate())
        var duplicate = backup()
        duplicate.assets = Array(repeating: .init(kind: .font, name: "same.ttf", data: Data([1])), count: 2)
        XCTAssertThrowsError(try duplicate.encoded())
    }

    func testCredentialsAreRemovedRecursivelyWithoutDroppingSettings() throws {
        let raw: [String: Any] = [
            "enabled": true, "cookie": "private-cookie", "secrets": ["custom": "private-secret"],
            "sslTrustDomains": ["example.com"], "hasExplicitRemoteConsent": true,
            "servers": [["address": "https://user:pass@example.com/api?key=private-key&lang=zh&access_token=private-token",
                         "authorization": "private-auth"]],
            "headers": ["Authorization": "private-header", "X-Token": "private-x", "Accept": "application/json"],
            "model": "my-model"
        ]
        let result = try OfflineSettingsRedaction.json(JSONSerialization.data(withJSONObject: raw))
        let text = String(decoding: result, as: UTF8.self)
        XCTAssertFalse(text.contains("private-"))
        XCTAssertFalse(text.contains("sslTrustDomains"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(decoded["enabled"] as? Bool, true)
        XCTAssertEqual(decoded["model"] as? String, "my-model")
        XCTAssertEqual(decoded["hasExplicitRemoteConsent"] as? Bool, false)
        let servers = try XCTUnwrap(decoded["servers"] as? [[String: Any]])
        XCTAssertEqual(servers[0]["address"] as? String, "https://example.com/api?lang=zh")
    }

    func testRestorePreservesOnlyTheMatchingDevicesCredentialsAndConsent() throws {
        let local: [String: Any] = [
            "hasExplicitRemoteConsent": true,
            "servers": [["id": "a", "address": "https://user:pass@example.com/api?token=local", "authorization": "local-a"],
                        ["id": "b", "authorization": "local-b"]],
            "headers": ["Authorization": "local-header", "Accept": "old"]
        ]
        let incoming: [String: Any] = [
            "hasExplicitRemoteConsent": false,
            "servers": [["id": "b"], ["id": "new"], ["id": "a", "address": "https://example.com/api"]]
        ]
        let result = try XCTUnwrap(OfflineSettingsRedaction.preservingLocalCredentials(in: incoming, from: local) as? [String: Any])
        let servers = try XCTUnwrap(result["servers"] as? [[String: Any]])
        XCTAssertEqual(servers[0]["authorization"] as? String, "local-b")
        XCTAssertNil(servers[1]["authorization"])
        XCTAssertEqual(servers[2]["address"] as? String, "https://user:pass@example.com/api?token=local")
        XCTAssertEqual(result["hasExplicitRemoteConsent"] as? Bool, true)
        XCTAssertEqual((result["headers"] as? [String: String])?["Authorization"], "local-header")
        XCTAssertNil((result["headers"] as? [String: String])?["Accept"])
        let changedProvider = OfflineSettingsRedaction.preservingLocalCredentials(in: ["id": "new"], from: ["id": "old", "apiKey": "old-key"]) as? [String: String]
        XCTAssertNil(changedProvider?["apiKey"])
    }

    func testFailedFileWriteRollsBackBothReplacementsAndNewFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a.txt")
        let created = root.appendingPathComponent("b.txt")
        let failure = root.appendingPathComponent("c.txt")
        try Data("old".utf8).write(to: original)
        XCTAssertThrowsError(try OfflineSettingsFileWriter.apply([
            original: Data("new".utf8), created: Data([1]), failure: Data([2])
        ]) { data, url in
            if url == failure { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url)
        })
        XCTAssertEqual(try Data(contentsOf: original), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failure.path))
    }
}
