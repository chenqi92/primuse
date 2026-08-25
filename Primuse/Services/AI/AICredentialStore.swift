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
        let account: String
        do {
            account = try Self.account(configuration: configuration)
        } catch {
            return .notConfigured
        }
        switch KeychainService.localOnlyPasswordLookup(for: account) {
        case .found(let value):
            return .ready(value)
        case .notFound:
            return .notConfigured
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
        let account = try Self.account(configuration: configuration)
        let legacyAccount = AICredentialStoragePolicy.legacyAccount(profileID: configuration.id)
        if value.isEmpty {
            guard KeychainService.deletePassword(for: account),
                  KeychainService.deletePassword(for: legacyAccount) else {
                throw AICredentialStoreError.persistenceFailed
            }
            return false
        }
        guard KeychainService.deletePassword(for: legacyAccount) else {
            throw AICredentialStoreError.persistenceFailed
        }
        guard KeychainService.setLocalOnlyPassword(value, for: account) else {
            throw AICredentialStoreError.persistenceFailed
        }
        return true
    }

    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) throws {
        let account = try Self.account(configuration: configuration)
        let legacyAccount = AICredentialStoragePolicy.legacyAccount(profileID: configuration.id)
        guard KeychainService.deletePassword(for: account),
              KeychainService.deletePassword(for: legacyAccount) else {
            throw AICredentialStoreError.persistenceFailed
        }
    }

    private static func account(configuration: AIRemoteProviderConfiguration) throws -> String {
        try AICredentialStoragePolicy.account(
            profileID: configuration.id,
            baseURL: configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
    }
}
