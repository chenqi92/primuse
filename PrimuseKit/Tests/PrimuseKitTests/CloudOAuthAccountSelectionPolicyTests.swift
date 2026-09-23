import Foundation
import Testing
@testable import PrimuseKit

@Suite("Cloud OAuth account selection")
struct CloudOAuthAccountSelectionPolicyTests {
    @Test("Different-account authorization uses an isolated browser session")
    func differentAccountUsesEphemeralSession() {
        #expect(CloudOAuthAccountSelectionPolicy.prefersEphemeralSession(for: .differentAccount))
        #expect(!CloudOAuthAccountSelectionPolicy.prefersEphemeralSession(for: .standard))
        #expect(!CloudOAuthAccountSelectionPolicy.prefersEphemeralSession(for: .useSignedInAccount))
    }

    @Test("Providers receive their supported account chooser parameters")
    func providerParameters() {
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .baiduPan,
            intent: .differentAccount
        )["force_login"] == "1")
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .googleDrive,
            intent: .differentAccount
        )["prompt"] == "select_account consent")
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .oneDrive,
            intent: .differentAccount
        )["prompt"] == "select_account")
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .dropbox,
            intent: .differentAccount
        )["force_reauthentication"] == "true")
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .dropbox,
            intent: .differentAccount
        )["force_reapprove"] == "true")
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .aliyunDrive,
            intent: .differentAccount
        )["prompt"] == "login")
    }

    @Test("Undocumented providers do not receive invented query parameters")
    func undocumentedProvidersUseSessionIsolationOnly() {
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .pan123,
            intent: .differentAccount
        ).isEmpty)
        #expect(CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .pan115,
            intent: .differentAccount
        ).isEmpty)
    }

    @Test("Google requests refreshable access for every mount")
    func googleOfflineAccess() {
        let parameters = CloudOAuthAccountSelectionPolicy.authorizationParameters(
            provider: .googleDrive,
            intent: .standard
        )
        #expect(parameters["access_type"] == "offline")
        #expect(parameters["include_granted_scopes"] == "true")
    }

    @Test("Provider parameters replace duplicate URL query keys")
    func authorizationURLParametersAreMergedWithoutDuplicates() {
        let result = CloudOAuthAccountSelectionPolicy.applyingAuthorizationParameters(
            to: [
                URLQueryItem(name: "client_id", value: "client"),
                URLQueryItem(name: "prompt", value: "none"),
            ],
            provider: .oneDrive,
            intent: .differentAccount
        )

        #expect(result.filter { $0.name == "client_id" }.count == 1)
        #expect(result.filter { $0.name == "prompt" }.count == 1)
        #expect(result.first { $0.name == "prompt" }?.value == "select_account")
    }

    @Test("Every source UUID owns a distinct credential namespace")
    func credentialsAreIsolatedPerSource() {
        let first = "source-a"
        let second = "source-b"

        #expect(CloudCredentialStorageKeyPolicy.tokenKey(sourceID: first)
            != CloudCredentialStorageKeyPolicy.tokenKey(sourceID: second))
        #expect(CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: first)
            != CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: second))
        #expect(CloudCredentialStorageKeyPolicy.tokenKey(sourceID: first)
            != CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: first))
        #expect(CloudCredentialStorageKeyPolicy.tokenKey(sourceID: first)
            == "cloud_tokens_source-a")
        #expect(CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: first)
            == "cloud_creds_source-a")
    }

    @Test("Cancelling authorization never commits credentials")
    func cancellationRollsBackBeforeCredentialCommit() async {
        var commitCount = 0

        do {
            let _: String = try await CloudOAuthCredentialTransaction.authorizeThenCommit {
                throw CancellationError()
            } commit: { _ in
                commitCount += 1
            }
            Issue.record("Expected authorization cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(commitCount == 0)
    }

    @Test("Provider failure never commits credentials")
    func providerFailureRollsBackBeforeCredentialCommit() async {
        enum ProviderError: Error {
            case denied
        }

        var commitCount = 0
        do {
            let _: String = try await CloudOAuthCredentialTransaction.authorizeThenCommit {
                throw ProviderError.denied
            } commit: { _ in
                commitCount += 1
            }
            Issue.record("Expected provider failure")
        } catch ProviderError.denied {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(commitCount == 0)
    }
}

@Suite("Cloud account mount keeper election")
struct CloudAccountMountKeeperPolicyTests {
    @Test("Election depends only on the ids, not on their order")
    func electionIgnoresInputOrder() {
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: ["b", "a", "c"]) == "a")
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: ["c", "a", "b"]) == "a")
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: ["a"]) == "a")
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: []) == nil)
    }

    @Test("Overlapping device views never elect keepers that delete each other")
    func overlappingViewsNeverDeleteEachOthersKeeper() {
        // 设备 A 看到 {m1, m2}，设备 B 看到 {m2, m3}(m1 还没同步到 B)：
        // A 留 m1 删 m2，B 留 m2 删 m3；B 从未见过 m1，也就不会删它，最后两边都只剩 m1。
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: ["m2", "m1"]) == "m1")
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: ["m3", "m2"]) == "m2")

        // 穷举两台设备各自能看到的任意非空子集：互删要求各自删掉对方的 keeper，
        // 即对方的 keeper 在我方视野里且不是我方的 keeper —— 这种组合不存在。
        let ids = ["m1", "m2", "m3", "m4"]
        let views: [[String]] = (1..<(1 << ids.count)).map { mask in
            ids.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element }
        }
        for a in views {
            for b in views {
                guard let keeperA = CloudAccountMountKeeperPolicy.keeperID(among: a),
                      let keeperB = CloudAccountMountKeeperPolicy.keeperID(among: b) else {
                    Issue.record("Non-empty views must elect a keeper")
                    continue
                }
                let aDeletesB = a.contains(keeperB) && keeperB != keeperA
                let bDeletesA = b.contains(keeperA) && keeperA != keeperB
                #expect(!(aDeletesB && bDeletesA), "views \(a) / \(b) would delete each other")
            }
        }
    }

    @Test("A device that already migrated keeps the keeper another device elected")
    func rerunFollowsTombstones() {
        // 别的设备留 m1 删了 m2；这台设备重跑时 m2 已是墓碑、不再参与分组。
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: ["m1"]) == "m1")
        // 墓碑还没到、两份都活着：按同一条规则也选出 m1，不会删掉别人留下的那份。
        #expect(CloudAccountMountKeeperPolicy.keeperID(among: ["m2", "m1"]) == "m1")
    }
}
