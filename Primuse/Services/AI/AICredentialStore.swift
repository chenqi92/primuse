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

actor AICredentialStore {
    func lookupAPIKey(profileID: UUID) -> AICredentialLookup {
        let account = AICredentialStoragePolicy.account(profileID: profileID)
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

    func requireAPIKey(profileID: UUID) throws -> String {
        switch lookupAPIKey(profileID: profileID) {
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
    func saveAPIKey(_ rawValue: String, profileID: UUID) throws -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = AICredentialStoragePolicy.account(profileID: profileID)
        if value.isEmpty {
            guard KeychainService.deletePassword(for: account) else {
                throw AICredentialStoreError.persistenceFailed
            }
            return false
        }
        guard KeychainService.setLocalOnlyPassword(value, for: account) else {
            throw AICredentialStoreError.persistenceFailed
        }
        return true
    }

    func deleteAPIKey(profileID: UUID) throws {
        let account = AICredentialStoragePolicy.account(profileID: profileID)
        guard KeychainService.deletePassword(for: account) else {
            throw AICredentialStoreError.persistenceFailed
        }
    }
}
