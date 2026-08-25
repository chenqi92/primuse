import Foundation
import Observation
import PrimuseKit

enum JellyfinSourceCreationPolicy {
    static func requiresPreflight(
        for sourceType: MusicSourceType,
        isEditing: Bool
    ) -> Bool {
        sourceType == .jellyfin && !isEditing
    }
}

enum JellyfinSourceCreationError: LocalizedError {
    case missingPersistenceHandler

    var errorDescription: String? { String(localized: "connection_failed") }
}

struct JellyfinSourceCreationFailure: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case authentication
        case network
        case timeout
        case server
        case credentialPersistence
        case sourcePersistence
        case credentialRollback
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String

    static func connection(_ error: any Error) -> Self {
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed:
                return localized(
                    kind: .authentication,
                    title: "source_diag_advice_auth_title",
                    message: "source_diag_advice_auth_message",
                    suggestion: "source_diag_advice_auth_suggestion"
                )
            case .timeout:
                return timeoutFailure()
            case .pathNotFound, .fileNotFound, .connectionFailed, .credentialUnavailable:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
                return localized(
                    kind: .authentication,
                    title: "source_diag_advice_auth_title",
                    message: "source_diag_advice_auth_message",
                    suggestion: "source_diag_advice_auth_suggestion"
                )
            case NSURLErrorTimedOut:
                return timeoutFailure()
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return localized(
                    kind: .network,
                    title: "source_diag_advice_network_title",
                    message: "source_diag_advice_network_message",
                    suggestion: "source_diag_advice_network_suggestion"
                )
            default:
                break
            }
        }

        return localized(
            kind: .server,
            title: "source_diag_advice_server_title",
            message: "connection_failed",
            suggestion: "source_diag_advice_server_suggestion"
        )
    }

    static func credentialPersistence() -> Self {
        Self(
            kind: .credentialPersistence,
            title: String(localized: "credential_save_failed_title"),
            message: String(localized: "credential_save_failed_message")
        )
    }

    static func sourcePersistence(_ error: any Error, rollbackSucceeded: Bool) -> Self {
        if !rollbackSucceeded {
            return Self(
                kind: .credentialRollback,
                title: String(localized: "credential_save_failed_title"),
                message: String(localized: "credential_save_failed_message")
            )
        }
        return Self(
            kind: .sourcePersistence,
            title: String(localized: "connection_failed"),
            message: error.localizedDescription
        )
    }

    private static func timeoutFailure() -> Self {
        localized(
            kind: .timeout,
            title: "source_diag_advice_timeout_title",
            message: "source_diag_advice_timeout_message",
            suggestion: "source_diag_advice_timeout_suggestion"
        )
    }

    private static func localized(
        kind: Kind,
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        suggestion: String.LocalizationValue
    ) -> Self {
        let message = String(localized: message)
        let suggestion = String(localized: suggestion)
        return Self(
            kind: kind,
            title: String(localized: title),
            message: suggestion.isEmpty ? message : "\(message)\n\n\(suggestion)"
        )
    }
}

enum JellyfinSourceCreationPreflight {
    static func validate(
        source: MusicSource,
        secret: String,
        requestDataLoader: MediaServerSource.RequestDataLoader? = nil
    ) async throws {
        guard source.type == .jellyfin else {
            throw SourceError.connectionFailed("Unsupported creation preflight")
        }

        let connector = MediaServerSource(
            sourceID: source.id,
            kind: .jellyfin,
            host: source.host ?? "",
            port: source.port,
            useSsl: source.useSsl,
            basePath: source.basePath,
            username: source.username ?? "",
            secret: secret,
            authType: source.authType,
            alternateTLSValidationHostname: source.alternateTLSValidationHostname,
            requestDataLoader: requestDataLoader
        )
        do {
            try await connector.connect()
            await connector.disconnect()
        } catch {
            await connector.disconnect()
            throw error
        }
    }
}

@MainActor
@Observable
final class JellyfinSourceCreationTransaction {
    typealias Preflight = @Sendable (MusicSource, String) async throws -> Void

    private let timeout: TimeInterval
    private let preflight: Preflight
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    private(set) var isRunning = false
    private(set) var didCommit = false
    private(set) var failure: JellyfinSourceCreationFailure?

    init(timeout: TimeInterval = 15, preflight: Preflight? = nil) {
        self.timeout = timeout
        self.preflight = preflight ?? { source, secret in
            try await JellyfinSourceCreationPreflight.validate(
                source: source,
                secret: secret
            )
        }
    }

    func submit(
        source: MusicSource,
        secret: String,
        persistCredential: @escaping @MainActor (String, String) -> Bool,
        removeCredential: @escaping @MainActor (String) -> Bool,
        persistSource: @escaping @MainActor (MusicSource) throws -> Void,
        onCommit: @escaping @MainActor (MusicSource) -> Void
    ) {
        guard !isRunning, !didCommit else { return }

        generation &+= 1
        let requestGeneration = generation
        let timeout = timeout
        let preflight = preflight
        failure = nil
        isRunning = true

        task = Task { @MainActor [weak self] in
            do {
                try await AsyncOperationTimeout.run(seconds: timeout) {
                    try await preflight(source, secret)
                }
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.task = nil
                self.isRunning = false
                guard !OperationCancellationPolicy.isCancellation(error) else { return }
                self.failure = .connection(error)
                return
            }

            guard let self,
                  self.generation == requestGeneration,
                  !Task.isCancelled else { return }

            guard persistCredential(source.id, secret) else {
                self.task = nil
                self.isRunning = false
                self.failure = .credentialPersistence()
                return
            }

            do {
                try persistSource(source)
            } catch {
                let rollbackSucceeded = removeCredential(source.id)
                self.task = nil
                self.isRunning = false
                self.failure = .sourcePersistence(
                    error,
                    rollbackSucceeded: rollbackSucceeded
                )
                return
            }

            self.task = nil
            self.isRunning = false
            self.didCommit = true
            onCommit(source)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isRunning = false
        failure = nil
    }

    func clearFailure() {
        failure = nil
    }
}
