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
