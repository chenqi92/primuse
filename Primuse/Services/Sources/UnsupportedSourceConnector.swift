import Foundation
import PrimuseKit

actor UnsupportedSourceConnector: MusicSourceConnector {
    let sourceID: String
    private let sourceType: MusicSourceType

    init(sourceID: String, sourceType: MusicSourceType) {
        self.sourceID = sourceID
        self.sourceType = sourceType
    }

    func connect() async throws {
        throw unsupportedError
    }

    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        throw unsupportedError
    }

    func localURL(for path: String) async throws -> URL {
        throw unsupportedError
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw unsupportedError
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        throw unsupportedError
    }

    private var unsupportedError: SourceError {
        .connectionFailed("\(sourceType.displayName) is not implemented yet")
    }
}

/// A fail-closed connector for an explicitly configured connection strategy
/// whose active side has no usable endpoint. Falling back to the projected
/// legacy host here would silently violate Local Only / Remote Only.
actor NoAvailableConnectionSourceConnector: MusicSourceConnector, ServerListeningStatsConnector {
    let sourceID: String

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func connect() async throws { throw unavailableError }
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { throw unavailableError }
    func localURL(for path: String) async throws -> URL { throw unavailableError }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { throw unavailableError }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        throw unavailableError
    }
    func fetchServerListeningStats() async throws -> ServerListeningStatsPayload {
        throw unavailableError
    }

    private var unavailableError: SourceError {
        .connectionFailed(String(localized: "source_connection_no_route"))
    }
}

/// A fail-closed connector used when a source secret could not be read.
/// Returning this instead of constructing the real connector guarantees that
/// a transient Keychain outage never becomes an empty-password login attempt.
actor CredentialUnavailableSourceConnector: MusicSourceConnector, ServerListeningStatsConnector {
    enum Failure: Sendable {
        case temporarilyUnavailable(Int32)
        case failed(Int32)
    }

    let sourceID: String
    private let failure: Failure

    init(sourceID: String, failure: Failure) {
        self.sourceID = sourceID
        self.failure = failure
    }

    func connect() async throws { throw unavailableError }
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { throw unavailableError }
    func localURL(for path: String) async throws -> URL { throw unavailableError }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { throw unavailableError }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { throw unavailableError }
    func fetchServerListeningStats() async throws -> ServerListeningStatsPayload { throw unavailableError }

    private var unavailableError: SourceError {
        switch failure {
        case .temporarilyUnavailable:
            return .credentialUnavailable(String(localized: "credential_temporarily_unavailable"))
        case .failed:
            return .credentialUnavailable(String(localized: "credential_read_failed"))
        }
    }
}

func credentialProtectedConnector(
    for source: MusicSource,
    build: (String) -> any MusicSourceConnector
) -> any MusicSourceConnector {
    switch KeychainService.connectorCredential(for: source) {
    case .ready(let secret):
        return build(secret)
    case .temporarilyUnavailable(let status):
        plog("⏳ Source '\(source.id)' credential temporarily unavailable status=\(status)")
        return CredentialUnavailableSourceConnector(
            sourceID: source.id,
            failure: .temporarilyUnavailable(status)
        )
    case .failed(let status):
        plog("⛔ Source '\(source.id)' credential read failed status=\(status)")
        return CredentialUnavailableSourceConnector(
            sourceID: source.id,
            failure: .failed(status)
        )
    }
}
