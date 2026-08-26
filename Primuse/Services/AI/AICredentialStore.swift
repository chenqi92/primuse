import Foundation
import PrimuseKit
import Security

enum AICredentialLookup: Sendable {
    case ready(String)
    case notConfigured
    case temporarilyUnavailable(OSStatus)
    case failed(OSStatus)
}

enum AICredentialStoreError: Error, Sendable {
    case persistenceFailed
    case temporarilyUnavailable(OSStatus)
    case readFailed(OSStatus)
}

protocol AICredentialStoring: Actor {
    func lookupAPIKey(configuration: AIRemoteProviderConfiguration) -> AICredentialLookup
    func requireAPIKey(configuration: AIRemoteProviderConfiguration) throws -> String
    @discardableResult
    func saveAPIKey(_ rawValue: String, configuration: AIRemoteProviderConfiguration) throws -> Bool
    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) throws
}

actor AICredentialStore: AICredentialStoring {
    func lookupAPIKey(configuration: AIRemoteProviderConfiguration) -> AICredentialLookup {
        let scopedAccount: String
        do {
            scopedAccount = try Self.scopedAccount(configuration: configuration)
        } catch {
            return .notConfigured
        }
        switch KeychainService.localOnlyPasswordLookup(for: scopedAccount) {
        case .found(let value):
            return .ready(value)
        case .notFound:
            return migrateLegacyCredential(
                configuration: configuration,
                to: scopedAccount
            )
        case .temporarilyUnavailable(let status):
            return .temporarilyUnavailable(status)
        case .failed(let status):
            return .failed(status)
        }
    }

    func requireAPIKey(configuration: AIRemoteProviderConfiguration) throws -> String {
        switch lookupAPIKey(configuration: configuration) {
        case .ready(let key):
            return key
        case .notConfigured:
            throw MusicIntelligenceError.unavailable(.missingCredential)
        case .temporarilyUnavailable(let status):
            throw AICredentialStoreError.temporarilyUnavailable(status)
        case .failed(let status):
            throw AICredentialStoreError.readFailed(status)
        }
    }

    @discardableResult
    func saveAPIKey(
        _ rawValue: String,
        configuration: AIRemoteProviderConfiguration
    ) throws -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = try Self.scopedAccount(configuration: configuration)
        let legacyAccounts = try Self.legacyAccounts(configuration: configuration)
        if value.isEmpty {
            guard Self.deleteAccounts([account] + legacyAccounts) else {
                throw AICredentialStoreError.persistenceFailed
            }
            return false
        }
        guard KeychainService.setLocalOnlyPassword(value, for: account) else {
            throw AICredentialStoreError.persistenceFailed
        }
        guard Self.deleteAccounts(legacyAccounts) else {
            throw AICredentialStoreError.persistenceFailed
        }
        return true
    }

    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) throws {
        let account = try Self.scopedAccount(configuration: configuration)
        let legacyAccounts = try Self.legacyAccounts(configuration: configuration)
        guard Self.deleteAccounts([account] + legacyAccounts) else {
            throw AICredentialStoreError.persistenceFailed
        }
    }

    private func migrateLegacyCredential(
        configuration: AIRemoteProviderConfiguration,
        to scopedAccount: String
    ) -> AICredentialLookup {
        let legacyAccounts: [String]
        do {
            legacyAccounts = try Self.legacyAccounts(configuration: configuration)
        } catch {
            return .notConfigured
        }

        for legacyAccount in legacyAccounts {
            switch KeychainService.localOnlyPasswordLookup(for: legacyAccount) {
            case .found(let value):
                guard KeychainService.setLocalOnlyPassword(value, for: scopedAccount) else {
                    return .failed(errSecInternalError)
                }
                guard Self.deleteAccounts(legacyAccounts) else {
                    return .failed(errSecInternalError)
                }
                return .ready(value)
            case .notFound:
                continue
            case .temporarilyUnavailable(let status):
                return .temporarilyUnavailable(status)
            case .failed(let status):
                return .failed(status)
            }
        }
        return .notConfigured
    }

    private static func scopedAccount(
        configuration: AIRemoteProviderConfiguration
    ) throws -> String {
        try AICredentialStoragePolicy.scopedAccount(configuration: configuration)
    }

    private static func legacyAccounts(
        configuration: AIRemoteProviderConfiguration
    ) throws -> [String] {
        let originAccount = try AICredentialStoragePolicy.account(
            profileID: configuration.id,
            baseURL: configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
        return [
            originAccount,
            AICredentialStoragePolicy.legacyAccount(profileID: configuration.id),
        ]
    }

    private static func deleteAccounts(_ accounts: [String]) -> Bool {
        var success = true
        for account in Set(accounts) {
            success = KeychainService.deletePassword(for: account) && success
        }
        return success
    }
}
